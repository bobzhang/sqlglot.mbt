// Port of sqlglot/optimizer/qualify_columns.py.

///|
/// Rewrite the AST to have fully qualified columns.
pub fn qualify_columns(
  expression : @core.Expr,
  schema : MappingSchema,
  expand_alias_refs? : Bool = true,
  expand_stars? : Bool = true,
  infer_schema? : Bool,
  allow_partial_qualification? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  let annotator = TypeAnnotator::new(schema)
  let infer_schema = match infer_schema {
    Some(b) => b
    None => schema.empty()
  }
  let dialect = schema.dialect
  let pseudocolumns = dialect.cfg.pseudocolumns
  let ancestry : Map[Int, (Scope?, Bool?)] = {}
  for scope in traverse_scope(expression) {
    if dialect.cfg.prefer_cte_alias_column {
      pushdown_cte_alias_columns(scope)
    }
    let scope_expression = scope.expression
    let is_select = scope_expression.kind.is_a(Select)
    separate_pseudocolumns(scope, pseudocolumns)
    let resolver = Resolver::new(scope, schema, infer_schema~)
    pop_table_column_aliases(scope.ctes())
    pop_table_column_aliases(scope.derived_tables())
    let using_column_tables = expand_using(scope, resolver)
    if (schema.empty() || dialect.cfg.force_early_alias_ref_expansion) &&
      expand_alias_refs {
      expand_alias_refs_impl(
        scope,
        resolver,
        dialect,
        ancestry,
        expand_only_groupby=dialect.cfg.expand_only_group_alias_ref,
      )
    }
    convert_columns_to_dots(scope, resolver)
    qualify_columns_impl(scope, resolver, allow_partial_qualification)
    scope.clear_column_cache()
    if !schema.empty() && expand_alias_refs {
      expand_alias_refs_impl(scope, resolver, dialect, ancestry)
    }
    if is_select {
      if expand_stars {
        expand_stars_impl(
          scope, resolver, using_column_tables, pseudocolumns, annotator,
        )
      }
      qualify_outputs_scope(scope, dialect)
    }
    expand_group_by(scope, dialect)
    expand_order_by_and_distinct_on(scope, resolver)
    if dialect.cfg.annotate_all_scopes {
      annotator.annotate_scope(scope)
    }
  }
  expression
}

///|
fn meta_int(e : @core.Expr, key : String) -> Int? {
  match e.meta_get(key) {
    Some(Int(i)) => Some(i.to_int())
    _ => None
  }
}

///|
/// Raise an `OptimizeError` if any columns aren't qualified.
pub fn validate_qualify_columns(
  expression : @core.Expr,
  sql? : String,
) -> @core.Expr raise @core.SqlglotError {
  let all_unqualified_columns = []
  for scope in traverse_scope(expression) {
    if scope.expression.kind.is_a(Select) {
      let unqualified_columns = scope.unqualified_columns()
      if !scope.external_columns().is_empty() &&
        !scope.is_correlated_subquery() &&
        scope.pivots().is_empty() {
        let column = scope.external_columns()[0]
        let for_table = if column.table_name() != "" {
          " for table: '\{column.table_name()}'"
        } else {
          ""
        }
        let mut error_msg = "Column '\{column.name()}' could not be resolved\{for_table}."
        let this = column.this_()
        match (meta_int(this, "line"), meta_int(this, "col")) {
          (Some(line), Some(col)) if line != 0 && col != 0 =>
            error_msg += " Line: \{line}, Col: \{col}"
          _ => ()
        }
        match (sql, meta_int(this, "start"), meta_int(this, "end")) {
          (Some(s), Some(start), Some(end)) => {
            let formatted = @core.highlight_sql(s, [(start, end)]).0
            error_msg += "\n  \{formatted}"
          }
          _ => ()
        }
        raise @core.OptimizeError(error_msg)
      }
      all_unqualified_columns.append(unqualified_columns)
    }
  }
  if !all_unqualified_columns.is_empty() {
    let first_column = all_unqualified_columns[0]
    let this = first_column.this_()
    let mut error_msg = "Ambiguous column '\{first_column.name()}'"
    match (meta_int(this, "line"), meta_int(this, "col")) {
      (Some(line), Some(col)) if line != 0 && col != 0 =>
        error_msg += " (Line: \{line}, Col: \{col})"
      _ => ()
    }
    match (sql, meta_int(this, "start"), meta_int(this, "end")) {
      (Some(s), Some(start), Some(end)) => {
        let formatted = @core.highlight_sql(s, [(start, end)]).0
        error_msg += "\n  \{formatted}"
      }
      _ => ()
    }
    raise @core.OptimizeError(error_msg)
  }
  expression
}

