// Shared helpers for the hand-ported direct assertions of tests/dialects/test_*.py
// (the Validator checks themselves are replayed from fixtures by src/dialect_tests).
//
// One file per Python test module (test_<module>_test.mbt); one MoonBit test per
// Python test method, named "TestClass.test_method" (tools/gen_dialect_fixtures.py
// uses these names for docs/dialect-test-manifest.md).
//
// A `T` mirrors a `Validator` instance: it carries the test class' dialect and collects
// assertion failures so that one failing assertion does not hide the others of the
// same Python test method; `T::done` fails the test at the end.

///|
priv struct T {
  dialect : String
  fails : Array[String]
}

///|
/// A validator for `dialect` (Python `Validator.dialect`; "" is the base dialect).
fn t(dialect? : String = "") -> T {
  @sqlglot.register_dialects()
  @core.take_log_messages() |> ignore
  { dialect, fails: [], }
}

///|
fn T::fail(self : T, msg : String, loc : SourceLoc) -> Unit {
  self.fails.push("\{loc}: \{msg}")
}

///|
fn T::done(self : T) -> Unit raise {
  if !self.fails.is_empty() {
    fail(
      "\{self.fails.length()} assertion(s) failed:\n" + self.fails.join("\n"),
    )
  }
}

///|
fn[X : Debug] repr_of(x : X) -> String {
  Repr(x).to_string().escape()
}

///|
/// Python `assertEqual(actual, expected)`.
#callsite(autofill(loc))
fn[X : Debug + Eq] T::eq(
  self : T,
  actual : X,
  expected : X,
  loc~ : SourceLoc,
) -> Unit {
  if actual != expected {
    self.fail(
      "\n    actual:   \{repr_of(actual)}\n    expected: \{repr_of(expected)}",
      loc,
    )
  }
}

///|
/// Python `assertNotEqual(actual, expected)`.
#callsite(autofill(loc))
fn[X : Debug + Eq] T::ne(
  self : T,
  actual : X,
  expected : X,
  loc~ : SourceLoc,
) -> Unit {
  if actual == expected {
    self.fail("\n    both equal: \{repr_of(actual)}", loc)
  }
}

///|
/// Python `assertEqual(expr1, expr2)` for expressions (structural equality).
#callsite(autofill(loc))
fn T::eq_expr(
  self : T,
  actual : @core.Expr?,
  expected : @core.Expr?,
  loc~ : SourceLoc,
) -> Unit {
  if actual != expected {
    let show = (e : @core.Expr?) => {
      match e {
        Some(e) => e.canonical()
        None => "None"
      }
    }
    self.fail(
      "\n    actual:   \{show(actual)}\n    expected: \{show(expected)}",
      loc,
    )
  }
}

///|
/// Python `assertTrue(cond)` / `assert cond`.
#callsite(autofill(loc))
fn T::ok(
  self : T,
  cond : Bool,
  msg? : String = "condition is false",
  loc~ : SourceLoc,
) -> Unit {
  if !cond {
    self.fail(msg, loc)
  }
}

///|
/// Python `expression.assert_is(exp.Kind)` (isinstance); returns the expression so
/// that chains like `e.assert_is(A).this.assert_is(B)` can be written.
#callsite(autofill(loc))
fn T::is_a(
  self : T,
  e : @core.Expr?,
  kind : @core.Kind,
  loc~ : SourceLoc,
) -> @core.Expr {
  match e {
    Some(e) => {
      if !e.kind.is_a(kind) {
        self.fail("\{e.kind} is not a \{kind}", loc)
      }
      e
    }
    None => {
      self.fail("None is not a \{kind}", loc)
      @core.mk0(kind)
    }
  }
}

///|
/// Python `assertIn(needle, haystack)` for strings.
#callsite(autofill(loc))
fn T::contains(
  self : T,
  haystack : String,
  needle : String,
  loc~ : SourceLoc,
) -> Unit {
  if !haystack.contains(needle) {
    self.fail(
      "\n    \{repr_of(needle)}\n    not found in: \{repr_of(haystack)}",
      loc,
    )
  }
}

///|
/// Python `assertNotIn(needle, haystack)` for strings.
#callsite(autofill(loc))
fn T::not_contains(
  self : T,
  haystack : String,
  needle : String,
  loc~ : SourceLoc,
) -> Unit {
  if haystack.contains(needle) {
    self.fail(
      "\n    \{repr_of(needle)}\n    unexpectedly found in: \{repr_of(haystack)}",
      loc,
    )
  }
}

