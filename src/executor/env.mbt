// Port of sqlglot/executor/env.py: the functions available to generated code.

///|
fn arity_error(name : String, min : Int, max : Int, got : Int) -> PyException {
  if got < min {
    type_error("\{name}() missing \{min - got} required positional argument(s)")
  } else {
    type_error(
      "\{name}() takes \{max} positional argument(s) but \{got} were given",
    )
  }
}

///|
/// A Python function with `min..=max` positional parameters (`max < 0`: variadic).
fn pyfunc(
  name : String,
  min : Int,
  max : Int,
  f : (Array[Value]) -> Value raise,
) -> Value {
  Func({
    name,
    call: args => {
      if args.length() < min || (max >= 0 && args.length() > max) {
        raise arity_error(name, min, max, args.length())
      }
      f(args)
    },
  })
}

///|
/// `null_if_any(*required)`: returns None if any of the required arguments (given by
/// position; all arguments when `required` is empty) is None.
fn null_if_any(
  name : String,
  min : Int,
  max : Int,
  f : (Array[Value]) -> Value raise,
  required? : Array[Int] = [],
) -> Value {
  pyfunc(name, min, max, args => {
    if required.is_empty() {
      if args.iter().any(a => a is Null) {
        return Null
      }
    } else {
      for i in required {
        if i < args.length() && args[i] is Null {
          return Null
        }
      }
    }
    f(args)
  })
}

///|
/// `filter_nulls(func, empty_null)` for aggregate functions.
fn filter_nulls(
  name : String,
  f : (Array[Value]) -> Value raise,
  empty_null? : Bool = true,
) -> Value {
  pyfunc(name, 1, 1, args => {
    let filtered = py_iter(args[0]).filter(v => !(v is Null))
    if filtered.is_empty() && empty_null {
      return Null
    }
    f(filtered)
  })
}

///|
fn sql_not(value : Value) -> Value {
  match value {
    Null => Null
    v => Bool(!v.truthy())
  }
}

///|
fn call_value(f : Value, args : Array[Value]) -> Value raise {
  match f {
    Func(func) => (func.call)(args)
    _ => raise type_error("'\{f.type_name()}' object is not callable")
  }
}

///|
fn to_sql_bool(v : Value) -> Bool? {
  match v {
    Null => None
    v => Some(v.truthy())
  }
}

///|
fn sql_and(left : Value, right : Value) -> Value raise {
  let l = to_sql_bool(call_value(left, []))
  if l is Some(false) {
    return Bool(false)
  }
  let r = to_sql_bool(call_value(right, []))
  if r is Some(false) {
    return Bool(false)
  }
  if l is None || r is None {
    Null
  } else {
    Bool(true)
  }
}

///|
fn sql_or(left : Value, right : Value) -> Value raise {
  let l = to_sql_bool(call_value(left, []))
  if l is Some(true) {
    return Bool(true)
  }
  let r = to_sql_bool(call_value(right, []))
  if r is Some(true) {
    return Bool(true)
  }
  if l is None || r is None {
    Null
  } else {
    Bool(false)
  }
}

///|
fn sql_in(args : Array[Value]) -> Value {
  let value = args[0]
  if value is Null {
    return Null
  }
  let mut has_null = false
  for i in 1..<args.length() {
    let candidate = args[i]
    if candidate is Null {
      has_null = true
    } else if py_eq(value, candidate) {
      return Bool(true)
    }
  }
  if has_null {
    Null
  } else {
    Bool(false)
  }
}

///|
fn expect_str(v : Value, what : String) -> String raise PyException {
  match v {
    Str(s) => s
    _ => raise type_error("\{what} must be str, not \{v.type_name()}")
  }
}

