// Black-box tests of the dialect helpers (expected values from Python sqlglot).

///|
fn gen_base() -> @core.Generator {
  @core.Generator::new(@core.base_dialect())
}

///|
fn run_helper(sql : String, f : @core.GenFn) -> String raise {
  f(gen_base(), @core.parse_one(sql))
}

///|
fn group_concat_expr() -> @core.Expr {
  let order = @core.mk(Order, [
    ("this", @core.column_of("x")),
    ("expressions", [@core.mk1(Ordered, @core.column_of("y"))]),
  ])
  @core.mk(GroupConcat, [
    ("this", order),
    ("separator", @core.literal_string("-")),
  ])
}

///|
test "dialect helpers: generator helpers" {
  inspect(
    run_helper("SUBSTRING(a, 1, 2)", @core.rename_func("FOO")),
    content="FOO(a, 1, 2)",
  )
  inspect(
    run_helper("STR_POSITION(a, 'x', 3)", (g, e) => @core.strposition_sql(g, e)),
    content="CASE WHEN STRPOS(SUBSTRING(a, 3), 'x') = 0 THEN 0 ELSE STRPOS(SUBSTRING(a, 3), 'x') + 3 - 1 END",
  )
  inspect(
    run_helper("STR_POSITION(a, 'x', 3)", (g, e) => @core.strposition_sql(
      g,
      e,
      func_name="LOCATE",
      supports_position=true,
    )),
    content="LOCATE('x', a, 3)",
  )
  inspect(
    run_helper("STR_POSITION(a, 'x')", (g, e) => @core.strposition_sql(
      g,
      e,
      func_name="POSITION",
    )),
    content="POSITION('x' IN a)",
  )
  inspect(
    run_helper("MONTHS_BETWEEN(a, b)", @core.months_between_sql),
    content="DATEDIFF(CAST(a AS DATE), CAST(b AS DATE), MONTH) + CASE WHEN DAY(CAST(a AS DATE)) = DAY(LAST_DAY(CAST(a AS DATE))) AND DAY(CAST(b AS DATE)) = DAY(LAST_DAY(CAST(b AS DATE))) THEN 0 ELSE (DAY(CAST(a AS DATE)) - DAY(CAST(b AS DATE))) / 31.0 END",
  )
  inspect(
    run_helper(
      "GENERATE_SERIES(CAST('2020-01-01' AS DATE), x, INTERVAL '1' DAY)",
      @core.sequence_sql,
    ),
    content="SEQUENCE(CAST('2020-01-01' AS DATE), CAST(x AS DATE), INTERVAL '1' DAY)",
  )
  inspect(
    @core.groupconcat_sql(gen_base(), group_concat_expr()),
    content="LISTAGG(x, '-') WITHIN GROUP (ORDER BY y NULLS LAST)",
  )
  inspect(
    @core.groupconcat_sql(gen_base(), group_concat_expr(), within_group=false),
    content="LISTAGG(x, '-' ORDER BY y NULLS LAST)",
  )
  inspect(
    run_helper("ARRAY_CONCAT(a, b, c)", @core.array_concat_sql("ARRAY_CAT")),
    content="ARRAY_CAT(a, b, c)",
  )
  let concat = @core.parse_one("ARRAY_CONCAT(a, b, c)")
  concat.set("null_propagation", true)
  inspect(
    @core.array_concat_sql("ARRAY_CAT")(gen_base(), concat),
    content="CASE WHEN a IS NULL OR b IS NULL OR c IS NULL THEN NULL ELSE ARRAY_CAT(a, b, c) END",
  )
  inspect(
    run_helper("MAKE_INTERVAL(1, 2)", (g, e) => @core.no_make_interval_sql(g, e)),
    content="INTERVAL '1 year, 2 month'",
  )
  inspect(
    run_helper("TRIM(BOTH 'x' FROM y)", (g, e) => @core.trim_sql(g, e)),
    content="TRIM(BOTH 'x' FROM y)",
  )
  inspect(
    run_helper("a ILIKE 'x'", @core.no_ilike_sql),
    content="LOWER(a) LIKE LOWER('x')",
  )
  inspect(
    run_helper("MAP(ARRAY(1, 2), ARRAY(3, 4))", (g, e) => @core.var_map_sql(g, e)),
    content="MAP(1, 3, 2, 4)",
  )
  inspect(
    run_helper("RIGHT(a, 3)", @core.right_to_substring_sql),
    content="SUBSTRING(a, LENGTH(a) - (3 - 1))",
  )
  inspect(
    run_helper("LEFT(a, 3)", @core.left_to_substring_sql),
    content="SUBSTRING(a, 1, 3)",
  )
  inspect(
    run_helper("FILTER(arr, x -> x > 1)", @core.filter_array_using_unnest),
    content="ARRAY(SELECT x FROM UNNEST(arr) AS _t0(x) WHERE x > 1)",
  )
  inspect(
    run_helper("ARRAY_COMPACT(arr)", @core.array_compact_sql),
    content="FILTER(arr, _u -> NOT _u IS NULL)",
  )
  inspect(
    run_helper("COUNT_IF(x > 1)", @core.count_if_to_sum),
    content="SUM(CASE WHEN x > 1 THEN 1 ELSE 0 END)",
  )
  inspect(
    run_helper("CONCAT_WS('-', a, b, c)", @core.concat_ws_to_dpipe_sql),
    content="a || '-' || b || '-' || c",
  )
  inspect(run_helper("GETBIT(a, 2)", @core.getbit_sql), content="GET_BIT(a, 2)")
  inspect(
    run_helper("JAROWINKLER_SIMILARITY(a, b)", @core.jarowinkler_similarity("JW")),
    content="JW(a, b)",
  )
  inspect(
    run_helper("IF(a, b)", @core.if_sql_str("NULL")),
    content="IF(a, b, NULL)",
  )
  inspect(
    run_helper("JSON_EXTRACT(x, '$.a')", (g, e) => @core.arrow_json_extract_sql(g, e)),
    content="x -> '$.a'",
  )
  inspect(
    run_helper("JSON_EXTRACT(x, '$.a[0].b')", @core.json_extract_segments("JE")),
    content="JE(x, '$', '.a', '[0]', '.b')",
  )
  inspect(
    run_helper(
      "JSON_EXTRACT(x, '$.a[0].b')",
      @core.json_extract_segments("JE", op="->"),
    ),
    content="x -> '$' -> '.a' -> '[0]' -> '.b'",
  )
  inspect(
    run_helper("REGEXP_EXTRACT(a, 'x', 0)", @core.regexp_extract_sql),
    content="REGEXP_EXTRACT(a, 'x')",
  )
  let lateral = @core.parse_one(
    "SELECT * FROM x LATERAL VIEW POSEXPLODE(y) t AS pos, col",
  ).find([Lateral]).unwrap()
  inspect(
    @core.explode_to_unnest_sql(gen_base(), lateral),
    content=" CROSS JOIN LATERAL (SELECT pos - 1 AS pos, col FROM UNNEST(y) WITH ORDINALITY AS t(col, pos))",
  )
  let lateral = @core.parse_one("SELECT * FROM x LATERAL VIEW EXPLODE(y) t AS col")
    .find([Lateral])
    .unwrap()
  inspect(
    @core.explode_to_unnest_sql(gen_base(), lateral),
    content=" CROSS JOIN UNNEST(y) AS t(col)",
  )
}

