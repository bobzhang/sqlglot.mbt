// Port of tests/test_executor.py (part 3: tables, functions and semantics).

///|
test "table_depth_mismatch" {
  let e = execute_error(
    "SELECT * FROM table",
    schema=mk_schema(
      (
        #|{"db": {"table": {"col": "VARCHAR"}}}
      ),
    ),
    tables=mk_tables(
      (
        #|{"table": []}
      ),
    ),
  )
  guard e is @executor.ExecuteError(_) else {
    fail("expected ExecuteError: \{e}")
  }
}

///|
test "tables" {
  let one = fn() { @executor.Table::new(columns=["a"], rows=[[Int(1L)]]) }
  let tables = @executor.ensure_tables(
    Some({
      "catalog1": Nested({
        "db1": Nested({
          "t1": Records([[("a", Int(1L))]]),
          "t2": Records([[("a", Int(1L))]]),
        }),
        "db2": Nested({
          "t3": Records([[("a", Int(1L))]]),
          "t4": Records([[("a", Int(1L))]]),
        }),
      }),
      "catalog2": Nested({
        "db3": Nested({ "t5": Tbl(one()), "t6": Tbl(one()) }),
        "db4": Nested({ "t7": Tbl(one()), "t8": Tbl(one()) }),
      }),
    }),
  )
  let t1 = tables
    .find(@sqlglot.table_("t1", db="db1", catalog="catalog1"))
    .unwrap()
  assert_eq(t1.columns, ["a"])
  assert_rows(t1, "[(1,)]")
  let t8 = tables.find(@sqlglot.table_("t8")).unwrap()
  assert_eq(t1.columns, t8.columns)
  assert_true(@executor.py_eq(rows_value(t1), rows_value(t8)))
}

///|
test "static_queries" {
  let s = Suite::new("static_queries")
  for
    case in [
      ("SELECT 1", ["1"], "[(1,)]"),
      ("SELECT 1 + 2 AS x", ["x"], "[(3,)]"),
      ("SELECT CONCAT('a', 'b') AS x", ["x"], "[('ab',)]"),
      ("SELECT CONCAT('a', 1) AS x", ["x"], "[('a1',)]"),
      ("SELECT 1 AS x, 2 AS y", ["x", "y"], "[(1, 2)]"),
      ("SELECT 'foo' LIMIT 1", ["foo"], "[('foo',)]"),
      (
        "SELECT SUM(x), COUNT(x) FROM (SELECT 1 AS x WHERE FALSE)",
        ["_col_0", "_col_1"],
        "[(None, 0)]",
      ),
    ] {
    let (sql, cols, rows) = case
    s.check(sql, () => {
      let result = @executor.execute(sql)
      assert_columns(result, cols)
      assert_rows(result, rows)
    })
  }
  s.finish()
}

