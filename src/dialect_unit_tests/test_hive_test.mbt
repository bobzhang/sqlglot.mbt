// Direct assertions of tests/dialects/test_hive.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestHive.test_hive" {
  let t = t(dialect="hive")
  let expression = t.parse_one("INITCAP('new york')")
  t.a_assert_duckdb_sql(
    expression,
    includes=["REGEXP_MATCHES(", "ARRAY_TO_STRING("],
    chr_chars=['\u{0b}', '\u{1c}', '\u{1d}', '\u{1e}', '\u{1f}'],
  )
  |> ignore
  t.validate_identity("TRUNC(date_col, 'MM')").assert_is(TimestampTrunc)
  |> ignore
  t.validate_identity("EXISTS(col, x -> x % 2 = 0)").assert_is(Exists) |> ignore
  t.done()
}

///|
test "TestHive.test_percentile" {
  let t = t(dialect="hive")
  let quantile_expr = t.validate_identity("PERCENTILE(DISTINCT x, 0.5)")
  quantile_expr.assert_is(Quantile) |> ignore
  quantile_expr.this().unwrap().assert_is(Distinct) |> ignore
  quantile_expr.arg("quantile").unwrap().assert_is(Literal) |> ignore
  let quantile_expr = t.validate_identity(
    "PERCENTILE(ALL x, 0.5)",
    write_sql="PERCENTILE(x, 0.5)",
  )
  quantile_expr.assert_is(Quantile) |> ignore
  quantile_expr.this().unwrap().assert_is(Column) |> ignore
  quantile_expr.arg("quantile").unwrap().assert_is(Literal) |> ignore
  t.done()
}

///|
test "TestHive.test_create_function_using" {
  let t = t(dialect="hive")
  // the AST node is a Create with UsingProperty
  let expr = t.parse_one(
    "CREATE FUNCTION my_func AS 'com.example.MyFunc' USING JAR 'hdfs://path/to/my.jar'",
  )
  t.ok(expr.kind.is_a(Create))
  let using_prop = expr.find([UsingProperty])
  t.ok(using_prop is Some(_))
  if using_prop is Some(using_prop) {
    t.eq(using_prop.str_arg("kind"), Some("JAR"))
    t.eq(
      using_prop.this().unwrap().str_arg("this"),
      Some("hdfs://path/to/my.jar"),
    )
  }
  // programmatic construction
  let create = @core.mk(Create, [
    ("this", @core.mk(Table, [("this", @core.to_identifier("my_func"))])),
    ("kind", "FUNCTION"),
    ("expression", @core.literal_string("com.example.MyFunc")),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(UsingProperty, [
              ("this", @core.literal_string("s3://bucket/new.jar")),
              ("kind", "JAR"),
            ]),
          ],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(create, dialect="hive"),
    "CREATE FUNCTION my_func AS 'com.example.MyFunc' USING JAR 's3://bucket/new.jar'",
  )
  // programmatic modification of the JAR path
  let expr = t.parse_one(
    "CREATE FUNCTION my_func AS 'com.example.MyFunc' USING JAR 'hdfs://old/path.jar'",
  )
  let using_prop = expr.find([UsingProperty]).unwrap()
  using_prop.set("this", @core.literal_string("hdfs://new/path.jar"))
  t.eq(
    sql(expr, dialect="hive"),
    "CREATE FUNCTION my_func AS 'com.example.MyFunc' USING JAR 'hdfs://new/path.jar'",
  )
  t.done()
}
