import gleam/erlang/process
import gleam/io
import gleam/int
import transport/udp_server
import vswitch/server

pub fn main() {
  let assert Ok(switch) = server.start()
  io.println("vswitch started")

  let assert Ok(udp) =
    udp_server.start(udp_server.UdpServerConfig(
      vswitch: switch,
      bind_host: "0.0.0.0",
      bind_port: 9999,
    ))

  let port = udp_server.bound_port(udp)
  io.println("udp server listening on port " <> int.to_string(port))

  process.sleep_forever()
}
