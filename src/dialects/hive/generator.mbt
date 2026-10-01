// Port of sqlglot/generators/hive.py

///|
/// These constants are duplicated from the Hive dialect (TIME_FORMAT, DATE_FORMAT,
/// DATEINT_FORMAT).
pub let hive_time_format : String = "'yyyy-MM-dd HH:mm:ss'"

///|
pub let hive_date_format : String = "'yyyy-MM-dd'"

///|
pub let hive_dateint_format : String = "'yyyyMMdd'"

///|
/// The default formats above, as rendered by the lenient rewrite.
let hive_non_padded_time_formats : Array[String] = [
  "'yyyy-M-d H:m:s'", "'yyyy-M-d'",
]

///|
/// Expressions that parse a string with a format (vs. formatting one, like TimeToStr).
let parse_time_expressions : Array[@core.Kind] = [
  StrToTime,
  StrToDate,
  StrToUnix,
  TsOrDsToDate,
]

///|
let lax_to_non_padded_formats : Map[String, String] = {
  "%m": "%-m",
  "%d": "%-d",
  "%H": "%-H",
  "%I": "%-I",
  "%M": "%-M",
  "%S": "%-S",
}

///|
/// Python `CANONICAL_TIME_FORMAT.split(fmt)` and `.findall(fmt)` for the regex
/// `%(?:[mdHIMS]strict|[-:].|.)`.
fn split_canonical_time_format(fmt : String) -> (Array[String], Array[String]) {
  let chars = fmt.to_array()
  let n = chars.length()
  let parts : Array[String] = []
  let formats : Array[String] = []
  let buf = StringBuilder()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '%' && i + 1 < n && chars[i + 1] != '\n' {
      let next = chars[i + 1]
      let mut len = 2
      if "mdHIMS".contains_char(next) &&
        i + 8 <= n &&
        String::from_array(chars[i + 2:i + 8].to_owned()) == "strict" {
        len = 8
      } else if (next == '-' || next == ':') &&
        i + 2 < n &&
        chars[i + 2] != '\n' {
        len = 3
      }
      parts.push(buf.to_string())
      buf.reset()
      formats.push(String::from_array(chars[i:i + len].to_owned()))
      i += len
    } else {
      buf.write_char(c)
      i += 1
    }
  }
  parts.push(buf.to_string())
  (parts, formats)
}

///|
fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Changes a lax month/day/hour/minute/second in a canonical format to its non-padded
/// form (e.g. %m -> %-m), only for delimited specifiers.
fn lenient_parse_format(fmt : String) -> String {
  let (parts, formats) = split_canonical_time_format(fmt)
  for i, fmt_ in formats {
    match lax_to_non_padded_formats.get(fmt_) {
      Some(np) => {
        let left = parts[i]
        let right = parts[i + 1]
        let left_adjacent = (left.is_empty() && i > 0) ||
          (
            !left.is_empty() &&
            is_digit_char(left.to_array()[left.to_array().length() - 1])
          )
        let right_adjacent = (right.is_empty() && i < formats.length() - 1) ||
          (!right.is_empty() && is_digit_char(right.to_array()[0]))
        if !left_adjacent && !right_adjacent {
          formats[i] = np
        }
      }
      None => ()
    }
  }
  let sb = StringBuilder()
  for i, part in parts {
    sb.write_string(part)
    if i < formats.length() {
      sb.write_string(formats[i])
    }
  }
  sb.to_string()
}

///|
/// (FuncType, Multiplier)
fn date_delta_interval(unit : String) -> (String, Int)? {
  match unit {
    "YEAR" => Some(("ADD_MONTHS", 12))
    "MONTH" => Some(("ADD_MONTHS", 1))
    "QUARTER" => Some(("ADD_MONTHS", 3))
    "WEEK" => Some(("DATE_ADD", 7))
    "DAY" => Some(("DATE_ADD", 1))
    _ => None
  }
}

