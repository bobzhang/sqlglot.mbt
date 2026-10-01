// Python builtins used by aggregations: `sum`, `math.fsum`, `max`, `min` and the
// iteration order of `set`.

///|
/// Python 3.12+ `sum(values)` (start 0): exact integer accumulation, then Neumaier
/// compensated summation once a float is seen.
pub fn py_sum(values : Array[Value]) -> Value raise PyException {
  let mut i = 0
  let n = values.length()
  let mut int_result = 0L
  let mut result : Value = Int(0L)
  let mut in_int = true
  // integer fast path; intermediate sums may leave Int64 (Python ints are unbounded),
  // so overflow switches to a big integer accumulator and only the result must fit
  let mut big_result : @bigint.BigInt? = None
  while i < n && in_int {
    match values[i] {
      Int(_) | Bool(_) => {
        let x = as_int(values[i]).unwrap()
        match big_result {
          Some(b) => big_result = Some(b + @bigint.BigInt::from_int64(x))
          None => {
            let r = int_result + x
            if ((int_result ^ r) & (x ^ r)) < 0L {
              big_result = Some(
                @bigint.BigInt::from_int64(int_result) +
                @bigint.BigInt::from_int64(x),
              )
            } else {
              int_result = r
            }
          }
        }
        i += 1
      }
      _ => in_int = false
    }
  }
  if big_result is Some(b) {
    let lo = @bigint.BigInt::from_int64(int64_min)
    let hi = @bigint.BigInt::from_int64(9223372036854775807L)
    if b < lo || b > hi {
      raise int64_overflow("sum(...)")
    }
    int_result = b.to_int64()
  }
  result = Int(int_result)
  if i == n {
    return result
  }
  // the first non-int item: generic addition
  result = py_add(result, values[i])
  i += 1
  while i < n {
    match result {
      Float(start) => {
        let mut f = start
        let mut c = 0.0
        let mut fallback = false
        while i < n && !fallback {
          match values[i] {
            Float(x) => {
              let t = f + x
              if f.abs() >= x.abs() {
                c += f - t + x
              } else {
                c += x - t + f
              }
              f = t
              i += 1
            }
            Int(_) | Bool(_) => {
              f += as_int(values[i]).unwrap().to_double()
              i += 1
            }
            _ => fallback = true
          }
        }
        if c != 0.0 && !c.is_inf() && !c.is_nan() {
          f += c
        }
        result = Float(f)
        if fallback {
          result = py_add(result, values[i])
          i += 1
        }
      }
      _ => {
        result = py_add(result, values[i])
        i += 1
      }
    }
  }
  result
}

///|
/// Python `math.fsum(values)` (Shewchuk's exactly rounded summation, as in CPython).
pub fn py_fsum(values : Array[Value]) -> Double raise PyException {
  let partials : Array[Double] = []
  let mut special_sum = 0.0
  let mut inf_sum = 0.0
  for v in values {
    let x = match v {
      Float(d) => d
      Int(i) => i.to_double()
      Bool(b) => if b { 1.0 } else { 0.0 }
      _ => raise type_error("must be real number, not \{v.type_name()}")
    }
    let mut x = x
    let xsave = x
    let mut i = 0
    for j in 0..<partials.length() {
      let mut y = partials[j]
      if x.abs() < y.abs() {
        let t = x
        x = y
        y = t
      }
      let hi = x + y
      let lo = y - (hi - x)
      if lo != 0.0 {
        partials[i] = lo
        i += 1
      }
      x = hi
    }
    if x.is_nan() || x.is_inf() {
      if xsave.is_inf() {
        inf_sum += xsave
      }
      special_sum += xsave
      partials.truncate(0)
    } else {
      partials.truncate(i)
      partials.push(x)
    }
  }
  if special_sum != 0.0 {
    if inf_sum.is_nan() {
      raise value_error("-inf + inf in fsum")
    }
    return special_sum
  }
  let mut hi = 0.0
  let mut n = partials.length()
  if n > 0 {
    n -= 1
    hi = partials[n]
    let mut lo = 0.0
    while n > 0 {
      let x = hi
      n -= 1
      let y = partials[n]
      hi = x + y
      let yr = hi - x
      lo = y - yr
      if lo != 0.0 {
        break
      }
    }
    if n > 0 &&
      (
        (lo < 0.0 && partials[n - 1] < 0.0) ||
        (lo > 0.0 && partials[n - 1] > 0.0)
      ) {
      let y = lo * 2.0
      let x = hi + y
      let yr = x - hi
      if y == yr {
        hi = x
      }
    }
  }
  hi
}

