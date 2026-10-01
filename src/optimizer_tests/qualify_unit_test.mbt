// Ports of the inline (non-fixture) asserts of the qualify-related tests in
// tests/test_optimizer.py.

///|
test "qualify_tables: on_qualify" {
  let tables : Array[String] = []
  @optimizer.qualify(
    parse_sql("with foo AS (select * from bar) select * from foo join baz"),
    qualify_columns=false,
    on_qualify=t => if !tables.contains(t.name()) { tables.push(t.name()) },
  )
  |> ignore
  tables.sort_by(py_cmp)
  inspect(tables, content="[bar, baz]")

  // Tables referenced by lateral sources (e.g. UNNEST) must only be qualified once
  let qualified : Array[String] = []
  @optimizer.qualify_tables(
    parse_sql("SELECT a, x FROM t, UNNEST(arr) AS x"),
    db="db",
    catalog="c",
    on_qualify=t => qualified.push(@core.expr_to_sql(t)) catch { _ => () },
  )
  |> ignore
  inspect(qualified, content="[c.db.t AS t]")
}

///|
test "qualify_tables: inline asserts" {
  assert_eq(
    qualify_sql(
      "WITH tesT AS (SELECT * FROM t1) SELECT * FROM test",
      dialect="bigquery",
      db="db",
      catalog="catalog",
      quote_identifiers=false,
    ),
    "WITH test AS (SELECT * FROM catalog.db.t1 AS t1) SELECT * FROM test AS test",
  )
  assert_eq(
    gen_sql(
      @optimizer.qualify_tables(
        parse_sql(
          "WITH cte AS (SELECT * FROM t) SELECT * FROM cte PIVOT(SUM(c) FOR v IN ('x', 'y'))",
        ),
        db="db",
        catalog="catalog",
      ),
    ),
    "WITH cte AS (SELECT * FROM catalog.db.t AS t) SELECT * FROM cte AS cte PIVOT(SUM(c) FOR v IN ('x', 'y')) AS _0",
  )
  assert_eq(
    gen_sql(
      @optimizer.qualify_tables(
        parse_sql(
          "WITH cte AS (SELECT * FROM t) SELECT * FROM cte PIVOT(SUM(c) FOR v IN ('x', 'y')) AS pivot_alias",
        ),
        db="db",
        catalog="catalog",
      ),
    ),
    "WITH cte AS (SELECT * FROM catalog.db.t AS t) SELECT * FROM cte AS cte PIVOT(SUM(c) FOR v IN ('x', 'y')) AS pivot_alias",
  )
  assert_eq(
    gen_sql(
      @optimizer.qualify_tables(parse_sql("select a from b"), catalog="catalog"),
    ),
    "SELECT a FROM b AS b",
  )
  assert_eq(
    gen_sql(@optimizer.qualify_tables(parse_sql("select a from b"), db="\"DB\"")),
    "SELECT a FROM \"DB\".b AS b",
  )
}

///|
test "qualify_tables: copies typed alias columns" {
  let expression = parse_sql(
    "SELECT * FROM JSON_TO_RECORDSET(z) AS y(\"rank\" INT)",
  )
  let original = expression.find([Table]).unwrap().arg("alias").unwrap().list(
    "columns",
  )[0]
  assert_true(original.kind == ColumnDef)
  @optimizer.qualify_tables(expression, canonicalize_table_aliases=true)
  |> ignore
  let new = expression.find([Table]).unwrap().arg("alias").unwrap().list(
    "columns",
  )[0]
  assert_true(new.kind == ColumnDef)
  assert_false(physical_equal(original, new))
  assert_eq(gen_sql(original), gen_sql(new))
}

///|
let struct_schema : String = "{\"customer\": {\"id\": \"INT\", \"address\": \"STRUCT<state TEXT, location STRUCT<state TEXT>>\"}, \"addresses\": {\"id\": \"INT\", \"state\": \"TEXT\"}, \"other\": {\"id\": \"INT\"}}"

///|
test "qualify_columns: struct field and source alias" {
  let qualified = qualify_expr(
    "SELECT c.address.state FROM customer AS c JOIN addresses AS address ON c.id = address.id",
    schema=struct_schema,
    identify=false,
  )
  let struct_field = @core.dot_build([
    @core.column_of("address", table="c"),
    @core.to_identifier("state"),
  ])
  assert_true(qualified.find([Dot]).unwrap().equal(struct_field))
  let nested = qualify_expr(
    "SELECT c.address.location.state FROM customer AS c CROSS JOIN addresses AS location",
    schema=struct_schema,
    identify=false,
  )
  assert_true(
    nested
    .find([Dot])
    .unwrap()
    .equal(
      @core.dot_build([
        @core.column_of("address", table="c"),
        @core.to_identifier("location"),
        @core.to_identifier("state"),
      ]),
    ),
  )
  let correlated = qualify_expr(
    "SELECT (SELECT c.address.state FROM addresses AS address WHERE address.id = c.id) FROM customer AS c",
    schema=struct_schema,
    identify=false,
  )
  assert_true(correlated.find([Dot]).unwrap().equal(struct_field))
  let physical = qualify_expr(
    "SELECT db.address.state FROM db.address AS address JOIN db.other AS db ON address.id = db.id",
    schema="{\"db\": {\"address\": {\"id\": \"INT\", \"state\": \"TEXT\"}, \"other\": {\"id\": \"INT\"}}}",
    identify=false,
  )
  assert_true(
    physical
    .find([Column])
    .unwrap()
    .equal(@core.column_of("state", table="address")),
  )
}