///|
fn separate_pseudocolumns(scope : Scope, pseudocolumns : @set.Set[String]) -> Unit {
  if pseudocolumns.is_empty() {
    return
  }
  let mut has_pseudocolumns = false
  let scope_expression = scope.expression
  for column in scope.columns() {
    let name = @core.py_upper(column.name())
    if !pseudocolumns.contains(name) {
      continue
    }
    if name != "LEVEL" ||
      (scope_expression.kind.is_a(Select) && scope_expression.has("connect")) {
      column.replace(Some(@core.Expr::new(Pseudocolumn, column.args.copy()))) |> ignore
      has_pseudocolumns = true
    }
  }
  if has_pseudocolumns {
    scope.clear_cache()
  }
}

///|
/// Remove table column aliases.
fn pop_table_column_aliases(derived_tables : Array[@core.Expr]) -> Unit {
  for derived_table in derived_tables {
    match derived_table.parent {
      Some(p) if p.kind.is_a(With) && p.has("recursive") => continue
      _ => ()
    }
    match derived_table.arg("alias") {
      Some(table_alias) => table_alias.set("columns", @core.null_arg)
      None => ()
    }
  }
}

///|
/// An ordered set of source names per automatically joined column.
priv struct ColumnTables {
  map : Map[String, Array[String]]
}

///|
fn ColumnTables::has(self : ColumnTables, column : String, table : String) -> Bool {
  match self.map.get(column) {
    Some(ts) => ts.contains(table)
    None => false
  }
}

///|
fn expand_using(
  scope : Scope,
  resolver : Resolver,
) -> ColumnTables raise @core.SqlglotError {
  let columns : Map[String, String] = {}
  fn update_source_columns(source_name : String) raise @core.SqlglotError {
    for column_name in resolver.get_source_columns(source_name) {
      if !columns.contains(column_name) {
        columns[column_name] = source_name
      }
    }
  }

  let joins = scope.find_all([Join]).collect()
  let column_tables : ColumnTables = { map: {} }
  if joins.is_empty() {
    return column_tables
  }
  let names : @set.Set[String] = @set.new()
  for join in joins {
    names.add(join.alias_or_name())
  }
  let ordered = []
  for key, _ in scope.selected_sources() {
    if !names.contains(key) {
      ordered.push(key)
    }
  }
  if !names.is_empty() && ordered.is_empty() {
    // Python formats the set: {'a', 'b'} (its order is the string hash order there;
    // insertion order here)
    let names_repr = "{" + names.iter().map(@core.py_repr_str).join(", ") + "}"
    raise @core.OptimizeError(
      "Joins \{names_repr} missing source table \{expr_sql(scope.expression)}",
    )
  }
  if !joins.iter().any(j => j.has("using") || join_method(j) == "NATURAL") {
    return column_tables
  }
  for source_name in ordered {
    update_source_columns(source_name)
  }
  for i, join in joins {
    let source_table = ordered[ordered.length() - 1]
    if source_table != "" {
      update_source_columns(source_table)
    }
    let join_table = join.alias_or_name()
    ordered.push(join_table)
    let join_columns = resolver.get_source_columns(join_table)
    let mut using_ : Array[@core.Expr]? = match join.get("using") {
      Some(List(_)) => Some(join.list("using"))
      _ => None
    }
    if using_ is None && join_method(join) == "NATURAL" {
      if !columns.is_empty() &&
        !columns.contains("*") &&
        !join_columns.is_empty() &&
        !join_columns.contains("*") {
        let u = []
        for column_name, _ in columns {
          if join_columns.contains(column_name) {
            u.push(@core.to_identifier(column_name))
          }
        }
        using_ = Some(u)
        if !u.is_empty() {
          join.set("method", @core.null_arg)
        }
      }
    }
    let using_ = match using_ {
      Some(u) if !u.is_empty() => u
      _ => continue
    }
    let conditions = []
    let using_identifier_count = using_.length()
    let is_semi_or_anti = is_semi_or_anti_join(join)
    for identifier in using_ {
      let identifier = identifier.name()
      let mut table = columns.get(identifier)
      let missing = match table {
        Some(t) => t == ""
        None => true
      }
      if missing || !join_columns.contains(identifier) {
        if !columns.is_empty() &&
          !columns.contains("*") &&
          !join_columns.is_empty() {
          raise @core.OptimizeError("Cannot automatically join: \{identifier}")
        }
      }
      let table = match table {
        Some(t) if t != "" => t
        _ => source_table
      }
      let lhs = if i == 0 || using_identifier_count == 1 {
        column_with_table(identifier, table~)
      } else {
        let coalesce_columns = []
        for t in ordered[0:ordered.length() - 1] {
          if resolver.get_source_columns(t).contains(identifier) {
            coalesce_columns.push(column_with_table(identifier, table=t))
          }
        }
        if coalesce_columns.length() > 1 {
          @core.func_("coalesce", coalesce_columns)
        } else {
          column_with_table(identifier, table~)
        }
      }
      conditions.push(
        @core.mk2(EQ, lhs, column_with_table(identifier, table=join_table)),
      )
      if !column_tables.map.contains(identifier) {
        column_tables.map[identifier] = []
      }
      let tables = column_tables.map[identifier]
      if !is_semi_or_anti {
        if !tables.contains(table) {
          tables.push(table)
        }
        if !tables.contains(join_table) {
          tables.push(join_table)
        }
      }
    }
    join.set("using", @core.null_arg)
    join.set("on", @core.and_(conditions, copy=false))
  }
  if !column_tables.map.is_empty() {
    for column in scope.columns() {
      if column.table_name() == "" && column_tables.map.contains(column.name()) {
        let tables = column_tables.map[column.name()]
        let coalesce_args = tables.map(t => column_with_table(column.name(), table=t))
        let mut replacement = @core.func_("coalesce", coalesce_args)
        if parent_is(column, [Select]) {
          replacement = @core.alias_(replacement, column.name(), copy=false)
        } else if parent_is(column, [Struct]) {
          replacement = @core.mk2(
            PropertyEQ,
            @core.to_identifier(column.name()),
            replacement,
          )
        }
        scope.replace(column, replacement)
      }
    }
  }
  column_tables
}

