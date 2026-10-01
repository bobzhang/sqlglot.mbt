// Port of sqlglot/optimizer/pushdown_projections.py and journal.py.

///|
/// One recorded argument mutation: (node, arg_key, value before the mutation).
pub type Journal = Array[(@core.Expr, String, @core.Value?)]

///|
/// Records the current value of `node.args[arg_key]` so `revert` can restore it.
pub fn record(journal : Journal, node : @core.Expr, arg_key : String) -> Unit {
  let value = match node.get(arg_key) {
    Some(List(l)) => Some(@core.Value::List(l.copy()))
    v => v
  }
  journal.push((node, arg_key, value))
}

///|
/// Restores every argument recorded from `start` onwards, newest first.
pub fn revert(journal : Journal, start? : Int = 0) -> Unit {
  let mut i = journal.length() - 1
  while i >= start {
    let (node, arg_key, value) = journal[i]
    node.set(arg_key, value)
    i -= 1
  }
  while journal.length() > start {
    journal.pop() |> ignore
  }
}

///|
/// Remove unused projections and CTEs while preserving all outermost outputs.
pub fn pushdown_projections(
  expression : @core.Expr,
  journal? : Journal,
) -> @core.Expr raise @core.SqlglotError {
  let reachability = projection_reachability(expression, whole_query=true)
  prune_projections(reachability, 0, journal?)
  expression
}

///|
/// Which root outputs reach each scope and output column through dependency edges.
pub struct ProjectionReachability {
  scopes : Array[Scope]
  /// scope id -> bitset of root outputs requiring the scope
  live : Map[Int, Int64]
  /// scope id -> per output column bitsets
  selections : Map[Int, Array[Int64]]
  is_agg : Map[Int, Bool]
  group_by_ordinals : Map[Int, Array[(@core.Expr, @core.Expr)]]
  set_names : Map[Int, Array[String]]
}

///|
priv struct DepNode {
  id : Int
  mut required_by : Int64
  dependencies : Array[DepNode]
}

///|
let dep_node_counter : Ref[Int] = Ref(0)

///|
fn DepNode::new() -> DepNode {
  dep_node_counter.val += 1
  { id: dep_node_counter.val, required_by: 0L, dependencies: [] }
}

///|
fn empty_reachability(scopes : Array[Scope]) -> ProjectionReachability {
  {
    scopes,
    live: {},
    selections: {},
    is_agg: {},
    group_by_ordinals: {},
    set_names: {},
  }
}

