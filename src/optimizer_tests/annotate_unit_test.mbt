// Ports of the test_annotate_* / *_annotation unit tests of tests/test_optimizer.py.

///|
/// `annotate_types(parse_one(sql, read=read), schema=schema, dialect=dialect)`
fn annotate_sql(
  sql : String,
  read? : String,
  schema? : String,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let schema = match schema {
    Some(s) => Some(mapping_schema(s, dialect?))
    None => None
  }
  @optimizer.annotate_types(
    parse_sql(sql, read?),
    schema?,
    dialect?=dialect_of(dialect),
  )
}

///|
/// `expression.type.this`, as the `DType` name (`"None"` when there's no type).
fn tthis(e : @core.Expr) -> String {
  match e.get_type() {
    Some(t) =>
      match t.datatype_this() {
        Some(d) => d.name()
        None => "?"
      }
    None => "None"
  }
}

///|
/// `expression.type.sql(dialect)`
fn tsql(e : @core.Expr, dialect? : String) -> String raise @core.SqlglotError {
  match e.get_type() {
    Some(t) => gen_sql(t, dialect?)
    None => "None"
  }
}

///|
/// `expression.type == exp.DataType.build(dtype, dialect=dialect)`
fn type_equals(
  e : @core.Expr,
  dtype : String,
  dialect? : String,
) -> Bool raise @core.SqlglotError {
  match e.get_type() {
    Some(t) =>
      t.equal(@core.datatype_from_str(dtype, dialect?=dialect_of(dialect)))
    None => false
  }
}

///|
test "annotate_types: set operation with a VALUES operand" {
  @optimizer.annotate_types(
    @core.select_star_from(Some(select_1_union_values().subquery(alias_="s"))),
  )
  |> ignore
}

///|
test "annotate_types: untyped binary operands" {
  let annotator = @optimizer.TypeAnnotator::new(@optimizer.MappingSchema::new())
  let binary = parse_sql("a + b")
  annotator.annotate_binary(binary)
  assert_true(binary.is_type([UNKNOWN]))
  let div = parse_sql("a / b")
  annotator.annotate_div(div)
  assert_true(div.is_type([UNKNOWN]))
}

///|
test "annotate_types: json dot parts preserve meta" {
  let schema = "{\"cat\": {\"sch\": {\"t\": {\"id\": \"varchar\", \"payload\": \"json\"}}}}"
  let sql = "SELECT payload.CaseSensitive FROM cat.sch.t"
  let snowflake = dialect_of(Some("snowflake"))
  let s = mapping_schema(schema, dialect="snowflake")
  let qualified = @optimizer.qualify(
    parse_sql(sql, read="duckdb"),
    schema=s,
    dialect?=snowflake,
    quote_identifiers=false,
  )
  let annotated = @optimizer.annotate_types(
    qualified,
    schema=s,
    dialect?=snowflake,
  )
  let identifier = annotated.selects()[0].this_().expression_()
  assert_true(identifier.kind == Identifier)
  assert_eq(identifier.name(), "CaseSensitive")
  assert_true(identifier.bool_arg("quoted"))
  guard identifier.meta_get("start") is Some(Int(start)) &&
    identifier.meta_get("end") is Some(Int(end)) else {
    fail("missing token positions")
  }
  assert_eq(sql[start.to_int():end.to_int() + 1].to_owned(), "CaseSensitive")
}

