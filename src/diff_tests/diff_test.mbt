// Replays the diff() calls recorded from tests/test_diff.py (tools/gen_diff_fixtures.py).

///|
fn py_cmp(a : String, b : String) -> Int {
  let ai = a.iter()
  let bi = b.iter()
  for ;; {
    match (ai.next(), bi.next()) {
      (None, None) => return 0
      (None, Some(_)) => return -1
      (Some(_), None) => return 1
      (Some(x), Some(y)) => if x != y { return if x < y { -1 } else { 1 } }
    }
  }
}

///|
fn edit_str(e : @diff.Edit) -> String raise {
  fn s(x : @core.Expr) raise {
    "\{x.kind.name()}: \{@core.expr_to_sql(x)}"
  }

  match e {
    Insert(x) => "Insert(\{s(x)})"
    Remove(x) => "Remove(\{s(x)})"
    Move(source~, target~) => "Move(\{s(source)} -> \{@core.expr_to_sql(target)})"
    Update(source~, target~) =>
      "Update(\{s(source)} -> \{@core.expr_to_sql(target)})"
    Keep(source~, target~) => "Keep(\{s(source)} -> \{@core.expr_to_sql(target)})"
  }
}

///|
test "diff fixtures" {
  let mut total = 0
  let mut passed = 0
  let mut i = 0
  while i + 1 < diff_fixtures.length() {
    let key = diff_fixtures[i]
    let expected = diff_fixtures[i + 1]
    i += 2
    total += 1
    let call = match @json.parse(key) {
      Object(m) => m
      _ => fail("bad key")
    }
    let source = match call.get("source") {
      Some(String(s)) => @core.parse_one(s)
      _ => fail("no source")
    }
    let target = match call.get("target") {
      Some(String(s)) => @core.parse_one(s)
      _ => fail("no target")
    }
    let delta_only = call.get("delta_only") is Some(True)
    let edits = @diff.diff(source, target, delta_only~).map(edit_str)
    edits.sort_by(py_cmp)
    let got = edits.join("\n")
    if got == expected {
      passed += 1
    } else {
      println("MISMATCH \{key}\n--- got:\n\{got}\n--- exp:\n\{expected}")
    }
  }
  println("DIFF: total=\{total} passed=\{passed}")
}

///|
test "diff simple" {
  let edits = @diff.diff(
    @core.parse_one("SELECT a + b"),
    @core.parse_one("SELECT a - b"),
    delta_only=true,
  )
  let expected = [
    @diff.Edit::Remove(@core.parse_one("a + b")),
    Insert(@core.parse_one("a - b")),
    Move(source=@core.parse_one("a"), target=@core.parse_one("a")),
    Move(source=@core.parse_one("b"), target=@core.parse_one("b")),
  ]
  assert_eq(edits.length(), expected.length())
  for e in expected {
    assert_true(edits.contains(e))
  }
}
