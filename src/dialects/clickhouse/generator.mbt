// Port of sqlglot/generators/clickhouse.py

///|
fn literal_number_eq(e : @core.Expr, n : String) -> Bool {
  e.kind == Literal && !e.is_string() && e.text("this") == n
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let timestamp = e.this().unwrap()
  let cast_bigint = (x : @core.Expr) => @core.exp_cast(x, BIGINT)
  match scale {
    None => return g.func("fromUnixTimestamp", [cast_bigint(timestamp)])
    Some(s) if literal_number_eq(s, "0") =>
      return g.func("fromUnixTimestamp", [cast_bigint(timestamp)])
    Some(s) if literal_number_eq(s, "3") =>
      return g.func("fromUnixTimestamp64Milli", [cast_bigint(timestamp)])
    Some(s) if literal_number_eq(s, "6") =>
      return g.func("fromUnixTimestamp64Micro", [cast_bigint(timestamp)])
    Some(s) if literal_number_eq(s, "9") =>
      return g.func("fromUnixTimestamp64Nano", [cast_bigint(timestamp)])
    Some(s) => {
      let pow = @core.func_("POW", [@core.literal_number("10"), s])
      g.func("fromUnixTimestamp", [
        cast_bigint(@core.mk(Div, [("this", timestamp), ("expression", pow)])),
      ])
    }
  }
}

///|
fn lower_func(sql : String) -> String {
  match sql.find("(") {
    Some(index) =>
      @core.py_lower(@core.substr(sql, 0, index)) +
      @core.substr(sql, index, sql.length())
    None => sql
  }
}

///|
fn quantile_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let quantile = e.arg("quantile").unwrap()
  let args = "(\{g.sql_key(e, "this")})"
  let func = if quantile.kind == Array {
    let qs : Array[&@core.SqlArg] = quantile.expressions().map(x => x)
    g.func("quantiles", qs)
  } else {
    g.func("quantile", [quantile])
  }
  func + args
}

///|
fn datetime_delta_sql(name : String) -> @core.GenFn {
  (g, e) => {
    if !e.has("unit") {
      return @core.rename_func(name)(g, e)
    }
    g.func(name, [@core.unit_to_var(e), e.expression(), e.this(), e.arg("zone")])
  }
}

///|
/// `datetime.datetime.fromisoformat(s).replace(tzinfo=None).isoformat(sep=" ")`
fn strip_iso_timezone(s : String) -> String {
  let chars = s.to_array()
  let n = chars.length()
  // date part
  let date = @core.substr(s, 0, if n < 10 { n } else { 10 })
  if n <= 10 {
    return date + " 00:00:00"
  }
  // time part (after 'T' or ' ')
  let rest = @core.substr(s, 11, n)
  let mut end = 0
  let rchars = rest.to_array()
  while end < rchars.length() &&
        (
          rchars[end].is_ascii_digit() ||
          rchars[end] == ':' ||
          rchars[end] == '.'
        ) {
    end += 1
  }
  let mut time = @core.substr(rest, 0, end)
  // isoformat: HH:MM:SS[.ffffff]
  let (hms, frac) = match time.find(".") {
    Some(i) =>
      (@core.substr(time, 0, i), @core.substr(time, i + 1, time.length()))
    None => (time, "")
  }
  let parts = hms.split(":").map(x => x.to_owned()).collect()
  let hh = if parts.length() > 0 { parts[0] } else { "00" }
  let mm = if parts.length() > 1 { parts[1] } else { "00" }
  let ss = if parts.length() > 2 { parts[2] } else { "00" }
  time = "\{hh}:\{mm}:\{ss}"
  let frac = if frac.length() > 6 { @core.substr(frac, 0, 6) } else { frac }
  let mut all_zero = true
  for c in frac {
    if c != '0' {
      all_zero = false
    }
  }
  if frac != "" && !all_zero {
    let mut f = frac
    while f.length() < 6 {
      f = f + "0"
    }
    time = time + "." + f
  }
  date + " " + time
}

