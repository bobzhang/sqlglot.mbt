// Differential Unicode tests against the fixtures recorded from Python by
// tools/gen_unicode_fixtures.py.

///|
struct Report {
  name : String
  mut passed : Int
  failures : Array[String]
}

///|
fn Report::new(name : String) -> Report {
  { name, passed: 0, failures: [], }
}

///|
fn Report::expect(
  self : Report,
  label : String,
  actual : String,
  expected : String,
) -> Unit {
  if actual == expected {
    self.passed += 1
  } else {
    self.failures.push(
      "\{label}\n    actual:   \{actual}\n    expected: \{expected}",
    )
  }
}

///|
fn Report::finish(self : Report) -> Unit raise {
  let total = self.passed + self.failures.length()
  println("ROBUST \{self.name}: \{self.passed}/\{total}")
  if !self.failures.is_empty() {
    let shown = self.failures.length().min(400)
    fail(self.failures[:shown].join("\n"))
  }
}

///|
fn fnv(h : Int, v : Int) -> Int {
  (h ^ v) * 16777619
}

///|
fn fnv_string(h : Int, s : String) -> Int {
  let mut h = fnv(h, s.char_length())
  for c in s {
    h = fnv(h, c.to_int())
  }
  h
}

///|
fn cp_flags(c : Char) -> Int {
  let bits = [
    @core.is_alpha(c),
    @core.is_decimal(c),
    @core.is_py_digit(c),
    @core.is_numeric(c),
    @core.is_space(c),
    @core.is_lower_char(c),
    @core.is_upper_char(c),
    @core.is_printable(c),
    @core.is_identifier_char(c),
    @core.is_identifier_continue(c),
    @core.is_alnum(c),
    @core.is_word_char(c),
    @core.is_decimal(c),
    @core.is_space(c),
  ]
  let mut flags = 0
  for i, b in bits {
    if b {
      flags = flags | (1 << i)
    }
  }
  flags
}

///|
test "unicode: every code point's case mappings and classes match Python" {
  inspect(@core.unicode_version == uc_python_unicode_version, content="true")
  let r = Report::new("unicode code points")
  for b, expected in uc_block_hashes {
    let mut h = 2166136261U.reinterpret_as_int()
    for c in (b * 4096)..<((b + 1) * 4096) {
      if c >= 0xD800 && c < 0xE000 {
        continue
      }
      let ch = Int::unsafe_to_char(c)
      let s = ch.to_string()
      h = fnv(h, c)
      h = fnv(h, cp_flags(ch))
      h = fnv(h, @core.decimal_value(ch))
      h = fnv_string(h, @core.py_upper(s))
      h = fnv_string(h, @core.py_lower(s))
      h = fnv_string(h, @core.py_casefold(s))
    }
    r.expect(
      "block U+\{(b * 4096).to_string(radix=16)}",
      h.to_string(),
      expected.to_string(),
    )
  }
  r.finish()
}

///|
test "unicode: re.IGNORECASE character equivalence matches Python" {
  let r = Report::new("unicode ignorecase")
  let pool = uc_ignorecase.map(x => x.0)
  for row in uc_ignorecase {
    let (p, matches) = row
    let pc = Int::unsafe_to_char(p)
    let actual = pool.filter(c => {
      c != p && @core.re_ignorecase_char_eq(pc, Int::unsafe_to_char(c))
    })
    r.expect(
      "U+\{p.to_string(radix=16)}",
      actual.map(x => x.to_string()).join(","),
      matches.map(x => x.to_string()).join(","),
    )
  }
  r.finish()
}

///|
fn str_is_space(s : String) -> Bool {
  !s.is_empty() && s.iter().all(@core.is_space)
}

///|
test "unicode: string corpus matches Python" {
  let r = Report::new("unicode strings")
  for row in uc_strings {
    let (s, upper, lower, fold, repr, flags, n, int_value) = row
    let label = @core.py_repr_str(s)
    r.expect("upper \{label}", @core.py_upper(s), upper)
    r.expect("lower \{label}", @core.py_lower(s), lower)
    r.expect("casefold \{label}", @core.py_casefold(s), fold)
    r.expect("repr \{label}", @core.py_repr_str(s), repr)
    let actual_flags = [
        @core.str_is_identifier(s),
        @core.str_is_digit(s),
        @core.str_is_alnum(s),
        str_is_space(s),
      ]
      .map(b => if b { "1" } else { "0" })
      .join("")
    r.expect("flags \{label}", actual_flags, flags)
    r.expect("len \{label}", @core.py_len(s).to_string(), n.to_string())
    let actual_int = match @core.parse_int_str(s) {
      Some(v) => v.to_string()
      None => "error"
    }
    r.expect("int \{label}", actual_int, int_value)
  }
  r.finish()
}

