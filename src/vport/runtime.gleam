import device/device
import gleam/erlang/process.{type Subject}
import gleam/otp/actor as otp_actor
import transport/client as transport
import transport/direct_vswitch as vswitch_transport
import transport/udp_client as udp_transport
import vswitch/server

/// VPort actor 对外可接收的消息类型。
pub type Message(reply) {
  SendToDevice(frame: BitArray)
  PumpDeviceToSwitchOnce(timeout_ms: Int, reply_to: Subject(reply))
  PumpSwitchToDeviceOnce(timeout_ms: Int, reply_to: Subject(reply))
  Stop
}

/// VPort actor 内部持有的运行时状态。
pub type State {
  State(device: device.Device, transport: transport.ClientTransport)
}

/// 用既有状态启动 VPort actor，并返回它的消息句柄。
pub fn start(
  state: State,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Subject(Message(a)) {
  let builder = otp_actor.new(state) |> otp_actor.on_message(handle_message)
  let assert Ok(started) = otp_actor.start(builder)
  started.data
}

/// 启动一个 mock device + 本机直连 transport 的 VPort runtime。
pub fn start_mock_direct(
  switch: server.Server,
  id: server.ClientId,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_mock_direct_dev(switch, id, handle_message)
}

/// 启动一个 mock device + 本机直连 transport 的 VPort runtime，并尝试解析开发期 helper 路径。
pub fn start_mock_direct_dev(
  switch: server.Server,
  id: server.ClientId,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case device.start_mock_dev(), vswitch_transport.connect(switch, id) {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(reason)
      }
    },
    handle_message,
  )
}

/// 启动一个 TAP device + 本机直连 transport 的 VPort runtime。
pub fn start_tap_direct(
  switch: server.Server,
  id: server.ClientId,
  tap_name: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_tap_direct_dev(switch, id, tap_name, handle_message)
}

/// 启动一个 TAP device + 本机直连 transport 的 VPort runtime，并尝试解析开发期 helper 路径。
pub fn start_tap_direct_dev(
  switch: server.Server,
  id: server.ClientId,
  tap_name: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case
        device.start_tap_dev(tap_name),
        vswitch_transport.connect(switch, id)
      {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(reason)
      }
    },
    handle_message,
  )
}

/// 启动一个 mock device + 本机直连 transport 的 VPort runtime，并显式指定 helper 路径。
pub fn start_mock_direct_with_helper(
  switch: server.Server,
  id: server.ClientId,
  helper_path: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case
        device.start_mock_with_helper(helper_path),
        vswitch_transport.connect(switch, id)
      {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(reason)
      }
    },
    handle_message,
  )
}

/// 启动一个 TAP device + 本机直连 transport 的 VPort runtime，并显式指定 helper 路径。
pub fn start_tap_direct_with_helper(
  switch: server.Server,
  id: server.ClientId,
  tap_name: String,
  helper_path: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case
        device.start_tap_with_helper(tap_name, helper_path),
        vswitch_transport.connect(switch, id)
      {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(reason)
      }
    },
    handle_message,
  )
}

/// 启动一个 mock device + 远端 UDP transport 的 VPort runtime。
pub fn start_mock_udp(
  config: udp_transport.UdpClientConfig,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_mock_udp_dev(config, handle_message)
}

/// 启动一个 mock device + 远端 UDP transport 的 VPort runtime，并尝试解析开发期 helper 路径。
pub fn start_mock_udp_dev(
  config: udp_transport.UdpClientConfig,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case device.start_mock_dev(), udp_transport.connect(config) {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(udp_error_to_string(reason))
      }
    },
    handle_message,
  )
}

/// 启动一个 TAP device + 远端 UDP transport 的 VPort runtime。
pub fn start_tap_udp(
  config: udp_transport.UdpClientConfig,
  tap_name: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_tap_udp_dev(config, tap_name, handle_message)
}

/// 启动一个 TAP device + 远端 UDP transport 的 VPort runtime，并尝试解析开发期 helper 路径。
pub fn start_tap_udp_dev(
  config: udp_transport.UdpClientConfig,
  tap_name: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case device.start_tap_dev(tap_name), udp_transport.connect(config) {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(udp_error_to_string(reason))
      }
    },
    handle_message,
  )
}

