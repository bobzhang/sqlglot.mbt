// Direct assertions of tests/dialects/test_duckdb.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestDuckDB.test_duckdb" {
  let t = t(dialect="duckdb")
  t.validate_identity("TRUNC(3.14)").assert_is(Trunc) |> ignore
  t.raises(() => ignore(parse_one("1 //", read="duckdb")), "ParseError")
  |> ignore
  let expr = @optimizer.annotate_types(
    t.validate_identity(
      "WITH _data AS (SELECT [{'a': 1, 'b': 2}, {'a': 2, 'b': 3}] AS col) SELECT t.col['b'] FROM _data, UNNEST(_data.col) AS t(col) WHERE t.col['a'] = 1",
      write_sql="WITH _data AS (SELECT [{'a': 1, 'b': 2}, {'a': 2, 'b': 3}] AS col) SELECT t.col['b'] FROM _data JOIN UNNEST(_data.col) AS t(col) ON TRUE WHERE t.col['a'] = 1",
    ),
  )
  t.eq(
    sql(expr, dialect="bigquery"),
    "WITH _data AS (SELECT [STRUCT(1 AS a, 2 AS b), STRUCT(2 AS a, 3 AS b)] AS col) SELECT col.b FROM _data, UNNEST(_data.col) AS col WHERE col.a = 1",
  )
  let struct_array_type = @sqlglot.maybe_parse(
    "STRUCT(k TEXT, v STRUCT(v_str TEXT, v_int INT, v_int_arr INT[]))[]",
    into=[DataType],
    dialect="duckdb",
  )
  t.eq(
    sql(struct_array_type, dialect="duckdb"),
    "STRUCT(k TEXT, v STRUCT(v_str TEXT, v_int INT, v_int_arr INT[]))[]",
  )
  t.eq(
    sql(parse_one("select * from t limit (select 5)"), dialect="duckdb"),
    sql(
      @sqlglot.select(["*"])
      .from_("t")
      .limit_(@sqlglot.select(["5"]).subquery()),
      dialect="duckdb",
    ),
  )
  t.eq(
    sql(parse_one("select * from t offset (select 5)"), dialect="duckdb"),
    sql(
      @sqlglot.select(["*"])
      .from_("t")
      .offset_(@sqlglot.select(["5"]).subquery()),
      dialect="duckdb",
    ),
  )
  t.eq(
    sql(parse_one("a / b", read="duckdb").assert_is(Div), dialect="duckdb"),
    "a / b",
  )
  t.eq(
    sql(parse_one("a // b", read="duckdb").assert_is(IntDiv), dialect="duckdb"),
    "a // b",
  )
  t.validate_identity("SELECT UNNEST([1, 2])").selects()[0].assert_is(UDTF)
  |> ignore
  t.validate_identity("'red' IN flags").arg("field").unwrap().assert_is(Column)
  |> ignore
  t.validate_identity("SUMMARIZE tbl").assert_is(Summarize) |> ignore
  t.validate_identity("SUMMARIZE SELECT * FROM tbl").assert_is(Summarize)
  |> ignore
  t
  .validate_identity("UNION_VALUE(k1 := 1)")
  .find([PropertyEQ])
  .unwrap()
  .this_()
  .assert_is(Identifier)
  |> ignore
  t
  .validate_identity(
    "SUMMARIZE TABLE 'https://blobs.duckdb.org/data/Star_Trek-Season_1.csv'",
  )
  .assert_is(Summarize)
  |> ignore
  t
  .validate_identity("DATE_SUB('YEAR', col, '2020-01-01')")
  .assert_is(Anonymous)
  |> ignore
  t.validate_identity("DATESUB('YEAR', col, '2020-01-01')").assert_is(Anonymous)
  |> ignore
  t.validate_identity("a @> b").assert_is(ArrayContainsAll) |> ignore
  t.validate_identity("a <@ b").assert_is(ArrayContainedBy) |> ignore
  t.validate_identity("a && b").assert_is(ArrayOverlaps) |> ignore
  t.eq(
    sql(
      @optimizer.annotate_types(t.parse_one("LOWER('HELLO')")),
      dialect="duckdb",
    ),
    "LOWER('HELLO')",
  )
  t.eq(
    sql(
      @optimizer.annotate_types(t.parse_one("UPPER('hello')")),
      dialect="duckdb",
    ),
    "UPPER('hello')",
  )
  t.eq(
    sql(
      @optimizer.annotate_types(
        t.parse_one("SELECT REPLACE('apple pie', 'pie', 'cobbler') AS result"),
      ),
      dialect="duckdb",
    ),
    "SELECT REPLACE('apple pie', 'pie', 'cobbler') AS result",
  )
  t.eq(
    sql(
      @optimizer.annotate_types(
        t.parse_one("SELECT TRIM('***apple***', '*') AS result"),
      ),
      dialect="duckdb",
    ),
    "SELECT TRIM('***apple***', '*') AS result",
  )
  t
  .validate_identity("CURRENT_LOCALTIMESTAMP()", write_sql="LOCALTIMESTAMP")
  .assert_is(Localtimestamp)
  |> ignore
  t.validate_identity("SELECT file[:256] FROM GLOB('*')").selects()[0]
  .this_()
  .assert_is(Column)
  |> ignore
  t.validate_identity("SELECT file[256] FROM GLOB('*')").selects()[0]
  .this_()
  .assert_is(Column)
  |> ignore
  t.done()
}