///|
fn join_method(join : @core.Expr) -> String {
  @core.py_upper(join.text("method"))
}

///|
/// Walks up from `scope` through non-CTE scopes (`while parent_scope and not
/// parent_scope.is_cte`): returns the scope the walk stops at and whether the last UNION
/// crossed was entered from its right side. Walks are memoized in `memo` (keyed by scope
/// expression) so that the scopes of a long set operation chain don't each walk the whole
/// chain.
fn scope_ancestry(
  scope : Scope,
  memo : Map[Int, (Scope?, Bool?)],
) -> (Scope?, Bool) {
  if scope.is_cte() {
    return (Some(scope), false)
  }
  // memo[ps]: where the walk from the non-CTE scope `ps` stops, and the side flag of the
  // topmost UNION step on the way (if any)
  let path : Array[(Scope, Bool?)] = []
  let mut ps = scope
  let mut tail : (Scope?, Bool?) = (None, None)
  for ;; {
    match memo.get(ps.expression.uid) {
      Some(r) => {
        tail = r
        break
      }
      None => ()
    }
    let local = match ps.parent {
      Some(pps) if pps.expression.kind.is_a(Union) =>
        Some(
          match pps.expression.expression() {
            Some(r) => physical_equal(r.unnest(), ps.expression)
            None => false
          },
        )
      _ => None
    }
    path.push((ps, local))
    match ps.parent {
      None => {
        tail = (None, None)
        break
      }
      Some(pps) if pps.is_cte() => {
        tail = (Some(pps), None)
        break
      }
      Some(pps) => ps = pps
    }
  }
  // fill in from the top of the path down: a higher UNION step overrides lower ones
  let (top, top_flag) = tail
  let mut flag = top_flag
  for i = path.length() - 1; i >= 0; i = i - 1 {
    let (p, local) = path[i]
    if flag is None {
      flag = local
    }
    memo[p.expression.uid] = (top, flag)
  }
  (top, flag.unwrap_or(false))
}

