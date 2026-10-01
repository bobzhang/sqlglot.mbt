// Ports of the test_annotate_* / *_annotation unit tests of tests/test_optimizer.py (part 2).

///|
/// `annotate_types(qualify(parse_one(sql, read=dialect), schema=schema, dialect=dialect),
/// schema=schema, dialect=dialect)`
fn qualify_and_annotate(
  sql : String,
  dialect? : String,
  schema? : String,
) -> @core.Expr raise @core.SqlglotError {
  let s = match schema {
    Some(s) => Some(mapping_schema(s, dialect?))
    None => None
  }
  let d = dialect_of(dialect)
  @optimizer.annotate_types(
    @optimizer.qualify(parse_sql(sql, read?=dialect), schema?=s, dialect?=d),
    schema?=s,
    dialect?=d,
  )
}

///|
test "annotate_types: unnest" {
  let expression = @optimizer.annotate_types(
    @optimizer.qualify(
      parse_sql("SELECT a, a.b, a.b.c FROM x, UNNEST(x.a) AS a", read="bigquery"),
    ),
    schema=mapping_schema("{\"x\": {\"a\": \"ARRAY<STRUCT<b STRUCT<c int>>>\"}}"),
  )
  assert_true(type_equals(expression.selects()[0], "STRUCT<b STRUCT<c int>>"))
  assert_true(type_equals(expression.selects()[1], "STRUCT<c int>"))
  assert_true(type_equals(expression.selects()[2], "int"))
  let e = @optimizer.annotate_types(
    @optimizer.qualify(
      parse_sql(
        "SELECT x FROM UNNEST(GENERATE_DATE_ARRAY('2021-01-01', current_date(), interval 1 day)) AS x",
      ),
    ),
  )
  assert_true(type_equals(e.selects()[0], "date"))
  let e = @optimizer.annotate_types(
    @optimizer.qualify(
      parse_sql(
        "SELECT x FROM UNNEST(GENERATE_TIMESTAMP_ARRAY('2016-10-05 00:00:00', '2016-10-06 02:00:00', interval 1 day)) AS x",
      ),
    ),
  )
  assert_true(type_equals(e.selects()[0], "timestamp"))
}

///|
test "annotate_types: unnest struct fields (bigquery)" {
  let expression = qualify_and_annotate(
    "WITH data AS (SELECT [STRUCT('Bob' AS first_name, 'Smith' AS last_name)] AS users) SELECT first_name, last_name FROM data, UNNEST(users)",
    dialect="bigquery",
  )
  assert_true(type_equals(expression.selects()[0], "VARCHAR", dialect="bigquery"))
  assert_true(type_equals(expression.selects()[1], "VARCHAR", dialect="bigquery"))
  let expression = qualify_and_annotate(
    "SELECT person FROM UNNEST([STRUCT('Charlie' AS name, 40 AS age)]) AS person",
    dialect="bigquery",
  )
  let select_type = expression.selects()[0].get_type().unwrap()
  assert_true(select_type.is_type([STRUCT]))
  assert_eq(select_type.expressions().length(), 2)
  let fields : Map[String, @core.Expr] = Map([])
  for col_def in select_type.expressions() {
    fields[col_def.name()] = col_def.arg("kind").unwrap()
  }
  let bigquery = dialect_of(Some("bigquery"))
  assert_true(
    fields["name"].equal(@core.datatype_from_str("VARCHAR", dialect?=bigquery)),
  )
  assert_true(
    fields["age"].equal(@core.datatype_from_str("INT", dialect?=bigquery)),
  )
  let expression = qualify_and_annotate(
    "WITH data AS (SELECT [STRUCT('Bob' AS first_name, 'Smith' AS last_name)] AS users) SELECT first_name, last_name FROM data, UNNEST(users) AS p",
    dialect="bigquery",
  )
  assert_true(type_equals(expression.selects()[0], "VARCHAR", dialect="bigquery"))
  assert_true(type_equals(expression.selects()[1], "VARCHAR", dialect="bigquery"))
  let expression = qualify_and_annotate(
    "SELECT name FROM UNNEST([STRUCT('Charlie' AS name, 40 AS age)]) AS person",
    dialect="bigquery",
  )
  assert_true(
    expression.selects()[0].is_type_expr(
      @core.datatype_from_str("VARCHAR", dialect?=bigquery),
    ),
  )
}

