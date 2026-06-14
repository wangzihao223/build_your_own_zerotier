import gleeunit
import protocol/ethernet
import protocol/udp_protocol
import transport/client as transport
import transport/udp_client
import transport/udp_server
import vport/client as vport
import vswitch/server as vswitch
import vswitch/switch_table as switch

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn learn_test() {
  let table = switch.new()
  let updated = switch.learn(table, "aa:aa:aa:aa:aa:aa", "port-1")

  assert switch.lookup(updated, "aa:aa:aa:aa:aa:aa") == Ok("port-1")
}

pub fn handle_frame_unicast_test() {
  let table =
    switch.new()
    |> switch.learn("aa:aa:aa:aa:aa:aa", "port-1")
    |> switch.learn("bb:bb:bb:bb:bb:bb", "port-2")

  let #(updated, action) =
    switch.handle_frame(
      table,
      "aa:aa:aa:aa:aa:aa",
      "bb:bb:bb:bb:bb:bb",
      "port-1",
    )

  assert switch.lookup(updated, "aa:aa:aa:aa:aa:aa") == Ok("port-1")
  assert action == switch.Unicast("port-2")
}

pub fn handle_frame_flood_test() {
  let table = switch.new()

  let #(updated, action) =
    switch.handle_frame(
      table,
      "aa:aa:aa:aa:aa:aa",
      "cc:cc:cc:cc:cc:cc",
      "port-1",
    )

  assert switch.lookup(updated, "aa:aa:aa:aa:aa:aa") == Ok("port-1")
  assert action == switch.Flood
}

pub fn relearn_mac_on_new_port_test() {
  let table =
    switch.new()
    |> switch.learn("aa:aa:aa:aa:aa:aa", "port-1")

  let #(updated, _) =
    switch.handle_frame(
      table,
      "aa:aa:aa:aa:aa:aa",
      "dd:dd:dd:dd:dd:dd",
      "port-2",
    )

  assert switch.lookup(updated, "aa:aa:aa:aa:aa:aa") == Ok("port-2")
}

pub fn parse_ethernet_header_test() {
  let frame = <<
    0xAA,
    0xBB,
    0xCC,
    0xDD,
    0xEE,
    0xFF,
    0x11,
    0x22,
    0x33,
    0x44,
    0x55,
    0x66,
    0x08,
    0x00,
    0xDE,
    0xAD,
  >>

  assert ethernet.parse_header(frame)
    == Ok(ethernet.Header(
      dst_mac: "AA:BB:CC:DD:EE:FF",
      src_mac: "11:22:33:44:55:66",
      ether_type: 0x0800,
    ))
}

pub fn parse_short_ethernet_frame_test() {
  let frame = <<0xAA, 0xBB, 0xCC>>

  assert ethernet.parse_header(frame) == Error(ethernet.FrameTooShort)
}

pub fn vswitch_flood_test() {
  let assert Ok(server) = vswitch.start()
  let receiver = vswitch.new_receiver()
  vswitch.connect(server, "client-1", receiver)
  vswitch.connect(server, "client-2", receiver)

  let frame =
    ethernet_frame(
      "AA",
      "BB",
      "CC",
      "DD",
      "EE",
      "FF",
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
    )

  vswitch.receive_from(server, "client-1", frame)

  assert vswitch.receive_forwarded(receiver, 100)
    == vswitch.Forwarded("client-2", frame)
}

pub fn vswitch_unicast_test() {
  let assert Ok(server) = vswitch.start()
  let receiver = vswitch.new_receiver()
  vswitch.connect(server, "client-1", receiver)
  vswitch.connect(server, "client-2", receiver)

  let learning_frame =
    ethernet_frame(
      "FF",
      "EE",
      "DD",
      "CC",
      "BB",
      "AA",
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
    )
  vswitch.receive_from(server, "client-2", learning_frame)
  let _ = vswitch.receive_forwarded(receiver, 100)

  let frame =
    ethernet_frame(
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
      "AA",
      "BB",
      "CC",
      "DD",
      "EE",
      "FF",
    )

  vswitch.receive_from(server, "client-1", frame)

  assert vswitch.receive_forwarded(receiver, 100)
    == vswitch.Forwarded("client-2", frame)
  assert vswitch.receive_forwarded(receiver, 20) == vswitch.Timeout
}

pub fn vswitch_drops_short_frame_test() {
  let assert Ok(server) = vswitch.start()
  let receiver = vswitch.new_receiver()
  vswitch.connect(server, "client-1", receiver)
  vswitch.connect(server, "client-2", receiver)

  vswitch.receive_from(server, "client-1", <<0xAA, 0xBB, 0xCC>>)

  assert vswitch.receive_forwarded(receiver, 20) == vswitch.Timeout
}

pub fn vport_pumps_device_frame_to_vswitch_test() {
  let assert Ok(server) = vswitch.start()
  let receiver = vswitch.new_receiver()
  vswitch.connect(server, "client-2", receiver)
  let assert Ok(client) = vport.start_mock_direct(server, "client-1")

  let frame =
    ethernet_frame(
      "AA",
      "BB",
      "CC",
      "DD",
      "EE",
      "FF",
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
    )

  vport.send_to_device(client, frame)

  assert vport.pump_device_to_switch_once(client, 1000) == vport.Pumped(frame)
  assert vswitch.receive_forwarded(receiver, 100)
    == vswitch.Forwarded("client-2", frame)

  vport.stop(client)
}

