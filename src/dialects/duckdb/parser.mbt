// Port of sqlglot/parsers/duckdb.py

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  args.get(i)
}

///|
fn build_sort_array_desc(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(SortArray, [("this", seq_get(args, 0)), ("asc", @core.false_())])
}

///|
fn build_array_prepend(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(ArrayPrepend, [
    ("this", seq_get(args, 1)),
    ("expression", seq_get(args, 0)),
  ])
}

///|
fn build_date_diff(args : Array[@core.Expr]) -> @core.Expr {
  @core.mk(DateDiff, [
    ("this", seq_get(args, 2)),
    ("expression", seq_get(args, 1)),
    ("unit", seq_get(args, 0)),
  ])
}

///|
fn build_generate_series(end_exclusive? : Bool = false) -> @core.FuncBuilder {
  (args, _) => {
    let args = args.copy()
    // Check https://duckdb.org/docs/sql/functions/nested.html#range-functions
    if args.length() == 1 {
      // DuckDB uses 0 as a default for the series' start when it's omitted
      args.insert(0, @core.literal_number("0"))
    }
    let gen_series = @core.from_arg_list(GenerateSeries, args)
    gen_series.set("is_end_exclusive", end_exclusive)
    gen_series
  }
}

///|
fn build_make_timestamp(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 1 {
    return @core.mk(UnixToTime, [
      ("this", seq_get(args, 0)),
      ("scale", @core.literal_int(6)),
    ])
  }
  @core.mk(TimestampFromParts, [
    ("year", seq_get(args, 0)),
    ("month", seq_get(args, 1)),
    ("day", seq_get(args, 2)),
    ("hour", seq_get(args, 3)),
    ("min", seq_get(args, 4)),
    ("sec", seq_get(args, 5)),
  ])
}

///|
fn convert_text_type(dtype : @core.Expr) -> @core.Expr {
  dtype.set("expressions", (None : @core.Expr?))
  dtype
}