///|
/// Find which scopes and projections each outermost output reaches through dependencies.
pub fn projection_reachability(
  expression : @core.Expr,
  whole_query? : Bool = false,
) -> ProjectionReachability raise @core.SqlglotError {
  if !whole_query && !expression.kind.is_a(Query) {
    raise @core.OptimizeError("projection_reachability requires a query")
  }
  let scopes = traverse_scope(expression)
  if scopes.is_empty() {
    if whole_query {
      return empty_reachability([])
    }
    raise @core.OptimizeError("projection_reachability requires a query scope")
  }
  if whole_query && scopes.length() == 1 {
    let scope = scopes[0]
    let query = scope.expression
    if query.kind.is_a(Select) {
      if query.is_star() {
        raise @core.OptimizeError(
          "projection_reachability requires star-free selections",
        )
      }
      let windows = query.list("windows")
      let r = empty_reachability(scopes)
      r.live[scope.id] = 1L
      r.selections[scope.id] = query.selects().map(_ => 1L)
      r.is_agg[scope.id] = query
        .selects()
        .iter()
        .any(s => projection_has_aggregate(s, windows))
      r.group_by_ordinals[scope.id] = group_by_ordinal_refs(query)
      return r
    }
  }
  let scope_nodes : Map[Int, DepNode] = {}
  let output_names : Map[Int, Array[String]] = {}
  let output_nodes : Map[Int, Array[DepNode]] = {}
  let outputs_by_name : Map[Int, Map[String, Array[DepNode]]] = {}
  let owners : Map[Int, DepNode] = {}
  let scopes_by_expression : Map[Int, Scope] = {}
  let is_agg : Map[Int, Bool] = {}
  let group_by_ordinals : Map[Int, Array[(@core.Expr, @core.Expr)]] = {}
  for scope in scopes {
    let query = scope.expression
    if query.kind.is_a(Select) && query.is_star() {
      raise @core.OptimizeError(
        "projection_reachability requires star-free selections",
      )
    }
    scopes_by_expression[query.uid] = scope
    let scope_node = DepNode::new()
    scope_nodes[scope.id] = scope_node
    owners[query.uid] = scope_node
    if query.kind.is_a(SetOperation) {
      let left = scope.set_operation_scopes[0]
      let right = scope.set_operation_scopes[1]
      output_names[scope.id] = if query.has("by_name") {
        dedup_strings(output_names[left.id] + output_names[right.id])
      } else {
        output_names[left.id]
      }
    } else {
      output_names[scope.id] = if query.kind.is_a(Selectable) {
        query.selects().map(s => s.alias_or_name())
      } else {
        []
      }
    }
    let outputs = output_names[scope.id].map(_ => DepNode::new())
    output_nodes[scope.id] = outputs
    let by_name : Map[String, Array[DepNode]] = {}
    outputs_by_name[scope.id] = by_name
    for i, name in output_names[scope.id] {
      if !by_name.contains(name) {
        by_name[name] = []
      }
      by_name[name].push(outputs[i])
      outputs[i].dependencies.push(scope_node)
    }
    if query.kind.is_a(Select) {
      let selects = query.selects()
      for i in 0..<@core.min_int(selects.length(), outputs.length()) {
        owners[selects[i].uid] = outputs[i]
      }
    }
  }
  fn owner(node : @core.Expr) -> DepNode {
    let mut node = node
    while !owners.contains(node.uid) {
      node = node.parent.unwrap()
    }
    owners[node.uid]
  }

  fn by_name_get(scope_id : Int, name : String) -> Array[DepNode] {
    match outputs_by_name[scope_id].get(name) {
      Some(l) => l
      None => []
    }
  }

  for scope in scopes {
    let query = scope.expression
    let scope_node = scope_nodes[scope.id]
    let outputs = output_nodes[scope.id]
    let order = query.arg("order")
    let mut keep_all = query.has("distinct") ||
      query.kind.is_any([Intersect, Except]) ||
      is_self_referencing_cte(scope) ||
      !query.kind.is_any([Select, SetOperation])
    for child in scope.subquery_scopes {
      let anchor = child.expression.parent.unwrap()
      let o = owner(anchor)
      o.dependencies.push(scope_nodes[child.id])
      for n in output_nodes[child.id] {
        o.dependencies.push(n)
      }
    }
    if query.kind.is_a(Subquery) {
      for child in scope.derived_table_scopes {
        scope_node.dependencies.push(scope_nodes[child.id])
        for n in output_nodes[child.id] {
          scope_node.dependencies.push(n)
        }
      }
    }
    if query.kind.is_a(SetOperation) {
      let left = scope.set_operation_scopes[0]
      let right = scope.set_operation_scopes[1]
      scope_node.dependencies.push(scope_nodes[left.id])
      scope_node.dependencies.push(scope_nodes[right.id])
      let by_name = query.has("by_name")
      if query.text("kind") != "" ||
        query.text("side") != "" ||
        (by_name && !scope.outer_columns.is_empty()) {
        keep_all = true
      }
      if !by_name &&
        output_nodes[left.id].length() != output_nodes[right.id].length() {
        raise @core.OptimizeError(
          "Invalid set operation due to column mismatch: \{expr_sql(query)}.",
        )
      }
      for branch in [left, right] {
        for i, output_node in output_nodes[branch.id] {
          let targets = if by_name {
            by_name_get(scope.id, output_names[branch.id][i])
          } else {
            match outputs.get(i) {
              Some(o) => [o]
              None => []
            }
          }
          for output in targets {
            output.dependencies.push(output_node)
            output_node.dependencies.push(output)
          }
        }
      }
    }
    if keep_all {
      for o in outputs {
        scope_node.dependencies.push(o)
      }
    } else {
      match order {
        Some(o) => {
          let mut max_ordinal = 0
          for ordered in o.expressions() {
            match ordered.this() {
              Some(t) if t.kind.is_a(Literal) && t.is_int() =>
                match t.to_py_int() {
                  Some(v) => max_ordinal = @core.max_int(max_ordinal, v.to_int())
                  None => ()
                }
              _ => ()
            }
          }
          for i in 0..<@core.min_int(max_ordinal, outputs.length()) {
            scope_node.dependencies.push(outputs[i])
          }
        }
        None => ()
      }
    }
    for name in output_column_refs(query, !query.kind.is_a(Select)) {
      for n in by_name_get(scope.id, name) {
        scope_node.dependencies.push(n)
      }
    }
    for i in 0..<@core.min_int(scope.outer_columns.length(), outputs.length()) {
      scope_node.dependencies.push(outputs[i])
    }
    if query.kind.is_a(Select) {
      let windows = query.list("windows")
      let group_all = is_implicit_group_by_all(query)
      group_by_ordinals[scope.id] = group_by_ordinal_refs(query)
      let ordinals : @set.Set[Int] = @set.new()
      for r in group_by_ordinals[scope.id] {
        ordinals.add(r.1.uid)
      }
      let mut first_aggregate : DepNode? = None
      let non_aggregates = []
      let mut has_grouping_key = false
      let selects = query.selects()
      for i in 0..<@core.min_int(selects.length(), outputs.length()) {
        let selection = selects[i]
        let output_node = outputs[i]
        let (aggregate, has_column, has_srf) = projection_properties(
          selection, windows,
        )
        if aggregate {
          if first_aggregate is None {
            first_aggregate = Some(output_node)
          }
        } else {
          non_aggregates.push(output_node)
        }
        if group_all && !aggregate && has_column {
          has_grouping_key = true
        }
        if ordinals.contains(selection.uid) || (group_all && !aggregate) || has_srf {
          scope_node.dependencies.push(output_node)
        }
      }
      is_agg[scope.id] = first_aggregate is Some(_)
      match first_aggregate {
        Some(fa) if !query.has("group") || (group_all && !has_grouping_key) =>
          for n in non_aggregates {
            n.dependencies.push(fa)
          }
        _ => ()
      }
    }
    for r in scope.references() {
      let (name, reference) = r
      let source = match scope.sources.get(name) {
        Some(ScopeSource(s)) => s
        _ => continue
      }
      let source = scopes_by_expression[source.expression.uid]
      scope_node.dependencies.push(scope_nodes[source.id])
      let source_outputs = output_nodes[source.id]
      let first = if source.expression.kind.is_a(Selectable) {
        source.expression.selects().get(0)
      } else {
        None
      }
      if scope.semi_or_anti_join_tables().contains(name) ||
        scope.scans_all_subscope_columns() ||
        !scope.pivots().is_empty() ||
        (match first {
          Some(f) => f.kind.is_a(QueryTransform)
          None => false
        }) {
        for n in source_outputs {
          scope_node.dependencies.push(n)
        }
      }
      for i in 0..<@core.min_int(
          reference.alias_column_names().length(),
          source_outputs.length(),
        ) {
        scope_node.dependencies.push(source_outputs[i])
      }
    }
    for col in scope.columns() {
      let key = if col.table_name() != "" { col.table_name() } else { col.name() }
      match scope.sources.get(key) {
        Some(ScopeSource(s)) => {
          let source = scopes_by_expression[s.expression.uid]
          let o = owner(col)
          let deps = if col.table_name() != "" {
            by_name_get(source.id, col.name())
          } else {
            output_nodes[source.id]
          }
          for n in deps {
            o.dependencies.push(n)
          }
        }
        _ => ()
      }
    }
    for table_column in scope.table_columns() {
      match scope.sources.get(table_column.name()) {
        Some(ScopeSource(s)) => {
          let source = scopes_by_expression[s.expression.uid]
          let o = owner(table_column)
          for n in output_nodes[source.id] {
            o.dependencies.push(n)
          }
        }
        _ => ()
      }
    }
  }
  let roots = if expression.kind.is_a(Query) {
    [scopes[scopes.length() - 1]]
  } else {
    scopes.filter(s => match s.parent {
      Some(p) => !scope_nodes.contains(p.id)
      None => true
    })
  }
  let pending : @deque.Deque[DepNode] = @deque.new()
  let queued : @set.Set[Int] = @set.new()
  for root in roots {
    let root_outputs = output_nodes[root.id]
    let all_roots = if whole_query {
      1L
    } else {
      (1L << root_outputs.length()) - 1L
    }
    scope_nodes[root.id].required_by = all_roots
    for i, output_node in root_outputs {
      output_node.required_by = if whole_query { all_roots } else { 1L << i }
    }
    pending.push_back(scope_nodes[root.id])
    queued.add(scope_nodes[root.id].id)
    for o in root_outputs {
      pending.push_back(o)
      queued.add(o.id)
    }
  }
  while pending.pop_front() is Some(node) {
    queued.remove(node.id)
    for dependency in node.dependencies {
      let required_by = dependency.required_by | node.required_by
      if required_by != dependency.required_by {
        dependency.required_by = required_by
        if !queued.contains(dependency.id) {
          queued.add(dependency.id)
          pending.push_back(dependency)
        }
      }
    }
  }
  let r = empty_reachability(scopes)
  // `named_selects` of a set operation is that of its left operand: memoized by
  // expression so that a long left-deep chain isn't walked once per set operation
  let set_names_by_expr : Map[Int, Array[String]] = {}
  for scope in scopes {
    r.live[scope.id] = scope_nodes[scope.id].required_by
    r.selections[scope.id] = output_nodes[scope.id].map(o => o.required_by)
    let query = scope.expression
    if query.kind.is_a(SetOperation) {
      let names = match query.this().map(t => t.unnest()) {
        Some(left) if left.kind.is_a(SetOperation) =>
          match set_names_by_expr.get(left.uid) {
            Some(n) => n
            None => query.named_selects()
          }
        _ => query.named_selects()
      }
      set_names_by_expr[query.uid] = names
      r.set_names[scope.id] = names
    }
  }
  for k, v in is_agg {
    r.is_agg[k] = v
  }
  for k, v in group_by_ordinals {
    r.group_by_ordinals[k] = v
  }
  r
}

