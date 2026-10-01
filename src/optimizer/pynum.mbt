// Python numbers as produced by `Literal.to_py()`: arbitrary precision ints and
// `decimal.Decimal`s (default context: 28 digits, ROUND_HALF_EVEN).

///|
/// A Python decimal: `(-1)^neg * coeff * 10^exp`.
priv struct Dec {
  neg : Bool
  coeff : @bigint.BigInt
  exp : Int
}

///|
priv enum PyNum {
  PInt(@bigint.BigInt)
  PDec(Dec)
}

///|
let decimal_prec : Int = 28

///|
fn big(i : Int) -> @bigint.BigInt {
  @bigint.BigInt::from_int(i)
}

///|
fn pow10(n : Int) -> @bigint.BigInt {
  let mut r = big(1)
  let ten = big(10)
  for _ in 0..<n {
    r = r * ten
  }
  r
}

///|
fn big_abs(x : @bigint.BigInt) -> @bigint.BigInt {
  if x < big(0) {
    -x
  } else {
    x
  }
}

///|
fn num_digits(x : @bigint.BigInt) -> Int {
  big_abs(x).to_string().length()
}

///|
/// Python `int(text)`.
fn parse_py_int(text : String) -> @bigint.BigInt? {
  let t = @core.py_strip(text).replace_all(old="_", new="")
  let mut s = t
  let mut neg = false
  if s.has_prefix("+") || s.has_prefix("-") {
    neg = s.has_prefix("-")
    s = s.unsafe_substring(start=1, end=s.length())
  }
  if s.is_empty() {
    return None
  }
  for c in s {
    if c < '0' || c > '9' {
      return None
    }
  }
  let v = @bigint.BigInt::from_string(s)
  Some(if neg { -v } else { v })
}

///|
/// Python `Decimal(text)`.
fn parse_decimal(text : String) -> Dec? {
  let s = @core.py_strip(text).replace_all(old="_", new="").to_array()
  let mut i = 0
  let mut neg = false
  if i < s.length() && (s[i] == '+' || s[i] == '-') {
    neg = s[i] == '-'
    i += 1
  }
  let digits = StringBuilder::new()
  let mut frac = 0
  let mut seen_digit = false
  while i < s.length() && s[i] >= '0' && s[i] <= '9' {
    digits.write_char(s[i])
    seen_digit = true
    i += 1
  }
  if i < s.length() && s[i] == '.' {
    i += 1
    while i < s.length() && s[i] >= '0' && s[i] <= '9' {
      digits.write_char(s[i])
      frac += 1
      seen_digit = true
      i += 1
    }
  }
  if !seen_digit {
    return None
  }
  let mut exp = 0
  if i < s.length() && (s[i] == 'e' || s[i] == 'E') {
    i += 1
    let mut eneg = false
    if i < s.length() && (s[i] == '+' || s[i] == '-') {
      eneg = s[i] == '-'
      i += 1
    }
    let start = i
    while i < s.length() && s[i] >= '0' && s[i] <= '9' {
      exp = exp * 10 + (s[i].to_int() - '0'.to_int())
      i += 1
    }
    if i == start {
      return None
    }
    if eneg {
      exp = -exp
    }
  }
  if i != s.length() {
    return None
  }
  Some({
    neg,
    coeff: @bigint.BigInt::from_string(digits.to_string()),
    exp: exp - frac,
  })
}

///|
/// `Literal.to_py()` / `Neg.to_py()` for number literals.
fn expr_to_pynum(e : @core.Expr) -> PyNum? {
  match e.kind {
    Literal =>
      if e.is_number() {
        let text = e.text("this")
        match parse_py_int(text) {
          Some(i) => Some(PInt(i))
          None => parse_decimal(text).map(d => PDec(d))
        }
      } else {
        None
      }
    Neg =>
      match e.this() {
        Some(t) if e.is_number() => expr_to_pynum(t).map(n => n.neg())
        _ => None
      }
    _ => None
  }
}

///|
fn PyNum::neg(self : PyNum) -> PyNum {
  match self {
    PInt(i) => PInt(-i)
    PDec(d) => PDec({ ..d, neg: !d.neg }).fix()
  }
}

///|
fn PyNum::to_dec(self : PyNum) -> Dec {
  match self {
    PInt(i) => { neg: i < big(0), coeff: big_abs(i), exp: 0 }
    PDec(d) => d
  }
}

///|
fn PyNum::fix(self : PyNum) -> PyNum {
  match self {
    PDec(d) => PDec(d.fix())
    i => i
  }
}

///|
/// Rounds to the context precision (ROUND_HALF_EVEN).
fn Dec::fix(self : Dec) -> Dec {
  let digits = num_digits(self.coeff)
  if digits <= decimal_prec {
    return self
  }
  let drop = digits - decimal_prec
  let p = pow10(drop)
  let mut q = self.coeff / p
  let rem = self.coeff - q * p
  let twice = rem * big(2)
  if twice > p || (twice == p && q % big(2) != big(0)) {
    q = q + big(1)
  }
  let mut exp = self.exp + drop
  if num_digits(q) > decimal_prec {
    q = q / big(10)
    exp += 1
  }
  { neg: self.neg, coeff: q, exp }
}

///|
fn Dec::signed(self : Dec) -> @bigint.BigInt {
  if self.neg {
    -self.coeff
  } else {
    self.coeff
  }
}

///|
fn dec_from_signed(v : @bigint.BigInt, exp : Int, zero_neg : Bool) -> Dec {
  if v == big(0) {
    { neg: zero_neg, coeff: big(0), exp }
  } else {
    { neg: v < big(0), coeff: big_abs(v), exp }
  }
}

