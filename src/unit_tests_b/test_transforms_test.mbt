// Port of tests/test_transforms.py

///|
fn validate_transform_expr(
  transform : (@core.Expr) -> @core.Expr raise @core.SqlglotError,
  expression : @core.Expr,
  target : String,
  dialect? : String = "",
) -> Unit raise {
  let transformed = expression.transform(node => Some(transform(node)))
  assert_eq(@sqlglot.generate(transformed, dialect~), target)
}

///|
fn validate_transform(
  transform : (@core.Expr) -> @core.Expr raise @core.SqlglotError,
  sql : String,
  target : String,
  dialect? : String = "",
) -> Unit raise {
  validate_transform_expr(
    transform,
    @sqlglot.parse_one(sql, read=dialect),
    target,
    dialect~,
  )
}

///|
test "TestTransforms.test_eliminate_distinct_on" {
  let t = @core.eliminate_distinct_on
  validate_transform(
    t, "SELECT DISTINCT ON (a) a, b FROM x ORDER BY c DESC", "SELECT a, b FROM (SELECT a AS a, b AS b, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) a, b FROM x", "SELECT a, b FROM (SELECT a AS a, b AS b, ROW_NUMBER() OVER (PARTITION BY a ORDER BY a) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a, b) a, b FROM x ORDER BY c DESC", "SELECT a, b FROM (SELECT a AS a, b AS b, ROW_NUMBER() OVER (PARTITION BY a, b ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT a, b FROM x ORDER BY c DESC", "SELECT DISTINCT a, b FROM x ORDER BY c DESC",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (_row_number) _row_number FROM x ORDER BY c DESC", "SELECT _row_number FROM (SELECT _row_number AS _row_number, ROW_NUMBER() OVER (PARTITION BY _row_number ORDER BY c DESC) AS _row_number_2 FROM x) AS _t WHERE _row_number_2 = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (x.a, x.b) x.a, x.b FROM x ORDER BY c DESC", "SELECT a, b FROM (SELECT x.a AS a, x.b AS b, ROW_NUMBER() OVER (PARTITION BY x.a, x.b ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) x.a, y.a FROM x CROSS JOIN y ORDER BY c DESC", "SELECT a, a_2 FROM (SELECT x.a AS a, y.a AS a_2, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x CROSS JOIN y) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) a, a + b FROM x ORDER BY c DESC", "SELECT a, _col FROM (SELECT a AS a, a + b AS _col, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) * FROM x ORDER BY c DESC", "SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) a AS \"A\", b FROM x ORDER BY c DESC", "SELECT \"A\", b FROM (SELECT a AS \"A\", b AS b, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
  validate_transform(
    t, "SELECT DISTINCT ON (a) \"A\", b FROM x ORDER BY c DESC", "SELECT \"A\", b FROM (SELECT \"A\" AS \"A\", b AS b, ROW_NUMBER() OVER (PARTITION BY a ORDER BY c DESC) AS _row_number FROM x) AS _t WHERE _row_number = 1",
  )
}

