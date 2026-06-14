import gleam/dict
import gleam/erlang/process.{
  type Subject, new_subject, receive, send, spawn_unlinked,
}
import gleam/list
import gleam/otp/actor as otp_actor
import neon/net
import neon/udp
import protocol/udp_protocol
import vswitch/server

/// UDP server 的启动配置。
pub type UdpServerConfig {
  UdpServerConfig(vswitch: server.Server, bind_host: String, bind_port: Int)
}

/// UDP server 句柄。
pub opaque type UdpServer {
  UdpServer(control: Subject(Control), bound_port: Int)
}

/// UDP server 启动阶段可能返回的错误。
pub type ServerError {
  InvalidBindPort
  OpenFailed
  ReadBoundPortFailed
  StartTimedOut
}

type Control {
  Stop
}

type StartAck {
  Started(port: Int, control: Subject(Control))
  Failed(reason: ServerError)
}

type Endpoint {
  Endpoint(ip_address: net.IpAddress, port: net.Port)
}

type ClientSession {
  ClientSession(endpoint: Endpoint, receiver: server.ForwardedReceiver)
}

// --- Sessions actor ---

type SessionsState {
  SessionsState(
    switch: server.Server,
    by_client_id: dict.Dict(String, ClientSession),
    by_endpoint: dict.Dict(Endpoint, String),
  )
}

type SessionsMessage {
  BindEndpoint(client_id: String, endpoint: Endpoint)
  LookupByEndpoint(endpoint: Endpoint, reply_to: Subject(Result(String, Nil)))
  GetAll(reply_to: Subject(List(ClientSession)))
}

// --- Public API ---

/// 启动一个 UDP server。
///
/// 内部分为三个并行部分：
/// - sessions actor：管理 client_id <-> endpoint 双向索引
/// - upstream 进程：专门处理 UDP 入包，上行帧送入 vswitch
/// - downstream 进程：专门刷 vswitch 下行帧，发回对应客户端
pub fn start(config: UdpServerConfig) -> Result(UdpServer, ServerError) {
  let ack = new_subject()
  let _ = spawn_unlinked(fn() { server_process(config, ack) })

  case receive(ack, 1000) {
    Ok(Started(port, control)) -> Ok(UdpServer(control:, bound_port: port))
    Ok(Failed(reason)) -> Error(reason)
    _ -> Error(StartTimedOut)
  }
}

/// 返回 UDP server 实际绑定的本地端口。
pub fn bound_port(server: UdpServer) -> Int {
  server.bound_port
}

/// 停止 UDP server 及其所有子进程。
pub fn stop(server: UdpServer) -> Nil {
  send(server.control, Stop)
}

// --- 主进程：负责启动子进程，等待 Stop 后统一关闭 ---

fn server_process(config: UdpServerConfig, ack: Subject(StartAck)) -> Nil {
  case net.port(config.bind_port) {
    Ok(bind_port) ->
      case udp.open(udp.new(bind_port)) {
        Ok(socket) ->
          case udp.port(socket) {
            Ok(actual_port) -> {
              let control = new_subject()
              let upstream_control = new_subject()
              let downstream_control = new_subject()
              let sessions = start_sessions_actor(config.vswitch)

              let _ =
                spawn_unlinked(fn() {
                  upstream_loop(
                    config.vswitch,
                    socket,
                    sessions,
                    upstream_control,
                  )
                })

              let _ =
                spawn_unlinked(fn() {
                  downstream_loop(socket, sessions, downstream_control)
                })

              send(ack, Started(net.port_to_int(actual_port), control))
              wait_for_stop(control, upstream_control, downstream_control, socket)
            }

            Error(Nil) -> send(ack, Failed(ReadBoundPortFailed))
          }

        Error(_) -> send(ack, Failed(OpenFailed))
      }

    Error(_) -> send(ack, Failed(InvalidBindPort))
  }
}

fn wait_for_stop(
  control: Subject(Control),
  upstream_control: Subject(Control),
  downstream_control: Subject(Control),
  socket: udp.Udp,
) -> Nil {
  case receive(control, 60_000) {
    Ok(Stop) -> {
      send(upstream_control, Stop)
      send(downstream_control, Stop)
      udp.close(socket)
    }
    Error(Nil) ->
      wait_for_stop(control, upstream_control, downstream_control, socket)
  }
}

// --- Sessions actor ---

fn start_sessions_actor(switch: server.Server) -> Subject(SessionsMessage) {
  let builder =
    otp_actor.new(SessionsState(
      switch:,
      by_client_id: dict.new(),
      by_endpoint: dict.new(),
    ))
    |> otp_actor.on_message(handle_sessions_message)

  let assert Ok(started) = otp_actor.start(builder)
  started.data
}

