import device/port_bridge

/// helper 运行模式。
pub type DeviceMode {
  Mock
  Tap(name: String)
}

/// 启动 Python helper 所需的配置。
pub type Config {
  Config(python: String, helper_path: String, mode: DeviceMode)
}

/// 以 mock 模式启动 helper。
pub fn start_mock() -> Result(port_bridge.Port, String) {
  start(Config(
    python: "python3",
    helper_path: "native/tap_helper.py",
    mode: Mock,
  ))
}

/// 以真实 TAP 模式启动 helper。
pub fn start_tap(name: String) -> Result(port_bridge.Port, String) {
  start(Config(
    python: "python3",
    helper_path: "native/tap_helper.py",
    mode: Tap(name),
  ))
}

/// 按给定配置启动 helper 进程，并返回对应的 Erlang port。
pub fn start(config: Config) -> Result(port_bridge.Port, String) {
  port_bridge.start(config.python, helper_args(config))
}

/// 停止 helper 对应的 port。
pub fn stop(port: port_bridge.Port) -> Nil {
  port_bridge.stop(port)
}

fn helper_args(config: Config) -> List(String) {
  case config.mode {
    Mock -> [config.helper_path, "--mode", "mock"]
    Tap(name) -> [config.helper_path, "--mode", "tap", "--name", name]
  }
}