///|
test "annotate_types: maps" {
  // ToMap annotation
  let expression = annotate_sql("SELECT MAP {'x': 1}", read="duckdb")
  assert_true(type_equals(expression.selects()[0], "MAP(VARCHAR, INT)"))
  // Map annotation
  let expression = annotate_sql(
    "SELECT MAP(['key1', 'key2', 'key3'], [10, 20, 30])",
    read="duckdb",
  )
  assert_true(type_equals(expression.selects()[0], "MAP(VARCHAR, INT)"))
  // VarMap annotation
  let expression = annotate_sql("SELECT MAP('a', 'b')", read="spark")
  assert_true(type_equals(expression.selects()[0], "MAP(VARCHAR, VARCHAR)"))
}

///|
test "annotate_types: unions" {
  let cases = [
    ("SELECT 1::INT AS c", "SELECT 2::BIGINT AS c", "BIGINT"),
    ("SELECT 1::INT AS c", "SELECT 2::BIGDECIMAL AS c", "BIGDECIMAL"),
    ("SELECT 1 AS c", "SELECT NULL AS c", "INT"),
    ("SELECT FOO() AS c", "SELECT 1 AS c", "UNKNOWN"),
    ("SELECT FOO() AS c", "SELECT BAR() AS c", "UNKNOWN"),
  ]
  for case_ in cases {
    let (left, right, expected_type) = case_
    let lr = annotate_sql("SELECT t.c FROM (\{left} UNION ALL \{right}) t(c)")
    let rl = annotate_sql("SELECT t.c FROM (\{right} UNION ALL \{left}) t(c)")
    if !type_equals(lr.selects()[0], expected_type) ||
      !type_equals(rl.selects()[0], expected_type) {
      fail(
        "\{left} / \{right}: expected \{expected_type}, got \{tsql(lr.selects()[0])} / \{tsql(rl.selects()[0])}",
      )
    }
  }
  let union_by_name = annotate_sql(
    "SELECT t.a, t.d FROM (SELECT 1 a, 3 d, UNION ALL BY NAME SELECT 7.0 d, 8::BIGINT a) AS t(a, d)",
  )
  assert_eq(tthis(union_by_name.selects()[0]), "BIGINT")
  assert_eq(tthis(union_by_name.selects()[1]), "DOUBLE")

  // BY NAME with differing column counts: missing columns are NULL-filled
  let union_by_name = annotate_sql(
    "SELECT t.a, t.b, t.c FROM (SELECT 1 AS a, 2 AS b UNION BY NAME SELECT 'x' AS c) AS t",
    read="duckdb",
  )
  assert_eq(tthis(union_by_name.selects()[0]), "INT")
  assert_eq(tthis(union_by_name.selects()[1]), "INT")
  assert_eq(tthis(union_by_name.selects()[2]), "VARCHAR")

  // Chained UNIONs and UNIONs with nested subqueries
  for sql in [
    "WITH t AS (SELECT NULL AS col UNION SELECT NULL AS col UNION SELECT 'a' AS col UNION SELECT NULL AS col UNION SELECT NULL AS col) SELECT col FROM t;",
    "WITH t AS (SELECT NULL AS col UNION (SELECT NULL AS col UNION ALL SELECT 'a' AS col)) SELECT col FROM t;",
    "WITH t AS ((SELECT NULL AS col UNION ALL SELECT 'a' AS col) UNION SELECT NULL AS col) SELECT col FROM t;",
  ] {
    assert_eq(
      tthis(@optimizer.optimize(parse_sql(sql)).selects()[0]),
      "VARCHAR",
    )
  }

  // BigQuery: STRING coerces to temporal types in UNION
  let cases = [
    ("SELECT '2010-01-01' AS c", "SELECT DATE '2020-02-02' AS c", "DATE"),
    (
      "SELECT '2010-01-01 00:00:00' AS c", "SELECT DATETIME '2020-02-02 00:00:00' AS c",
      "DATETIME",
    ),
    ("SELECT '00:00:00' AS c", "SELECT TIME '00:01:00' AS c", "TIME"),
    (
      "SELECT '2010-01-01 00:00:00' AS c", "SELECT TIMESTAMP '2020-02-02 00:00:00' AS c",
      "TIMESTAMP",
    ),
  ]
  for case_ in cases {
    let (left, right, expected_type) = case_
    let lr = annotate_sql(
      "SELECT t.c FROM (\{left} UNION ALL \{right}) t(c)",
      read="bigquery",
      dialect="bigquery",
    )
    let rl = annotate_sql(
      "SELECT t.c FROM (\{right} UNION ALL \{left}) t(c)",
      read="bigquery",
      dialect="bigquery",
    )
    if !type_equals(lr.selects()[0], expected_type, dialect="bigquery") ||
      !type_equals(rl.selects()[0], expected_type, dialect="bigquery") {
      fail(
        "\{left} / \{right}: expected \{expected_type}, got \{tsql(lr.selects()[0])} / \{tsql(rl.selects()[0])}",
      )
    }
  }
}

