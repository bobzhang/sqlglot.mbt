// Python operators on runtime values.

///|
fn unsupported(op : String, a : Value, b : Value) -> PyException {
  type_error(
    "unsupported operand type(s) for \{op}: '\{a.type_name()}' and '\{b.type_name()}'",
  )
}

///|
fn as_int(v : Value) -> Int64? {
  match v {
    Int(i) => Some(i)
    Bool(b) => Some(if b { 1L } else { 0L })
    _ => None
  }
}

///|
fn as_float(v : Value) -> Double? {
  match v {
    Int(i) => Some(i.to_double())
    Bool(b) => Some(if b { 1.0 } else { 0.0 })
    Float(d) => Some(d)
    _ => None
  }
}

///|
/// Python `a + b`.
pub fn py_add(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) =>
      Int(checked_add(as_int(a).unwrap(), as_int(b).unwrap()))
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) =>
      Float(as_float(a).unwrap() + as_float(b).unwrap())
    (Str(x), Str(y)) => Str(x + y)
    (List(x), List(y)) => List(x + y)
    (Tuple(x), Tuple(y)) => Tuple(x + y)
    (Date(d), TimeDelta(td)) | (TimeDelta(td), Date(d)) =>
      Date(d.add_days(td.days))
    (DateTime(d), TimeDelta(td)) | (TimeDelta(td), DateTime(d)) =>
      DateTime(d.add_us(td.total_us()))
    (TimeDelta(x), TimeDelta(y)) =>
      TimeDelta(check_td(PyTimeDelta::from_us(x.total_us() + y.total_us())))
    _ => raise unsupported("+", a, b)
  }
}

///|
/// Python `a - b`.
pub fn py_sub(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) =>
      Int(checked_sub(as_int(a).unwrap(), as_int(b).unwrap()))
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) =>
      Float(as_float(a).unwrap() - as_float(b).unwrap())
    (Date(d), TimeDelta(td)) => Date(d.add_days(-td.days))
    (Date(x), Date(y)) =>
      TimeDelta(
        PyTimeDelta::from_us((x.toordinal() - y.toordinal()) * 86400000000L),
      )
    (DateTime(d), TimeDelta(td)) => DateTime(d.add_us(-td.total_us()))
    (DateTime(x), DateTime(y)) =>
      match (x.tz, y.tz) {
        (None, None) =>
          TimeDelta(PyTimeDelta::from_us(x.total_us() - y.total_us()))
        (Some(_), Some(_)) =>
          TimeDelta(PyTimeDelta::from_us(x.utc_us() - y.utc_us()))
        _ =>
          raise type_error(
            "can't subtract offset-naive and offset-aware datetimes",
          )
      }
    (TimeDelta(x), TimeDelta(y)) =>
      TimeDelta(check_td(PyTimeDelta::from_us(x.total_us() - y.total_us())))
    _ => raise unsupported("-", a, b)
  }
}

///|
fn repeat_seq(items : Array[Value], n : Int64) -> Array[Value] {
  let out = []
  for _ in 0L..<n {
    for x in items {
      out.push(x)
    }
  }
  out
}

///|
/// Python `a * b`.
pub fn py_mul(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) =>
      Int(checked_mul(as_int(a).unwrap(), as_int(b).unwrap()))
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) =>
      Float(as_float(a).unwrap() * as_float(b).unwrap())
    (Str(s), Int(_) | Bool(_)) | (Int(_) | Bool(_), Str(s)) => {
      let n = match as_int(a) {
        Some(n) => n
        None => as_int(b).unwrap()
      }
      Str(if n <= 0L { "" } else { s.repeat(n.to_int()) })
    }
    (List(l), Int(_) | Bool(_)) => List(repeat_seq(l, as_int(b).unwrap()))
    (Int(_) | Bool(_), List(l)) => List(repeat_seq(l, as_int(a).unwrap()))
    (Tuple(l), Int(_) | Bool(_)) => Tuple(repeat_seq(l, as_int(b).unwrap()))
    (TimeDelta(td), Int(_) | Bool(_)) | (Int(_) | Bool(_), TimeDelta(td)) => {
      let n = match as_int(a) {
        Some(n) => n
        None => as_int(b).unwrap()
      }
      TimeDelta(check_td(PyTimeDelta::from_us(checked_mul(td.total_us(), n))))
    }
    (TimeDelta(td), Float(f)) | (Float(f), TimeDelta(td)) =>
      TimeDelta(
        check_td(
          PyTimeDelta::from_us(
            round_half_even(td.total_us().to_double() * f).to_int64(),
          ),
        ),
      )
    _ => raise unsupported("*", a, b)
  }
}

