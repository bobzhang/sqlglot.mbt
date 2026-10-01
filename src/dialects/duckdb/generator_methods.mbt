// Port of the `*_sql` method overrides of DuckDBGenerator (sqlglot/generators/duckdb.py).

///|
let zipf_template : Template = Template::new(
  (
    #|WITH rand AS (SELECT :random_expr AS r),
    #|weights AS (
    #|    SELECT i, 1.0 / POWER(i, :s) AS w
    #|    FROM RANGE(1, :n + 1) AS t(i)
    #|),
    #|cdf AS (
    #|    SELECT i, SUM(w) OVER (ORDER BY i) / SUM(w) OVER () AS p
    #|    FROM weights
    #|)
    #|SELECT MIN(i)
    #|FROM cdf
    #|WHERE p >= (SELECT r FROM rand)
  ),
)

///|
let normal_template : Template = Template::new(
  ":mean + (:stddev * SQRT(-2 * LN(GREATEST(:u1, 1e-10))) * COS(2 * PI() * :u2))",
)

///|
let seeded_random_template : Template = Template::new(
  "(ABS(HASH(:seed)) % 1000000) / 1000000.0",
)

///|
let mapcat_template : Template = Template::new(
  (
    #|CASE
    #|    WHEN :map1 IS NULL OR :map2 IS NULL THEN NULL
    #|    ELSE MAP_FROM_ENTRIES(LIST_FILTER(LIST_TRANSFORM(
    #|        LIST_DISTINCT(LIST_CONCAT(MAP_KEYS(:map1), MAP_KEYS(:map2))),
    #|        __k -> STRUCT_PACK(key := __k, value := COALESCE(:map2[__k], :map1[__k]))
    #|    ), __x -> __x.value IS NOT NULL))
    #|END
  ),
)

///|
let bitmap_construct_agg_template : Template = Template::new(
  (
    #|SELECT CASE
    #|    WHEN l IS NULL OR LENGTH(l) = 0 THEN NULL
    #|    WHEN LENGTH(l) != LENGTH(LIST_FILTER(l, __v -> __v BETWEEN 0 AND 32767)) THEN NULL
    #|    WHEN LENGTH(l) < 5 THEN UNHEX(PRINTF('%04X', LENGTH(l)) || h || REPEAT('00', GREATEST(0, 4 - LENGTH(l)) * 2))
    #|    ELSE UNHEX('08000000000000000000' || h)
    #|END
    #|FROM (
    #|    SELECT l, COALESCE(LIST_REDUCE(
    #|        LIST_TRANSFORM(l, __x -> PRINTF('%02X%02X', CAST(__x AS INT) & 255, (CAST(__x AS INT) >> 8) & 255)),
    #|        (__a, __b) -> __a || __b, ''
    #|    ), '') AS h
    #|    FROM (SELECT LIST_SORT(LIST_DISTINCT(LIST(:arg) FILTER(NOT :arg IS NULL))) AS l)
    #|)
  ),
)

///|
let randstr_template : Template = Template::new(
  (
    $|SELECT LISTAGG(
    $|    SUBSTRING(
    $|        '\{randstr_char_pool}',
    $|        1 + CAST(FLOOR(random_value * 62) AS INT),
    $|        1
    $|    ),
    $|    ''
    $|)
    $|FROM (
    $|    SELECT (ABS(HASH(i + :seed)) % 1000) / 1000.0 AS random_value
    $|    FROM RANGE(:length) AS t(i)
    $|)
  ),
)

///|
let minhash_template : Template = Template::new(
  (
    #|SELECT JSON_OBJECT('state', LIST(min_h ORDER BY seed), 'type', 'minhash', 'version', 1)
    #|FROM (
    #|    SELECT seed, LIST_MIN(LIST_TRANSFORM(vals, __v -> HASH(CAST(__v AS VARCHAR) || CAST(seed AS VARCHAR)))) AS min_h
    #|    FROM (SELECT LIST(:expr) AS vals), RANGE(0, :k) AS t(seed)
    #|)
  ),
)

///|
let minhash_combine_template : Template = Template::new(
  (
    #|SELECT JSON_OBJECT('state', LIST(min_h ORDER BY idx), 'type', 'minhash', 'version', 1)
    #|FROM (
    #|    SELECT
    #|        pos AS idx,
    #|        MIN(val) AS min_h
    #|    FROM
    #|        UNNEST(LIST(:expr)) AS _(sig),
    #|        UNNEST(CAST(sig -> 'state' AS UBIGINT[])) WITH ORDINALITY AS t(val, pos)
    #|    GROUP BY pos
    #|)
  ),
)

///|
let approximate_similarity_template : Template = Template::new(
  (
    #|SELECT CAST(SUM(CASE WHEN num_distinct = 1 THEN 1 ELSE 0 END) AS DOUBLE) / COUNT(*)
    #|FROM (
    #|    SELECT pos, COUNT(DISTINCT h) AS num_distinct
    #|    FROM (
    #|        SELECT h, pos
    #|        FROM UNNEST(LIST(:expr)) AS _(sig),
    #|             UNNEST(CAST(sig -> 'state' AS UBIGINT[])) WITH ORDINALITY AS s(h, pos)
    #|    )
    #|    GROUP BY pos
    #|)
  ),
)

///|
let arrays_zip_template : Template = Template::new(
  (
    #|CASE WHEN :null_check THEN NULL
    #|WHEN :all_empty_check THEN [:empty_struct]
    #|ELSE LIST_TRANSFORM(RANGE(0, :max_len), __i -> :transform_struct)
    #|END
  ),
)

///|
let uuid_v5_template : Template = Template::new(
  (
    #|(SELECT
    #|    LOWER(
    #|        SUBSTR(h, 1, 8) || '-' ||
    #|        SUBSTR(h, 9, 4) || '-' ||
    #|        '5' || SUBSTR(h, 14, 3) || '-' ||
    #|        FORMAT('{:02x}', CAST('0x' || SUBSTR(h, 17, 2) AS INT) & 63 | 128) || SUBSTR(h, 19, 2) || '-' ||
    #|        SUBSTR(h, 21, 12)
    #|    )
    #|FROM (
    #|    SELECT SUBSTR(SHA1(UNHEX(REPLACE(:namespace, '-', '')) || ENCODE(:name, 'utf8')), 1, 32) AS h
    #|))
  ),
)

///|
let array_bag_template : Template = Template::new(
  (
    #|CASE
    #|    WHEN :arr1 IS NULL OR :arr2 IS NULL THEN NULL
    #|    ELSE LIST_TRANSFORM(
    #|        LIST_FILTER(
    #|            LIST_ZIP(:arr1, GENERATE_SERIES(1, LEN(:arr1))),
    #|            pair -> :cond
    #|        ),
    #|        pair -> pair[0]
    #|    )
    #|END
  ),
)

///|
let array_except_condition : Template = Template::new(
  "LEN(LIST_FILTER(:arr1[1:pair[1]], e -> e IS NOT DISTINCT FROM pair[0])) > LEN(LIST_FILTER(:arr2, e -> e IS NOT DISTINCT FROM pair[0]))",
)

///|
let array_intersection_condition : Template = Template::new(
  "LEN(LIST_FILTER(:arr1[1:pair[1]], e -> e IS NOT DISTINCT FROM pair[0])) <= LEN(LIST_FILTER(:arr2, e -> e IS NOT DISTINCT FROM pair[0]))",
)

///|
let array_except_set_template : Template = Template::new(
  (
    #|CASE
    #|    WHEN :arr1 IS NULL OR :arr2 IS NULL THEN NULL
    #|    ELSE LIST_FILTER(
    #|        LIST_DISTINCT(:arr1),
    #|        e -> LEN(LIST_FILTER(:arr2, x -> x IS NOT DISTINCT FROM e)) = 0
    #|    )
    #|END
  ),
)

///|
let in_unnest_template : Template = Template::new(
  (
    #|CASE
    #|    WHEN :arr IS NULL OR ARRAY_LENGTH(:arr) = 0 THEN FALSE
    #|    WHEN ARRAY_CONTAINS(:arr, :value) THEN TRUE
    #|    WHEN :value IS NULL OR ARRAY_LENGTH(:arr) <> LIST_COUNT(:arr) THEN NULL
    #|    ELSE FALSE
    #|END
  ),
)

///|
let strtok_to_array_template : Template = Template::new(
  (
    #|CASE WHEN :delimiter IS NULL THEN NULL
    #|ELSE LIST_FILTER(
    #|    REGEXP_SPLIT_TO_ARRAY(:string, CASE WHEN :delimiter = '' THEN '.^' ELSE CONCAT('[', :escaped, ']') END),
    #|    x -> NOT x = ''
    #|) END
  ),
)

///|
let strtok_template : Template = Template::new(
  (
    #|CASE
    #|    WHEN :delimiter = '' AND :string = '' THEN NULL
    #|    WHEN :delimiter = '' AND :part_index = 1 THEN :string
    #|    WHEN :delimiter = '' THEN NULL
    #|    WHEN :part_index < 0 THEN NULL
    #|    WHEN :string IS NULL OR :delimiter IS NULL OR :part_index IS NULL THEN NULL
    #|    ELSE :base_func
    #|END
  ),
)

///|
let extract_strftime_mappings : Map[String, (String, String)] = {
  "WEEKISO": ("%V", "INTEGER"),
  "YEAROFWEEK": ("%G", "INTEGER"),
  "YEAROFWEEKISO": ("%G", "INTEGER"),
  "NANOSECOND": ("%n", "BIGINT"),
}

///|
let extract_epoch_mappings : Map[String, String] = {
  "EPOCH_SECOND": "EPOCH",
  "EPOCH_MILLISECOND": "EPOCH_MS",
  "EPOCH_MICROSECOND": "EPOCH_US",
  "EPOCH_NANOSECOND": "EPOCH_NS",
}

///|
fn unsupported_fallback(message : String) -> @core.GenFn {
  (g, e) => {
    g.unsupported(message)
    g.function_fallback_sql(e)
  }
}