///|
test "annotate_types: udtf (snowflake)" {
  let table_udtf = parse_sql(
    "SELECT * FROM TABLE(GENERATOR(ROWCOUNT => 100000))",
    read="snowflake",
  )
  assert_eq(
    gen_sql(
      @optimizer.annotate_types(table_udtf, dialect?=dialect_of(Some("snowflake"))),
      dialect="snowflake",
    ),
    "SELECT * FROM TABLE(GENERATOR(ROWCOUNT => 100000))",
  )
}

///|
test "annotate_types: manually annotate snowflake" {
  let annotated = qualify_and_annotate(
    "SELECT * FROM \"SCHEMA\".\"TBL\"",
    dialect="snowflake",
    schema="{\"SCHEMA\": {\"TBL\": {\"COL\": \"INT\", \"col2\": \"VARCHAR\"}}}",
  )
  assert_true(annotated.selects()[0].is_type([INT]))
  assert_true(annotated.selects()[1].is_type([VARCHAR]))
}

///|
test "annotate_types: struct (bigquery)" {
  let annotated = qualify_and_annotate(
    "WITH t1 AS (SELECT 'foo' AS c), t2 AS (SELECT ARRAY_AGG(STRUCT(c)) AS arr FROM t1) SELECT arr[0].c FROM t2",
    dialect="bigquery",
  )
  assert_true(type_equals(annotated.selects()[0], "VARCHAR"))
}

///|
test "annotate_types: struct field case sensitivity" {
  let schema = "{\"t\": {\"struct_col\": \"STRUCT<fooBar STRING>\"}}"
  let cases = [
    // BigQuery is case-insensitive
    ("SELECT struct_col.fooBar FROM t", "bigquery", "TEXT"),
    ("SELECT struct_col.foobar FROM t", "bigquery", "TEXT"),
    ("SELECT struct_col.Foobar FROM t", "bigquery", "TEXT"),
    // ClickHouse is case-sensitive
    ("SELECT struct_col.fooBar FROM t", "clickhouse", "TEXT"),
    ("SELECT struct_col.foobar FROM t", "clickhouse", "UNKNOWN"),
  ]
  for case_ in cases {
    let (query, dialect, expected) = case_
    let annotated = qualify_and_annotate(query, dialect~, schema~)
    if tthis(annotated.selects()[0]) != expected {
      fail("\{dialect} \{query}: expected \{expected}, got \{tthis(annotated.selects()[0])}")
    }
  }
}

///|
test "annotate_types: OBJECT_CONSTRUCT (snowflake)" {
  let annotated = annotate_sql(
    "SELECT OBJECT_CONSTRUCT('foo', 'bar', 'a b', 'c d') AS c",
    read="snowflake",
    dialect="snowflake",
  )
  assert_eq(
    annotated.selects()[0].get_type().unwrap() |> gen_sql(dialect="snowflake"),
    "OBJECT(\"foo\" VARCHAR, \"a b\" VARCHAR)",
  )
}

///|
/// `expression.meta.get("nonnull")`
fn nonnull(e : @core.Expr) -> Bool? {
  match e.meta_get("nonnull") {
    Some(Bool(b)) => Some(b)
    _ => None
  }
}

