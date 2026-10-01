// Port of tests/test_executor.py (part 1).

///|
test "py_dialect" {
  let g = fn(sql : String) raise {
    @executor.python_generate(@sqlglot.parse_one(sql))
  }
  inspect(g("'x '''"), content="'x \\''")
  inspect(g("MAP([1], [2])"), content="MAP([1], [2])")
  inspect(g("1 is null"), content="1 == None")
  inspect(g("x is null"), content="scope[None][x] is None")
  inspect(g("x like 'y'"), content="LIKE(scope[None][x], 'y')")
  inspect(g("x not like 'y'"), content="NOT(LIKE(scope[None][x], 'y'))")
}

///|
test "execute_callable" {
  let tables = mk_tables(
    (
      #|{
      #|  "x": [{"a": "a", "b": "d"}, {"a": "b", "b": "e"}, {"a": "c", "b": "f"}],
      #|  "y": [{"b": "d", "c": "g"}, {"b": "e", "c": "h"}, {"b": "f", "c": "i"}],
      #|  "z": [],
      #|}
    ),
  )
  let schema = mk_schema(
    (
      #|{"x": {"a": "VARCHAR", "b": "VARCHAR"}, "y": {"b": "VARCHAR", "c": "VARCHAR"}, "z": {"d": "VARCHAR"}}
    ),
  )
  let s = Suite::new("execute_callable")
  for
    case in [
      ("SELECT * FROM x", ["a", "b"], "[('a', 'd'), ('b', 'e'), ('c', 'f')]"),
      (
        "SELECT * FROM x JOIN y ON x.b = y.b",
        ["a", "b", "b", "c"],
        "[('a', 'd', 'd', 'g'), ('b', 'e', 'e', 'h'), ('c', 'f', 'f', 'i')]",
      ),
      (
        "SELECT j.c AS d FROM x AS i JOIN y AS j ON i.b = j.b",
        ["d"],
        "[('g',), ('h',), ('i',)]",
      ),
      (
        "SELECT CONCAT(x.a, y.c) FROM x JOIN y ON x.b = y.b WHERE y.b = 'e'",
        ["_col_0"],
        "[('bh',)]",
      ),
      (
        "SELECT * FROM x JOIN y ON x.b = y.b WHERE y.b = 'e'",
        ["a", "b", "b", "c"],
        "[('b', 'e', 'e', 'h')]",
      ),
      ("SELECT * FROM z", ["d"], "[]"),
      ("SELECT d FROM z ORDER BY d", ["d"], "[]"),
      ("SELECT a FROM x WHERE x.a <> 'b'", ["a"], "[('a',), ('c',)]"),
      ("SELECT a AS i FROM x ORDER BY a", ["i"], "[('a',), ('b',), ('c',)]"),
      ("SELECT a AS i FROM x ORDER BY i", ["i"], "[('a',), ('b',), ('c',)]"),
      (
        "SELECT 100 - ORD(a) AS a, a AS i FROM x ORDER BY a",
        ["a", "i"],
        "[(1, 'c'), (2, 'b'), (3, 'a')]",
      ),
      ("SELECT a /* test */ FROM x LIMIT 1", ["a"], "[('a',)]"),
      (
        "SELECT DISTINCT a FROM (SELECT 1 AS a UNION ALL SELECT 1 AS a)",
        ["a"],
        "[(1,)]",
      ),
      (
        "SELECT DISTINCT a, SUM(b) AS b FROM (SELECT 'a' AS a, 1 AS b UNION ALL SELECT 'a' AS a, 2 AS b UNION ALL SELECT 'b' AS a, 1 AS b) GROUP BY a LIMIT 1",
        ["a", "b"],
        "[('a', 3)]",
      ),
      ("SELECT COUNT(1) AS a FROM (SELECT 1)", ["a"], "[(1,)]"),
      ("SELECT COUNT(1) AS a FROM (SELECT 1) LIMIT 0", ["a"], "[]"),
      ("SELECT a FROM x GROUP BY a LIMIT 0", ["a"], "[]"),
      ("SELECT a FROM x LIMIT 0", ["a"], "[]"),
    ] {
    let (sql, cols, rows) = case
    s.check(sql, () => {
      let result = @executor.execute(sql, schema~, tables~)
      assert_columns(result, cols)
      assert_rows(result, rows)
    })
  }
  s.finish()
}

