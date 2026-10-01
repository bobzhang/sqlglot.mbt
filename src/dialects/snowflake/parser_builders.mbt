// Port of the module-level function builders of sqlglot/parsers/snowflake.py

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i >= 0 && i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn expr_or(a : @core.Expr?, b : () -> @core.Expr?) -> @core.Expr? {
  match a {
    Some(_) => a
    None => b()
  }
}

///|
/// `helper.is_date_unit`
fn is_date_unit(e : @core.Expr?) -> Bool {
  match e {
    Some(u) =>
      ["day", "week", "month", "quarter", "year", "year_month"].contains(
        @core.py_lower(u.name()),
      )
    None => false
  }
}

///|
fn build_approx_top_k(args : Array[@core.Expr]) -> @core.Expr {
  let args = args.copy()
  if args.length() == 1 {
    args.push(@core.literal_number("1"))
  }
  @core.from_arg_list(ApproxTopK, args)
}

///|
fn build_to_number(args : Array[@core.Expr], safe : Bool) -> @core.Expr {
  let second_arg = seq_get(args, 1)
  let (fmt, precision, scale) = match second_arg {
    Some(s) if s.is_number() =>
      (
        None,
        second_arg,
        expr_or(seq_get(args, 2), () => Some(@core.literal_number("0"))),
      )
    _ =>
      (
        second_arg,
        expr_or(seq_get(args, 2), () => Some(@core.literal_number("38"))),
        expr_or(seq_get(args, 3), () => Some(@core.literal_number("0"))),
      )
  }
  @core.mk(ToNumber, [
    ("this", seq_get(args, 0)),
    ("format", fmt),
    ("precision", precision),
    ("scale", scale),
    ("safe", safe),
  ])
}

///|
fn build_date_from_parts(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(DateFromParts, [
    ("year", seq_get(args, 0)),
    ("month", seq_get(args, 1)),
    ("day", seq_get(args, 2)),
    ("allow_overflow", true),
  ])
}

///|
/// `TIMESTAMP_TYPES`
fn timestamp_type_func(dtype : @core.DType) -> String? {
  match dtype {
    TIMESTAMP => Some("TO_TIMESTAMP")
    TIMESTAMPLTZ => Some("TO_TIMESTAMP_LTZ")
    TIMESTAMPNTZ => Some("TO_TIMESTAMP_NTZ")
    TIMESTAMPTZ => Some("TO_TIMESTAMP_TZ")
    _ => None
  }
}

///|
fn build_datetime(
  name : String,
  kind : @core.DType,
  safe? : Bool = false,
) -> @core.FuncBuilder {
  (args, p) => {
    let value = seq_get(args, 0)
    let scale_or_fmt = seq_get(args, 1)
    let int_value = match value {
      Some(v) => @core.is_int_str(v.name())
      None => false
    }
    let int_scale_or_fmt = match scale_or_fmt {
      Some(s) => s.is_int()
      None => false
    }
    let is_lit = match value {
      Some(v) => v.kind == Literal || v.kind == Neg
      None => false
    }
    if is_lit || (value is Some(_) && scale_or_fmt is Some(_)) {
      let v = value.unwrap()
      // Converts calls like `TO_TIME('01:02:03')` into casts
      if args.length() == 1 && v.is_string() && !int_value {
        let cast = if safe {
          @core.mk(TryCast, [
            ("this", v),
            ("to", kind.into_expr()),
            ("requires_string", true),
          ])
        } else {
          @core.exp_cast(v, kind)
        }
        if safe && kind == DATE {
          cast.set("probe_date_format", true)
        }
        return cast
      }
      // Handles `TO_TIMESTAMP(str, fmt)` and `TO_TIMESTAMP(num, scale)` as special
      // cases so we can transpile them, since they're relatively common
      if timestamp_type_func(kind) is Some(_) {
        if !safe && (int_scale_or_fmt || (int_value && scale_or_fmt is None)) {
          let unix_expr = @core.mk(UnixToTime, [
            ("this", value),
            ("scale", scale_or_fmt),
          ])
          unix_expr.set("target_type", kind.into_expr())
          return unix_expr
        }
        if scale_or_fmt is Some(_) && !int_scale_or_fmt {
          let strtotime_expr = @core.build_formatted_time(StrToTime)(args, p)
          strtotime_expr.set("safe", safe)
          strtotime_expr.set("target_type", kind.into_expr())
          return strtotime_expr
        }
      }
    }
    // Handle DATE/TIME with format strings - allow int_value if a format string is provided
    let has_format_string = scale_or_fmt is Some(_) && !int_scale_or_fmt
    if (kind == DATE || kind == TIME) && (!int_value || has_format_string) {
      let klass : @core.Kind = if kind == DATE {
        TsOrDsToDate
      } else {
        TsOrDsToTime
      }
      let formatted_exp = @core.build_formatted_time(klass)(args, p)
      formatted_exp.set("safe", safe)
      return formatted_exp
    }
    @core.mk(Anonymous, [("this", name), ("expressions", args)])
  }
}