// SKIPPED (unported dialect features), from test_qualify_columns:
//   - `SELECT Teams.Name, count(*) FROM raw.TeamMemberships ...` (bigquery): needs BigQuery's
//     case-sensitive `normalize_identifier` override (not in src/dialects/bigquery).
//   - "SELECT `my_db.my_table`.`my_column` FROM `my_db.my_table`" (bigquery): needs BigQuery's
//     splitting of quoted dotted table names in the parser.
//   - `... CROSS JOIN a.b.INFORMATION_SCHEMA.COLUMNS` (bigquery): INFORMATION_SCHEMA parsing.
//   - "CREATE FUNCTION udfs.`myTest`(...)" (bigquery): case-sensitive UDF names.

///|
test "qualify_columns: values set operation and recursive ctes" {
  assert_eq(
    qualify_sql(
      "WITH t(a) AS (VALUES (1) UNION ALL SELECT 2) SELECT t.a FROM t",
    ),
    "WITH \"t\" AS (SELECT \"_values\".\"_col_0\" AS \"a\" FROM (VALUES (1)) AS \"_values\"(\"_col_0\") UNION ALL SELECT 2 AS \"a\") SELECT \"t\".\"a\" AS \"a\" FROM \"t\" AS \"t\"",
  )
  assert_eq(
    qualify_sql(
      "WITH RECURSIVE t(n) AS (SELECT 1 AS n UNION ALL SELECT n + 1 AS n FROM t WHERE n < 5) SELECT * FROM t",
    ),
    "WITH RECURSIVE \"t\"(\"n\") AS (SELECT 1 AS \"n\" UNION ALL SELECT \"t\".\"n\" + 1 AS \"n\" FROM \"t\" AS \"t\" WHERE \"t\".\"n\" < 5) SELECT \"t\".\"n\" AS \"n\" FROM \"t\" AS \"t\"",
  )
  assert_eq(
    qualify_sql(
      "WITH RECURSIVE t(n) AS (SELECT 1 AS n UNION ALL (SELECT n + 1 AS n FROM t WHERE n < 5)) SELECT * FROM t",
    ),
    "WITH RECURSIVE \"t\"(\"n\") AS (SELECT 1 AS \"n\" UNION ALL (SELECT \"t\".\"n\" + 1 AS \"n\" FROM \"t\" AS \"t\" WHERE \"t\".\"n\" < 5)) SELECT \"t\".\"n\" AS \"n\" FROM \"t\" AS \"t\"",
  )
}

///|
test "qualify_columns: programmatic set operation with VALUES operand" {
  let union = @core.set_operation(
    Union,
    parse_sql("SELECT a FROM x"),
    parse_sql("VALUES (2)"),
    distinct=false,
  )
  union.set("side", "LEFT")
  let expression = @core.select_star_from(Some(union.subquery(alias="s")))
  try @optimizer.qualify(expression) catch {
    @core.OptimizeError(_) => ()
    err => fail("expected OptimizeError, got \{err}")
  } noraise {
    _ => fail("expected OptimizeError")
  }
}

///|
test "qualify_columns: duckdb laterals" {
  assert_eq(
    qualify_sql(
      "SELECT pos, val FROM t CROSS JOIN LATERAL (SELECT pos - 1 AS pos, val FROM UNNEST(t.arr) WITH ORDINALITY AS _t0(val, pos))",
      dialect="duckdb",
      schema="{\"t\": {\"arr\": \"ARRAY<VARCHAR>\"}}",
    ),
    "SELECT \"_0\".\"pos\" AS \"pos\", \"_0\".\"val\" AS \"val\" FROM \"t\" AS \"t\" CROSS JOIN LATERAL (SELECT \"_t0\".\"pos\" - 1 AS \"pos\", \"_t0\".\"val\" AS \"val\" FROM UNNEST(\"t\".\"arr\") WITH ORDINALITY AS \"_t0\"(\"val\", pos)) AS \"_0\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT * FROM t CROSS JOIN LATERAL (SELECT 1 AS x, 2 AS y) AS foo",
      dialect="duckdb",
      schema="{\"t\": {\"k\": \"INT\"}}",
    ),
    "SELECT \"t\".\"k\" AS \"k\", \"foo\".\"x\" AS \"x\", \"foo\".\"y\" AS \"y\" FROM \"t\" AS \"t\" CROSS JOIN LATERAL (SELECT 1 AS \"x\", 2 AS \"y\") AS \"foo\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT c, d FROM t CROSS JOIN LATERAL (SELECT 1 AS a, 2 AS b) AS x(c, d)",
      dialect="duckdb",
      schema="{\"t\": {\"k\": \"INT\"}}",
    ),
    "SELECT \"x\".\"c\" AS \"c\", \"x\".\"d\" AS \"d\" FROM \"t\" AS \"t\" CROSS JOIN LATERAL (SELECT 1 AS \"a\", 2 AS \"b\") AS \"x\"(\"c\", \"d\")",
  )
  assert_eq(
    qualify_sql(
      "SELECT * FROM t CROSS JOIN LATERAL (SELECT 1 AS a, 2 AS b) AS x(c)",
      dialect="duckdb",
      schema="{\"t\": {\"k\": \"INT\"}}",
    ),
    "SELECT \"t\".\"k\" AS \"k\", \"x\".\"c\" AS \"c\", \"x\".\"b\" AS \"b\" FROM \"t\" AS \"t\" CROSS JOIN LATERAL (SELECT 1 AS \"a\", 2 AS \"b\") AS \"x\"(\"c\")",
  )
}

