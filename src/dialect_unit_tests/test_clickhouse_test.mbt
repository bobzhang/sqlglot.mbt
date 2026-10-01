// Direct assertions of tests/dialects/test_clickhouse.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestClickhouse.test_clickhouse" {
  let t = t(dialect="clickhouse")
  t
  .validate_identity(
    "SELECT col.^nested, t.col2.^nested, t.col3.^nested.twice FROM t",
  )
  .selects()[0].assert_is(NestedJSONSelect)
  |> ignore
  let expr = @optimizer.quote_identifiers(
    t.parse_one("{start_date:String}"),
    dialect=@sqlglot.dialect("clickhouse"),
  )
  t.eq(sql(expr, dialect="clickhouse"), "{start_date: String}")
  // Arrays, maps and tuples can't be Nullable in ClickHouse
  for non_nullable_type in ["ARRAY<INT>", "MAP<INT, INT>", "STRUCT(a: INT)"] {
    let try_cast = parse_one("TRY_CAST(x AS \{non_nullable_type})")
    let target_type = sql(try_cast.arg("to").unwrap(), dialect="clickhouse")
    t.eq(sql(try_cast, dialect="clickhouse"), "CAST(x AS \{target_type})")
  }
  for
    nullable_type in [
      "INT", "UINT", "BIGINT", "FLOAT", "DOUBLE", "TEXT", "DATE", "UUID",
    ] {
    let try_cast = parse_one("TRY_CAST(x AS \{nullable_type})")
    let target_type = sql(
      @sqlglot.datatype_build(nullable_type, dialect="clickhouse"),
      dialect="clickhouse",
    )
    t.eq(
      sql(try_cast, dialect="clickhouse"),
      "CAST(x AS Nullable(\{target_type}))",
    )
  }
  let expr = parse_one("count(x)")
  t.eq(sql(expr, dialect="clickhouse"), "COUNT(x)")
  t.validate_identity("@macro").assert_is(Parameter).this_().assert_is(Var)
  |> ignore
  t.validate_identity("trunc(3.14159, 2)").assert_is(Trunc) |> ignore
  t.validate_identity("trunc(3.14159)").assert_is(Trunc) |> ignore
  t.validate_identity("1 AS FORMAT").assert_is(Alias) |> ignore
  let modify = t
    .validate_identity(
      "ALTER TABLE t MODIFY COLUMN c Int64",
      write_sql="ALTER TABLE t ALTER COLUMN c TYPE Int64",
    )
    .assert_is(Alter)
  t.ok(modify.list("actions")[0].kind.is_a(AlterColumn))
  // Non-column MODIFY forms must not be routed to the ALTER COLUMN parser
  let modify_order = parse_one(
    "ALTER TABLE t MODIFY ORDER BY (a, b)",
    read="clickhouse",
  )
  t.ok(modify_order.list("actions")[0].kind.is_a(AlterModifySqlSecurity))
  t.ok(
    @sqlglot.parse_one("Tuple(select Int64)", into=DataType, read="clickhouse").kind.is_a(
      DataType,
    ),
  )
  t.validate_identity("current_timestamp").assert_is(Column) |> ignore
  t
  .validate_identity("arrayCompact([1, 1, nan, nan, 2, 3, 3, 3])")
  .assert_is(ArrayCompact)
  |> ignore
  t.validate_identity("arrayConcat([1, 2], [3, 4])").assert_is(ArrayConcat)
  |> ignore
  t.validate_identity("arrayDistinct([1, 2, 2, 3, 1])").assert_is(ArrayDistinct)
  |> ignore
  t
  .validate_identity("arrayExcept([1, 2, 3, 2, 4], [3, 5])")
  .assert_is(ArrayExcept)
  |> ignore
  t.done()
}

///|
test "TestClickhouse.test_clickhouse_values" {
  let t = t(dialect="clickhouse")
  let ast = t.parse_one("SELECT * FROM VALUES (1, 2, 3)")
  t.eq(ast.find_all([Tuple]).collect().length(), 4)
  let values = @sqlglot.select(["*"]).from_(
    @sqlglot.values([@core.PyExpr(@sqlglot.tuple_([1, 2, 3]))], alias="subq", columns=[
      "a", "b", "c",
    ]),
  )
  t.eq(
    sql(values, dialect="clickhouse"),
    "SELECT * FROM (SELECT 1 AS a, 2 AS b, 3 AS c) AS subq",
  )
  t.done()
}

