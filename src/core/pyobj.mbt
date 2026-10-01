// Host ("Python") values accepted by the builder API, and the conversions between them and
// expressions: `maybe_parse`, `convert`, `Expr.to_py` and `Expr.__repr__` (port of the
// corresponding helpers in sqlglot/expressions/core.py).

///|
/// A host value, mirroring the Python objects that sqlglot's builder API accepts
/// (`ExpOrStr`, and the values understood by `exp.convert`).
pub(all) enum PyObj {
  PyExpr(Expr)
  PyStr(String)
  PyInt(Int64)
  PyFloat(Double)
  /// A `decimal.Decimal`, kept in its textual form.
  PyDecimal(String)
  PyBool(Bool)
  PyNone
  PyTuple(Array[PyObj])
  PyList(Array[PyObj])
  PyDict(Array[(PyObj, PyObj)])
  PyBytes(Bytes)
  /// An object with named attributes (a namedtuple or an object with a `__dict__`).
  PyObject(Array[(String, PyObj)])
  /// A `datetime.date`.
  PyDate(year~ : Int, month~ : Int, day~ : Int)
  /// A `datetime.time`.
  PyTime(hour~ : Int, minute~ : Int, second~ : Int, microsecond~ : Int)
  /// A `datetime.datetime`; `tz` is the time zone name (`str(tzinfo)`) and its UTC offset
  /// in minutes, for aware datetimes.
  PyDateTime(
    year~ : Int,
    month~ : Int,
    day~ : Int,
    hour~ : Int,
    minute~ : Int,
    second~ : Int,
    microsecond~ : Int,
    tz~ : (String, Int)?
  )
} derive(Eq)

///|
#deprecated
pub extend PyObj with Eq::{not_equal, equal}

///|
fn pad_int(n : Int, width : Int) -> String {
  let s = n.abs().to_string()
  let s = if s.length() < width {
    "0".repeat(width - s.length()) + s
  } else {
    s
  }
  if n < 0 {
    "-" + s
  } else {
    s
  }
}

///|
/// Python `date.isoformat()`.
fn iso_date(year : Int, month : Int, day : Int) -> String {
  "\{pad_int(year, 4)}-\{pad_int(month, 2)}-\{pad_int(day, 2)}"
}

///|
/// Python `time.isoformat()` (without a time zone).
fn iso_time(
  hour : Int,
  minute : Int,
  second : Int,
  microsecond : Int,
) -> String {
  let base = "\{pad_int(hour, 2)}:\{pad_int(minute, 2)}:\{pad_int(second, 2)}"
  if microsecond != 0 {
    base + "." + pad_int(microsecond, 6)
  } else {
    base
  }
}

///|
/// Python `datetime.isoformat(sep=" ")`.
fn iso_datetime(
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
  microsecond : Int,
  tz : (String, Int)?,
) -> String {
  let base = iso_date(year, month, day) +
    " " +
    iso_time(hour, minute, second, microsecond)
  match tz {
    Some((_, offset)) => {
      let sign = if offset < 0 { "-" } else { "+" }
      let o = offset.abs()
      base + sign + pad_int(o / 60, 2) + ":" + pad_int(o % 60, 2)
    }
    None => base
  }
}

///|
/// Conversion of MoonBit values into host values (`PyObj`).
pub(open) trait IntoPy {
  fn into_py(Self) -> PyObj
}

///|
pub impl IntoPy for PyObj with fn into_py(self) {
  self
}

///|
#deprecated
pub extend PyObj with IntoPy::{into_py}

///|
pub impl IntoPy for Expr with fn into_py(self) {
  PyExpr(self)
}

///|
#deprecated
pub extend Expr with IntoPy::{into_py}

///|
pub impl IntoPy for String with fn into_py(self) {
  PyStr(self)
}

///|
pub impl IntoPy for Int with fn into_py(self) {
  PyInt(self.to_int64())
}

///|
pub impl IntoPy for Int64 with fn into_py(self) {
  PyInt(self)
}

///|
pub impl IntoPy for Double with fn into_py(self) {
  PyFloat(self)
}

///|
pub impl IntoPy for Bool with fn into_py(self) {
  PyBool(self)
}

///|
pub impl IntoPy for Bytes with fn into_py(self) {
  PyBytes(self)
}

///|
pub impl[T : IntoPy] IntoPy for T? with fn into_py(self) {
  match self {
    Some(x) => x.into_py()
    None => PyNone
  }
}

