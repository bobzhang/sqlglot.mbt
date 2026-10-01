// Expression builders used by the generator (ports of helpers from
// sqlglot/expressions/core.py, builders.py and query.py).

///|
/// Python `to_identifier(name, quoted, copy)` for an identifier or a string value.
pub fn to_identifier_value(
  name : Value,
  quoted? : Bool,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  match name {
    Node(e) if e.kind == Identifier => maybe_copy(e, copy)
    Str(s) => to_identifier(s, quoted?)
    Node(e) =>
      raise ValueError(
        "Name needs to be a string or an Identifier, got: <class 'sqlglot.expressions.\{e.kind.name()}'>",
      )
    _ => raise ValueError("Name needs to be a string or an Identifier")
  }
}

///|
/// Python `_wrap(expression, kind)`: wraps in a `Paren` if it is a `kind`.
pub fn exp_wrap(expression : Expr, kind : Kind) -> Expr {
  if expression.kind.is_a(kind) {
    mk1(Paren, expression)
  } else {
    expression
  }
}

///|
/// Python `Expr._binop(klass, other)`.
pub fn exp_binop(kind : Kind, this : Expr, other : Expr) -> Expr {
  let mut this = this.copy()
  let mut other = other.copy()
  if !this.kind.is_a(kind) && !other.kind.is_a(kind) {
    this = exp_wrap(this, Binary)
    other = exp_wrap(other, Binary)
  }
  mk2(kind, this, other)
}

///|
/// Python `this.is_(other)`.
pub fn exp_is(this : Expr, other : Expr) -> Expr {
  exp_binop(Is, this, other)
}

///|
/// Python `this.eq(other)`.
pub fn exp_eq(this : Expr, other : Expr) -> Expr {
  exp_binop(EQ, this, other)
}

///|
/// Python `this.neq(other)`.
pub fn exp_neq(this : Expr, other : Expr) -> Expr {
  exp_binop(NEQ, this, other)
}

///|
/// Python `this / other`.
pub fn exp_div(this : Expr, other : Expr) -> Expr {
  exp_binop(Div, this, other)
}

///|
/// Python `this + other`.
pub fn exp_add(this : Expr, other : Expr) -> Expr {
  exp_binop(Add, this, other)
}

///|
/// Python `paren(expression, copy)`.
pub fn exp_paren(expression : Expr, copy? : Bool = true) -> Expr {
  mk1(Paren, maybe_copy(expression, copy))
}

///|
/// Python `not_(expression, copy)`.
pub fn exp_not(expression : Expr, copy? : Bool = true) -> Expr {
  mk1(Not, exp_wrap(maybe_copy(expression, copy), Connector))
}

///|
/// Python `_combine(expressions, operator, copy, wrap)`.
fn exp_combine(
  expressions : Array[Expr],
  operator : Kind,
  copy : Bool,
  wrap : Bool,
) -> Expr {
  let conditions = expressions.map(e => maybe_copy(e, copy))
  let mut this = conditions[0]
  if conditions.length() > 1 && wrap {
    this = exp_wrap(this, Connector)
  }
  for i in 1..<conditions.length() {
    let e = conditions[i]
    this = mk2(operator, this, if wrap { exp_wrap(e, Connector) } else { e })
  }
  this
}

///|
/// Python `and_(*expressions)`.
pub fn exp_and(
  expressions : Array[Expr],
  copy? : Bool = true,
  wrap? : Bool = true,
) -> Expr {
  exp_combine(expressions, And, copy, wrap)
}

///|
/// Python `or_(*expressions)`.
pub fn exp_or(
  expressions : Array[Expr],
  copy? : Bool = true,
  wrap? : Bool = true,
) -> Expr {
  exp_combine(expressions, Or, copy, wrap)
}

///|
/// Python `alias_(expression, alias)` with `table=False`.
pub fn exp_alias(
  expression : Expr,
  alias_ : Value,
  quoted? : Bool,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let e = maybe_copy(expression, copy)
  let alias_ = to_identifier_value(alias_, quoted?)
  if e.kind.has_arg("alias") && e.kind != Window {
    e.set("alias", alias_)
    return e
  }
  mk(Alias, [("this", e), ("alias", alias_)])
}

