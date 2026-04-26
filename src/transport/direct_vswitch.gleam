import transport/client
import vswitch/server

/// 创建一个直连当前 BEAM 节点 `vswitch` 的 transport。
///
/// 它主要用于本机开发和测试，不经过真实网络。
pub fn connect(
  switch: server.Server,
  client_id: server.ClientId,
) -> Result(client.ClientTransport, String) {
  client.connect_vswitch(switch, client_id)
}