///|
/// `str.find(sub, start)` + 1 in code points.
fn str_position(args : Array[Value]) -> Value raise {
  let this = expect_str(args[0], "argument")
  let substr = match args[1] {
    Str(s) => s
    v => raise type_error("must be str, not \{v.type_name()}")
  }
  let position = if args.length() > 2 { args[2] } else { Null }
  let start = match position {
    Null => Null
    p => py_sub(p, Int(1L))
  }
  let hay = this.to_array()
  let needle = substr.to_array()
  let n = hay.length()
  let mut s = match start {
    Null => 0
    Int(i) => i.to_int()
    Bool(b) => if b { 1 } else { 0 }
    v =>
      raise type_error(
        "slice indices must be integers or None or have an __index__ method, not \{v.type_name()}",
      )
  }
  if s < 0 {
    s = s + n
    if s < 0 {
      s = 0
    }
  }
  if s > n {
    return Int(0L)
  }
  let m = needle.length()
  for i in s..<=(n - m) {
    let mut ok = true
    for j in 0..<m {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
    }
    if ok {
      return Int((i + 1).to_int64())
    }
  }
  Int(0L)
}

///|
fn substring(args : Array[Value]) -> Value raise {
  let this = args[0]
  let start = if args.length() > 1 { args[1] } else { Null }
  let length = if args.length() > 2 { args[2] } else { Null }
  if start is Null {
    return this
  }
  if py_eq(start, Int(0L)) {
    return Str("")
  }
  let start = if py_lt(start, Int(0L)) {
    py_add(Int(py_len(this).to_int64()), start)
  } else {
    py_sub(start, Int(1L))
  }
  let end = match length {
    Null => Null
    l => py_add(start, l)
  }
  py_slice(this, start, end)
}

///|
fn in_types(t : @core.DType, types : Array[@core.DType]) -> Bool {
  types.contains(t)
}

///|
fn cast(this : Value, to : Value) -> Value raise {
  let t = match to {
    DTypeV(t) => Some(t)
    _ => None
  }
  let is_t = fn(x : @core.DType) { t == Some(x) }
  if is_t(DATE) {
    match this {
      DateTime(dt) => return Date(dt.date)
      Date(_) => return this
      Str(_) => return Date(date_fromisoformat(this))
      _ => ()
    }
  }
  if is_t(TIME) {
    match this {
      DateTime(dt) => return Time(dt.time)
      Time(_) => return this
      Str(_) => return Time(time_fromisoformat(this))
      _ => ()
    }
  }
  if is_t(DATETIME) || is_t(TIMESTAMP) {
    match this {
      DateTime(_) => return this
      Date(d) =>
        return DateTime({
          date: d,
          time: { hour: 0, minute: 0, second: 0, microsecond: 0, },
          tz: None,
        })
      Str(_) => return DateTime(datetime_fromisoformat(this))
      _ => ()
    }
  }
  match t {
    Some(BOOLEAN) => return Bool(this.truthy())
    Some(x) if in_types(x, @core.dtype_text_types) => return Str(this.py_str())
    Some(FLOAT | DOUBLE) => return py_float(this)
    Some(x) if in_types(x, @core.dtype_numeric_types) => return py_int(this)
    _ => ()
  }
  let to_str = match to {
    DTypeV(t) => "DType.\{t.name()}"
    v => v.py_str()
  }
  raise PyException(
    "NotImplementedError",
    "Casting \{this.py_str()} to '\{to_str}' not implemented.",
  )
}

///|
let first : Int64 = 0L

///|
let last : Int64 = 1L

///|
fn ordered(this : Value, desc : Value, nulls_first : Value) -> Value {
  if this is Null {
    return Tuple([Int(if nulls_first.truthy() { first } else { last }), Int(0L)])
  }
  Tuple([
    Int(if nulls_first.truthy() { last } else { first }),
    if desc.truthy() {
      RevKey(this)
    } else {
      this
    },
  ])
}

///|
/// `_like`: `re.fullmatch` of the pattern with `_` as any char and `%` as any string.
fn like(this : Value, pattern : Value, ignore_case : Bool) -> Value raise {
  let p = match pattern {
    Str(s) => s
    v => raise type_error("expected str, got \{v.type_name()}")
  }
  let s = match this {
    Str(s) => s
    v =>
      raise type_error(
        "expected string or bytes-like object, got '\{v.type_name()}'",
      )
  }
  Bool(glob_match(s.to_array(), p.to_array(), ignore_case))
}

