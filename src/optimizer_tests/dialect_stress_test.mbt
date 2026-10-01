// optimize() over queries of the dialect test corpus, compared with Python
// (tools/gen_optimizer_dialect_stress.py).

///|
test "optimizer dialect stress" {
  let totals : Map[String, (Int, Int)] = {}
  let mut reported = 0
  let mut i = 0
  while i + 2 < dialect_stress_fixtures.length() {
    let read = dialect_stress_fixtures[i]
    let sql = dialect_stress_fixtures[i + 1]
    let expected = dialect_stress_fixtures[i + 2]
    i += 3
    let got = (try {
      let dialect = if read == "" {
        None
      } else {
        Some(@core.Dialect::get_or_raise(read))
      }
      let e = @core.parse_one(sql, dialect?)
      @optimizer.sql_of(@optimizer.optimize(e, dialect?), dialect?)
    } catch {
      err => "ERROR: \{err}"
    })
    let ok = if expected.has_prefix("ERROR:") {
      got.has_prefix("ERROR:")
    } else {
      got == expected
    }
    let (t, p) = totals.get(read).unwrap_or((0, 0))
    totals[read] = (t + 1, if ok { p + 1 } else { p })
    if !ok && reported < 10 {
      reported += 1
      println("MISMATCH [\{read}] \{sql}\n  got: \{got}\n  exp: \{expected}")
    }
  }
  let mut total = 0
  let mut passed = 0
  for read, tp in totals {
    total += tp.0
    passed += tp.1
    if tp.0 != tp.1 {
      println("STRESS \{read}: total=\{tp.0} passed=\{tp.1}")
    }
  }
  println("OPTIMIZER dialect_stress: total=\{total} passed=\{passed}")
  assert_eq(passed, total)
}
