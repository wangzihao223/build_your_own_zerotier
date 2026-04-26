import gleam/dict
import gleam/erlang/process.{
  type Subject, new_subject, receive, send, spawn_unlinked,
}
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

type Sessions {
  Sessions(
    by_client_id: dict.Dict(String, ClientSession),
    by_endpoint: dict.Dict(Endpoint, String),
  )
}

/// 启动一个 UDP server。
///
/// 它负责：
/// - 接收客户端 `Hello`
/// - 维护 `client_id <-> endpoint` 双向会话索引
/// - 把客户端上行帧送入 `vswitch`
/// - 把 `vswitch` 下行帧发回客户端
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

/// 停止 UDP server 进程。
pub fn stop(server: UdpServer) -> Nil {
  send(server.control, Stop)
}

fn server_process(config: UdpServerConfig, ack: Subject(StartAck)) -> Nil {
  case net.port(config.bind_port) {
    Ok(bind_port) ->
      case udp.open(udp.new(bind_port)) {
        Ok(socket) ->
          case udp.port(socket) {
            Ok(actual_port) -> {
              let control = new_subject()
              send(ack, Started(net.port_to_int(actual_port), control))
              server_loop(
                config.vswitch,
                socket,
                control,
                Sessions(by_client_id: dict.new(), by_endpoint: dict.new()),
              )
            }

            Error(Nil) -> send(ack, Failed(ReadBoundPortFailed))
          }

        Error(_error) -> send(ack, Failed(OpenFailed))
      }

    Error(_) -> send(ack, Failed(InvalidBindPort))
  }
}

fn server_loop(
  switch: server.Server,
  socket: udp.Udp,
  control: Subject(Control),
  sessions: Sessions,
) -> Nil {
  case receive(control, 0) {
    Ok(Stop) -> udp.close(socket)
    Error(Nil) -> continue_server_loop(switch, socket, control, sessions)
  }
}

fn continue_server_loop(
  switch: server.Server,
  socket: udp.Udp,
  control: Subject(Control),
  sessions: Sessions,
) -> Nil {
  let timeout = case net.timeout(10) {
    Ok(timeout) -> timeout
    Error(_) -> net.infinity
  }

  let sessions = case udp.receive(socket, 0, timeout) {
    Ok(udp.ReceiveData(ip_address:, port:, payload:)) ->
      handle_udp_packet(switch, socket, sessions, ip_address, port, payload)
    Error(_) -> sessions
  }

  let _ = flush_forwarded_frames(socket, sessions)

  server_loop(switch, socket, control, sessions)
}

fn handle_udp_packet(
  switch: server.Server,
  socket: udp.Udp,
  sessions: Sessions,
  ip_address: net.IpAddress,
  port: net.Port,
  payload: BitArray,
) -> Sessions {
  let endpoint = Endpoint(ip_address:, port:)

  case udp_protocol.decode_client_message(payload) {
    Ok(udp_protocol.Hello(client_id)) -> {
      let sessions = bind_client_endpoint(switch, sessions, client_id, endpoint)
      let _ =
        send_server_message(socket, ip_address, port, udp_protocol.Welcome)
      sessions
    }

    Ok(udp_protocol.ClientFrame(frame)) -> {
      case lookup_client_by_endpoint(sessions, endpoint) {
        Ok(client_id) -> server.receive_from(switch, client_id, frame)
        Error(Nil) -> Nil
      }
      sessions
    }

    Error(_) -> sessions
  }
}

fn bind_client_endpoint(
  switch: server.Server,
  sessions: Sessions,
  client_id: String,
  endpoint: Endpoint,
) -> Sessions {
  let update = fn(
    receiver: server.ForwardedReceiver,
    previous: Result(ClientSession, Nil),
  ) {
    let by_endpoint = case previous {
      Ok(ClientSession(endpoint: old_endpoint, ..)) ->
        dict.delete(sessions.by_endpoint, old_endpoint)
      Error(Nil) -> sessions.by_endpoint
    }

    let session = ClientSession(endpoint:, receiver:)
    Sessions(
      by_client_id: dict.insert(sessions.by_client_id, client_id, session),
      by_endpoint: dict.insert(by_endpoint, endpoint, client_id),
    )
  }

  ensure_client_session(switch, sessions, client_id, update)
}

fn ensure_client_session(
  switch: server.Server,
  sessions: Sessions,
  client_id: String,
  update: fn(server.ForwardedReceiver, Result(ClientSession, Nil)) -> Sessions,
) -> Sessions {
  case dict.get(sessions.by_client_id, client_id) {
    Ok(ClientSession(receiver:, ..) as session) -> update(receiver, Ok(session))
    Error(Nil) -> {
      let receiver = server.new_receiver()
      server.connect(switch, client_id, receiver)
      update(receiver, Error(Nil))
    }
  }
}

fn lookup_client_by_endpoint(
  sessions: Sessions,
  endpoint: Endpoint,
) -> Result(String, Nil) {
  dict.get(sessions.by_endpoint, endpoint)
}

fn flush_forwarded_frames(socket: udp.Udp, sessions: Sessions) -> Nil {
  sessions.by_client_id
  |> dict.each(fn(_client_id, session) {
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
        Nil
      }

      server.Timeout -> Nil
    }
  })
}

fn send_server_message(
  socket: udp.Udp,
  ip_address: net.IpAddress,
  port: net.Port,
  message: udp_protocol.ServerMessage,
) -> Result(Nil, Nil) {
  let assert Ok(payload) = udp_protocol.encode_server_message(message)

  case udp.connect(socket, net.ip_address(ip_address), port) {
    Ok(Nil) ->
      case udp.send(socket, payload) {
        Ok(Nil) -> Ok(Nil)
        Error(_) -> Error(Nil)
      }

    Error(_) -> Error(Nil)
  }
}
