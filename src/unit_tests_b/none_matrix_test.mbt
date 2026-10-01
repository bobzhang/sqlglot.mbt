// The missing / None / False / 0 / "" / [] / SQL NULL argument matrix: the port's
// observations are compared with the ones recorded from Python by
// tools/gen_none_matrix.py (see that file for the list of observations).
//
// The port stores no `None` values in `args`: an argument set to None at construction
// is only remembered as a key (`Expr::has_key` / `Expr::arg_keys`, Python's
// `key in e.args`), which equality/hashing, serde and SQL generation ignore like Python.
// None *list elements* are dropped, while Python keeps them (and renders them as empty
// strings: `Tuple(expressions=[1, None])` gives "(1, )", the port "(1)"). Those
// observations are listed in `port_differences` (see README "Known differences").

///|
/// "<case>|<value>|<observation>" -> the port's value, where it can't match Python.
let port_differences : Map[String, String] = {
  // None list elements are dropped: [None] is [], [1, None] is [1]
  "tuple.expressions|[None]|get": "[]",
  "tuple.expressions|[None]|truthy": "False",
  "tuple.expressions|[None]|eq_missing": "True",
  "tuple.expressions|[None]|hash_missing": "True",
  "tuple.expressions|[None]|serde_keys": "",
  "tuple.expressions|[None]|serde_get": "missing",
  "tuple.expressions|[None]|set_get": "[]",
  "tuple.expressions|[1, None]|get": "[node:Literal]",
  "tuple.expressions|[1, None]|serde_get": "[node:Literal]",
  "tuple.expressions|[1, None]|set_get": "[node:Literal]",
  "tuple.expressions|[1, None]|sql": "(1)",
  // a Literal without its required `is_string` arg: Python raises KeyError
  // (`args["is_string"]`), the port treats it as a number
  "literal.is_string|missing|sql": "1",
}

///|
fn none_matrix_value(tag : String) -> Value? {
  match tag {
    "None" => @core.null_arg
    "False" => Some(Bool(false))
    "True" => Some(Bool(true))
    "0" => Some(Int(0))
    "1" => Some(Int(1))
    "''" => Some(Str(""))
    "[]" => Some(List([]))
    "NULL" => Some(Node(@core.null_()))
    // what `Array[Expr?]` arguments become: None elements are dropped
    "[None]" => IntoValue::into_value([(None : @core.Expr?)])
    "[1, None]" => IntoValue::into_value([Some(@core.literal_number("1")), None])
    "[False]" => Some(List([Bool(false)]))
    "[1]" => Some(List([Node(@core.literal_number("1"))]))
    "[1, '']" => Some(List([Node(@core.literal_number("1")), Str("")]))
    "['', 1]" => Some(List([Str(""), Node(@core.literal_number("1"))]))
    "[1, NULL]" => Some(List([Node(@core.literal_number("1")), Node(@core.null_())]))
    _ => abort("unknown value \{tag}")
  }
}

///|
using @core {type Value, trait IntoValue}

///|
fn none_matrix_build(case_ : String, kv : Array[(String, Value?)]) -> @core.Expr {
  let args : Array[(String, &IntoValue)] = kv.map(p => (p.0, p.1 as &IntoValue))
  match case_ {
    "column.db" =>
      @core.mk(
        Column,
        [
          ("this", @core.to_identifier("b") as &IntoValue),
          ("table", @core.to_identifier("a")),
        ] +
        args,
      )
    "ordered.desc" =>
      @core.mk(
        Ordered,
        [
          ("this", @core.mk1(Column, @core.to_identifier("x")) as &IntoValue),
          ("nulls_first", false),
        ] +
        args,
      )
    "identifier.quoted" =>
      @core.mk(Identifier, [("this", "x" as &IntoValue)] + args)
    "literal.is_string" =>
      @core.mk(Literal, [("this", "1" as &IntoValue)] + args)
    "tuple.expressions" => @core.mk(Tuple, args)
    _ => abort("unknown case \{case_}")
  }
}

///|
fn none_matrix_show(v : Value?) -> String {
  match v {
    None => "missing"
    Some(Node(e)) => "node:\{e.kind}"
    Some(List(l)) => "[" + l.map(x => none_matrix_show(Some(x))).join(", ") + "]"
    Some(Str(s)) => py_repr(s)
    Some(Bool(b)) => if b { "True" } else { "False" }
    Some(Int(i)) => i.to_string()
    Some(DT(d)) => "DType.\{d}"
  }
}