///|
fn configure_methods(d : @core.Dialect) -> Unit {
  let m = d.gen_fns.methods
  m[DataType] = datatype_sql
  m[TimeSlice] = timeslice_sql
  m[BitmapBucketNumber] = bitmapbucketnumber_sql
  m[BitmapBitPosition] = bitmapbitposition_sql
  m[BitmapConstructAgg] = (g, e) => {
    "(\{g.sql(Some(tmpl(bitmap_construct_agg_template.get(), [("arg", this_of(e))])))})"
  }
  m[GetIgnoreCase] = unsupported_fallback(
    "DuckDB does not support the GET_IGNORE_CASE() function",
  )
  m[Compress] = unsupported_fallback(
    "DuckDB does not support the COMPRESS() function",
  )
  m[Encrypt] = unsupported_fallback("ENCRYPT is not supported in DuckDB")
  m[Decrypt] = (g, e) => {
    let func_name = if e.has("safe") { "TRY_DECRYPT" } else { "DECRYPT" }
    g.unsupported("\{func_name} is not supported in DuckDB")
    g.function_fallback_sql(e)
  }
  m[DecryptRaw] = (g, e) => {
    let func_name = if e.has("safe") {
      "TRY_DECRYPT_RAW"
    } else {
      "DECRYPT_RAW"
    }
    g.unsupported("\{func_name} is not supported in DuckDB")
    g.function_fallback_sql(e)
  }
  m[EncryptRaw] = unsupported_fallback("ENCRYPT_RAW is not supported in DuckDB")
  m[ParseUrl] = unsupported_fallback("PARSE_URL is not supported in DuckDB")
  m[ParseIp] = unsupported_fallback("PARSE_IP is not supported in DuckDB")
  m[DecompressString] = unsupported_fallback(
    "DECOMPRESS_STRING is not supported in DuckDB",
  )
  m[DecompressBinary] = unsupported_fallback(
    "DECOMPRESS_BINARY is not supported in DuckDB",
  )
  m[JarowinklerSimilarity] = jarowinklersimilarity_sql
  m[Randstr] = randstr_sql
  m[Reduce] = reduce_sql
  m[Zipf] = zipf_sql
  m[ToBinary] = tobinary_sql
  m[ToNumber] = tonumber_sql
  m[Generator] = generator_sql
  m[Greatest] = greatest_least_sql
  m[Least] = greatest_least_sql
  m[Show] = show_sql
  m[Soundex] = (g, e) => {
    g.unsupported("SOUNDEX is not supported in DuckDB")
    g.func("SOUNDEX", [e.this()])
  }
  m[SortArray] = sortarray_sql
  m[Install] = install_sql
  m[ApproxTopK] = unsupported_fallback(
    "APPROX_TOP_K cannot be transpiled to DuckDB due to incompatible return types. ",
  )
  m[StrPosition] = strposition_sql
  m[Substring] = substring_sql
  m[StrToTime] = strtotime_sql
  m[StrToDate] = strtodate_sql
  m[ParseDatetime] = (g, e) => {
    let (value, formatted_time) = strptime_default_year(g, e)
    g.func("STRPTIME", [value, formatted_time])
  }
  m[ParseTime] = (g, e) => {
    let formatted_time = g.format_time(e)
    g.sql(
      Some(
        cast_to(
          parse(g.func("STRPTIME", [e.this(), formatted_time])),
          @core.datatype_of(TIME),
        ),
      ),
    )
  }
  m[TsOrDsToTime] = tsordstotime_sql
  m[CurrentDate] = currentdate_sql
  m[CheckJson] = checkjson_sql
  m[ParseJSON] = parsejson_sql
  m[Unicode] = unicode_sql
  m[StripNullValue] = (g, e) => {
    g.sql(
      Some(
        else_(
          when(
            case_(),
            eq(func("json_type", [this_of(e)]), str_lit("NULL")),
            @core.null_(),
          ),
          this_of(e),
        ),
      ),
    )
  }
  m[Trunc] = trunc_sql
  m[Normal] = normal_sql
  m[Uniform] = uniform_sql
  m[TimeFromParts] = timefromparts_sql
  m[Extract] = extract_sql
  m[TimestampFromParts] = timestampfromparts_sql
  m[TimestampLtzFromParts] = timestampltzfromparts_sql
  m[TimestampTzFromParts] = timestamptzfromparts_sql
  m[In] = in_sql
  m[Join] = join_sql
  m[CountIf] = countif_sql
  m[Bracket] = bracket_sql
  m[WithinGroup] = withingroup_sql
  m[Length] = length_sql
  m[BitLength] = bitlength_sql
  m[Collation] = unsupported_fallback(
    "COLLATION function is not supported by DuckDB",
  )
  m[Collate] = collate_sql
  m[RegexpCount] = regexpcount_sql
  m[RegexpReplace] = regexpreplace_sql
  m[RegexpLike] = regexplike_sql
  m[Levenshtein] = levenshtein_sql
  m[Pad] = pad_sql
  m[Minhash] = minhash_sql
  m[MinhashCombine] = (g, e) => {
    "(\{g.sql(Some(tmpl(minhash_combine_template.get(), [("expr", this_of(e))])))})"
  }
  m[ApproximateSimilarity] = (g, e) => {
    "(\{g.sql(Some(tmpl(approximate_similarity_template.get(), [("expr", this_of(e))])))})"
  }
  m[ArrayUniqueAgg] = (g, e) => {
    g.sql(
      Some(
        @core.mk(Filter, [
          (
            "this",
            func("LIST", [@core.mk(Distinct, [("expressions", [this_of(e)])])]),
          ),
          ("expression", @core.mk1(Where, not_(is_null(this_of(e).copy())))),
        ]),
      ),
    )
  }
  m[ArrayConcatAgg] = arrayconcatagg_sql
  m[ArrayUnionAgg] = unsupported_fallback(
    "ARRAY_UNION_AGG is not supported in DuckDB",
  )
  m[ArrayDistinct] = arraydistinct_sql
  m[ArrayIntersect] = (g, e) => {
    let exprs = e.expressions()
    if e.has("is_multiset") && exprs.length() == 2 {
      return array_bag_sql(
        g,
        array_intersection_condition.get(),
        exprs[0],
        exprs[1],
      )
    }
    g.function_fallback_sql(e)
  }
  m[ArrayExcept] = (g, e) => {
    let arr1 = this_of(e)
    let arr2 = expr_of(e)
    if e.has("is_multiset") {
      return array_bag_sql(g, array_except_condition.get(), arr1, arr2)
    }
    g.sql(
      Some(
        tmpl(array_except_set_template.get(), [("arr1", arr1), ("arr2", arr2)]),
      ),
    )
  }
  m[ArraySlice] = arrayslice_sql
  m[ArraysZip] = arrayszip_sql
  m[Lower] = (g, e) => {
    gen_with_cast_to_blob(g, e, g.func("LOWER", [cast_to_varchar(e.this())]))
  }
  m[Upper] = (g, e) => {
    gen_with_cast_to_blob(g, e, g.func("UPPER", [cast_to_varchar(e.this())]))
  }
  m[Reverse] = (g, e) => {
    gen_with_cast_to_blob(g, e, g.func("REVERSE", [cast_to_varchar(e.this())]))
  }
  m[Left] = (g, e) => left_right_sql(g, e, "LEFT")
  m[Right] = (g, e) => left_right_sql(g, e, "RIGHT")
  m[RtrimmedLength] = (g, e) => {
    g.func("LENGTH", [
      @core.mk(Trim, [("this", e.this()), ("position", "TRAILING")]),
    ])
  }
  m[Stuff] = stuff_sql
  m[Rand] = rand_sql
  m[ByteLength] = (g, e) => {
    let arg = this_of(e)
    if is_text(arg) {
      return g.func("OCTET_LENGTH", [@core.mk1(Encode, arg)])
    }
    g.func("OCTET_LENGTH", [arg])
  }
  m[Base64Encode] = base64encode_sql
  m[Hex] = hex_sql
  m[Replace] = (g, e) => {
    let result_sql = g.func("REPLACE", [
      cast_to_varchar(e.this()),
      cast_to_varchar(e.expression()),
      cast_to_varchar(e.arg("replacement")),
    ])
    gen_with_cast_to_blob(g, e, result_sql)
  }
  m[BitwiseXor] = (g, e) => {
    prepare_binary_bitwise_args(e)
    let result_sql = g.func("XOR", [e.this(), e.expression()])
    gen_with_cast_to_blob(g, e, result_sql)
  }
  m[ObjectInsert] = objectinsert_sql
  m[MapCat] = (g, e) => {
    g.sql(
      Some(
        tmpl(mapcat_template.get(), [("map1", this_of(e)), ("map2", expr_of(e))]),
      ),
    )
  }
  m[MapContainsKey] = (g, e) => {
    g.func("ARRAY_CONTAINS", [func("MAP_KEYS", [req(e, "key")]), this_of(e)])
  }
  m[MapDelete] = mapdelete_sql
  m[MapPick] = mappick_sql
  m[MapSize] = (g, e) => g.func("CARDINALITY", [e.this()])
  m[MapInsert] = mapinsert_sql
  m[StartsWith] = (g, e) => {
    g.func("STARTS_WITH", [
      cast_to_varchar(e.this()),
      cast_to_varchar(e.expression()),
    ])
  }
  m[Space] = (g, e) => {
    // DuckDB's REPEAT requires BIGINT for the count parameter
    g.sql(
      Some(
        @core.mk(Repeat, [
          ("this", str_lit(" ")),
          ("times", cast(this_of(e), BIGINT)),
        ]),
      ),
    )
  }
  m[TableFromRows] = tablefromrows_sql
  m[Unnest] = unnest_sql
  m[ArrayAgg] = (g, e) => {
    match e.this() {
      Some(t) if t.kind == Limit =>
        g.unsupported("LIMIT inside ARRAY_AGG is not supported in DuckDB")
      _ => ()
    }
    g.arrayagg_sql(e)
  }
  m[IgnoreNulls] = ignorenulls_sql
  m[Split] = split_sql
  m[SplitPart] = splitpart_sql
  m[RespectNulls] = (g, e) => {
    match e.this() {
      Some(t) if t.kind.is_any(ignore_respect_nulls_window_functions) =>
        g.respectnulls_sql(e)
      _ => {
        g.unsupported(
          "RESPECT NULLS is not supported for non-window functions.",
        )
        g.sql_key(e, "this")
      }
    }
  }
  m[ArrayToString] = arraytostring_sql
  m[ConcatWs] = concatws_sql
  m[RegexpExtract] = regexp_extract_sql
  m[RegexpExtractAll] = regexp_extract_sql
  m[RegexpInstr] = regexpinstr_sql
  m[NumberToStr] = (g, e) => {
    g.unsupported_args(e, ["culture"])
    match e.arg("format") {
      Some(fmt) if fmt.is_int() =>
        g.func("FORMAT", ["'{:,.\{fmt.name()}f}'", g.sql(e.this())])
      _ => {
        g.unsupported("Only integer formats are supported by NumberToStr")
        g.function_fallback_sql(e)
      }
    }
  }
  m[AutoIncrementColumnConstraint] = (g, _) => {
    g.unsupported(
      "The AUTOINCREMENT column constraint is not supported by DuckDB",
    )
    ""
  }
  m[Aliases] = (g, e) => {
    match e.this() {
      Some(t) if t.kind.is_a(Posexplode) => g.call_method(Posexplode, t)
      _ => g.aliases_sql(e)
    }
  }
  m[Posexplode] = posexplode_sql
  m[AddMonths] = addmonths_sql
  m[Format] = (g, e) => {
    let exprs = e.expressions()
    if @core.py_lower(e.name()) == "%s" && exprs.length() == 1 {
      return g.func("FORMAT", ["'{}'", g.sql(Some(exprs[0]))])
    }
    g.function_fallback_sql(e)
  }
  m[DateTrunc] = datetrunc_sql
  m[DatetimeTrunc] = datetimetrunc_sql
  m[TimestampTrunc] = timestamptrunc_sql
  m[Trim] = trim_sql
  m[Round] = round_sql
  m[TryCast] = trycast_sql
  m[Strtok] = strtok_sql
  m[StrtokToArray] = strtoktoarray_sql
  m[ApproxQuantile] = (g, e) => {
    let mut result = g.func("APPROX_QUANTILE", [e.this(), e.arg("quantile")])
    // DuckDB returns integers for APPROX_QUANTILE, cast to DOUBLE if the expected type is a real type
    if is_real(e) {
      result = "CAST(\{result} AS DOUBLE)"
    }
    result
  }
  m[ApproxQuantiles] = approxquantiles_sql
  m[JSONExtractScalar] = jsonextractscalar_sql
  m[BitwiseNot] = bitwisenot_sql
  m[Window] = (g, e) => {
    match e.this() {
      Some(t) if t.kind == Corr ||
        (
          t.kind == Filter &&
          (match t.this() {
            Some(tt) => tt.kind == Corr
            None => false
          })
        ) => corr_sql(g, e)
      _ => g.window_sql(e)
    }
  }
  m[Filter] = (g, e) => {
    match e.this() {
      Some(t) if t.kind == Corr => corr_sql(g, e)
      _ => g.filter_sql(e)
    }
  }
  m[Uuid] = (g, e) => {
    match (e.this(), e.arg("name")) {
      (Some(ns), Some(name)) =>
        g.sql(
          Some(
            tmpl(uuid_v5_template.get(), [("namespace", ns), ("name", name)]),
          ),
        )
      _ => g.uuid_sql(e)
    }
  }
  // Methods with extra parameters (typed hooks)
  let hooks = d.gen_fns.hooks
  hooks.lambda_sql = Some(lambda_sql)
  hooks.tablesample_sql = Some(tablesample_sql)
  hooks.chr_sql = Some((g, e, _name) => {
    let mut arg = e.expressions()[0]
    if is_real(arg) {
      arg = cast(arg, INT)
    }
    g.func("CHR", [arg])
  })
  hooks.hexstring_sql = Some((g, e, _binary_function_repr) => {
    // UNHEX('FF') correctly produces blob \xFF in DuckDB
    g.hexstring_sql(e, binary_function_repr="UNHEX")
  })
}

///|
fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.is_type([ARRAY]) {
    return "\{g.expressions(expression=e, flat=true)}[\{g.expressions(expression=e, key="values", flat=true)}]"
  }
  // Modifiers are not supported for TIME, [TIME | TIMESTAMP] WITH TIME ZONE
  if e.is_type([TIME, TIMETZ, TIMESTAMPTZ, TIMESTAMPLTZ]) {
    e.set("expressions", (None : @core.Expr?))
  }
  g.datatype_sql(e)
}

///|
fn array_bag_sql(
  g : @core.Generator,
  condition : @core.Expr,
  arr1 : @core.Expr,
  arr2 : @core.Expr,
) -> String raise @core.SqlglotError {
  let cond = @core.mk1(Paren, tmpl(condition, [("arr1", arr1), ("arr2", arr2)]))
  g.sql(
    Some(
      tmpl(array_bag_template.get(), [
        ("arr1", arr1),
        ("arr2", arr2),
        ("cond", cond),
      ]),
    ),
  )
}

