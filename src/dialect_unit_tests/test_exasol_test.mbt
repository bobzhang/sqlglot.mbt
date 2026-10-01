// Direct assertions of tests/dialects/test_exasol.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestExasol.test_group_by_all" {
  let t = t(dialect="exasol")
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "SELECT *, COUNT(*) FROM t GROUP BY ALL",
        write="exasol",
        unsupported_level=Raise,
      ),
    ),
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestExasol.test_use_to_open_schema" {
  let t = t(dialect="exasol")
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "USE ROLE admin",
        read="snowflake",
        write="exasol",
        unsupported_level=Raise,
      ),
    ),
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestExasol.test_exasol" {
  let t = t(dialect="exasol")
  t.is_a(Some(t.validate_identity("CURRENT_SCHEMA")), CurrentSchema) |> ignore
  t.done()
}

///|
test "TestExasol.test_number_functions" {
  let t = t(dialect="exasol")
  t.is_a(Some(t.validate_identity("TRUNC(123.456, 2)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(3.14159)")), Trunc) |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS DATE), 'MONTH')")), DateTrunc) |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS TIMESTAMP), 'MONTH')")), DateTrunc)
  |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS DATETIME), 'MONTH')")), DateTrunc)
  |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(CAST(x AS DATE))")), Anonymous) |> ignore
  t.done()
}
