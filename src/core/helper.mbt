// Python-compatible helpers used throughout the port.

///|
/// Python `str.isdigit()` for a whole string.
pub fn str_is_digit(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  for c in s {
    if !is_py_digit(c) {
      return false
    }
  }
  true
}

///|
/// Python `str.isalnum()`-like check used for plain words.
pub fn str_is_alnum(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  for c in s {
    if !is_alnum(c) {
      return false
    }
  }
  true
}

///|
/// Python `str.strip()` (whitespace).
pub fn py_strip(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  let mut j = chars.length()
  while i < j && is_space(chars[i]) {
    i += 1
  }
  while j > i && is_space(chars[j - 1]) {
    j -= 1
  }
  if i == 0 && j == chars.length() {
    s
  } else {
    String::from_array(chars[i:j])
  }
}

///|
/// Python `str.strip(chars)`.
pub fn strip_chars(s : String, chars : String) -> String {
  s.trim(chars~).to_string()
}

///|
/// Python `str.split()` (no separator: splits on runs of whitespace).
pub fn py_split_ws(s : String) -> Array[String] {
  let out = []
  let sb = StringBuilder()
  let mut has = false
  for c in s {
    if is_space(c) {
      if has {
        out.push(sb.to_string())
        sb.reset()
        has = false
      }
    } else {
      sb.write_char(c)
      has = true
    }
  }
  if has {
    out.push(sb.to_string())
  }
  out
}

///|
/// Python `str.split(sep)`.
pub fn py_split(s : String, sep : String) -> Array[String] {
  s.split(sep).map(x => x.to_string()).collect()
}

///|
/// Converts `name` from CamelCase to SNAKE_CASE (upper).
pub fn camel_to_snake_case(name : String) -> String {
  let sb = StringBuilder()
  let mut first = true
  for c in name {
    if !first && c >= 'A' && c <= 'Z' {
      sb.write_char('_')
    }
    sb.write_char(c)
    first = false
  }
  py_upper(sb.to_string())
}

///|
/// Searches for a name that isn't in `taken`.
pub fn find_new_name(taken : (String) -> Bool, base : String) -> String {
  if !taken(base) {
    return base
  }
  let mut i = 2
  let mut new = "\{base}_\{i}"
  while taken(new) {
    i += 1
    new = "\{base}_\{i}"
  }
  new
}