///|
fn time_diff_factor(unit : String) -> String? {
  match unit {
    "MILLISECOND" => Some(" * 1000")
    "SECOND" => Some("")
    "MINUTE" => Some(" / 60")
    "HOUR" => Some(" / 3600")
    _ => None
  }
}

///|
/// Python `repr(float)` for the results of simple arithmetic.
fn py_float_str(d : Double) -> String {
  if d == d.floor() && d.abs() < 1.0e16 {
    "\{d.to_int64()}.0"
  } else {
    d.to_string()
  }
}

///|
fn add_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.kind == TsOrDsAdd && !e.has("unit") {
    return g.func("DATE_ADD", [e.this(), e.expression()])
  }
  let unit = @core.py_upper(e.text("unit"))
  let (func, multiplier0) = match date_delta_interval(unit) {
    Some(x) => x
    None => ("DATE_ADD", 1)
  }
  let mut multiplier = multiplier0
  if e.kind == DateSub {
    multiplier = -multiplier
  }
  let mut increment = e.expression()
  match increment {
    Some(inc) if inc.kind == Literal =>
      if inc.is_number() {
        match inc.to_py_int() {
          Some(v) =>
            increment = Some(
              @core.literal_number((v * multiplier.to_int64()).to_string()),
            )
          None =>
            match inc.to_py_float() {
              Some(v) =>
                increment = Some(
                  @core.literal_number(py_float_str(v * multiplier.to_double())),
                )
              None => ()
            }
        }
      } else {
        let v = match @core.parse_int_str(@core.py_strip(inc.name())) {
          Some(v) => v
          None =>
            raise @core.ValueError("invalid literal for int(): '\{inc.name()}'")
        }
        increment = Some(
          @core.literal_number((v * multiplier.to_int64()).to_string()),
        )
      }
    Some(inc) if multiplier != 1 =>
      increment = Some(@core.exp_binop(Mul, inc, @core.literal_int(multiplier)))
    _ => ()
  }
  g.func(func, [e.this(), increment])
}

///|
fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = @core.py_upper(e.text("unit"))
  match time_diff_factor(unit) {
    Some(factor) => {
      let left = g.sql_key(e, "this")
      let right = g.sql_key(e, "expression")
      let sec_diff = "UNIX_TIMESTAMP(\{left}) - UNIX_TIMESTAMP(\{right})"
      return if factor != "" { "(\{sec_diff})\{factor}" } else { sec_diff }
    }
    None => ()
  }
  let months_between = unit == "YEAR" || unit == "QUARTER" || unit == "MONTH"
  let sql_func = if months_between { "MONTHS_BETWEEN" } else { "DATEDIFF" }
  let multiplier = match date_delta_interval(unit) {
    Some((_, m)) => m
    None => 1
  }
  let multiplier_sql = if multiplier > 1 { " / \{multiplier}" } else { "" }
  let mut diff_sql = "\{sql_func}(\{g.format_args([e.this(), e.expression()])})"
  if months_between || multiplier_sql != "" {
    // MONTHS_BETWEEN returns a float, so we need to truncate the fractional part.
    // For the same reason, we want to truncate if there's a divisor present.
    diff_sql = "CAST(\{diff_sql}\{multiplier_sql} AS INT)"
  }
  diff_sql
}

///|
fn array_sort_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("expression") {
    g.unsupported("Hive's SORT_ARRAY does not support a comparator.")
  }
  g.func("SORT_ARRAY", [e.this()])
}

///|
fn str_to_unix_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.func("UNIX_TIMESTAMP", [e.this(), @core.time_format(dialect="hive")(g, e)])
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let timestamp = g.sql_key(e, "this")
  match e.arg("scale") {
    None => @core.rename_func("FROM_UNIXTIME")(g, e)
    Some(s) if s == @core.literal_int(0) =>
      @core.rename_func("FROM_UNIXTIME")(g, e)
    Some(s) => "FROM_UNIXTIME(\{timestamp} / POW(10, \{@core.expr_to_sql(s)}))"
  }
}

