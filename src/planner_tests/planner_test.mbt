// Compares plans of optimized queries with Python's (tools/gen_planner_fixtures.py).

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
/// The step's text without its trailing ` (<uid>)` and with sorted dependencies.
fn canonical(step : @planner.Step, level : Int) -> String {
  let indent = "  ".repeat(level)
  let nested = indent + "    "
  let text = step.to_s(level~)
  let head = []
  for line in text.split("\n") {
    let line = line.to_string()
    if line == "\{nested}Dependencies:" {
      break
    }
    head.push(line)
  }
  let suffix = " (\{step.uid})"
  if head[0].has_suffix(suffix) {
    head[0] = head[0].substring(end=head[0].length() - suffix.length())
  }
  let deps = step.dependencies.map(d => canonical(d, level + 1))
  deps.sort_by(py_cmp)
  if !deps.is_empty() {
    head.push("\{nested}Dependencies:")
    for d in deps {
      head.push("  " + d)
    }
  }
  head.join("\n")
}

///|
test "planner fixtures" {
  let mut total = 0
  let mut passed = 0
  let mut i = 0
  while i + 2 < planner_fixtures.length() {
    let schema_name = planner_fixtures[i]
    let sql = planner_fixtures[i + 1]
    let expected = planner_fixtures[i + 2]
    i += 3
    total += 1
    let got = (try {
      let mapping = @optimizer.schema_from_json_string(
        if schema_name == "tpch" {
          tpch_schema_json
        } else {
          extra_schema_json
        },
      )
      let optimized = @optimizer.optimize(
        @core.parse_one(sql),
        mapping~,
        leave_tables_isolated=true,
      )
      canonical(@planner.Plan::new(optimized).root, 0)
    } catch {
      err => "ERROR: \{err}"
    })
    if got == expected {
      passed += 1
    } else if total - passed <= 3 {
      println("MISMATCH \{sql}\n--- got:\n\{got}\n--- exp:\n\{expected}")
    }
  }
  println("PLANNER: total=\{total} passed=\{passed}")
  assert_eq(passed, total)
}
