// Port of sqlglot/parsers/hive.py

///|
fn arg_at(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  args.get(i)
}

///|
/// Python `build_with_ignore_nulls(exp_class)`.
pub fn build_with_ignore_nulls(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    let this = @core.mk1(kind, arg_at(args, 0))
    if arg_at(args, 1) is Some(a) && a == @core.true_() {
      return @core.mk1(IgnoreNulls, this)
    }
    this
  }
}

///|
fn build_to_date(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let expr = @core.build_formatted_time(TsOrDsToDate)(args, p)
  expr.set("safe", true)
  expr
}

///|
/// Map named_struct('k', v, ...) to exp.Struct.
fn build_named_struct(args : Array[@core.Expr]) -> @core.Expr {
  let expressions : Array[@core.Expr] = []
  let mut i = 0
  while i < args.length() - 1 {
    let key = args[i]
    let value = args[i + 1]
    expressions.push(
      @core.mk(PropertyEQ, [
        ("this", @core.to_identifier(key.name())),
        ("expression", value),
      ]),
    )
    i += 2
  }
  @core.mk(Struct, [("expressions", expressions)])
}

///|
fn build_date_sub(args : Array[@core.Expr]) -> @core.Expr {
  let expression = match arg_at(args, 1) {
    Some(e) => Some(@core.exp_binop(Mul, e, @core.literal_int(-1)))
    None => None
  }
  @core.mk(TsOrDsAdd, [
    ("this", arg_at(args, 0)),
    ("expression", expression),
    ("unit", Some(@core.literal_string("DAY"))),
  ])
}

///|
fn str_or(e : @core.Expr?, s : String) -> @core.Expr {
  match e {
    Some(x) => x
    None => @core.literal_string(s)
  }
}

///|
/// Dialect-specific parser class attributes that are not part of the shared config.
pub(all) struct HiveParserSettings {
  /// Strip trailing fractional zeros and normalize zero when inferring BD literal types.
  normalize_decimal_literals : Bool
  /// Allow negative scales for BD exponent literals, e.g. 1E3BD as DECIMAL(1, -3).
  decimal_literals_allow_negative_scale : Bool
  /// Whether the dialect supports using ALTER COLUMN syntax with CHANGE COLUMN.
  change_column_alter_syntax : Bool
}

