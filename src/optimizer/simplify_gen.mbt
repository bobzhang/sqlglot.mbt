// Port of the pseudo SQL generator `gen` of sqlglot/optimizer/simplify.py, used to sort
// and deduplicate operands.

///|
priv enum GenItem {
  GE(@core.Expr)
  GS(String)
  GL(Array[GenItem?])
}

///|
fn value_item(v : @core.Value, repr_str : Bool) -> GenItem? {
  match v {
    Node(e) => Some(GE(e))
    List(l) => Some(GL(l.map(x => value_item(x, repr_str))))
    Str(s) => Some(GS(if repr_str { @core.py_repr_str(s) } else { s }))
    Bool(b) => Some(GS(if b { "True" } else { "False" }))
    Int(i) => Some(GS(i.to_string()))
    DT(d) => Some(GS("DType.\{d.name()}"))
  }
}

///|
fn opt_item(e : @core.Expr?) -> GenItem? {
  e.map(x => GE(x))
}

///|
/// Simple pseudo sql generator for quickly generating sortable and uniq strings.
///
/// `comments` controls whether the expressions' comments are included.
pub fn gen(
  expression : @core.Expr,
  comments? : Bool = false,
) -> String raise @core.SqlglotError {
  let stack : Array[GenItem?] = [Some(GE(expression))]
  let sqls = StringBuilder::new()
  fn push(x : GenItem?) {
    stack.push(x)
  }

  fn s(x : String) {
    stack.push(Some(GS(x)))
  }

  fn args(node : @core.Expr, arg_index : Int) -> Bool {
    let kvs : Array[GenItem?] = []
    let arg_types = node.kind.arg_types()
    for i in arg_index..<arg_types.length() {
      let k = arg_types[i].0
      match node.args.get(k) {
        Some(v) => kvs.push(Some(GL([Some(GS(":\{k}")), value_item(v, true)])))
        None => ()
      }
    }
    if !kvs.is_empty() {
      stack.push(Some(GL(kvs)))
      true
    } else {
      false
    }
  }

  fn binary(e : @core.Expr, op : String) {
    push(opt_item(e.expression()))
    s(op)
    push(opt_item(e.this()))
  }

  fn unary(e : @core.Expr, op : String) {
    push(opt_item(e.this()))
    s(op)
  }

  fn parts_of(e : @core.Expr) {
    let parts = e.parts()
    for i = parts.length() - 1; i >= 0; i = i - 1 {
      push(Some(GE(parts[i])))
      s(".")
    }
    stack.pop() |> ignore
  }

  while stack.pop() is Some(item) {
    match item {
      None => ()
      Some(GS(str)) => sqls.write_string(str)
      Some(GL(l)) => {
        for i = l.length() - 1; i >= 0; i = i - 1 {
          match l[i] {
            Some(n) => {
              push(Some(n))
              s(",")
            }
            None => ()
          }
        }
        if !l.is_empty() {
          stack.pop() |> ignore
        }
      }
      Some(GE(e)) => {
        if comments && e.comments is Some(cs) && !cs.is_empty() {
          s(" /*" + cs.join(",") + "*/")
        }
        match e.kind.key() {
          "add" => binary(e, " + ")
          "alias" => {
            push(opt_item(e.arg("alias")))
            s(" AS ")
            push(opt_item(e.arg("this")))
          }
          "and" => binary(e, " AND ")
          "anonymous" => {
            let name = match e.get("this") {
              Some(Str(t)) => @core.py_upper(t)
              Some(Node(i)) if i.kind == Identifier => {
                let n = i.text("this")
                if i.has("quoted") {
                  "\"" + n.replace_all(old="\"", new="\"\"") + "\""
                } else {
                  @core.py_upper(n)
                }
              }
              Some(v) => {
                let type_name = match v {
                  Node(n) => n.kind.name()
                  List(_) => "list"
                  Str(_) => "str"
                  Bool(_) => "bool"
                  Int(_) => "int"
                  DT(_) => "Type"
                }
                raise @core.ValueError(
                  "Anonymous.this expects a str or an Identifier, got '\{type_name}'.",
                )
              }
              None =>
                raise @core.ValueError(
                  "Anonymous.this expects a str or an Identifier, got 'NoneType'.",
                )
            }
            s(")")
            push(Some(GL(e.expressions().map(x => Some(GE(x))))))
            s("(")
            s(name)
          }
          "between" => {
            push(opt_item(e.arg("high")))
            s(" AND ")
            push(opt_item(e.arg("low")))
            s(" BETWEEN ")
            push(opt_item(e.this()))
          }
          "boolean" => s(if e.has("this") { "TRUE" } else { "FALSE" })
          "bracket" => {
            s("]")
            push(Some(GL(e.expressions().map(x => Some(GE(x))))))
            s("[")
            push(opt_item(e.this()))
          }
          "column" => parts_of(e)
          "datatype" => {
            args(e, 1) |> ignore
            let name = match e.get("this") {
              Some(DT(d)) => d.name()
              Some(Node(n)) => n.name()
              Some(Str(x)) => x
              _ => ""
            }
            s("\{name} ")
          }
          "div" => binary(e, " / ")
          "dot" => binary(e, ".")
          "eq" => binary(e, " = ")
          "from" => {
            push(opt_item(e.this()))
            s("FROM ")
          }
          "gt" => binary(e, " > ")
          "gte" => binary(e, " >= ")
          "identifier" =>
            if e.has("quoted") {
              s("\"" + e.text("this").replace_all(old="\"", new="\"\"") + "\"")
            } else {
              s(e.text("this"))
            }
          "ilike" =>
            binary(e, if e.has("negate") { " NOT ILIKE " } else { " ILIKE " })
          "in" => {
            s(")")
            args(e, 1) |> ignore
            s("(")
            s(" IN ")
            push(opt_item(e.this()))
          }
          "intdiv" => binary(e, " DIV ")
          "is" => binary(e, if e.has("negate") { " IS NOT " } else { " IS " })
          "like" => binary(e, if e.has("negate") { " NOT Like " } else { " Like " })
          "literal" =>
            if e.is_string() {
              s("'" + e.text("this").replace_all(old="'", new="''") + "'")
            } else {
              s(e.text("this"))
            }
          "lt" => binary(e, " < ")
          "lte" => binary(e, " <= ")
          "mod" => binary(e, " % ")
          "mul" => binary(e, " * ")
          "neg" => unary(e, "-")
          "neq" => binary(e, " <> ")
          "not" => unary(e, "NOT ")
          "null" => s("NULL")
          "or" => binary(e, " OR ")
          "paren" => {
            s(")")
            push(opt_item(e.this()))
            s("(")
          }
          "sub" => binary(e, " - ")
          "subquery" => {
            args(e, 2) |> ignore
            match e.arg("alias") {
              Some(a) => push(Some(GE(a)))
              None => ()
            }
            s(")")
            push(opt_item(e.this()))
            s("(")
          }
          "table" => {
            args(e, 4) |> ignore
            match e.arg("alias") {
              Some(a) => push(Some(GE(a)))
              None => ()
            }
            parts_of(e)
          }
          "tablealias" => {
            let columns = e.list("columns")
            if !columns.is_empty() {
              s(")")
              push(Some(GL(columns.map(x => Some(GE(x))))))
              s("(")
            }
            push(opt_item(e.this()))
            s(" AS ")
          }
          "var" => s(e.text("this"))
          _ =>
            if e.kind.is_a(Func) {
              s(")")
              let vals : Array[GenItem?] = []
              for _, v in e.args {
                vals.push(value_item(v, false))
              }
              push(Some(GL(vals)))
              s("(")
              s(e.kind.sql_name())
            } else {
              let key = @core.py_upper(e.kind.key())
              // `_args` pushes before the key is pushed
              let has = args(e, 0)
              s(if has { "\{key} " } else { key })
            }
        }
      }
    }
  }
  sqls.to_string()
}
