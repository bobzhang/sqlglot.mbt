// Ports of test_scope, test_scope_warning, test_traverse_set_operation_invalid_operand and
// test_recursive_cte of tests/test_optimizer.py.

///|
/// `set(scope.sources)`, sorted.
fn source_names(scope : @optimizer.Scope) -> Array[String] {
  let names = scope.sources.keys().collect()
  names.sort_by(py_cmp)
  names
}

///|
fn sorted_set(xs : Array[String]) -> Array[String] {
  let ys = xs.copy()
  ys.sort_by(py_cmp)
  ys.dedup()
  ys
}

///|
/// Runs `check` over both `traverse_scope(e)` and `build_scope(e).traverse()`.
fn both_traversals(
  e : @core.Expr,
  check : (Array[@optimizer.Scope]) -> Unit raise,
) -> Unit raise {
  check(@optimizer.traverse_scope(e))
  check(@optimizer.build_scope(e).unwrap().traverse())
}

///|
test "scope: columns of a bigquery UNNEST predicate" {
  let ast = parse_sql("SELECT IF(a IN UNNEST(b), 1, 0) AS c FROM t", read="bigquery")
  let columns = @optimizer.build_scope(ast).unwrap().columns()
  assert_eq(columns.length(), 2)
  assert_true(columns[0].equal(@core.column_of("a")))
  assert_true(columns[1].equal(@core.column_of("b")))
}

///|
test "scope: many unions" {
  let many_unions = parse_sql(Array::make(10000, "SELECT x FROM t").join(" UNION ALL "))
  let scopes_using_traverse = @optimizer.build_scope(many_unions).unwrap().traverse()
  let scopes_using_traverse_scope = @optimizer.traverse_scope(many_unions)
  assert_eq(
    scopes_using_traverse.length(),
    scopes_using_traverse_scope.length(),
  )
  for i, x in scopes_using_traverse {
    assert_true(
      physical_equal(x.expression, scopes_using_traverse_scope[i].expression),
    )
  }
}

///|
test "scope: ctes, joins and subqueries" {
  let sql =
    #|WITH q AS (
    #|  SELECT x.b FROM x
    #|), r AS (
    #|  SELECT y.b FROM y
    #|), z as (
    #|  SELECT cola, colb FROM (VALUES(1, 'test')) AS tab(cola, colb)
    #|)
    #|SELECT
    #|  r.b,
    #|  s.b
    #|FROM r
    #|JOIN (
    #|  SELECT y.c AS b FROM y
    #|) s
    #|ON s.b = r.b
    #|WHERE s.b > (SELECT MAX(x.a) FROM x WHERE x.b = s.b)
  let expression = parse_sql(sql)
  both_traversals(expression, scopes => {
    assert_eq(scopes.length(), 7)
    assert_eq(gen_sql(scopes[0].expression), "SELECT x.b FROM x")
    assert_eq(gen_sql(scopes[1].expression), "SELECT y.b FROM y")
    assert_eq(
      gen_sql(scopes[2].expression),
      "(VALUES (1, 'test')) AS tab(cola, colb)",
    )
    assert_eq(
      gen_sql(scopes[3].expression),
      "SELECT cola, colb FROM (VALUES (1, 'test')) AS tab(cola, colb)",
    )
    assert_eq(gen_sql(scopes[4].expression), "SELECT y.c AS b FROM y")
    assert_eq(
      gen_sql(scopes[5].expression),
      "SELECT MAX(x.a) FROM x WHERE x.b = s.b",
    )
    assert_eq(gen_sql(scopes[6].expression), gen_sql(parse_sql(sql)))
    inspect(source_names(scopes[6]), content="[q, r, s, z]")
    assert_eq(scopes[6].columns().length(), 6)
    inspect(
      sorted_set(scopes[6].columns().map(c => c.table_name())),
      content="[r, s]",
    )
    assert_eq(scopes[6].source_columns("q").length(), 0)
    assert_eq(scopes[6].source_columns("r").length(), 2)
    inspect(
      sorted_set(scopes[6].source_columns("r").map(c => c.table_name())),
      content="[r]",
    )
    inspect(
      sorted_set(scopes[6].find_all([Column]).collect().map(c => gen_sql(c))),
      content="[r.b, s.b]",
    )
    assert_eq(gen_sql(scopes[6].find([Column]).unwrap()), "r.b")
    inspect(
      sorted_set(scopes[0].find_all([Column]).collect().map(c => gen_sql(c))),
      content="[x.b]",
    )
  })

  // We can walk in scope from an arbitrary node
  let in_scope = []
  for node in @optimizer.walk_in_scope(expression.find([Where]).unwrap()) {
    if node.kind == Column {
      in_scope.push(gen_sql(node))
    }
  }
  inspect(sorted_set(in_scope), content="[s.b]")
}