///|
test "annotate_types: nonnull" {
  for literal_sql in ["1", "'foo'", "2.5"] {
    let annotated = annotate_sql("SELECT \{literal_sql}")
    assert_eq(nonnull(annotated.selects()[0]), Some(true))
  }
  let schema = "{\"foo\": {\"id\": \"INT\"}}"
  let operand_pairs : Array[(String, String, Bool?)] = [
    ("1", "1", Some(true)),
    ("foo.id", "foo.id", None),
    ("1", "foo.id", None),
    ("foo.id", "1", None),
  ]
  let predicates = [">", "<", ">=", "<=", "=", "!=", "<>", "LIKE", "NOT LIKE"]
  for predicate in predicates {
    for pair in operand_pairs {
      let (operand1, operand2, expected) = pair
      let sql = "SELECT \{operand1} \{predicate} \{operand2} FROM foo"
      assert_eq(nonnull(annotate_sql(sql, schema~).selects()[0]), expected)
    }
  }
  for predicate in ["IS NULL", "IS NOT NULL"] {
    let sql = "SELECT foo.id \{predicate} FROM foo"
    assert_eq(nonnull(annotate_sql(sql, schema~).selects()[0]), Some(true))
  }
  for connector in ["AND", "OR"] {
    for predicate in predicates {
      for pair in operand_pairs {
        let (operand1, operand2, expected) = pair
        let p = "(\{operand1} \{predicate} \{operand2})"
        let sql = "SELECT \{p} \{connector} \{p} FROM foo"
        assert_eq(nonnull(annotate_sql(sql, schema~).selects()[0]), expected)
      }
    }
  }
  for unary in ["NOT", "-"] {
    for pair in [("1", Some(true)), ("foo.id", None)] {
      let (value, expected) = pair
      let sql = "SELECT \{unary} \{value} FROM foo"
      assert_eq(nonnull(annotate_sql(sql, schema~).selects()[0]), expected)
    }
  }
  // ClickHouse: non-Nullable column types are NOT NULL
  let ch_schema = "{\"t\": {\"c1\": \"Int32\", \"c2\": \"Nullable(Int32)\"}}"
  let s = mapping_schema(ch_schema, dialect="clickhouse")
  let clickhouse = dialect_of(Some("clickhouse"))
  let qualified_query = @optimizer.qualify_columns(
    parse_sql("select c1, c2 from t"),
    s,
  )
  let annotated = @optimizer.annotate_types(
    qualified_query,
    schema=s,
    dialect?=clickhouse,
  )
  assert_eq(nonnull(annotated.selects()[0]), Some(true))
  assert_eq(nonnull(annotated.selects()[1]), None)
}

///|
test "annotate_types: deep ASTs" {
  let union_sql = "SELECT 1 UNION ALL ".repeat(2000) + "SELECT 1"
  let annotated = annotate_sql(union_sql)
  assert_eq(gen_sql(annotated), union_sql)
  assert_eq(tthis(annotated.selects()[0]), "INT")
  let binary_sql = "SELECT " + "t.a + ".repeat(2000) + "t.a FROM t"
  let annotated = annotate_sql(binary_sql, schema="{\"t\": {\"a\": \"INT\"}}")
  assert_eq(gen_sql(annotated), binary_sql)
  assert_eq(tthis(annotated.selects()[0]), "INT")
}

///|
test "annotate_types: NULL coercion (bigquery)" {
  for null_sql in [
    "SELECT t.foo FROM (SELECT CAST(1 AS BIGDECIMAL) AS foo UNION ALL SELECT NULL AS foo) AS t",
    "SELECT t.foo FROM (SELECT NULL AS foo UNION ALL SELECT CAST(1 AS BIGDECIMAL) AS foo) AS t",
  ] {
    let annotated = annotate_sql(null_sql, read="bigquery", dialect="bigquery")
    assert_eq(gen_sql(annotated), null_sql)
    assert_eq(tthis(annotated.selects()[0]), "BIGDECIMAL")
  }
}