///|
test "set_operations" {
  let tables = mk_tables(
    (
      #|{"x": [{"a": "a"}, {"a": "b"}, {"a": "c"}], "y": [{"a": "b"}, {"a": "c"}, {"a": "d"}]}
    ),
  )
  let schema = mk_schema(
    (
      #|{"x": {"a": "VARCHAR"}, "y": {"a": "VARCHAR"}}
    ),
  )
  let s = Suite::new("set_operations")
  for
    case in [
      (
        "SELECT a FROM x UNION ALL SELECT a FROM y", "[('a',), ('b',), ('c',), ('b',), ('c',), ('d',)]",
      ),
      (
        "SELECT a FROM x UNION SELECT a FROM y", "[('a',), ('b',), ('c',), ('d',)]",
      ),
      ("SELECT a FROM x EXCEPT SELECT a FROM y", "[('a',)]"),
      ("(SELECT a FROM x) EXCEPT (SELECT a FROM y)", "[('a',)]"),
      ("SELECT a FROM x INTERSECT SELECT a FROM y", "[('b',), ('c',)]"),
      (
        "SELECT i.a FROM (SELECT a FROM x UNION SELECT a FROM y) AS i JOIN (SELECT a FROM x UNION SELECT a FROM y) AS j ON i.a = j.a",
        "[('a',), ('b',), ('c',), ('d',)]",
      ),
      (
        "SELECT 1 AS a UNION SELECT 2 AS a UNION SELECT 3 AS a", "[(1,), (2,), (3,)]",
      ),
      ("SELECT 1 / 2 AS a", "[(0.5,)]"),
      ("SELECT a FROM x UNION ALL SELECT a FROM x LIMIT 1", "[('a',)]"),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      let result = @executor.execute(sql, schema~, tables~)
      assert_columns(result, ["a"])
      assert_set(result, rows)
    })
  }
  s.check("SELECT 1 / 0 AS a", () => {
    let e = execute_error("SELECT 1 / 0 AS a", schema~, tables~)
    guard e
      is @executor.ExecuteError(
        _,
        cause=Some(@executor.PyException("ZeroDivisionError", _))
      ) else {
      fail("unexpected error \{@executor.error_message(e)}")
    }
  })
  s.check("typed div", () => {
    let one = @core.literal_number("1")
    let e = @sqlglot.select([
      @core.alias_(one.div(@core.literal_number("2"), typed=true), "a"),
    ])
    let result = @executor.execute(e, schema~, tables~)
    assert_columns(result, ["a"])
    assert_rows(result, "[(0,)]")
  })
  s.check("safe div", () => {
    let one = @core.literal_number("1")
    let e = @sqlglot.select([
      @core.alias_(one.div(@core.literal_number("0"), safe=true), "a"),
    ])
    let result = @executor.execute(e, schema~, tables~)
    assert_columns(result, ["a"])
    assert_rows(result, "[(None,)]")
  })
  let duplicate_tables = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 1}, {"a": 1}, {"a": 2}], "y": [{"a": 1}, {"a": 1}, {"a": 3}]}
    ),
  )
  for
    case in [
      ("SELECT a FROM x INTERSECT ALL SELECT a FROM y", "[(1,), (1,)]"),
      ("SELECT a FROM x EXCEPT ALL SELECT a FROM y", "[(1,), (2,)]"),
      ("SELECT a FROM x INTERSECT SELECT a FROM y", "[(1,)]"),
      ("SELECT a FROM x EXCEPT SELECT a FROM y", "[(2,)]"),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, tables=duplicate_tables), rows)
    })
  }
  s.finish()
}

///|
test "set_operation_order_by" {
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"x": [{"a": 3}, {"a": 1}], "y": [{"b": 1}, {"b": 2}]}
    ),
  )
  let s = Suite::new("set_operation_order_by")
  for
    case in [
      (
        "SELECT a FROM x UNION ALL SELECT b FROM y ORDER BY a", "[(1,), (1,), (2,), (3,)]",
      ),
      ("SELECT a FROM x UNION SELECT b FROM y ORDER BY a", "[(1,), (2,), (3,)]"),
      (
        "SELECT a FROM x UNION ALL SELECT b FROM y ORDER BY a DESC", "[(3,), (2,), (1,), (1,)]",
      ),
      (
        "SELECT a FROM x UNION ALL SELECT b FROM y ORDER BY a LIMIT 2", "[(1,), (1,)]",
      ),
      (
        "SELECT a FROM x UNION ALL (SELECT b FROM y LIMIT 1) ORDER BY a", "[(1,), (1,), (3,)]",
      ),
      ("SELECT a FROM x EXCEPT SELECT b FROM y ORDER BY a", "[(3,)]"),
      ("SELECT a FROM x INTERSECT SELECT b FROM y ORDER BY a", "[(1,)]"),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, schema~, tables~), rows)
    })
  }
  s.finish()
}