///|
fn qualify_columns_sql(
  sql : String,
  schema : String,
  dialect? : String,
  expand_stars? : Bool,
  infer_schema? : Bool,
) -> String raise @core.SqlglotError {
  gen_sql(
    @optimizer.qualify_columns(
      parse_sql(sql, read?=dialect),
      mapping_schema(schema, dialect?),
      expand_stars?,
      infer_schema?,
    ),
    dialect?,
  )
}

///|
test "qualify_columns: qualify_columns inline asserts" {
  assert_eq(
    qualify_columns_sql(
      "WITH RECURSIVE t AS (SELECT 1 AS x UNION ALL SELECT x + 1 FROM t AS child WHERE x < 10) SELECT * FROM t",
      "{}",
      infer_schema=false,
    ),
    "WITH RECURSIVE t AS (SELECT 1 AS x UNION ALL SELECT child.x + 1 AS _col_0 FROM t AS child WHERE child.x < 10) SELECT t.x AS x FROM t",
  )
  assert_eq(
    qualify_columns_sql(
      "WITH x AS (SELECT a FROM db.y) SELECT * FROM db.x",
      "{\"db\": {\"x\": {\"z\": \"int\"}, \"y\": {\"a\": \"int\"}}}",
      expand_stars=false,
    ),
    "WITH x AS (SELECT y.a AS a FROM db.y) SELECT * FROM db.x",
  )
  assert_eq(
    qualify_columns_sql(
      "WITH x AS (SELECT a FROM db.y) SELECT z FROM db.x",
      "{\"db\": {\"x\": {\"z\": \"int\"}, \"y\": {\"a\": \"int\"}}}",
      infer_schema=false,
    ),
    "WITH x AS (SELECT y.a AS a FROM db.y) SELECT x.z AS z FROM db.x",
  )
  assert_eq(
    qualify_columns_sql("select y from x", "{}", infer_schema=false),
    "SELECT y AS y FROM x",
  )
}

///|
test "qualify_columns: aliases keep the spelling of quoted projections" {
  assert_eq(
    qualify_columns_sql(
      "SELECT \"C1\" FROM t",
      "{}",
      infer_schema=false,
      dialect="trino",
    ),
    "SELECT \"C1\" AS \"C1\" FROM t",
  )
  assert_eq(
    qualify_columns_sql(
      "SELECT (\"C1\") FROM t",
      "{}",
      infer_schema=false,
      dialect="trino",
    ),
    "SELECT (\"C1\") AS \"C1\" FROM t",
  )
  assert_eq(
    qualify_columns_sql(
      "SELECT t.s.\"Ff\" FROM t",
      "{\"t\": {\"s\": \"STRUCT(\\\"Ff\\\" INT)\"}}",
      dialect="duckdb",
    ),
    "SELECT t.s.\"Ff\" AS \"Ff\" FROM t",
  )
  assert_eq(
    qualify_columns_sql(
      "SELECT Cc FROM (SELECT Cc FROM t) AS s",
      "{}",
      infer_schema=false,
      dialect="snowflake",
    ),
    "SELECT s.Cc AS Cc FROM (SELECT Cc AS Cc FROM t) AS s",
  )
}

///|
test "qualify_columns: spark identifiers" {
  assert_eq(
    qualify_sql(
      "SELECT `bar_bazfoo_$id` FROM test",
      dialect="spark",
      schema="{\"test\": {\"bar_bazFoo_$id\": \"BIGINT\"}}",
    ),
    "SELECT `test`.`bar_bazfoo_$id` AS `bar_bazfoo_$id` FROM `test` AS `test`",
  )
}

///|
test "qualify_columns: wrapped query keeps parents" {
  let qualified = qualify_expr("WITH t AS (SELECT 1 AS c) (SELECT c FROM t)")
  assert_true(physical_equal(qualified.selects()[0].parent.unwrap(), qualified))
  assert_eq(
    gen_sql(qualified),
    "WITH \"t\" AS (SELECT 1 AS \"c\") SELECT \"t\".\"c\" AS \"c\" FROM \"t\" AS \"t\"",
  )
}