pub fn vport_pumps_vswitch_frame_to_device_test() {
  let assert Ok(server) = vswitch.start()
  let assert Ok(client) = vport.start_mock_direct(server, "client-1")
  let receiver = vswitch.new_receiver()
  vswitch.connect(server, "client-2", receiver)

  let learning_frame =
    ethernet_frame(
      "FF",
      "EE",
      "DD",
      "CC",
      "BB",
      "AA",
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
    )
  vswitch.receive_from(server, "client-1", learning_frame)
  let _ = vswitch.receive_forwarded(receiver, 100)

  let frame =
    ethernet_frame(
      "11",
      "22",
      "33",
      "44",
      "55",
      "66",
      "AA",
      "BB",
      "CC",
      "DD",
      "EE",
      "FF",
    )
  vswitch.receive_from(server, "client-2", frame)

  assert vport.pump_switch_to_device_once(client, 100) == vport.Pumped(frame)

  vport.stop(client)
}

pub fn encode_hello_test() {
  assert udp_protocol.encode_client_message(udp_protocol.Hello("client-1"))
    == Ok(<<0x01, 0x00, 0x08, "client-1":utf8>>)
}

pub fn decode_hello_test() {
  assert udp_protocol.decode_client_message(<<
      0x01,
      0x00,
      0x08,
      "client-1":utf8,
    >>)
    == Ok(udp_protocol.Hello("client-1"))
}

pub fn encode_welcome_test() {
  assert udp_protocol.encode_server_message(udp_protocol.Welcome)
    == Ok(<<0x02>>)
}

pub fn decode_welcome_test() {
  assert udp_protocol.decode_server_message(<<0x02>>)
    == Ok(udp_protocol.Welcome)
}

pub fn decode_hello_truncated_packet_test() {
  assert udp_protocol.decode_client_message(<<0x01, 0x00>>)
    == Error(udp_protocol.TruncatedPacket)
}

pub fn encode_client_frame_test() {
  let frame = <<0xAA, 0xBB, 0xCC>>

  assert udp_protocol.encode_client_message(udp_protocol.ClientFrame(frame))
    == Ok(<<0x03, 0xAA, 0xBB, 0xCC>>)
}

pub fn decode_client_frame_test() {
  assert udp_protocol.decode_client_message(<<0x03, 0xAA, 0xBB, 0xCC>>)
    == Ok(udp_protocol.ClientFrame(<<0xAA, 0xBB, 0xCC>>))
}

pub fn encode_server_frame_test() {
  let frame = <<0x11, 0x22, 0x33>>

  assert udp_protocol.encode_server_message(udp_protocol.ServerFrame(frame))
    == Ok(<<0x04, 0x11, 0x22, 0x33>>)
}

pub fn decode_server_frame_test() {
  assert udp_protocol.decode_server_message(<<0x04, 0x11, 0x22, 0x33>>)
    == Ok(udp_protocol.ServerFrame(<<0x11, 0x22, 0x33>>))
}

pub fn udp_server_accepts_multiple_clients_test() {
  let assert Ok(switch_server) = vswitch.start()
  let assert Ok(server) =
    udp_server.start(udp_server.UdpServerConfig(
      vswitch: switch_server,
      bind_host: "127.0.0.1",
      bind_port: 0,
    ))

  let assert Ok(client_1) =
    udp_client.connect(udp_client.UdpClientConfig(
      client_id: "client-1",
      server_host: "127.0.0.1",
      server_port: udp_server.bound_port(server),
      local_port: 0,
    ))

  let assert Ok(client_2) =
    udp_client.connect(udp_client.UdpClientConfig(
      client_id: "client-2",
      server_host: "127.0.0.1",
      server_port: udp_server.bound_port(server),
      local_port: 0,
    ))

  transport.stop(client_1)
  transport.stop(client_2)
  udp_server.stop(server)
}

fn ethernet_frame(
  dst_0: String,
  dst_1: String,
  dst_2: String,
  dst_3: String,
  dst_4: String,
  dst_5: String,
  src_0: String,
  src_1: String,
  src_2: String,
  src_3: String,
  src_4: String,
  src_5: String,
) -> BitArray {
  <<
    hex_byte(dst_0),
    hex_byte(dst_1),
    hex_byte(dst_2),
    hex_byte(dst_3),
    hex_byte(dst_4),
    hex_byte(dst_5),
    hex_byte(src_0),
    hex_byte(src_1),
    hex_byte(src_2),
    hex_byte(src_3),
    hex_byte(src_4),
    hex_byte(src_5),
    0x08,
    0x00,
    0xDE,
    0xAD,
  >>
}

fn hex_byte(hex: String) -> Int {
  case hex {
    "11" -> 0x11
    "22" -> 0x22
    "33" -> 0x33
    "44" -> 0x44
    "55" -> 0x55
    "66" -> 0x66
    "AA" -> 0xAA
    "BB" -> 0xBB
    "CC" -> 0xCC
    "DD" -> 0xDD
    "EE" -> 0xEE
    "FF" -> 0xFF
    _ -> 0x00
  }
}