///|
test "distinct_order_by" {
  let schema = mk_schema(
    (
      #|{"x": {"a": "int", "b": "int"}, "n": {"a": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{
      #|  "x": [{"a": 1, "b": 5}, {"a": 3, "b": 6}, {"a": 2, "b": 7}, {"a": 3, "b": 6}],
      #|  "n": [{"a": 1}, {"a": None}, {"a": 3}, {"a": None}],
      #|}
    ),
  )
  let s = Suite::new("distinct_order_by")
  for
    case in [
      ("SELECT DISTINCT a FROM x ORDER BY a", "[(1,), (2,), (3,)]"),
      ("SELECT DISTINCT a FROM x ORDER BY a DESC", "[(3,), (2,), (1,)]"),
      ("SELECT DISTINCT a FROM x ORDER BY a DESC LIMIT 1", "[(3,)]"),
      ("SELECT DISTINCT a FROM x ORDER BY a DESC LIMIT 1 OFFSET 1", "[(2,)]"),
      (
        "SELECT DISTINCT a, b FROM x ORDER BY b DESC", "[(2, 7), (3, 6), (1, 5)]",
      ),
      (
        "SELECT DISTINCT a + 1 AS c FROM x ORDER BY c DESC", "[(4,), (3,), (2,)]",
      ),
      (
        "SELECT DISTINCT a, SUM(b) AS s FROM x GROUP BY a ORDER BY a DESC", "[(3, 12), (2, 7), (1, 5)]",
      ),
      (
        "SELECT DISTINCT a FROM n ORDER BY a NULLS FIRST", "[(None,), (1,), (3,)]",
      ),
      (
        "SELECT DISTINCT a FROM n ORDER BY a DESC NULLS LAST", "[(3,), (1,), (None,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, schema~, tables~), rows)
    })
  }
  // duckdb/sqlite pick an arbitrary row's value here instead of rejecting like postgres
  let schema2 = mk_schema(
    (
      #|{"x": {"a": "int", "b": "int"}}
    ),
  )
  let tables2 = mk_tables(
    (
      #|{"x": [{"a": 5, "b": 10}, {"a": 1, "b": 10}, {"a": 3, "b": 20}]}
    ),
  )
  for
    case in [
      ("SELECT DISTINCT b FROM x ORDER BY a", "[(20,), (10,)]"),
      ("SELECT DISTINCT b FROM x ORDER BY a DESC", "[(10,), (20,)]"),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, schema=schema2, tables=tables2), rows)
    })
  }
  s.check("computed expression", () => {
    assert_rows(
      @executor.execute(
        "SELECT DISTINCT a FROM x ORDER BY a + 1 DESC",
        tables=mk_tables(
          (
            #|{"x": [{"a": 1}, {"a": 3}, {"a": 2}, {"a": 3}]}
          ),
        ),
      ),
      "[(3,), (2,), (1,)]",
    )
  })
  s.check("group by order by aggregate", () => {
    assert_rows(
      @executor.execute(
        "SELECT DISTINCT a FROM x GROUP BY a ORDER BY AVG(b)",
        tables=mk_tables(
          (
            #|{"x": [{"a": 1, "b": 10}, {"a": 2, "b": 20}, {"a": 3, "b": 28}, {"a": 2, "b": 25}, {"a": 1, "b": 40}]}
          ),
        ),
      ),
      "[(2,), (1,), (3,)]",
    )
  })
  s.check("column from different table", () => {
    assert_rows(
      @executor.execute(
        "SELECT DISTINCT x.a FROM x JOIN y ON x.id = y.id ORDER BY y.a",
        schema=mk_schema(
          (
            #|{"x": {"a": "int", "id": "int"}, "y": {"a": "int", "id": "int"}}
          ),
        ),
        tables=mk_tables(
          (
            #|{"x": [{"a": 1, "id": 1}, {"a": 2, "id": 2}], "y": [{"a": 100, "id": 1}, {"a": 50, "id": 2}]}
          ),
        ),
      ),
      "[(2,), (1,)]",
    )
  })
  let t3 = mk_tables(
    (
      #|{"x": [{"a": 1}, {"a": 3}, {"a": 2}, {"a": 3}]}
    ),
  )
  for
    case in [
      ("SELECT DISTINCT a AS z FROM x ORDER BY a DESC", "[(3,), (2,), (1,)]"),
      ("SELECT DISTINCT a AS z FROM x ORDER BY x.a DESC", "[(3,), (2,), (1,)]"),
      (
        "SELECT DISTINCT a + 1 AS z FROM x ORDER BY a + 1 DESC", "[(4,), (3,), (2,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => assert_rows(@executor.execute(sql, tables=t3), rows))
  }
  s.check("unaliased projection", () => {
    assert_rows(
      @executor.execute(
        "SELECT DISTINCT UPPER(c) FROM x ORDER BY UPPER(c) DESC",
        tables=mk_tables(
          (
            #|{"x": [{"c": "a"}, {"c": "c"}, {"c": "b"}, {"c": "c"}]}
          ),
        ),
      ),
      "[('C',), ('B',), ('A',)]",
    )
  })
  s.finish()
}