///|
test "qualify_columns: USING columns can't always be coalesced" {
  assert_eq(
    qualify_columns_sql(
      "SELECT id, dt, v FROM (SELECT t1.id, t1.dt, sum(coalesce(t2.v, 0)) AS v FROM t1 AS t1 LEFT JOIN lkp AS lkp USING (id) LEFT JOIN t2 AS t2 USING (other_id, dt, common) WHERE t1.id > 10 GROUP BY 1, 2) AS `_0`",
      "{\"t1\": {\"id\": \"int64\", \"dt\": \"date\", \"common\": \"int64\"}, \"lkp\": {\"id\": \"int64\", \"other_id\": \"int64\", \"common\": \"int64\"}, \"t2\": {\"other_id\": \"int64\", \"dt\": \"date\", \"v\": \"int64\", \"common\": \"int64\"}}",
      dialect="bigquery",
    ),
    "SELECT `_0`.id AS id, `_0`.dt AS dt, `_0`.v AS v FROM (SELECT t1.id AS id, t1.dt AS dt, sum(coalesce(t2.v, 0)) AS v FROM t1 AS t1 LEFT JOIN lkp AS lkp ON t1.id = lkp.id LEFT JOIN t2 AS t2 ON lkp.other_id = t2.other_id AND t1.dt = t2.dt AND COALESCE(t1.common, lkp.common) = t2.common WHERE t1.id > 10 GROUP BY t1.id, t1.dt) AS `_0`",
  )
}

///|
test "qualify_columns: correlation in nested derived tables" {
  assert_eq(
    qualify_sql(
      "SELECT a.g FROM a WHERE a.e < (SELECT MAX(u) FROM (SELECT SUM(c.b) AS u FROM c WHERE  c.d = f GROUP BY c.e) w)",
      schema="{\"a\": {\"g\": \"INT\", \"e\": \"INT\", \"f\": \"INT\"}, \"c\": {\"d\": \"INT\", \"e\": \"INT\", \"b\": \"INT\"}}",
      quote_identifiers=false,
    ),
    "SELECT a.g AS g FROM a AS a WHERE a.e < (SELECT MAX(w.u) AS _col_0 FROM (SELECT SUM(c.b) AS u FROM c AS c WHERE c.d = a.f GROUP BY c.e) AS w)",
  )
}

///|
test "qualify_columns: postgres laterals and USING" {
  // Python parses with `dialect="postgres"` but qualifies with the default dialect
  let e = @optimizer.qualify(
    parse_sql(
      "SELECT u.user_id, l.log_date FROM users AS u CROSS JOIN LATERAL (SELECT l1.log_date FROM (SELECT l.log_date FROM logs AS l WHERE l.user_id = u.user_id AND l.log_date <= 100 ORDER BY l.log_date LIMIT 1) AS l1) AS l",
      read="postgres",
    ),
    schema=mapping_schema(
      "{\"users\": {\"user_id\": \"text\", \"log_date\": \"date\"}, \"logs\": {\"user_id\": \"text\", \"log_date\": \"date\"}}",
    ),
    quote_identifiers=false,
  )
  assert_eq(
    gen_sql(e, dialect="postgres"),
    "SELECT u.user_id AS user_id, l.log_date AS log_date FROM users AS u CROSS JOIN LATERAL (SELECT l1.log_date AS log_date FROM (SELECT l.log_date AS log_date FROM logs AS l WHERE l.user_id = u.user_id AND l.log_date <= 100 ORDER BY l.log_date LIMIT 1) AS l1) AS l",
  )
  let e = @optimizer.qualify(
    parse_sql(
      "SELECT A.b_id FROM A JOIN B ON A.b_id=B.b_id JOIN C USING(c_id)",
      read="postgres",
    ),
    schema=mapping_schema(
      "{\"A\": {\"b_id\": \"int\"}, \"B\": {\"b_id\": \"int\", \"c_id\": \"int\"}, \"C\": {\"c_id\": \"int\"}}",
    ),
    quote_identifiers=false,
  )
  assert_eq(
    gen_sql(e, dialect="postgres"),
    "SELECT a.b_id AS b_id FROM a AS a JOIN b AS b ON a.b_id = b.b_id JOIN c AS c ON b.c_id = c.c_id",
  )
  let e = @optimizer.qualify(
    parse_sql(
      "SELECT A.b_id FROM A JOIN B ON A.b_id=B.b_id JOIN C ON B.b_id = C.b_id JOIN D USING(d_id)",
      read="postgres",
    ),
    schema=mapping_schema(
      "{\"A\": {\"b_id\": \"int\"}, \"B\": {\"b_id\": \"int\", \"d_id\": \"int\"}, \"C\": {\"b_id\": \"int\"}, \"D\": {\"d_id\": \"int\"}}",
    ),
    quote_identifiers=false,
  )
  assert_eq(
    gen_sql(e, dialect="postgres"),
    "SELECT a.b_id AS b_id FROM a AS a JOIN b AS b ON a.b_id = b.b_id JOIN c AS c ON b.b_id = c.b_id JOIN d AS d ON b.d_id = d.d_id",
  )
}

