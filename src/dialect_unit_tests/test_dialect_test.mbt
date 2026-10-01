// Direct assertions of tests/dialects/test_dialect.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).
// SKIP: TestDialect.test_lazy_load (runs a Python subprocess).

///|
test "TestDialect.test_enum" {
  let t = t()
  // the values of Python's `Dialects` enum
  for
    dialect in [
      "", "athena", "bigquery", "clickhouse", "databricks", "dax", "doris", "dremio",
      "drill", "druid", "duckdb", "dune", "fabric", "hive", "materialize", "mysql",
      "oracle", "postgres", "presto", "prql", "redshift", "risingwave", "snowflake",
      "solr", "spark", "spark2", "sqlite", "starrocks", "tableau", "teradata", "trino",
      "tsql", "exasol",
    ] {
    // Dialect[dialect], Dialect.get(dialect)
    t.ok(
      @core.get_dialect(dialect) is Some(_),
      msg="Dialect[\{dialect}] is None",
    )
    t.ok(
      (try? @core.Dialect::get_or_raise(dialect)) is Ok(_),
      msg="get_or_raise(\{dialect}) failed",
    )
    // dialect in Dialect.classes
    t.ok(@core.dialect_names().contains(dialect) || dialect == "")
  }
  t.done()
}

///|
test "TestDialect.test_get_or_raise" {
  let t = t()
  // SKIP: get_or_raise(Hive) / get_or_raise(Hive()) / get_or_raise(1): the port only
  // looks dialects up by name.
  t.eq(@core.Dialect::get_or_raise("hive").name, "hive")
  let default_mysql = @core.Dialect::get_or_raise("mysql")
  t.ok(default_mysql.normalization_strategy is CaseSensitive)
  let lowercase_mysql = @core.Dialect::get_or_raise(
    "mysql,normalization_strategy=lowercase",
  )
  t.ok(lowercase_mysql.normalization_strategy is Lowercase)
  let lowercase_mysql = @core.Dialect::get_or_raise(
    "mysql, normalization_strategy = lowercase",
  )
  t.ok(lowercase_mysql.normalization_strategy is Lowercase)
  // KNOWN DIFFERENCE: Python raises AttributeError; the port has no such error class
  // and raises a ValueError with the same message.
  t.raises(
    () => ignore(@core.Dialect::get_or_raise("mysql, normalization_strategy")),
    "ValueError",
    message="'bool' object has no attribute 'upper'",
  )
  |> ignore
  t.raises(
    () => ignore(@core.Dialect::get_or_raise("myqsl")),
    "ValueError",
    message="Unknown dialect 'myqsl'. Did you mean mysql?",
  )
  |> ignore
  t.raises(
    () => ignore(@core.Dialect::get_or_raise("asdfjasodiufjsd")),
    "ValueError",
    message="Unknown dialect 'asdfjasodiufjsd'.",
  )
  |> ignore
  let oracle_with_settings = @core.Dialect::get_or_raise(
    "oracle, normalization_strategy = lowercase, version = 19.5",
  )
  t.ok(oracle_with_settings.normalization_strategy is Lowercase)
  t.eq(oracle_with_settings.version, (19, 5, 0))
  // class MyDialect(Dialect): SUPPORTED_SETTINGS = {"s1", "s2", "s3", "s4", "s5"}
  @core.register_dialect("mydialect", () => {
    @core.Dialect::subclass(@core.base_dialect(), "mydialect", d => {
      d.supported_settings.clear()
      d.supported_settings.append(["s1", "s2", "s3", "s4", "s5"])
    })
  })
  let bool_settings = @core.Dialect::get_or_raise(
    "mydialect, s1=TruE, s2=1, s3=FaLse, s4=0, s5=nonbool",
  )
  // the port stores the Python booleans True / False as "true" / "false"
  t.eq(bool_settings.settings, {
    "s1": "true",
    "s2": "true",
    "s3": "false",
    "s4": "false",
    "s5": "nonbool",
  })
  t.raises(
    () => {
      ignore(
        @core.Dialect::get_or_raise(
          "tsql,normalisation_strategy=case_sensitive",
        ),
      )
    },
    "ValueError",
    message="Unknown setting 'normalisation_strategy'. Did you mean normalization_strategy?",
  )
  |> ignore
  t.done()
}

///|
/// Python `Dialect.__eq__` / `_Dialect.__eq__` against a dialect name.
fn a_dialect_eq_name(d : @core.Dialect, name : String) -> Bool {
  match @core.get_dialect(name) {
    Some(other) => d == other
    None => false
  }
}

///|
test "TestDialect.test_compare_dialects" {
  let t = t()
  let bigquery_class = @core.get_dialect("bigquery").unwrap()
  let bigquery_object = @core.Dialect::get_or_raise("bigquery")
  let bigquery_string = "bigquery"
  let snowflake_class = @core.get_dialect("snowflake").unwrap()
  let snowflake_object = @core.Dialect::get_or_raise("snowflake")
  let snowflake_string = "snowflake"
  t.ok(snowflake_class == snowflake_class)
  t.ok(snowflake_class == snowflake_object)
  t.ok(a_dialect_eq_name(snowflake_class, snowflake_string))
  t.ok(snowflake_object == snowflake_object)
  t.ok(a_dialect_eq_name(snowflake_object, snowflake_string))
  t.ok(snowflake_class != bigquery_class)
  t.ok(snowflake_class != bigquery_object)
  t.ok(!a_dialect_eq_name(snowflake_class, bigquery_string))
  t.ok(snowflake_object != bigquery_object)
  t.ok(!a_dialect_eq_name(snowflake_object, bigquery_string))
  let in_set = (d : @core.Dialect, names : Array[String]) => {
    names.iter().any(n => a_dialect_eq_name(d, n))
  }
  t.ok(in_set(snowflake_class, ["snowflake", "bigquery"]))
  t.ok(in_set(snowflake_object, ["snowflake", "bigquery"]))
  t.ok(!in_set(snowflake_class, ["bigquery", "redshift"]))
  t.ok(!in_set(snowflake_object, ["bigquery", "redshift"]))
  t.done()
}

