// Query builder methods (port of the Select/Query builder API in
// sqlglot/expressions/query.py and builders.py).
//
// Arguments are host values (`IntoPy`): expressions are used as-is, other values (e.g. SQL
// strings) are parsed with `maybe_parse`, as in Python. As in Python, the builder methods
// default to `copy=true`: they return a modified copy and leave the instance untouched;
// pass `copy=false` to modify the instance in place.

///|
/// `exp.select(*expressions)`
pub fn[T : IntoPy] select_(
  expressions : Array[T],
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  mk0(Select).select_(expressions, dialect?, copy~)
}

///|
/// `Select.select(*expressions, append=...)` (also `SetOperation.select` and
/// `Subquery.select`).
pub fn[T : IntoPy] Expr::select_(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let inst = maybe_copy(self, copy)
  if inst.kind.is_a(SetOperation) {
    match inst.this() {
      Some(t) => t.unnest().select_(expressions, append~, dialect?, copy=false)
        |> ignore
      None => ()
    }
    match inst.expression() {
      Some(t) => t.unnest().select_(expressions, append~, dialect?, copy=false)
        |> ignore
      None => ()
    }
    return inst
  }
  if inst.kind.is_a(Subquery) {
    let inner = inst.unnest()
    if inner.kind == Select || inner.kind.is_a(SetOperation) {
      inner.select_(expressions, append~, dialect?, copy=false) |> ignore
    }
    return inst
  }
  apply_list_builder(
    py_list(expressions),
    inst,
    "expressions",
    append~,
    copy=false,
    into=Expression,
    dialect?,
  )
}

///|
/// `Select.from_(expression)` / `Update.from_(expression)`
pub fn[T : IntoPy] Expr::from_(
  self : Expr,
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let expression = expression.into_py()
  if self.kind == Update && !expression.truthy() {
    return maybe_copy(self, copy)
  }
  apply_builder(
    expression,
    self,
    "from_",
    copy~,
    prefix="FROM",
    into=From,
    dialect?,
  )
}