///|
test "qualify_columns: bigquery correlated UNNEST" {
  // The Python asserts compare BigQuery output, whose generator unqualifies columns of
  // UNNEST sources (`transforms.unqualify_unnest`, not ported in src/dialects/bigquery).
  // The qualified ASTs are checked through the base dialect instead, with the expected
  // strings taken from the Python reference (`qualify(...).sql()`).
  assert_eq(
    qualify_sql(
      "SELECT (SELECT SUM(c.amount) FROM UNNEST(credits) AS c WHERE type != 'promotion') as total FROM billing",
      dialect="bigquery",
      schema="{\"billing\": {\"credits\": \"ARRAY<STRUCT<amount FLOAT64, type STRING>>\"}}",
      out_dialect="",
    ),
    "SELECT (SELECT SUM(\"_0\".\"c\".\"amount\") AS \"_col_0\" FROM UNNEST(\"billing\".\"credits\") AS \"_0\"(\"c\") WHERE \"_0\".\"type\" <> 'promotion') AS \"total\" FROM \"billing\" AS \"billing\"",
  )
  assert_eq(
    qualify_sql(
      "WITH cte AS (SELECT * FROM base_table) SELECT (SELECT SUM(item.price) FROM UNNEST(items) AS item WHERE category = 'electronics') as electronics_total FROM cte",
      dialect="bigquery",
      schema="{\"base_table\": {\"id\": \"INT64\", \"items\": \"ARRAY<STRUCT<price FLOAT64, category STRING>>\"}}",
      out_dialect="",
    ),
    "WITH \"cte\" AS (SELECT \"base_table\".\"id\" AS \"id\", \"base_table\".\"items\" AS \"items\" FROM \"base_table\" AS \"base_table\") SELECT (SELECT SUM(\"_0\".\"item\".\"price\") AS \"_col_0\" FROM UNNEST(\"cte\".\"items\") AS \"_0\"(\"item\") WHERE \"_0\".\"category\" = 'electronics') AS \"electronics_total\" FROM \"cte\" AS \"cte\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT (SELECT col_st.value FROM UNNEST(col_st) AS col_st) AS vcol1 FROM t AS b",
      dialect="bigquery",
      schema="{\"t\": {\"col_st\": \"ARRAY<STRUCT<key STRING, value INT>>\"}}",
      out_dialect="",
    ),
    "SELECT (SELECT \"_0\".\"col_st\".\"value\" AS \"value\" FROM UNNEST(\"b\".\"col_st\") AS \"_0\"(\"col_st\")) AS \"vcol1\" FROM \"t\" AS \"b\"",
  )
}

///|
test "qualify_columns: schema-qualified tables, keywords and unpivot" {
  assert_eq(
    qualify_sql(
      "SELECT 1 FROM dbo.a JOIN dbo.b ON dbo.b.id = dbo.a.id JOIN dbo.b AS x ON x.id = dbo.a.id",
    ),
    "SELECT 1 AS \"1\" FROM \"dbo\".\"a\" AS \"a\" JOIN \"dbo\".\"b\" AS \"b\" ON \"b\".\"id\" = \"a\".\"id\" JOIN \"dbo\".\"b\" AS \"x\" ON \"x\".\"id\" = \"a\".\"id\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT * FROM t",
      schema="{\"t\": {\"end\": \"text\"}}",
      quote_identifiers=false,
    ),
    "SELECT t.end AS end FROM t AS t",
  )
  assert_eq(
    qualify_sql(
      "WITH cte AS (SELECT 1 AS a, 2 AS b, 3 AS c) SELECT u.val, u.name FROM cte UNPIVOT(val FOR name IN (a, b, c)) AS u",
    ),
    "WITH \"cte\" AS (SELECT 1 AS \"a\", 2 AS \"b\", 3 AS \"c\") SELECT \"u\".\"val\" AS \"val\", \"u\".\"name\" AS \"name\" FROM \"cte\" AS \"cte\" UNPIVOT(\"val\" FOR \"name\" IN (\"cte\".\"a\", \"cte\".\"b\", \"cte\".\"c\")) AS \"u\"",
  )
}

///|
test "qualify_columns: bigquery unpivot" {
  assert_eq(
    qualify_sql(
      "WITH produce AS (SELECT 'Kale' AS product, 51 AS q1, 23 AS q2) SELECT * FROM produce UNPIVOT(sales FOR quarter IN (q1, q2))",
      dialect="bigquery",
    ),
    "WITH `produce` AS (SELECT 'Kale' AS `product`, 51 AS `q1`, 23 AS `q2`) SELECT `produce`.`product` AS `product`, `produce`.`quarter` AS `quarter`, `produce`.`sales` AS `sales` FROM `produce` AS `produce` UNPIVOT(`sales` FOR `quarter` IN (`produce`.`q1`, `produce`.`q2`)) AS `produce`",
  )
  assert_eq(
    qualify_sql(
      "WITH produce AS (SELECT 'Kale' AS product, 51 AS q1, 23 AS q2, 45 AS q3, 3 AS q4) SELECT * FROM produce UNPIVOT((first_half, second_half) FOR semesters IN ((q1, q2) AS 'h1', (q3, q4) AS 'h2'))",
      dialect="bigquery",
    ),
    "WITH `produce` AS (SELECT 'Kale' AS `product`, 51 AS `q1`, 23 AS `q2`, 45 AS `q3`, 3 AS `q4`) SELECT `produce`.`product` AS `product`, `produce`.`semesters` AS `semesters`, `produce`.`first_half` AS `first_half`, `produce`.`second_half` AS `second_half` FROM `produce` AS `produce` UNPIVOT((`first_half`, `second_half`) FOR `semesters` IN ((`produce`.`q1`, `produce`.`q2`) AS 'h1', (`produce`.`q3`, `produce`.`q4`) AS 'h2')) AS `produce`",
  )
}