///|
test "TestDialect.test_compare_dialect_versions" {
  let t = t()
  let ddb_v1 = @core.Dialect::get_or_raise("duckdb, version=1.0")
  let ddb_v1_2 = @core.Dialect::get_or_raise(
    "duckdb, normalization_strategy=case_sensitive, version=1.0",
  )
  let ddb_v2 = @core.Dialect::get_or_raise("duckdb, version=2.2.4")
  let ddb_latest = @core.Dialect::get_or_raise("duckdb")
  t.ok(ddb_latest.version > ddb_v2.version)
  t.ok(ddb_v1.version < ddb_v2.version)
  t.ok(ddb_v1.version == ddb_v1_2.version)
  t.ok(ddb_latest.version == @core.Dialect::get_or_raise("duckdb").version)
  t.done()
}

///|
test "TestDialect.test_decimal_literals" {
  let t = t()
  for dialect in ["hive", "spark2", "spark", "databricks"] {
    for
      case in [
        ("10.50", "DECIMAL(3, 1)", "DECIMAL(4, 2)"),
        ("0", "DECIMAL(1, 0)", "DECIMAL(1, 0)"),
        ("0.00", "DECIMAL(1, 0)", "DECIMAL(2, 2)"),
        ("0.01", "DECIMAL(2, 2)", "DECIMAL(2, 2)"),
        ("0001.50", "DECIMAL(2, 1)", "DECIMAL(3, 2)"),
        ("1E-18", "DECIMAL(18, 18)", "DECIMAL(18, 18)"),
        ("1.234567890123456789E2", "DECIMAL(19, 16)", "DECIMAL(19, 16)"),
        (
          "12345678901234567890.123456789012345678", "DECIMAL(38, 18)", "DECIMAL(38, 18)",
        ),
        (
          "12345678901234567890.123456789012345670", "DECIMAL(37, 17)", "DECIMAL(38, 18)",
        ),
      ] {
      let (literal, hive_type, spark_type) = case
      let data_type = if dialect == "hive" { hive_type } else { spark_type }
      for sign in ["", "-", "+"] {
        let prefix = if sign == "-" { "-" } else { "" }
        t.eqf(
          () => sql(parse_one("\{sign}\{literal}bd", read=dialect), dialect~),
          "\{prefix}CAST('\{literal}' AS \{data_type})",
        )
      }
    }
    if dialect != "spark2" {
      for case in [("1E3", 4), ("0E3", if dialect == "hive" { 1 } else { 4 })] {
        let (literal, precision) = case
        t.eqf(
          () => sql(parse_one("\{literal}BD", read=dialect), dialect~),
          "CAST('\{literal}' AS DECIMAL(\{precision}, 0))",
        )
      }
    }
    let data_type = if dialect == "hive" {
      "DECIMAL(3, 1)"
    } else {
      "DECIMAL(4, 2)"
    }
    for
      case in [
        ("CAST(10.50 AS DECIMAL)", "CAST(10.50 AS DECIMAL)"),
        ("10.50::DECIMAL", "CAST(10.50 AS DECIMAL)"),
        (
          "CAST(10.50BD AS DECIMAL)",
          "CAST(CAST('10.50' AS \{data_type}) AS DECIMAL)",
        ),
      ] {
      let (sql_, expected) = case
      t.eqf(() => sql(parse_one(sql_, read=dialect), dialect~), expected)
    }
  }
  t.done()
}

///|
test "TestDialect.test_spark2_negative_scale_decimal_literals" {
  let t = t()
  for
    case in [
      ("1E3", 1, -3),
      ("0E3", 1, -3),
      ("1.20E3", 3, -1),
      ("1E38", 1, -38),
    ] {
    let (literal, precision, scale) = case
    let expression = parse_one("\{literal}BD", read="spark2")
    t.eq(sql(expression, dialect="spark2"), "\{literal}BD")
    t.eqf(
      () => {
        expression
        .arg("to")
        .unwrap()
        .expressions()
        .map(parameter => parameter.this_().to_py().py_repr())
      },
      ["\{precision}", "\{scale}"],
    )
  }
  t.done()
}

///|
test "TestDialect.test_cast" {
  let t = t()
  t.ok(
    t
    .validate_identity("CREATE TABLE foo (bar INT AS (foo))")
    .find([ComputedColumnConstraint])
    is Some(_),
  )
  t.ok(
    t
    .validate_identity(
      "CREATE TABLE foo (t1 INT, t2 INT, bar INT AS (t1 * t2 * 2))",
    )
    .find([ComputedColumnConstraint])
    is Some(_),
  )
  t.done()
}

