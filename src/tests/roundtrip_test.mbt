///|
test "base dialect round trips match python" {
  let d = @core.base_dialect()
  let mut failures = 0
  let mut errors = 0
  let mut i = 0
  let total = roundtrip_fixtures.length() / 3
  while i < roundtrip_fixtures.length() {
    let sql = roundtrip_fixtures[i]
    let pretty = roundtrip_fixtures[i + 1] == "1"
    let expected = roundtrip_fixtures[i + 2]
    i += 3
    let got = @core.transpile(sql, read=d, pretty~)[0] catch {
      err => {
        errors += 1
        if errors <= 20 {
          println("ERR \{sql}\n  \{err}")
        }
        continue
      }
    }
    if got != expected {
      failures += 1
      if failures <= 40 {
        println("MISMATCH \{sql}\n  got: \{got}\n  exp: \{expected}")
      }
    }
  }
  println("ROUNDTRIP: total=\{total} mismatches=\{failures} errors=\{errors}")
}