///|
test "annotate_types: semi-structured dot parts (duckdb)" {
  let schema = "{\"t\": {\"m\": \"MAP(VARCHAR, INT)\", \"v\": \"VARIANT\", \"j\": \"JSON\", \"s\": \"STRUCT(Foo INT)\"}}"
  let cases = [
    ("SELECT m.Foo FROM t", "SELECT \"t\".\"m\".\"Foo\" AS \"foo\" FROM \"t\" AS \"t\""),
    ("SELECT v.Foo FROM t", "SELECT \"t\".\"v\".\"Foo\" AS \"foo\" FROM \"t\" AS \"t\""),
    (
      "SELECT j.Foo.Bar FROM t", "SELECT \"t\".\"j\".\"Foo\".\"Bar\" AS \"bar\" FROM \"t\" AS \"t\"",
    ),
    ("SELECT s.Foo FROM t", "SELECT \"t\".\"s\".\"foo\" AS \"foo\" FROM \"t\" AS \"t\""),
    // Roots that are already qualified drop a different number of leading dot parts
    ("SELECT t.m.Foo FROM t", "SELECT \"t\".\"m\".\"Foo\" AS \"foo\" FROM \"t\" AS \"t\""),
    (
      "SELECT t.j.Foo.Bar FROM t", "SELECT \"t\".\"j\".\"Foo\".\"Bar\" AS \"bar\" FROM \"t\" AS \"t\"",
    ),
    (
      "SELECT x.j.Foo FROM t AS x", "SELECT \"x\".\"j\".\"Foo\" AS \"foo\" FROM \"t\" AS \"x\"",
    ),
  ]
  for case_ in cases {
    let (sql, expected) = case_
    let s = mapping_schema(schema, dialect="duckdb")
    let duckdb = dialect_of(Some("duckdb"))
    let qualified = @optimizer.qualify(
      parse_sql(sql, read="duckdb"),
      schema=s,
      dialect?=duckdb,
    )
    let annotated = @optimizer.annotate_types(
      qualified,
      schema=s,
      dialect?=duckdb,
    )
    assert_eq(gen_sql(annotated, dialect="duckdb"), expected)
  }
}

///|
test "annotate_types: dot parts of non-column roots" {
  let cases = [
    (
      "SELECT PARSE_JSON('{\"Foo\":1}').Foo", "bigquery", "SELECT PARSE_JSON('{\"Foo\":1}').`Foo` AS `foo`",
    ),
    (
      "SELECT ('{\"Foo\":1}'::JSON).Foo", "duckdb", "SELECT (CAST('{\"Foo\":1}' AS JSON)).\"Foo\" AS \"foo\"",
    ),
    // Every part of the chain is restored, not just the innermost one
    (
      "SELECT PARSE_JSON('{\"Foo\":{\"Bar\":1}}').Foo.Bar", "bigquery", "SELECT PARSE_JSON('{\"Foo\":{\"Bar\":1}}').`Foo`.`Bar` AS `bar`",
    ),
    (
      "SELECT ('{\"Foo\":{\"Bar\":{\"Baz\":1}}}'::JSON).Foo.Bar.Baz", "duckdb", "SELECT (CAST('{\"Foo\":{\"Bar\":{\"Baz\":1}}}' AS JSON)).\"Foo\".\"Bar\".\"Baz\" AS \"baz\"",
    ),
    // Dot access that doesn't name a key is left alone
    (
      "SELECT ('{\"Foo\":1}'::JSON).*", "duckdb", "SELECT (CAST('{\"Foo\":1}' AS JSON)).*",
    ),
  ]
  for case_ in cases {
    let (sql, dialect, expected) = case_
    let d = dialect_of(Some(dialect))
    let qualified = @optimizer.qualify(parse_sql(sql, read=dialect), dialect?=d)
    let annotated = @optimizer.annotate_types(qualified, dialect?=d)
    assert_eq(gen_sql(annotated, dialect~), expected)
  }
}

///|
test "annotate_types: cast" {
  let expression = annotate_sql("CAST('2020-01-01' AS TIMESTAMPTZ(9))")
  assert_eq(tthis(expression), "TIMESTAMPTZ")
  assert_eq(tthis(expression.this_()), "VARCHAR")
  assert_eq(tthis(expression.arg("to").unwrap()), "TIMESTAMPTZ")
  assert_eq(
    tthis(expression.arg("to").unwrap().expressions()[0].this_()),
    "INT",
  )
  let expression = annotate_sql("ARRAY(1)::ARRAY<INT>")
  assert_true(
    expression.get_type().unwrap().equal(@core.parse_one("ARRAY<INT>", into=[DataType])),
  )
  let expression = annotate_sql("CAST(x AS INTERVAL)")
  assert_eq(tthis(expression), "INTERVAL")
  assert_eq(tthis(expression.this_()), "UNKNOWN")
  assert_eq(tthis(expression.arg("to").unwrap()), "INTERVAL")
}