///|
test "TestDialect.test_heredoc_strings" {
  let t = t()
  for dialect in ["clickhouse", "postgres", "redshift"] {
    // invalid matching tag
    t.raises(
      () => {
        ignore(
          parse_one("SELECT $tag1$invalid heredoc string$tag2$", read=dialect),
        )
      },
      "TokenError",
    )
    |> ignore
    // unmatched tag
    t.raises(
      () => {
        ignore(parse_one("SELECT $tag1$invalid heredoc string", read=dialect))
      },
      "TokenError",
    )
    |> ignore
  }
  t.done()
}

///|
test "TestDialect.test_array" {
  let t = t()
  // NULL propagation semantics: NULL-propagating dialects -> array-creating dialects
  for source_dialect in ["snowflake", "databricks", "spark"] {
    let expr = parse_one("ARRAY_APPEND(arr, x)", read=source_dialect)
    t.eq(
      sql(expr, dialect="duckdb"),
      "CASE WHEN arr IS NULL THEN NULL ELSE LIST_APPEND(arr, x) END",
    )
    t.eq(
      sql(expr, dialect="postgres"),
      "CASE WHEN arr IS NULL THEN NULL ELSE ARRAY_APPEND(arr, x) END",
    )
  }
  // array creation semantics: array-creating dialects -> NULL-propagating dialects
  for
    case in [
      ("duckdb", "LIST_APPEND(arr, x)"),
      ("postgres", "ARRAY_APPEND(arr, x)"),
    ] {
    let (source_dialect, source_sql) = case
    let expr = parse_one(source_sql, read=source_dialect)
    t.eq(sql(expr, dialect="snowflake"), "ARRAY_APPEND(COALESCE(arr, []), x)")
    t.eq(
      sql(expr, dialect="databricks"),
      "ARRAY_APPEND(COALESCE(arr, ARRAY()), x)",
    )
    t.eq(sql(expr, dialect="spark"), "ARRAY_APPEND(COALESCE(arr, ARRAY()), x)")
  }
  // identity transpilation (no wrappers)
  for
    case in [
      ("duckdb", "LIST_APPEND(arr, x)"),
      ("postgres", "ARRAY_APPEND(arr, x)"),
      ("snowflake", "ARRAY_APPEND(arr, x)"),
      ("databricks", "ARRAY_APPEND(arr, x)"),
      ("spark", "ARRAY_APPEND(arr, x)"),
    ] {
    let (dialect, sql_) = case
    t.eqf(() => sql(parse_one(sql_, read=dialect), dialect~), sql_)
  }
  // ARRAY_PREPEND NULL propagation
  for source_dialect in ["snowflake", "databricks", "spark"] {
    let expr = parse_one("ARRAY_PREPEND(arr, x)", read=source_dialect)
    t.eq(
      sql(expr, dialect="duckdb"),
      "CASE WHEN arr IS NULL THEN NULL ELSE LIST_PREPEND(x, arr) END",
    )
    t.eq(
      sql(expr, dialect="postgres"),
      "CASE WHEN arr IS NULL THEN NULL ELSE ARRAY_PREPEND(x, arr) END",
    )
  }
  // ARRAY_PREPEND array creation
  for
    case in [
      ("duckdb", "LIST_PREPEND(x, arr)"),
      ("postgres", "ARRAY_PREPEND(x, arr)"),
    ] {
    let (source_dialect, source_sql) = case
    let expr = parse_one(source_sql, read=source_dialect)
    t.eq(sql(expr, dialect="snowflake"), "ARRAY_PREPEND(COALESCE(arr, []), x)")
    t.eq(
      sql(expr, dialect="databricks"),
      "ARRAY_PREPEND(COALESCE(arr, ARRAY()), x)",
    )
    t.eq(sql(expr, dialect="spark"), "ARRAY_PREPEND(COALESCE(arr, ARRAY()), x)")
  }
  // ARRAY_PREPEND identity
  for
    case in [
      ("duckdb", "LIST_PREPEND(x, arr)"),
      ("postgres", "ARRAY_PREPEND(x, arr)"),
      ("snowflake", "ARRAY_PREPEND(arr, x)"),
      ("databricks", "ARRAY_PREPEND(arr, x)"),
      ("spark", "ARRAY_PREPEND(arr, x)"),
    ] {
    let (dialect, sql_) = case
    t.eqf(() => sql(parse_one(sql_, read=dialect), dialect~), sql_)
  }
  // ARRAY_CAT NULL propagation
  for
    case in [
      ("snowflake", "ARRAY_CAT(arr1, arr2)"),
      ("redshift", "ARRAY_CONCAT(arr1, arr2)"),
    ] {
    let (source_dialect, source_sql) = case
    let expr = parse_one(source_sql, read=source_dialect)
    t.eq(
      sql(expr, dialect="duckdb"),
      "CASE WHEN arr1 IS NULL OR arr2 IS NULL THEN NULL ELSE LIST_CONCAT(arr1, arr2) END",
    )
    t.eq(
      sql(expr, dialect="postgres"),
      "CASE WHEN arr1 IS NULL OR arr2 IS NULL THEN NULL ELSE ARRAY_CAT(arr1, arr2) END",
    )
  }
  // ARRAY_CAT NULL skipping
  for
    case in [
      ("duckdb", "LIST_CONCAT(arr1, arr2)"),
      ("postgres", "ARRAY_CAT(arr1, arr2)"),
    ] {
    let (source_dialect, source_sql) = case
    let expr = parse_one(source_sql, read=source_dialect)
    t.eq(
      sql(expr, dialect="snowflake"),
      "ARRAY_CAT(COALESCE(arr1, []), COALESCE(arr2, []))",
    )
    t.eq(
      sql(expr, dialect="redshift"),
      "ARRAY_CONCAT(COALESCE(arr1, ARRAY()), COALESCE(arr2, ARRAY()))",
    )
  }
  // ARRAY_CAT identity
  for
    case in [
      ("duckdb", "LIST_CONCAT(arr1, arr2)"),
      ("postgres", "ARRAY_CAT(arr1, arr2)"),
      ("snowflake", "ARRAY_CAT(arr1, arr2)"),
      ("redshift", "ARRAY_CONCAT(arr1, arr2)"),
    ] {
    let (dialect, sql_) = case
    t.eqf(() => sql(parse_one(sql_, read=dialect), dialect~), sql_)
  }
  // ARRAY_CAT with variadic arguments: all arguments are checked
  for
    case in [
      (
        "snowflake", "ARRAY_CAT(arr1, arr2, arr3)", "CASE WHEN arr1 IS NULL OR arr2 IS NULL OR arr3 IS NULL THEN NULL ELSE LIST_CONCAT(arr1, arr2, arr3) END",
      ),
      (
        "redshift", "ARRAY_CONCAT(arr1, arr2, arr3)", "CASE WHEN arr1 IS NULL OR arr2 IS NULL OR arr3 IS NULL THEN NULL ELSE LIST_CONCAT(arr1, arr2, arr3) END",
      ),
    ] {
    let (source_dialect, source_sql, expected) = case
    t.eqf(
      () => sql(parse_one(source_sql, read=source_dialect), dialect="duckdb"),
      expected,
    )
  }
  // variadic COALESCE wrapping: all args are wrapped
  for
    case in [
      (
        "duckdb", "LIST_CONCAT(arr1, arr2, arr3)", "ARRAY_CAT(COALESCE(arr1, []), ARRAY_CAT(COALESCE(arr2, []), COALESCE(arr3, [])))",
        "ARRAY_CONCAT(COALESCE(arr1, ARRAY()), ARRAY_CONCAT(COALESCE(arr2, ARRAY()), COALESCE(arr3, ARRAY())))",
      ),
      (
        "postgres", "ARRAY_CAT(arr1, arr2, arr3)", "ARRAY_CAT(COALESCE(arr1, []), ARRAY_CAT(COALESCE(arr2, []), COALESCE(arr3, [])))",
        "ARRAY_CONCAT(COALESCE(arr1, ARRAY()), ARRAY_CONCAT(COALESCE(arr2, ARRAY()), COALESCE(arr3, ARRAY())))",
      ),
    ] {
    let (source_dialect, source_sql, expected_snowflake, expected_redshift) = case
    let expr = parse_one(source_sql, read=source_dialect)
    t.eq(sql(expr, dialect="snowflake"), expected_snowflake)
    t.eq(sql(expr, dialect="redshift"), expected_redshift)
  }
  // PostgreSQL -> Snowflake (2 args)
  let expr = parse_one("ARRAY_CAT(arr1, arr2)", read="postgres")
  t.eq(
    sql(expr, dialect="snowflake"),
    "ARRAY_CAT(COALESCE(arr1, []), COALESCE(arr2, []))",
  )
  // array literal: no wrapper needed
  let expr = parse_one("ARRAY_CAT([1, 2], arr2)", read="snowflake")
  t.eq(sql(expr, dialect="duckdb"), "LIST_CONCAT([1, 2], arr2)")
  // single argument
  let expr = parse_one("ARRAY_CAT(arr1)", read="snowflake")
  t.eq(sql(expr, dialect="duckdb"), "LIST_CONCAT(arr1)")
  t.done()
}