///|
pub impl[T : IntoPy] IntoPy for Array[T] with fn into_py(self) {
  PyList(self.map(x => x.into_py()))
}

///|
pub impl[V : IntoPy] IntoPy for Map[String, V] with fn into_py(self) {
  PyDict(self.iter().map(kv => (PyStr(kv.0), kv.1.into_py())).collect())
}

///|
/// Python `repr(float)`.
pub fn py_float_repr(d : Double) -> String {
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
      let m = s.view(end_offset=i).to_owned()
      let e = s.view(start_offset=i + 1).to_owned()
      let e = if e.has_prefix("+") {
        e.view(start_offset=1).to_owned()
      } else {
        e
      }
      (m, parse_int_str(e).map(x => x.to_int()).unwrap_or(0))
    }
    None => (s, 0)
  }
  let (int_part, frac_part) = match mantissa.find(".") {
    Some(i) =>
      (
        mantissa.view(end_offset=i).to_owned(),
        mantissa.view(start_offset=i + 1).to_owned(),
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
  digits = digits.view(start_offset=lead).to_owned()
  decpt -= lead
  // strip trailing zeros
  let mut end = digits.length()
  while end > 1 && digits[end - 1] == '0' {
    end -= 1
  }
  digits = digits.view(end_offset=end).to_owned()
  let sign = if d < 0.0 { "-" } else { "" }
  let n = digits.length()
  if decpt <= -4 || decpt > 16 {
    let e = decpt - 1
    let mant = if n == 1 {
      digits
    } else {
      digits.view(end_offset=1).to_owned() +
      "." +
      digits.view(start_offset=1).to_owned()
    }
    let es = e.abs().to_string()
    let es = if es.length() < 2 { "0" + es } else { es }
    sign + mant + "e" + (if e < 0 { "-" } else { "+" }) + es
  } else if decpt <= 0 {
    sign + "0." + "0".repeat(-decpt) + digits
  } else if decpt >= n {
    sign + digits + "0".repeat(decpt - n) + ".0"
  } else {
    sign +
    digits.view(end_offset=decpt).to_owned() +
    "." +
    digits.view(start_offset=decpt).to_owned()
  }
}

///|
/// Python `str(value)` for a host value.
pub fn PyObj::py_str(self : PyObj) -> String {
  match self {
    PyExpr(e) => e.to_s()
    PyStr(s) => s
    PyInt(i) => i.to_string()
    PyFloat(d) => py_float_repr(d)
    PyDecimal(s) => s
    PyBool(b) => if b { "True" } else { "False" }
    PyNone => "None"
    PyTuple(items) =>
      if items.length() == 1 {
        "(\{items[0].py_repr()},)"
      } else {
        "(" + items.map(x => x.py_repr()).join(", ") + ")"
      }
    PyList(items) => "[" + items.map(x => x.py_repr()).join(", ") + "]"
    PyDict(items) =>
      "{" +
      items.map(kv => "\{kv.0.py_repr()}: \{kv.1.py_repr()}").join(", ") +
      "}"
    PyBytes(b) => {
      let sb = StringBuilder()
      sb.write_string("b'")
      for byte in b {
        let c = byte.to_int()
        if c == '\\'.to_int() || c == '\''.to_int() {
          sb.write_char('\\')
          sb.write_char(Int::unsafe_to_char(c))
        } else if c >= 32 && c < 127 {
          sb.write_char(Int::unsafe_to_char(c))
        } else {
          let hex = "0123456789abcdef"
          sb.write_string("\\x")
          sb.write_char(hex.get_char(c / 16).unwrap())
          sb.write_char(hex.get_char(c % 16).unwrap())
        }
      }
      sb.write_char('\'')
      sb.to_string()
    }
    PyObject(fields) =>
      "(" + fields.map(kv => "\{kv.0}=\{kv.1.py_repr()}").join(", ") + ")"
    PyDate(year~, month~, day~) => iso_date(year, month, day)
    PyTime(hour~, minute~, second~, microsecond~) =>
      iso_time(hour, minute, second, microsecond)
    PyDateTime(year~, month~, day~, hour~, minute~, second~, microsecond~, tz~) =>
      iso_datetime(year, month, day, hour, minute, second, microsecond, tz)
  }
}

///|
/// Python `repr(value)` for a host value.
pub fn PyObj::py_repr(self : PyObj) -> String {
  match self {
    PyStr(s) => py_repr_str(s)
    PyDecimal(s) => "Decimal(\{py_repr_str(s)})"
    PyExpr(e) => e.to_s()
    _ => self.py_str()
  }
}

///|
/// Python `maybe_parse`: returns the given expression (copied if `copy`), or parses the
/// given SQL code (`str(sql_or_expression)`, optionally prefixed by `prefix`) into one of
/// the kinds `into`.
pub fn[T : IntoPy] maybe_parse(
  sql_or_expression : T,
  into? : ArrayView[Kind],
  dialect? : Dialect,
  prefix? : String,
  copy? : Bool = false,
  error_level? : ErrorLevel = Immediate,
) -> Expr raise SqlglotError {
  let obj = sql_or_expression.into_py()
  match obj {
    PyExpr(e) => return if copy { e.copy() } else { e }
    PyNone => raise ParseError("SQL cannot be None", [])
    _ => ()
  }
  let mut sql = obj.py_str()
  match prefix {
    Some(p) if !p.is_empty() => sql = "\{p} \{sql}"
    _ => ()
  }
  parse_one(sql, dialect?, into?=into.map(i => i.to_owned()), error_level~)
}

///|
/// Python `exp.convert`: converts a host value into an expression. Raises `ValueError`
/// when a conversion is not possible.
pub fn[T : IntoPy] convert(
  value : T,
  copy? : Bool = false,
) -> Expr raise SqlglotError {
  convert_obj(value.into_py(), copy~)
}

///|
fn convert_obj(value : PyObj, copy~ : Bool) -> Expr raise SqlglotError {
  match value {
    PyExpr(e) => maybe_copy(e, copy)
    PyStr(s) => literal_string(s)
    PyBool(b) => boolean(b)
    PyNone => null_()
    PyFloat(d) if d.is_nan() => null_()
    PyFloat(d) => literal_number(py_float_repr(d))
    PyInt(i) => literal_number(i.to_string())
    PyDecimal(s) => literal_number(s)
    PyBytes(b) => {
      let sb = StringBuilder()
      let hex = "0123456789abcdef"
      for byte in b {
        let c = byte.to_int()
        sb.write_char(hex.get_char(c / 16).unwrap())
        sb.write_char(hex.get_char(c % 16).unwrap())
      }
      mk1(HexString, sb.to_string())
    }
    PyDateTime(year~, month~, day~, hour~, minute~, second~, microsecond~, tz~) => {
      let datetime_literal = literal_string(
        iso_datetime(year, month, day, hour, minute, second, microsecond, tz),
      )
      let zone = tz.map(t => literal_string(t.0))
      mk(TimeStrToTime, [("this", datetime_literal), ("zone", zone)])
    }
    PyDate(year~, month~, day~) =>
      mk1(DateStrToDate, literal_string(iso_date(year, month, day)))
    PyTime(hour~, minute~, second~, microsecond~) =>
      mk1(
        TsOrDsToTime,
        literal_string(iso_time(hour, minute, second, microsecond)),
      )
    PyObject(fields) => {
      let exprs = []
      for kv in fields {
        exprs.push(
          mk(PropertyEQ, [
            ("this", to_identifier(kv.0)),
            ("expression", convert_obj(kv.1, copy~)),
          ]),
        )
      }
      mk(Struct, [("expressions", exprs)])
    }
    PyTuple(items) => {
      let exprs = []
      for v in items {
        exprs.push(convert_obj(v, copy~))
      }
      mk(Tuple, [("expressions", exprs)])
    }
    PyList(items) => {
      let exprs = []
      for v in items {
        exprs.push(convert_obj(v, copy~))
      }
      mk(Array, [("expressions", exprs)])
    }
    PyDict(items) => {
      let keys = []
      let values = []
      for kv in items {
        keys.push(convert_obj(kv.0, copy~))
        values.push(convert_obj(kv.1, copy~))
      }
      mk(Map, [
        ("keys", mk(Array, [("expressions", keys)])),
        ("values", mk(Array, [("expressions", values)])),
      ])
    }
  }
}

///|
/// Python `Expr.to_py()`: returns a host value equivalent of the SQL node. Raises
/// `ValueError` for nodes that can't be converted.
pub fn Expr::to_py(self : Expr) -> PyObj raise SqlglotError {
  match self.kind.owner_to_py() {
    Some(Literal) => {
      let this = self.text("this")
      if !self.is_number() {
        return PyStr(this)
      }
      // `int(this)` (Int64 only: larger ints raise `int64_range_error`), else
      // `Decimal(this)` (kept as `str(Decimal(this))`)
      match parse_int_checked(this) {
        Some(i) => PyInt(i)
        None =>
          if is_float_str(this) {
            PyDecimal(py_decimal_str(this))
          } else {
            raise ValueError("Invalid numeric literal: \{py_repr_str(this)}")
          }
      }
    }
    Some(Null) => PyNone
    Some(Boolean) => PyBool(self.bool_arg("this"))
    // `-<int literal>` may be -2**63, whose absolute value is outside Int64
    Some(Neg) if self.is_number() &&
      self.this_().kind == Literal &&
      is_int_str(self.this_().text("this")) &&
      !py_strip(self.this_().text("this")).has_prefix("-") &&
      !py_strip(self.this_().text("this")).has_prefix("+") =>
      match parse_int_checked("-" + py_strip(self.this_().text("this"))) {
        Some(i) => PyInt(i)
        None => raise ValueError("Invalid numeric literal")
      }
    Some(Neg) if self.is_number() =>
      match self.this_().to_py() {
        PyInt(i) => PyInt(-i)
        PyDecimal(s) =>
          PyDecimal(
            if s.has_prefix("-") {
              s.view(start_offset=1).to_owned()
            } else {
              "-" + s
            },
          )
        other => other
      }
    _ =>
      raise ValueError("\{self.to_s()} cannot be converted to a Python object.")
  }
}

///|
/// Python `Expr.__repr__` (`_to_s`): a textual representation of the expression tree.
pub fn Expr::to_s(self : Expr) -> String {
  to_s_node(self, 0)
}

///|
fn to_s_value(value : Value, level : Int, repr_str : Bool) -> String {
  let indent = "\n" + "  ".repeat(level + 1)
  let delim = ",\{indent}"
  match value {
    Node(e) => to_s_node(e, level)
    List(items) => {
      let s = items.map(v => to_s_value(v, level + 1, false)).join(delim)
      if s.is_empty() {
        "[]"
      } else {
        "[\{indent}\{s}]"
      }
    }
    Str(s) => {
      let s = if repr_str { py_repr_str(s) } else { s }
      // Indent multiline strings to match the current level
      to_s_dedent(s).join(indent)
    }
    Bool(b) => if b { "True" } else { "False" }
    Int(i) => i.to_string()
    DT(d) => "DType.\{d}"
  }
}

///|
/// `textwrap.dedent(s.strip("\n")).splitlines()`
fn to_s_dedent(s : String) -> Array[String] {
  let lines = strip_chars(s, "\n").split("\n").map(l => l.to_owned()).collect()
  let mut margin : Int? = None
  for line in lines {
    if py_strip(line).is_empty() {
      continue
    }
    let mut n = 0
    for c in line {
      if c == ' ' || c == '\t' {
        n += 1
      } else {
        break
      }
    }
    margin = match margin {
      Some(m) if m <= n => Some(m)
      _ => Some(n)
    }
  }
  let m = margin.unwrap_or(0)
  lines.map(line => {
    if py_strip(line).is_empty() {
      ""
    } else {
      line.view(start_offset=m).to_owned()
    }
  })
}

///|
fn to_s_node(node : Expr, level : Int) -> String {
  let mut indent = "\n" + "  ".repeat(level + 1)
  let mut delim = ",\{indent}"
  let items : Array[(String, String)] = []
  let repr_str = node.is_string() ||
    (node.kind == Identifier && node.bool_arg("quoted"))
  for k, v in node.args {
    match v {
      List(l) if l.is_empty() => continue
      _ => ()
    }
    items.push((k, to_s_value(v, level + 1, repr_str)))
  }
  if !node.kind.is_data_type() {
    match node.get_type() {
      Some(t) => items.push(("_type", to_s_node(t, level + 1)))
      None => ()
    }
  }
  match node.comments {
    Some(c) if !c.is_empty() =>
      items.push(
        ("_comments", to_s_value(List(c.map(x => Str(x))), level + 1, false)),
      )
    _ => ()
  }
  if node.is_leaf() {
    indent = ""
    delim = ", "
  }
  let body = items.map(kv => "\{kv.0}=\{kv.1}").join(delim)
  "\{node.kind.name()}(\{indent}\{body})"
}

///|
/// A `DType` converts to its `DataType` expression (Python accepts a `DType` wherever a
/// `DATA_TYPE` is expected).
pub impl IntoPy for DType with fn into_py(self) {
  PyExpr(mk1(DataType, self))
}

///|
#deprecated
pub extend DType with IntoPy::{into_py}