///|
/// Transform Snowflake's TIME_SLICE to DuckDB's time_bucket.
fn timeslice_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let date_expr = this_of(e)
  let slice_length = e.expression()
  let unit = e.arg("unit")
  let kind = @core.py_upper(e.text("kind"))
  let interval_expr = @core.mk(Interval, [
    ("this", slice_length),
    ("unit", unit),
  ])
  let time_bucket_expr = func("time_bucket", [interval_expr, date_expr])
  if kind != "END" {
    return g.sql(Some(time_bucket_expr))
  }
  let add_expr = @core.mk(Add, [
    ("this", time_bucket_expr),
    ("expression", interval_expr.copy()),
  ])
  if date_expr.is_type([DATE]) {
    return g.sql(Some(cast(add_expr, DATE)))
  }
  g.sql(Some(add_expr))
}

///|
fn bitmapbucketnumber_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let value = this_of(e)
  let positive_formula = add(intdiv(sub(value, num(1)), num(32768)), num(1))
  let non_positive_formula = intdiv(value, num(32768))
  let case_expr = else_(
    when(
      case_(),
      @core.mk(GT, [("this", value), ("expression", num(0))]),
      positive_formula,
    ),
    non_positive_formula,
  )
  g.sql(Some(case_expr))
}

///|
fn bitmapbitposition_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  g.sql(
    Some(
      @core.mk(Mod, [
        (
          "this",
          @core.mk1(
            Paren,
            if_(
              @core.mk(GT, [("this", this), ("expression", num(0))]),
              sub(this, num(1)),
              @core.mk1(Abs, this),
            ),
          ),
        ),
        ("expression", num(32768)),
      ]),
    ),
  )
}

///|
fn jarowinklersimilarity_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  let mut expr = expr_of(e)
  if e.has("case_insensitive") {
    this = @core.mk1(Upper, this)
    expr = @core.mk1(Upper, expr)
  }
  let mut result = func("JARO_WINKLER_SIMILARITY", [this, expr])
  if e.has("integer_scale") {
    result = cast_to(mul(result, num(100)), base_type("INTEGER"))
  }
  g.sql(Some(result))
}

///|
fn randstr_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let length = this_of(e)
  let seed_value = match e.arg("generator") {
    Some(generator) =>
      if generator.kind == Rand {
        // If it's RANDOM(), use its seed if available, otherwise use RANDOM() itself
        match generator.this() {
          Some(s) => s
          None => generator
        }
      } else {
        generator
      }
    None => num(randstr_seed)
  }
  "(\{g.sql(Some(tmpl(randstr_template.get(), [("seed", seed_value), ("length", length)])))})"
}

///|
fn reduce_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["finish"])
  let array_arg = e.this()
  let initial_value = e.arg("initial")
  let merge_lambda = e.arg("merge")
  match merge_lambda {
    Some(l) => l.set("colon", true)
    None => ()
  }
  g.func("list_reduce", [array_arg, merge_lambda, initial_value])
}

///|
fn hash_random_expr(seed : @core.Expr) -> @core.Expr {
  @core.mk(Div, [
    (
      "this",
      @core.mk1(
        Paren,
        @core.mk(Mod, [
          (
            "this",
            @core.mk1(
              Abs,
              @core.mk(Anonymous, [("this", "HASH"), ("expressions", [seed])]),
            ),
          ),
          ("expression", num(1000000)),
        ]),
      ),
    ),
    ("expression", numstr("1000000.0")),
  ])
}

///|
fn zipf_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let s = this_of(e)
  let n = req(e, "elementcount")
  let gen = req(e, "gen")
  let random_expr = if gen.kind != Rand {
    hash_random_expr(gen.copy())
  } else {
    @core.mk0(Rand)
  }
  "(\{g.sql(Some(tmpl(zipf_template.get(), [("s", s), ("n", n), ("random_expr", random_expr)])))})"
}

///|
fn tobinary_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let value = this_of(e)
  let format_arg = e.arg("format")
  let is_safe = e.has("safe")
  let is_bin = is_binary(Some(e))
  if format_arg is None && !is_bin {
    let func_name = if is_safe { "TRY_TO_BINARY" } else { "TO_BINARY" }
    return g.func(func_name, [value])
  }
  // Snowflake defaults to HEX encoding when no format is specified
  let fmt = match format_arg {
    Some(f) => @core.py_upper(f.name())
    None => "HEX"
  }
  let result = if fmt == "UTF-8" || fmt == "UTF8" {
    g.func("ENCODE", [value])
  } else if fmt == "BASE64" {
    g.func("FROM_BASE64", [value])
  } else if fmt == "HEX" {
    g.func("UNHEX", [value])
  } else if is_safe {
    return g.sql(Some(@core.null_()))
  } else {
    g.unsupported("format \{fmt} is not supported")
    g.func("TO_BINARY", [value])
  }
  if is_safe {
    "TRY(\{result})"
  } else {
    result
  }
}

///|
fn tonumber_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match (e.arg("format"), e.arg("precision"), e.arg("scale")) {
    (None, Some(precision), Some(scale)) => {
      let to = duck_type("DECIMAL(\{precision.name()}, \{scale.name()})")
      if e.has("safe") {
        return g.sql(Some(@core.mk(TryCast, [("this", e.this()), ("to", to)])))
      }
      g.sql(Some(@core.exp_cast_to(this_of(e), to, dialect=dialect())))
    }
    _ => g.tonumber_sql(e)
  }
}

///|
/// Handle GREATEST/LEAST functions with dialect-aware NULL behavior.
fn greatest_least_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let all_args = [this_of(e), ..e.expressions()]
  let fallback_sql = g.function_fallback_sql(e)
  if e.has("ignore_nulls") {
    return fallback_sql
  }
  // return NULL if any argument is NULL
  let case_expr = @core.case_when(
    case_(),
    @core.exp_or(all_args.map(arg => is_null(arg)), copy=false),
    @core.null_(),
    copy=false,
  )
  case_expr.set("default", fallback_sql)
  g.sql(Some(case_expr))
}

///|
fn generator_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let rowcount = e.arg("rowcount")
  if e.has("time_limit") {
    g.unsupported("GENERATOR TIMELIMIT parameter is not supported in DuckDB")
  }
  match rowcount {
    None => {
      g.unsupported("GENERATOR without ROWCOUNT is not supported in DuckDB")
      g.func("range", [num(0)])
    }
    Some(r) => g.func("range", [r])
  }
}

///|
fn lambda_sql(
  g : @core.Generator,
  e : @core.Expr,
  arrow_sep : String,
  wrap : Bool,
) -> String raise @core.SqlglotError {
  let (prefix, arrow_sep, wrap) = if e.has("colon") {
    ("LAMBDA ", ":", false)
  } else {
    ("", arrow_sep, wrap)
  }
  let lambda_sql = g.lambda_sql(e, arrow_sep~, wrap~)
  "\{prefix}\{lambda_sql}"
}

///|
fn show_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let from_ = g.sql_key(e, "from_")
  let from_ = if from_ != "" { " FROM \{from_}" } else { "" }
  "SHOW \{e.name()}\{from_}"
}

///|
fn sortarray_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arr = e.this()
  let asc = e.arg("asc")
  let nulls_first = e.arg("nulls_first")
  let is_bool = (x : @core.Expr?) => {
    match x {
      Some(b) => b.kind == Boolean
      None => false
    }
  }
  if !is_bool(asc) && !is_bool(nulls_first) {
    return g.func("LIST_SORT", [arr, asc, nulls_first])
  }
  let nulls_are_first = match nulls_first {
    Some(n) => n == @core.true_()
    None => false
  }
  let nulls_first_sql = if nulls_are_first {
    Some(str_lit("NULLS FIRST"))
  } else {
    None
  }
  if !is_bool(asc) {
    return g.func("LIST_SORT", [arr, asc, nulls_first_sql])
  }
  let descending = match asc {
    Some(a) => a == @core.false_()
    None => false
  }
  if !descending && !nulls_are_first {
    return g.func("LIST_SORT", [arr])
  }
  if !nulls_are_first {
    return g.func("ARRAY_REVERSE_SORT", [arr])
  }
  g.func("LIST_SORT", [
    arr,
    Some(str_lit(if descending { "DESC" } else { "ASC" })),
    Some(str_lit("NULLS FIRST")),
  ])
}

///|
fn install_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let force = if e.has("force") { "FORCE " } else { "" }
  let this = g.sql_key(e, "this")
  let from_clause = match e.arg("from_") {
    Some(f) => " FROM \{@core.expr_to_sql(f)}"
    None => ""
  }
  "\{force}INSTALL \{this}\{from_clause}"
}

///|
fn strposition_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let substr = e.arg("substr")
  let position = e.arg("position")
  // For BINARY/BLOB: DuckDB's STRPOS doesn't support BLOB types
  if is_binary(Some(this)) {
    let hex_strpos = @core.mk(StrPosition, [
      ("this", @core.mk1(Hex, this)),
      ("substr", @core.mk1(Hex, substr)),
    ])
    return g.sql(Some(cast(div(add(hex_strpos, num(1)), num(2)), INT)))
  }
  let mut e = e
  match position {
    Some(position) if e.has("clamp_position") => {
      e = e.copy()
      e.set(
        "position",
        if_(
          @core.mk(LTE, [("this", position), ("expression", num(0))]),
          num(1),
          position.copy(),
        ),
      )
    }
    _ => ()
  }
  @core.strposition_sql(g, e)
}

///|
fn substring_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("zero_start") {
    let start = match e.arg("start") {
      Some(start) => Some(if_(eq(start, num(0)), num(1), start))
      None => None
    }
    let length = match e.arg("length") {
      Some(length) => Some(if_(lt(length, num(0)), num(0), length))
      None => None
    }
    return g.func("SUBSTRING", [e.this(), start, length])
  }
  g.function_fallback_sql(e)
}

///|
fn strptime_default_year(
  g : @core.Generator,
  e : @core.Expr,
) -> (&@core.SqlArg, &@core.SqlArg) raise @core.SqlglotError {
  let formatted_time = g.format_time(e)
  match e.arg("default_year") {
    Some(default_year) => {
      let value = @core.mk(DPipe, [
        ("this", str_lit("\{default_year.name()} ")),
        ("expression", e.this()),
      ])
      let formatted = @core.mk(DPipe, [
        ("this", str_lit("%Y ")),
        ("expression", formatted_time),
      ])
      (value, formatted)
    }
    None => (e.this(), formatted_time)
  }
}

///|
fn strtotime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let needs_tz = match e.arg("target_type") {
    Some(t) => t.kind == DataType && t.is_type([TIMESTAMPLTZ, TIMESTAMPTZ])
    None => false
  }
  let (value, formatted_time) = strptime_default_year(g, e)
  if e.has("safe") {
    let cast_type : @core.DType = if needs_tz { TIMESTAMPTZ } else { TIMESTAMP }
    return g.sql(
      Some(
        cast(parse(g.func("TRY_STRPTIME", [value, formatted_time])), cast_type),
      ),
    )
  }
  let base_sql = g.func("STRPTIME", [value, formatted_time])
  if needs_tz {
    return g.sql(Some(cast_to(parse(base_sql), @core.datatype_of(TIMESTAMPTZ))))
  }
  base_sql
}

///|
fn strtodate_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let (value, formatted_time) = strptime_default_year(g, e)
  let function_name = if !e.has("safe") { "STRPTIME" } else { "TRY_STRPTIME" }
  g.sql(
    Some(
      cast_to(
        parse(g.func(function_name, [value, formatted_time])),
        @core.datatype_of(DATE),
      ),
    ),
  )
}

///|
fn tsordstotime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let time_format = g.format_time(e)
  let safe = e.has("safe")
  let time_type = duck_type("TIME")
  let cast_kind : @core.Kind = if safe { TryCast } else { Cast }
  match time_format {
    Some(tf) => {
      let func_name = if safe { "TRY_STRPTIME" } else { "STRPTIME" }
      let strptime = @core.mk(Anonymous, [
        ("this", func_name),
        // The formatted time is already SQL (a quoted string), like Python's raw str arg
        ("expressions", [this, @core.var_(tf)]),
      ])
      return g.sql(
        Some(@core.mk(cast_kind, [("this", strptime), ("to", time_type)])),
      )
    }
    None => ()
  }
  if this.kind == TsOrDsToTime || this.is_type([TIME]) {
    return g.sql(Some(this))
  }
  g.sql(Some(@core.mk(cast_kind, [("this", this), ("to", time_type)])))
}

///|
fn currentdate_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  guard e.this() is Some(zone) else { return "CURRENT_DATE" }
  let expr = @core.mk(Cast, [
    (
      "this",
      @core.mk(AtTimeZone, [
        ("this", @core.mk0(CurrentTimestamp)),
        ("zone", zone),
      ]),
    ),
    ("to", @core.datatype_of(DATE)),
  ])
  g.sql(Some(expr))
}

///|
fn checkjson_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = this_of(e)
  g.sql(
    Some(
      else_(
        when(
          case_(),
          @core.exp_or([
            is_(arg, @core.mk0(Null)),
            eq(arg, str_lit("")),
            func("json_valid", [arg]),
          ]),
          @core.null_(),
        ),
        str_lit("Invalid JSON"),
      ),
    ),
  )
}

