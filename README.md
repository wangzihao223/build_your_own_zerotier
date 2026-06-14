# build_your_own_zerotier

用 Gleam / Erlang OTP 实现的 ZeroTier 风格**二层 overlay 网络库**。

通过 UDP 隧道把多台机器的虚拟网卡连到同一个虚拟交换机上，让它们像在同一个局域网里一样通信。工作在数据链路层，支持所有以太网上层协议（IPv4、IPv6、ARP 等）。

---

## 架构

### 整体拓扑

```
客户端 A                      服务端                      客户端 B
┌─────────┐                ┌─────────┐                ┌─────────┐
│  TAP/   │                │ vswitch │                │  TAP/   │
│  mock   │                │(二层交换)│                │  mock   │
│ device  │                └────┬────┘                │ device  │
└────┬────┘                     │                     └────┬────┘
     │                    ┌─────┴─────┐                    │
   vport               udp_server                        vport
     │                    │       │                        │
  udp_client ════════════UDP     UDP════════════════ udp_client
```

### 分层结构

```
protocol/
  ethernet.gleam       以太网帧头解析（MAC、EtherType）
  udp_protocol.gleam   UDP 隧道协议编解码（Hello/Welcome/Frame）

vswitch/
  server.gleam         虚拟二层交换机 actor，MAC 学习 + 转发
  switch_table.gleam   MAC 学习表纯逻辑

device/
  device.gleam         本地设备 actor（TAP 或 mock）
  helper_launcher.gleam Python helper 启动参数封装
  port_bridge.gleam    Gleam <-> Erlang port FFI

transport/
  client.gleam         客户端 transport actor（直连 / UDP 两种实现）
  udp_server.gleam     服务端 UDP 接入层
  udp_client.gleam     UDP transport 对外封装
  direct_vswitch.gleam 本机直连 transport（用于测试）

vport/
  client.gleam         VPort 对外 API
  runtime.gleam        VPort 运行时，组合 device + transport
```

### 服务端内部结构

```
server_process（主进程）
├── sessions actor     管理 client_id <-> endpoint 映射
│     └── forwarder 进程（每客户端一个）
│           接收 vswitch 下行帧 → 发给 sessions actor
├── upstream 进程      udp.receive 循环，上行帧送入 vswitch
└── downstream 进程    轮询 sessions actor，把下行帧发回客户端
```

### 一帧数据的流动路径

**上行（客户端 → 交换机）：**
```
TAP device → vport → udp_client ══UDP══ udp_server → vswitch
```

**下行（交换机 → 客户端）：**
```
vswitch → forwarder → sessions actor → downstream ══UDP══ udp_client → vport → TAP device
```

---

## 快速开始

### 依赖

- [Gleam](https://gleam.run) >= 1.0
- Erlang/OTP >= 25
- Python 3（TAP helper，mock 模式不需要）
- Linux（TAP 模式需要，mock 模式跨平台）

### 编译

```sh
gleam build
```

---

## 运行

### 服务端

```sh
gleam run -m server -- --port 9999
```

参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--port` | `9999` | 监听端口（UDP） |

### 客户端

```sh
gleam run -m client -- --server <服务端IP> --port 9999 --id <客户端ID>
```

参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--server` | `127.0.0.1` | 服务端地址 |
| `--port` | `9999` | 服务端端口 |
| `--id` | `client-1` | 客户端唯一标识 |
| `--local-port` | `0` | 本地绑定端口，0 表示自动分配 |
| `--tap` | 无 | TAP 设备名，不填则使用 mock 模式 |

---

## 两种运行模式

### mock 模式（开发/测试）

不需要真实网卡，Python helper 模拟帧 I/O，适合验证协议流程。

```sh
# 服务端
gleam run -m server

# 客户端 1
gleam run -m client -- --id client-1

# 客户端 2
gleam run -m client -- --id client-2
```

### TAP 模式（真实网络）

需要 Linux + `CAP_NET_ADMIN` 权限，创建真实虚拟网卡，支持 ping 等网络工具。

**客户端 1（机器 A）：**

```sh
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 10.0.0.1/24 dev tap0
sudo ip link set tap0 up

sudo gleam run -m client -- \
  --server <服务端IP> --port 9999 \
  --id client-1 --tap tap0
```

**客户端 2（机器 B）：**

```sh
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 10.0.0.2/24 dev tap0
sudo ip link set tap0 up

sudo gleam run -m client -- \
  --server <服务端IP> --port 9999 \
  --id client-2 --tap tap0
```

**验证连通性：**

```sh
ping 10.0.0.2
```

---

## 作为库使用

### 服务端

```gleam
import transport/udp_server
import vswitch/server

pub fn main() {
  let assert Ok(switch) = server.start()
  let assert Ok(udp) =
    udp_server.start(udp_server.UdpServerConfig(
      vswitch: switch,
      bind_host: "0.0.0.0",
      bind_port: 9999,
    ))
  let port = udp_server.bound_port(udp)
  // 常驻...
}
```

### 客户端（mock + UDP）

```gleam
import transport/udp_client
import vport/client as vport

pub fn main() {
  let config = udp_client.UdpClientConfig(
    client_id: "client-1",
    server_host: "192.168.1.10",
    server_port: 9999,
    local_port: 0,
  )
  let assert Ok(client) = vport.start_mock_udp(config)

  // 主循环
  loop(fn() {
    let _ = vport.pump_device_to_switch_once(client, 50)
    let _ = vport.pump_switch_to_device_once(client, 50)
  })
}
```

### 客户端（TAP + UDP）

```gleam
let assert Ok(client) = vport.start_tap_udp(config, "tap0")
```

### 本机直连（测试）

```gleam
let assert Ok(switch) = server.start()
let assert Ok(client_a) = vport.start_mock_direct(switch, "a")
let assert Ok(client_b) = vport.start_mock_direct(switch, "b")
```

---

## 设计原则

**资源归属（owner-bound resource）**

Erlang port、UDP socket、vswitch receiver 都绑定到创建它的进程，不跨进程传递。
谁创建，谁持有，谁操作。其他进程通过消息请求 owner 代为操作。

**分层职责**

- `vswitch` 只管 MAC 学习和帧转发，不知道网络细节
- `udp_server` 只管接入层，不是交换机本体
- `vport` 只管在 device 和 transport 之间泵送帧，不碰底层资源
- `device` 只管本地设备读写

---

## 开发命令

```sh
gleam build       # 编译
gleam test        # 运行测试
gleam format src test  # 格式化代码
```
