// Query builder methods (port of the Select/Query builder API in
// sqlglot/expressions/query.py and builders.py) for expression arguments.

///|
/// `exp.select(*expressions)`
pub fn select_(expressions : Array[Expr]) -> Expr {
  mk(Select, [("expressions", expressions)])
}

///|
/// `Select.select(*expressions, append=...)`
pub fn Expr::select_(
  self : Expr,
  expressions : Array[Expr],
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  if inst.kind.is_a(SetOperation) {
    match inst.this() {
      Some(t) => t.unnest().select_(expressions, append~) |> ignore
      None => ()
    }
    match inst.expression() {
      Some(t) => t.unnest().select_(expressions, append~) |> ignore
      None => ()
    }
    return inst
  }
  if inst.kind.is_a(Subquery) {
    let inner = inst.unnest()
    if inner.kind == Select || inner.kind.is_a(SetOperation) {
      inner.select_(expressions, append~) |> ignore
    }
    return inst
  }
  let parsed = if append { inst.expressions() + expressions } else { expressions }
  inst.set("expressions", parsed)
  inst
}

///|
/// `Select.from_(expression)`
pub fn Expr::from_(self : Expr, expression : Expr, copy? : Bool = false) -> Expr {
  let inst = maybe_copy(self, copy)
  let f = if expression.kind == From { expression } else { mk1(From, expression) }
  inst.set("from_", f)
  inst
}

///|
/// `table name` -> `Table` expression (Python `maybe_parse(name, into=From)` for a name).
pub fn table_of(name : String) -> Expr {
  let parts = py_split(name, ".")
  if parts.iter().all(p => is_safe_identifier(p)) {
    match parts.length() {
      1 => mk1(Table, to_identifier(parts[0]))
      2 => mk(Table, [("this", to_identifier(parts[1])), ("db", to_identifier(parts[0]))])
      _ =>
        mk(Table, [
          ("this", to_identifier(parts[parts.length() - 1])),
          ("db", to_identifier(parts[parts.length() - 2])),
          ("catalog", to_identifier(parts[parts.length() - 3])),
        ])
    }
  } else {
    mk1(Table, to_identifier(name))
  }
}

///|
fn apply_conjunction(
  inst : Expr,
  arg : String,
  into : Kind?,
  expressions : Array[Expr],
  append : Bool,
) -> Expr {
  if expressions.is_empty() {
    return inst
  }
  let filtered = []
  match inst.arg(arg) {
    Some(existing) if append =>
      filtered.push(
        match into {
          Some(_) =>
            match existing.this() {
              Some(t) => t
              None => existing
            }
          None => existing
        },
      )
    _ => ()
  }
  for e in expressions {
    filtered.push(e)
  }
  let node = and_(filtered)
  inst.set(
    arg,
    match into {
      Some(k) => mk1(k, node)
      None => node
    },
  )
  inst
}

///|
/// `Query.where(*expressions)`
pub fn Expr::where_(
  self : Expr,
  expressions : Array[Expr],
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  let exprs = expressions.map(e => if e.kind == Where {
    match e.this() {
      Some(t) => t
      None => e
    }
  } else {
    e
  })
  apply_conjunction(inst, "where", Some(Where), exprs, append)
}

///|
/// `Select.having(*expressions)`
pub fn Expr::having_(
  self : Expr,
  expressions : Array[Expr],
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  apply_conjunction(inst, "having", Some(Having), expressions, append)
}

///|
fn apply_child_list(
  inst : Expr,
  arg : String,
  into : Kind,
  expressions : Array[Expr],
  append : Bool,
) -> Expr {
  let parsed = []
  let properties : Array[(String, Value)] = []
  for expression in expressions {
    let e = if expression.kind.is_a(into) {
      expression
    } else {
      mk(into, [("expressions", [expression])])
    }
    for k, v in e.args {
      if k == "expressions" {
        match v {
          List(l) =>
            for x in l {
              match x {
                Node(n) => parsed.push(n)
                _ => ()
              }
            }
          _ => ()
        }
      } else {
        properties.push((k, v))
      }
    }
  }
  let all = match inst.arg(arg) {
    Some(existing) if append => existing.expressions() + parsed
    _ => parsed
  }
  let child = mk(into, [("expressions", all)])
  for kv in properties {
    child.set(kv.0, kv.1)
  }
  inst.set(arg, child)
  inst
}

///|
/// `Select.group_by(*expressions)`
pub fn Expr::group_by(
  self : Expr,
  expressions : Array[Expr],
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  if expressions.is_empty() {
    return inst
  }
  apply_child_list(inst, "group", Group, expressions, append)
}