///|
fn dec_add(a : Dec, b : Dec) -> Dec {
  let exp = @core.min_int(a.exp, b.exp)
  let va = a.signed() * pow10(a.exp - exp)
  let vb = b.signed() * pow10(b.exp - exp)
  let zero_neg = a.neg && b.neg && a.coeff == big(0) && b.coeff == big(0)
  dec_from_signed(va + vb, exp, zero_neg).fix()
}

///|
fn dec_mul(a : Dec, b : Dec) -> Dec {
  { neg: a.neg != b.neg, coeff: a.coeff * b.coeff, exp: a.exp + b.exp }.fix()
}

///|
fn dec_div(a : Dec, b : Dec) -> Dec raise @core.SqlglotError {
  if b.coeff == big(0) {
    raise @core.ValueError("decimal.DivisionByZero")
  }
  let sign = a.neg != b.neg
  if a.coeff == big(0) {
    return { neg: sign, coeff: big(0), exp: a.exp - b.exp }.fix()
  }
  let shift = num_digits(b.coeff) - num_digits(a.coeff) + decimal_prec + 1
  let mut exp = a.exp - b.exp - shift
  let (coeff0, remainder) = if shift >= 0 {
    let n = a.coeff * pow10(shift)
    let q = n / b.coeff
    (q, n - q * b.coeff)
  } else {
    let d = b.coeff * pow10(-shift)
    let q = a.coeff / d
    (q, a.coeff - q * d)
  }
  let mut coeff = coeff0
  if remainder != big(0) {
    if coeff % big(5) == big(0) {
      coeff = coeff + big(1)
    }
  } else {
    let ideal_exp = a.exp - b.exp
    while exp < ideal_exp && coeff % big(10) == big(0) {
      coeff = coeff / big(10)
      exp += 1
    }
  }
  { neg: sign, coeff, exp }.fix()
}

///|
fn pynum_add(a : PyNum, b : PyNum) -> PyNum {
  match (a, b) {
    (PInt(x), PInt(y)) => PInt(x + y)
    _ => PDec(dec_add(a.to_dec(), b.to_dec()))
  }
}

///|
fn pynum_sub(a : PyNum, b : PyNum) -> PyNum {
  match (a, b) {
    (PInt(x), PInt(y)) => PInt(x - y)
    _ => {
      let bd = b.to_dec()
      PDec(dec_add(a.to_dec(), { ..bd, neg: !bd.neg }))
    }
  }
}

///|
fn pynum_mul(a : PyNum, b : PyNum) -> PyNum {
  match (a, b) {
    (PInt(x), PInt(y)) => PInt(x * y)
    _ => PDec(dec_mul(a.to_dec(), b.to_dec()))
  }
}

///|
fn pynum_div(a : PyNum, b : PyNum) -> PyNum raise @core.SqlglotError {
  PDec(dec_div(a.to_dec(), b.to_dec()))
}

///|
/// Numeric comparison: -1, 0 or 1.
fn pynum_cmp(a : PyNum, b : PyNum) -> Int {
  let x = a.to_dec()
  let y = b.to_dec()
  let exp = @core.min_int(x.exp, y.exp)
  let vx = x.signed() * pow10(x.exp - exp)
  let vy = y.signed() * pow10(y.exp - exp)
  vx.compare(vy)
}

///|
fn PyNum::is_zero(self : PyNum) -> Bool {
  match self {
    PInt(i) => i == big(0)
    PDec(d) => d.coeff == big(0)
  }
}

///|
fn PyNum::is_negative(self : PyNum) -> Bool {
  match self {
    PInt(i) => i < big(0)
    PDec(d) => d.neg && d.coeff != big(0)
  }
}

///|
fn PyNum::is_int(self : PyNum) -> Bool {
  self is PInt(_)
}

///|
/// Python `str(number)`.
fn PyNum::to_py_string(self : PyNum) -> String {
  match self {
    PInt(i) => i.to_string()
    PDec(d) => d.to_py_string()
  }
}

///|
/// Python `str(Decimal)` (to-scientific-string).
fn Dec::to_py_string(self : Dec) -> String {
  let sign = if self.neg { "-" } else { "" }
  let coeff = self.coeff.to_string()
  let exp = self.exp
  let leftdigits = exp + coeff.length()
  let dotplace = if exp <= 0 && leftdigits > -6 { leftdigits } else { 1 }
  let (intpart, fracpart) = if dotplace <= 0 {
    ("0", "." + "0".repeat(-dotplace) + coeff)
  } else if dotplace >= coeff.length() {
    (coeff + "0".repeat(dotplace - coeff.length()), "")
  } else {
    (
      coeff.unsafe_substring(start=0, end=dotplace),
      "." + coeff.unsafe_substring(start=dotplace, end=coeff.length()),
    )
  }
  let exp_str = if leftdigits == dotplace {
    ""
  } else {
    let e = leftdigits - dotplace
    if e >= 0 {
      "E+\{e}"
    } else {
      "E\{e}"
    }
  }
  sign + intpart + fracpart + exp_str
}

///|
/// Python `exp.Literal.number(number)`.
fn literal_from_pynum(n : PyNum) -> @core.Expr {
  let text = n.to_py_string()
  if n.is_negative() {
    let abs_text = n.neg().to_py_string()
    @core.mk1(Neg, @core.mk(Literal, [("this", abs_text), ("is_string", false)]))
  } else {
    @core.mk(Literal, [("this", text), ("is_string", false)])
  }
}