///|
test "qualify: unpivot with unknown schema (snowflake)" {
  // The Python asserts compare Snowflake output, whose generator unqualifies the UNPIVOT
  // IN-list columns (`_unqualify_pivot_columns`, not ported in src/dialects/snowflake).
  // The qualified ASTs are checked through the base dialect instead, with the expected
  // strings taken from the Python reference (`qualify(...).sql()`).
  assert_eq(
    qualify_sql(
      "SELECT i.other_col FROM my_table AS i UNPIVOT(v FOR k IN (a, b))",
      dialect="snowflake",
      out_dialect="",
    ),
    "SELECT \"I\".\"OTHER_COL\" AS \"OTHER_COL\" FROM \"MY_TABLE\" AS \"I\" UNPIVOT(\"V\" FOR \"K\" IN (\"I\".\"A\", \"I\".\"B\")) AS \"I\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT i.a FROM my_table AS i UNPIVOT(v FOR k IN (a, b))",
      dialect="snowflake",
      out_dialect="",
    ),
    "SELECT \"I\".\"A\" AS \"A\" FROM \"MY_TABLE\" AS \"I\" UNPIVOT(\"V\" FOR \"K\" IN (\"I\".\"A\", \"I\".\"B\")) AS \"I\"",
  )
  assert_eq(
    qualify_sql(
      "SELECT i.z FROM my_table AS i UNPIVOT(v FOR k IN (a, b)) AS i(w, x, y, z)",
      dialect="snowflake",
      out_dialect="",
    ),
    "SELECT \"I\".\"Z\" AS \"Z\" FROM \"MY_TABLE\" AS \"I\" UNPIVOT(\"V\" FOR \"K\" IN (\"I\".\"A\", \"I\".\"B\")) AS \"I\"(\"W\", \"X\", \"Y\", \"Z\")",
  )
}

///|
/// `[(s.alias_or_name, s.type.sql()) for s in expression.selects]`
fn select_types(
  e : @core.Expr,
  dialect? : String,
) -> Array[(String, String)] raise @core.SqlglotError {
  e
  .selects()
  .map(s => (
    s.alias_or_name(),
    match s.get_type() {
      Some(t) => gen_sql(t, dialect?)
      None => "None"
    },
  ))
}

///|
fn qualify_annotate(
  sql : String,
  schema : String,
  dialect : String,
) -> @core.Expr raise @core.SqlglotError {
  let s = mapping_schema(schema, dialect~)
  let d = dialect_of(Some(dialect))
  @optimizer.annotate_types(
    @optimizer.qualify(parse_sql(sql, read=dialect), schema=s, dialect?=d),
    schema=s,
    dialect?=d,
  )
}

///|
test "annotate_types: multiple pivots" {
  let expression = qualify_annotate(
    "SELECT * FROM t UNPIVOT(revenue FOR month IN (jan, feb)) UNPIVOT(headcount FOR region IN (north, south))",
    "{\"t\": {\"id\": \"int\", \"jan\": \"int\", \"feb\": \"int\", \"north\": \"double\", \"south\": \"double\"}}",
    "snowflake",
  )
  inspect(
    select_types(expression),
    content=(
      #|[(ID, INT), (MONTH, VARCHAR), (REVENUE, INT), (REGION, VARCHAR), (HEADCOUNT, DOUBLE)]
    ),
  )
  let expression = qualify_annotate(
    "SELECT * FROM t PIVOT(SUM(val) FOR cat IN ('a' AS a, 'b' AS b)) PIVOT(SUM(amt) FOR kind IN ('x' AS x, 'y' AS y))",
    "{\"t\": {\"id\": \"int\", \"cat\": \"text\", \"val\": \"int\", \"kind\": \"text\", \"amt\": \"double\"}}",
    "snowflake",
  )
  inspect(
    select_types(expression),
    content=(
      #|[(ID, INT), (A, BIGINT), (B, BIGINT), (X, DOUBLE), (Y, DOUBLE)]
    ),
  )
}

///|
test "annotate_types: unpivot of a cte" {
  let expression = qualify_annotate(
    "WITH c AS (SELECT id, jan, feb FROM t) SELECT * FROM c UNPIVOT(v FOR m IN (jan, feb))",
    "{\"t\": {\"id\": \"int\", \"jan\": \"int\", \"feb\": \"int\"}}",
    "duckdb",
  )
  inspect(
    select_types(expression),
    content=(
      #|[(id, INT), (m, VARCHAR), (v, INT)]
    ),
  )
}