///|
/// Expand references to aliases.
fn expand_alias_refs_impl(
  scope : Scope,
  resolver : Resolver,
  dialect : @core.Dialect,
  ancestry : Map[Int, (Scope?, Bool?)],
  expand_only_groupby? : Bool = false,
) -> Unit raise @core.SqlglotError {
  let expression = scope.expression
  if !expression.kind.is_a(Select) || dialect.cfg.disables_alias_ref_expansion {
    return
  }
  let alias_to_expression : Map[String, (@core.Expr, Int)] = {}
  let projections : @set.Set[String] = @set.new()
  for s in expression.selects() {
    projections.add(s.alias_or_name())
  }
  let mut replaced = false
  fn replace_columns(
    node : @core.Expr?,
    resolve_table : Bool,
    literal_index : Bool,
  ) raise @core.SqlglotError {
    let node = match node {
      Some(n) => n
      None => return
    }
    let is_group_by = node.kind.is_a(Group)
    let is_having = node.kind.is_a(Having)
    let is_qualify = node.kind.is_a(Qualify)
    if expand_only_groupby && !is_group_by {
      return
    }
    for column in walk_in_scope(node, prune=n => n.is_star()) {
      if !column.kind.is_a(Column) {
        continue
      }
      if expand_only_groupby &&
        is_group_by &&
        !(match column.parent {
          Some(p) => physical_equal(p, node)
          None => false
        }) {
        continue
      }
      let mut skip_replace = false
      let table = if resolve_table && column.table_name() == "" {
        resolver.get_table_by_name(column.name())
      } else {
        None
      }
      let (alias_expr, i) = match alias_to_expression.get(column.name()) {
        Some((e, i)) => (Some(e), i)
        None => (None, 1)
      }
      match alias_expr {
        Some(ae) => {
          skip_replace = find_in_scope(ae, [AggFunc]) is Some(_) &&
            (is_group_by ||
            (column.find_ancestor([AggFunc]) is Some(_) &&
            !(match column.find_ancestor([Window, Select]) {
              Some(a) => a.kind.is_a(Window)
              None => false
            })))
          if (is_having || is_qualify) &&
            dialect.cfg.projection_aliases_shadow_source_names {
            skip_replace = skip_replace ||
              ae
              .find_all([Column])
              .any(n => projections.contains(n.parts()[0].name()))
          }
        }
        None => ()
      }
      if table is Some(t) && (alias_expr is None || skip_replace) {
        column.set("table", t)
      } else if column.table_name() == "" &&
        alias_expr is Some(ae) &&
        !skip_replace {
        if (ae.kind.is_a(Literal) || ae.is_number()) &&
          (literal_index || resolve_table) {
          if literal_index {
            column.replace(Some(lit_num(i))) |> ignore
            replaced = true
          }
        } else {
          replaced = true
          let mut column = column.replace(Some(@core.paren(ae.copy()))).unwrap()
          let simplified = simplify_parens(column, dialect)
          if !physical_equal(simplified, column) {
            column.replace(Some(simplified)) |> ignore
            column = simplified
          }
          if resolve_table && resolver.schema.empty() {
            for inner in walk_in_scope(column) {
              if inner.kind.is_a(Column) && inner.table_name() == "" {
                match resolver.get_table(inner) {
                  Some(inner_table) => inner.set("table", inner_table)
                  None => ()
                }
              }
            }
          }
        }
      }
    }
  }

  for i, projection in expression.selects() {
    replace_columns(Some(projection), false, false)
    if projection.kind.is_a(Alias) {
      alias_to_expression[projection.alias()] = (projection.this_(), i + 1)
    }
  }
  let (parent_scope, on_right_sub_tree) = scope_ancestry(scope, ancestry)
  match parent_scope {
    Some(ps) if on_right_sub_tree =>
      match ps.expression.parent {
        Some(cte) =>
          match cte.find_ancestor([With]) {
            Some(w) if w.has("recursive") => {
              let cols = match cte.arg("alias") {
                Some(a) => a.list("columns")
                None => []
              }
              let cols = if cols.is_empty() {
                match cte.this() {
                  Some(t) => t.selects()
                  None => []
                }
              } else {
                cols
              }
              for c in cols {
                alias_to_expression.remove(c.output_name())
              }
            }
            _ => ()
          }
        None => ()
      }
    _ => ()
  }
  replace_columns(expression.arg("where"), false, false)
  replace_columns(expression.arg("group"), false, true)
  replace_columns(expression.arg("having"), true, false)
  replace_columns(expression.arg("qualify"), true, false)
  if dialect.cfg.supports_alias_refs_in_join_conditions {
    for join in expression.list("joins") {
      replace_columns(Some(join), false, false)
    }
  }
  if dialect.cfg.projection_aliases_shadow_source_names {
    for key in ["group", "having", "qualify"] {
      match expression.arg(key) {
        Some(clause) =>
          for column in find_all_in_scope(clause, [Column]).collect() {
            if column.table_name() != "" && column.db() == "" {
              if projections.contains(column.table_name()) {
                column.set("shadow", true)
              } else {
                column.set("shadow", @core.null_arg)
              }
            }
          }
        None => ()
      }
    }
  }
  if replaced {
    scope.clear_cache()
  }
}

///|
fn expand_group_by(
  scope : Scope,
  dialect : @core.Dialect,
) -> Unit raise @core.SqlglotError {
  let expression = scope.expression
  match expression.arg("group") {
    Some(group) => {
      group.set(
        "expressions",
        expand_positional_references(scope, group.expressions(), dialect, None),
      )
      expression.set("group", group)
    }
    None => ()
  }
}

///|
fn expand_order_by_and_distinct_on(
  scope : Scope,
  resolver : Resolver,
) -> Unit raise @core.SqlglotError {
  let expression = scope.expression
  if !expression.kind.is_a(Selectable) {
    return
  }
  // Only needed with an ORDER BY / DISTINCT ON; computed lazily since `named_selects` of
  // a left-deep set operation chain walks the whole chain.
  let mut alias_names_ : @set.Set[String]? = None
  let alias_names = () => {
    match alias_names_ {
      Some(a) => a
      None => {
        let counts : Map[String, Int] = {}
        for n in expression.named_selects() {
          counts[n] = counts.get_or_default(n, 0) + 1
        }
        let a : @set.Set[String] = @set.new()
        for n, c in counts {
          if c == 1 {
            a.add(n)
          }
        }
        alias_names_ = Some(a)
        a
      }
    }
  }
  for modifier_key in ["order", "distinct"] {
    let mut modifier = expression.arg(modifier_key)
    match modifier {
      Some(m) if m.kind.is_a(Distinct) => modifier = m.arg("on")
      _ => ()
    }
    let modifier = match modifier {
      Some(m) => m
      None => continue
    }
    let mut modifier_expressions = modifier.expressions()
    if modifier_key == "order" {
      modifier_expressions = modifier_expressions.map(o => o.this_())
    }
    let expanded = expand_positional_references(
      scope,
      modifier_expressions,
      resolver.dialect,
      Some(alias_names()),
    )
    for idx, original in modifier_expressions {
      match expanded.get(idx) {
        Some(exp) => {
          for agg in original.find_all([AggFunc]).collect() {
            for col in agg.find_all([Column]).collect() {
              if col.table_name() == "" {
                col.set("table", resolver.get_table_by_name(col.name()))
              }
            }
          }
          original.replace(Some(exp)) |> ignore
        }
        None => ()
      }
    }
    if expression.has("group") {
      let selects : Array[(@core.Expr, @core.Expr)] = []
      for s in expression.selects() {
        if alias_names().contains(s.alias_or_name()) {
          match s.this() {
            Some(t) => selects.push((t, column_with_table(s.alias_or_name())))
            None => ()
          }
        }
      }
      for node in modifier_expressions {
        if !node.is_int() {
          let mut replacement = node
          for kv in selects {
            if kv.0 == node {
              replacement = kv.1
            }
          }
          node.replace(Some(replacement)) |> ignore
        }
      }
    }
  }
}

