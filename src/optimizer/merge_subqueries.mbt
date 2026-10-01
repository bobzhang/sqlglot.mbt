// Port of sqlglot/optimizer/merge_subqueries.py.

///|
/// Caps the number of nodes copied by merges (relative to the statement size).
pub struct CopyBudget {
  expression : @core.Expr
  max_copy_factor : Int?
  min_copy_budget : Int
  mut remaining : Int?
}

///|
pub fn CopyBudget::new(
  expression : @core.Expr,
  max_copy_factor? : Int? = Some(8),
  min_copy_budget? : Int = 1000,
) -> CopyBudget {
  { expression, max_copy_factor, min_copy_budget, remaining: None }
}

///|
/// Charges the copies needed to merge `inner_scope` into `outer_scope`, if they fit.
pub fn CopyBudget::consume(
  self : CopyBudget,
  outer_scope : Scope,
  inner_scope : Scope,
  alias_ : String,
) -> Bool {
  let factor = match self.max_copy_factor {
    Some(f) => f
    None => return true
  }
  if self.remaining is None {
    let size = self.expression.walk().count()
    self.remaining = Some(@core.max_int(factor * size, self.min_copy_budget))
  }
  let remaining = self.remaining.unwrap()
  let references : Map[String, Int] = {}
  for c in outer_scope.columns() {
    if c.table_name() == alias_ {
      references[c.name()] = references.get_or_default(c.name(), 0) + 1
    }
  }
  let mut copies = 0
  for projection in inner_scope.expression.expressions() {
    let count = references.get_or_default(projection.alias_or_name(), 0) - 1
    if count > 0 {
      for _ in projection.unalias().walk() {
        copies += count
        if copies > remaining {
          return false
        }
      }
    }
  }
  self.remaining = Some(remaining - copies)
  true
}

///|
/// Rewrite the AST to merge derived tables into the outer query.
pub fn merge_subqueries(
  expression : @core.Expr,
  leave_tables_isolated? : Bool = false,
  max_copy_factor? : Int? = Some(8),
  min_copy_budget? : Int = 1000,
) -> @core.Expr raise @core.SqlglotError {
  let mut scopes = traverse_scope(expression)
  let copy_budget = CopyBudget::new(expression, max_copy_factor~, min_copy_budget~)
  let (expression, merged_ctes) = merge_ctes(
    expression,
    leave_tables_isolated~,
    scopes~,
    copy_budget~,
  )
  if merged_ctes {
    scopes = traverse_scope(expression)
  }
  merge_derived_tables(expression, leave_tables_isolated~, scopes~, copy_budget~)
}

///|
let unmergable_args : Array[String] = {
  let keep = ["expressions", "from_", "joins", "where", "order", "hint"]
  let out = []
  for kv in @core.Kind::Select.arg_types() {
    if !keep.contains(kv.0) {
      out.push(kv.0)
    }
  }
  out
}

///|
pub fn merge_ctes(
  expression : @core.Expr,
  leave_tables_isolated? : Bool = false,
  scopes? : Array[Scope],
  copy_budget? : CopyBudget,
) -> (@core.Expr, Bool) raise @core.SqlglotError {
  let copy_budget = match copy_budget {
    Some(c) => c
    None => CopyBudget::new(expression)
  }
  let scopes = match scopes {
    Some(s) => s
    None => traverse_scope(expression)
  }
  let cte_selections : Map[Int, Array[(Scope, Scope, @core.Expr)]] = {}
  for outer_scope in scopes {
    for _, v in outer_scope.selected_sources() {
      let (table, source) = v
      match source {
        ScopeSource(inner_scope) if inner_scope.is_cte() => {
          if !cte_selections.contains(inner_scope.id) {
            cte_selections[inner_scope.id] = []
          }
          cte_selections[inner_scope.id].push((outer_scope, inner_scope, table))
        }
        _ => ()
      }
    }
  }
  let mut merged = false
  let singular = []
  for _, v in cte_selections {
    if v.length() == 1 {
      singular.push(v[0])
    }
  }
  for sel in singular {
    let (outer_scope, inner_scope, table) = sel
    let from_or_join = match table.find_ancestor([From, Join]) {
      Some(f) if f.kind.is_any([From, Join]) => f
      _ => continue
    }
    let alias_ = table.alias_or_name()
    if mergeable(outer_scope, inner_scope, leave_tables_isolated, from_or_join) &&
      copy_budget.consume(outer_scope, inner_scope, alias_) {
      rename_inner_sources(outer_scope, inner_scope, alias_)
      merge_from(outer_scope, inner_scope, table, alias_)
      merge_expressions(outer_scope, inner_scope, alias_)
      merge_order(outer_scope, inner_scope)
      merge_joins(outer_scope, inner_scope, from_or_join)
      merge_where(outer_scope, inner_scope, from_or_join)
      merge_hints(outer_scope, inner_scope)
      pop_cte(inner_scope)
      outer_scope.clear_cache()
      merged = true
    }
  }
  (expression, merged)
}