///|
fn zero_division(msg : String) -> PyException {
  PyException("ZeroDivisionError", msg)
}

///|
/// Python `a / b`.
pub fn py_truediv(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) => {
      let x = as_int(a).unwrap()
      let y = as_int(b).unwrap()
      if y == 0L {
        raise zero_division("division by zero")
      }
      Float(int_true_div(x, y))
    }
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) => {
      let y = as_float(b).unwrap()
      if y == 0.0 {
        raise zero_division("division by zero")
      }
      Float(as_float(a).unwrap() / y)
    }
    (TimeDelta(x), TimeDelta(y)) => {
      if y.is_zero() {
        raise zero_division("division by zero")
      }
      Float(x.total_us().to_double() / y.total_us().to_double())
    }
    (TimeDelta(x), Int(_) | Bool(_)) => {
      let n = as_int(b).unwrap()
      if n == 0L {
        raise zero_division("division by zero")
      }
      TimeDelta(
        PyTimeDelta::from_us(
          round_half_even(x.total_us().to_double() / n.to_double()).to_int64(),
        ),
      )
    }
    _ => raise unsupported("/", a, b)
  }
}

///|
/// Correctly rounded true division of two integers (exact when both fit in 53 bits).
fn int_true_div(x : Int64, y : Int64) -> Double {
  let limit = 9007199254740992L
  if x.abs() <= limit && y.abs() <= limit {
    return x.to_double() / y.to_double()
  }
  let bx = @bigint.BigInt::from_int64(x)
  let by = @bigint.BigInt::from_int64(y)
  big_true_div(bx, by)
}

///|
/// Correctly rounded `a / b` for big integers (round half to even).
fn big_true_div(a : @bigint.BigInt, b : @bigint.BigInt) -> Double {
  let zero = @bigint.BigInt::from_int(0)
  let negative = (a.compare(zero) < 0) != (b.compare(zero) < 0)
  let a = if a.compare(zero) < 0 { a.neg() } else { a }
  let b = if b.compare(zero) < 0 { b.neg() } else { b }
  // scale so that the quotient has 55 significant bits
  let shift = 55 - (a.bit_length() - b.bit_length())
  let (num, den) = if shift >= 0 {
    (a.shl(shift), b)
  } else {
    (a, b.shl(-shift))
  }
  let q = num.div(den)
  let r = num.sub(q.mul(den))
  // q has 55 or 56 bits; round to 53 bits with sticky
  let qbits = q.bit_length()
  let extra = qbits - 53
  let mant = q.shr(extra)
  let rem = q.sub(mant.shl(extra))
  let half = @bigint.BigInt::from_int(1).shl(extra - 1)
  let c = rem.compare(half)
  let sticky = !r.is_zero()
  let mut m = mant.to_int64()
  if c > 0 || (c == 0 && (sticky || m % 2L == 1L)) {
    m += 1L
  }
  let e = extra - shift
  let d = ldexp(m.to_double(), e)
  if negative {
    -d
  } else {
    d
  }
}

///|
fn ldexp(x : Double, e : Int) -> Double {
  let mut r = x
  let mut e = e
  while e > 0 {
    let step = if e > 1000 { 1000 } else { e }
    r = r * @math.pow(2.0, step.to_double())
    e -= step
  }
  while e < 0 {
    let step = if e < -1000 { -1000 } else { e }
    r = r * @math.pow(2.0, step.to_double())
    e -= step
  }
  r
}

