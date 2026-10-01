// Python-compatible helpers used throughout the port.

///|
/// Python `str.upper()` for the common Unicode ranges.
pub fn py_upper(s : String) -> String {
  let mut ascii = true
  for c in s {
    if c.to_int() >= 128 {
      ascii = false
      break
    }
  }
  if ascii {
    return s.to_upper()
  }
  let sb = StringBuilder::new()
  for c in s {
    sb.write_char(char_upper(c))
  }
  sb.to_string()
}

///|
/// Python `str.lower()` for the common Unicode ranges.
pub fn py_lower(s : String) -> String {
  let mut ascii = true
  for c in s {
    if c.to_int() >= 128 {
      ascii = false
      break
    }
  }
  if ascii {
    return s.to_lower()
  }
  let sb = StringBuilder::new()
  for c in s {
    sb.write_char(char_lower(c))
  }
  sb.to_string()
}

///|
pub fn char_upper(c : Char) -> Char {
  let i = c.to_int()
  if i < 128 {
    return c.to_ascii_uppercase()
  }
  let u = if (i >= 0xE0 && i <= 0xFE && i != 0xF7) || (i >= 0x3B1 && i <= 0x3C9 && i != 0x3C2) || (i >= 0x430 && i <= 0x44F) {
    i - 32
  } else if i >= 0x450 && i <= 0x45F {
    i - 80
  } else if i >= 0x100 && i <= 0x17F && i % 2 == 1 && i != 0x131 && i != 0x138 && i != 0x149 && i != 0x17F {
    if (i >= 0x139 && i <= 0x148) || (i >= 0x179 && i <= 0x17E) {
      i
    } else {
      i - 1
    }
  } else if ((i >= 0x139 && i <= 0x148) || (i >= 0x179 && i <= 0x17E)) && i % 2 == 0 {
    i - 1
  } else if i == 0xFF {
    0x178
  } else {
    i
  }
  Int::unsafe_to_char(u)
}

///|
pub fn char_lower(c : Char) -> Char {
  let i = c.to_int()
  if i < 128 {
    return c.to_ascii_lowercase()
  }
  let l = if (i >= 0xC0 && i <= 0xDE && i != 0xD7) || (i >= 0x391 && i <= 0x3A9 && i != 0x3A2) || (i >= 0x410 && i <= 0x42F) {
    i + 32
  } else if i >= 0x400 && i <= 0x40F {
    i + 80
  } else if i >= 0x100 && i <= 0x17F && i % 2 == 0 && i != 0x130 && i != 0x138 {
    if (i >= 0x139 && i <= 0x148) || (i >= 0x179 && i <= 0x17E) {
      i
    } else {
      i + 1
    }
  } else if ((i >= 0x139 && i <= 0x148) || (i >= 0x179 && i <= 0x17E)) && i % 2 == 1 {
    i + 1
  } else if i == 0x178 {
    0xFF
  } else {
    i
  }
  Int::unsafe_to_char(l)
}

///|
/// Python `str.isspace()` for a single character.
pub fn is_space(c : Char) -> Bool {
  match c {
    ' ' | '\t' | '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{1c}' | '\u{1d}' | '\u{1e}' | '\u{1f}' | '\u{85}' | '\u{a0}' => true
    _ => {
      let i = c.to_int()
      i == 0x1680 ||
      (i >= 0x2000 && i <= 0x200A) ||
      i == 0x2028 ||
      i == 0x2029 ||
      i == 0x202F ||
      i == 0x205F ||
      i == 0x3000
    }
  }
}

///|
/// Python `str.isalpha()` approximation for a single character.
pub fn is_alpha(c : Char) -> Bool {
  if c.to_int() < 128 {
    return c.is_ascii_alphabetic()
  }
  let i = c.to_int()
  if i == 0xD7 || i == 0xF7 {
    return false
  }
  // Treat most non-ASCII letters, CJK, etc. as alphabetic. Excludes common
  // punctuation and symbol blocks.
  if i >= 0xA0 && i < 0xC0 {
    return i == 0xAA || i == 0xB5 || i == 0xBA
  }
  if i >= 0x2000 && i <= 0x2BFF {
    return false
  }
  if i >= 0x3000 && i <= 0x303F {
    return false
  }
  if i >= 0xFF00 && i <= 0xFF20 {
    return false
  }
  if i >= 0x1F000 && i <= 0x1FAFF {
    return false
  }
  !is_space(c) && !c.is_control()
}

///|
/// Python `str.isdigit()` approximation for a single character.
pub fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Python `str.isalnum()` for a single character.
pub fn is_alnum(c : Char) -> Bool {
  is_digit_char(c) || is_alpha(c)
}

///|
/// Python `str.isidentifier()` for a single character string.
pub fn is_identifier_char(c : Char) -> Bool {
  c == '_' || is_alpha(c)
}

///|
/// Python `str.isdigit()` for a whole string.
pub fn str_is_digit(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  for c in s {
    if !is_digit_char(c) {
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
  let sb = StringBuilder::new()
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
  let sb = StringBuilder::new()
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
/// Python `int(text)` succeeds.
pub fn is_int_str(text : String) -> Bool {
  let t = py_strip(text)
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
  let t = py_lower(py_strip(text))
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
/// Parses a Python-style integer string (allowing `_` separators and sign).
pub fn parse_int_str(text : String) -> Int64? {
  if !is_int_str(text) {
    return None
  }
  let t = py_strip(text).replace_all(old="_", new="")
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
  let chars = s.to_array()
  let n = chars.length()
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
  String::from_array(chars[a:b])
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
/// Python's `repr()` for a string (single-quoted unless it contains single quotes only).
pub fn py_repr_str(s : String) -> String {
  let quote = if s.contains("'") && !s.contains("\"") { '"' } else { '\'' }
  let sb = StringBuilder::new()
  sb.write_char(quote)
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
        } else if c.to_int() < 32 || c.to_int() == 127 {
          let h = c.to_int()
          let hex = "0123456789abcdef"
          sb.write_string("\\x")
          sb.write_char(hex.get_char(h / 16).unwrap())
          sb.write_char(hex.get_char(h % 16).unwrap())
        } else {
          sb.write_char(c)
        }
    }
  }
  sb.write_char(quote)
  sb.to_string()
}

///|
/// Whether `text` matches `^[_a-zA-Z][\w]*$` (Python `SAFE_IDENTIFIER_RE`).
pub fn is_safe_identifier(text : String) -> Bool {
  let mut first = true
  for c in text {
    if first {
      if !(c == '_' || c.is_ascii_alphabetic() || (c.to_int() >= 128 && is_alpha(c))) {
        return false
      }
      first = false
    } else if !(c == '_' || is_alnum(c)) {
      return false
    }
  }
  !first
}
