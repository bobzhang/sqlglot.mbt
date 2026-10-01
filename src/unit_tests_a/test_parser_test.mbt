// Port of tests/test_parser.py

///|
/// `isinstance(e, kind)`
fn isa(e : @core.Expr?, kind : @core.Kind) -> Bool {
  match e {
    Some(e) => e.kind.is_a(kind)
    None => false
  }
}

///|
/// Python `expression.meta` as sorted (key, int) pairs.
fn meta_of(e : @core.Expr?) -> Array[(String, Int)] {
  match e {
    None => []
    Some(e) => {
      let out = []
      for k, v in e.get_meta() {
        match v {
          @core.Int(i) => out.push((k, i.to_int()))
          _ => out.push((k, -999999))
        }
      }
      out.sort_by((a, b) => a.0.compare(b.0))
      out
    }
  }
}

///|
fn sorted_meta(pairs : Array[(String, Int)]) -> Array[(String, Int)] {
  let out = pairs.copy()
  out.sort_by((a, b) => a.0.compare(b.0))
  out
}

///|
/// `e.sql()` for an optional node ("" when missing).
fn gen_opt(e : @core.Expr?) -> String raise {
  match e {
    Some(e) => gen(e)
    None => ""
  }
}

///|
fn po(sql : String, read? : String = "") -> @core.Expr raise {
  @sqlglot.parse_one(sql, read~)
}

///|
test "TestParser.test_parse_empty" {
  let t = t()
  t.raises_parse(() => ignore(po(""))) |> ignore
  t.done()
}

///|
test "TestParser.test_parse_into" {
  let t = t()
  let into = (sql : String, kind : @core.Kind) => {
    isa(Some(@sqlglot.parse_one(sql, into=kind)), kind)
  }
  t.eqf(() => into("(1)", Tuple), true)
  t.eqf(() => into("(1,)", Tuple), true)
  t.eqf(() => into("(x=1)", Tuple), true)
  t.eqf(() => into("((SELECT 42), 1)", Tuple), true)
  t.eqf(() => into("select * from t", Select), true)
  t.eqf(() => into("select * from t limit 5", Select), true)
  t.eqf(() => into("left join foo", Join), true)
  t.eqf(() => into("int", DataType), true)
  t.eqf(() => into("array<int>", DataType), true)
  t.eqf(() => into("foo", Table), true)
  t.eqf(
    () => {
      into(
        "WHEN MATCHED THEN UPDATE SET target.salary = COALESCE(source.salary, target.salary)",
        Whens,
      )
    },
    true,
  )
  let e = t.raises_parse(() => {
    ignore(@sqlglot.parse_one("SELECT * FROM tbl", into=Table))
  })
  t.eq(
    msg_of(e),
    "Failed to parse 'SELECT * FROM tbl' into <class 'sqlglot.expressions.query.Table'>",
  )
  t.eqf(() => into("foo INT NOT NULL", ColumnDef), true)
  t.done()
}

///|
test "TestParser.test_parse_into_error" {
  let t = t()
  let expected_message = "Failed to parse 'SELECT 1;' into [<class 'sqlglot.expressions.query.From'>]"
  let expected_errors = [
    info(
      "Invalid expression / Unexpected token",
      1,
      6,
      "",
      "SELECT",
      " 1;",
      into_expression="From",
    ),
  ].map(info_repr)
  let e = t.raises_parse(() => {
    ignore(@sqlglot.parse_one("SELECT 1;", read="sqlite", into_any=[From]))
  })
  t.eq(msg_of(e), expected_message)
  t.eq(errors_of(e), expected_errors)
  t.done()
}

///|
test "TestParser.test_parse_into_errors" {
  let t = t()
  let expected_message = "Failed to parse 'SELECT 1;' into [<class 'sqlglot.expressions.query.From'>, <class 'sqlglot.expressions.query.Join'>]"
  let expected_errors = [
    info(
      "Invalid expression / Unexpected token",
      1,
      6,
      "",
      "SELECT",
      " 1;",
      into_expression="From",
    ),
    info(
      "Invalid expression / Unexpected token",
      1,
      6,
      "",
      "SELECT",
      " 1;",
      into_expression="Join",
    ),
  ].map(info_repr)
  let e = t.raises_parse(() => {
    ignore(
      @sqlglot.parse_one("SELECT 1;", read="sqlite", into_any=[From, Join]),
    )
  })
  t.eq(msg_of(e), expected_message)
  t.eq(errors_of(e), expected_errors)
  t.done()
}

///|
test "TestParser.test_column" {
  let columns = po("select a, ARRAY[1] b, case when 1 then 1 end").find_all([
    Column,
  ])
  assert_eq(columns.count(), 1)
  assert_true(po("date").find([Column]) is Some(_))
}

///|
test "TestParser.test_no_paren_functions_after_dot" {
  // NO_PAREN_FUNCTIONS (token-type-based): should be identifiers after a dot
  let col = po("SELECT t.current_date FROM t").find([Column]).unwrap()
  assert_eq(col.text("table"), "t")
  assert_eq(col.name(), "current_date")

  // Slow path via :: cast
  let cast = po("SELECT t.current_user::TEXT FROM t", read="postgres")
    .find([Cast])
    .unwrap()
  assert_true(isa(cast.this(), Column))
  assert_eq(cast.this().unwrap().name(), "current_user")
}

///|
test "TestParser.test_text_match_excludes_delimited_tokens" {
  // Tokens whose delimiters are stripped during tokenization (quoted identifiers,
  // heredoc/national strings, etc.) must not be matched as keywords by text.
  // Base-dialect roundtrip cases live in identity.sql; these are the dialect-specific
  // and non-roundtripping ones
  let t = t()
  for
    case in [
      ("postgres", "SELECT TRIM($$leading$$)", "SELECT TRIM('leading')"),
      ("tsql", "SELECT TRIM(N'both')", "SELECT TRIM(N'both')"),
      (
        "postgres", "SELECT TRIM(\"leading\" FROM x)", "SELECT TRIM(\"leading\" FROM x)",
      ),
      (
        "mysql", "INSERT `local` (a) VALUES (1)", "INSERT INTO `local` (a) VALUES (1)",
      ),
      (
        "mysql", "INSERT `directory` (a) VALUES (1)", "INSERT INTO `directory` (a) VALUES (1)",
      ),
      (
        "mysql", "SELECT `high_priority` FROM t", "SELECT `high_priority` FROM t",
      ),
      (
        "postgres", "SELECT * INTO \"unlogged\" FROM t", "SELECT * INTO \"unlogged\" FROM t",
      ),
      (
        "oracle", "SELECT XMLELEMENT(\"name\", x) FROM t", "SELECT XMLELEMENT(NAME \"name\", x) FROM t",
      ),
      (
        "postgres", "SELECT c::INT \"unsigned\" FROM t", "SELECT CAST(c AS INT) AS \"unsigned\" FROM t",
      ),
      (
        "oracle", "SELECT INTERVAL '1' DAY \"to\" FROM t", "SELECT INTERVAL '1' DAY AS \"to\" FROM t",
      ),
      (
        "clickhouse", "CREATE TABLE t (j JSON(`skip` String))", "CREATE TABLE t (j JSON(\"skip\" String))",
      ),
      (
        "clickhouse", "ALTER TABLE t DROP PARTITION \"id\"", "ALTER TABLE t DROP PARTITION \"id\"",
      ),
      ("databricks", "DECLARE `var` INT", "DECLARE `var` INT"),
      (
        "redshift", "ALTER TABLE t ALTER \"sortkey\" TYPE INT", "ALTER TABLE t ALTER COLUMN \"sortkey\" TYPE INTEGER",
      ),
      (
        "duckdb", "ALTER TABLE t ADD \"columns\" INT", "ALTER TABLE t ADD COLUMN \"columns\" INT",
      ),
      (
        "postgres", "ALTER TABLE \"only\" ADD COLUMN x INT", "ALTER TABLE \"only\" ADD COLUMN x INT",
      ),
      (
        "duckdb", "SELECT MAX(\"lambda\") FROM t", "SELECT MAX(\"lambda\") FROM t",
      ),
      (
        "duckdb", "CREATE MACRO m() AS \"return\"", "CREATE MACRO m() AS \"return\"",
      ),
      ("mysql", "ALTER TABLE t RENAME `index`", "ALTER TABLE t RENAME `index`"),
      (
        "mysql", "CREATE TABLE t (x TEXT, FULLTEXT `index` (x))", "CREATE TABLE t (x TEXT, FULLTEXT INDEX `index` (x))",
      ),
      ("mysql", "SHOW CREATE TABLE `json`", "SHOW CREATE TABLE `json`"),
      (
        "snowflake", "WITH \"identifier\" (c) AS (SELECT 1) SELECT c FROM \"identifier\"",
        "WITH \"identifier\"(c) AS (SELECT 1) SELECT c FROM \"identifier\"",
      ),
      (
        "snowflake", "SELECT * FROM t AS \"identifier\"(a, b)", "SELECT * FROM t AS \"identifier\"(a, b)",
      ),
      (
        "bigquery", "SELECT ML.PREDICT(MODEL m, `table`)", "SELECT ML.PREDICT(MODEL m, TABLE `table`)",
      ),
      (
        "spark", "ALTER TABLE t CHANGE COLUMN a `type` INT", "ALTER TABLE t RENAME COLUMN a TO `type`",
      ),
      (
        "exasol", "SELECT JSON_EXTRACT(x, '$.a') \"emits\" FROM t", "SELECT JSON_EXTRACT(x, '$.a') AS \"emits\" FROM t",
      ),
      ("trino", "SELECT U&'abc' \"uescape\"", "SELECT U&'abc' AS \"uescape\""),
      (
        "snowflake", "SELECT * FROM t MATCH_RECOGNIZE(MEASURES \"final\" AS f PATTERN (a) DEFINE a AS TRUE)",
        "SELECT * FROM t MATCH_RECOGNIZE ( MEASURES \"final\" AS f PATTERN (a) DEFINE a AS TRUE)",
      ),
    ] {
    let (dialect, sql, expected) = case
    t.eqf(() => sql_of(sql, read=dialect), expected)
  }
  t.done()
}

