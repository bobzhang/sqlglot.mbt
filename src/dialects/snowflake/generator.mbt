// Port of sqlglot/generators/snowflake.py (SnowflakeGenerator): TRANSFORMS and
// method registration. Method bodies live in generator_methods.mbt, preprocessing
// transforms in generator_transforms.mbt.

///|
fn try_prefix(e : @core.Expr) -> String {
  if e.has("safe") {
    "TRY_"
  } else {
    ""
  }
}

///|
fn regexpilike_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut flag = e.text("flag")
  if !flag.contains("i") {
    flag = flag + "i"
  }
  g.func("REGEXP_LIKE", [
    e.this(),
    e.expression(),
    Some(@core.literal_string(flag)),
  ])
}

///|
fn regexpextract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Other dialects don't support all of the following parameters, so we need to
  // generate default values as necessary to ensure the transpilation is correct
  let mut group = e.arg("group")
  // To avoid generating all these default values, we set group to None if
  // it's 0 (also default value) which doesn't trigger the following chain
  if group is Some(gr) && gr.name() == "0" {
    group = None
  }
  let parameters = match e.arg("parameters") {
    Some(p) => Some(p)
    None => group.map(_ => @core.literal_string("c"))
  }
  let occurrence = match e.arg("occurrence") {
    Some(o) => Some(o)
    None => parameters.map(_ => @core.literal_number("1"))
  }
  let position = match e.arg("position") {
    Some(p) => Some(p)
    None => occurrence.map(_ => @core.literal_number("1"))
  }
  g.func(
    if e.kind == RegexpExtract {
      "REGEXP_SUBSTR"
    } else {
      "REGEXP_SUBSTR_ALL"
    },
    [e.this(), e.expression(), position, occurrence, parameters, group],
  )
}

