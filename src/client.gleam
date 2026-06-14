import args
import gleam/int
import gleam/io
import transport/udp_client
import vport/client as vport

pub fn main() {
  let argv = args.argv()
  let server_host = args.get_string(argv, "--server", "127.0.0.1")
  let server_port = args.get_int(argv, "--port", 9999)
  let client_id = args.get_string(argv, "--id", "client-1")
  let local_port = args.get_int(argv, "--local-port", 0)

  let config =
    udp_client.UdpClientConfig(
      client_id: client_id,
      server_host: server_host,
      server_port: server_port,
      local_port: local_port,
    )

  io.println(
    "connecting to "
    <> server_host
    <> ":"
    <> int.to_string(server_port)
    <> " as "
    <> client_id,
  )

  let tap = args.get_string(argv, "--tap", "")
  let result = case tap {
    "" -> vport.start_mock_udp(config)
    name -> vport.start_tap_udp(config, name)
  }

  case result {
    Ok(client) -> {
      io.println("connected")
      pump_loop(client)
    }
    Error(reason) -> io.println("failed to connect: " <> reason)
  }
}

fn pump_loop(client: vport.Client) -> Nil {
  let _ = vport.pump_device_to_switch_once(client, 50)
  let _ = vport.pump_switch_to_device_once(client, 50)
  pump_loop(client)
}