///|
test "TestDuckDB.test_array_index" {
  let t = t(dialect="duckdb")
  let output = t.assert_logs(() => {
    t.validate_all(
      "SELECT some_arr[1] AS first FROM blah",
      read={ "bigquery": "SELECT some_arr[0] AS first FROM blah" },
      write={
        "bigquery": "SELECT some_arr[0] AS first FROM blah",
        "duckdb": "SELECT some_arr[1] AS first FROM blah",
        "presto": "SELECT some_arr[1] AS first FROM blah",
      },
    )
    t.validate_identity(
      "[x.STRING_SPLIT(' ')[i] FOR x IN ['1', '2', 3] IF x.CONTAINS('1')]",
    )
    |> ignore
    t.validate_identity(
      "SELECT [4, 5, 6] AS l, [x FOR x, i IN l IF i = 2] AS filtered",
    )
    |> ignore
    t.validate_identity("SELECT LIST_VALUE(1)[i]", write_sql="SELECT [1][i]")
    |> ignore
    t.validate_identity("{'x': LIST_VALUE(1)[i]}", write_sql="{'x': [1][i]}")
    |> ignore
    t.validate_identity(
      "SELECT LIST_APPLY(RANGE(1, 4), i -> {'f1': LIST_VALUE(1, 2, 3)[i], 'f2': LIST_VALUE(1, 2, 3)[i]})",
      write_sql="SELECT LIST_APPLY(RANGE(1, 4), i -> {'f1': [1, 2, 3][i], 'f2': [1, 2, 3][i]})",
    )
    |> ignore
  })
  t.eq(output, [
    "INFO:sqlglot:Applying array index offset (-1)", "INFO:sqlglot:Applying array index offset (1)",
    "INFO:sqlglot:Applying array index offset (1)", "INFO:sqlglot:Applying array index offset (1)",
  ])
  t.done()
}

