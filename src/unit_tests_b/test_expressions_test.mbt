// Port of tests/test_expressions.py

///|
fn sql(
  e : @core.Expr,
  dialect? : String = "",
) -> String raise @core.SqlglotError {
  @sqlglot.generate(e, dialect~)
}

///|
/// Python `expression.sql(dialect=..., **opts)` with generator options.
fn gen(
  e : @core.Expr,
  dialect? : String = "",
  pretty? : Bool = false,
  identify? : Bool = false,
  normalize? : Bool = false,
  normalize_functions? : String,
  comments? : Bool = true,
) -> String raise @core.SqlglotError {
  @core.Generator::new(
    @sqlglot.dialect(dialect),
    pretty~,
    identify=if identify { "always" } else { "" },
    normalize~,
    normalize_functions?,
    comments~,
  ).generate(e)
}

///|
fn p1(s : String, read? : String = "") -> @core.Expr raise @core.SqlglotError {
  @sqlglot.parse_one(s, read~)
}

///|
fn ident(name : String, quoted? : Bool) -> @core.Expr {
  @core.to_identifier(name, quoted?)
}

///|
test "TestExprs.test_to_s" {
  assert_eq(p1("5").to_s(), "Literal(this=5, is_string=False)")
  assert_eq(p1("5.3").to_s(), "Literal(this=5.3, is_string=False)")
  assert_eq(p1("True").to_s(), "Boolean(this=True)")
  assert_eq(p1("'  x'").to_s(), "Literal(this='  x', is_string=True)")
  assert_eq(p1("' \n  x'").to_s(), "Literal(this=' \\n  x', is_string=True)")
  assert_eq(
    p1("   x ").to_s(),
    "Column(\n  this=Identifier(this=x, quoted=False))",
  )
  assert_eq(
    p1("\"   x \"").to_s(),
    "Column(\n  this=Identifier(this='   x ', quoted=True))",
  )
}

///|
test "TestExprs.test_arg_key" {
  assert_eq(p1("sum(1)").find([Literal]).unwrap().arg_key, Some("this"))
}

///|
test "TestExprs.test_depth" {
  assert_eq(p1("x(1)").find([Literal]).unwrap().depth(), 1)
}

///|
test "TestExprs.test_iter" {
  assert_true(
    [@core.literal_number("1"), @core.literal_number("2")] ==
    p1("[1, 2]").expressions(),
  )
  // SKIP: iterating a non-iterable expression raises TypeError (Python `__iter__` protocol)
}

///|
test "TestExprs.test_eq" {
  let query = p1("SELECT x FROM t")
  assert_true(query == query.copy())
  assert_true(ident("a") != ident("A"))
  assert_true(
    @core.mk(Column, [("table", ident("b")), ("this", ident("b"))]) ==
    @core.mk(Column, [("this", ident("b")), ("table", ident("b"))]),
  )
  assert_true(ident("a", quoted=true) != ident("A"))
  assert_true(ident("A", quoted=true) != ident("A"))
  assert_true(ident("A", quoted=true) != ident("a", quoted=true))
  assert_true(p1("'x'") != p1("'X'"))
  assert_true(p1("'1'") != p1("1"))
  assert_true(p1("`a`", read="hive") == p1("\"a\""))
  assert_true(p1("`a`", read="hive") == p1("\"a\"  "))
  assert_true(p1("`a`.`b`", read="hive") == p1("\"a\".\"b\""))
  assert_true(p1("select a, b+1") == p1("SELECT a, b + 1"))
  assert_true(p1("`a`.`b`.`c`", read="hive") != p1("a.b.c"))
  assert_true(p1("a.b.c.d", read="hive") != p1("a.b.c"))
  assert_true(p1("a.b.c.d", read="hive") == p1("a.b.c.d"))
  assert_true(p1("a + b * c - 1.0") == p1("a+b*c-1.0"))
  assert_true(p1("a + b * c - 1.0") != p1("a + b * c + 1.0"))
  assert_true(p1("a as b") == p1("a AS b"))
  assert_true(p1("a as b") != p1("a"))
  assert_true(
    p1("ROW() OVER(Partition by y)") == p1("ROW() OVER (partition BY y)"),
  )
  assert_true(
    @core.mk(Table, [("pivots", ([] : Array[@core.Expr]))]) == @core.mk0(Table),
  )
  // SKIP: `exp.Table(pivots=[None]) != exp.Table()`: argument lists can't hold `None` in the port
  assert_true(
    @sqlglot.datatype_build("int") ==
    @core.mk(DataType, [("this", @core.DType::INT), ("nested", false)]),
  )
  assert_true(
    @core.mk(Identifier, [("this", "a"), ("temporary", true)]) !=
    @core.mk(Identifier, [("this", "a")]),
  )
}

// SKIP: TestExprs.test_eq_on_same_instance_short_circuits (1 assertion): checks Python's
// private `_hash` cache attribute.

///|
test "TestExprs.test_find" {
  let expression = p1("CREATE TABLE x STORED AS PARQUET AS SELECT * FROM y")
  assert_true(expression.find([Create]) is Some(_))
  assert_true(expression.find([Group]) is None)
  assert_eq(expression.find_all([Table]).map(t => t.name()).collect(), [
    "x", "y",
  ])
}

///|
test "TestExprs.test_find_all" {
  let expression = p1(
    (
      #|
      #|            SELECT *
      #|            FROM (
      #|                SELECT b.*
      #|                FROM a.b b
      #|            ) x
      #|            JOIN (
      #|              SELECT c.foo
      #|              FROM a.c c
      #|              WHERE foo = 1
      #|            ) y
      #|              ON x.c = y.foo
      #|            CROSS JOIN (
      #|              SELECT *
      #|              FROM (
      #|                SELECT d.bar
      #|                FROM d
      #|              ) nested
      #|            ) z
      #|              ON x.c = y.foo
      #|
    ),
  )
  assert_eq(expression.find_all([Table]).map(t => t.name()).collect(), [
    "b", "c", "d",
  ])
  let expression = p1("select a + b + c + d")
  assert_eq(expression.find_all([Column]).map(c => c.name()).collect(), [
    "d", "c", "a", "b",
  ])
  assert_eq(
    expression.find_all([Column], bfs=false).map(c => c.name()).collect(),
    ["a", "b", "c", "d"],
  )
}

///|
test "TestExprs.test_find_ancestor" {
  let column = p1("select * from foo where (a + 1 > 2)").find([Column]).unwrap()
  assert_true(column.kind.is_a(Column))
  assert_true(column.parent_select().unwrap().kind.is_a(Select))
  assert_true(column.find_ancestor([Join]) is None)
}

///|
test "TestExprs.test_to_dot" {
  let orig = p1("a.b.c.\"d\".e.f")
  let parts_sql = fn(parts : Array[@core.Expr]) raise {
    parts.map(p => sql(p)).join(".")
  }
  assert_eq(parts_sql(orig.parts()), "a.b.c.\"d\".e.f")
  assert_eq(
    parts_sql(
      @core.dot_build([
        @sqlglot.to_table("a.b.c"),
        ident("d"),
        ident("e"),
        ident("f"),
      ]).parts(),
    ),
    "a.b.c.d.e.f",
  )
  assert_eq(parts_sql(orig.parts()), "a.b.c.\"d\".e.f")
  let column = orig.find([Column]).unwrap()
  let dot = column.to_dot()
  assert_eq(sql(dot), "a.b.c.\"d\".e.f")
  let mk_dot = fn(this : @core.Expr, expression : @core.Expr) {
    @core.mk(Dot, [("this", this), ("expression", expression)])
  }
  assert_true(
    dot ==
    mk_dot(
      mk_dot(
        mk_dot(
          mk_dot(mk_dot(ident("a"), ident("b")), ident("c")),
          ident("d", quoted=true),
        ),
        ident("e"),
      ),
      ident("f"),
    ),
  )
}

///|
test "TestExprs.test_root" {
  let ast = p1("select * from (select a from x)")
  assert_true(physical_equal(ast, ast.root()))
  assert_true(physical_equal(ast, ast.find([Column]).unwrap().root()))
}

///|
test "TestExprs.test_alias_or_name" {
  let expression = p1(
    "SELECT a, b AS B, c + d AS e, *, 'zz', 'zz' AS z FROM foo as bar, baz",
  )
  assert_eq(expression.expressions().map(e => e.alias_or_name()), [
    "a", "B", "e", "*", "zz", "z",
  ])
  let names = expression.find_all([Table]).map(e => e.alias_or_name()).collect()
  names.sort()
  assert_eq(names, ["bar", "baz"])
  let expression = p1(
    (
      #|
      #|            WITH first AS (SELECT * FROM foo),
      #|                 second AS (SELECT * FROM bar)
      #|            SELECT * FROM first, second, (SELECT * FROM baz) AS third
      #|
    ),
  )
  assert_eq(
    expression.arg("with_").unwrap().expressions().map(e => e.alias_or_name()),
    ["first", "second"],
  )
  assert_eq("first", expression.arg("from_").unwrap().alias_or_name())
  assert_eq(expression.list("joins").map(e => e.alias_or_name()), [
    "second", "third",
  ])
  assert_eq(p1("x.*").name(), "*")
  assert_eq(p1("NULL").name(), "NULL")
  assert_eq(p1("a.b.c").name(), "c")
}

