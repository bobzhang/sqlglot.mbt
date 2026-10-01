// Python-faithful builder helpers and methods taking host values (port of the
// `_apply_*_builder` helpers and the builder methods in sqlglot/expressions/*.py).

///|
/// Converts builder arguments to host values.
pub fn[T : IntoPy] py_list(xs : Array[T]) -> Array[PyObj] {
  xs.map(x => x.into_py())
}

///|
/// Python truthiness of a host value.
pub fn PyObj::truthy(self : PyObj) -> Bool {
  match self {
    PyExpr(_) => true
    PyStr(s) => !s.is_empty()
    PyInt(i) => i != 0L
    PyFloat(d) => d != 0.0
    PyDecimal(s) => s != "0"
    PyBool(b) => b
    PyNone => false
    PyTuple(l) | PyList(l) => !l.is_empty()
    PyDict(l) => !l.is_empty()
    PyBytes(b) => b.length() > 0
    PyObject(_) | PyDate(..) | PyTime(..) | PyDateTime(..) => true
  }
}

///|
/// Python `_apply_builder`.
fn apply_builder(
  expression : PyObj,
  instance : Expr,
  arg : String,
  copy~ : Bool,
  prefix? : String,
  into? : Kind,
  dialect? : Dialect,
  into_arg? : String = "this",
) -> Expr raise SqlglotError {
  let expression = match (expression, into) {
    (PyExpr(e), Some(k)) if !e.kind.is_a(k) => PyExpr(mk(k, [(into_arg, e)]))
    _ => expression
  }
  let inst = maybe_copy(instance, copy)
  let parsed = maybe_parse(
    expression,
    prefix?,
    into?=into.map(k => [k][:]),
    dialect?,
  )
  inst.set(arg, parsed)
  inst
}

///|
/// Python `_apply_child_list_builder`.
fn apply_child_list_builder(
  expressions : Array[PyObj],
  instance : Expr,
  arg : String,
  append~ : Bool,
  copy~ : Bool,
  prefix? : String,
  into~ : Kind,
  dialect? : Dialect,
  properties? : Map[String, Value] = Map([]),
) -> Expr raise SqlglotError {
  let inst = maybe_copy(instance, copy)
  let mut parsed : Array[Expr] = []
  for expression in expressions {
    if expression is PyNone {
      continue
    }
    let expression = match expression {
      PyExpr(e) if !e.kind.is_a(into) =>
        PyExpr(mk(into, [("expressions", [e])]))
      _ => expression
    }
    let e = maybe_parse(expression, into=[into], dialect?, prefix?)
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
          Node(n) => parsed.push(n)
          _ => ()
        }
      } else {
        properties[k] = v
      }
    }
  }
  match inst.arg(arg) {
    Some(existing) if append => parsed = existing.expressions() + parsed
    _ => ()
  }
  let child = mk(into, [("expressions", parsed)])
  for k, v in properties {
    child.set(k, v)
  }
  inst.set(arg, child)
  inst
}

///|
/// Python `_apply_list_builder`.
fn apply_list_builder(
  expressions : Array[PyObj],
  instance : Expr,
  arg : String,
  append~ : Bool,
  copy~ : Bool,
  prefix? : String,
  into? : Kind,
  dialect? : Dialect,
) -> Expr raise SqlglotError {
  let inst = maybe_copy(instance, copy)
  let mut parsed = []
  for expression in expressions {
    if expression is PyNone {
      continue
    }
    parsed.push(
      maybe_parse(expression, into?=into.map(k => [k][:]), prefix?, dialect?),
    )
  }
  let existing = inst.list(arg)
  if append && !existing.is_empty() {
    parsed = existing + parsed
  }
  inst.set(arg, parsed)
  inst
}

