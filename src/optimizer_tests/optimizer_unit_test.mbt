// Ports of assorted non-fixture unit tests of tests/test_optimizer.py.

///|
fn optimize_sql_str(
  sql : String,
  dialect? : String,
  schema? : String,
  identify? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let mapping = match schema {
    Some(s) => Some(@optimizer.schema_from_json_string(s))
    None => None
  }
  @optimizer.optimize(
    parse_sql(sql, read?=dialect),
    mapping?,
    dialect?=dialect_of(dialect),
    identify?,
  )
}

///|
test "optimize: x = 1 + 1" {
  assert_eq(gen_sql(optimize_sql_str("x = 1 + 1", identify=false)), "x = 2")
}

///|
test "normalize: inline asserts" {
  assert_eq(
    gen_sql(@optimizer.normalize(parse_sql("x AND (y OR z)"), dnf=true)),
    "(x AND y) OR (x AND z)",
  )
  assert_eq(
    gen_sql(@optimizer.normalize(parse_sql("x AND (y OR z)"))),
    "x AND (y OR z)",
  )
  // Python parses Snowflake's `(a AND b) OR BOOLXOR(x, y)` into a Xor connector carrying a
  // `round_input` arg, and expects `((BOOLXOR(x, y)) OR a) AND ((BOOLXOR(x, y)) OR b)`.
  // src/dialects/snowflake doesn't parse BOOLXOR yet, so the same tree is built directly
  // and checked through the base dialect (expected string from the Python reference).
  let xor = @core.mk(Xor, [
    ("this", @core.column_of("x")),
    ("expression", @core.column_of("y")),
    ("round_input", true),
  ])
  let e = @core.mk(Or, [("this", parse_sql("(a AND b)")), ("expression", xor)])
  assert_eq(
    gen_sql(@optimizer.normalize(e)),
    "((x XOR y) OR a) AND ((x XOR y) OR b)",
  )
}

///|
test "normalization_distance" {
  fn gen_expr(depth : Int) -> @core.Expr raise {
    parse_sql(Array::make(depth, "a AND b").join(" OR "))
  }

  assert_eq(@optimizer.normalization_distance(gen_expr(2), max=100), 4)
  assert_eq(@optimizer.normalization_distance(gen_expr(3), max=100), 18)
  assert_eq(@optimizer.normalization_distance(gen_expr(10), max=100), 110)
}

///|
test "expand_alias_refs" {
  // negative integer literal as group by column
  assert_eq(
    gen_sql(optimize_sql_str("SELECT -99 AS e GROUP BY e")),
    "SELECT -99 AS \"e\" GROUP BY 1",
  )
  // order of lateral expansion with no schema
  assert_eq(
    gen_sql(
      optimize_sql_str(
        "SELECT a + 1 AS d, d + 1 AS e FROM x WHERE e > 1 GROUP BY e",
      ),
    ),
    "SELECT \"x\".\"a\" + 1 AS \"d\", \"x\".\"a\" + 1 + 1 AS \"e\" FROM \"x\" AS \"x\" WHERE (\"x\".\"a\" + 2) > 1 GROUP BY \"x\".\"a\" + 1 + 1",
  )
  let unused_schema = "{\"l\": {\"c\": \"int\"}}"
  assert_eq(
    gen_sql(
      @optimizer.qualify_columns(
        parse_sql("SELECT CAST(x AS INT) AS y FROM z AS z"),
        mapping_schema(unused_schema),
        infer_schema=false,
      ),
    ),
    "SELECT CAST(x AS INT) AS y FROM z AS z",
  )

  // BigQuery expands overlapping alias only for GROUP BY + HAVING
  let sql = "WITH data AS (SELECT 1 AS id, 2 AS my_id, 'a' AS name, 'b' AS full_name) SELECT id AS my_id, CONCAT(id, name) AS full_name FROM data WHERE my_id = 1 GROUP BY my_id, full_name HAVING my_id = 1"
  assert_eq(
    gen_sql(
      @optimizer.qualify_columns(
        parse_sql(sql, read="bigquery"),
        mapping_schema(unused_schema, dialect="bigquery"),
      ),
    ),
    "WITH data AS (SELECT 1 AS id, 2 AS my_id, 'a' AS name, 'b' AS full_name) SELECT data.id AS my_id, CONCAT(data.id, data.name) AS full_name FROM data WHERE data.my_id = 1 GROUP BY data.id, CONCAT(data.id, data.name) HAVING data.id = 1",
  )
  // Clickhouse expands overlapping alias across the entire query
  assert_eq(
    gen_sql(
      @optimizer.qualify_columns(
        parse_sql(sql, read="clickhouse"),
        mapping_schema(unused_schema, dialect="clickhouse"),
      ),
    ),
    "WITH data AS (SELECT 1 AS id, 2 AS my_id, 'a' AS name, 'b' AS full_name) SELECT data.id AS my_id, CONCAT(data.id, data.name) AS full_name FROM data WHERE data.id = 1 GROUP BY data.id, CONCAT(data.id, data.name) HAVING data.id = 1",
  )
  // BigQuery shouldn't expand aliases in complex expressions
  assert_eq(
    gen_sql(
      @optimizer.qualify_columns(
        parse_sql(
          "WITH data AS (SELECT 1 AS id) SELECT FUNC(id) AS id FROM data GROUP BY FUNC(id)",
          read="bigquery",
        ),
        mapping_schema(unused_schema, dialect="bigquery"),
      ),
    ),
    "WITH data AS (SELECT 1 AS id) SELECT FUNC(data.id) AS id FROM data GROUP BY FUNC(data.id)",
  )
  assert_eq(
    gen_sql(
      @optimizer.qualify_columns(
        parse_sql(
          "SELECT x.a, max(x.b) as x FROM x AS x GROUP BY 1 HAVING x > 1",
          read="bigquery",
        ),
        mapping_schema(unused_schema, dialect="bigquery"),
      ),
    ),
    "SELECT x.a AS a, MAX(x.b) AS x FROM x AS x GROUP BY 1 HAVING x > 1",
  )
}