///|
test "TestExprs.test_table_name" {
  let bq_dashed_table = @sqlglot.to_table("a-1.b.c", dialect="bigquery")
  assert_eq(@sqlglot.table_name(bq_dashed_table), "\"a-1\".b.c")
  assert_eq(
    @sqlglot.table_name(bq_dashed_table, dialect="bigquery"),
    "`a-1`.b.c",
  )
  assert_eq(@sqlglot.table_name("a-1.b.c", dialect="bigquery"), "`a-1`.b.c")
  assert_eq(@sqlglot.table_name(@sqlglot.maybe_parse("a", into=[Table])), "a")
  assert_eq(
    @sqlglot.table_name(@sqlglot.maybe_parse("a.b", into=[Table])),
    "a.b",
  )
  assert_eq(
    @sqlglot.table_name(@sqlglot.maybe_parse("a.b.c", into=[Table])),
    "a.b.c",
  )
  assert_eq(@sqlglot.table_name("a.b.c"), "a.b.c")
  assert_eq(
    @sqlglot.table_name(@sqlglot.to_table("a.b.c.d.e", dialect="bigquery")),
    "a.b.c.d.e",
  )
  assert_eq(
    @sqlglot.table_name(@sqlglot.to_table("'@foo'", dialect="snowflake")),
    "'@foo'",
  )
  assert_eq(
    @sqlglot.table_name(@sqlglot.to_table("@foo", dialect="snowflake")),
    "@foo",
  )
  assert_eq(
    @sqlglot.table_name(bq_dashed_table, identify=true),
    "\"a-1\".\"b\".\"c\"",
  )
  assert_eq(
    @sqlglot.table_name(
      @sqlglot.maybe_parse("foo.`{bar,er}`", dialect="databricks", into=[Table]),
      dialect="databricks",
    ),
    "foo.`{bar,er}`",
  )
  assert_eq(
    @sqlglot.table_name(
      @sqlglot.maybe_parse("/*c*/foo.bar", into=[Table]),
      identify=true,
    ),
    "\"foo\".\"bar\"",
  )
}

///|
test "TestExprs.test_table" {
  assert_true(
    @sqlglot.table_("a", alias="b") ==
    p1("select * from a b").find([Table]).unwrap(),
  )
  assert_eq(sql(@sqlglot.table_("a", db="")), "a")
  assert_eq(sql(@core.mk(Table, [("db", ident("a"))])), "a")
}

///|
test "TestExprs.test_replace_tables" {
  assert_eq(
    sql(
      @sqlglot.replace_tables(
        p1(
          "select * from a AS a, b, c.a, d.a cross join e.a cross join \"f-F\".\"A\" cross join G",
        ),
        {
          "a": "a1",
          "b": "b.a",
          "c.a": "c.a2",
          "d.a": "d2",
          "`f-F`.`A`": "\"F\"",
          "g": "g1.a",
        },
        dialect="bigquery",
      ),
    ),
    "SELECT * FROM a1 AS a /* a */, b.a /* b */, c.a2 /* c.a */, d2 /* d.a */ CROSS JOIN e.a CROSS JOIN \"F\" /* f-F.A */ CROSS JOIN g1.a /* g */",
  )
  assert_eq(
    sql(
      @sqlglot.replace_tables(
        @sqlglot.parse_one("select * from example.table", read="bigquery"),
        { "example.table": "`my-project.example.table`" },
        dialect="bigquery",
      ),
    ),
    "SELECT * FROM \"my-project\".\"example\".\"table\" /* example.table */",
  )
  assert_eq(
    sql(
      @sqlglot.replace_tables(
        p1("select * from example.table /* sqlglot.meta replace=false */"),
        { "example.table": "a.b" },
      ),
    ),
    "SELECT * FROM example.table /* sqlglot.meta replace=false */",
  )
}

///|
test "TestExprs.test_expand" {
  assert_eq(
    sql(
      @sqlglot.expand(
        p1("select * from \"a-b\".\"C\" AS a"),
        { "`a-b`.`c`": () => p1("select 1") },
        dialect="spark",
      ),
    ),
    "SELECT * FROM (SELECT 1) AS a /* source: a-b.c */",
  )
}

///|
test "TestExprs.test_expand_with_lazy_source_provider" {
  assert_eq(
    sql(
      @sqlglot.expand(
        p1("select * from \"a-b\".\"C\" AS a"),
        { "`a-b`.c": () => @sqlglot.parse_one("select 1", read="spark") },
        dialect="spark",
      ),
    ),
    "SELECT * FROM (SELECT 1) AS a /* source: a-b.c */",
  )
}

///|
test "TestExprs.test_replace_placeholders" {
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(
        p1(
          "select * from :tbl1 JOIN :tbl2 ON :col1 = :str1 WHERE :col2 > :int1",
        ),
        kwargs={
          "tbl1": ident("foo"),
          "tbl2": ident("bar"),
          "col1": ident("a"),
          "col2": ident("c"),
          "str1": "b",
          "int1": 100,
        },
      ),
    ),
    "SELECT * FROM foo JOIN bar ON a = 'b' WHERE c > 100",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(
        p1("select * from ? JOIN ? ON ? = ? WHERE ? = 'bla'"),
        args=[ident("foo"), ident("bar"), ident("a"), "b", "bla"],
      ),
    ),
    "SELECT * FROM foo JOIN bar ON a = 'b' WHERE 'bla' = 'bla'",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(p1("select * from ? WHERE ? > 100"), args=[
        ident("foo"),
      ]),
    ),
    "SELECT * FROM foo WHERE ? > 100",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(p1("select * from :name WHERE ? > 100"), kwargs={
        "another_name": "bla",
      }),
    ),
    "SELECT * FROM :name WHERE ? > 100",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(
        p1("select * from (SELECT :col1 FROM ?) WHERE :col2 > ?"),
        args=[ident("tbl1"), 100, "tbl3"],
        kwargs={ "col1": ident("a"), "col2": ident("b"), "col3": "c" },
      ),
    ),
    "SELECT * FROM (SELECT a FROM tbl1) WHERE b > 100",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(
        p1("select * from foo WHERE x > ? AND y IS ?"),
        args=[0, false],
      ),
    ),
    "SELECT * FROM foo WHERE x > 0 AND y IS FALSE",
  )
  assert_eq(
    sql(
      @sqlglot.replace_placeholders(
        p1("select * from foo WHERE x > :int1 AND y IS :bool1"),
        kwargs={ "int1": 0, "bool1": false },
      ),
    ),
    "SELECT * FROM foo WHERE x > 0 AND y IS FALSE",
  )
}

///|
fn expect_value_error(f : () -> Unit raise) -> String {
  try f() catch {
    @core.ValueError(m) => m
    e => "unexpected error: \{e}"
  } noraise {
    _ => "no error"
  }
}

///|
test "TestExprs.test_function_building" {
  assert_eq(sql(@sqlglot.func("max", args=[1])), "MAX(1)")
  assert_eq(sql(@sqlglot.func("max", args=[1, 2])), "MAX(1, 2)")
  assert_eq(sql(@sqlglot.func("bla", args=[1, "foo"])), "BLA(1, foo)")
  assert_eq(sql(@sqlglot.func("COUNT", args=[@core.mk0(Star)])), "COUNT(*)")
  assert_eq(sql(@sqlglot.func("bloo")), "BLOO()")
  assert_eq(
    sql(
      @sqlglot.func("concat", args=[@core.convert("a")], dialect="duckdb"),
      dialect="duckdb",
    ),
    "CONCAT('a')",
  )
  assert_eq(
    sql(
      @sqlglot.func("locate", args=["'x'", "'xo'"], dialect="hive"),
      dialect="hive",
    ),
    "LOCATE('x', 'xo')",
  )
  assert_eq(
    sql(
      @sqlglot.func("log", args=[ident("x"), 2], dialect="bigquery"),
      dialect="bigquery",
    ),
    "LOG(x, 2)",
  )
  assert_eq(
    sql(
      @sqlglot.func("log", dialect="bigquery", kwargs={
        "expression": "x",
        "this": 2,
      }),
      dialect="bigquery",
    ),
    "LOG(x, 2)",
  )
  assert_true(
    @sqlglot.func("instr", args=["x", "b"], dialect="mysql").kind.is_a(
      StrPosition,
    ),
  )
  assert_true(
    @sqlglot.func("instr", args=["x", "b"], dialect="sqlite").kind.is_a(
      StrPosition,
    ),
  )
  assert_true(@sqlglot.func("bla", args=[1, "foo"]).kind.is_a(Anonymous))
  assert_true(
    @sqlglot.func("cast", kwargs={
      "this": @core.literal_number("5"),
      "to": @sqlglot.datatype_build("DOUBLE"),
    }).kind.is_a(Cast),
  )
  assert_true(
    expect_value_error(fn() raise {
      ignore(@sqlglot.func("some_func", args=[1], kwargs={ "arg2": "foo" }))
    }).has_prefix("Can't use both args and kwargs"),
  )
  assert_true(
    expect_value_error(fn() raise { ignore(@sqlglot.func("abs")) }).has_prefix(
      "Required keyword",
    ),
  )
  assert_eq(
    expect_value_error(fn() raise {
      ignore(@sqlglot.func("to_hex", dialect="bigquery", kwargs={ "this": 5 }))
    }),
    "Unable to convert 'to_hex' into a Func. Either manually construct the Func expression of interest or parse the function call.",
  )
}

