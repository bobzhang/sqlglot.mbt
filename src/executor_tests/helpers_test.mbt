// Helpers for the port of tests/test_executor.py: values, tables and schemas are written
// as Python literals and evaluated with the executor's Python evaluator.

///|
fn date_ctor(args : Array[@executor.Value]) -> @executor.Value raise {
  guard args is [Int(y), Int(m), Int(d)] else { fail("date()") }
  Date({ year: y.to_int(), month: m.to_int(), day: d.to_int(), })
}

///|
fn time_ctor(args : Array[@executor.Value]) -> @executor.Value raise {
  let f = args.map(a => {
    match a {
      Int(i) => i.to_int()
      _ => 0
    }
  })
  Time({
    hour: f[0],
    minute: f.get(1).unwrap_or(0),
    second: f.get(2).unwrap_or(0),
    microsecond: f.get(3).unwrap_or(0),
  })
}

///|
fn datetime_ctor(args : Array[@executor.Value]) -> @executor.Value raise {
  let tz = match args.last() {
    Some(Str("utc")) => Some(0)
    _ => None
  }
  let f = args.map(a => {
    match a {
      Int(i) => i.to_int()
      _ => 0
    }
  })
  DateTime({
    date: { year: f[0], month: f[1], day: f[2], },
    time: {
      hour: f.get(3).unwrap_or(0),
      minute: f.get(4).unwrap_or(0),
      second: f.get(5).unwrap_or(0),
      microsecond: 0,
    },
    tz,
  })
}

///|
fn timedelta_ctor(args : Array[@executor.Value]) -> @executor.Value raise {
  guard args is [Int(days), ..] else { fail("timedelta()") }
  TimeDelta(@executor.PyTimeDelta::from_us(days * 86400000000L))
}

///|
let literal_globals : Map[String, @executor.Value] = {
  "date": Func({ name: "date", call: date_ctor, }),
  "time": Func({ name: "time", call: time_ctor, }),
  "datetime": Func({ name: "datetime", call: datetime_ctor, }),
  "timedelta": Func({ name: "timedelta", call: timedelta_ctor, }),
}

///|
/// Evaluates a Python literal, e.g. `[(1, 'a'), (2, None)]`. `date(y, m, d)`,
/// `time(h, m, s)`, `datetime(y, m, d, h, mi, s[, 'utc'])` and `timedelta(days)` are
/// available.
fn py(src : String) -> @executor.Value raise {
  @executor.eval_code(@executor.compile_python(src), literal_globals, Null)
}

///|
fn records_of(v : @executor.Value) -> @executor.TableData raise {
  match v {
    List(rows) =>
      Records(
        rows.map(r => {
          match r {
            Dict(kvs) =>
              kvs.map(kv => {
                match kv.0 {
                  Str(k) => (k, kv.1)
                  _ => ("?", kv.1)
                }
              })
            _ => []
          }
        }),
      )
    Dict(m) => Nested(tables_of_value(Dict(m)))
    _ => fail("not a table: \{v}")
  }
}

///|
fn tables_of_value(
  v : @executor.Value,
) -> Map[String, @executor.TableData] raise {
  guard v is Dict(kvs) else { fail("not a dict") }
  let out : Map[String, @executor.TableData] = Map([])
  for kv in kvs {
    guard kv.0 is Str(k) else { fail("bad key") }
    out[k] = records_of(kv.1)
  }
  out
}

///|
/// Tables given as a Python dict literal of lists of records (possibly nested).
fn mk_tables(src : String) -> Map[String, @executor.TableData] raise {
  tables_of_value(py(src))
}

///|
fn schema_of_value(v : @executor.Value) -> @optimizer.SchemaNode raise {
  match v {
    Dict(kvs) => {
      let out : Map[String, @optimizer.SchemaNode] = Map([])
      for kv in kvs {
        guard kv.0 is Str(k) else { fail("bad key") }
        out[k] = schema_of_value(kv.1)
      }
      Dict(out)
    }
    Str(s) => Type(s)
    _ => fail("bad schema")
  }
}

///|
/// A schema given as a Python dict literal.
fn mk_schema(src : String) -> Map[String, @optimizer.SchemaNode] raise {
  guard schema_of_value(py(src)) is Dict(m) else { fail("bad schema") }
  m
}

///|
fn rows_value(t : @executor.Table) -> @executor.Value {
  List(t.rows.map(r => Tuple(r)))
}

///|
/// Asserts `rows == expected` (Python equality; `expected` is a Python literal).
#callsite(autofill(loc))
fn assert_rows(
  t : @executor.Table,
  expected : String,
  loc~ : SourceLoc,
) -> Unit raise {
  let e = py(expected)
  let a = rows_value(t)
  if !@executor.py_eq(a, e) {
    fail("rows differ:\n  actual:   \{a.repr()}\n  expected: \{e.repr()}", loc~)
  }
}

///|
fn sorted_reprs(v : @executor.Value) -> Array[String] raise {
  let items = @executor.py_iter(v).map(x => x.repr())
  items.sort()
  items
}

///|
/// Asserts that the rows equal `expected` as multisets (Python `assertCountEqual` and,
/// for duplicate-free rows, `set(rows) == set(expected)`).
#callsite(autofill(loc))
fn assert_rows_unordered(
  t : @executor.Table,
  expected : String,
  loc~ : SourceLoc,
) -> Unit raise {
  let a = sorted_reprs(rows_value(t))
  let e = sorted_reprs(py(expected))
  if a != e {
    fail("rows differ:\n  actual:   \{a}\n  expected: \{e}", loc~)
  }
}

///|
#callsite(autofill(loc))
fn assert_set(
  t : @executor.Table,
  expected : String,
  loc~ : SourceLoc,
) -> Unit raise {
  let a = sorted_reprs(
    @executor.Value::List(@executor.py_set(t.rows.map(r => Tuple(r)))),
  )
  let e = sorted_reprs(
    @executor.Value::List(@executor.py_set(@executor.py_iter(py(expected)))),
  )
  if a != e {
    fail("row sets differ:\n  actual:   \{a}\n  expected: \{e}", loc~)
  }
}

///|
#callsite(autofill(loc))
fn assert_columns(
  t : @executor.Table,
  expected : Array[String],
  loc~ : SourceLoc,
) -> Unit raise {
  if t.columns != expected {
    fail("columns differ: \{t.columns} != \{expected}", loc~)
  }
}

///|
/// Runs `execute` and returns the error it raises.
fn execute_error(
  sql : String,
  schema? : Map[String, @optimizer.SchemaNode] = {},
  dialect? : String = "",
  tables? : Map[String, @executor.TableData] = {},
) -> Error raise {
  try @executor.execute(sql, schema~, dialect~, tables~) catch {
    e => e
  } noraise {
    t => fail("expected an error, got \{t.columns} \{rows_value(t)}")
  }
}

///|
/// A suite of checks that counts its passes and failures instead of stopping at the
/// first failure.
struct Suite {
  name : String
  mut passed : Int
  failures : Array[String]
}

///|
fn Suite::new(name : String) -> Suite {
  { name, passed: 0, failures: [], }
}

///|
fn Suite::check(self : Suite, label : String, f : () -> Unit raise) -> Unit {
  try f() catch {
    e => self.failures.push("\{label}: \{e}")
  } noraise {
    _ => self.passed += 1
  }
}

///|
fn Suite::finish(self : Suite) -> Unit raise {
  let total = self.passed + self.failures.length()
  println("EXECUTOR \{self.name}: \{self.passed}/\{total}")
  if !self.failures.is_empty() {
    fail(self.failures.join("\n"))
  }
}