///|
test "TestParser.test_tuple" {
  assert_true(isa(Some(po("(a,)")), Tuple))
}

///|
test "TestParser.test_structs" {
  let cast = po("cast(x as struct<int>)")
  assert_true(isa(Some(cast.arg("to").unwrap().expressions()[0]), DataType))
  assert_eq(gen(cast), "CAST(x AS STRUCT<INT>)")
  let cast = po("cast(x as struct<varchar(10)>)")
  assert_true(isa(Some(cast.arg("to").unwrap().expressions()[0]), DataType))
  assert_eq(gen(cast), "CAST(x AS STRUCT<VARCHAR(10)>)")
}

///|
test "TestParser.test_float" {
  let t = t()
  t.eq_expr(po(".2"), po("0.2"))
  t.done()
}

///|
test "TestParser.test_unnest" {
  let unnest_sql = "UNNEST(foo)"
  let expr = po(unnest_sql)
  assert_true(isa(Some(expr), Unnest))
  // assertIsInstance(expr.expressions, list): `expressions()` is an array
  assert_eq(expr.expressions().length(), 1)
  assert_eq(gen(expr), unnest_sql)
}

///|
test "TestParser.test_unnest_projection" {
  let expr = po("SELECT foo IN UNNEST(bla) AS bar")
  assert_true(isa(Some(expr.selects()[0]), Alias))
  assert_eq(expr.selects()[0].output_name(), "bar")
  assert_true(po("select unnest(x)").find([Unnest]) is Some(_))
}

///|
test "TestParser.test_unary_plus" {
  let t = t()
  t.eq_expr(po("+15"), @core.literal_int(15))
  t.done()
}

///|
test "TestParser.test_table" {
  let tables = po("select * from a, b.c, .d")
    .find_all([Table])
    .map(t => gen(t) catch { _ => "<error>" })
    .collect()
  // assertEqual(set(tables), {"a", "b.c", "d"})
  let expected = ["a", "b.c", "d"]
  assert_eq(tables.length(), expected.length())
  for e in expected {
    assert_true(tables.contains(e))
  }
}

///|
test "TestParser.test_union" {
  assert_true(isa(Some(po("SELECT * FROM (SELECT 1) UNION SELECT 2")), Union))
  assert_true(
    isa(Some(po("SELECT x FROM y HAVING x > (SELECT 1) UNION SELECT 2")), Union),
  )

  // Check that modifiers are attached to the topmost union node and not the rightmost query
  let single_union = "SELECT x FROM t1 UNION ALL SELECT x FROM t2 LIMIT 1"
  let expr = po(single_union)
  assert_true(isa(Some(expr), Union))
  assert_true(isa(expr.arg("limit"), Limit))
  assert_eq(gen(expr), single_union)
  let two_unions = "SELECT x FROM t1 UNION ALL SELECT x FROM t2 UNION ALL SELECT x FROM t3 LIMIT 1"
  let expr = po(two_unions)
  assert_true(isa(Some(expr), Union))
  assert_true(isa(expr.arg("limit"), Limit))
  assert_eq(gen(expr), two_unions)
  let expr = po(single_union, read="clickhouse")
  assert_true(expr.arg("limit") is None)
  assert_eq(@sqlglot.generate(expr, dialect="clickhouse"), single_union)
}

///|
test "TestParser.test_mod_precedence" {
  let expression = po("SELECT 10 % 3 / 2").expressions()[0]
  assert_true(isa(Some(expression), Div))
  assert_true(isa(expression.this(), Mod))
  let this = expression.this().unwrap()
  assert_eq(gen_opt(this.this()), "10")
  assert_eq(gen_opt(this.expression()), "3")
  assert_eq(gen_opt(expression.expression()), "2")
}

///|
test "TestParser.test_limit_percent_parses_without_modulo" {
  let expression = po("SELECT * FROM range(1000) LIMIT 1 / 10% OFFSET 5")
  let limit = expression.arg("limit")
  assert_true(limit is Some(_))
  let limit = limit.unwrap()
  assert_eq(gen_opt(limit.expression()), "1 / 10")
  assert_eq(gen_opt(expression.arg("offset").unwrap().expression()), "5")
  assert_true(limit.arg("limit_options").unwrap().bool_arg("percent"))
}

///|
test "TestParser.test_tablesample_percent_parses_without_modulo" {
  let table = po("SELECT * FROM tbl TABLESAMPLE RESERVOIR (20%)")
    .find([Table])
    .unwrap()
  let sample = table.arg("sample")
  assert_true(sample is Some(_))
  let sample = sample.unwrap()
  assert_eq(gen_opt(sample.arg("percent")), "20")
  assert_true(sample.arg("size") is None)
}

///|
test "TestParser.test_select" {
  let t = t()
  t.run(() => po("select 1 natural")) |> ignore
  t.eqf(
    () => po("select * from (select 1) x order by x.y").arg("order") is Some(_),
    true,
  )
  t.eqf(
    () => {
      po("select * from x where a = (select 1) order by x.y").arg("order")
      is Some(_)
    },
    true,
  )
  t.eqf(
    () => po("select * from (select 1) x cross join y").list("joins").length(),
    1,
  )
  t.eqf(
    () => gen(po("SELECT * FROM x CROSS JOIN y, z LATERAL VIEW EXPLODE(y)")),
    "SELECT * FROM x CROSS JOIN y, z LATERAL VIEW EXPLODE(y)",
  )
  t.eqf(
    () => {
      po("create table a as (select b from c) index").find([TableAlias]) is None
    },
    true,
  )
  t.done()
}