///|
test "TestExprs.test_var_len_args_spill_into_var_len_arg_key" {
  // Variadic args spill into var_len_arg_key, not into trailing flag args
  let chr_ = @core.from_arg_list(Chr, [@core.convert(65), @core.convert(66)])
  assert_true(chr_.expressions() == [@core.convert(65), @core.convert(66)])
  assert_true(chr_.get("charset") is None)
  assert_eq(sql(chr_), "CHR(65, 66)")
  assert_eq(sql(@sqlglot.func("CHR", args=[65, 66])), "CHR(65, 66)")
  let count = @core.from_arg_list(Count, [
    @sqlglot.column("a"),
    @sqlglot.column("b"),
    @sqlglot.column("c"),
  ])
  assert_true(
    count.expressions() == [@sqlglot.column("b"), @sqlglot.column("c")],
  )
  assert_true(count.get("big_int") is None)
  let greatest = @core.from_arg_list(Greatest, [
    @sqlglot.column("a"),
    @sqlglot.column("b"),
  ])
  assert_true(greatest.expressions() == [@sqlglot.column("b")])
  assert_true(greatest.get("ignore_nulls") is None)
  // VarMap overrides var_len_arg_key so the spill lands in "values"
  let var_map = @core.from_arg_list(VarMap, [
    @sqlglot.column("k"),
    @sqlglot.column("v1"),
    @sqlglot.column("v2"),
  ])
  assert_true(var_map.arg("keys").unwrap() == @sqlglot.column("k"))
  assert_true(
    var_map.list("values") == [@sqlglot.column("v1"), @sqlglot.column("v2")],
  )
}

///|
test "TestExprs.test_named_selects" {
  let expression = p1(
    "SELECT a, b AS B, c + d AS e, *, 'zz', 'zz' AS z FROM foo as bar, baz",
  )
  assert_eq(expression.named_selects(), ["a", "B", "e", "*", "zz", "z"])
  let expression = p1(
    (
      #|
      #|            WITH first AS (SELECT * FROM foo)
      #|            SELECT foo.bar, foo.baz as bazz, SUM(x) FROM first
      #|
    ),
  )
  assert_eq(expression.named_selects(), ["bar", "bazz"])
  let expression = p1(
    (
      #|
      #|            SELECT foo, bar FROM first
      #|            UNION SELECT "ss" as foo, bar FROM second
      #|            UNION ALL SELECT foo, bazz FROM third
      #|
    ),
  )
  assert_eq(expression.named_selects(), ["foo", "bar"])
  let expression = p1(
    "SELECT a, b FROM x UNION BY NAME SELECT c, b FROM y",
    read="duckdb",
  )
  assert_eq(expression.named_selects(), ["a", "b", "c"])
  let expression = p1(
    "SELECT a FROM x UNION SELECT b FROM y UNION BY NAME SELECT c FROM z",
    read="duckdb",
  )
  assert_eq(expression.named_selects(), ["a", "c"])
  let expression = p1(
    "(SELECT a FROM x UNION BY NAME SELECT c FROM z) UNION SELECT a, c FROM w",
    read="duckdb",
  )
  assert_eq(expression.named_selects(), ["a", "c"])
}

///|
test "TestExprs.test_selects" {
  let expression = p1("SELECT FROM x")
  assert_eq(expression.selects().length(), 0)
  let expression = p1("SELECT a FROM x")
  assert_eq(expression.selects().map(s => sql(s)), ["a"])
  let expression = p1("SELECT a, b FROM x")
  assert_eq(expression.selects().map(s => sql(s)), ["a", "b"])
  let expression = p1("(SELECT a, b FROM x)")
  assert_eq(expression.selects().map(s => sql(s)), ["a", "b"])
}

///|
test "TestExprs.test_alias_column_names" {
  let expression = p1("SELECT * FROM (SELECT * FROM x) AS y")
  let subquery = expression.find([Subquery]).unwrap()
  assert_eq(subquery.alias_column_names(), [])
  let expression = p1("SELECT * FROM (SELECT * FROM x) AS y(a)")
  let subquery = expression.find([Subquery]).unwrap()
  assert_eq(subquery.alias_column_names(), ["a"])
  let expression = p1("SELECT * FROM (SELECT * FROM x) AS y(a, b)")
  let subquery = expression.find([Subquery]).unwrap()
  assert_eq(subquery.alias_column_names(), ["a", "b"])
  let expression = p1("WITH y AS (SELECT * FROM x) SELECT * FROM y")
  let cte = expression.find([CTE]).unwrap()
  assert_eq(cte.alias_column_names(), [])
  let expression = p1("WITH y(a, b) AS (SELECT * FROM x) SELECT * FROM y")
  let cte = expression.find([CTE]).unwrap()
  assert_eq(cte.alias_column_names(), ["a", "b"])
  let expression = p1("SELECT * FROM tbl AS tbl(a, b)")
  let table = expression.find([Table]).unwrap()
  assert_eq(table.alias_column_names(), ["a", "b"])
}

///|
test "TestExprs.test_cast" {
  let expression = p1("CAST(x AS DATE)")
  assert_true(
    physical_equal(
      expression.get_type().unwrap(),
      expression.arg("to").unwrap(),
    ),
  )
  let expression = p1("select cast(x as DATE)")
  let casts = expression.find_all([Cast]).collect()
  assert_eq(casts.length(), 1)
  let cast = casts[0]
  assert_true(cast.arg("to").unwrap().is_type([@core.DType::DATE]))
  // check that already cast values arent re-cast if wrapped in a cast to the same type
  let recast = @sqlglot.cast(cast, @core.DType::DATE)
  assert_true(recast == cast)
  assert_eq(sql(recast), "CAST(x AS DATE)")
  // however, recasting is fine if the types are different
  let recast = @sqlglot.cast(cast, @core.DType::VARCHAR)
  assert_true(recast != cast)
  assert_eq(recast.find_all([Cast]).count(), 2)
  assert_eq(sql(recast), "CAST(CAST(x AS DATE) AS VARCHAR)")
  // a cast to a complex type (e.g. INTERVAL) nests an expression in `to.this`,
  // which the equivalence check must not treat as a plain type enum
  let interval_cast = p1("CAST(-1 AS INTERVAL HOUR)")
  let recast = @sqlglot.cast(interval_cast, @core.DType::BIGINT)
  assert_eq(sql(recast), "CAST(CAST(-1 AS INTERVAL HOUR) AS BIGINT)")
  // check that dialect is used when casting strings
  assert_eq(
    sql(@sqlglot.cast("x", "regtype", dialect="postgres")),
    "CAST(x AS REGTYPE)",
  )
  assert_eq(
    sql(@sqlglot.cast("`x`", "date", dialect="hive")),
    "CAST(\"x\" AS DATE)",
  )
}

///|
test "TestExprs.test_ctes" {
  let expression = p1("SELECT a FROM x")
  assert_eq(expression.ctes().length(), 0)
  let expression = p1("WITH x AS (SELECT a FROM y) SELECT a FROM x")
  assert_eq(expression.ctes().map(s => sql(s)), ["x AS (SELECT a FROM y)"])
}

///|
test "TestExprs.test_hash" {
  let a : @set.Set[@core.Expr] = @set.Set::from_array([
    p1("select a.b"),
    p1("1+2"),
    p1("\"a\".\"b\""),
    p1("a.b.c.d"),
  ])
  let b : @set.Set[@core.Expr] = @set.Set::from_array([
    p1("select a.b"),
    p1("1+2"),
    p1("\"a\".\"b\""),
    p1("a.b.c.d"),
  ])
  assert_eq(a.length(), b.length())
  for e in a {
    assert_true(b.contains(e))
  }
}

///|
test "TestExprs.test_hash_invalidated_on_append" {
  let expr = p1("SELECT a")
  ignore(expr.hash()) // populate the cached _hash
  expr.append("expressions", @sqlglot.column("b"))
  assert_eq(expr.hash(), p1("SELECT a, b").hash())
}

///|
test "TestExprs.test_sql" {
  assert_eq(sql(p1("x + y * 2")), "x + y * 2")
  assert_eq(
    gen(p1("select \"x\""), dialect="hive", pretty=true),
    "SELECT\n  `x`",
  )
  assert_eq(gen(p1("X + y"), identify=true, normalize=true), "\"x\" + \"y\"")
  assert_eq(
    gen(p1("\"X\" + Y"), identify=true, normalize=true),
    "\"X\" + \"y\"",
  )
  assert_eq(gen(p1("SUM(X)"), identify=true, normalize=true), "SUM(\"x\")")
}

