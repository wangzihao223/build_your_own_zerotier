import gleam/erlang/process.{type Subject, new_subject, receive, send}
import gleam/otp/actor as otp_actor
import transport/udp_client
import vport/runtime
import vswitch/server

/// VPort 对外暴露的 actor 句柄。
pub opaque type Client {
  Client(subject: Subject(runtime.Message(PumpResult)))
}

pub type PumpResult {
  Pumped(frame: BitArray)
  Closed
  TimedOut
  Ignored
}

/// 用一个已经准备好的 `runtime.State` 启动 VPort actor。
pub fn start(
  device device_adapter: runtime.State,
  transport _transport_adapter: Nil,
) -> Client {
  Client(runtime.start(device_adapter, handle_message))
}

/// 启动一个使用 mock device 且直连本机 `vswitch` 的 VPort。
pub fn start_mock_direct(
  switch: server.Server,
  id: server.ClientId,
) -> Result(Client, String) {
  case runtime.start_mock_direct(switch, id, handle_message) {
    Ok(subject) -> Ok(Client(subject))
    Error(reason) -> Error(reason)
  }
}

/// 启动一个使用真实 TAP 设备且直连本机 `vswitch` 的 VPort。
pub fn start_tap_direct(
  switch: server.Server,
  id: server.ClientId,
  tap_name: String,
) -> Result(Client, String) {
  case runtime.start_tap_direct(switch, id, tap_name, handle_message) {
    Ok(subject) -> Ok(Client(subject))
    Error(reason) -> Error(reason)
  }
}

/// 启动一个使用 mock device 且通过 UDP 连接远端 `vswitch` 的 VPort。
pub fn start_mock_udp(
  config: udp_client.UdpClientConfig,
) -> Result(Client, String) {
  case runtime.start_mock_udp(config, handle_message) {
    Ok(subject) -> Ok(Client(subject))
    Error(reason) -> Error(reason)
  }
}

/// 启动一个使用真实 TAP 设备且通过 UDP 连接远端 `vswitch` 的 VPort。
pub fn start_tap_udp(
  config: udp_client.UdpClientConfig,
  tap_name: String,
) -> Result(Client, String) {
  case runtime.start_tap_udp(config, tap_name, handle_message) {
    Ok(subject) -> Ok(Client(subject))
    Error(reason) -> Error(reason)
  }
}

/// 停止 VPort actor，并级联关闭底层 device/transport。
pub fn stop(client: Client) -> Nil {
  send(client.subject, runtime.Stop)
}

/// 主动向本地 device 侧写入一帧。
pub fn send_to_device(client: Client, frame: BitArray) -> Nil {
  send(client.subject, runtime.SendToDevice(frame))
}

/// 执行一次“device -> transport”的泵送。
pub fn pump_device_to_switch_once(client: Client, timeout_ms: Int) -> PumpResult {
  let reply_to = new_subject()
  send(client.subject, runtime.PumpDeviceToSwitchOnce(timeout_ms, reply_to))

  case receive(reply_to, timeout_ms + 50) {
    Ok(result) -> result
    Error(Nil) -> TimedOut
  }
}

/// 执行一次“transport -> device”的泵送。
pub fn pump_switch_to_device_once(client: Client, timeout_ms: Int) -> PumpResult {
  let reply_to = new_subject()
  send(client.subject, runtime.PumpSwitchToDeviceOnce(timeout_ms, reply_to))

  case receive(reply_to, timeout_ms + 50) {
    Ok(result) -> result
    Error(Nil) -> TimedOut
  }
}

fn handle_message(
  state: runtime.State,
  message: runtime.Message(PumpResult),
) -> otp_actor.Next(runtime.State, runtime.Message(PumpResult)) {
  case message {
    runtime.SendToDevice(frame) -> {
      runtime.write_to_device(state, frame)
      otp_actor.continue(state)
    }

    runtime.PumpDeviceToSwitchOnce(timeout_ms, reply_to) -> {
      send(
        reply_to,
        from_runtime_result(runtime.pump_device_once(state)(timeout_ms)),
      )
      otp_actor.continue(state)
    }

    runtime.PumpSwitchToDeviceOnce(timeout_ms, reply_to) -> {
      send(
        reply_to,
        from_runtime_result(runtime.pump_switch_once(state)(timeout_ms)),
      )
      otp_actor.continue(state)
    }

    runtime.Stop -> {
      runtime.stop(state)
      otp_actor.stop()
    }
  }
}

fn from_runtime_result(result: runtime.PumpResult) -> PumpResult {
  case result {
    runtime.Pumped(frame) -> Pumped(frame)
    runtime.Closed -> Closed
    runtime.TimedOut -> TimedOut
    runtime.Ignored -> Ignored
  }
}
