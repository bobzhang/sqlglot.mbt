// Port of sqlglot/parsers/clickhouse.py

///|
fn arg(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  args.get(i)
}

///|
fn build_datetime_format(kind : @core.Kind) -> @core.FuncBuilder {
  (args, p) => {
    let expr = @core.build_formatted_time(kind)(args, p)
    match arg(args, 2) {
      Some(timezone) => expr.set("zone", timezone)
      None => ()
    }
    expr
  }
}

///|
fn build_count_if(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 1 {
    return @core.mk1(CountIf, args[0])
  }
  @core.mk(CombinedAggFunc, [("this", "countIf"), ("expressions", args)])
}

///|
fn build_str_to_date(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 3 {
    return @core.mk(Anonymous, [("this", "STR_TO_DATE"), ("expressions", args)])
  }
  let strtodate = @core.from_arg_list(StrToDate, args)
  @core.cast_to(strtodate, @core.DType::DATETIME.into_expr())
}

///|
fn build_timestamp_trunc(unit : String) -> @core.FuncBuilder {
  (args, _) => {
    @core.mk(TimestampTrunc, [
      ("this", arg(args, 0)),
      ("unit", Some(@core.var_(unit))),
      ("zone", arg(args, 1)),
    ])
  }
}

///|
fn build_split(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    @core.mk(kind, [
      ("this", arg(args, 1)),
      ("expression", arg(args, 0)),
      ("limit", arg(args, 2)),
    ])
  }
}

///|
fn build_split_by_char(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  match arg(args, 0) {
    Some(sep) if sep.kind == Literal && sep.is_string() => {
      let value = sep.name()
      // len(sep_value.encode("utf-8")) == 1
      let chars = value.iter().collect()
      if chars.length() == 1 && chars[0].to_int() < 0x80 {
        return build_split(Split)(args, p)
      }
    }
    _ => ()
  }
  @core.mk(Anonymous, [("this", "splitByChar"), ("expressions", args)])
}

///|
fn build_array_lambda_func(
  kind : @core.Kind,
  name : String,
) -> @core.FuncBuilder {
  (args, _) => {
    // Other dialects can't express arrayMap((x, y) -> x + y, arr1, arr2), which
    // iterates over multiple arrays at once, so we keep it as an anonymous function
    if args.length() > 2 {
      return @core.mk(Anonymous, [("this", name), ("expressions", args)])
    }
    @core.mk(kind, [("this", arg(args, 1)), ("expression", arg(args, 0))])
  }
}

///|
/// Skip the 'week' unit since ClickHouse's toStartOfWeek uses an extra mode argument to
/// specify the first day of the week
let timestamp_trunc_units : Array[String] = [
  "MICROSECOND", "MILLISECOND", "SECOND", "MINUTE", "HOUR", "DAY", "MONTH", "QUARTER",
  "YEAR",
]

///|
let agg_functions : @set.Set[String] = @set.Set::from_array([
  "count", "min", "max", "sum", "avg", "any", "stddevPop", "stddevSamp", "varPop",
  "varSamp", "corr", "covarPop", "covarSamp", "entropy", "exponentialMovingAverage",
  "intervalLengthSum", "kolmogorovSmirnovTest", "mannWhitneyUTest", "median", "rankCorr",
  "sumKahan", "studentTTest", "welchTTest", "anyHeavy", "anyLast", "boundingRatio",
  "first_value", "last_value", "argMin", "argMax", "avgWeighted", "topK", "approx_top_sum",
  "topKWeighted", "deltaSum", "deltaSumTimestamp", "groupArray", "groupArrayLast",
  "groupConcat", "groupUniqArray", "groupArrayInsertAt", "groupArrayMovingAvg", "groupArrayMovingSum",
  "groupArraySample", "groupBitAnd", "groupBitOr", "groupBitXor", "groupBitmap",
  "groupBitmapAnd", "groupBitmapOr", "groupBitmapXor", "sumWithOverflow", "sumMap",
  "minMap", "maxMap", "skewSamp", "skewPop", "kurtSamp", "kurtPop", "uniq", "uniqExact",
  "uniqCombined", "uniqCombined64", "uniqHLL12", "uniqTheta", "quantile", "quantiles",
  "quantileExact", "quantileExactInclusive", "quantilesExact", "quantilesExactExclusive",
  "quantileExactLow", "quantilesExactLow", "quantileExactHigh", "quantilesExactHigh",
  "quantileExactWeighted", "quantilesExactWeighted", "quantileTiming", "quantilesTiming",
  "quantileTimingWeighted", "quantilesTimingWeighted", "quantileDeterministic", "quantilesDeterministic",
  "quantileTDigest", "quantilesTDigest", "quantileTDigestWeighted", "quantilesTDigestWeighted",
  "quantileBFloat16", "quantilesBFloat16", "quantileBFloat16Weighted", "quantilesBFloat16Weighted",
  "simpleLinearRegression", "stochasticLinearRegression", "stochasticLogisticRegression",
  "categoricalInformationValue", "contingency", "cramersV", "cramersVBiasCorrected",
  "theilsU", "maxIntersections", "maxIntersectionsPosition", "meanZTest", "quantileInterpolatedWeighted",
  "quantilesInterpolatedWeighted", "quantileGK", "quantilesGK", "sparkBar", "sumCount",
  "largestTriangleThreeBuckets", "histogram", "sequenceMatch", "sequenceCount", "windowFunnel",
  "retention", "uniqUpTo", "sequenceNextNode", "exponentialTimeDecayedAvg",
])

