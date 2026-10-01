// Module-level helpers of sqlglot/optimizer/simplify.py.

///|
let final_key : String = "final"

///|
/// Marks that an expression should not be simplified.
fn is_final(e : @core.Expr) -> Bool {
  e.meta_bool(final_key)
}

///|
fn is_simplifiable(e : @core.Expr) -> Bool {
  e.kind.is_any([Binary, Func, Lambda, Predicate, Unary])
}

///|
/// A AND (B AND C) -> A AND B AND C
fn flatten_connector(expression : @core.Expr) -> @core.Expr {
  if expression.kind.is_a(Connector) {
    for node in expression.iter_expressions() {
      let child = node.unnest()
      if child.kind == expression.kind {
        node.replace(Some(child)) |> ignore
      }
    }
  }
  expression
}

///|
/// Propagate constants for conjunctions in DNF.
fn propagate_constants(expression : @core.Expr, root : Bool) -> @core.Expr {
  if expression.kind.is_a(And) &&
    (root || !expression.same_parent()) &&
    normalized(expression, dnf=true) {
    let constant_mapping : Array[(@core.Expr, @core.Expr, @core.Expr)] = []
    for expr in walk_in_scope(expression, prune=n => n.kind.is_a(If)) {
      if expr.kind.is_a(EQ) {
        match (expr.this(), expr.expression()) {
          (Some(l), Some(r)) =>
            if l.kind.is_a(Column) &&
              r.kind.is_a(Literal) &&
              l.meta_get("nonnull") is Some(Bool(true)) {
              // dict semantics: later equal keys overwrite the value, keep position
              let mut found = false
              for i, kv in constant_mapping {
                if kv.0 == l {
                  constant_mapping[i] = (kv.0, l, r)
                  found = true
                  break
                }
              }
              if !found {
                constant_mapping.push((l, l, r))
              }
            }
          _ => ()
        }
      }
    }
    if !constant_mapping.is_empty() {
      for column in find_all_in_scope(expression, [Column]).collect() {
        let parent = column.parent
        for kv in constant_mapping {
          if kv.0 == column {
            let is_null_check = match parent {
              Some(p) =>
                p.kind.is_a(Is) &&
                (match p.expression() {
                  Some(x) => x.kind.is_a(Null)
                  None => false
                })
              None => false
            }
            if !physical_equal(column, kv.1) && !is_null_check {
              column.replace(Some(kv.2.copy())) |> ignore
            }
            break
          }
        }
      }
    }
  }
  expression
}

///|
fn is_number_expr(e : @core.Expr) -> Bool {
  e.is_number()
}

///|
fn is_interval_expr(e : @core.Expr) -> Bool {
  e.kind.is_a(Interval) && extract_interval(e) is Some(_)
}

///|
fn is_nonnull_constant(e : @core.Expr) -> Bool {
  e.kind.is_any([Literal, Boolean]) || is_date_literal(e)
}

///|
fn is_constant_expr(e : @core.Expr) -> Bool {
  let expr = if e.kind.is_a(Neg) {
    match e.this() {
      Some(t) => t
      None => e
    }
  } else {
    e
  }
  expr.kind.is_any([Literal, Boolean, Null]) || is_date_literal(expr)
}

///|
fn always_true(e : @core.Expr?) -> Bool {
  match e {
    Some(e) =>
      (e.kind.is_a(Boolean) && e.has("this")) ||
      (e.kind.is_a(Literal) && e.is_number() && !is_zero(Some(e)))
    None => false
  }
}

///|
fn always_false(e : @core.Expr?) -> Bool {
  is_false(e) || is_null(e) || is_zero(e)
}

///|
fn is_zero(e : @core.Expr?) -> Bool {
  match e {
    Some(e) if e.kind.is_a(Literal) =>
      match expr_to_pynum(e) {
        Some(n) => n.is_zero()
        None => false
      }
    _ => false
  }
}

///|
fn is_false(e : @core.Expr?) -> Bool {
  match e {
    Some(e) => e.kind == Boolean && !e.has("this")
    None => false
  }
}

///|
fn is_null(e : @core.Expr?) -> Bool {
  match e {
    Some(e) => e.kind == Null
    None => false
  }
}

///|
fn boolean_literal(b : Bool) -> @core.Expr {
  if b {
    @core.true_()
  } else {
    @core.false_()
  }
}

///|
/// Python `eval_boolean` given a comparison result (`cmp`) and equality (`eq`).
fn eval_boolean_cmp(expression : @core.Expr, cmp : () -> Int raise @core.SqlglotError, eq : () -> Bool) -> @core.Expr? raise @core.SqlglotError {
  let k = expression.kind
  if k.is_any([EQ, Is]) {
    if k.is_a(Is) && expression.has("negate") {
      return Some(boolean_literal(!eq()))
    }
    return Some(boolean_literal(eq()))
  }
  if k.is_a(NEQ) {
    return Some(boolean_literal(!eq()))
  }
  if k.is_a(GT) {
    return Some(boolean_literal(cmp() > 0))
  }
  if k.is_a(GTE) {
    return Some(boolean_literal(cmp() >= 0))
  }
  if k.is_a(LT) {
    return Some(boolean_literal(cmp() < 0))
  }
  if k.is_a(LTE) {
    return Some(boolean_literal(cmp() <= 0))
  }
  None
}