///|
/// `table name` -> `Table` expression (Python `maybe_parse(name, into=From)` for a name).
pub fn table_of(name : String) -> Expr {
  let parts = py_split(name, ".")
  if parts.iter().all(p => is_safe_identifier(p)) {
    match parts.length() {
      1 => mk1(Table, to_identifier(parts[0]))
      2 =>
        mk(Table, [
          ("this", to_identifier(parts[1])),
          ("db", to_identifier(parts[0])),
        ])
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
/// `Query.where(*expressions)` (also `Delete.where` / `Update.where`)
pub fn[T : IntoPy] Expr::where_(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let exprs = expressions.map(e => {
    match e.into_py() {
      PyExpr(w) if w.kind == Where =>
        match w.this() {
          Some(t) => PyExpr(t)
          None => PyNone
        }
      other => other
    }
  })
  apply_conjunction_builder(
    exprs,
    self,
    "where",
    into=Where,
    append~,
    copy~,
    dialect?,
  )
}

///|
/// `Select.having(*expressions)`
pub fn[T : IntoPy] Expr::having_(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_conjunction_builder(
    py_list(expressions),
    self,
    "having",
    into=Having,
    append~,
    copy~,
    dialect?,
  )
}

///|
/// `Select.group_by(*expressions)`
pub fn[T : IntoPy] Expr::group_by(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  if expressions.is_empty() {
    return maybe_copy(self, copy)
  }
  apply_child_list_builder(
    py_list(expressions),
    self,
    "group",
    append~,
    copy~,
    prefix="GROUP BY",
    into=Group,
    dialect?,
  )
}

///|
/// `Query.order_by(*expressions)`
pub fn[T : IntoPy] Expr::order_by(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_child_list_builder(
    py_list(expressions),
    self,
    "order",
    append~,
    copy~,
    prefix="ORDER BY",
    into=Order,
    dialect?,
  )
}

///|
/// `Query.limit(expression)`
pub fn[T : IntoPy] Expr::limit_(
  self : Expr,
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_builder(
    expression.into_py(),
    self,
    "limit",
    copy~,
    prefix="LIMIT",
    into=Limit,
    dialect?,
    into_arg="expression",
  )
}

///|
/// `Query.offset(expression)`
pub fn[T : IntoPy] Expr::offset_(
  self : Expr,
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_builder(
    expression.into_py(),
    self,
    "offset",
    copy~,
    prefix="OFFSET",
    into=Offset,
    dialect?,
    into_arg="expression",
  )
}

///|
/// `Select.distinct(*ons, distinct=True)`
pub fn Expr::distinct_(
  self : Expr,
  ons? : Array[&IntoPy] = [],
  distinct? : Bool = true,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let inst = maybe_copy(self, copy)
  let on = if ons.is_empty() {
    None
  } else {
    let exprs = []
    for on in ons {
      let o = on.into_py()
      if o.truthy() {
        exprs.push(maybe_parse(o, copy~))
      }
    }
    Some(mk(Tuple, [("expressions", exprs)]))
  }
  inst.set(
    "distinct",
    if distinct {
      Some(mk(Distinct, [("on", on)]))
    } else {
      None
    },
  )
  inst
}

///|
/// `Select.join(expression, on=..., using=..., join_type=..., join_alias=...)`.
///
/// `side`, `kind` and `method` directly set the corresponding join arguments.
pub fn[T : IntoPy] Expr::join_(
  self : Expr,
  expression : T,
  on? : Array[&IntoPy] = [],
  using_? : Array[&IntoPy] = [],
  append? : Bool = true,
  join_type? : String,
  join_alias? : String,
  side? : String,
  kind? : String,
  method? : String,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let expression = expression.into_py()
  let parsed = maybe_parse(expression, into=[Join], prefix="JOIN", dialect?) catch {
    ParseError(_, _) =>
      maybe_parse(expression, into=[Join, Expression], dialect?)
    e => raise e
  }
  let join = if parsed.kind == Join { parsed } else { mk1(Join, parsed) }
  match join.this() {
    Some(t) if t.kind == Select => t.replace(Some(t.subquery())) |> ignore
    _ => ()
  }
  match join_type {
    Some(jt) if !jt.is_empty() => {
      let new_join = maybe_parse("FROM _ \{jt} JOIN _", dialect?)
        .find([Join])
        .unwrap()
      let m = py_upper(new_join.text("method"))
      let s = py_upper(new_join.text("side"))
      let k = py_upper(new_join.text("kind"))
      if !m.is_empty() {
        join.set("method", m)
      }
      if !s.is_empty() {
        join.set("side", s)
      }
      if !k.is_empty() {
        join.set("kind", k)
      }
    }
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
    join.set("on", combine_py(on.map(o => o.into_py()), And, dialect?, copy~))
  }
  let join = if !using_.is_empty() {
    apply_list_builder(
      using_.map(u => u.into_py()),
      join,
      "using",
      append~,
      copy~,
      into=Identifier,
    )
  } else {
    join
  }
  match join_alias {
    Some(a) =>
      match join.this() {
        Some(t) => join.set("this", alias_table(t, a))
        None => ()
      }
    None => ()
  }
  apply_list_builder([PyExpr(join)], self, "joins", append~, copy~)
}

///|
/// Builds a set operation (`exp.union` / `exp.intersect` / `exp.except_`).
pub fn set_operation(
  kind : Kind,
  left : Expr,
  right : Expr,
  distinct? : Bool = true,
) -> Expr {
  mk(kind, [("this", left), ("expression", right), ("distinct", distinct)])
}

///|
/// `Query.union(*expressions, distinct=...)`
pub fn[T : IntoPy] Expr::union_(
  self : Expr,
  other : T,
  distinct? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_set_operation(
    [PyExpr(self), other.into_py()],
    Union,
    distinct~,
    dialect?,
    copy~,
  )
}

///|
/// `Query.with_(alias, as_, recursive=...)` (also `Insert.with_` / `Update.with_`)
pub fn[A : IntoPy, B : IntoPy] Expr::with_(
  self : Expr,
  alias : A,
  as_ : B,
  recursive? : Bool,
  materialized? : Bool,
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
  scalar? : Bool,
) -> Expr raise SqlglotError {
  let alias_expression = maybe_parse(alias, dialect?, into=[TableAlias])
  let mut as_expression = maybe_parse(as_, dialect?, copy~)
  if scalar == Some(true) && as_expression.kind != Subquery {
    // scalar CTE must be wrapped in a subquery
    as_expression = mk1(Subquery, as_expression)
  }
  let cte = mk(CTE, [
    ("this", as_expression),
    ("alias", alias_expression),
    ("materialized", materialized),
    ("scalar", scalar),
  ])
  let properties : Map[String, Value] = Map([])
  if recursive == Some(true) {
    properties["recursive"] = Bool(true)
  }
  apply_child_list_builder(
    [PyExpr(cte)],
    self,
    "with_",
    append~,
    copy~,
    into=With,
    properties~,
  )
}

///|
/// `exp.cast(expression, to)` with a DType target. Avoids re-casting to the same type.
pub fn cast_(expression : Expr, to : DType, copy? : Bool = true) -> Expr {
  cast_to(expression, mk1(DataType, to), copy~)
}

///|
/// `exp.cast(expression, to)` with a DataType expression target.
pub fn cast_to(expression : Expr, to : Expr, copy? : Bool = true) -> Expr {
  let expr = maybe_copy(expression, copy)
  let to = maybe_copy(to, copy)
  if expr.kind.is_a(Cast) {
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
pub fn func_(
  name : String,
  args : Array[Expr],
  dialect? : Dialect,
) -> Expr raise SqlglotError {
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
pub fn[C : IntoPy, T : IntoPy] Expr::when_(
  self : Expr,
  condition : C,
  then : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let instance = maybe_copy(self, copy)
  instance.append(
    "ifs",
    mk(If, [
      ("this", maybe_parse(condition, copy~, dialect?)),
      ("true", maybe_parse(then, copy~, dialect?)),
    ]),
  )
  instance
}

///|
/// `Case.else_(condition)`
pub fn[T : IntoPy] Expr::else_(
  self : Expr,
  default : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let instance = maybe_copy(self, copy)
  instance.set("default", maybe_parse(default, copy~, dialect?))
  instance
}

///|
/// `expr.as_(alias)`
pub fn Expr::as_(
  self : Expr,
  alias : String,
  quoted? : Bool,
  copy? : Bool = true,
  table? : Array[String],
) -> Expr {
  match table {
    Some(columns) => {
      let e = maybe_copy(self, copy)
      let table_alias = mk1(TableAlias, to_identifier(alias, quoted?))
      e.set("alias", table_alias)
      for c in columns {
        table_alias.append("columns", to_identifier(c, quoted?))
      }
      e
    }
    None => alias_(self, alias, quoted?, copy~)
  }
}

///|
/// `expr.eq(other)`
pub fn[T : IntoPy] Expr::eq_(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(EQ, other)
}

///|
/// `expr.is_(other)`
pub fn[T : IntoPy] Expr::is__(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(Is, other)
}

///|
/// `exp.array(*expressions)` (copied unless `copy` is false).
pub fn array_(expressions : Array[Expr], copy? : Bool = true) -> Expr {
  mk(Array, [("expressions", expressions.map(e => maybe_copy(e, copy)))])
}

///|
/// `exp.tuple_(*expressions)` (copied unless `copy` is false).
pub fn tuple_(expressions : Array[Expr], copy? : Bool = true) -> Expr {
  mk(Tuple, [("expressions", expressions.map(e => maybe_copy(e, copy)))])
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
pub fn replace_placeholders(
  expression : Expr,
  kwargs : Map[String, Expr],
) -> Expr {
  expression.transform(
    node => {
      if node.kind == Placeholder {
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
      }
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
pub fn column_table_names(
  expression : Expr,
  exclude? : String = "",
) -> Array[String] {
  let out : @set.Set[String] = @set.Set::new()
  for c in expression.find_all([Column]) {
    let t = c.table_name()
    if !t.is_empty() && t != exclude {
      out.add(t)
    }
  }
  out.iter().collect()
}