///|
/// Python `_apply_conjunction_builder`.
fn apply_conjunction_builder(
  expressions : Array[PyObj],
  instance : Expr,
  arg : String,
  into? : Kind,
  append~ : Bool,
  copy~ : Bool,
  dialect? : Dialect,
) -> Expr raise SqlglotError {
  let mut filtered = expressions.filter(e => !(e is PyNone) && !(e is PyStr("")))
  if filtered.is_empty() {
    return instance
  }
  let inst = maybe_copy(instance, copy)
  match inst.arg(arg) {
    Some(existing) if append =>
      filtered = [
          match into {
            Some(_) =>
              match existing.this() {
                Some(t) => PyExpr(t)
                None => PyNone
              }
            None => PyExpr(existing)
          },
        ] +
        filtered
    _ => ()
  }
  let node = combine_py(filtered, And, dialect?, copy~)
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
/// Python `_combine`: parses the conditions and combines them with `operator` (`And`,
/// `Or` or `Xor`), wrapping connector operands in parentheses when `wrap` is set.
pub fn combine_py(
  expressions : Array[PyObj],
  operator : Kind,
  dialect? : Dialect,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> Expr raise SqlglotError {
  let conditions = []
  for e in expressions {
    if !(e is PyNone) {
      conditions.push(condition(e, dialect?, copy~))
    }
  }
  if conditions.is_empty() {
    raise ValueError("not enough values to unpack (expected at least 1, got 0)")
  }
  let wrap_ = fn(e : Expr) {
    if e.kind.is_a(Connector) {
      mk1(Paren, e)
    } else {
      e
    }
  }
  let mut this = conditions[0]
  if conditions.length() > 1 && wrap {
    this = wrap_(this)
  }
  for i in 1..<conditions.length() {
    let e = conditions[i]
    this = mk(operator, [
      ("this", this),
      ("expression", if wrap { wrap_(e) } else { e }),
    ])
  }
  this
}

///|
/// Python `_apply_set_operation`.
pub fn apply_set_operation(
  expressions : Array[PyObj],
  kind : Kind,
  distinct? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let mut result : Expr? = None
  for e in expressions {
    let parsed = maybe_parse(e, dialect?, copy~)
    result = Some(
      match result {
        None => parsed
        Some(r) =>
          mk(kind, [("this", r), ("expression", parsed), ("distinct", distinct)])
      },
    )
  }
  match result {
    Some(r) => r
    None => raise ValueError("At least one expression is required")
  }
}

///|
/// Python `exp.condition(expression)`: parses a logical condition.
pub fn[T : IntoPy] condition(
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  maybe_parse(expression, into=[Condition], dialect?, copy~)
}

///|
/// Python `Expr._binop(klass, other, reverse)`.
pub fn[T : IntoPy] Expr::binop(
  self : Expr,
  kind : Kind,
  other : T,
  reverse? : Bool = false,
) -> Expr raise SqlglotError {
  let mut this = self.copy()
  let mut other = convert(other, copy=true)
  if !this.kind.is_a(kind) && !other.kind.is_a(kind) {
    this = wrap_binary(this)
    other = wrap_binary(other)
  }
  if reverse {
    mk(kind, [("this", other), ("expression", this)])
  } else {
    mk(kind, [("this", this), ("expression", other)])
  }
}

// ---------------------------------------------------------------------------
// Expr methods

///|
/// `Expr.and_(*expressions)`
pub fn[T : IntoPy] Expr::and_(
  self : Expr,
  expressions : Array[T],
  dialect? : Dialect,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> Expr raise SqlglotError {
  combine_py([PyExpr(self)] + py_list(expressions), And, dialect?, copy~, wrap~)
}

///|
/// `Expr.or_(*expressions)`
pub fn[T : IntoPy] Expr::or_(
  self : Expr,
  expressions : Array[T],
  dialect? : Dialect,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> Expr raise SqlglotError {
  combine_py([PyExpr(self)] + py_list(expressions), Or, dialect?, copy~, wrap~)
}

///|
/// `Expr.not_()`
pub fn Expr::not_(self : Expr, copy? : Bool = true) -> Expr raise SqlglotError {
  not_(condition(self, copy~), copy=false)
}

///|
/// `Expr.isin(*expressions, query=..., unnest=...)`
pub fn Expr::isin(
  self : Expr,
  expressions? : Array[&IntoPy] = [],
  query? : &IntoPy,
  unnest? : Array[&IntoPy] = [],
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let subquery = match query {
    Some(q) if q.into_py().truthy() => {
      let s = maybe_parse(q.into_py(), dialect?, copy~)
      Some(if s.kind.is_a(Query) { s.subquery(copy=false) } else { s })
    }
    _ => None
  }
  let unnest_expr = if unnest.is_empty() {
    None
  } else {
    let exprs = []
    for u in unnest {
      exprs.push(maybe_parse(u.into_py(), dialect?, copy~))
    }
    Some(mk(Unnest, [("expressions", exprs)]))
  }
  let converted = []
  for e in expressions {
    converted.push(convert(e.into_py(), copy~))
  }
  mk(In, [
    ("this", maybe_copy(self, copy)),
    ("expressions", converted),
    ("query", subquery),
    ("unnest", unnest_expr),
  ])
}

///|
/// `Expr.between(low, high, symmetric=...)`
pub fn[L : IntoPy, H : IntoPy] Expr::between(
  self : Expr,
  low : L,
  high : H,
  copy? : Bool = true,
  symmetric? : Bool,
) -> Expr raise SqlglotError {
  let between = mk(Between, [
    ("this", maybe_copy(self, copy)),
    ("low", convert(low, copy~)),
    ("high", convert(high, copy~)),
  ])
  match symmetric {
    Some(s) => between.set("symmetric", s)
    None => ()
  }
  between
}

///|
/// `Expr.like(other)`
pub fn[T : IntoPy] Expr::like(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(Like, other)
}

///|
/// `Expr.ilike(other)`
pub fn[T : IntoPy] Expr::ilike(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(ILike, other)
}

///|
/// `Expr.rlike(other)`
pub fn[T : IntoPy] Expr::rlike(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(RegexpLike, other)
}

///|
/// `Expr.neq(other)`
pub fn[T : IntoPy] Expr::neq(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(NEQ, other)
}

///|
/// `Expr.div(other, typed=..., safe=...)`
pub fn[T : IntoPy] Expr::div(
  self : Expr,
  other : T,
  typed? : Bool = false,
  safe? : Bool = false,
) -> Expr raise SqlglotError {
  let div = self.binop(Div, other)
  div.set("typed", typed)
  div.set("safe", safe)
  div
}

///|
/// `Expr.asc(nulls_first=True)`
pub fn Expr::asc(self : Expr, nulls_first? : Bool = true) -> Expr {
  mk(Ordered, [("this", self.copy()), ("nulls_first", nulls_first)])
}

///|
/// `Expr.desc(nulls_first=False)`
pub fn Expr::desc(self : Expr, nulls_first? : Bool = false) -> Expr {
  mk(Ordered, [
    ("this", self.copy()),
    ("desc", true),
    ("nulls_first", nulls_first),
  ])
}

///|
/// Python `expr + other` (`Expr.__add__`).
pub fn[T : IntoPy] Expr::add(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Add, other)
}

///|
/// Python `expr - other` (`Expr.__sub__`).
pub fn[T : IntoPy] Expr::sub(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Sub, other)
}

///|
/// Python `expr * other` (`Expr.__mul__`).
pub fn[T : IntoPy] Expr::mul(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Mul, other)
}

///|
/// Python `expr / other` (`Expr.__truediv__`).
pub fn[T : IntoPy] Expr::truediv(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(Div, other)
}

///|
/// Python `expr // other` (`Expr.__floordiv__`).
pub fn[T : IntoPy] Expr::floordiv(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(IntDiv, other)
}

///|
/// Python `expr % other` (`Expr.__mod__`).
pub fn[T : IntoPy] Expr::mod(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Mod, other)
}