///|
test "annotate_types: cache statement" {
  let expression = annotate_sql(
    "CACHE LAZY TABLE x OPTIONS('storageLevel' = 'value') AS SELECT 1",
  )
  assert_eq(tthis(expression.expression_().expressions()[0]), "INT")
}

///|
test "annotate_types: binary" {
  let expression = annotate_sql("SELECT 0.0 + (2 + 3)").expressions()[0]
  assert_eq(tthis(expression), "DOUBLE")
  assert_eq(tthis(expression.this_()), "DOUBLE")
  assert_eq(tthis(expression.expression_()), "INT")
  assert_eq(tthis(expression.expression_().this_()), "INT")
  assert_eq(tthis(expression.expression_().this_().this_()), "INT")
  assert_eq(tthis(expression.expression_().this_().expression_()), "INT")
  for numeric_type in ["BIGINT", "DOUBLE", "INT"] {
    let expression = annotate_sql("SELECT '1' + CAST(x AS \{numeric_type})").expressions()[0]
    assert_true(type_equals(expression, numeric_type))
  }
}

///|
test "annotate_types: typed division" {
  let expressions = annotate_sql("SELECT 2 / 3, 2 / 3.0", read="presto").expressions()
  assert_eq(tthis(expressions[0]), "BIGINT")
  assert_eq(tthis(expressions[1]), "DOUBLE")
  let expressions = annotate_sql(
    "SELECT SUM(2 / 3), CAST(2 AS DECIMAL) / 3",
    read="mysql",
  ).expressions()
  assert_eq(tthis(expressions[0]), "DOUBLE")
  assert_eq(tthis(expressions[0].this_()), "DOUBLE")
  assert_eq(tthis(expressions[1]), "DECIMAL")
}

///|
test "annotate_types: bracket" {
  let expression = annotate_sql("SELECT A[:]").expressions()[0]
  assert_eq(tthis(expression), "UNKNOWN")
  assert_eq(tthis(expression.expressions()[0]), "UNKNOWN")
  let expression = annotate_sql("SELECT ARRAY[1, 2, 3][1]").expressions()[0]
  assert_eq(tsql(expression.this_()), "ARRAY<INT>")
  assert_eq(tthis(expression), "INT")
  let expression = annotate_sql("SELECT ARRAY[1, 2, 3][1 : 2]").expressions()[0]
  assert_eq(tsql(expression.this_()), "ARRAY<INT>")
  assert_eq(tsql(expression), "ARRAY<INT>")
  let expression = annotate_sql(
    "SELECT ARRAY[ARRAY[1], ARRAY[2], ARRAY[3]][1][2]",
  ).expressions()[0]
  assert_eq(tsql(expression.this_().this_()), "ARRAY<ARRAY<INT>>")
  assert_eq(tsql(expression.this_()), "ARRAY<INT>")
  assert_eq(tthis(expression), "INT")
  let expression = annotate_sql(
    "SELECT ARRAY[ARRAY[1], ARRAY[2], ARRAY[3]][1:2]",
  ).expressions()[0]
  assert_eq(tsql(expression), "ARRAY<ARRAY<INT>>")
  let expression = annotate_sql("MAP(1.0, 2, '2', 3.0)['2']", read="spark")
  assert_eq(tthis(expression), "DOUBLE")
  let expression = annotate_sql("MAP(1.0, 2, x, 3.0)[2]", read="spark")
  assert_eq(tthis(expression), "UNKNOWN")
  let expression = annotate_sql("MAP(ARRAY(1.0, x), ARRAY(2, 3.0))[x]")
  assert_eq(tthis(expression), "DOUBLE")
  let expression = annotate_sql(
    "SELECT MAP(1.0, 2, 2, t.y)[2] FROM t",
    read="spark",
    schema="{\"t\": {\"y\": \"int\"}}",
  ).expressions()[0]
  assert_eq(tthis(expression), "INT")
}

