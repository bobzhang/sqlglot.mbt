// Parser builder helpers of sqlglot/dialects/dialect.py (`FUNCTIONS` entries).
//
// Conventions:
//   * Python `def f(args)` -> `pub fn f(args : Array[Expr]) -> Expr` (wrap it as
//     `fn(args, _p) { f(args) }` to use it as a `FuncBuilder`).
//   * Python `def f(args, dialect)` -> `pub fn f(args : Array[Expr], dialect : Dialect)`.
//   * Python factories returning builders return a `FuncBuilder` (whose `Parser` argument
//     provides the dialect).

///|
/// Python `build_formatted_time(exp_class, dialect_override, default)(args, dialect)`.
/// `default=true` uses the dialect's TIME_FORMAT; `default_format` is a string default.
pub fn build_formatted_time_expr(
  kind : Kind,
  args : Array[Expr],
  dialect : Dialect,
  dialect_override? : String,
  default? : Bool = false,
  default_format? : String,
) -> Expr raise SqlglotError {
  let target_dialect = match dialect_override {
    Some(name) => Dialect::get_or_raise(name)
    None => dialect
  }
  // Python passes the raw (quoted) TIME_FORMAT / default string to `format_time`.
  let format = match arg(args, 1) {
    Some(f) => target_dialect.format_time(Some(f))
    None =>
      if default {
        Some(target_dialect.format_time_str(target_dialect.cfg.time_format))
      } else {
        match default_format {
          Some(s) if s != "" => Some(target_dialect.format_time_str(s))
          _ => None
        }
      }
  }
  mk(kind, [("this", arg(args, 0)), ("format", format)])
}

///|
/// Python `build_formatted_time(exp_class, dialect_override=None, default=None)`.
pub fn build_formatted_time(
  kind : Kind,
  dialect_override? : String,
  default? : Bool = false,
  default_format? : String,
) -> FuncBuilder {
  fn(args, p) raise SqlglotError {
    build_formatted_time_expr(
      kind,
      args,
      p.dialect,
      dialect_override?,
      default~,
      default_format?,
    )
  }
}

///|
/// Python `build_date_delta(exp_class, unit_mapping=None, default_unit="DAY",
/// supports_timezone=False)`. Pass `default_unit=""` for Python `None`.
pub fn build_date_delta(
  kind : Kind,
  unit_mapping? : Map[String, String],
  default_unit? : String = "DAY",
  supports_timezone? : Bool = false,
) -> FuncBuilder {
  fn(args, _p) {
    let unit_based = args.length() >= 3
    let has_timezone = args.length() == 4
    let this = if unit_based { Some(args[2]) } else { arg(args, 0) }
    let mut unit : Expr? = None
    if unit_based || default_unit != "" {
      let u = if unit_based { args[0] } else { literal_string(default_unit) }
      unit = Some(
        match unit_mapping {
          Some(m) if !m.is_empty() =>
            var_(
              match m.get(py_lower(u.name())) {
                Some(v) => v
                None => u.name()
              },
            )
          _ => u
        },
      )
    }
    let expression = mk(kind, [
      ("this", this),
      ("expression", arg(args, 1)),
      ("unit", unit),
    ])
    if supports_timezone && has_timezone {
      expression.set("zone", args[args.length() - 1])
    }
    expression
  }
}

///|
/// Python `build_date_delta_with_interval(expression_class, default_unit=None)`.
/// Python returns `None` for fewer than 2 arguments; this raises a ParseError instead.
pub fn build_date_delta_with_interval(
  kind : Kind,
  default_unit? : String,
) -> FuncBuilder {
  fn(args, _p) raise SqlglotError {
    if args.length() < 2 {
      raise ParseError(
        "\{kind.name()} expects at least 2 arguments, got \{args.length()}",
        [],
      )
    }
    let interval = args[1]
    if !interval.kind.is_a(Interval) {
      match default_unit {
        None =>
          raise ParseError(
            "INTERVAL expression expected but got '\{expr_to_sql(interval)}'",
            [],
          )
        Some(u) =>
          return mk(kind, [
            ("this", args[0]),
            ("expression", interval),
            ("unit", literal_string(u)),
          ])
      }
    }
    mk(kind, [
      ("this", Some(args[0])),
      ("expression", interval.this()),
      ("unit", unit_to_str(interval)),
    ])
  }
}

