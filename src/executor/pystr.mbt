// Python `repr(float)` and `str.upper()` / `str.lower()` special cases.

///|
/// Python `repr(float)`: the shortest round-tripping digits, in scientific notation when
/// the decimal exponent is < -4 or >= 16.
/// TODO(dedupe): `@core.py_float_repr` prints e.g. `1e16` as `10000000000000000`.
pub fn float_repr(d : Double) -> String {
  if d.is_nan() {
    return "nan"
  }
  if d.is_pos_inf() {
    return "inf"
  }
  if d.is_neg_inf() {
    return "-inf"
  }
  if d == 0.0 {
    return if (1.0 / d).is_neg_inf() { "-0.0" } else { "0.0" }
  }
  // decompose MoonBit's shortest representation into digits and a decimal exponent
  let s = d.abs().to_string()
  let (mantissa, exp) = match s.find("e") {
    Some(i) => {
      let m = s.view(end_offset=i).to_string()
      let e = s.view(start_offset=i + 1).to_string()
      let e = if e.has_prefix("+") { e.substring(start=1) } else { e }
      (m, @core.parse_int_str(e).map(x => x.to_int()).unwrap_or(0))
    }
    None => (s, 0)
  }
  let (int_part, frac_part) = match mantissa.find(".") {
    Some(i) =>
      (
        mantissa.view(end_offset=i).to_string(),
        mantissa.view(start_offset=i + 1).to_string(),
      )
    None => (mantissa, "")
  }
  let mut digits = int_part + frac_part
  // value = 0.<digits> * 10^decpt
  let mut decpt = int_part.length() + exp
  // strip leading zeros
  let mut lead = 0
  while lead < digits.length() - 1 && digits[lead] == '0' {
    lead += 1
  }
  digits = digits.substring(start=lead)
  decpt -= lead
  // strip trailing zeros
  let mut end = digits.length()
  while end > 1 && digits[end - 1] == '0' {
    end -= 1
  }
  digits = digits.substring(end~)
  let sign = if d < 0.0 { "-" } else { "" }
  let n = digits.length()
  if decpt <= -4 || decpt > 16 {
    let e = decpt - 1
    let mant = if n == 1 {
      digits
    } else {
      digits.substring(end=1) + "." + digits.substring(start=1)
    }
    let es = e.abs().to_string()
    let es = if es.length() < 2 { "0" + es } else { es }
    sign + mant + "e" + (if e < 0 { "-" } else { "+" }) + es
  } else if decpt <= 0 {
    sign + "0." + "0".repeat(-decpt) + digits
  } else if decpt >= n {
    sign + digits + "0".repeat(decpt - n) + ".0"
  } else {
    sign + digits.substring(end=decpt) + "." + digits.substring(start=decpt)
  }
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