///|
/// Checks whether CAST subsumes the expression's parse format.
fn is_cast_time_format(
  g : @core.Generator,
  e : @core.Expr,
  time_format : String,
) -> Bool raise @core.SqlglotError {
  if time_format == hive_time_format || time_format == hive_date_format {
    return true
  }
  if hive_non_padded_time_formats.contains(time_format) {
    // The base render skips the lenient rewrite
    let padded_format = g.format_time_base(e)
    return padded_format == Some(hive_time_format) ||
      padded_format == Some(hive_date_format)
  }
  false
}

///|
fn str_to_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = g.sql_key(e, "this")
  match g.format_time(e) {
    Some(tf) if tf != "" && !is_cast_time_format(g, e, tf) =>
      this = "FROM_UNIXTIME(UNIX_TIMESTAMP(\{this}, \{tf}))"
    _ => ()
  }
  "CAST(\{this} AS DATE)"
}

///|
fn str_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = g.sql_key(e, "this")
  match g.format_time(e) {
    Some(tf) if tf != "" && !is_cast_time_format(g, e, tf) =>
      this = "FROM_UNIXTIME(UNIX_TIMESTAMP(\{this}, \{tf}))"
    _ => ()
  }
  "CAST(\{this} AS TIMESTAMP)"
}

///|
let ts_or_ds_expressions_registry : Map[String, Array[@core.Kind]] = Map([])

///|
/// `HIVE_TS_OR_DS_EXPRESSIONS`
pub let hive_ts_or_ds_expressions : Array[@core.Kind] = [
  DateDiff,
  Day,
  Month,
  Year,
]

///|
/// Registers the generator class attribute `TS_OR_DS_EXPRESSIONS` of a dialect.
pub fn register_ts_or_ds_expressions(
  name : String,
  kinds : Array[@core.Kind],
) -> Unit {
  ts_or_ds_expressions_registry[name] = kinds
}

///|
fn ts_or_ds_expressions(d : @core.Dialect) -> Array[@core.Kind] {
  let mut cur : @core.Dialect? = Some(d)
  while cur is Some(c) {
    match ts_or_ds_expressions_registry.get(c.name) {
      Some(s) => return s
      None => cur = c.parent
    }
  }
  hive_ts_or_ds_expressions
}

///|
fn to_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match g.format_time(e) {
    Some(tf) if tf != "" && !is_cast_time_format(g, e, tf) =>
      return g.func("TO_DATE", [e.this(), tf])
    _ => ()
  }
  match e.parent {
    Some(p) if p.kind.is_any(ts_or_ds_expressions(g.dialect)) =>
      return g.sql_key(e, "this")
    _ => ()
  }
  g.func("TO_DATE", [e.this()])
}