///|
pub fn merge_derived_tables(
  expression : @core.Expr,
  leave_tables_isolated? : Bool = false,
  scopes? : Array[Scope],
  copy_budget? : CopyBudget,
) -> @core.Expr raise @core.SqlglotError {
  let copy_budget = match copy_budget {
    Some(c) => c
    None => CopyBudget::new(expression)
  }
  let scopes = match scopes {
    Some(s) => s
    None => traverse_scope(expression)
  }
  for outer_scope in scopes {
    for subquery in outer_scope.derived_tables() {
      let from_or_join = match subquery.find_ancestor([From, Join]) {
        Some(f) if f.kind.is_any([From, Join]) => f
        _ => continue
      }
      let alias_ = subquery.alias_or_name()
      let inner_scope = match outer_scope.sources.get(alias_) {
        Some(ScopeSource(s)) => s
        Some(_) => continue
        None => raise @core.OptimizeError("KeyError: \{alias_}")
      }
      if mergeable(outer_scope, inner_scope, leave_tables_isolated, from_or_join) &&
        copy_budget.consume(outer_scope, inner_scope, alias_) {
        rename_inner_sources(outer_scope, inner_scope, alias_)
        merge_from(outer_scope, inner_scope, subquery, alias_)
        merge_expressions(outer_scope, inner_scope, alias_)
        merge_order(outer_scope, inner_scope)
        merge_joins(outer_scope, inner_scope, from_or_join)
        merge_where(outer_scope, inner_scope, from_or_join)
        merge_hints(outer_scope, inner_scope)
        outer_scope.clear_cache()
      }
    }
  }
  expression
}

///|
fn side_in(join : @core.Expr, sides : Array[String]) -> Bool {
  sides.contains(@core.py_upper(join.text("side")))
}

