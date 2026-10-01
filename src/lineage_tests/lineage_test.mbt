// Replays the lineage() calls recorded from tests/test_lineage.py (see
// tools/gen_lineage_fixtures.py) and compares canonical graph dumps.

///|
fn sql_or_error(e : @core.Expr, dialect : @core.Dialect?) -> String {
  @optimizer.sql_of(e, dialect?) catch {
    err => "<\{err}>"
  }
}

///|
fn dump(
  node : @lineage.Node,
  dialect : @core.Dialect?,
  depth : Int,
  seen : Array[Int],
) -> String {
  let head = "\{node.name} | \{node.source_name} | \{node.reference_node_name} | \{sql_or_error(node.expression, dialect)} | \{sql_or_error(node.source, dialect)}"
  if seen.contains(node.id) || depth > 30 {
    return head + " ..."
  }
  let seen = seen + [node.id]
  let children = node.downstream.map(d => dump(d, dialect, depth + 1, seen))
  children.sort_by(py_cmp)
  if children.is_empty() {
    return head
  }
  let lines = []
  for c in children {
    for line in c.split("\n") {
      lines.push("  " + line.to_string())
    }
  }
  head + "\n" + lines.join("\n")
}

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
fn run_call(key : String) -> String raise {
  let call = match @json.parse(key) {
    Object(m) => m
    _ => fail("bad key")
  }
  let dialect = match call.get("dialect") {
    Some(String(d)) if d != "" => Some(@core.Dialect::get_or_raise(d))
    _ => None
  }
  let sql = match call.get("sql") {
    Some(String(s)) => s
    _ => fail("no sql")
  }
  let schema = match call.get("schema") {
    Some(Object(_) as j) =>
      match @optimizer.SchemaNode::from_json(j) {
        Dict(m) => Some(@optimizer.MappingSchema::new(schema=m, dialect?))
        _ => None
      }
    _ => None
  }
  let sources = match call.get("sources") {
    Some(Object(m)) => {
      let out : Map[String, @core.Expr] = {}
      for k, v in m {
        match v {
          String(s) => out[k] = @core.parse_one(s, dialect?)
          _ => ()
        }
      }
      Some(out)
    }
    _ => None
  }
  let trim_selects = match call.get("trim_selects") {
    Some(False) => false
    _ => true
  }
  let expression = @core.parse_one(sql, dialect?)
  match call.get("column") {
    Some(String(c)) => {
      let node = @lineage.lineage(
        c,
        expression,
        schema?,
        sources?,
        dialect?,
        trim_selects~,
      )
      dump(node, dialect, 0, [])
    }
    _ => {
      let result = @lineage.lineage_all(
        expression,
        schema?,
        sources?,
        dialect?,
        trim_selects~,
      )
      let parts = []
      for name, n in result {
        parts.push("[\{name}]\n" + dump(n, dialect, 0, []))
      }
      parts.join("\n")
    }
  }
}

///|
test "lineage fixtures" {
  let mut total = 0
  let mut passed = 0
  let mut base_total = 0
  let mut base_passed = 0
  let mut reported = 0
  let mut i = 0
  while i + 1 < lineage_fixtures.length() {
    let key = lineage_fixtures[i]
    let expected = lineage_fixtures[i + 1]
    i += 2
    total += 1
    let is_base = key.contains("\"dialect\": \"\"")
    if is_base {
      base_total += 1
    }
    let got = run_call(key) catch { err => "ERROR: \{err}" }
    if got == expected {
      passed += 1
      if is_base {
        base_passed += 1
      }
    } else if is_base && reported < 10 {
      reported += 1
      println("MISMATCH \{key}\n--- got:\n\{got}\n--- exp:\n\{expected}")
    }
  }
  println(
    "LINEAGE: total=\{total} passed=\{passed} (base dialect: total=\{base_total} passed=\{base_passed})",
  )
  assert_eq(passed, total)
}