///|
fn timestrtotime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut ts = e.this().unwrap()
  let tz = e.arg("zone")
  if tz is Some(_) && ts.kind == Literal {
    // Clickhouse will not accept timestamps that include a UTC offset, so we must remove them.
    let mut ts_string = @core.py_strip(ts.name())
    let ts_parts = ts_string.split(".").map(x => x.to_owned()).collect()
    if ts_parts.length() == 2 {
      // separate fractional seconds and UTC offset
      let offset_sep = if ts_parts[1].contains("+") { "+" } else { "-" }
      let ts_frac_parts = ts_parts[1]
        .split(offset_sep)
        .map(x => x.to_owned())
        .collect()
      let num_frac_parts = ts_frac_parts.length()
      let mut frac = ts_frac_parts[0]
      while frac.length() < 6 {
        frac = frac + "0"
      }
      ts_string = ts_parts[0] +
        "." +
        frac +
        (if num_frac_parts > 1 { offset_sep } else { "" }) +
        (if num_frac_parts > 1 { ts_frac_parts[1] } else { "" })
    }
    ts = @core.literal_string(strip_iso_timezone(ts_string))
  }
  // Non-nullable DateTime64 with microsecond precision
  let expressions = [@core.mk1(DataTypeParam, @core.literal_number("6"))]
  match tz {
    Some(t) => expressions.push(@core.mk1(DataTypeParam, t))
    None => ()
  }
  let datatype = @core.datatype_build(DATETIME64, kwargs=[
    ("expressions", expressions),
    ("nullable", false),
  ])
  g.sql(Some(@core.exp_cast_to(ts, datatype, dialect=g.dialect)))
}

///|
fn map_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let in_settings = match e.parent {
    Some(p) => p.arg_key == Some("settings")
    None => false
  }
  if !in_settings {
    return lower_func(@core.var_map_sql(g, e))
  }
  let keys = e.arg("keys")
  let values = e.arg("values")
  guard keys is Some(k) &&
    k.kind == Array &&
    values is Some(v) &&
    v.kind == Array else {
    g.unsupported("Cannot convert array columns into map.")
    return ""
  }
  let args = []
  let ks = k.expressions()
  let vs = v.expressions()
  for
    i in 0..<(if ks.length() < vs.length() { ks.length() } else { vs.length() }) {
    args.push("\{g.sql(Some(ks[i]))}: \{g.sql(Some(vs[i]))}")
  }
  let csv_args = args.join(", ")
  "{\{csv_args}}"
}

///|
fn json_cast_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let to = e.arg("to").unwrap()
  let mut to_sql = g.sql(Some(to))
  if !to.expressions().is_empty() {
    to_sql = g.sql(Some(@core.to_identifier(to_sql)))
  }
  "\{this}.:\{to_sql}"
}

///|
let string_type_mapping : Array[@core.DType] = [
  BLOB,
  CHAR,
  LONGBLOB,
  LONGTEXT,
  MEDIUMBLOB,
  MEDIUMTEXT,
  TINYBLOB,
  TINYTEXT,
  TEXT,
  VARBINARY,
  VARCHAR,
]

///|
/// There's no list in docs, but it can be found in Clickhouse code
/// see `ClickHouse/src/Parsers/ParserCreate*.cpp`
let on_cluster_targets : Array[String] = [
  "SCHEMA", "DATABASE", "TABLE", "VIEW", "DICTIONARY", "INDEX", "FUNCTION", "NAMED COLLECTION",
]

///|
/// https://clickhouse.com/docs/en/sql-reference/data-types/nullable
let non_nullable_types : Array[@core.DType] = [
  ARRAY,
  MAP,
  STRUCT,
  POINT,
  RING,
  LINESTRING,
  MULTILINESTRING,
  POLYGON,
  MULTIPOLYGON,
]