///|
fn is_constant(e : @core.Expr) -> Bool {
  e.kind.is_any([Literal, Boolean, Null])
}

///|
fn expand_positional_references(
  scope : Scope,
  expressions : Array[@core.Expr],
  dialect : @core.Dialect,
  alias_names : @set.Set[String]?,
) -> Array[@core.Expr] raise @core.SqlglotError {
  let new_nodes = []
  let mut ambiguous_projections : @set.Set[String]? = None
  let expression = scope.expression
  if !expression.kind.is_a(Selectable) {
    return new_nodes
  }
  for node in expressions {
    if node.is_int() && node.kind.is_a(Literal) {
      let select = select_by_pos(expression, node)
      match alias_names {
        Some(names) =>
          new_nodes.push(
            if names.contains(select.alias()) {
              @core.mk1(Column, select.arg("alias").unwrap().copy())
            } else {
              node
            },
          )
        None => {
          let select_expr = select.this_()
          let ambiguous = if dialect.cfg.projection_aliases_shadow_source_names {
            let ap = match ambiguous_projections {
              Some(a) => a
              None => {
                let a : @set.Set[String] = @set.new()
                let selected = scope.selected_sources()
                for s in expression.selects() {
                  if selected.contains(s.alias_or_name()) {
                    a.add(s.alias_or_name())
                  }
                }
                ambiguous_projections = Some(a)
                a
              }
            }
            select_expr
            .find_all([Column])
            .any(column => ap.contains(column.parts()[0].name()))
          } else {
            false
          }
          if is_constant(select_expr) ||
            select_expr.is_number() ||
            select_expr.find([Explode, Unnest]) is Some(_) ||
            ambiguous {
            new_nodes.push(node)
          } else {
            new_nodes.push(select_expr.copy())
          }
        }
      }
    } else {
      new_nodes.push(node)
    }
  }
  new_nodes
}

///|
fn select_by_pos(
  expression : @core.Expr,
  node : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let idx = match node.to_py_int() {
    Some(i) => i.to_int() - 1
    None => -1
  }
  let selects = expression.selects()
  // Python negative indices wrap around
  let idx = if idx < 0 { selects.length() + idx } else { idx }
  match selects.get(idx) {
    Some(s) if s.kind.is_a(Alias) => s
    Some(s) =>
      raise @core.OptimizeError(
        "\{s.kind.name()} is not a sqlglot.expressions.Alias",
      )
    None => raise @core.OptimizeError("Unknown output column: \{node.name()}")
  }
}