///|
test "annotate_types: interval math" {
  let schema = "{\"x\": {\"a\": \"DATE\", \"b\": \"DATETIME\"}}"
  let cases = [
    ("SELECT '2023-01-01' + INTERVAL '1' DAY", "DATE"),
    ("SELECT '2023-01-01' + INTERVAL '1' HOUR", "DATETIME"),
    ("SELECT '2023-01-01 00:00:01' + INTERVAL '1' HOUR", "DATETIME"),
    ("SELECT 'nonsense' + INTERVAL '1' DAY", "UNKNOWN"),
    ("SELECT x.a + INTERVAL '1' DAY FROM x AS x", "DATE"),
    ("SELECT x.a + INTERVAL '1' HOUR FROM x AS x", "DATETIME"),
    ("SELECT x.b + INTERVAL '1' DAY FROM x AS x", "DATETIME"),
    ("SELECT x.b + INTERVAL '1' HOUR FROM x AS x", "DATETIME"),
    ("SELECT DATE_ADD('2023-01-01', 1, 'DAY')", "DATE"),
    ("SELECT DATE_ADD('2023-01-01 00:00:00', 1, 'DAY')", "DATETIME"),
    ("SELECT DATE_ADD(x.a, 1, 'DAY') FROM x AS x", "DATE"),
    ("SELECT DATE_ADD(x.a, 1, 'HOUR') FROM x AS x", "DATETIME"),
    ("SELECT DATE_ADD(x.b, 1, 'DAY') FROM x AS x", "DATETIME"),
    ("SELECT DATE_TRUNC('DAY', x.a) FROM x AS x", "DATE"),
    ("SELECT DATE_TRUNC('DAY', x.b) FROM x AS x", "DATETIME"),
    ("SELECT DATE_TRUNC('SECOND', x.a) FROM x AS x", "DATETIME"),
    ("SELECT DATE_TRUNC('DAY', '2023-01-01') FROM x AS x", "DATE"),
    ("SELECT DATEDIFF('2023-01-01', '2023-01-02', DAY) FROM x AS x", "INT"),
  ]
  for case_ in cases {
    let (sql, expected_type) = case_
    let expression = annotate_sql(sql, schema~)
    if tthis(expression.expressions()[0]) != expected_type {
      fail("\{sql}: expected \{expected_type}, got \{tthis(expression.expressions()[0])}")
    }
    assert_eq(gen_sql(expression), sql)
  }
}

///|
test "annotate_types: lateral" {
  let expression = @optimizer.optimize(
    parse_sql("SELECT c FROM (select 1 a) as x LATERAL VIEW EXPLODE (a) AS c"),
  ).expressions()[0]
  assert_eq(tthis(expression), "INT")
}

///|
test "annotate_types: derived table columns" {
  let schema = "{\"x\": {\"cola\": \"INT\"}, \"y\": {\"cola\": \"FLOAT\"}}"
  let sql = "SELECT a.cola AS cola FROM (SELECT x.cola + y.cola AS cola FROM (SELECT x.cola AS cola FROM x AS x) AS x JOIN (SELECT y.cola AS cola FROM y AS y) AS y) AS a"
  let expression = annotate_sql(sql, schema~)
  assert_eq(tthis(expression.expressions()[0]), "FLOAT")
  let addition_alias = expression.arg("from_").unwrap().this_().this_().expressions()[0]
  assert_eq(tthis(addition_alias), "FLOAT")
  let addition = addition_alias.this_()
  assert_eq(tthis(addition), "FLOAT")
  assert_eq(tthis(addition.this_()), "INT")
  assert_eq(tthis(addition.expression_()), "FLOAT")
}

