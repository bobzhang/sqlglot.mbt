// Port of sqlglot/optimizer/pushdown_predicates.py.

///|
fn dialect_is_a(dialect : @core.Dialect, names : Array[String]) -> Bool {
  let mut d : @core.Dialect? = Some(dialect)
  while d is Some(x) {
    if names.contains(x.name) {
      return true
    }
    d = x.parent
  }
  false
}

///|
fn sorted_strings(xs : Array[String]) -> Array[String] {
  let out = xs.copy()
  out.sort_by(py_str_cmp)
  out
}

///|
/// `Join.on(predicate, copy=False)`
fn join_on(join : @core.Expr, predicate : @core.Expr) -> Unit {
  let node = match join.arg("on") {
    Some(existing) => @core.and_([existing, predicate], copy=false)
    None => predicate
  }
  join.set("on", node)
  if @core.py_upper(join.text("kind")) == "CROSS" {
    join.set("kind", @core.null_arg)
  }
}

///|
/// Rewrite the AST to pushdown predicates in FROMS and JOINS.
pub fn pushdown_predicates(
  expression : @core.Expr,
  dialect? : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  let root = build_scope(expression)
  let dialect = get_dialect(dialect)
  let unnest_requires_cross_join = dialect_is_a(dialect, ["athena", "presto"])
  match root {
    Some(root) => {
      let scope_ref_count = root.ref_count()
      let scopes = root.traverse()
      scopes.rev_in_place()
      for scope in scopes {
        let select = scope.expression
        let joins = select.list("joins")
        match select.arg("where") {
          Some(where_) => {
            let join_index : Map[String, Int] = {}
            for i, join in joins {
              join_index[join.alias_or_name()] = i
            }
            let mut last_null_extending = -1
            for i, join in joins {
              let side = @core.py_upper(join.text("side"))
              if side == "RIGHT" || side == "FULL" {
                last_null_extending = i
              }
            }
            let mut pushdown_allowed = true
            let reachable : Map[String, (@core.Expr, Source)] = {}
            for k, v in scope.selected_sources() {
              let (node, _) = v
              let position = match node.find_ancestor([Join, From]) {
                Some(p) if p.kind.is_a(Join) => {
                  if node.kind.is_a(Unnest) && unnest_requires_cross_join {
                    pushdown_allowed = false
                    break
                  }
                  join_index.get(p.alias_or_name()).unwrap_or(-1)
                }
                _ => -1
              }
              if position >= last_null_extending {
                reachable[k] = v
              }
            }
            if pushdown_allowed {
              pushdown(
                where_.this(),
                reachable,
                scope_ref_count,
                dialect,
                Some(join_index),
              )
            }
          }
          None => ()
        }
        for join in joins {
          let name = join.alias_or_name()
          let side = @core.py_upper(join.text("side"))
          if side == "RIGHT" || side == "FULL" {
            continue
          }
          match scope.selected_sources().get(name) {
            Some(v) => {
              let sources : Map[String, (@core.Expr, Source)] = {}
              sources[name] = v
              pushdown(join.arg("on"), sources, scope_ref_count, dialect, None)
            }
            None => ()
          }
        }
      }
    }
    None => ()
  }
  expression
}

///|
fn pushdown(
  condition : @core.Expr?,
  sources : Map[String, (@core.Expr, Source)],
  scope_ref_count : Map[Int, Int],
  dialect : @core.Dialect,
  join_index : Map[String, Int]?,
) -> Unit raise @core.SqlglotError {
  let condition = match condition {
    Some(c) => c
    None => return
  }
  let condition = condition
    .replace(Some(simplify(condition, dialect~)))
    .unwrap()
  let cnf_like = normalized(condition) || !normalized(condition, dnf=true)
  let predicates = if condition.kind.is_a(if cnf_like { And } else { Or }) {
    condition.flatten().collect()
  } else {
    [condition]
  }
  if cnf_like {
    pushdown_cnf(predicates, sources, scope_ref_count, join_index)
  } else {
    pushdown_dnf(predicates, sources, scope_ref_count, join_index)
  }
}

///|
fn pushdown_cnf(
  predicates : Array[@core.Expr],
  sources : Map[String, (@core.Expr, Source)],
  scope_ref_count : Map[Int, Int],
  join_index : Map[String, Int]?,
) -> Unit raise @core.SqlglotError {
  // The predicates are the operands of one connector: their JOIN/WHERE ancestor is
  // found once for the whole chain (pushing a predicate replaces it by TRUE, which
  // doesn't move the others).
  let clauses = AncestorCache::new([Join, Where])
  for predicate in predicates {
    for
      _, node in nodes_for_predicate(
        predicate,
        sources,
        scope_ref_count,
        clauses~,
      ) {
      if node.kind.is_a(Join) {
        let name = node.alias_or_name()
        let predicate_tables = @core.column_table_names(predicate, exclude=name)
        match join_index {
          Some(ji) if !ji.is_empty() => {
            let this_index = match ji.get(name) {
              Some(i) => i
              None => raise @core.OptimizeError("KeyError: \{name}")
            }
            if predicate_tables.iter().all(t => ji.get(t).unwrap_or(-1) < this_index) {
              predicate.replace(Some(@core.true_())) |> ignore
              join_on(node, predicate)
              break
            }
          }
          _ => ()
        }
      }
      if node.kind.is_a(Select) {
        predicate.replace(Some(@core.true_())) |> ignore
        let inner_predicate = replace_aliases(node, predicate)
        if find_in_scope(inner_predicate, [AggFunc]) is Some(_) {
          node.having_([inner_predicate], copy=false) |> ignore
        } else {
          node.where_([inner_predicate], copy=false) |> ignore
        }
      }
    }
  }
}

