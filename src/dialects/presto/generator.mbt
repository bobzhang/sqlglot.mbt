// Port of sqlglot/generators/presto.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  // (the module-level table: only WINDOW and QUALIFY)
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
  let t = d.gen_fns.transforms
  t[AnyValue] = @core.rename_func("ARBITRARY")
  t[ApproxQuantile] = (g, e) => {
    g.func("APPROX_PERCENTILE", [
      e.this(),
      e.arg("weight"),
      e.arg("quantile"),
      e.arg("accuracy"),
    ])
  }
  t[ArgMax] = @core.rename_func("MAX_BY")
  t[ArgMin] = @core.rename_func("MIN_BY")
  t[Array] = @core.preprocess([@core.inherit_struct_field_names], generator=(
    g,
    e,
  ) => "ARRAY[\{g.expressions(expression=e, flat=true)}]")
  t[ArrayAny] = @core.rename_func("ANY_MATCH")
  t[ArrayConcat] = @core.rename_func("CONCAT")
  t[ArrayContains] = @core.rename_func("CONTAINS")
  t[ArrayToString] = @core.rename_func("ARRAY_JOIN")
  t[ArrayUniqueAgg] = @core.rename_func("SET_AGG")
  t[ArraySlice] = @core.rename_func("SLICE")
  t[AtTimeZone] = @core.rename_func("AT_TIMEZONE")
  t[BitwiseAnd] = (g, e) => g.func("BITWISE_AND", [e.this(), e.expression()])
  t[BitwiseLeftShift] = @core.rename_func("BITWISE_LEFT_SHIFT")
  t[BitwiseNot] = (g, e) => g.func("BITWISE_NOT", [e.this()])
  t[BitwiseOr] = (g, e) => g.func("BITWISE_OR", [e.this(), e.expression()])
  t[BitwiseRightShift] = @core.rename_func("BITWISE_RIGHT_SHIFT")
  t[BitwiseXor] = (g, e) => g.func("BITWISE_XOR", [e.this(), e.expression()])
  t[Cast] = @core.preprocess([@core.epoch_cast_to_ts])
  t[CurrentTime] = (_, _) => "CURRENT_TIME"
  t[CurrentTimestamp] = (_, _) => "CURRENT_TIMESTAMP"
  t[CurrentUser] = (_, _) => "CURRENT_USER"
  t[DateAdd] = date_delta_sql("DATE_ADD")
  t[DateDiff] = date_diff_sql
  t[DatetimeDiff] = date_diff_sql
  t[TimestampDiff] = date_diff_sql
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateToDi] = (g, e) => {
    "CAST(DATE_FORMAT(\{g.sql_key(e, "this")}, \{g.dialect.cfg.dateint_format}) AS INT)"
  }
  t[DateSub] = date_delta_sql("DATE_ADD", negate_interval=true)
  t[DayOfWeek] = (g, e) => "((\{g.func("DAY_OF_WEEK", [e.this()])} % 7) + 1)"
  t[DayOfWeekIso] = @core.rename_func("DAY_OF_WEEK")
  t[Decode] = (g, e) => @core.encode_decode_sql(g, e, "FROM_UTF8")
  t[DiToDate] = (g, e) => {
    "CAST(DATE_PARSE(CAST(\{g.sql_key(e, "this")} AS VARCHAR), \{g.dialect.cfg.dateint_format}) AS DATE)"
  }
  t[Encode] = (g, e) => @core.encode_decode_sql(g, e, "TO_UTF8")
  t[FileFormatProperty] = (g, e) => {
    "format=\{g.sql(Some(@core.literal_string(e.name())))}"
  }
  t[First] = first_last_sql
  t[FromISO8601Date] = @core.rename_func("FROM_ISO8601_DATE")
  t[FromISO8601Timestamp] = @core.rename_func("FROM_ISO8601_TIMESTAMP")
  t[FromTimeZone] = (g, e) => {
    "WITH_TIMEZONE(\{g.sql_key(e, "this")}, \{g.sql_key(e, "zone")}) AT TIME ZONE 'UTC'"
  }
  t[GenerateSeries] = @core.sequence_sql
  t[GenerateDateArray] = @core.sequence_sql
  t[If] = @core.if_sql()
  t[ILike] = @core.no_ilike_sql
  t[Initcap] = initcap_sql
  t[Last] = first_last_sql
  t[LastDay] = (g, e) => g.func("LAST_DAY_OF_MONTH", [e.this()])
  t[Lateral] = explode_to_unnest_sql
  t[Left] = @core.left_to_substring_sql
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("LEVENSHTEIN_DISTANCE")(g, e)
  }
  t[LogicalAnd] = @core.rename_func("BOOL_AND")
  t[LogicalOr] = @core.rename_func("BOOL_OR")
  t[Pivot] = @core.no_pivot_sql
  t[Quantile] = quantile_sql
  t[RegexpExtract] = @core.regexp_extract_sql
  t[RegexpExtractAll] = @core.regexp_extract_sql
  t[Right] = @core.right_to_substring_sql
  t[Schema] = schema_sql
  t[SchemaCommentProperty] = (g, e) => g.naked_property(e)
  t[Select] = @core.preprocess([
    @core.eliminate_window_clause,
    @core.eliminate_qualify,
    @core.eliminate_distinct_on,
    @optimizer.explode_projection_to_unnest(index_offset=1, unnest_map=true),
    @core.eliminate_semi_and_anti_joins,
    amend_exploded_column_table,
  ])
  t[SortArray] = no_sort_array
  t[SqlSecurityProperty] = (g, e) => "SECURITY \{g.sql_key(e, "this")}"
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(g, e, supports_occurrence=true)
  }
  t[StrToDate] = (g, e) => "CAST(\{str_to_time_sql(g, e)} AS DATE)"
  t[StrToMap] = @core.rename_func("SPLIT_TO_MAP")
  t[StrToTime] = str_to_time_sql
  t[StructExtract] = @core.struct_extract_sql
  t[Table] = @core.preprocess([@core.unnest_generate_series])
  t[Timestamp] = @core.no_timestamp_sql
  t[TimestampAdd] = date_delta_sql("DATE_ADD")
  t[TimestampTrunc] = @core.timestamptrunc_sql()
  t[TimeStrToDate] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeStrToUnix] = (g, e) => {
    g.func("TO_UNIXTIME", [
      g.func("DATE_PARSE", [e.this(), g.dialect.cfg.time_format]),
    ])
  }
  t[TimeToStr] = (g, e) => g.func("DATE_FORMAT", [e.this(), g.format_time(e)])
  t[TimeToUnix] = @core.rename_func("TO_UNIXTIME")
  t[ToChar] = (g, e) => g.func("DATE_FORMAT", [e.this(), g.format_time(e)])
  t[TryCast] = @core.preprocess([@core.epoch_cast_to_ts])
  t[TsOrDiToDi] = (g, e) => {
    "CAST(SUBSTR(REPLACE(CAST(\{g.sql_key(e, "this")} AS VARCHAR), '-', ''), 1, 8) AS INT)"
  }
  t[TsOrDsAdd] = ts_or_ds_add_sql
  t[TsOrDsDiff] = ts_or_ds_diff_sql
  t[TsOrDsToDate] = ts_or_ds_to_date_sql
  t[Unhex] = @core.rename_func("FROM_HEX")
  t[UnixToStr] = (g, e) => {
    "DATE_FORMAT(FROM_UNIXTIME(\{g.sql_key(e, "this")}), \{g.format_time(e).unwrap_or("")})"
  }
  t[UnixToTime] = unix_to_time_sql
  t[UnixToTimeStr] = (g, e) => {
    "CAST(FROM_UNIXTIME(\{g.sql_key(e, "this")}) AS VARCHAR)"
  }
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[With] = @core.preprocess([@core.add_recursive_cte_column_names])
  t[WithinGroup] = @core.preprocess([@core.remove_within_group_for_percentiles])
  // Note: Presto's TRUNCATE always returns DOUBLE, even with decimals=0, whereas
  // most dialects return INT (SQLite also returns REAL, see sqlite.py).
  t[Trunc] = @core.rename_func("TRUNCATE")
  t[Xor] = @core.bool_xor_sql
  t[MD5Digest] = @core.rename_func("MD5")
  t[SHA] = @core.rename_func("SHA1")
  t[SHA1Digest] = @core.rename_func("SHA1")
  t[SHA2Digest] = sha2_digest_sql
  t[Substring] = @core.rename_func("SUBSTR")
  let m = d.gen_fns.methods
  m[Extract] = extract_sql
  m[JSONFormat] = jsonformat_sql
  m[MD5] = md5_sql
  m[SHA2] = sha2_sql
  m[StrToUnix] = strtounix_sql
  m[Bracket] = (g, e) => {
    if e.has("safe") {
      @core.bracket_to_element_at_sql(g, e)
    } else {
      g.bracket_sql(e)
    }
  }
  m[Struct] = struct_sql
  m[Interval] = (g, e) => {
    if e.has("this") && @core.py_upper(e.text("unit")).has_prefix("WEEK") {
      "(\{e.this_().name()} * INTERVAL '7' DAY)"
    } else {
      g.interval_sql(e)
    }
  }
  m[Transaction] = (_, e) => {
    let modes = e.raw_list("modes").filter_map(v => v.as_str())
    let modes = if modes.is_empty() { "" } else { " " + modes.join(", ") }
    "START TRANSACTION\{modes}"
  }
  d.gen_fns.hooks.offset_limit_modifiers = Some((g, e, _fetch, limit) => {
    [g.sql_key(e, "offset"), g.sql(limit)]
  })
  m[Create] = create_sql
  m[Delete] = delete_sql
  m[JSONExtract] = jsonextract_sql
  m[GroupConcat] = (g, e) => {
    g.func("ARRAY_JOIN", [g.func("ARRAY_AGG", [e.this()]), e.arg("separator")])
  }
}