///|
fn parsejson_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = this_of(e)
  if e.has("safe") {
    return g.sql(
      Some(
        else_(
          when(
            case_(),
            func("json_valid", [arg]),
            cast_to(arg.copy(), base_type("JSON")),
          ),
          @core.null_(),
        ),
      ),
    )
  }
  g.func("JSON", [arg])
}

///|
fn unicode_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("empty_is_zero") {
    return g.sql(
      Some(
        else_(
          when(case_(), eq(this_of(e), str_lit("")), num(0)),
          @core.mk(Anonymous, [
            ("this", "UNICODE"),
            ("expressions", [this_of(e)]),
          ]),
        ),
      ),
    )
  }
  g.func("UNICODE", [e.this()])
}

///|
fn trunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut decimals = e.arg("decimals")
  match decimals {
    Some(dec) if e.has("fractions_supported") && !dec.is_type([INT]) =>
      decimals = Some(@core.exp_cast(dec, INT, dialect=dialect()))
    _ => ()
  }
  g.func("TRUNC", [e.this(), decimals])
}

///|
/// Transpile Snowflake's NORMAL(mean, stddev, gen) to DuckDB.
fn normal_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mean = this_of(e)
  let stddev = req(e, "stddev")
  let gen = req(e, "gen")
  let (u1, u2) = if gen.kind == Rand && gen.this() is None {
    (@core.mk0(Rand), @core.mk0(Rand))
  } else {
    let seed = if gen.kind == Rand { this_of(gen) } else { gen }
    (
      tmpl(seeded_random_template.get(), [("seed", seed)]),
      tmpl(seeded_random_template.get(), [
        ("seed", @core.mk(Add, [("this", seed.copy()), ("expression", num(1))])),
      ]),
    )
  }
  g.sql(
    Some(
      tmpl(normal_template.get(), [
        ("mean", mean),
        ("stddev", stddev),
        ("u1", u1),
        ("u2", u2),
      ]),
    ),
  )
}

///|
/// Transpile Snowflake's UNIFORM(min, max, gen) to DuckDB.
fn uniform_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let min_val = this_of(e)
  let max_val = expr_of(e)
  let gen = e.arg("gen")
  let is_int_result = min_val.is_int() && max_val.is_int()
  let random_expr = match gen {
    Some(gen) if gen.kind == Rand => @core.mk0(Rand)
    _ => hash_random_expr_opt(gen)
  }
  let mut range_expr = @core.mk(Sub, [
    ("this", max_val),
    ("expression", min_val),
  ])
  if is_int_result {
    range_expr = @core.mk(Add, [("this", range_expr), ("expression", num(1))])
  }
  let mut result = @core.mk(Add, [
    ("this", min_val),
    (
      "expression",
      @core.mk(Mul, [
        ("this", random_expr),
        ("expression", @core.mk1(Paren, range_expr)),
      ]),
    ),
  ])
  if is_int_result {
    result = @core.mk(Cast, [
      ("this", @core.mk1(Floor, result)),
      ("to", @core.datatype_of(BIGINT)),
    ])
  }
  g.sql(Some(result))
}

///|
fn hash_random_expr_opt(seed : @core.Expr?) -> @core.Expr {
  @core.mk(Div, [
    (
      "this",
      @core.mk1(
        Paren,
        @core.mk(Mod, [
          (
            "this",
            @core.mk1(
              Abs,
              @core.mk(Anonymous, [
                ("this", @core.Value::Str("HASH")),
                (
                  "expressions",
                  @core.Value::List(
                    match seed {
                      Some(s) => [Node(s)]
                      None => []
                    },
                  ),
                ),
              ]),
            ),
          ),
          ("expression", num(1000000)),
        ]),
      ),
    ),
    ("expression", numstr("1000000.0")),
  ])
}

///|
fn timefromparts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let nano = e.arg("nano")
  // Snowflake's TIME_FROM_PARTS supports overflow
  if e.has("overflow") {
    let hour = req(e, "hour")
    let minute = req(e, "min")
    let mut sec = req(e, "sec")
    // Check if values are within normal ranges - use MAKE_TIME for efficiency
    if nano is None && hour.is_int() && minute.is_int() && sec.is_int() {
      let h_val = to_int(hour)
      let m_val = to_int(minute)
      let s_val = to_int(sec)
      if 0 <= h_val &&
        h_val <= 23 &&
        0 <= m_val &&
        m_val <= 59 &&
        0 <= s_val &&
        s_val <= 59 {
        return @core.rename_func("MAKE_TIME")(g, e)
      }
    }
    // Overflow or nanoseconds detected - use INTERVAL arithmetic
    match nano {
      Some(n) => sec = add(sec, div(n.pop(), numstr("1000000000.0")))
      None => ()
    }
    let total_seconds = add(
      add(mul(hour, num(3600)), mul(minute, num(60))),
      sec,
    )
    return g.sql(
      Some(
        @core.mk(Add, [
          (
            "this",
            @core.mk(Cast, [
              ("this", str_lit("00:00:00")),
              ("to", @core.datatype_of(TIME)),
            ]),
          ),
          ("expression", interval(total_seconds, "SECOND")),
        ]),
      ),
    )
  }
  // Default: MAKE_TIME
  match nano {
    Some(n) => {
      let sec = req(e, "sec")
      e.set("sec", add(sec, div(n.pop(), numstr("1000000000.0"))))
    }
    None => ()
  }
  @core.rename_func("MAKE_TIME")(g, e)
}

///|
/// Transpile EXTRACT/DATE_PART for DuckDB, handling specifiers not natively supported.
fn extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let datetime_expr = expr_of(e)
  if datetime_expr.is_type([TIMESTAMPTZ, TIMESTAMPLTZ]) {
    g.unsupported(
      "EXTRACT from TIMESTAMPTZ / TIMESTAMPLTZ may produce different results due to timezone handling differences",
    )
  }
  let part_name = @core.py_upper(this.name())
  match extract_strftime_mappings.get(part_name) {
    Some((fmt, cast_type)) => {
      let is_nano_time = part_name == "NANOSECOND" &&
        datetime_expr.is_type([TIME, TIMETZ])
      if is_nano_time {
        g.unsupported(
          "Parameter NANOSECOND is not supported with TIME type in DuckDB",
        )
        return g.sql(
          Some(
            cast_to(
              @core.mk(Mul, [
                (
                  "this",
                  @core.mk(Extract, [
                    ("this", @core.var_("MICROSECOND")),
                    ("expression", datetime_expr),
                  ]),
                ),
                ("expression", num(1000)),
              ]),
              duck_type(cast_type),
            ),
          ),
        )
      }
      let strftime_input = if part_name == "NANOSECOND" {
        cast(datetime_expr, TIMESTAMP_NS)
      } else {
        datetime_expr
      }
      return g.sql(
        Some(
          cast_to(
            @core.mk(Anonymous, [
              ("this", @core.Value::Str("STRFTIME")),
              (
                "expressions",
                @core.Value::List([Node(strftime_input), Node(str_lit(fmt))]),
              ),
            ]),
            duck_type(cast_type),
          ),
        ),
      )
    }
    None => ()
  }
  match extract_epoch_mappings.get(part_name) {
    Some(func_name) => {
      let mut result = @core.mk(Anonymous, [
        ("this", func_name),
        ("expressions", [datetime_expr]),
      ])
      if part_name == "EPOCH_SECOND" {
        result = cast_to(result, duck_type("BIGINT"))
      }
      return g.sql(Some(result))
    }
    None => ()
  }
  g.extract_sql(e)
}

///|
fn timestampfromparts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match (e.this(), e.expression()) {
    (Some(date_expr), Some(time_expr)) =>
      // In DuckDB, DATE + TIME produces TIMESTAMP
      return g.sql(
        Some(@core.mk(Add, [("this", date_expr), ("expression", time_expr)])),
      )
    _ => ()
  }
  guard e.arg("sec") is Some(sec) else {
    return @core.rename_func("MAKE_TIMESTAMP")(g, e)
  }
  let mut sec = sec
  let milli = e.arg("milli")
  match milli {
    Some(m) => sec = add(sec, div(m.pop(), numstr("1000.0")))
    None => ()
  }
  let nano = e.arg("nano")
  match nano {
    Some(n) => sec = add(sec, div(n.pop(), numstr("1000000000.0")))
    None => ()
  }
  if milli is Some(_) || nano is Some(_) {
    e.set("sec", sec)
  }
  match e.arg("zone") {
    Some(zone) =>
      return g.sql(
        Some(@core.mk(AtTimeZone, [("this", e), ("zone", zone.pop())])),
      )
    None => ()
  }
  @core.rename_func("MAKE_TIMESTAMP")(g, e)
}

///|
fn timestampltzfromparts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["nano"])
  match e.arg("nano") {
    Some(n) => n.pop() |> ignore
    None => ()
  }
  let timestamp = @core.rename_func("MAKE_TIMESTAMP")(g, e)
  "CAST(\{timestamp} AS TIMESTAMPTZ)"
}

///|
fn timestamptzfromparts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["nano"])
  let zone = match e.arg("zone") {
    Some(z) => Some(z.pop())
    None => None
  }
  match e.arg("nano") {
    Some(n) => n.pop() |> ignore
    None => ()
  }
  let timestamp = @core.rename_func("MAKE_TIMESTAMP")(g, e)
  match zone {
    Some(z) => "\{timestamp} AT TIME ZONE \{g.sql(Some(z))}"
    None => timestamp
  }
}

///|
fn tablesample_sql(
  g : @core.Generator,
  e : @core.Expr,
  tablesample_keyword : String?,
) -> String raise @core.SqlglotError {
  let mut tablesample_keyword = tablesample_keyword
  match e.parent {
    Some(p) if p.kind == Select => ()
    // This sample clause only applies to a single source, not the entire resulting relation
    _ => tablesample_keyword = Some("TABLESAMPLE")
  }
  if e.has("size") {
    match e.arg("method") {
      Some(meth) if @core.py_upper(meth.name()) != "RESERVOIR" => {
        g.unsupported(
          "Sampling method \{@core.expr_to_sql(meth)} is not supported with a discrete sample count, defaulting to reservoir sampling",
        )
        e.set("method", @core.var_("RESERVOIR"))
      }
      _ => ()
    }
  }
  g.tablesample_sql(e, tablesample_keyword?)
}

///|
fn in_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.arg("unnest") {
    Some(unnest) =>
      g.sql(
        Some(
          tmpl(in_unnest_template.get(), [
            ("arr", unnest.expressions()[0]),
            ("value", this_of(e)),
          ]),
        ),
      )
    None => g.in_sql(e)
  }
}

///|
fn join_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let kind = @core.py_upper(e.text("kind"))
  if !e.has("using") &&
    !e.has("on") &&
    e.text("method") == "" &&
    (kind == "" || kind == "INNER" || kind == "OUTER") {
    // Some dialects support `LEFT/INNER JOIN UNNEST(...)` without an explicit ON clause
    // DuckDB doesn't, but we can just add a dummy ON clause that is always true
    match e.this() {
      Some(t) if t.kind == Unnest => {
        let join = e.copy()
        join.set("on", @core.true_())
        return g.join_sql(join)
      }
      _ => ()
    }
    e.set("side", (None : @core.Expr?))
    e.set("kind", (None : @core.Expr?))
  }
  g.join_sql(e)
}

///|
fn countif_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if g.dialect.version >= (1, 2, 0) {
    let this = this_of(e)
    let mut e = e
    if e.has("zero_on_all_null") && this.kind != Distinct {
      // DuckDB >= 1.2's COUNT_IF returns NULL when the condition is NULL on all rows,
      // so we wrap the condition in IS TRUE to preserve count-like semantics
      e = @core.mk1(CountIf, is_(@core.exp_paren(this), @core.true_()))
    }
    return g.function_fallback_sql(e)
  }
  // https://github.com/tobymao/sqlglot/pull/4749
  @core.count_if_to_sum(g, e)
}

///|
fn bracket_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if g.dialect.version >= (1, 2, 0) {
    return g.bracket_sql(e)
  }
  // https://duckdb.org/2025/02/05/announcing-duckdb-120.html#breaking-changes
  let mut this = this_of(e)
  if this.kind == Array {
    this.replace(Some(@core.exp_paren(this))) |> ignore
  }
  let mut bracket = g.bracket_sql(e)
  if !e.has("returns_list_for_maps") {
    if !has_type(this) {
      this = @core.gen_annotate_types(this, g.dialect)
    }
    if this.is_type([MAP]) {
      bracket = "(\{bracket})[1]"
    }
  }
  bracket
}

