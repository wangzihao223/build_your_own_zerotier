# build_your_own_zerotier

这是一个**库项目**，不是最终的 server/client 可执行程序。

它提供一组可以复用的组件，帮助你在 Gleam / Erlang 上搭一个 **ZeroTier 风格的二层 overlay 网络**：

- `vswitch`：虚拟二层交换机
- `udp_server`：服务端 UDP 接入层
- `vport`：客户端运行时
- `device`：本地 TAP / mock 设备封装
- `protocol`：以太网和 UDP framing 协议

如果你想做成真正可运行的程序，推荐：

- 当前仓库只当库
- 单独再建 `server app`
- 单独再建 `client app`

这样职责最清楚，库也更稳定。

## 一句话理解

这个库做的事情可以简单理解成：

- 客户端本地有一个虚拟网卡
- 客户端把网卡里的以太网帧通过 UDP 发到服务端
- 服务端像一个二层交换机一样，按 MAC 地址把帧转发给其他客户端
- 从客户端视角看，几台机器像是接在同一个二层局域网里

它不是 IP 路由器，也不是 VPN 隧道栈的完整版。

它更接近：

- 二层交换
- UDP 隧道
- actor 方式组织资源和消息流

## 这个库解决什么问题

如果你自己从零写这类系统，通常会碰到几块麻烦：

- TAP 设备怎么安全读写
- UDP socket 归谁持有
- 服务端怎么维护 MAC 学习表
- 客户端怎么在“本地设备”和“远端网络”之间泵送帧
- 跨进程时怎么避免把 `port` / `socket` 当普通值乱传

这个库把这些事情拆成几个清晰模块，让你在上层程序里只管：

- 启动服务端
- 启动客户端
- 配置地址和设备名
- 决定 supervision / CLI / 配置文件怎么做

## 适合怎么用

推荐把它作为底层库，然后在别的项目中组合：

### 服务端项目

服务端程序主要做两件事：

1. 启动 `vswitch`
2. 启动 `udp_server`

也就是：

```text
remote clients ~~ UDP ~~ udp_server -> vswitch
```

### 客户端项目

客户端程序主要做三件事：

1. 准备本地 device
2. 准备到服务端的 transport
3. 启动 `vport`，在两边之间转发帧

也就是：

```text
device <-> vport <-> transport
```

在 UDP 模式下是：

```text
device <-> vport <-> udp_client ~~ UDP ~~ udp_server -> vswitch
```

## 设计原则

这个库最重要的一条原则是：

**谁拥有资源，谁就自己创建并自己使用。**

这里的资源主要包括：

- Erlang `port`
- UDP `socket`
- `vswitch` 下行 `receiver`

它们都按 **owner-bound resource** 对待，不当成普通值随便传来传去。

所以现在的设计是：

- `device` actor 自己创建并持有 helper `port`
- `transport` actor 自己创建并持有 UDP `socket` 或本地 `receiver`
- `vport` actor 只负责编排，不越权直接碰底层资源
- `udp_server` 在服务端本地持有 `vswitch` 句柄和每个远端客户端对应的下行 receiver

这样做的好处是：

- 资源归属清楚
- 不容易踩 Erlang / OTP 的 owner 语义坑
- 后面要加 supervision、重连、心跳时边界更稳定

## 项目结构

```text
src/
├── device/
│   ├── device.gleam          # 本地设备 actor，统一封装 mock / TAP
│   ├── helper_launcher.gleam # Python helper 启动参数包装
│   ├── port_bridge.gleam     # Gleam <-> Erlang port FFI 声明
│   └── port_bridge_ffi.erl   # Erlang 侧 open_port 实现
├── protocol/
│   ├── ethernet.gleam        # 以太网头解析
│   └── udp_protocol.gleam    # Hello / Welcome / Frame 编解码
├── transport/
│   ├── client.gleam          # 客户端 transport actor 核心抽象
│   ├── direct_vswitch.gleam  # 本机直连 vswitch 的 transport
│   ├── udp_client.gleam      # 远端 UDP transport 包装
│   └── udp_server.gleam      # 服务端 UDP 接入层
├── vport/
│   ├── client.gleam          # VPort 对外 API
│   └── runtime.gleam         # VPort actor 运行时
└── vswitch/
    ├── server.gleam          # VSwitch actor
    └── switch_table.gleam    # MAC 学习表纯逻辑
```

## 核心模块说明

### `vswitch`

文件：

- `src/vswitch/server.gleam:1`
- `src/vswitch/switch_table.gleam:1`

职责：

- 接收客户端上行帧
- 解析源 MAC / 目的 MAC
- 学习 “源 MAC 来自哪个 client”
- 判断应该单播还是泛洪
- 把帧转发给目标客户端

可以把它理解成一个最小版二层交换机。