///|
test "TestClickhouse.test_cte" {
  let t = t(dialect="clickhouse")
  let query = parse_one(
    "WITH (SELECT 1) AS y SELECT * FROM y",
    read="clickhouse",
  )
  let cte = query.arg("with_").unwrap().expressions()[0]
  t.ok(cte.this_().kind.is_a(Subquery))
  t.eq(cte.alias(), "y")
  let query = "WITH 1 AS var SELECT var"
  for error_level in [@core.ErrorLevel::Ignore, Raise, Immediate] {
    t.eqf(() => sql(t.parse_one(query, error_level~), dialect=t.dialect), query)
  }
  t.done()
}

///|
test "TestClickhouse.test_ternary" {
  let t = t(dialect="clickhouse")
  let ternary = parse_one("x ? (y ? 1 : 2) : 3", read="clickhouse")
  t.ok(ternary.kind.is_a(If))
  t.ok(ternary.this_().kind.is_a(Column))
  t.ok(ternary.arg("true").unwrap().kind.is_a(Paren))
  t.ok(ternary.arg("false").unwrap().kind.is_a(Literal))
  let nested_ternary = ternary.arg("true").unwrap().this_()
  t.ok(nested_ternary.this_().kind.is_a(Column))
  t.ok(nested_ternary.arg("true").unwrap().kind.is_a(Literal))
  t.ok(nested_ternary.arg("false").unwrap().kind.is_a(Literal))
  parse_one("a and b ? 1 : 2", read="clickhouse")
  .assert_is(If)
  .this_()
  .assert_is(And)
  |> ignore
  t.done()
}

///|
test "TestClickhouse.test_create_table_as_alias" {
  let t = t(dialect="clickhouse")
  let ctas_alias = "CREATE TABLE my_db.my_table AS another_db.another_table"
  let expected = @core.mk(Create, [
    ("this", @sqlglot.to_table("my_db.my_table")),
    ("kind", "TABLE"),
    ("expression", @sqlglot.to_table("another_db.another_table")),
  ])
  t.eq_expr(Some(t.parse_one(ctas_alias)), Some(expected))
  t.done()
}

