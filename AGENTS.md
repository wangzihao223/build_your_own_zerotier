# AGENTS.md

AI 协作指南。本仓库是一个 ZeroTier 风格 overlay 网络的最小原型,用 Gleam + Erlang/OTP 编写,外挂一个 Python 辅助进程处理 TAP 设备。

## 参考实现

本项目按照 [peiyuanix/build-your-own-zerotier](https://github.com/peiyuanix/build-your-own-zerotier) 的原理进行 Gleam 重写。参考项目是一个教学性质的二层虚拟交换机,核心组件有两个:

- **VSwitch(服务端)**:维护 MAC 地址表,根据目的 MAC 在已连接客户端之间转发以太网帧
- **VPort(客户端)**:在本机 TAP 设备和到 VSwitch 的 UDP 套接字之间双向中继帧

核心原理是 **二层交换 + UDP 隧道**:不做 IP 路由,只按 MAC 转发;跨地域的机器通过 UDP 打通,看起来像在同一个局域网里。

### 本仓库的对应关系

| 参考项目(C) | 本仓库(Gleam/Erlang/Python) |
| --- | --- |
| VSwitch 的 MAC 地址表 | [src/switch.gleam](src/switch.gleam) |
| VPort 的 TAP 设备读写 | [native/tap_helper.py](native/tap_helper.py) |
| VPort ↔ VSwitch 的 UDP 传输 | 待实现(当前用 Erlang port 做本地回环) |
| 客户端进程模型 | [src/tun_actor.gleam](src/tun_actor.gleam) + port 桥 |

### 实现路线

按参考项目的阶段推进,每一步都保持可运行:

1. ✅ 用 Erlang port + Python helper 打通 TAP 读写(`mock` 模式已可回环)
2. ⏳ 把 `switch` 做成长驻 actor,接收 port 消息并根据 MAC 表转发
3. ⏳ 加入 UDP 传输层,让多个 VPort 能通过 VSwitch 互通
4. ⏳ 在真实 `tap` 模式下跑通两台 Linux 机器之间的 `ping`

新增功能时优先对照参考项目的对应模块,保持概念一一对应,不要引入参考项目里没有的抽象。

## 项目速览

三层结构,从上到下:

1. **Gleam 层** ([src/](src/)) — 业务逻辑与 actor 编排
   - [build_your_own_zerorier.gleam](src/build_your_own_zerorier.gleam) — `main` 入口,冒烟测试用
   - [tun_actor.gleam](src/tun_actor.gleam) — 启动/停止 helper 进程的 Gleam 包装
   - [port_bridge.gleam](src/port_bridge.gleam) — Erlang port 的类型化 FFI 边界
   - [switch.gleam](src/switch.gleam) — MAC 学习表(以太网交换核心)
2. **Erlang 桥接** — [src/port_bridge_ffi.erl](src/port_bridge_ffi.erl) 用 `open_port/2` 拉起外部命令,使用 `{packet, 4}` 帧格式
3. **Python helper** — [native/tap_helper.py](native/tap_helper.py) 支持 `mock`(安全本地测试)和 `tap`(真实 `/dev/net/tun`,仅 Linux + root)两种模式

## 常用命令

```sh
gleam run              # 运行 main,会拉起 Python mock helper 做一次回环
gleam test             # 跑 gleeunit 测试套件
gleam build            # 仅编译
gleam format src test  # 格式化
python3 native/tap_helper.py --mode mock  # 单独跑 helper(调试 framing 用)
```

## 约定与风格

- **帧格式**:Erlang port 和 Python helper 之间严格遵循 `{packet, 4}` — 每个以太网帧前置 4 字节大端长度。修改任一端时必须同步。见 [native/tap_helper.py:16-19](native/tap_helper.py#L16-L19) 和 [src/port_bridge_ffi.erl:15](src/port_bridge_ffi.erl#L15)。
- **FFI 边界**:Gleam 侧通过 `@external(erlang, ...)` 声明,对应的 Erlang 实现放在 [src/port_bridge_ffi.erl](src/port_bridge_ffi.erl)。新增原生调用时两边类型要对齐(`BitArray` ↔ `binary`,`Result(X, String)` ↔ `{ok, X} | {error, Binary}`)。
- **Gleam 代码风格**:跟随 `gleam format` 默认设置,不手动排版。公开函数加 `pub`,类型构造器用 `PascalCase`,值/函数用 `snake_case`。
- **注释**:只解释"为什么",不重复"是什么"。[native/tap_helper.py](native/tap_helper.py) 里的中文注释是现有约定,保持即可。

## 平台注意事项

- `tap` 模式需要 Linux 且有 `CAP_NET_ADMIN`(通常 `sudo`)。macOS/Windows 上只能跑 `mock` 模式。
- helper 退出时 BEAM 侧可能竞争关闭 stdout,helper 在 [native/tap_helper.py:22-27](native/tap_helper.py#L22-L27) 做了 `discard_stdout` 规避,改动时别破坏这个兜底。

## 测试

- 测试文件放在 [test/](test/),以 `_test.gleam` 结尾,测试函数名以 `_test` 结尾(gleeunit 约定)。
- 当前只有占位测试。新增真实测试时优先覆盖 `switch` 的 MAC 学习逻辑——它没有外部依赖,适合纯单测。
- 涉及 port/helper 的集成测试请走 `mock` 模式,避免在 CI 上需要 TAP 权限。

## 变更前的自检清单

- [ ] `gleam format src test` 通过
- [ ] `gleam build` 通过
- [ ] `gleam test` 通过
- [ ] 如果改了 framing 或 FFI 签名,三个语言层(Gleam / Erlang / Python)都同步更新