///|
fn withingroup_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let func = this_of(e)
  // For ARRAY_AGG, DuckDB requires ORDER BY inside the function, not in WITHIN GROUP
  if func.kind == ArrayAgg {
    guard e.expression() is Some(order) && order.kind.is_a(Order) else {
      return g.sql(Some(func))
    }
    let original_this = func.this()
    func.set(
      "this",
      @core.mk(Order, [
        ("this", this_of(func).copy()),
        ("expressions", order.expressions()),
      ]),
    )
    let array_agg_sql = g.function_fallback_sql(func)
    return g.add_arrayagg_null_filter(array_agg_sql, func, original_this)
  }
  let expression_sql = g.sql_key(e, "expression")
  if func.kind == PercentileCont || func.kind == PercentileDisc {
    // Make the order key the first arg and slide the fraction to the right
    match e.find([Ordered]) {
      Some(order_col) => {
        func.set("expression", func.this())
        func.set("this", order_col.this())
      }
      None => ()
    }
  }
  let this = rstrip_parens(g.sql_key(e, "this"))
  "\{this}\{expression_sql})"
}

///|
fn rstrip_parens(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s[end - 1] == ')' {
    end -= 1
  }
  s.unsafe_substring(start=0, end~)
}

///|
fn length_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut arg = this_of(e)
  // Dialects like BQ and Snowflake also accept binary values as args, so
  // DDB will attempt to infer the type or resort to case/when resolution
  if !e.has("binary") || arg.is_string() {
    return g.func("LENGTH", [arg])
  }
  if !has_type(arg) {
    arg = @core.gen_annotate_types(arg, g.dialect)
  }
  if is_text(arg) {
    return g.func("LENGTH", [arg])
  }
  // We need these casts to make duckdb's static type checker happy
  let blob = cast(arg, VARBINARY)
  let varchar = cast(arg, VARCHAR)
  let case_expr = else_(
    when(
      @core.mk(Case, [
        (
          "this",
          @core.mk(Anonymous, [("this", "TYPEOF"), ("expressions", [arg])]),
        ),
        ("ifs", ([] : Array[@core.Expr])),
      ]),
      str_lit("BLOB"),
      @core.mk1(ByteLength, blob),
    ),
    @core.mk(Anonymous, [("this", "LENGTH"), ("expressions", [varchar])]),
  )
  g.sql(Some(case_expr))
}

///|
fn bitlength_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = this_of(e)
  if !is_binary(Some(arg)) {
    return g.func("BIT_LENGTH", [arg])
  }
  let blob = cast(arg, VARBINARY)
  g.sql(Some(mul(@core.mk1(ByteLength, blob), num(8))))
}

///|
fn collate_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if !expr_of(e).is_string() {
    return g.collate_sql(e)
  }
  let raw = expr_of(e).name()
  if raw == "" {
    return g.sql(e.this())
  }
  let parts = []
  for part in @core.py_split(raw, "-") {
    let lower = @core.py_lower(part)
    if !snowflake_collation_defaults.contains(lower) {
      if snowflake_collation_unsupported.contains(lower) {
        g.unsupported(
          "Snowflake collation specifier '\{part}' has no DuckDB equivalent",
        )
      }
      parts.push(lower)
    }
  }
  if parts.is_empty() {
    return g.sql(e.this())
  }
  g.collate_sql(
    @core.mk(Collate, [
      ("this", e.this()),
      ("expression", @core.var_(parts.join("."))),
    ]),
  )
}

///|
/// Validate and filter regexp flags for DuckDB compatibility.
fn validate_regexp_flags(
  g : @core.Generator,
  flags : @core.Expr?,
  supported_flags : String,
) -> String? raise @core.SqlglotError {
  guard flags is Some(flags) else { return None }
  if !flags.is_string() {
    g.unsupported("Non-literal regexp flags are not fully supported in DuckDB")
    return None
  }
  let flag_str = flags.text("this")
  let unsupported : Array[Char] = []
  for c in flag_str {
    if !supported_flags.contains_char(c) && !unsupported.contains(c) {
      unsupported.push(c)
    }
  }
  if !unsupported.is_empty() {
    unsupported.sort()
    let listed = unsupported.map(c => "'\{c}'").join(", ")
    g.unsupported("Regexp flags [\{listed}] are not supported in this context")
  }
  let filtered = StringBuilder()
  for c in flag_str {
    if supported_flags.contains_char(c) {
      filtered.write_char(c)
    }
  }
  let flag_str = filtered.to_string()
  if flag_str != "" {
    Some(flag_str)
  } else {
    None
  }
}

///|
fn regexpcount_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  let mut pattern = expr_of(e)
  let position = e.arg("position")
  let parameters = e.arg("parameters")
  let validated_flags = validate_regexp_flags(g, parameters, "ims")
  match position {
    Some(p) => this = @core.mk(Substring, [("this", this), ("start", p)])
    None => ()
  }
  match validated_flags {
    Some(f) =>
      pattern = @core.mk(Concat, [
        ("expressions", [str_lit("(?\{f})"), pattern]),
      ])
    None => ()
  }
  let result = else_(
    when(
      case_(),
      @core.mk(EQ, [("this", pattern), ("expression", str_lit(""))]),
      num(0),
    ),
    @core.mk1(
      Length,
      @core.mk(Anonymous, [
        ("this", "REGEXP_EXTRACT_ALL"),
        ("expressions", [this, pattern]),
      ]),
    ),
  )
  g.sql(Some(result))
}

///|
fn regexpreplace_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut subject = this_of(e)
  let pattern = expr_of(e)
  let replacement = match e.arg("replacement") {
    Some(r) => r
    None => str_lit("")
  }
  let position = e.arg("position")
  let occurrence = e.arg("occurrence")
  let modifiers = e.arg("modifiers")
  let mut validated_flags = match validate_regexp_flags(g, modifiers, "cimsg") {
    Some(f) => f
    None => ""
  }
  match occurrence {
    Some(o) if !o.is_int() =>
      g.unsupported("REGEXP_REPLACE with non-literal occurrence")
    _ => {
      let occurrence = match occurrence {
        Some(o) => to_int(o)
        None => 0
      }
      if occurrence > 1 {
        g.unsupported("REGEXP_REPLACE occurrence=\{occurrence} not supported")
      } else if occurrence == 0 &&
        !validated_flags.contains("g") &&
        !e.has("single_replace") {
        validated_flags = validated_flags + "g"
      }
    }
  }
  let mut prefix : @core.Expr? = None
  match position {
    Some(p) if !p.is_int() =>
      g.unsupported("REGEXP_REPLACE with non-literal position")
    Some(p) if to_int(p) > 1 => {
      let pos = to_int(p)
      prefix = Some(
        @core.mk(Substring, [
          ("this", subject),
          ("start", num(1)),
          ("length", num(pos - 1)),
        ]),
      )
      subject = @core.mk(Substring, [("this", subject), ("start", num(pos))])
    }
    _ => ()
  }
  let exprs = [subject, pattern, replacement]
  if validated_flags != "" {
    exprs.push(str_lit(validated_flags))
  }
  let mut result = @core.mk(Anonymous, [
    ("this", "REGEXP_REPLACE"),
    ("expressions", exprs),
  ])
  match prefix {
    Some(p) => result = @core.mk(Concat, [("expressions", [p, result])])
    None => ()
  }
  g.sql(Some(result))
}

///|
fn regexplike_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let pattern = e.expression()
  let flag = e.arg("flag")
  if e.has("full_match") {
    let validated_flags = validate_regexp_flags(g, flag, "cims")
    let flag = match validated_flags {
      Some(f) => Some(str_lit(f))
      None => None
    }
    return g.func("REGEXP_FULL_MATCH", [this, pattern, flag])
  }
  g.func("REGEXP_MATCHES", [this, pattern, flag])
}

///|
fn levenshtein_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost"])
  let this = e.this()
  let expr = e.expression()
  match e.arg("max_dist") {
    None => g.func("LEVENSHTEIN", [this, expr])
    Some(max_dist) => {
      // Emulate Snowflake semantics: if distance > max_dist, return max_dist
      let levenshtein = @core.mk(Levenshtein, [
        ("this", this),
        ("expression", expr),
      ])
      g.sql(
        Some(
          @core.mk(Least, [("this", levenshtein), ("expressions", [max_dist])]),
        ),
      )
    }
  }
}

///|
fn pad_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let string_arg = this_of(e)
  let fill_arg = match e.arg("fill_pattern") {
    Some(f) => f
    None => str_lit(" ")
  }
  if is_binary(Some(string_arg)) || is_binary(Some(fill_arg)) {
    let length_arg = expr_of(e)
    let is_left = e.has("is_left")
    let input_len = @core.mk1(ByteLength, string_arg)
    let chars_needed = sub(length_arg, input_len)
    let pad_count = @core.mk(Greatest, [
      ("this", num(0)),
      ("expressions", [chars_needed]),
      ("ignore_nulls", true),
    ])
    let repeat_expr = @core.mk(Repeat, [
      ("this", fill_arg),
      ("times", pad_count),
    ])
    let (left, right) = if is_left {
      (repeat_expr, string_arg)
    } else {
      (string_arg, repeat_expr)
    }
    return g.sql(Some(@core.mk(DPipe, [("this", left), ("expression", right)])))
  }
  g.pad_sql(e)
}

///|
fn minhash_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let k = this_of(e)
  let exprs = e.expressions()
  if exprs.length() != 1 || exprs[0].kind == Star {
    g.unsupported(
      "MINHASH with multiple expressions or * requires manual query restructuring",
    )
    let args : Array[&@core.SqlArg] = [k]
    for x in exprs {
      args.push(x)
    }
    return g.func("MINHASH", args)
  }
  let expr = exprs[0]
  "(\{g.sql(Some(tmpl(minhash_template.get(), [("expr", expr), ("k", k)])))})"
}

///|
fn arrayconcatagg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  if this.kind == Limit {
    g.unsupported("LIMIT in ARRAY_CONCAT_AGG cannot be transpiled to DuckDB")
    this = this_of(this)
  }
  let inner = if this.kind.is_a(Order) { this_of(this) } else { this }
  g.func("FLATTEN", [
    @core.mk(Filter, [
      ("this", @core.mk1(ArrayAgg, this)),
      ("expression", @core.mk1(Where, not_(is_null(inner.copy())))),
    ]),
  ])
}

///|
fn arraydistinct_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arr = this_of(e)
  let func_sql = g.func("LIST_DISTINCT", [arr])
  if e.has("check_null") {
    let add_null_to_array = func("LIST_APPEND", [
      func("LIST_DISTINCT", [@core.mk1(ArrayCompact, arr)]),
      @core.mk0(Null),
    ])
    return g.sql(
      Some(
        if_(
          @core.mk(NEQ, [
            ("this", @core.mk1(ArraySize, arr)),
            ("expression", func("LIST_COUNT", [arr])),
          ]),
          add_null_to_array,
          func_sql,
        ),
      ),
    )
  }
  func_sql
}

///|
/// Transpiles Snowflake's ARRAY_SLICE (0-indexed, exclusive end) to DuckDB's ARRAY_SLICE.
fn arrayslice_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut start = e.arg("start")
  let mut end = e.arg("end")
  if e.has("zero_based") {
    match start {
      Some(s) =>
        start = Some(
          else_(
            when(
              case_(),
              @core.mk(GTE, [("this", s.copy()), ("expression", num(0))]),
              @core.mk(Add, [("this", s.copy()), ("expression", num(1))]),
            ),
            s,
          ),
        )
      None => ()
    }
    match end {
      Some(x) =>
        end = Some(
          else_(
            when(
              case_(),
              @core.mk(LT, [("this", x.copy()), ("expression", num(0))]),
              @core.mk(Sub, [("this", x.copy()), ("expression", num(1))]),
            ),
            x,
          ),
        )
      None => ()
    }
  }
  g.func("ARRAY_SLICE", [e.this(), start, end, e.arg("step")])
}

///|
fn arrayszip_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let args = e.expressions()
  if args.is_empty() {
    // Return [{}] - using MAP([], []) since DuckDB can't represent empty structs
    return g.sql(
      Some(
        @core.array_([
          @core.mk(Map, [
            ("keys", @core.array_([])),
            ("values", @core.array_([])),
          ]),
        ]),
      ),
    )
  }
  let lengths = args.map(arg => @core.mk1(Length, arg))
  let max_len = if lengths.length() == 1 {
    lengths[0]
  } else {
    @core.mk(Greatest, [
      ("this", lengths[0]),
      ("expressions", lengths[1:].to_owned()),
    ])
  }
  let empty_struct = func(
    "STRUCT",
    args.mapi((i, _) => {
      @core.mk(PropertyEQ, [
        ("this", str_lit("$\{i + 1}")),
        ("expression", @core.mk0(Null)),
      ])
    }),
  )
  let index = add(@core.column_of("__i"), num(1))
  let transform_struct = func(
    "STRUCT",
    args.mapi((i, arg) => {
      @core.mk(PropertyEQ, [
        ("this", str_lit("$\{i + 1}")),
        (
          "expression",
          getitem(func_nr("COALESCE", [arg, @core.array_([])]), index),
        ),
      ])
    }),
  )
  let result = tmpl(arrays_zip_template.get(), [
    ("null_check", @core.exp_or(args.map(arg => is_(arg, @core.mk0(Null))))),
    (
      "all_empty_check",
      @core.exp_and(
        args.map(arg => {
          @core.mk(EQ, [
            ("this", @core.mk1(Length, arg)),
            ("expression", num(0)),
          ])
        }),
      ),
    ),
    ("empty_struct", empty_struct),
    ("max_len", max_len),
    ("transform_struct", transform_struct),
  ])
  g.sql(Some(result))
}