///|
fn fb(f : (Array[@core.Expr]) -> @core.Expr) -> @core.FuncBuilder {
  (args, _) => f(args)
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let cfg = d.parser_cfg
  let fns = d.parser_fns
  cfg.no_paren_functions[LOCALTIME] = Localtime
  cfg.no_paren_functions[LOCALTIMESTAMP] = Localtimestamp
  cfg.no_paren_functions[CURRENT_CATALOG] = CurrentCatalog
  cfg.no_paren_functions[SESSION_USER] = SessionUser
  fns.column_operators.remove(ARROW)
  fns.column_operators.remove(DARROW)
  fns.json_operators[ARROW] = @core.build_json_extract_op
  fns.json_operators[DARROW] = @core.build_json_extract_scalar_op
  fns.range_parsers[DAMP] = @core.binary_range_parser(ArrayOverlaps)
  fns.range_parsers[CARET_AT] = @core.binary_range_parser(StartsWith)
  fns.range_parsers[TILDE] = @core.binary_range_parser(RegexpFullMatch)
  fns.show_parsers.clear()
  fns.show_parsers["TABLES"] = p => parse_show_duckdb(p, "TABLES")
  fns.show_parsers["ALL TABLES"] = p => parse_show_duckdb(p, "ALL TABLES")
  // FUNCTIONS
  let f = fns.functions
  f.remove("DATE_SUB")
  f.remove("GLOB")
  f["ANY_VALUE"] = fb(args => {
    @core.mk1(IgnoreNulls, @core.from_arg_list(AnyValue, args))
  })
  f["ARRAY_PREPEND"] = fb(build_array_prepend)
  f["ARRAY_REVERSE_SORT"] = fb(build_sort_array_desc)
  f["ARRAY_INTERSECT"] = fb(args => {
    @core.mk(ArrayIntersect, [("expressions", args)])
  })
  f["ARRAY_SORT"] = @core.from_arg_list_builder(SortArray)
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["BIT_XOR"] = @core.from_arg_list_builder(BitwiseXorAgg)
  f["CURRENT_LOCALTIMESTAMP"] = @core.from_arg_list_builder(Localtimestamp)
  f["DATEDIFF"] = fb(build_date_diff)
  f["DATE_DIFF"] = fb(build_date_diff)
  f["DATE_TRUNC"] = fb(@core.date_trunc_to_time)
  f["DATETRUNC"] = fb(@core.date_trunc_to_time)
  f["DECODE"] = fb(args => {
    @core.mk(Decode, [
      ("this", seq_get(args, 0)),
      ("charset", @core.literal_string("utf-8")),
    ])
  })
  f["EDITDIST3"] = @core.from_arg_list_builder(Levenshtein)
  f["ENCODE"] = fb(args => {
    @core.mk(Encode, [
      ("this", seq_get(args, 0)),
      ("charset", @core.literal_string("utf-8")),
    ])
  })
  f["EPOCH"] = @core.from_arg_list_builder(TimeToUnix)
  f["EPOCH_MS"] = fb(args => {
    @core.mk(UnixToTime, [
      ("this", seq_get(args, 0)),
      ("scale", @core.literal_int(3)),
    ])
  })
  f["FROM_HEX"] = @core.from_arg_list_builder(Unhex)
  f["GENERATE_SERIES"] = build_generate_series()
  f["GET_CURRENT_TIME"] = @core.from_arg_list_builder(CurrentTime)
  f["GET_BIT"] = fb(args => {
    @core.mk(Getbit, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("zero_is_msb", true),
    ])
  })
  f["JARO_WINKLER_SIMILARITY"] = @core.from_arg_list_builder(
    JarowinklerSimilarity,
  )
  f["JSON"] = @core.from_arg_list_builder(ParseJSON)
  f["JSON_ARRAY"] = fb(args => @core.mk(JSONArray, [("expressions", args)]))
  f["JSON_EXTRACT_PATH"] = @core.build_extract_json_with_path(JSONExtract)
  f["JSON_EXTRACT_STRING"] = @core.build_extract_json_with_path(
    JSONExtractScalar,
  )
  f["LIST"] = @core.from_arg_list_builder(ArrayAgg)
  f["LIST_DISTINCT"] = @core.from_arg_list_builder(ArrayDistinct)
  f["LIST_APPEND"] = @core.from_arg_list_builder(ArrayAppend)
  f["LIST_CONCAT"] = (args, p) => @core.build_array_concat(args, p)
  f["LIST_CONTAINS"] = @core.from_arg_list_builder(ArrayContains)
  f["LIST_COSINE_DISTANCE"] = @core.from_arg_list_builder(CosineDistance)
  f["LIST_DISTANCE"] = @core.from_arg_list_builder(EuclideanDistance)
  f["LIST_FILTER"] = @core.from_arg_list_builder(ArrayFilter)
  f["LIST_HAS"] = @core.from_arg_list_builder(ArrayContains)
  f["LIST_HAS_ANY"] = @core.from_arg_list_builder(ArrayOverlaps)
  f["LIST_MAX"] = @core.from_arg_list_builder(ArrayMax)
  f["LIST_MIN"] = @core.from_arg_list_builder(ArrayMin)
  f["LIST_PREPEND"] = fb(build_array_prepend)
  f["LIST_REVERSE_SORT"] = fb(build_sort_array_desc)
  f["LIST_SORT"] = @core.from_arg_list_builder(SortArray)
  f["LIST_TRANSFORM"] = @core.from_arg_list_builder(Transform)
  f["LIST_VALUE"] = fb(args => @core.mk(Array, [("expressions", args)]))
  f["MAKE_DATE"] = @core.from_arg_list_builder(DateFromParts)
  f["MAKE_TIME"] = @core.from_arg_list_builder(TimeFromParts)
  f["MAKE_TIMESTAMP"] = fb(build_make_timestamp)
  f["QUANTILE_CONT"] = @core.from_arg_list_builder(PercentileCont)
  f["QUANTILE_DISC"] = @core.from_arg_list_builder(PercentileDisc)
  f["RANGE"] = build_generate_series(end_exclusive=true)
  f["REGEXP_EXTRACT"] = @core.build_regexp_extract(RegexpExtract)
  f["REGEXP_EXTRACT_ALL"] = @core.build_regexp_extract(RegexpExtractAll)
  f["REGEXP_MATCHES"] = @core.from_arg_list_builder(RegexpLike)
  f["REGEXP_REPLACE"] = fb(args => {
    @core.mk(RegexpReplace, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("replacement", seq_get(args, 2)),
      ("modifiers", seq_get(args, 3)),
      ("single_replace", true),
    ])
  })
  f["SHA256"] = fb(args => {
    @core.mk(SHA2, [
      ("this", seq_get(args, 0)),
      ("length", @core.literal_number("256")),
    ])
  })
  f["STRFTIME"] = @core.build_formatted_time(TimeToStr)
  f["STRING_SPLIT"] = @core.from_arg_list_builder(Split)
  f["STRING_SPLIT_REGEX"] = @core.from_arg_list_builder(RegexpSplit)
  f["STRING_TO_ARRAY"] = @core.from_arg_list_builder(Split)
  f["STRPTIME"] = @core.build_formatted_time(StrToTime)
  f["STRUCT_PACK"] = @core.from_arg_list_builder(Struct)
  f["STR_SPLIT"] = @core.from_arg_list_builder(Split)
  f["STR_SPLIT_REGEX"] = @core.from_arg_list_builder(RegexpSplit)
  f["TODAY"] = @core.from_arg_list_builder(CurrentDate)
  f["TIME_BUCKET"] = @core.from_arg_list_builder(DateBin)
  f["TO_TIMESTAMP"] = @core.from_arg_list_builder(UnixToTime)
  f["UNNEST"] = @core.from_arg_list_builder(Explode)
  f["VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  f["XOR"] = @core.binary_from_function(BitwiseXor)
  // FUNCTION_PARSERS
  let fp = fns.function_parsers
  fp.remove("DECODE")
  for name in ["GROUP_CONCAT", "LISTAGG", "STRINGAGG"] {
    fp[name] = p => p.parse_string_agg()
  }
  fp["APPROX_QUANTILE"] = p => p.parse_distinct_arg_function(ApproxQuantile)
  fp["QUANTILE"] = p => p.parse_distinct_arg_function(Quantile)
  fp["QUANTILE_CONT"] = p => p.parse_distinct_arg_function(PercentileCont)
  fp["QUANTILE_DISC"] = p => p.parse_distinct_arg_function(PercentileDisc)
  // NO_PAREN_FUNCTION_PARSERS
  fns.no_paren_function_parsers["MAP"] = p => Some(parse_map(p))
  fns.no_paren_function_parsers["@"] = p => {
    Some(@core.mk1(Abs, p.parse_bitwise()))
  }
  // PLACEHOLDER_PARSERS
  fns.placeholder_parsers[PARAMETER] = p => {
    if p.match_(NUMBER) || p.match_set(p.cfg.id_var_tokens) {
      Some(p.expression(@core.mk1(Placeholder, p.prev.text)))
    } else {
      None
    }
  }
  // TYPE_CONVERTERS
  fns.type_converters[DECIMAL] = @core.build_default_decimal_type(
    precision=18,
    scale=3,
  )
  fns.type_converters[TEXT] = convert_text_type
  // STATEMENT_PARSERS
  fns.statement_parsers[ATTACH] = p => Some(parse_attach_detach(p, true))
  fns.statement_parsers[DETACH] = p => Some(parse_attach_detach(p, false))
  fns.statement_parsers[FORCE] = parse_force
  fns.statement_parsers[INSTALL] = p => Some(parse_install(p, false))
  fns.statement_parsers[SHOW] = p => p.parse_show()
  // SET_PARSERS
  fns.set_parsers["VARIABLE"] = p => {
    p.parse_set_item_assignment(kind="VARIABLE")
  }
  // Method overrides
  let hooks = fns.hooks
  hooks.parse_function_properties = Some(parse_function_properties)
  hooks.parse_lambda = Some(parse_lambda)
  hooks.parse_expression = Some(parse_expression)
  hooks.parse_table = Some(parse_table)
  hooks.parse_table_sample = Some(parse_table_sample)
  hooks.parse_bracket = Some(parse_bracket)
  hooks.parse_struct_types = Some((p, _type_required) => p.parse_field_def())
  hooks.pivot_column_names = Some(pivot_column_names)
  hooks.parse_primary = Some(parse_primary)
  d.hooks.to_json_path = Some(to_json_path)
}

