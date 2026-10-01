// Direct assertions of tests/dialects/test_databricks.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestDatabricks.test_databricks" {
  let t = t(dialect="databricks")
  let null_type = @sqlglot.datatype_build("VOID", dialect="databricks")
  t.eq(sql(null_type), "NULL")
  t.eq(sql(null_type, dialect="databricks"), "VOID")
  t
  .validate_identity(
    "DATE_DIFF(day, created_at, current_date())",
    write_sql="DATEDIFF(DAY, created_at, CURRENT_DATE)",
  )
  .arg("unit")
  .unwrap()
  .assert_is(Var)
  |> ignore
  t.raises(
    () => {
      ignore(
        @sqlglot.transpile(
          "CREATE FUNCTION add_one(x INT) RETURNS INT LANGUAGE PYTHON AS $foo$def add_one(x):\n  return x+1$$",
          read="databricks",
        ),
      )
    },
    "ParseError",
  )
  |> ignore
  t.raises(
    () => {
      ignore(
        @sqlglot.transpile(
          "CREATE FUNCTION add_one(x INT) RETURNS INT LANGUAGE PYTHON AS $foo bar$def add_one(x):\n  return x+1$foo bar$",
          read="databricks",
        ),
      )
    },
    "ParseError",
  )
  |> ignore
  t
  .validate_identity(
    "WITH t AS (SELECT '{\"x-y\": \"z\"}' AS c) SELECT get_json_object(c, '$.x-y') FROM t",
    write_sql="WITH t AS (SELECT '{\"x-y\": \"z\"}' AS c) SELECT GET_JSON_OBJECT(c, '$[\"x-y\"]') FROM t",
  )
  .selects()[0]
  .expression_()
  .assert_is(JSONPath)
  |> ignore
  t.done()
}

///|
test "TestDatabricks.test_to_char_is_numeric_transpile_to_cast" {
  let t = t(dialect="databricks")
  let sql_ = "SELECT TO_CHAR(12345, '#')"
  let expression = parse_one(sql_, read="dremio")
  let to_char_exp = expression.find([ToChar])
  t.ok(to_char_exp is Some(_))
  t.ok(to_char_exp.unwrap().get("is_numeric") is Some(Bool(true)))
  let result = @sqlglot.transpile(sql_, read="dremio", write="databricks")[0]
  t.contains(result, "CAST(12345 AS STRING)")
  t.done()
}