///|
test "qualify: unnest type trace terminates" {
  // The Python test counts calls of a private method to check memoization; here we only
  // check that qualifying the query terminates.
  let ctes = [
    "order_attrs0 AS (SELECT id, [STRUCT('color' AS key, 'red' AS value)] AS attrs FROM orders)",
  ]
  for k in 1..<12 {
    ctes.push(
      "order_attrs\{k} AS (SELECT a.id AS id, array_concat(a.attrs, [STRUCT('size' AS key, 'large' AS value)]) AS attrs FROM order_attrs\{k - 1} AS a JOIN orders AS o ON a.id = o.id)",
    )
  }
  ctes.push(
    "non_null_attrs AS (SELECT ARRAY(SELECT x FROM UNNEST(attrs) AS x WHERE NOT x.value IS NULL) AS attrs FROM order_attrs11)",
  )
  let sql = "WITH " + ctes.join(", ") + " SELECT * FROM non_null_attrs"
  qualify_expr(sql, dialect="bigquery", schema="{\"orders\": {\"id\": \"INT64\"}}")
  |> ignore
}

///|
test "qualify: validate columns" {
  assert_raises_with(
    () => qualify_expr("select foo from x", schema="{\"foo\": {\"y\": \"int\"}}")
    |> ignore,
    "Column 'foo' could not be resolved. Line: 1, Col: 10",
  )
  // ambiguous columns error with PIVOT (which skips the "could not be resolved" check)
  assert_raises_with(
    () => {
      let qualified = @optimizer.qualify_columns(
        parse_sql(
          "SELECT * FROM (SELECT a, b, c FROM x) PIVOT (SUM(b) FOR c IN ('x', 'y'))",
        ),
        mapping_schema(
          "{\"x\": {\"a\": \"int\", \"b\": \"int\", \"c\": \"str\"}}",
        ),
      )
      @optimizer.validate_qualify_columns(qualified) |> ignore
    },
    "Ambiguous column 'a'",
  )
}

///|
test "qualify: spark lateral view explode" {
  let schema = "{\"my_table\": {\"items\": \"ARRAY<STRUCT<name STRING, age INT>>\"}}"
  let expression = qualify_annotate(
    "SELECT ci.name, ci.age FROM my_table LATERAL VIEW EXPLODE(items) ci AS ci",
    schema, "spark",
  )
  assert_eq(
    gen_sql(expression, dialect="spark"),
    "SELECT `ci`.`name` AS `name`, `ci`.`age` AS `age` FROM `my_table` AS `my_table` LATERAL VIEW EXPLODE(`my_table`.`items`) ci AS `ci`",
  )
  let spark = @core.Dialect::get_or_raise("spark")
  assert_true(
    expression.selects()[0]
    .get_type()
    .unwrap()
    .equal(@core.datatype_from_str("STRING", dialect=spark)),
  )
  assert_true(
    expression.selects()[1]
    .get_type()
    .unwrap()
    .equal(@core.datatype_from_str("INT", dialect=spark)),
  )
  let expression = qualify_annotate(
    "SELECT (SELECT SUM(ci.amount) FROM my_table LATERAL VIEW EXPLODE(items) ci AS ci WHERE ci.type = 'promotion') AS total FROM my_table",
    "{\"my_table\": {\"items\": \"ARRAY<STRUCT<amount FLOAT, type STRING>>\"}}",
    "spark",
  )
  assert_eq(
    gen_sql(expression, dialect="spark"),
    "SELECT (SELECT SUM(`ci`.`amount`) AS `_col_0` FROM `my_table` AS `my_table` LATERAL VIEW EXPLODE(`my_table`.`items`) ci AS `ci` WHERE `ci`.`type` = 'promotion') AS `total` FROM `my_table` AS `my_table`",
  )
  assert_true(
    expression.selects()[0]
    .get_type()
    .unwrap()
    .equal(@core.datatype_from_str("DOUBLE", dialect=spark)),
  )
  // An unqualified struct field is disambiguated through the lateral's extended columns
  assert_eq(
    qualify_sql(
      "SELECT name FROM my_table LATERAL VIEW EXPLODE(items) ci AS ci",
      dialect="spark",
      schema~,
    ),
    "SELECT `ci`.`name` AS `name` FROM `my_table` AS `my_table` LATERAL VIEW EXPLODE(`my_table`.`items`) ci AS `ci`",
  )
}

///|
test "qualify: unresolvable snowflake lateral column" {
  assert_raises_with(
    () => qualify_expr(
      "SELECT f.value AS v FROM my_db.raw.events, LATERAL FLATTEN(items) AS f",
      dialect="snowflake",
      schema="{\"my_db\": {\"other\": {\"some_view\": {\"v\": \"VARIANT\"}}}}",
    )
    |> ignore,
    "Column 'ITEMS' could not be resolved",
  )
}