///|
/// Python `exp.cast(expression, to, copy, dialect)` with a DataType expression.
pub fn exp_cast_to(
  expression : Expr,
  to : Expr,
  copy? : Bool = true,
  dialect? : Dialect,
) -> Expr {
  let expr = maybe_copy(expression, copy)
  let data_type = maybe_copy(to, copy)
  if expr.kind == Cast {
    let target_dialect = match dialect {
      Some(d) => d
      None => base_dialect()
    }
    let type_mapping = target_dialect.gen_cfg.type_mapping
    let existing = match expr.arg("to") {
      Some(t) => t.datatype_this()
      None => None
    }
    let new_type = data_type.datatype_this()
    let types_are_equivalent = match (existing, new_type) {
      (Some(a), Some(b)) => {
        let ma = match type_mapping.get(a) {
          Some(v) => v
          None => a.value()
        }
        let mb = match type_mapping.get(b) {
          Some(v) => v
          None => b.value()
        }
        ma == mb
      }
      _ => false
    }
    if expr.is_type_expr(data_type) || types_are_equivalent {
      return expr
    }
  }
  let cast = mk(Cast, [("this", expr), ("to", data_type)])
  cast.set_type(Some(data_type))
  cast
}

///|
/// Python `exp.cast(expression, dtype, copy, dialect)` with a `DType`.
pub fn exp_cast(
  expression : Expr,
  to : DType,
  copy? : Bool = true,
  dialect? : Dialect,
) -> Expr {
  exp_cast_to(expression, datatype_of(to), copy~, dialect?)
}

///|
/// Python `Query.subquery(alias, copy)`.
pub fn exp_subquery_of(
  query : Expr,
  alias_? : String,
  copy? : Bool = true,
) -> Expr {
  let instance = maybe_copy(query, copy)
  match alias_ {
    Some(a) if a != "" =>
      mk(Subquery, [
        ("this", instance),
        ("alias", mk1(TableAlias, to_identifier(a))),
      ])
    _ => mk1(Subquery, instance)
  }
}

///|
/// Python `Query.subquery(alias_expr, copy)` where alias is already an expression.
pub fn exp_subquery_with_alias_expr(
  query : Expr,
  alias_ : Expr?,
  copy? : Bool = true,
) -> Expr {
  let instance = maybe_copy(query, copy)
  mk(Subquery, [("this", instance), ("alias", alias_)])
}

///|
/// Python `exp.select(*projections).from_(from_expr, copy=False)`.
pub fn exp_select_from(projections : Array[Expr], from_expr : Expr) -> Expr {
  let from_node = if from_expr.kind == From {
    from_expr
  } else {
    mk1(From, from_expr)
  }
  mk(Select, [("expressions", projections), ("from_", from_node)])
}

///|
/// Python `exp.union(left, right, distinct=distinct, copy=False)`.
pub fn exp_union(left : Expr, right : Expr, distinct? : Bool = true) -> Expr {
  mk(Union, [("this", left), ("expression", right), ("distinct", distinct)])
}

///|
/// Python `exp.case()`.
pub fn exp_case() -> Expr {
  mk(Case, [("ifs", ([] : Array[Expr]))])
}

///|
/// Python `Case.when(condition, then, copy)`.
pub fn case_when(
  case_ : Expr,
  condition : Expr,
  then : Expr,
  copy? : Bool = true,
) -> Expr {
  let instance = maybe_copy(case_, copy)
  instance.append(
    "ifs",
    mk(If, [
      ("this", maybe_copy(condition, copy)),
      ("true", maybe_copy(then, copy)),
    ]),
  )
  instance
}

///|
/// Python `Case.else_(value, copy)`.
pub fn case_else(case_ : Expr, value : Expr, copy? : Bool = true) -> Expr {
  let instance = maybe_copy(case_, copy)
  instance.set("default", maybe_copy(value, copy))
  instance
}

///|
/// Python `maybe_parse(sql, dialect=dialect)` for a SQL string.
pub fn maybe_parse_str(
  sql : String,
  dialect? : Dialect,
) -> Expr raise SqlglotError {
  parse_one(sql, dialect?)
}

///|
/// Python `exp.table_(name)` for an identifier expression.
pub fn exp_table_from_identifier(table : Expr?) -> Expr raise SqlglotError {
  match table {
    Some(t) => mk1(Table, to_identifier_value(Node(t)))
    None => mk0(Table)
  }
}
