// Ports of the inline asserts of test_simplify / test_simplify_nested / test_gen in
// tests/test_optimizer.py.

///|
/// The `simplify` helper of tests/test_optimizer.py: annotate types, then simplify with
/// constant propagation and coalesce simplification.
fn simplify_with_types(
  e : @core.Expr,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_of(dialect)
  let e = @optimizer.annotate_types(e, dialect?=d)
  @optimizer.simplify(
    e,
    constant_propagation=true,
    coalesce_simplification=true,
    dialect?=d,
  )
}

///|
test "simplify: huge union" {
  let union_sql = "SELECT 1 UNION ALL ".repeat(1000) + "SELECT 1"
  let expression = parse_sql(union_sql)
  assert_eq(gen_sql(@optimizer.simplify(expression)), union_sql)
}

///|
test "simplify: mutates the AST in place" {
  let expression = parse_sql("SELECT 1 + 2")
  simplify_with_types(expression.selects()[0]) |> ignore
  assert_eq(gen_sql(expression), "SELECT 3")
  let expression = parse_sql("SELECT a, c, b FROM table1 WHERE 1 = 1")
  assert_eq(
    gen_sql(
      simplify_with_types(simplify_with_types(expression.find([Where]).unwrap())),
    ),
    "WHERE TRUE",
  )
  let expression = parse_sql("TRUE AND TRUE AND TRUE")
  assert_true(@core.true_().equal(@optimizer.simplify(expression)))
}

///|
test "simplify: concat keeps its safe flag" {
  let concat = parse_sql("CONCAT('a', x, 'b', 'c')", read="presto")
  let simplified_concat = @optimizer.simplify(concat)
  let safe_concat = parse_sql("CONCAT('a', x, 'b', 'c')")
  let simplified_safe_concat = @optimizer.simplify(safe_concat)
  assert_false(simplified_concat.bool_arg("safe"))
  assert_true(simplified_safe_concat.bool_arg("safe"))
  assert_eq(
    gen_sql(simplified_concat, dialect="presto"),
    "CONCAT('a', x, 'bc')",
  )
  assert_eq(gen_sql(simplified_safe_concat), "CONCAT('a', x, 'bc')")

  // Both Databricks' and DuckDB's CONCAT_WS skip NULL args, so no CASE wrapping is needed
  let concat_ws = parse_sql("CONCAT_WS(' ', a, NULL, 'b', 'c')", read="databricks")
  let simplified_concat_ws = @optimizer.simplify(concat_ws)
  assert_true(simplified_concat_ws.bool_arg("coalesce"))
  assert_eq(
    gen_sql(simplified_concat_ws, dialect="duckdb"),
    "CONCAT_WS(' ', a, NULL, 'b c')",
  )

  // DuckDB's || coerces its args to strings, so the "safe" flag must survive simplification
  let dpipe = parse_sql("x || 'a' || 'b'", read="duckdb")
  let simplified_dpipe = @optimizer.simplify(dpipe)
  assert_true(simplified_dpipe.bool_arg("safe"))
  assert_eq(gen_sql(simplified_dpipe, dialect="duckdb"), "x || 'ab'")
  assert_eq(
    gen_sql(simplified_dpipe, dialect="presto"),
    "CONCAT(CAST(x AS VARCHAR), CAST('ab' AS VARCHAR))",
  )
}

///|
test "simplify: gen" {
  assert_eq(@optimizer.gen(parse_sql("anonymous(x, y)")), "ANONYMOUS(x,y)")
  let query = parse_sql("SELECT x FROM t")
  assert_eq(@optimizer.gen(query), @optimizer.gen(query.copy()))
  let anon_unquoted_identifier = @core.mk(Anonymous, [
    ("this", @core.to_identifier("anonymous")),
    (
      "expressions",
      @core.Value::List([
        Node(@core.column_of("x")),
        Node(@core.column_of("y")),
      ]),
    ),
  ])
  assert_eq(@optimizer.gen(anon_unquoted_identifier), "ANONYMOUS(x,y)")
  assert_eq(
    @optimizer.gen(parse_sql("\"anonymous\"(x, y)")),
    "\"anonymous\"(x,y)",
  )

  // Literal and identifier content must be escaped so it can't forge structure
  assert_not_eq(
    @optimizer.gen(parse_sql("v IN ('x'',''y')")),
    @optimizer.gen(parse_sql("v IN ('x', 'y')")),
  )
  assert_eq(@optimizer.gen(parse_sql("'''a'''")), "'''a'''")
  assert_eq(@optimizer.gen(parse_sql("\"a\"\"b\"")), "\"a\"\"b\"")
  assert_eq(@optimizer.gen(parse_sql("\"an\"\"on\"(x)")), "\"an\"\"on\"(x)")
  let raw_in = parse_sql("v IN (r'a', r'b')", read="spark")
  let forged = parse_sql("v IN (r'x')", read="spark")
  forged.find([RawString]).unwrap().set("this", "a,RAWSTRING :this,b")
  assert_not_eq(@optimizer.gen(raw_in), @optimizer.gen(forged))
  // SKIPPED: `gen(exp.Anonymous(this=5))` raising a ValueError is a Python type check.
}

///|
test "simplify: gen of a complex query" {
  let sql = parse_sql(
    (
      #|WITH cte AS (select 1 union select 2), cte2 AS (
      #|    SELECT ROW() OVER (PARTITION BY y) FROM (
      #|        (select 1) limit 10
      #|    )
      #|)
      #|SELECT
      #|  *,
      #|  a + 1,
      #|  a div 1,
      #|  filter("B", (x, y) -> x + y)
      #|  FROM (z AS z CROSS JOIN z) AS f(a) LEFT JOIN a.b.c.d.e.f.g USING(n) ORDER BY 1
    ),
  )
  assert_eq(
    @optimizer.gen(sql),
    "SELECT :with_,WITH :expressions,CTE :this,UNION :this,SELECT :expressions,1,:expression,SELECT :expressions,2,:distinct,True,:alias, AS cte,CTE :this,SELECT :expressions,WINDOW :this,ROW(),:partition_by,y,:over,'OVER',:from_,FROM ((SELECT :expressions,1):limit,LIMIT :expression,10),:alias, AS cte2,:expressions,STAR,a + 1,a DIV 1,FILTER(\"B\",LAMBDA :this,x + y,:expressions,x,y),:from_,FROM (z AS z:joins,JOIN :this,z,:kind,'CROSS') AS f(a),:joins,JOIN :this,a.b.c.d.e.f.g,:side,'LEFT',:using,n,:order,ORDER :expressions,ORDERED :this,1,:nulls_first,True",
  )
  assert_eq(
    @optimizer.gen(parse_sql("select item_id /* description */"), comments=true),
    "SELECT :expressions,item_id /* description */",
  )
}

///|
test "simplify: nested" {
  let sql = "SELECT x, 1 + 1 FROM foo WHERE x > (((select x + 1 + 1, sum(y + 1 + 1) FROM bar GROUP BY x + 1 + 1)))"
  assert_eq(
    gen_sql(@optimizer.simplify(parse_sql(sql)), pretty=true),
    gen_sql(
      parse_sql(
        "SELECT x, 2 FROM foo WHERE x > (((select x + 1 + 1, sum(y + 2) FROM bar GROUP BY x + 1 + 1)))",
      ),
      pretty=true,
    ),
  )
}

///|
test "simplify: gen of every function" {
  let mut n = 0
  for kind in @core.all_kinds {
    if kind.is_a(Func) {
      @optimizer.gen(@core.mk0(kind)) |> ignore
      n += 1
    }
  }
  assert_true(n > 0)
}
