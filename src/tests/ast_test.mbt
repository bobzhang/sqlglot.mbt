///|
test "parser matches python AST on identity fixtures" {
  let mut failures = 0
  let mut errors = 0
  let mut i = 0
  let total = ast_fixtures.length() / 2
  while i < ast_fixtures.length() {
    let sql = ast_fixtures[i]
    let expected = ast_fixtures[i + 1]
    i += 2
    let e = @core.parse_one(sql) catch {
      err => {
        errors += 1
        if errors <= 15 {
          println("ERR \{sql}\n  \{err}")
        }
        continue
      }
    }
    let got = e.canonical()
    if got != expected {
      failures += 1
      if failures <= 60 {
        // show the first differing region
        let g = got.to_array()
        let x = expected.to_array()
        let mut k = 0
        while k < g.length() && k < x.length() && g[k] == x[k] {
          k += 1
        }
        let s0 = if k > 40 { k - 40 } else { 0 }
        let ge = if k + 80 < g.length() { k + 80 } else { g.length() }
        let xe = if k + 80 < x.length() { k + 80 } else { x.length() }
        println(
          "MISMATCH \{sql}\n  got: ...\{String::from_array(g[s0:ge])}\n  exp: ...\{String::from_array(x[s0:xe])}",
        )
      }
    }
  }
  println("AST: total=\{total} mismatches=\{failures} errors=\{errors}")
  assert_eq(failures + errors, 0)
}