///|
test "TestDuckDB.test_timestamp_from_parts" {
  let t = t(dialect="duckdb")
  for
    case in [
      (
        "SELECT TIMESTAMP_FROM_PARTS(2019, 1, 10, 2, 3, 4, 0, 'America/Los_Angeles')",
        "SELECT MAKE_TIMESTAMP(2019, 1, 10, 2, 3, 4 + (0 / 1000000000.0)) AT TIME ZONE 'America/Los_Angeles'",
        @core.DType::TIMESTAMPTZ,
      ),
      (
        "SELECT TIMESTAMP_FROM_PARTS(2019, 7, 10, 2, 3, 4, 123456000, 'America/Los_Angeles')",
        "SELECT MAKE_TIMESTAMP(2019, 7, 10, 2, 3, 4 + (123456000 / 1000000000.0)) AT TIME ZONE 'America/Los_Angeles'",
        TIMESTAMPTZ,
      ),
      (
        "SELECT TIMESTAMP_FROM_PARTS(2019, 1, 10, 2, 3, 4, ns, tz) FROM (VALUES (123456000, 'America/Los_Angeles'), (NULL, 'UTC'), (0, NULL)) AS t(ns, tz)",
        "SELECT MAKE_TIMESTAMP(2019, 1, 10, 2, 3, 4 + (ns / 1000000000.0)) AT TIME ZONE tz FROM (VALUES (123456000, 'America/Los_Angeles'), (NULL, 'UTC'), (0, NULL)) AS t(ns, tz)",
        TIMESTAMPTZ,
      ),
      (
        "SELECT TIMESTAMP_FROM_PARTS(2019, 1, 10, 2, 3, 4, 123456000)",
        "SELECT MAKE_TIMESTAMP(2019, 1, 10, 2, 3, 4 + (123456000 / 1000000000.0))",
        TIMESTAMP,
      ),
    ] {
    let (source, target, dtype) = case
    for pair in [("snowflake", source), ("duckdb", target)] {
      let (dialect, sql) = pair
      let expression = @optimizer.annotate_types(
        parse_one(sql, read=dialect),
        dialect=@sqlglot.dialect(dialect),
      )
      t.eq_expr(
        expression.selects()[0].get_type(),
        Some(@core.datatype_of(dtype)),
      )
    }
  }
  t.done()
}

///|
test "TestDuckDB.test_iceberg_property_no_warning" {
  let t = t(dialect="duckdb")
  let expression = parse_one("CREATE ICEBERG TABLE t (a INT)", read="snowflake")
  @core.take_log_messages() |> ignore
  t.eq(sql(expression, dialect="duckdb"), "CREATE TABLE t (a INT)")
  // logger.warning was not called
  t.eq(captured_logs(level="WARNING"), [])
  t.done()
}

///|
test "TestDuckDB.test_non_iceberg_property_still_warns" {
  let t = t(dialect="duckdb")
  let expression = parse_one(
    "CREATE TRANSIENT TABLE t (a INT)",
    read="snowflake",
  )
  let output = t.assert_logs(() => {
    t.eq(sql(expression, dialect="duckdb"), "CREATE TABLE t (a INT)")
  })
  t.eq(output[0], "WARNING:sqlglot:Unsupported property transientproperty")
  t.done()
}

///|
test "TestDuckDB.test_ignore_nulls" {
  let t = t(dialect="duckdb")
  // DuckDB.Generator.IGNORE_RESPECT_NULLS_WINDOW_FUNCTIONS
  let window_funcs : Array[@core.Kind] = [
    FirstValue,
    Lag,
    LastValue,
    Lead,
    NthValue,
  ]
  let agg_funcs : Array[@core.Kind] = [Sum, Max, Min]
  for func_type in window_funcs + agg_funcs {
    let func = @core.mk(func_type, [("this", @core.to_identifier("col"))])
    let ignore_null = @core.mk(IgnoreNulls, [("this", func)])
    let windowed_ignore_null = @core.mk(Window, [("this", ignore_null)])
    if window_funcs.contains(func_type) {
      t.contains(sql(windowed_ignore_null, dialect="duckdb"), "IGNORE NULLS")
    } else {
      let output = t.assert_logs(() => {
        t.eq(sql(ignore_null, dialect="duckdb"), sql(func, dialect="duckdb"))
        t.not_contains(
          sql(windowed_ignore_null, dialect="duckdb"),
          "IGNORE NULLS",
        )
      })
      t.eq(
        output[0],
        "WARNING:sqlglot:IGNORE NULLS is not supported for non-window functions.",
      )
    }
  }
  t.done()
}

///|
test "TestDuckDB.test_install" {
  let t = t(dialect="duckdb")
  let ast = t.validate_identity("INSTALL httpfs")
  ast.assert_is(Install) |> ignore
  t.ok(ast.this_().kind == Identifier)
  t.validate_identity("FORCE INSTALL httpfs").assert_is(Install) |> ignore
  t.done()
}

