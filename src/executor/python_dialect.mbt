// Port of the `Python` dialect of sqlglot/executor/python.py and of its generator,
// sqlglot/generators/python.py: SQL expressions are rendered as Python source code.

///|
let python_dialect_cell : Ref[@core.Dialect?] = Ref(None)

///|
/// The `Python` dialect used by the executor to generate Python code.
pub fn python_dialect() -> @core.Dialect {
  match python_dialect_cell.val {
    Some(d) => d
    None => {
      let d = @core.Dialect::subclass(
        @core.base_dialect(),
        "python",
        configure_python,
      )
      python_dialect_cell.val = Some(d)
      d
    }
  }
}

///|
fn configure_python(d : @core.Dialect) -> Unit {
  let c = d.cfg
  c.byte_strings_support_escaped_sequences = true
  c.strings_support_escaped_sequences = true
  c.initcap_supports_custom_delimiters = false
  c.escaped_sequences = Map::from_array([
    ("\u{7}", "\\a"),
    ("\u{8}", "\\b"),
    ("\u{c}", "\\f"),
    ("\n", "\\n"),
    ("\r", "\\r"),
    ("\t", "\\t"),
    ("\u{b}", "\\v"),
    ("\\", "\\\\"),
  ])
  c.unescaped_sequences = Map::from_array([
    ("\\a", "\u{7}"),
    ("\\b", "\u{8}"),
    ("\\f", "\u{c}"),
    ("\\n", "\n"),
    ("\\r", "\r"),
    ("\\t", "\t"),
    ("\\v", "\u{b}"),
    ("\\\\", "\\"),
  ])
  d.tokenizer.string_escapes = ["\\"]
  d.tokenizer.byte_string_escapes = Some(["\\"])
  // PythonGenerator.TRANSFORMS replaces the base generator's TRANSFORMS entirely
  let t = d.gen_fns.transforms
  t.clear()
  for kind in @core.all_kinds {
    let is_func = kind.is_a(Func) &&
      kind != Func &&
      kind != AggFunc &&
      kind != Anonymous
    if (kind.is_a(Binary) && kind != Binary) || is_func {
      t[kind] = rename_sql
    }
  }
  t[Between] = rename_sql
  t[Case] = case_sql
  t[Alias] = (g, e) => g.sql(e.this())
  t[Array] = @core.inline_array_sql
  t[And] = (g, e) => {
    "AND(lambda: \{g.sql(e.this())}, lambda: \{g.sql(e.expression())})"
  }
  t[Boolean] = (_, e) => if e.bool_arg("this") { "True" } else { "False" }
  t[Cast] = (g, e) => {
    let to = match e.arg("to") {
      Some(dt) => @core.expr_to_sql(dt)
      None => "None"
    }
    "CAST(\{g.sql(e.this())}, exp.DType.\{to})"
  }
  t[Column] = (g, e) => {
    let table = g.sql_key(e, "table")
    let table = if table == "" { "None" } else { table }
    "scope[\{table}][\{g.sql(e.this())}]"
  }
  t[Concat] = (g, e) => {
    g.func(
      if e.bool_arg("safe") {
        "SAFECONCAT"
      } else {
        "CONCAT"
      },
      e.expressions().map(x => (x : &@core.SqlArg)),
    )
  }
  t[Distinct] = (g, e) => {
    let this = g.expressions(expression=e, flat=true)
    if e.expressions().length() == 1 {
      "set(\{this})"
    } else {
      "set(ZIPNOTNULL(\{this}))"
    }
  }
  t[Div] = div_sql
  t[DPipe] = dpipe_sql
  t[Extract] = (g, e) => {
    "EXTRACT('\{@core.py_lower(e.name())}', \{g.sql_key(e, "expression")})"
  }
  t[ILike] = like_sql
  t[In] = (g, e) => {
    let args : Array[&@core.SqlArg] = [e.this()]
    for x in e.expressions() {
      args.push(x)
    }
    g.func("IN", args)
  }
  t[Interval] = (g, e) => {
    "INTERVAL(\{g.sql(e.this())}, '\{g.sql(e.arg("unit"))}')"
  }
  t[Is] = (g, e) => {
    match e.this() {
      Some(this) if this.kind.is_a(Literal) =>
        g.binary(e, if e.bool_arg("negate") { "!=" } else { "==" })
      _ => g.binary(e, if e.bool_arg("negate") { "is not" } else { "is" })
    }
  }
  t[JSONExtract] = (g, e) => {
    let args : Array[&@core.SqlArg] = [e.this(), e.expression()]
    for x in e.expressions() {
      args.push(x)
    }
    g.func(e.kind.key(), args)
  }
  t[JSONPath] = (g, e) => {
    let parts = []
    for i, p in e.expressions() {
      if i > 0 {
        parts.push(g.sql(Some(p)))
      }
    }
    "[" + parts.join(",") + "]"
  }
  t[JSONPathKey] = (_, e) => "'\{e.text("this")}'"
  t[JSONPathSubscript] = (_, e) => "'\{@core.py_str_value(e.get("this"))}'"
  t[Lambda] = lambda_sql
  t[Like] = like_sql
  t[Not] = (g, e) => g.func("NOT", [e.this()])
  t[Null] = (_, _) => "None"
  t[Or] = (g, e) => {
    "OR(lambda: \{g.sql(e.this())}, lambda: \{g.sql(e.expression())})"
  }
  t[Ordered] = (g, e) => {
    let this = g.sql_key(e, "this")
    let desc = if e.bool_arg("desc") { "True" } else { "False" }
    let nulls_first = if e.bool_arg("nulls_first") { "True" } else { "False" }
    "ORDERED(\{this}, \{desc}, \{nulls_first})"
  }
  t[Star] = (_, _) => "1"
}