fn handle_sessions_message(
  state: SessionsState,
  message: SessionsMessage,
) -> otp_actor.Next(SessionsState, SessionsMessage) {
  case message {
    BindEndpoint(client_id, endpoint) ->
      otp_actor.continue(do_bind_endpoint(state, client_id, endpoint))

    LookupByEndpoint(endpoint, reply_to) -> {
      send(reply_to, dict.get(state.by_endpoint, endpoint))
      otp_actor.continue(state)
    }

    GetAll(reply_to) -> {
      send(reply_to, dict.values(state.by_client_id))
      otp_actor.continue(state)
    }
  }
}

fn do_bind_endpoint(
  state: SessionsState,
  client_id: String,
  endpoint: Endpoint,
) -> SessionsState {
  let #(receiver, by_endpoint) = case dict.get(state.by_client_id, client_id) {
    Ok(ClientSession(receiver:, endpoint: old_endpoint)) -> #(
      receiver,
      dict.delete(state.by_endpoint, old_endpoint),
    )
    Error(Nil) -> {
      let receiver = server.new_receiver()
      server.connect(state.switch, client_id, receiver)
      #(receiver, state.by_endpoint)
    }
  }

  let session = ClientSession(endpoint:, receiver:)
  SessionsState(
    ..state,
    by_client_id: dict.insert(state.by_client_id, client_id, session),
    by_endpoint: dict.insert(by_endpoint, endpoint, client_id),
  )
}

// --- Upstream 进程：专门处理 UDP 入包 ---

fn upstream_loop(
  switch: server.Server,
  socket: udp.Udp,
  sessions: Subject(SessionsMessage),
  control: Subject(Control),
) -> Nil {
  case receive(control, 0) {
    Ok(Stop) -> Nil
    Error(Nil) -> {
      let timeout = case net.timeout(100) {
        Ok(t) -> t
        Error(_) -> net.infinity
      }
      case udp.receive(socket, 0, timeout) {
        Ok(udp.ReceiveData(ip_address:, port:, payload:)) ->
          handle_upstream_packet(
            switch,
            socket,
            sessions,
            ip_address,
            port,
            payload,
          )
        Error(_) -> Nil
      }
      upstream_loop(switch, socket, sessions, control)
    }
  }
}

fn handle_upstream_packet(
  switch: server.Server,
  socket: udp.Udp,
  sessions: Subject(SessionsMessage),
  ip_address: net.IpAddress,
  port: net.Port,
  payload: BitArray,
) -> Nil {
  let endpoint = Endpoint(ip_address:, port:)

  case udp_protocol.decode_client_message(payload) {
    Ok(udp_protocol.Hello(client_id)) -> {
      send(sessions, BindEndpoint(client_id, endpoint))
      let _ = send_server_message(socket, ip_address, port, udp_protocol.Welcome)
      Nil
    }

    Ok(udp_protocol.ClientFrame(frame)) -> {
      let reply_to = new_subject()
      send(sessions, LookupByEndpoint(endpoint, reply_to))
      case receive(reply_to, 100) {
        Ok(Ok(client_id)) -> server.receive_from(switch, client_id, frame)
        _ -> Nil
      }
    }

    Error(_) -> Nil
  }
}

// --- Downstream 进程：专门刷 vswitch 下行帧 ---

fn downstream_loop(
  socket: udp.Udp,
  sessions: Subject(SessionsMessage),
  control: Subject(Control),
) -> Nil {
  case receive(control, 1) {
    Ok(Stop) -> Nil
    Error(Nil) -> {
      flush_all_sessions(socket, sessions)
      downstream_loop(socket, sessions, control)
    }
  }
}

fn flush_all_sessions(
  socket: udp.Udp,
  sessions: Subject(SessionsMessage),
) -> Nil {
  let reply_to = new_subject()
  send(sessions, GetAll(reply_to))
  case receive(reply_to, 100) {
    Ok(all_sessions) ->
      list.each(all_sessions, fn(session) {
        flush_session_frames(socket, session)
      })
    Error(Nil) -> Nil
  }
}

fn flush_session_frames(socket: udp.Udp, session: ClientSession) -> Nil {
  case server.receive_forwarded(session.receiver, 0) {
    server.Forwarded(_, frame) -> {
      let Endpoint(ip_address:, port:) = session.endpoint
      let _ =
        send_server_message(
          socket,
          ip_address,
          port,
          udp_protocol.ServerFrame(frame),
        )
      flush_session_frames(socket, session)
    }
    server.Timeout -> Nil
  }
}

fn send_server_message(
  socket: udp.Udp,
  ip_address: net.IpAddress,
  port: net.Port,
  message: udp_protocol.ServerMessage,
) -> Result(Nil, Nil) {
  let assert Ok(payload) = udp_protocol.encode_server_message(message)
  udp_send_to(socket, ip_address, port, payload)
}

@external(erlang, "udp_server_ffi", "send_to")
fn udp_send_to(
  socket: udp.Udp,
  ip_address: net.IpAddress,
  port: net.Port,
  payload: BitArray,
) -> Result(Nil, Nil)