///|
fn build_bitwise(kind : @core.Kind, name : String) -> @core.FuncBuilder {
  (args, p) => {
    if args.length() == 3 {
      // Special handling for bitwise operations with padside argument
      if kind == BitwiseAnd || kind == BitwiseOr || kind == BitwiseXor {
        return @core.mk(kind, [
          ("this", seq_get(args, 0)),
          ("expression", seq_get(args, 1)),
          ("padside", seq_get(args, 2)),
        ])
      }
      return @core.mk(Anonymous, [("this", name), ("expressions", args)])
    }
    let result = @core.binary_from_function(kind)(args, p)
    // Snowflake specifies INT128 for bitwise shifts
    if kind == BitwiseLeftShift || kind == BitwiseRightShift {
      result.set("requires_int128", true)
    }
    result
  }
}

///|
fn wrap_binary_opt(e : @core.Expr?) -> @core.Expr? {
  match e {
    Some(x) => Some(@core.exp_wrap(x, Binary))
    None => None
  }
}

///|
/// https://docs.snowflake.com/en/sql-reference/functions/div0
fn build_if_from_div0(args : Array[@core.Expr]) -> @core.Expr {
  let lhs = wrap_binary_opt(seq_get(args, 0))
  let rhs = wrap_binary_opt(seq_get(args, 1))
  let cond = @core.exp_and([
    @core.mk(EQ, [("this", rhs), ("expression", @core.literal_number("0"))]),
    @core.exp_not(@core.mk(Is, [("this", lhs), ("expression", @core.null_())])),
  ])
  let true_ = @core.literal_number("0")
  let false_ = @core.mk(Div, [("this", lhs), ("expression", rhs)])
  @core.mk(If, [("this", cond), ("true", true_), ("false", false_)])
}

///|
/// https://docs.snowflake.com/en/sql-reference/functions/div0null
fn build_if_from_div0null(args : Array[@core.Expr]) -> @core.Expr {
  let lhs = wrap_binary_opt(seq_get(args, 0))
  let rhs = wrap_binary_opt(seq_get(args, 1))
  // Returns 0 when divisor is 0 OR NULL
  let cond = @core.exp_or([
    @core.mk(EQ, [("this", rhs), ("expression", @core.literal_number("0"))]),
    @core.mk(Is, [("this", rhs), ("expression", @core.null_())]),
  ])
  let true_ = @core.literal_number("0")
  let false_ = @core.mk(Div, [("this", lhs), ("expression", rhs)])
  @core.mk(If, [("this", cond), ("true", true_), ("false", false_)])
}

///|
/// https://docs.snowflake.com/en/sql-reference/functions/zeroifnull
fn build_if_from_zeroifnull(args : Array[@core.Expr]) -> @core.Expr {
  let cond = @core.mk(Is, [
    ("this", seq_get(args, 0)),
    ("expression", @core.null_()),
  ])
  @core.mk(If, [
    ("this", cond),
    ("true", @core.literal_number("0")),
    ("false", seq_get(args, 0)),
  ])
}

///|
fn build_search(args : Array[@core.Expr]) -> @core.Expr {
  let e = @core.mk(Search, [
    ("this", seq_get(args, 0)),
    ("expression", seq_get(args, 1)),
  ])
  for i in 2..<args.length() {
    let arg = args[i]
    if arg.kind == Kwarg {
      e.set(@core.py_lower(arg.name()), arg)
    }
  }
  e
}

