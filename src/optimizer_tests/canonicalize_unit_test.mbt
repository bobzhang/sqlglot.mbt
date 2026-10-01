// Ports of the inline asserts of test_canonicalize_internal_names and test_canonicalize in
// tests/test_optimizer.py.

///|
/// `canonicalize_internal_names(qualify(parse_one(sql, read=dialect), **kwargs)).sql(dialect)`
fn canon_sql(
  sql : String,
  schema? : String,
  dialect? : String,
  db? : String,
  catalog? : String,
) -> String raise @core.SqlglotError {
  gen_sql(canon_expr(qualify_expr(sql, schema?, dialect?, db?, catalog?)), dialect?)
}

///|
fn canon_expr(e : @core.Expr) -> @core.Expr raise @core.SqlglotError {
  @optimizer.canonicalize_internal_names(e)
}

///|
test "canonicalize_internal_names: data contract" {
  // Physical table identity is part of the data contract
  let canon_a = canon_sql(
    "SELECT id, name FROM cat.db.users WHERE id > 5",
    schema="{\"cat\": {\"db\": {\"users\": {\"id\": \"INT\", \"name\": \"TEXT\"}}}}",
  )
  let canon_diff_table = canon_sql(
    "SELECT id, name FROM cat.db.employees WHERE id > 5",
    schema="{\"cat\": {\"db\": {\"employees\": {\"id\": \"INT\", \"name\": \"TEXT\"}}}}",
  )
  assert_not_eq(canon_a, canon_diff_table)

  // Renaming a base-table column is a data-contract change
  let canon_rename = canon_sql(
    "SELECT emp_id, full_name FROM cat.db.users WHERE emp_id > 5",
    schema="{\"cat\": {\"db\": {\"users\": {\"emp_id\": \"INT\", \"full_name\": \"TEXT\"}}}}",
  )
  assert_not_eq(canon_a, canon_rename)

  // User-chosen table aliases are internal handles
  assert_eq(
    canon_sql(
      "SELECT foo.id FROM users AS foo",
      schema="{\"users\": {\"id\": \"INT\"}}",
    ),
    canon_sql(
      "SELECT bar.id FROM users AS bar",
      schema="{\"users\": {\"id\": \"INT\"}}",
    ),
  )
  // ... even on sources whose columns are never referenced
  let two_tables = "{\"users\": {\"id\": \"INT\"}, \"logs\": {\"id\": \"INT\"}}"
  assert_eq(
    canon_sql(
      "SELECT 1 FROM users AS foo CROSS JOIN logs AS bar",
      schema=two_tables,
    ),
    canon_sql(
      "SELECT 1 FROM users AS baz CROSS JOIN logs AS qux",
      schema=two_tables,
    ),
  )
  let ts = "{\"t\": {\"id\": \"INT\"}, \"s\": {\"id\": \"INT\"}}"
  assert_eq(
    canon_sql("SELECT 1 FROM t WHERE EXISTS(SELECT 1 FROM s AS abc)", schema=ts),
    canon_sql("SELECT 1 FROM t WHERE EXISTS(SELECT 1 FROM s AS xyz)", schema=ts),
  )

  // Physical table identity is preserved for real tables
  assert_eq(
    canon_sql(
      "SELECT a FROM x",
      schema="{\"x\": {\"a\": \"INT\"}}",
      db="mydb",
      catalog="cat",
    ),
    "SELECT \"_t0\".\"a\" AS \"a\" FROM \"cat\".\"mydb\".\"x\" AS \"_t0\"",
  )

  // Top-level output aliases are part of the contract
  let xa = "{\"x\": {\"a\": \"INT\"}}"
  assert_not_eq(
    canon_sql("SELECT a AS alpha FROM x", schema=xa),
    canon_sql("SELECT a AS beta FROM x", schema=xa),
  )
  // Internal aliases inside a CTE are self-consistent
  assert_eq(
    canon_sql(
      "WITH t AS (SELECT a AS foo FROM x) SELECT foo AS result FROM t",
      schema=xa,
    ),
    canon_sql(
      "WITH t AS (SELECT a AS bar FROM x) SELECT bar AS result FROM t",
      schema=xa,
    ),
  )
  // Changing which base-table column a CTE reads is a real change
  let src = "{\"src\": {\"a\": \"INT\", \"b\": \"INT\"}}"
  assert_not_eq(
    canon_sql("WITH t AS (SELECT a AS x FROM src) SELECT x FROM t", schema=src),
    canon_sql("WITH t AS (SELECT b AS x FROM src) SELECT x FROM t", schema=src),
  )
}