///|
/// `dtype.is_type(*dtypes, check_nullable=True)` for plain dtypes.
fn is_type_check_nullable(dt : @core.Expr, dtypes : Array[@core.DType]) -> Bool {
  if dt.get("nullable") is Some(Bool(true)) {
    return false
  }
  dt.is_type(dtypes)
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS (the
  // module-level table: WINDOW and QUALIFY only)
  let ah = d.gen_fns.after_having_modifier_transforms
  d.gen_fns.after_having_modifier_transforms = ah.filter(kv => kv.0 == "windows") +
    ah.filter(kv => kv.0 == "qualify")
  let t = d.gen_fns.transforms
  t.remove(AutoRefreshProperty)
  t[AnyValue] = @core.rename_func("any")
  t[ApproxDistinct] = @core.rename_func("uniq")
  t[ArrayDistinct] = @core.rename_func("arrayDistinct")
  t[ArrayConcat] = @core.rename_func("arrayConcat")
  t[ArrayContains] = @core.rename_func("has")
  t[ArrayFilter] = (g, e) => g.func("arrayFilter", [e.expression(), e.this()])
  t[Transform] = (g, e) => g.func("arrayMap", [e.expression(), e.this()])
  t[ArrayRemove] = @core.remove_from_array_using_filter
  t[ArrayReverse] = @core.rename_func("arrayReverse")
  t[ArraySlice] = @core.rename_func("arraySlice")
  t[ArraySum] = @core.rename_func("arraySum")
  t[ArrayMax] = @core.rename_func("arrayMax")
  t[ArrayMin] = @core.rename_func("arrayMin")
  t[ArgMax] = @core.arg_max_or_min_no_count("argMax")
  t[ArgMin] = @core.arg_max_or_min_no_count("argMin")
  t[Array] = @core.inline_array_sql
  t[CityHash64] = @core.rename_func("cityHash64")
  t[CastToStrType] = @core.rename_func("CAST")
  t[CurrentDatabase] = @core.rename_func("CURRENT_DATABASE")
  t[CurrentSchemas] = @core.rename_func("CURRENT_SCHEMAS")
  t[CountIf] = @core.rename_func("countIf")
  t[CosineDistance] = @core.rename_func("cosineDistance")
  t[CompressColumnConstraint] = (g, e) => {
    "CODEC(\{g.expressions(expression=e, key="this", flat=true)})"
  }
  t[ComputedColumnConstraint] = (g, e) => {
    let kw = if e.has("persisted") { "MATERIALIZED" } else { "ALIAS" }
    "\{kw} \{g.sql_key(e, "this")}"
  }
  t[CurrentDate] = (g, _) => g.func("CURRENT_DATE", [])
  t[CurrentVersion] = @core.rename_func("VERSION")
  t[DateAdd] = datetime_delta_sql("DATE_ADD")
  t[DateDiff] = datetime_delta_sql("DATE_DIFF")
  t[DateStrToDate] = @core.rename_func("toDate")
  t[DateSub] = datetime_delta_sql("DATE_SUB")
  t[DayOfMonth] = @core.rename_func("toDayOfMonth")
  t[DayOfYear] = @core.rename_func("toDayOfYear")
  t[Explode] = @core.rename_func("arrayJoin")
  t[FarmFingerprint] = @core.rename_func("farmFingerprint64")
  t[Final] = (g, e) => "\{g.sql_key(e, "this")} FINAL"
  t[IsNan] = @core.rename_func("isNaN")
  t[JarowinklerSimilarity] = @core.jarowinkler_similarity(
    "jaroWinklerSimilarity",
  )
  t[JSONCast] = json_cast_sql
  t[JSONExtract] = @core.json_extract_segments(
    "JSONExtractString",
    quoted_index=false,
  )
  t[JSONExtractScalar] = @core.json_extract_segments(
    "JSONExtractString",
    quoted_index=false,
  )
  t[JSONPathKey] = @core.json_path_key_only_name
  t[JSONPathRoot] = (_, _) => ""
  t[JSONPathSubscript] = (g, e) => {
    let this = g.json_path_part(e.get("this"))
    match @core.parse_int_str(this) {
      Some(i) if @core.is_int_str(this) => (i + 1L).to_string()
      _ => this
    }
  }
  t[Length] = @core.length_or_char_length_sql
  t[Map] = map_sql
  t[Median] = @core.rename_func("median")
  t[Nullif] = @core.rename_func("nullIf")
  t[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  t[Pivot] = @core.no_pivot_sql
  t[Quantile] = quantile_sql
  t[RegexpLike] = (g, e) => g.func("match", [e.this(), e.expression()])
  t[Rand] = @core.rename_func("randCanonical")
  t[StartsWith] = @core.rename_func("startsWith")
  t[Struct] = @core.rename_func("tuple")
  t[Trunc] = @core.rename_func("trunc")
  t[EndsWith] = @core.rename_func("endsWith")
  t[EuclideanDistance] = @core.rename_func("L2Distance")
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(
      g,
      e,
      func_name="POSITION",
      supports_position=true,
      use_ansi_position=false,
    )
  }
  t[TimeToStr] = (g, e) => {
    let this = match e.this() {
      Some(x) if x.kind == TsOrDsToTimestamp => x.this()
      other => other
    }
    g.func("formatDateTime", [this, g.format_time(e), e.arg("zone")])
  }
  t[TimeStrToTime] = timestrtotime_sql
  t[TimestampAdd] = datetime_delta_sql("TIMESTAMP_ADD")
  t[TimestampSub] = datetime_delta_sql("TIMESTAMP_SUB")
  t[Typeof] = @core.rename_func("toTypeName")
  t[VarMap] = map_sql
  t[Xor] = (g, e) => g.func("xor", [e.this(), e.expression()])
  t[MD5Digest] = @core.rename_func("MD5")
  t[MD5] = (g, e) => {
    g.func("LOWER", [g.func("HEX", [g.func("MD5", [e.this()])])])
  }
  t[SHA] = @core.rename_func("SHA1")
  t[SHA1Digest] = @core.rename_func("SHA1")
  t[SHA2] = @core.sha256_sql
  t[SHA2Digest] = @core.sha2_digest_sql
  t[Split] = (g, e) => {
    g.func("splitByString", [e.arg("expression"), e.this(), e.arg("limit")])
  }
  t[RegexpSplit] = (g, e) => {
    g.func("splitByRegexp", [e.arg("expression"), e.this(), e.arg("limit")])
  }
  t[UnixToTime] = unix_to_time_sql
  t[Trim] = (g, e) => @core.trim_sql(g, e, default_trim_type="BOTH")
  t[Variance] = @core.rename_func("varSamp")
  t[VariancePop] = @core.rename_func("varPop")
  t[SchemaCommentProperty] = (g, e) => g.naked_property(e)
  t[Stddev] = @core.rename_func("stddevSamp")
  t[Chr] = @core.rename_func("CHAR")
  t[Lag] = @core.rename_func("lag")
  t[Lead] = @core.rename_func("lead")
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("editDistance")(g, e)
  }
  t[ParseDatetime] = (g, e) => {
    g.func("parseDateTime", [e.this(), e.arg("format"), e.arg("zone")])
  }
  let m = d.gen_fns.methods
  m[GroupConcat] = groupconcat_sql
  m[Select] = (g, e) => {
    match e.arg("limit") {
      Some(limit) if limit.kind == Fetch && !e.has("order") => {
        let count = match limit.arg("count") {
          Some(c) => c
          None => @core.literal_number("1")
        }
        e.set("limit", @core.mk(Limit, [("expression", count)]))
      }
      _ => ()
    }
    g.select_sql(e)
  }
  m[Offset] = (g, e) => {
    let mut offset = g.offset_sql(e)
    // OFFSET ... FETCH syntax requires a "ROW" or "ROWS" keyword
    // https://clickhouse.com/docs/sql-reference/statements/select/offset
    match e.parent {
      Some(p) if p.kind == Select &&
        p.arg("limit") is Some(l) &&
        l.kind == Fetch => offset = offset + " ROWS"
      _ => ()
    }
    offset
  }
  m[StrToDate] = (g, e) => {
    let strtodate_sql = g.function_fallback_sql(e)
    match e.parent {
      Some(p) if p.kind.is_a(Cast) => strtodate_sql
      // StrToDate returns DATEs in other dialects (eg. postgres), so
      // this branch aims to improve the transpilation to clickhouse
      _ => g.cast_sql_v(@core.exp_cast(e, DATE))
    }
  }
  d.gen_fns.hooks.cast_sql = Some((g, e, safe_prefix) => {
    match (e.this(), e.arg("to")) {
      (Some(this), Some(to)) if this.kind == StrToDate &&
        to == @core.DType::DATETIME.into_expr() => g.sql(Some(this))
      _ => g.cast_sql(e, safe_prefix?)
    }
  })
  m[TryCast] = (g, e) => {
    let dtype = e.arg("to").unwrap()
    if !is_type_check_nullable(dtype, non_nullable_types) {
      // Casting x into Nullable(T) appears to behave similarly to TRY_CAST(x AS T)
      dtype.set("nullable", true)
    }
    g.cast_sql(e)
  }
  m[LikeProperty] = (g, e) => "AS \{g.sql_key(e, "this")}"
  m[EQ] = (g, e) => any_to_has(g, e, (g, e) => g.eq_sql(e))
  m[NEQ] = (g, e) => any_to_has(g, e, (g, e) => g.neq_sql(e), prefix="NOT ")
  m[RegexpILike] = (g, e) => {
    // Manually add a flag to make the search case-insensitive
    let regex = g.func("CONCAT", ["'(?i)'", e.expression()])
    g.func("match", [e.this(), regex])
  }
  m[DataType] = datatype_sql
  m[CTE] = (g, e) => {
    if e.has("scalar") {
      let this = g.sql_key(e, "this")
      let alias = g.sql_key(e, "alias")
      return "\{this} AS \{alias}"
    }
    g.cte_sql(e)
  }
  d.gen_fns.hooks.after_limit_modifiers = Some((g, e) => {
    let base = g.after_limit_modifiers_base(e)
    base.push(
      if e.has("settings") {
        g.seg("SETTINGS ") +
        g.expressions(expression=e, key="settings", flat=true)
      } else {
        ""
      },
    )
    base.push(
      if e.has("format") {
        g.seg("FORMAT ") + g.sql_key(e, "format")
      } else {
        ""
      },
    )
    base
  })
  m[Placeholder] = (g, e) => "{\{e.name()}: \{g.sql_key(e, "kind")}}"
  m[OnCluster] = (g, e) => "ON CLUSTER \{g.sql_key(e, "this")}"
  m[AutoRefreshProperty] = autorefreshproperty_sql
  d.gen_fns.hooks.createable_sql = Some(createable_sql)
  m[Create] = create_sql
  m[PreWhere] = (g, e) => {
    let this = g.indent(g.sql_key(e, "this"))
    "\{g.seg("PREWHERE")}\{g.sep()}\{this}"
  }
  m[IndexColumnConstraint] = (g, e) => {
    let this = pfx(" ", g.sql_key(e, "this"))
    let expr = pfx(" ", g.sql_key(e, "expression"))
    let index_type = pfx(" TYPE ", g.sql_key(e, "index_type"))
    let granularity = pfx(" GRANULARITY ", g.sql_key(e, "granularity"))
    "INDEX\{this}\{expr}\{index_type}\{granularity}"
  }
  m[Partition] = (g, e) => "PARTITION \{g.expressions(expression=e, flat=true)}"
  m[PartitionId] = (g, e) => "ID \{g.sql(e.this())}"
  m[ReplacePartition] = (g, e) => {
    "REPLACE \{g.sql(e.expression())} FROM \{g.sql_key(e, "source")}"
  }
  m[ProjectionDef] = (g, e) => {
    "PROJECTION \{g.sql(e.this())} \{g.wrap(e.expression().unwrap())}"
  }
  m[NestedJSONSelect] = (g, e) => {
    "\{g.sql_key(e, "this")}.^\{g.sql_key(e, "expression")}"
  }
  m[Is] = (g, e) => {
    let is_sql = g.is_sql(e)
    match e.parent {
      // value IS NOT NULL -> NOT (value IS NULL)
      Some(p) if p.kind == Not => g.wrap_sql(is_sql)
      _ => is_sql
    }
  }
  m[In] = (g, e) => {
    let in_sql = g.in_sql(e)
    match e.parent {
      Some(p) if p.kind == Not && e.has("is_global") =>
        in_sql.replace(old="GLOBAL IN", new="GLOBAL NOT IN")
      _ => in_sql
    }
  }
  m[Not] = (g, e) => {
    match e.this() {
      Some(this) if this.kind == In => {
        if this.has("is_global") {
          // let `GLOBAL IN` child interpose `NOT`
          return g.sql_key(e, "this")
        }
        e.set("this", @core.exp_paren(this, copy=false))
      }
      _ => ()
    }
    g.not_sql(e)
  }
  d.gen_fns.hooks.values_sql = Some((g, e, _values_as_table) => {
    // If the VALUES clause contains tuples of expressions, we need to treat it
    // as a table since Clickhouse will automatically alias it as such.
    let values_as_table = match e.arg("alias") {
      Some(alias) if alias.has("columns") && !e.expressions().is_empty() => {
        let values = e.expressions()[0].expressions()
        values.iter().any(v => v.kind == Tuple)
      }
      _ => true
    }
    g.values_sql(e, values_as_table~)
  })
  m[TimestampTrunc] = timestamptrunc_sql
  m[DateTrunc] = timestamptrunc_sql
}