///|
fn extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let date_part = e.name()
  if !date_part.has_prefix("EPOCH") {
    return g.extract_sql(e)
  }
  let scale = match date_part {
    "EPOCH_MILLISECOND" => Some("1000")
    "EPOCH_MICROSECOND" => Some("1000000")
    "EPOCH_NANOSECOND" => Some("1000000000")
    _ => None
  }
  let value = e.expression_()
  let ts = @core.exp_cast_to(value, @core.DType::TIMESTAMP.into_expr())
  let mut to_unix = @core.mk1(TimeToUnix, ts)
  match scale {
    Some(s) =>
      to_unix = @core.mk(Mul, [
        ("this", to_unix),
        ("expression", @core.literal_number(s)),
      ])
    None => ()
  }
  g.sql(Some(to_unix))
}

///|
fn jsonformat_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this()
  let is_json = e.has("is_json")
  match this {
    Some(t) if !(is_json || t.get_type() is Some(_)) =>
      this = Some(@core.gen_annotate_types(t, g.dialect))
    _ => ()
  }
  match this {
    Some(t) if !(is_json || t.is_type([JSON])) =>
      t.replace(Some(@core.exp_cast(t, JSON))) |> ignore
    _ => ()
  }
  g.function_fallback_sql(e)
}

///|
fn md5_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this_()
  if this.get_type() is None {
    this = @core.gen_annotate_types(this, g.dialect)
  }
  if this.is_type(@core.dtype_text_types) {
    this = @core.mk(Encode, [
      ("this", this),
      ("charset", @core.literal_string("utf-8")),
    ])
  }
  g.func("LOWER", [g.func("TO_HEX", [g.func("MD5", [g.sql(Some(this))])])])
}

