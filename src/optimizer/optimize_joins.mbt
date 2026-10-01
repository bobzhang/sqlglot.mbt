// Port of sqlglot/optimizer/optimize_joins.py, eliminate_ctes.py and eliminate_joins.py.

///|
/// Python `helper.tsort`: topological sort of a DAG (name -> dependencies).
pub fn tsort(
  dag : Array[(String, Array[String])],
) -> Array[String] raise @core.SqlglotError {
  let nodes : Array[(String, Array[String])] = dag.map(kv => (kv.0, kv.1.copy()))
  let present = fn(n : String) { nodes.iter().any(kv => kv.0 == n) }
  for kv in nodes.copy() {
    for dep in kv.1 {
      if !present(dep) {
        nodes.push((dep, []))
      }
    }
  }
  let result = []
  while nodes.length() > 0 {
    let current = nodes.filter(kv => kv.1.is_empty()).map(kv => kv.0)
    if current.is_empty() {
      raise @core.ValueError("Cycle error")
    }
    let remaining = nodes.filter(kv => !current.contains(kv.0))
    nodes.clear()
    for kv in remaining {
      nodes.push((kv.0, kv.1.filter(d => !current.contains(d))))
    }
    for c in sorted_strings(dedup_strings(current)) {
      result.push(c)
    }
  }
  result
}

///|
fn other_table_names(join : @core.Expr) -> Array[String] {
  match join.arg("on") {
    Some(on) => @core.column_table_names(on, exclude=join.alias_or_name())
    None => []
  }
}

///|
fn is_reorderable(joins : Array[@core.Expr]) -> Bool {
  !joins.iter().any(j => j.text("side") != "")
}

///|
/// Removes cross joins if possible and reorder joins based on predicate dependencies.
pub fn optimize_joins(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  for select in expression.find_all([Select]).collect() {
    let joins = select.list("joins")
    if !is_reorderable(joins) {
      continue
    }
    let references : Map[String, Array[@core.Expr]] = {}
    let cross_joins : Array[(String, @core.Expr)] = []
    for join in joins {
      let tables = other_table_names(join)
      if !tables.is_empty() {
        for table in tables {
          if !references.contains(table) {
            references[table] = []
          }
          references[table].push(join)
        }
      } else {
        cross_joins.push((join.alias_or_name(), join))
      }
    }
    for cj in cross_joins {
      let (name, join) = cj
      for dep in references.get(name).unwrap_or([]) {
        if @core.py_upper(dep.text("kind")) == "ANTI" {
          continue
        }
        let on = dep.arg("on").unwrap()
        if on.kind.is_a(And) {
          if other_table_names(dep).length() < 2 {
            continue
          }
          let it = on.flatten()
          while it.next() is Some(predicate) {
            if @core.column_table_names(predicate).contains(name) {
              predicate.replace(Some(@core.true_())) |> ignore
              let combined = match join.arg("on") {
                Some(existing) =>
                  @core.combine_conditions(
                    [existing, predicate],
                    And,
                    copy=false,
                  )
                None => predicate
              }
              join.set("on", combined)
              if @core.py_upper(join.text("kind")) == "CROSS" {
                join.set("kind", @core.null_arg)
              }
            }
          }
        }
      }
    }
  }
  let expression = reorder_joins(expression)
  normalize_joins(expression)
}

///|
/// Reorder joins by topological sort order based on predicate references.
pub fn reorder_joins(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  for from_ in expression.find_all([From]).collect() {
    let parent = match from_.parent {
      Some(p) => p
      None => raise @core.OptimizeError("FROM clause without parent expression")
    }
    let joins = parent.list("joins")
    if !is_reorderable(joins) {
      continue
    }
    let joins_by_name : Map[String, @core.Expr] = {}
    for join in joins {
      joins_by_name[join.alias_or_name()] = join
    }
    let dag = []
    for name, join in joins_by_name {
      dag.push((name, other_table_names(join)))
    }
    let from_name = from_.alias_or_name()
    let ordered = tsort(dag)
      .filter(name => name != from_name && joins_by_name.contains(name))
      .map(name => joins_by_name[name])
    parent.set("joins", ordered)
  }
  expression
}

///|
/// Remove INNER and OUTER from joins as they are optional.
fn normalize_joins(expression : @core.Expr) -> @core.Expr {
  for join in expression.find_all([Join]).collect() {
    if !["on", "side", "kind", "using", "method"].iter().any(k => join.has(k)) {
      join.set("kind", "CROSS")
    }
    let kind = @core.py_upper(join.text("kind"))
    if kind == "CROSS" {
      join.set("on", @core.null_arg)
    } else {
      if kind == "INNER" || kind == "OUTER" {
        join.set("kind", @core.null_arg)
      }
      if !join.has("on") && !join.has("using") {
        join.set("on", @core.true_())
      }
    }
  }
  expression
}

///|
/// Remove unused CTEs from an expression.
pub fn eliminate_ctes(
  expression : @core.Expr,
  journal? : Journal,
) -> @core.Expr raise @core.SqlglotError {
  match build_scope(expression) {
    Some(root) => {
      let ref_count = root.ref_count()
      let scopes = root.traverse()
      scopes.rev_in_place()
      for scope in scopes {
        if scope.is_cte() {
          let count = ref_count.get(scope.key()).unwrap_or(0)
          if count <= 0 {
            let cte_node = match scope.expression.parent {
              Some(c) => c
              None => continue
            }
            let with_node = cte_node.parent
            match (journal, with_node) {
              (Some(j), Some(w)) => record(j, w, "expressions")
              _ => ()
            }
            cte_node.pop() |> ignore
            match with_node {
              Some(w) if w.expressions().is_empty() => {
                match (journal, w.parent) {
                  (Some(j), Some(p)) => record(j, p, "with_")
                  _ => ()
                }
                w.pop() |> ignore
              }
              _ => ()
            }
            for _, v in scope.selected_sources() {
              match v.1 {
                ScopeSource(s) =>
                  ref_count[s.key()] = ref_count.get(s.key()).unwrap_or(0) - 1
                _ => ()
              }
            }
          }
        }
      }
    }
    None => ()
  }
  expression
}