///|
/// Prune the analyzed tree to the scopes and projections reachable from output `root`.
pub fn prune_projections(
  reachability : ProjectionReachability,
  root : Int,
  journal? : Journal,
  remove_ctes? : Bool = true,
) -> Unit {
  let bit = 1L << root
  let scopes = reachability.scopes.copy()
  scopes.rev_in_place()
  for scope in scopes {
    if (reachability.live[scope.id] & bit) == 0L {
      if remove_ctes && scope.is_cte() {
        match scope.expression.parent {
          Some(cte_node) if cte_node.kind.is_a(CTE) => {
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
          }
          _ => ()
        }
      }
      continue
    }
    let expression = scope.expression
    if !expression.kind.is_a(Select) {
      continue
    }
    let selects = expression.selects()
    let sels = reachability.selections[scope.id]
    let mut subset = []
    for i in 0..<@core.min_int(selects.length(), sels.length()) {
      if (sels[i] & bit) != 0L {
        subset.push(selects[i])
      }
    }
    if subset.length() == selects.length() {
      continue
    }
    let ordinal_refs = reachability.group_by_ordinals.get(scope.id).unwrap_or([])
    if subset.is_empty() {
      let agg = reachability.is_agg.get(scope.id).unwrap_or(false)
      let placeholder = default_selection(agg)
      let mut ancestor = scope
      while ancestor.is_set_operation() && ancestor.parent is Some(p) {
        ancestor = p
        let names = reachability.set_names.get(ancestor.id).unwrap_or([])
        let asels = reachability.selections.get(ancestor.id).unwrap_or([])
        let mut retained_name : String? = None
        for i in 0..<@core.min_int(names.length(), asels.length()) {
          if (asels[i] & bit) != 0L {
            retained_name = Some(names[i])
            break
          }
        }
        match retained_name {
          Some(name) => {
            placeholder.set(
              "this",
              if agg {
                @core.mk1(Max, @core.null_())
              } else {
                @core.null_()
              },
            )
            placeholder.set("alias", @core.to_identifier(name, quoted=true))
            break
          }
          None => ()
        }
      }
      subset = [placeholder]
    }
    match journal {
      Some(j) => record(j, expression, "expressions")
      None => ()
    }
    expression.set("expressions", subset)
    if !ordinal_refs.is_empty() {
      let new_pos : Map[Int, Int] = {}
      for i, selection in subset {
        new_pos[selection.uid] = i + 1
      }
      for r in ordinal_refs {
        let (node, old_selection) = r
        match new_pos.get(old_selection.uid) {
          Some(pos) =>
            if node.to_py_int() != Some(pos.to_int64()) {
              match journal {
                Some(j) => record(j, node, "this")
                None => ()
              }
              node.set("this", pos.to_string())
            }
          None => ()
        }
      }
    }
  }
}

