import gleam/erlang/process.{
  type Subject, new_selector, new_subject, receive, select, select_map, send,
}
import gleam/list
import gleam/otp/actor as otp_actor
import neon/net
import neon/udp
import protocol/udp_protocol
import vswitch/server

/// 客户端侧 transport 句柄。
///
/// 外部只能通过它向上游发送帧、接收上游帧，
/// 不直接接触底层 `vswitch receiver` 或 UDP socket。
///
/// 约束：
/// - transport 自己创建并持有底层 socket / receiver
/// - 不提供把外部 socket 直接塞进 actor 的公开接口
/// - 若未来必须跨进程移交 socket，必须先显式完成 owner handoff
pub opaque type ClientTransport {
  ActorTransport(subject: Subject(Message))
}

pub type ReceiveResult {
  Received(frame: BitArray)
  TimedOut
}

/// 用于启动 UDP transport actor 的配置。
pub type UdpStartConfig {
  UdpStartConfig(
    client_id: server.ClientId,
    server_host: String,
    server_port: Int,
    local_port: Int,
  )
}

/// UDP transport 初始化阶段可能返回的错误。
pub type UdpStartError {
  InvalidLocalPort
  InvalidServerPort
  OpenFailed
  ConnectFailed
  SendFailed
  HandshakeTimeout
  ReceiveFailed
  InvalidHandshakeTimeout
  HandshakeDecodeFailed
  UnexpectedHandshakeMessage
  InitFailed
}

type Message {
  SendToServer(frame: BitArray)
  ReceiveFromServer(timeout_ms: Int, reply_to: Subject(ReceiveResult))
  VswitchForwarded(forwarded: server.ForwardedFrame)
  Stop
}

type State {
  Vswitch(
    switch: server.Server,
    client_id: server.ClientId,
    receiver: server.ForwardedReceiver,
    pending_frames: List(BitArray),
  )
  Udp(socket: udp.Udp)
}

/// 通过 transport 向上游发送一帧。
pub fn send_to_server(transport: ClientTransport, frame: BitArray) -> Nil {
  let ActorTransport(subject) = transport
  send(subject, SendToServer(frame))
}

/// 从 transport 读取一帧上游下发的数据。
///
/// 若在 `timeout_ms` 内没有拿到帧，则返回 `TimedOut`。
pub fn receive_from_server(
  transport: ClientTransport,
  timeout_ms: Int,
) -> ReceiveResult {
  let ActorTransport(subject) = transport
  let reply_to = new_subject()
  send(subject, ReceiveFromServer(timeout_ms, reply_to))

  case receive(reply_to, timeout_ms + 50) {
    Ok(result) -> result
    Error(Nil) -> TimedOut
  }
}

/// 停止 transport actor，并释放底层链路资源。
pub fn stop(transport: ClientTransport) -> Nil {
  let ActorTransport(subject) = transport
  send(subject, Stop)
}

/// 连接到当前 BEAM 节点中的 `vswitch` actor。
///
/// 这个入口主要用于本机开发、测试和不经过真实网络的集成验证。
pub fn connect_vswitch(
  switch: server.Server,
  client_id: server.ClientId,
) -> Result(ClientTransport, String) {
  let builder =
    otp_actor.new_with_initialiser(1000, fn(subject) {
      let receiver = server.new_receiver()
      let selector =
        new_selector()
        |> select(subject)
        |> select_map(receiver, VswitchForwarded)

      server.connect(switch, client_id, receiver)

      Ok(
        otp_actor.initialised(
          Vswitch(
            switch: switch,
            client_id: client_id,
            receiver: receiver,
            pending_frames: [],
          ),
        )
        |> otp_actor.selecting(selector)
        |> otp_actor.returning(subject),
      )
    })
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(ActorTransport(started.data))
    Error(otp_actor.InitFailed(reason)) -> Error(reason)
    Error(_) -> Error("failed to start vswitch transport")
  }
}

/// 启动一个持有 UDP socket 的 transport actor。
///
/// actor 会在初始化阶段完成：
/// - 打开本地 UDP socket
/// - connect 到服务端地址
/// - 发送 `Hello`
/// - 等待 `Welcome`
pub fn start_udp_client(
  config: UdpStartConfig,
) -> Result(ClientTransport, UdpStartError) {
  let builder =
    otp_actor.new_with_initialiser(1000, fn(subject) {
      case open_and_handshake(config) {
        Ok(socket) ->
          Ok(otp_actor.initialised(Udp(socket)) |> otp_actor.returning(subject))
        Error(error) -> Error(error_to_string(error))
      }
    })
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(ActorTransport(started.data))
    Error(otp_actor.InitFailed(reason)) -> Error(error_from_string(reason))
    Error(_) -> Error(InitFailed)
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> otp_actor.Next(State, Message) {
  case message {
    SendToServer(frame) -> {
      send_frame(state, frame)
      otp_actor.continue(state)
    }

    ReceiveFromServer(timeout_ms, reply_to) -> {
      let #(state, result) = receive_frame(state, timeout_ms)
      send(reply_to, result)
      otp_actor.continue(state)
    }

    VswitchForwarded(forwarded) -> {
      otp_actor.continue(store_forwarded(state, forwarded))
    }

    Stop -> {
      stop_state(state)
      otp_actor.stop()
    }
  }
}

fn send_frame(state: State, frame: BitArray) -> Nil {
  case state {
    Vswitch(switch:, client_id:, ..) ->
      server.receive_from(switch, client_id, frame)
    Udp(socket) -> {
      let assert Ok(payload) =
        udp_protocol.encode_client_message(udp_protocol.ClientFrame(frame))
      let _ = udp.send(socket, payload)
      Nil
    }
  }
}

fn receive_frame(state: State, timeout_ms: Int) -> #(State, ReceiveResult) {
  case state {
    Vswitch(pending_frames: [frame, ..rest], ..) -> #(
      Vswitch(..state, pending_frames: rest),
      Received(frame),
    )

    Vswitch(receiver:, pending_frames: [], ..) ->
      case server.receive_forwarded(receiver, timeout_ms) {
        server.Forwarded(_, frame) -> #(state, Received(frame))
        server.Timeout -> #(state, TimedOut)
      }

    Udp(socket) ->
      case udp.receive(socket, 0, safe_timeout(timeout_ms)) {
        Ok(received) ->
          case udp_protocol.decode_server_message(received.payload) {
            Ok(udp_protocol.ServerFrame(frame)) -> #(state, Received(frame))
            _ -> #(state, TimedOut)
          }

        Error(udp.Timeout) -> #(state, TimedOut)
        Error(_) -> #(state, TimedOut)
      }
  }
}