///|
fn mergeable(
  outer_scope : Scope,
  inner_scope : Scope,
  leave_tables_isolated : Bool,
  from_or_join : @core.Expr,
) -> Bool raise @core.SqlglotError {
  let inner_select = inner_scope.expression.unnest()
  let outer = outer_scope.expression
  let inner_name = from_or_join.alias_or_name()
  let is_join = from_or_join.kind.is_a(Join)
  if !outer.kind.is_a(Select) ||
    outer.is_star() ||
    !inner_select.kind.is_a(Select) ||
    unmergable_args.iter().any(k => inner_select.has(k)) ||
    inner_select.get("from_") is None ||
    !outer_scope.pivots().is_empty() ||
    (leave_tables_isolated && outer_scope.selected_sources().length() > 1) ||
    (is_join && inner_select.has("joins")) ||
    (is_join &&
    inner_select.has("where") &&
    side_in(from_or_join, ["FULL", "LEFT", "RIGHT"])) ||
    (from_or_join.kind.is_a(From) &&
    inner_select.has("where") &&
    outer.list("joins").iter().any(j => side_in(j, ["FULL", "RIGHT"]))) ||
    (inner_select.has("order") && outer_scope.is_set_operation()) ||
    (match inner_select.expressions().get(0) {
      Some(e) => e.kind.is_a(QueryTransform)
      None => false
    }) {
    return false
  }
  let window_aliases = []
  let number_literal_aliases = []
  let projections : Map[String, @core.Expr] = {}
  for s in inner_select.selects() {
    let name = s.alias_or_name()
    projections[name] = s
    if s.unalias().is_number() && !number_literal_aliases.contains(name) {
      number_literal_aliases.push(name)
    }
    for node in s.walk() {
      if node.kind.is_any([
          AggFunc, Select, Anonymous, UDTF, ExplodingGenerateSeries,
        ]) {
        return false
      }
      if node.kind.is_a(Window) && !window_aliases.contains(name) {
        window_aliases.push(name)
      }
    }
  }
  // _outer_select_joins_on_inner_select_join
  let joins_on_inner_join = if !is_join {
    false
  } else {
    match from_or_join.arg("on") {
      None => false
      Some(on) => {
        let selections = on
          .find_all([Column])
          .filter(c => c.table_name() == inner_name)
          .map(c => c.name())
          .collect()
        match inner_scope.expression.arg("from_") {
          None => false
          Some(inner_from) => {
            let inner_from_table = inner_from.alias_or_name()
            let mut found = false
            for selection in selections {
              let p = match projections.get(selection) {
                Some(p) => p
                None => raise @core.OptimizeError("KeyError: \{selection}")
              }
              if p.find_all([Column]).any(col => col.table_name() != inner_from_table) {
                found = true
                break
              }
            }
            found
          }
        }
      }
    }
  }
  // _window_projection_blocks_merge
  let window_blocks = if window_aliases.is_empty() {
    false
  } else if outer.has("where") || outer.has("joins") {
    true
  } else {
    outer_scope
    .columns()
    .iter()
    .any(column => column.table_name() == inner_name &&
      window_aliases.contains(column.name()) &&
      column.find_ancestor([Group, Order, Having, AggFunc]) is Some(_))
  }
  // _literal_group_unmergeable
  let literal_group = match outer.arg("group") {
    None => false
    Some(_) if number_literal_aliases.is_empty() => false
    Some(group) => {
      let grouped = []
      let top_level_ids : @set.Set[Int] = @set.new()
      for e in group.expressions() {
        top_level_ids.add(e.unnest().uid)
      }
      let mut blocked = false
      for col in group.find_all([Column]).collect() {
        if col.table_name() != inner_name ||
          !number_literal_aliases.contains(col.name()) {
          continue
        }
        if !top_level_ids.contains(col.uid) {
          blocked = true
          break
        }
        grouped.push(col.name())
      }
      if blocked {
        true
      } else if grouped.is_empty() {
        false
      } else {
        let projected = []
        for s in outer.selects() {
          let unaliased = s.unalias()
          if unaliased.kind.is_a(Column) && unaliased.table_name() == inner_name {
            projected.push(unaliased.name())
          }
        }
        !grouped.iter().all(g => projected.contains(g))
      }
    }
  }
  // _literal_in_order_by
  let literal_order = match outer.arg("order") {
    None => false
    Some(order) =>
      order
      .expressions()
      .iter()
      .any(o => {
        let key = o.this_().unnest()
        key.kind.is_a(Column) &&
        key.table_name() == inner_name &&
        number_literal_aliases.contains(key.name())
      })
  }
  // _is_recursive
  let is_recursive = if inner_scope.is_cte() {
    let cte = inner_scope.expression.parent
    let mut node = outer.parent
    let mut found = false
    while node is Some(n) {
      match cte {
        Some(c) if physical_equal(n, c) => {
          found = true
          break
        }
        _ => ()
      }
      node = n.parent
    }
    found
  } else {
    false
  }
  !joins_on_inner_join &&
  !window_blocks &&
  !literal_group &&
  !literal_order &&
  !is_recursive
}