///|
test "operators_apply_to_a_whole_case_expression" {
  let tables = mk_tables(
    (
      #|{"t": [{"a": 1}, {"a": 2}]}
    ),
  )
  let s = Suite::new("case_expression")
  for
    case in [
      (
        "SELECT (CASE WHEN a = 1 THEN 'x' END) IS NOT NULL AS c FROM t", "[(True,), (False,)]",
      ),
      (
        "SELECT (CASE WHEN a = 1 THEN 'x' END) IS NULL AS c FROM t", "[(False,), (True,)]",
      ),
      (
        "SELECT (CASE WHEN a = 1 THEN 1 ELSE 2 END) + 10 AS c FROM t", "[(11,), (12,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => assert_rows(@executor.execute(sql, tables~), rows))
  }
  s.finish()
}

///|
test "like" {
  let s = Suite::new("like")
  let tables = mk_tables(
    (
      #|{"t": [{"s": "Bump version"}, {"s": "Add feature"}, {"s": None}]}
    ),
  )
  s.check("negated_like", () => {
    assert_rows(
      @executor.execute("SELECT s FROM t WHERE s LIKE 'Bump%'", tables~),
      "[('Bump version',)]",
    )
    for
      sql in [
        "SELECT s FROM t WHERE s NOT LIKE 'Bump%'", "SELECT s FROM t WHERE NOT (s LIKE 'Bump%')",
      ] {
      assert_rows(@executor.execute(sql, tables~), "[('Add feature',)]")
    }
  })
  let tables = mk_tables(
    (
      #|{"t": [{"s": "Bump version"}, {"s": "Add feature"}]}
    ),
  )
  let all = ["Bump version", "Add feature"]
  for
    case in [
      ("Bump", []),
      ("Bump%", ["Bump version"]),
      ("%version", ["Bump version"]),
      ("Bump_version", ["Bump version"]),
      ("B.mp version", []),
      ("Bump version", ["Bump version"]),
    ] {
    let (pattern, matches) = case
    s.check(pattern, () => {
      let rows = @executor.execute(
        "SELECT s FROM t WHERE s LIKE '\{pattern}'",
        tables~,
      )
      assert_eq(rows.rows.map(r => r[0].py_str()), matches)
      let negated = @executor.execute(
        "SELECT s FROM t WHERE s NOT LIKE '\{pattern}'",
        tables~,
      )
      assert_eq(
        negated.rows.map(r => r[0].py_str()),
        all.filter(r => !matches.contains(r)),
      )
    })
  }
  let tables = mk_tables(
    (
      #|{"t": [{"s": "Bump Version"}, {"s": "B.mp Version"}, {"s": "Add feature"}]}
    ),
  )
  let all = ["Bump Version", "B.mp Version", "Add feature"]
  for
    case in [
      ("bump", []),
      ("bump%", ["Bump Version"]),
      ("%version", ["Bump Version", "B.mp Version"]),
      ("bump_version", ["Bump Version"]),
      ("b.mp version", ["B.mp Version"]),
      ("b_mp version", ["Bump Version", "B.mp Version"]),
      ("bump version", ["Bump Version"]),
    ] {
    let (pattern, matches) = case
    for cased in [@core.py_lower(pattern), @core.py_upper(pattern)] {
      s.check("ilike " + cased, () => {
        let rows = @executor.execute(
          "SELECT s FROM t WHERE s ILIKE '\{cased}'",
          tables~,
        )
        assert_eq(rows.rows.map(r => r[0].py_str()), matches)
        let negated = @executor.execute(
          "SELECT s FROM t WHERE s NOT ILIKE '\{cased}'",
          tables~,
        )
        assert_eq(
          negated.rows.map(r => r[0].py_str()),
          all.filter(r => !matches.contains(r)),
        )
      })
    }
  }
  s.finish()
}

///|
test "length" {
  let tables = mk_tables(
    (
      #|{"t": [{"s": "abc"}, {"s": ""}, {"s": None}]}
    ),
  )
  for func in ["LENGTH", "CHAR_LENGTH"] {
    assert_rows(
      @executor.execute("SELECT \{func}(s) FROM t", tables~),
      "[(3,), (0,), (None,)]",
    )
  }
}

///|
test "dpipe" {
  let tables = mk_tables(
    (
      #|{"t": [{"a": "x", "b": "y", "n": 1, "arr": [1, 2], "nul": None}]}
    ),
  )
  let s = Suite::new("dpipe")
  for
    case in [
      ("a || b", "'xy'"),
      ("a || b || a", "'xyx'"),
      ("a || n", "'x1'"),
      ("n || a", "'1x'"),
      ("a || nul", "None"),
      ("nul || a", "None"),
      ("arr || arr", "[1, 2, 1, 2]"),
      ("arr || n", "[1, 2, 1]"),
      ("n || arr", "[1, 1, 2]"),
      ("arr || nul", "None"),
      ("ARRAY_CONCAT(arr, arr)", "[1, 2, 1, 2]"),
      ("ARRAY_CAT(arr, arr, arr)", "[1, 2, 1, 2, 1, 2]"),
    ] {
    let (expression, expected) = case
    s.check(expression, () => {
      assert_rows(
        @executor.execute("SELECT \{expression} FROM t", tables~),
        "[(\{expected},)]",
      )
    })
  }
  let tables = mk_tables(
    (
      #|{"t": [{"a": "x", "n": 1}]}
    ),
  )
  s.check("postgres coercion", () => {
    assert_rows(
      @executor.execute("SELECT a || n FROM t", tables~, dialect="postgres"),
      "[('x1',)]",
    )
  })
  s.check("trino coercion", () => {
    let e = execute_error("SELECT a || n FROM t", tables~, dialect="trino")
    guard e is @executor.ExecuteError(_) else {
      fail("expected ExecuteError: \{e}")
    }
  })
  s.finish()
}

///|
test "typed_division" {
  // Postgres' 10 / 3 is 3, but its 10 / 3.0 and 10 / 3::numeric are not.
  let schema = mk_schema(
    (
      #|{"t": {"n": "INT", "d": "DECIMAL"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"t": [{"n": 10, "d": 3}]}
    ),
  )
  let s = Suite::new("typed_division")
  for
    case in [
      ("SELECT n / 3.0 AS x FROM t", "10 / 3"),
      ("SELECT 3.0 / n AS x FROM t", "3.0 / 10"),
      ("SELECT CAST(n AS DOUBLE) / 3 AS x FROM t", "10 / 3"),
      ("SELECT n / d AS x FROM t", "10 / 3"), // decimal: real, but not a float
      ("SELECT n / 3 AS x FROM t", "3"),
      ("SELECT -n / 3 AS x FROM t", "-3"),
    ] {
    let (sql, expected) = case
    for dialect in ["postgres", "sqlite"] {
      s.check("\{dialect}: \{sql}", () => {
        assert_rows(
          @executor.execute(sql, schema~, tables~, dialect~),
          "[(\{expected},)]",
        )
      })
    }
  }
  s.check("inferred schema", () => {
    assert_rows(
      @executor.execute("SELECT n / 3 AS x FROM t", tables~, dialect="postgres"),
      "[(3,)]",
    )
  })
  let schema = mk_schema(
    (
      #|{"t": {"n": "INT"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"t": [{"n": None}]}
    ),
  )
  for sql in ["SELECT n / 3 AS x FROM t", "SELECT 3 / n AS x FROM t"] {
    for dialect in ["postgres", "sqlite"] {
      s.check("null \{dialect}: \{sql}", () => {
        assert_rows(
          @executor.execute(sql, schema~, tables~, dialect~),
          "[(None,)]",
        )
      })
    }
  }
  s.finish()
}

///|
test "null_ordering_honors_nulls_first_and_dialect_defaults" {
  let schema = mk_schema(
    (
      #|{"t": {"a": "INT"}}
    ),
  )
  let tables = mk_tables(
    (
      #|{"t": [{"a": 1}, {"a": None}, {"a": 3}, {"a": None}]}
    ),
  )
  let s = Suite::new("null_ordering")
  for
    case in [
      ("SELECT a FROM t ORDER BY a NULLS FIRST", "[None, None, 1, 3]"),
      ("SELECT a FROM t ORDER BY a NULLS LAST", "[1, 3, None, None]"),
      ("SELECT a FROM t ORDER BY a DESC NULLS FIRST", "[None, None, 3, 1]"),
      ("SELECT a FROM t ORDER BY a DESC NULLS LAST", "[3, 1, None, None]"),
    ] {
    let (sql, expected) = case
    for dialect in ["postgres", "duckdb", "mysql"] {
      s.check("\{dialect}: \{sql}", () => {
        let result = @executor.execute(sql, schema~, tables~, dialect~)
        assert_true(
          @executor.py_eq(List(result.rows.map(r => r[0])), py(expected)),
        )
      })
    }
  }
  for
    case in [
      ("postgres", "[1, 3, None, None]", "[None, None, 3, 1]"),
      ("mysql", "[None, None, 1, 3]", "[3, 1, None, None]"),
      ("duckdb", "[1, 3, None, None]", "[3, 1, None, None]"),
    ] {
    let (dialect, ascending, descending) = case
    for
      c in [
        ("SELECT a FROM t ORDER BY a", ascending),
        ("SELECT a FROM t ORDER BY a DESC", descending),
      ] {
      let (sql, expected) = c
      s.check("\{dialect}: \{sql}", () => {
        let result = @executor.execute(sql, schema~, tables~, dialect~)
        assert_true(
          @executor.py_eq(List(result.rows.map(r => r[0])), py(expected)),
        )
      })
    }
  }
  s.finish()
}

///|
test "aggregate_without_group_by" {
  let result = @executor.execute(
    "SELECT SUM(x) FROM t",
    tables=mk_tables(
      (
        #|{"t": [{"x": 1}, {"x": 2}]}
      ),
    ),
  )
  assert_columns(result, ["_col_0"])
  assert_rows(result, "[(3,)]")
}

///|
test "first" {
  let tables = mk_tables(
    (
      #|{"t": [{"g": 1, "a": 5}, {"g": 1, "a": 1}, {"g": 2, "a": 3}]}
    ),
  )
  assert_rows(
    @executor.execute("SELECT FIRST(a) FROM t", tables~, dialect="hive"),
    "[(5,)]",
  )
  assert_rows(
    @executor.execute(
      "SELECT g, FIRST(a) FROM t GROUP BY g",
      tables~,
      dialect="hive",
    ),
    "[(1, 5), (2, 3)]",
  )
}

///|
/// Runs `f` with the CURRENT_* functions pinned to `now` (Python `mock.patch.dict`).
fn with_now(now : @executor.PyDateTime, f : () -> Unit raise) -> Unit raise {
  let names = [
    "CURRENTDATETIME", "CURRENTTIMESTAMP", "CURRENTTIME", "CURRENTDATE",
  ]
  let saved = names.map(n => @executor.default_env[n])
  for n in names {
    @executor.default_env[n] = Func({
      name: n,
      call: _ => if n == "CURRENTDATE" { Date(now.date) } else { DateTime(now) },
    })
  }
  defer (for i, n in names {
    @executor.default_env[n] = saved[i]
  })
  f()
}

///|
test "scalar_functions" {
  let now : @executor.PyDateTime = {
    date: { year: 2020, month: 6, day: 15, },
    time: { hour: 12, minute: 0, second: 0, microsecond: 0, },
    tz: None,
  }
  let s = Suite::new("scalar_functions")
  with_now(now, () => {
    for
      case in [
        ("CONCAT('a', 'b')", "'ab'"),
        ("CONCAT('a', NULL)", "None"),
        ("CONCAT_WS('_', 'a', 'b')", "'a_b'"),
        ("STR_POSITION('foobarbar', 'bar')", "4"),
        ("STR_POSITION('foobarbar', 'bar', 5)", "7"),
        ("STR_POSITION('foobarbar', NULL)", "None"),
        ("STR_POSITION(NULL, 'bar')", "None"),
        ("UPPER('foo')", "'FOO'"),
        ("UPPER(NULL)", "None"),
        ("LOWER('FOO')", "'foo'"),
        ("LOWER(NULL)", "None"),
        ("IFNULL('a', 'b')", "'a'"),
        ("IFNULL(NULL, 'b')", "'b'"),
        ("IFNULL(NULL, NULL)", "None"),
        ("SUBSTRING('12345')", "'12345'"),
        ("SUBSTRING('12345', 3)", "'345'"),
        ("SUBSTRING('12345', 3, 0)", "''"),
        ("SUBSTRING('12345', 3, 1)", "'3'"),
        ("SUBSTRING('12345', 3, 2)", "'34'"),
        ("SUBSTRING('12345', 3, 3)", "'345'"),
        ("SUBSTRING('12345', 3, 4)", "'345'"),
        ("SUBSTRING('12345', -3)", "'345'"),
        ("SUBSTRING('12345', -3, 0)", "''"),
        ("SUBSTRING('12345', -3, 1)", "'3'"),
        ("SUBSTRING('12345', -3, 2)", "'34'"),
        ("SUBSTRING('12345', 0)", "''"),
        ("SUBSTRING('12345', 0, 1)", "''"),
        ("SUBSTRING(NULL)", "None"),
        ("SUBSTRING(NULL, 1)", "None"),
        ("CAST(1 AS TEXT)", "'1'"),
        ("CAST('1' AS LONG)", "1"),
        ("CAST('1.1' AS FLOAT)", "1.1"),
        ("CAST('12:05:01' AS TIME)", "time(12, 5, 1)"),
        ("COALESCE(NULL)", "None"),
        ("COALESCE(NULL, NULL)", "None"),
        ("COALESCE(NULL, 'b')", "'b'"),
        ("COALESCE('a', 'b')", "'a'"),
        ("1 << 1", "2"),
        ("1 >> 1", "0"),
        ("1 & 1", "1"),
        ("1 | 1", "1"),
        ("1 < 1", "False"),
        ("1 <= 1", "True"),
        ("1 > 1", "False"),
        ("1 >= 1", "True"),
        ("1 + NULL", "None"),
        ("IF(true, 1, 0)", "1"),
        ("IF(false, 1, 0)", "0"),
        ("CASE WHEN 0 = 1 THEN 'foo' ELSE 'bar' END", "'bar'"),
        ("CAST('2022-01-01' AS DATE) + INTERVAL '1' DAY", "date(2022, 1, 2)"),
        ("INTERVAL '1' week", "timedelta(7)"),
        ("1 IN (1, 2, 3)", "True"),
        ("1 IN (2, 3)", "False"),
        ("1 IN (1)", "True"),
        ("NULL IS NULL", "True"),
        ("NULL IS NOT NULL", "False"),
        ("NULL = NULL", "None"),
        ("NULL <> NULL", "None"),
        ("YEAR(CURRENT_TIMESTAMP)", "2020"),
        ("MONTH(CURRENT_TIME)", "6"),
        ("DAY(CURRENT_DATETIME())", "15"),
        ("YEAR(CURRENT_DATE())", "2020"),
        ("MONTH(CURRENT_DATE())", "6"),
        ("DAY(CURRENT_DATE())", "15"),
        ("YEAR(CURRENT_TIMESTAMP) + 1", "2021"),
        (
          "YEAR(CURRENT_TIMESTAMP) IN (YEAR(CURRENT_TIMESTAMP) + 1, YEAR(CURRENT_TIMESTAMP) * 10)",
          "False",
        ),
        ("YEAR(CURRENT_TIMESTAMP) = (YEAR(CURRENT_TIMESTAMP))", "True"),
        ("YEAR(CURRENT_TIMESTAMP) <> (YEAR(CURRENT_TIMESTAMP))", "False"),
        ("YEAR(CURRENT_DATE()) + 1", "2021"),
        (
          "YEAR(CURRENT_DATE()) IN (YEAR(CURRENT_DATE()) + 1, YEAR(CURRENT_DATE()) * 10)",
          "False",
        ),
        ("YEAR(CURRENT_DATE()) = (YEAR(CURRENT_DATE()))", "True"),
        ("YEAR(CURRENT_DATE()) <> (YEAR(CURRENT_DATE()))", "False"),
        ("1::bool", "True"),
        ("0::bool", "False"),
        ("MAP(['a'], [1]).a", "1"),
        ("MAP()", "{}"),
        ("STRFTIME('%j', '2023-03-23 15:00:00')", "'082'"),
        ("STRFTIME('%j', NULL)", "None"),
        ("DATESTRTODATE('2022-01-01')", "date(2022, 1, 1)"),
        ("TIMESTRTOTIME('2022-01-01')", "datetime(2022, 1, 1)"),
        ("LEFT('12345', 3)", "'123'"),
        ("RIGHT('12345', 3)", "'345'"),
        ("DATEDIFF('2022-01-03'::date, '2022-01-01'::TIMESTAMP::DATE)", "2"),
        ("TRIM(' foo ')", "'foo'"),
        ("TRIM('afoob', 'ab')", "'foo'"),
        ("REVERSE('foo')", "'oof'"),
        ("REVERSE(NULL)", "None"),
        ("ARRAY_JOIN(['foo', 'bar'], ':')", "'foo:bar'"),
        ("ARRAY_JOIN(['hello', null ,'world'], ' ', ',')", "'hello , world'"),
        ("ARRAY_JOIN(['', null ,'world'], ' ', ',')", "' , world'"),
        ("STRUCT('foo', 'bar', null, null)", "{'foo': 'bar'}"),
        ("ROUND(1.5)", "2"),
        ("ROUND(1.2)", "1"),
        ("ROUND(1.2345, 2)", "1.23"),
        ("ROUND(NULL)", "None"),
        ("POWER(2, 3)", "8"),
        ("POWER(NULL, 3)", "None"),
        ("POWER(2, NULL)", "None"),
        ("POWER(NULL, NULL)", "None"),
        ("UNIXTOTIME(1659981729)", "datetime(2022, 8, 8, 18, 2, 9, 'utc')"),
        (
          "TIMESTRTOTIME('2013-04-05 01:02:03')", "datetime(2013, 4, 5, 1, 2, 3)",
        ),
        (
          "UNIXTOTIME(40 * 365 * 86400)", "datetime(2009, 12, 22, 0, 0, 0, 'utc')",
        ),
        (
          "STRTOTIME('08/03/2024 12:34:56', '%d/%m/%Y %H:%M:%S')", "datetime(2024, 3, 8, 12, 34, 56)",
        ),
        ("STRTOTIME('27/01/2024', '%d/%m/%Y')", "datetime(2024, 1, 27)"),
      ] {
      let (sql, expected) = case
      s.check(sql, () => {
        assert_rows(@executor.execute("SELECT \{sql}"), "[(\{expected},)]")
      })
    }
  })
  s.check("NVL", () => {
    assert_rows(
      @executor.execute(
        "WITH t AS (SELECT 'a' AS c1, 'b' AS c2) SELECT NVL(c1, c2) FROM t",
        dialect="oracle",
      ),
      "[('a',)]",
    )
  })
  s.finish()
}

///|
test "sql_three_valued_boolean_logic" {
  let s = Suite::new("three_valued_logic")
  for
    case in [
      ("NOT TRUE", "False"),
      ("NOT FALSE", "True"),
      ("NOT NULL", "None"),
      ("TRUE AND NULL", "None"),
      ("FALSE AND NULL", "False"),
      ("TRUE OR NULL", "True"),
      ("FALSE OR NULL", "None"),
      ("NULL IN (1, 2)", "None"),
      ("3 NOT IN (1, 2, NULL)", "None"),
      ("3 NOT IN (1, 2)", "True"),
    ] {
    let (sql, expected) = case
    s.check(sql, () => {
      assert_rows(@executor.execute("SELECT \{sql}"), "[(\{expected},)]")
    })
  }
  s.check("NOT flag", () => {
    assert_rows(
      @executor.execute(
        "SELECT id FROM policy WHERE NOT flag",
        tables=mk_tables(
          (
            #|{"policy": [{"id": 1, "flag": True}, {"id": 2, "flag": False}, {"id": 3, "flag": None}]}
          ),
        ),
        schema=mk_schema(
          (
            #|{"policy": {"id": "INT", "flag": "BOOLEAN"}}
          ),
        ),
      ),
      "[(2,)]",
    )
  })
  // test_sql_boolean_logic_with_numpy_scalars (with plain bools)
  let tables = mk_tables(
    (
      #|{"policy": [
      #|  {"id": 1, "left_flag": True, "right_flag": True},
      #|  {"id": 2, "left_flag": False, "right_flag": True},
      #|  {"id": 3, "left_flag": None, "right_flag": True},
      #|]}
    ),
  )
  let schema = mk_schema(
    (
      #|{"policy": {"id": "INT", "left_flag": "BOOLEAN", "right_flag": "BOOLEAN"}}
    ),
  )
  for
    case in [
      ("SELECT id FROM policy WHERE left_flag", "[(1,)]"),
      ("SELECT id FROM policy WHERE left_flag AND right_flag", "[(1,)]"),
      (
        "SELECT id FROM policy WHERE left_flag OR right_flag", "[(1,), (2,), (3,)]",
      ),
    ] {
    let (sql, rows) = case
    s.check(sql, () => {
      assert_rows(@executor.execute(sql, tables~, schema~), rows)
    })
  }
  s.finish()
}

///|
test "sql_boolean_logic_preserves_short_circuiting" {
  let evaluations = []
  let executor = @executor.PythonExecutor::new(env={
    "RECORD_EVALUATION": Func({
      name: "RECORD_EVALUATION",
      call: _ => {
        evaluations.push(true)
        Bool(true)
      },
    }),
  })
  let context = executor.context([])
  for
    case in [
      ("FALSE AND RECORD_EVALUATION()", "False"),
      ("TRUE OR RECORD_EVALUATION()", "True"),
    ] {
    let (sql, expected) = case
    let code = executor.generate(Some(@sqlglot.parse_one(sql))).unwrap()
    assert_true(@executor.py_eq(context.eval(code), py(expected)))
  }
  assert_eq(evaluations, [])
}

///|
test "case_sensitivity" {
  let result = @executor.execute(
    "SELECT A AS A FROM X",
    tables=mk_tables(
      (
        #|{"x": [{"a": 1}]}
      ),
    ),
  )
  assert_columns(result, ["a"])
  assert_rows(result, "[(1,)]")
  let result = @executor.execute(
    "SELECT A AS \"A\" FROM X",
    tables=mk_tables(
      (
        #|{"x": [{"a": 1}]}
      ),
    ),
  )
  assert_columns(result, ["A"])
  assert_rows(result, "[(1,)]")
}

///|
test "nested_table_reference" {
  let result = @executor.execute(
    "SELECT * FROM some_catalog.some_schema.some_table s",
    tables=mk_tables(
      (
        #|{"some_catalog": {"some_schema": {"some_table": [
        #|  {"id": 1, "price": 1.0}, {"id": 2, "price": 2.0}, {"id": 3, "price": 3.0}
        #|]}}}
      ),
    ),
  )
  assert_columns(result, ["id", "price"])
  assert_rows(result, "[(1, 1.0), (2, 2.0), (3, 3.0)]")
}

///|
test "group_by" {
  let tables = mk_tables(
    (
      #|{"x": [{"a": 1, "b": 10}, {"a": 2, "b": 20}, {"a": 3, "b": 28}, {"a": 2, "b": 25}, {"a": 1, "b": 40}]}
    ),
  )
  let s = Suite::new("group_by")
  for
    case in [
      (
        "SELECT a, AVG(b) FROM x GROUP BY a ORDER BY AVG(b)",
        "[(2, 22.5), (1, 25.0), (3, 28.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, AVG(b) FROM x GROUP BY a having avg(b) > 23",
        "[(1, 25.0), (3, 28.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, AVG(b) FROM x GROUP BY a having avg(b + 1) > 23",
        "[(1, 25.0), (2, 22.5), (3, 28.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, AVG(b) FROM x GROUP BY a having sum(b) + 5 > 50",
        "[(1, 25.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a + 1 AS a, AVG(b + 1) FROM x GROUP BY a + 1 having AVG(b + 1) > 26",
        "[(4, 29.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, avg(b) FROM x GROUP BY a HAVING a = 1",
        "[(1, 25.0)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a + 1, avg(b) FROM x GROUP BY a + 1 HAVING a + 1 = 2",
        "[(2, 25.0)]",
        ["_col_0", "_col_1"],
      ),
      (
        "SELECT a FROM x GROUP BY a ORDER BY AVG(b)",
        "[(2,), (1,), (3,)]",
        ["a"],
      ),
      (
        "SELECT a, SUM(b) FROM x GROUP BY a ORDER BY COUNT(*)",
        "[(3, 28), (1, 50), (2, 45)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, SUM(b) FROM x GROUP BY a ORDER BY COUNT(*) DESC",
        "[(1, 50), (2, 45), (3, 28)]",
        ["a", "_col_1"],
      ),
      (
        "SELECT a, ARRAY_UNIQUE_AGG(b) FROM x GROUP BY a",
        "[(1, [40, 10]), (2, [25, 20]), (3, [28])]",
        ["a", "_col_1"],
      ),
    ] {
    let (sql, expected, columns) = case
    s.check(sql, () => {
      let result = @executor.execute(sql, tables~)
      assert_columns(result, columns)
      assert_rows(result, expected)
    })
  }
  s.finish()
}

///|
test "nested_values" {
  let tables = mk_tables(
    (
      #|{"foo": [{"raw": {"name": "Hello, World", "a": [{"b": 1}]}}]}
    ),
  )
  let s = Suite::new("nested_values")
  for
    case in [
      ("SELECT raw:name AS name FROM foo", "NAME", "[('Hello, World',)]"),
      ("SELECT raw:a[0].b AS b FROM foo", "B", "[(1,)]"),
      ("SELECT raw:a[1].b AS b FROM foo", "B", "[(None,)]"),
      ("SELECT raw:a[0].c AS c FROM foo", "C", "[(None,)]"),
    ] {
    let (sql, column, rows) = case
    s.check(sql, () => {
      let result = @executor.execute(sql, dialect="snowflake", tables~)
      assert_columns(result, [column])
      assert_rows(result, rows)
    })
  }
  s.check("bigquery struct", () => {
    let result = @executor.execute(
      "SELECT i.attributes.flavor FROM `ITEM` i",
      dialect="bigquery",
      tables=mk_tables(
        (
          #|{"\"ITEM\"": [
          #|  {"id": 1, "attributes": {"flavor": "cherry", "taste": "sweet"}},
          #|  {"id": 2, "attributes": {"flavor": "lime", "taste": "sour"}},
          #|  {"id": 3, "attributes": {"flavor": "apple", "taste": None}},
          #|]}
        ),
      ),
    )
    assert_columns(result, ["flavor"])
    assert_rows(result, "[('cherry',), ('lime',), ('apple',)]")
  })
  s.check("duckdb list", () => {
    let result = @executor.execute(
      "SELECT x FROM t",
      dialect="duckdb",
      tables=mk_tables(
        (
          #|{"t": [{"x": [1, 2, 3]}]}
        ),
      ),
    )
    assert_columns(result, ["x"])
    assert_rows(result, "[([1, 2, 3],)]")
  })
  s.finish()
}

///|
test "agg_order" {
  let plan = @planner.Plan::new(
    @optimizer.optimize(
      @sqlglot.parse_one(
        "SELECT AVG(bill_length_mm) AS avg_bill_length, AVG(bill_depth_mm) AS avg_bill_depth FROM penguins",
      ),
    ),
  )
  assert_eq(plan.root.aggregations.map(agg => agg.alias_()), [
    "avg_bill_length", "avg_bill_depth",
  ])
}

///|
test "table_to_pylist" {
  let table = @executor.Table::new(columns=["id", "product", "price"], rows=[
    [Int(1L), Str("Shirt"), Float(20.0)],
    [Int(2L), Str("Shoes"), Float(60.0)],
  ])
  let records = table
    .to_pylist()
    .map(r => r.map(kv => "\{kv.0}=\{kv.1.repr()}").join(", "))
  assert_eq(records, [
    "id=1, product='Shirt', price=20.0", "id=2, product='Shoes', price=60.0",
  ])
}

///|
test "count_distinct" {
  let rows = mk_tables(
    (
      #|{"t": [{"a": "x", "v": 1}, {"a": "x", "v": 1}, {"a": "x", "v": 2}, {"a": "y", "v": None}]}
    ),
  )
  let schema = mk_schema(
    (
      #|{"t": {"a": "VARCHAR", "v": "INT"}}
    ),
  )
  let s = Suite::new("count_distinct")
  for
    case in [
      ("SELECT COUNT(DISTINCT v) AS c FROM t", "[(2,)]"),
      ("SELECT COUNT(v) AS c FROM t", "[(3,)]"),
      ("SELECT COUNT(*) AS c FROM t", "[(4,)]"),
      ("SELECT SUM(DISTINCT v) AS c FROM t", "[(3,)]"),
      (
        "SELECT a, COUNT(DISTINCT v) AS c FROM t GROUP BY a", "[('x', 2), ('y', 0)]",
      ),
    ] {
    let (sql, expected) = case
    s.check(sql, () => {
      assert_rows_unordered(
        @executor.execute(sql, schema~, tables=rows),
        expected,
      )
    })
  }
  s.check("multiple columns", () => {
    assert_rows(
      @executor.execute(
        "SELECT COUNT(DISTINCT a, b) AS c FROM t",
        schema=mk_schema(
          (
            #|{"t": {"a": "VARCHAR", "b": "INT"}}
          ),
        ),
        tables=mk_tables(
          (
            #|{"t": [{"a": "x", "b": 1}, {"a": "x", "b": 1}, {"a": "x", "b": 2}, {"a": None, "b": 1}, {"a": "y", "b": None}]}
          ),
        ),
      ),
      "[(2,)]",
    )
  })
  s.finish()
}
