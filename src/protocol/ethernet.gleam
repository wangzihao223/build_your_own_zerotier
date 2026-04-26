import gleam/int
import gleam/list
import gleam/string

pub type Mac =
  String

pub type EtherType =
  Int

/// 原始以太网帧头的解析结果。
pub type Header {
  Header(dst_mac: Mac, src_mac: Mac, ether_type: EtherType)
}

pub type ParseError {
  FrameTooShort
}

/// 解析以太网帧头部，提取目的 MAC、源 MAC 和 EtherType。
pub fn parse_header(frame: BitArray) -> Result(Header, ParseError) {
  case frame {
    <<
      dst_0:size(8),
      dst_1:size(8),
      dst_2:size(8),
      dst_3:size(8),
      dst_4:size(8),
      dst_5:size(8),
      src_0:size(8),
      src_1:size(8),
      src_2:size(8),
      src_3:size(8),
      src_4:size(8),
      src_5:size(8),
      ether_type:size(16),
      _payload:bits,
    >> -> {
      Ok(Header(
        dst_mac: mac_to_string([dst_0, dst_1, dst_2, dst_3, dst_4, dst_5]),
        src_mac: mac_to_string([src_0, src_1, src_2, src_3, src_4, src_5]),
        ether_type: ether_type,
      ))
    }
    _ -> Error(FrameTooShort)
  }
}

fn mac_to_string(bytes: List(Int)) -> String {
  bytes
  |> list.map(byte_to_hex)
  |> string.join(":")
}

fn byte_to_hex(byte: Int) -> String {
  let hex = int.to_base16(byte)

  case string.length(hex) {
    1 -> "0" <> hex
    _ -> hex
  }
}
