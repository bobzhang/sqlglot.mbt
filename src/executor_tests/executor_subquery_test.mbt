// Port of tests/test_executor.py (part 2: subqueries).

///|
test "execute_subqueries" {
  assert_rows(
    @executor.execute(
      "SELECT * FROM table WHERE a = (SELECT MAX(a) FROM table)",
      tables=mk_tables(
        (
          #|{"table": [{"a": 1, "b": 1}, {"a": 2, "b": 2}]}
        ),
      ),
    ),
    "[(2, 2)]",
  )
  let table1_view = @sqlglot.select(["id", "sub_type"])
    .from_("table1")
    .subquery()
  let select_from_sub_query = @sqlglot.select(["id AS id_alias", "sub_type"]).from_(
    table1_view,
  )
  let expression = @sqlglot.select(["*"])
    .from_("cte1")
    .with_("cte1", select_from_sub_query)
  let schema = mk_schema(
    (
      #|{"table1": {"id": "str", "sub_type": "str"}}
    ),
  )
  let executed = @executor.execute(
    expression,
    tables=mk_tables(
      (
        #|{"table1": []}
      ),
    ),
    schema~,
  )
  assert_rows(executed, "[]")
  assert_columns(executed, ["id_alias", "sub_type"])
}

///|
test "subqueries" {
  // expected rows are duckdb's, which postgres agrees with on every case here
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}, "empty_table": {"b": "int"}, "tbl_with_null": {"b": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{
      #|  "x": [{"a": 1}, {"a": 2}, {"a": 3}, {"a": 5}],
      #|  "y": [{"b": 2}, {"b": 3}],
      #|  "empty_table": [],
      #|  "tbl_with_null": [{"b": 2}, {"b": None}],
      #|}
    ),
  )
  let s = Suite::new("subqueries")
  for
    case in [
      (
        "SELECT a FROM x WHERE NOT EXISTS (SELECT 1 FROM y WHERE b = x.a OR b = 3)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT 1 FROM y WHERE NOT b = x.a)", "[(1,), (2,), (3,), (5,)]",
      ),
      ("SELECT a FROM x WHERE EXISTS (SELECT 1 FROM empty_table)", "[]"),
      (
        "SELECT a, (SELECT MAX(b) FROM y WHERE b > x.a) AS m FROM x", "[(1, 3), (2, 3), (3, None), (5, None)]",
      ),
      (
        "SELECT a FROM x WHERE (SELECT COUNT(*) FROM y WHERE b > x.a) > 0", "[(1,), (2,)]",
      ),
      (
        "SELECT a FROM x WHERE a IN (SELECT b FROM y WHERE b = x.a OR b = 3)", "[(2,), (3,)]",
      ),
      ("SELECT a FROM x WHERE a NOT IN (SELECT b FROM y)", "[(1,), (5,)]"),
      ("SELECT a FROM x WHERE a IN (SELECT b FROM tbl_with_null)", "[(2,)]"),
      ("SELECT a FROM x WHERE a NOT IN (SELECT b FROM tbl_with_null)", "[]"),
      (
        "SELECT a FROM x WHERE a IN (5, (SELECT MIN(b) FROM y WHERE b > x.a))", "[(5,)]",
      ),
      (
        "SELECT a FROM x WHERE (SELECT MIN(b) FROM y WHERE b > x.a) IN (1, 2)", "[(1,)]",
      ),
      (
        "SELECT a FROM x WHERE a > ANY (SELECT b FROM tbl_with_null)", "[(3,), (5,)]",
      ),
      ("SELECT a FROM x WHERE a > ALL (SELECT b FROM tbl_with_null)", "[]"),
      ("SELECT a FROM x WHERE a > ANY (SELECT b FROM empty_table)", "[]"),
      (
        "SELECT a FROM x WHERE a > ALL (SELECT b FROM empty_table)", "[(1,), (2,), (3,), (5,)]",
      ),
      ("SELECT a FROM x WHERE a > SOME (SELECT b FROM y)", "[(3,), (5,)]"),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT 1 FROM y WHERE b = x.a AND EXISTS (SELECT 1 FROM tbl_with_null WHERE tbl_with_null.b = y.b))",
        "[(2,)]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT 1 FROM y WHERE b = 99 OR EXISTS (SELECT 1 FROM tbl_with_null WHERE tbl_with_null.b = x.a OR tbl_with_null.b = 99))",
        "[(2,)]",
      ),
      (
        "SELECT a FROM x WHERE a IN (SELECT b FROM y WHERE b = x.a) OR a IN (SELECT b FROM tbl_with_null WHERE b = x.a)",
        "[(2,), (3,)]",
      ),
      (
        "SELECT a FROM x WHERE a IN (SELECT b FROM y UNION SELECT b FROM tbl_with_null)",
        "[(2,), (3,)]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS ((SELECT 1 FROM y WHERE b = x.a OR b = 99))",
        "[(2,), (3,)]",
      ),
      (
        "SELECT a FROM x GROUP BY a HAVING MAX(a) > (SELECT MIN(b) FROM y)", "[(3,), (5,)]",
      ),
      (
        "WITH w AS (SELECT b, COUNT(*) AS k FROM y GROUP BY b) SELECT a FROM x WHERE EXISTS (SELECT 1 FROM w WHERE w.b = x.a OR w.k = 2)",
        "[(2,), (3,)]",
      ),
      (
        "WITH c AS (SELECT b FROM y) SELECT a FROM x WHERE a IN (SELECT b FROM c) AND NOT EXISTS (SELECT 1 FROM c WHERE b = x.a OR b = 99)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT 1 FROM y WHERE b = x.a OR EXISTS (SELECT 1 FROM tbl_with_null WHERE tbl_with_null.b = x.a))",
        "[(2,), (3,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows_unordered(@executor.execute(sql, schema~, tables~), rows)
    })
  }
  s.finish()
}