///|
test "qualify_columns: struct star expansion types" {
  let qualified = qualify_expr(
    "WITH cte AS (SELECT t.s.* FROM t UNION ALL SELECT t.s.* FROM t) SELECT cte.x FROM cte",
    dialect="bigquery",
    schema="{\"t\": {\"s\": \"STRUCT<x INT64, y STRING>\"}}",
  )
  let union = qualified.find([Union]).unwrap()
  inspect(
    select_types(union, dialect="bigquery").map(p => p.1),
    content=(
      #|[INT64, STRING]
    ),
  )
  inspect(
    select_types(union.expression().unwrap(), dialect="bigquery").map(p => p.1),
    content=(
      #|[INT64, STRING]
    ),
  )
  assert_eq(
    gen_sql(qualified.selects()[0].get_type().unwrap(), dialect="bigquery"),
    "INT64",
  )
}

///|
test "qualify: snowflake positional columns" {
  let snowflake = @core.Dialect::get_or_raise("snowflake")
  let visible_schema = @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(
      "{\"t\": {\"hidden\": \"INT\", \"HAS SPACE\": \"INT\"}}",
    ),
    visible={ "T": Names(["HAS SPACE"]) },
    dialect=snowflake,
  )
  assert_eq(
    gen_sql(
      @optimizer.qualify(
        parse_sql("SELECT t.$1 FROM t", read="snowflake"),
        dialect=snowflake,
        quote_identifiers=false,
        schema=visible_schema,
      ),
      dialect="snowflake",
    ),
    "SELECT T.\"HAS SPACE\" AS \"HAS SPACE\" FROM T AS T",
  )
  // positional columns are Snowflake-only
  assert_eq(
    qualify_sql(
      "WITH t AS (SELECT 1 AS a) SELECT t.$1 FROM t",
      dialect="postgres",
      allow_partial_qualification=true,
      quote_identifiers=false,
    ),
    "WITH t AS (SELECT 1 AS a) SELECT t.$1 AS _col_0 FROM t AS t",
  )
  let sql = "WITH t AS (SELECT 1 AS a) SELECT t.$2 FROM t"
  assert_raises_with(
    () => qualify_expr(sql, dialect="snowflake") |> ignore,
    "Positional reference $2 is out of range for source 'T'",
  )
  assert_eq(
    qualify_sql(
      sql,
      dialect="snowflake",
      allow_partial_qualification=true,
      quote_identifiers=false,
    ),
    "WITH T AS (SELECT 1 AS A) SELECT T.$2 AS _COL_0 FROM T AS T",
  )
}

///|
test "qualify_columns__invalid: unresolvable column instead of unknown table" {
  let sql =
    #|SELECT
    #|INLINE_VIEW.a AS ACCOUNT
    #|FROM (
    #|(
    #|    SELECT
    #|    a
    #|    FROM table1
    #|) inline_view
    #|LEFT JOIN table2
    #|    ON a = table2.id
    #|)
    #|LEFT JOIN table3
    #|ON inline_view.a = table3.a
  assert_raises_with(
    () => {
      let schema = @optimizer.MappingSchema::new()
      schema.add_table_str("table3", columns=["a"])
      let expression = @optimizer.qualify_columns(parse_sql(sql), schema)
      @optimizer.validate_qualify_columns(expression) |> ignore
    },
    "Column 'a' could not be resolved",
  )
}

///|
test "optimize: error highlighting" {
  let ansi_underline = "\u{1b}[4m"
  let ansi_reset = "\u{1b}[0m"
  let sql = "SELECT nonexistent FROM x"
  let schema = mapping_schema(test_schema_json)
  let with_sql = try
    @optimizer.optimize(parse_sql(sql), schema~, sql~)
    |> ignore
    |> Ok
  catch {
    e => Err(e.message())
  }
  guard with_sql is Err(msg) else { fail("expected OptimizeError") }
  assert_true(msg.contains("Column 'nonexistent' could not be resolved"))
  assert_true(msg.contains("\{ansi_underline}nonexistent\{ansi_reset}"))
  let without_sql = try
    @optimizer.optimize(parse_sql(sql), schema~)
    |> ignore
    |> Ok
  catch {
    e => Err(e.message())
  }
  guard without_sql is Err(msg) else { fail("expected OptimizeError") }
  assert_true(msg.contains("Column 'nonexistent' could not be resolved"))
  assert_false(msg.contains("\{ansi_underline}nonexistent\{ansi_reset}"))
}

///|
test "normalize_identifiers: string input" {
  assert_eq(
    gen_sql(@optimizer.normalize_identifier_str("a%")),
    "\"a%\"",
  )
}

///|
test "qualify: correlated shadowed struct path" {
  // The Python test runs both queries in DuckDB and compares the results; without an
  // engine, the qualified query is compared with the Python reference's output instead.
  let query = "SELECT (SELECT c.address.state FROM other AS c JOIN addresses AS address ON c.id = address.id) AS state FROM customer AS c"
  assert_eq(
    qualify_sql(
      query,
      schema="{\"customer\": {\"address\": \"STRUCT<state TEXT>\"}, \"other\": {\"id\": \"INT\"}, \"addresses\": {\"id\": \"INT\", \"state\": \"TEXT\"}}",
      identify=false,
    ),
    "SELECT (SELECT c.address.state AS state FROM other AS c JOIN addresses AS address ON c.id = address.id) AS state FROM customer AS c",
  )
}