///|
fn pfx(prefix : String, s : String) -> String {
  if s == "" {
    ""
  } else {
    prefix + s
  }
}

///|
fn groupconcat_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let separator = e.arg("separator")
  match this {
    Some(limit) if limit.kind == Limit && limit.this() is Some(lt) => {
      let this = lt.pop()
      return g.sql(
        Some(
          @core.mk(ParameterizedAgg, [
            ("this", "groupConcat"),
            ("params", [this]),
            ("expressions", [separator, limit.expression()]),
          ]),
        ),
      )
    }
    _ => ()
  }
  if separator is Some(sep) {
    return g.sql(
      Some(
        @core.mk(ParameterizedAgg, [
          ("this", "groupConcat"),
          ("params", [this]),
          ("expressions", [sep]),
        ]),
      ),
    )
  }
  g.func("groupConcat", [this])
}

///|
fn any_to_has(
  g : @core.Generator,
  e : @core.Expr,
  default : @core.GenFn,
  prefix? : String = "",
) -> String raise @core.SqlglotError {
  let left = e.this()
  let right = e.expression()
  let (arr, this) = match (left, right) {
    (Some(l), _) if l.kind == Any => (l, right)
    (_, Some(r)) if r.kind == Any => (r, left)
    _ => return default(g, e)
  }
  prefix + g.func("has", [arr.this().unwrap().unnest(), this.unwrap()])
}

