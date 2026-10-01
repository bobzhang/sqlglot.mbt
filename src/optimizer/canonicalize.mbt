// Port of sqlglot/optimizer/canonicalize.py.

///|
/// Python `exp.replace_tree`: replaces the tree with the results of `fun` on each node,
/// leaves first; new nodes are traversed too.
pub fn replace_tree(
  expression : @core.Expr,
  fun : (@core.Expr) -> @core.Expr raise @core.SqlglotError,
  prune? : (@core.Expr) -> Bool,
) -> @core.Expr raise @core.SqlglotError {
  let stack = expression.dfs(prune?).collect()
  let mut new_node = expression
  while stack.pop() is Some(node) {
    new_node = fun(node)
    if !physical_equal(new_node, node) {
      node.replace(Some(new_node)) |> ignore
      stack.push(new_node)
    }
  }
  new_node
}

///|
let canonicalize_kinds : Array[@core.Kind] = [
  Add, Date, TsOrDsToDate, Timestamp, Sub, EQ, NEQ, GT, GTE, LT, LTE, NullSafeEQ, NullSafeNEQ,
  Between, Extract, DateAdd, DateSub, DateTrunc, DateDiff, Cast, Connector, Not, If, Where,
  Having, Ordered,
]

///|
let coercible_date_ops : Array[@core.Kind] = [
  Add, Sub, EQ, NEQ, GT, GTE, LT, LTE, NullSafeEQ, NullSafeNEQ,
]

///|
/// Converts a sql expression into a standard form.
pub fn canonicalize(
  expression : @core.Expr,
  dialect? : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  let dialect = get_dialect(dialect)
  replace_tree(expression, e => {
    if !e.kind.is_any(canonicalize_kinds) {
      return e
    }
    let mut e = add_text_to_concat(e)
    e = replace_date_funcs(e, dialect)
    e = coerce_type(e, dialect.cfg.promote_to_inferred_datetime_type)
    e = remove_redundant_casts(e)
    e = canonicalize_ensure_bools(e, replace_int_predicate)
    e = remove_ascending_order(e)
    e
  })
}

///|
fn type_in(e : @core.Expr, set : Array[@core.DType]) -> Bool {
  match e.get_type() {
    Some(t) =>
      match t.datatype_this() {
        Some(d) => set.contains(d)
        None => false
      }
    None => false
  }
}

///|
fn add_text_to_concat(node : @core.Expr) -> @core.Expr {
  if node.kind.is_a(Add) && type_in(node, @core.dtype_text_types) {
    return @core.mk(Concat, [
      ("expressions", [node.this_(), node.expression_()]),
      ("coalesce", false),
    ])
  }
  node
}

///|
fn replace_date_funcs(
  node : @core.Expr,
  dialect : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  if node.kind.is_any([Date, TsOrDsToDate]) &&
    node.expressions().is_empty() &&
    !node.has("zone") &&
    node.this_().is_string() &&
    is_iso_date(node.this_().name()) {
    return @core.exp_cast(node.this_(), DATE)
  }
  if node.kind.is_a(Timestamp) && !node.has("zone") {
    let node = if node.get_type() is None {
      annotate_types(node, dialect~)
    } else {
      node
    }
    return match node.get_type() {
      Some(t) => @core.exp_cast_to(node.this_(), t)
      None => @core.exp_cast(node.this_(), TIMESTAMP)
    }
  }
  node
}

///|
fn coerce_type(
  node : @core.Expr,
  promote_to_inferred_datetime_type : Bool,
) -> @core.Expr {
  if node.kind.is_any(coercible_date_ops) {
    coerce_date_args(
      node.this_(),
      node.expression_(),
      promote_to_inferred_datetime_type,
    )
  } else if node.kind.is_a(Between) {
    coerce_date_args(
      node.this_(),
      node.arg("low").unwrap(),
      promote_to_inferred_datetime_type,
    )
  } else if node.kind.is_a(Extract) &&
    !node.expression_().is_type(@core.dtype_temporal_types) {
    replace_cast(node.expression_(), @core.datatype_of(DATETIME))
  } else if node.kind.is_any([DateAdd, DateSub, DateTrunc]) {
    coerce_timeunit_arg(node.this_(), node.arg("unit")) |> ignore
  } else if node.kind.is_a(DateDiff) {
    for e in [node.this_(), node.expression_()] {
      if !type_in(e, @core.dtype_temporal_types) {
        e.replace(Some(@core.exp_cast(e.copy(), DATETIME))) |> ignore
      }
    }
  }
  node
}