///|
test "journal: record and revert" {
  let journal : @optimizer.Journal = []
  let expression = parse_sql("SELECT a, b FROM x")
  @optimizer.record(journal, expression, "expressions")
  expression.set("expressions", @core.Value::List([Node(expression.expressions()[0])]))
  assert_eq(gen_sql(expression), "SELECT a FROM x")
  @optimizer.revert(journal)
  assert_eq(gen_sql(expression), "SELECT a, b FROM x")
  assert_true(journal.is_empty())
  for i, selection in expression.expressions() {
    assert_true(physical_equal(selection.parent.unwrap(), expression))
    assert_eq(selection.arg_key, Some("expressions"))
    assert_eq(selection.index, Some(i))
  }
}

///|
test "journal: eliminate_ctes" {
  let journal : @optimizer.Journal = []
  // Removing the last CTE pops the entire WITH clause
  let sql = "WITH y AS (SELECT a FROM x) SELECT a FROM z"
  let expression = parse_sql(sql)
  @optimizer.eliminate_ctes(expression, journal~) |> ignore
  assert_eq(gen_sql(expression), "SELECT a FROM z")
  @optimizer.revert(journal)
  assert_eq(gen_sql(expression), sql)

  // The WITH clause survives when other CTEs remain
  let sql = "WITH y AS (SELECT a FROM x), z AS (SELECT b FROM x) SELECT b FROM z"
  let expression = parse_sql(sql)
  @optimizer.eliminate_ctes(expression, journal~) |> ignore
  assert_eq(
    gen_sql(expression),
    "WITH z AS (SELECT b FROM x) SELECT b FROM z",
  )
  @optimizer.revert(journal)
  assert_eq(gen_sql(expression), sql)

  // Chained removals record the same WITH clause multiple times
  let sql = "WITH y AS (SELECT a FROM x), z AS (SELECT a FROM y) SELECT 1 AS c"
  let expression = parse_sql(sql)
  @optimizer.eliminate_ctes(expression, journal~) |> ignore
  assert_eq(gen_sql(expression), "SELECT 1 AS c")
  @optimizer.revert(journal)
  assert_eq(gen_sql(expression), sql)
}

///|
test "journal: pushdown_projections" {
  let journal : @optimizer.Journal = []
  let expression = qualify_expr(
    "SELECT a FROM (SELECT a, b FROM x) AS t",
    schema=test_schema_json,
    identify=false,
  )
  let sql = gen_sql(expression)
  @optimizer.pushdown_projections(expression, journal~) |> ignore
  assert_eq(
    gen_sql(expression),
    "SELECT t.a AS a FROM (SELECT x.a AS a FROM x AS x) AS t",
  )
  @optimizer.revert(journal)
  assert_eq(gen_sql(expression), sql)
  let expression = qualify_expr(
    "WITH x AS (SELECT z, 0 AS c, SUM(d) AS s FROM t GROUP BY z, 2, 2) SELECT c, s FROM x",
    dialect="duckdb",
    identify=false,
  )
  let original = expression.copy()
  @optimizer.pushdown_projections(expression, journal~) |> ignore
  let group = expression.find([CTE]).unwrap().this_().arg("group").unwrap()
  inspect(
    group.expressions().map(e => gen_sql(e)),
    content="[t.z, 1, 1]",
  )
  @optimizer.revert(journal)
  assert_true(expression.equal(original))
}