///|
/// Converts `Column` instances that represent STRUCT or JSON field lookup into chained `Dots`.
fn convert_columns_to_dots(
  scope : Scope,
  resolver : Resolver,
) -> Unit raise @core.SqlglotError {
  let mut converted = false
  let candidates = scope.columns() + scope.stars()
  for column in candidates {
    if column.kind.is_a(Dot) {
      continue
    }
    let is_star = match column.this() {
      Some(t) => t.kind.is_a(Star)
      None => false
    }
    let mut column_table : @core.Expr? = None
    let column_table_name = column.table_name()
    let dot_parts : Array[String] = match column.meta_get("dot_parts") {
      Some(List(l)) => l.filter_map(v => v.as_str())
      _ => []
    }
    match column.meta {
      Some(m) => m.remove("dot_parts")
      None => ()
    }
    let selected_sources = scope.selected_sources()
    let mut root_resolver : Resolver? = None
    if !is_star && column.db() != "" && selected_sources.contains(column_table_name) {
      let parts = column.parts()
      let root = parts[0]
      let field = parts[1]
      for candidate in [resolver] + resolver.outer_resolvers() {
        if !candidate.scope.selected_sources().contains(root.name()) {
          continue
        }
        if candidate.get_source_columns(root.name()).contains(field.name()) {
          root_resolver = Some(candidate)
        }
        break
      }
    }
    let has_table = column_table_name != ""
    if has_table &&
      (!selected_sources.contains(column_table_name) ||
      (is_star && column.db() != "") ||
      root_resolver is Some(_)) &&
      (root_resolver is Some(_) ||
      is_star ||
      scope.parent is None ||
      !scope.parent.unwrap().sources.contains(column_table_name) ||
      !scope.is_correlated_subquery()) {
      let all_parts = column.parts()
      let mut root = all_parts[0]
      let mut parts = all_parts[1:].to_array()
      let mut was_qualified = false
      // column_table starts as the column's table name (a string in Python)
      let mut table_str : String? = Some(column_table_name)
      let resolvers = if is_star {
        [resolver] + resolver.outer_resolvers()
      } else {
        match root_resolver {
          Some(r) => [r]
          None => [resolver]
        }
      }
      for source_resolver in resolvers {
        let selected = source_resolver.scope.selected_sources()
        if column.db() == "" && selected.contains(column.table_name()) {
          table_str = None
          column_table = None
          break
        }
        if root.kind == Identifier && selected.contains(root.name()) {
          table_str = None
          column_table = Some(root)
          root = parts[0]
          parts = parts[1:].to_array()
          was_qualified = true
          break
        }
        if is_star &&
          !source_resolver.all_columns().contains(root.name()) &&
          source_resolver.has_unknown_sources() {
          table_str = None
          column_table = None
          break
        }
        table_str = None
        column_table = source_resolver.get_table_by_name(root.name())
        if column_table is Some(_) {
          break
        }
      }
      // A string table can only survive the loop when `resolvers` is empty
      match table_str {
        Some(t) if t != "" => column_table = Some(@core.to_identifier(t))
        _ => ()
      }
      match column_table {
        Some(ct) => {
          converted = true
          let new_column = column_with_ident(root, table=ct)
          if !dot_parts.is_empty() {
            let skip = if was_qualified { 2 } else { 1 }
            let rest = if skip <= dot_parts.length() {
              dot_parts[skip:].to_array()
            } else {
              []
            }
            new_column.get_meta()["dot_parts"] = List(rest.map(s => Str(s)))
          }
          column.replace(Some(@core.dot_build([new_column] + parts))) |> ignore
        }
        _ => ()
      }
    }
  }
  if converted {
    scope.clear_cache()
  }
}

///|
fn find_pivot_by_alias(pivots : Array[@core.Expr], alias : String) -> @core.Expr? {
  for p in pivots {
    if p.alias() == alias {
      return Some(p)
    }
  }
  None
}

///|
/// Resolve a positional column, returning whether to skip further qualification.
fn qualify_positional_column(
  scope : Scope,
  resolver : Resolver,
  column : @core.Expr,
  column_table : String,
  column_source : Source,
  source_columns : Array[String],
  pivots : Array[@core.Expr],
  allow_partial_qualification : Bool,
) -> Bool raise @core.SqlglotError {
  if !resolver.dialect.cfg.supports_positional_column_refs {
    return false
  }
  let position = match column.this() {
    Some(p) if p.kind.is_a(Parameter) =>
      match p.this() {
        Some(l) if l.kind.is_a(Literal) && l.is_int() => l
        _ => return false
      }
    _ => return false
  }
  let mut scope_pivot = find_pivot_by_alias(scope.pivots(), column_table)
  if scope_pivot is None {
    let sp = scope.pivots().copy()
    sp.rev_in_place()
    for pivot in sp {
      match pivot.parent {
        Some(pp) if pp.alias_or_name() == column_table => {
          scope_pivot = Some(pivot)
          break
        }
        _ => ()
      }
    }
  }
  if !pivots.is_empty() ||
    scope_pivot is Some(_) ||
    source_columns.is_empty() ||
    source_columns.contains("*") {
    match scope_pivot {
      Some(p) => column.set("table", @core.to_identifier(p.alias()))
      None => ()
    }
    return true
  }
  let position_value = position.to_py_int().unwrap()
  let (alias_columns, source_columns_incomplete) = match column_source {
    TableSource(t) => {
      let without = resolver.schema.column_names(t, only_visible=true)
      (t.alias_column_names(), without.is_empty() || without.contains("*"))
    }
    _ => ([], false)
  }
  if !alias_columns.is_empty() &&
    position_value > alias_columns.length().to_int64() &&
    source_columns_incomplete {
    return true
  }
  let positional_columns = resolver.get_source_columns(
    column_table,
    only_visible=true,
  )
  if !(
      1L <= position_value &&
      position_value <= positional_columns.length().to_int64()
    ) {
    if allow_partial_qualification {
      return true
    }
    raise @core.OptimizeError(
      "Positional reference $\{position_value} is out of range for source '\{column_table}'",
    )
  }
  // in range, so it fits an Int
  let position_index = position_value.to_int() - 1
  let positional_name = positional_columns[position_index]
  if positional_columns.filter(c => c == positional_name).length() > 1 {
    return true
  }
  let positional_identifier = match column_source {
    ScopeSource(s) => {
      let source_expression = s.expression
      if !source_expression.kind.is_a(Query) {
        return true
      }
      let source_selects = selects_of(source_expression)
      let selection = source_selects.get(position_index)
      match output_identifier(selection) {
        Some(si) if si.name() == positional_name => si.copy()
        _ => return true
      }
    }
    TableSource(_) => {
      let i = @core.to_identifier(positional_name)
      resolver.dialect.quote_identifier(i, identify=false) |> ignore
      i
    }
  }
  column.set("this", positional_identifier)
  false
}

