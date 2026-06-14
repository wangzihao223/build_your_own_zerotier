import args
import gleam/erlang/process
import gleam/int
import gleam/io
import transport/udp_server
import vswitch/server as vswitch

pub fn main() {
  let argv = args.argv()
  let port = args.get_int(argv, "--port", 9999)

  let assert Ok(switch) = vswitch.start()
  io.println("vswitch started")

  let assert Ok(udp) =
    udp_server.start(udp_server.UdpServerConfig(
      vswitch: switch,
      bind_host: "0.0.0.0",
      bind_port: port,
    ))

  let actual_port = udp_server.bound_port(udp)
  io.println("listening on 0.0.0.0:" <> int.to_string(actual_port))

  process.sleep_forever()
}
