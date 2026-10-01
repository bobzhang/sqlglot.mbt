// Direct assertions of tests/dialects/test_spark.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestSpark.test_spark" {
  let t = t(dialect="spark")
  t.eq(
    sql(
      parse_one("REFRESH TABLE t", read="spark").assert_is(Refresh),
      dialect="spark",
    ),
    "REFRESH TABLE t",
  )
  // Spark TRUNC is date-only, should parse to DateTrunc (not numeric Trunc)
  t.validate_identity("TRUNC(date_col, 'MM')").assert_is(DateTrunc) |> ignore
  t.done()
}

///|
test "TestSpark.test_grouping_sets_as_group_by_element" {
  let t = t(dialect="spark")
  let suffix_sql = "SELECT COUNT(1), d, h FROM t GROUP BY d, h GROUPING SETS ((d, h), (d))"
  let element_sql = "SELECT COUNT(1), d, h FROM t GROUP BY d, h, GROUPING SETS ((d, h), (d))"
  for
    case in [
      (suffix_sql, true),
      (element_sql, false),
      (
        "SELECT a FROM t GROUP BY a, GROUPING SETS ((a)), GROUPING SETS ((a))", false,
      ),
      (
        "SELECT COUNT(1), d, h FROM t GROUP BY GROUPING SETS ((d, h), (d))", false,
      ),
    ] {
    let (sql, is_suffix) = case
    let group = t.validate_identity(sql).arg("group").unwrap()
    t.eq(
      group.get("grouping_sets").map(v => v.truthy()).unwrap_or(false),
      is_suffix,
    )
    t.eq(
      group.expressions().iter().any(e => e.kind == GroupingSets),
      !is_suffix,
    )
  }
  t.raises(
    () => {
      ignore(
        t.parse_one(
          "SELECT a FROM t GROUP BY a GROUPING SETS ((a)), GROUPING SETS ((a))",
        ),
      )
    },
    "ParseError",
  )
  |> ignore
  let suffix_expression = t.parse_one(suffix_sql)
  for dialect in ["hive", "spark"] {
    t.eqf(
      () => sql(suffix_expression, dialect~, unsupported_level=Raise),
      suffix_sql,
    )
  }
  t.eq(
    sql(suffix_expression, dialect="trino", unsupported_level=Ignore),
    element_sql,
  )
  t.raises(
    () => {
      ignore(sql(suffix_expression, dialect="trino", unsupported_level=Raise))
    },
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestSpark.test_explode_map" {
  let t = t(dialect="spark")
  let expression = @optimizer.annotate_types(
    t.parse_one("SELECT EXPLODE(MAP(1, 'a')) AS (k, v)"),
  )
  t.eq(
    sql(expression, dialect="presto"),
    "SELECT _u_2.k AS k, _u_2.v AS v FROM UNNEST(MAP(ARRAY[1], ARRAY['a'])) AS _u_2(k, v)",
  )
  let schema_json = "{\"tbl\": {\"cells\": \"MAP<INT, STRING>\"}}"
  let spark = @sqlglot.dialect("spark")
  let expression = @optimizer.qualify(
    t.parse_one("SELECT EXPLODE(cells) AS (cell_id, cell_name) FROM tbl"),
    dialect=spark,
    schema=d_schema(schema_json, dialect="spark"),
  )
  let expression = @optimizer.annotate_types(
    expression,
    dialect=spark,
    schema=d_schema(schema_json, dialect="spark"),
  )
  t.eq(
    sql(expression, dialect="trino"),
    "SELECT _u_2.\"cell_id\" AS \"cell_id\", _u_2.\"cell_name\" AS \"cell_name\" FROM \"tbl\" AS \"tbl\" CROSS JOIN UNNEST(\"tbl\".\"cells\") AS _u_2(\"cell_id\", \"cell_name\")",
  )
  let expression = @optimizer.annotate_types(
    t.parse_one("SELECT EXPLODE(tbl.cells) FROM tbl"),
    dialect=spark,
    schema=d_schema(schema_json, dialect="spark"),
  )
  t.eq(
    sql(expression, dialect="trino"),
    "SELECT _u_2.key AS key, _u_2.value AS value FROM tbl CROSS JOIN UNNEST(tbl.cells) AS _u_2(key, value)",
  )
  t.done()
}

///|
test "TestSpark.test_strip_modifiers" {
  let t = t(dialect="spark")
  let without_modifiers = "SELECT * FROM t"
  let with_modifiers = "\{without_modifiers} CLUSTER BY y DISTRIBUTE BY x SORT BY z"
  let query = t.parse_one(with_modifiers)
  for name in d_python_dialects {
    if name is ("" | "databricks" | "hive" | "spark" | "spark2") {
      t.eqf(() => sql(query, dialect=name), with_modifiers)
    } else {
      t.eqf(() => sql(query, dialect=name), without_modifiers)
    }
  }
  t.done()
}

///|
test "TestSpark.test_string" {
  let t = t(dialect="spark")
  for dialect in ["hive", "spark2", "spark", "databricks"] {
    let query = parse_one("STRING(a)", read=dialect)
    t.eq(sql(query, dialect~), "CAST(a AS STRING)")
  }
  t.done()
}

///|
test "TestSpark.test_binary_string" {
  let t = t(dialect="spark")
  for dialect in ["spark2", "spark", "databricks"] {
    let query = parse_one("X'ab'", read=dialect)
    t.eq(sql(query, dialect~), "X'ab'")
    let query = parse_one("X''", read=dialect)
    t.eq(sql(query, dialect~), "X''")
  }
  t.done()
}

///|
test "TestSpark.test_transpile_annotated_exploded_column" {
  let t = t(dialect="spark")
  let spark = @sqlglot.dialect("spark")
  for db_prefix in ["", "explode_view."] {
    let sql_ =
      $|
      $|                    WITH test_table AS (
      $|                      SELECT
      $|                        12345 AS id_column,
      $|                        ARRAY(
      $|                          STRUCT('John' AS name, 30 AS age),
      $|                          STRUCT('Mary' AS name, 20 AS age),
      $|                          STRUCT('Mike' AS name, 80 AS age),
      $|                          STRUCT('Dan' AS name, 50 AS age)
      $|                        ) AS struct_column
      $|                    )
      $|
      $|                    SELECT
      $|                        id_column,
      $|                        \{db_prefix}new_column.name,
      $|                        \{db_prefix}new_column.age
      $|                    FROM test_table
      $|                    LATERAL VIEW EXPLODE(struct_column) explode_view AS new_column
      $|
    let expr = t.parse_one(sql_)
    let qualified = @optimizer.qualify(expr, dialect=spark)
    let annotated = @optimizer.annotate_types(qualified, dialect=spark)
    t.eq(
      sql(annotated, dialect="spark"),
      "WITH `test_table` AS (SELECT 12345 AS `id_column`, ARRAY(STRUCT('John' AS `name`, 30 AS `age`), STRUCT('Mary' AS `name`, 20 AS `age`), STRUCT('Mike' AS `name`, 80 AS `age`), STRUCT('Dan' AS `name`, 50 AS `age`)) AS `struct_column`) SELECT `test_table`.`id_column` AS `id_column`, `explode_view`.`new_column`.`name` AS `name`, `explode_view`.`new_column`.`age` AS `age` FROM `test_table` AS `test_table` LATERAL VIEW EXPLODE(`test_table`.`struct_column`) explode_view AS `new_column`",
    )
    t.eq(
      sql(annotated, dialect="presto"),
      "WITH \"test_table\" AS (SELECT 12345 AS \"id_column\", ARRAY[CAST(ROW('John', 30) AS ROW(\"name\" VARCHAR, \"age\" INTEGER)), CAST(ROW('Mary', 20) AS ROW(\"name\" VARCHAR, \"age\" INTEGER)), CAST(ROW('Mike', 80) AS ROW(\"name\" VARCHAR, \"age\" INTEGER)), CAST(ROW('Dan', 50) AS ROW(\"name\" VARCHAR, \"age\" INTEGER))] AS \"struct_column\") SELECT \"test_table\".\"id_column\" AS \"id_column\", \"explode_view\".\"name\" AS \"name\", \"explode_view\".\"age\" AS \"age\" FROM \"test_table\" AS \"test_table\" CROSS JOIN UNNEST(\"test_table\".\"struct_column\") AS \"explode_view\"(\"name\", \"age\")",
    )
  }
  t.done()
}

///|
test "TestSpark.test_approx_percentile" {
  let t = t(dialect="spark")
  let e = t.is_a(
    Some(t.validate_identity("PERCENTILE_APPROX(DISTINCT col, 0.3)")),
    ApproxQuantile,
  )
  t.is_a(e.this(), Distinct) |> ignore
  t.is_a(e.arg("quantile"), Literal) |> ignore
  let e = t.is_a(
    Some(t.validate_identity("PERCENTILE_APPROX(DISTINCT col, 0.3, 200)")),
    ApproxQuantile,
  )
  t.is_a(e.this(), Distinct) |> ignore
  t.is_a(e.arg("quantile"), Literal) |> ignore
  t.is_a(e.arg("accuracy"), Literal) |> ignore
  t.done()
}