///|
test "TestParser.test_command" {
  let t = t()
  @core.take_log_messages() |> ignore
  match
    t.run(() => {
      @sqlglot.parse("SET x = 1; ADD JAR s3://a; SELECT 1", read="hive")
    }) {
    Some(expressions) => {
      t.eq(expressions.length(), 3)
      t.eqf(() => gen_opt(expressions[0]), "SET x = 1")
      t.eqf(() => gen_opt(expressions[1]), "ADD JAR s3://a")
      t.eqf(() => gen_opt(expressions[2]), "SELECT 1")
    }
    None => ()
  }
  let output = logged("WARNING")
  t.ok(
    output.length() > 0 && output[0].contains("'ADD JAR s3://a'"),
    msg="\{output}",
  )
  t.done()
}

///|
test "TestParser.test_grant_revoke_without_privileges" {
  let t = t()
  for
    sql in [
      "GRANT ON TABLE tbl TO bob", "REVOKE ON TABLE tbl FROM bob", "GRANT , SELECT ON TABLE tbl TO bob",
      "GRANT SELECT, ON TABLE tbl TO bob", "GRANT SELECT,,UPDATE ON TABLE tbl TO bob",
    ] {
    let e = t.raises_parse(() => ignore(po(sql)))
    t.ok(msg_of(e).contains("Expected privilege"), msg="\{sql}: \{msg_of(e)}")
  }
  t.done()
}

///|
test "TestParser.test_lambda_struct" {
  let expression = po("FILTER(a.b, x -> x.id = id)")
  let lambda_expr = expression.expression().unwrap()
  assert_true(isa(lambda_expr.this().unwrap().this(), Dot))
  assert_eq(gen(lambda_expr), "x -> x.id = id")
  assert_true(po("FILTER([], x -> x)").find([Column]) is None)
}

///|
test "TestParser.test_transactions" {
  let t = t()
  let modes_of = (e : @core.Expr) => {
    match e.get("modes") {
      Some(@core.List(l)) => Some(l.map(v => v.as_str().unwrap_or("?")))
      _ => None
    }
  }
  let expression = po("BEGIN TRANSACTION")
  t.ok(expression.get("this") is None)
  t.eq(modes_of(expression), Some([]))
  t.eqf(() => gen(expression), "BEGIN")
  let expression = po("START TRANSACTION", read="mysql")
  t.ok(expression.get("this") is None)
  t.eq(modes_of(expression), Some([]))
  t.eqf(() => gen(expression), "BEGIN")
  let expression = po("BEGIN DEFERRED TRANSACTION")
  t.eq(expression.text("this"), "DEFERRED")
  t.eq(modes_of(expression), Some([]))
  t.eqf(() => gen(expression), "BEGIN")
  let expression = po(
    "START TRANSACTION READ WRITE, ISOLATION LEVEL SERIALIZABLE",
    read="presto",
  )
  t.ok(expression.get("this") is None)
  t.eq(
    modes_of(expression),
    Some(["READ WRITE", "ISOLATION LEVEL SERIALIZABLE"]),
  )
  t.eqf(() => gen(expression), "BEGIN READ WRITE, ISOLATION LEVEL SERIALIZABLE")
  let expression = po("BEGIN", read="bigquery")
  t.ok(!isa(Some(expression), Transaction))
  t.ok(expression.expression() is None)
  t.eqf(() => gen(expression), "BEGIN")
  t.done()
}

///|
test "TestParser.test_identify" {
  let expression = po(
    (
      #|
      #|            SELECT a, "b", c AS c, d AS "D", e AS "y|z'"
      #|            FROM y."z"
      #|
    ),
  )
  let exprs = expression.expressions()
  assert_eq(exprs[0].name(), "a")
  assert_eq(exprs[1].name(), "b")
  assert_eq(exprs[2].alias_(), "c")
  assert_eq(exprs[3].alias_(), "D")
  assert_eq(exprs[4].alias_(), "y|z'")
  let table = expression.arg("from_").unwrap().this().unwrap()
  assert_eq(table.name(), "z")
  assert_eq(table.arg("db").unwrap().name(), "y")
}

///|
test "TestParser.test_multi" {
  let expressions = @sqlglot.parse(
    (
      #|
      #|            SELECT * FROM a; SELECT * FROM b;
      #|
    ),
  )
  assert_eq(expressions.length(), 2)
  assert_eq(expressions[0].unwrap().arg("from_").unwrap().name(), "a")
  assert_eq(expressions[1].unwrap().arg("from_").unwrap().name(), "b")
  let expressions = @sqlglot.parse("SELECT 1; ; SELECT 2")
  assert_eq(expressions.length(), 3)
  assert_true(expressions[1] is None)
}

///|
test "TestParser.test_expression" {
  let t = t()
  let base = @core.base_dialect()
  let ignore_ = @core.Parser::new(base, error_level=Ignore)
  t.eqf(
    () => {
      isa(
        Some(
          ignore_.expression(
            @core.mk(Hint, [("expressions", ([] : Array[@core.Expr]))]),
          ),
        ),
        Hint,
      )
    },
    true,
  )
  t.eqf(
    () => isa(Some(ignore_.expression(@core.mk(Hint, [("y", "")]))), Hint),
    true,
  )
  t.eqf(() => isa(Some(ignore_.expression(@core.mk0(Hint))), Hint), true)
  let default = @core.Parser::new(base, error_level=Raise)
  // SKIP: `with self.assertRaises(TypeError): default.expression(exp.Hint(y=""))` --
  // unknown-keyword TypeErrors are a Python UNITTEST-mode-only check.
  t.eqf(
    () => {
      isa(
        Some(
          default.expression(
            @core.mk(Hint, [("expressions", ([] : Array[@core.Expr]))]),
          ),
        ),
        Hint,
      )
    },
    true,
  )
  t.run(() => ignore(default.expression(@core.mk0(Hint)))) |> ignore
  t.eq(default.errors.length(), 2)
  let warn = @core.Parser::new(base, error_level=Warn)
  t.run(() => ignore(warn.expression(@core.mk0(Hint)))) |> ignore
  t.eq(warn.errors.length(), 1)
  t.done()
}

///|
test "TestParser.test_parse_errors" {
  let t = t()
  t.raises_parse(() => ignore(po("IF(a > 0, a, b, c)"))) |> ignore
  t.raises_parse(() => ignore(po("IF(a > 0)"))) |> ignore
  t.raises_parse(() => ignore(po("SELECT CASE FROM x"))) |> ignore
  t.raises_parse(() => ignore(po("WITH cte AS (SELECT * FROM x)"))) |> ignore
  t.raises_parse(() => ignore(po("SELECT foo( FROM bar"))) |> ignore
  t.eqf(
    () => {
      @sqlglot.generate(
        @sqlglot.parse_one(
          "CREATE TABLE t (i UInt8) ENGINE = AggregatingMergeTree() ORDER BY tuple()",
          read="clickhouse",
          error_level=Raise,
        ),
        dialect="clickhouse",
      )
    },
    "CREATE TABLE t (i UInt8) ENGINE=AggregatingMergeTree() ORDER BY tuple()",
  )
  t.raises_parse(() => ignore(po("SELECT A[:"))) |> ignore

  // Truncated input must produce a ParseError, not an AttributeError
  t.raises_parse(() => {
    ignore(
      po(
        "SELECT * FROM t MATCH_RECOGNIZE(AFTER MATCH SKIP TO FIRST",
        read="snowflake",
      ),
    )
  })
  |> ignore
  t.raises_parse(() => {
    ignore(
      po(
        "SELECT * FROM t MATCH_RECOGNIZE(AFTER MATCH SKIP TO LAST",
        read="snowflake",
      ),
    )
  })
  |> ignore
  t.eqf(() => gen(@sqlglot.parse_one("as as", error_level=Ignore)), "AS as")
  t.done()
}