其中：

- `switch_table.gleam` 是纯逻辑，不依赖 actor / socket / port
- `server.gleam` 是 actor 外壳，负责接收消息和分发帧

### `device`

文件：

- `src/device/device.gleam:1`
- `src/device/helper_launcher.gleam:1`
- `src/device/port_bridge.gleam:1`
- `src/device/port_bridge_ffi.erl:1`

职责：

- 启动本地 mock helper 或真实 TAP helper
- 从设备读一帧
- 向设备写一帧
- 把底层 Erlang port 封装成 actor 持有资源

当前支持两种模式：

- `start_mock()`
- `start_tap(name)`

这里的真实 TAP 读写最终由 `native/tap_helper.py` 完成。

### `transport`

文件：

- `src/transport/client.gleam:1`
- `src/transport/direct_vswitch.gleam:1`
- `src/transport/udp_client.gleam:1`
- `src/transport/udp_server.gleam:1`

职责：

- 把“客户端怎么连到交换面”抽象成统一接口

客户端侧统一只有三件事：

- `send_to_server(...)`
- `receive_from_server(...)`
- `stop(...)`

底下可以是两种链路：

- 本机直连 `vswitch`
- 远端 UDP

#### `direct_vswitch`

用于本机调试和测试。

链路是：

```text
vport -> direct_vswitch -> vswitch
```

这是本地 actor 间通信，不走网络。

#### `udp_client`

用于远端连接服务端。

链路是：

```text
vport -> udp_client ~~ UDP ~~ udp_server -> vswitch
```

它会在内部：

- 创建 UDP socket
- connect 到服务端
- 发送 `Hello(client_id)`
- 等待 `Welcome`

#### `udp_server`

这是远端客户端真正连上的“网络入口”。

它不是交换机本体，但它代表远端客户端接入本地 `vswitch`。

它负责：

- 收 UDP 包
- 处理 `Hello / Welcome`
- 维护 `client_id <-> endpoint` 双向会话索引
- 把客户端上行帧送进 `vswitch`
- 从 `vswitch` 收下行帧，再发回对应的 UDP endpoint

所以可以这样理解：

- `vswitch` 是交换核心
- `udp_server` 是网络接入层

### `vport`

文件：

- `src/vport/client.gleam:1`
- `src/vport/runtime.gleam:1`

职责：

- 从本地 `device` 读帧
- 把帧交给 `transport`
- 从 `transport` 收帧
- 再写回本地 `device`

它相当于客户端里的“中继器”。

当前公开的启动入口分得比较明确：

- `start_mock_direct(...)`
- `start_tap_direct(...)`
- `start_mock_udp(...)`
- `start_tap_udp(...)`

这里特意把：

- “本地设备类型” 和
- “怎么连接服务端”

拆开命名，避免 `start_tap()` 这种容易让人误会的接口名。

## 两种使用模式

### 1. 本机直连模式

链路：

```text
device <-> vport <-> direct_vswitch transport <-> vswitch
```

适合：

- 单元测试
- 集成测试
- 本地调试
- 不想引入真实网络变量时验证交换逻辑

对应入口：

- `vport.start_mock_direct(switch, client_id)`
- `vport.start_tap_direct(switch, client_id, tap_name)`

### 2. 远端 UDP 模式

链路：

```text
device <-> vport <-> udp client transport ~~ UDP ~~ udp server <-> vswitch
```

适合：

- 两台机器之间通信
- 真实 overlay 网络实验

对应入口：

- `vport.start_mock_udp(config)`
- `vport.start_tap_udp(config, tap_name)`

其中 `config` 是 `transport/udp_client.UdpClientConfig`，字段有：

- `client_id`
- `server_host`
- `server_port`
- `local_port`

## 一帧数据怎么流动

### 上行：设备到交换机

```text
device -> vport -> transport -> vswitch
```

过程：

1. `device` 读到一帧本地以太网帧
2. `vport` 调用 `transport.send_to_server(...)`
3. 如果是直连模式，就直接送给本地 `vswitch`
4. 如果是 UDP 模式，就编码成 UDP 消息发给 `udp_server`
5. `vswitch` 学习源 MAC，并决定单播还是泛洪

### 下行：交换机到目标设备

```text
vswitch -> transport -> vport -> device
```

过程：

1. `vswitch` 决定把帧投递给目标客户端
2. 直连模式下，帧直接进入本地下行 receiver
3. UDP 模式下，帧先到服务端本地 `udp_server` 持有的 receiver
4. `udp_server` 把帧发回远端客户端
5. 远端 `transport` 收到帧后交给 `vport`
6. `vport` 再写回本地 `device`

## 为什么远端客户端不能直接调 `server.connect`

因为 `server.connect(...)` 是**本地 actor API**。