///|
fn to_json_path(
  d : @core.Dialect,
  path : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  match path {
    Some(p) if p.kind == Literal => {
      // DuckDB also supports the JSON pointer syntax, where every path starts with a `/`.
      // Additionally, it allows accessing the back of lists using the `[#-i]` syntax.
      // This check ensures we'll avoid trying to parse these as JSON paths, which can
      // either result in a noisy warning or in an invalid representation of the path.
      let path_text = p.name()
      if path_text.has_prefix("/") || path_text.contains("[#") {
        return path
      }
    }
    _ => ()
  }
  d.to_json_path_base(path)
}

///|
fn parse_function_properties(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if p.match_(TABLE) {
    return Some(
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(ReturnsProperty, [
              ("this", @core.mk1(Schema, @core.var_("TABLE"))),
              ("is_table", true),
            ]),
          ],
        ),
      ]),
    )
  }
  p.parse_function_properties_base()
}

///|
fn parse_lambda(
  p : @core.Parser,
  alias_ : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  if !p.match_text_seq(["LAMBDA"]) {
    return p.parse_lambda_base(alias=alias_)
  }
  let expressions = p.parse_csv(() => p.parse_lambda_arg())
  if !p.match_(COLON) {
    p.retreat(index)
    return None
  }
  let this = p.replace_lambda(p.parse_assignment(), expressions)
  Some(
    p.expression(
      @core.mk(Lambda, [
        ("this", this),
        ("expressions", expressions),
        ("colon", true),
      ]),
    ),
  )
}