///|
test "TestExprs.test_transform_with_arguments" {
  let expression = p1("a")
  let fun = fn(node : @core.Expr, alias_ : Bool) raise {
    if alias_ {
      Some(p1("a AS a"))
    } else {
      Some(node)
    }
  }
  let transformed_expression = expression.transform(n => fun(n, true))
  assert_eq(sql(transformed_expression, dialect="presto"), "a AS a")
  let transformed_expression_2 = expression.transform(n => fun(n, false))
  assert_eq(sql(transformed_expression_2, dialect="presto"), "a")
}

///|
test "TestExprs.test_transform_simple" {
  let expression = p1("IF(a > 0, a, b)")
  let fun = fn(node : @core.Expr) raise {
    if node.kind.is_a(Column) && node.name() == "a" {
      Some(p1("c - 2"))
    } else {
      Some(node)
    }
  }
  let actual_expression_1 = expression.transform(fun)
  assert_eq(
    sql(actual_expression_1, dialect="presto"),
    "IF(c - 2 > 0, c - 2, b)",
  )
  assert_false(physical_equal(actual_expression_1, expression))
  let actual_expression_2 = expression.transform(fun, copy=false)
  assert_eq(
    sql(actual_expression_2, dialect="presto"),
    "IF(c - 2 > 0, c - 2, b)",
  )
  assert_true(physical_equal(actual_expression_2, expression))
}

///|
test "TestExprs.test_transform_no_infinite_recursion" {
  let expression = p1("a")
  let fun = fn(node : @core.Expr) raise {
    if node.kind.is_a(Column) && node.name() == "a" {
      Some(p1("FUN(a)"))
    } else {
      Some(node)
    }
  }
  assert_eq(sql(expression.transform(fun)), "FUN(a)")
}

///|
test "TestExprs.test_transform_with_parent_mutation" {
  let expression = p1("SELECT COUNT(1) FROM table")
  let fun = fn(node : @core.Expr) raise {
    if sql(node) == "COUNT(1)" {
      // node gets silently mutated here - its parent points to the filter node
      Some(
        @core.mk(Filter, [
          ("this", node),
          ("expression", @core.mk1(Where, @core.true_())),
        ]),
      )
    } else {
      Some(node)
    }
  }
  let transformed = expression.transform(fun)
  assert_eq(sql(transformed), "SELECT COUNT(1) FILTER(WHERE TRUE) FROM table")
}

///|
test "TestExprs.test_transform_multiple_children" {
  let expression = p1("SELECT * FROM x")
  let fun = fn(node : @core.Expr) raise {
    if node.kind.is_a(Star) {
      Some(@core.Value::List(["a", "b"].map(c => @core.Node(p1(c)))))
    } else {
      Some(@core.Node(node))
    }
  }
  let transformed = expression.transform_values(fun)
  match transformed {
    Node(e) => assert_eq(sql(e), "SELECT a, b FROM x")
    _ => fail("expected a node")
  }
}

///|
test "TestExprs.test_transform_node_removal" {
  let expression = p1("SELECT a, b FROM x")
  let remove_column_b = fn(node : @core.Expr) {
    if node.kind.is_a(Column) && node.name() == "b" {
      None
    } else {
      Some(node)
    }
  }
  assert_eq(sql(expression.transform(remove_column_b)), "SELECT a FROM x")
  let expression = p1("CAST(x AS FLOAT)")
  let remove_non_list_arg = fn(node : @core.Expr) {
    if node.kind.is_a(DataType) {
      None
    } else {
      Some(node)
    }
  }
  assert_eq(sql(expression.transform(remove_non_list_arg)), "CAST(x AS)")
  let expression = p1("SELECT a, b FROM x")
  let remove_all_columns = fn(node : @core.Expr) {
    if node.kind.is_a(Column) {
      None
    } else {
      Some(node)
    }
  }
  assert_eq(sql(expression.transform(remove_all_columns)), "SELECT FROM x")
}

///|
test "TestExprs.test_replace" {
  let expression = p1("SELECT a, b FROM x")
  expression.find([Column]).unwrap().replace(Some(p1("c"))) |> ignore
  assert_eq(sql(expression), "SELECT c, b FROM x")
  expression.find([Table]).unwrap().replace(Some(p1("y"))) |> ignore
  assert_eq(sql(expression), "SELECT c, b FROM y")
  // we try to replace a with a list but a's parent is actually ordered, not the ORDER BY node
  let expression = p1("SELECT * FROM x ORDER BY a DESC, c")
  expression
  .find([Ordered])
  .unwrap()
  .this_()
  .replace_with_list([@sqlglot.column("a").asc(), @sqlglot.column("b").desc()])
  assert_eq(sql(expression), "SELECT * FROM x ORDER BY a, b DESC, c")
}

///|
test "TestExprs.test_arg_deletion" {
  // Using the pop helper method
  let expression = p1("SELECT a, b FROM x")
  expression.find([Column]).unwrap().pop() |> ignore
  assert_eq(sql(expression), "SELECT b FROM x")
  expression.find([Column]).unwrap().pop() |> ignore
  assert_eq(sql(expression), "SELECT FROM x")
  expression.pop() |> ignore
  assert_eq(sql(expression), "SELECT FROM x")
  let expression = p1("WITH x AS (SELECT a FROM x) SELECT * FROM x")
  expression.find([With]).unwrap().pop() |> ignore
  assert_eq(sql(expression), "SELECT * FROM x")
  // Manually deleting by setting to None
  let expression = p1("SELECT * FROM foo JOIN bar")
  assert_eq(expression.list("joins").length(), 1)
  expression.set("joins", @core.null_arg)
  assert_eq(sql(expression), "SELECT * FROM foo")
  assert_eq(expression.list("joins").length(), 0)
  assert_true(expression.get("joins") is None)
}

///|
test "TestExprs.test_walk" {
  let expression = p1("SELECT * FROM (SELECT * FROM x)")
  assert_eq(expression.walk().count(), 9)
  assert_eq(expression.walk(bfs=false).count(), 9)
  // `all(isinstance(e, exp.Expr) ...)` holds by construction (walk yields `@core.Expr`)
}

///|
test "TestExprs.test_str_position_order" {
  let str_position_exp = p1("STR_POSITION('mytest', 'test')")
  assert_true(str_position_exp.kind.is_a(StrPosition))
  assert_eq(str_position_exp.arg("this").unwrap().text("this"), "mytest")
  assert_eq(str_position_exp.arg("substr").unwrap().text("this"), "test")
}