/// 启动一个 mock device + 远端 UDP transport 的 VPort runtime，并显式指定 helper 路径。
pub fn start_mock_udp_with_helper(
  config: udp_transport.UdpClientConfig,
  helper_path: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case
        device.start_mock_with_helper(helper_path),
        udp_transport.connect(config)
      {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(udp_error_to_string(reason))
      }
    },
    handle_message,
  )
}

/// 启动一个 TAP device + 远端 UDP transport 的 VPort runtime，并显式指定 helper 路径。
pub fn start_tap_udp_with_helper(
  config: udp_transport.UdpClientConfig,
  tap_name: String,
  helper_path: String,
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  start_with(
    fn() {
      case
        device.start_tap_with_helper(tap_name, helper_path),
        udp_transport.connect(config)
      {
        Ok(device_adapter), Ok(transport_adapter) ->
          Ok(State(device: device_adapter, transport: transport_adapter))

        Error(reason), _ -> Error(reason)
        _, Error(reason) -> Error(udp_error_to_string(reason))
      }
    },
    handle_message,
  )
}

/// 停止 runtime 中持有的 device 和 transport。
pub fn stop(state: State) -> Nil {
  transport.stop(state.transport)
  device.stop(state.device)
}

/// 返回一次“device -> transport”泵送函数。
pub fn pump_device_once(state: State) -> fn(Int) -> PumpResult {
  fn(timeout_ms) {
    case device.read_frame(state.device, timeout_ms) {
      device.Read(frame) -> {
        transport.send_to_server(state.transport, frame)
        Pumped(frame)
      }

      device.Closed -> Closed
      device.TimedOut -> TimedOut
      device.Ignored -> Ignored
    }
  }
}

/// 返回一次“transport -> device”泵送函数。
pub fn pump_switch_once(state: State) -> fn(Int) -> PumpResult {
  fn(timeout_ms) {
    case transport.receive_from_server(state.transport, timeout_ms) {
      transport.Received(frame) -> {
        device.write_frame(state.device, frame)
        Pumped(frame)
      }

      transport.TimedOut -> TimedOut
    }
  }
}

/// 直接向 runtime 持有的 device 写一帧。
pub fn write_to_device(state: State, frame: BitArray) -> Nil {
  device.write_frame(state.device, frame)
}

pub type PumpResult {
  Pumped(frame: BitArray)
  Closed
  TimedOut
  Ignored
}

fn start_with(
  open_state: fn() -> Result(State, String),
  handle_message: fn(State, Message(a)) -> otp_actor.Next(State, Message(a)),
) -> Result(Subject(Message(a)), String) {
  let builder =
    otp_actor.new_with_initialiser(10_000, fn(subject) {
      case open_state() {
        Ok(state) ->
          Ok(otp_actor.initialised(state) |> otp_actor.returning(subject))
        Error(reason) -> Error(reason)
      }
    })
    |> otp_actor.on_message(handle_message)

  case otp_actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(otp_actor.InitFailed(reason)) -> Error(reason)
    Error(otp_actor.InitTimeout) -> Error("init_timeout")
    Error(_) -> Error("failed to start vport actor")
  }
}

fn udp_error_to_string(error: udp_transport.ClientError) -> String {
  case error {
    udp_transport.InvalidLocalPort -> "invalid_local_port"
    udp_transport.InvalidServerPort -> "invalid_server_port"
    udp_transport.OpenFailed -> "open_failed"
    udp_transport.ConnectFailed -> "connect_failed"
    udp_transport.SendFailed -> "send_failed"
    udp_transport.HandshakeTimeout -> "handshake_timeout"
    udp_transport.ReceiveFailed -> "receive_failed"
    udp_transport.InvalidHandshakeTimeout -> "invalid_handshake_timeout"
    udp_transport.HandshakeDecodeFailed -> "handshake_decode_failed"
    udp_transport.UnexpectedHandshakeMessage -> "unexpected_handshake_message"
  }
}