///|
/// Renames any sources in the inner query that conflict with names in the outer query.
fn rename_inner_sources(
  outer_scope : Scope,
  inner_scope : Scope,
  alias_ : String,
) -> Unit raise @core.SqlglotError {
  let inner_taken = inner_scope.selected_sources().keys().collect()
  let outer_taken = outer_scope.selected_sources().keys().collect()
  let conflicts = outer_taken.filter(n => inner_taken.contains(n) && n != alias_)
  let taken = dedup_strings(outer_taken + inner_taken)
  for conflict in conflicts {
    let new_name = @core.find_new_name(n => taken.contains(n), conflict)
    let (source, _) = inner_scope.selected_sources()[conflict]
    let new_alias = @core.to_identifier(new_name)
    if source.kind.is_a(Table) && source.alias_() != "" {
      source.set("alias", @core.mk1(TableAlias, new_alias))
    } else if source.kind.is_a(Table) {
      source.replace(Some(@core.alias_expr(source, Some(new_alias)))) |> ignore
    } else if parent_is(source, [Subquery]) {
      source.parent.unwrap().set("alias", @core.mk1(TableAlias, new_alias))
    }
    for column in inner_scope.source_columns(conflict) {
      column.set("table", @core.to_identifier(new_name))
    }
    inner_scope.rename_source(Some(conflict), new_name)
  }
}

///|
fn merge_from(
  outer_scope : Scope,
  inner_scope : Scope,
  node_to_replace : @core.Expr,
  alias_ : String,
) -> Unit raise @core.SqlglotError {
  let new_subquery = inner_scope.expression.arg("from_").unwrap().this_()
  new_subquery.set("joins", node_to_replace.get("joins"))
  node_to_replace.replace(Some(new_subquery)) |> ignore
  for join_hint in outer_scope.join_hints() {
    for table in join_hint.find_all([Table]).collect() {
      if table.alias_or_name() == node_to_replace.alias_or_name() {
        table.set("this", @core.to_identifier(new_subquery.alias_or_name()))
      }
    }
  }
  outer_scope.remove_source(alias_)
  match inner_scope.sources.get(new_subquery.alias_or_name()) {
    Some(s) => outer_scope.add_source(new_subquery.alias_or_name(), s)
    None =>
      raise @core.OptimizeError("KeyError: \{new_subquery.alias_or_name()}")
  }
}

///|
fn merge_joins(
  outer_scope : Scope,
  inner_scope : Scope,
  from_or_join : @core.Expr,
) -> Unit raise @core.SqlglotError {
  let new_joins = []
  for join in inner_scope.expression.list("joins") {
    new_joins.push(join)
    match inner_scope.sources.get(join.alias_or_name()) {
      Some(s) => outer_scope.add_source(join.alias_or_name(), s)
      None => raise @core.OptimizeError("KeyError: \{join.alias_or_name()}")
    }
  }
  if !new_joins.is_empty() {
    let outer_joins = outer_scope.expression.list("joins")
    let position = if from_or_join.kind.is_a(From) {
      0
    } else {
      let mut idx = -1
      for i, j in outer_joins {
        if j == from_or_join {
          idx = i
          break
        }
      }
      if idx < 0 {
        raise @core.ValueError("join is not in list")
      }
      idx + 1
    }
    for i, j in new_joins {
      outer_joins.insert(position + i, j)
    }
    outer_scope.expression.set("joins", outer_joins)
  }
}

