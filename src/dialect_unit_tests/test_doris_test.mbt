// Direct assertions of tests/dialects/test_doris.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestDoris.test_identity" {
  let t = t(dialect="doris")
  for
    keyword in [
      "analyzer", "asof", "both", "char_filter", "dump", "layout", "leading", "match_condition",
      "no_use_mv", "play", "token_filter", "tokenizer", "trailing", "try_cast", "use_mv",
    ] {
    t.eqf(
      () => sql(@sqlglot.select([keyword]).from_("t"), dialect="doris"),
      "SELECT `\{keyword}` FROM t",
    )
  }
  t.done()
}
