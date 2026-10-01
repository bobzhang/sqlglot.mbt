// Date/time/unit helpers of sqlglot/dialects/dialect.py used by dialect generators.

///|
/// Python `date_add_interval_sql(data_type, kind)`: `<data_type>_<kind>(this, INTERVAL ...)`.
pub fn date_add_interval_sql(data_type : String, kind : String) -> GenFn {
  (g, e) => {
    let this = g.sql_key(e, "this")
    let interval = mk(Interval, [
      ("this", e.expression()),
      ("unit", unit_to_var(e)),
    ])
    data_type + "_" + kind + "(" + this + ", " + g.sql(Some(interval)) + ")"
  }
}

///|
/// Python `timestamptrunc_sql(func="DATE_TRUNC", zone=False)`.
pub fn timestamptrunc_sql(
  func? : String = "DATE_TRUNC",
  zone? : Bool = false,
) -> GenFn {
  (g, e) => {
    let args : Array[&SqlArg] = [weekstart_unit_to_str(g, e), e.this()]
    if zone {
      args.push(e.get("zone"))
    }
    g.func(func, args)
  }
}

///|
/// Python `no_timestamp_sql`.
pub fn no_timestamp_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  match e.arg("zone") {
    None => {
      let target_type = match gen_annotate_types(e, g.dialect).get_type() {
        Some(t) => t
        None => datatype_of(DType::TIMESTAMP)
      }
      g.sql(Some(exp_cast_to(e.this_(), target_type)))
    }
    Some(zone) =>
      if timezones.contains(py_lower(zone.name())) {
        g.sql(
          Some(
            mk(AtTimeZone, [
              ("this", exp_cast(e.this_(), DType::TIMESTAMP)),
              ("zone", zone),
            ]),
          ),
        )
      } else {
        g.func("TIMESTAMP", [e.this(), Some(zone)])
      }
  }
}

///|
/// Python `no_time_sql`: transpiles BigQuery's TIME(timestamp, zone) to
/// `CAST(CAST(<timestamp> AS TIMESTAMPTZ) AT TIME ZONE <zone> AS TIME)`.
pub fn no_time_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let this = exp_cast(e.this_(), DType::TIMESTAMPTZ)
  let expr = exp_cast(
    mk(AtTimeZone, [("this", Some(this)), ("zone", e.arg("zone"))]),
    DType::TIME,
  )
  g.sql(Some(expr))
}

///|
/// Python `no_datetime_sql`.
pub fn no_datetime_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let this = e.this_()
  // Python raises AttributeError here when the expression is missing; raise
  // instead of aborting the whole process
  guard e.expression() is Some(expr) else {
    raise ValueError("'NoneType' object has no attribute 'name'")
  }
  if timezones.contains(py_lower(expr.name())) {
    // Transpile BigQuery's DATETIME(timestamp, zone) to
    // CAST(CAST(<timestamp> AS TIMESTAMPTZ) AT TIME ZONE <zone> AS TIMESTAMP)
    let this = exp_cast(this, DType::TIMESTAMPTZ)
    let this = exp_cast(
      mk(AtTimeZone, [("this", this), ("zone", expr)]),
      DType::TIMESTAMP,
    )
    return g.sql(Some(this))
  }
  let this = exp_cast(this, DType::DATE)
  let expr = exp_cast(expr, DType::TIME)
  g.sql(Some(exp_cast(mk2(Add, this, expr), DType::TIMESTAMP)))
}

///|
/// Python `timestrtotime_sql(self, expression, include_precision=False)`.
pub fn timestrtotime_sql(
  g : Generator,
  e : Expr,
  include_precision? : Bool = false,
) -> String raise SqlglotError {
  let builder = if e.has("zone") {
    DType::TIMESTAMPTZ
  } else {
    DType::TIMESTAMP
  }
  let mut datatype = datatype_of(builder)
  match e.this() {
    Some(this) if this.kind.is_a(Literal) && include_precision => {
      let precision = subsecond_precision(this.name())
      if precision > 0 {
        datatype = datatype_build(builder, kwargs=[
          ("expressions", [mk1(DataTypeParam, literal_int(precision))]),
        ])
      }
    }
    _ => ()
  }
  g.sql(Some(exp_cast_to(e.this_(), datatype, dialect=g.dialect)))
}

