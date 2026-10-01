// Differential numeric-boundary tests against the fixtures recorded from Python by
// tools/gen_numeric_fixtures.py.
//
// Python integers are unbounded; the port's AST integers (`Value::Int`), host ints
// (`PyInt`) and executor integers are Int64. Where Python produces an integer outside
// Int64 the port must raise an error that mentions "Int64 range" instead of wrapping.

///|
fn full_error_message(e : Error) -> String {
  match e {
    @core.SqlglotError::ValueError(m) => m
    @core.SqlglotError::OptimizeError(m) => m
    @core.SqlglotError::ExecuteError(m) => m
    @core.SqlglotError::UnsupportedError(m) => m
    @core.SqlglotError::ParseError(m, _) => m
    @core.SqlglotError::TokenError(m, ..) => m
    _ => @executor.error_message(e)
  }
}

///|
fn is_int64_limit(e : Error) -> Bool {
  let m = full_error_message(e)
  let cause = match e {
    @executor.ExecuteError(_, cause=Some(c)) => full_error_message(c)
    _ => ""
  }
  m.contains("Int64 range") || cause.contains("Int64 range")
}

///|
/// Runs `f`; an Int64-range error is reported as "int64-limit".
fn attempt_num(f : () -> String raise) -> String {
  f() catch {
    e => if is_int64_limit(e) { "int64-limit" } else { error_name(e) }
  }
}

///|
/// Whether `sql` holds an integer literal outside Int64 (digits only, no exponent).
fn has_big_literal(sql : String) -> Bool {
  let chars = sql.to_array()
  let mut i = 0
  while i < chars.length() {
    if chars[i] >= '0' && chars[i] <= '9' {
      let st = i
      while i < chars.length() &&
            ((chars[i] >= '0' && chars[i] <= '9') || chars[i] == '_') {
        i += 1
      }
      let digits = String::from_array(chars[st:i]).replace_all(old="_", new="")
      let next = if i < chars.length() { chars[i] } else { ' ' }
      let prev = if st > 0 { chars[st - 1] } else { ' ' }
      if next != '.' && next != 'e' && next != 'E' && prev != '.' && prev != 'x' {
        let trimmed = digits.trim_start(chars="0").to_owned()
        if trimmed.length() > 19 ||
          (trimmed.length() == 19 && trimmed > "9223372036854775807") {
          return true
        }
      }
    } else {
      i += 1
    }
  }
  false
}

///|
/// `actual` matches Python's `expected`, or is an Int64-range error for SQL that holds a
/// literal beyond Int64 (a documented limitation).
fn Report::expect_num(
  self : Report,
  label : String,
  sql : String,
  actual : String,
  expected : String,
  limits : Array[String],
) -> Unit {
  if actual == "int64-limit" && has_big_literal(sql) {
    limits.push(label)
    self.passed += 1
  } else {
    self.expect(label, actual, expected)
  }
}

///|
test "numeric: boundary literals round trip and simplify like Python" {
  let r = Report::new("numeric sql")
  let limits = []
  for row in num_sql {
    let (d, sql, roundtrip, simplified) = row
    let label = "[\{d}] \{sql}"
    r.expect_num(
      "roundtrip \{label}",
      sql,
      attempt_num(() => {
        @sqlglot.generate(@sqlglot.parse_one(sql, read=d), dialect=d)
      }),
      roundtrip,
      limits,
    )
    r.expect_num(
      "simplify \{label}",
      sql,
      attempt_num(() => {
        let e = @optimizer.simplify(
          @sqlglot.parse_one(sql, read=d),
          dialect=@sqlglot.dialect(d),
        )
        @sqlglot.generate(e, dialect=d)
      }),
      simplified,
      limits,
    )
  }
  let non_json = limits.filter(l => !l.contains("$[") && !l.contains("$.b["))
  println(
    "ROBUST numeric sql: \{limits.length()} documented Int64 limits (JSON path subscripts; other: \{non_json.length()})",
  )
  for l in non_json {
    println("  \{l}")
  }
  r.finish()
}

///|
test "numeric: constant folding matches Python" {
  let r = Report::new("numeric simplify")
  let limits = []
  for row in num_simplify {
    let (sql, expected) = row
    r.expect_num(
      sql,
      sql,
      attempt_num(() => {
        @sqlglot.generate(@optimizer.simplify(@sqlglot.parse_one(sql)))
      }),
      expected,
      limits,
    )
  }
  r.finish()
}

///|
test "numeric: executor integers match Python or refuse to wrap" {
  let r = Report::new("numeric executor")
  let limits = []
  let rows : Array[Array[(String, @executor.Value)]] = num_exec_values.mapi((
    i,
    v,
  ) => [("i", Int(i.to_int64())), ("a", Int(v))])
  let tables : Map[String, @executor.TableData] = { "t": Records(rows) }
  for case in num_exec {
    let (sql, kind, columns, expected) = case
    let actual = attempt_num(() => {
      let t = @executor.execute(sql, tables~)
      let cols = @executor.Value::Tuple(t.columns.map(c => Str(c))).repr()
      let rows = @executor.Value::List(t.rows.map(r => Tuple(r))).repr()
      "ok|\{cols}|\{rows}"
    })
    let expected = match kind {
      "ok" => "ok|\{columns}|\{expected}"
      "overflow" => "int64-limit"
      _ => "error:\{columns}"
    }
    r.expect_num(sql, sql, actual, expected, limits)
  }
  println("ROBUST numeric executor: \{limits.length()} documented Int64 limits")
  r.finish()
}

///|
test "numeric: serde of integer arguments matches Python or refuses" {
  let r = Report::new("numeric serde")
  for case in num_serde {
    let (sql, kind, payload, expected_sql) = case
    if kind == "error" {
      r.expect(
        sql,
        attempt_num(() => @sqlglot.generate(@sqlglot.parse_one(sql))),
        payload,
      )
      continue
    }
    // Loading Python's payload.
    let loaded = attempt_num(() => {
      match @core.Expr::load(@json.parse(payload)) {
        Some(e) => @sqlglot.generate(e)
        None => "None"
      }
    })
    // Parsing in the port, then dump -> load.
    let parsed = attempt_num(() => {
      let e = @sqlglot.parse_one(sql)
      let text = e.dump().stringify()
      match @core.Expr::load(@json.parse(text)) {
        Some(back) => @sqlglot.generate(back)
        None => "None"
      }
    })
    let expected = if kind == "overflow" { "int64-limit" } else { expected_sql }
    r.expect("load \{sql}", loaded, expected)
    r.expect("parse+dump+load \{sql}", parsed, expected)
  }
  r.finish()
}

///|
test "numeric: Literal.to_py and is_int match Python or refuse" {
  let r = Report::new("numeric to_py")
  for case in num_to_py {
    let (literal, kind, value, is_int) = case
    let e = @sqlglot.parse_one(literal) catch {
      err => {
        r.expect(literal, error_name(err), "parsed")
        continue
      }
    }
    let actual = attempt_num(() => e.to_py().py_repr())
    let expected = match kind {
      "ok" => value
      "overflow" => "int64-limit"
      _ => "error:\{value}"
    }
    r.expect("to_py \{literal}", actual, expected)
    r.expect("is_int \{literal}", if e.is_int() { "1" } else { "0" }, is_int)
  }
  r.finish()
}