///|
test "TestExprs.test_functions" {
  let cases : Array[(String, @core.Kind, String)] = [
    ("x LIKE ANY (y)", Like, ""),
    ("x ILIKE ANY (y)", ILike, ""),
    ("ABS(a)", Abs, ""),
    ("APPROX_DISTINCT(a)", ApproxDistinct, ""),
    ("ARRAY(a)", Array, ""),
    ("ARRAY_AGG(a)", ArrayAgg, ""),
    ("ARRAY_CONTAINS(a, 'a')", ArrayContains, ""),
    ("ARRAY_SIZE(a)", ArraySize, ""),
    ("ARRAY_INTERSECTION([1, 2], [2, 3])", ArrayIntersect, ""),
    ("ARRAY_INTERSECT([1, 2], [2, 3])", ArrayIntersect, ""),
    ("AVG(a)", Avg, ""),
    ("BEGIN DEFERRED TRANSACTION", Transaction, ""),
    ("CEIL(a)", Ceil, ""),
    ("CEILING(a)", Ceil, ""),
    ("COALESCE(a, b)", Coalesce, ""),
    ("COMMIT", Commit, ""),
    ("COUNT(a)", Count, ""),
    ("COUNT_IF(a > 0)", CountIf, ""),
    ("DATE_ADD(a, 1)", DateAdd, ""),
    ("DATE_DIFF(a, 2)", DateDiff, ""),
    ("DATE_STR_TO_DATE(a)", DateStrToDate, ""),
    ("TS_OR_DS_TO_TIME(a)", TsOrDsToTime, ""),
    ("DAY(a)", Day, ""),
    ("EXP(a)", Exp, ""),
    ("FLOOR(a)", Floor, ""),
    ("GENERATE_SERIES(a, b, c)", GenerateSeries, ""),
    ("GLOB(x, y)", Glob, ""),
    ("GREATEST(a, b)", Greatest, ""),
    ("IF(a, b, c)", If, ""),
    ("INITCAP(a)", Initcap, ""),
    ("JSON_EXTRACT(a, '$.name')", JSONExtract, ""),
    ("JSON_EXTRACT_SCALAR(a, '$.name')", JSONExtractScalar, ""),
    ("LEAST(a, b)", Least, ""),
    ("LIKE(x, y)", Like, ""),
    ("LN(a)", Ln, ""),
    ("LOG(b, n)", Log, ""),
    ("LOG2(a)", Log, ""),
    ("LOG10(a)", Log, ""),
    ("MAX(a)", Max, ""),
    ("MIN(a)", Min, ""),
    ("MONTH(a)", Month, ""),
    ("QUARTER(a)", Quarter, ""),
    ("POSITION(' ' IN a)", StrPosition, ""),
    ("POW(a, 2)", Pow, ""),
    ("POWER(a, 2)", Pow, ""),
    ("QUANTILE(a, 0.90)", Quantile, ""),
    ("REGEXP_LIKE(a, 'test')", RegexpLike, ""),
    ("REGEXP_SPLIT(a, 'test')", RegexpSplit, ""),
    ("ROLLBACK", Rollback, ""),
    ("ROUND(a)", Round, ""),
    ("ROUND(a, 2)", Round, ""),
    ("SPLIT(a, 'test')", Split, ""),
    ("ST_POINT(10, 20)", StPoint, ""),
    ("ST_DISTANCE(a, b)", StDistance, ""),
    ("STR_POSITION(a, 'test')", StrPosition, ""),
    ("STR_TO_UNIX(a, 'format')", StrToUnix, ""),
    ("STRUCT_EXTRACT(a, 'test')", StructExtract, ""),
    ("SUBSTR('a', 1, 1)", Substring, ""),
    ("SUBSTRING('a', 1, 1)", Substring, ""),
    ("SUM(a)", Sum, ""),
    ("SQRT(a)", Sqrt, ""),
    ("STDDEV(a)", Stddev, ""),
    ("STDDEV_POP(a)", StddevPop, ""),
    ("STDDEV_SAMP(a)", StddevSamp, ""),
    ("TIME_TO_STR(a, 'format')", TimeToStr, ""),
    ("TIME_TO_TIME_STR(a)", Cast, ""),
    ("TIME_TO_UNIX(a)", TimeToUnix, ""),
    ("TIME_STR_TO_DATE(a)", TimeStrToDate, ""),
    ("TIME_STR_TO_TIME(a)", TimeStrToTime, ""),
    ("TIME_STR_TO_TIME(a, 'some_zone')", TimeStrToTime, ""),
    ("TIME_STR_TO_UNIX(a)", TimeStrToUnix, ""),
    ("TRIM(LEADING 'b' FROM 'bla')", Trim, ""),
    ("TS_OR_DS_ADD(a, 1, 'day')", TsOrDsAdd, ""),
    ("TS_OR_DS_TO_DATE(a)", TsOrDsToDate, ""),
    ("TS_OR_DS_TO_DATE_STR(a)", Substring, ""),
    ("UNIX_TO_STR(a, 'format')", UnixToStr, ""),
    ("UNIX_TO_TIME(a)", UnixToTime, ""),
    ("UNIX_TO_TIME_STR(a)", UnixToTimeStr, ""),
    ("VARIANCE(a)", Variance, ""),
    ("VARIANCE_POP(a)", VariancePop, ""),
    ("YEAR(a)", Year, ""),
    ("HLL(a)", Hll, ""),
    ("ARRAY(time, foo)", Array, ""),
    ("STANDARD_HASH('hello', 'sha256')", StandardHash, ""),
    ("DATE(foo)", Date, ""),
    ("HEX(foo)", Hex, ""),
    ("LOWER(HEX(foo))", LowerHex, ""),
    ("TO_HEX(foo)", LowerHex, "bigquery"),
    ("UPPER(TO_HEX(foo))", Hex, "bigquery"),
    ("TO_HEX(MD5(foo))", MD5, "bigquery"),
    ("TRANSFORM(a, b)", Transform, "spark"),
    ("ADD_MONTHS(a, b)", AddMonths, ""),
  ]
  let failures = []
  for case in cases {
    let (s, kind, read) = case
    let e = p1(s, read~)
    if !e.kind.is_a(kind) {
      failures.push("\{s}: expected \{kind}, got \{e.kind}")
    }
  }
  assert_eq(failures.length(), 0, msg=failures.join("\n"))
  let ast = p1("GREATEST(a, b, c)")
  assert_eq(ast.expressions().length(), 2)
}

///|
test "TestExprs.test_column" {
  let column = @sqlglot.column(@core.mk0(Star), table="t")
  assert_eq(sql(column), "t.*")
  let column = p1("a.b.c.d")
  assert_eq(column.catalog(), "a")
  assert_eq(column.db(), "b")
  assert_eq(column.table_name(), "c")
  assert_eq(column.name(), "d")
  let column = p1("a")
  assert_eq(column.name(), "a")
  assert_eq(column.table_name(), "")
  let fields = p1("a.b.c.d.e")
  assert_true(fields.kind.is_a(Dot))
  assert_eq(fields.text("expression"), "e")
  let column = fields.find([Column]).unwrap()
  assert_eq(column.name(), "d")
  assert_eq(column.table_name(), "c")
  assert_eq(column.db(), "b")
  assert_eq(column.catalog(), "a")
  let column = p1("a[0].b")
  assert_true(column.kind.is_a(Dot))
  assert_true(column.this_().kind.is_a(Bracket))
  assert_true(column.this_().this_().kind.is_a(Column))
  let column = p1("a.*")
  assert_true(column.kind.is_a(Column))
  assert_true(column.this_().kind.is_a(Star))
  assert_true(column.arg("table").unwrap().kind.is_a(Identifier))
  assert_eq(column.table_name(), "a")
  assert_true(p1("*").kind.is_a(Star))
  assert_true(
    @sqlglot.column("a", table="b", db="c", catalog="d") ==
    @sqlglot.to_column("d.c.b.a"),
  )
  let dot = @sqlglot.column("d", table="c", db="b", catalog="a", fields=[
    "e", "f",
  ])
  assert_true(dot.kind.is_a(Dot))
  assert_eq(sql(dot), "a.b.c.d.e.f")
  let dot = @sqlglot.column(
    "d",
    table="c",
    db="b",
    catalog="a",
    fields=["e", "f"],
    quoted=true,
  )
  assert_eq(sql(dot), "\"a\".\"b\".\"c\".\"d\".\"e\".\"f\"")
}

///|
test "TestExprs.test_text" {
  let column = p1("a.b.c.d.e")
  assert_eq(column.text("expression"), "e")
  assert_eq(column.text("y"), "")
  assert_eq(p1("select * from x.y").find([Table]).unwrap().text("db"), "x")
  assert_eq(p1("select *").name(), "")
  assert_eq(p1("1 + 1").name(), "1")
  assert_eq(p1("'a'").name(), "a")
}

///|
test "TestExprs.test_alias" {
  assert_eq(sql(@sqlglot.alias_("foo", "bar")), "foo AS bar")
  assert_eq(sql(@sqlglot.alias_("foo", "bar-1")), "foo AS \"bar-1\"")
  assert_eq(sql(@sqlglot.alias_("foo", "bar_1")), "foo AS bar_1")
  assert_eq(sql(@sqlglot.alias_("foo * 2", "2bar")), "foo * 2 AS \"2bar\"")
  assert_eq(sql(@sqlglot.alias_("\"foo\"", "_bar")), "\"foo\" AS _bar")
  assert_eq(sql(@sqlglot.alias_("foo", "bar", quoted=true)), "foo AS \"bar\"")
}

///|
test "TestExprs.test_alias_with_placeholder" {
  // Snowflake's `AS :name` syntax parses the alias as a Placeholder node.
  // Regression test: Expression.alias should return the placeholder name, not "".
  let expr = @sqlglot.parse_one(
    "SELECT PARSE_JSON(col) AS :userInfo FROM t",
    read="snowflake",
  )
  let select = expr.selects()[0]
  assert_true(select.arg("alias").unwrap().kind.is_a(Placeholder))
  assert_eq(select.alias(), "userInfo")
  assert_eq(select.alias_or_name(), "userInfo")
  assert_eq(select.output_name(), "userInfo")
}

///|
test "TestExprs.test_unit" {
  let unit = p1("timestamp_trunc(current_timestamp, week(thursday))")
  assert_true(unit.find([CurrentTimestamp]) is Some(_))
  let week = unit.find([Week]).unwrap()
  assert_true(week.this_() == @sqlglot.var_("thursday"))
  for abbreviated_unit, unnabreviated_unit in @core.unabbreviated_unit_name {
    let interval = p1("interval '500 \{abbreviated_unit}'")
    let unit = interval.arg("unit").unwrap()
    assert_true(unit.kind.is_a(Var))
    assert_eq(unit.name(), unnabreviated_unit)
  }
}

///|
test "TestExprs.test_identifier" {
  assert_true(ident("\"x\"").bool_arg("quoted"))
  assert_false(ident("x").bool_arg("quoted"))
  assert_true(ident("foo ").bool_arg("quoted"))
  assert_false(ident("_x").bool_arg("quoted"))
}

///|
test "TestExprs.test_function_normalizer" {
  assert_eq(gen(p1("HELLO()"), normalize_functions="lower"), "hello()")
  assert_eq(gen(p1("hello()"), normalize_functions="upper"), "HELLO()")
  assert_eq(gen(p1("heLLO()"), normalize_functions=""), "heLLO()")
  assert_eq(gen(p1("SUM(x)"), normalize_functions="lower"), "sum(x)")
  assert_eq(gen(p1("sum(x)"), normalize_functions="upper"), "SUM(x)")
}