///|
/// https://docs.snowflake.com/en/sql-reference/functions/nullifzero
fn build_if_from_nullifzero(args : Array[@core.Expr]) -> @core.Expr {
  let cond = @core.mk(EQ, [
    ("this", seq_get(args, 0)),
    ("expression", @core.literal_number("0")),
  ])
  @core.mk(If, [
    ("this", cond),
    ("true", @core.null_()),
    ("false", seq_get(args, 0)),
  ])
}

///|
fn build_regexp_replace(args : Array[@core.Expr]) -> @core.Expr {
  let regexp_replace = @core.from_arg_list(RegexpReplace, args)
  if !regexp_replace.has("replacement") {
    regexp_replace.set("replacement", @core.literal_string(""))
  }
  regexp_replace
}

///|
fn build_regexp_like(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(RegexpLike, [
    ("this", seq_get(args, 0)),
    ("expression", seq_get(args, 1)),
    ("flag", seq_get(args, 2)),
    ("full_match", true),
  ])
}

///|
fn date_trunc_to_time_sf(args : Array[@core.Expr]) -> @core.Expr {
  let trunc = @core.date_trunc_to_time(args)
  let unit = @core.map_date_part(trunc.arg("unit"))
  trunc.set("unit", unit)
  let is_time_input = match trunc.this() {
    Some(t) => t.is_type([TIME, TIMETZ])
    None => false
  }
  if (trunc.kind == TimestampTrunc && is_date_unit(unit)) ||
    is_time_input ||
    (trunc.kind == DateTrunc && !is_date_unit(unit)) {
    trunc.set("input_type_preserved", true)
  }
  trunc
}