///|
fn safe_json_path_key(s : String) -> Bool {
  // ^[_\-a-zA-Z][\-\w]*$
  let chars = s.to_array()
  if chars.is_empty() {
    return false
  }
  let first = chars[0]
  if !(first == '_' || first == '-' || first.is_ascii_alphabetic()) {
    return false
  }
  for i in 1..<chars.length() {
    let c = chars[i]
    if !(c == '-' ||
      c == '_' ||
      c.is_ascii_alphabetic() ||
      is_digit_char(c) ||
      c.to_int() > 127) {
      return false
    }
  }
  true
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  t[Property] = @core.property_sql
  t[AnyValue] = @core.rename_func("FIRST")
  t[ApproxDistinct] = @core.approx_count_distinct_sql
  t[ArgMax] = @core.arg_max_or_min_no_count("MAX_BY")
  t[ArgMin] = @core.arg_max_or_min_no_count("MIN_BY")
  t[Array] = @core.preprocess([@core.inherit_struct_field_names])
  t[ArrayConcat] = @core.rename_func("CONCAT")
  t[ArrayToString] = (g, e) => g.func("CONCAT_WS", [e.expression(), e.this()])
  t[ArraySort] = array_sort_sql
  t[With] = @core.no_recursive_cte_sql
  t[DateAdd] = add_date_sql
  t[DateDiff] = date_diff_sql
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateSub] = add_date_sql
  t[DateToDi] = (g, e) => {
    "CAST(DATE_FORMAT(\{g.sql_key(e, "this")}, \{hive_dateint_format}) AS INT)"
  }
  t[DiToDate] = (g, e) => {
    "TO_DATE(CAST(\{g.sql_key(e, "this")} AS STRING), \{hive_dateint_format})"
  }
  t[StorageHandlerProperty] = (g, e) => "STORED BY \{g.sql_key(e, "this")}"
  t[FromBase64] = @core.rename_func("UNBASE64")
  t[GenerateSeries] = @core.sequence_sql
  t[GenerateDateArray] = @core.sequence_sql
  t[If] = @core.if_sql()
  t[ILike] = @core.no_ilike_sql
  t[IntDiv] = (g, e) => g.binary(e, "DIV")
  t[IsNan] = @core.rename_func("ISNAN")
  t[JSONExtract] = (g, e) => {
    g.func("GET_JSON_OBJECT", [e.this(), e.expression()])
  }
  t[JSONExtractScalar] = (g, e) => {
    g.func("GET_JSON_OBJECT", [e.this(), e.expression()])
  }
  t[JSONFormat] = @core.rename_func("TO_JSON")
  t[Left] = @core.left_to_substring_sql
  t[Map] = (g, e) => @core.var_map_sql(g, e)
  t[Max] = @core.max_or_greatest
  t[MD5Digest] = (g, e) => g.func("UNHEX", [g.func("MD5", [e.this()])])
  t[Min] = @core.min_or_least
  t[MonthsBetween] = (g, e) => {
    g.func("MONTHS_BETWEEN", [e.this(), e.expression()])
  }
  t[NotNullColumnConstraint] = (_, e) => {
    if e.has("allow_null") {
      ""
    } else {
      "NOT NULL"
    }
  }
  t[VarMap] = (g, e) => @core.var_map_sql(g, e)
  t[Create] = @core.preprocess([
    @core.remove_unique_constraints,
    @core.ctas_with_tmp_tables_to_create_tmp_view(),
    @core.move_schema_columns_to_partitioned_by,
  ])
  t[Quantile] = @core.rename_func("PERCENTILE")
  t[ApproxQuantile] = @core.rename_func("PERCENTILE_APPROX")
  t[RegexpExtract] = @core.regexp_extract_sql
  t[RegexpExtractAll] = @core.regexp_extract_sql
  t[RegexpReplace] = @core.regexp_replace_sql
  t[RegexpLike] = (g, e) => g.binary(e, "RLIKE")
  t[RegexpSplit] = @core.rename_func("SPLIT")
  t[Right] = @core.right_to_substring_sql
  t[SchemaCommentProperty] = (g, e) => g.naked_property(e)
  t[ArrayUniqueAgg] = @core.rename_func("COLLECT_SET")
  t[Split] = (g, e) => {
    g.func("SPLIT", [
      e.this(),
      g.func("CONCAT", ["'\\\\Q'", e.expression(), "'\\\\E'"]),
    ])
  }
  t[Select] = @core.preprocess([
    @core.eliminate_qualify,
    @core.eliminate_distinct_on,
    @core.unnest_to_explode(unnest_using_arrays_zip=false),
    @core.any_to_exists,
  ])
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(g, e, func_name="LOCATE", supports_position=true)
  }
  t[StrToDate] = str_to_date_sql
  t[StrToTime] = str_to_time_sql
  t[StrToUnix] = str_to_unix_sql
  t[StructExtract] = @core.struct_extract_sql
  t[StarMap] = @core.rename_func("MAP")
  t[Table] = @core.preprocess([@core.unnest_generate_series])
  t[TimeStrToDate] = @core.rename_func("TO_DATE")
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeStrToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[TimestampTrunc] = (g, e) => {
    g.func("TRUNC", [e.this(), @core.weekstart_unit_to_str(g, e)])
  }
  t[TimeToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[ToBase64] = @core.rename_func("BASE64")
  t[TsOrDiToDi] = (g, e) => {
    "CAST(SUBSTR(REPLACE(CAST(\{g.sql_key(e, "this")} AS STRING), '-', ''), 1, 8) AS INT)"
  }
  t[TsOrDsAdd] = add_date_sql
  t[TsOrDsDiff] = date_diff_sql
  t[TsOrDsToDate] = to_date_sql
  t[TryCast] = @core.no_trycast_sql
  t[Trim] = (g, e) => @core.trim_sql(g, e)
  t[Unicode] = @core.rename_func("ASCII")
  t[UnixToStr] = (g, e) => {
    g.func("FROM_UNIXTIME", [e.this(), @core.time_format(dialect="hive")(g, e)])
  }
  t[UnixToTime] = unix_to_time_sql
  t[UnixToTimeStr] = @core.rename_func("FROM_UNIXTIME")
  t[Unnest] = @core.rename_func("EXPLODE")
  t[PartitionedByProperty] = (g, e) => "PARTITIONED BY \{g.sql_key(e, "this")}"
  t[NumberToStr] = @core.rename_func("FORMAT_NUMBER")
  t[National] = (g, e) => g.national_sql(e, prefix="")
  t[ClusteredColumnConstraint] = (g, e) => {
    "(\{g.expressions(expression=e, key="this", indent=false)})"
  }
  t[NonClusteredColumnConstraint] = (g, e) => {
    "(\{g.expressions(expression=e, key="this", indent=false)})"
  }
  t[NotForReplicationColumnConstraint] = (_, _) => ""
  t[OnProperty] = (_, _) => ""
  t[PartitionedByBucket] = (g, e) => {
    g.func("BUCKET", [e.expression(), e.this()])
  }
  t[PartitionByTruncate] = (g, e) => {
    g.func("TRUNCATE", [e.expression(), e.this()])
  }
  t[PrimaryKeyColumnConstraint] = (_, _) => "PRIMARY KEY"
  t[WeekOfYear] = @core.rename_func("WEEKOFYEAR")
  t[DayOfMonth] = @core.rename_func("DAYOFMONTH")
  t[DayOfWeek] = @core.rename_func("DAYOFWEEK")
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("LEVENSHTEIN")(g, e)
  }
  // `_jsonpathkey_sql` override (used by the base TRANSFORMS entry).
  t[JSONPathKey] = jsonpathkey_sql
  let hooks = d.gen_fns.hooks
  hooks.safe_json_path_key_re = Some(safe_json_path_key)
  hooks.format_time = Some(format_time)
  hooks.columndef_sql = Some(columndef_sql)
  let m = d.gen_fns.methods
  m[IgnoreNulls] = ignorenulls_sql
  m[Unnest] = (g, e) => @core.rename_func("EXPLODE")(g, e)
  m[Parameter] = parameter_sql
  m[Schema] = schema_sql
  m[Constraint] = constraint_sql
  m[RowFormatSerdeProperty] = rowformatserdeproperty_sql
  m[ArrayAgg] = arrayagg_sql
  m[Trunc] = trunc_sql
  m[DataType] = datatype_sql
  m[Version] = version_sql
  m[Struct] = struct_sql
  m[AlterColumn] = altercolumn_sql
  m[RenameColumn] = renamecolumn_sql
  m[AlterSet] = alterset_sql
  m[SerdeProperties] = serdeproperties_sql
  m[Exists] = exists_sql
  m[TimeToStr] = timetostr_sql
  m[UsingProperty] = usingproperty_sql
  m[FileFormatProperty] = fileformatproperty_sql
}