///|
fn remove_redundant_casts(expression : @core.Expr) -> @core.Expr {
  if expression.kind.is_a(Cast) {
    match (expression.this_().get_type(), expression.arg("to")) {
      (Some(t), Some(to)) if to == t => return expression.this_()
      _ => ()
    }
  }
  if expression.kind.is_any([Date, TsOrDsToDate]) {
    match expression.this_().get_type() {
      Some(t) if t.datatype_this() == Some(DATE) && t.expressions().is_empty() =>
        return expression.this_()
      _ => ()
    }
  }
  expression
}

///|
fn canonicalize_ensure_bools(
  expression : @core.Expr,
  replace_func : (@core.Expr) -> Unit,
) -> @core.Expr {
  if expression.kind.is_a(Connector) {
    replace_func(expression.this_())
    replace_func(expression.expression_())
  } else if expression.kind.is_a(Not) {
    replace_func(expression.this_())
  } else if expression.kind.is_a(If) &&
    !(match expression.parent {
      Some(p) => p.kind.is_a(Case) && p.has("this")
      None => false
    }) {
    replace_func(expression.this_())
  } else if expression.kind.is_any([Where, Having]) {
    replace_func(expression.this_())
  }
  expression
}

///|
fn remove_ascending_order(expression : @core.Expr) -> @core.Expr {
  if expression.kind.is_a(Ordered) && expression.get("desc") is Some(Bool(false)) {
    expression.set("desc", @core.null_arg)
  }
  expression
}

///|
fn coerce_date_args(
  a : @core.Expr,
  b : @core.Expr,
  promote_to_inferred_datetime_type : Bool,
) -> Unit {
  for perm in [(a, b), (b, a)] {
    let (a0, b) = perm
    let mut a = a0
    if b.kind.is_a(Interval) {
      a = coerce_timeunit_arg(a, b.arg("unit"))
    }
    let a_type = match a.get_type() {
      Some(t) => t
      None => continue
    }
    let a_this = match a_type.datatype_this() {
      Some(d) if @core.dtype_temporal_types.contains(d) => d
      _ => continue
    }
    if !type_in(b, @core.dtype_text_types) {
      continue
    }
    let target_type = if promote_to_inferred_datetime_type {
      let b_type = if b.is_string() {
        let date_text = b.name()
        if is_iso_date(date_text) {
          @core.DType::DATE
        } else if is_iso_datetime(date_text) {
          DATETIME
        } else {
          a_this
        }
      } else {
        DATETIME
      }
      match default_coerces_to.get(a_this) {
        Some(s) if s.contains(b_type) => @core.datatype_of(b_type)
        _ => a_type
      }
    } else {
      a_type
    }
    if target_type != a_type {
      replace_cast(a, target_type)
    }
    replace_cast(b, target_type)
  }
}

///|
fn coerce_timeunit_arg(arg : @core.Expr, unit : @core.Expr?) -> @core.Expr {
  let t = match arg.get_type() {
    Some(t) => t
    None => return arg
  }
  let this = t.datatype_this()
  match this {
    Some(d) if @core.dtype_text_types.contains(d) => {
      let date_text = arg.name()
      let is_iso_date_ = is_iso_date(date_text)
      if is_iso_date_ && is_date_unit(unit) {
        return arg.replace(Some(@core.exp_cast(arg.copy(), DATE))).unwrap()
      }
      if is_iso_date_ || is_iso_datetime(date_text) {
        return arg.replace(Some(@core.exp_cast(arg.copy(), DATETIME))).unwrap()
      }
    }
    Some(DATE) if !is_date_unit(unit) =>
      return arg.replace(Some(@core.exp_cast(arg.copy(), DATETIME))).unwrap()
    _ => ()
  }
  arg
}

///|
fn replace_cast(node : @core.Expr, to : @core.Expr) -> Unit {
  node.replace(Some(@core.exp_cast_to(node.copy(), to))) |> ignore
}

///|
fn replace_int_predicate(expression : @core.Expr) -> Unit {
  if expression.kind.is_a(Coalesce) {
    for child in expression.iter_expressions() {
      replace_int_predicate(child)
    }
  } else if type_in(expression, @core.dtype_integer_types) {
    expression.replace(Some(@core.exp_neq(expression, @core.literal_int(0))))
    |> ignore
  }
}
