// Python `repr(float)` (`str.upper()`/`str.lower()` are `@core.py_upper`/`@core.py_lower`).

///|
/// Python `repr(float)`: the shortest round-tripping digits, in scientific notation when
/// the decimal exponent is < -4 or >= 16.
pub fn float_repr(d : Double) -> String {
  @core.py_float_repr(d)
}