///|
/// Python `max(values)` (the first maximal item wins).
pub fn py_max(values : Array[Value]) -> Value raise PyException {
  if values.is_empty() {
    raise value_error("max() iterable argument is empty")
  }
  let mut best = values[0]
  for i in 1..<values.length() {
    if py_gt(values[i], best) {
      best = values[i]
    }
  }
  best
}

///|
/// Python `min(values)` (the first minimal item wins).
pub fn py_min(values : Array[Value]) -> Value raise PyException {
  if values.is_empty() {
    raise value_error("min() iterable argument is empty")
  }
  let mut best = values[0]
  for i in 1..<values.length() {
    if py_lt(values[i], best) {
      best = values[i]
    }
  }
  best
}

// ---- hashing ----

///|
/// A key that identifies a hashable value up to Python equality (e.g. `1`, `1.0` and
/// `True` share a key). Raises `TypeError` for unhashable values.
pub fn hash_key(v : Value) -> String raise PyException {
  let sb = StringBuilder()
  write_hash_key(sb, v)
  sb.to_string()
}

///|
fn write_hash_key(sb : StringBuilder, v : Value) -> Unit raise PyException {
  match v {
    Null => sb.write_string("N;")
    Bool(b) => sb.write_string(if b { "i1;" } else { "i0;" })
    Int(i) => sb.write_string("i\{i};")
    Float(d) =>
      if d == d.floor() && d.abs() < 9.2e18 {
        sb.write_string("i\{d.to_int64()};")
      } else {
        sb.write_string("f\{d.reinterpret_as_uint64()};")
      }
    Str(s) => {
      sb.write_string("s\{s.length()}:")
      sb.write_string(s)
    }
    Tuple(items) => {
      sb.write_string("t\{items.length()}(")
      for x in items {
        write_hash_key(sb, x)
      }
      sb.write_string(")")
    }
    Date(d) => sb.write_string("d\{d.toordinal()};")
    Time(t) => sb.write_string("T\{t.total_us()};")
    DateTime(dt) =>
      match dt.tz {
        None => sb.write_string("D\{dt.total_us()};")
        Some(_) => sb.write_string("Z\{dt.utc_us()};")
      }
    TimeDelta(td) => sb.write_string("td\{td.total_us()};")
    DTypeV(t) => sb.write_string("ty\{t.name()};")
    _ => raise type_error("unhashable type: '\{v.type_name()}'")
  }
}

///|
let hash_modulus : UInt64 = (1UL << 61) - 1UL

///|
/// CPython `_Py_HashDouble`.
fn hash_double(v : Double) -> Int64 {
  if v.is_inf() {
    return if v > 0.0 { 314159L } else { -314159L }
  }
  if v.is_nan() {
    return 0L
  }
  let (m0, e0) = frexp(v)
  let mut m = m0
  let mut e = e0
  let mut sign = 1L
  if m < 0.0 {
    sign = -1L
    m = -m
  }
  let mut x = 0UL
  while m != 0.0 {
    x = ((x << 28) & hash_modulus) | (x >> (61 - 28))
    m = m * 268435456.0
    e -= 28
    let y = m.to_int64().reinterpret_as_uint64()
    m = m - y.to_double()
    x = x + y
    if x >= hash_modulus {
      x = x - hash_modulus
    }
  }
  let e = if e >= 0 { e % 61 } else { 61 - 1 - (-1 - e) % 61 }
  x = ((x << e) & hash_modulus) | (x >> (61 - e))
  let r = x.reinterpret_as_int64() * sign
  if r == -1L {
    -2L
  } else {
    r
  }
}

///|
/// C `frexp`: v = m * 2^e with 0.5 <= |m| < 1.
fn frexp(v : Double) -> (Double, Int) {
  if v == 0.0 {
    return (v, 0)
  }
  let bits = v.reinterpret_as_uint64()
  let exp = ((bits >> 52) & 0x7ffUL).to_int()
  if exp == 0 {
    // subnormal: scale up
    let (m, e) = frexp(v * 18014398509481984.0) // 2^54
    return (m, e - 54)
  }
  let e = exp - 1022
  let mbits = (bits & 0x800fffffffffffffUL) | (1022UL << 52)
  (mbits.reinterpret_as_double(), e)
}
