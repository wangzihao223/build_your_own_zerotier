import device/helper_launcher
import device/port_bridge
import gleam/erlang/process.{
  type Subject, new_selector, new_subject, receive, select, select_other, send,
}
import gleam/list
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
  PortEvent(message: port_bridge.PortMessage)
  IgnoredPortMessage
  Stop
}

type State {
  State(port: port_bridge.Port, pending_frames: List(BitArray), closed: Bool)
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
  start_mock_dev()
}

/// 启动一个绑定到指定 TAP 名称的设备 actor。
pub fn start_tap(name: String) -> Result(Device, String) {
  start_tap_dev(name)
}

/// 启动一个基于 Python mock helper 的设备 actor，并尝试解析开发期 helper 路径。
pub fn start_mock_dev() -> Result(Device, String) {
  start(fn() { helper_launcher.start_mock_dev() })
}

/// 启动一个绑定到指定 TAP 名称的设备 actor，并尝试解析开发期 helper 路径。
pub fn start_tap_dev(name: String) -> Result(Device, String) {
  start(fn() { helper_launcher.start_tap_dev(name) })
}

/// 启动一个基于 Python mock helper 的设备 actor，并显式指定 helper 脚本路径。
pub fn start_mock_with_helper(helper_path: String) -> Result(Device, String) {
  start(fn() { helper_launcher.start_mock_with_helper(helper_path) })
}

/// 启动一个绑定到指定 TAP 名称的设备 actor，并显式指定 helper 脚本路径。
pub fn start_tap_with_helper(
  name: String,
  helper_path: String,
) -> Result(Device, String) {
  start(fn() { helper_launcher.start_tap_with_helper(name, helper_path) })
}

fn start(
  open_port: fn() -> Result(port_bridge.Port, String),
) -> Result(Device, String) {
  let builder =
    otp_actor.new_with_initialiser(1000, fn(subject) {
      case open_port() {
        Ok(port) -> {
          let selector =
            new_selector()
            |> select(subject)
            |> select_other(fn(message) {
              case port_bridge.decode_message(port, message) {
                Ok(port_message) -> PortEvent(port_message)
                Error(Nil) -> IgnoredPortMessage
              }
            })

          Ok(
            otp_actor.initialised(State(
              port:,
              pending_frames: [],
              closed: False,
            ))
            |> otp_actor.selecting(selector)
            |> otp_actor.returning(subject),
          )
        }

        Error(reason) -> Error(reason)
      }
    })
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(Device(started.data))
    Error(otp_actor.InitFailed(reason)) -> Error(reason)
    Error(_) -> Error("failed to start device actor")
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> otp_actor.Next(State, Message) {
  case message {
    WriteFrame(frame) -> {
      port_bridge.send_frame(state.port, frame)
      otp_actor.continue(state)
    }

    ReadFrame(timeout_ms, reply_to) -> {
      let #(state, result) = read_once(state, timeout_ms)
      send(reply_to, result)

      case result {
        Closed -> otp_actor.stop()
        _ -> otp_actor.continue(state)
      }
    }

    PortEvent(port_bridge.Frame(frame)) ->
      otp_actor.continue(
        State(
          ..state,
          pending_frames: list.append(state.pending_frames, [frame]),
        ),
      )

    PortEvent(port_bridge.ExitStatus(_code)) ->
      otp_actor.continue(State(..state, closed: True))

    PortEvent(port_bridge.Timeout) -> otp_actor.continue(state)

    PortEvent(port_bridge.Unknown) -> otp_actor.continue(state)

    IgnoredPortMessage -> otp_actor.continue(state)

    Stop -> {
      helper_launcher.stop(state.port)
      otp_actor.stop()
    }
  }
}

fn read_once(state: State, timeout_ms: Int) -> #(State, ReadResult) {
  case state.pending_frames {
    [frame, ..rest] -> #(State(..state, pending_frames: rest), Read(frame))
    [] ->
      case state.closed {
        True -> #(state, Closed)
        False -> read_from_port(state, timeout_ms)
      }
  }
}

fn read_from_port(state: State, timeout_ms: Int) -> #(State, ReadResult) {
  case port_bridge.receive_message(state.port, timeout_ms) {
    port_bridge.Frame(frame) -> #(state, Read(frame))
    port_bridge.ExitStatus(_code) -> #(State(..state, closed: True), Closed)
    port_bridge.Timeout -> #(state, TimedOut)
    port_bridge.Unknown -> #(state, Ignored)
  }
}