///|
/// Python `datestrtodate_sql`.
pub fn datestrtodate_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.sql(Some(exp_cast(e.this_(), DType::DATE)))
}

///|
/// Python `TsOrDsAdd.return_type`: `DataType.build(return_type or DATE)`.
pub fn ts_or_ds_add_return_type(e : Expr) -> Expr {
  match e.arg("return_type") {
    Some(t) => t.copy()
    None =>
      match e.get("return_type") {
        Some(DT(d)) => datatype_of(d)
        _ => datatype_of(DType::DATE)
      }
  }
}

///|
/// Python `ts_or_ds_add_cast`.
pub fn ts_or_ds_add_cast(e : Expr) -> Expr {
  let mut this = e.this_().copy()
  let return_type = ts_or_ds_add_return_type(e)
  if return_type.is_type([DType::DATE]) {
    // If we need to cast to a DATE, we cast to TIMESTAMP first to make sure we can
    // truncate timestamp strings, because some dialects can't cast them to DATE
    this = exp_cast(this, DType::TIMESTAMP)
  }
  e.this_().replace(Some(exp_cast_to(this, return_type))) |> ignore
  e
}

///|
/// Python `remove_ts_or_ds_to_date(to_sql=None, args=("this",))`.
pub fn remove_ts_or_ds_to_date(
  to_sql? : GenFn,
  args? : Array[String] = ["this"],
) -> GenFn {
  (g, e) => {
    for arg_key in args {
      match e.arg(arg_key) {
        Some(a) if a.kind.is_any([TsOrDsToDate, TsOrDsToTimestamp]) &&
          !a.has("format") => e.set(arg_key, a.this())
        _ => ()
      }
    }
    match to_sql {
      Some(f) => f(g, e)
      None => g.function_fallback_sql(e)
    }
  }
}

///|
/// Python `date_delta_sql(name, cast=False)`: `name(unit, expression, this)`.
pub fn date_delta_sql(name : String, cast? : Bool = false) -> GenFn {
  (g, e) => {
    let e = if cast && e.kind.is_a(TsOrDsAdd) {
      ts_or_ds_add_cast(e)
    } else {
      e
    }
    g.func(name, [unit_to_var(e), e.expression(), e.this()])
  }
}

///|
/// Python `date_delta_to_binary_interval_op(cast=True)`: `this +/- INTERVAL ...`.
pub fn date_delta_to_binary_interval_op(cast? : Bool = true) -> GenFn {
  (g, e) => {
    let mut this = e.this_()
    let unit = unit_to_var(e)
    let op = if e.kind.is_any([
        DateAdd,
        TimeAdd,
        DatetimeAdd,
        TsOrDsAdd,
        TimestampAdd,
      ]) {
      "+"
    } else {
      "-"
    }
    let mut to_type : Expr? = None
    if cast {
      if e.kind.is_a(TsOrDsAdd) {
        to_type = Some(ts_or_ds_add_return_type(e))
      } else if this.is_string() {
        // Cast string literals (i.e function parameters) to the appropriate type for
        // +/- interval to work
        to_type = Some(
          datatype_of(
            if e.kind.is_any([DatetimeAdd, DatetimeSub]) {
              DType::DATETIME
            } else {
              DType::DATE
            },
          ),
        )
      }
    }
    match to_type {
      Some(t) => this = exp_cast_to(this, t)
      None => ()
    }
    let expr = e.expression_()
    let interval = if expr.kind.is_a(Interval) {
      expr
    } else {
      mk(Interval, [("this", Some(expr)), ("unit", unit)])
    }
    g.sql(Some(this)) + " " + op + " " + g.sql(Some(interval))
  }
}