///|
/// `e.args.get(key, MISSING)`: "None" for a key set to an explicit None.
fn show_arg(e : @core.Expr, key : String) -> String {
  match e.get(key) {
    None if e.has_key(key) => "None"
    v => none_matrix_show(v)
  }
}

///|
/// Python's `repr` of a simple string.
fn py_repr(s : String) -> String {
  "'\{s}'"
}

///|
fn py_bool(b : Bool) -> String {
  if b {
    "True"
  } else {
    "False"
  }
}

///|
fn sorted_keys(e : @core.Expr) -> String {
  let keys = e.arg_keys()
  // Python's lexicographic order (MoonBit's String order compares lengths first)
  keys.sort_by(py_str_compare)
  keys.join(",")
}

///|
fn py_str_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}

///|
fn none_matrix_observe(case_ : String, key : String, tag : String) -> String {
  let kv = if tag == "missing" { [] } else { [(key, none_matrix_value(tag))] }
  let e = none_matrix_build(case_, kv)
  let base = none_matrix_build(case_, [])
  let obs = []
  obs.push(("keys", sorted_keys(e)))
  obs.push(("get", show_arg(e, key)))
  obs.push(("truthy", py_bool(e.has(key))))
  obs.push(("text", py_repr(e.text(key))))
  obs.push(("eq_missing", py_bool(e == base)))
  obs.push(("hash_missing", py_bool(e.hash() == base.hash())))
  let c = e.copy()
  obs.push(("copy_keys", sorted_keys(c)))
  obs.push(("copy_eq", py_bool(c == e)))
  let loaded = try! @core.Expr::load(e.dump()).unwrap()
  obs.push(("serde_keys", sorted_keys(loaded)))
  obs.push(("serde_get", show_arg(loaded, key)))
  obs.push(("serde_eq", py_bool(loaded == e)))
  let sql = @sqlglot.generate(e) catch {
    @core.ValueError(_) => "<ValueError>"
    err => "<\{err}>"
  }
  obs.push(("sql", sql))
  if tag != "missing" {
    let s = none_matrix_build(case_, [])
    s.set(key, none_matrix_value(tag))
    obs.push(("set_keys", sorted_keys(s)))
    obs.push(("set_get", show_arg(s, key)))
  }
  obs
  .map(o => {
    let (name, value) = o
    let value = match port_differences.get("\{case_}|\{tag}|\{name}") {
      // a documented difference: check the port's value, show Python's
      Some(port) if port == value => "<python>"
      _ => value
    }
    "\{name}=\{value}"
  })
  .join("; ")
}

///|
test "none/missing/falsy argument matrix" {
  let keys = {
    "column.db": "db",
    "ordered.desc": "desc",
    "identifier.quoted": "quoted",
    "literal.is_string": "is_string",
    "tuple.expressions": "expressions",
  }
  let fails = []
  for i = 0; i < none_matrix_fixtures.length(); i = i + 3 {
    let case_ = none_matrix_fixtures[i]
    let tag = none_matrix_fixtures[i + 1]
    let expected = none_matrix_fixtures[i + 2]
    let got = none_matrix_observe(case_, keys[case_], tag)
    // replace the documented differences by Python's values
    let expected_parts = expected.split("; ").collect()
    let got_parts = got.split("; ").collect()
    let merged = []
    for j, g in got_parts {
      merged.push(
        if g.has_suffix("=<python>") && j < expected_parts.length() {
          expected_parts[j].to_owned()
        } else {
          g.to_owned()
        },
      )
    }
    let got = merged.join("; ")
    if got != expected {
      fails.push("\{case_} \{tag}\n  got: \{got}\n  exp: \{expected}")
    }
  }
  if !fails.is_empty() {
    fail(fails.join("\n"))
  }
}