///|
test "dialect helpers: date and time" {
  inspect(
    run_helper("DATE_ADD(x, 1, 'month')", @core.date_delta_sql("DATEADD")),
    content="DATEADD(MONTH, 1, x)",
  )
  inspect(
    run_helper(
      "DATE_ADD('2020-01-01', 1, 'month')",
      @core.date_delta_to_binary_interval_op(),
    ),
    content="CAST('2020-01-01' AS DATE) + INTERVAL 1 MONTH",
  )
  let g = gen_base()
  inspect(
    g.sql(@core.unit_to_var(@core.parse_one("DATE_ADD(x, 1, 'month')"))),
    content="MONTH",
  )
  inspect(
    g.sql(@core.unit_to_str(@core.parse_one("DATE_ADD(x, 1)"))),
    content="'DAY'",
  )
  inspect(
    @core.unit_to_str(@core.parse_one("DATE_ADD(x, 1)"), default="") is None,
    content="true",
  )
  inspect(
    run_helper("TIMESTAMP(x, 'America/New_York')", @core.no_timestamp_sql),
    content="CAST(x AS TIMESTAMP) AT TIME ZONE 'America/New_York'",
  )
  inspect(
    run_helper("DATETIME(x, y)", @core.no_datetime_sql),
    content="CAST(CAST(x AS DATE) + CAST(y AS TIME) AS TIMESTAMP)",
  )
  inspect(
    run_helper("TIME_STR_TO_TIME('2020-01-01 12:13:14.123')", (g, e) => @core.timestrtotime_sql(
      g,
      e,
      include_precision=true,
    )),
    content="CAST('2020-01-01 12:13:14.123' AS TIMESTAMP(3))",
  )
  inspect(
    run_helper("LAST_DAY(x)", @core.no_last_day_sql),
    content="CAST(DATE_SUB(DATE_ADD(DATE_TRUNC('MONTH', x), 1, 'MONTH'), 1, DAY) AS DATE)",
  )
  inspect(
    run_helper("TIMESTAMP_TRUNC(x, DAY)", @core.timestamptrunc_sql()),
    content="DATE_TRUNC('DAY', x)",
  )
  inspect(
    g.sql(@core.map_date_part(Some(@core.parse_one("dd")))),
    content="DAY",
  )
  inspect(
    g.sql(@core.map_date_part(Some(@core.parse_one("'yy'")))),
    content="'YEAR'",
  )
  inspect(@core.week_offset_to_dow(-1), content="7")
  inspect(
    @core.week_unit_to_dow(Some(@core.var_("ISOWEEK"))).unwrap_or(0),
    content="1",
  )
  let precisions = [
    "2023-01-01 12:13:14.123456+00:00", "2023-01-01 12:13:14.12", "2023-01-01", "2023-01-01T12:13:14.1000",
    "bad", "2023-02-30 12:00:00.1", "20230101T121314.5", "2023-01-01 12:13:14.1234567Z",
  ].map(@core.subsecond_precision)
  debug_inspect(precisions, content="[6, 3, 0, 3, 0, 0, 3, 6]")
  inspect(@core.timezones.contains("america/new_york"), content="true")
}

///|
test "dialect helpers: parser builders" {
  let p = @core.Parser::new(@core.base_dialect())
  let g = gen_base()
  let args = [@core.parse_one("x")]
  inspect(
    g.sql(Some(@core.build_formatted_time(StrToTime, default=true)(args, p))),
    content="STR_TO_TIME(x, '%Y-%m-%d %H:%M:%S')",
  )
  let args = [
    @core.parse_one("'month'"),
    @core.parse_one("1"),
    @core.parse_one("x"),
  ]
  inspect(
    g.sql(Some(@core.build_date_delta(DateAdd)(args, p))),
    content="DATE_ADD(x, 1, 'MONTH')",
  )
  let args = [@core.parse_one("x"), @core.parse_one("'a'"), @core.parse_one("1")]
  inspect(
    g.sql(Some(@core.build_json_extract_path(JSONExtract)(args, p))),
    content="JSON_EXTRACT(x, '$.a[1]')",
  )
  inspect(args.length(), content="2")
  inspect(
    @core.pivot_column_names(
      [@core.parse_one("AVG(\"foo\")"), @core.parse_one("SUM(x) AS s")],
      @core.base_dialect(),
    ).join(","),
    content="avg(foo),s",
  )
}