///|
test "annotate_types: correlated subqueries" {
  let annotated = qualify_and_annotate(
    "SELECT (SELECT col) FROM t",
    dialect="bigquery",
    schema="{\"t\": {\"col\": \"BIGNUMERIC\"}}",
  )
  assert_eq(
    gen_sql(annotated, dialect="bigquery"),
    "SELECT (SELECT `t`.`col` AS `col`) AS `_col_0` FROM `t` AS `t`",
  )
  assert_true(type_equals(annotated.selects()[0], "BIGNUMERIC", dialect="bigquery"))
  let annotated = qualify_and_annotate(
    "SELECT (SELECT MAX(u_x) FROM UNNEST([1, d_x]) AS u_x WHERE u_x < d_z) AS c_i FROM (SELECT CAST(20 AS BIGNUMERIC) AS d_x, 30 AS d_z) AS d_t",
    dialect="bigquery",
    schema="{\"d_t\": {\"d_x\": \"STRING\"}}",
  )
  assert_eq(
    gen_sql(annotated, dialect="bigquery"),
    "SELECT (SELECT MAX(`u_x`) AS `_col_0` FROM UNNEST([1, `d_t`.`d_x`]) AS `u_x` WHERE `u_x` < `d_t`.`d_z`) AS `c_i` FROM (SELECT CAST(20 AS BIGNUMERIC) AS `d_x`, 30 AS `d_z`) AS `d_t`",
  )
  assert_true(type_equals(annotated.selects()[0], "BIGNUMERIC", dialect="bigquery"))
  let annotated = qualify_and_annotate(
    "SELECT (SELECT col FROM t) as u FROM (SELECT 1 AS col) AS t",
    schema="{\"t\": {\"col\": \"TEXT\"}}",
  )
  assert_eq(
    gen_sql(annotated),
    "SELECT (SELECT \"t\".\"col\" AS \"col\" FROM \"t\" AS \"t\") AS \"u\" FROM (SELECT 1 AS \"col\") AS \"t\"",
  )
  assert_true(type_equals(annotated.selects()[0], "TEXT"))
}