///|
test "offset" {
  let schema = mk_schema(
    (
      #|{"x": {"a": "int"}, "y": {"b": "int"}, "g": {"v": "int"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{
      #|  "x": [{"a": 3}, {"a": 1}, {"a": 5}, {"a": 2}, {"a": 4}],
      #|  "y": [{"b": 7}, {"b": 6}],
      #|  "g": [{"v": 1}, {"v": 2}, {"v": 2}, {"v": 3}, {"v": 4}, {"v": 4}, {"v": 5}, {"v": 5}],
      #|}
    ),
  )
  let s = Suite::new("offset")
  for
    case in [
      ("SELECT a FROM x ORDER BY a OFFSET 2", "[(3,), (4,), (5,)]"),
      ("SELECT a FROM x ORDER BY a LIMIT 2 OFFSET 1", "[(2,), (3,)]"),
      ("SELECT a FROM x ORDER BY a LIMIT 2 OFFSET 10", "[]"),
      (
        "SELECT a FROM x WHERE a > 1 ORDER BY a LIMIT 2 OFFSET 1", "[(3,), (4,)]",
      ),
      (
        "SELECT a, COUNT(*) AS c FROM x GROUP BY a ORDER BY a LIMIT 2 OFFSET 2",
        "[(3, 1), (4, 1)]",
      ),
      (
        "SELECT a FROM x UNION ALL SELECT b FROM y ORDER BY a LIMIT 3 OFFSET 2",
        "[(3,), (4,), (5,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, schema~, tables~), rows)
    })
  }
  let rows_x = "[(3,), (1,), (5,), (2,), (4,)]"
  let rows_union = "[(3,), (1,), (5,), (2,), (4,), (7,), (6,)]"
  let groups = "[(1, 1), (2, 2), (3, 1), (4, 2), (5, 2)]"
  let groups_having_count = "[(2, 2), (4, 2), (5, 2)]"
  let groups_having_key = "[(3, 1), (4, 2), (5, 2)]"
  // Row order is unspecified without ORDER BY, so assert cardinality and membership.
  for
    case in [
      ("SELECT a FROM x OFFSET 2", 3, rows_x),
      ("SELECT a FROM x LIMIT 2 OFFSET 1", 2, rows_x),
      ("SELECT v, COUNT(*) AS c FROM g GROUP BY v LIMIT 2 OFFSET 1", 2, groups),
      ("SELECT v, COUNT(*) AS c FROM g GROUP BY v OFFSET 3", 2, groups),
      (
        "SELECT v, COUNT(*) AS c FROM g GROUP BY v HAVING COUNT(*) > 1 LIMIT 2",
        2, groups_having_count,
      ),
      (
        "SELECT v, COUNT(*) AS c FROM g GROUP BY v HAVING COUNT(*) > 1 LIMIT 2 OFFSET 1",
        2, groups_having_count,
      ),
      (
        "SELECT v, COUNT(*) AS c FROM g GROUP BY v HAVING v > 2 LIMIT 2 OFFSET 1",
        2, groups_having_key,
      ),
      (
        "SELECT a FROM x UNION ALL SELECT b FROM y LIMIT 3 OFFSET 2", 3, rows_union,
      ),
      ("SELECT a FROM x UNION ALL SELECT b FROM y OFFSET 2", 5, rows_union),
      ("SELECT COUNT(*) AS c FROM x LIMIT 1 OFFSET 1", 0, "[(5,)]"),
    ] {
    let (sql, count, allowed) = case
    s.check(sql, () => {
      let result = @executor.execute(sql, schema~, tables~)
      if result.rows.length() != count {
        fail("expected \{count} rows, got \{rows_value(result)}")
      }
      let allowed = sorted_reprs(py(allowed))
      for r in sorted_reprs(rows_value(result)) {
        if !allowed.contains(r) {
          fail("unexpected row \{r}")
        }
      }
    })
  }
  s.finish()
}