///|
/// Remove unused joins from an expression.
pub fn eliminate_joins(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  for scope in traverse_scope(expression) {
    let joins = scope.expression.list("joins")
    if joins.is_empty() {
      continue
    }
    if !scope.unqualified_columns().is_empty() {
      continue
    }
    let reversed = joins.copy()
    reversed.rev_in_place()
    for join in reversed {
      if is_semi_or_anti_join(join) {
        continue
      }
      let alias = join.alias_or_name()
      if should_eliminate_join(scope, join, alias) {
        join.pop() |> ignore
        scope.remove_source(alias)
      }
    }
  }
  expression
}

///|
fn should_eliminate_join(scope : Scope, join : @core.Expr, alias : String) -> Bool {
  match scope.sources.get(alias) {
    Some(ScopeSource(inner)) =>
      !join_is_used(scope, join, alias) &&
      ((@core.py_upper(join.text("side")) == "LEFT" &&
      is_joined_on_all_unique_outputs(inner, join)) ||
      (!join.has("on") && has_single_output_row(inner)))
    _ => false
  }
}

///|
fn join_is_used(scope : Scope, join : @core.Expr, alias : String) -> Bool {
  let on_ids : @set.Set[Int] = @set.new()
  match join.arg("on") {
    Some(on) => for c in on.find_all([Column]) { on_ids.add(c.uid) }
    None => ()
  }
  scope.source_columns(alias).iter().any(c => !on_ids.contains(c.uid))
}

///|
fn is_joined_on_all_unique_outputs(scope : Scope, join : @core.Expr) -> Bool {
  let unique_outputs = unique_outputs(scope)
  if unique_outputs.is_empty() {
    return false
  }
  let (_, join_keys, _) = join_condition(join)
  let names = join_keys.map(c => c.name())
  unique_outputs.iter().all(o => names.contains(o))
}

///|
fn unique_outputs(scope : Scope) -> Array[String] {
  let expr = scope.expression
  if expr.get("distinct") is Some(_) {
    return dedup_strings(expr.named_selects())
  }
  match expr.arg("group") {
    Some(group) => {
      let grouped_expressions = expr_set(group.expressions())
      let grouped_outputs = []
      let unique = []
      for select in expr.selects() {
        let output = select.unalias()
        if grouped_expressions.contains(output) {
          if !grouped_outputs.contains(output) {
            grouped_outputs.push(output)
          }
          if !unique.contains(select.alias_or_name()) {
            unique.push(select.alias_or_name())
          }
        }
      }
      if grouped_expressions.iter().all(g => grouped_outputs.contains(g)) {
        return unique
      }
      return []
    }
    None => ()
  }
  if has_single_output_row(scope) {
    return dedup_strings(expr.named_selects())
  }
  []
}

///|
fn has_single_output_row(scope : Scope) -> Bool {
  let e = scope.expression
  e.kind.is_a(Select) &&
  (e.selects().iter().all(s => s.unalias().kind.is_a(AggFunc)) ||
  is_limit_1(scope) ||
  !e.has("from_"))
}

///|
fn is_limit_1(scope : Scope) -> Bool {
  match scope.expression.arg("limit") {
    Some(limit) =>
      match limit.expression() {
        Some(e) => e.get("this") is Some(Str("1"))
        None => false
      }
    None => false
  }
}

///|
/// Extract the join condition: (source keys, join keys, remaining predicate).
pub fn join_condition(
  join : @core.Expr,
) -> (Array[@core.Expr], Array[@core.Expr], @core.Expr) {
  let name = join.alias_or_name()
  let mut on = match join.arg("on") {
    Some(o) => o.copy()
    None => @core.true_()
  }
  let source_key = []
  let join_key = []
  fn extract_condition(condition : @core.Expr) {
    let operands = condition.unnest_operands()
    let left = operands[0]
    let right = operands[1]
    let left_tables = @core.column_table_names(left)
    let right_tables = @core.column_table_names(right)
    if left_tables.contains(name) && !right_tables.contains(name) {
      join_key.push(left)
      source_key.push(right)
      condition.replace(Some(@core.true_())) |> ignore
    } else if right_tables.contains(name) && !left_tables.contains(name) {
      join_key.push(right)
      source_key.push(left)
      condition.replace(Some(@core.true_())) |> ignore
    }
  }

  if normalized(on) {
    if !on.kind.is_a(And) {
      on = @core.and_([on, @core.true_()], copy=false)
    }
    let it = on.flatten()
    while it.next() is Some(condition) {
      if condition.kind.is_a(EQ) {
        extract_condition(condition)
      }
    }
  } else if normalized(on, dnf=true) {
    let mut conditions : Array[@core.Expr] = []
    for condition in on.flatten().collect() {
      let parts = condition.flatten().filter(p => p.kind.is_a(EQ)).collect()
      if conditions.is_empty() {
        conditions = parts
      } else {
        let temp = []
        for p in parts {
          let cs = conditions.filter(c => p == c)
          if !cs.is_empty() {
            temp.push(p)
            for c in cs {
              temp.push(c)
            }
          }
        }
        conditions = temp
      }
    }
    for condition in conditions {
      extract_condition(condition)
    }
  }
  (source_key, join_key, on)
}