///|
fn node_count(e : @core.Expr) -> Int {
  let mut n = 0
  for _ in e.walk() {
    n += 1
  }
  n
}

///|
test "merge_subqueries: copy budget" {
  // Each CTE references its source's projection twice, so merging the whole chain would
  // double the expression at every step
  let ctes = ["q0 AS (SELECT x.a AS a FROM x AS x)"]
  for i in 1..<17 {
    ctes.push(
      "q\{i} AS (SELECT q\{i - 1}.a + q\{i - 1}.a AS a FROM q\{i - 1} AS q\{i - 1})",
    )
  }
  let expression = parse_sql(
    "WITH \{ctes.join(", ")} SELECT q16.a AS a FROM q16 AS q16",
  )
  let input_size = node_count(expression)
  let merged = @optimizer.merge_subqueries(expression.copy())
  assert_true(merged.arg("with_") is Some(_))
  assert_true(node_count(merged) < 10 * input_size)

  // With no budget, only q16 is merged, since the outer query references it once
  let merged = @optimizer.merge_subqueries(
    expression.copy(),
    max_copy_factor=Some(0),
    min_copy_budget=0,
  )
  assert_eq(merged.arg("with_").unwrap().expressions().length(), 16)

  // A None factor disables the budget, so everything is merged despite the zero minimum
  let short_chain = parse_sql(
    "WITH \{ctes[:5].to_array().join(", ")} SELECT q4.a AS a FROM q4 AS q4",
  )
  let merged = @optimizer.merge_subqueries(
    short_chain,
    max_copy_factor=None,
    min_copy_budget=0,
  )
  assert_true(merged.arg("with_") is None)
}

///|
test "optimize: on_qualify can replace tables" {
  assert_eq(
    gen_sql(
      @optimizer.optimize(
        parse_sql("SELECT * FROM foo"),
        on_qualify=table => table.replace(Some(@core.to_table("bar"))) |> ignore,
        mapping=@optimizer.schema_from_json_string("{\"bar\": {\"a\": \"INT\"}}"),
      ),
    ),
    "SELECT \"bar\".\"a\" AS \"a\" FROM \"bar\"",
  )
}

///|
test "pushdown_projections: keeps positionally aliased columns" {
  let cases = [
    (
      "SELECT t.c FROM (SELECT a, b FROM x) AS t(c, d)", "SELECT t.c FROM (SELECT a, b FROM x) AS t(c, d)",
    ),
    (
      "SELECT t.c FROM ((SELECT a, b FROM x)) AS t(c, d)", "SELECT t.c FROM ((SELECT a, b FROM x)) AS t(c, d)",
    ),
    (
      "SELECT t.c FROM (SELECT a, b FROM x UNION ALL SELECT b, c FROM y) AS t(c, d)",
      "SELECT t.c FROM (SELECT a, b FROM x UNION ALL SELECT b, c FROM y) AS t(c, d)",
    ),
    (
      "WITH t(c, d) AS (SELECT a, b FROM x) SELECT c FROM t", "WITH t(c, d) AS (SELECT a, b FROM x) SELECT c FROM t",
    ),
    (
      "SELECT t.c FROM LATERAL (SELECT a, b FROM x) AS t(c, d)", "SELECT t.c FROM LATERAL (SELECT a, b FROM x) AS t(c, d)",
    ),
    // BY NAME merges the operands by column name, so positions don't map onto them
    (
      "WITH t(c) AS (SELECT a, b FROM x UNION ALL BY NAME SELECT b, a FROM x) SELECT c FROM t",
      "WITH t(c) AS (SELECT a, b FROM x UNION ALL BY NAME SELECT b, a FROM x) SELECT c FROM t",
    ),
    // Columns beyond the list keep their own names and are pruned as usual
    (
      "SELECT t.c FROM (SELECT a, b FROM x) AS t(c)", "SELECT t.c FROM (SELECT a FROM x) AS t(c)",
    ),
  ]
  for case_ in cases {
    let (sql, expected) = case_
    assert_eq(
      gen_sql(@optimizer.pushdown_projections(parse_sql(sql))),
      expected,
    )
  }
}

///|
fn alias_names(selects : Array[@core.Expr]) -> Array[String] {
  let names = selects.map(s => s.alias_or_name())
  names.sort()
  names.dedup()
  names
}

///|
test "pushdown_projections: keeps recursive cte self-referenced columns" {
  let optimized = optimize_sql_str(
    "WITH RECURSIVE t AS (SELECT id, link FROM graph WHERE id = 1 UNION ALL SELECT g.id, g.link FROM graph AS g, t WHERE g.id = t.link) SELECT id FROM t",
    dialect="postgres",
    schema="{\"graph\": {\"id\": \"INT\", \"link\": \"INT\"}}",
  )
  let cte = optimized.find([CTE]).unwrap()
  assert_true(alias_names(cte.this_().selects()).contains("link"))
}

