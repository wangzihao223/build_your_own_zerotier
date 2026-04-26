import gleam/bit_array

pub type ClientId =
  String

/// 客户端发给服务端的协议消息。
pub type ClientMessage {
  /// 客户端启动后先发握手，声明自己希望使用的 client_id。
  Hello(client_id: ClientId)
  /// 握手完成后，客户端用这个消息承载原始以太网帧。
  ClientFrame(frame: BitArray)
}

/// 服务端发给客户端的协议消息。
pub type ServerMessage {
  /// 服务端确认握手成功，客户端收到后才能进入正常收发。
  Welcome
  /// 服务端转发给客户端的原始以太网帧。
  ServerFrame(frame: BitArray)
}

/// UDP payload 首字节使用的消息标签。
pub type MessageTag {
  HelloTag
  WelcomeTag
  ClientFrameTag
  ServerFrameTag
}

/// 当前使用的最小 UDP 二进制协议。
///
/// 所有 UDP payload 先放一个 1 字节消息类型：
///
/// - `0x01` = `Hello`
/// - `0x02` = `Welcome`
/// - `0x03` = `ClientFrame`
/// - `0x04` = `ServerFrame`
pub const hello_tag = 0x01

pub const welcome_tag = 0x02

pub const client_frame_tag = 0x03

pub const server_frame_tag = 0x04

pub type DecodeError {
  EmptyPacket
  UnknownTag
  TruncatedPacket
  InvalidUtf8
}

/// 把客户端消息编码成 UDP payload。
pub fn encode_client_message(message: ClientMessage) -> Result(BitArray, String) {
  case message {
    Hello(client_id) -> {
      let client_id_bytes = bit_array.from_string(client_id)
      let client_id_length = bit_array.byte_size(client_id_bytes)

      Ok(<<
        hello_tag,
        client_id_length:size(16),
        client_id:utf8,
      >>)
    }

    ClientFrame(frame) -> Ok(<<client_frame_tag, frame:bits>>)
  }
}

/// 把服务端消息编码成 UDP payload。
pub fn encode_server_message(message: ServerMessage) -> Result(BitArray, String) {
  case message {
    Welcome -> Ok(<<welcome_tag>>)
    ServerFrame(frame) -> Ok(<<server_frame_tag, frame:bits>>)
  }
}

/// 把 UDP payload 解码成客户端消息。
pub fn decode_client_message(
  packet: BitArray,
) -> Result(ClientMessage, DecodeError) {
  case packet {
    <<>> -> Error(EmptyPacket)
    <<tag, rest:bytes>> ->
      case tag {
        0x01 -> decode_hello(rest)
        0x03 -> Ok(ClientFrame(rest))
        0x02 -> Error(UnknownTag)
        0x04 -> Error(UnknownTag)
        _ -> Error(UnknownTag)
      }
    _ -> Error(TruncatedPacket)
  }
}

/// 把 UDP payload 解码成服务端消息。
pub fn decode_server_message(
  packet: BitArray,
) -> Result(ServerMessage, DecodeError) {
  case packet {
    <<>> -> Error(EmptyPacket)
    <<tag, _rest:bytes>> ->
      case tag {
        0x02 -> Ok(Welcome)
        0x01 -> Error(UnknownTag)
        0x03 -> Error(UnknownTag)
        0x04 -> decode_server_frame(packet)
        _ -> Error(UnknownTag)
      }
    _ -> Error(TruncatedPacket)
  }
}

fn decode_hello(rest: BitArray) -> Result(ClientMessage, DecodeError) {
  case rest {
    <<client_id_length:size(16), client_id_bytes:bytes-size(client_id_length)>> ->
      case bit_array.to_string(client_id_bytes) {
        Ok(client_id) -> Ok(Hello(client_id))
        Error(Nil) -> Error(InvalidUtf8)
      }

    _ -> Error(TruncatedPacket)
  }
}

fn decode_server_frame(packet: BitArray) -> Result(ServerMessage, DecodeError) {
  case packet {
    <<0x04, frame:bytes>> -> Ok(ServerFrame(frame))
    _ -> Error(TruncatedPacket)
  }
}
