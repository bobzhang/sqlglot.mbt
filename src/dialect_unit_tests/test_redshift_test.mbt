// Direct assertions of tests/dialects/test_redshift.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestRedshift.test_values" {
  let t = t(dialect="redshift")
  let values = Array::makei(10000, v => v.to_string())
  let values_query = "SELECT * FROM (VALUES \{values.map(v => "(" + v + ")").join(", ")})"
  let union_query = "SELECT * FROM (\{values.map(v => "SELECT " + v).join(" UNION ALL ")})"
  t.eqf(() => @sqlglot.transpile(values_query, write="redshift")[0], union_query)
  let values_sql = @sqlglot.transpile(
    "SELECT * FROM (VALUES (1), (2))",
    write="redshift",
    pretty=true,
  )[0]
  t.eq(
    values_sql, "SELECT\n  *\nFROM (\n  SELECT\n    1\n  UNION ALL\n  SELECT\n    2\n)",
  )
  t.done()
}

///|
test "TestRedshift.test_column_unnesting" {
  let t = t(dialect="redshift")
  let ast = parse_one(
    "SELECT * FROM t.t JOIN t.c1 ON c1.c2 = t.c3",
    read="redshift",
  )
  ast.arg("from_").unwrap().this_().assert_is(Table) |> ignore
  ast.list("joins")[0].this_().assert_is(Table) |> ignore
  t.eq(sql(ast, dialect="redshift"), "SELECT * FROM t.t JOIN t.c1 ON c1.c2 = t.c3")
  let ast = parse_one("SELECT * FROM t AS t CROSS JOIN t.c1", read="redshift")
  ast.arg("from_").unwrap().this_().assert_is(Table) |> ignore
  ast.list("joins")[0].this_().assert_is(Unnest) |> ignore
  t.eq(sql(ast, dialect="redshift"), "SELECT * FROM t AS t CROSS JOIN t.c1")
  let ast = parse_one(
    "SELECT * FROM x AS a, a.b AS c, c.d.e AS f, f.g.h.i.j.k AS l",
    read="redshift",
  )
  let joins = ast.list("joins")
  ast.arg("from_").unwrap().this_().assert_is(Table) |> ignore
  joins[0].this_().assert_is(Unnest) |> ignore
  joins[1].this_().assert_is(Unnest) |> ignore
  joins[2].this_().assert_is(Unnest).expressions()[0].assert_is(Dot) |> ignore
  t.eq(
    sql(ast, dialect="redshift"),
    "SELECT * FROM x AS a, a.b AS c, c.d.e AS f, f.g.h.i.j.k AS l",
  )
  t.done()
}

///|
test "TestRedshift.test_cast" {
  let t = t(dialect="redshift")
  let e = t.validate_identity("1::\"int\"", write_sql="CAST(1 AS INTEGER)")
  t.ok(e.arg("to").unwrap().is_type([INT]))
  t.raises(() => ignore(parse_one("1::\"udt\"", read="redshift")), "ParseError")
  |> ignore
  t.eq(
    b_dtype(t.parse_one("CAST(65 AS \"char\")").arg("to")),
    @core.DType::USERDEFINED.to_string(),
  )
  t.done()
}

///|
test "TestRedshift.test_to_timestamp" {
  let t = t(dialect="redshift")
  let d = @sqlglot.dialect("redshift")
  let expr = @optimizer.annotate_types(
    parse_one(
      "SELECT TO_TIMESTAMP('2023-01-01', 'YYYY-MM-DD')",
      read="redshift",
    ),
    dialect=d,
  )
  t.eq(
    b_dtype(expr.expressions()[0].get_type()),
    @core.DType::TIMESTAMPTZ.to_string(),
  )
  t.done()
}

///|
test "TestRedshift.test_identity" {
  let t = t(dialect="redshift")
  t.is_a(
    t
    .validate_identity(
      "DATE_PART(year, \"somecol\")",
      write_sql="EXTRACT(YEAR FROM \"somecol\")",
    )
    .this(),
    Var,
  )
  |> ignore
  t.done()
}