///|
fn char_eq(a : Char, b : Char, ignore_case : Bool) -> Bool {
  a == b ||
  (
    ignore_case &&
    (
      @core.char_lower(a) == @core.char_lower(b) ||
      @core.char_upper(a) == @core.char_upper(b)
    )
  )
}

///|
fn glob_match(s : Array[Char], p : Array[Char], ignore_case : Bool) -> Bool {
  let mut si = 0
  let mut pi = 0
  let mut star_p = -1
  let mut star_s = 0
  while si < s.length() {
    if pi < p.length() && p[pi] == '%' {
      star_p = pi
      star_s = si
      pi += 1
    } else if pi < p.length() &&
      (p[pi] == '_' || char_eq(p[pi], s[si], ignore_case)) {
      pi += 1
      si += 1
    } else if star_p >= 0 {
      pi = star_p + 1
      star_s += 1
      si = star_s
    } else {
      return false
    }
  }
  while pi < p.length() && p[pi] == '%' {
    pi += 1
  }
  pi == p.length()
}

///|
let time_part_singulars : Array[String] = [
  "MICROSECONDS", "SECONDS", "MINUTES", "HOURS", "DAYS", "WEEKS", "MONTHS", "QUARTERS",
  "YEARS",
]

///|
fn interval(this : Value, unit : Value) -> Value raise {
  let unit = match unit {
    Str(u) => u
    v => raise type_error("unsupported operand: \{v.type_name()}")
  }
  let plural = unit + "S"
  let unit = if time_part_singulars.contains(plural) { plural } else { unit }
  let amount = match py_float(this) {
    Float(d) => d
    _ => 0.0
  }
  let factor = match @core.py_lower(unit) {
    "days" => 86400000000.0
    "seconds" => 1000000.0
    "microseconds" => 1.0
    "milliseconds" => 1000.0
    "minutes" => 60000000.0
    "hours" => 3600000000.0
    "weeks" => 604800000000.0
    u =>
      raise type_error(
        "\{@core.py_repr_str(u)} is an invalid keyword argument for __new__()",
      )
  }
  let us = round_half_even(amount * factor)
  if us.is_nan() || us.abs() > 8.64e19 {
    raise PyException(
      "OverflowError", "normalized days too large to fit in a C int",
    )
  }
  TimeDelta(check_td(PyTimeDelta::from_us(us.to_int64())))
}

///|
fn arrayconcat(args : Array[Value]) -> Value {
  let out = []
  for arg in args {
    match arg {
      List(l) => out.append(l)
      v => out.push(v)
    }
  }
  List(out)
}

///|
fn arraytostring(args : Array[Value]) -> Value raise {
  let this = args[0]
  let sep = args[1]
  let null = if args.length() > 2 { args[2] } else { Null }
  let items = py_iter(this)
    .map(x => if x is Null { null } else { x })
    .filter(x => !(x is Null))
  str_join(sep, items)
}

///|
/// Python `sep.join(items)`.
fn str_join(sep : Value, items : Array[Value]) -> Value raise {
  let s = match sep {
    Str(s) => s
    v =>
      raise type_error(
        "descriptor 'join' requires a 'str' object but received a '\{v.type_name()}'",
      )
  }
  let parts = []
  for i, x in items {
    match x {
      Str(t) => parts.push(t)
      v =>
        raise type_error(
          "sequence item \{i}: expected str instance, \{v.type_name()} found",
        )
    }
  }
  Str(parts.join(s))
}

///|
fn jsonextract(this : Value, path : Value) -> Value raise {
  let mut this = this
  for segment in py_iter(path) {
    match this {
      Dict(_) =>
        this = py_getitem(this, segment) catch {
          PyException("KeyError", _) => Null
          e => raise e
        }
      List(l) if segment is Str(s) && @core.parse_int_str(s) is Some(i) => {
        let i = i.to_int()
        this = if i >= 0 && i < l.length() {
          l[i]
        } else if i < 0 && -i <= l.length() {
          l[l.length() + i]
        } else {
          Null
        }
      }
      _ =>
        raise PyException(
          "NotImplementedError",
          "Unable to extract value for \{this.py_str()} at \{segment.py_str()}.",
        )
    }
    if this is Null {
      break
    }
  }
  this
}