///|
/// Python `divmod` for floats: (floor quotient, modulo).
fn float_divmod(x : Double, y : Double) -> (Double, Double) {
  let mut m = x % y
  let mut div = (x - m) / y
  if m != 0.0 {
    if (y < 0.0) != (m < 0.0) {
      m += y
      div -= 1.0
    }
  } else {
    m = if y < 0.0 { -0.0 } else { 0.0 }
  }
  let floordiv = if div != 0.0 {
    let f = div.floor()
    if div - f > 0.5 {
      f + 1.0
    } else {
      f
    }
  } else if x / y < 0.0 {
    -0.0
  } else {
    0.0
  }
  (floordiv, m)
}

///|
/// Python `a // b`.
pub fn py_floordiv(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) => {
      let y = as_int(b).unwrap()
      if y == 0L {
        raise zero_division("integer division or modulo by zero")
      }
      Int(checked_floordiv(as_int(a).unwrap(), y))
    }
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) => {
      let y = as_float(b).unwrap()
      if y == 0.0 {
        raise zero_division("float floor division by zero")
      }
      Float(float_divmod(as_float(a).unwrap(), y).0)
    }
    (TimeDelta(x), TimeDelta(y)) => {
      if y.is_zero() {
        raise zero_division("integer division or modulo by zero")
      }
      Int(floor_div64(x.total_us(), y.total_us()))
    }
    _ => raise unsupported("//", a, b)
  }
}

///|
/// Python `a % b`.
pub fn py_mod(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) => {
      let x = as_int(a).unwrap()
      let y = as_int(b).unwrap()
      if y == 0L {
        raise zero_division("integer modulo by zero")
      }
      Int(py_mod64(x, y))
    }
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) => {
      let y = as_float(b).unwrap()
      if y == 0.0 {
        raise zero_division("float modulo")
      }
      Float(float_divmod(as_float(a).unwrap(), y).1)
    }
    (Str(_), _) =>
      raise type_error("not all arguments converted during string formatting")
    _ => raise unsupported("%", a, b)
  }
}

///|
/// Python `pow(a, b)` / `a ** b`.
pub fn py_pow(a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Int(_) | Bool(_), Int(_) | Bool(_)) => {
      let x = as_int(a).unwrap()
      let y = as_int(b).unwrap()
      if y < 0L {
        if x == 0L {
          raise zero_division("zero to a negative power")
        }
        return Float(@math.pow(x.to_double(), y.to_double()))
      }
      Int(checked_pow(x, y))
    }
    (Float(_) | Int(_) | Bool(_), Float(_) | Int(_) | Bool(_)) => {
      let x = as_float(a).unwrap()
      let y = as_float(b).unwrap()
      if x == 0.0 && y < 0.0 {
        raise zero_division("zero to a negative power")
      }
      if x < 0.0 && y != y.floor() {
        raise value_error("math domain error")
      }
      Float(@math.pow(x, y))
    }
    _ => raise unsupported("** or pow()", a, b)
  }
}

///|
/// Python `-a`.
pub fn py_neg(a : Value) -> Value raise PyException {
  match a {
    Int(i) => Int(checked_neg(i))
    Bool(b) => Int(if b { -1L } else { 0L })
    Float(d) => Float(-d)
    TimeDelta(td) => TimeDelta(check_td(PyTimeDelta::from_us(-td.total_us())))
    _ => raise type_error("bad operand type for unary -: '\{a.type_name()}'")
  }
}

///|
/// Python `+a`.
pub fn py_pos(a : Value) -> Value raise PyException {
  match a {
    Int(_) | Float(_) | TimeDelta(_) => a
    Bool(b) => Int(if b { 1L } else { 0L })
    _ => raise type_error("bad operand type for unary +: '\{a.type_name()}'")
  }
}

///|
/// Python `~a`.
pub fn py_invert(a : Value) -> Value raise PyException {
  match as_int(a) {
    Some(i) => Int(i.lnot())
    None => raise type_error("bad operand type for unary ~: '\{a.type_name()}'")
  }
}