///|
test "TestExprs.test_properties_from_dict" {
  assert_true(
    @core.properties_from_dict({
      "FORMAT": @core.PyStr("parquet"),
      "PARTITIONED_BY": @core.PyTuple([
        @core.PyExpr(ident("a")),
        @core.PyExpr(ident("b")),
      ]),
      "custom": @core.PyInt(1),
      "ENGINE": @core.PyNone,
      "COLLATE": @core.PyBool(true),
    }) ==
    @core.mk(Properties, [
      (
        "expressions",
        [
          @core.mk1(FileFormatProperty, @core.literal_string("parquet")),
          @core.mk1(
            PartitionedByProperty,
            @core.mk(Tuple, [("expressions", [ident("a"), ident("b")])]),
          ),
          @core.mk(Property, [
            ("this", @core.literal_string("custom")),
            ("value", @core.literal_number("1")),
          ]),
          @core.mk1(EngineProperty, @core.null_()),
          @core.mk1(CollateProperty, @core.true_()),
        ],
      ),
    ]),
  )
  // SKIP: `Properties.from_dict({"FORMAT": object})` raising ValueError: arbitrary Python
  // objects can't be represented as host values in the port
}

///|
test "TestExprs.test_convert" {
  let cases : Array[(@core.PyObj, String)] = [
    (@core.PyInt(1), "1"),
    (@core.PyStr("1"), "'1'"),
    (@core.PyNone, "NULL"),
    (@core.PyBool(true), "TRUE"),
    (
      @core.PyTuple([@core.PyInt(1), @core.PyStr("2"), @core.PyNone]),
      "(1, '2', NULL)",
    ),
    (
      @core.PyList([@core.PyInt(1), @core.PyStr("2"), @core.PyNone]),
      "ARRAY(1, '2', NULL)",
    ),
    (
      @core.PyDict([(@core.PyStr("x"), @core.PyNone)]),
      "MAP(ARRAY('x'), ARRAY(NULL))",
    ),
    // datetime.datetime(2022, 10, 1, 1, 1, 1, 1)
    (
      @core.PyDateTime(
        year=2022,
        month=10,
        day=1,
        hour=1,
        minute=1,
        second=1,
        microsecond=1,
        tz=None,
      ),
      "TIME_STR_TO_TIME('2022-10-01 01:01:01.000001')",
    ),
    // datetime.datetime(2022, 10, 1, 1, 1, 1, tzinfo=datetime.timezone.utc)
    (
      @core.PyDateTime(
        year=2022,
        month=10,
        day=1,
        hour=1,
        minute=1,
        second=1,
        microsecond=0,
        tz=Some(("UTC", 0)),
      ),
      "TIME_STR_TO_TIME('2022-10-01 01:01:01+00:00', 'UTC')",
    ),
    // pytz.timezone("America/Los_Angeles").localize(datetime.datetime(2022, 10, 1, 1, 1, 1))
    (
      @core.PyDateTime(
        year=2022,
        month=10,
        day=1,
        hour=1,
        minute=1,
        second=1,
        microsecond=0,
        tz=Some(("America/Los_Angeles", -7 * 60)),
      ),
      "TIME_STR_TO_TIME('2022-10-01 01:01:01-07:00', 'America/Los_Angeles')",
    ),
    // datetime.date(2022, 10, 1)
    (@core.PyDate(year=2022, month=10, day=1), "DATE_STR_TO_DATE('2022-10-01')"),
    (@core.PyFloat(@double.not_a_number), "NULL"),
    (@core.PyBytes(b"\x00\x00\x00\x00\x00\x00\x07\xd3"), "2003"),
    // namedtuple PointTuple(1, 2) and object PointClass(1, 2)
    (
      @core.PyObject([("x", @core.PyInt(1)), ("y", @core.PyInt(2))]),
      "STRUCT(1 AS x, 2 AS y)",
    ),
    (
      @core.PyObject([("x", @core.PyInt(1)), ("y", @core.PyInt(2))]),
      "STRUCT(1 AS x, 2 AS y)",
    ),
  ]
  for case in cases {
    let (value, expected) = case
    assert_eq(sql(@core.convert(value)), expected)
  }
  assert_eq(
    sql(
      @core.convert(@core.PyDict([(@core.PyStr("test"), @core.PyStr("value"))])),
      dialect="spark",
    ),
    "MAP_FROM_ARRAYS(ARRAY('test'), ARRAY('value'))",
  )
}

///|
test "TestExprs.test_convert_python39" {
  // datetime.datetime(2022, 10, 1, 1, 1, 1, tzinfo=zoneinfo.ZoneInfo("America/Los_Angeles"))
  let value = @core.PyDateTime(
    year=2022,
    month=10,
    day=1,
    hour=1,
    minute=1,
    second=1,
    microsecond=0,
    tz=Some(("America/Los_Angeles", -7 * 60)),
  )
  assert_eq(
    sql(@core.convert(value)),
    "TIME_STR_TO_TIME('2022-10-01 01:01:01-07:00', 'America/Los_Angeles')",
  )
}

///|
test "TestExprs.test_comment_alias" {
  let s =
    #|
    #|        SELECT
    #|            a,
    #|            b AS B,
    #|            c, /*comment*/
    #|            d AS D, -- another comment
    #|            CAST(x AS INT), -- yet another comment
    #|            y AND /* foo */ w AS E -- final comment
    #|        FROM foo
    #|
  let expression = p1(s)
  assert_eq(expression.expressions().map(e => e.alias_or_name()), [
    "a", "B", "c", "D", "x", "E",
  ])
  assert_eq(
    sql(expression),
    "SELECT a, b AS B, c /* comment */, d AS D /* another comment */, CAST(x AS INT) /* yet another comment */, y AND /* foo */ w AS E /* final comment */ FROM foo",
  )
  assert_eq(
    gen(expression, comments=false),
    "SELECT a, b AS B, c, d AS D, CAST(x AS INT), y AND w AS E FROM foo",
  )
  assert_eq(
    gen(expression, pretty=true, comments=false),
    (
      #|SELECT
      #|  a,
      #|  b AS B,
      #|  c,
      #|  d AS D,
      #|  CAST(x AS INT),
      #|  y AND w AS E
      #|FROM foo
    ),
  )
  assert_eq(
    gen(expression, pretty=true),
    (
      #|SELECT
      #|  a,
      #|  b AS B,
      #|  c, /* comment */
      #|  d AS D, /* another comment */
      #|  CAST(x AS INT), /* yet another comment */
      #|  y AND /* foo */ w AS E /* final comment */
      #|FROM foo
    ),
  )
  assert_eq(p1("max(x) as \"a b\" -- comment").comments, Some([" comment"]))
}

///|
test "TestExprs.test_to_interval" {
  assert_eq(sql(@sqlglot.to_interval("1day")), "INTERVAL '1' DAY")
  assert_eq(sql(@sqlglot.to_interval("  5     months")), "INTERVAL '5' MONTHS")
  assert_eq(sql(@sqlglot.to_interval("-2 day")), "INTERVAL '-2' DAY")
  assert_eq(
    sql(@sqlglot.to_interval(@core.literal_string("1day"))),
    "INTERVAL '1' DAY",
  )
  assert_eq(
    sql(@sqlglot.to_interval(@core.literal_string("-2 day"))),
    "INTERVAL '-2' DAY",
  )
  assert_eq(
    sql(@sqlglot.to_interval(@core.literal_string("  5   months"))),
    "INTERVAL '5' MONTHS",
  )
}

///|
test "TestExprs.test_to_table" {
  let table_only = @sqlglot.to_table("table_name")
  assert_eq(table_only.name(), "table_name")
  assert_true(table_only.get("db") is None)
  assert_true(table_only.get("catalog") is None)
  let db_and_table = @sqlglot.to_table("db.table_name")
  assert_eq(db_and_table.name(), "table_name")
  assert_true(db_and_table.arg("db").unwrap() == ident("db"))
  assert_true(db_and_table.get("catalog") is None)
  let catalog_db_and_table = @sqlglot.to_table("catalog.db.table_name")
  assert_eq(catalog_db_and_table.name(), "table_name")
  assert_true(catalog_db_and_table.arg("db").unwrap() == ident("db"))
  assert_true(catalog_db_and_table.arg("catalog").unwrap() == ident("catalog"))
  let table_only_unsafe_identifier = @sqlglot.to_table("3e")
  assert_eq(sql(table_only_unsafe_identifier), "\"3e\"")
}

///|
test "TestExprs.test_to_column" {
  let column_only = @sqlglot.to_column("column_name")
  assert_eq(column_only.name(), "column_name")
  assert_true(column_only.get("table") is None)
  let table_and_column = @sqlglot.to_column("table_name.column_name")
  assert_eq(table_and_column.name(), "column_name")
  assert_true(table_and_column.arg("table").unwrap() == ident("table_name"))
  assert_eq(sql(@sqlglot.to_column("foo bar")), "\"foo bar\"")
  assert_eq(
    sql(@sqlglot.to_column("`column_name`", dialect="spark")),
    "\"column_name\"",
  )
  assert_eq(
    sql(@sqlglot.to_column("column_name", quoted=true)),
    "\"column_name\"",
  )
  assert_eq(
    sql(
      @sqlglot.to_column("column_name", kwargs={
        "table": @core.Node(ident("table_name")),
      }),
    ),
    "table_name.column_name",
  )
}