///|
let hive_parser_settings : HiveParserSettings = {
  normalize_decimal_literals: true,
  decimal_literals_allow_negative_scale: false,
  change_column_alter_syntax: false,
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.function_parsers["PERCENTILE"] = p => {
    p.parse_distinct_arg_function(Quantile)
  }
  fns.function_parsers["PERCENTILE_APPROX"] = p => {
    p.parse_distinct_arg_function(ApproxQuantile)
  }
  let f = fns.functions
  f["BASE64"] = @core.from_arg_list_builder(ToBase64)
  f["COLLECT_LIST"] = (args, _) => {
    @core.mk(ArrayAgg, [
      ("this", arg_at(args, 0)),
      ("nulls_excluded", Some(true)),
    ])
  }
  f["COLLECT_SET"] = @core.from_arg_list_builder(ArrayUniqueAgg)
  f["CONCAT_WS"] = (args, p) => {
    @core.mk(ConcatWs, [
      ("expressions", args),
      ("safe", !p.dialect.cfg.strict_string_concat),
      ("coalesce", p.dialect.cfg.concat_ws_coalesce),
      ("flatten", true),
    ])
  }
  f["DATE_ADD"] = (args, _) => {
    @core.mk(TsOrDsAdd, [
      ("this", arg_at(args, 0)),
      ("expression", arg_at(args, 1)),
      ("unit", Some(@core.literal_string("DAY"))),
    ])
  }
  f["DATE_FORMAT"] = (args, p) => {
    let a : Array[@core.Expr] = [@core.mk1(TimeStrToTime, arg_at(args, 0))]
    match arg_at(args, 1) {
      Some(x) => a.push(x)
      None => ()
    }
    @core.build_formatted_time(TimeToStr)(a, p)
  }
  f["DATE_SUB"] = (args, _) => build_date_sub(args)
  f["DATEDIFF"] = (args, _) => {
    @core.mk(DateDiff, [
      ("this", @core.mk1(TsOrDsToDate, arg_at(args, 0))),
      ("expression", @core.mk1(TsOrDsToDate, arg_at(args, 1))),
    ])
  }
  f["DAY"] = (args, _) => {
    @core.mk1(Day, @core.mk1(TsOrDsToDate, arg_at(args, 0)))
  }
  f["FIRST"] = build_with_ignore_nulls(First)
  f["FIRST_VALUE"] = build_with_ignore_nulls(FirstValue)
  f["FROM_UNIXTIME"] = @core.build_formatted_time(UnixToStr, default=true)
  f["GET_JSON_OBJECT"] = (args, p) => {
    @core.mk(JSONExtractScalar, [
      ("this", arg_at(args, 0)),
      ("expression", p.dialect.to_json_path(arg_at(args, 1))),
    ])
  }
  f["LAST"] = build_with_ignore_nulls(Last)
  f["LAST_VALUE"] = build_with_ignore_nulls(LastValue)
  f["MAP"] = (args, _) => @core.build_var_map(args)
  f["MONTH"] = (args, _) => {
    @core.mk1(Month, @core.from_arg_list(TsOrDsToDate, args))
  }
  f["NAMED_STRUCT"] = (args, _) => build_named_struct(args)
  f["REGEXP_EXTRACT"] = @core.build_regexp_extract(RegexpExtract)
  f["REGEXP_EXTRACT_ALL"] = @core.build_regexp_extract(RegexpExtractAll)
  f["SEQUENCE"] = @core.from_arg_list_builder(GenerateSeries)
  f["SIZE"] = @core.from_arg_list_builder(ArraySize)
  f["SPLIT"] = @core.from_arg_list_builder(RegexpSplit)
  f["STR_TO_MAP"] = (args, _) => {
    @core.mk(StrToMap, [
      ("this", arg_at(args, 0)),
      ("pair_delim", Some(str_or(arg_at(args, 1), ","))),
      ("key_value_delim", Some(str_or(arg_at(args, 2), ":"))),
    ])
  }
  f["TO_DATE"] = build_to_date
  f["TO_JSON"] = @core.from_arg_list_builder(JSONFormat)
  f["TRUNC"] = @core.from_arg_list_builder(TimestampTrunc)
  f["UNBASE64"] = @core.from_arg_list_builder(FromBase64)
  f["UNIX_TIMESTAMP"] = (args, p) => {
    let a = if args.is_empty() { [@core.mk0(CurrentTimestamp)] } else { args }
    @core.build_formatted_time(StrToUnix, default=true)(a, p)
  }
  f["YEAR"] = (args, _) => {
    @core.mk1(Year, @core.from_arg_list(TsOrDsToDate, args))
  }
  fns.no_paren_function_parsers["TRANSFORM"] = parse_transform
  fns.property_parsers["SERDEPROPERTIES"] = (p, _) => {
    Some(
      Node(
        @core.mk(SerdeProperties, [
          ("expressions", p.parse_wrapped_properties()),
        ]),
      ),
    )
  }
  fns.property_parsers["USING"] = (p, _) => Some(Node(parse_using_property(p)))
  fns.alter_parsers["CHANGE"] = p => {
    match parse_alter_table_change(p) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  fns.hooks.build_cast = Some(build_cast)
  fns.hooks.parse_types = Some(parse_types)
  fns.hooks.parse_partition_and_order = Some(parse_partition_and_order)
  fns.hooks.parse_parameter = Some(parse_parameter)
  fns.hooks.to_prop_eq = Some(to_prop_eq)
}

///|
let parser_settings_registry : Map[String, HiveParserSettings] = Map([])

///|
/// Registers the Hive-specific parser class attributes of a dialect (Python class
/// attributes overridden by Spark2/Spark parsers). Read at call time.
pub fn register_parser_settings(name : String, s : HiveParserSettings) -> Unit {
  parser_settings_registry[name] = s
}

///|
fn parser_settings(d : @core.Dialect) -> HiveParserSettings {
  let mut cur : @core.Dialect? = Some(d)
  while cur is Some(c) {
    match parser_settings_registry.get(c.name) {
      Some(s) => return s
      None => cur = c.parent
    }
  }
  hive_parser_settings
}

///|
/// Python `Decimal(text).as_tuple()` -> (digits, exponent).
fn decimal_as_tuple(text : String) -> (Array[Int], Int) {
  let mut mantissa = text
  let mut exponent = 0
  for i, c in text {
    if c == 'e' || c == 'E' {
      mantissa = text.unsafe_substring(start=0, end=i)
      let exp_text = text.unsafe_substring(start=i + 1, end=text.length())
      exponent = match @core.parse_int_str(exp_text) {
        Some(v) => v.to_int()
        None => 0
      }
      break
    }
  }
  let digits : Array[Int] = []
  let mut frac = 0
  let mut seen_dot = false
  for c in mantissa {
    if c == '.' {
      seen_dot = true
    } else if c >= '0' && c <= '9' {
      if !(digits.is_empty() && c == '0') {
        digits.push(c.to_int() - '0'.to_int())
      }
      if seen_dot {
        frac += 1
      }
    }
  }
  if digits.is_empty() {
    digits.push(0)
  }
  (digits, exponent - frac)
}

///|
fn build_cast(
  p : @core.Parser,
  strict : Bool,
  kwargs : Array[(String, @core.Value?)],
) -> @core.Expr raise @core.SqlglotError {
  let s = parser_settings(p.dialect)
  if @core.py_upper(p.prev.text) == "BD" {
    let mut this_idx = -1
    for i, kv in kwargs {
      if kv.0 == "this" {
        this_idx = i
      }
    }
    if this_idx >= 0 && kwargs[this_idx].1 is Some(Node(this)) {
      let (digits, exponent) = decimal_as_tuple(this.name())
      let mut precision = digits.length()
      let mut scale = -exponent
      if s.normalize_decimal_literals {
        if digits.iter().all(x => x == 0) {
          precision = 1
          scale = 0
        } else {
          while scale > 0 && digits[precision - 1] == 0 {
            precision -= 1
            scale -= 1
          }
        }
      }
      if scale < 0 && !s.decimal_literals_allow_negative_scale {
        precision -= scale
        scale = 0
      }
      let new_this = if scale < 0 {
        this
      } else {
        @core.literal_string(this.name())
      }
      let params = [if precision > scale { precision } else { scale }, scale].map(v => {
          @core.mk1(DataTypeParam, @core.literal_int(v))
        },
      )
      let to = @core.mk(DataType, [
        ("this", @core.DType::DECIMAL),
        ("expressions", params),
      ])
      let kwargs = kwargs.filter(kv => kv.0 != "this" && kv.0 != "to")
      kwargs.push(("this", Some(Node(new_this))))
      kwargs.push(("to", Some(Node(to))))
      return p.build_cast_base(strict, kwargs)
    }
  }
  p.build_cast_base(strict, kwargs)
}

///|
fn parse_transform(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if !p.match_(L_PAREN, advance=false) {
    p.retreat(p.index - 1)
    return None
  }
  let args = p.parse_wrapped_csv(() => p.parse_lambda())
  let row_format_before = p.parse_row_format(match_row=true)
  let mut record_writer : @core.Expr? = None
  if p.match_text_seq(["RECORDWRITER"]) {
    record_writer = p.parse_string()
  }
  if !p.match_(USING) {
    return Some(@core.from_arg_list(Transform, args))
  }
  let command_script = p.parse_string()
  p.match_(ALIAS) |> ignore
  let schema = p.parse_schema()
  let row_format_after = p.parse_row_format(match_row=true)
  let mut record_reader : @core.Expr? = None
  if p.match_text_seq(["RECORDREADER"]) {
    record_reader = p.parse_string()
  }
  Some(
    p.expression(
      @core.mk(QueryTransform, [
        ("expressions", args),
        ("command_script", command_script),
        ("schema", schema),
        ("row_format_before", row_format_before),
        ("record_writer", record_writer),
        ("row_format_after", row_format_after),
        ("record_reader", record_reader),
      ]),
    ),
  )
}

///|
/// Spark (and most likely Hive) treats casts to CHAR(length) and VARCHAR(length) as
/// casts to STRING in all contexts except for schema definitions.
pub fn parse_types(
  p : @core.Parser,
  check_func : Bool,
  schema : Bool,
  allow_identifiers : Bool,
  with_collation : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_types_base(
    check_func~,
    schema~,
    allow_identifiers~,
    with_collation~,
  )
  match this {
    Some(t) if !schema =>
      Some(
        t.transform(
          node => {
            if node.kind == DataType && node.is_type([CHAR, VARCHAR]) {
              node.set("this", @core.DType::TEXT)
              node.set("expressions", (None : @core.Expr?))
            }
            Some(node)
          },
          copy=false,
        ),
      )
    _ => this
  }
}

///|
fn parse_alter_table_change(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let s = parser_settings(p.dialect)
  p.match_(COLUMN) |> ignore
  let this = p.parse_field(any_token=true)
  if s.change_column_alter_syntax && p.match_text_seq(["TYPE"]) {
    return Some(
      p.expression(
        @core.mk(AlterColumn, [
          ("this", this),
          ("dtype", p.parse_types(schema=true)),
        ]),
      ),
    )
  }
  let column_new = p.parse_field(any_token=true)
  let dtype = p.parse_types(schema=true)
  let comment = if p.match_(COMMENT) { p.parse_string() } else { None }
  if this is None || column_new is None || dtype is None {
    p.raise_error(
      "Expected 'CHANGE COLUMN' to be followed by 'column_name' 'column_name' 'data_type'",
    )
  }
  Some(
    p.expression(
      @core.mk(AlterColumn, [
        ("this", this),
        ("rename_to", column_new),
        ("dtype", dtype),
        ("comment", comment),
      ]),
    ),
  )
}

///|
fn parse_using_property(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  if p.match_texts(["JAR", "FILE", "ARCHIVE"]) {
    let kind = @core.py_upper(p.prev.text)
    return @core.mk(UsingProperty, [
      ("this", p.parse_string()),
      ("kind", Some(kind)),
    ])
  }
  p.parse_property_assignment(FileFormatProperty)
}

///|
fn parse_partition_and_order(
  p : @core.Parser,
) -> (Array[@core.Expr], @core.Expr?) raise @core.SqlglotError {
  let partition = if p.match_set(
      @core.TokenSet::new([PARTITION_BY, DISTRIBUTE_BY]),
    ) {
    p.parse_csv(() => p.parse_assignment())
  } else {
    []
  }
  let skip = p.match_(SORT_BY)
  (partition, p.parse_order(skip_order_token=skip))
}

///|
fn parse_parameter(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  p.match_(L_BRACE) |> ignore
  let this = @core.expr_or(p.parse_identifier(), () => p.parse_primary_or_var())
  let expression = if p.match_(COLON) {
    @core.expr_or(p.parse_identifier(), () => p.parse_primary_or_var())
  } else {
    None
  }
  p.match_(R_BRACE) |> ignore
  Some(
    p.expression(
      @core.mk(Parameter, [("this", this), ("expression", expression)]),
    ),
  )
}

///|
fn to_prop_eq(
  p : @core.Parser,
  expression : @core.Expr,
  index : Int,
) -> @core.Expr raise @core.SqlglotError {
  if expression.is_star() {
    return expression
  }
  let key = if expression.kind == Column {
    expression.this().unwrap()
  } else {
    @core.to_identifier("col\{index + 1}")
  }
  p.expression(
    @core.mk(PropertyEQ, [("this", key), ("expression", expression)]),
  )
}