///|
test "TestTransforms.test_eliminate_qualify" {
  let t = @core.eliminate_qualify
  validate_transform(
    t, "SELECT i, a + 1 FROM qt QUALIFY ROW_NUMBER() OVER (PARTITION BY p) = 1",
    "SELECT i, _c FROM (SELECT i, a + 1 AS _c, ROW_NUMBER() OVER (PARTITION BY p) AS _w FROM qt) AS _t WHERE _w = 1",
  )
  validate_transform(
    t, "SELECT i FROM qt QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) = 1 AND p = 0",
    "SELECT i FROM (SELECT i, ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) AS _w, p FROM qt) AS _t WHERE _w = 1 AND p = 0",
  )
  validate_transform(
    t, "SELECT i, p, o FROM qt QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) = 1",
    "SELECT i, p, o FROM (SELECT i, p, o, ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) AS _w FROM qt) AS _t WHERE _w = 1",
  )
  validate_transform(
    t, "SELECT i, p, o, ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) AS row_num FROM qt QUALIFY row_num = 1",
    "SELECT i, p, o, row_num FROM (SELECT i, p, o, ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) AS row_num FROM qt) AS _t WHERE row_num = 1",
  )
  validate_transform(
    t, "SELECT * FROM qt QUALIFY ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) = 1",
    "SELECT * FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY p ORDER BY o) AS _w FROM qt) AS _t WHERE _w = 1",
  )
  validate_transform(
    t, "SELECT c2, SUM(c3) OVER (PARTITION BY c2) AS r FROM t1 WHERE c3 < 4 GROUP BY c2, c3 HAVING SUM(c1) > 3 QUALIFY r IN (SELECT MIN(c1) FROM test GROUP BY c2 HAVING MIN(c1) > 3)",
    "SELECT c2, r FROM (SELECT c2, SUM(c3) OVER (PARTITION BY c2) AS r, c1 FROM t1 WHERE c3 < 4 GROUP BY c2, c3 HAVING SUM(c1) > 3) AS _t WHERE r IN (SELECT MIN(c1) FROM test GROUP BY c2 HAVING MIN(c1) > 3)",
  )
  validate_transform(
    t, "SELECT x FROM y QUALIFY ROW_NUMBER() OVER (PARTITION BY p)", "SELECT x FROM (SELECT x, ROW_NUMBER() OVER (PARTITION BY p) AS _w FROM y) AS _t WHERE _w",
  )
  validate_transform(
    t, "SELECT x AS z FROM y QUALIFY ROW_NUMBER() OVER (PARTITION BY z)", "SELECT z FROM (SELECT x AS z, ROW_NUMBER() OVER (PARTITION BY x) AS _w FROM y) AS _t WHERE _w",
  )
  validate_transform(
    t, "SELECT SOME_UDF(x) AS z FROM y QUALIFY ROW_NUMBER() OVER (PARTITION BY x ORDER BY z)",
    "SELECT z FROM (SELECT SOME_UDF(x) AS z, ROW_NUMBER() OVER (PARTITION BY x ORDER BY SOME_UDF(x)) AS _w FROM y) AS _t WHERE _w",
  )
  validate_transform(
    t, "SELECT x, t, x || t AS z FROM y QUALIFY ROW_NUMBER() OVER (PARTITION BY x ORDER BY z DESC)",
    "SELECT x, t, z FROM (SELECT x, t, x || t AS z, ROW_NUMBER() OVER (PARTITION BY x ORDER BY x || t DESC) AS _w FROM y) AS _t WHERE _w",
  )
  validate_transform(
    t, "SELECT y.x AS x, y.t AS z FROM y QUALIFY ROW_NUMBER() OVER (PARTITION BY x ORDER BY x DESC, z)",
    "SELECT x, z FROM (SELECT y.x AS x, y.t AS z, ROW_NUMBER() OVER (PARTITION BY y.x ORDER BY y.x DESC, y.t) AS _w FROM y) AS _t WHERE _w",
  )
  validate_transform(
    t, "select max(col) over (partition by col_id) as col, from some_table qualify row_number() over (partition by col_id order by col asc)=1",
    "SELECT col FROM (SELECT MAX(col) OVER (PARTITION BY col_id) AS col, ROW_NUMBER() OVER (PARTITION BY col_id ORDER BY MAX(col) OVER (PARTITION BY col_id) ASC) AS _w FROM some_table) AS _t WHERE _w = 1",
  )
  // A column that is only read by a window function must not be projected in the
  // subquery, otherwise a grouped query selects a non-grouped column
  validate_transform(
    t, "SELECT d, c, SUM(s) AS t FROM x GROUP BY d, c QUALIFY RANK() OVER (PARTITION BY d ORDER BY SUM(s) DESC) <= 3",
    "SELECT d, c, t FROM (SELECT d, c, SUM(s) AS t, RANK() OVER (PARTITION BY d ORDER BY SUM(s) DESC) AS _w FROM x GROUP BY d, c) AS _t WHERE _w <= 3",
  )
  // Ditto when the window contains a subquery, whose columns may not be in scope
  validate_transform(
    t, "SELECT x.c, SUM(x.s) AS t FROM x GROUP BY x.c QUALIFY RANK() OVER (ORDER BY (SELECT SUM(y.s) FROM y WHERE y.c = x.c) DESC) <= 3",
    "SELECT c, t FROM (SELECT x.c, SUM(x.s) AS t, RANK() OVER (ORDER BY (SELECT SUM(y.s) FROM y WHERE y.c = x.c) DESC) AS _w FROM x GROUP BY x.c) AS _t WHERE _w <= 3",
  )
  // Columns that the outer filter reads are still projected
  validate_transform(
    t, "SELECT a, b FROM t QUALIFY ROW_NUMBER() OVER (PARTITION BY d ORDER BY e) = 1 AND f > 0",
    "SELECT a, b FROM (SELECT a, b, ROW_NUMBER() OVER (PARTITION BY d ORDER BY e) AS _w, f FROM t) AS _t WHERE _w = 1 AND f > 0",
  )
}

