// A minimal subset of sqlglot/optimizer/scope.py (`Scope` of a single SELECT) used by
// the Snowflake generator transforms, until the optimizer package is ported.

///|
priv struct MiniScope {
  expression : @core.Expr
  /// `Scope.sources` keys (CTE names, then FROM/JOIN/LATERAL source names)
  sources : Array[String]
}

///|
fn is_derived_table(e : @core.Expr) -> Bool {
  e.kind == Subquery &&
  (
    e.alias() != "" ||
    (match e.this() {
      Some(t) => t.kind.is_any([Select, SetOperation])
      None => false
    })
  )
}

///|
/// `_get_source_alias`
fn get_source_alias(e : @core.Expr) -> String {
  let mut alias_name = e.alias()
  if alias_name == "" {
    match e.arg("alias") {
      Some(a) if a.kind == TableAlias && a.list("columns").length() == 1 =>
        alias_name = a.list("columns")[0].name()
      _ => ()
    }
  }
  alias_name
}

///|
fn walk_scope(expression : @core.Expr) -> Array[@core.Expr] {
  let all = []
  @core.gen_walk_in_scope(expression, all)
  all
}

///|
/// `build_scope(select)` restricted to the root scope's source names.
fn build_mini_scope(expression : @core.Expr) -> MiniScope {
  let sources : Array[String] = []
  let add = (name : String) => if !sources.contains(name) { sources.push(name) }
  match expression.arg("with_") {
    Some(w) =>
      for cte in w.expressions() {
        add(cte.alias())
      }
    None => ()
  }
  let cte_names = sources.copy()
  let expressions : Array[@core.Expr] = []
  match expression.arg("from_") {
    Some(f) => if f.this() is Some(t) { expressions.push(t) }
    None => ()
  }
  for join in expression.list("joins") {
    if join.this() is Some(t) {
      expressions.push(t)
    }
  }
  for l in expression.list("laterals") {
    expressions.push(l)
  }
  let mut i = 0
  while i < expressions.length() {
    let mut node = expressions[i]
    i += 1
    if node.kind == Final {
      node = node.this_()
    }
    if node.kind == Table {
      let table_name = node.name()
      let source_name = node.alias_or_name()
      if cte_names.contains(table_name) && node.db() == "" {
        let pivots = node.list("pivots")
        if !pivots.is_empty() {
          add(pivots[pivots.length() - 1].alias())
        } else {
          add(source_name)
        }
      } else if sources.contains(source_name) {
        add(@core.find_new_name(n => sources.contains(n), table_name))
      } else {
        add(source_name)
      }
      for join in node.list("joins") {
        if join.this() is Some(t) {
          expressions.push(t)
        }
      }
      continue
    }
    if !node.kind.is_a(DerivedTable) {
      continue
    }
    if node.kind.is_a(UDTF) {
      add(get_source_alias(node))
    } else if is_derived_table(node) {
      for join in node.list("joins") {
        if join.this() is Some(t) {
          expressions.push(t)
        }
      }
      add(get_source_alias(node))
    } else {
      if node.this() is Some(t) {
        expressions.push(t)
      }
      for join in node.list("joins") {
        if join.this() is Some(t) {
          expressions.push(t)
        }
      }
    }
  }
  { expression, sources, }
}

///|
/// `Scope.columns` (without the external columns of child scopes).
fn scope_columns(expression : @core.Expr) -> Array[@core.Expr] {
  let named_selects = if expression.kind.is_a(Query) {
    expression.named_selects()
  } else {
    []
  }
  let out = []
  for column in walk_scope(expression) {
    if physical_equal(column, expression) || column.kind != Column {
      continue
    }
    if column.this() is Some(t) && t.kind == Star {
      continue
    }
    let ancestor = column.find_ancestor([
      Select,
      Qualify,
      Order,
      Cluster,
      Having,
      Hint,
      Table,
      Star,
      Distinct,
    ])
    let keep = match ancestor {
      None => true
      Some(a) =>
        column.text("table") != "" ||
        a.kind == Select ||
        (
          a.kind == Table &&
          !(match a.this() {
            Some(t) => t.kind.is_a(Func)
            None => false
          })
        ) ||
        (
          a.kind.is_any([Order, Cluster, Distinct]) &&
          (
            (match a.parent {
              Some(p) =>
                p.kind.is_any([Window, WithinGroup]) || p.kind != Select
              None => true
            }) ||
            !named_selects.contains(column.name())
          )
        ) ||
        (a.kind == Star && column.arg_key != Some("except_"))
    }
    if keep {
      out.push(column)
    }
  }
  out
}