///|
/// Python bitwise operators `&`, `|`, `^`, `<<`, `>>`.
pub fn py_bitop(op : String, a : Value, b : Value) -> Value raise PyException {
  match (a, b) {
    (Bool(x), Bool(y)) if op == "&" || op == "|" || op == "^" =>
      Bool(
        match op {
          "&" => x && y
          "|" => x || y
          _ => x != y
        },
      )
    _ =>
      match (as_int(a), as_int(b)) {
        (Some(x), Some(y)) =>
          Int(
            match op {
              "&" => x & y
              "|" => x | y
              "^" => x ^ y
              "<<" => {
                if y < 0L {
                  raise value_error("negative shift count")
                }
                checked_shl(x, y)
              }
              _ => {
                if y < 0L {
                  raise value_error("negative shift count")
                }
                if y >= 64L {
                  if x < 0L {
                    -1L
                  } else {
                    0L
                  }
                } else {
                  x >> y.to_int()
                }
              }
            },
          )
        _ => raise unsupported(op, a, b)
      }
  }
}

///|
/// Python `abs(a)`.
pub fn py_abs(a : Value) -> Value raise PyException {
  match a {
    Int(i) => Int(if i < 0L { checked_neg(i) } else { i })
    Bool(b) => Int(if b { 1L } else { 0L })
    Float(d) => Float(d.abs())
    TimeDelta(td) => if td.days < 0L { py_neg(a) } else { a }
    _ => raise type_error("bad operand type for abs(): '\{a.type_name()}'")
  }
}

///|
/// Python `int(x)`.
pub fn py_int(v : Value) -> Value raise PyException {
  match v {
    Int(_) => v
    Bool(b) => Int(if b { 1L } else { 0L })
    Float(d) => {
      if d.is_nan() {
        raise value_error("cannot convert float NaN to integer")
      }
      if d.is_inf() {
        raise PyException(
          "OverflowError", "cannot convert float infinity to integer",
        )
      }
      Int(float_to_int64(d))
    }
    Str(s) =>
      match parse_py_int_literal(s) {
        Some(i) => Int(i)
        None if @core.is_int_str(s) =>
          raise int64_overflow("int(\{@core.py_repr_str(s)})")
        None =>
          raise value_error(
            "invalid literal for int() with base 10: \{@core.py_repr_str(s)}",
          )
      }
    _ =>
      raise type_error(
        "int() argument must be a string, a bytes-like object or a real number, not '\{v.type_name()}'",
      )
  }
}

///|
fn py_strip_ws(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  let mut j = chars.length()
  while i < j && @core.is_space(chars[i]) {
    i += 1
  }
  while j > i && @core.is_space(chars[j - 1]) {
    j -= 1
  }
  String::from_array(chars[i:j].to_array())
}

///|
/// Python `float(x)`.
pub fn py_float(v : Value) -> Value raise PyException {
  match v {
    Float(_) => v
    Int(i) => Float(i.to_double())
    Bool(b) => Float(if b { 1.0 } else { 0.0 })
    Str(s) =>
      match parse_py_float_literal(s) {
        Some(d) => Float(d)
        None =>
          raise value_error(
            "could not convert string to float: \{@core.py_repr_str(s)}",
          )
      }
    _ =>
      raise type_error(
        "float() argument must be a string or a real number, not '\{v.type_name()}'",
      )
  }
}

///|
fn parse_py_float_literal(s : String) -> Double? {
  let t = py_strip_ws(s)
  let lower = @core.py_lower(t)
  let (sign, body) = if lower.has_prefix("-") {
    (-1.0, lower.substring(start=1))
  } else if lower.has_prefix("+") {
    (1.0, lower.substring(start=1))
  } else {
    (1.0, lower)
  }
  if body == "inf" || body == "infinity" {
    return Some(sign * @double.infinity)
  }
  if body == "nan" {
    return Some(@double.not_a_number)
  }
  // validate: digits [. digits] [e [sign] digits], underscores between digits
  let chars = body.to_array()
  let clean = StringBuilder()
  let mut i = 0
  let mut digits = 0
  let mut seen_dot = false
  let mut seen_e = false
  while i < chars.length() {
    let c = chars[i]
    if c >= '0' && c <= '9' {
      digits += 1
      clean.write_char(c)
    } else if c == '_' {
      let ok = i > 0 &&
        i + 1 < chars.length() &&
        chars[i - 1] >= '0' &&
        chars[i - 1] <= '9' &&
        chars[i + 1] >= '0' &&
        chars[i + 1] <= '9'
      if !ok {
        return None
      }
    } else if c == '.' && !seen_dot && !seen_e {
      seen_dot = true
      clean.write_char(c)
    } else if c == 'e' && !seen_e && digits > 0 {
      seen_e = true
      clean.write_char(c)
      if i + 1 < chars.length() && (chars[i + 1] == '+' || chars[i + 1] == '-') {
        clean.write_char(chars[i + 1])
        i += 1
      }
      if i + 1 >= chars.length() {
        return None
      }
    } else {
      return None
    }
    i += 1
  }
  if digits == 0 {
    return None
  }
  let d = @string.parse_double(clean.to_string()) catch { _ => return None }
  Some(sign * d)
}