///|
/// Non-raising `exp.func` for known coalesce-like builders used inside closures.
fn func_nr(name : String, args : Array[@core.Expr]) -> @core.Expr {
  func(name, args) catch {
    _ => @core.mk(Anonymous, [("this", name), ("expressions", args)])
  }
}

///|
fn left_right_sql(
  g : @core.Generator,
  e : @core.Expr,
  func_name : String,
) -> String raise @core.SqlglotError {
  let arg = this_of(e)
  let length = expr_of(e)
  let is_bin = is_binary(Some(arg))
  let mut result = if is_bin {
    let hex_arg = @core.mk1(Hex, arg)
    let hex_length = @core.mk(Mul, [("this", length), ("expression", num(2))])
    @core.mk1(
      Unhex,
      @core.mk(Anonymous, [
        ("this", func_name),
        ("expressions", [hex_arg, hex_length]),
      ]),
    )
  } else {
    @core.mk(Anonymous, [("this", func_name), ("expressions", [arg, length])])
  }
  if e.has("negative_length_returns_empty") {
    let mut empty = str_lit("")
    if is_bin {
      empty = @core.mk1(Unhex, empty)
    }
    result = else_(when(case_(), lt(length, num(0)), empty), result)
  }
  g.sql(Some(result))
}

///|
fn stuff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut base = this_of(e)
  let start = req(e, "start")
  let length = req(e, "length")
  let mut insertion = expr_of(e)
  let is_bin = is_binary(Some(base))
  let (left, right) = if is_bin {
    base = @core.mk1(Hex, base)
    insertion = @core.mk1(Hex, insertion)
    let left = @core.mk(Substring, [
      ("this", base.copy()),
      ("start", num(1)),
      ("length", mul(sub(start.copy(), num(1)), num(2))),
    ])
    let right = @core.mk(Substring, [
      ("this", base.copy()),
      ("start", add(mul(sub(add(start, length), num(1)), num(2)), num(1))),
    ])
    (left, right)
  } else {
    let left = @core.mk(Substring, [
      ("this", base.copy()),
      ("start", num(1)),
      ("length", sub(start.copy(), num(1))),
    ])
    let right = @core.mk(Substring, [
      ("this", base.copy()),
      ("start", add(start, length)),
    ])
    (left, right)
  }
  let mut result = @core.mk(DPipe, [
    ("this", @core.mk(DPipe, [("this", left), ("expression", insertion)])),
    ("expression", right),
  ])
  if is_bin {
    result = @core.mk1(Unhex, result)
  }
  g.sql(Some(result))
}

///|
fn rand_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.this() is Some(_) {
    g.unsupported("RANDOM with seed is not supported in DuckDB")
  }
  match (e.arg("lower"), e.arg("upper")) {
    (Some(lower), Some(upper)) => {
      // scale DuckDB's [0,1) to the specified range
      let range_size = @core.exp_paren(sub(upper, lower))
      let scaled = @core.mk(Add, [
        ("this", lower),
        ("expression", mul(func("random", []), range_size)),
      ])
      // For now we assume that if bounds are set, return type is BIGINT. Snowflake/Teradata
      g.sql(Some(cast(scaled, BIGINT)))
    }
    _ => "RANDOM()"
  }
}

///|
fn base64encode_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut result = this_of(e)
  if is_text(result) {
    result = @core.mk1(Encode, result)
  }
  result = @core.mk1(ToBase64, result)
  let max_line_length = e.arg("max_line_length")
  let alphabet = e.arg("alphabet")
  result = apply_base64_alphabet_replacements(result, alphabet)
  let line_length = match max_line_length {
    Some(m) if m.kind == Literal && m.is_number() =>
      match m.to_py_int() {
        Some(v) => v.to_int()
        None => 0
      }
    _ => 0
  }
  if line_length > 0 {
    let newline = @core.mk(Chr, [("expressions", [num(10)])])
    result = @core.mk(Trim, [
      (
        "this",
        @core.mk(RegexpReplace, [
          ("this", result),
          ("expression", str_lit("(.{\{line_length}})")),
          (
            "replacement",
            @core.mk(Concat, [("expressions", [str_lit("\\1"), newline.copy()])]),
          ),
        ]),
      ),
      ("expression", newline),
      ("position", "TRAILING"),
    ])
  }
  g.sql(Some(result))
}

///|
fn hex_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  guard e.arg("case") is Some(case) else { return g.func("HEX", [e.this()]) }
  let hex_expr = @core.mk1(Hex, e.this())
  g.sql(
    Some(
      else_(
        when(
          when(case_(), is_null(case), @core.null_()),
          eq(case.copy(), num(0)),
          @core.mk1(Lower, hex_expr.copy()),
        ),
        hex_expr,
      ),
    ),
  )
}

///|
fn bitwise_op(
  g : @core.Generator,
  e : @core.Expr,
  op : String,
) -> String raise @core.SqlglotError {
  prepare_binary_bitwise_args(e)
  let result_sql = g.binary(e, op)
  gen_with_cast_to_blob(g, e, result_sql)
}

///|
fn objectinsert_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let key_sql = match e.arg("key") {
    Some(k) => k.name()
    None => ""
  }
  let value_sql = g.sql_key(e, "value")
  let kv_sql = "\{key_sql} := \{value_sql}"
  // If the input struct is empty e.g. transpiling OBJECT_INSERT(OBJECT_CONSTRUCT(), key, value) from Snowflake
  // then we can generate STRUCT_PACK which will build it since STRUCT_INSERT({}, key := value) is not valid DuckDB
  if this.kind == Struct && this.expressions().is_empty() {
    return g.func("STRUCT_PACK", [kv_sql])
  }
  g.func("STRUCT_INSERT", [g.sql(Some(this)), kv_sql])
}

///|
fn x_dot_key() -> @core.Expr {
  @core.mk(Dot, [
    ("this", @core.to_identifier("x")),
    ("expression", @core.to_identifier("key")),
  ])
}

///|
fn mapdelete_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let map_arg = this_of(e)
  let keys_to_delete = e.expressions()
  let lambda_expr = @core.mk(Lambda, [
    (
      "this",
      not_(
        @core.mk(In, [("this", x_dot_key()), ("expressions", keys_to_delete)]),
      ),
    ),
    ("expressions", [@core.to_identifier("x")]),
  ])
  let result = func("MAP_FROM_ENTRIES", [
    @core.mk(ArrayFilter, [
      ("this", func("MAP_ENTRIES", [map_arg])),
      ("expression", lambda_expr),
    ]),
  ])
  g.sql(Some(result))
}

///|
fn mappick_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let map_arg = this_of(e)
  let keys_to_pick = e.expressions()
  let lambda_expr = if keys_to_pick.length() == 1 &&
    keys_to_pick[0].is_type([ARRAY]) {
    @core.mk(Lambda, [
      ("this", func("ARRAY_CONTAINS", [keys_to_pick[0], x_dot_key()])),
      ("expressions", [@core.to_identifier("x")]),
    ])
  } else {
    @core.mk(Lambda, [
      (
        "this",
        @core.mk(In, [("this", x_dot_key()), ("expressions", keys_to_pick)]),
      ),
      ("expressions", [@core.to_identifier("x")]),
    ])
  }
  let result = func("MAP_FROM_ENTRIES", [
    func("LIST_FILTER", [func("MAP_ENTRIES", [map_arg]), lambda_expr]),
  ])
  g.sql(Some(result))
}

///|
fn mapinsert_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["update_flag"])
  let map_arg = this_of(e)
  let key = e.arg("key")
  let mut value = e.arg("value")
  match (value, map_arg.get_type()) {
    (Some(v), Some(map_type)) if map_type.expressions().length() > 1 => {
      // Cast value to match the map's value type to avoid type conflicts
      let value_type = map_type.expressions()[1]
      value = Some(cast_to(v, value_type))
    }
    _ => ()
  }
  let new_entry_struct = @core.mk(Struct, [
    (
      "expressions",
      [@core.mk(PropertyEQ, [("this", key), ("expression", value)])],
    ),
  ])
  let new_entry = @core.mk1(ToMap, new_entry_struct)
  let result = func("MAP_CONCAT", [map_arg, new_entry])
  g.sql(Some(result))
}

///|
fn tablefromrows_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.this() {
    Some(t) if t.kind == Generator => {
      let table = @core.mk(Table, [
        ("this", Some(t)),
        ("alias", e.arg("alias")),
        ("joins", e.get("joins")),
      ])
      g.sql(Some(table))
    }
    _ => g.tablefromrows_sql(e)
  }
}

///|
fn unnest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("explode_array") {
    // In BigQuery, UNNESTing a nested array leads to explosion of the top-level array & struct
    e.append(
      "expressions",
      @core.mk(Kwarg, [
        ("this", @core.var_("max_depth")),
        ("expression", num(2)),
      ]),
    )
    // If BQ's UNNEST is aliased, we transform it from a column alias to a table alias in DDB
    let mut alias_ = e.arg("alias")
    match alias_ {
      Some(a) if a.kind == TableAlias => {
        e.set("alias", (None : @core.Expr?))
        let columns = a.list("columns")
        if !columns.is_empty() {
          alias_ = Some(@core.mk1(TableAlias, columns[0]))
        }
      }
      _ => ()
    }
    let unnest_sql = g.unnest_sql(e)
    let select = @core.exp_subquery_with_alias_expr(
      @core.mk(Select, [("expressions", [unnest_sql])]),
      alias_,
    )
    return g.sql(Some(select))
  }
  g.unnest_sql(e)
}

///|
fn ignorenulls_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  if this.kind.is_any(ignore_respect_nulls_window_functions) {
    // DuckDB should render IGNORE NULLS only for the general-purpose
    // window functions that accept it e.g. FIRST_VALUE(... IGNORE NULLS) OVER (...)
    return g.ignorenulls_sql(e)
  }
  // For ARRAY_AGG(expr IGNORE NULLS ...), convert IGNORE NULLS to a
  // FILTER(WHERE expr IS NOT NULL) clause by setting nulls_excluded on the ArrayAgg.
  if this.kind == ArrayAgg {
    this.set("nulls_excluded", true)
    return g.sql(Some(this))
  }
  if this.kind == First {
    this = @core.mk1(AnyValue, this.this())
  }
  if this.kind != AnyValue && this.kind != ApproxQuantiles {
    g.unsupported("IGNORE NULLS is not supported for non-window functions.")
  }
  g.sql(Some(this))
}

///|
fn split_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let base_func = func("STR_SPLIT", [this_of(e), expr_of(e)])
  let mut case_expr = else_(case_(), base_func)
  let mut needs_case = false
  if e.has("null_returns_null") {
    case_expr = when(case_expr, is_null(expr_of(e)), @core.null_())
    needs_case = true
  }
  if e.has("empty_delimiter_returns_whole") {
    // When delimiter is empty string, return input string as single array element
    let array_with_input = @core.array_([this_of(e)])
    case_expr = when(case_expr, eq(expr_of(e), str_lit("")), array_with_input)
    needs_case = true
  }
  g.sql(Some(if needs_case { case_expr } else { base_func }))
}

///|
fn splitpart_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let string_arg = this_of(e)
  match (e.arg("delimiter"), e.arg("part_index")) {
    (Some(delimiter_arg), Some(part_index_arg)) => {
      let mut part_index_arg = part_index_arg
      // Handle Snowflake's "index 0 and 1 both return first element" behavior
      if e.has("part_index_zero_as_one") {
        part_index_arg = @core.mk1(
          Paren,
          else_(
            when(case_(), eq(part_index_arg, numstr("0")), numstr("1")),
            part_index_arg,
          ),
        )
      }
      let base_func_expr = @core.mk(Anonymous, [
        ("this", "SPLIT_PART"),
        ("expressions", [string_arg, delimiter_arg, part_index_arg]),
      ])
      let mut needs_case_transform = false
      let mut case_expr = else_(case_(), base_func_expr)
      if e.has("empty_delimiter_returns_whole") {
        let empty_case = @core.mk1(
          Paren,
          else_(
            when(
              case_(),
              @core.exp_or([
                eq(part_index_arg, numstr("1")),
                eq(part_index_arg, numstr("-1")),
              ]),
              string_arg,
            ),
            str_lit(""),
          ),
        )
        case_expr = when(case_expr, eq(delimiter_arg, str_lit("")), empty_case)
        needs_case_transform = true
      }
      g.sql(Some(if needs_case_transform { case_expr } else { base_func_expr }))
    }
    _ => g.function_fallback_sql(e)
  }
}