///|
/// `HiveGenerator.format_time`.
pub fn format_time(
  g : @core.Generator,
  e : @core.Expr,
  inverse_time_mapping : Map[String, String]?,
  inverse_time_trie : @core.Trie?,
) -> String? raise @core.SqlglotError {
  // Inferred property because this method is reused by other dialects under Hive
  let is_dialect_strict = g.dialect.cfg.time_mapping.get("MM") ==
    Some("%mstrict")
  if is_dialect_strict &&
    inverse_time_mapping is None &&
    e.kind.is_any(parse_time_expressions) {
    // Render a lenient %m/%d non-padded (M/d) so single-digit sources stay parseable
    return @core.format_time_opt(
      lenient_parse_format(g.sql_key(e, "format")),
      g.dialect.cfg.inverse_time_mapping,
      trie=g.dialect.inverse_time_trie,
    )
  }
  g.format_time_base(e, inverse_time_mapping?, inverse_time_trie?)
}

///|
let ignore_nulls_funcs : Array[@core.Kind] = [
  First,
  Last,
  FirstValue,
  LastValue,
]

///|
fn ignorenulls_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.this() {
    Some(this) if this.kind.is_any(ignore_nulls_funcs) =>
      g.func(this.kind.sql_name(), [this.this(), @core.true_()])
    _ => g.ignorenulls_sql(e)
  }
}