///|
fn pushdown_dnf(
  predicates : Array[@core.Expr],
  sources : Map[String, (@core.Expr, Source)],
  scope_ref_count : Map[Int, Int],
  join_index : Map[String, Int]?,
) -> Unit raise @core.SqlglotError {
  let pushdown_tables : Array[String] = []
  for a in predicates {
    let mut a_tables = @core.column_table_names(a)
    for b in predicates {
      let bt = @core.column_table_names(b)
      a_tables = a_tables.filter(t => bt.contains(t))
    }
    for t in a_tables {
      if !pushdown_tables.contains(t) {
        pushdown_tables.push(t)
      }
    }
  }
  let conditions : Map[String, @core.Expr] = {}
  for table in sorted_strings(pushdown_tables) {
    let mut nodes : Map[String, @core.Expr] = {}
    for predicate in predicates {
      nodes = nodes_for_predicate(predicate, sources, scope_ref_count)
      if !nodes.contains(table) {
        continue
      }
      conditions[table] = match conditions.get(table) {
        Some(c) => @core.or_([c, predicate])
        None => predicate
      }
    }
    for name, node in nodes {
      let predicate = match conditions.get(name) {
        Some(p) => p
        None => continue
      }
      if node.kind.is_a(Join) {
        match join_index {
          Some(ji) if !ji.is_empty() => {
            let this_index = match ji.get(name) {
              Some(i) => i
              None => raise @core.OptimizeError("KeyError: \{name}")
            }
            let predicate_tables = @core.column_table_names(predicate, exclude=name)
            if !predicate_tables.iter().all(t => ji.get(t).unwrap_or(-1) < this_index) {
              continue
            }
          }
          _ => ()
        }
        join_on(node, predicate)
      } else if node.kind.is_a(Select) {
        let inner_predicate = replace_aliases(node, predicate)
        if find_in_scope(inner_predicate, [AggFunc]) is Some(_) {
          node.having_([inner_predicate], copy=false) |> ignore
        } else {
          node.where_([inner_predicate], copy=false) |> ignore
        }
      }
    }
  }
}

///|
fn nodes_for_predicate(
  predicate : @core.Expr,
  sources : Map[String, (@core.Expr, Source)],
  scope_ref_count : Map[Int, Int],
  clauses? : AncestorCache,
) -> Map[String, @core.Expr] raise @core.SqlglotError {
  let nodes : Map[String, @core.Expr] = {}
  let tables = @core.column_table_names(predicate)
  let clause = match clauses {
    Some(c) => c.find(predicate)
    None => predicate.find_ancestor([Join, Where])
  }
  let where_condition = match clause {
    Some(a) => a.kind.is_a(Where)
    None => false
  }
  for table in sorted_strings(tables) {
    let (node0, source) = match sources.get(table) {
      Some((n, s)) => (Some(n), Some(s))
      None => (None, None)
    }
    let mut node = node0
    if node is Some(n) && where_condition {
      node = n.find_ancestor([Join, From])
    }
    match (node, source) {
      (Some(n), Some(ScopeSource(s))) if n.kind.is_a(From) => {
        let parent = match s.parent {
          Some(p) => p
          None => raise @core.ValueError("Source node has no parent")
        }
        match parent.expression.arg("with_") {
          Some(w) if w.has("recursive") => return {}
          _ => ()
        }
        node = Some(s.expression)
      }
      _ => ()
    }
    match node {
      Some(n) if n.kind.is_a(Join) => {
        let side = @core.py_upper(n.text("side"))
        if side != "" {
          let pushable = match source {
            Some(ScopeSource(s)) if side == "RIGHT" => Some(s)
            _ => None
          }
          match pushable {
            None => return {}
            Some(s) => node = Some(s.expression)
          }
        } else {
          nodes[table] = n
        }
      }
      _ => ()
    }
    match node {
      Some(n) if n.kind.is_a(Select) && tables.length() == 1 => {
        let has_window_expression = n
          .selects()
          .iter()
          .any(s => find_in_scope(s, [Window]) is Some(_))
        let ref_count = match source {
          Some(s) => scope_ref_count.get(s.key()).unwrap_or(0)
          None => 0
        }
        if !n.has("group") &&
          ref_count < 2 &&
          !has_window_expression &&
          !n.has("limit") &&
          !n.has("offset") &&
          !n.has("qualify") {
          nodes[table] = n
        }
      }
      _ => ()
    }
  }
  nodes
}

///|
fn is_operator_expression(e : @core.Expr) -> Bool {
  e.kind.is_any([Binary, Unary, Predicate])
}

///|
fn replace_aliases(source : @core.Expr, predicate : @core.Expr) -> @core.Expr {
  let aliases : Map[String, @core.Expr] = {}
  for select in source.selects() {
    if select.kind.is_a(Alias) {
      aliases[select.alias()] = select.this_()
    } else {
      aliases[select.name()] = select
    }
  }
  predicate.transform(column => {
    if column.kind.is_a(Column) && aliases.contains(column.name()) {
      let mut replaced = aliases[column.name()].copy()
      if is_operator_expression(replaced) &&
        (match column.parent {
          Some(p) => is_operator_expression(p)
          None => false
        }) {
        replaced = @core.paren(replaced)
      }
      return Some(replaced)
    }
    Some(column)
  })
}