///|
test "scope: parentheses don't introduce a scope without an alias" {
  let sql = "SELECT * FROM (((SELECT * FROM (t1 JOIN t2) AS t3) JOIN (SELECT * FROM t4)))"
  both_traversals(parse_sql(sql), scopes => {
    assert_eq(scopes.length(), 4)
    assert_eq(gen_sql(scopes[0].expression), "t1, t2")
    inspect(source_names(scopes[0]), content="[t1, t2]")
    assert_eq(gen_sql(scopes[1].expression), "SELECT * FROM (t1, t2) AS t3")
    inspect(source_names(scopes[1]), content="[t3]")
    assert_eq(gen_sql(scopes[2].expression), "SELECT * FROM t4")
    inspect(source_names(scopes[2]), content="[t4]")
    assert_eq(
      gen_sql(scopes[3].expression),
      "SELECT * FROM (((SELECT * FROM (t1, t2) AS t3), (SELECT * FROM t4)))",
    )
    inspect(source_names(scopes[3]), content="[]")
  })
}

///|
test "scope: udtfs" {
  let inner_query = "SELECT bar FROM baz"
  for udtf in ["UNNEST((\{inner_query}))", "LATERAL (\{inner_query})"] {
    let sql = "SELECT a FROM foo CROSS JOIN \{udtf}"
    both_traversals(parse_sql(sql), scopes => {
      assert_eq(scopes.length(), 3)
      assert_eq(gen_sql(scopes[0].expression), inner_query)
      inspect(source_names(scopes[0]), content="[baz]")
      assert_eq(gen_sql(scopes[1].expression), udtf)
      // foo is a lateral source
      inspect(source_names(scopes[1]), content="[, foo]")
      assert_eq(gen_sql(scopes[2].expression), sql)
      inspect(source_names(scopes[2]), content="[, foo]")
    })
  }
}

///|
test "scope: DML statements" {
  let sql = "UPDATE customers SET total_spent = (SELECT 1 FROM t1) WHERE EXISTS (SELECT 1 FROM t2)"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 2)
  assert_true(scopes.all(s => s.is_subquery()))
  let sql = "UPDATE t1 SET x = s.x FROM (SELECT x FROM t2) AS s"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 2)
  assert_eq(gen_sql(scopes[0].expression), "SELECT x FROM t2")
  inspect(source_names(scopes[0]), content="[t2]")
  assert_true(scopes[0].is_derived_table())
  inspect(source_names(scopes[1]), content="[s]")

  // Joins and column lists attached to the FROM-position subquery are not lost
  let sql = "UPDATE t1 SET x = s.renamed FROM (SELECT y FROM t2) AS s(renamed) CROSS JOIN v WHERE v.id = t1.id"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 2)
  inspect(scopes[0].outer_columns, content="[renamed]")
  inspect(source_names(scopes[1]), content="[s, v]")
  let sql = "UPDATE t1 SET x = 1 FROM (t2 JOIN v ON t2.id = v.id) WHERE t1.id = t2.id"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 1)
  inspect(source_names(scopes[0]), content="[t2, v]")
  let sql = "UPDATE tbl1 SET col = 1 WHERE EXISTS (SELECT 1 FROM tbl2 WHERE tbl1.id = tbl2.id)"
  assert_eq(@optimizer.traverse_scope(parse_sql(sql)).length(), 1)
  let sql = "UPDATE tbl1 SET col = 0"
  assert_eq(@optimizer.traverse_scope(parse_sql(sql)).length(), 0)

  // Bare tables in relation position get their own scopes, including any attached joins
  let sql = "UPDATE t1 SET x = u.x FROM c.db.u AS u"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 1)
  inspect(source_names(scopes[0]), content="[u]")
  let sql = "MERGE INTO t1 USING c.db.u AS u ON t1.id = u.id WHEN MATCHED THEN UPDATE SET x = u.x"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 1)
  inspect(source_names(scopes[0]), content="[u]")
  let sql = "WITH source AS (SELECT * FROM c.db.real) DELETE FROM t1 USING source JOIN c.db.lookup AS l ON source.id = l.id"
  let scopes = @optimizer.traverse_scope(parse_sql(sql, read="duckdb"))
  assert_eq(scopes.length(), 2)
  inspect(source_names(scopes[0]), content="[real]")
  inspect(source_names(scopes[1]), content="[l, source]")
  guard scopes[1].sources.get("source") is Some(ScopeSource(s)) else {
    fail("expected a scope source")
  }
  assert_true(physical_equal(s, scopes[0]))

  // The subquery joined to a FROM-position table is scoped by that table, not twice
  let sql = "UPDATE t1 SET x = q.x FROM c.db.u AS u JOIN (SELECT * FROM c.db.v) AS q ON u.id = q.id"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 2)
  inspect(source_names(scopes[0]), content="[v]")
  inspect(source_names(scopes[1]), content="[q, u]")
}