///|
/// Python `expr ** other` (`Expr.__pow__`).
pub fn[T : IntoPy] Expr::pow(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Pow, other)
}

///|
/// Python `expr & other` (`Expr.__and__`).
pub fn[T : IntoPy] Expr::land(
  self : Expr,
  other : T,
) -> Expr raise SqlglotError {
  self.binop(And, other)
}

///|
/// Python `expr | other` (`Expr.__or__`).
pub fn[T : IntoPy] Expr::lor(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(Or, other)
}

///|
/// Python `expr < other` (`Expr.__lt__`).
pub fn[T : IntoPy] Expr::lt(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(LT, other)
}

///|
/// Python `expr <= other` (`Expr.__le__`).
pub fn[T : IntoPy] Expr::le(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(LTE, other)
}

///|
/// Python `expr > other` (`Expr.__gt__`).
pub fn[T : IntoPy] Expr::gt(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(GT, other)
}

///|
/// Python `expr >= other` (`Expr.__ge__`).
pub fn[T : IntoPy] Expr::ge(self : Expr, other : T) -> Expr raise SqlglotError {
  self.binop(GTE, other)
}

///|
/// Python `-expr` (`Expr.__neg__`).
pub fn Expr::neg(self : Expr) -> Expr {
  mk1(Neg, wrap_binary(self.copy()))
}