///|
/// Like CPython's `_PyUnicode_TransformDecimalAndSpaceToASCII` (used by `int()` and
/// `float()`): replaces Unicode decimal digits by their ASCII digit and Unicode white space
/// by a space.
pub fn to_ascii_decimal(text : String) -> String {
  if is_ascii_string(text) {
    return text
  }
  let sb = StringBuilder()
  for c in text {
    let d = decimal_value(c)
    if c.to_int() < 128 {
      sb.write_char(c)
    } else if d >= 0 {
      sb.write_char(Int::unsafe_to_char('0'.to_int() + d))
    } else if is_space(c) {
      sb.write_char(' ')
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Python `int(text)` succeeds.
pub fn is_int_str(text : String) -> Bool {
  let t = py_strip(to_ascii_decimal(text))
  if t.is_empty() {
    return false
  }
  let chars = t.to_array()
  let mut i = 0
  if chars[0] == '+' || chars[0] == '-' {
    i = 1
  }
  if i >= chars.length() {
    return false
  }
  let mut prev_us = true
  while i < chars.length() {
    let c = chars[i]
    if c == '_' {
      if prev_us {
        return false
      }
      prev_us = true
    } else if is_digit_char(c) {
      prev_us = false
    } else {
      return false
    }
    i += 1
  }
  !prev_us
}

///|
/// Python `float(text)` succeeds.
pub fn is_float_str(text : String) -> Bool {
  let t = py_lower(py_strip(to_ascii_decimal(text)))
  if t.is_empty() {
    return false
  }
  let body = if t.has_prefix("+") || t.has_prefix("-") {
    t.unsafe_substring(start=1, end=t.length())
  } else {
    t
  }
  if body == "inf" || body == "infinity" || body == "nan" {
    return true
  }
  let chars = body.to_array()
  let n = chars.length()
  let mut i = 0
  let mut digits = 0
  while i < n && (is_digit_char(chars[i]) || chars[i] == '_') {
    if chars[i] != '_' {
      digits += 1
    }
    i += 1
  }
  if i < n && chars[i] == '.' {
    i += 1
    while i < n && (is_digit_char(chars[i]) || chars[i] == '_') {
      if chars[i] != '_' {
        digits += 1
      }
      i += 1
    }
  }
  if digits == 0 {
    return false
  }
  if i < n && chars[i] == 'e' {
    i += 1
    if i < n && (chars[i] == '+' || chars[i] == '-') {
      i += 1
    }
    let mut ed = 0
    while i < n && is_digit_char(chars[i]) {
      ed += 1
      i += 1
    }
    if ed == 0 {
      return false
    }
  }
  i == n
}

///|
/// The error raised where Python would hold an integer outside the Int64 range: the
/// port's AST integers (`Value::Int`), host ints (`PyInt`) and executor integers are
/// 64-bit, so such values are refused instead of wrapping or being silently changed.
pub fn int64_range_error(what : String) -> SqlglotError {
  ValueError(
    "integer \{what} is outside the Int64 range supported by this port (Python ints are unbounded)",
  )
}

///|
/// Python `int(text)` as an Int64: `None` when `text` isn't an integer literal, and
/// `int64_range_error` when it is one outside the Int64 range.
pub fn parse_int_checked(text : String) -> Int64? raise SqlglotError {
  if !is_int_str(text) {
    return None
  }
  match parse_int_str(text) {
    Some(v) => Some(v)
    None => raise int64_range_error(py_strip(text))
  }
}

///|
/// `str(int(text) + delta)` for an integer literal `text` of any size, else `None`.
pub fn py_int_text_add(text : String, delta : Int) -> String? {
  if !is_int_str(text) {
    return None
  }
  let t = py_strip(to_ascii_decimal(text)).replace_all(old="_", new="")
  let (neg, digits) = if t.has_prefix("-") || t.has_prefix("+") {
    (t.has_prefix("-"), t.unsafe_substring(start=1, end=t.length()))
  } else {
    (false, t)
  }
  let v = @bigint.BigInt::from_string(digits)
  let v = if neg { -v } else { v }
  Some((v + @bigint.BigInt::from_int(delta)).to_string())
}

///|
/// Parses a Python-style integer string (allowing `_` separators and sign); `None` when
/// it isn't an integer or is outside the Int64 range (see `parse_int_checked`).
pub fn parse_int_str(text : String) -> Int64? {
  if !is_int_str(text) {
    return None
  }
  let t = py_strip(to_ascii_decimal(text)).replace_all(old="_", new="")
  Some(@string.parse_int64(t)) catch {
    _ => None
  }
}

///|
/// Python `to_bool` helper.
pub fn to_bool_str(value : String) -> Bool? {
  let v = py_lower(value)
  if v == "true" || v == "1" {
    Some(true)
  } else if v == "false" || v == "0" {
    Some(false)
  } else {
    None
  }
}

///|
/// Returns a name generator given a prefix (e.g. a0, a1, a2...).
pub fn name_sequence(prefix : String) -> () -> String {
  let counter = Ref::new(0)
  fn() {
    let n = counter.val
    counter.val += 1
    "\{prefix}\{n}"
  }
}

///|
/// Python `str[start:end]` on code points.
pub fn substr(s : String, start : Int, end : Int) -> String {
  // Without surrogate pairs, code point and UTF-16 indices coincide: slice directly
  // instead of materializing the code points.
  let bmp = !has_surrogates(s)
  let n = if bmp { s.length() } else { s.char_length() }
  let mut a = if start < 0 { n + start } else { start }
  let mut b = if end < 0 { n + end } else { end }
  if a < 0 {
    a = 0
  }
  if b > n {
    b = n
  }
  if a >= b {
    return ""
  }
  if bmp {
    return s.unsafe_substring(start=a, end=b)
  }
  let offsets = code_point_offsets(s)
  s.unsafe_substring(start=offsets[a], end=offsets[b])
}

///|
fn has_surrogates(s : String) -> Bool {
  for i in 0..<s.length() {
    let u = s.code_unit_at(i).to_int()
    if u >= 0xD800 && u <= 0xDFFF {
      return true
    }
  }
  false
}

///|
/// The UTF-16 offset of every code point of `s`, plus `s.length()` at the end; `[]` when
/// `s` has no surrogate pairs (offsets equal code point indices).
pub fn code_point_offsets(s : String) -> Array[Int] {
  if !has_surrogates(s) {
    return []
  }
  let out = []
  let mut i = 0
  let n = s.length()
  while i < n {
    out.push(i)
    let u = s.code_unit_at(i).to_int()
    let pair = u >= 0xD800 &&
      u <= 0xDBFF &&
      i + 1 < n &&
      s.code_unit_at(i + 1).to_int() >= 0xDC00 &&
      s.code_unit_at(i + 1).to_int() <= 0xDFFF
    i += if pair { 2 } else { 1 }
  }
  out.push(n)
  out
}

///|
/// Number of code points of a string (Python `len`).
pub fn py_len(s : String) -> Int {
  s.char_length()
}

///|
pub fn starts_with(s : String, prefix : String) -> Bool {
  s.has_prefix(prefix)
}

///|
pub fn ends_with(s : String, suffix : String) -> Bool {
  s.has_suffix(suffix)
}

///|
/// Python's `repr()` for a string (single-quoted unless it contains single quotes only;
/// non-printable characters are escaped as `\xhh`, `\uhhhh` or `\Uhhhhhhhh`).
pub fn py_repr_str(s : String) -> String {
  let quote = if s.contains("'") && !s.contains("\"") { '"' } else { '\'' }
  let sb = StringBuilder()
  sb.write_char(quote)
  let hex = "0123456789abcdef"
  for c in s {
    match c {
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ =>
        if c == quote {
          sb.write_char('\\')
          sb.write_char(c)
        } else if is_printable(c) {
          sb.write_char(c)
        } else {
          let h = c.to_int()
          let (prefix, width) = if h < 0x100 {
            ("\\x", 2)
          } else if h < 0x10000 {
            ("\\u", 4)
          } else {
            ("\\U", 8)
          }
          sb.write_string(prefix)
          for k in 0..<width {
            let shift = 4 * (width - 1 - k)
            sb.write_char(hex.get_char((h >> shift) & 15).unwrap())
          }
        }
    }
  }
  sb.write_char(quote)
  sb.to_string()
}

///|
/// Whether `text` matches `^[_a-zA-Z][\w]*$` (Python `SAFE_IDENTIFIER_RE`; `$` also
/// matches before a trailing newline).
pub fn is_safe_identifier(text : String) -> Bool {
  let text = if text.has_suffix("\n") {
    text.unsafe_substring(start=0, end=text.length() - 1)
  } else {
    text
  }
  let mut first = true
  for c in text {
    if first {
      if !(c == '_' || c.is_ascii_alphabetic()) {
        return false
      }
      first = false
    } else if !is_word_char(c) {
      return false
    }
  }
  !first
}

///|
pub fn min_int(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
pub fn max_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}