///|
test "TestClickhouse.test_ddl" {
  let t = t(dialect="clickhouse")
  let db_table_expr = @core.mk(Table, [("db", @core.to_identifier("foo"))])
  let create_with_cluster = @core.mk(Create, [
    ("this", db_table_expr),
    ("kind", "DATABASE"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [@core.mk(OnCluster, [("this", @core.to_identifier("c"))])],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(create_with_cluster, dialect="clickhouse"),
    "CREATE DATABASE foo ON CLUSTER c",
  )
  // Transpiled CREATE SCHEMA may have OnCluster property set
  let create_with_cluster = @core.mk(Create, [
    ("this", db_table_expr),
    ("kind", "SCHEMA"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [@core.mk(OnCluster, [("this", @core.to_identifier("c"))])],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(create_with_cluster, dialect="clickhouse"),
    "CREATE DATABASE foo ON CLUSTER c",
  )
  let ctas_with_comment = @core.mk(Create, [
    ("this", @sqlglot.table_("foo")),
    ("kind", "TABLE"),
    ("expression", @sqlglot.select(["*"]).from_("db.other_table")),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(EngineProperty, [("this", @core.var_("Memory"))]),
            @core.mk(SchemaCommentProperty, [
              ("this", @core.literal_string("foo")),
            ]),
          ],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(ctas_with_comment, dialect="clickhouse"),
    "CREATE TABLE foo ENGINE=Memory AS (SELECT * FROM db.other_table) COMMENT 'foo'",
  )
  t.ok(
    t
    .validate_identity("CREATE TABLE t1 (a String MATERIALIZED func())")
    .find([ColumnConstraint])
    is Some(_),
  )
  t.done()
}

///|
test "TestClickhouse.test_agg_functions" {
  let t = t(dialect="clickhouse")
  let extract_agg_func = (query : String) => {
    parse_one(query, read="clickhouse").selects()[0].this_()
  }
  t
  .validate_identity(
    "SELECT quantileExactInclusive(0.25)(number) AS x FROM numbers(5)",
  )
  .selects()[0]
  .this_()
  .assert_is(ParameterizedAgg)
  |> ignore
  t.ok(
    extract_agg_func(
      "select quantileGK(100, 0.95) OVER (PARTITION BY id) FROM table",
    ).kind.is_a(AnonymousAggFunc),
  )
  t.ok(
    extract_agg_func(
      "select quantileGK(100, 0.95)(reading) OVER (PARTITION BY id) FROM table",
    ).kind.is_a(ParameterizedAgg),
  )
  t.ok(
    extract_agg_func(
      "select quantileGKIf(100, 0.95) OVER (PARTITION BY id) FROM table",
    ).kind.is_a(CombinedAggFunc),
  )
  t.ok(
    extract_agg_func(
      "select quantileGKIf(100, 0.95)(reading) OVER (PARTITION BY id) FROM table",
    ).kind.is_a(CombinedParameterizedAgg),
  )
  parse_one("foobar(x)").assert_is(Anonymous) |> ignore
  t.validate_identity("SELECT approx_top_sum(column, weight) FROM t").selects()[0].assert_is(
    AnonymousAggFunc,
  )
  |> ignore
  t
  .validate_identity("SELECT approx_top_sum(N)(column, weight) FROM t")
  .selects()[0].assert_is(ParameterizedAgg)
  |> ignore
  t
  .validate_identity(
    "SELECT approx_top_sum(N, reserved)(column, weight) FROM t",
  )
  .selects()[0].assert_is(ParameterizedAgg)
  |> ignore
  t.done()
}

///|
test "TestClickhouse.test_agg_functions_multiple_suffixes" {
  let t = t(dialect="clickhouse")
  for
    case in [
      ("SELECT uniqExactIf(x, y) FROM t", @core.Kind::CombinedAggFunc),
      ("SELECT countIfMerge(state) FROM t", CombinedAggFunc),
      ("SELECT uniqExactIfMerge(state) FROM t", CombinedAggFunc),
      ("SELECT avgArgMinIfState(x, y) FROM t", CombinedAggFunc),
      (
        "SELECT quantileIfState(0.5)(col, cond) FROM t",
        CombinedParameterizedAgg,
      ),
      ("SELECT sumMap(k, v) FROM t", AnonymousAggFunc),
      ("SELECT minMap(k, v) FROM t", AnonymousAggFunc),
      ("SELECT maxMap(k, v) FROM t", AnonymousAggFunc),
      ("SELECT sumMapIf(k, v, cond) FROM t", CombinedAggFunc),
      ("SELECT minMapIf(k, v, cond) FROM t", CombinedAggFunc),
      ("SELECT maxMapIf(k, v, cond) FROM t", CombinedAggFunc),
      ("SELECT sumMapState(k, v) FROM t", CombinedAggFunc),
      ("SELECT sumMapIfState(k, v, cond) FROM t", CombinedAggFunc),
    ] {
    let (sql, kind) = case
    t.validate_identity(sql).selects()[0].assert_is(kind) |> ignore
  }
  let sum_merge_if_merge = t
  .validate_identity(
    "SELECT sumMergeIfMerge(s) FROM (SELECT sumMergeIfState(agg, 1 = 1) AS s " +
    "FROM (SELECT sumState(toFloat64(number)) AS agg FROM numbers(10)))",
  )
  .selects()[0].assert_is(CombinedAggFunc)
  t.eq(sum_merge_if_merge.name(), "sumMergeIfMerge")
  t.done()
}

///|
test "TestClickhouse.test_convert" {
  let t = t(dialect="clickhouse")
  t.eq(
    sql(
      @core.convert(@core.PyDate(year=2020, month=1, day=1)),
      dialect=t.dialect,
    ),
    "toDate('2020-01-01')",
  )
  let dt = (microsecond : Int, tz : (String, Int)?) => {
    @core.PyDateTime(
      year=2020,
      month=1,
      day=1,
      hour=0,
      minute=0,
      second=1,
      microsecond~,
      tz~,
    )
  }
  // no fractional seconds
  t.eq(
    sql(@core.convert(dt(0, None)), dialect=t.dialect),
    "CAST('2020-01-01 00:00:01' AS DateTime64(6))",
  )
  t.eq(
    sql(@core.convert(dt(0, Some(("UTC", 0)))), dialect=t.dialect),
    "CAST('2020-01-01 00:00:01' AS DateTime64(6, 'UTC'))",
  )
  // with fractional seconds
  t.eq(
    sql(@core.convert(dt(1, None)), dialect=t.dialect),
    "CAST('2020-01-01 00:00:01.000001' AS DateTime64(6))",
  )
  t.eq(
    sql(@core.convert(dt(1, Some(("UTC", 0)))), dialect=t.dialect),
    "CAST('2020-01-01 00:00:01.000001' AS DateTime64(6, 'UTC'))",
  )
  t.done()
}

///|
test "TestClickhouse.test_timestr_to_time" {
  let t = t(dialect="clickhouse")
  let timestr_to_time = (this : String, zone : String?) => {
    let e = @core.mk(TimeStrToTime, [("this", @core.literal_string(this))])
    if zone is Some(z) {
      e.set("zone", @core.literal_string(z))
    }
    e
  }
  // no fractional seconds
  let time_strings = [
    "2020-01-01 00:00:01", "2020-01-01 00:00:01+01:00", " 2020-01-01 00:00:01-01:00 ",
    "2020-01-01T00:00:01+01:00",
  ]
  for time_string in time_strings {
    t.eq(
      sql(timestr_to_time(time_string, None), dialect=t.dialect),
      "CAST('\{time_string}' AS DateTime64(6))",
    )
  }
  let time_strings_no_utc = Array::make(4, "2020-01-01 00:00:01")
  for i, utc in time_strings {
    t.eq(
      sql(timestr_to_time(utc, Some("UTC")), dialect=t.dialect),
      "CAST('\{time_strings_no_utc[i]}' AS DateTime64(6, 'UTC'))",
    )
  }
  // with fractional seconds
  let time_strings = [
    "2020-01-01 00:00:01.001", "2020-01-01 00:00:01.000001", "2020-01-01 00:00:01.001+00:00",
    "2020-01-01 00:00:01.000001-00:00", "2020-01-01 00:00:01.0001", "2020-01-01 00:00:01.1+00:00",
  ]
  for time_string in time_strings {
    // (sic) `time_string[0]` in Python: the first character
    let first = time_string.unsafe_substring(start=0, end=1)
    t.eq(
      sql(timestr_to_time(first, None), dialect=t.dialect),
      "CAST('\{first}' AS DateTime64(6))",
    )
  }
  let time_strings_no_utc = [
    "2020-01-01 00:00:01.001000", "2020-01-01 00:00:01.000001", "2020-01-01 00:00:01.001000",
    "2020-01-01 00:00:01.000001", "2020-01-01 00:00:01.000100", "2020-01-01 00:00:01.100000",
  ]
  for i, utc in time_strings {
    t.eq(
      sql(timestr_to_time(utc, Some("UTC")), dialect=t.dialect),
      "CAST('\{time_strings_no_utc[i]}' AS DateTime64(6, 'UTC'))",
    )
  }
  t.done()
}

///|
test "TestClickhouse.test_array_join" {
  let t = t(dialect="clickhouse")
  let expr = t.validate_identity(
    "SELECT * FROM arrays_test ARRAY JOIN arr1, arrays_test.arr2 AS foo, ['a', 'b', 'c'] AS elem",
  )
  let joins = expr.list("joins")
  t.eq(joins.length(), 1)
  let join = joins[0]
  t.eq(join.text("kind"), "ARRAY")
  t.ok(join.this_().kind.is_a(Column))
  t.eq(join.expressions().length(), 2)
  t.ok(join.expressions()[0].kind.is_a(Alias))
  t.ok(join.expressions()[0].this_().kind.is_a(Column))
  t.ok(join.expressions()[1].kind.is_a(Alias))
  t.ok(join.expressions()[1].this_().kind.is_a(Array))
  t.done()
}

///|
test "TestClickhouse.test_traverse_scope" {
  let t = t(dialect="clickhouse")
  let sql = "SELECT * FROM t FINAL"
  let scopes = @optimizer.traverse_scope(parse_one(sql, read=t.dialect))
  t.eq(scopes.length(), 1)
  t.eq(scopes[0].sources.keys().collect().join(","), "t")
  t.done()
}

///|
test "TestClickhouse.test_groupconcat" {
  let t = t(dialect="clickhouse")
  // groupConcat(sep)(col) - parametric form with separator
  let parsed = t.validate_identity(
    "SELECT groupConcat(', ')(part_name) FROM system.parts",
  )
  let gc = parsed.selects()[0]
  t.ok(gc.kind.is_a(GroupConcat))
  t.eq(gc.this_().name(), "part_name")
  t.eq(gc.arg("separator").unwrap().name(), ", ")
  // groupConcat(col) - no separator
  let parsed2 = t.validate_identity("SELECT groupConcat(part_name) FROM t")
  let gc2 = parsed2.selects()[0]
  t.ok(gc2.kind.is_a(GroupConcat))
  t.eq(gc2.this_().name(), "part_name")
  t.ok(gc2.get("separator") is None)
  // groupConcat(sep, limit)(col) - with limit
  let parsed3 = t.validate_identity(
    "SELECT groupConcat(', ', 2)(part_name) FROM t",
  )
  let gc3 = parsed3.selects()[0]
  t.ok(gc3.kind.is_a(GroupConcat))
  t.ok(gc3.this_().kind.is_a(Limit))
  t.eq(gc3.this_().this_().name(), "part_name")
  // Combinators are preserved as CombinedAggFunc / CombinedParameterizedAgg
  t.validate_identity("SELECT groupConcatIf(x, cond) FROM t").selects()[0].assert_is(
    CombinedAggFunc,
  )
  |> ignore
  t.validate_identity("SELECT groupConcatIf(', ')(x, cond) FROM t").selects()[0].assert_is(
    CombinedParameterizedAgg,
  )
  |> ignore
  t.done()
}

///|
test "TestClickhouse.test_array_offset" {
  let t = t(dialect="clickhouse")
  let output = t.assert_logs(() => {
    t.validate_all("SELECT col[1]", write={
      "bigquery": "SELECT col[0]",
      "duckdb": "SELECT col[1]",
      "hive": "SELECT col[0]",
      "clickhouse": "SELECT col[1]",
      "presto": "SELECT col[1]",
    })
  })
  t.eq(output, [
    "INFO:sqlglot:Applying array index offset (-1)", "INFO:sqlglot:Applying array index offset (1)",
    "INFO:sqlglot:Applying array index offset (1)", "INFO:sqlglot:Applying array index offset (1)",
  ])
  t.done()
}

///|
test "TestClickhouse.test_functions" {
  let t = t(dialect="clickhouse")
  t.is_a(Some(t.validate_identity("arrayMap(x -> x + 1, arr)")), Transform)
  |> ignore
  t.is_a(Some(t.validate_identity("arrayFilter(x -> x > 0, arr)")), ArrayFilter)
  |> ignore
  t.is_a(
    t
    .validate_identity(
      "SELECT arrayMap((a, b) -> a * b, [1, 2, 3], [10, 20, 30]) AS products",
    )
    .expressions()[0].this(),
    Anonymous,
  )
  |> ignore
  t.is_a(
    Some(t.validate_identity("arrayFilter((x, y) -> y, [1, 2, 3], [1, 0, 1])")),
    Anonymous,
  )
  |> ignore
  t.done()
}

///|
test "TestClickhouse.test_refreshable_materialized_view" {
  let t = t(dialect="clickhouse")
  let statements = [
    "CREATE MATERIALIZED VIEW v REFRESH EVERY 30 SECOND AS SELECT 1", "CREATE MATERIALIZED VIEW v REFRESH AFTER 5 MINUTE AS SELECT 1",
    "CREATE MATERIALIZED VIEW v REFRESH DEPENDS ON db.x, db.y APPEND TO db.t AS SELECT 1",
    "CREATE MATERIALIZED VIEW v ON CLUSTER '{cluster}' REFRESH EVERY 1 MONTH OFFSET 5 DAY 2 HOUR RANDOMIZE FOR 1 HOUR DEPENDS ON db.x, db.y SETTINGS refresh_retries = 5 APPEND TO db.t AS SELECT 1",
    "CREATE MATERIALIZED VIEW v REFRESH EVERY 1 HOUR (id UInt64) AS SELECT 1 AS id",
    "CREATE MATERIALIZED VIEW v REFRESH DEPENDS ON dep (id UInt64) AS SELECT 1",
  ]
  for statement in statements {
    t.is_a(Some(t.validate_identity(statement)), Create) |> ignore
  }
  t.is_a(
    Some(t.validate_identity("CREATE MATERIALIZED VIEW v TO db.t AS SELECT 1")),
    Create,
  )
  |> ignore
  t.is_a(
    Some(
      t.validate_identity(
        "CREATE MATERIALIZED VIEW v REFRESH AS SELECT 1",
        check_command_warning=true,
      ),
    ),
    Command,
  )
  |> ignore
  t.done()
}