///|
fn sha2_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let length = e.text("length")
  let length = if length == "" { "256" } else { length }
  if length != "256" && length != "512" {
    g.unsupported("SHA\{length} is not supported in Presto")
  }
  let mut this = e.this_()
  if this.is_type(@core.dtype_text_types) {
    this = @core.mk(Encode, [
      ("this", this),
      ("charset", @core.literal_string("utf-8")),
    ])
  }
  g.func("LOWER", [
    g.func("TO_HEX", [g.func("SHA\{length}", [g.sql(Some(this))])]),
  ])
}

///|
fn strtounix_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Since `TO_UNIXTIME` requires a `TIMESTAMP`, we need to parse the argument into one.
  // To do this, we first try to `DATE_PARSE` it, but since this can fail when there's a
  // timezone involved, we wrap it in a `TRY` call and use `PARSE_DATETIME` as a fallback,
  // which seems to be using the same time mapping as Hive.
  let this = e.this_()
  let value_as_text = @core.exp_cast(this, TEXT)
  let value_as_timestamp = if this.is_string() {
    @core.exp_cast(this, TIMESTAMP)
  } else {
    this
  }
  let parse_without_tz = g.func("DATE_PARSE", [value_as_text, g.format_time(e)])
  let formatted_value = g.func("DATE_FORMAT", [
    value_as_timestamp,
    g.format_time(e),
  ])
  let hive = @hive.dialect()
  let parse_with_tz = g.func("PARSE_DATETIME", [
    formatted_value,
    g.format_time(
      e,
      inverse_time_mapping=hive.cfg.inverse_time_mapping,
      inverse_time_trie=hive.inverse_time_trie,
    ),
  ])
  let coalesced = g.func("COALESCE", [
    g.func("TRY", [parse_without_tz]),
    parse_with_tz,
  ])
  g.func("TO_UNIXTIME", [coalesced])
}