///|
/// Python `date_trunc_to_time(args)`.
pub fn date_trunc_to_time(args : Array[Expr]) -> Expr {
  let unit = arg(args, 0)
  let this = arg(args, 1)
  match this {
    Some(t) if t.kind.is_a(Cast) && t.is_type([DType::DATE]) =>
      mk(DateTrunc, [("unit", unit), ("this", this)])
    _ => mk(TimestampTrunc, [("this", this), ("unit", unit)])
  }
}

///|
/// Python `binary_from_function(expr_type)`.
pub fn binary_from_function(kind : Kind) -> FuncBuilder {
  fn(args, _p) {
    mk(kind, [("this", arg(args, 0)), ("expression", arg(args, 1))])
  }
}

///|
/// Python `build_timestamp_trunc(args)` (DATE_TRUNC in Doris, Postgres and StarRocks).
pub fn build_timestamp_trunc(args : Array[Expr]) -> Expr {
  mk(TimestampTrunc, [
    ("this", arg(args, 1)),
    ("unit", arg(args, 0)),
    ("zone", arg(args, 2)),
  ])
}

///|
/// Python `build_trunc(args, dialect, ...)`: builder for dialects with an overloaded
/// TRUNC (Oracle, Snowflake, etc). Uses type annotation to distinguish date vs numeric
/// truncation and returns Anonymous if the type cannot be determined.
pub fn build_trunc(
  args : Array[Expr],
  dialect : Dialect,
  date_trunc_unabbreviate? : Bool = true,
  default_date_trunc_unit? : String,
  date_trunc_requires_part? : Bool = true,
  fractions_supported? : Bool = false,
) -> Expr raise SqlglotError {
  let mut this = arg(args, 0)
  let mut second = arg(args, 1)
  match this {
    Some(t) if t.get_type() is None =>
      this = Some(gen_annotate_types(t, dialect))
    _ => ()
  }
  match second {
    Some(s) if s.get_type() is None =>
      second = Some(gen_annotate_types(s, dialect))
    _ => ()
  }
  let default_unit = match default_date_trunc_unit {
    Some(u) if u != "" => Some(u)
    _ => None
  }
  let is_type = fn(e : Expr?, types : Array[DType]) {
    match e {
      Some(x) => x.is_type(types)
      None => false
    }
  }
  if (
      is_type(this, dtype_temporal_types) &&
      (second is Some(_) || default_unit is Some(_))
    ) ||
    is_type(second, dtype_text_types) {
    let unit = match second {
      Some(s) => s
      None => literal_string(default_unit.unwrap_or(""))
    }
    return mk(DateTrunc, [
      ("this", this),
      ("unit", Some(unit)),
      ("unabbreviate", Some(date_trunc_unabbreviate)),
    ])
  }
  if is_type(this, dtype_numeric_types) ||
    is_type(second, dtype_numeric_types) ||
    (!date_trunc_requires_part && second is None) {
    return mk(Trunc, [
      ("this", this),
      ("decimals", second),
      ("fractions_supported", Some(fractions_supported)),
    ])
  }
  mk(Anonymous, [("this", "TRUNC"), ("expressions", args)])
}

///|
/// Python `isnull_to_is_null(args)`.
pub fn isnull_to_is_null(args : Array[Expr]) -> Expr {
  mk1(Paren, mk(Is, [("this", arg(args, 0)), ("expression", Some(null_()))]))
}

///|
/// Python `build_json_extract_path(expr_type, zero_based_indexing=True,
/// arrow_req_json_type=False, json_type=None)`. Like Python, it truncates `args` to 2
/// elements when the path is built.
pub fn build_json_extract_path(
  kind : Kind,
  zero_based_indexing? : Bool = true,
  arrow_req_json_type? : Bool = false,
  json_type? : String,
) -> FuncBuilder {
  (args, _p) => {
    let segments : Array[Expr] = [mk0(JSONPathRoot)]
    for i in 1..<args.length() {
      let a = args[i]
      if !a.kind.is_a(Literal) {
        // We use the fallback parser because we can't really transpile non-literals safely
        let rest_args : Array[Expr] = if args.length() > 2 {
          args[2:].to_owned()
        } else {
          []
        }
        return mk(kind, [
          ("this", arg(args, 0)),
          ("expression", arg(args, 1)),
          (
            "expressions",
            if rest_args.is_empty() {
              None
            } else {
              Some(rest_args)
            },
          ),
        ])
      }
      let text = a.name()
      match
        (if is_int_str(text) && (!arrow_req_json_type || !a.is_string()) {
          parse_int_checked(text)
        } else {
          None
        }) {
        Some(index) => {
          if !zero_based_indexing && index == -9223372036854775807L - 1L {
            raise int64_range_error("\{text} - 1")
          }
          segments.push(
            mk1(
              JSONPathSubscript,
              Value::Int(if zero_based_indexing { index } else { index - 1L }),
            ),
          )
        }
        _ => segments.push(mk1(JSONPathKey, text))
      }
    }
    // This is done to avoid failing in the expression validator due to the arg count
    args.truncate(2)
    let expression = mk(kind, [
      ("this", arg(args, 0)),
      ("expression", Some(mk(JSONPath, [("expressions", segments)]))),
    ])
    if !kind.is_any([JSONBExtract, JSONBExtractScalar]) {
      expression.set("only_json_types", arrow_req_json_type)
    }
    match json_type {
      Some(t) => expression.set("json_type", t)
      None => ()
    }
    expression
  }
}