///|
/// Disambiguate columns, ensuring each column specifies a source.
fn qualify_columns_impl(
  scope : Scope,
  resolver : Resolver,
  allow_partial_qualification : Bool,
) -> Unit raise @core.SqlglotError {
  for column in scope.columns() {
    let column_table = column.table_name()
    let mut column_name = column.name()
    if column_table != "" && scope.sources.contains(column_table) {
      let column_source = scope.sources[column_table]
      let mut source_columns = resolver.get_source_columns(column_table)
      let pivots = match column_source {
        TableSource(t) => t.list("pivots")
        _ => []
      }
      if !pivots.is_empty() &&
        !source_columns.is_empty() &&
        !source_columns.contains("*") {
        for pivot in pivots {
          source_columns = pivot_output_columns(pivot, source_columns).map(kv => kv.0)
        }
      }
      if qualify_positional_column(
          scope, resolver, column, column_table, column_source, source_columns, pivots,
          allow_partial_qualification,
        ) {
        continue
      }
      column_name = column.name()
      if !allow_partial_qualification &&
        !source_columns.is_empty() &&
        !source_columns.contains(column_name) &&
        !source_columns.contains("*") {
        raise @core.OptimizeError("Unknown column: \{column_name}")
      }
    }
    if column_table == "" {
      if !scope.pivots().is_empty() && column.find_ancestor([Pivot]) is None {
        let pivots = scope.pivots()
        column.set(
          "table",
          @core.to_identifier(pivots[pivots.length() - 1].alias()),
        )
        continue
      }
      let table = resolver.get_table(column)
      match table {
        Some(t) =>
          match scope.sources.get(t.name()) {
            Some(ScopeSource(source)) if source.column_index().contains(
              column.uid,
            ) => continue
            _ => ()
          }
        None => ()
      }
      match table {
        Some(t) => column.set("table", t)
        None =>
          if resolver.dialect.cfg.tables_referenceable_as_columns &&
            column.parts().length() == 1 &&
            scope.selected_sources().contains(column_name) {
            scope.replace(column, @core.mk1(TableColumn, column.this_()))
          }
      }
    }
  }
  let pivots = scope.pivots()
  let single_chain = !pivots.is_empty() &&
    (match (pivots[0].parent, pivots[pivots.length() - 1].parent) {
      (Some(a), Some(b)) => physical_equal(a, b)
      (None, None) => true
      _ => false
    })
  let produced : @set.Set[String] = @set.new()
  let pivoted_source = if single_chain {
    pivots[pivots.length() - 1].alias()
  } else {
    ""
  }
  let mut available : Array[String] = if scope.sources.contains(pivoted_source) {
    resolver.get_source_columns(pivoted_source)
  } else {
    []
  }
  for pivot in pivots {
    for column in pivot.find_all([Column]).collect() {
      if column.table_name() != "" {
        continue
      }
      if resolver.all_columns().contains(column.name()) {
        match resolver.get_table_by_name(column.name()) {
          Some(table) => column.set("table", table)
          None => ()
        }
      } else if single_chain && produced.contains(column.name()) {
        column.set("table", @core.to_identifier(pivoted_source))
      }
    }
    if single_chain {
      available = pivot_output_columns(pivot, available).map(kv => kv.0)
      for c in available {
        produced.add(c)
      }
    }
  }
}

///|
/// `Pivot.output_columns`: ordered (post-rename name, pre-rename name) pairs.
pub fn pivot_output_columns(
  pivot : @core.Expr,
  pre_pivot_columns : Array[String],
) -> Array[(String, String)] {
  let excluded : @set.Set[String] = @set.new()
  let outputs = if pivot.has("unpivot") {
    let name_columns = []
    for field in pivot.list("fields") {
      if !field.kind.is_a(In) {
        continue
      }
      match field.this() {
        Some(t) if t.kind == Identifier => name_columns.push(t)
        _ => ()
      }
      for e in field.expressions() {
        for c in e.find_all([Column]) {
          excluded.add(c.output_name())
        }
      }
    }
    let value_columns = []
    for e in pivot.expressions() {
      let idents = if e.kind.is_a(Tuple) { e.expressions() } else { [e] }
      for ident in idents {
        if ident.kind == Identifier {
          value_columns.push(ident)
        }
      }
    }
    let ordered = if pivot.has("value_columns_first") {
      value_columns + name_columns
    } else {
      name_columns + value_columns
    }
    ordered.map(i => i.name())
  } else {
    for c in pivot.find_all([Column]) {
      excluded.add(c.output_name())
    }
    let outs = pivot.list("columns").map(c => c.output_name())
    if outs.is_empty() {
      pivot.expressions().map(c => c.alias_or_name())
    } else {
      outs
    }
  }
  if excluded.is_empty() || outputs.is_empty() {
    return []
  }
  let pre_rename = pre_pivot_columns.filter(c => !excluded.contains(c)) +
    outputs
  let renames = match pivot.arg("alias") {
    Some(a) => a.list("columns")
    None => []
  }
  let post_rename = if !renames.is_empty() {
    let rename_names = renames.map(r => r.name())
    if rename_names.length() < pre_rename.length() {
      rename_names + pre_rename[rename_names.length():].to_array()
    } else {
      rename_names
    }
  } else {
    pre_rename
  }
  // dict(zip(post_rename, pre_rename))
  let keys = []
  let values : Map[String, String] = {}
  for i in 0..<@core.min_int(post_rename.length(), pre_rename.length()) {
    let k = post_rename[i]
    if !values.contains(k) {
      keys.push(k)
    }
    values[k] = pre_rename[i]
  }
  keys.map(k => (k, values[k]))
}