///|
fn jsonpathkey_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.get("this") {
    Some(Node(w)) if w.kind.is_a(JSONPathWildcard) => {
      g.unsupported("Unsupported wildcard in JSONPathKey expression")
      ""
    }
    _ => g.jsonpathkey_sql(e)
  }
}

///|
fn parameter_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let expression_sql = g.sql_key(e, "expression")
  let this = if expression_sql != "" {
    "\{this}:\{expression_sql}"
  } else {
    this
  }
  match e.parent {
    Some(p) if p.kind == EQ && p.parent is Some(pp) && pp.kind == SetItem =>
      // We need to produce SET key = value instead of SET ${key} = value
      this
    _ => "${\{this}}"
  }
}

///|
fn schema_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  for ordered in e.find_all([Ordered]).to_array() {
    if ordered.get("desc") is Some(Bool(false)) {
      ordered.set("desc", (None : @core.Expr?))
    }
  }
  g.schema_sql(e)
}

///|
fn constraint_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  for prop in e.find_all([Properties]).to_array() {
    prop.pop() |> ignore
  }
  let this = g.sql_key(e, "this")
  let expressions = g.expressions(expression=e, sep=" ", flat=true)
  "CONSTRAINT \{this} \{expressions}"
}

///|
fn rowformatserdeproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let serde_props = g.sql_key(e, "serde_properties")
  let serde_props = if serde_props != "" { " " + serde_props } else { "" }
  "ROW FORMAT SERDE \{g.sql_key(e, "this")}\{serde_props}"
}

///|
fn arrayagg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = match e.this() {
    Some(o) if o.kind.is_a(Order) => o.this()
    x => x
  }
  g.func("COLLECT_LIST", [arg])
}

///|
/// Hive/Spark lack native numeric TRUNC. CAST to BIGINT truncates toward zero.
fn trunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["decimals"])
  g.sql(Some(@core.exp_cast(e.this().unwrap(), BIGINT)))
}

///|
pub fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.datatype_this()
  let exprs = e.expressions()
  if this is Some(t) &&
    g.cfg.parameterizable_text_types.contains(t) &&
    (exprs.is_empty() || exprs[0].name() == "MAX") {
    e.set("this", @core.DType::TEXT)
    e.set("expressions", (None : @core.Expr?))
  } else if e.is_type([TEXT]) && !exprs.is_empty() {
    e.set("this", @core.DType::VARCHAR)
  } else if this is Some(t) && @core.dtype_temporal_types.contains(t) {
    e.set("expressions", (None : @core.Expr?))
  } else if e.is_type([FLOAT]) {
    match e.find([DataTypeParam]) {
      Some(size_expression) => {
        let size = match @core.parse_int_str(size_expression.name()) {
          Some(v) => v
          None => 0L
        }
        e.set("this", if size <= 32L { @core.DType::FLOAT } else { DOUBLE })
        e.set("expressions", (None : @core.Expr?))
      }
      None => ()
    }
  }
  g.datatype_sql(e)
}