///|
test "annotate_types: cte columns" {
  let schema = "{\"x\": {\"cola\": \"CHAR\"}, \"y\": {\"colb\": \"TEXT\", \"colc\": \"BOOLEAN\"}}"
  let sql = "WITH tbl AS (SELECT x.cola + 'bla' AS cola, y.colb AS colb, y.colc AS colc FROM (SELECT x.cola AS cola FROM x AS x) AS x JOIN (SELECT y.colb AS colb, y.colc AS colc FROM y AS y) AS y) SELECT tbl.cola + tbl.colb + 'foo' AS col FROM tbl AS tbl WHERE tbl.colc = True"
  let expression = annotate_sql(sql, schema~)
  assert_eq(tthis(expression.expressions()[0]), "TEXT")
  let outer_addition = expression.expressions()[0].this_()
  assert_eq(tthis(outer_addition), "TEXT")
  assert_eq(tthis(outer_addition.this_()), "TEXT")
  assert_eq(tthis(outer_addition.expression_()), "VARCHAR")
  let inner_addition = outer_addition.this_()
  assert_eq(tthis(inner_addition.this_()), "VARCHAR")
  assert_eq(tthis(inner_addition.expression_()), "TEXT")
  assert_eq(tthis(expression.arg("where").unwrap().this_()), "BOOLEAN")
  let cte_select = expression.arg("with_").unwrap().expressions()[0].this_()
  assert_eq(tthis(cte_select.expressions()[0]), "VARCHAR")
  assert_eq(tthis(cte_select.expressions()[1]), "TEXT")
  assert_eq(tthis(cte_select.expressions()[2]), "BOOLEAN")
  let cte_select_addition = cte_select.expressions()[0].this_()
  assert_eq(tthis(cte_select_addition), "VARCHAR")
  assert_eq(tthis(cte_select_addition.this_()), "CHAR")
  assert_eq(tthis(cte_select_addition.expression_()), "VARCHAR")
  let subqueries = cte_select.find_all([Subquery]).collect()
  let expected = ["CHAR", "TEXT"]
  for i, d in subqueries {
    if i < expected.length() {
      assert_eq(tthis(d.this_().expressions()[0].this_()), expected[i])
    }
  }
}

///|
test "annotate_types: functions" {
  let schema = "{\"x\": {\"cola\": \"VARCHAR\", \"colb\": \"CHAR\"}}"
  let sql = "SELECT x.cola || TRIM(x.colb) AS col, DATE(x.colb), DATEFROMPARTS(y, m, d) FROM x AS x"
  let expression = annotate_sql(sql, schema~)
  let concat_expr_alias = expression.expressions()[0]
  assert_eq(tthis(concat_expr_alias), "VARCHAR")
  let concat_expr = concat_expr_alias.this_()
  assert_eq(tthis(concat_expr), "VARCHAR")
  assert_eq(tthis(concat_expr.this_()), "VARCHAR")
  assert_eq(tthis(concat_expr.expression_()), "VARCHAR")
  assert_eq(tthis(concat_expr.expression_().this_()), "CHAR")
  assert_eq(tthis(expression.expressions()[1]), "DATE")
  assert_eq(tthis(expression.expressions()[2]), "DATE")
  let sql = "SELECT CASE WHEN 1=1 THEN x.cola ELSE x.colb END AS col FROM x AS x"
  let case_expr_alias = annotate_sql(sql, schema~).expressions()[0]
  assert_eq(tthis(case_expr_alias), "VARCHAR")
  let case_expr = case_expr_alias.this_()
  assert_eq(tthis(case_expr), "VARCHAR")
  assert_eq(tthis(case_expr.arg("default").unwrap()), "CHAR")
  let case_ifs_expr = case_expr.list("ifs")[0]
  assert_eq(tthis(case_ifs_expr), "VARCHAR")
  assert_eq(tthis(case_ifs_expr.arg("true").unwrap()), "VARCHAR")
  assert_eq(tthis(annotate_sql("TIMESTAMP(x)")), "TIMESTAMP")
  assert_eq(tthis(annotate_sql("TIMESTAMP(x)", read="bigquery")), "TIMESTAMPTZ")
}

///|
test "annotate_types: unknown" {
  let schema = "{\"x\": {\"cola\": \"VARCHAR\"}}"
  let sql = "SELECT x.cola + SOME_ANONYMOUS_FUNC(x.cola) AS col FROM x AS x"
  let concat_expr_alias = annotate_sql(sql, schema~).expressions()[0]
  assert_eq(tthis(concat_expr_alias), "UNKNOWN")
  let concat_expr = concat_expr_alias.this_()
  assert_eq(tthis(concat_expr), "UNKNOWN")
  assert_eq(tthis(concat_expr.this_()), "VARCHAR")
  assert_eq(tthis(concat_expr.expression_()), "UNKNOWN")
  assert_eq(tthis(concat_expr.expression_().expressions()[0]), "VARCHAR")
  // Ensures we don't raise if there are unqualified columns
  annotate_sql("select x from y lateral view explode(y) as x") |> ignore
  // NULL <op> UNKNOWN should yield UNKNOWN
  assert_eq(
    tthis(annotate_sql("SELECT NULL + ANONYMOUS_FUNC()").expressions()[0]),
    "UNKNOWN",
  )
}

