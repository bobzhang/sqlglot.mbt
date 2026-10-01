// Direct assertions of tests/dialects/test_dune.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestDune.test_dune" {
  let t = t(dialect="dune")
  for hex_literal in [
    "deadbeef", "deadbeefdead", "deadbeefdeadbeef", "deadbeefdeadbeefde", "deadbeefdeadbeefdead",
    "deadbeefdeadbeefdeadbeef", "deadbeefdeadbeefdeadbeefdeadbeef",
  ] {
    t.is_a(Some(t.parse_one("0x\{hex_literal}")), HexString) |> ignore
  }
  t.done()
}