///|
fn arraytostring_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let null = e.arg("null")
  if e.has("null_is_empty") {
    let x = @core.to_identifier("x")
    let list_transform = @core.mk(Transform, [
      ("this", this_of(e).copy()),
      (
        "expression",
        @core.mk(Lambda, [
          (
            "this",
            @core.mk(Coalesce, [
              ("this", cast_to(x, base_type("TEXT"))),
              ("expressions", [str_lit("")]),
            ]),
          ),
          ("expressions", [x]),
        ]),
      ),
    ])
    let array_to_string = @core.mk(ArrayToString, [
      ("this", list_transform),
      ("expression", e.expression()),
    ])
    if e.has("null_delim_is_null") {
      return g.sql(
        Some(
          else_(
            when(case_(), is_null(expr_of(e).copy()), @core.null_()),
            array_to_string,
          ),
        ),
      )
    }
    return g.sql(Some(array_to_string))
  }
  match null {
    Some(null) => {
      let x = @core.to_identifier("x")
      g.sql(
        Some(
          @core.mk(ArrayToString, [
            (
              "this",
              @core.mk(Transform, [
                ("this", e.this()),
                (
                  "expression",
                  @core.mk(Lambda, [
                    (
                      "this",
                      @core.mk(Coalesce, [("this", x), ("expressions", [null])]),
                    ),
                    ("expressions", [x.copy()]),
                  ]),
                ),
              ]),
            ),
            ("expression", e.expression()),
          ]),
        ),
      )
    }
    None => g.func("ARRAY_TO_STRING", [e.this(), e.expression()])
  }
}

///|
fn concatws_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // DuckDB-specific: handle binary types using DPipe (||) operator
  let exprs = e.expressions()
  let separator = exprs.get(0)
  let args = if exprs.length() > 1 { exprs[1:].to_owned() } else { [] }
  if is_binary(separator) || args.iter().any(a => is_binary(Some(a))) {
    let mut result = args[0]
    for arg in args[1:] {
      result = @core.mk(DPipe, [
        ("this", @core.mk(DPipe, [("this", result), ("expression", separator)])),
        ("expression", arg),
      ])
    }
    return g.sql(Some(result))
  }
  g.concatws_sql(e)
}

///|
fn regexp_extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  let mut group = e.arg("group")
  let mut params = e.arg("parameters")
  let position = e.arg("position")
  let occurrence = e.arg("occurrence")
  let null_if_pos_overflow = e.has("null_if_pos_overflow")
  // Handle Snowflake's 'e' flag: it enables capture group extraction
  match params {
    Some(p) if p.is_string() && p.name().contains("e") =>
      params = Some(str_lit(p.name().replace_all(old="e", new="")))
    _ => ()
  }
  let validated_flags = validate_regexp_flags(g, params, "cims")
  // Strip default group when no following params (DuckDB default is same as group=0)
  match group {
    Some(gr) if validated_flags is None &&
      gr.name() == g.dialect.cfg.regexp_extract_default_group.to_string() =>
      group = None
    _ => ()
  }
  let flags_expr = match validated_flags {
    Some(f) => Some(str_lit(f))
    None => None
  }
  // use substring to handle position argument
  match position {
    Some(p) if !p.is_int() || to_int(p) > 1 => {
      this = @core.mk(Substring, [("this", this), ("start", p)])
      if null_if_pos_overflow {
        this = @core.mk(Nullif, [("this", this), ("expression", str_lit(""))])
      }
    }
    _ => ()
  }
  let is_extract_all = e.kind == RegexpExtractAll
  let non_single_occurrence = match occurrence {
    Some(o) => !o.is_int() || to_int(o) > 1
    None => false
  }
  let name = if is_extract_all || non_single_occurrence {
    "REGEXP_EXTRACT_ALL"
  } else {
    "REGEXP_EXTRACT"
  }
  let exprs : Array[@core.Expr] = [this, expr_of(e)]
  match group {
    Some(gr) => exprs.push(gr)
    None => ()
  }
  match flags_expr {
    Some(f) => exprs.push(f)
    None => ()
  }
  let mut result = @core.mk(Anonymous, [("this", name), ("expressions", exprs)])
  if is_extract_all && non_single_occurrence {
    result = @core.mk(Bracket, [
      ("this", result),
      ("expressions", [@core.mk1(Slice, occurrence)]),
    ])
  } else if non_single_occurrence {
    result = @core.mk(Anonymous, [
      ("this", "ARRAY_EXTRACT"),
      ("expressions", [result, occurrence.unwrap()]),
    ])
  }
  g.sql(Some(result))
}

///|
fn regexpinstr_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  let mut pattern = expr_of(e)
  let position = e.arg("position")
  let orig_occ = e.arg("occurrence")
  let occurrence = match orig_occ {
    Some(o) => o
    None => num(1)
  }
  let option = e.arg("option")
  let parameters = e.arg("parameters")
  match validate_regexp_flags(g, parameters, "ims") {
    Some(f) =>
      pattern = @core.mk(Concat, [
        ("expressions", [str_lit("(?\{f})"), pattern]),
      ])
    None => ()
  }
  let mut pos_offset = num(0)
  match position {
    Some(p) if !p.is_int() || to_int(p) > 1 => {
      this = @core.mk(Substring, [("this", this), ("start", p)])
      pos_offset = sub(p, num(1))
    }
    _ => ()
  }
  let sum_lengths = (func_name : String, end : @core.Expr) => {
    let lst = @core.mk(Bracket, [
      (
        "this",
        @core.mk(Anonymous, [
          ("this", func_name),
          ("expressions", [this, pattern]),
        ]),
      ),
      (
        "expressions",
        [@core.mk(Slice, [("this", num(1)), ("expression", end)])],
      ),
      ("offset", 1),
    ])
    let transform = @core.mk(Anonymous, [
      ("this", "LIST_TRANSFORM"),
      (
        "expressions",
        [
          lst,
          @core.mk(Lambda, [
            ("this", @core.mk1(Length, @core.to_identifier("x"))),
            ("expressions", [@core.to_identifier("x")]),
          ]),
        ],
      ),
    ])
    @core.mk(Coalesce, [
      (
        "this",
        @core.mk(Anonymous, [("this", "LIST_SUM"), ("expressions", [transform])]),
      ),
      ("expressions", [num(0)]),
    ])
  }
  let mut base_pos = add(
    add(
      add(num(1), sum_lengths("STRING_SPLIT_REGEX", occurrence)),
      sum_lengths("REGEXP_EXTRACT_ALL", sub(occurrence, num(1))),
    ),
    pos_offset,
  )
  match option {
    Some(o) if o.is_int() && to_int(o) == 1 => {
      let match_at_occ = @core.mk(Bracket, [
        (
          "this",
          @core.mk(Anonymous, [
            ("this", "REGEXP_EXTRACT_ALL"),
            ("expressions", [this, pattern]),
          ]),
        ),
        ("expressions", [occurrence]),
        ("offset", 1),
      ])
      base_pos = add(
        base_pos,
        @core.mk(Coalesce, [
          ("this", @core.mk1(Length, match_at_occ)),
          ("expressions", [num(0)]),
        ]),
      )
    }
    _ => ()
  }
  let null_checks = []
  for arg in [e.this(), e.expression(), position, orig_occ, option, parameters] {
    match arg {
      Some(a) => null_checks.push(is_(a.copy(), @core.mk0(Null)))
      None => ()
    }
  }
  let matches = @core.mk(Anonymous, [
    ("this", "REGEXP_EXTRACT_ALL"),
    ("expressions", [this, pattern]),
  ])
  g.sql(
    Some(
      else_(
        when(
          when(
            when(case_(), @core.exp_or(null_checks), @core.mk0(Null)),
            eq(pattern.copy(), str_lit("")),
            num(0),
          ),
          lt(@core.mk1(Length, matches), occurrence),
          num(0),
        ),
        base_pos,
      ),
    ),
  )
}

///|
fn posexplode_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let parent = e.parent
  // The default Spark aliases are "pos" and "col", unless specified otherwise
  let mut pos = @core.to_identifier("pos")
  let mut col = @core.to_identifier("col")
  match parent {
    Some(p) if p.kind == Aliases => {
      let exprs = p.expressions()
      pos = exprs[0]
      col = exprs[1]
    }
    Some(p) if p.kind == Table =>
      match p.arg("alias") {
        Some(alias_) => {
          let columns = alias_.list("columns")
          if !columns.is_empty() {
            pos = columns[0]
            col = columns[1]
          }
          alias_.pop() |> ignore
        }
        None => ()
      }
    _ => ()
  }
  // Translate POSEXPLODE to UNNEST + GENERATE_SUBSCRIPTS
  let unnest_sql = g.sql(
    Some(@core.mk(Unnest, [("expressions", [this]), ("alias", Some(col))])),
  )
  let gen_subscripts = g.sql(
    Some(
      @core.mk(Alias, [
        (
          "this",
          sub(
            @core.mk(Anonymous, [
              ("this", @core.Value::Str("GENERATE_SUBSCRIPTS")),
              (
                "expressions",
                @core.Value::List(
                  match this {
                    Some(t) => [Node(t), Node(num(1))]
                    None => [Node(num(1))]
                  },
                ),
              ),
            ]),
            num(1),
          ),
        ),
        ("alias", pos),
      ]),
    ),
  )
  let posexplode_sql = g.format_args([gen_subscripts, unnest_sql])
  let in_from = match parent {
    Some(p) =>
      p.kind == From ||
      (match p.parent {
        Some(pp) => pp.kind == From
        None => false
      })
    None => false
  }
  if in_from {
    return g.sql(
      Some(
        @core.mk1(
          Subquery,
          @core.mk(Select, [("expressions", [posexplode_sql])]),
        ),
      ),
    )
  }
  posexplode_sql
}

///|
fn addmonths_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  if !has_type(this) {
    this = @core.gen_annotate_types(this, g.dialect)
  }
  if is_text(this) {
    this = @core.mk(Cast, [("this", this), ("to", @core.datatype_of(TIMESTAMP))])
  }
  let mut months_expr = expr_of(e)
  if !has_type(months_expr) {
    months_expr = @core.gen_annotate_types(months_expr, g.dialect)
  }
  let interval_or_to_months = if months_expr.is_type([FLOAT, DOUBLE, DECIMAL]) {
    func("TO_MONTHS", [cast_to(func("ROUND", [months_expr]), base_type("INT"))])
  } else {
    interval(months_expr, "MONTH")
  }
  let date_add_expr = @core.mk(Add, [
    ("this", this),
    ("expression", interval_or_to_months),
  ])
  let result_expr = if e.has("preserve_end_of_month") {
    else_(
      when(
        case_(),
        @core.mk(EQ, [("this", func("LAST_DAY", [this])), ("expression", this)]),
        func("LAST_DAY", [date_add_expr]),
      ),
      date_add_expr,
    )
  } else {
    date_add_expr
  }
  if this.is_type([DATE, TIMESTAMPTZ]) {
    return g.sql(
      Some(@core.mk(Cast, [("this", result_expr), ("to", this.get_type())])),
    )
  }
  g.sql(Some(result_expr))
}

///|
fn datetrunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit_arg = e.arg("unit")
  let date = this_of(e)
  let week_start = week_trunc_start_dow(unit_arg)
  let unit = @core.unit_to_str(e)
  let result = match week_start {
    Some(ws) if ws != 0 =>
      g.sql(
        Some(build_week_trunc_expression(date, ws, preserve_start_day=true)),
      )
    _ => g.func("DATE_TRUNC", [unit, Some(date)])
  }
  if e.has("input_type_preserved") &&
    date.is_type(@core.dtype_temporal_types) &&
    !(is_date_unit(unit) && date.is_type([DATE])) {
    return g.sql(
      Some(@core.mk(Cast, [("this", result), ("to", date.get_type())])),
    )
  }
  result
}

///|
fn datetimetrunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = cast(this_of(e), DATETIME)
  match week_trunc_start_dow(e.arg("unit")) {
    Some(ws) if ws != 0 =>
      g.sql(
        Some(
          build_week_trunc_expression(
            this,
            ws,
            preserve_start_day=true,
            cast_to_date=false,
          ),
        ),
      )
    _ => g.func("DATE_TRUNC", [@core.unit_to_str(e), Some(this)])
  }
}