///|
test "outer_joins_preserve_unmatched_rows" {
  let tables = mk_tables(
    (
      #|{"x": [{"id": 1}, {"id": 2}], "y": [{"id": 2}, {"id": 3}]}
    ),
  )
  assert_set(
    @executor.execute(
      "SELECT x.id, y.id FROM x FULL JOIN y ON x.id = y.id",
      tables~,
    ),
    "[(1, None), (2, 2), (None, 3)]",
  )
  assert_set(
    @executor.execute(
      "SELECT x.id, y.id FROM x LEFT JOIN y ON x.id = y.id AND y.id > 2",
      tables~,
    ),
    "[(1, None), (2, None)]",
  )
  assert_rows(
    @executor.execute("SELECT x.id, y.id FROM x JOIN y ON x.id < y.id", tables~),
    "[(1, 2), (1, 3), (2, 3)]",
  )
}

///|
test "execute_catalog_db_table" {
  let tables = mk_tables(
    (
      #|{"catalog": {"db": {"x": [{"a": "a"}, {"a": "b"}, {"a": "c"}]}}}
    ),
  )
  let schema = mk_schema(
    (
      #|{"catalog": {"db": {"x": {"a": "VARCHAR"}}}}
    ),
  )
  let result1 = @executor.execute("SELECT * FROM x", schema~, tables~)
  let result2 = @executor.execute(
    "SELECT * FROM catalog.db.x",
    schema~,
    tables~,
  )
  assert_eq(result1.columns, result2.columns)
  assert_true(@executor.py_eq(rows_value(result1), rows_value(result2)))
}

///|
test "execute_tables" {
  let tables = mk_tables(
    (
      #|{
      #|  "sushi": [{"id": 1, "price": 1.0}, {"id": 2, "price": 2.0}, {"id": 3, "price": 3.0}],
      #|  "order_items": [
      #|    {"sushi_id": 1, "order_id": 1},
      #|    {"sushi_id": 1, "order_id": 1},
      #|    {"sushi_id": 2, "order_id": 1},
      #|    {"sushi_id": 3, "order_id": 2},
      #|  ],
      #|  "orders": [{"id": 1, "user_id": 1}, {"id": 2, "user_id": 2}],
      #|}
    ),
  )
  assert_rows(
    @executor.execute(
      (
        #|SELECT
        #|  o.user_id,
        #|  SUM(s.price) AS price
        #|FROM orders o
        #|JOIN order_items i
        #|  ON o.id = i.order_id
        #|JOIN sushi s
        #|  ON i.sushi_id = s.id
        #|GROUP BY o.user_id
      ),
      tables~,
    ),
    "[(1, 4.0), (2, 3.0)]",
  )
  assert_rows(
    @executor.execute(
      "SELECT o.id, x.* FROM orders o LEFT JOIN (SELECT 1 AS id, 'b' AS x UNION ALL SELECT 3 AS id, 'c' AS x) x ON o.id = x.id",
      tables~,
    ),
    "[(1, 1, 'b'), (2, None, None)]",
  )
  assert_rows(
    @executor.execute(
      "SELECT o.id, x.* FROM orders o RIGHT JOIN (SELECT 1 AS id, 'b' AS x UNION ALL SELECT 3 AS id, 'c' AS x) x ON o.id = x.id",
      tables~,
    ),
    "[(1, 1, 'b'), (None, 3, 'c')]",
  )
}