///|
/// Python `round(x, ndigits)`; `ndigits=None` rounds to an integer.
pub fn py_round(x : Value, ndigits : Value) -> Value raise PyException {
  match (x, ndigits) {
    (Int(_) | Bool(_), Null) => Int(as_int(x).unwrap())
    (Int(_) | Bool(_), Int(_) | Bool(_)) => {
      let i = as_int(x).unwrap()
      let n = as_int(ndigits).unwrap()
      if n >= 0L {
        return Int(i)
      }
      if n < -18L {
        return Int(0L)
      }
      let mut p = 1L
      for _ in 0L..<-n {
        p = p * 10L
      }
      let q = floor_div64(i, p)
      let r = i - q * p
      let twice = r * 2L
      let q = if twice > p || (twice == p && q % 2L != 0L) { q + 1L } else { q }
      Int(q * p)
    }
    (Float(d), Null) => {
      if d.is_nan() {
        raise value_error("cannot convert float NaN to integer")
      }
      if d.is_inf() {
        raise PyException(
          "OverflowError", "cannot convert float infinity to integer",
        )
      }
      Int(round_half_even(d).to_int64())
    }
    (Float(d), Int(_) | Bool(_)) =>
      Float(round_float_digits(d, as_int(ndigits).unwrap().to_int()))
    (_, Null | Int(_) | Bool(_)) =>
      raise type_error("type \{x.type_name()} doesn't define __round__ method")
    _ =>
      raise type_error(
        "'\{ndigits.type_name()}' object cannot be interpreted as an integer",
      )
  }
}

///|
/// Correctly rounded `round(d, n)` (half to even on the exact binary value).
fn round_float_digits(d : Double, n : Int) -> Double {
  if d.is_nan() || d.is_inf() || d == 0.0 {
    return d
  }
  if n > 330 {
    return d
  }
  if n < -330 {
    return 0.0 * d
  }
  let bits = d.reinterpret_as_uint64()
  let negative = bits >> 63 != 0UL
  let exp_bits = ((bits >> 52) & 0x7ffUL).to_int()
  let frac = bits & 0xfffffffffffffUL
  let (mant, e) = if exp_bits == 0 {
    (frac, -1074)
  } else {
    (frac | 0x10000000000000UL, exp_bits - 1075)
  }
  // value = mant * 2^e; compute round(value * 10^n) half-even
  let m = @bigint.BigInt::from_uint64(mant)
  let ten = @bigint.BigInt::from_int(10)
  let p10 = ten.pow(@bigint.BigInt::from_int(if n >= 0 { n } else { -n }))
  let (num, den) = if n >= 0 {
    if e >= 0 {
      (m.mul(p10).shl(e), @bigint.BigInt::from_int(1))
    } else {
      (m.mul(p10), @bigint.BigInt::from_int(1).shl(-e))
    }
  } else if e >= 0 {
    (m.shl(e), p10)
  } else {
    (m, p10.shl(-e))
  }
  let q = num.div(den)
  let r = num.sub(q.mul(den))
  let twice = r.shl(1)
  let c = twice.compare(den)
  let one = @bigint.BigInt::from_int(1)
  let two = @bigint.BigInt::from_int(2)
  let q = if c > 0 || (c == 0 && !q.mod(two).is_zero()) {
    q.add(one)
  } else {
    q
  }
  // result = q / 10^n
  let s = q.to_string()
  let text = if n >= 0 {
    s + "e-" + n.to_string()
  } else {
    s + "e" + (-n).to_string()
  }
  let r = @string.parse_double(text) catch { _ => 0.0 }
  if negative {
    -r
  } else {
    r
  }
}