///|
test "scope: DML value-position subqueries can be correlated" {
  assert_eq(
    qualify_sql(
      "UPDATE t SET x = (SELECT MAX(u.a) FROM u WHERE u.id = t.id)",
      schema="{\"t\": {\"id\": \"int\", \"x\": \"int\"}, \"u\": {\"a\": \"int\", \"id\": \"int\"}}",
    ),
    "UPDATE \"t\" SET \"x\" = (SELECT MAX(\"u\".\"a\") AS \"_col_0\" FROM \"u\" AS \"u\" WHERE \"u\".\"id\" = \"t\".\"id\")",
  )

  // The query of an INSERT / CTAS is scoped as a derived table
  for sql in [
    "INSERT INTO t (SELECT a FROM x)", "CREATE TABLE t AS (SELECT a FROM x)",
  ] {
    let scopes = @optimizer.traverse_scope(parse_sql(sql))
    assert_eq(scopes.length(), 2)
    assert_eq(gen_sql(scopes[0].expression), "SELECT a FROM x")
    inspect(source_names(scopes[0]), content="[x]")
    inspect(source_names(scopes[1]), content="[]")
  }
  let sql = "MERGE INTO t USING (SELECT id, a FROM u) AS s ON t.id = s.id WHEN MATCHED THEN UPDATE SET x = s.a"
  let scopes = @optimizer.traverse_scope(parse_sql(sql))
  assert_eq(scopes.length(), 1)
  inspect(source_names(scopes[0]), content="[u]")
  assert_true(scopes[0].is_subquery())
  assert_eq(
    qualify_sql(
      "MERGE INTO t USING (SELECT * FROM u) AS s ON t.id = s.id WHEN MATCHED THEN UPDATE SET x = (SELECT MAX(w.a) FROM w WHERE w.id = t.id)",
      schema="{\"t\": {\"id\": \"int\", \"x\": \"int\"}, \"u\": {\"id\": \"int\", \"a\": \"int\"}, \"w\": {\"id\": \"int\", \"a\": \"int\"}}",
    ),
    "MERGE INTO \"t\" USING (SELECT \"u\".\"id\" AS \"id\", \"u\".\"a\" AS \"a\" FROM \"u\" AS \"u\") AS \"s\" ON \"t\".\"id\" = \"s\".\"id\" WHEN MATCHED THEN UPDATE SET \"x\" = (SELECT MAX(\"w\".\"a\") AS \"_col_0\" FROM \"w\" AS \"w\" WHERE \"w\".\"id\" = \"t\".\"id\")",
  )
}