///|
test "TestDialect.test_json" {
  let t = t()
  for dialect in ["duckdb", "starrocks"] {
    // json extraction with a digit-prefixed key
    t.eqf(
      () => {
        sql(parse_one("select '{\"0\": \"v\"}' -> '0'", read=dialect), dialect~)
      },
      "SELECT '{\"0\": \"v\"}' -> '0'",
    )
  }
  t.done()
}

///|
test "TestDialect.test_typeddiv" {
  let t = t()
  let typed_div = @core.mk(Div, [
    ("this", @sqlglot.column("a")),
    ("expression", @sqlglot.column("b")),
    ("typed", true),
  ])
  let div = @core.mk(Div, [
    ("this", @sqlglot.column("a")),
    ("expression", @sqlglot.column("b")),
  ])
  let typed_div_dialect = "presto"
  let div_dialect = "hive"
  let int : @core.DType? = Some(INT)
  let float : @core.DType? = Some(FLOAT)
  let none : @core.DType? = None
  for
    case in [
      (typed_div, (none, none), typed_div_dialect, "a / b"),
      (typed_div, (none, none), div_dialect, "a / b"),
      (div, (none, none), typed_div_dialect, "CAST(a AS DOUBLE) / b"),
      (div, (none, none), div_dialect, "a / b"),
      (typed_div, (int, int), typed_div_dialect, "a / b"),
      (typed_div, (int, int), div_dialect, "CAST(a / b AS BIGINT)"),
      (div, (int, int), typed_div_dialect, "CAST(a AS DOUBLE) / b"),
      (div, (int, int), div_dialect, "a / b"),
      (typed_div, (float, float), typed_div_dialect, "a / b"),
      (typed_div, (float, float), div_dialect, "a / b"),
      (div, (float, float), typed_div_dialect, "a / b"),
      (div, (float, float), div_dialect, "a / b"),
      (typed_div, (int, float), typed_div_dialect, "a / b"),
      (typed_div, (int, float), div_dialect, "a / b"),
      (div, (int, float), typed_div_dialect, "a / b"),
      (div, (int, float), div_dialect, "a / b"),
    ] {
    let (expression, types, dialect, expected) = case
    let expression = expression.copy()
    expression.this_().set_type(types.0.map(@core.datatype_of))
    expression.expression_().set_type(types.1.map(@core.datatype_of))
    t.eqf(() => sql(expression, dialect~), expected)
  }
  t.done()
}

