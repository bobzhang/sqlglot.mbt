// Replays the `parse_one` / `parse` / `transpile` / `Expr.sql` calls made directly by
// the Python dialect tests that raised a sqlglot error (recorded by
// tools/extract_dialect_tests.py as `error_call` cases) and checks that the port raises
// the same error class with the same message.

///|
fn error_level_of(name : String) -> @core.ErrorLevel {
  match name {
    "IGNORE" => Ignore
    "WARN" => Warn
    "RAISE" => Raise
    "IMMEDIATE" => Immediate
    _ => abort("unknown error level \{name}")
  }
}

///|
/// `"<Python exception class>: <message>"` for an error raised by the port.
fn describe_error(e : Error) -> String {
  match e {
    @core.TokenError(m, ..) => "TokenError: \{m}"
    @core.ParseError(m, _) => "ParseError: \{m}"
    @core.UnsupportedError(m) => "UnsupportedError: \{m}"
    @core.OptimizeError(m) => "OptimizeError: \{m}"
    @core.SchemaError(m) => "SchemaError: \{m}"
    @core.ExecuteError(m) => "ExecuteError: \{m}"
    @core.ValueError(m) => "ValueError: \{m}"
    e => "other error: \{e}"
  }
}

///|
fn run_error_call(
  fn_name : String,
  dialect : String,
  opts : Map[String, Json],
  source : String,
) -> Unit raise {
  @sqlglot.register_dialects()
  let mut error_level = None
  let mut unsupported_level = None
  let mut max_nodes = None
  let mut write = None
  for key, value in opts {
    match (key, value) {
      ("error_level", String(l)) => error_level = Some(error_level_of(l))
      ("unsupported_level", String(l)) =>
        unsupported_level = Some(error_level_of(l))
      ("max_nodes", Number(n, ..)) => max_nodes = Some(n.to_int())
      ("write", String(w)) => write = Some(w)
      _ => fail("unsupported option \{key}=\{value.stringify()}")
    }
  }
  match fn_name {
    "parse_one" =>
      @sqlglot.parse_one(source, read=dialect, error_level?, max_nodes?)
      |> ignore
    "parse" =>
      @sqlglot.parse(source, read=dialect, error_level?, max_nodes?) |> ignore
    "transpile" =>
      @sqlglot.transpile(
        source,
        read=dialect,
        write?,
        error_level?,
        unsupported_level?,
      )
      |> ignore
    "sql" => {
      guard @core.Expr::load(@json.parse(source)) is Some(e) else {
        fail("empty expression dump")
      }
      @sqlglot.generate(e, dialect~, unsupported_level?) |> ignore
    }
    _ => fail("unknown function \{fn_name}")
  }
}

///|
fn run_error_cases(module : String, cases : Array[String]) -> Unit raise {
  if cases.length() % 6 != 0 {
    fail("malformed error fixture for \{module}: \{cases.length()} strings")
  }
  let total = cases.length() / 6
  let failures = []
  for i = 0; i < cases.length(); i = i + 6 {
    let fn_name = cases[i]
    let dialect = cases[i + 1]
    guard @json.parse(cases[i + 2]) is Object(opts) else {
      fail("malformed options \{cases[i + 2]}")
    }
    let source = cases[i + 3]
    let expected = "\{cases[i + 4]}: \{cases[i + 5]}"
    let label = "[\{fn_name} \{dialect} \{cases[i + 2]}] \{source}"
    try run_error_call(fn_name, dialect, opts, source) catch {
      e => {
        let got = describe_error(e)
        if got != expected {
          failures.push(
            "WRONG-ERROR \{label}\n  got: \{got.escape()}\n  exp: \{expected.escape()}",
          )
        }
      }
    } noraise {
      _ => failures.push("NO-ERROR \{label}\n  exp: \{expected.escape()}")
    }
  }
  for f in failures {
    println(f)
  }
  println(
    "DIALECT ERRORS \{module}: total=\{total} passed=\{total - failures.length()}",
  )
  if !failures.is_empty() {
    fail("\{module}: \{failures.length()} error-case mismatches")
  }
}