fn store_forwarded(state: State, forwarded: server.ForwardedFrame) -> State {
  case state, forwarded {
    Vswitch(pending_frames:, ..), server.Forwarded(_, frame) ->
      Vswitch(..state, pending_frames: list.append(pending_frames, [frame]))

    _, server.Timeout -> state
    Udp(_), _ -> state
  }
}

fn stop_state(state: State) -> Nil {
  case state {
    Vswitch(switch:, client_id:, ..) -> server.disconnect(switch, client_id)
    Udp(socket) -> udp.close(socket)
  }
}

fn open_and_handshake(
  config: UdpStartConfig,
) -> Result(udp.Udp, UdpStartError) {
  case net.port(config.local_port), net.port(config.server_port) {
    Ok(local_port), Ok(server_port) -> {
      let server_address = net.hostname(config.server_host)
      case udp.open(udp.new(local_port)) {
        Ok(socket) ->
          case udp.connect(socket, server_address, server_port) {
            Ok(Nil) ->
              case send_hello(config, socket) {
                Ok(Nil) ->
                  case receive_welcome(socket) {
                    Ok(Nil) -> Ok(socket)
                    Error(error) -> Error(error)
                  }

                Error(error) -> Error(error)
              }
            Error(_) -> Error(ConnectFailed)
          }

        Error(_) -> Error(OpenFailed)
      }
    }

    Error(_), _ -> Error(InvalidLocalPort)
    _, Error(_) -> Error(InvalidServerPort)
  }
}

fn send_hello(
  config: UdpStartConfig,
  socket: udp.Udp,
) -> Result(Nil, UdpStartError) {
  let assert Ok(hello) =
    udp_protocol.Hello(config.client_id)
    |> udp_protocol.encode_client_message()

  case udp.send(socket, hello) {
    Ok(Nil) -> Ok(Nil)
    Error(_) -> Error(SendFailed)
  }
}

fn receive_welcome(socket: udp.Udp) -> Result(Nil, UdpStartError) {
  case net.timeout(1000) {
    Ok(timeout) ->
      case udp.receive(socket, 0, timeout) {
        Ok(reply) ->
          case udp_protocol.decode_server_message(reply.payload) {
            Ok(udp_protocol.Welcome) -> Ok(Nil)
            Ok(udp_protocol.ServerFrame(_)) -> Error(UnexpectedHandshakeMessage)
            Error(_) -> Error(HandshakeDecodeFailed)
          }

        Error(udp.Timeout) -> Error(HandshakeTimeout)
        Error(_) -> Error(ReceiveFailed)
      }

    Error(_) -> Error(InvalidHandshakeTimeout)
  }
}

fn safe_timeout(timeout_ms: Int) -> net.Timeout {
  case net.timeout(timeout_ms) {
    Ok(timeout) -> timeout
    Error(_) -> net.infinity
  }
}

fn error_to_string(error: UdpStartError) -> String {
  case error {
    InvalidLocalPort -> "invalid_local_port"
    InvalidServerPort -> "invalid_server_port"
    OpenFailed -> "open_failed"
    ConnectFailed -> "connect_failed"
    SendFailed -> "send_failed"
    HandshakeTimeout -> "handshake_timeout"
    ReceiveFailed -> "receive_failed"
    InvalidHandshakeTimeout -> "invalid_handshake_timeout"
    HandshakeDecodeFailed -> "handshake_decode_failed"
    UnexpectedHandshakeMessage -> "unexpected_handshake_message"
    InitFailed -> "init_failed"
  }
}

fn error_from_string(reason: String) -> UdpStartError {
  case reason {
    "invalid_local_port" -> InvalidLocalPort
    "invalid_server_port" -> InvalidServerPort
    "open_failed" -> OpenFailed
    "connect_failed" -> ConnectFailed
    "send_failed" -> SendFailed
    "handshake_timeout" -> HandshakeTimeout
    "receive_failed" -> ReceiveFailed
    "invalid_handshake_timeout" -> InvalidHandshakeTimeout
    "handshake_decode_failed" -> HandshakeDecodeFailed
    "unexpected_handshake_message" -> UnexpectedHandshakeMessage
    _ -> InitFailed
  }
}