///|
fn merge_expressions(
  outer_scope : Scope,
  inner_scope : Scope,
  alias_ : String,
) -> Unit {
  let outer_columns : Map[String, Array[@core.Expr]] = {}
  for column in outer_scope.columns() {
    if column.table_name() == alias_ {
      if !outer_columns.contains(column.name()) {
        outer_columns[column.name()] = []
      }
      outer_columns[column.name()].push(column)
    }
  }
  let group = outer_scope.expression.arg("group")
  for expression in inner_scope.expression.expressions() {
    let projection_name = expression.alias_or_name()
    if projection_name == "" {
      continue
    }
    let columns_to_replace = outer_columns.get(projection_name).unwrap_or([])
    if columns_to_replace.is_empty() {
      continue
    }
    let expression = expression.unalias()
    let must_wrap_expression = !expression.kind.is_any([
      Column, EQ, Func, NEQ, Paren,
    ])
    let is_number = expression.is_number()
    let last = columns_to_replace.length() - 1
    let mut group_ordinal = 0
    if is_number && outer_scope.expression.kind.is_a(Select) {
      for j, s in outer_scope.expression.selects() {
        let unaliased = s.unalias()
        if unaliased.kind.is_a(Column) &&
          unaliased.table_name() == alias_ &&
          unaliased.name() == projection_name {
          group_ordinal = j + 1
          break
        }
      }
    }
    for i, column in columns_to_replace {
      let parent = column.parent
      if is_number {
        match group {
          Some(g) => {
            let mut item : @core.Expr? = None
            for e in g.expressions() {
              if physical_equal(e.unnest(), column) {
                item = Some(e)
                break
              }
            }
            match item {
              Some(it) => {
                it.replace(Some(lit_num(group_ordinal))) |> ignore
                continue
              }
              None => ()
            }
          }
          None => ()
        }
      }
      let mut replacement = if i < last { expression.copy() } else { expression }
      if (match parent {
          Some(p) => p.kind.is_any([Unary, Binary])
          None => false
        }) &&
        must_wrap_expression {
        replacement = @core.paren(replacement, copy=false)
      }
      if (match parent {
          Some(p) => p.kind.is_a(Select)
          None => false
        }) &&
        column.name() != expression.name() {
        replacement = @core.alias_(replacement, column.name(), copy=false)
      }
      column.replace(Some(replacement)) |> ignore
    }
  }
}

///|
fn merge_where(
  outer_scope : Scope,
  inner_scope : Scope,
  from_or_join : @core.Expr,
) -> Unit raise @core.SqlglotError {
  let where_ = match inner_scope.expression.arg("where") {
    Some(w) => w
    None => return
  }
  let cond = match where_.this() {
    Some(c) => c
    None => return
  }
  let expression = outer_scope.expression
  if from_or_join.kind.is_a(Join) {
    let sources = []
    match expression.arg("from_") {
      Some(f) => sources.push(f.alias_or_name())
      None => ()
    }
    for join in expression.list("joins") {
      let source = join.alias_or_name()
      sources.push(source)
      if source == from_or_join.alias_or_name() {
        break
      }
    }
    if @core.column_table_names(cond).iter().all(t => sources.contains(t)) {
      join_on(from_or_join, cond)
      from_or_join.set("on", from_or_join.get("on"))
      return
    }
  }
  expression.where_([cond], copy=false) |> ignore
}

///|
fn merge_order(outer_scope : Scope, inner_scope : Scope) -> Unit {
  let inner_order = match inner_scope.expression.arg("order") {
    Some(o) => o
    None => return
  }
  let outer = outer_scope.expression
  if ["group", "distinct", "having", "order"].iter().any(a => outer.has(a)) ||
    outer_scope.selected_sources_or_empty().length() != 1 ||
    outer.expressions().iter().any(e => e.find([AggFunc]) is Some(_)) {
    return
  }
  outer.set("order", inner_order)
}

///|
fn merge_hints(outer_scope : Scope, inner_scope : Scope) -> Unit {
  let inner_hint = match inner_scope.expression.arg("hint") {
    Some(h) => h
    None => return
  }
  match outer_scope.expression.arg("hint") {
    Some(outer_hint) =>
      for h in inner_hint.expressions() {
        outer_hint.append("expressions", h)
      }
    None => outer_scope.expression.set("hint", inner_hint)
  }
}

///|
fn pop_cte(inner_scope : Scope) -> Unit {
  let cte = match inner_scope.expression.parent {
    Some(c) => c
    None => return
  }
  let with_ = match cte.parent {
    Some(w) => w
    None => return
  }
  if with_.expressions().length() == 1 {
    with_.pop() |> ignore
  } else {
    cte.pop() |> ignore
  }
}