///|
test "TestDialect.test_safediv" {
  let t = t()
  let safe_div = @core.mk(Div, [
    ("this", @sqlglot.column("a")),
    ("expression", @sqlglot.column("b")),
    ("safe", true),
  ])
  let div = @core.mk(Div, [
    ("this", @sqlglot.column("a")),
    ("expression", @sqlglot.column("b")),
  ])
  let safe_div_dialect = "mysql"
  let div_dialect = "snowflake"
  for
    case in [
      (safe_div, safe_div_dialect, "a / b"),
      (safe_div, div_dialect, "a / NULLIF(b, 0)"),
      (div, safe_div_dialect, "a / b"),
      (div, div_dialect, "a / b"),
    ] {
    let (expression, dialect, expected) = case
    t.eqf(() => sql(expression, dialect~), expected)
  }
  t.eq(
    sql(parse_one("CAST(x AS DECIMAL) / y", read="mysql"), dialect="postgres"),
    "CAST(x AS DECIMAL) / NULLIF(y, 0)",
  )
  t.done()
}

///|
test "TestDialect.test_fetch_first_implicit_count" {
  let t = t()
  // the generated SQL must round-trip in every LIMIT-based dialect
  for dialect in ["mysql", "sqlite", "duckdb", "bigquery", "spark", "redshift"] {
    let once = sql(
      parse_one("SELECT * FROM t FETCH FIRST ROWS ONLY", read=dialect),
      dialect~,
    )
    t.eq(once, "SELECT * FROM t LIMIT 1")
    let twice = sql(parse_one(once, read=dialect), dialect~)
    t.eq(once, twice)
  }
  t.done()
}

///|
test "TestDialect.test_alias" {
  let t = t()
  for
    dialect in [
      "presto", "hive", "postgres", "clickhouse", "bigquery", "snowflake", "duckdb",
    ] {
    // string alias
    t.raises(
      () => ignore(parse_one("SELECT 1 'foo'", read=dialect)),
      "ParseError",
    )
    |> ignore
  }
  t.done()
}

///|
test "TestDialect.test_cast_to_user_defined_type" {
  let t = t()
  t.raises(
    () => ignore(parse_one("CAST(x AS some_udt)", read="bigquery")),
    "ParseError",
  )
  |> ignore
  t.done()
}

///|
test "TestDialect.test_unsupported_null_ordering" {
  let t = t()
  // MySQL / T-SQL both treat NULLs as small values
  let with_last_nulls = "duckdb"
  let with_small_nulls = "spark"
  let with_large_nulls = "postgres"
  let sql_ = "SELECT * FROM t ORDER BY c"
  let sql_nulls_last = "SELECT * FROM t ORDER BY CASE WHEN c IS NULL THEN 1 ELSE 0 END, c"
  let sql_nulls_first = "SELECT * FROM t ORDER BY CASE WHEN c IS NULL THEN 1 ELSE 0 END DESC, c"
  for
    case in [
      (with_last_nulls, false, None, sql_nulls_last),
      (with_last_nulls, true, None, sql_),
      (with_last_nulls, false, Some(true), sql_),
      (with_last_nulls, true, Some(true), sql_nulls_first),
      (with_last_nulls, false, Some(false), sql_nulls_last),
      (with_last_nulls, true, Some(false), sql_),
      (with_small_nulls, false, None, sql_),
      (with_small_nulls, true, None, sql_),
      (with_small_nulls, false, Some(true), sql_),
      (with_small_nulls, true, Some(true), sql_nulls_first),
      (with_small_nulls, false, Some(false), sql_nulls_last),
      (with_small_nulls, true, Some(false), sql_),
      (with_large_nulls, false, None, sql_nulls_last),
      (with_large_nulls, true, None, sql_nulls_first),
      (with_large_nulls, false, Some(true), sql_),
      (with_large_nulls, true, Some(true), sql_nulls_first),
      (with_large_nulls, false, Some(false), sql_nulls_last),
      (with_large_nulls, true, Some(false), sql_),
    ] {
    let (read_dialect, desc, nulls_first, expected_sql) = case
    let sort_order = if desc { " DESC" } else { "" }
    let null_order = match nulls_first {
      Some(true) => " NULLS FIRST"
      Some(false) => " NULLS LAST"
      None => ""
    }
    let expected_sql = "\{expected_sql}\{sort_order}"
    let expression = parse_one(
      "\{sql_}\{sort_order}\{null_order}",
      read=read_dialect,
    )
    t.eqf(() => sql(expression, dialect="mysql"), expected_sql)
    t.eqf(() => sql(expression, dialect="tsql"), expected_sql)
  }
  t.done()
}

///|
test "TestDialect.test_reserved_keywords" {
  let t = t()
  let order = @sqlglot.select(["*"]).from_("order")
  for name in ["duckdb", "presto", "redshift"] {
    let dialect = @core.Dialect::get_or_raise(name)
    t.eqf(
      () => sql(order, dialect=name),
      "SELECT * FROM \{dialect.cfg.identifier_start}order\{dialect.cfg.identifier_end}",
    )
  }
  t.done()
}