///|
fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // String is the standard ClickHouse type, every other variant is just an alias.
  // Additionally, any supplied length parameter will be ignored.
  //
  // https://clickhouse.com/docs/en/sql-reference/data-types/string
  let mut dtype = match e.datatype_this() {
    Some(t) if string_type_mapping.contains(t) => "String"
    _ => g.datatype_sql(e)
  }
  // This section changes the type to `Nullable(...)` if the following conditions hold:
  // - It's marked as nullable - this ensures we won't wrap ClickHouse types with `Nullable`
  //   and change their semantics
  // - It's not the key type of a `Map`. This is because ClickHouse enforces the following
  //   constraint: "Type of Map key must be a type, that can be represented by integer or
  //   String or FixedString (possibly LowCardinality) or UUID or IPv6"
  // - It's not a composite type, e.g. `Nullable(Array(...))` is not a valid type
  let nullable = e.get("nullable")
  let is_map_key = match e.parent {
    Some(p) if p.kind.is_a(DataType) &&
      is_type_check_nullable(p, [MAP]) &&
      (e.index is None || e.index == Some(0)) => true
    _ => false
  }
  if nullable is Some(Bool(true)) ||
    (
      nullable is None &&
      !is_map_key &&
      !is_type_check_nullable(e, non_nullable_types)
    ) {
    dtype = "Nullable(\{dtype})"
  }
  dtype
}