///|
test "TestTransforms.test_remove_precision_parameterized_types" {
  validate_transform(
    @core.remove_precision_parameterized_types, "SELECT CAST(1 AS DECIMAL(10, 2)), CAST('13' AS VARCHAR(10))",
    "SELECT CAST(1 AS DECIMAL), CAST('13' AS VARCHAR)",
  )
}

///|
test "TestTransforms.test_remove_unique_constraints" {
  for
    case in [
      ("CREATE TABLE t (a INT UNIQUE)", "CREATE TABLE t (a INT)"),
      (
        "CREATE TABLE t (a INT, CONSTRAINT c UNIQUE (a))", "CREATE TABLE t (a INT)",
      ),
      (
        "CREATE TABLE t (a INT, b INT, UNIQUE (a))", "CREATE TABLE t (a INT, b INT)",
      ),
      (
        "CREATE TABLE t (a INT, b INT, UNIQUE (a), UNIQUE (b))", "CREATE TABLE t (a INT, b INT)",
      ),
      (
        "CREATE TABLE t (a INT, UNIQUE (a), PRIMARY KEY (a), FOREIGN KEY (a) REFERENCES u (b))",
        "CREATE TABLE t (a INT, PRIMARY KEY (a), FOREIGN KEY (a) REFERENCES u (b))",
      ),
    ] {
    let (sql, target) = case
    assert_eq(
      @sqlglot.generate(
        @core.remove_unique_constraints(@sqlglot.parse_one(sql)),
      ),
      target,
    )
  }
  assert_eq(
    @sqlglot.generate(
      @core.remove_unique_constraints(
        @sqlglot.parse_one(
          "CREATE TABLE t (a INT, b INT, UNIQUE KEY (a), UNIQUE INDEX idx (b))",
          read="mysql",
        ),
      ),
      dialect="mysql",
    ),
    "CREATE TABLE t (a INT, b INT)",
  )
}

// SKIP: TestTransforms.test_eliminate_join_marks (38 assertions over oracle/redshift):
// `transforms.eliminate_join_marks` needs the optimizer (scope.traverse_scope,
// normalize.normalize) which is not ported yet.

///|
test "TestTransforms.test_eliminate_semi_and_anti_joins" {
  let t = @core.eliminate_semi_and_anti_joins
  validate_transform(
    t, "SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.id ANTI JOIN t3 ON t1.id = t3.id",
    "SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.id WHERE NOT EXISTS(SELECT 1 FROM t3 WHERE t1.id = t3.id)",
  )
  validate_transform(
    t, "SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.id SEMI JOIN t3 ON t1.id = t3.id",
    "SELECT t1.id FROM t1 JOIN t2 ON t1.id = t2.id WHERE EXISTS(SELECT 1 FROM t3 WHERE t1.id = t3.id)",
  )
  validate_transform(
    t, "SELECT t1.id FROM t1 ANTI JOIN t2 ON t1.id = t2.id ANTI JOIN t3 ON t1.id = t3.id",
    "SELECT t1.id FROM t1 WHERE NOT EXISTS(SELECT 1 FROM t2 WHERE t1.id = t2.id) AND NOT EXISTS(SELECT 1 FROM t3 WHERE t1.id = t3.id)",
  )
  validate_transform(
    t, "SELECT t1.id FROM t1 ANTI JOIN t2 ON t1.id = t2.id ANTI JOIN t3 ON t1.id = t3.id ANTI JOIN t4 ON t1.id = t4.id",
    "SELECT t1.id FROM t1 WHERE (NOT EXISTS(SELECT 1 FROM t2 WHERE t1.id = t2.id) AND NOT EXISTS(SELECT 1 FROM t3 WHERE t1.id = t3.id)) AND NOT EXISTS(SELECT 1 FROM t4 WHERE t1.id = t4.id)",
  )
  validate_transform(
    t, "SELECT t1.id FROM t1 SEMI JOIN t2 ON t1.id = t2.id SEMI JOIN t3 ON t1.id = t3.id",
    "SELECT t1.id FROM t1 WHERE EXISTS(SELECT 1 FROM t2 WHERE t1.id = t2.id) AND EXISTS(SELECT 1 FROM t3 WHERE t1.id = t3.id)",
  )
}