///|
fn getattr(obj : Value, name : String) -> Value raise {
  let v = match (obj, name) {
    (Date(d), "year") | (DateTime({ date: d, .. }), "year") => Some(d.year)
    (Date(d), "month") | (DateTime({ date: d, .. }), "month") => Some(d.month)
    (Date(d), "day") | (DateTime({ date: d, .. }), "day") => Some(d.day)
    (Time(t), "hour") | (DateTime({ time: t, .. }), "hour") => Some(t.hour)
    (Time(t), "minute") | (DateTime({ time: t, .. }), "minute") =>
      Some(t.minute)
    (Time(t), "second") | (DateTime({ time: t, .. }), "second") =>
      Some(t.second)
    (Time(t), "microsecond") | (DateTime({ time: t, .. }), "microsecond") =>
      Some(t.microsecond)
    (TimeDelta(td), "days") => return Int(td.days)
    (TimeDelta(td), "seconds") => Some(td.seconds)
    (TimeDelta(td), "microseconds") => Some(td.microseconds)
    (Module("exp"), "DType") => return Module("exp.DType")
    (Module("exp.DType"), n) =>
      match @core.dtype_from_name(n) {
        Some(t) => return DTypeV(t)
        None => None
      }
    _ => None
  }
  match v {
    Some(i) => Int(i.to_int64())
    None =>
      raise PyException(
        "AttributeError",
        "'\{obj.type_name()}' object has no attribute '\{name}'",
      )
  }
}

///|
fn now_datetime() -> PyDateTime raise PyException {
  let ms = @env.now().reinterpret_as_int64()
  datetime_from_us(ms * 1000L + 62135596800L * 1000000L, None)
}

///|
fn struct_(args : Array[Value]) -> Value raise {
  let out : Array[(Value, Value)] = []
  let mut x = 0
  while x < args.length() {
    if x + 1 >= args.length() {
      raise PyException("IndexError", "tuple index out of range")
    }
    let k = args[x]
    let v = args[x + 1]
    if !(v is Null) && !(k is Null) {
      dict_set(out, k, v)
    }
    x += 2
  }
  Dict(out)
}

///|
fn dict_set(d : Array[(Value, Value)], k : Value, v : Value) -> Unit raise {
  ignore(hash_key(k))
  for i, kv in d {
    if py_eq(kv.0, k) {
      d[i] = (kv.0, v)
      return
    }
  }
  d.push((k, v))
}

///|
fn zip_values(args : Array[Value]) -> Array[Array[Value]] raise {
  if args.is_empty() {
    return []
  }
  let iters = args.map(a => py_iter(a))
  let mut n = iters[0].length()
  for it in iters {
    if it.length() < n {
      n = it.length()
    }
  }
  Array::makei(n, i => iters.map(it => it[i]))
}

///|
fn str_strip(this : Value, chars : Value) -> Value raise {
  let s = match this {
    Str(s) => s
    v =>
      raise type_error(
        "descriptor 'strip' for 'str' objects doesn't apply to a '\{v.type_name()}' object",
      )
  }
  match chars {
    Null => Str(py_strip_ws(s))
    Str(c) => {
      let set = c.to_array()
      let a = s.to_array()
      let mut i = 0
      let mut j = a.length()
      while i < j && set.contains(a[i]) {
        i += 1
      }
      while j > i && set.contains(a[j - 1]) {
        j -= 1
      }
      Str(String::from_array(a[i:j].to_array()))
    }
    v => raise type_error("strip arg must be None or str, not \{v.type_name()}")
  }
}

///|
fn str_method(
  this : Value,
  method_name : String,
  f : (String) -> String,
) -> Value raise {
  match this {
    Str(s) => Str(f(s))
    v =>
      raise PyException(
        "AttributeError",
        "'\{v.type_name()}' object has no attribute '\{method_name}'",
      )
  }
}

///|
fn attr_of(this : Value, name : String) -> Value raise {
  getattr(this, name)
}

