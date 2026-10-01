// Runs the dialect conformance cases extracted from the Python test-suite
// (tests/dialects/test_*.py) by tools/extract_dialect_tests.py.

///|
/// Maximum number of mismatches printed per module.
let max_printed : Int = 25

///|
fn get_dialect(name : String) -> @core.Dialect raise @core.SqlglotError {
  @sqlglot.register_dialects()
  @core.Dialect::get_or_raise(name)
}

///|
fn run_case(
  read : String,
  write : String,
  flags : String,
  sql : String,
) -> String raise @core.SqlglotError {
  let r = get_dialect(read)
  let w = get_dialect(write)
  let unsupported_level : @core.ErrorLevel = if flags.contains("u") {
    Raise
  } else if flags.contains("I") {
    Ignore
  } else {
    Warn
  }
  if flags.contains("c") {
    @core.take_log_messages() |> ignore
  }
  let e = @core.parse_one(sql, dialect=r)
  if flags.contains("c") {
    let prefix = sql.to_array()
    let prefix = String::from_array(
      prefix[:if prefix.length() > 100 { 100 } else { prefix.length() }],
    )
    let warning = "WARNING: '\{prefix}' contains unsupported syntax"
    guard @core.take_log_messages().iter().any(m => m.has_prefix(warning)) else {
      raise @core.ValueError("expected the Command fallback warning")
    }
  }
  @core.Generator::new(
    w,
    pretty=flags.contains("p"),
    identify=if flags.contains("i") { "always" } else { "" },
    unsupported_level~,
  ).generate(e)
}

///|
fn run_dialect_cases(module_name : String, cases : Array[String]) -> Unit raise {
  let total = cases.length() / 5
  let mut failures = 0
  let mut errors = 0
  let mut printed = 0
  for i = 0; i < cases.length(); i = i + 5 {
    let read = cases[i]
    let write = cases[i + 1]
    let flags = cases[i + 2]
    let sql = cases[i + 3]
    let expected = cases[i + 4]
    let label = "[\{read} -> \{write}\{if flags.is_empty() { "" } else { " " + flags }}]"
    let expect_unsupported = flags.contains("u")
    let expect_error = flags.contains("E")
    let got = run_case(read, write, flags, sql) catch {
      @core.UnsupportedError(_) if expect_unsupported => continue
      err if expect_error => {
        if err.to_string() != expected {
          failures += 1
          if printed < max_printed {
            printed += 1
            println(
              "WRONG-ERROR \{label} \{sql}\n  got: \{err}\n  exp: \{expected}",
            )
          }
        }
        continue
      }
      err => {
        errors += 1
        if printed < max_printed {
          printed += 1
          println("ERR \{label} \{sql}\n  \{err}")
        }
        continue
      }
    }
    if expect_unsupported || expect_error {
      failures += 1
      if printed < max_printed {
        printed += 1
        let what = if expect_error { "NO-ERROR" } else { "NOT-UNSUPPORTED" }
        println("\{what} \{label} \{sql}\n  got: \{got}")
      }
    } else if got != expected {
      failures += 1
      if printed < max_printed {
        printed += 1
        println("MISMATCH \{label} \{sql}\n  got: \{got}\n  exp: \{expected}")
      }
    }
  }
  let passed = total - failures - errors
  println(
    "DIALECT \{module_name}: total=\{total} passed=\{passed} mismatches=\{failures} errors=\{errors}",
  )
  if cases.length() % 5 != 0 {
    fail("malformed fixture for \{module_name}: \{cases.length()} strings")
  }
  if failures + errors > 0 {
    fail("\{module_name}: \{failures} mismatches, \{errors} errors")
  }
}