///|
fn optimize_for_plan(
  sql : String,
  schema : Map[String, @optimizer.SchemaNode],
) -> @planner.Plan raise {
  let e = @optimizer.optimize(
    @sqlglot.parse_one(sql),
    schema=@optimizer.MappingSchema::new(schema~),
    leave_tables_isolated=true,
  )
  @planner.Plan::new(e)
}

///|
test "subquery_memoization" {
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  // {"x": [{"a": i % 3} for i in range(12)], ...}
  let x = []
  for i in 0..<12 {
    x.push("{\"a\": \{i % 3}}")
  }
  let tables = mk_tables(
    "{\"x\": [\{x.join(", ")}], \"y\": [{\"b\": 1}, {\"b\": 2}]}",
  )
  for
    case in [
      (
        "SELECT a FROM x WHERE NOT EXISTS (SELECT 1 FROM y WHERE b = x.a OR b = 9)",
        1,
      ),
      (
        "SELECT a FROM x WHERE NOT EXISTS (SELECT 1 FROM y WHERE b = 9 OR EXISTS (SELECT 1 FROM y AS y2 WHERE y2.b = x.a OR y2.b = 9))",
        2,
      ),
    ] {
    let (sql, expected_plans) = case
    let executor = @executor.PythonExecutor::new(
      tables=@executor.ensure_tables(Some(tables)),
    )
    executor.execute(optimize_for_plan(sql, schema)) |> ignore
    // one plan per subquery, and one run per distinct correlated value of the 12 rows
    assert_eq(executor.subquery_cache_sizes(), Array::make(expected_plans, 3))
  }
}

///|
test "subquery_execution_does_not_mutate_the_plan" {
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 2}], "y": [{"b": 2}]}
    ),
  )
  let plan = optimize_for_plan(
    "SELECT a FROM x WHERE NOT EXISTS (SELECT 1 FROM y WHERE b = x.a OR b = 9)",
    schema,
  )
  let before = @core.expr_to_sql(plan.expression)
  @executor.PythonExecutor::new(tables=@executor.ensure_tables(Some(tables))).execute(
    plan,
  )
  |> ignore
  assert_eq(@core.expr_to_sql(plan.expression), before)
}