///|
/// Whether a projection aggregates rows, reads columns, or contains a set-returning function.
fn projection_properties(
  selection : @core.Expr,
  windows : Array[@core.Expr],
) -> (Bool, Bool, Bool) {
  let mut has_aggregate_or_window = false
  let mut has_column = false
  let mut has_srf = false
  for node in find_all_in_scope(selection, [
    AggFunc, Window, Column, Anonymous, UDTF, ExplodingGenerateSeries,
  ]) {
    if node.kind.is_any([AggFunc, Window]) {
      has_aggregate_or_window = true
    }
    if node.kind.is_a(Column) {
      has_column = true
    }
    if node.kind.is_any([Anonymous, UDTF, ExplodingGenerateSeries]) {
      has_srf = true
    }
  }
  let aggregate = has_aggregate_or_window &&
    projection_has_aggregate(selection, windows)
  (aggregate, has_column, has_srf)
}

///|
fn output_column_refs(expression : @core.Expr, scoped : Bool) -> Array[String] {
  let refs = []
  for arg in ["order", "sort", "distribute", "cluster"] {
    match expression.arg(arg) {
      Some(node) => {
        let columns = if scoped {
          find_all_in_scope(node, [Column]).collect()
        } else {
          node.find_all([Column]).collect()
        }
        for c in columns {
          if c.table_name() == "" && !refs.contains(c.name()) {
            refs.push(c.name())
          }
        }
      }
      None => ()
    }
  }
  refs
}