///|
/// A value that `cast_value` operates on: a string, or a date/datetime.
priv enum DateValue {
  DVStr(String)
  DVDate(PyDT)
}

///|
fn cast_as_date(value : DateValue) -> PyDT? {
  match value {
    DVDate(d) => Some(d.to_date())
    DVStr(s) => parse_py_datetime(s).map(d => d.to_date())
  }
}

///|
fn cast_as_datetime(value : DateValue) -> PyDT? {
  match value {
    DVDate(d) => Some(d.to_datetime())
    DVStr(s) => parse_py_datetime(s)
  }
}

///|
fn cast_value(value : DateValue, to : @core.Expr) -> PyDT? {
  match value {
    DVStr("") => return None
    _ => ()
  }
  if to.is_type([DATE]) {
    return cast_as_date(value)
  }
  if to.is_type(@core.dtype_temporal_types) {
    return cast_as_datetime(value)
  }
  None
}

///|
fn extract_date(cast : @core.Expr) -> PyDT? {
  let to = if cast.kind.is_a(Cast) {
    match cast.arg("to") {
      Some(t) => t
      None => return None
    }
  } else if cast.kind.is_a(TsOrDsToDate) && !cast.has("format") {
    @core.datatype_of(DATE)
  } else {
    return None
  }
  let this = match cast.this() {
    Some(t) => t
    None => return None
  }
  let value = if this.kind.is_a(Literal) {
    DVStr(this.name())
  } else if this.kind.is_any([Cast, TsOrDsToDate]) {
    match extract_date(this) {
      Some(d) => DVDate(d)
      None => return None
    }
  } else {
    return None
  }
  cast_value(value, to)
}

///|
fn is_date_literal(e : @core.Expr) -> Bool {
  extract_date(e) is Some(_)
}

///|
fn extract_interval(expression : @core.Expr) -> RelDelta? {
  let this = match expression.this() {
    Some(t) => t
    None => return None
  }
  let n = match this.kind {
    Literal =>
      if this.is_number() {
        match expr_to_pynum(this) {
          Some(PInt(i)) => i.to_int()
          Some(PDec(d)) =>
            // int(Decimal) truncates
            {
              let v = d.coeff
              let truncated = if d.exp >= 0 {
                v * pow10(d.exp)
              } else {
                v / pow10(-d.exp)
              }
              let t = truncated.to_int()
              if d.neg {
                -t
              } else {
                t
              }
            }
          None => return None
        }
      } else {
        match parse_py_int(this.text("this")) {
          Some(i) => i.to_int()
          None => return None
        }
      }
    Neg =>
      match expr_to_pynum(this) {
        Some(PInt(i)) => i.to_int()
        _ => return None
      }
    _ => return None
  }
  let unit = @core.py_lower(expression.text("unit"))
  interval_delta(unit, n~)
}

///|
fn is_exact_interval_move(
  op : @core.Expr,
  literal : @core.Expr,
  interval : @core.Expr,
) -> Bool raise @core.SqlglotError {
  let mut delta = match extract_interval(interval) {
    Some(d) => d
    None => return false
  }
  let value = match extract_date(literal) {
    Some(v) => v
    None => return false
  }
  if delta.months == 0 && delta.years == 0 {
    return true
  }
  if op.kind.is_any([Sub, DateSub, DatetimeSub]) {
    delta = delta.neg()
  }
  let moved = add_reldelta(value, delta.neg())
  let back = add_reldelta(moved, delta)
  let next = add_reldelta(moved.add_timedelta(1, 0L, 0L), delta)
  pydt_eq(back, value) && !pydt_eq(next, value)
}

///|
fn extract_type(expressions : Array[@core.Expr]) -> @core.Expr? {
  let mut target_type = None
  for expression in expressions {
    target_type = if expression.kind.is_a(Cast) {
      expression.arg("to")
    } else {
      expression.get_type()
    }
    if target_type is Some(_) {
      break
    }
  }
  target_type
}

///|
fn date_literal(date : PyDT, target_type : @core.Expr?) -> @core.Expr {
  let to = match target_type {
    Some(t) if t.is_type(@core.dtype_temporal_types) => t.copy()
    _ => @core.datatype_of(if date.is_datetime { DATETIME } else { DATE })
  }
  let cast = @core.mk(Cast, [
    ("this", @core.literal_string(date.to_py_string())),
    ("to", to),
  ])
  cast.set_type(Some(to))
  cast
}