///|
fn build_regexp_extract_sf(kind : @core.Kind) -> @core.FuncBuilder {
  (args, p) => {
    let e = @core.mk(kind, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("position", seq_get(args, 2)),
      ("occurrence", seq_get(args, 3)),
      ("parameters", seq_get(args, 4)),
      (
        "group",
        expr_or(seq_get(args, 5), () => Some(@core.literal_number("0"))),
      ),
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
/// TIMESTAMP_FROM_PARTS(year, month, day, hour, minute, second [, nanosecond] [, time_zone])
/// or TIMESTAMP_FROM_PARTS(date_expr, time_expr)
fn build_timestamp_from_parts_sf(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 2 {
    return @core.mk(TimestampFromParts, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
    ])
  }
  @core.from_arg_list(TimestampFromParts, args)
}

///|
/// Build Round expression, unwrapping Snowflake's named parameters.
fn build_round(args : Array[@core.Expr]) -> @core.Expr {
  let round_args : Array[(String, &@core.IntoValue)] = []
  let positional_keys = ["this", "decimals", "truncate"]
  let mut positional_idx = 0
  for arg in args {
    if arg.kind == Kwarg {
      let key = match arg.this() {
        Some(t) => @core.py_upper(t.name())
        None => ""
      }
      let round_key = match key {
        "EXPR" => Some("this")
        "SCALE" => Some("decimals")
        "ROUNDING_MODE" => Some("truncate")
        _ => None
      }
      if round_key is Some(k) {
        round_args.push((k, arg.expression()))
      }
    } else if positional_idx < positional_keys.length() {
      round_args.push((positional_keys[positional_idx], arg))
      positional_idx += 1
    }
  }
  let expression = @core.mk(Round, round_args)
  expression.set("casts_non_integer_decimals", true)
  expression
}

///|
fn build_array_sort(args : Array[@core.Expr]) -> @core.Expr {
  let asc = seq_get(args, 1)
  let mut nulls_first = seq_get(args, 2)
  if nulls_first is None {
    match asc {
      Some(a) if a.kind == Boolean =>
        nulls_first = Some(@core.boolean(!a.bool_arg("this")))
      _ => ()
    }
  }
  @core.mk(SortArray, [
    ("this", seq_get(args, 0)),
    ("asc", asc),
    ("nulls_first", nulls_first),
  ])
}

///|
/// Build Generator expression, unwrapping Snowflake's named parameters.
fn build_generator(args : Array[@core.Expr]) -> @core.Expr {
  let gen_args : Array[(String, &@core.IntoValue)] = []
  let positional_keys = ["rowcount", "timelimit"]
  for i, arg in args {
    if arg.kind == Kwarg {
      let key = match arg.this() {
        Some(t) => @core.py_upper(t.name())
        None => ""
      }
      let gen_key = match key {
        "ROWCOUNT" => Some("rowcount")
        "TIMELIMIT" => Some("timelimit")
        _ => None
      }
      if gen_key is Some(k) {
        gen_args.push((k, arg.expression()))
      }
    } else if i < positional_keys.length() {
      gen_args.push((positional_keys[i], arg))
    }
  }
  @core.mk(Generator, gen_args)
}

///|
/// `build_object_construct` (shared by the parser and the generator).
fn build_object_construct(args : Array[@core.Expr]) -> @core.Expr {
  let expression = @core.build_var_map(args)
  if expression.kind == StarMap {
    return expression
  }
  let keys = match expression.arg("keys") {
    Some(k) => k.expressions()
    None => []
  }
  let values = match expression.arg("values") {
    Some(v) => v.expressions()
    None => []
  }
  let n = @core.min_int(keys.length(), values.length())
  let props = []
  for i in 0..<n {
    props.push(
      @core.mk(PropertyEQ, [("this", keys[i]), ("expression", values[i])]),
    )
  }
  @core.mk(Struct, [("expressions", props)])
}

///|
fn map_date_part_arg(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  @core.map_date_part(seq_get(args, i))
}

///|
fn build_date_diff(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(DateDiff, [
    ("this", seq_get(args, 2)),
    ("expression", seq_get(args, 1)),
    ("unit", map_date_part_arg(args, 0)),
    ("date_part_boundary", true),
  ])
}

///|
fn build_date_time_add(kind : @core.Kind) -> (Array[@core.Expr]) -> @core.Expr {
  fn(args) {
    @core.mk(kind, [
      ("this", seq_get(args, 2)),
      ("expression", seq_get(args, 1)),
      ("unit", map_date_part_arg(args, 0)),
    ])
  }
}

///|
fn fb(f : (Array[@core.Expr]) -> @core.Expr) -> @core.FuncBuilder {
  (args, _) => f(args)
}

///|
fn register_functions(fns : @core.ParserFns) -> Unit {
  let f = fns.functions
  let a = @core.from_arg_list_builder
  f["CHARINDEX"] = fb(args => {
    @core.mk(StrPosition, [
      ("this", seq_get(args, 1)),
      ("substr", seq_get(args, 0)),
      ("position", seq_get(args, 2)),
      ("clamp_position", true),
    ])
  })
  f["ADD_MONTHS"] = fb(args => {
    @core.mk(AddMonths, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("preserve_end_of_month", true),
    ])
  })
  f["APPROX_PERCENTILE"] = a(ApproxQuantile)
  f["CURRENT_TIME"] = fb(args => {
    @core.mk(Localtime, [("this", seq_get(args, 0))])
  })
  f["APPROX_TOP_K"] = fb(build_approx_top_k)
  f["ARRAY_CONSTRUCT"] = fb(args => @core.mk(Array, [("expressions", args)]))
  f["ARRAY_CONTAINS"] = fb(args => {
    @core.mk(ArrayContains, [
      ("this", seq_get(args, 1)),
      ("expression", seq_get(args, 0)),
      ("ensure_variant", false),
      ("check_null", true),
    ])
  })
  f["ARRAY_DISTINCT"] = fb(args => {
    @core.mk(ArrayDistinct, [("this", seq_get(args, 0)), ("check_null", true)])
  })
  f["ARRAY_GENERATE_RANGE"] = fb(build_array_generate_range)
  f["ARRAY_EXCEPT"] = fb(args => {
    @core.mk(ArrayExcept, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("is_multiset", true),
    ])
  })
  f["ARRAY_INTERSECTION"] = fb(args => {
    @core.mk(ArrayIntersect, [("expressions", args), ("is_multiset", true)])
  })
  f["ARRAY_POSITION"] = fb(args => {
    @core.mk(ArrayPosition, [
      ("this", seq_get(args, 1)),
      ("expression", seq_get(args, 0)),
      ("zero_based", true),
    ])
  })
  f["ARRAY_SLICE"] = fb(args => {
    @core.mk(ArraySlice, [
      ("this", seq_get(args, 0)),
      ("start", seq_get(args, 1)),
      ("end", seq_get(args, 2)),
      ("zero_based", true),
    ])
  })
  f["ARRAY_SORT"] = fb(build_array_sort)
  f["ARRAY_FLATTEN"] = a(Flatten)
  f["ARRAY_TO_STRING"] = fb(args => {
    @core.mk(ArrayToString, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("null_is_empty", true),
      ("null_delim_is_null", true),
    ])
  })
  f["ARRAYS_OVERLAP"] = fb(args => {
    @core.mk(ArrayOverlaps, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("null_safe", true),
    ])
  })
  f["BITAND"] = build_bitwise(BitwiseAnd, "BITAND")
  f["BIT_AND"] = build_bitwise(BitwiseAnd, "BITAND")
  f["BITNOT"] = fb(args => @core.mk(BitwiseNot, [("this", seq_get(args, 0))]))
  f["BIT_NOT"] = fb(args => @core.mk(BitwiseNot, [("this", seq_get(args, 0))]))
  f["BITXOR"] = build_bitwise(BitwiseXor, "BITXOR")
  f["BIT_XOR"] = build_bitwise(BitwiseXor, "BITXOR")
  f["BITOR"] = build_bitwise(BitwiseOr, "BITOR")
  f["BIT_OR"] = build_bitwise(BitwiseOr, "BITOR")
  f["BITSHIFTLEFT"] = build_bitwise(BitwiseLeftShift, "BITSHIFTLEFT")
  f["BIT_SHIFTLEFT"] = build_bitwise(BitwiseLeftShift, "BIT_SHIFTLEFT")
  f["BITSHIFTRIGHT"] = build_bitwise(BitwiseRightShift, "BITSHIFTRIGHT")
  f["BIT_SHIFTRIGHT"] = build_bitwise(BitwiseRightShift, "BIT_SHIFTRIGHT")
  for name in ["BITANDAGG", "BITAND_AGG", "BIT_AND_AGG", "BIT_ANDAGG"] {
    f[name] = a(BitwiseAndAgg)
  }
  for name in ["BITORAGG", "BITOR_AGG", "BIT_OR_AGG", "BIT_ORAGG"] {
    f[name] = a(BitwiseOrAgg)
  }
  for name in ["BITXORAGG", "BITXOR_AGG", "BIT_XOR_AGG", "BIT_XORAGG"] {
    f[name] = a(BitwiseXorAgg)
  }
  f["BITMAP_OR_AGG"] = a(BitmapOrAgg)
  f["BOOLAND"] = fb(args => {
    @core.mk(Booland, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("round_input", true),
    ])
  })
  f["BOOLOR"] = fb(args => {
    @core.mk(Boolor, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("round_input", true),
    ])
  })
  f["BOOLNOT"] = fb(args => {
    @core.mk(Boolnot, [("this", seq_get(args, 0)), ("round_input", true)])
  })
  f["BOOLXOR"] = fb(args => {
    @core.mk(Xor, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("round_input", true),
    ])
  })
  f["CORR"] = fb(args => {
    @core.mk(Corr, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("null_on_zero_variance", true),
    ])
  })
  f["COUNT_IF"] = fb(args => {
    @core.mk(CountIf, [("this", seq_get(args, 0)), ("zero_on_all_null", true)])
  })
  f["DATE"] = build_datetime("DATE", DATE)
  f["DATEFROMPARTS"] = fb(build_date_from_parts)
  f["DATE_FROM_PARTS"] = fb(build_date_from_parts)
  f["DATE_TRUNC"] = fb(date_trunc_to_time_sf)
  f["DATEADD"] = fb(build_date_time_add(DateAdd))
  f["DATEDIFF"] = fb(build_date_diff)
  f["DAYNAME"] = fb(args => {
    @core.mk(Dayname, [("this", seq_get(args, 0)), ("abbreviated", true)])
  })
  f["DAYOFWEEKISO"] = a(DayOfWeekIso)
  f["DIV0"] = fb(build_if_from_div0)
  f["DIV0NULL"] = fb(build_if_from_div0null)
  f["EDITDISTANCE"] = fb(args => {
    @core.mk(Levenshtein, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("max_dist", seq_get(args, 2)),
    ])
  })
  f["FLATTEN"] = a(Explode)
  f["GENERATOR"] = fb(build_generator)
  f["GET"] = a(GetExtract)
  f["GETDATE"] = a(CurrentTimestamp)
  f["GET_PATH"] = (args, p) => {
    @core.mk(JSONExtract, [
      ("this", seq_get(args, 0)),
      ("expression", p.dialect.to_json_path(seq_get(args, 1))),
      ("requires_json", true),
    ])
  }
  f["GREATEST_IGNORE_NULLS"] = fb(args => {
    @core.mk(Greatest, [
      ("this", seq_get(args, 0)),
      ("expressions", args[1:].to_owned()),
      ("ignore_nulls", true),
    ])
  })
  f["LEAST_IGNORE_NULLS"] = fb(args => {
    @core.mk(Least, [
      ("this", seq_get(args, 0)),
      ("expressions", args[1:].to_owned()),
      ("ignore_nulls", true),
    ])
  })
  f["LEFT"] = fb(args => {
    @core.mk(Left, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("negative_length_returns_empty", true),
    ])
  })
  f["HEX_DECODE_BINARY"] = a(Unhex)
  f["HEX_ENCODE"] = a(Hex)
  f["IFF"] = a(If)
  f["JAROWINKLER_SIMILARITY"] = fb(args => {
    @core.mk(JarowinklerSimilarity, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("case_insensitive", true),
      ("integer_scale", true),
    ])
  })
  f["MD5_HEX"] = a(MD5)
  f["MD5_BINARY"] = a(MD5Digest)
  f["MD5_NUMBER_LOWER64"] = a(MD5NumberLower64)
  f["MD5_NUMBER_UPPER64"] = a(MD5NumberUpper64)
  f["MONTHNAME"] = fb(args => {
    @core.mk(Monthname, [("this", seq_get(args, 0)), ("abbreviated", true)])
  })
  f["LAST_DAY"] = fb(args => {
    @core.mk(LastDay, [
      ("this", seq_get(args, 0)),
      ("unit", map_date_part_arg(args, 1)),
    ])
  })
  f["LEN"] = fb(args => {
    @core.mk(Length, [("this", seq_get(args, 0)), ("binary", true)])
  })
  f["LENGTH"] = fb(args => {
    @core.mk(Length, [("this", seq_get(args, 0)), ("binary", true)])
  })
  f["LOCALTIMESTAMP"] = a(CurrentTimestamp)
  f["NULLIFZERO"] = fb(build_if_from_nullifzero)
  f["OBJECT_CONSTRUCT"] = fb(build_object_construct)
  f["OBJECT_KEYS"] = a(JSONKeys)
  f["OCTET_LENGTH"] = a(ByteLength)
  f["PARSE_URL"] = fb(args => {
    @core.mk(ParseUrl, [
      ("this", seq_get(args, 0)),
      ("permissive", seq_get(args, 1)),
    ])
  })
  f["REGEXP_EXTRACT_ALL"] = build_regexp_extract_sf(RegexpExtractAll)
  f["REGEXP_LIKE"] = fb(build_regexp_like)
  f["REGEXP_REPLACE"] = fb(build_regexp_replace)
  f["REGEXP_SUBSTR"] = build_regexp_extract_sf(RegexpExtract)
  f["REGEXP_SUBSTR_ALL"] = build_regexp_extract_sf(RegexpExtractAll)
  f["RANDOM"] = fb(args => {
    @core.mk(Rand, [
      ("this", seq_get(args, 0)),
      ("lower", @core.literal_number("-9.223372036854776E+18")),
      ("upper", @core.literal_number("9.223372036854776e+18")),
    ])
  })
  f["REPLACE"] = fb(@core.build_replace_with_optional_replacement)
  f["RIGHT"] = fb(args => {
    @core.mk(Right, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("negative_length_returns_empty", true),
    ])
  })
  f["RLIKE"] = fb(build_regexp_like)
  f["ROUND"] = fb(build_round)
  f["SHA1_BINARY"] = a(SHA1Digest)
  f["SHA1_HEX"] = a(SHA)
  f["SHA2_BINARY"] = a(SHA2Digest)
  f["SHA2_HEX"] = a(SHA2)
  f["SPLIT"] = fb(args => {
    @core.mk(Split, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("null_returns_null", true),
      ("empty_delimiter_returns_whole", true),
    ])
  })
  f["SQUARE"] = fb(args => {
    @core.mk(Pow, [
      ("this", seq_get(args, 0)),
      ("expression", @core.literal_number("2")),
    ])
  })
  f["STDDEV_SAMP"] = a(Stddev)
  f["SYSDATE"] = fb(args => {
    @core.mk(CurrentTimestamp, [("this", seq_get(args, 0)), ("sysdate", true)])
  })
  f["TABLE"] = fb(args => @core.mk(TableFromRows, [("this", seq_get(args, 0))]))
  f["TIMEADD"] = fb(build_date_time_add(TimeAdd))
  f["TIMEDIFF"] = fb(build_date_diff)
  f["TIME_FROM_PARTS"] = fb(args => {
    @core.mk(TimeFromParts, [
      ("hour", seq_get(args, 0)),
      ("min", seq_get(args, 1)),
      ("sec", seq_get(args, 2)),
      ("nano", seq_get(args, 3)),
      ("overflow", true),
    ])
  })
  f["TIMESTAMPADD"] = fb(build_date_time_add(DateAdd))
  f["TIMESTAMPDIFF"] = fb(build_date_diff)
  for
    name in [
      "TIMESTAMPFROMPARTS", "TIMESTAMP_FROM_PARTS", "TIMESTAMPNTZFROMPARTS", "TIMESTAMP_NTZ_FROM_PARTS",
    ] {
    f[name] = fb(build_timestamp_from_parts_sf)
  }
  f["TRUNC"] = (args, p) => {
    @core.build_trunc(
      args,
      p.dialect,
      date_trunc_requires_part=false,
      fractions_supported=true,
    )
  }
  f["TRUNCATE"] = (args, p) => {
    @core.build_trunc(
      args,
      p.dialect,
      date_trunc_requires_part=false,
      fractions_supported=true,
    )
  }
  f["TRY_DECRYPT"] = fb(args => {
    @core.mk(Decrypt, [
      ("this", seq_get(args, 0)),
      ("passphrase", seq_get(args, 1)),
      ("aad", seq_get(args, 2)),
      ("encryption_method", seq_get(args, 3)),
      ("safe", true),
    ])
  })
  f["TRY_DECRYPT_RAW"] = fb(args => {
    @core.mk(DecryptRaw, [
      ("this", seq_get(args, 0)),
      ("key", seq_get(args, 1)),
      ("iv", seq_get(args, 2)),
      ("aad", seq_get(args, 3)),
      ("encryption_method", seq_get(args, 4)),
      ("aead", seq_get(args, 5)),
      ("safe", true),
    ])
  })
  f["TRY_PARSE_JSON"] = fb(args => {
    @core.mk(ParseJSON, [("this", seq_get(args, 0)), ("safe", true)])
  })
  f["TRY_TO_BINARY"] = fb(args => {
    @core.mk(ToBinary, [
      ("this", seq_get(args, 0)),
      ("format", seq_get(args, 1)),
      ("safe", true),
    ])
  })
  f["TRY_TO_BOOLEAN"] = fb(args => {
    @core.mk(ToBoolean, [("this", seq_get(args, 0)), ("safe", true)])
  })
  f["TRY_TO_DATE"] = build_datetime("TRY_TO_DATE", DATE, safe=true)
  for name in ["TRY_TO_DECIMAL", "TRY_TO_NUMBER", "TRY_TO_NUMERIC"] {
    f[name] = fb(args => build_to_number(args, true))
  }
  f["TRY_TO_DOUBLE"] = fb(args => {
    @core.mk(ToDouble, [
      ("this", seq_get(args, 0)),
      ("format", seq_get(args, 1)),
      ("safe", true),
    ])
  })
  f["TRY_TO_FILE"] = fb(args => {
    @core.mk(ToFile, [
      ("this", seq_get(args, 0)),
      ("path", seq_get(args, 1)),
      ("safe", true),
    ])
  })
  f["TRY_TO_TIME"] = build_datetime("TRY_TO_TIME", TIME, safe=true)
  f["TRY_TO_TIMESTAMP"] = build_datetime(
    "TRY_TO_TIMESTAMP",
    TIMESTAMP,
    safe=true,
  )
  f["TRY_TO_TIMESTAMP_LTZ"] = build_datetime(
    "TRY_TO_TIMESTAMP_LTZ",
    TIMESTAMPLTZ,
    safe=true,
  )
  f["TRY_TO_TIMESTAMP_NTZ"] = build_datetime(
    "TRY_TO_TIMESTAMP_NTZ",
    TIMESTAMPNTZ,
    safe=true,
  )
  f["TRY_TO_TIMESTAMP_TZ"] = build_datetime(
    "TRY_TO_TIMESTAMP_TZ",
    TIMESTAMPTZ,
    safe=true,
  )
  f["TO_CHAR"] = (args, p) => @core.build_timetostr_or_tochar(args, p.dialect)
  f["TO_DATE"] = build_datetime("TO_DATE", DATE)
  for name in ["TO_DECIMAL", "TO_NUMBER", "TO_NUMERIC"] {
    f[name] = fb(args => build_to_number(args, false))
  }
  f["TO_TIME"] = build_datetime("TO_TIME", TIME)
  f["TO_TIMESTAMP"] = build_datetime("TO_TIMESTAMP", TIMESTAMP)
  f["TO_TIMESTAMP_LTZ"] = build_datetime("TO_TIMESTAMP_LTZ", TIMESTAMPLTZ)
  f["TO_TIMESTAMP_NTZ"] = build_datetime("TO_TIMESTAMP_NTZ", TIMESTAMPNTZ)
  f["TO_TIMESTAMP_TZ"] = build_datetime("TO_TIMESTAMP_TZ", TIMESTAMPTZ)
  f["TO_GEOGRAPHY"] = fb(args => {
    if args.length() == 1 {
      @core.exp_cast(args[0], GEOGRAPHY)
    } else {
      @core.mk(Anonymous, [("this", "TO_GEOGRAPHY"), ("expressions", args)])
    }
  })
  f["TO_GEOMETRY"] = fb(args => {
    if args.length() == 1 {
      @core.exp_cast(args[0], GEOMETRY)
    } else {
      @core.mk(Anonymous, [("this", "TO_GEOMETRY"), ("expressions", args)])
    }
  })
  f["TO_VARCHAR"] = (args, p) => {
    @core.build_timetostr_or_tochar(args, p.dialect)
  }
  f["TO_JSON"] = a(JSONFormat)
  f["VECTOR_COSINE_SIMILARITY"] = a(CosineDistance)
  f["VECTOR_INNER_PRODUCT"] = a(DotProduct)
  f["VECTOR_L1_DISTANCE"] = a(ManhattanDistance)
  f["VECTOR_L2_DISTANCE"] = a(EuclideanDistance)
  f["ZEROIFNULL"] = fb(build_if_from_zeroifnull)
  f["LIKE"] = @core.build_like_fn(Like)
  f["ILIKE"] = @core.build_like_fn(ILike)
  f["SEARCH"] = fb(build_search)
  f["SKEW"] = a(Skewness)
  f["SPLIT_PART"] = fb(args => {
    @core.mk(SplitPart, [
      ("this", seq_get(args, 0)),
      ("delimiter", seq_get(args, 1)),
      ("part_index", seq_get(args, 2)),
      ("part_index_zero_as_one", true),
      ("empty_delimiter_returns_whole", true),
    ])
  })
  f["STRTOK"] = fb(args => {
    @core.mk(Strtok, [
      ("this", seq_get(args, 0)),
      (
        "delimiter",
        expr_or(seq_get(args, 1), () => Some(@core.literal_string(" "))),
      ),
      (
        "part_index",
        expr_or(seq_get(args, 2), () => Some(@core.literal_number("1"))),
      ),
    ])
  })
  f["STRTOK_TO_ARRAY"] = fb(args => {
    @core.mk(StrtokToArray, [
      ("this", seq_get(args, 0)),
      (
        "expression",
        expr_or(seq_get(args, 1), () => Some(@core.literal_string(" "))),
      ),
    ])
  })
  f["SYSTIMESTAMP"] = a(CurrentTimestamp)
  f["IDENTIFIER"] = a(DynamicIdentifier)
  f["UNICODE"] = fb(args => {
    @core.mk(Unicode, [("this", seq_get(args, 0)), ("empty_is_zero", true)])
  })
  f["WEEKISO"] = a(WeekOfYear)
  f["WEEKOFYEAR"] = a(Week)
  f.remove("PREDICT")
}

///|
/// `SnowflakeParser.FUNCTIONS["ARRAY_GENERATE_RANGE"]`
fn build_array_generate_range(args : Array[@core.Expr]) -> @core.Expr {
  // Snowflake has exclusive end semantics
  @core.mk(GenerateSeries, [
    ("start", seq_get(args, 0)),
    ("end", seq_get(args, 1)),
    ("step", seq_get(args, 2)),
    ("is_end_exclusive", true),
  ])
}
