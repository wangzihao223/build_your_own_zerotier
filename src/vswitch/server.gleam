import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/otp/actor as otp_actor
import protocol/ethernet
import vswitch/switch_table

pub type ClientId =
  String

/// VSwitch 服务端 actor 句柄。
pub opaque type Server {
  Server(subject: Subject(Message))
}

type Message {
  Connect(client_id: ClientId, receiver: Subject(ForwardedFrame))
  Disconnect(client_id: ClientId)
  ReceiveFrom(client_id: ClientId, frame: BitArray)
}

type State {
  State(
    table: switch_table.Table,
    clients: dict.Dict(ClientId, Subject(ForwardedFrame)),
  )
}

pub type ForwardedFrame {
  Forwarded(to_client: ClientId, frame: BitArray)
  Timeout
}

pub type ForwardedReceiver =
  Subject(ForwardedFrame)

/// 启动一个 VSwitch actor。
pub fn start() -> Result(Server, String) {
  let builder =
    otp_actor.new(State(table: switch_table.new(), clients: dict.new()))
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(Server(started.data))
    Error(_) -> Error("failed to start vswitch server")
  }
}

/// 为某个客户端创建下行帧接收通道。
pub fn new_receiver() -> Subject(ForwardedFrame) {
  process.new_subject()
}

/// 把一个客户端注册到 VSwitch。
pub fn connect(
  server: Server,
  client_id: ClientId,
  receiver: Subject(ForwardedFrame),
) -> Nil {
  process.send(server.subject, Connect(client_id, receiver))
}

/// 从 VSwitch 中移除一个客户端。
pub fn disconnect(server: Server, client_id: ClientId) -> Nil {
  process.send(server.subject, Disconnect(client_id))
}

/// 向 VSwitch 提交一帧来自某客户端的上行帧。
pub fn receive_from(server: Server, client_id: ClientId, frame: BitArray) -> Nil {
  process.send(server.subject, ReceiveFrom(client_id, frame))
}

/// 从客户端下行接收通道中读取一条转发结果。
pub fn receive_forwarded(
  receiver: Subject(ForwardedFrame),
  timeout_ms: Int,
) -> ForwardedFrame {
  case process.receive(receiver, timeout_ms) {
    Ok(forwarded) -> forwarded
    Error(Nil) -> Timeout
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> otp_actor.Next(State, Message) {
  case message {
    Connect(client_id, receiver) -> {
      let clients = dict.insert(state.clients, client_id, receiver)
      otp_actor.continue(State(..state, clients:))
    }

    Disconnect(client_id) -> {
      let clients = dict.delete(state.clients, client_id)
      otp_actor.continue(State(..state, clients:))
    }

    ReceiveFrom(client_id, frame) -> {
      case ethernet.parse_header(frame) {
        Ok(ethernet.Header(dst_mac:, src_mac:, ..)) -> {
          let #(table, action) =
            switch_table.handle_frame(state.table, src_mac, dst_mac, client_id)
          forward(
            action,
            from_client: client_id,
            frame: frame,
            clients: state.clients,
          )
          otp_actor.continue(State(..state, table:))
        }

        Error(ethernet.FrameTooShort) -> otp_actor.continue(state)
      }
    }
  }
}

fn forward(
  action: switch_table.ForwardAction,
  from_client from_client: ClientId,
  frame frame: BitArray,
  clients clients: dict.Dict(ClientId, Subject(ForwardedFrame)),
) -> Nil {
  case action {
    switch_table.Unicast(to_client) -> {
      case dict.get(clients, to_client) {
        Ok(receiver) -> process.send(receiver, Forwarded(to_client, frame))
        Error(Nil) -> Nil
      }
    }

    switch_table.Flood -> {
      clients
      |> dict.each(fn(client_id, receiver) {
        case client_id == from_client {
          True -> Nil
          False -> process.send(receiver, Forwarded(client_id, frame))
        }
      })
    }
  }
}