///|
fn parse_expression(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // DuckDB supports prefix aliases, e.g. foo: 1
  if p.next.token_type == COLON {
    let alias_ = p.parse_id_var(tokens=p.cfg.alias_tokens)
    p.match_(COLON) |> ignore
    let comments = p.prev_comments.copy()
    let this = p.parse_assignment()
    match this {
      // Moves the comment next to the alias in `alias: expr /* comment */`
      Some(t) => comments.append(t.pop_comments())
      None => ()
    }
    return Some(
      p.expression(
        @core.mk(Alias, [("this", this), ("alias", alias_)]),
        comments~,
      ),
    )
  }
  p.parse_alias(p.parse_assignment())
}

///|
fn parse_table(
  p : @core.Parser,
  args : @core.TableArgs,
) -> @core.Expr? raise @core.SqlglotError {
  // DuckDB supports prefix aliases, e.g. FROM foo: bar
  let mut alias_ : @core.Expr? = None
  let comments : Array[String] = []
  if p.next.token_type == COLON {
    alias_ = p.parse_table_alias(
      alias_tokens=match args.alias_tokens {
        Some(t) => t
        None => p.cfg.table_alias_tokens
      },
    )
    p.match_(COLON) |> ignore
    comments.append(p.prev_comments)
  }
  let table = p.parse_table_base({ ..args, consume_pipe: false, })
  match (table, alias_) {
    (Some(t), Some(a)) if a.kind == TableAlias => {
      // Moves the comment next to the alias in `alias: table /* comment */`
      comments.append(t.pop_comments())
      a.add_comments(Some(a.pop_comments() + comments))
      t.set("alias", a)
    }
    _ => ()
  }
  table
}