///|
/// Python `build_default_decimal_type(precision=None, scale=None)`: a DataType
/// converter that adds default DECIMAL parameters.
pub fn build_default_decimal_type(
  precision? : Int,
  scale? : Int,
) -> (Expr) -> Expr {
  fn(dtype) {
    match precision {
      Some(p) if dtype.expressions().is_empty() => {
        let params = [mk1(DataTypeParam, literal_int(p))]
        match scale {
          Some(s) => params.push(mk1(DataTypeParam, literal_int(s)))
          None => ()
        }
        mk(DataType, [
          ("this", DType::DECIMAL),
          ("expressions", params),
          ("nested", false),
        ])
      }
      _ => dtype
    }
  }
}

///|
/// Python `build_timestamp_from_parts(args)`.
pub fn build_timestamp_from_parts(args : Array[Expr]) -> Expr {
  if args.length() == 2 {
    // Other dialects don't have the TIMESTAMP_FROM_PARTS(date, time) concept, so we
    // parse this into Anonymous for now instead of introducing complexity
    return mk(Anonymous, [
      ("this", "TIMESTAMP_FROM_PARTS"),
      ("expressions", args),
    ])
  }
  from_arg_list(TimestampFromParts, args)
}

///|
/// Python `build_like(expr_type, not_like=False)` from dialects/dialect.py (named
/// `build_like_fn` because the parser's `build_like(args)` already exists).
pub fn build_like_fn(kind : Kind, not_like? : Bool = false) -> FuncBuilder {
  fn(args, _p) {
    let mut like_expr = mk(kind, [
      ("this", arg(args, 0)),
      ("expression", arg(args, 1)),
    ])
    match arg(args, 2) {
      Some(escape) =>
        like_expr = mk(Escape, [("this", like_expr), ("expression", escape)])
      None => ()
    }
    if not_like {
      like_expr = mk1(Not, like_expr)
    }
    like_expr
  }
}

///|
/// Python `build_regexp_extract(expr_type)`.
pub fn build_regexp_extract(kind : Kind) -> FuncBuilder {
  fn(args, p) {
    // The "position" argument specifies the index of the string character to start
    // matching from. `null_if_pos_overflow` reflects the dialect's behavior when position
    // is greater than the string length: NULL if true, else an empty string. It's only
    // needed for RegexpExtract - RegexpExtractAll always returns an empty array.
    let group = match arg(args, 2) {
      Some(g) => g
      None => literal_int(p.dialect.cfg.regexp_extract_default_group)
    }
    let e = mk(kind, [
      ("this", arg(args, 0)),
      ("expression", arg(args, 1)),
      ("group", Some(group)),
      ("parameters", arg(args, 3)),
    ])
    if kind == RegexpExtract {
      e.set(
        "null_if_pos_overflow",
        p.dialect.cfg.regexp_extract_position_overflow_returns_null,
      )
    }
    e
  }
}

///|
/// Python `build_timetostr_or_tochar(args, dialect)`.
pub fn build_timetostr_or_tochar(
  args : Array[Expr],
  dialect : Dialect,
) -> Expr raise SqlglotError {
  if args.length() == 2 {
    let this = args[0]
    if this.get_type() is None {
      gen_annotate_types(this, dialect) |> ignore
    }
    if this.is_type(dtype_temporal_types) {
      return build_formatted_time_expr(TimeToStr, args, dialect, default=true)
    }
  }
  from_arg_list(ToChar, args)
}

///|
/// Python `build_replace_with_optional_replacement(args)`.
pub fn build_replace_with_optional_replacement(args : Array[Expr]) -> Expr {
  mk(Replace, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    (
      "replacement",
      Some(
        match arg(args, 2) {
          Some(r) => r
          None => literal_string("")
        },
      ),
    ),
  ])
}