///|
fn build_env() -> Map[String, Value] {
  let env : Map[String, Value] = {}
  let set = fn(v : Value) {
    match v {
      Func(f) => env[f.name] = v
      _ => ()
    }
  }
  env["exp"] = Module("exp")
  set(pyfunc("AND", 2, 2, args => sql_and(args[0], args[1])))
  // aggs
  set(pyfunc("ARRAYAGG", 1, 1, args => List(py_iter(args[0]).copy())))
  set(filter_nulls("ARRAYUNIQUEAGG", acc => List(py_set(acc))))
  set(
    filter_nulls("AVG", acc => Float(py_fsum(acc) / acc.length().to_double())),
  )
  set(
    filter_nulls("COUNT", acc => Int(acc.length().to_int64()), empty_null=false),
  )
  set(
    pyfunc("FIRST", 1, 1, args => {
      let items = py_iter(args[0])
      if items.is_empty() {
        Null
      } else {
        items[0]
      }
    }),
  )
  set(filter_nulls("MAX", acc => py_max(acc)))
  set(filter_nulls("MIN", acc => py_min(acc)))
  set(filter_nulls("SUM", acc => py_sum(acc)))
  // scalar functions
  set(null_if_any("ABS", 1, 1, args => py_abs(args[0])))
  set(null_if_any("ADD", 2, 2, args => py_add(args[0], args[1])))
  set(
    null_if_any("ARRAYANY", 2, 2, args => {
      for e in py_iter(args[0]) {
        if call_value(args[1], [e]).truthy() {
          return Bool(true)
        }
      }
      Bool(false)
    }),
  )
  set(null_if_any("ARRAYCONCAT", 0, -1, args => arrayconcat(args)))
  set(
    null_if_any("ARRAYTOSTRING", 2, 3, args => arraytostring(args), required=[
      0, 1,
    ]),
  )
  set(
    null_if_any("BETWEEN", 3, 3, args => {
      let l = py_le(args[1], args[0])
      if !l {
        return Bool(false)
      }
      Bool(py_le(args[0], args[2]))
    }),
  )
  set(null_if_any("BITWISEAND", 2, 2, args => py_bitop("&", args[0], args[1])))
  set(
    null_if_any("BITWISELEFTSHIFT", 2, 2, args => {
      py_bitop("<<", args[0], args[1])
    }),
  )
  set(null_if_any("BITWISEOR", 2, 2, args => py_bitop("|", args[0], args[1])))
  set(
    null_if_any("BITWISERIGHTSHIFT", 2, 2, args => {
      py_bitop(">>", args[0], args[1])
    }),
  )
  set(null_if_any("BITWISEXOR", 2, 2, args => py_bitop("^", args[0], args[1])))
  set(null_if_any("CAST", 2, 2, args => cast(args[0], args[1])))
  set(
    pyfunc("COALESCE", 0, -1, args => {
      for a in args {
        if !(a is Null) {
          return a
        }
      }
      Null
    }),
  )
  set(null_if_any("CONCAT", 0, -1, args => str_join(Str(""), args)))
  set(
    null_if_any("SAFECONCAT", 0, -1, args => {
      Str(args.map(a => a.py_str()).join(""))
    }),
  )
  set(
    null_if_any("CONCATWS", 1, -1, args => {
      str_join(args[0], args[1:].to_array())
    }),
  )
  set(
    null_if_any("DATEDIFF", 2, -1, args => {
      attr_of(py_sub(args[0], args[1]), "days")
    }),
  )
  set(
    null_if_any("DATESTRTODATE", 1, 1, args => Date(date_fromisoformat(args[0]))),
  )
  set(null_if_any("DIV", 2, 2, args => py_truediv(args[0], args[1])))
  set(null_if_any("DOT", 2, 2, args => py_getitem(args[0], args[1])))
  set(null_if_any("EQ", 2, 2, args => Bool(py_eq(args[0], args[1]))))
  set(
    null_if_any("EXTRACT", 2, 2, args => {
      match args[0] {
        Str(name) => getattr(args[1], name)
        v =>
          raise type_error(
            "attribute name must be string, not '\{v.type_name()}'",
          )
      }
    }),
  )
  set(null_if_any("GT", 2, 2, args => Bool(py_gt(args[0], args[1]))))
  set(null_if_any("GTE", 2, 2, args => Bool(py_ge(args[0], args[1]))))
  set(
    pyfunc("IF", 3, 3, args => if args[0].truthy() { args[1] } else { args[2] }),
  )
  set(pyfunc("IN", 1, -1, args => sql_in(args)))
  set(null_if_any("INT", 1, 1, args => py_int(args[0])))
  set(null_if_any("INTDIV", 2, 2, args => py_floordiv(args[0], args[1])))
  set(null_if_any("INTERVAL", 2, 2, args => interval(args[0], args[1])))
  set(
    null_if_any("JSONEXTRACT", 2, 2, args => jsonextract(args[0], args[1]), required=[
      0, 1,
    ]),
  )
  set(null_if_any("LEFT", 2, 2, args => py_slice(args[0], Null, args[1])))
  set(null_if_any("LENGTH", 1, 1, args => Int(py_len(args[0]).to_int64())))
  set(null_if_any("LIKE", 2, 2, args => like(args[0], args[1], false)))
  set(null_if_any("ILIKE", 2, 2, args => like(args[0], args[1], true)))
  set(
    null_if_any("LOWER", 1, 1, args => {
      str_method(args[0], "lower", @core.py_lower)
    }),
  )
  set(null_if_any("LT", 2, 2, args => Bool(py_lt(args[0], args[1]))))
  set(null_if_any("LTE", 2, 2, args => Bool(py_le(args[0], args[1]))))
  set(
    null_if_any("MAP", 0, -1, args => {
      let out : Array[(Value, Value)] = []
      for pair in zip_values(args) {
        if pair.length() != 2 {
          raise value_error(
            "dictionary update sequence element #0 has length \{pair.length()}; 2 is required",
          )
        }
        dict_set(out, pair[0], pair[1])
      }
      Dict(out)
    }),
  )
  set(null_if_any("MOD", 2, 2, args => py_mod(args[0], args[1])))
  set(null_if_any("MUL", 2, 2, args => py_mul(args[0], args[1])))
  set(null_if_any("NEQ", 2, 2, args => Bool(!py_eq(args[0], args[1]))))
  set(
    null_if_any("ORD", 1, 1, args => {
      match args[0] {
        Str(s) if s.char_length() == 1 =>
          Int(s.get_char(0).unwrap().to_int().to_int64())
        Str(s) =>
          raise type_error(
            "ord() expected a character, but string of length \{s.char_length()} found",
          )
        v =>
          raise type_error(
            "ord() expected string of length 1, but \{v.type_name()} found",
          )
      }
    }),
  )
  set(pyfunc("NOT", 1, 1, args => sql_not(args[0])))
  set(pyfunc("OR", 2, 2, args => sql_or(args[0], args[1])))
  set(pyfunc("ORDERED", 3, 3, args => ordered(args[0], args[1], args[2])))
  set(null_if_any("POW", 2, 2, args => py_pow(args[0], args[1])))
  set(
    null_if_any("REVERSE", 1, 1, args => py_slice(args[0], Null, Null, step=-1)),
  )
  set(
    null_if_any("RIGHT", 2, 2, args => py_slice(args[0], py_neg(args[1]), Null)),
  )
  set(
    null_if_any("ROUND", 1, 3, args => {
      py_round(args[0], if args.length() > 1 { args[1] } else { Null })
    }),
  )
  set(
    null_if_any("STRPOSITION", 2, 3, args => str_position(args), required=[0, 1]),
  )
  set(null_if_any("SUB", 2, 2, args => py_sub(args[0], args[1])))
  set(null_if_any("SUBSTRING", 1, 3, args => substring(args), required=[0]))
  set(
    null_if_any("TIMESTRTOTIME", 1, 1, args => {
      DateTime(datetime_fromisoformat(args[0]))
    }),
  )
  set(
    null_if_any("UPPER", 1, 1, args => {
      str_method(args[0], "upper", @core.py_upper)
    }),
  )
  set(
    pyfunc("ZIPNOTNULL", 0, -1, args => {
      Iter(
        zip_values(args)
        .filter(row => row.iter().all(v => !(v is Null)))
        .map(row => Tuple(row)),
      )
    }),
  )
  set(null_if_any("YEAR", 1, 1, args => getattr(args[0], "year")))
  set(null_if_any("MONTH", 1, 1, args => getattr(args[0], "month")))
  set(null_if_any("DAY", 1, 1, args => getattr(args[0], "day")))
  set(pyfunc("CURRENTDATETIME", 0, 0, _ => DateTime(now_datetime())))
  set(pyfunc("CURRENTTIMESTAMP", 0, 0, _ => DateTime(now_datetime())))
  set(pyfunc("CURRENTTIME", 0, 0, _ => DateTime(now_datetime())))
  set(pyfunc("CURRENTDATE", 0, 0, _ => Date(now_datetime().date)))
  set(
    null_if_any("STRFTIME", 2, 2, args => {
      let fmt = expect_str(args[0], "strftime() argument 1")
      Str(strftime(datetime_fromisoformat(args[1]), fmt))
    }),
  )
  set(
    null_if_any("STRTOTIME", 2, 2, args => {
      let s = expect_str(args[0], "strptime() argument 1")
      let f = expect_str(args[1], "strptime() argument 2")
      DateTime(strptime(s, f))
    }),
  )
  set(
    null_if_any("TRIM", 1, 2, args => {
      str_strip(args[0], if args.length() > 1 { args[1] } else { Null })
    }),
  )
  set(pyfunc("STRUCT", 0, -1, args => struct_(args)))
  set(
    null_if_any("UNIXTOTIME", 1, 1, args => {
      DateTime(datetime_from_timestamp_utc(args[0]))
    }),
  )
  env
}

