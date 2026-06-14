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

// --- Sessions actor ---
//
// 每个 session 对应一个 forwarder 进程，forwarder 持有 receiver（Subject owner），
// 收到下行帧后发 GotFrame 给 sessions actor。
// sessions actor 自己只处理 SessionsMessage，不碰任何 receiver。

type ClientSession {
  ClientSession(endpoint: Endpoint)
}

type SessionsState {
  SessionsState(
    switch: server.Server,
    self: Subject(SessionsMessage),
    by_client_id: dict.Dict(String, ClientSession),
    by_endpoint: dict.Dict(Endpoint, String),
    pending_frames: List(#(Endpoint, BitArray)),
  )
}

type SessionsMessage {
  BindEndpoint(client_id: String, endpoint: Endpoint)
  LookupByEndpoint(endpoint: Endpoint, reply_to: Subject(Result(String, Nil)))
  GotFrame(endpoint: Endpoint, frame: BitArray)
  PollAll(reply_to: Subject(List(#(Endpoint, BitArray))))
}

// --- Public API ---

pub fn start(config: UdpServerConfig) -> Result(UdpServer, ServerError) {
  let ack = new_subject()
  let _ = spawn_unlinked(fn() { server_process(config, ack) })

  case receive(ack, 1000) {
    Ok(Started(port, control)) -> Ok(UdpServer(control:, bound_port: port))
    Ok(Failed(reason)) -> Error(reason)
    _ -> Error(StartTimedOut)
  }
}

pub fn bound_port(server: UdpServer) -> Int {
  server.bound_port
}

pub fn stop(server: UdpServer) -> Nil {
  send(server.control, Stop)
}

// --- 主进程 ---

fn server_process(config: UdpServerConfig, ack: Subject(StartAck)) -> Nil {
  case net.port(config.bind_port) {
    Ok(bind_port) ->
      case udp.open(udp.new(bind_port)) {
        Ok(socket) ->
          case udp.port(socket) {
            Ok(actual_port) -> {
              let control = new_subject()
              let sessions = start_sessions_actor(config.vswitch)

              let upstream_ack = new_subject()
              let _ =
                spawn_unlinked(fn() {
                  let upstream_control = new_subject()
                  send(upstream_ack, upstream_control)
                  upstream_loop(
                    config.vswitch,
                    socket,
                    sessions,
                    upstream_control,
                  )
                })

              let downstream_ack = new_subject()
              let _ =
                spawn_unlinked(fn() {
                  let downstream_control = new_subject()
                  send(downstream_ack, downstream_control)
                  downstream_loop(socket, sessions, downstream_control)
                })

              let assert Ok(upstream_control) = receive(upstream_ack, 1000)
              let assert Ok(downstream_control) = receive(downstream_ack, 1000)

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
    otp_actor.new_with_initialiser(1000, fn(subject) {
      Ok(
        otp_actor.initialised(SessionsState(
          switch:,
          self: subject,
          by_client_id: dict.new(),
          by_endpoint: dict.new(),
          pending_frames: [],
        ))
        |> otp_actor.returning(subject),
      )
    })
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

    GotFrame(endpoint, frame) ->
      otp_actor.continue(
        SessionsState(
          ..state,
          pending_frames: [#(endpoint, frame), ..state.pending_frames],
        ),
      )

    PollAll(reply_to) -> {
      send(reply_to, state.pending_frames)
      otp_actor.continue(SessionsState(..state, pending_frames: []))
    }
  }
}

fn do_bind_endpoint(
  state: SessionsState,
  client_id: String,
  endpoint: Endpoint,
) -> SessionsState {
  let by_endpoint = case dict.get(state.by_client_id, client_id) {
    Ok(ClientSession(endpoint: old_endpoint)) ->
      dict.delete(state.by_endpoint, old_endpoint)
    Error(Nil) -> state.by_endpoint
  }

  // 每次 bind 都创建新 receiver + 新 forwarder，
  // 旧 forwarder 因为 vswitch 不再发给旧 receiver 而自然停止收帧。
  let receiver = server.new_receiver()
  server.connect(state.switch, client_id, receiver)

  let sessions_self = state.self
  let _ =
    spawn_unlinked(fn() { forwarder_loop(endpoint, receiver, sessions_self) })

  SessionsState(
    ..state,
    by_client_id: dict.insert(
      state.by_client_id,
      client_id,
      ClientSession(endpoint:),
    ),
    by_endpoint: dict.insert(by_endpoint, endpoint, client_id),
  )
}

// forwarder 进程：持有 receiver，收到帧就发 GotFrame 给 sessions actor
fn forwarder_loop(
  endpoint: Endpoint,
  receiver: server.ForwardedReceiver,
  sessions: Subject(SessionsMessage),
) -> Nil {
  case server.receive_forwarded(receiver, 60_000) {
    server.Forwarded(_, frame) -> {
      send(sessions, GotFrame(endpoint, frame))
      forwarder_loop(endpoint, receiver, sessions)
    }
    server.Timeout -> forwarder_loop(endpoint, receiver, sessions)
  }
}

// --- Upstream 进程 ---

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

// --- Downstream 进程 ---

fn downstream_loop(
  socket: udp.Udp,
  sessions: Subject(SessionsMessage),
  control: Subject(Control),
) -> Nil {
  case receive(control, 0) {
    Ok(Stop) -> Nil
    Error(Nil) -> {
      let reply_to = new_subject()
      send(sessions, PollAll(reply_to))
      case receive(reply_to, 100) {
        Ok(frames) ->
          list.each(frames, fn(entry) {
            let #(Endpoint(ip_address:, port:), frame) = entry
            let _ =
              send_server_message(
                socket,
                ip_address,
                port,
                udp_protocol.ServerFrame(frame),
              )
            Nil
          })
        Error(Nil) -> Nil
      }
      downstream_loop(socket, sessions, control)
    }
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
