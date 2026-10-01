// Port of tests/test_serde.py.

///|
fn dump_load(expression : @core.Expr) -> @core.Expr raise {
  // json.loads(json.dumps(expression.dump()))
  let text = expression.dump().stringify()
  @core.Expr::load(@json.parse(text)).unwrap()
}

///|
test "serde" {
  let mut failures = 0
  for sql in serde_identity {
    let before = @sqlglot.parse_one(sql)
    let after = dump_load(before)
    if before.to_s() != after.to_s() {
      failures += 1
      if failures <= 10 {
        println("SERDE MISMATCH \{sql}")
      }
    }
  }
  println("SERDE: total=\{serde_identity.length()} mismatches=\{failures}")
  assert_eq(failures, 0)
}

///|
test "serde loads python payloads" {
  // Payloads dumped by Python's `Expr.dump` load into the tree MoonBit parses.
  // Argument insertion order can differ between the two parsers, so trees are
  // compared structurally; identical payload text is counted for information.
  let mut failures = 0
  let mut identical = 0
  let total = serde_python_dumps.length() / 2
  for i = 0; i < serde_python_dumps.length(); i = i + 2 {
    let sql = serde_python_dumps[i]
    let payload = serde_python_dumps[i + 1]
    let expected = @sqlglot.parse_one(sql)
    let loaded = @core.Expr::load(@json.parse(payload)).unwrap()
    if loaded.canonical() != expected.canonical() ||
      loaded != expected ||
      loaded.get_type() != expected.get_type() {
      failures += 1
      if failures <= 10 {
        println("SERDE PY MISMATCH \{sql}")
      }
    }
    if expected.dump().stringify() == payload {
      identical += 1
    }
  }
  println(
    "SERDE_PY: total=\{total} mismatches=\{failures} identical_payloads=\{identical}",
  )
  assert_eq(failures, 0)
}

///|
test "serde custom expression (skipped)" {
  // test_custom_expression subclasses `exp.Expression`; expression kinds are a
  // closed enum in the MoonBit port, so there is nothing to port. A dotted
  // class name resolves to its last component.
  let e = @core.Expr::load(
    @json.parse("[{\"c\":\"sqlglot.expressions.Column\"}]"),
  ).unwrap()
  inspect(e.kind.name(), content="Column")
}

///|
test "serde type annotations" {
  let before = @optimizer.annotate_types(
    @sqlglot.parse_one("CAST('1' AS STRUCT<x ARRAY<INT>>)"),
  )
  let after = dump_load(before)
  assert_true(before.get_type() == after.get_type())
  assert_true(before.this_().get_type() == after.this_().get_type())
  assert_true(after.this_().get_type() is Some(_))
}

///|
test "serde meta" {
  let before = @sqlglot.parse_one("SELECT * FROM X")
  before.get_meta()["x"] = Int(1)
  let after = dump_load(before)
  inspect(after.meta_get("x") is Some(Int(1)), content="true")
  assert_eq(before.get_meta().length(), after.get_meta().length())
}

///|
test "serde recursion" {
  let sb = StringBuilder()
  sb.write_string("SELECT 1")
  for _ in 0..<5000 {
    sb.write_string(" UNION ALL SELECT 1")
  }
  let expr = @sqlglot.parse_one(sb.to_string())
  let before = @sqlglot.generate(expr)
  assert_eq(before, @sqlglot.generate(dump_load(expr)))
  // pickle round trip: a deep copy
  assert_eq(before, @sqlglot.generate(expr.copy()))
}