///|
test "pushdown_projections: prunes non-self-referencing ctes" {
  let optimized = optimize_sql_str(
    "WITH RECURSIVE t AS (SELECT id, link FROM graph WHERE id = 1 UNION ALL SELECT g.id, g.link FROM graph AS g, t WHERE g.id = t.link), helper AS (SELECT id, link, junk FROM graph LIMIT 5) SELECT t.id FROM t JOIN helper ON t.id = helper.id",
    dialect="postgres",
    schema="{\"graph\": {\"id\": \"INT\", \"link\": \"INT\", \"junk\": \"INT\"}}",
  )
  let ctes = optimized.find_all([CTE]).collect()
  inspect(alias_names(ctes[0].this_().selects()), content="[id, link]")
  inspect(alias_names(ctes[1].this_().selects()), content="[id]")

  // A db-qualified table that shares the CTE's name is not a self-reference
  let optimized = optimize_sql_str(
    "WITH RECURSIVE t AS (SELECT id, link FROM db.t UNION ALL SELECT id, link FROM db.t) SELECT id FROM t",
    dialect="postgres",
    schema="{\"db\": {\"t\": {\"id\": \"INT\", \"link\": \"INT\"}}}",
  )
  let union = optimized.find([CTE]).unwrap().this_()
  for side in [union.this_(), union.expression_()] {
    inspect(alias_names(side.selects()), content="[id]")
  }
}

///|
test "optimize: schema with spaces" {
  let optimized = optimize_sql_str(
    "SELECT * FROM a",
    schema="{\"a\": {\"b c\": \"text\", \"\\\"d e\\\"\": \"text\"}}",
  )
  assert_true(
    optimized.equal(
      parse_sql(
        "SELECT \"a\".\"b c\" AS \"b c\", \"a\".\"d e\" AS \"d e\" FROM \"a\" AS \"a\"",
      ),
    ),
  )
}

///|
test "optimize: quotes (snowflake)" {
  let schema = "{\"example\": {\"\\\"source\\\"\": {\"id\": \"text\", \"\\\"name\\\"\": \"text\", \"\\\"payload\\\"\": \"text\"}}}"
  let expected = gen_sql(
    parse_sql(
      "SELECT \"source\".\"ID\" AS \"ID\", \"source\".\"name\" AS \"name\", \"source\".\"payload\" AS \"payload\" FROM \"EXAMPLE\".\"source\" AS \"source\"",
      read="snowflake",
    ),
    dialect="snowflake",
    pretty=true,
  )
  let sql = "SELECT * FROM example.\"source\" AS \"source\""
  assert_eq(
    gen_sql(
      qualify_expr(sql, dialect="snowflake", schema~),
      dialect="snowflake",
      pretty=true,
    ),
    expected,
  )
  assert_eq(
    gen_sql(
      optimize_sql_str(sql, dialect="snowflake", schema~),
      dialect="snowflake",
      pretty=true,
    ),
    expected,
  )
}

///|
test "optimize: no pseudocolumn expansion (bigquery schema)" {
  let schema = mapping_schema(
    "{\"a\": {\"a\": \"text\", \"b\": \"text\", \"_PARTITIONDATE\": \"date\", \"_PARTITIONTIME\": \"timestamp\"}}",
    dialect="bigquery",
  )
  assert_true(
    @optimizer.optimize(parse_sql("SELECT * FROM a"), schema~).equal(
      parse_sql("SELECT \"a\".\"a\" AS \"a\", \"a\".\"b\" AS \"b\" FROM \"a\" AS \"a\""),
    ),
  )
}

///|
test "qualify: semistructured (snowflake)" {
  let query = parse_sql("select a.b:c from d", read="snowflake")
  let qualified = @optimizer.qualify(query)
  assert_eq(qualified.expressions()[0].alias(), "c")
}

///|
test "optimize: semi/anti joins" {
  for join_kind in ["LEFT ANTI", "ANTI", "SEMI"] {
    let query = "WITH x AS (SELECT 1 AS b UNION ALL SELECT 2 AS b) SELECT x.b FROM x \{join_kind} JOIN (SELECT 1 AS b) AS sub ON x.b = sub.b"
    assert_eq(
      gen_sql(optimize_sql_str(query)),
      "WITH \"x\" AS (SELECT 1 AS \"b\" UNION ALL SELECT 2 AS \"b\"), \"sub\" AS (SELECT 1 AS \"b\") SELECT \"x\".\"b\" AS \"b\" FROM \"x\" AS \"x\" \{join_kind} JOIN \"sub\" AS \"sub\" ON \"sub\".\"b\" = \"x\".\"b\"",
    )
  }
}