///|
fn refresh_interval_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.kind == Add {
    return "\{refresh_interval_sql(g, e.this().unwrap())} \{refresh_interval_sql(g, e.expression().unwrap())}"
  }
  if e.kind != Interval {
    raise @core.ValueError("\{e.kind.name()} is not Interval.")
  }
  g.sql(Some(e))
}

///|
fn autorefreshproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let cadence = g.sql_key(e, "cadence")
  let schedule = match e.this() {
    Some(interval) if cadence != "" =>
      " \{cadence} \{refresh_interval_sql(g, interval)}"
    _ => ""
  }
  let offset = match e.arg("offset") {
    Some(o) => " OFFSET \{refresh_interval_sql(g, o)}"
    None => ""
  }
  let randomize = match e.arg("randomize") {
    Some(r) => " RANDOMIZE FOR \{refresh_interval_sql(g, r)}"
    None => ""
  }
  let dependencies = pfx(" DEPENDS ON ", g.expressions(expression=e, flat=true))
  let settings = pfx(" ", g.sql_key(e, "settings"))
  let append = if e.has("append") { " APPEND" } else { "" }
  "REFRESH\{schedule}\{offset}\{randomize}\{dependencies}\{settings}\{append}"
}

///|
fn createable_sql(
  g : @core.Generator,
  e : @core.Expr,
  locations : @core.PropLocs,
) -> String raise @core.SqlglotError {
  let post_name = locations.get(PostName).unwrap_or([])
  if on_cluster_targets.contains(e.text("kind")) && !post_name.is_empty() {
    let this_name = match e.this() {
      Some(s) if s.kind == Schema => g.sql_key(s, "this")
      _ => g.sql_key(e, "this")
    }
    let props = []
    for prop in post_name {
      props.push(g.sql(Some(prop)))
    }
    let this_properties = props.join(" ")
    let this_schema = match e.this() {
      Some(s) => g.schema_columns_sql(s)
      None => ""
    }
    let this_schema = if this_schema != "" {
      "\{g.sep()}\{this_schema}"
    } else {
      ""
    }
    return "\{this_name}\{g.sep()}\{this_properties}\{this_schema}"
  }
  g.createable_sql_base(e, locations)
}

///|
fn create_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // The comment property comes last in CTAS statements, i.e. after the query
  let mut comment_prop : @core.Expr? = None
  match e.expression() {
    Some(query) if query.kind.is_a(Query) => {
      comment_prop = e.find([SchemaCommentProperty])
      match comment_prop {
        Some(c) => {
          c.pop() |> ignore
          query.replace(Some(@core.exp_paren(query))) |> ignore
        }
        None => ()
      }
    }
    _ => ()
  }
  let create_sql = g.create_sql(e)
  let comment_sql = pfx(" ", g.sql(comment_prop))
  "\{create_sql}\{comment_sql}"
}

///|
fn timestamptrunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut unit = @core.weekstart_unit_to_str(g, e)
  // https://clickhouse.com/docs/whats-new/changelog/2023#improvement
  let (major, minor, _) = g.dialect.version
  if (major < 23 || (major == 23 && minor < 12)) &&
    unit is Some(u) &&
    u.is_string() {
    unit = Some(@core.literal_string(@core.py_lower(u.name())))
  }
  g.func("dateTrunc", [unit, e.this(), e.arg("zone")])
}
