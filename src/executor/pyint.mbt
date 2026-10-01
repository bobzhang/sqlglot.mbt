// Checked Int64 arithmetic for Python ints.
//
// Python ints are unbounded while the executor's `Value::Int` is an Int64. Rather than
// wrapping silently, every integer operation whose exact result falls outside Int64
// raises `int64_overflow` (an `OverflowError` whose message names the Int64 limit).

///|
let int64_min : Int64 = -9223372036854775807L - 1L

///|
/// The error for an integer result outside the Int64 range.
fn int64_overflow(what : String) -> PyException {
  PyException(
    "OverflowError",
    "integer result of \{what} is outside the Int64 range supported by this port (Python ints are unbounded)",
  )
}

///|
fn checked_add(x : Int64, y : Int64) -> Int64 raise PyException {
  let r = x + y
  if ((x ^ r) & (y ^ r)) < 0L {
    raise int64_overflow("\{x} + \{y}")
  }
  r
}

///|
fn checked_sub(x : Int64, y : Int64) -> Int64 raise PyException {
  let r = x - y
  if ((x ^ y) & (x ^ r)) < 0L {
    raise int64_overflow("\{x} - \{y}")
  }
  r
}

///|
fn checked_mul(x : Int64, y : Int64) -> Int64 raise PyException {
  if x == 0L || y == 0L {
    return 0L
  }
  if (x == -1L && y == int64_min) || (y == -1L && x == int64_min) {
    raise int64_overflow("\{x} * \{y}")
  }
  let r = x * y
  if r / y != x {
    raise int64_overflow("\{x} * \{y}")
  }
  r
}

///|
fn checked_neg(x : Int64) -> Int64 raise PyException {
  if x == int64_min {
    raise int64_overflow("-(\{x})")
  }
  -x
}

///|
/// `x // y` (floor division) for `y != 0`.
fn checked_floordiv(x : Int64, y : Int64) -> Int64 raise PyException {
  if y == -1L {
    return checked_neg(x)
  }
  floor_div64(x, y)
}

///|
/// `x % y` (sign of the divisor) for `y != 0`.
fn py_mod64(x : Int64, y : Int64) -> Int64 {
  if y == -1L {
    return 0L
  }
  x - floor_div64(x, y) * y
}

///|
/// `x << y` for `y >= 0`.
fn checked_shl(x : Int64, y : Int64) -> Int64 raise PyException {
  if x == 0L {
    return 0L
  }
  if y >= 63L {
    raise int64_overflow("\{x} << \{y}")
  }
  let r = x << y.to_int()
  if r >> y.to_int() != x {
    raise int64_overflow("\{x} << \{y}")
  }
  r
}

///|
/// `x ** y` for `y >= 0`.
fn checked_pow(x : Int64, y : Int64) -> Int64 raise PyException {
  let mut r = 1L
  let mut base = x
  let mut e = y
  while e > 0L {
    if e % 2L == 1L {
      r = checked_mul(r, base) catch {
        _ => raise int64_overflow("\{x} ** \{y}")
      }
    }
    e = e / 2L
    if e > 0L {
      base = checked_mul(base, base) catch {
        _ => raise int64_overflow("\{x} ** \{y}")
      }
    }
  }
  r
}

///|
/// Python `int(d)` for a finite float, if it fits Int64.
fn float_to_int64(d : Double) -> Int64 raise PyException {
  let t = d.trunc()
  // 2**63 is exactly representable; Int64 covers [-2**63, 2**63)
  if t >= 9223372036854775808.0 || t < -9223372036854775808.0 {
    raise int64_overflow("int(\{float_repr(d)})")
  }
  t.to_int64()
}

///|
/// `int(s)` parsing (base 10; Python's rules for signs, `_` separators, white space and
/// Unicode digits); `None` if `s` isn't an integer literal or doesn't fit Int64.
fn parse_py_int_literal(s : String) -> Int64? {
  if @core.is_int_str(s) {
    @core.parse_int_str(s)
  } else {
    None
  }
}

///|
/// `a + b`, saturated to the Int64 range (for LIMIT/OFFSET bounds, which only matter up
/// to the number of rows).
fn sat_add64(a : Int64, b : Int64) -> Int64 {
  let r = a + b
  if ((a ^ r) & (b ^ r)) < 0L {
    if a < 0L {
      int64_min
    } else {
      9223372036854775807L
    }
  } else {
    r
  }
}

///|
/// `v` clamped to the Int range: slicing a row list by a bound beyond Int behaves like
/// slicing by the clamped bound.
fn clamp_int(v : Int64) -> Int {
  if v > 2147483647L {
    2147483647
  } else if v < -2147483648L {
    -2147483648
  } else {
    v.to_int()
  }
}