///|
/// Runs `f`, recording a failure if it raises; returns its result.
#callsite(autofill(loc))
fn[X] T::run(self : T, f : () -> X raise, loc~ : SourceLoc) -> X? {
  try f() catch {
    e => {
      self.fail("unexpected error: \{e}", loc)
      None
    }
  } noraise {
    x => Some(x)
  }
}

///|
/// Python `assertEqual(f(), expected)` where `f` may raise.
#callsite(autofill(loc))
fn[X : Debug + Eq] T::eqf(
  self : T,
  f : () -> X raise,
  expected : X,
  loc~ : SourceLoc,
) -> Unit {
  match self.run(f, loc~) {
    Some(actual) => self.eq(actual, expected, loc~)
    None => ()
  }
}

// ---------------------------------------------------------------------------
// Errors

///|
/// Python's exception class name and message (`type(e).__name__`, `str(e)`).
fn error_parts(e : Error) -> (String, String) {
  match e {
    @core.TokenError(m, ..) => ("TokenError", m)
    @core.ParseError(m, _) => ("ParseError", m)
    @core.UnsupportedError(m) => ("UnsupportedError", m)
    @core.OptimizeError(m) => ("OptimizeError", m)
    @core.SchemaError(m) => ("SchemaError", m)
    @core.ExecuteError(m) => ("ExecuteError", m)
    @core.ValueError(m) => ("ValueError", m)
    e => ("other", e.to_string())
  }
}

///|
/// Python `with self.assertRaises(<class>) as cm: f()`: expects `f` to raise a sqlglot
/// error of the given Python class ("ParseError", "UnsupportedError", "TokenError",
/// "ValueError", ...). Returns the message (`str(cm.exception)`), or "" on failure.
/// `message` checks the whole message, `contains` a substring (`assertRaisesRegex`
/// with a plain-text pattern).
#callsite(autofill(loc))
fn T::raises(
  self : T,
  f : () -> Unit raise,
  class : String,
  message? : String,
  contains? : String,
  loc~ : SourceLoc,
) -> String {
  try f() catch {
    e => {
      let (got_class, got_message) = error_parts(e)
      if got_class != class {
        self.fail("expected \{class}, got \{got_class}: \{got_message}", loc)
        return ""
      }
      if message is Some(m) && m != got_message {
        self.fail(
          "\n    message:  \{repr_of(got_message)}\n    expected: \{repr_of(m)}",
          loc,
        )
      }
      if contains is Some(m) && !got_message.contains(m) {
        self.fail(
          "\n    message:  \{repr_of(got_message)}\n    lacks:    \{repr_of(m)}",
          loc,
        )
      }
      got_message
    }
  } noraise {
    _ => {
      self.fail("expected \{class} to be raised", loc)
      ""
    }
  }
}

// ---------------------------------------------------------------------------
// Logging

///|
/// Python `with self.assertLogs(logger) as cm: f()`: runs `f` and returns `cm.output`
/// ("LEVEL:sqlglot:message" strings); records a failure when nothing was logged
/// (`assertLogs` fails in that case). All sqlglot loggers are named "sqlglot".
/// With `level="WARNING"` only warnings and errors are captured.
#callsite(autofill(loc))
fn T::assert_logs(
  self : T,
  f : () -> Unit raise,
  level? : String = "INFO",
  loc~ : SourceLoc,
) -> Array[String] {
  @core.take_log_messages() |> ignore
  self.run(f, loc~) |> ignore
  let output = captured_logs(level~)
  if output.is_empty() {
    self.fail("no logs of level \{level} or higher triggered", loc)
  }
  output
}

///|
/// The log messages since the last call in Python's `assertLogs` output format
/// ("WARNING:sqlglot:message"), keeping only those of `level` or higher.
fn captured_logs(level? : String = "INFO") -> Array[String] {
  let rank = (l : String) => {
    match l {
      "DEBUG" => 0
      "INFO" => 1
      "WARNING" => 2
      "ERROR" => 3
      _ => 4
    }
  }
  @core.take_log_messages().filter_map(m => {
    guard m.find(": ") is Some(i) else { None }
    let l = m.unsafe_substring(start=0, end=i)
    if rank(l) < rank(level) {
      return None
    }
    Some("\{l}:sqlglot:\{m.unsafe_substring(start=i + 2, end=m.length())}")
  })
}

// ---------------------------------------------------------------------------
// Validator