///|
/// Sorted longest-first so that compound suffixes (e.g. "SimpleState") are matched
/// before their sub-suffixes (e.g. "State") when resolving multi-combinator functions.
let agg_functions_suffixes : Array[String] = [
  "SimpleState", "MergeState", "OrDefault", "Distinct", "Resample", "ArrayIf", "ForEach",
  "OrNull", "ArgMin", "ArgMax", "Array", "State", "Merge", "Map", "If",
]

///|
/// `_AGG_FUNC_MAPPING.get(name)`: all 0- and 1-suffix aggregate function names.
fn agg_func_mapping(name : String) -> (String, String?)? {
  if agg_functions.contains(name) {
    return Some((name, None))
  }
  // Later dict entries (shorter suffixes) win in Python
  for i = agg_functions_suffixes.length() - 1; i >= 0; i = i - 1 {
    let sfx = agg_functions_suffixes[i]
    if name.has_suffix(sfx) {
      let f = @core.substr(name, 0, name.length() - sfx.length())
      if agg_functions.contains(f) {
        return Some((f, Some(sfx)))
      }
    }
  }
  None
}

///|
/// ClickHouse allows chaining multiple combinators on aggregate functions.
/// See https://clickhouse.com/docs/sql-reference/aggregate-functions/combinators
fn resolve_clickhouse_agg(name : String) -> (String, Array[String])? {
  let accumulated_suffixes : Array[String] = []
  let mut name = name
  let mut parts = agg_func_mapping(name)
  while parts is None {
    let mut found = false
    for suffix in agg_functions_suffixes {
      if name.has_suffix(suffix) && name.length() != suffix.length() {
        accumulated_suffixes.insert(0, suffix)
        name = @core.substr(name, 0, name.length() - suffix.length())
        found = true
        break
      }
    }
    if !found {
      return None
    }
    parts = agg_func_mapping(name)
  }
  let (agg_func_name, inner_suffix) = parts.unwrap()
  match inner_suffix {
    Some(s) => accumulated_suffixes.insert(0, s)
    None => ()
  }
  Some((agg_func_name, accumulated_suffixes))
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f.remove("TRANSFORM")
  f.remove("APPROX_TOP_SUM")
  for name in ["REGEXPEXTRACT", "REGEXP_EXTRACT", "REGEXP_SUBSTR"] {
    f[name] = (args, _) => {
      @core.mk(RegexpExtract, [
        ("this", arg(args, 0)),
        ("expression", arg(args, 1)),
        ("group", arg(args, 2)),
      ])
    }
  }
  for unit in timestamp_trunc_units {
    f["TOSTARTOF" + unit] = build_timestamp_trunc(unit)
  }
  f["ANY"] = @core.from_arg_list_builder(AnyValue)
  f["ARRAYCOMPACT"] = @core.from_arg_list_builder(ArrayCompact)
  f["ARRAYCONCAT"] = @core.from_arg_list_builder(ArrayConcat)
  f["ARRAYDISTINCT"] = @core.from_arg_list_builder(ArrayDistinct)
  f["ARRAYEXCEPT"] = @core.from_arg_list_builder(ArrayExcept)
  f["ARRAYSUM"] = @core.from_arg_list_builder(ArraySum)
  f["ARRAYMAX"] = @core.from_arg_list_builder(ArrayMax)
  f["ARRAYMIN"] = @core.from_arg_list_builder(ArrayMin)
  f["ARRAYREVERSE"] = @core.from_arg_list_builder(ArrayReverse)
  f["ARRAYSLICE"] = @core.from_arg_list_builder(ArraySlice)
  f["ARRAYFILTER"] = build_array_lambda_func(ArrayFilter, "arrayFilter")
  f["ARRAYMAP"] = build_array_lambda_func(Transform, "arrayMap")
  f["CURRENTDATABASE"] = @core.from_arg_list_builder(CurrentDatabase)
  f["CURRENTSCHEMAS"] = @core.from_arg_list_builder(CurrentSchemas)
  f["COUNTIF"] = (args, _) => build_count_if(args)
  f["CITYHASH64"] = @core.from_arg_list_builder(CityHash64)
  f["COSINEDISTANCE"] = @core.from_arg_list_builder(CosineDistance)
  f["VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  f["DATE_ADD"] = @core.build_date_delta(DateAdd, default_unit="")
  f["DATEADD"] = @core.build_date_delta(DateAdd, default_unit="")
  f["DATE_DIFF"] = @core.build_date_delta(
    DateDiff,
    default_unit="",
    supports_timezone=true,
  )
  f["DATEDIFF"] = @core.build_date_delta(
    DateDiff,
    default_unit="",
    supports_timezone=true,
  )
  f["DATE_FORMAT"] = build_datetime_format(TimeToStr)
  f["DATE_SUB"] = @core.build_date_delta(DateSub, default_unit="")
  f["DATESUB"] = @core.build_date_delta(DateSub, default_unit="")
  f["DATETRUNC"] = @core.from_arg_list_builder(DateTrunc)
  f["FORMATDATETIME"] = build_datetime_format(TimeToStr)
  f["HAS"] = @core.from_arg_list_builder(ArrayContains)
  f["ILIKE"] = @core.build_like_fn(ILike)
  f["JSONEXTRACTSTRING"] = @core.build_json_extract_path(
    JSONExtractScalar,
    zero_based_indexing=false,
  )
  f["LENGTH"] = (args, _) => {
    @core.mk(Length, [("this", arg(args, 0)), ("binary", true)])
  }
  f["LIKE"] = @core.build_like_fn(Like)
  f["L2Distance"] = @core.from_arg_list_builder(EuclideanDistance)
  f["MAP"] = (args, _) => @core.build_var_map(args)
  f["MATCH"] = @core.from_arg_list_builder(RegexpLike)
  f["NOTLIKE"] = @core.build_like_fn(Like, not_like=true)
  f["PARSEDATETIME"] = build_datetime_format(ParseDatetime)
  f["RANDCANONICAL"] = @core.from_arg_list_builder(Rand)
  f["STR_TO_DATE"] = (args, _) => build_str_to_date(args)
  f["TIMESTAMP_SUB"] = @core.build_date_delta(TimestampSub, default_unit="")
  f["TIMESTAMPSUB"] = @core.build_date_delta(TimestampSub, default_unit="")
  f["TIMESTAMP_ADD"] = @core.build_date_delta(TimestampAdd, default_unit="")
  f["TIMESTAMPADD"] = @core.build_date_delta(TimestampAdd, default_unit="")
  f["TOMONDAY"] = build_timestamp_trunc("WEEK")
  f["UNIQ"] = @core.from_arg_list_builder(ApproxDistinct)
  f["MD5"] = @core.from_arg_list_builder(MD5Digest)
  f["SHA256"] = (args, _) => {
    @core.mk(SHA2, [
      ("this", arg(args, 0)),
      ("length", Some(@core.literal_number("256"))),
    ])
  }
  f["SHA512"] = (args, _) => {
    @core.mk(SHA2, [
      ("this", arg(args, 0)),
      ("length", Some(@core.literal_number("512"))),
    ])
  }
  f["SPLITBYCHAR"] = build_split_by_char
  f["SPLITBYREGEXP"] = build_split(RegexpSplit)
  f["SPLITBYSTRING"] = build_split(Split)
  f["SUBSTRINGINDEX"] = @core.from_arg_list_builder(SubstringIndex)
  f["TOTYPENAME"] = @core.from_arg_list_builder(Typeof)
  f["TRIMBOTH"] = @core.from_arg_list_builder(Trim)
  f["TRIMLEFT"] = (args, _) => @core.build_trim(args)
  f["TRIMRIGHT"] = (args, _) => @core.build_trim(args, is_left=false)
  f["EDITDISTANCE"] = @core.from_arg_list_builder(Levenshtein)
  f["JAROWINKLERSIMILARITY"] = @core.from_arg_list_builder(
    JarowinklerSimilarity,
  )
  f["LEVENSHTEINDISTANCE"] = @core.from_arg_list_builder(Levenshtein)
  f["UTCTIMESTAMP"] = @core.from_arg_list_builder(UtcTimestamp)

  // FUNCTION_PARSERS
  let fp = fns.function_parsers
  fp.remove("MATCH")
  fp["ARRAYJOIN"] = p => {
    Some(p.expression(@core.mk1(Explode, p.parse_expression())))
  }
  fp["GROUPCONCAT"] = p => p.parse_group_concat()
  fp["QUANTILE"] = parse_quantile
  fp["MEDIAN"] = parse_quantile
  fp["COLUMNS"] = parse_columns
  fp["TUPLE"] = p => {
    Some(@core.from_arg_list(Struct, p.parse_function_args(alias_=true)))
  }
  fp["AND"] = p => p.parse_connector_function(And)
  fp["OR"] = p => p.parse_connector_function(Or)
  fp["XOR"] = p => {
    Some(@core.combine_conditions(p.parse_function_args(alias_=false), Xor))
  }
  fp["VIEW"] = p => {
    let select = p.parse_select()
    Some(
      p.expression(
        @core.mk(Anonymous, [
          ("this", "view"),
          ("expressions", select.map(s => [s]).unwrap_or([])),
        ]),
      ),
    )
  }

  // PROPERTY_PARSERS
  let pp = fns.property_parsers
  pp.remove("DYNAMIC")
  pp["ENGINE"] = (p, _) => Some(Node(parse_engine_property(p)))
  pp["REFRESH"] = (p, _) => {
    match parse_auto_refresh_property(p) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  pp["UUID"] = (p, _) => {
    Some(Node(p.expression(@core.mk1(UuidProperty, p.parse_string()))))
  }
  fns.no_paren_function_parsers.remove("ANY")
  fns.range_parsers[GLOBAL] = parse_global_in
  fns.column_operators.remove(PLACEHOLDER)
  fns.column_operators[DOTCARET] = Some((p, this, field) => {
    Some(
      p.expression(
        @core.mk(NestedJSONSelect, [("this", this), ("expression", field)]),
      ),
    )
  })
  fns.query_modifier_parsers[SETTINGS] = p => {
    p.advance()
    (
      "settings",
      Some(@core.Value::List(nodes(p.parse_csv(() => p.parse_assignment())))),
    )
  }
  fns.query_modifier_parsers[FORMAT] = p => {
    p.advance()
    ("format", p.parse_id_var().map(e => @core.Value::Node(e)))
  }
  fns.constraint_parsers["INDEX"] = p => Some(parse_index_constraint(p))
  fns.constraint_parsers["CODEC"] = p => p.parse_compress()
  fns.constraint_parsers["ASSUME"] = p => {
    Some(
      p.expression(
        @core.mk1(AssumeColumnConstraint, parse_wrapped_select_or_assignment(p)),
      ),
    )
  }
  fns.alter_parsers["MODIFY"] = p => {
    p.parse_alter_table_alter().map(e => @core.Value::Node(e))
  }
  fns.alter_parsers["REPLACE"] = p => {
    parse_alter_table_replace(p).map(e => @core.Value::Node(e))
  }
  fns.placeholder_parsers[L_BRACE] = parse_query_parameter
  fns.statement_parsers[DETACH] = p => Some(parse_detach(p))

  // Method overrides
  let h = fns.hooks
  h.parse_check_constraint = Some(p => {
    Some(
      p.expression(
        @core.mk1(CheckColumnConstraint, parse_wrapped_select_or_assignment(p)),
      ),
    )
  })
  h.parse_user_defined_function_expression = Some(p => p.parse_lambda())
  h.parse_types = Some(parse_types)
  h.parse_extract = Some(parse_extract)
  h.parse_assignment = Some(parse_assignment)
  h.parse_bracket = Some(parse_bracket)
  h.parse_table = Some(parse_table)
  h.parse_position = Some((p, _) => p.parse_position_base(haystack_first=true))
  h.parse_cte = Some(parse_cte)
  h.parse_join_parts = Some(parse_join_parts)
  h.parse_join = Some(parse_join)
  h.parse_function = Some(parse_function)
  h.parse_group_concat = Some(parse_group_concat)
  h.parse_wrapped_id_vars = Some((p, _) => {
    p.parse_wrapped_csv(() => p.parse_id_var(), optional=true)
  })
  h.parse_column_def = Some((p, this, computed_column) => {
    if p.match_(DOT) {
      return Some(
        @core.mk(Dot, [("this", this), ("expression", p.parse_id_var())]),
      )
    }
    p.parse_column_def_base(this, computed_column~)
  })
  h.parse_primary_key = Some((p, wrapped_optional, in_props, named_primary_key) => {
    p.parse_primary_key_base(
      wrapped_optional=wrapped_optional || in_props,
      in_props~,
      named_primary_key~,
    )
  })
  h.parse_on_property = Some(parse_on_property)
  h.parse_partition = Some(parse_partition)
  h.parse_alter_table_alter = Some(parse_alter_table_alter)
  h.parse_definer = Some(p => {
    p.match_(EQ) |> ignore
    if p.match_(CURRENT_USER) {
      return Some(
        @core.mk1(DefinerProperty, @core.var_(@core.py_upper(p.prev.text))),
      )
    }
    Some(@core.mk1(DefinerProperty, p.parse_string()))
  })
  h.parse_constraint = Some(p => {
    match p.parse_constraint_base() {
      Some(c) => Some(c)
      None => parse_projection_def(p)
    }
  })
  h.parse_alias = Some((p, this, explicit) => {
    // In clickhouse "SELECT <expr> APPLY(...)" is a query modifier, so "APPLY" shouldn't
    // be parsed as <expr>'s alias. However, "SELECT <expr> apply" is a valid alias
    if p.match_pair(APPLY, L_PAREN, advance=false) {
      return this
    }
    p.parse_alias_base(this, explicit~)
  })
  h.parse_expression = Some(parse_expression)
  h.parse_value = Some(parse_value)
  h.parse_partitioned_by = Some(p => {
    // ClickHouse allows custom expressions as partition key
    Some(p.expression(@core.mk1(PartitionedByProperty, p.parse_assignment())))
  })
}

///|
fn nodes(es : Array[@core.Expr]) -> Array[@core.Value] {
  es.map(e => @core.Value::Node(e))
}

///|
fn parse_wrapped_select_or_assignment(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.parse_wrapped(
    () => {
      match p.parse_select() {
        Some(s) => Some(s)
        None => p.parse_assignment()
      }
    },
    optional=true,
  )
}

///|
fn parse_engine_property(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  p.match_(EQ) |> ignore
  p.expression(
    @core.mk1(
      EngineProperty,
      p.parse_field(any_token=true, anonymous_func=true),
    ),
  )
}

///|
fn parse_types(
  p : @core.Parser,
  check_func : Bool,
  schema : Bool,
  allow_identifiers : Bool,
  with_collation : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let dtype = p.parse_types_base(
    check_func~,
    schema~,
    allow_identifiers~,
    with_collation~,
  )
  match dtype {
    Some(dt) if dt.kind.is_a(DataType) &&
      !(dt.get("nullable") is Some(Bool(true))) =>
      // Mark every type as non-nullable which is ClickHouse's default, unless it's
      // already marked as nullable. This marker helps us transpile types from other
      // dialects to ClickHouse, so that we can e.g. produce `CAST(x AS Nullable(String))`
      // from `CAST(x AS TEXT)`. If there is a `NULL` value in `x`, the former would
      // fail in ClickHouse without the `Nullable` type constructor.
      dt.set("nullable", false)
    _ => ()
  }
  dtype
}

///|
fn parse_extract(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  let this = p.parse_bitwise()
  if p.match_(FROM) {
    p.retreat(index)
    return p.parse_extract_base()
  }
  // We return Anonymous here because extract and regexpExtract have different semantics,
  // so parsing extract(foo, bar) into RegexpExtract can potentially break queries.
  p.match_(COMMA) |> ignore
  let second = p.parse_bitwise()
  let exprs : Array[@core.Expr] = []
  match this {
    Some(t) => exprs.push(t)
    None => ()
  }
  match second {
    Some(t) => exprs.push(t)
    None => ()
  }
  Some(
    p.expression(
      @core.mk(Anonymous, [("this", "extract"), ("expressions", exprs)]),
    ),
  )
}

///|
fn parse_assignment(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_assignment_base()
  if p.match_(PLACEHOLDER) {
    let true_ = p.parse_assignment()
    let false_ : @core.Value? = if p.match_(COLON) {
      p.parse_assignment().map(e => @core.Value::Node(e))
    } else {
      Some(Bool(false))
    }
    return Some(
      p.expression(
        @core.mk(If, [("this", this), ("true", true_), ("false", false_)]),
      ),
    )
  }
  this
}

///|
/// Parse a placeholder expression like SELECT {abc: UInt32} or FROM {table: Identifier}
fn parse_query_parameter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  let mut this = p.parse_id_var()
  p.match_(COLON) |> ignore
  let kind : @core.Value? = match
    p.parse_types(check_func=false, allow_identifiers=false) {
    Some(k) => Some(Node(k))
    None =>
      if p.match_text_seq(["IDENTIFIER"]) {
        Some(Str("Identifier"))
      } else {
        None
      }
  }
  if kind is None {
    p.retreat(index)
    return None
  } else if !p.match_(R_BRACE) {
    p.raise_error("Expecting }")
  }
  match this {
    Some(t) if t.kind == Identifier && !t.has("quoted") =>
      this = Some(@core.var_(t.name()))
    _ => ()
  }
  Some(p.expression(@core.mk(Placeholder, [("this", this), ("kind", kind)])))
}

///|
fn parse_bracket(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  if this is Some(_) {
    let mut bracket_json_type : @core.Expr? = None
    while p.match_pair(L_BRACKET, R_BRACKET) {
      let inner = match bracket_json_type {
        Some(t) => t
        None => @core.datatype_build(JSON, kwargs=[("nullable", false)])
      }
      bracket_json_type = Some(
        @core.mk(DataType, [
          ("this", @core.DType::ARRAY),
          ("expressions", [inner]),
          ("nested", true),
        ]),
      )
    }
    if bracket_json_type is Some(t) {
      return Some(p.expression(@core.mk(JSONCast, [("this", this), ("to", t)])))
    }
  }
  let l_brace = p.match_(L_BRACE, advance=false)
  let bracket = p.parse_bracket_base(this)
  match bracket {
    Some(b) if l_brace && b.kind == Struct => {
      let keys = @core.mk0(Array)
      let values = @core.mk0(Array)
      let varmap = @core.mk(VarMap, [("keys", keys), ("values", values)])
      for expression in b.expressions() {
        if expression.kind != PropertyEQ {
          break
        }
        keys.append("expressions", @core.literal_string(expression.name()))
        values.append("expressions", expression.expression())
      }
      Some(varmap)
    }
    _ => bracket
  }
}

///|
fn parse_global_in(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index - 1
  let is_negated = p.match_(NOT)
  if !p.match_(IN) {
    p.retreat(index)
    return None
  }
  let in_expr = p.parse_in(this)
  match in_expr {
    Some(e) => e.set("is_global", true)
    None => ()
  }
  if is_negated {
    Some(p.expression(@core.mk1(Not, in_expr)))
  } else {
    in_expr
  }
}

///|
fn parse_table(
  p : @core.Parser,
  args : @core.TableArgs,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.parse_table_base({
    ..args,
    parse_partition: false,
    consume_pipe: false,
  })
  match this {
    Some(t) if t.kind == Table =>
      match (t.this(), t.arg("alias")) {
        (Some(inner), Some(alias_)) if inner.kind.is_a(GenerateSeries) &&
          alias_.list("columns").is_empty() =>
          alias_.set("columns", [@core.to_identifier("generate_series")])
        _ => ()
      }
    _ => ()
  }
  if p.match_(FINAL) {
    this = Some(p.expression(@core.mk1(Final, this)))
  }
  this
}

///|
/// https://clickhouse.com/docs/en/sql-reference/statements/select/with/
fn parse_cte(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // WITH <identifier> AS <subquery expression>
  match p.try_parse(() => p.parse_cte_base()) {
    Some(cte) => Some(cte)
    None => {
      // WITH <expression> AS <identifier>
      let this = p.parse_assignment()
      let alias_ = p.parse_table_alias()
      Some(
        p.expression(
          @core.mk(CTE, [("this", this), ("alias", alias_), ("scalar", true)]),
        ),
      )
    }
  }
}

///|
fn parse_join_parts(
  p : @core.Parser,
) -> (@core.Token?, @core.Token?, @core.Token?) raise @core.SqlglotError {
  let is_global = if p.match_(GLOBAL) { Some(p.prev) } else { None }
  let kind_pre = if p.match_set(p.cfg.join_kinds) { Some(p.prev) } else { None }
  let side = if p.match_set(p.cfg.join_sides) { Some(p.prev) } else { None }
  let kind = if p.match_set(p.cfg.join_kinds) { Some(p.prev) } else { None }
  (
    is_global,
    if side is Some(_) {
      side
    } else {
      kind
    },
    if kind_pre is Some(_) {
      kind_pre
    } else {
      kind
    },
  )
}

///|
fn parse_join(
  p : @core.Parser,
  skip_join_token : Bool,
  _parse_bracket : Bool,
  alias_tokens : @core.TokenSet?,
) -> @core.Expr? raise @core.SqlglotError {
  let join = p.parse_join_base(
    skip_join_token~,
    parse_bracket=true,
    alias_tokens?,
  )
  match join {
    Some(j) => {
      let method_ = j.get("method")
      j.set("method", (None : @core.Expr?))
      j.set("global_", method_)
      // tbl ARRAY JOIN arr <-- this should be a `Column` reference, not a `Table`
      // https://clickhouse.com/docs/en/sql-reference/statements/select/array-join
      if j.text("kind") == "ARRAY" {
        let tables = j.find_all([Table]).collect()
        for table in tables {
          table.replace(Some(table.to_column())) |> ignore
        }
      }
    }
    None => ()
  }
  join
}

///|
fn parse_function(
  p : @core.Parser,
  functions : Map[String, @core.FuncBuilder]?,
  anonymous : Bool,
  optional_parens : Bool,
  any_token : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let mut expr = p.parse_function_base(
    functions?,
    anonymous~,
    optional_parens~,
    any_token~,
  )
  let func = match expr {
    Some(e) if e.kind == Window => e.this()
    _ => expr
  }
  // Aggregate functions can be split in 2 parts: <func_name><suffix[es]>
  guard func is Some(anon_func) && anon_func.kind == Anonymous else {
    return expr
  }
  guard resolve_clickhouse_agg(anon_func.name()) is Some(parts) else {
    return expr
  }
  let params = parse_func_params(p, this=anon_func)
  let has_params = params is Some(ps) && !ps.is_empty()
  let exp_class : @core.Kind = if parts.1.length() > 0 {
    if has_params {
      CombinedParameterizedAgg
    } else {
      CombinedAggFunc
    }
  } else if has_params {
    ParameterizedAgg
  } else {
    AnonymousAggFunc
  }
  let instance = @core.mk(exp_class, [
    ("this", anon_func.get("this")),
    ("expressions", anon_func.expressions()),
  ])
  if has_params {
    instance.set("params", params.unwrap())
  }
  let func = p.expression(instance)
  match expr {
    Some(e) if e.kind == Window =>
      // The window's func was parsed as Anonymous in base parser, fix its
      // type to be ClickHouse style CombinedAnonymousAggFunc / AnonymousAggFunc
      e.set("this", func)
    _ =>
      if has_params {
        // Params have blocked super()._parse_function() from parsing the following window
        // (if that exists) as they're standing between the function call and the window spec
        expr = p.parse_window(Some(func))
      } else {
        expr = Some(func)
      }
  }
  expr
}

///|
fn parse_func_params(
  p : @core.Parser,
  this? : @core.Expr,
) -> Array[@core.Expr]? raise @core.SqlglotError {
  if p.match_pair(R_PAREN, L_PAREN) {
    return Some(p.parse_csv(() => p.parse_lambda()))
  }
  if p.match_(L_PAREN) {
    let params = p.parse_csv(() => p.parse_lambda())
    p.match_r_paren(expression?=this)
    return Some(params)
  }
  None
}

///|
fn parse_group_concat(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let args = p.parse_csv(() => p.parse_lambda())
  let params = parse_func_params(p)
  match params {
    Some(ps) if !ps.is_empty() => {
      // groupConcat(sep [, limit])(expr)
      let separator = arg(args, 0)
      let limit = arg(args, 1)
      let mut this = arg(ps, 0)
      if limit is Some(_) {
        this = Some(@core.mk(Limit, [("this", this), ("expression", limit)]))
      }
      Some(
        p.expression(
          @core.mk(GroupConcat, [("this", this), ("separator", separator)]),
        ),
      )
    }
    // groupConcat(expr)
    _ => Some(p.expression(@core.mk1(GroupConcat, arg(args, 0))))
  }
}

///|
fn parse_quantile(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_lambda()
  let params = parse_func_params(p)
  match params {
    Some(ps) if !ps.is_empty() =>
      Some(
        p.expression(@core.mk(Quantile, [("this", ps[0]), ("quantile", this)])),
      )
    _ =>
      Some(
        p.expression(
          @core.mk(Quantile, [
            ("this", this),
            ("quantile", Some(@core.literal_number("0.5"))),
          ]),
        ),
      )
  }
}

///|
fn parse_on_property(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  if p.match_text_seq(["CLUSTER"]) {
    let this = match p.parse_string() {
      Some(s) => Some(s)
      None => p.parse_id_var()
    }
    match this {
      Some(t) => return Some(p.expression(@core.mk1(OnCluster, t)))
      None => p.retreat(index)
    }
  }
  None
}

///|
fn parse_interval_no_keyword(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.parse_interval(require_interval=false, parse_function_unit=false)
}

///|
fn parse_auto_refresh_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index - 1
  let cadence = if p.match_texts(["EVERY", "AFTER"]) {
    Some(@core.py_upper(p.prev.text))
  } else {
    None
  }
  let interval = if cadence is Some(_) {
    parse_interval_no_keyword(p)
  } else {
    None
  }
  if cadence is Some(_) && interval is None {
    p.retreat(index)
    return None
  }
  let mut offset = None
  if p.match_text_seq(["OFFSET"]) {
    offset = parse_interval_no_keyword(p)
    if offset is None {
      p.retreat(index)
      return None
    }
  }
  let mut randomize = None
  if p.match_text_seq(["RANDOMIZE", "FOR"]) {
    randomize = parse_interval_no_keyword(p)
    if randomize is None {
      p.retreat(index)
      return None
    }
  }
  let mut dependencies : Array[@core.Expr]? = None
  if p.match_text_seq(["DEPENDS", "ON"]) {
    let deps = p.parse_csv(() => p.parse_table_parts(schema=true))
    if deps.is_empty() {
      p.retreat(index)
      return None
    }
    dependencies = Some(deps)
  }
  if cadence is None && dependencies is None {
    p.retreat(index)
    return None
  }
  let settings = if p.match_text_seq(["SETTINGS"]) {
    Some(p.parse_settings_property())
  } else {
    None
  }
  let append = p.match_text_seq(["APPEND"])
  Some(
    p.expression(
      @core.mk(AutoRefreshProperty, [
        ("this", interval),
        ("cadence", cadence),
        ("offset", offset),
        ("randomize", randomize),
        ("expressions", dependencies),
        ("settings", settings),
        ("append", append),
      ]),
    ),
  )
}