///|
fn is_self_referencing_cte(scope : Scope) -> Bool {
  match scope.expression.parent {
    Some(cte) if cte.kind.is_a(CTE) =>
      match cte.parent {
        Some(w) if w.kind.is_a(With) && w.has("recursive") =>
          scope.expression
          .find_all([Table])
          .any(table => table.db() == "" && table.name() == cte.alias())
        _ => false
      }
    _ => false
  }
}

///|
/// Selection to use if the selection list is empty.
pub fn default_selection(is_agg : Bool) -> @core.Expr {
  let e = if is_agg {
    @core.mk1(Max, @core.literal_int(1))
  } else {
    @core.literal_int(1)
  }
  @core.alias_(e, "_", copy=false)
}

///|
fn is_implicit_group_by_all(select : @core.Expr) -> Bool {
  match select.arg("group") {
    Some(group) if group.has("all") =>
      !(group.has("expressions") ||
      group.has("cube") ||
      group.has("rollup") ||
      group.has("grouping_sets"))
    _ => false
  }
}

///|
fn group_by_ordinal_refs(
  select : @core.Expr,
) -> Array[(@core.Expr, @core.Expr)] {
  let group = match select.arg("group") {
    Some(g) => g
    None => return []
  }
  let selects = select.selects()
  let n = selects.length()
  let refs = []
  fn collect(nodes : Array[@core.Expr]) -> Unit {
    for node in nodes {
      if node.kind.is_any([Cube, GroupingSets, Paren, Rollup, Tuple]) {
        collect(node.iter_expressions())
      } else if node.is_int() && node.kind.is_a(Literal) {
        match node.to_py_int() {
          Some(p) => {
            let pos = p.to_int()
            if 1 <= pos && pos <= n {
              refs.push((node, selects[pos - 1]))
            }
          }
          None => ()
        }
      }
    }
  }

  collect(group.iter_expressions())
  refs
}

///|
let window_has_aggregate_key : String = "window_has_aggregate"

///|
/// Port of `optimizer.helpers.projection_has_aggregate`.
pub fn projection_has_aggregate(
  projection : @core.Expr,
  windows : Array[@core.Expr],
) -> Bool {
  let windowed_aggregates : @set.Set[Int] = @set.new()
  let remaining_windows : Map[String, @core.Expr] = {}
  for w in windows {
    remaining_windows[w.name()] = w
  }
  for node in walk_in_scope(projection) {
    if node.kind.is_a(Window) {
      let mut target = node.this()
      while target is Some(t) && !t.kind.is_a(Func) {
        target = t.this()
      }
      match target {
        Some(t) if t.kind.is_a(AggFunc) => windowed_aggregates.add(t.uid)
        _ => ()
      }
      let mut name = node.alias()
      while name != "" {
        let window = match remaining_windows.get(name) {
          Some(w) => w
          None => break
        }
        remaining_windows.remove(name)
        let has_aggregate = match window.meta_get(window_has_aggregate_key) {
          Some(Bool(b)) => b
          _ => {
            let b = find_in_scope(window, [AggFunc]) is Some(_)
            window.get_meta()[window_has_aggregate_key] = Bool(b)
            b
          }
        }
        if has_aggregate {
          return true
        }
        name = window.alias()
      }
    } else if node.kind.is_a(AggFunc) && !windowed_aggregates.contains(node.uid) {
      return true
    }
  }
  false
}