///|
test "TestDuckDB.test_udf" {
  let t = t(dialect="duckdb")
  for keyword in ["FUNCTION", "MACRO"] {
    t
    .validate_identity(
      "CREATE \{keyword} my_table_function(a, b) AS TABLE SELECT x, y FROM (VALUES (a, b)) AS tbl(x, y)",
    )
    .assert_is(Create)
    |> ignore
  }
  let overloaded = t.validate_identity(
    "CREATE MACRO add_x (a, b) AS a + b, (a, b, c) AS a + b + c",
  )
  let overloads = overloaded.expression_()
  t.ok(overloads.kind.is_a(MacroOverloads))
  t.eq(overloads.expressions().length(), 2)
  t.ok(overloaded.this_().get("expressions") is None)
  t.done()
}

///|
test "TestDuckDB.test_approx_percentile" {
  let t = t(dialect="duckdb")
  let expr = @optimizer.annotate_types(
    parse_one(
      "SELECT APPROX_PERCENTILE(CAST(a AS DOUBLE), 0.5) FROM t",
      read="snowflake",
    ),
  )
  t.eq(
    sql(expr, dialect="duckdb"),
    "SELECT CAST(APPROX_QUANTILE(CAST(a AS DOUBLE), 0.5) AS DOUBLE) FROM t",
  )
  t.done()
}

///|
test "TestDuckDB.test_map_pick" {
  let t = t(dialect="duckdb")
  let snowflake = @sqlglot.dialect("snowflake")
  let sql_ = "SELECT MAP_PICK(t.t_map, t.t_key) FROM t"
  let annotated = @optimizer.annotate_types(
    parse_one(sql_, read="snowflake"),
    schema=d_schema(
      "{\"t\": {\"t_map\": \"MAP(VARCHAR, INT)\", \"t_key\": \"VARCHAR\"}}",
      dialect="snowflake",
    ),
    dialect=snowflake,
  )
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SELECT MAP_FROM_ENTRIES(LIST_FILTER(MAP_ENTRIES(t.t_map), x -> x.key IN (t.t_key))) FROM t",
  )
  let annotated = @optimizer.annotate_types(
    parse_one(sql_, read="snowflake"),
    schema=d_schema(
      "{\"t\": {\"t_map\": \"MAP(VARCHAR, INT)\", \"t_key\": \"ARRAY(VARCHAR)\"}}",
      dialect="snowflake",
    ),
    dialect=snowflake,
  )
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SELECT MAP_FROM_ENTRIES(LIST_FILTER(MAP_ENTRIES(t.t_map), x -> ARRAY_CONTAINS(t.t_key, x.key))) FROM t",
  )
  let sql_ = "SELECT MAP_PICK(t.t_map, t.t_key1, t.t_key2) FROM t"
  let annotated = @optimizer.annotate_types(
    parse_one(sql_, read="snowflake"),
    schema=d_schema(
      "{\"t\": {\"t_map\": \"MAP(VARCHAR, INT)\", \"t_key1\": \"VARCHAR\", \"t_key2\": \"VARCHAR\"}}",
      dialect="snowflake",
    ),
    dialect=snowflake,
  )
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SELECT MAP_FROM_ENTRIES(LIST_FILTER(MAP_ENTRIES(t.t_map), x -> x.key IN (t.t_key1, t.t_key2))) FROM t",
  )
  t.done()
}

///|
test "TestDuckDB.test_map_insert" {
  let t = t(dialect="duckdb")
  t.eq(
    sql(
      @optimizer.annotate_types(
        parse_one(
          "SELECT MAP_INSERT(my_map, 'key', 42) FROM my_table",
          read="snowflake",
        ),
        dialect=@sqlglot.dialect("snowflake"),
      ),
      dialect="duckdb",
    ),
    "SELECT MAP_CONCAT(my_map, MAP {'key': 42}) FROM my_table",
  )
  t.done()
}

///|
test "TestDuckDB.test_show_tables" {
  let t = t(dialect="duckdb")
  for
    sql in [
      "SHOW TABLES", "SHOW TABLES FROM my_schema", "SHOW TABLES FROM my_database",
      "SHOW TABLES FROM my_database.my_schema", "SHOW ALL TABLES",
    ] {
    t.is_a(Some(t.validate_identity(sql)), Show) |> ignore
  }
  t.done()
}