///|
/// `_rename`: `KEY(<args>)`.
fn rename_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let values = e.args.values().collect()
  if values.length() == 1 {
    match values[0] {
      List(l) => return g.func(e.kind.key(), l.map(v => (v : &@core.SqlArg)))
      v => return g.func(e.kind.key(), [v])
    }
  }
  if e.kind.is_a(Func) && e.kind.is_var_len_args() {
    let args : Array[&@core.SqlArg] = []
    for v in values {
      match v {
        List(l) =>
          for x in l {
            args.push(x)
          }
        v => args.push(v)
      }
    }
    return g.func(e.kind.key(), args)
  }
  for v in values {
    if v is List(l) && !l.is_empty() {
      raise @core.ValueError("Could not rename \{e.kind.name()}")
    }
  }
  g.func(e.kind.key(), values.map(v => (v : &@core.SqlArg)))
}

///|
fn case_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let default = g.sql_key(e, "default")
  let mut chain = if default == "" { "None" } else { default }
  let ifs = e.list("ifs")
  for i = ifs.length() - 1; i >= 0; i = i - 1 {
    let branch = ifs[i]
    let true_ = g.sql_key(branch, "true")
    let condition = g.sql_key(branch, "this")
    let condition = if this != "" {
      "\{this} = (\{condition})"
    } else {
      condition
    }
    chain = "\{true_} if \{condition} else (\{chain})"
  }
  "(\{chain})"
}

///|
fn lambda_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let names = e.expressions().map(x => @core.py_lower(x.name()))
  let e = e.transform(n => {
    if n.kind == Identifier && names.contains(@core.py_lower(n.name())) {
      Some(@core.var_(n.name()))
    } else {
      Some(n)
    }
  })
  "lambda \{g.expressions(expression=e, flat=true)}: \{g.sql_key(e, "this")}"
}

///|
fn like_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let sql = g.func(e.kind.key(), [e.this(), e.expression()])
  if e.bool_arg("negate") {
    "NOT(\{sql})"
  } else {
    sql
  }
}

///|
fn div_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut denominator = g.sql_key(e, "expression")
  if e.bool_arg("safe") {
    denominator = denominator + " or None"
  }
  let mut sql = "DIV(\{g.sql_key(e, "this")}, \{denominator})"
  if e.bool_arg("typed") &&
    !(e.this_().is_type(@core.dtype_real_types) ||
    e.expression_().is_type(@core.dtype_real_types)) {
    sql = "INT(\{sql})"
  }
  sql
}

///|
fn dpipe_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.this_().is_type([ARRAY]) || e.expression_().is_type([ARRAY]) {
    return g.func("ARRAYCONCAT", [e.this(), e.expression()])
  }
  g.func(if e.bool_arg("safe") { "SAFECONCAT" } else { "CONCAT" }, [
    e.this(),
    e.expression(),
  ])
}

///|
/// Python `Python().generate(expression)`: renders an expression as Python code.
pub fn python_generate(
  expression : @core.Expr,
  identify? : Bool = false,
) -> String raise @core.SqlglotError {
  @core.Generator::new(
    python_dialect(),
    identify=if identify { "always" } else { "" },
  ).generate(expression)
}