///|
fn json_extract_value_array_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let json_extract = @core.mk(JSONExtract, [
    ("this", e.this()),
    ("expression", e.expression()),
  ])
  let ident = @core.to_identifier("x")
  let this = if e.kind == JSONValueArray {
    @core.exp_cast(ident, VARCHAR)
  } else {
    @core.mk1(ParseJSON, "TO_JSON(\{g.sql(Some(ident))})")
  }
  let transform_lambda = @core.mk(Lambda, [
    ("expressions", [ident]),
    ("this", this),
  ])
  g.func("TRANSFORM", [json_extract, transform_lambda])
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(x => {
      x.0 == "windows" || x.0 == "qualify"
    },
  )
  let t = d.gen_fns.transforms
  let r = @core.rename_func
  t[ApproxDistinct] = r("APPROX_COUNT_DISTINCT")
  t[ArgMax] = r("MAX_BY")
  t[ArgMin] = r("MIN_BY")
  t[Array] = @core.preprocess([@core.inherit_struct_field_names])
  t[ArrayConcat] = @core.array_concat_sql("ARRAY_CAT")
  t[ArrayAppend] = @core.array_append_sql("ARRAY_APPEND")
  t[ArrayPrepend] = @core.array_append_sql("ARRAY_PREPEND")
  t[ArrayContains] = (g, e) => {
    let expression = if e.get("ensure_variant") is Some(Bool(false)) {
      e.expression()
    } else {
      e.expression().map(x => @core.exp_cast(x, VARIANT, copy=false))
    }
    g.func("ARRAY_CONTAINS", [expression, e.this()])
  }
  t[ArrayPosition] = (g, e) => {
    g.func("ARRAY_POSITION", [e.expression(), e.this()])
  }
  t[ArrayIntersect] = r("ARRAY_INTERSECTION")
  t[ArrayOverlaps] = r("ARRAYS_OVERLAP")
  t[AtTimeZone] = (g, e) => {
    g.func("CONVERT_TIMEZONE", [e.arg("zone"), e.this()])
  }
  t[BitwiseOr] = r("BITOR")
  t[BitwiseXor] = r("BITXOR")
  t[BitwiseAnd] = r("BITAND")
  t[BitwiseAndAgg] = r("BITANDAGG")
  t[BitwiseOrAgg] = r("BITORAGG")
  t[BitwiseXorAgg] = r("BITXORAGG")
  t[BitwiseNot] = r("BITNOT")
  t[BitwiseLeftShift] = r("BITSHIFTLEFT")
  t[BitwiseRightShift] = r("BITSHIFTRIGHT")
  t[CurrentTimestamp] = (g, e) => {
    if e.has("sysdate") {
      g.func("SYSDATE", [])
    } else {
      g.function_fallback_sql(e)
    }
  }
  t[CurrentSchemas] = (g, _) => g.func("CURRENT_SCHEMAS", [])
  t[Localtime] = (g, e) => {
    if e.has("this") {
      g.func("CURRENT_TIME", [e.this()])
    } else {
      "CURRENT_TIME"
    }
  }
  t[Localtimestamp] = (g, e) => {
    if e.has("this") {
      g.func("CURRENT_TIMESTAMP", [e.this()])
    } else {
      "CURRENT_TIMESTAMP"
    }
  }
  t[DateAdd] = @core.date_delta_sql("DATEADD")
  t[DateDiff] = @core.date_delta_sql("DATEDIFF")
  t[DatetimeAdd] = @core.date_delta_sql("TIMESTAMPADD")
  t[DatetimeDiff] = @core.timestampdiff_sql
  t[DateStrToDate] = @core.datestrtodate_sql
  t[Decrypt] = (g, e) => {
    g.func(try_prefix(e) + "DECRYPT", [
      e.this(),
      e.arg("passphrase"),
      e.arg("aad"),
      e.arg("encryption_method"),
    ])
  }
  t[DecryptRaw] = (g, e) => {
    g.func(try_prefix(e) + "DECRYPT_RAW", [
      e.this(),
      e.arg("key"),
      e.arg("iv"),
      e.arg("aad"),
      e.arg("encryption_method"),
      e.arg("aead"),
    ])
  }
  t[DayOfMonth] = r("DAYOFMONTH")
  t[DayOfWeek] = r("DAYOFWEEK")
  t[DayOfWeekIso] = r("DAYOFWEEKISO")
  t[DayOfYear] = r("DAYOFYEAR")
  t[DotProduct] = r("VECTOR_INNER_PRODUCT")
  t[Explode] = r("FLATTEN")
  t[Extract] = (g, e) => {
    g.func("DATE_PART", [
      @core.map_date_part(e.this(), dialect=g.dialect),
      e.expression(),
    ])
  }
  t[CosineDistance] = r("VECTOR_COSINE_SIMILARITY")
  t[EuclideanDistance] = r("VECTOR_L2_DISTANCE")
  t[HandlerProperty] = (g, e) => "HANDLER = \{g.sql_key(e, "this")}"
  t[FileFormatProperty] = (g, e) => {
    "FILE_FORMAT=(\{g.expressions(expression=e, key="expressions", sep=" ")})"
  }
  t[FromTimeZone] = (g, e) => {
    g.func("CONVERT_TIMEZONE", [e.arg("zone"), "'UTC'", e.this()])
  }
  t[GenerateSeries] = (g, e) => {
    let end = if e.has("is_end_exclusive") {
      e.arg("end")
    } else {
      e.arg("end").map(x => @core.exp_add(x, @core.literal_number("1")))
    }
    g.func("ARRAY_GENERATE_RANGE", [e.arg("start"), end, e.arg("step")])
  }
  t[GetExtract] = r("GET")
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e, sep="")
  t[If] = @core.if_sql_str(name="IFF", "NULL")
  t[JSONArray] = (g, e) => {
    g.func("TO_VARIANT", [
      g.func("ARRAY_CONSTRUCT", e.expressions().map(x => (x : &@core.SqlArg))),
    ])
  }
  t[JSONExtractArray] = json_extract_value_array_sql
  t[JSONExtractScalar] = (g, e) => {
    g.func("JSON_EXTRACT_PATH_TEXT", [e.this(), e.expression()])
  }
  t[JSONKeys] = r("OBJECT_KEYS")
  t[JSONObject] = (g, e) => {
    g.func(
      "OBJECT_CONSTRUCT_KEEP_NULL",
      e.expressions().map(x => (x : &@core.SqlArg)),
    )
  }
  t[JSONPathRoot] = (_, _) => ""
  t[JSONValueArray] = json_extract_value_array_sql
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost"])
    r("EDITDISTANCE")(g, e)
  }
  t[LocationProperty] = (g, e) => "LOCATION=\{g.sql_key(e, "this")}"
  t[LogicalAnd] = r("BOOLAND_AGG")
  t[LogicalOr] = r("BOOLOR_AGG")
  t[Map] = (g, e) => @core.var_map_sql(g, e, map_func_name="OBJECT_CONSTRUCT")
  t[ManhattanDistance] = r("VECTOR_L1_DISTANCE")
  t[MakeInterval] = (g, e) => @core.no_make_interval_sql(g, e)
  t[Max] = @core.max_or_greatest
  t[Min] = @core.min_or_least
  t[NthValue] = @core.nth_value_from_sql
  t[ParseJSON] = (g, e) => g.func(try_prefix(e) + "PARSE_JSON", [e.get("this")])
  t[ToBinary] = (g, e) => {
    g.func(try_prefix(e) + "TO_BINARY", [e.this(), e.arg("format")])
  }
  t[ToBoolean] = (g, e) => g.func(try_prefix(e) + "TO_BOOLEAN", [e.this()])
  t[ToDouble] = (g, e) => {
    g.func(try_prefix(e) + "TO_DOUBLE", [e.this(), e.arg("format")])
  }
  t[ToFile] = (g, e) => {
    g.func(try_prefix(e) + "TO_FILE", [e.this(), e.arg("path")])
  }
  t[JSONFormat] = r("TO_JSON")
  t[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  t[PercentileCont] = @core.preprocess([@core.add_within_group_for_percentiles])
  t[PercentileDisc] = @core.preprocess([@core.add_within_group_for_percentiles])
  t[Pivot] = @core.preprocess([unqualify_pivot_columns])
  t[RegexpExtract] = regexpextract_sql
  t[RegexpExtractAll] = regexpextract_sql
  t[RegexpILike] = regexpilike_sql
  t[RowAccessProperty] = (g, e) => g.call_method(RowAccessProperty, e)
  t[Select] = @core.preprocess([
    @core.eliminate_window_clause, @core.eliminate_distinct_on, explode_projection_to_unnest,
    @core.eliminate_semi_and_anti_joins, transform_generate_date_array, qualify_unnested_columns,
    eliminate_dot_variant_lookup,
  ])
  t[SHA] = r("SHA1")
  t[SHA1Digest] = r("SHA1_BINARY")
  t[MD5Digest] = r("MD5_BINARY")
  t[MD5NumberLower64] = r("MD5_NUMBER_LOWER64")
  t[MD5NumberUpper64] = r("MD5_NUMBER_UPPER64")
  t[Hex] = r("HEX_ENCODE")
  t[LowerHex] = r("TO_CHAR")
  t[Skewness] = r("SKEW")
  t[StarMap] = r("OBJECT_CONSTRUCT")
  t[StartsWith] = r("STARTSWITH")
  t[EndsWith] = r("ENDSWITH")
  t[Rand] = (g, e) => g.func("RANDOM", [e.this()])
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(g, e, func_name="CHARINDEX", supports_position=true)
  }
  t[StrToDate] = (g, e) => g.func("DATE", [e.this(), g.format_time(e)])
  t[StringToArray] = r("STRTOK_TO_ARRAY")
  t[StrtokToArray] = r("STRTOK_TO_ARRAY")
  t[Stuff] = r("INSERT")
  t[StPoint] = r("ST_MAKEPOINT")
  t[TimeAdd] = @core.date_delta_sql("TIMEADD")
  t[TimeSlice] = (g, e) => {
    g.func("TIME_SLICE", [
      e.this(),
      e.expression(),
      @core.unit_to_str(e),
      e.arg("kind"),
    ])
  }
  t[Timestamp] = @core.no_timestamp_sql
  t[TimestampAdd] = @core.date_delta_sql("TIMESTAMPADD")
  t[TimestampDiff] = (g, e) => {
    g.func("TIMESTAMPDIFF", [e.arg("unit"), e.expression(), e.this()])
  }
  t[TimestampTrunc] = @core.timestamptrunc_sql()
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeToUnix] = (g, e) => "EXTRACT(epoch_second FROM \{g.sql_key(e, "this")})"
  t[ToArray] = r("TO_ARRAY")
  t[ToChar] = (g, e) => g.function_fallback_sql(e)
  t[TsOrDsAdd] = @core.date_delta_sql("DATEADD", cast=true)
  t[TsOrDsDiff] = @core.date_delta_sql("DATEDIFF")
  t[TsOrDsToDate] = (g, e) => {
    g.func(try_prefix(e) + "TO_DATE", [e.this(), g.format_time(e)])
  }
  t[TsOrDsToTime] = (g, e) => {
    g.func(try_prefix(e) + "TO_TIME", [e.this(), g.format_time(e)])
  }
  t[Unhex] = r("HEX_DECODE_BINARY")
  t[UnixToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), e.arg("scale")])
  t[Uuid] = r("UUID_STRING")
  t[VarMap] = (g, e) => {
    @core.var_map_sql(g, e, map_func_name="OBJECT_CONSTRUCT")
  }
  t[Booland] = r("BOOLAND")
  t[Boolor] = r("BOOLOR")
  t[WeekOfYear] = r("WEEKISO")
  t[YearOfWeek] = r("YEAROFWEEK")
  t[YearOfWeekIso] = r("YEAROFWEEKISO")
  t[Xor] = r("BOOLXOR")
  t[ByteLength] = r("OCTET_LENGTH")
  t[Flatten] = r("ARRAY_FLATTEN")
  t[ArrayConcatAgg] = (g, e) => {
    g.func("ARRAY_FLATTEN", [@core.mk1(ArrayAgg, e.this())])
  }
  t[SHA2Digest] = (g, e) => {
    g.func("SHA2_BINARY", [
      e.this(),
      match e.arg("length") {
        Some(l) => Some(l)
        None => Some(@core.literal_number("256"))
      },
    ])
  }
  register_methods(d)
}