///|
fn udf_schema(
  schema : String,
  udfs : String,
) -> @optimizer.MappingSchema raise @core.SqlglotError {
  @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(schema),
    udf_mapping=@optimizer.schema_from_json_string(udfs),
  )
}

///|
test "annotate_types: udfs" {
  // Unqualified UDF
  let schema = udf_schema(
    "{\"t\": {\"col\": \"INT\"}}",
    "{\"my_func\": \"VARCHAR\"}",
  )
  let expr = @optimizer.annotate_types(
    parse_sql("SELECT my_func(col) FROM t"),
    schema~,
  )
  assert_eq(tthis(expr.selects()[0]), "VARCHAR")

  // Qualified UDF (2-level)
  let schema = udf_schema(
    "{\"db\": {\"t\": {\"col\": \"INT\"}}}",
    "{\"db\": {\"my_func\": \"DOUBLE\"}}",
  )
  let expr = @optimizer.annotate_types(
    parse_sql("SELECT db.my_func(col) FROM db.t"),
    schema~,
  )
  let anon = expr.selects()[0].find([Anonymous]).unwrap()
  assert_eq(tthis(anon), "DOUBLE")
  // Dot parent should also have the type
  assert_eq(tthis(expr.selects()[0]), "DOUBLE")

  // Qualified UDF (3-level)
  let schema = udf_schema(
    "{\"cat\": {\"db\": {\"t\": {\"col\": \"INT\"}}}}",
    "{\"cat\": {\"db\": {\"my_func\": \"BOOLEAN\"}}}",
  )
  let expr = @optimizer.annotate_types(
    parse_sql("SELECT cat.db.my_func(col) FROM cat.db.t"),
    schema~,
  )
  let anon = expr.selects()[0].find([Anonymous]).unwrap()
  assert_eq(tthis(anon), "BOOLEAN")

  // Unknown UDF returns UNKNOWN
  let schema = udf_schema(
    "{\"t\": {\"col\": \"INT\"}}",
    "{\"known_func\": \"DATE\"}",
  )
  let expr = @optimizer.annotate_types(
    parse_sql("SELECT unknown_func(col) FROM t"),
    schema~,
  )
  assert_eq(tthis(expr.selects()[0]), "UNKNOWN")

  // get_udf_type with string input
  let dtype = fn(udfs : String, udf : String) raise {
    @optimizer.MappingSchema::new(
      udf_mapping=@optimizer.schema_from_json_string(udfs),
    )
    .get_udf_type_str(udf)
    .datatype_this()
    .unwrap()
    .name()
  }
  assert_eq(dtype("{\"my_func\": \"INT\"}", "my_func(x)"), "INT")
  assert_eq(dtype("{\"db\": {\"my_func\": \"FLOAT\"}}", "db.my_func(x, y)"), "FLOAT")
  assert_eq(
    dtype("{\"cat\": {\"db\": {\"my_func\": \"DATE\"}}}", "cat.db.my_func(a, b, c)"),
    "DATE",
  )
  // Unknown UDF string returns UNKNOWN
  assert_eq(dtype("{\"known\": \"INT\"}", "unknown(x)"), "UNKNOWN")
}

///|
test "annotate_types: predicates" {
  assert_eq(tthis(annotate_sql("x BETWEEN a AND b")), "BOOLEAN")
  assert_eq(tthis(annotate_sql("x IN (a, b, c, d)")), "BOOLEAN")
}