///|
/// `exp.select("1").union("VALUES (2)")`
fn select_1_union_values() -> @core.Expr raise {
  @core.set_operation(Union, parse_sql("SELECT 1"), parse_sql("VALUES (2)"))
}

///|
test "scope: VALUES as a set operation operand" {
  both_traversals(select_1_union_values(), scopes => {
    assert_eq(scopes.length(), 3)
    assert_eq(gen_sql(scopes[0].expression), "SELECT 1")
    assert_eq(gen_sql(scopes[1].expression), "VALUES (2)")
    assert_eq(gen_sql(scopes[2].expression), "SELECT 1 UNION VALUES (2)")
  })
  assert_eq(
    gen_sql(@optimizer.qualify(select_1_union_values())),
    "SELECT 1 AS \"1\" UNION VALUES (2)",
  )
}

///|
test "scope: chained bigquery UNNEST sources" {
  let sql = "SELECT * FROM t LEFT JOIN UNNEST(a) AS a1 LEFT JOIN UNNEST(a1.a) AS a2"
  let scope = @optimizer.build_scope(parse_sql(sql, read="bigquery")).unwrap()
  let names = scope.selected_sources().keys().collect()
  names.sort_by(py_cmp)
  inspect(names, content="[a1, a2, t]")
}

///|
test "scope: correlated subqueries through ctes" {
  for sql in [
    // the outer table name collides with a CTE name
    "WITH x AS (SELECT 1 AS id) SELECT x.id, (SELECT MAX(x2.id) FROM x AS x2 WHERE x2.id = x.id) AS mx FROM x",
    // a CTE defined in the same WITH clause as another CTE used in the outer query
    "WITH x AS (SELECT 1 AS id), y AS (SELECT 2 AS id) SELECT (SELECT y.id FROM y WHERE y.id = x.id) FROM x",
    // an outer CTE referenced through a derived table
    "WITH x AS (SELECT 1 AS id) SELECT (SELECT x.id FROM (SELECT * FROM x) AS sub) FROM x",
  ] {
    let scopes = @optimizer.traverse_scope(parse_sql(sql))
    let subquery_scope = scopes.search_by(s => s.is_subquery()).map(i => scopes[i]).unwrap()
    assert_true(subquery_scope.is_correlated_subquery())
    assert_true(
      subquery_scope.external_columns().map(c => gen_sql(c)).contains("x.id"),
    )
  }
}

///|
test "scope: warning for untraversable scopes" {
  @core.take_log_messages() |> ignore
  assert_eq(
    @optimizer.traverse_scope(parse_sql("WITH q AS (@y) SELECT * FROM q")).length(),
    1,
  )
  let messages = @core.take_log_messages()
  assert_true(messages.any(m => m.contains("Cannot traverse scope")))
}

///|
test "scope: invalid set operation operand" {
  let cases = [
    @core.mk(Union, [
      ("this", @core.column_of("a")),
      ("expression", parse_sql("SELECT 1")),
    ]),
    @core.mk(Union, [
      ("this", parse_sql("SELECT 1")),
      ("expression", @core.column_of("a")),
    ]),
  ]
  for expression in cases {
    assert_raises_with(
      () => @optimizer.qualify(expression) |> ignore,
      "Cannot build a scope for set operation operand",
    )
  }
}

///|
test "scope: recursive cte sources" {
  let query = parse_sql(
    (
      #|with recursive t(n) AS
      #|(
      #|  select 1
      #|  union all
      #|  select n + 1
      #|  FROM t
      #|  where n < 3
      #|), y AS (
      #|  select n
      #|  FROM t
      #|  union all
      #|  select n + 1
      #|  FROM y
      #|  where n < 2
      #|)
      #|select * from y
    ),
  )
  let cte_scopes = @optimizer.build_scope(query).unwrap().cte_scopes
  assert_eq(cte_scopes.length(), 2)
  let names = fn(s : @optimizer.Scope) {
    let ks = s.cte_sources.keys().collect()
    ks.sort_by(py_cmp)
    ks
  }
  inspect(names(cte_scopes[0]), content="[t]")
  inspect(names(cte_scopes[1]), content="[t, y]")
}
