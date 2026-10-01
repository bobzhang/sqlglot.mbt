// Fixture harness for the optimizer rules (see tools/gen_optimizer_fixtures.py).

///|
/// Per-case context passed to a rule runner.
struct Case {
  dialect : @core.Dialect?
  meta : Map[String, Json]
}

///|
fn Case::meta_bool(self : Case, key : String) -> Bool? {
  match self.meta.get(key) {
    Some(String(s)) => Some(@core.py_lower(s) == "true" || s == "1")
    _ => None
  }
}

///|
/// The schema given in the fixture meta, or `default`.
fn Case::schema(
  self : Case,
  default : String,
) -> @optimizer.MappingSchema raise @core.SqlglotError {
  let mapping = match self.meta.get("schema") {
    Some(String(s)) => @optimizer.schema_from_json_string(s)
    _ =>
      if default == "" {
        {}
      } else {
        @optimizer.schema_from_json_string(default)
      }
  }
  @optimizer.MappingSchema::new(schema=mapping, dialect?=self.dialect)
}

///|
fn parse_meta(s : String) -> Map[String, Json] {
  match (try? @json.parse(s)) {
    Ok(Object(m)) => m
    _ => {}
  }
}

///|
/// Runs every fixture of a rule and prints a summary line.
fn run_fixtures(
  name : String,
  fixtures : Array[String],
  pretty~ : Bool,
  runner : (@core.Expr, Case) -> @core.Expr raise,
  output? : (@core.Expr, Case) -> String raise,
  max_report? : Int = 15,
  report_dialects? : Bool = false,
) -> Unit raise {
  let mut total = 0
  let mut passed = 0
  let mut mismatches = 0
  let mut errors = 0
  let mut base_total = 0
  let mut base_passed = 0
  let mut i = 0
  let mut reported = 0
  while i + 4 < fixtures.length() {
    let title = fixtures[i]
    let dialect_name = fixtures[i + 1]
    let meta = parse_meta(fixtures[i + 2])
    let sql = fixtures[i + 3]
    let expected = fixtures[i + 4]
    i += 5
    total += 1
    if dialect_name == "" {
      base_total += 1
    }
    let result : Result[String, String] = try {
      let dialect = if dialect_name == "" {
        None
      } else {
        Some(@core.Dialect::get_or_raise(dialect_name))
      }
      let case_ = { dialect, meta }
      let expression = @core.parse_one(sql, dialect?)
      let optimized = runner(expression, case_)
      match output {
        Some(f) => Ok(f(optimized, case_))
        None => Ok(@optimizer.sql_of(optimized, dialect?, pretty~))
      }
    } catch {
      err => Err("ERROR: \{err}")
    }
    let got = match result {
      Ok(s) => s
      Err(s) => s
    }
    let ok = outcome_matches(got, expected)
    if ok {
      passed += 1
      if dialect_name == "" {
        base_passed += 1
      }
    } else {
      if result is Err(_) {
        errors += 1
      } else {
        mismatches += 1
      }
      if reported < max_report && (dialect_name == "" || report_dialects) {
        reported += 1
        println(
          "MISMATCH [\{name}] [\{dialect_name}] \{title}\n  sql: \{sql}\n  got: \{got}\n  exp: \{expected}",
        )
      }
    }
  }
  println(
    "OPTIMIZER \{name}: total=\{total} passed=\{passed} mismatches=\{mismatches} errors=\{errors} (base dialect: total=\{base_total} passed=\{base_passed})",
  )
  assert_eq(passed, total)
}

///|
/// Whether a run's outcome (`got`: the output, or "ERROR: <error>") matches the one
/// recorded from Python (`expected`: the output, or "ERROR: <Class>: <message>").
/// sqlglot errors must have the same class and message. Python-internal exceptions
/// (AssertionError, KeyError, ...: crashes of the Python implementation) can't be
/// reproduced; any error of the port is accepted for them.
fn outcome_matches(got : String, expected : String) -> Bool {
  guard expected.has_prefix("ERROR: ") else { return got == expected }
  let rest = expected.unsafe_substring(start=7, end=expected.length())
  let class = match rest.find(":") {
    Some(i) => rest.unsafe_substring(start=0, end=i)
    None => rest
  }
  if sqlglot_error_classes.contains(class) {
    got == expected
  } else {
    got.has_prefix("ERROR: ")
  }
}

///|
let sqlglot_error_classes : Array[String] = [
  "TokenError", "ParseError", "UnsupportedError", "OptimizeError", "SchemaError",
  "ExecuteError", "ValueError",
]