///|
test "TestDialect.test_normalize" {
  let t = t()
  t.ok(
    parse_one("NORMALIZE('str', NFD)").arg("form").map(f => f.kind.is_a(Var)) ==
    Some(true),
  )
  t.done()
}

///|
/// Python `isinstance(expression.expressions, list)`.
fn a_expressions_is_list(e : @core.Expr) -> Bool {
  e.get("expressions") is Some(List(_))
}

///|
test "TestDialect.test_coalesce" {
  let t = t()
  // the 2-arg aliases
  for func in ["COALESCE", "IFNULL", "NVL"] {
    t.ok(a_expressions_is_list(t.parse_one("\{func}(1, 2)")))
  }
  // the varlen case
  let coalesce = t.parse_one("COALESCE(x, y, z)")
  t.ok(a_expressions_is_list(coalesce))
  t.ok(coalesce.get("is_nvl") is None)
  // Oracle's NVL which is decoupled from COALESCE
  let oracle_nvl = parse_one("NVL(x, y)", read="oracle")
  t.ok(a_expressions_is_list(oracle_nvl))
  t.ok(oracle_nvl.bool_arg("is_nvl"))
  // T-SQL's ISNULL which is parsed into exp.Coalesce
  t.ok(a_expressions_is_list(parse_one("ISNULL(x, y)", read="tsql")))
  t.done()
}

///|
test "TestDialect.test_integer_hex_strings" {
  let t = t()
  // hex strings such as 0xCC represent INTEGER values in the read dialects
  let integer_dialects = ["bigquery", "clickhouse"]
  for read_dialect in integer_dialects {
    for
      write_dialect in [
        "", "duckdb", "databricks", "snowflake", "spark", "redshift",
      ] {
      t.eqf(
        () => {
          sql(
            parse_one("SELECT 0xCC", read=read_dialect),
            dialect=write_dialect,
          )
        },
        "SELECT 204",
      )
    }
    for other_integer_dialects in integer_dialects {
      t.eqf(
        () => {
          sql(
            parse_one("SELECT 0xCC", read=read_dialect),
            dialect=other_integer_dialects,
          )
        },
        "SELECT 0xCC",
      )
    }
  }
  t.done()
}

///|
test "TestDialect.test_between" {
  let t = t()
  let between = @sqlglot.column("x").between(1, 2)
  t.eq(sql(between, dialect="postgres"), "x BETWEEN 1 AND 2")
  t.eq(sql(between, dialect="redshift"), "x BETWEEN 1 AND 2")
  t.ok(!between.args.contains("symmetric"))
  t.done()
}

///|
test "TestDialect.test_regexp_replace" {
  let t = t()
  for target_dialect in ["postgres", "duckdb"] {
    // transpilations to Postgres / DuckDB append 'g' (replace all occurrences)
    for
      read_dialect in ["", "bigquery", "presto", "trino", "spark", "databricks"] {
      t.eqf(
        () => {
          sql(
            parse_one("REGEXP_REPLACE('aaa', 'a', 'b')", read=read_dialect),
            dialect=target_dialect,
          )
        },
        "REGEXP_REPLACE('aaa', 'a', 'b', 'g')",
      )
    }
  }
  t.done()
}

///|
test "TestDialect.test_initcap" {
  let t = t()
  let delimiter_chars : Map[String, String] = Map([])
  for
    item in [
      ("", ""),
      ("bigquery", "bigquery"),
      ("snowflake", "snowflake"),
      ("spark", "spark2"),
    ] {
    delimiter_chars[item.0] = @sqlglot.dialect(item.1).cfg.initcap_default_delimiter_chars
  }
  // INITCAP without explicit delimiters
  t.eq(
    sql(@core.mk(Initcap, [("this", @core.literal_string("col"))])),
    "INITCAP('col')",
  )
  t.eq(
    sql(@core.mk(Initcap, [("this", @sqlglot.column("col"))])),
    "INITCAP(col)",
  )
  for dialect, _ in delimiter_chars {
    // round-tripping default delimiters
    t.eqf(
      () => sql(parse_one("INITCAP(col)", read=dialect), dialect~),
      "INITCAP(col)",
    )
  }
  for read_dialect in ["", "spark"] {
    for write_dialect in ["bigquery", "snowflake"] {
      // default delimiters emitted
      let escaped_delimiters = sql(
        @core.literal_string(delimiter_chars[read_dialect]),
        dialect=write_dialect,
      )
      t.eqf(
        () => {
          sql(
            parse_one("INITCAP(col)", read=read_dialect),
            dialect=write_dialect,
          )
        },
        "INITCAP(col, \{escaped_delimiters})",
      )
    }
  }
  let ws_control_chars = ['\u{0b}', '\u{1c}', '\u{1d}', '\u{1e}', '\u{1f}']
  for dialect, default_chars in delimiter_chars {
    // DuckDB rewrite for default delimiters
    let chr_chars = ws_control_chars.filter(c => default_chars.contains_char(c))
    let expression = parse_one("INITCAP(col)", read=dialect)
    t.a_assert_duckdb_sql(
      expression,
      includes=["ARRAY_TO_STRING(", "REGEXP_MATCHES(", "LIST_TRANSFORM("],
      chr_chars~,
    )
    |> ignore
  }
  t.a_custom_initcap_duckdb_sql("INITCAP(col, '')", includes=["UPPER(LEFT("], excludes=[
    "REGEXP_MATCHES(",
  ])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, NULL)", includes=[
    "REGEXP_MATCHES(", "REPLACE(",
  ])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, ' ')", includes=["' '"])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, '@')", includes=["'@'"], excludes=[
    "CHR(",
  ])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, '_@')", includes=["'_@'"])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, '\\\\\\\\')", includes=["\\\\"])
  t.a_custom_initcap_duckdb_sql("INITCAP(col, '\u{0b}')", chr_chars=['\u{0b}'])
  t.a_custom_initcap_duckdb_sql(
    "INITCAP(col, (SELECT delimiter FROM settings LIMIT 1))",
    includes=["SELECT delimiter FROM settings", "REPLACE("],
  )
  t.done()
}