///|
/// `Query.order_by(*expressions)`
pub fn Expr::order_by(
  self : Expr,
  expressions : Array[Expr],
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  apply_child_list(inst, "order", Order, expressions, append)
}

///|
/// `Query.limit(expression)`
pub fn Expr::limit_(self : Expr, expression : Expr, copy? : Bool = false) -> Expr {
  let inst = maybe_copy(self, copy)
  let l = if expression.kind == Limit {
    expression
  } else {
    mk(Limit, [("expression", expression)])
  }
  inst.set("limit", l)
  inst
}

///|
/// `Query.offset(expression)`
pub fn Expr::offset_(self : Expr, expression : Expr, copy? : Bool = false) -> Expr {
  let inst = maybe_copy(self, copy)
  let o = if expression.kind == Offset {
    expression
  } else {
    mk(Offset, [("expression", expression)])
  }
  inst.set("offset", o)
  inst
}

///|
/// `Select.distinct(*ons, distinct=True)`
pub fn Expr::distinct_(
  self : Expr,
  ons? : Array[Expr] = [],
  distinct? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  let on = if ons.is_empty() {
    None
  } else {
    Some(mk(Tuple, [("expressions", ons)]))
  }
  inst.set("distinct", if distinct { Some(mk(Distinct, [("on", on)])) } else { None })
  inst
}

///|
/// `Select.join(expression, on=..., using=..., join_type=...)`
pub fn Expr::join_(
  self : Expr,
  expression : Expr,
  on? : Array[Expr] = [],
  using_? : Array[Expr] = [],
  side? : String,
  kind? : String,
  method? : String,
  join_alias? : String,
  append? : Bool = true,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  let join = if expression.kind == Join {
    expression
  } else {
    mk1(Join, expression)
  }
  match join.this() {
    Some(t) if t.kind == Select => t.replace(Some(t.subquery(copy=false))) |> ignore
    _ => ()
  }
  match method {
    Some(m) => join.set("method", m)
    None => ()
  }
  match side {
    Some(s) => join.set("side", s)
    None => ()
  }
  match kind {
    Some(k) => join.set("kind", k)
    None => ()
  }
  if !on.is_empty() {
    join.set("on", and_(on))
  }
  if !using_.is_empty() {
    let existing = if append { join.list("using") } else { [] }
    join.set("using", existing + using_)
  }
  match join_alias {
    Some(a) =>
      match join.this() {
        Some(t) => join.set("this", alias_table(t, a))
        None => ()
      }
    None => ()
  }
  let joins = if append { inst.list("joins") } else { [] }
  joins.push(join)
  inst.set("joins", joins)
  inst
}

///|
/// Builds a set operation (`exp.union` / `exp.intersect` / `exp.except_`).
pub fn set_operation(kind : Kind, left : Expr, right : Expr, distinct? : Bool = true) -> Expr {
  mk(kind, [("this", left), ("expression", right), ("distinct", distinct)])
}

///|
/// `Query.union(other, distinct=...)`
pub fn Expr::union_(self : Expr, other : Expr, distinct? : Bool = true) -> Expr {
  set_operation(Union, self, other, distinct~)
}

///|
/// `Query.with_(alias, as_, recursive=...)`
pub fn Expr::with_(
  self : Expr,
  alias : String,
  as_ : Expr,
  recursive? : Bool,
  materialized? : Bool,
  append? : Bool = true,
  scalar? : Bool,
  copy? : Bool = false,
) -> Expr {
  let inst = maybe_copy(self, copy)
  let alias_expression = mk1(TableAlias, to_identifier(alias))
  let as_expression = match scalar {
    Some(true) if as_.kind != Subquery => mk1(Subquery, as_)
    _ => as_
  }
  let cte = mk(CTE, [
    ("this", as_expression),
    ("alias", alias_expression),
    ("materialized", materialized),
    ("scalar", scalar),
  ])
  let existing = match inst.arg("with_") {
    Some(w) if append => w.expressions()
    _ => []
  }
  let w = mk(With, [("expressions", existing + [cte])])
  match inst.arg("with_") {
    Some(old) =>
      for k, v in old.args {
        if k != "expressions" {
          w.set(k, v)
        }
      }
    None => ()
  }
  match recursive {
    Some(true) => w.set("recursive", true)
    _ => ()
  }
  inst.set("with_", w)
  inst
}

///|
/// `exp.cast(expression, to)` with a DType target. Avoids re-casting to the same type.
pub fn cast_(expression : Expr, to : DType, copy? : Bool = false) -> Expr {
  cast_to(expression, mk1(DataType, to), copy~)
}

