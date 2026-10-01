// Runs the fixtures recorded from the Python executor by tools/gen_executor_fixtures.py.

///|
/// The Python exception type name of an error raised by `execute`.
fn error_kind(e : Error) -> String {
  match e {
    @executor.ExecuteError(_, ..) => "ExecuteError"
    @executor.PyException(k, _) => k
    @core.SqlglotError::ParseError(_) => "ParseError"
    @core.SqlglotError::TokenError(_) => "TokenError"
    @core.SqlglotError::UnsupportedError(_) => "UnsupportedError"
    @core.SqlglotError::OptimizeError(_) => "OptimizeError"
    @core.SqlglotError::SchemaError(_) => "SchemaError"
    @core.SqlglotError::ExecuteError(_) => "ExecuteError"
    @core.SqlglotError::ValueError(_) => "ValueError"
    _ => "Exception"
  }
}

///|
fn cause_kind(e : Error) -> String {
  match e {
    @executor.ExecuteError(_, cause=Some(c)) => error_kind(c)
    _ => ""
  }
}

///|
/// Checks an execution outcome against a recorded Python one.
fn check_outcome(
  run : () -> @executor.Table raise,
  kind : String,
  x : String,
  y : String,
  ordered : Bool,
) -> Unit raise {
  let result = run() catch {
    e => {
      if kind != "error" {
        fail(
          "unexpected error: \{error_kind(e)}: \{@executor.error_message(e)}",
        )
      }
      if error_kind(e) != x || cause_kind(e) != y {
        fail(
          "expected \{x}(cause=\{y}), got \{error_kind(e)}(cause=\{cause_kind(e)}): \{@executor.error_message(e)}",
        )
      }
      return
    }
  }
  if kind == "error" {
    fail("expected \{x}(cause=\{y}), got \{rows_value(result).repr()}")
  }
  let columns = @executor.Value::Tuple(result.columns.map(c => Str(c))).repr()
  if columns != x {
    fail("columns: \{columns} != \{x}")
  }
  if ordered {
    let rows = rows_value(result).repr()
    if rows != y {
      fail("rows:\n  actual:   \{rows}\n  expected: \{y}")
    }
  } else {
    let actual = sorted_reprs(rows_value(result))
    let expected = sorted_reprs(py(y))
    if actual != expected {
      fail(
        "rows (unordered):\n  actual:   \{Repr(actual)}\n  expected: \{Repr(expected)}",
      )
    }
  }
}

///|
test "fixture: test_executor cases" {
  let now : @executor.PyDateTime = {
    date: { year: 2020, month: 6, day: 15, },
    time: { hour: 12, minute: 0, second: 0, microsecond: 0, },
    tz: None,
  }
  let s = Suite::new("fixture test_executor cases")
  with_now(now, () => {
    for case in executor_cases {
      let (sql, schema, tables, dialect, kind, x, y, ordered) = case
      s.check(sql, () => {
        let schema = mk_schema(schema)
        let tables = mk_tables(tables)
        check_outcome(
          () => @executor.execute(sql, schema~, tables~, dialect~),
          kind,
          x,
          y,
          ordered,
        )
      })
    }
  })
  s.finish()
}

///|
/// Splits a fixture row on unescaped `|` and unescapes the fields.
fn split_fields(line : String) -> Array[String] {
  let fields = []
  let sb = StringBuilder()
  let chars = line.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' && i + 1 < chars.length() {
      match chars[i + 1] {
        'n' => sb.write_char('\n')
        'r' => sb.write_char('\r')
        other => sb.write_char(other)
      }
      i += 2
    } else if c == '|' {
      fields.push(sb.to_string())
      sb.reset()
      i += 1
    } else {
      sb.write_char(c)
      i += 1
    }
  }
  fields.push(sb.to_string())
  fields
}

///|
/// Converts a field like `TestExecutor.setUpClass` does: `t(v)` for the column's type,
/// and `None` for an empty non-string value.
fn typed_field(code : Char, v : String) -> @executor.Value raise {
  if code != 's' && v == "" {
    return Null
  }
  match code {
    'i' => @executor.py_int(Str(v))
    'f' => @executor.py_float(Str(v))
    'b' => Bool(v != "")
    _ => Str(v)
  }
}

///|
fn tpcds_data() -> Map[String, @executor.Table] raise {
  let out : Map[String, @executor.Table] = Map([])
  for entry in tpcds_tables {
    let (name, columns, codes, text) = entry
    let codes = codes.to_array()
    let rows = []
    for line in text.split("\n") {
      let line = line.to_owned()
      if line == "" && columns.length() > 0 {
        continue
      }
      let fields = split_fields(line)
      rows.push(fields.mapi((i, v) => typed_field(codes[i], v)))
    }
    out[name] = @executor.Table::new(columns~, rows~)
  }
  out
}

///|
test "fixture: tpc-ds" {
  let data = tpcds_data()
  let schema = @optimizer.schema_from_json_string(tpcds_schema_json)
  let s = Suite::new("fixture tpc-ds")
  for case in tpcds_cases {
    let (number, sql, kind, x, y, ordered) = case
    s.check("tpc-ds \{number}", () => {
      let expression = @sqlglot.parse_one(sql)
      let tables : Map[String, @executor.TableData] = Map([])
      for t in @core.find_tables(expression) {
        match data.get(t.name()) {
          Some(table) => tables[t.name()] = Tbl(table)
          None => ()
        }
      }
      check_outcome(
        () => @executor.execute(expression, schema~, tables~),
        kind,
        x,
        y,
        ordered,
      )
    })
  }
  s.finish()
}
