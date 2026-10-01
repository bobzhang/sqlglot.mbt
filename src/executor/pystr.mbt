// Python `repr(float)` and `str.upper()` / `str.lower()` special cases.

///|
/// Python `repr(float)`: the shortest round-tripping digits, in scientific notation when
/// the decimal exponent is < -4 or >= 16.
pub fn float_repr(d : Double) -> String {
  @core.py_float_repr(d)
}

///|
/// Python `str.upper()`, including the expansions of the special casing table that
/// matter in practice (e.g. `ß` -> `SS`).
pub fn str_upper(s : String) -> String {
  let mut special = false
  for c in s {
    if special_upper(c) is Some(_) {
      special = true
      break
    }
  }
  if !special {
    return @core.py_upper(s)
  }
  let sb = StringBuilder()
  for c in s {
    match special_upper(c) {
      Some(u) => sb.write_string(u)
      None => sb.write_char(@core.char_upper(c))
    }
  }
  sb.to_string()
}

///|
fn special_upper(c : Char) -> String? {
  match c {
    'ß' => Some("SS")
    'ŉ' => Some("ʼN")
    'ﬀ' => Some("FF")
    'ﬁ' => Some("FI")
    'ﬂ' => Some("FL")
    'ﬃ' => Some("FFI")
    'ﬄ' => Some("FFL")
    'ﬅ' | 'ﬆ' => Some("ST")
    _ => None
  }
}

///|
/// Python `str.lower()` (`İ` lowers to `i̇`).
pub fn str_lower(s : String) -> String {
  if !s.contains_char('İ') {
    return @core.py_lower(s)
  }
  let sb = StringBuilder()
  for c in s {
    if c == 'İ' {
      sb.write_string("i\u{307}")
    } else {
      sb.write_char(@core.char_lower(c))
    }
  }
  sb.to_string()
}