///|
fn timestamptrunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let zone = e.arg("zone")
  let mut timestamp = this_of(e)
  let week_start = match week_trunc_start_dow(e.arg("unit")) {
    Some(0) => None
    w => w
  }
  // The week start emulation below is exact, so avoid weekstart_unit_to_str's degrade warning
  let unit = if week_start is Some(_) {
    @core.unit_to_str(e)
  } else {
    @core.weekstart_unit_to_str(g, e)
  }
  let date_unit = is_date_unit(unit) || week_start is Some(_)
  let trunc_expr = (this : @core.Expr) => {
    match week_start {
      Some(ws) =>
        build_week_trunc_expression(
          this,
          ws,
          preserve_start_day=true,
          cast_to_date=false,
        )
      None => func_nr("DATE_TRUNC", [unit.unwrap_or(@core.null_()), this])
    }
  }
  match zone {
    Some(zone) if date_unit => {
      timestamp = @core.mk(AtTimeZone, [("this", timestamp), ("zone", zone)])
      let mut trunced = trunc_expr(timestamp)
      if trunced.kind == DateAdd {
        // Parenthesize so the trailing AT TIME ZONE binds to the whole shifted expression
        trunced = @core.mk1(Paren, trunced)
      }
      return g.sql(
        Some(@core.mk(AtTimeZone, [("this", trunced), ("zone", zone)])),
      )
    }
    _ => ()
  }
  let mut result = g.sql(Some(trunc_expr(timestamp)))
  if e.has("input_type_preserved") {
    if has_type(timestamp) && timestamp.is_type([TIME, TIMETZ]) {
      let dummy_date = @core.mk(Cast, [
        ("this", str_lit("1970-01-01")),
        ("to", @core.datatype_of(DATE)),
      ])
      let date_time = @core.mk(Add, [
        ("this", dummy_date),
        ("expression", timestamp),
      ])
      result = g.func("DATE_TRUNC", [unit, Some(date_time)])
      return g.sql(
        Some(@core.mk(Cast, [("this", result), ("to", timestamp.get_type())])),
      )
    }
    if timestamp.is_type(@core.dtype_temporal_types) &&
      !(date_unit && timestamp.is_type([DATE])) {
      return g.sql(
        Some(@core.mk(Cast, [("this", result), ("to", timestamp.get_type())])),
      )
    }
  }
  result
}

///|
fn trim_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  this.replace(cast_to_varchar(Some(this))) |> ignore
  match e.expression() {
    Some(x) => x.replace(cast_to_varchar(Some(x))) |> ignore
    None => ()
  }
  let result_sql = g.trim_sql(e)
  gen_with_cast_to_blob(g, e, result_sql)
}

///|
fn round_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let mut decimals = e.arg("decimals")
  let mut truncate = e.arg("truncate")
  // DuckDB requires the scale (decimals) argument to be an INT
  match decimals {
    Some(dec) if e.has("casts_non_integer_decimals") &&
      !(dec.is_int() || is_integer(dec)) => decimals = Some(cast(dec, INT))
    _ => ()
  }
  let mut func_name = "ROUND"
  match truncate {
    Some(t) => {
      let tt = t.text("this")
      // BigQuery uses ROUND_HALF_EVEN; Snowflake uses HALF_TO_EVEN
      if tt == "ROUND_HALF_EVEN" || tt == "HALF_TO_EVEN" {
        func_name = "ROUND_EVEN"
        truncate = None
      } else if tt == "ROUND_HALF_AWAY_FROM_ZERO" || tt == "HALF_AWAY_FROM_ZERO" {
        truncate = None
      }
    }
    None => ()
  }
  g.func(func_name, [this, decimals, truncate])
}

///|
fn trycast_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let to = req(e, "to")
  let src = this_of(e)
  let to_type = to.get("this")
  if e.has("null_on_text_overflow") &&
    to.is_type(@core.dtype_text_types) &&
    !to.expressions().is_empty() {
    return g.sql(
      Some(
        else_(
          when(
            case_(),
            @core.mk(LTE, [
              ("this", func("LENGTH", [src])),
              ("expression", to.expressions()[0].this()),
            ]),
            cast_to(src, base_type("TEXT")),
          ),
          @core.mk0(Null),
        ),
      ),
    )
  } else if to.is_type([DATE]) && e.has("probe_date_format") {
    let slash_strptime = cast_to(
      func("TRY_STRPTIME", [src, str_lit("%m/%d/%Y")]),
      base_type("DATE"),
    )
    let mon_strptime = cast_to(
      func("TRY_STRPTIME", [src, str_lit("%d-%b-%Y")]),
      base_type("DATE"),
    )
    return g.sql(
      Some(
        else_(
          when(
            when(case_(), func("CONTAINS", [src, str_lit("/")]), slash_strptime),
            @core.mk(RegexpLike, [
              ("this", src),
              ("expression", str_lit("[A-Za-z]")),
            ]),
            mon_strptime,
          ),
          @core.mk(TryCast, [("this", src), ("to", to)]),
        ),
      ),
    )
  }
  match to_type {
    Some(Node(iv)) if iv.kind == Interval && e.has("requires_string") =>
      match iv.arg("unit") {
        Some(unit) => {
          let interval_type = base_type("INTERVAL")
          if unit.kind == IntervalSpan {
            g.unsupported(
              "TRY_CAST to INTERVAL with span (e.g. HOUR TO MINUTE) is not supported in DuckDB",
            )
            return g.sql(
              Some(@core.mk(TryCast, [("this", src), ("to", interval_type)])),
            )
          }
          return g.sql(
            Some(
              @core.mk(TryCast, [
                (
                  "this",
                  @core.mk(DPipe, [
                    ("this", src),
                    ("expression", str_lit(" \{unit.name()}")),
                  ]),
                ),
                ("to", interval_type),
              ]),
            ),
          )
        }
        None => ()
      }
    _ => ()
  }
  g.trycast_sql(e)
}

///|
fn strtok_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let string_arg = this_of(e)
  match (e.arg("delimiter"), e.arg("part_index")) {
    (Some(delimiter_arg), Some(part_index_arg)) => {
      // Escape regex chars and build character class at runtime using REGEXP_REPLACE
      let escaped_delimiter = @core.mk(Anonymous, [
        ("this", "REGEXP_REPLACE"),
        (
          "expressions",
          [
            delimiter_arg,
            str_lit("([\\[\\]^.\\-*+?(){}|$\\\\])"),
            str_lit("\\\\\\1"),
            str_lit("g"),
          ],
        ),
      ])
      let regex_pattern = else_(
        when(case_(), eq(delimiter_arg, str_lit("")), str_lit("")),
        func("CONCAT", [str_lit("["), escaped_delimiter, str_lit("]")]),
      )
      let split_array = func("REGEXP_SPLIT_TO_ARRAY", [
        string_arg, regex_pattern,
      ])
      let x = @core.to_identifier("x")
      let is_empty = eq(x, str_lit(""))
      let filtered_array = func("LIST_FILTER", [
        split_array,
        @core.mk(Lambda, [
          ("this", @core.exp_not(is_empty.copy())),
          ("expressions", [x.copy()]),
        ]),
      ])
      let base_func = @core.mk(Bracket, [
        ("this", filtered_array),
        ("expressions", [part_index_arg]),
        ("offset", 1),
      ])
      let result = tmpl(strtok_template.get(), [
        ("string", string_arg),
        ("delimiter", delimiter_arg),
        ("part_index", part_index_arg),
        ("base_func", base_func),
      ])
      g.sql(Some(result))
    }
    _ => g.function_fallback_sql(e)
  }
}

///|
fn strtoktoarray_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let string_arg = this_of(e)
  let delimiter_arg = match e.arg("expression") {
    Some(d) => d
    None => str_lit(" ")
  }
  let escaped = @core.mk(RegexpReplace, [
    ("this", delimiter_arg.copy()),
    ("expression", str_lit("([\\[\\]^.\\-*+?(){}|$\\\\])")),
    ("replacement", str_lit("\\\\\\1")),
    ("modifiers", str_lit("g")),
  ])
  g.sql(
    Some(
      tmpl(strtok_to_array_template.get(), [
        ("string", string_arg),
        ("delimiter", delimiter_arg),
        ("escaped", escaped),
      ]),
    ),
  )
}

///|
/// Python `str(Decimal(i) / Decimal(n))` for 0 <= i <= n.
fn decimal_div_str(i : Int, n : Int) -> String {
  if i == 0 {
    return "0"
  }
  let gcd = (a : Int, b : Int) => {
    let mut a = a
    let mut b = b
    while b != 0 {
      let t = a % b
      a = b
      b = t
    }
    a
  }
  let d = gcd(i, n)
  let num = i / d
  let den = n / d
  if num % den == 0 {
    return (num / den).to_string()
  }
  // Long division: integer part and up to 28 significant digits (half-even rounding)
  let int_part = num / den
  let mut rem = num % den
  let digits = StringBuilder()
  let mut sig = if int_part > 0 { int_part.to_string().length() } else { 0 }
  let mut started = int_part > 0
  let frac : Array[Int] = []
  while rem != 0 && sig < 28 {
    rem = rem * 10
    let digit = rem / den
    rem = rem % den
    frac.push(digit)
    if digit != 0 {
      started = true
    }
    if started {
      sig += 1
    }
  }
  if rem != 0 {
    // round half-even on the remainder
    let twice = rem * 2
    let round_up = twice > den ||
      (twice == den && frac[frac.length() - 1] % 2 == 1)
    if round_up {
      let mut k = frac.length() - 1
      while k >= 0 {
        if frac[k] == 9 {
          frac[k] = 0
          k -= 1
        } else {
          frac[k] = frac[k] + 1
          break
        }
      }
    }
  }
  digits.write_string(int_part.to_string())
  digits.write_char('.')
  for f in frac {
    digits.write_string(f.to_string())
  }
  digits.to_string()
}

///|
fn approxquantiles_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let num_quantiles_expr = if this.kind == Distinct {
    // APPROX_QUANTILES requires 2 args and DISTINCT node grabs both
    let exprs = this.expressions()
    if exprs.length() < 2 {
      g.unsupported("APPROX_QUANTILES requires a bucket count argument")
      return g.function_fallback_sql(e)
    }
    exprs[1].pop()
  } else {
    expr_of(e)
  }
  if num_quantiles_expr.kind != Literal || !num_quantiles_expr.is_int() {
    g.unsupported("APPROX_QUANTILES bucket count must be a positive integer")
    return g.function_fallback_sql(e)
  }
  let num_quantiles = to_int(num_quantiles_expr)
  if num_quantiles <= 0 {
    g.unsupported("APPROX_QUANTILES bucket count must be a positive integer")
    return g.function_fallback_sql(e)
  }
  let quantiles = []
  for i in 0..<=num_quantiles {
    quantiles.push(numstr(decimal_div_str(i, num_quantiles)))
  }
  g.sql(
    Some(
      @core.mk(ApproxQuantile, [
        ("this", this),
        ("quantile", @core.mk(Array, [("expressions", quantiles)])),
      ]),
    ),
  )
}

///|
fn jsonextractscalar_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut e = e
  if e.has("scalar_only") {
    let json_value = @core.mk(JSONExtractScalar, [
      ("this", @core.rename_func("JSON_VALUE")(g, e)),
      ("expression", "'$'"),
    ])
    // `->>` binds looser than most operators, so the wrap logic needs the parent
    let parent = e.parent
    e = json_value
    let mut arrow_sql = @core.arrow_json_extract_sql(g, e)
    match parent {
      Some(p) if p.kind != JSONExtractScalar &&
        p.kind.is_any([Binary, Bracket, In, Not]) =>
        arrow_sql = g.wrap_str(arrow_sql)
      _ => ()
    }
    return arrow_sql
  }
  arrow_json_extract_sql(g, e)
}

///|
fn bitwisenot_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  if is_binary(Some(this)) {
    e.set_type(Some(@core.datatype_of(BINARY)))
  }
  let mut arg = cast_to_bit(this)
  if this.kind == Neg {
    arg = @core.mk1(Paren, arg)
  }
  e.set("this", arg)
  let result_sql = "~\{g.sql_key(e, "this")}"
  gen_with_cast_to_blob(g, e, result_sql)
}

///|
fn corr_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.kind == Corr && !e.has("null_on_zero_variance") {
    return g.func("CORR", [e.this(), e.expression()])
  }
  let corr_expr = match maybe_corr_null_to_false(e) {
    Some(c) => c
    None => {
      if e.kind == Window {
        return g.window_sql(e)
      }
      if e.kind == Filter {
        return g.filter_sql(e)
      }
      e
    }
  }
  g.sql(
    Some(
      else_(
        when(case_(), @core.mk1(IsNan, corr_expr), @core.null_()),
        corr_expr,
      ),
    ),
  )
}