///|
/// Python `~expr` (`Expr.__invert__`).
pub fn Expr::invert(self : Expr) -> Expr raise SqlglotError {
  not_(condition(self.copy()), copy=false)
}

///|
/// Python `expr[other]` (`Expr.__getitem__`); several keys build a multi-index bracket.
pub fn Expr::getitem(
  self : Expr,
  keys : Array[&IntoPy],
) -> Expr raise SqlglotError {
  let exprs = []
  for k in keys {
    exprs.push(convert(k.into_py(), copy=true))
  }
  mk(Bracket, [("this", self.copy()), ("expressions", exprs)])
}

///|
/// `Expr.assert_is(type_)`: raises if this expression isn't of kind `kind`.
pub fn Expr::assert_is(self : Expr, kind : Kind) -> Expr raise SqlglotError {
  if !self.kind.is_a(kind) {
    let sql = Generator::new(base_dialect()).generate(self)
    raise ValueError("\{sql} is not \{class_path(kind)}.")
  }
  self
}

///|
/// `Expr.pipe(func)`: applies `func` to this expression and returns the result.
pub fn[R] Expr::pipe(self : Expr, func : (Expr) -> R raise?) -> R raise? {
  func(self)
}

///|
/// `Expr.apply(func)`: applies `func` to this expression for side effects and returns it.
pub fn Expr::apply(self : Expr, func : (Expr) -> Unit raise?) -> Expr raise? {
  func(self)
  self
}

///|
/// `Query.intersect(*expressions, distinct=...)`
pub fn[T : IntoPy] Expr::intersect_(
  self : Expr,
  other : T,
  distinct? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_set_operation(
    [PyExpr(self), other.into_py()],
    Intersect,
    distinct~,
    dialect?,
    copy~,
  )
}

///|
/// `Query.except_(*expressions, distinct=...)`
pub fn[T : IntoPy] Expr::except_(
  self : Expr,
  other : T,
  distinct? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_set_operation(
    [PyExpr(self), other.into_py()],
    Except,
    distinct~,
    dialect?,
    copy~,
  )
}

///|
/// `Select.sort_by(*expressions)`
pub fn[T : IntoPy] Expr::sort_by(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_child_list_builder(
    py_list(expressions),
    self,
    "sort",
    append~,
    copy~,
    prefix="SORT BY",
    into=Sort,
    dialect?,
  )
}

///|
/// `Select.cluster_by(*expressions)`
pub fn[T : IntoPy] Expr::cluster_by(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_child_list_builder(
    py_list(expressions),
    self,
    "cluster",
    append~,
    copy~,
    prefix="CLUSTER BY",
    into=Cluster,
    dialect?,
  )
}

///|
/// `Select.lateral(*expressions)`
pub fn[T : IntoPy] Expr::lateral(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_list_builder(
    py_list(expressions),
    self,
    "laterals",
    append~,
    copy~,
    prefix="LATERAL VIEW",
    into=Lateral,
    dialect?,
  )
}

///|
/// `Select.window(*expressions)`
pub fn[T : IntoPy] Expr::window(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_list_builder(
    py_list(expressions),
    self,
    "windows",
    append~,
    copy~,
    into=Window,
    dialect?,
  )
}

///|
/// `Select.qualify(*expressions)`
pub fn[T : IntoPy] Expr::qualify(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_conjunction_builder(
    py_list(expressions),
    self,
    "qualify",
    into=Qualify,
    append~,
    copy~,
    dialect?,
  )
}

///|
/// `Select.ctas(table, properties=...)`: converts this query to a CREATE TABLE AS statement.
pub fn[T : IntoPy] Expr::ctas(
  self : Expr,
  table : T,
  properties? : Map[String, PyObj],
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let instance = maybe_copy(self, copy)
  let table_expression = maybe_parse(table, into=[Table], dialect?)
  let properties_expression = match properties {
    Some(p) if !p.is_empty() => Some(properties_from_dict(p))
    _ => None
  }
  mk(Create, [
    ("this", table_expression),
    ("kind", "TABLE"),
    ("expression", instance),
    ("properties", properties_expression),
  ])
}