///|
fn parse_index_constraint(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // INDEX name1 expr TYPE type1(args) GRANULARITY value
  let this = p.parse_id_var()
  let expression = p.parse_assignment()
  let index_type : @core.Value? = if p.match_text_seq(["TYPE"]) {
    match p.parse_function() {
      Some(f) => Some(Node(f))
      None => p.parse_var().map(e => @core.Value::Node(e))
    }
  } else {
    Some(Bool(false))
  }
  let granularity : @core.Value? = if p.match_text_seq(["GRANULARITY"]) {
    p.parse_term().map(e => @core.Value::Node(e))
  } else {
    Some(Bool(false))
  }
  p.expression(
    @core.mk(IndexColumnConstraint, [
      ("this", this),
      ("expression", expression),
      ("index_type", index_type),
      ("granularity", granularity),
    ]),
  )
}

///|
fn parse_partition(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // https://clickhouse.com/docs/en/sql-reference/statements/alter/partition#how-to-set-partition-expression
  if !p.match_(PARTITION) {
    return None
  }
  let expressions = if p.match_text_seq(["ID"]) {
    // Corresponds to the PARTITION ID <string_value> syntax
    [p.expression(@core.mk1(PartitionId, p.parse_string()))]
  } else {
    p.parse_expressions()
  }
  Some(p.expression(@core.mk(Partition, [("expressions", expressions)])))
}

