import device/helper_launcher
import device/port_bridge
import gleam/erlang/process.{type Subject, new_subject, receive, send}
import gleam/otp/actor as otp_actor

/// 本地设备 actor 句柄。
///
/// 当前底层资源可能是 Python mock helper，也可能是真实 TAP helper。
pub opaque type Device {
  Device(subject: Subject(Message))
}

pub type ReadResult {
  Read(frame: BitArray)
  Closed
  TimedOut
  Ignored
}

type Message {
  ReadFrame(timeout_ms: Int, reply_to: Subject(ReadResult))
  WriteFrame(frame: BitArray)
  Stop
}

/// 从设备读取一帧原始以太网数据。
pub fn read_frame(device: Device, timeout_ms: Int) -> ReadResult {
  let reply_to = new_subject()
  send(device.subject, ReadFrame(timeout_ms, reply_to))

  case receive(reply_to, timeout_ms + 50) {
    Ok(result) -> result
    Error(Nil) -> TimedOut
  }
}

/// 向设备写入一帧原始以太网数据。
pub fn write_frame(device: Device, frame: BitArray) -> Nil {
  send(device.subject, WriteFrame(frame))
}

/// 停止设备 actor，并关闭底层 helper/port。
pub fn stop(device: Device) -> Nil {
  send(device.subject, Stop)
}

/// 启动一个基于 Python mock helper 的设备 actor。
pub fn start_mock() -> Result(Device, String) {
  start(fn() { helper_launcher.start_mock() })
}

/// 启动一个绑定到指定 TAP 名称的设备 actor。
pub fn start_tap(name: String) -> Result(Device, String) {
  start(fn() { helper_launcher.start_tap(name) })
}

fn start(
  open_port: fn() -> Result(port_bridge.Port, String),
) -> Result(Device, String) {
  let builder =
    otp_actor.new_with_initialiser(1000, fn(subject) {
      case open_port() {
        Ok(port) ->
          Ok(otp_actor.initialised(port) |> otp_actor.returning(subject))
        Error(reason) -> Error(reason)
      }
    })
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(Device(started.data))
    Error(_) -> Error("failed to start device actor")
  }
}

fn handle_message(
  port: port_bridge.Port,
  message: Message,
) -> otp_actor.Next(port_bridge.Port, Message) {
  case message {
    WriteFrame(frame) -> {
      port_bridge.send_frame(port, frame)
      otp_actor.continue(port)
    }

    ReadFrame(timeout_ms, reply_to) -> {
      let result = case port_bridge.receive_message(port, timeout_ms) {
        port_bridge.Frame(frame) -> Read(frame)
        port_bridge.ExitStatus(_) -> Closed
        port_bridge.Timeout -> TimedOut
        port_bridge.Unknown -> Ignored
      }
      send(reply_to, result)

      case result {
        Closed -> otp_actor.stop()
        _ -> otp_actor.continue(port)
      }
    }

    Stop -> {
      helper_launcher.stop(port)
      otp_actor.stop()
    }
  }
}
