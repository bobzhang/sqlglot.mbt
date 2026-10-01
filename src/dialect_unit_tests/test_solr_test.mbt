// Direct assertions of tests/dialects/test_solr.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestSolr.test_solr" {
  let t = t(dialect="solr")
  t.is_a(Some(t.validate_identity("a || b", write_sql="a OR b")), Or) |> ignore
  t.done()
}