///|
fn parse_alter_table_replace(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let partition = p.parse_partition()
  if partition is None || !p.match_(FROM) {
    return None
  }
  Some(
    p.expression(
      @core.mk(ReplacePartition, [
        ("expression", partition),
        ("source", p.parse_table_parts()),
      ]),
    ),
  )
}

///|
fn parse_alter_table_alter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // MODIFY forms other than MODIFY COLUMN (SQL SECURITY, ORDER BY, TTL, COMMENT, ...)
  // are parsed as properties, since ALTER can now reach this path too
  if @core.py_upper(p.prev.text) == "MODIFY" && !p.match_(COLUMN, advance=false) {
    match p.parse_properties() {
      Some(properties) =>
        return Some(
          p.expression(
            @core.mk(AlterModifySqlSecurity, [
              ("expressions", properties.expressions()),
            ]),
          ),
        )
      None => return None
    }
  }
  // https://clickhouse.com/docs/sql-reference/statements/alter/column#modify-column
  let alter = p.parse_alter_table_alter_base()
  if p.curr.ok() {
    None
  } else {
    alter
  }
}

///|
fn parse_projection_def(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if !p.match_(PROJECTION) {
    return None
  }
  let this = p.parse_id_var()
  let expression = p.parse_wrapped(() => p.parse_statement())
  Some(
    p.expression(
      @core.mk(ProjectionDef, [("this", this), ("expression", expression)]),
    ),
  )
}