///|
/// Python `unit_to_str(expression, default="DAY")`. Pass `default=""` for Python `None`.
pub fn unit_to_str(e : Expr, default? : String = "DAY") -> Expr? {
  match e.get("unit") {
    Some(Node(unit)) =>
      if unit.kind.is_a(WeekStart) {
        // WEEK(<day>) is BigQuery-only syntax, so it degrades to the plain WEEK unit.
        // Callers that need a warning about a changed week start should use
        // weekstart_unit_to_str
        Some(literal_string("WEEK"))
      } else if unit.kind.is_a(Placeholder) ||
        (unit.kind != Var && unit.kind != Literal) {
        Some(unit)
      } else {
        Some(literal_string(unit.name()))
      }
    Some(v) if v.truthy() => Some(literal_string(value_name(v)))
    _ => if default != "" { Some(literal_string(default)) } else { None }
  }
}

///|
/// Python `.name` of a non-expression argument value.
fn value_name(v : Value) -> String {
  match v {
    Str(s) => s
    Int(i) => i.to_string()
    _ => ""
  }
}

///|
/// Python `weekstart_unit_to_str(self, expression, default="DAY")`.
pub fn weekstart_unit_to_str(
  g : Generator,
  e : Expr,
  default? : String = "DAY",
) -> Expr? raise SqlglotError {
  match e.arg("unit") {
    Some(unit) if unit.kind.is_a(WeekStart) =>
      Some(literal_string(g.weekstart_name(unit)))
    _ => unit_to_str(e, default~)
  }
}

///|
/// Python `unit_to_var(expression, default="DAY")`. Pass `default=""` for Python `None`.
pub fn unit_to_var(e : Expr, default? : String = "DAY") -> Expr? {
  let value = match e.get("unit") {
    Some(Node(unit)) => {
      if unit.kind.is_any([Var, Placeholder, WeekStart, Column]) {
        return Some(unit)
      }
      unit.name()
    }
    Some(v) if v.truthy() => value_name(v)
    _ => default
  }
  if value != "" {
    Some(var_(value))
  } else {
    None
  }
}

///|
/// Python `WEEK_START_DAY_TO_DOW`: days of week to ISO 8601 day-of-week numbers
/// (Monday=1, ..., Sunday=7).
pub let week_start_day_to_dow : Map[String, Int] = {
  "MONDAY": 1,
  "TUESDAY": 2,
  "WEDNESDAY": 3,
  "THURSDAY": 4,
  "FRIDAY": 5,
  "SATURDAY": 6,
  "SUNDAY": 7,
}

///|
/// Python `week_offset_to_dow(offset)`: converts a dialect's WEEK_OFFSET (days relative
/// to Monday) to the ISO day number of its week start.
pub fn week_offset_to_dow(offset : Int) -> Int {
  let m = offset % 7
  (if m < 0 { m + 7 } else { m }) + 1
}

///|
/// Python `week_unit_to_dow(unit)`: the ISO 8601 week start day (Monday=1 .. Sunday=7) of
/// a week-ish unit, e.g. BigQuery's WEEK(<day>) or ISOWEEK, or None if not a week unit or
/// if the day is dynamic.
pub fn week_unit_to_dow(unit : Expr?) -> Int? {
  match unit {
    Some(u) if u.kind.is_a(Var) => {
      let n = py_upper(u.name())
      if n == "WEEK" || n == "ISOWEEK" {
        Some(1)
      } else {
        None
      }
    }
    Some(u) if u.kind.is_a(WeekStart) =>
      week_start_day_to_dow.get(py_upper(u.name()))
    _ => None
  }
}

///|
/// Python `map_date_part(part, dialect)`. `dialect` defaults to the base dialect.
pub fn map_date_part(part : Expr?, dialect? : Dialect) -> Expr? {
  guard part is Some(p) else { return None }
  if p.kind.is_a(Column) && p.parts().length() != 1 {
    return part
  }
  let d = match dialect {
    Some(d) => d
    None => base_dialect()
  }
  match d.cfg.date_part_mapping.get(py_upper(p.name())) {
    Some(mapped) if mapped != "" =>
      Some(if p.is_string() { literal_string(mapped) } else { var_(mapped) })
    _ => part
  }
}

///|
/// Python `map_date_part(part, dialect)` for a non-optional part.
pub fn map_date_part_expr(part : Expr, dialect? : Dialect) -> Expr {
  match map_date_part(Some(part), dialect?) {
    Some(p) => p
    None => part
  }
}