///|
test "annotate_types: ORDER BY aliases" {
  let schema = "{\"t\": {\"x\": \"INT\", \"z\": \"TEXT\", \"category\": \"TEXT\", \"col\": \"INT\"}, \"u\": {\"a\": \"INT\", \"x\": \"INT\"}}"
  fn order_types(sql : String) -> Array[String] raise {
    let annotated = qualify_and_annotate(sql, schema~)
    let order = annotated.find([Order]).unwrap()
    order.expressions().map(o => tsql(o.this_()))
  }

  let cases : Array[(String, Array[String])] = [
    // Basic alias resolution
    ("SELECT x + 1 AS y FROM t ORDER BY y", ["INT"]),
    ("SELECT x, z FROM t ORDER BY x", ["INT"]),
    (
      "SELECT category, COUNT(*) AS cnt FROM t GROUP BY category ORDER BY cnt",
      ["BIGINT"],
    ),
    (
      "SELECT CASE WHEN x > 0 THEN 'a' ELSE 'b' END AS label FROM t ORDER BY label",
      ["VARCHAR"],
    ),
    ("SELECT CAST(x AS TEXT) AS s FROM t ORDER BY s", ["TEXT"]),
    // Alias shadows column name
    ("SELECT z AS x FROM t ORDER BY x", ["TEXT"]),
    // Alias shadows column from joined table (ambiguous column, alias wins)
    ("SELECT t.x + u.a AS a FROM t, u ORDER BY a", ["INT"]),
    // Alias shadows column across cross-join (u also has x)
    ("SELECT t.z AS x FROM t, u ORDER BY x", ["TEXT"]),
    // CTE name collides with alias
    (
      "WITH y AS (SELECT 999 AS v) SELECT x + 1 AS y FROM t ORDER BY y",
      ["INT"],
    ),
    // Column name equals alias name (self-referential guard)
    ("SELECT x FROM t ORDER BY x", ["INT"]),
    // Multiple ORDER BY columns
    ("SELECT x + 1 AS y, z AS w FROM t ORDER BY y, w", ["INT", "TEXT"]),
    // Sort modifiers
    ("SELECT x + 1 AS y FROM t ORDER BY y DESC", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY y NULLS FIRST", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY y DESC NULLS LAST", ["INT"]),
    // Three-column sort with mixed ASC/DESC
    (
      "SELECT x + 1 AS y, z AS w, category AS c FROM t ORDER BY y ASC, w DESC, c ASC",
      ["INT", "TEXT", "TEXT"],
    ),
    // Compound expressions using aliases
    ("SELECT x + 1 AS y FROM t ORDER BY y + 1", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY (y + 1) * 2", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY ((y + 1) * 2) + 3", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY ABS(y + 1)", ["INT"]),
    ("SELECT x + 1 AS y FROM t ORDER BY COALESCE(y, 0) + 1", ["INT"]),
    (
      "SELECT x AS a, z AS b FROM t ORDER BY CONCAT(b, CAST(a AS TEXT))",
      ["VARCHAR"],
    ),
    // Non-projected column in ORDER BY
    ("SELECT x FROM t ORDER BY z", ["TEXT"]),
    // Mixed alias + expression
    ("SELECT x + 1 AS y FROM t ORDER BY y, x + 2", ["INT", "INT"]),
    // GROUP BY + ORDER BY alias
    ("SELECT x + 1 AS y FROM t GROUP BY y ORDER BY y", ["INT"]),
    // Set operations
    ("SELECT x AS y FROM t UNION ALL SELECT a FROM u ORDER BY y", ["INT"]),
    ("SELECT x AS y FROM t UNION SELECT a FROM u ORDER BY y", ["INT"]),
    ("SELECT x AS y FROM t INTERSECT SELECT a FROM u ORDER BY y", ["INT"]),
    ("SELECT x AS y FROM t EXCEPT SELECT a FROM u ORDER BY y", ["INT"]),
    ("SELECT x AS y FROM t UNION ALL SELECT a FROM u ORDER BY y + 1", ["INT"]),
    ("SELECT x AS y FROM t UNION ALL SELECT a FROM u ORDER BY 1", ["INT"]),
    // Subquery with ORDER BY
    ("SELECT * FROM (SELECT x AS y FROM t ORDER BY y) AS sub", ["INT"]),
    // Window function alias (SUM is typed, unlike ROW_NUMBER)
    ("SELECT SUM(x) OVER () AS s FROM t ORDER BY s", ["BIGINT"]),
    // Subquery-as-projection alias
    ("SELECT (SELECT MAX(a) FROM u) AS m FROM t ORDER BY m", ["INT"]),
    // Alias name collides with table name
    ("SELECT (SELECT MAX(a) FROM u) AS u FROM t ORDER BY u", ["INT"]),
    // Type coercion through lazy annotation
    (
      "SELECT CASE WHEN x > 0 THEN x ELSE CAST(x AS BIGINT) END AS y FROM t ORDER BY y",
      ["BIGINT"],
    ),
    // Subquery in ORDER BY with alias name clash (inner col is table-qualified)
    ("SELECT x AS a FROM t ORDER BY (SELECT MAX(a) FROM u)", ["INT"]),
    // CAST in ORDER BY using alias
    ("SELECT x AS y FROM t ORDER BY CAST(y AS TEXT)", ["TEXT"]),
    // Duplicate alias (last wins, consistent with _expand_alias_refs)
    ("SELECT x AS y, z AS y FROM t ORDER BY y", ["TEXT"]),
    // Compound ORDER BY with subquery (reannotation skips inner scope)
    ("SELECT x AS y FROM t ORDER BY y + (SELECT MAX(a) FROM u)", ["INT"]),
  ]
  for case_ in cases {
    let (sql, expected) = case_
    let got = order_types(sql)
    if got != expected {
      fail("\{sql}: expected \{Repr(expected)}, got \{Repr(got)}")
    }
  }

  // Regression: correlated subquery — no recursion error
  qualify_and_annotate("SELECT (SELECT col) FROM t", schema~) |> ignore
  // Regression: self-referential alias (BigQuery pseudocolumn pattern)
  qualify_and_annotate(
    "SELECT _col AS _col FROM t",
    schema="{\"t\": {\"_col\": \"INT\"}}",
  )
  |> ignore
}