它的前提是：

- 你和 `vswitch` 在同一个本地运行时里
- 你手里已经有 `server.Server`

所以：

- 本机直连模式可以直接调
- 跨机器不行

跨机器时的做法是：

1. 远端客户端发 `Hello(client_id)` 给 `udp_server`
2. 服务端本机的 `udp_server` 收到后
3. `udp_server` 再代表这个远端客户端，去本地调用 `server.connect(...)`

也就是说：

- 远端客户端连的是 `udp_server`
- 不是直接连 `vswitch`

## 为什么要强调资源 owner

因为 Erlang / OTP 里的很多东西都不是“普通值”。

比如：

- `port`
- `socket`
- 某些接收通道

如果把它们随便跨进程传递，经常会出现：

- owner 不一致
- 读写失败
- 语义混乱
- 后续不好 supervision

所以这个库尽量遵守：

- 谁用，谁创建
- 谁拥有，谁操作
- 其他人通过消息请求 owner 代操作

这比“到处传 socket / port”要稳得多。

## 依赖这个库时，最常用的模块

如果你只是想在上层项目里用它，最常接触的大概是这些：

- `src/vswitch/server.gleam:1`
- `src/transport/udp_server.gleam:1`
- `src/transport/udp_client.gleam:1`
- `src/vport/client.gleam:1`
- `src/device/device.gleam:1`

可以粗略记成：

- 服务端看 `vswitch` + `udp_server`
- 客户端看 `vport` + `udp_client` + `device`

## 一个最小的服务端思路

在你的 server app 里，大致会写成：

1. `vswitch.start()`
2. `udp_server.start(...)`
3. 让进程常驻

也就是：

```text
start vswitch
start udp_server
wait forever
```

更接近真实代码的伪代码大概是：

```gleam
import transport/udp_server
import vswitch/server

pub fn main() {
  let assert Ok(switch) = server.start()
  let assert Ok(udp) =
    udp_server.start(
      udp_server.UdpServerConfig(
        vswitch: switch,
        bind_host: "0.0.0.0",
        bind_port: 9999,
      ),
    )

  // 记录监听端口、注册 supervision、等待退出信号……
  let _port = udp_server.bound_port(udp)

  wait_forever()
}
```

## 一个最小的客户端思路

在你的 client app 里，大致会写成：

1. 选择 `mock` 还是 `tap`
2. 准备 `UdpClientConfig`
3. 启动 `vport.start_mock_udp(...)` 或 `vport.start_tap_udp(...)`
4. 持续泵送两边数据

也就是：

```text
device <-> vport <-> udp transport
```

更接近真实代码的伪代码大概是：

```gleam
import transport/udp_client
import vport/client as vport

pub fn main() {
  let config =
    udp_client.UdpClientConfig(
      client_id: "client-1",
      server_host: "192.168.1.10",
      server_port: 9999,
      local_port: 0,
    )

  let assert Ok(client) = vport.start_tap_udp(config, "tap0")

  loop_forever(fn() {
    let _ = vport.pump_device_to_switch_once(client, 50)
    let _ = vport.pump_switch_to_device_once(client, 50)
  })
}
```

如果你暂时不想碰真实 TAP，可以先把：

- `vport.start_tap_udp(config, "tap0")`

换成：

- `vport.start_mock_udp(config)`

这样可以先把 UDP 链路和协议流程跑通，再去接真实网卡。

## 上层 app 自己还要补什么

这个库故意没有替你决定“应用层长什么样”，所以上层项目通常还要自己补这些：

- CLI 参数解析
- 配置文件读取
- 日志输出
- supervision tree
- 退出信号处理
- 客户端主循环的调度策略
- 重连、心跳、超时策略

也就是说，这个仓库负责的是：

- 核心网络组件
- 资源 owner 边界
- 基础消息流

而真正的“产品化应用外壳”应该放在独立的 server/client 项目里。

## 平台注意事项

- 真实 TAP 模式依赖 Linux
- 通常需要 `CAP_NET_ADMIN`，也就是常见的 `sudo`
- macOS / Windows 上更适合先用 `mock` 模式做开发

## 开发命令

```sh
gleam format src test
gleam build
gleam test
python3 native/tap_helper.py --mode mock
```

## 当前状态

现在这个仓库更适合作为**库**来用，当前已经具备：

- `device / protocol / transport / vport / vswitch` 分层
- actor owner 模型
- 本机直连模式测试
- UDP client / server 基础链路

还没做成的部分主要是：

- 独立的 server 可执行项目
- 独立的 client 可执行项目
- 更完整的跨机器联调脚本
- TAP + 双机 `ping` 的最终演示工程

如果你要把它接到单独的 app 里，这个 README 现在应该可以直接作为整体结构说明来看。