///|
fn parse_expression(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.parse_alias(p.parse_assignment())
  // Clickhouse allows "SELECT <expr> [APPLY(func)] [...]]" modifier
  while p.match_pair(APPLY, L_PAREN) {
    this = Some(
      @core.mk(Apply, [
        ("this", this),
        ("expression", p.parse_var(any_token=true)),
      ]),
    )
    p.match_(R_PAREN) |> ignore
  }
  this
}

///|
fn parse_columns(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.expression(@core.mk1(Columns, p.parse_lambda()))
  while p.next.ok() && p.match_text_seq([")", "APPLY", "("]) {
    p.match_(R_PAREN) |> ignore
    this = @core.mk(Apply, [
      ("this", Some(this)),
      ("expression", p.parse_var(any_token=true)),
    ])
  }
  Some(this)
}

///|
fn parse_value(
  p : @core.Parser,
  values : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let value = p.parse_value_base(values~)
  guard value is Some(v) else { return None }
  // In Clickhouse "SELECT * FROM VALUES (1, 2, 3)" generates a table with a single column,
  // in contrast to other dialects. For this case, we canonicalize the values into a
  // tuple-of-tuples AST if it's not already one.
  let expressions = v.expressions()
  if values &&
    !expressions.is_empty() &&
    expressions[expressions.length() - 1].kind != Tuple {
    v.set(
      "expressions",
      expressions.map(expr => {
        p.expression(@core.mk(Tuple, [("expressions", [expr.unnest()])]))
      }),
    )
  }
  value
}

///|
fn parse_detach(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  let kind : @core.Value = if p.match_set(p.cfg.db_creatables) {
    Str(@core.py_upper(p.prev.text))
  } else {
    Bool(false)
  }
  let exists = p.parse_exists()
  let this = p.parse_table_parts()
  let cluster = if p.match_(ON) { p.parse_on_property() } else { None }
  let permanent = p.match_text_seq(["PERMANENTLY"])
  let sync = p.match_text_seq(["SYNC"])
  p.expression(
    @core.mk(Detach, [
      ("this", this),
      ("kind", kind),
      ("exists", exists),
      ("cluster", cluster),
      ("permanent", permanent),
      ("sync", sync),
    ]),
  )
}