///|
test "TestTransforms.test_eliminate_window_clause" {
  let t = @core.eliminate_window_clause
  validate_transform(
    t, "SELECT purchases, LAST_VALUE(item) OVER (d) AS most_popular FROM Produce WINDOW a AS (PARTITION BY purchases), b AS (a ORDER BY purchases), c AS (b ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING), d AS (c)",
    "SELECT purchases, LAST_VALUE(item) OVER (PARTITION BY purchases ORDER BY purchases ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS most_popular FROM Produce",
  )
  validate_transform(
    t, "SELECT LAST_VALUE(c) OVER (a) AS c2 FROM (SELECT LAST_VALUE(i) OVER (a) AS c FROM p WINDOW a AS (PARTITION BY x)) AS q(c) WINDOW a AS (PARTITION BY y)",
    "SELECT LAST_VALUE(c) OVER (PARTITION BY y) AS c2 FROM (SELECT LAST_VALUE(i) OVER (PARTITION BY x) AS c FROM p) AS q(c)",
  )
}

///|
fn parse_and_set_struct_name_inheritance(sql : String) -> @core.Expr raise {
  let ast = @sqlglot.parse_one(sql)
  for array in ast.find_all([@core.Kind::Array]) {
    array.set("struct_name_inheritance", true)
  }
  ast
}

///|
test "TestTransforms.test_inherit_struct_field_names" {
  let t = @core.inherit_struct_field_names
  // Basic case: field names inherited from first struct
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob', 92), STRUCT('Diana', 95))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob' AS name, 92 AS score), STRUCT('Diana' AS name, 95 AS score))",
  )
  // Single struct in array: no inheritance needed
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score))",
  )
  // Empty array: no change
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance("SELECT ARRAY()"),
    "SELECT ARRAY()",
  )
  // First struct has no field names: no inheritance
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice', 85), STRUCT('Bob', 92))",
    ),
    "SELECT ARRAY(STRUCT('Alice', 85), STRUCT('Bob', 92))",
  )
  // Mismatched field counts: skip inheritance
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob'))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob'))",
  )
  // Struct already has field names: don't override
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob' AS fullname, 92 AS points))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob' AS fullname, 92 AS points))",
  )
  // Mixed: some structs inherit, some already have names
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob', 92), STRUCT('Carol' AS name, 88 AS score), STRUCT('Diana', 95))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob' AS name, 92 AS score), STRUCT('Carol' AS name, 88 AS score), STRUCT('Diana' AS name, 95 AS score))",
  )
  // Non-struct elements: no change
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance("SELECT ARRAY(1, 2, 3)"),
    "SELECT ARRAY(1, 2, 3)",
  )
  // Multiple arrays: each processed independently
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob', 92)), ARRAY(STRUCT('X' AS col), STRUCT('Y'))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85 AS score), STRUCT('Bob' AS name, 92 AS score)), ARRAY(STRUCT('X' AS col), STRUCT('Y' AS col))",
  )
  // Partial field names in first struct: inherit only the named ones
  validate_transform_expr(
    t,
    parse_and_set_struct_name_inheritance(
      "SELECT ARRAY(STRUCT('Alice' AS name, 85), STRUCT('Bob', 92))",
    ),
    "SELECT ARRAY(STRUCT('Alice' AS name, 85), STRUCT('Bob', 92))",
  )
}
