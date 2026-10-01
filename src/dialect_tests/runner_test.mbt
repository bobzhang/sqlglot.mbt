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
  let e = @core.parse_one(sql, dialect=r)
  @core.Generator::new(
    w,
    pretty=flags.contains("p"),
    identify=if flags.contains("i") { "always" } else { "" },
    unsupported_level~,
  ).generate(e)
}

///|
fn run_dialect_cases(module : String, cases : Array[String]) -> Unit {
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
    let got = run_case(read, write, flags, sql) catch {
      @core.UnsupportedError(_) if expect_unsupported => continue
      err => {
        errors += 1
        if printed < max_printed {
          printed += 1
          println("ERR \{label} \{sql}\n  \{err}")
        }
        continue
      }
    }
    if expect_unsupported {
      failures += 1
      if printed < max_printed {
        printed += 1
        println("NOT-UNSUPPORTED \{label} \{sql}\n  got: \{got}")
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
    "DIALECT \{module}: total=\{total} passed=\{passed} mismatches=\{failures} errors=\{errors}",
  )
}
