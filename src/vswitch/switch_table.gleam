import gleam/dict

pub type Mac =
  String

pub type PortId =
  String

/// MAC 学习表。
pub type Table =
  dict.Dict(Mac, PortId)

/// 交换机在学习后做出的转发决策。
pub type ForwardAction {
  Unicast(output_port: PortId)
  Flood
}

/// 创建一个空的 MAC 学习表。
pub fn new() -> Table {
  dict.new()
}

/// 学习一条 `src_mac -> input_port` 映射。
pub fn learn(table: Table, src_mac: Mac, input_port: PortId) -> Table {
  dict.insert(table, src_mac, input_port)
}

/// 查询目的 MAC 当前命中的输出端口。
pub fn lookup(table: Table, dst_mac: Mac) -> Result(PortId, Nil) {
  dict.get(table, dst_mac)
}

/// 在收到一帧后，先学习源 MAC，再决定单播或泛洪。
pub fn handle_frame(
  table: Table,
  src_mac: Mac,
  dst_mac: Mac,
  input_port: PortId,
) -> #(Table, ForwardAction) {
  let updated_table = learn(table, src_mac, input_port)

  case lookup(updated_table, dst_mac) {
    Ok(output_port) -> #(updated_table, Unicast(output_port))
    Error(Nil) -> #(updated_table, Flood)
  }
}