///|
test "TestParser.test_space" {
  let t = t()
  t.eqf(
    () => gen(po("SELECT ROW() OVER(PARTITION  BY x) FROM x GROUP  BY y")),
    "SELECT ROW() OVER (PARTITION BY x) FROM x GROUP BY y",
  )
  t.eqf(
    () => {
      gen(
        po(
          (
            #|SELECT   * FROM x GROUP
            #|                BY y
          ),
        ),
      )
    },
    "SELECT * FROM x GROUP BY y",
  )
  t.done()
}

///|
test "TestParser.test_missing_by" {
  let t = t()
  t.raises_parse(() => ignore(po("SELECT FROM x ORDER BY"))) |> ignore
  t.done()
}

///|
test "TestParser.test_parameter" {
  assert_eq(gen(po("SELECT @x, @@x, @1")), "SELECT @x, @@x, @1")
}

///|
test "TestParser.test_var" {
  assert_true(isa(po("INTERVAL '1' DAY").arg("unit"), Var))
  assert_eq(gen(po("SELECT @JOIN, @'foo'")), "SELECT @JOIN, @'foo'")
}

///|
test "TestParser.test_comments_select" {
  let t = t()
  let expression = po(
    (
      #|
      #|            --comment1.1
      #|            --comment1.2
      #|            SELECT /*comment1.3*/
      #|                a, --comment2
      #|                b as B, --comment3:testing
      #|                "test--annotation",
      #|                c, --comment4 --foo
      #|                e, --
      #|                f -- space
      #|            FROM foo
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment1.1", "comment1.2", "comment1.3"]))
  let exprs = expression.expressions()
  t.eq(exprs[0].comments, Some(["comment2"]))
  t.eq(exprs[1].comments, Some(["comment3:testing"]))
  t.eq(exprs[2].comments, None)
  t.eq(exprs[3].comments, Some(["comment4 --foo"]))
  t.eq(exprs[4].comments, Some([""]))
  t.eq(exprs[5].comments, Some([" space"]))
  let expression = po(
    (
      #|
      #|            SELECT a.column_name --# Comment 1
      #|                   ,b.column_name2, --# Comment 2
      #|                   b.column_name3 AS NAME3 --# Comment 3
      #|            FROM table_name a
      #|            JOIN table_name2 b ON a.column_name = b.column_name
      #|
    ),
  )
  let exprs = expression.expressions()
  t.eq(exprs[0].comments, Some(["# Comment 1"]))
  t.eq(exprs[1].comments, Some(["# Comment 2"]))
  t.eq(exprs[2].comments, Some(["# Comment 3"]))
  t.done()
}

///|
test "TestParser.test_comments_select_cte" {
  let t = t()
  let expression = po(
    (
      #|
      #|            /*comment1.1*/
      #|            /*comment1.2*/
      #|            WITH a AS (SELECT 1)
      #|            SELECT /*comment2*/
      #|                a.*
      #|            FROM /*comment3*/
      #|                a
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment2"]))
  t.eq(expression.arg("from_").unwrap().comments, Some(["comment3"]))
  t.eq(
    expression.arg("with_").unwrap().comments,
    Some(["comment1.1", "comment1.2"]),
  )
  t.done()
}

///|
test "TestParser.test_comments_insert" {
  let t = t()
  let expression = po(
    (
      #|
      #|            --comment1.1
      #|            --comment1.2
      #|            INSERT INTO /*comment1.3*/
      #|                x       /*comment2*/
      #|            VALUES      /*comment3*/
      #|                (1, 'a', 2.0)
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment1.1", "comment1.2", "comment1.3"]))
  t.eq(expression.this().unwrap().comments, Some(["comment2"]))
  t.done()
}

///|
test "TestParser.test_comments_insert_cte" {
  let t = t()
  let expression = po(
    (
      #|
      #|            /*comment1.1*/
      #|            /*comment1.2*/
      #|            WITH a AS (SELECT 1)
      #|            INSERT INTO /*comment2*/
      #|                b /*comment3*/
      #|            SELECT * FROM a
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment2"]))
  t.eq(expression.this().unwrap().comments, Some(["comment3"]))
  t.eq(
    expression.arg("with_").unwrap().comments,
    Some(["comment1.1", "comment1.2"]),
  )
  t.done()
}

///|
test "TestParser.test_update_assignment" {
  let t = t()
  for
    sql in [
      "UPDATE t SET a = t.b = t.c OR t.d AND t.e", "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = t.b = t.c OR t.d AND t.e",
      "INSERT INTO t (id) VALUES (1) ON CONFLICT(id) DO UPDATE SET a = t.b = t.c OR t.d AND t.e",
      "INSERT INTO t (id) VALUES (1) ON DUPLICATE KEY UPDATE a = t.b = t.c OR t.d AND t.e",
    ] {
    match t.run(() => po(sql).find([Update, OnConflict])) {
      Some(Some(update)) => {
        let assignment = update.expressions()[0]
        t.ok(isa(Some(assignment), EQ), msg=sql)
        t.eq_expr(assignment.this().unwrap(), @core.column_of("a"))
        match t.run(() => po("t.b = t.c OR t.d AND t.e")) {
          Some(e) => t.eq_expr(assignment.expression().unwrap(), e)
          None => ()
        }
      }
      Some(None) => t.ok(false, msg="\{sql}: no Update/OnConflict found")
      None => ()
    }
  }
  t.done()
}

///|
test "TestParser.test_comments_update" {
  let t = t()
  let expression = po(
    (
      #|
      #|            --comment1.1
      #|            --comment1.2
      #|            UPDATE  /*comment1.3*/
      #|                tbl /*comment2*/
      #|            SET     /*comment3*/
      #|                x = 2
      #|            WHERE /*comment4*/
      #|                x <> 2
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment1.1", "comment1.2", "comment1.3"]))
  t.eq(expression.this().unwrap().comments, Some(["comment2"]))
  t.eq(expression.arg("where").unwrap().comments, Some(["comment4"]))
  t.done()
}

///|
test "TestParser.test_comments_update_cte" {
  let t = t()
  let expression = po(
    (
      #|
      #|            /*comment1.1*/
      #|            /*comment1.2*/
      #|            WITH a AS (SELECT * FROM b)
      #|            UPDATE /*comment2*/
      #|                a  /*comment3*/
      #|            SET col = 1
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment2"]))
  t.eq(expression.this().unwrap().comments, Some(["comment3"]))
  t.eq(
    expression.arg("with_").unwrap().comments,
    Some(["comment1.1", "comment1.2"]),
  )
  t.done()
}

///|
test "TestParser.test_comments_delete" {
  let t = t()
  let expression = po(
    (
      #|
      #|            --comment1.1
      #|            --comment1.2
      #|            DELETE /*comment1.3*/
      #|            FROM   /*comment2*/
      #|                x  /*comment3*/
      #|            WHERE  /*comment4*/
      #|                y > 1
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment1.1", "comment1.2", "comment1.3"]))
  t.eq(expression.this().unwrap().comments, Some(["comment3"]))
  t.eq(expression.arg("where").unwrap().comments, Some(["comment4"]))
  t.done()
}

///|
test "TestParser.test_comments_delete_cte" {
  let t = t()
  let expression = po(
    (
      #|
      #|            /*comment1.1*/
      #|            /*comment1.2*/
      #|            WITH a AS (SELECT * FROM b)
      #|            --comment2
      #|            DELETE FROM a /*comment3*/
      #|
    ),
  )
  t.eq(expression.comments, Some(["comment2"]))
  t.eq(expression.this().unwrap().comments, Some(["comment3"]))
  t.eq(
    expression.arg("with_").unwrap().comments,
    Some(["comment1.1", "comment1.2"]),
  )
  t.done()
}

///|
test "TestParser.test_type_literals" {
  let t = t()
  t.eq_expr(po("int 1"), po("CAST(1 AS INT)"))
  t.eq_expr(po("int.5"), po("CAST(0.5 AS INT)"))
  t.eqf(
    () => gen(po("TIMESTAMP '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMP)",
  )
  t.eqf(
    () => gen(po("TIMESTAMP(1) '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMP(1))",
  )
  t.eqf(
    () => gen(po("TIMESTAMP WITH TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMPTZ)",
  )
  t.eqf(
    () => gen(po("TIMESTAMP WITH LOCAL TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMPLTZ)",
  )
  t.eqf(
    () => gen(po("TIMESTAMP WITHOUT TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMP)",
  )
  t.eqf(
    () => gen(po("TIMESTAMP(1) WITH TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMPTZ(1))",
  )
  t.eqf(
    () => gen(po("TIMESTAMP(1) WITH LOCAL TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMPLTZ(1))",
  )
  t.eqf(
    () => gen(po("TIMESTAMP(1) WITHOUT TIME ZONE '2022-01-01'")),
    "CAST('2022-01-01' AS TIMESTAMP(1))",
  )
  t.eqf(() => gen(po("TIMESTAMP(1) WITH TIME ZONE")), "TIMESTAMPTZ(1)")
  t.eqf(() => gen(po("TIMESTAMP(1) WITH LOCAL TIME ZONE")), "TIMESTAMPLTZ(1)")
  t.eqf(() => gen(po("TIMESTAMP(1) WITHOUT TIME ZONE")), "TIMESTAMP(1)")
  t.eqf(() => gen(po("JSON '{\"x\":\"y\"}'")), "PARSE_JSON('{\"x\":\"y\"}')")
  t.eqf(() => isa(Some(po("TIMESTAMP(1)")), Func), true)
  t.eqf(() => isa(Some(po("TIMESTAMP('2022-01-01')")), Func), true)
  t.eqf(() => isa(Some(po("TIMESTAMP()")), Func), true)
  t.eqf(() => isa(Some(po("map.x")), Column), true)
  t.eqf(
    () => {
      isa(
        Some(po("CAST(x AS CHAR(5))").arg("to").unwrap().expressions()[0]),
        DataTypeParam,
      )
    },
    true,
  )
  t.eq_expr(po("1::int64", read="bigquery"), po("CAST(1 AS BIGINT)"))
  t.done()
}

///|
test "TestParser.test_set_expression" {
  let t = t()
  let set_ = po("SET")
  t.eqf(() => gen(set_), "SET")
  t.ok(isa(Some(set_), Set))
  let set_session = po("SET SESSION x = 1")
  t.eqf(() => gen(set_session), "SET SESSION x = 1")
  t.ok(isa(Some(set_session), Set))
  let set_item = set_session.expressions()[0]
  t.ok(isa(Some(set_item), SetItem))
  t.ok(isa(set_item.this(), EQ))
  t.ok(isa(set_item.this().unwrap().this(), Column))
  t.ok(isa(set_item.this().unwrap().expression(), Literal))
  t.eq(set_item.get("kind").map(v => v.as_str()), Some(Some("SESSION")))
  let set_to = po("SET x TO 1")
  t.eqf(() => gen(set_to), "SET x = 1")
  t.ok(isa(Some(set_to), Set))
  @core.take_log_messages() |> ignore
  let set_as_command = po("SET DEFAULT ROLE ALL TO USER")
  let output = logged("WARNING")
  t.ok(
    output.length() > 0 && output[0].contains("'SET DEFAULT ROLE ALL TO USER'"),
    msg="\{output}",
  )
  t.eqf(() => gen(set_as_command), "SET DEFAULT ROLE ALL TO USER")
  t.ok(isa(Some(set_as_command), Command))
  t.eq(set_as_command.text("this"), "SET")
  t.eq(set_as_command.text("expression"), " DEFAULT ROLE ALL TO USER")
  t.done()
}

///|
test "TestParser.test_pretty_config_override" {
  let t = t()
  t.eqf(() => gen(po("SELECT col FROM x")), "SELECT col FROM x")
  // with patch("sqlglot.pretty", True)
  @core.default_pretty.val = true
  t.eqf(() => gen(po("SELECT col FROM x")), "SELECT\n  col\nFROM x")
  @core.default_pretty.val = false
  t.eqf(
    () => @sqlglot.generate(po("SELECT col FROM x"), pretty=true),
    "SELECT\n  col\nFROM x",
  )
  t.done()
}

///|
test "TestParser.test_comment_error_n" {
  let t = t()
  @core.take_log_messages() |> ignore
  t.run(() => {
    ignore(
      @sqlglot.parse_one(
        (
          #|SUM
          #|(
          #|-- test
          #|)
        ),
        error_level=Warn,
      ),
    )
  })
  |> ignore
  let output = logged("ERROR").join("\n")
  let message = "Required keyword: 'this' missing for <class 'sqlglot.expressions.aggregate.Sum'>. Line 4, Col: 1."
  t.ok(output.contains(message), msg="Expected '\{message}' not in \{output}")
  t.done()
}

///|
test "TestParser.test_comment_error_r" {
  let t = t()
  @core.take_log_messages() |> ignore
  t.run(() => ignore(@sqlglot.parse_one("SUM(-- test\r)", error_level=Warn)))
  |> ignore
  let output = logged("ERROR").join("\n")
  let message = "Required keyword: 'this' missing for <class 'sqlglot.expressions.aggregate.Sum'>. Line 2, Col: 1."
  t.ok(output.contains(message), msg="Expected '\{message}' not in \{output}")
  t.done()
}

///|
test "TestParser.test_create_table_error" {
  let t = t()
  @core.take_log_messages() |> ignore
  t.run(() => {
    ignore(@sqlglot.parse_one("CREATE TABLE SELECT", error_level=Warn))
  })
  |> ignore
  let output = logged("ERROR").join("\n")
  t.ok(
    output.contains("Expected table name"),
    msg="Expected 'Expected table name' not in \{output}",
  )
  t.done()
}

///|
test "TestParser.test_pivot_columns" {
  let nothing_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price FROM part
    #|            ) PIVOT (AVG(price) FOR partname IN ('prop', 'rudder'))
    #|
  let everything_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price FROM part
    #|            ) PIVOT (AVG(price) AS avg_price FOR partname IN ('prop' AS prop1, 'rudder' AS rudder1))
    #|
  let only_pivot_columns_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price FROM part
    #|            ) PIVOT (AVG(price) FOR partname IN ('prop' AS prop1, 'rudder' AS rudder1))
    #|
  let columns_partially_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price FROM part
    #|            ) PIVOT (AVG(price) FOR partname IN ('prop' AS prop1, 'rudder'))
    #|
  let multiple_aggregates_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price, quality FROM part
    #|            ) PIVOT (AVG(price) AS p, MAX(quality) AS q FOR partname IN ('prop' AS prop1, 'rudder'))
    #|
  let multiple_aggregates_not_aliased =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price, quality FROM part
    #|            ) PIVOT (AVG(price), MAX(quality) FOR partname IN ('prop' AS prop1, 'rudder'))
    #|
  let multiple_aggregates_not_aliased_with_quoted_identifier_spark =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price, quality FROM part
    #|            ) PIVOT (AVG(`PrIcE`), MAX(quality) FOR partname IN ('prop' AS prop1, 'rudder'))
    #|
  let multiple_aggregates_not_aliased_with_quoted_identifier_duckdb =
    #|
    #|            SELECT * FROM (
    #|                SELECT partname, price, quality FROM part
    #|            ) PIVOT (AVG("PrIcE"), MAX(quality) FOR partname IN ('prop' AS prop1, 'rudder'))
    #|
  let two_in_clauses_duckdb =
    #|
    #|            SELECT * FROM cities PIVOT (
    #|                sum(population) AS total,
    #|                count(population) AS count
    #|                FOR
    #|                    year IN (2000, 2010)
    #|                    country IN ('NL', 'US')
    #|            )
    #|
  let three_in_clauses_duckdb =
    #|
    #|            SELECT * FROM cities PIVOT (
    #|                sum(population) AS total,
    #|                count(population) AS count
    #|                FOR
    #|                    year IN (2000, 2010)
    #|                    country IN ('NL', 'US')
    #|                    name IN ('Amsterdam', 'Seattle')
    #|            )
    #|
  let query_to_column_names : Array[(String, Array[(String, Array[String])])] = [
    (
      nothing_aliased,
      [
        ("bigquery", ["prop", "rudder"]),
        ("duckdb", ["prop", "rudder"]),
        ("redshift", ["prop", "rudder"]),
        ("snowflake", ["\"'prop'\"", "\"'rudder'\""]),
        ("spark", ["prop", "rudder"]),
      ],
    ),
    (
      everything_aliased,
      [
        ("bigquery", ["avg_price_prop1", "avg_price_rudder1"]),
        ("duckdb", ["prop1_avg_price", "rudder1_avg_price"]),
        ("redshift", ["prop1_avg_price", "rudder1_avg_price"]),
        ("spark", ["prop1", "rudder1"]),
      ],
    ),
    (
      only_pivot_columns_aliased,
      [
        ("bigquery", ["prop1", "rudder1"]),
        ("duckdb", ["prop1", "rudder1"]),
        ("redshift", ["prop1", "rudder1"]),
        ("spark", ["prop1", "rudder1"]),
      ],
    ),
    (
      columns_partially_aliased,
      [
        ("bigquery", ["prop1", "rudder"]),
        ("duckdb", ["prop1", "rudder"]),
        ("redshift", ["prop1", "rudder"]),
        ("spark", ["prop1", "rudder"]),
      ],
    ),
    (
      multiple_aggregates_aliased,
      [
        ("bigquery", ["p_prop1", "q_prop1", "p_rudder", "q_rudder"]),
        ("duckdb", ["prop1_p", "prop1_q", "rudder_p", "rudder_q"]),
        ("spark", ["prop1_p", "prop1_q", "rudder_p", "rudder_q"]),
      ],
    ),
    (
      multiple_aggregates_not_aliased,
      [
        (
          "duckdb",
          [
            "\"prop1_avg(price)\"", "\"prop1_max(quality)\"", "\"rudder_avg(price)\"",
            "\"rudder_max(quality)\"",
          ],
        ),
        (
          "spark",
          [
            "`prop1_avg(price)`", "`prop1_max(quality)`", "`rudder_avg(price)`",
            "`rudder_max(quality)`",
          ],
        ),
      ],
    ),
    (
      multiple_aggregates_not_aliased_with_quoted_identifier_spark,
      [
        (
          "spark",
          [
            "`prop1_avg(PrIcE)`", "`prop1_max(quality)`", "`rudder_avg(PrIcE)`",
            "`rudder_max(quality)`",
          ],
        ),
      ],
    ),
    (
      multiple_aggregates_not_aliased_with_quoted_identifier_duckdb,
      [
        (
          "duckdb",
          [
            "\"prop1_avg(PrIcE)\"", "\"prop1_max(quality)\"", "\"rudder_avg(PrIcE)\"",
            "\"rudder_max(quality)\"",
          ],
        ),
      ],
    ),
    (
      two_in_clauses_duckdb,
      [
        (
          "duckdb",
          [
            "\"2000_NL_total\"", "\"2000_NL_count\"", "\"2000_US_total\"", "\"2000_US_count\"",
            "\"2010_NL_total\"", "\"2010_NL_count\"", "\"2010_US_total\"", "\"2010_US_count\"",
          ],
        ),
      ],
    ),
    (
      three_in_clauses_duckdb,
      [
        (
          "duckdb",
          [
            "\"2000_NL_Amsterdam_total\"", "\"2000_NL_Amsterdam_count\"", "\"2000_NL_Seattle_total\"",
            "\"2000_NL_Seattle_count\"", "\"2000_US_Amsterdam_total\"", "\"2000_US_Amsterdam_count\"",
            "\"2000_US_Seattle_total\"", "\"2000_US_Seattle_count\"", "\"2010_NL_Amsterdam_total\"",
            "\"2010_NL_Amsterdam_count\"", "\"2010_NL_Seattle_total\"", "\"2010_NL_Seattle_count\"",
            "\"2010_US_Amsterdam_total\"", "\"2010_US_Amsterdam_count\"", "\"2010_US_Seattle_total\"",
            "\"2010_US_Seattle_count\"",
          ],
        ),
      ],
    ),
  ]
  let t = t()
  for qc in query_to_column_names {
    let (query, dialect_columns) = qc
    for dc in dialect_columns {
      let (dialect, expected_columns) = dc
      t.eqf(
        () => {
          let expr = po(query, read=dialect)
          let columns = expr
          .arg("from_")
          .unwrap()
          .this()
          .unwrap()
          .list("pivots")[0].list("columns")
          columns.map(col => @sqlglot.generate(col, dialect~))
        },
        expected_columns,
      )
    }
  }
  t.done()
}

///|
test "TestParser.test_parse_nested" {
  // Python logs a warning when a query takes longer than 0.2s to parse; here we
  // only check that the deeply nested queries parse.
  let t = t()
  let warn_over_threshold = (query : String) => {
    t.ok(t.run(() => po(query)) is Some(_))
  }
  warn_over_threshold(
    "SELECT * FROM a " + "LEFT JOIN b ON a.id = b.id ".repeat(38),
  )
  warn_over_threshold(
    "SELECT * FROM a " + "LEFT JOIN UNNEST(ARRAY[]) ".repeat(15),
  )
  warn_over_threshold(
    "SELECT * FROM a " + "OUTER APPLY (SELECT * FROM b) ".repeat(30),
  )
  warn_over_threshold(
    "SELECT * FROM a " + "NATURAL FULL OUTER JOIN x ".repeat(30),
  )
  t.done()
}

///|
test "TestParser.test_parse_properties" {
  assert_eq(
    gen(po("create materialized table x")),
    "CREATE MATERIALIZED TABLE x",
  )
}

///|
test "TestParser.test_parse_floats" {
  assert_true(po("1. ").is_number())
}

///|
test "TestParser.test_parse_terse_coalesce" {
  assert_true(po("SELECT x ?? y FROM z").find([Coalesce]) is Some(_))
  assert_eq(
    gen(po("SELECT a, b ?? 'No Data' FROM z")),
    "SELECT a, COALESCE(b, 'No Data') FROM z",
  )
  assert_eq(
    gen(po("SELECT a, b ?? c ?? 'No Data' FROM z")),
    "SELECT a, COALESCE(COALESCE(b, c), 'No Data') FROM z",
  )
}

///|
test "TestParser.test_parse_intervals" {
  let ast = po(
    "SELECT a FROM tbl WHERE a <= DATE '1998-12-01' - INTERVAL '71 days' GROUP BY b",
  )
  let interval = ast.find([Interval]).unwrap()
  assert_eq(gen_opt(interval.this()), "'71'")
  assert_true(isa(interval.arg("unit"), Var))
  assert_eq(gen_opt(interval.arg("unit")), "DAYS")
}

///|
test "TestParser.test_parse_concat_ws" {
  let ast = po("CONCAT_WS(' ', 'John', 'Doe')")
  assert_eq(gen(ast), "CONCAT_WS(' ', 'John', 'Doe')")
  assert_eq(gen(ast.expressions()[0]), "' '")
  assert_eq(gen(ast.expressions()[1]), "'John'")
  assert_eq(gen(ast.expressions()[2]), "'Doe'")

  // Ensure we can parse without argument when error level is ignore
  let ast = @sqlglot.parse("CONCAT_WS()", error_level=Ignore)
  assert_eq(gen_opt(ast[0]), "CONCAT_WS()")
}

///|
fn ident(name : String) -> @core.Expr {
  @core.mk(Identifier, [("this", name), ("quoted", false)])
}

///|
test "TestParser.test_parse_drop_schema" {
  let t = t()
  for dialect in ["", "bigquery", "snowflake", "duckdb"] {
    match t.run(() => po("DROP SCHEMA catalog.schema", read=dialect)) {
      Some(ast) => {
        t.eq_expr(
          ast,
          @core.mk(Drop, [
            (
              "tables",
              [
                @core.mk(Table, [
                  ("this", (None : @core.Expr?)),
                  ("db", ident("schema")),
                  ("catalog", ident("catalog")),
                ]),
              ],
            ),
            ("kind", "SCHEMA"),
          ]),
        )
        t.eqf(
          () => @sqlglot.generate(ast, dialect~),
          "DROP SCHEMA catalog.schema",
        )
      }
      None => ()
    }
  }

  // when there is IF EXISTS it must not displace catalog mapping
  for dialect in ["", "bigquery", "snowflake", "duckdb"] {
    match
      t.run(() => po("DROP SCHEMA IF EXISTS catalog.schema", read=dialect)) {
      Some(ast) => {
        t.eq_expr(
          ast,
          @core.mk(Drop, [
            (
              "tables",
              [
                @core.mk(Table, [
                  ("this", (None : @core.Expr?)),
                  ("db", ident("schema")),
                  ("catalog", ident("catalog")),
                ]),
              ],
            ),
            ("kind", "SCHEMA"),
            ("exists", true),
          ]),
        )
        t.eqf(
          () => @sqlglot.generate(ast, dialect~),
          "DROP SCHEMA IF EXISTS catalog.schema",
        )
      }
      None => ()
    }
  }

  // single part name no catalog and schema name in db
  for dialect in ["", "bigquery", "snowflake", "duckdb"] {
    match t.run(() => po("DROP SCHEMA IF EXISTS myschema", read=dialect)) {
      Some(ast) => {
        t.eq_expr(
          ast,
          @core.mk(Drop, [
            (
              "tables",
              [
                @core.mk(Table, [
                  ("this", (None : @core.Expr?)),
                  ("db", ident("myschema")),
                ]),
              ],
            ),
            ("kind", "SCHEMA"),
            ("exists", true),
          ]),
        )
        t.eqf(() => gen(ast), "DROP SCHEMA IF EXISTS myschema")
      }
      None => ()
    }
  }
  t.done()
}

///|
test "TestParser.test_parse_create_schema" {
  let t = t()
  for dialect in ["", "bigquery", "snowflake"] {
    match t.run(() => po("CREATE SCHEMA catalog.schema", read=dialect)) {
      Some(ast) => {
        t.eq_expr(
          ast,
          @core.mk(Create, [
            (
              "this",
              @core.mk(Table, [
                ("this", (None : @core.Expr?)),
                ("db", ident("schema")),
                ("catalog", ident("catalog")),
              ]),
            ),
            ("kind", "SCHEMA"),
          ]),
        )
        t.eqf(
          () => @sqlglot.generate(ast, dialect~),
          "CREATE SCHEMA catalog.schema",
        )
      }
      None => ()
    }
  }
  t.done()
}

///|
test "TestParser.test_values_as_identifier" {
  let t = t()
  let sql = "SELECT values FROM t WHERE values + 1 > x"
  for
    dialect in [
      "bigquery", "clickhouse", "duckdb", "postgres", "redshift", "snowflake",
    ] {
    t.eqf(() => sql_of(sql, read=dialect), sql)
  }
  t.done()
}

///|
test "TestParser.test_alter_set" {
  let t = t()
  let sqls = [
    "ALTER TABLE tbl SET TBLPROPERTIES ('x'='1', 'Z'='2')", "ALTER TABLE tbl SET SERDE 'test' WITH SERDEPROPERTIES ('k'='v', 'kay'='vee')",
    "ALTER TABLE tbl SET SERDEPROPERTIES ('k'='v', 'kay'='vee')", "ALTER TABLE tbl SET LOCATION 'new_location'",
    "ALTER TABLE tbl SET FILEFORMAT file_format", "ALTER TABLE tbl SET TAGS ('tag1' = 't1', 'tag2' = 't2')",
  ]
  for dialect in ["hive", "spark2", "spark", "databricks"] {
    for sql in sqls {
      t.eqf(() => sql_of(sql, read=dialect), sql)
    }
  }
  t.done()
}

///|
test "TestParser.test_distinct_from" {
  assert_true(isa(Some(po("a IS DISTINCT FROM b OR c IS DISTINCT FROM d")), Or))
}

///|
test "TestParser.test_trailing_comments" {
  let expressions = @sqlglot.parse(
    (
      #|
      #|        select * from x;
      #|        -- my comment
      #|
    ),
  )
  assert_eq(
    expressions.map(e => gen_opt(e) catch { _ => "<error>" }).join(";\n"),
    "SELECT * FROM x;\n/* my comment */",
  )
}

///|
test "TestParser.test_parse_prop_eq" {
  assert_true(isa(Some(po("x(a := b and c)").expressions()[0]), PropertyEQ))
}

///|
test "TestParser.test_collate" {
  let collates : Array[(String, @core.Kind)] = [
    ("pg_catalog.\"default\"", Column),
    ("\"en_DE\"", Identifier),
    ("LATIN1_GENERAL_BIN", Var),
    ("'en'", Literal),
  ]
  for collate_pair in collates {
    let collate_node = po(
      "SELECT * FROM t WHERE foo LIKE '%bar%' COLLATE \{collate_pair.0}",
    ).find([Collate])
    assert_true(isa(collate_node, Collate))
    assert_true(isa(collate_node.unwrap().expression(), collate_pair.1))
  }
}

///|
test "TestParser.test_drop_column" {
  let ast = po("ALTER TABLE tbl DROP COLUMN col")
  assert_eq(ast.find_all([Table]).count(), 1)
  assert_eq(ast.find_all([Column]).count(), 1)
}

///|
test "TestParser.test_udf_meta" {
  let ast = po("YEAR(a) /* sqlglot.anonymous */")
  assert_true(isa(Some(ast), Anonymous))

  // Meta flag is case sensitive
  let ast = po("YEAR(a) /* sqlglot.anONymous */")
  assert_true(isa(Some(ast), Year))

  // Incomplete or incorrect anonymous meta comments are not registered
  let ast = po("YEAR(a) /* sqlglot.anon */")
  assert_true(isa(Some(ast), Year))
}

///|
test "TestParser.test_token_position_meta" {
  let t = t()
  let ast = po(
    "SELECT a, b FROM test_schema.test_table_a UNION ALL SELECT c, d FROM test_catalog.test_schema.test_table_b",
  )
  for identifier in ast.find_all([Identifier]) {
    t.eq(meta_of(Some(identifier)).map(kv => kv.0), [
      "col", "end", "line", "start",
    ])
  }
  let left_table = ast.this().unwrap().arg("from_").unwrap().this().unwrap()
  t.eq(
    meta_of(left_table.arg("this")),
    sorted_meta([("line", 1), ("col", 41), ("start", 29), ("end", 40)]),
  )
  t.eq(
    meta_of(left_table.arg("db")),
    sorted_meta([("line", 1), ("col", 28), ("start", 17), ("end", 27)]),
  )
  let right_table = ast
    .expression()
    .unwrap()
    .arg("from_")
    .unwrap()
    .this()
    .unwrap()
  t.eq(
    meta_of(right_table.arg("this")),
    sorted_meta([("line", 1), ("col", 106), ("start", 94), ("end", 105)]),
  )
  t.eq(
    meta_of(right_table.arg("db")),
    sorted_meta([("line", 1), ("col", 93), ("start", 82), ("end", 92)]),
  )
  t.eq(
    meta_of(right_table.arg("catalog")),
    sorted_meta([("line", 1), ("col", 81), ("start", 69), ("end", 80)]),
  )
  let ast = po("SELECT FOO()")
  t.eq(
    meta_of(ast.find([Anonymous])),
    sorted_meta([("line", 1), ("col", 10), ("start", 7), ("end", 9)]),
  )
  let ast = po("SELECT * FROM t")
  t.eq(
    meta_of(ast.find([Star])),
    sorted_meta([("line", 1), ("col", 8), ("start", 7), ("end", 7)]),
  )
  let ast = po("SELECT t.* FROM t")
  t.eq(
    meta_of(ast.find([Star])),
    sorted_meta([("line", 1), ("col", 10), ("start", 9), ("end", 9)]),
  )
  let ast = po("SELECT 1")
  t.eq(
    meta_of(ast.find([Literal])),
    sorted_meta([("line", 1), ("col", 8), ("start", 7), ("end", 7)]),
  )
  t.eq(
    meta_of(Some(po("max(1)"))),
    sorted_meta([("col", 3), ("end", 2), ("line", 1), ("start", 0)]),
  )
  t.done()
}

///|
test "TestParser.test_quoted_identifier_meta" {
  let sql = "SELECT \"a\" FROM \"test_schema\".\"test_table_a\""
  let ast = po(sql)
  let table = ast.arg("from_").unwrap().this().unwrap()
  let db_meta = table.arg("db").unwrap().get_meta()
  let slice = (m : Map[String, @core.Value]) => {
    match (m.get("start"), m.get("end")) {
      (Some(@core.Int(s)), Some(@core.Int(e))) =>
        sql.unsafe_substring(start=s.to_int(), end=e.to_int() + 1)
      _ => "<missing meta>"
    }
  }
  assert_eq(slice(db_meta), "\"test_schema\"")
  let table_meta = table.this().unwrap().get_meta()
  assert_eq(slice(table_meta), "\"test_table_a\"")
}

///|
test "TestParser.test_qualified_function" {
  let sql = "a.b.c.d.e.f.g.foo()"
  let ast = po(sql)
  assert_false(ast.walk().any(n => n.kind.is_a(Column)))
  assert_eq(ast.find_all([Dot]).count(), 7)
}

///|
test "TestParser.test_pivot_missing_agg_func" {
  let t = t()
  let e = t.raises_parse(() => {
    ignore(po("select * from tbl pivot(col1 for col2 in (val1, val1))"))
  })
  t.ok(
    msg_of(e).contains("Expecting an aggregation function in PIVOT"),
    msg=msg_of(e),
  )
  t.done()
}

///|
test "TestParser.test_multiple_query_modifiers" {
  let t = t()
  let sql = "SELECT * FROM a WHERE b = 'true' AND c > 50 WHERE c = 'false'"
  let e = t.raises_parse(() => ignore(po(sql)))
  t.ok(
    msg_of(e).contains("Found multiple 'WHERE' clauses. Line 1, Col: 49."),
    msg=msg_of(e),
  )
  t.eqf(
    () => gen(@sqlglot.parse_one(sql, error_level=Ignore)),
    "SELECT * FROM a WHERE c = 'false'",
  )
  let e = t.raises_parse(() => {
    ignore(
      po(
        "SELECT id FROM t START WITH a = 1 CONNECT BY PRIOR id = pid START WITH b = 2 CONNECT BY PRIOR id = pid",
      ),
    )
  })
  t.ok(
    msg_of(e).contains("Found multiple 'START WITH' clauses. Line 1, Col: 65."),
    msg=msg_of(e),
  )
  let sql = "SELECT a FROM x OFFSET 1 LIMIT 2, 3"
  let e = t.raises_parse(() => ignore(po(sql)))
  t.ok(
    msg_of(e).contains("Found multiple 'OFFSET' clauses. Line 1, Col: 30."),
    msg=msg_of(e),
  )
  t.eqf(
    () => gen(@sqlglot.parse_one(sql, error_level=Ignore)),
    "SELECT a FROM x LIMIT 3 OFFSET 2",
  )
  t.done()
}

///|
test "TestParser.test_window_clause_without_from" {
  // https://github.com/tobymao/sqlglot/issues/7438
  let t = t()
  for dialect in ["", "sqlite", "postgres", "mysql", "duckdb", "bigquery"] {
    let sql = "SELECT 1 WINDOW a AS (PARTITION BY x)"
    t.eqf(() => sql_of(sql, read=dialect), sql)
  }

  // multiple named windows still work
  t.eqf(
    () => gen(po("SELECT 1 WINDOW a AS (PARTITION BY x), b AS (ORDER BY y)")),
    "SELECT 1 WINDOW a AS (PARTITION BY x), b AS (ORDER BY y)",
  )

  // WINDOW can still be used as an explicit alias (SELECT 1 AS WINDOW)
  t.eqf(() => gen(po("SELECT 1 AS WINDOW")), "SELECT 1 AS WINDOW")

  // WINDOW remains usable as an implicit alias when not followed by `<id> AS (`
  t.eqf(
    () => gen(po("SELECT col window FROM t")),
    "SELECT col AS window FROM t",
  )
  t.done()
}

///|
test "TestParser.test_parse_into_grant_principal" {
  let t = t()
  let into = (sql : String, read : String) => {
    isa(
      Some(@sqlglot.parse_one(sql, into=GrantPrincipal, read~)),
      GrantPrincipal,
    )
  }
  t.eqf(() => into("ROLE blah", ""), true)
  t.eqf(() => into("GROUP blah", ""), true)
  t.eqf(() => into("blah", ""), true)
  t.eqf(() => into("ROLE `blah`", "databricks"), true)
  t.eqf(
    () => {
      @sqlglot.generate(
        @sqlglot.parse_one(
          "ROLE `blah`",
          into=GrantPrincipal,
          read="databricks",
        ),
        dialect="databricks",
      )
    },
    "ROLE `blah`",
  )
  t.done()
}

///|
test "TestParser.test_parse_into_grant_privilege" {
  let t = t()
  let into = (sql : String) => {
    isa(Some(@sqlglot.parse_one(sql, into=GrantPrivilege)), GrantPrivilege)
  }
  t.eqf(() => into("SELECT"), true)
  t.eqf(() => into("ALL PRIVILEGES"), true)
  t.done()
}

///|
test "TestParser.test_max_nodes" {
  let t = t()
  t.eqf(
    () => isa(Some(@sqlglot.parse_one("SELECT 1", max_nodes=1_000_000)), Select),
    true,
  )
  let cols = Array::makei(500, i => "col\{i}")
  let sql = "SELECT \{cols.join(",")} FROM t"
  t.eqf(
    () => isa(Some(@sqlglot.parse_one(sql, max_nodes=1_000_000)), Select),
    true,
  )
  let width = 10000
  let depth = 100
  let expr = "x" + "=x".repeat(depth)
  let cols = Array::make(width, expr)
  let sql = "SELECT \{cols.join(",")}"
  let e = t.raises_parse(() => {
    ignore(@sqlglot.parse_one(sql, max_nodes=1_000_000))
  })
  t.ok(msg_of(e).contains("Maximum number of AST nodes"), msg=msg_of(e))
  let e = t.raises_parse(() => ignore(@sqlglot.parse_one(sql, max_nodes=50_000)))
  t.ok(msg_of(e).contains("(50000)"), msg=msg_of(e))

  // Hitting a limit in one parse doesn't affect the next
  let sql = "SELECT " + Array::makei(100, i => "x=\{i}").join(",")
  t.raises_parse(() => ignore(@sqlglot.parse_one(sql, max_nodes=5))) |> ignore
  t.eqf(() => isa(Some(po("SELECT 1, 2, 3")), Select), true)
  t.done()
}