///|
fn parse_table_sample(
  p : @core.Parser,
  as_modifier : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  // https://duckdb.org/docs/sql/samples.html
  let sample = p.parse_table_sample_base(as_modifier~)
  match sample {
    Some(s) if !s.has("method") =>
      if s.has("size") {
        s.set("method", @core.var_("RESERVOIR"))
      } else {
        s.set("method", @core.var_("SYSTEM"))
      }
    _ => ()
  }
  sample
}

///|
fn parse_bracket(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let bracket = p.parse_bracket_base(this)
  if p.dialect.version < (1, 2, 0) {
    match bracket {
      // https://duckdb.org/2025/02/05/announcing-duckdb-120.html#breaking-changes
      Some(b) if b.kind == Bracket => b.set("returns_list_for_maps", true)
      _ => ()
    }
  }
  bracket
}

///|
fn parse_map(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  if p.match_(L_BRACE, advance=false) {
    return p.expression(@core.mk1(ToMap, p.parse_bracket(None)))
  }
  let args = p.parse_wrapped_csv(() => p.parse_assignment())
  p.expression(
    @core.mk(Map, [("keys", seq_get(args, 0)), ("values", seq_get(args, 1))]),
  )
}

///|
fn pivot_column_names(
  p : @core.Parser,
  aggregations : Array[@core.Expr],
) -> Array[String] raise @core.SqlglotError {
  if aggregations.length() == 1 {
    let out = []
    for agg in aggregations {
      let a = agg.alias()
      if !a.is_empty() {
        out.push(a)
      }
    }
    return out
  }
  ignore(p)
  @core.pivot_column_names(aggregations, dialect())
}

///|
fn parse_attach_detach(
  p : @core.Parser,
  is_attach : Bool,
) -> @core.Expr raise @core.SqlglotError {
  fn parse_attach_option() -> @core.Expr? raise @core.SqlglotError {
    Some(
      p.expression(
        @core.mk(AttachOption, [
          ("this", p.parse_var(any_token=true)),
          ("expression", p.parse_field(any_token=true)),
        ]),
      ),
    )
  }

  p.match_(DATABASE) |> ignore
  let exists = p.parse_exists(not_=is_attach)
  let this = p.parse_alias(p.parse_primary_or_var(), explicit=true)
  let expressions = if p.match_(L_PAREN, advance=false) {
    Some(p.parse_wrapped_csv(parse_attach_option))
  } else {
    None
  }
  if is_attach {
    p.expression(
      @core.mk(Attach, [
        ("this", this),
        ("exists", exists),
        ("expressions", expressions),
      ]),
    )
  } else {
    p.expression(@core.mk(Detach, [("this", this), ("exists", exists)]))
  }
}

///|
fn parse_show_duckdb(
  p : @core.Parser,
  this : String,
) -> @core.Expr? raise @core.SqlglotError {
  let from_ = if p.match_(FROM) { p.parse_table(schema=true) } else { None }
  Some(p.expression(@core.mk(Show, [("this", this), ("from_", from_)])))
}

///|
fn parse_force(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // FORCE can only be followed by INSTALL or CHECKPOINT
  // In the case of CHECKPOINT, we fallback
  if !p.match_(INSTALL) {
    return Some(p.parse_as_command(p.prev))
  }
  Some(parse_install(p, true))
}

///|
fn parse_install(
  p : @core.Parser,
  force : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let this = p.parse_id_var()
  let from_ = if p.match_(FROM) { p.parse_var_or_string() } else { None }
  p.expression(
    @core.mk(Install, [("this", this), ("from_", from_), ("force", force)]),
  )
}

///|
fn parse_primary(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_pair(HASH, NUMBER) {
    return Some(@core.mk1(PositionalColumn, @core.literal_number(p.prev.text)))
  }
  p.parse_primary_base()
}
