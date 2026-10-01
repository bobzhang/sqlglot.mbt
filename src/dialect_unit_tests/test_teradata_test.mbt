// Direct assertions of tests/dialects/test_teradata.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestTeradata.test_teradata" {
  let t = t(dialect="teradata")
  t.is_a(
    Some(
      t.validate_identity(
        "RENAME TABLE emp TO employee",
        check_command_warning=true,
      ),
    ),
    Command,
  )
  |> ignore
  t.done()
}