///|
/// `exp.cast(expression, to)` with a DataType expression target.
pub fn cast_to(expression : Expr, to : Expr, copy? : Bool = false) -> Expr {
  let expr = maybe_copy(expression, copy)
  if expr.kind == Cast {
    match expr.arg("to") {
      Some(existing) if existing == to => return expr
      _ => ()
    }
  }
  let e = mk(Cast, [("this", expr), ("to", to)])
  e.type_ = Some(to)
  e
}

///|
/// `exp.func(name, *args)`: builds a known function via the dialect's FUNCTIONS, or an
/// Anonymous function.
pub fn func_(name : String, args : Array[Expr], dialect? : Dialect) -> Expr raise SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => base_dialect()
  }
  match d.parser_fns.functions.get(py_upper(name)) {
    Some(constructor) => constructor(args, Parser::new(d))
    None => mk(Anonymous, [("this", name), ("expressions", args)])
  }
}

///|
/// `exp.case()` builder.
pub fn case_(this? : Expr) -> Expr {
  mk(Case, [("this", this)])
}

///|
/// `Case.when(condition, then)`
pub fn Expr::when_(self : Expr, condition : Expr, then : Expr) -> Expr {
  self.append("ifs", mk(If, [("this", condition), ("true", then)]))
  self
}

///|
/// `Case.else_(condition)`
pub fn Expr::else_(self : Expr, default : Expr) -> Expr {
  self.set("default", default)
  self
}

///|
/// `expr.as_(alias)`
pub fn Expr::as_(self : Expr, alias : String, quoted? : Bool, copy? : Bool = true) -> Expr {
  alias_(self, alias, quoted?, copy~)
}

///|
/// `expr.eq(other)`
pub fn Expr::eq_(self : Expr, other : Expr) -> Expr {
  mk(EQ, [("this", self), ("expression", other)])
}

///|
/// `expr.is_(other)`
pub fn Expr::is__(self : Expr, other : Expr) -> Expr {
  mk(Is, [("this", self), ("expression", other)])
}

///|
/// `exp.array(*expressions)`
pub fn array_(expressions : Array[Expr]) -> Expr {
  mk(Array, [("expressions", expressions)])
}

///|
/// `exp.tuple_(*expressions)`
pub fn tuple_(expressions : Array[Expr]) -> Expr {
  mk(Tuple, [("expressions", expressions)])
}

///|
/// Wraps a binary operand in parentheses if needed (Python `_wrap(e, Binary)`).
pub fn wrap_binary(e : Expr) -> Expr {
  if e.kind.is_a(Binary) {
    mk1(Paren, e)
  } else {
    e
  }
}

///|
/// Python `expr + other` (`Expr.__add__`): Add with operands wrapped as needed.
pub fn add_(a : Expr, b : Expr) -> Expr {
  mk(Add, [("this", wrap_binary(a)), ("expression", wrap_binary(b))])
}

///|
/// Python `expr - other`.
pub fn sub_(a : Expr, b : Expr) -> Expr {
  mk(Sub, [("this", wrap_binary(a)), ("expression", wrap_binary(b))])
}

///|
/// Python `expr * other`.
pub fn mul_(a : Expr, b : Expr) -> Expr {
  mk(Mul, [("this", wrap_binary(a)), ("expression", wrap_binary(b))])
}

///|
/// Python `expr / other`.
pub fn div_(a : Expr, b : Expr) -> Expr {
  mk(Div, [("this", wrap_binary(a)), ("expression", wrap_binary(b))])
}

///|
/// `exp.to_table(name)` for dotted names.
pub fn to_table(name : String) -> Expr {
  table_of(name)
}

///|
/// `exp.replace_placeholders(expression, **kwargs)`
pub fn replace_placeholders(expression : Expr, kwargs : Map[String, Expr]) -> Expr {
  expression.transform(
    node => if node.kind == Placeholder {
      let name = node.text("this")
      if !name.is_empty() {
        match kwargs.get(name) {
          Some(v) => return Some(v)
          None => ()
        }
      }
      Some(node)
    } else {
      Some(node)
    },
    copy=false,
  )
}

///|
/// `exp.find_tables(expression)`
pub fn find_tables(expression : Expr) -> Array[Expr] {
  expression.find_all([Table]).filter(t => !t.name().is_empty()).collect()
}

///|
/// `exp.column_table_names(expression, exclude)`
pub fn column_table_names(expression : Expr, exclude? : String = "") -> Array[String] {
  let out : @set.Set[String] = @set.Set::new()
  for c in expression.find_all([Column]) {
    let t = c.table_name()
    if !t.is_empty() && t != exclude {
      out.add(t)
    }
  }
  out.iter().collect()
}
