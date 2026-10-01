// Port of sqlglot/optimizer/eliminate_subqueries.py.

///|
priv struct CteState {
  existing_ctes : Array[(@core.Expr, String)]
  taken : Map[String, Bool]
}

///|
fn CteState::existing_get(self : CteState, e : @core.Expr) -> String? {
  for kv in self.existing_ctes {
    if kv.0 == e {
      return Some(kv.1)
    }
  }
  None
}

///|
/// `exp.alias_(exp.table_(name), alias=alias)`
fn aliased_table(name : String, alias : String) -> @core.Expr {
  let table = @core.mk1(Table, @core.to_identifier(name))
  table.set("alias", @core.to_identifier(alias))
  table
}

///|
/// Rewrite derived tables as CTES, deduplicating if possible.
pub fn eliminate_subqueries(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind.is_a(Subquery) {
    eliminate_subqueries(expression.this_()) |> ignore
    return expression
  }
  let root = match build_scope(expression) {
    Some(r) => r
    None => return expression
  }
  let state : CteState = { existing_ctes: [], taken: {} }
  for scope in root.cte_scopes {
    match scope.expression.parent {
      Some(p) => state.taken[p.alias()] = true
      None => ()
    }
  }
  for scope in root.traverse() {
    for _, source in scope.sources {
      match source {
        TableSource(t) => state.taken[t.name()] = true
        _ => ()
      }
    }
  }
  let mut recursive : @core.Value? = Some(Bool(false))
  match root.expression.arg("with_") {
    Some(with_) => {
      recursive = with_.get("recursive")
      for cte in with_.expressions() {
        let this = cte.this_()
        let mut found = false
        for i, kv in state.existing_ctes {
          if kv.0 == this {
            state.existing_ctes[i] = (kv.0, cte.alias())
            found = true
            break
          }
        }
        if !found {
          state.existing_ctes.push((this, cte.alias()))
        }
      }
    }
    None => ()
  }
  let new_ctes = []
  for cte_scope in root.cte_scopes {
    for scope in cte_scope.traverse() {
      if physical_equal(scope, cte_scope) {
        continue
      }
      match eliminate_scope(scope, state) {
        Some(c) => new_ctes.push(c)
        None => ()
      }
    }
    match cte_scope.expression.parent {
      Some(p) => new_ctes.push(p)
      None => ()
    }
  }
  for scope in root.set_operation_scopes + root.subquery_scopes + root.table_scopes {
    for child_scope in scope.traverse() {
      match eliminate_scope(child_scope, state) {
        Some(c) => new_ctes.push(c)
        None => ()
      }
    }
  }
  if !new_ctes.is_empty() {
    let mut query = if expression.kind.is_a(DDL) {
      expression.expression_()
    } else {
      expression
    }
    if !query.kind.is_a(Query) {
      query = root.expression.unnest()
    }
    let with_ = @core.mk(With, [("expressions", new_ctes)])
    match recursive {
      Some(v) => with_.set("recursive", v)
      None => ()
    }
    query.set("with_", with_)
  }
  expression
}

///|
fn eliminate_scope(
  scope : Scope,
  state : CteState,
) -> @core.Expr? raise @core.SqlglotError {
  if scope.is_derived_table() {
    return eliminate_derived_table(scope, state)
  }
  if scope.is_cte() {
    return eliminate_cte(scope, state)
  }
  None
}

///|
fn eliminate_derived_table(scope : Scope, state : CteState) -> @core.Expr? {
  let parent_scope = match scope.parent {
    Some(p) => p
    None => return None
  }
  if !parent_scope.pivots().is_empty() ||
    parent_scope.expression.kind.is_a(Lateral) {
    return None
  }
  let expr_parent = match scope.expression.parent {
    Some(p) if p.kind.is_a(Subquery) && !physical_equal(p, parent_scope.expression) =>
      p
    _ => return None
  }
  let to_replace = expr_parent.unwrap_subquery()
  let (name, cte) = new_cte(scope, state)
  let alias = if to_replace.alias() != "" { to_replace.alias() } else { name }
  let table = aliased_table(name, alias)
  match to_replace.get("joins") {
    Some(j) => table.set("joins", j)
    None => ()
  }
  to_replace.replace(Some(table)) |> ignore
  cte
}

///|
fn eliminate_cte(
  scope : Scope,
  state : CteState,
) -> @core.Expr? raise @core.SqlglotError {
  let parent = match scope.expression.parent {
    Some(p) => p
    None => return None
  }
  let (name, cte) = new_cte(scope, state)
  let with_ = parent.parent
  parent.pop() |> ignore
  match with_ {
    Some(w) if w.expressions().is_empty() => w.pop() |> ignore
    _ => ()
  }
  let scope_parent = match scope.parent {
    Some(p) => p
    None => return cte
  }
  for child_scope in scope_parent.traverse() {
    for _, v in child_scope.selected_sources() {
      let (table, source) = v
      match source {
        ScopeSource(s) if physical_equal(s, scope) =>
          table.replace(Some(aliased_table(name, table.alias_or_name()))) |> ignore
        _ => ()
      }
    }
  }
  cte
}

///|
fn new_cte(scope : Scope, state : CteState) -> (String, @core.Expr?) {
  let duplicate_cte_alias = state.existing_get(scope.expression)
  let mut name = match scope.expression.parent {
    Some(p) => p.alias()
    None => ""
  }
  if name == "" {
    name = @core.find_new_name(n => state.taken.contains(n), "cte")
  }
  match duplicate_cte_alias {
    Some(d) if d != "" => name = d
    _ =>
      if state.taken.contains(name) {
        name = @core.find_new_name(n => state.taken.contains(n), name)
      }
  }
  state.taken[name] = true
  match duplicate_cte_alias {
    Some(d) if d != "" => (name, None)
    _ => {
      state.existing_ctes.push((scope.expression, name))
      let cte = @core.mk(CTE, [
        ("this", scope.expression),
        ("alias", @core.mk1(TableAlias, @core.to_identifier(name))),
      ])
      (name, Some(cte))
    }
  }
}