///|
test "correlated_not_in_is_not_unnested" {
  // the LEFT-JOIN-anti rewrite decides NOT IN using `<> `/`IS NULL` logic, which
  // doesn't reproduce NOT IN's three-valued NULL semantics for a correlated subquery
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 2}, {"a": 3}, {"a": 5}], "y": [{"b": 2}, {"b": 3}]}
    ),
  )
  assert_rows(
    @executor.execute(
      "SELECT a FROM x WHERE a NOT IN (SELECT b FROM y WHERE b = x.a)",
      schema~,
      tables~,
    ),
    "[(1,), (5,)]",
  )
  assert_rows(
    @executor.execute(
      "SELECT a FROM x WHERE NOT (a IN (SELECT b FROM y WHERE b = x.a))",
      schema~,
      tables~,
    ),
    "[(1,), (5,)]",
  )
  assert_rows(
    @executor.execute(
      "SELECT a FROM x WHERE a NOT IN (SELECT b FROM y WHERE y.c = x.c)",
      schema=mk_schema(
        (
          #|{"x": {"a": "int", "c": "int"}, "y": {"b": "int", "c": "int"}}
        ),
      ),
      tables=mk_tables(
        (
          #|{
          #|  "x": [{"a": 1, "c": 10}, {"a": 2, "c": 20}, {"a": 3, "c": 40}],
          #|  "y": [{"b": 2, "c": 20}, {"b": 5, "c": 30}],
          #|}
        ),
      ),
    ),
    "[(1,), (3,)]",
  )
}

///|
test "subquery_cardinality" {
  // a scalar subquery must yield a single row and column, as in duckdb and postgres
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  for
    case in [
      (
        "SELECT a, (SELECT b FROM y) AS m FROM x",
        (
          #|{"x": [{"a": 1}], "y": [{"b": 2}, {"b": 3}]}
        ),
      ),
      (
        "SELECT a, (SELECT b, b FROM y) AS m FROM x",
        (
          #|{"x": [{"a": 1}], "y": [{"b": 2}]}
        ),
      ),
      // the column count is a property of the query, so it is rejected even when no
      // outer row would have evaluated it -- duckdb reports this as a binder error
      (
        "SELECT a, (SELECT b, b FROM y) AS m FROM x",
        (
          #|{"x": [], "y": [{"b": 2}]}
        ),
      ),
    ] {
    let (sql, tables) = case
    let e = execute_error(sql, schema~, tables=mk_tables(tables))
    guard e is @executor.ExecuteError(_) else {
      fail("expected an ExecuteError, got \{e}")
    }
  }
}

///|
test "correlated_count" {
  let tables = mk_tables(
    (
      #|{"parts": [{"pnum": 0, "qoh": 1}], "supplies": []}
    ),
  )
  let schema = mk_schema(
    (
      #|{"parts": {"pnum": "int", "qoh": "int"}, "supplies": {"pnum": "int", "shipdate": "int"}}
    ),
  )
  assert_rows(
    @executor.execute(
      (
        #|select *
        #|from parts
        #|where parts.qoh >= (
        #|  select count(supplies.shipdate) + 1
        #|  from supplies
        #|  where supplies.pnum = parts.pnum and supplies.shipdate < 10
        #|)
      ),
      tables~,
      schema~,
    ),
    "[(0, 1)]",
  )
}

///|
fn first_column_sorted(t : @executor.Table) -> Array[String] {
  let items = t.rows.map(r => r[0].py_str())
  items.sort()
  items
}

///|
fn sorted_strs(src : String) -> Array[String] raise {
  let items = @executor.py_iter(py(src)).map(x => x.py_str())
  items.sort()
  items
}

