/// 外部 helper 进程对应的 Erlang port 句柄。
pub type Port

/// 从 port 侧收到的消息。
pub type PortMessage {
  Frame(frame: BitArray)
  ExitStatus(code: Int)
  Timeout
  Unknown
}

/// 启动外部命令，并把它包装成 port。
@external(erlang, "port_bridge_ffi", "start")
pub fn start(command: String, args: List(String)) -> Result(Port, String)

/// 通过 port 向 helper 发送一帧原始数据。
@external(erlang, "port_bridge_ffi", "send_frame")
pub fn send_frame(port: Port, frame: BitArray) -> Nil

/// 从 port 读取一条消息。
@external(erlang, "port_bridge_ffi", "receive_message")
pub fn receive_message(port: Port, timeout_ms: Int) -> PortMessage

/// 停止 port 对应的外部进程。
@external(erlang, "port_bridge_ffi", "stop")
pub fn stop(port: Port) -> Nil