///|
test "TestExprs.test_union" {
  let expression = p1("SELECT cola, colb UNION SELECT colx, coly")
  assert_true(expression.kind.is_a(Union))
  assert_eq(expression.named_selects(), ["cola", "colb"])
  assert_true(
    expression.selects() ==
    [@core.mk1(Column, ident("cola")), @core.mk1(Column, ident("colb"))],
  )
}

///|
test "TestExprs.test_values" {
  let rows = [
    @core.PyTuple([@core.PyInt(1), @core.PyInt(2)]),
    @core.PyTuple([@core.PyInt(3), @core.PyInt(4)]),
  ]
  assert_eq(
    sql(@sqlglot.values(rows, alias="t", columns=["a", "b"])),
    "(VALUES (1, 2), (3, 4)) AS t(a, b)",
  )
  // Python passes `{"a": DataType.build("TEXT"), "b": DataType.build("TEXT")}`; only the
  // (ordered) column names are used
  assert_eq(
    sql(@sqlglot.values(rows, alias="t", columns=["a", "b"])),
    "(VALUES (1, 2), (3, 4)) AS t(a, b)",
  )
  assert_eq(
    expect_value_error(fn() raise {
      ignore(@sqlglot.values(rows, columns=["a"]))
    }),
    "Alias is required when providing columns",
  )
}

///|
fn dtb(s : String, dialect? : String = "") -> String raise @core.SqlglotError {
  sql(@sqlglot.datatype_build(s, dialect~))
}

///|
test "TestExprs.test_data_type_builder" {
  assert_eq(dtb("TEXT"), "TEXT")
  assert_eq(dtb("DECIMAL(10, 2)"), "DECIMAL(10, 2)")
  assert_eq(dtb("VARCHAR(255)"), "VARCHAR(255)")
  assert_eq(dtb("ARRAY<INT>"), "ARRAY<INT>")
  assert_eq(dtb("CHAR"), "CHAR")
  assert_eq(dtb("NCHAR"), "CHAR")
  assert_eq(dtb("VARCHAR"), "VARCHAR")
  assert_eq(dtb("NVARCHAR"), "VARCHAR")
  assert_eq(dtb("TEXT"), "TEXT")
  assert_eq(dtb("BINARY"), "BINARY")
  assert_eq(dtb("VARBINARY"), "VARBINARY")
  assert_eq(dtb("INT"), "INT")
  assert_eq(dtb("TINYINT"), "TINYINT")
  assert_eq(dtb("SMALLINT"), "SMALLINT")
  assert_eq(dtb("BIGINT"), "BIGINT")
  assert_eq(dtb("FLOAT"), "FLOAT")
  assert_eq(dtb("DOUBLE"), "DOUBLE")
  assert_eq(dtb("DECIMAL"), "DECIMAL")
  assert_eq(dtb("BOOLEAN"), "BOOLEAN")
  assert_eq(dtb("JSON"), "JSON")
  assert_eq(dtb("JSONB", dialect="postgres"), "JSONB")
  assert_eq(dtb("INTERVAL"), "INTERVAL")
  assert_eq(dtb("TIME"), "TIME")
  assert_eq(dtb("TIMESTAMP"), "TIMESTAMP")
  assert_eq(dtb("TIMESTAMPTZ"), "TIMESTAMPTZ")
  assert_eq(dtb("TIMESTAMPLTZ"), "TIMESTAMPLTZ")
  assert_eq(dtb("DATE"), "DATE")
  assert_eq(dtb("DATETIME"), "DATETIME")
  assert_eq(dtb("ARRAY"), "ARRAY")
  assert_eq(dtb("MAP"), "MAP")
  assert_eq(dtb("UUID"), "UUID")
  assert_eq(dtb("GEOGRAPHY"), "GEOGRAPHY")
  assert_eq(dtb("GEOMETRY"), "GEOMETRY")
  assert_eq(dtb("STRUCT"), "STRUCT")
  assert_eq(dtb("HLLSKETCH", dialect="redshift"), "HLLSKETCH")
  assert_eq(dtb("HSTORE", dialect="postgres"), "HSTORE")
  assert_eq(dtb("NULL"), "NULL")
  assert_eq(dtb("NULL", dialect="bigquery"), "NULL")
  assert_eq(dtb("UNKNOWN"), "UNKNOWN")
  assert_eq(dtb("UNKNOWN", dialect="bigquery"), "UNKNOWN")
  assert_eq(dtb("UNKNOWN", dialect="snowflake"), "UNKNOWN")
  assert_eq(dtb("TIMESTAMP", dialect="bigquery"), "TIMESTAMPTZ")
  assert_eq(dtb("USER-DEFINED"), "USER-DEFINED")
  assert_eq(dtb("ARRAY<UNKNOWN>"), "ARRAY<UNKNOWN>")
  assert_eq(dtb("ARRAY<NULL>"), "ARRAY<NULL>")
  assert_eq(dtb("varchar(100) collate 'en-ci'"), "VARCHAR(100)")
  assert_eq(sql(@sqlglot.datatype_build("int[3]"), dialect="duckdb"), "INT[3]")
  assert_eq(
    sql(@sqlglot.datatype_build("int[3][3]"), dialect="duckdb"),
    "INT[3][3]",
  )
  assert_eq(dtb("time_ns", dialect="duckdb"), "TIME_NS")
  assert_eq(dtb("bignum", dialect="duckdb"), "BIGNUM")
  assert_eq(dtb("struct<x int>", dialect="spark"), "STRUCT<x INT>")
  try @sqlglot.datatype_build("varchar(") catch {
    @core.ParseError(_, _) => ()
    e => fail("unexpected error \{e}")
  } noraise {
    _ => fail("expected ParseError")
  }
}

///|
test "TestExprs.test_rename_table" {
  assert_eq(
    sql(@sqlglot.rename_table("t1", "t2")),
    "ALTER TABLE t1 RENAME TO t2",
  )
}

///|
test "TestExprs.test_to_py" {
  assert_true(p1("- -1").to_py() == @core.PyInt(1))
  assert_true(p1("TRUE").to_py() == @core.PyBool(true))
  assert_true(p1("1").to_py() == @core.PyInt(1))
  assert_true(p1("'1'").to_py() == @core.PyStr("1"))
  assert_true(p1("null").to_py() == @core.PyNone)
  assert_true(
    expect_value_error(fn() raise { ignore(p1("x").to_py()) }).has_suffix(
      "cannot be converted to a Python object.",
    ),
  )
  assert_eq(
    expect_value_error(fn() raise {
      ignore(@core.literal_number("0.1.2").to_py())
    }),
    "Invalid numeric literal: '0.1.2'",
  )
}

///|
test "TestExprs.test_is_int" {
  assert_true(p1("- -1").is_int())
}

///|
test "TestExprs.test_is_star" {
  assert_true(p1("*").is_star())
  assert_true(p1("foo.*").is_star())
  assert_true(p1("SELECT * FROM foo").is_star())
  assert_true(p1("(SELECT * FROM foo)").is_star())
  assert_true(p1("SELECT *, 1 FROM foo").is_star())
  assert_true(p1("SELECT foo.* FROM foo").is_star())
  assert_true(p1("SELECT * EXCEPT (a, b) FROM foo").is_star())
  assert_true(p1("SELECT foo.* EXCEPT (foo.a, foo.b) FROM foo").is_star())
  assert_true(p1("SELECT * REPLACE (a AS b, b AS C)").is_star())
  assert_true(p1("SELECT * EXCEPT (a, b) REPLACE (a AS b, b AS C)").is_star())
  assert_true(p1("SELECT * INTO newevent FROM event").is_star())
  assert_true(p1("SELECT * FROM foo UNION SELECT * FROM bar").is_star())
  assert_true(p1("SELECT * FROM bla UNION SELECT 1 AS x").is_star())
  assert_true(p1("SELECT 1 AS x UNION SELECT * FROM bla").is_star())
  assert_true(
    p1("SELECT 1 AS x UNION SELECT 1 AS x UNION SELECT * FROM foo").is_star(),
  )
  // Deeply nested set operations / subqueries must not hit the recursion limit
  let mut deep_union = @sqlglot.select(["1"])
  let mut deep_subquery = @sqlglot.select(["1"])
  for _ in 0..<5000 {
    deep_union = @core.mk(Union, [
      ("this", deep_union),
      ("expression", @sqlglot.select(["1"])),
    ])
    deep_subquery = @core.mk1(Subquery, deep_subquery)
  }
  assert_false(deep_union.is_star())
  assert_false(deep_subquery.is_star())
  assert_true(
    @core.mk(Union, [
      ("this", deep_union),
      ("expression", @sqlglot.select(["*"])),
    ]).is_star(),
  )
  assert_true(
    @core.mk1(
      Subquery,
      @core.mk(Union, [
        ("this", deep_union),
        ("expression", @sqlglot.select(["*"])),
      ]),
    ).is_star(),
  )
}

///|
test "TestExprs.test_set_metadata" {
  let ast = p1("SELECT foo.col FROM foo")
  assert_true(ast.meta is None)
  // calling ast.meta would lazily instantiate self._meta
  assert_eq(ast.get_meta().length(), 0)
  assert_true(ast.meta is Some(_))
  ast.get_meta()["some_meta_key"] = Str("some_meta_value")
  assert_true(ast.meta_get("some_meta_key") is Some(Str("some_meta_value")))
  assert_true(ast.meta_get("some_other_meta_key") is None)
  ast.get_meta()["some_other_meta_key"] = Str("some_other_meta_value")
  assert_true(
    ast.meta_get("some_other_meta_key") is Some(Str("some_other_meta_value")),
  )
}