///|
test "annotate_types: aggregate functions" {
  let schema = "{\"x\": {\"cola\": \"SMALLINT\", \"colb\": \"FLOAT\", \"colc\": \"TEXT\", \"cold\": \"DATE\"}}"
  let tests = [
    ("AVG", "cola", "DOUBLE"),
    ("SUM", "cola", "BIGINT"),
    ("SUM", "colb", "DOUBLE"),
    ("MIN", "cola", "SMALLINT"),
    ("MIN", "colb", "FLOAT"),
    ("MAX", "colc", "TEXT"),
    ("MAX", "cold", "DATE"),
    ("COUNT", "colb", "BIGINT"),
    ("STDDEV", "cola", "DOUBLE"),
    ("ABS", "cola", "SMALLINT"),
    ("ABS", "colb", "FLOAT"),
  ]
  for t in tests {
    let (func, col, target_type) = t
    let expression = annotate_sql(
      "SELECT \{func}(x.\{col}) AS _col_0 FROM x AS x",
      schema~,
    )
    assert_eq(tthis(expression.expressions()[0]), target_type)
  }
}

///|
test "annotate_types: concat and root subquery" {
  assert_eq(tthis(annotate_sql("CONCAT('A', 'B')")), "VARCHAR")
  let expression = annotate_sql("(SELECT 1, 2 FROM x) LIMIT 0")
  assert_true(expression.kind == Subquery)
  // `Subquery.selects` are the inner query's (Python `DerivedTable.selects`); the port's
  // `Expr::selects` returns [] for a Subquery, so the inner query is read directly.
  let selects = expression.unnest().selects()
  assert_eq(tthis(selects[0]), "INT")
  assert_eq(tthis(selects[1]), "INT")
}

///|
test "annotate_types: nested types" {
  let schema = "{\"order\": {\"customer_id\": \"bigint\", \"item_id\": \"bigint\", \"item_price\": \"numeric\"}}"
  let sql = "SELECT ARRAY_AGG(DISTINCT order.item_id) FILTER (WHERE order.item_price > 10) AS items, FROM order AS order GROUP BY order.customer_id"
  let expression = annotate_sql(sql, schema~)
  assert_eq(tthis(expression.selects()[0]), "ARRAY")
  assert_eq(tsql(expression.selects()[0]), "ARRAY<BIGINT>")
  let expression = annotate_sql(
    "SELECT ARRAY_CAT(ARRAY[1,2,3], ARRAY[4,5])",
    read="postgres",
  )
  assert_eq(tthis(expression.selects()[0]), "ARRAY")
  assert_eq(tsql(expression.selects()[0]), "ARRAY<INT>")
  let schema = mapping_schema(
    "{\"t\": {\"c\": \"STRUCT<`f` STRING>\"}}",
    dialect="bigquery",
  )
  let expression = @optimizer.annotate_types(
    parse_sql("SELECT t.c, [t.c] FROM t"),
    schema~,
  )
  assert_eq(
    tsql(expression.selects()[0], dialect="bigquery"),
    "STRUCT<`f` STRING>",
  )
  assert_eq(
    tsql(expression.selects()[1], dialect="bigquery"),
    "ARRAY<STRUCT<`f` STRING>>",
  )
  let expression = annotate_sql(
    "SELECT unnest(t.x) FROM t AS t",
    read="postgres",
    schema="{\"t\": {\"x\": \"array<int>\"}}",
  )
  assert_true(
    expression.selects()[0].is_type_expr(@core.datatype_from_str("int")),
  )
}

///|
test "annotate_types: annotation cache" {
  let expression = annotate_sql("SELECT 1 + 1")
  assert_eq(tthis(expression.selects()[0]), "INT")
  expression.selects()[0].this_().replace(Some(parse_sql("1.2"))) |> ignore
  let expression = @optimizer.annotate_types(expression)
  assert_eq(tthis(expression.selects()[0]), "DOUBLE")
}

///|
test "annotate_types: user defined type" {
  let schema = mapping_schema("{\"t\": {\"x\": \"int\"}}", dialect="postgres")
  let expression = @optimizer.annotate_types(
    parse_sql("SELECT CAST(x AS IPADDRESS) FROM t"),
    schema~,
  )
  assert_eq(tthis(expression.selects()[0]), "USERDEFINED")
  assert_eq(tsql(expression.selects()[0], dialect="postgres"), "IPADDRESS")
}