///|
/// Explicit None keys are observable through `key in e.args` in Python's generators:
/// Tableau picks FINDNTH over FIND when StrPosition has an `occurrence` key, even a
/// None one (e.g. Presto's STRPOS and Tableau's own 2-argument FINDNTH set it).
/// Expected outputs recorded from Python.
test "explicit None keys: StrPosition to tableau" {
  let cases = [
    ("tableau", "FINDNTH(a, b)", "FINDNTH(a, b)"),
    ("tableau", "FINDNTH(a, b, 2)", "FINDNTH(a, b, 2)"),
    ("tableau", "FIND(a, b)", "FIND(a, b)"),
    (
      "tableau", "FIND(a, b, 3)", "IF FIND(SUBSTRING(a, 3), b) = 0 THEN 0 ELSE FIND(SUBSTRING(a, 3), b) + 3 - 1 END",
    ),
    ("oracle", "INSTR(a, b)", "FIND(a, b)"),
    (
      "oracle", "INSTR(a, b, 1)", "IF FIND(SUBSTRING(a, 1), b) = 0 THEN 0 ELSE FIND(SUBSTRING(a, 1), b) + 1 - 1 END",
    ),
    (
      "oracle", "INSTR(a, b, 1, 2)", "IF FINDNTH(SUBSTRING(a, 1), b, 2) = 0 THEN 0 ELSE FINDNTH(SUBSTRING(a, 1), b, 2) + 1 - 1 END",
    ),
    ("mysql", "INSTR(a, b)", "FIND(a, b)"),
    ("mysql", "LOCATE(b, a)", "FIND(a, b)"),
    (
      "mysql", "LOCATE(b, a, 3)", "IF FIND(SUBSTRING(a, 3), b) = 0 THEN 0 ELSE FIND(SUBSTRING(a, 3), b) + 3 - 1 END",
    ),
    ("mysql", "POSITION(b IN a)", "FIND(a, b)"),
    ("hive", "INSTR(a, b)", "FIND(a, b)"),
    ("hive", "LOCATE(b, a)", "FIND(a, b)"),
    ("spark", "INSTR(a, b)", "FIND(a, b)"),
    ("spark", "LOCATE(b, a)", "FIND(a, b)"),
    ("spark", "POSITION(b, a)", "FIND(a, b)"),
    ("bigquery", "INSTR(a, b)", "FIND(a, b)"),
    (
      "bigquery", "INSTR(a, b, 1, 2)", "IF FINDNTH(SUBSTRING(a, 1), b, 2) = 0 THEN 0 ELSE FINDNTH(SUBSTRING(a, 1), b, 2) + 1 - 1 END",
    ),
    ("bigquery", "STRPOS(a, b)", "FIND(a, b)"),
    ("presto", "STRPOS(a, b)", "FINDNTH(a, b)"),
    ("presto", "STRPOS(a, b, 2)", "FINDNTH(a, b, 2)"),
    ("presto", "POSITION(b IN a)", "FIND(a, b)"),
    ("postgres", "STRPOS(a, b)", "FIND(a, b)"),
    ("duckdb", "STRPOS(a, b)", "FIND(a, b)"),
    ("duckdb", "INSTR(a, b)", "FIND(a, b)"),
    ("tsql", "CHARINDEX(b, a)", "FIND(a, b)"),
    ("snowflake", "CHARINDEX(b, a)", "FIND(a, b)"),
    ("snowflake", "POSITION(b, a)", "FIND(a, b)"),
    ("clickhouse", "position(a, b)", "FIND(a, b)"),
    ("clickhouse", "locate(a, b)", "FIND(b, a)"),
    ("sqlite", "INSTR(a, b)", "FIND(a, b)"),
    ("", "STR_POSITION(a, b)", "FIND(a, b)"),
    (
      "", "STR_POSITION(a, b, 1, 2)", "IF FINDNTH(SUBSTRING(a, 1), b, 2) = 0 THEN 0 ELSE FINDNTH(SUBSTRING(a, 1), b, 2) + 1 - 1 END",
    ),
  ]
  let fails = []
  for c in cases {
    let (read, sql, expected) = c
    let got = @sqlglot.generate(@sqlglot.parse_one(sql, read~), dialect="tableau")
    if got != expected {
      fails.push("[\{read}] \{sql}\n  got: \{got}\n  exp: \{expected}")
    }
  }
  if !fails.is_empty() {
    fail(fails.join("\n"))
  }
}

///|
test "explicit None keys: has_key, set, copy, serde" {
  let e = @core.mk(Column, [
    ("this", @core.to_identifier("b") as &IntoValue),
    ("db", @core.null_arg),
  ])
  inspect(e.has_key("db"), content="true")
  inspect(e.has("db"), content="false")
  inspect(e.get("db") is None, content="true")
  inspect(e.copy().has_key("db"), content="true")
  // serde skips None values (like Python)
  inspect(@core.Expr::load(e.dump()).unwrap().has_key("db"), content="false")
  // set(key, None) pops the key; set(key, value) replaces the None
  e.set("db", @core.null_arg)
  inspect(e.has_key("db"), content="false")
  let e = @core.mk(Column, [("db", @core.null_arg)])
  e.set("db", @core.to_identifier("d"))
  inspect(e.arg_keys().join(","), content="db")
}