///|
/// The functions available to the generated code (Python `env.ENV`). Entries can be
/// replaced (e.g. to pin `CURRENT_TIMESTAMP` in tests), like patching the Python dict.
pub let default_env : Map[String, Value] = build_env()

///|
/// Python builtins reachable from generated code.
let builtins : Map[String, Value] = {
  "set": pyfunc("set", 0, 1, args => {
    if args.is_empty() {
      Set([])
    } else {
      Set(py_set(py_iter(args[0])))
    }
  }),
  "len": pyfunc("len", 1, 1, args => Int(py_len(args[0]).to_int64())),
  "list": pyfunc("list", 0, 1, args => {
    if args.is_empty() {
      List([])
    } else {
      List(py_iter(args[0]).copy())
    }
  }),
  "tuple": pyfunc("tuple", 0, 1, args => {
    if args.is_empty() {
      Tuple([])
    } else {
      Tuple(py_iter(args[0]).copy())
    }
  }),
  "str": pyfunc("str", 0, 1, args => {
    if args.is_empty() {
      Str("")
    } else {
      Str(args[0].py_str())
    }
  }),
  "int": pyfunc("int", 0, 1, args => {
    if args.is_empty() {
      Int(0L)
    } else {
      py_int(args[0])
    }
  }),
  "float": pyfunc("float", 0, 1, args => {
    if args.is_empty() {
      Float(0.0)
    } else {
      py_float(args[0])
    }
  }),
  "bool": pyfunc("bool", 0, 1, args => {
    Bool(!args.is_empty() && args[0].truthy())
  }),
  "abs": pyfunc("abs", 1, 1, args => py_abs(args[0])),
  "sum": pyfunc("sum", 1, 1, args => py_sum(py_iter(args[0]))),
  "max": pyfunc("max", 1, -1, args => {
    if args.length() == 1 {
      py_max(py_iter(args[0]))
    } else {
      py_max(args)
    }
  }),
  "min": pyfunc("min", 1, -1, args => {
    if args.length() == 1 {
      py_min(py_iter(args[0]))
    } else {
      py_min(args)
    }
  }),
  "round": pyfunc("round", 1, 2, args => {
    py_round(args[0], if args.length() > 1 { args[1] } else { Null })
  }),
  "pow": pyfunc("pow", 2, 2, args => py_pow(args[0], args[1])),
  "ord": pyfunc("ord", 1, 1, args => {
    match args[0] {
      Str(s) if s.char_length() == 1 =>
        Int(s.get_char(0).unwrap().to_int().to_int64())
      _ => raise type_error("ord() expected a character")
    }
  }),
}