///|
fn output_identifier(selection : @core.Expr?) -> @core.Expr? {
  let identifier = match selection {
    Some(s) if s.kind.is_a(Alias) => s.arg("alias")
    Some(s) if s.kind.is_a(Column) => s.this()
    _ => None
  }
  match identifier {
    Some(i) if i.kind == Identifier => Some(i)
    _ => None
  }
}

///|
fn is_output_identifier_quoted(selection : @core.Expr) -> Bool {
  match output_identifier(Some(selection)) {
    Some(i) => i.has("quoted")
    None => false
  }
}

///|
/// Ensure all output columns are aliased.
pub fn qualify_outputs(
  expression : @core.Expr,
  dialect : @core.Dialect,
) -> Unit raise @core.SqlglotError {
  match build_scope(expression) {
    Some(scope) => qualify_outputs_scope(scope, dialect)
    None => ()
  }
}

///|
/// Ensure all output columns of a scope are aliased.
pub fn qualify_outputs_scope(scope : Scope, dialect : @core.Dialect) -> Unit {
  let expression = scope.expression
  if !expression.kind.is_a(Selectable) {
    return
  }
  let new_selections = []
  let selects = expression.selects()
  let n = @core.max_int(selects.length(), scope.outer_columns.length())
  for i in 0..<n {
    let mut selection = match selects.get(i) {
      Some(s) => s
      None => break
    }
    let aliased_column = scope.outer_columns.get(i)
    if selection.kind.is_a(QueryTransform) {
      break
    }
    if selection.kind.is_a(Subquery) {
      if selection.output_name() == "" {
        let alias_identifier = @core.to_identifier("_col_\{i}")
        dialect.normalize_identifier(alias_identifier) |> ignore
        selection.set("alias", @core.mk1(TableAlias, alias_identifier))
      }
    } else if !selection.kind.is_any([Alias, Aliases]) && !selection.is_star() {
      let unwrapped = selection.unnest()
      let source_identifier = if unwrapped.kind.is_a(Column) {
        unwrapped.this()
      } else if unwrapped.kind.is_a(Dot) {
        unwrapped.expression()
      } else {
        None
      }
      let name = if selection.output_name() != "" {
        selection.output_name()
      } else {
        "_col_\{i}"
      }
      selection = @core.alias_(selection, name, copy=false)
      match source_identifier {
        Some(si) if si.kind == Identifier =>
          if si.has("quoted") {
            selection.arg("alias").unwrap().set("quoted", true)
          }
        _ => dialect.normalize_identifier(selection.arg("alias").unwrap()) |> ignore
      }
    }
    match aliased_column {
      Some(ac) if ac != "" => selection.set("alias", @core.to_identifier(ac))
      _ => ()
    }
    new_selections.push(selection)
  }
  if !new_selections.is_empty() && expression.kind.is_a(Select) {
    expression.set("expressions", new_selections)
  }
}

///|
/// Makes sure all identifiers that need to be quoted are quoted.
pub fn quote_identifiers(
  expression : @core.Expr,
  dialect? : @core.Dialect,
  identify? : Bool = true,
) -> @core.Expr {
  let dialect = get_dialect(dialect)
  for node in expression.walk() {
    if node.kind == Identifier {
      dialect.quote_identifier(node, identify~) |> ignore
    }
  }
  expression
}

///|
/// Pushes down the CTE alias columns into the projection.
pub fn pushdown_cte_alias_columns(scope : Scope) -> Unit {
  for cte in scope.ctes() {
    match cte.this() {
      Some(sel) if !cte.alias_column_names().is_empty() && sel.kind.is_a(Select) => {
        let new_expressions = []
        let aliases = cte.arg("alias").unwrap().list("columns")
        let projections = sel.expressions()
        for i in 0..<@core.min_int(aliases.length(), projections.length()) {
          let alias = aliases[i]
          let mut projection = projections[i]
          if projection.kind.is_a(Alias) {
            projection.set("alias", alias.copy())
          } else {
            projection = @core.alias_expr(projection, Some(alias.copy()))
          }
          new_expressions.push(projection)
        }
        sel.set("expressions", new_expressions)
      }
      _ => ()
    }
  }
}