///|
/// `assert_custom_duckdb_sql` of TestDialect.test_initcap.
#callsite(autofill(loc))
fn T::a_custom_initcap_duckdb_sql(
  self : T,
  query : String,
  includes? : Array[String] = [],
  excludes? : Array[String] = [],
  chr_chars? : Array[Char] = [],
  loc~ : SourceLoc,
) -> Unit {
  for dialect in ["bigquery", "snowflake"] {
    self.run(loc~, () => {
      let expression = parse_one(query, read=dialect)
      self.a_assert_duckdb_sql(
        expression,
        includes~,
        excludes~,
        chr_chars~,
        loc~,
      )
      |> ignore
    })
    |> ignore
  }
}

///|
test "TestDialect.test_initcap_custom_delimiter_warning" {
  let t = t()
  let expression = parse_one("INITCAP(col, '_')", read="bigquery")
  for dialect in ["postgres", "presto"] {
    let output = t.assert_logs(level="WARNING", () => {
      sql(expression, dialect~) |> ignore
    })
    if output.length() > 0 {
      t.contains(output[0], "INITCAP does not support custom delimiters")
    }
  }
  t.done()
}

///|
test "TestDialect.test_parse_at_time_zone" {
  let t = t()
  let parsed_expr = t
    .validate_identity(
      "SELECT CAST('2001-02-17 08:38:40' AS TIMESTAMP) AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Tokyo'",
    )
    .expressions()[0]
  t.eq(sql(parsed_expr.arg("zone").unwrap()), "'Asia/Tokyo'")
  t.eq(sql(parsed_expr.this_().arg("zone").unwrap()), "'UTC'")
  let parsed_expr = t
    .validate_identity(
      "SELECT CAST('2001-02-17 08:38:40' AS TIMESTAMP) AT TIME ZONE INTERVAL '3' HOURS AT TIME ZONE 'Asia/Tokyo'",
    )
    .expressions()[0]
  t.eq(
    sql(parsed_expr.arg("zone").unwrap(), dialect="postgres"),
    "'Asia/Tokyo'",
  )
  t.eq(
    sql(parsed_expr.this_().arg("zone").unwrap(), dialect="postgres"),
    "INTERVAL '3 HOURS'",
  )
  t.done()
}

///|
test "TestDialect.test_underscore_scientific_notation" {
  let t = t()
  for dialect in ["duckdb", "clickhouse"] {
    for notation in ["e", "E"] {
      for sign in ["", "-", "+"] {
        let number = "1_2\{notation}\{sign}1_0"
        let expected = "12\{notation}\{sign}10"
        t.eqf(() => sql(parse_one(number, read=dialect), dialect~), expected)
        let number = "12.3_4\{notation}\{sign}5_6_7"
        let expected = "12.34\{notation}\{sign}567"
        t.eqf(() => sql(parse_one(number, read=dialect), dialect~), expected)
      }
    }
    // underscore separated numbers
    let ast = parse_one("1_2_3_4_5", read=dialect)
    t.ok(ast.is_int())
    t.eqf(() => ast.to_py().py_repr(), "12345")
    t.eq(sql(ast, dialect~), "12345")
  }
  t.done()
}

///|
test "TestDialect.test_localtime_and_localtimestamp" {
  let t = t()
  for func in ["LOCALTIME", "LOCALTIMESTAMP"] {
    let exp_type : @core.Kind = if func == "LOCALTIME" {
      Localtime
    } else {
      Localtimestamp
    }
    for func_variant in [func, "\{func}(2)"] {
      // function node
      t.run(() => {
        t.validate_identity("SELECT \{func_variant}").selects()[0].assert_is(
          exp_type,
        )
        |> ignore
      })
      |> ignore
    }
  }
  for
    dialect in [
      "tsql", "oracle", "sqlite", "hive", "spark2", "spark", "databricks", "bigquery",
    ] {
    for func in ["localtime", "localtimestamp"] {
      // oracle supports localtimestamp but not localtime
      if func == "localtimestamp" && dialect == "oracle" {
        continue
      }
      // identifier
      let sql_ = "SELECT \{func}"
      t.run(() => {
        let select = parse_one(sql_, read=dialect)
        select.selects()[0].assert_is(Column) |> ignore
        t.eq(sql(select, dialect~), sql_)
      })
      |> ignore
    }
  }
  t.done()
}