///|
test "canonicalize_internal_names: VALUES operands" {
  // VALUES as a set operation operand, e.g. in ASTs built programmatically
  assert_eq(
    gen_sql(canon_expr(@optimizer.qualify(select_1_union_values()))),
    "SELECT 1 AS \"1\" UNION VALUES (2)",
  )
  let by_name_union = @core.mk(Union, [
    ("this", parse_sql("SELECT 1 AS c")),
    ("expression", parse_sql("VALUES (2)")),
    ("distinct", false),
    ("by_name", true),
  ])
  assert_eq(
    gen_sql(canon_expr(@optimizer.qualify(by_name_union))),
    "SELECT 1 AS \"c\" UNION ALL BY NAME VALUES (2)",
  )
  // For parsed SQL, VALUES operands are instead wrapped in selects and canonicalized
  assert_eq(
    canon_sql("VALUES (1) UNION ALL SELECT 2"),
    "SELECT \"_t0\".\"_c0\" AS \"_col_0\" FROM (VALUES (1)) AS \"_t0\"(\"_c0\") UNION ALL SELECT 2 AS \"_c1\"",
  )
}

///|
test "canonicalize_internal_names: UNION BY NAME (duckdb)" {
  let schema_ux = "{\"x\": {\"a\": \"INT\"}, \"y\": {\"a\": \"INT\", \"b\": \"INT\"}}"
  assert_not_eq(
    canon_sql(
      "SELECT a FROM x UNION BY NAME SELECT a FROM y",
      schema=schema_ux,
      dialect="duckdb",
    ),
    canon_sql(
      "SELECT a FROM x UNION BY NAME SELECT b FROM y",
      schema=schema_ux,
      dialect="duckdb",
    ),
  )
  let schema_nested = "{\"x\": {\"a\": \"INT\"}, \"y\": {\"b\": \"INT\"}, \"z\": {\"c\": \"INT\", \"d\": \"INT\"}}"
  assert_not_eq(
    canon_sql(
      "SELECT a + 1 AS shared FROM x UNION BY NAME (SELECT b AS shared FROM y UNION BY NAME SELECT c AS shared FROM z)",
      schema=schema_nested,
      dialect="duckdb",
    ),
    canon_sql(
      "SELECT a + 1 AS shared FROM x UNION BY NAME (SELECT b AS shared FROM y UNION BY NAME SELECT d AS shared FROM z)",
      schema=schema_nested,
      dialect="duckdb",
    ),
  )
}

///|
test "canonicalize_internal_names: case folding" {
  // postgres: unquoted `a` and quoted `"a"` are the same column
  let pg_schema = "{\"x\": {\"a\": \"INT\", \"b\": \"INT\"}}"
  assert_eq(
    canon_sql("SELECT a FROM x", schema=pg_schema, dialect="postgres"),
    canon_sql("SELECT \"a\" FROM x", schema=pg_schema, dialect="postgres"),
  )
  // Snowflake: unquoted `a` is `A`, quoted `"a"` is a different column
  assert_eq(
    canon_sql(
      "SELECT a, \"a\" FROM x",
      schema="{\"X\": {\"A\": \"INT\", \"\\\"a\\\"\": \"INT\"}}",
      dialect="snowflake",
    ),
    "SELECT \"_t0\".\"A\" AS \"A\", \"_t0\".\"a\" AS \"a\" FROM \"_t0\" AS \"_t0\"",
  )
  // ... but unquoted `A` and quoted `"A"` are the same column
  assert_eq(
    canon_sql(
      "SELECT A, \"A\" FROM x",
      schema="{\"X\": {\"A\": \"INT\"}}",
      dialect="snowflake",
    ),
    "SELECT \"_t0\".\"A\" AS \"A\", \"_t0\".\"A\" AS \"A\" FROM \"_t0\" AS \"_t0\"",
  )
}