///|
/// `Select.lock(update=True)`
pub fn Expr::lock(
  self : Expr,
  update? : Bool = true,
  copy? : Bool = true,
) -> Expr {
  let inst = maybe_copy(self, copy)
  inst.set("locks", [mk(Lock, [("update", update)])])
  inst
}

///|
/// `Select.hint(*hints)`
pub fn[T : IntoPy] Expr::hint(
  self : Expr,
  hints : Array[T],
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let inst = maybe_copy(self, copy)
  let exprs = []
  for h in hints {
    exprs.push(maybe_parse(h, copy~, dialect?))
  }
  inst.set("hint", mk(Hint, [("expressions", exprs)]))
  inst
}

///|
/// `Join.on(*expressions)`
pub fn[T : IntoPy] Expr::on(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let join = apply_conjunction_builder(
    py_list(expressions),
    self,
    "on",
    append~,
    copy~,
    dialect?,
  )
  if py_upper(join.text("kind")) == "CROSS" {
    join.set("kind", null_arg)
  }
  join
}

///|
/// `Join.using(*expressions)`
pub fn[T : IntoPy] Expr::using_(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  let join = apply_list_builder(
    py_list(expressions),
    self,
    "using",
    append~,
    copy~,
    dialect?,
  )
  if py_upper(join.text("kind")) == "CROSS" {
    join.set("kind", null_arg)
  }
  join
}

///|
/// `DML.returning(expression)`
pub fn[T : IntoPy] Expr::returning(
  self : Expr,
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_builder(
    expression.into_py(),
    self,
    "returning",
    copy~,
    prefix="RETURNING",
    into=Returning,
    dialect?,
  )
}

///|
/// `Delete.delete(table)`: sets the table to delete from.
pub fn[T : IntoPy] Expr::delete(
  self : Expr,
  table : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_builder(table.into_py(), self, "this", copy~, into=Table, dialect?)
}

///|
/// `Update.table(expression)`: sets the table to update.
pub fn[T : IntoPy] Expr::table(
  self : Expr,
  expression : T,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_builder(expression.into_py(), self, "this", copy~, into=Table, dialect?)
}

///|
/// `Update.set_(*expressions)`
pub fn[T : IntoPy] Expr::set_(
  self : Expr,
  expressions : Array[T],
  append? : Bool = true,
  dialect? : Dialect,
  copy? : Bool = true,
) -> Expr raise SqlglotError {
  apply_list_builder(
    py_list(expressions),
    self,
    "expressions",
    append~,
    copy~,
    into=Expression,
    dialect?,
  )
}

///|
/// `Properties.from_dict(properties)`
pub fn properties_from_dict(
  properties : Map[String, PyObj],
) -> Expr raise SqlglotError {
  let name_to_property : Map[String, Kind] = Map([])
  for k, v in property_to_name {
    name_to_property[v] = k
  }
  let expressions = []
  for key, value in properties {
    match name_to_property.get(py_upper(key)) {
      Some(kind) => expressions.push(mk1(kind, convert(value)))
      None =>
        expressions.push(
          mk(Property, [
            ("this", literal_string(key)),
            ("value", convert(value)),
          ]),
        )
    }
  }
  mk(Properties, [("expressions", expressions)])
}

///|
/// Python `Expr.transform(fun)` where `fun` may return a node, a list of nodes or `None`
/// (Python's `transform` accepts any of these as replacement values).
pub fn Expr::transform_values(
  self : Expr,
  fun : (Expr) -> Value? raise?,
  copy? : Bool = true,
) -> Value raise? {
  let mut root : Value? = None
  let mut new_node : Value? = None
  let start = if copy { self.copy() } else { self }
  let it = start.dfs(prune=n => {
    match new_node {
      Some(Node(nn)) => !physical_equal(n, nn)
      _ => true
    }
  })
  while it.next() is Some(node) {
    let parent = node.parent
    let arg_key = node.arg_key
    let index = node.index
    let nn = fun(node)
    new_node = nn
    if root is None {
      root = nn
      if nn is None {
        break
      }
    } else {
      match (parent, arg_key) {
        (Some(p), Some(k)) => {
          let same = match nn {
            Some(Node(n)) => physical_equal(n, node)
            _ => false
          }
          if !same {
            match index {
              Some(i) => p.set_at(k, nn, i)
              None => p.set(k, nn)
            }
          }
        }
        _ => ()
      }
    }
  }
  match root {
    Some(r) => r
    None => abort("transform produced no root")
  }
}