///|
test "correlated_exists_over_scalar_aggregate" {
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 2}, {"a": None}], "y": [{"b": 2}, {"b": 3}]}
    ),
  )
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  let all_rows = "[1, 2, None]"
  let s = Suite::new("correlated_exists_over_scalar_aggregate")
  for
    case in [
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) FROM y WHERE b = x.a)", all_rows,
      ),
      (
        "SELECT a FROM x WHERE NOT EXISTS (SELECT COUNT(*) FROM y WHERE b = x.a)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT SUM(b) FROM y WHERE b = x.a)", all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT MAX(b) FROM y WHERE b = x.a AND 1 = 2)",
        all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) FROM y WHERE b > x.a)", all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT DISTINCT COUNT(*) FROM y WHERE b = x.a)",
        all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT (SELECT COUNT(*) FROM y) FROM y WHERE b = x.a)",
        "[2]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT 1, COUNT(*) FROM y WHERE b = x.a)",
        all_rows,
      ),
      ("SELECT a FROM x WHERE EXISTS (SELECT 1, 2 FROM y WHERE b = x.a)", "[2]"),
      (
        "SELECT a FROM x WHERE NOT EXISTS (SELECT 1, 2 FROM y WHERE b = x.a)", "[1, None]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) OVER () FROM y WHERE b = x.a)",
        "[2]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT RANK() OVER (ORDER BY SUM(b)) FROM y WHERE b = x.a)",
        all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) FROM y WHERE b = x.a GROUP BY b)",
        "[2]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT RANK() OVER (ORDER BY (SUM(b))) FROM y WHERE b = x.a)",
        all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT LAG(SUM(b)) OVER (ORDER BY 1) FROM y WHERE b = x.a)",
        all_rows,
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT SUM(b) FILTER (WHERE b > 1) OVER () FROM y WHERE b = x.a)",
        "[2]",
      ),
      // a HAVING is declined, so the executor evaluates the subquery per outer row
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) FROM y WHERE b = x.a HAVING COUNT(*) = 0)",
        "[1, None]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) FROM y WHERE b = x.a HAVING COUNT(*) > 0)",
        "[2]",
      ),
    ] {
    let (sql, expected) = case
    s.check(sql, () => {
      let actual = first_column_sorted(@executor.execute(sql, tables~, schema~))
      let expected = sorted_strs(expected)
      if actual != expected {
        fail("\{Repr(actual)} != \{Repr(expected)}")
      }
    })
  }
  // the aggregate belongs to a nested query, so the EXISTS is still conditional
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 2}, {"a": None}], "y": [{"a": 2, "b": 20}, {"a": 3, "b": 30}], "z": [{"a": 1}]}
    ),
  )
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"a": "int", "b": "int"}, "z": {"a": "int"}}
    ),
  )
  for
    case in [
      (
        "SELECT a FROM x WHERE EXISTS (SELECT * FROM (SELECT COUNT(*) AS c FROM y WHERE y.a = x.a) AS t WHERE t.c > 5)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (WITH t AS (SELECT COUNT(*) AS c FROM y WHERE y.a = x.a) SELECT t.c AS c FROM t WHERE t.c > 5)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT COUNT(*) AS c FROM y WHERE y.a = x.a INTERSECT SELECT z.a AS a FROM z)",
        "[2]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS (SELECT y.a AS a FROM y WHERE y.a = x.a INTERSECT SELECT z.a AS a FROM z)",
        "[]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS ((SELECT COUNT(*) AS c FROM y WHERE y.a = x.a) INTERSECT (SELECT z.a AS a FROM z))",
        "[2]",
      ),
      (
        "SELECT a FROM x WHERE EXISTS ((SELECT y.a AS a FROM y WHERE y.a = x.a) EXCEPT (SELECT z.a AS a FROM z))",
        "[2]",
      ),
    ] {
    let (sql, expected) = case
    s.check(sql, () => {
      let actual = first_column_sorted(@executor.execute(sql, tables~, schema~))
      let expected = sorted_strs(expected)
      if actual != expected {
        fail("\{Repr(actual)} != \{Repr(expected)}")
      }
    })
  }
  s.finish()
}

///|
test "in_any_subquery_without_a_from" {
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 2}, {"a": None}]}
    ),
  )
  let s = Suite::new("in_any_subquery_without_a_from")
  for
    case in [
      ("SELECT x.a FROM x WHERE x.a IN (SELECT 1)", "[(1,)]"),
      ("SELECT x.a FROM x WHERE x.a IN (SELECT 1 + 1)", "[(2,)]"),
      (
        "SELECT x.a FROM x WHERE x.a IN (SELECT 1 UNION SELECT 2)", "[(1,), (2,)]",
      ),
      ("SELECT x.a FROM x WHERE x.a = ANY (SELECT 1)", "[(1,)]"),
    ] {
    let (sql, rows) = case
    s.check(sql, () => assert_rows(@executor.execute(sql, tables~), rows))
  }
  s.finish()
}
