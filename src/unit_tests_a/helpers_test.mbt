// Shared helpers for the ported Python unit tests (tests/test_transpile.py,
// tests/test_parser.py, tests/test_generator.py, tests/test_errors.py,
// tests/test_tokens.py, tests/test_jsonpath.py).
//
// A `T` collects assertion failures so that one failing assertion does not hide
// the others of the same Python test method; `T::done` fails the test at the end.

///|
priv struct T {
  fails : Array[String]
}

///|
fn t() -> T {
  { fails: [], }
}

///|
fn T::fail(self : T, msg : String, loc : SourceLoc) -> Unit {
  self.fails.push("\{loc}: \{msg}")
}

///|
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
/// Python `assertEqual(expr1, expr2)` for expressions (structural equality).
#callsite(autofill(loc))
fn T::eq_expr(
  self : T,
  actual : @core.Expr,
  expected : @core.Expr,
  loc~ : SourceLoc,
) -> Unit {
  if actual != expected {
    self.fail(
      "\n    actual:   \{actual.canonical()}\n    expected: \{expected.canonical()}",
      loc,
    )
  }
}

///|
fn[X : Debug] repr_of(x : X) -> String {
  Repr(x).to_string().escape()
}

///|
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

///|
/// Python `assertRaises(...)`: expects `f` to raise; returns the error.
#callsite(autofill(loc))
fn T::raises(self : T, f : () -> Unit raise, loc~ : SourceLoc) -> Error? {
  try f() catch {
    e => Some(e)
  } noraise {
    _ => {
      self.fail("expected an error to be raised", loc)
      None
    }
  }
}

///|
/// Expects `f` to raise a `ParseError`; returns it.
#callsite(autofill(loc))
fn T::raises_parse(
  self : T,
  f : () -> Unit raise,
  loc~ : SourceLoc,
) -> @core.SqlglotError? {
  match self.raises(f, loc~) {
    Some(@core.ParseError(_, _) as e) => Some(e)
    Some(e) => {
      self.fail("expected ParseError, got \{e}", loc)
      None
    }
    None => None
  }
}

///|
/// `str(ctx.exception)` for a caught sqlglot error ("" when nothing was raised).
fn msg_of(e : @core.SqlglotError?) -> String {
  match e {
    Some(e) => e.message()
    None => ""
  }
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
/// `TestTranspile.validate`: `transpile(sql, **kwargs)[0] == target`.
#callsite(autofill(loc))
fn T::validate(
  self : T,
  sql : String,
  target : String,
  read? : String = "",
  write? : String,
  identity? : Bool = true,
  pretty? : Bool = false,
  identify? : Bool = false,
  leading_comma? : Bool = false,
  pad? : Int = 2,
  indent? : Int = 2,
  loc~ : SourceLoc,
) -> Unit {
  self.eqf(
    () => {
      @sqlglot.transpile(
        sql,
        read~,
        write?,
        identity~,
        pretty~,
        identify=if identify { Always } else { Never },
        leading_comma~,
        pad~,
        indent~,
      )[0]
    },
    target,
    loc~,
  )
}

///|
/// `parse_one(sql, read).sql(write)`.
fn sql_of(sql : String, read? : String = "", write? : String) -> String raise {
  let w = match write {
    Some(w) => w
    None => read
  }
  @sqlglot.generate(@sqlglot.parse_one(sql, read~), dialect=w)
}

///|
/// `expression.sql()` with the base dialect.
fn gen(e : @core.Expr) -> String raise {
  @sqlglot.generate(e)
}

///|
/// Log messages captured since the last call, with the given level prefix
/// ("WARNING: ", "ERROR: ", "INFO: ") removed; messages of other levels are dropped.
fn logged(level : String) -> Array[String] {
  let prefix = level + ": "
  @core.take_log_messages().filter_map(m => {
    if m.has_prefix(prefix) {
      Some(m.unsafe_substring(start=prefix.length(), end=m.length()))
    } else {
      None
    }
  })
}
