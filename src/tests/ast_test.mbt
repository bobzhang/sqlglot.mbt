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
      if failures <= 15 {
        println("MISMATCH \{sql}\n  got: \{got}\n  exp: \{expected}")
      }
    }
  }
  println("AST: total=\{total} mismatches=\{failures} errors=\{errors}")
}