///|
/// `Validator.parse_one`: parses `sql` with the test's dialect.
fn T::parse_one(
  self : T,
  sql : String,
  error_level? : @core.ErrorLevel,
  max_nodes? : Int,
) -> @core.Expr raise {
  @sqlglot.parse_one(sql, read=self.dialect, error_level?, max_nodes?)
}

///|
/// `Validator.validate_identity`: parses `sql`, checks it generates `write_sql` (or
/// `sql`) in the test's dialect and returns the parsed expression.
#callsite(autofill(loc))
fn T::validate_identity(
  self : T,
  sql : String,
  write_sql? : String,
  pretty? : Bool = false,
  check_command_warning? : Bool = false,
  identify? : Bool = false,
  loc~ : SourceLoc,
) -> @core.Expr raise {
  if check_command_warning {
    @core.take_log_messages() |> ignore
  }
  let expression = self.parse_one(sql)
  if check_command_warning {
    let prefix = sql.to_array()
    let n = if prefix.length() > 100 { 100 } else { prefix.length() }
    let warning = "'\{String::from_array(prefix[:n])}' contains unsupported syntax"
    let logs = captured_logs()
    if !logs.iter().any(m => m.contains(warning)) {
      self.fail("missing Command fallback warning for \{repr_of(sql)}", loc)
    }
  }
  let expected = match write_sql {
    Some(w) => w
    None => sql
  }
  let got = @sqlglot.generate(
    expression,
    dialect=self.dialect,
    pretty~,
    identify=identify_of(identify),
  )
  self.eq(got, expected, loc~)
  expression
}

///|
/// `Validator.validate_transpile`: parses `sql` with the test's dialect and checks it
/// generates `write_sql` in `write_dialect`; returns the parsed expression.
#callsite(autofill(loc))
fn T::validate_transpile(
  self : T,
  sql : String,
  write_sql : String,
  write_dialect? : String = "",
  loc~ : SourceLoc,
) -> @core.Expr raise {
  let expression = self.parse_one(sql)
  self.eq(@sqlglot.generate(expression, dialect=write_dialect), write_sql, loc~)
  expression
}

///|
/// `Validator.validate_all`: everything in `read` must transpile to `sql`, and `sql`
/// must transpile to everything in `write` (`write_unsupported` lists the write
/// dialects mapped to `UnsupportedError` in Python).
#callsite(autofill(loc))
fn T::validate_all(
  self : T,
  sql : String,
  read? : Map[String, String] = {},
  write? : Map[String, String] = {},
  write_unsupported? : Array[String] = [],
  pretty? : Bool = false,
  identify? : Bool = false,
  loc~ : SourceLoc,
) -> Unit raise {
  let expression = self.parse_one(sql)
  for read_dialect, read_sql in read {
    let got = @sqlglot.generate(
      @sqlglot.parse_one(read_sql, read=read_dialect),
      dialect=self.dialect,
      unsupported_level=Ignore,
      pretty~,
      identify=identify_of(identify),
    )
    self.eq(got, sql, loc~)
  }
  for write_dialect, write_sql in write {
    let got = @sqlglot.generate(
      expression,
      dialect=write_dialect,
      unsupported_level=Ignore,
      pretty~,
      identify=identify_of(identify),
    )
    self.eq(got, write_sql, loc~)
  }
  for write_dialect in write_unsupported {
    self.raises(
      () => {
        ignore(
          @sqlglot.generate(
            expression,
            dialect=write_dialect,
            unsupported_level=Raise,
          ),
        )
      },
      "UnsupportedError",
      loc~,
    )
    |> ignore
  }
}

// ---------------------------------------------------------------------------
// Shortcuts

///|
/// `parse_one(sql, read=read)` (the module-level function, not the validator's).
fn parse_one(sql : String, read? : String = "") -> @core.Expr raise {
  @sqlglot.parse_one(sql, read~)
}

///|
/// `expression.sql(dialect)`.
fn sql(
  e : @core.Expr,
  dialect? : String = "",
  pretty? : Bool = false,
  identify? : Bool = false,
  unsupported_level? : @core.ErrorLevel = Warn,
) -> String raise {
  @sqlglot.generate(
    e,
    dialect~,
    pretty~,
    identify=identify_of(identify),
    unsupported_level~,
  )
}

///|
/// Python `identify=True/False` as the facade's `Identify` mode.
fn identify_of(identify : Bool) -> @sqlglot.Identify {
  if identify {
    Always
  } else {
    Never
  }
}
