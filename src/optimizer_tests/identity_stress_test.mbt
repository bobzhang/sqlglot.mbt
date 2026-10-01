// optimize / qualify / annotate_types over every statement of identity.sql, compared
// with Python (tools/gen_optimizer_fixtures.py: gen_identity_stress).

///|
test "optimizer identity stress" {
  let totals : Map[String, (Int, Int)] = {}
  let mut reported = 0
  let mut i = 0
  while i + 4 < identity_stress_fixtures.length() {
    let mode = identity_stress_fixtures[i]
    let sql = identity_stress_fixtures[i + 3]
    let expected = identity_stress_fixtures[i + 4]
    i += 5
    let got = (try {
      let e = @core.parse_one(sql)
      match mode {
        "optimize" => @optimizer.sql_of(@optimizer.optimize(e))
        "qualify" =>
          @optimizer.sql_of(
            @optimizer.qualify(e, validate_qualify_columns=false),
          )
        _ =>
          match @optimizer.annotate_types(e).get_type() {
            Some(t) => @optimizer.sql_of(t)
            None => "None"
          }
      }
    } catch {
      err => "ERROR: \{err}"
    })
    let ok = outcome_matches(got, expected)
    let (t, p) = totals.get(mode).unwrap_or((0, 0))
    totals[mode] = (t + 1, if ok { p + 1 } else { p })
    if !ok && reported < 15 {
      reported += 1
      println("MISMATCH [\{mode}] \{sql}\n  got: \{got}\n  exp: \{expected}")
    }
  }
  for mode, tp in totals {
    println("IDENTITY \{mode}: total=\{tp.0} passed=\{tp.1}")
  }
  for _, tp in totals {
    assert_eq(tp.1, tp.0)
  }
}