///|
test "TestExprs.test_unnest" {
  let ast = p1("SELECT (((1)))")
  assert_true(
    physical_equal(ast.selects()[0].unnest(), ast.find([Literal]).unwrap()),
  )
  let ast = p1("SELECT * FROM (((SELECT * FROM t)))")
  assert_true(
    physical_equal(
      ast.arg("from_").unwrap().this_().unnest(),
      ast.find_all([Select]).collect()[1],
    ),
  )
  let ast = p1("SELECT * FROM ((((SELECT * FROM t))) AS foo)")
  let second_subquery = ast.arg("from_").unwrap().this_().this_()
  let innermost_subquery = ast.find_all([Select]).collect()[1].parent.unwrap()
  assert_true(
    physical_equal(second_subquery, innermost_subquery.unwrap_subquery()),
  )
}

///|
test "TestExprs.test_is_type" {
  let ast = p1("CAST(x AS VARCHAR)")
  assert_true(@sqlglot.is_type(ast, ["VARCHAR"]))
  assert_false(@sqlglot.is_type(ast, ["VARCHAR(5)"]))
  assert_false(@sqlglot.is_type(ast, ["FLOAT"]))
  let ast = p1("CAST(x AS VARCHAR(5))")
  assert_true(@sqlglot.is_type(ast, ["VARCHAR"]))
  assert_true(@sqlglot.is_type(ast, ["VARCHAR(5)"]))
  assert_false(@sqlglot.is_type(ast, ["VARCHAR(4)"]))
  assert_false(@sqlglot.is_type(ast, ["FLOAT"]))
  let ast = p1("CAST(x AS ARRAY<INT>)")
  assert_true(@sqlglot.is_type(ast, ["ARRAY"]))
  assert_true(@sqlglot.is_type(ast, ["ARRAY<INT>"]))
  assert_false(@sqlglot.is_type(ast, ["ARRAY<FLOAT>"]))
  assert_false(@sqlglot.is_type(ast, ["INT"]))
  let ast = p1("CAST(x AS ARRAY)")
  assert_true(@sqlglot.is_type(ast, ["ARRAY"]))
  assert_false(@sqlglot.is_type(ast, ["ARRAY<INT>"]))
  assert_false(@sqlglot.is_type(ast, ["ARRAY<FLOAT>"]))
  assert_false(@sqlglot.is_type(ast, ["INT"]))
  let ast = p1("CAST(x AS STRUCT<a INT, b FLOAT>)")
  assert_true(@sqlglot.is_type(ast, ["STRUCT"]))
  assert_true(@sqlglot.is_type(ast, ["STRUCT<a INT, b FLOAT>"]))
  assert_false(@sqlglot.is_type(ast, ["STRUCT<a VARCHAR, b INT>"]))
  let dtype = @sqlglot.datatype_build("foo", udt=true)
  assert_true(@sqlglot.datatype_is_type(dtype, ["foo"]))
  assert_false(@sqlglot.datatype_is_type(dtype, ["bar"]))
  let dtype = @sqlglot.datatype_build("a.b.c", udt=true)
  assert_true(@sqlglot.datatype_is_type(dtype, ["a.b.c"]))
  let dtype = @sqlglot.datatype_build("Nullable(Int32)", dialect="clickhouse")
  assert_true(@sqlglot.datatype_is_type(dtype, ["int"]))
  assert_false(@sqlglot.datatype_is_type(dtype, ["int"], check_nullable=true))
  try @sqlglot.datatype_build("foo") catch {
    @core.ParseError(_, _) => ()
    e => fail("unexpected error \{e}")
  } noraise {
    _ => fail("expected ParseError")
  }
}

///|
test "TestExprs.test_set_meta" {
  let query = p1("SELECT * FROM foo /* sqlglot.meta x = 1, y = a, z */")
  let table = query.find([Table]).unwrap()
  let meta = table.get_meta()
  assert_eq(meta.length(), 3)
  assert_true(meta.get("x") is Some(Bool(true)))
  assert_true(meta.get("y") is Some(Str("a")))
  assert_true(meta.get("z") is Some(Bool(true)))
  assert_eq(sql(query), "SELECT * FROM foo /* sqlglot.meta x = 1, y = a, z */")
}

///|
test "TestExprs.test_assert_is" {
  ignore(p1("x").assert_is(Column))
  try p1("x").assert_is(Identifier) catch {
    @core.ValueError(m) =>
      // Python: "x is not <class 'sqlglot.expressions.core.Identifier'>." (the port does
      // not track the Python module of each expression class)
      assert_true(
        m.has_prefix("x is not <class 'sqlglot.expressions.") &&
        m.has_suffix("Identifier'>."),
        msg=m,
      )
    e => fail("unexpected error \{e}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "TestExprs.test_parse_identifier" {
  assert_true(@sqlglot.parse_identifier("a ' b") == ident("a ' b"))
}

///|
fn py_time(h : Int, m : Int, s : Int, us? : Int = 0) -> @core.PyObj {
  PyTime(hour=h, minute=m, second=s, microsecond=us)
}

///|
test "TestExprs.test_convert_datetime_time" {
  // Test converting datetime.time objects to TsOrDsToTime expressions
  let result = @core.convert(py_time(14, 30, 45))
  assert_true(result.kind.is_a(TsOrDsToTime))
  assert_true(result.this_().kind.is_a(Literal))
  assert_eq(sql(result), "CAST('14:30:45' AS TIME)")
  assert_true(result.this_().is_string())
  // Test with microseconds
  let result = @core.convert(py_time(9, 15, 30, us=123456))
  assert_true(result.kind.is_a(TsOrDsToTime))
  assert_eq(sql(result), "CAST('09:15:30.123456' AS TIME)")
  // Test midnight
  let result = @core.convert(py_time(0, 0, 0))
  assert_true(result.kind.is_a(TsOrDsToTime))
  assert_eq(sql(result), "CAST('00:00:00' AS TIME)")
  // Test noon
  let result = @core.convert(py_time(12, 0, 0))
  assert_true(result.kind.is_a(TsOrDsToTime))
  assert_eq(sql(result), "CAST('12:00:00' AS TIME)")
}

///|
test "TestExprs.test_hash_large_ast" {
  let expr = p1("SELECT 1 UNION ALL ".repeat(3000) + "SELECT 1")
  assert_true(expr == expr)
}

///|
test "TestExprs.test_literal_number" {
  // (Python value, its `str()`, whether it is a string)
  let numbers : Array[(@core.PyObj, Bool)] = [
    (@core.PyInt(1), false),
    (@core.PyFloat(-1.1), false),
    (@core.PyFloat(1.1), false),
    (@core.PyInt(0), false),
    (@core.PyStr("-1"), true),
    (@core.PyStr("1"), true),
    (@core.PyStr("1.1"), true),
    (@core.PyStr("-1.1"), true),
    (@core.PyStr("1e6"), true),
    (@core.PyStr("inf"), true),
    (@core.PyStr("binary_double_nan"), true),
  ]
  for case in numbers {
    let (number, is_str) = case
    // `exp.Literal.number(number)` is `Literal(this=str(number), ...)`
    let literal = @core.literal_number(number.py_str())
    assert_true(literal.is_number(), msg=number.py_str())
    let (is_negative, expected_this) = match number {
      PyStr(s) => (s.has_prefix("-"), @core.strip_chars(s, "-"))
      PyInt(i) => (i < 0L, i.abs().to_string())
      PyFloat(d) => (d < 0.0, @core.py_float_repr(d.abs()))
      _ => abort("unexpected")
    }
    ignore(is_str)
    let this = if is_negative {
      assert_true(literal.kind.is_a(Neg))
      assert_true(literal.this_().kind.is_a(Literal))
      literal.this_().text("this")
    } else {
      assert_true(literal.kind.is_a(Literal))
      literal.text("this")
    }
    assert_eq(this, expected_this)
  }
}

///|
test "TestExprs.test_update_positions_empty_meta" {
  let expr1 = @core.mk(Column, [("this", "a")])
  let expr2 = @core.mk(Column, [("this", "b")])
  expr2.get_meta().clear()
  expr1.update_positions(Some(expr2)) |> ignore
  assert_eq(expr1.get_meta().length(), 0)
}

///|
fn add_val(
  expr : @core.Expr,
  val : Int,
  squared~ : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let nb = if squared { val * val } else { val }
  expr.add(nb)
}

///|
test "TestExprs.test_pipe_and_apply" {
  let add_val_alt = fn(val : Int, squared : Bool, expr : @core.Expr) raise {
    add_val(expr, val, squared~)
  }
  let col = @sqlglot.column("age")
  let added = add_val(col, 5, squared=true)
  assert_true(col == col.apply(_ => ()))
  assert_true(col.pipe(e => add_val(e, 5, squared=true)) == added)
  assert_true(col.pipe(e => add_val_alt(5, true, e)) == added)
}