///|
test "canonicalize_internal_names: self-joined ctes" {
  let cte_self_join_schema = "{\"src\": {\"foo\": \"INT\", \"bar\": \"INT\"}}"
  assert_eq(
    canon_sql(
      "WITH t AS (SELECT * FROM src) SELECT x.foo AS l, y.bar AS r FROM t AS x JOIN t AS y ON x.foo = y.foo",
      schema=cte_self_join_schema,
    ),
    "WITH \"_t1\" AS (SELECT \"_t0\".\"foo\" AS \"_c0\", \"_t0\".\"bar\" AS \"_c1\" FROM \"_t0\" AS \"_t0\") SELECT \"_t2\".\"_c0\" AS \"l\", \"_t3\".\"_c1\" AS \"r\" FROM \"_t1\" AS \"_t2\" JOIN \"_t1\" AS \"_t3\" ON \"_t2\".\"_c0\" = \"_t3\".\"_c0\"",
  )
  // Three references to the same CTE each get their own alias
  let canon_triple = canon_expr(
    qualify_expr(
      "WITH t AS (SELECT * FROM src) SELECT a.foo, b.foo, c.foo FROM t AS a JOIN t AS b ON a.foo = b.foo JOIN t AS c ON b.foo = c.foo",
      schema=cte_self_join_schema,
    ),
  )
  let scope = @optimizer.build_scope(canon_triple).unwrap()
  let outer_table_aliases = scope.tables().map(t => t.alias())
  assert_eq(sorted_set(outer_table_aliases).length(), 3)
  assert_eq(scope.selected_sources().length(), 3)
}

///|
test "canonicalize_internal_names: unresolved UNNEST element type (duckdb)" {
  // Python compares DuckDB output, whose generator renders the comma-joined UNNEST as
  // `JOIN UNNEST("_t0"."arr") AS "_t1"("_c0") ON TRUE` (not in src/dialects/duckdb yet), so
  // the AST is checked through the base dialect (expected from the Python reference).
  let e = canon_expr(
    qualify_expr(
      "SELECT v FROM t, UNNEST(t.arr) AS v(v)",
      schema="{\"t\": {\"arr\": \"ARRAY<INT>\"}}",
      dialect="duckdb",
    ),
  )
  assert_eq(
    gen_sql(e),
    "SELECT \"_t1\".\"_c0\" AS \"v\" FROM \"_t0\" AS \"_t0\", UNNEST(\"_t0\".\"arr\") AS \"_t1\"(\"_c0\")",
  )
}

///|
test "canonicalize: inline asserts" {
  // In T-SQL, SELECT a + b can produce a NULL, so it can't become a CONCAT in Postgres
  let ast = @optimizer.optimize(
    parse_sql("SELECT CAST(a AS TEXT) + CAST(b AS TEXT) FROM t", read="tsql"),
    dialect?=dialect_of(Some("tsql")),
    rules=[Qualify, QuoteIdentifiers, AnnotateTypes, Canonicalize],
  )
  assert_eq(
    gen_sql(ast, dialect="postgres"),
    "SELECT CAST(\"t\".\"a\" AS TEXT) || CAST(\"t\".\"b\" AS TEXT) AS \"_col_0\" FROM \"t\" AS \"t\"",
  )
  // DateDiff args without inferred types should not crash
  assert_eq(
    gen_sql(@optimizer.canonicalize(parse_sql("SELECT DATEDIFF(a, b) FROM t"))),
    "SELECT DATEDIFF(CAST(a AS DATETIME), CAST(b AS DATETIME)) FROM t",
  )
}