///|
fn version_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let sql = g.version_sql(e)
  sql.replace(old="FOR ", new="")
}

///|
fn struct_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let values : Array[&@core.SqlArg] = []
  for x in e.expressions() {
    if x.kind == PropertyEQ {
      g.unsupported("Hive does not support named structs.")
      values.push(x.expression())
    } else {
      values.push(x)
    }
  }
  g.func("STRUCT", values)
}

///|
fn columndef_sql(
  g : @core.Generator,
  e : @core.Expr,
  sep : String,
) -> String raise @core.SqlglotError {
  let sep = match e.parent {
    Some(p) if p.kind.is_a(DataType) && p.is_type([STRUCT]) => ": "
    _ => sep
  }
  g.columndef_sql(e, sep~)
}

///|
fn altercolumn_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("exists") {
    g.unsupported("ALTER COLUMN IF EXISTS is not supported by this dialect")
  }
  let this = g.sql_key(e, "this")
  let new_name = match g.sql_key(e, "rename_to") {
    "" => this
    s => s
  }
  let dtype = g.sql_key(e, "dtype")
  let comment = if g.sql_key(e, "comment") != "" {
    " COMMENT \{g.sql_key(e, "comment")}"
  } else {
    ""
  }
  let default = g.sql_key(e, "default")
  let visible = e.has("visible")
  let allow_null = e.get("allow_null")
  let drop = e.has("drop")
  if default != "" || drop || visible || allow_null is Some(_) {
    g.unsupported("Unsupported CHANGE COLUMN syntax")
  }
  if dtype == "" {
    g.unsupported("CHANGE COLUMN without a type is not supported")
  }
  "CHANGE COLUMN \{this} \{new_name} \{dtype}\{comment}"
}

///|
fn renamecolumn_sql(
  g : @core.Generator,
  _e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported("Cannot rename columns without data type defined in Hive")
  ""
}

///|
fn alterset_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let exprs = g.expressions(expression=e, flat=true)
  let exprs = if exprs != "" { " " + exprs } else { "" }
  let location = g.sql_key(e, "location")
  let location = if location != "" { " LOCATION " + location } else { "" }
  let file_format = g.expressions(
    expression=e,
    key="file_format",
    flat=true,
    sep=" ",
  )
  let file_format = if file_format != "" {
    " FILEFORMAT " + file_format
  } else {
    ""
  }
  let serde = g.sql_key(e, "serde")
  let serde = if serde != "" { " SERDE " + serde } else { "" }
  let tags = g.expressions(expression=e, key="tag", flat=true, sep="")
  let tags = if tags != "" { " TAGS " + tags } else { "" }
  "SET\{serde}\{exprs}\{location}\{file_format}\{tags}"
}

///|
fn serdeproperties_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let prefix = if e.has("with_") { "WITH " } else { "" }
  let exprs = g.expressions(expression=e, flat=true)
  "\{prefix}SERDEPROPERTIES (\{exprs})"
}

///|
fn exists_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("expression") {
    return g.function_fallback_sql(e)
  }
  g.exists_sql(e)
}

///|
fn timetostr_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = match e.this() {
    Some(t) if t.kind == TimeStrToTime => t.this()
    x => x
  }
  g.func("DATE_FORMAT", [this, g.format_time(e)])
}

///|
fn usingproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let kind = e.text("kind")
  "USING \{kind} \{g.sql_key(e, "this")}"
}

///|
/// `HiveGenerator.fileformatproperty_sql`.
pub fn fileformatproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = match e.this() {
    Some(t) if t.kind == InputOutputFormat => g.sql_key(e, "this")
    _ => @core.py_upper(e.name())
  }
  "STORED AS \{this}"
}
