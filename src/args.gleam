import gleam/int

@external(erlang, "argv_ffi", "get")
pub fn argv() -> List(String)

pub fn get_string(args: List(String), flag: String, default: String) -> String {
  case find_value(args, flag) {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

pub fn get_int(args: List(String), flag: String, default: Int) -> Int {
  case find_value(args, flag) {
    Ok(value) ->
      case int.parse(value) {
        Ok(n) -> n
        Error(Nil) -> default
      }
    Error(Nil) -> default
  }
}

fn find_value(args: List(String), flag: String) -> Result(String, Nil) {
  case args {
    [] -> Error(Nil)
    [_] -> Error(Nil)
    [key, value, ..rest] ->
      case key == flag {
        True -> Ok(value)
        False -> find_value([value, ..rest], flag)
      }
  }
}
