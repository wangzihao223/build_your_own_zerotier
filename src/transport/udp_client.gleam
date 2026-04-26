import transport/client
import vswitch/server

/// 用于启动 UDP transport client 的配置。
pub type UdpClientConfig {
  UdpClientConfig(
    client_id: server.ClientId,
    server_host: String,
    server_port: Int,
    local_port: Int,
  )
}

/// UDP transport client 对外暴露的错误类型。
pub type ClientError {
  InvalidLocalPort
  InvalidServerPort
  OpenFailed
  ConnectFailed
  SendFailed
  HandshakeTimeout
  ReceiveFailed
  InvalidHandshakeTimeout
  HandshakeDecodeFailed
  UnexpectedHandshakeMessage
}

/// 启动一个基于 UDP 的客户端 transport。
///
/// 它会在内部调用 `transport/client.start_udp_client`，
/// 并把内部错误类型映射成对外更稳定的 `ClientError`。
pub fn connect(
  config: UdpClientConfig,
) -> Result(client.ClientTransport, ClientError) {
  case
    client.start_udp_client(client.UdpStartConfig(
      client_id: config.client_id,
      server_host: config.server_host,
      server_port: config.server_port,
      local_port: config.local_port,
    ))
  {
    Ok(transport) -> Ok(transport)
    Error(error) -> Error(from_client_error(error))
  }
}

fn from_client_error(error: client.UdpStartError) -> ClientError {
  case error {
    client.InvalidLocalPort -> InvalidLocalPort
    client.InvalidServerPort -> InvalidServerPort
    client.OpenFailed -> OpenFailed
    client.ConnectFailed -> ConnectFailed
    client.SendFailed -> SendFailed
    client.HandshakeTimeout -> HandshakeTimeout
    client.ReceiveFailed -> ReceiveFailed
    client.InvalidHandshakeTimeout -> InvalidHandshakeTimeout
    client.HandshakeDecodeFailed -> HandshakeDecodeFailed
    client.UnexpectedHandshakeMessage -> UnexpectedHandshakeMessage
    client.InitFailed -> OpenFailed
  }
}