///|
test "TestDialect.test_current_catalog" {
  let t = t()
  let mut sql_ = "SELECT CURRENT_CATALOG"
  let unsupported_dialects = [
    "bigquery", "mysql", "oracle", "clickhouse", "snowflake", "spark", "databricks",
    "presto",
  ]
  for dialect in unsupported_dialects {
    // CURRENT_CATALOG as Column
    t.run(() => {
      let select = parse_one(sql_, read=dialect)
      select.selects()[0].assert_is(Column) |> ignore
      t.eq(sql(select, dialect~), sql_)
    })
    |> ignore
  }
  let supported_dialects = ["postgres", "duckdb", "trino", "databricks"]
  for dialect in supported_dialects {
    // CURRENT_CATALOG expression
    if dialect == "databricks" {
      sql_ = "SELECT CURRENT_CATALOG()"
    }
    t.run(() => {
      let select = parse_one(sql_, read=dialect)
      select.selects()[0].assert_is(CurrentCatalog) |> ignore
      t.eq(sql(select, dialect~), sql_)
    })
    |> ignore
  }
  t.done()
}

///|
test "TestDialect.test_session_user" {
  let t = t()
  let no_paren_sql = "SELECT SESSION_USER"
  let func_sql = "SELECT SESSION_USER()"
  // these dialects support only SESSION_USER()
  for dialect in ["bigquery", "mysql"] {
    t.run(() => {
      let select = parse_one(no_paren_sql, read=dialect)
      select.selects()[0].assert_is(Column) |> ignore
      t.eq(sql(select, dialect~), no_paren_sql)
      let select = parse_one(func_sql, read=dialect)
      select.selects()[0].assert_is(SessionUser) |> ignore
      t.eq(sql(select, dialect~), func_sql)
    })
    |> ignore
  }
  // these dialects support either only SESSION_USER or both
  let no_paren_dialects = ["postgres", "duckdb", "databricks", "tsql", "spark"]
  for dialect in no_paren_dialects {
    t.run(() => {
      let select = parse_one(no_paren_sql, read=dialect)
      select.selects()[0].assert_is(SessionUser) |> ignore
      t.eq(sql(select, dialect~), no_paren_sql)
      // these dialects support both SESSION_USER and SESSION_USER()
      if ["databricks", "spark", "duckdb"].contains(dialect) {
        t.eq(sql(parse_one(func_sql, read=dialect), dialect~), no_paren_sql)
      }
    })
    |> ignore
  }
  t.done()
}

///|
test "TestDialect.test_operator" {
  let t = t()
  let expr = t.validate_identity("1 OPERATOR(+) 2 OPERATOR(*) 3")
  expr.this_().assert_is(Operator) |> ignore
  expr.this_().this_().assert_is(Literal) |> ignore
  expr.this_().expression_().assert_is(Literal) |> ignore
  expr.expression_().assert_is(Literal) |> ignore
  t.eq(sql(expr, dialect="postgres"), "1 OPERATOR(+) 2 OPERATOR(*) 3")
  t.done()
}

///|
test "TestDialect.test_patch_dialect_parser" {
  let t = t()
  // Snowflake.parser_class = CustomSnowflakeParser (FUNCTIONS + MY_CUSTOM_FUNC)
  let snowflake = @core.get_dialect("snowflake").unwrap()
  let original = snowflake.parser_fns.functions
  let functions = original.copy()
  functions["MY_CUSTOM_FUNC"] = @core.from_arg_list_builder(Length)
  snowflake.parser_fns.functions = functions
  let result = t.run(() => {
    let result = parse_one("SELECT 1", read="snowflake")
    t.ok(result.kind.is_a(Select))
    let result = parse_one("SELECT MY_CUSTOM_FUNC(a)", read="snowflake")
    t.ok(result.find([Length]) is Some(_))
  })
  snowflake.parser_fns.functions = original
  ignore(result)
  t.done()
}

///|
test "TestDialect.test_custom_dialect" {
  let t = t()
  // class MyDialect(Dialect): class Parser(SnowflakeParser) with an extra DOUBLE_IT
  let snowflake = @core.get_dialect("snowflake").unwrap()
  let my_dialect = @core.Dialect::subclass(@core.base_dialect(), "mydialect", d => {
    let functions = snowflake.parser_fns.functions.copy()
    functions["DOUBLE_IT"] = (args, _) => {
      @core.mk(Mul, [
        ("this", @core.literal_number("2")),
        (
          "expression",
          match args.get(0) {
            Some(a) => a
            None => @core.mk0(Null)
          },
        ),
      ])
    }
    d.parser_fns.functions = functions
  })
  let result = my_dialect.parse("SELECT DOUBLE_IT(5)")[0].unwrap()
  t.ok(result.expressions()[0].kind.is_a(Mul))
  t.eq(sql(result), "SELECT 2 * 5")
  t.done()
}

///|
test "TestDialect.test_agg" {
  let t = t()
  let expression = t.validate_identity(
    "SELECT AGG(m), AGG(m) AS x, AGG(t.m) FROM t",
  )
  t.ok(expression.selects()[0].kind.is_a(Agg))
  t.eq(expression.selects().map(s => s.output_name()), ["m", "x", "m"])
  t.done()
}

///|
test "TestDialect.test_order_by" {
  let t = t()
  let order_by_all_sql = "SELECT * FROM t ORDER BY ALL"
  t
  .validate_identity(order_by_all_sql)
  .find([Ordered])
  .unwrap()
  .this_()
  .assert_is(Column)
  |> ignore
  for dialect in ["duckdb", "spark", "databricks"] {
    // ORDER BY ALL
    t.run(() => {
      parse_one(order_by_all_sql, read=dialect)
      .find([Ordered])
      .unwrap()
      .this_()
      .assert_is(Var)
      |> ignore
    })
    |> ignore
  }
  t.done()
}