///|
fn struct_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.get_type() is None {
    @core.gen_annotate_types(e, g.dialect) |> ignore
  }
  let values : Array[String] = []
  let schema : Array[String] = []
  let mut unknown_type = false
  for x in e.expressions() {
    if x.kind.is_a(PropertyEQ) {
      match x.get_type() {
        // An untyped node has an unknown type (annotate_types types every node)
        None => unknown_type = true
        Some(t) if t.is_type([UNKNOWN]) => unknown_type = true
        Some(t) => schema.push("\{g.sql_key(x, "this")} \{g.sql(Some(t))}")
      }
      values.push(g.sql_key(x, "expression"))
    } else {
      values.push(g.sql(Some(x)))
    }
  }
  let size = e.expressions().length()
  if size == 0 || schema.length() != size {
    if unknown_type {
      g.unsupported(
        "Cannot convert untyped key-value definitions (try annotate_types).",
      )
    }
    return g.func("ROW", values.map(v => (v : &@core.SqlArg)))
  }
  "CAST(ROW(\{values.join(", ")}) AS ROW(\{schema.join(", ")}))"
}

///|
/// Presto doesn't support CREATE VIEW with expressions (ex: `CREATE VIEW x (cola)` then
/// `(cola)` is the expression), so we need to remove them
fn create_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let kind = e.text("kind")
  match e.this() {
    Some(schema) if kind == "VIEW" && !schema.expressions().is_empty() =>
      schema.set("expressions", (None : @core.Expr?))
    _ => ()
  }
  g.create_sql(e)
}

///|
/// Presto only supports DELETE FROM for a single table without an alias, so we need
/// to remove the unnecessary parts. If the original DELETE statement contains more
/// than one table to be deleted, we can't safely map it 1-1 to a Presto statement.
fn delete_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let tables = e.list("tables")
  let tables = if tables.is_empty() {
    match e.this() {
      Some(t) => [t]
      None => []
    }
  } else {
    tables
  }
  if tables.length() > 1 {
    return g.delete_sql(e)
  }
  let mut e = e
  guard tables.get(0) is Some(table) else { return g.delete_sql(e) }
  e.set("this", table)
  e.set("tables", (None : @core.Expr?))
  if table.kind.is_a(Table) {
    match table.arg("alias") {
      Some(table_alias) => {
        table_alias.pop() |> ignore
        e = @core.unqualify_columns(e.copy())
      }
      None => ()
    }
  }
  g.delete_sql(e)
}

///|
fn jsonextract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let is_json_extract = match
    g.dialect.settings.get("variant_extract_is_json_extract") {
    Some(v) =>
      match @core.to_bool_str(v) {
        Some(b) => b
        None => v != ""
      }
    None => true
  }
  // Generate JSON_EXTRACT unless the user has configured that a Snowflake / Databricks
  // VARIANT extract (e.g. col:x.y) should map to dot notation (i.e ROW access) in Presto/Trino
  if !e.has("variant_extract") || is_json_extract {
    let args : Array[&@core.SqlArg] = [e.this(), e.expression()]
    for x in e.expressions() {
      args.push(x)
    }
    return g.func("JSON_EXTRACT", args)
  }
  let this = g.sql_key(e, "this")
  // Convert the JSONPath extraction `JSON_EXTRACT(col, '$.x.y) to a ROW access col.x.y
  let segments = []
  let path_keys = e.expression_().expressions()
  for i in 1..<path_keys.length() {
    let path_key = path_keys[i]
    if !path_key.kind.is_a(JSONPathKey) {
      // Cannot transpile subscripts, wildcards etc to dot notation
      g.unsupported(
        "Cannot transpile JSONPath segment '\{g.sql(Some(path_key))}' to ROW access",
      )
      continue
    }
    let mut key = path_key.text("this")
    if !@core.is_safe_identifier(key) {
      key = "\"\{key}\""
    }
    segments.push(".\{key}")
  }
  "\{this}\{segments.join("")}"
}