///|
fn error_name(e : Error) -> String {
  match e {
    @core.SqlglotError::ParseError(_) => "error:ParseError"
    @core.SqlglotError::TokenError(_) => "error:TokenError"
    @core.SqlglotError::UnsupportedError(_) => "error:UnsupportedError"
    // Python exceptions without a SqlglotError variant are ValueErrors whose message
    // starts with the Python type (e.g. "OverflowError: ...", "decimal.DivisionByZero").
    @core.SqlglotError::ValueError(m) =>
      if m.has_prefix("decimal.") {
        "error:" + m.view(start_offset=8).to_owned()
      } else {
        match m.find(":") {
          Some(k) if k > 0 && m.view(end_offset=k).has_suffix("Error") =>
            "error:" + m.view(end_offset=k).to_owned()
          _ => "error:ValueError"
        }
      }
    @core.SqlglotError::OptimizeError(_) => "error:OptimizeError"
    @core.SqlglotError::SchemaError(_) => "error:SchemaError"
    _ => "error:\{e}"
  }
}

///|
fn attempt(f : () -> String raise) -> String {
  f() catch {
    e => error_name(e)
  }
}

///|
test "unicode: SQL identifiers, tokens and normalization match Python" {
  let r = Report::new("unicode sql")
  for row in uc_sql {
    let (
      d,
      name,
      sql,
      tokens,
      roundtrip,
      normalized,
      case_sensitive,
      safe,
      quoted,
    ) = row
    let label = "[\{d}] \{@core.py_repr_str(sql)}"
    let actual_tokens = attempt(() => {
      @sqlglot.dialect(d)
      .tokenize(sql)
      .map(t => {
        "\{t.token_type.name()}:\{t.text}@\{t.line},\{t.col},\{t.start},\{t.end}"
      })
      .join(" ")
    })
    r.expect("tokens \{label}", actual_tokens, tokens)
    r.expect(
      "roundtrip \{label}",
      attempt(() => {
        @sqlglot.generate(@sqlglot.parse_one(sql, read=d), dialect=d)
      }),
      roundtrip,
    )
    r.expect(
      "normalize \{label}",
      attempt(() => {
        let e = @optimizer.normalize_identifiers(
          @sqlglot.parse_one(sql, read=d),
          dialect=@sqlglot.dialect(d),
        )
        @sqlglot.generate(e, dialect=d)
      }),
      normalized,
    )
    if sql == "SELECT \{name} FROM t" {
      r.expect(
        "case_sensitive \{label}",
        attempt(() => {
          if @sqlglot.dialect(d).case_sensitive(name) {
            "1"
          } else {
            "0"
          }
        }),
        case_sensitive,
      )
      r.expect(
        "identify=safe \{label}",
        attempt(() => {
          @sqlglot.generate(
            @sqlglot.to_identifier(name).unwrap(),
            dialect=d,
            identify=Safe,
          )
        }),
        safe,
      )
      r.expect(
        "to_identifier \{label}",
        attempt(() => {
          @sqlglot.generate(@sqlglot.to_identifier(name).unwrap(), dialect=d)
        }),
        quoted,
      )
    }
  }
  r.finish()
}

///|
test "unicode: executor string functions match Python" {
  let r = Report::new("unicode executor")
  let rows : Array[Array[(String, @executor.Value)]] = uc_exec_strings.mapi((
    i,
    s,
  ) => [("i", Int(i.to_int64())), ("s", Str(s))])
  let tables : Map[String, @executor.TableData] = { "t": Records(rows) }
  for case in uc_exec {
    let (sql, kind, columns, expected) = case
    let actual = attempt(() => {
      let t = @executor.execute(sql, tables~)
      let cols = @executor.Value::Tuple(t.columns.map(c => Str(c))).repr()
      let rows = @executor.Value::List(t.rows.map(r => Tuple(r))).repr()
      "ok|\{cols}|\{rows}"
    })
    let expected = if kind == "ok" {
      "ok|\{columns}|\{expected}"
    } else {
      "error:\{columns}"
    }
    r.expect(sql, actual, expected)
  }
  r.finish()
}