///|
priv suberror UnsupportedUnit {
  UnsupportedUnit
}

///|
fn interval_or_raise(unit : String) -> RelDelta raise UnsupportedUnit {
  match interval_delta(unit) {
    Some(d) => d
    None => raise UnsupportedUnit
  }
}

///|
fn floor_or_raise(
  d : PyDT,
  unit : String,
  dialect : @core.Dialect,
) -> PyDT raise UnsupportedUnit {
  match datetime_floor(d, unit, dialect.cfg.week_offset) {
    Some(r) => r
    None => raise UnsupportedUnit
  }
}

///|
fn trunc_unit(unit : @core.Expr, dialect : @core.Dialect) -> String raise UnsupportedUnit {
  if unit.kind.is_a(WeekStart) {
    let dow = match @core.py_upper(unit.name()) {
      "MONDAY" => 1
      "TUESDAY" => 2
      "WEDNESDAY" => 3
      "THURSDAY" => 4
      "FRIDAY" => 5
      "SATURDAY" => 6
      "SUNDAY" => 7
      _ => -1
    }
    let offset = dialect.cfg.week_offset
    let expected = (offset % 7 + 7) % 7 + 1
    if dow != expected {
      raise UnsupportedUnit
    }
    return "week"
  }
  @core.py_lower(unit.name())
}

///|
fn date_ceil(
  d : PyDT,
  unit : String,
  dialect : @core.Dialect,
) -> PyDT raise UnsupportedUnit {
  let floor = floor_or_raise(d, unit, dialect)
  if pydt_eq(floor, d) {
    return d
  }
  add_reldelta(floor, interval_or_raise(unit)) catch {
    _ => raise UnsupportedUnit
  }
}

///|
fn datetrunc_range(
  date : PyDT,
  unit : String,
  dialect : @core.Dialect,
) -> (PyDT, PyDT)? raise UnsupportedUnit {
  let floor = floor_or_raise(date, unit, dialect)
  if !pydt_eq(date, floor) {
    return None
  }
  let upper = add_reldelta(floor, interval_or_raise(unit)) catch {
    _ => raise UnsupportedUnit
  }
  Some((floor, upper))
}

///|
fn ge_(l : @core.Expr, r : @core.Expr) -> @core.Expr {
  binop(GTE, l, r)
}

///|
fn lt_(l : @core.Expr, r : @core.Expr) -> @core.Expr {
  binop(LT, l, r)
}

///|
/// Python `Expr._binop(klass, other)`: copies both operands, wrapping binaries in parens.
fn binop(kind : @core.Kind, a : @core.Expr, b : @core.Expr) -> @core.Expr {
  let mut this = a.copy()
  let mut other = b.copy()
  if !this.kind.is_a(kind) && !other.kind.is_a(kind) {
    if this.kind.is_a(Binary) {
      this = @core.paren(this)
    }
    if other.kind.is_a(Binary) {
      other = @core.paren(other)
    }
  }
  @core.mk2(kind, this, other)
}

///|
fn datetrunc_eq_expression(
  left : @core.Expr,
  drange : (PyDT, PyDT),
  target_type : @core.Expr?,
) -> @core.Expr {
  @core.and_(
    [
      ge_(left, date_literal(drange.0, target_type)),
      lt_(left, date_literal(drange.1, target_type)),
    ],
    copy=false,
  )
}

///|
fn parenthesize_nested_connector(
  expression : @core.Expr,
  parent : @core.Expr?,
) -> @core.Expr {
  if expression.kind.is_a(Connector) &&
    (match parent {
      Some(p) =>
        p.kind.is_a(Not) || (p.kind.is_a(Connector) && p.kind != expression.kind)
      None => false
    }) {
    return @core.paren(expression)
  }
  expression
}

///|
/// Python `helper.merge_ranges`.
fn merge_ranges(
  ranges : Array[(PyDT, PyDT)],
) -> Array[(PyDT, PyDT)] raise @core.SqlglotError {
  if ranges.is_empty() {
    return []
  }
  let sorted = ranges.copy()
  // insertion sort with Python tuple ordering
  for i in 1..<sorted.length() {
    let mut j = i
    while j > 0 {
      let a = sorted[j - 1]
      let b = sorted[j]
      let c = pydt_cmp(a.0, b.0)
      let greater = c > 0 || (c == 0 && pydt_cmp(a.1, b.1) > 0)
      if !greater {
        break
      }
      sorted[j - 1] = b
      sorted[j] = a
      j -= 1
    }
  }
  let merged = [sorted[0]]
  for i in 1..<sorted.length() {
    let (start, end) = sorted[i]
    let (last_start, last_end) = merged[merged.length() - 1]
    if pydt_cmp(start, last_end) <= 0 {
      let m = if pydt_cmp(end, last_end) > 0 { end } else { last_end }
      merged[merged.length() - 1] = (last_start, m)
    } else {
      merged.push((start, end))
    }
  }
  merged
}
