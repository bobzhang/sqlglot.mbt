// Port of sqlglot/optimizer/resolver.py.

///|
/// Helper for resolving columns.
pub struct Resolver {
  scope : Scope
  schema : MappingSchema
  dialect : @core.Dialect
  priv mut source_columns_ : Map[String, Array[String]]?
  priv mut unambiguous_columns_ : Map[String, String]?
  priv mut all_columns_ : @set.Set[String]?
  priv infer_schema : Bool
  priv get_source_columns_cache : Map[(String, Bool), Array[String]]
  priv column_type_from_scope_cache : Map[(Int, String), @core.Expr?]
}

///|
pub fn Resolver::new(
  scope : Scope,
  schema : MappingSchema,
  infer_schema? : Bool = true,
) -> Resolver {
  {
    scope,
    schema,
    dialect: schema.dialect,
    source_columns_: None,
    unambiguous_columns_: None,
    all_columns_: None,
    infer_schema,
    get_source_columns_cache: {},
    column_type_from_scope_cache: {},
  }
}

///|
/// Get the table for a column name.
pub fn Resolver::get_table_by_name(
  self : Resolver,
  column_name : String,
) -> @core.Expr? raise @core.SqlglotError {
  self.get_table_impl(column_name, None)
}

///|
/// Get the table for a column.
pub fn Resolver::get_table(
  self : Resolver,
  column : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  self.get_table_impl(column.name(), Some(column))
}

///|
fn Resolver::get_table_impl(
  self : Resolver,
  column_name : String,
  column : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let join_context = match column {
    Some(c) if c.kind.is_a(Column) => self.get_column_join_context(c)
    _ => None
  }
  let is_semi_or_anti = match join_context {
    Some(j) => is_semi_or_anti_join(j)
    None => false
  }
  let mut table_name : String? = if is_semi_or_anti {
    None
  } else {
    self.get_table_name_from_sources(column_name, None)
  }
  if table_name is None && join_context is Some(jc) {
    table_name = self.get_table_name_from_sources(
      column_name,
      Some(self.get_available_source_columns(jc)),
    ) catch {
      @core.OptimizeError(_) => None
      e => raise e
    }
  }
  if table_name is None && self.infer_schema {
    let sources_without_schema = []
    for source, columns in self.get_all_source_columns() {
      if columns.is_empty() || columns.contains("*") {
        sources_without_schema.push(source)
      }
    }
    if sources_without_schema.length() == 1 {
      table_name = Some(sources_without_schema[0])
    }
  }
  let table_name = match table_name {
    Some(t) => t
    None => return None
  }
  let selected = self.scope.selected_sources()
  match selected.get(table_name) {
    None => Some(@core.to_identifier(table_name))
    Some((node, _)) => {
      let mut node = node
      if node.kind.is_a(Query) {
        while node.alias() != table_name && node.parent is Some(p) {
          node = p
        }
      }
      match node.arg("alias") {
        Some(node_alias) =>
          match node_alias.this() {
            Some(t) => Some(t.copy())
            None => Some(@core.to_identifier(node_alias.name()))
          }
        None => Some(@core.to_identifier(table_name))
      }
    }
  }
}

///|
/// Resolvers for the outer scopes a correlated subquery can reference, innermost first.
pub fn Resolver::outer_resolvers(self : Resolver) -> Array[Resolver] {
  let out = []
  let mut scope = self.scope
  while scope.can_be_correlated && scope.parent is Some(p) {
    scope = p
    out.push(Resolver::new(scope, self.schema, infer_schema=self.infer_schema))
  }
  out
}

///|
/// Whether some source's columns can't be determined.
pub fn Resolver::has_unknown_sources(
  self : Resolver,
) -> Bool raise @core.SqlglotError {
  for _, columns in self.get_all_source_columns() {
    if columns.is_empty() || columns.contains("*") {
      return true
    }
  }
  false
}

///|
/// All available columns of all sources in this scope.
pub fn Resolver::all_columns(
  self : Resolver,
) -> @set.Set[String] raise @core.SqlglotError {
  match self.all_columns_ {
    Some(c) => c
    None => {
      let s : @set.Set[String] = @set.new()
      for _, columns in self.get_all_source_columns() {
        for c in columns {
          s.add(c)
        }
      }
      self.all_columns_ = Some(s)
      s
    }
  }
}

///|
fn dedup_strings(xs : Array[String]) -> Array[String] {
  let seen : @set.Set[String] = @set.new()
  let out = []
  for x in xs {
    if !seen.contains(x) {
      seen.add(x)
      out.push(x)
    }
  }
  out
}

///|
pub fn Resolver::get_source_columns_from_set_op(
  self : Resolver,
  expression : @core.Expr,
) -> Array[String] raise @core.SqlglotError {
  if expression.kind.is_a(Select) {
    return expression.named_selects()
  }
  if expression.kind.is_a(Subquery) {
    return self.get_source_columns_from_set_op(expression.unnest())
  }
  if !expression.kind.is_a(SetOperation) {
    raise @core.OptimizeError("Unknown set operation: \{expr_sql(expression)}")
  }
  let set_op = expression
  let on_column_list = set_op.list("on")
  if !on_column_list.is_empty() {
    on_column_list.map(c => c.name())
  } else {
    let side = @core.py_upper(set_op.text("side"))
    let kind = @core.py_upper(set_op.text("kind"))
    if side != "" || kind != "" {
      let left = self.get_source_columns_from_set_op(set_op.this_())
      let right = self.get_source_columns_from_set_op(set_op.expression_())
      if side == "LEFT" {
        left
      } else if side == "FULL" {
        dedup_strings(left + right)
      } else if kind == "INNER" {
        // dict keys intersection: Python set semantics, order of the left operand
        let r : @set.Set[String] = @set.from_array(right)
        dedup_strings(left).filter(x => r.contains(x))
      } else {
        // Python leaves `columns` unbound here
        raise @core.OptimizeError("Unknown set operation: \{expr_sql(expression)}")
      }
    } else {
      set_op.named_selects()
    }
  }
}

///|
/// Resolve the source columns for a given source `name`.
pub fn Resolver::get_source_columns(
  self : Resolver,
  name : String,
  only_visible? : Bool = false,
) -> Array[String] raise @core.SqlglotError {
  let cache_key = (name, only_visible)
  match self.get_source_columns_cache.get(cache_key) {
    Some(c) => return c
    None => ()
  }
  let mut source = match self.scope.sources.get(name) {
    Some(s) => s
    None => raise @core.OptimizeError("Unknown table: \{name}")
  }
  match source {
    TableSource(t) if t.db() == "" &&
      t.has("pivots") &&
      self.scope.cte_sources.contains(t.name()) =>
      source = self.scope.cte_sources[t.name()]
    _ => ()
  }
  let mut columns : Array[String] = match source {
    TableSource(t) => self.schema.column_names(t, only_visible~)
    ScopeSource(s) if s.expression.kind.is_any([Values, Unnest, Lateral]) => {
      let source_expr = s.expression
      let mut columns = source_expr.named_selects()
      if self.dialect.cfg.unnest_column_only && source_expr.kind.is_a(Unnest) {
        if source_expr.get_type() is None ||
          type_is(source_expr.get_type(), [UNKNOWN]) {
          match source_expr.expressions().get(0) {
            Some(unnest_expr) if unnest_expr.kind.is_a(Column) &&
              self.scope.parent is Some(parent) => {
              let col_type = self.get_unnest_column_type(unnest_expr, parent)
              match col_type {
                Some(ct) =>
                  if ct.is_type([ARRAY]) {
                    let element_types = ct.expressions()
                    if !element_types.is_empty() {
                      source_expr.set_type(Some(element_types[0].copy()))
                    }
                  } else {
                    source_expr.set_type(Some(ct.copy()))
                  }
                None => ()
              }
            }
            _ => ()
          }
        }
        columns = columns + struct_field_names(source_expr.get_type())
      } else if source_expr.kind.is_a(Lateral) &&
        (match source_expr.this() {
          Some(t) => t.kind.is_a(Explode)
          None => false
        }) {
        let explode_col = source_expr.this_().this()
        match explode_col {
          Some(ec) if ec.kind.is_a(Column) &&
            ec.table_name() != "" &&
            s.parent is Some(sp) => {
            let col_type = self.get_unnest_column_type(ec, sp)
            columns = columns + struct_field_names(col_type)
          }
          _ => ()
        }
      } else if source_expr.kind.is_a(Lateral) &&
        (match source_expr.this() {
          Some(t) => t.kind.is_a(Query)
          None => false
        }) {
        columns = named_selects_of(source_expr.this_())
      }
      columns
    }
    ScopeSource(s) if s.expression.kind.is_a(SetOperation) =>
      self.get_source_columns_from_set_op(s.expression)
    ScopeSource(s) => {
      let selectable = s.expression
      match selects_of(selectable).get(0) {
        Some(select) if select.kind.is_a(QueryTransform) =>
          match select.arg("schema") {
            Some(schema) => schema.expressions().map(c => c.name())
            None => ["key", "value"]
          }
        _ => named_selects_of(selectable)
      }
    }
  }
  let column_aliases = match self.scope.selected_sources().get(name) {
    Some((node, _)) => node.alias_column_names()
    None => []
  }
  if !column_aliases.is_empty() {
    let n = @core.max_int(columns.length(), column_aliases.length())
    let out = []
    for i in 0..<n {
      match column_aliases.get(i) {
        Some(a) if a != "" => out.push(a)
        _ =>
          match columns.get(i) {
            Some(c) => out.push(c)
            None => out.push("")
          }
      }
    }
    columns = out
  }
  self.get_source_columns_cache[cache_key] = columns
  columns
}

///|
fn Resolver::get_all_source_columns(
  self : Resolver,
) -> Map[String, Array[String]] raise @core.SqlglotError {
  match self.source_columns_ {
    Some(s) => return s
    None => ()
  }
  let result : Map[String, Array[String]] = {}
  for source_name, _ in self.scope.selected_sources() {
    result[source_name] = self.get_source_columns(source_name)
  }
  for source_name, _ in self.scope.lateral_sources {
    result[source_name] = self.get_source_columns(source_name)
  }
  self.source_columns_ = Some(result)
  result
}

///|
fn Resolver::get_table_name_from_sources(
  self : Resolver,
  column_name : String,
  source_columns : Map[String, Array[String]]?,
) -> String? raise @core.SqlglotError {
  let unambiguous_columns = match source_columns {
    Some(sc) if !sc.is_empty() => self.get_unambiguous_columns(sc)
    _ =>
      match self.unambiguous_columns_ {
        Some(u) => u
        None => {
          let u = self.get_unambiguous_columns(self.get_all_source_columns())
          self.unambiguous_columns_ = Some(u)
          u
        }
      }
  }
  unambiguous_columns.get(column_name)
}

///|
fn Resolver::get_column_join_context(
  self : Resolver,
  column : @core.Expr,
) -> @core.Expr? {
  let e = self.scope.expression
  if !e.has("joins") || e.has("laterals") || e.has("pivots") {
    return None
  }
  match column.find_ancestor([Join, Select]) {
    Some(j) if j.kind.is_a(Join) => {
      let join_name = j.alias_or_name()
      if self.scope.selected_sources_or_empty().contains(join_name) ||
        self.scope.semi_or_anti_join_tables().contains(join_name) {
        Some(j)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn Resolver::get_available_source_columns(
  self : Resolver,
  join_ancestor : @core.Expr,
) -> Map[String, Array[String]] raise @core.SqlglotError {
  let e = self.scope.expression
  let from_name = match e.arg("from_") {
    Some(f) => f.alias_or_name()
    None => raise @core.OptimizeError("KeyError: from_")
  }
  let available : Map[String, Array[String]] = {}
  available[from_name] = self.get_source_columns(from_name)
  let joins = e.list("joins")
  let upto = match join_ancestor.index {
    Some(i) => i + 1
    None => 0
  }
  for i in 0..<@core.min_int(upto, joins.length()) {
    let join = joins[i]
    available[join.alias_or_name()] = self.get_source_columns(join.alias_or_name())
  }
  available
}

///|
fn Resolver::get_unambiguous_columns(
  self : Resolver,
  source_columns : Map[String, Array[String]],
) -> Map[String, String] {
  if source_columns.is_empty() {
    return {}
  }
  let pairs = source_columns.to_array()
  let (first_table, first_columns) = pairs[0]
  let unambiguous_columns : Map[String, String] = {}
  for col in first_columns {
    unambiguous_columns[col] = first_table
  }
  if pairs.length() == 1 {
    return unambiguous_columns
  }
  let unnest_original_aliases : Map[String, String] = {}
  if self.dialect.cfg.unnest_column_only {
    for source_name, source in self.scope.sources {
      match source.expression() {
        Some(se) if se.kind.is_a(Unnest) =>
          match se.arg("alias") {
            Some(alias_arg) => {
              let cols = alias_arg.list("columns")
              if !cols.is_empty() {
                unnest_original_aliases[cols[0].name()] = source_name
              }
            }
            None => ()
          }
        _ => ()
      }
    }
  }
  let all_columns : @set.Set[String] = @set.new()
  for c in unambiguous_columns.keys() {
    all_columns.add(c)
  }
  for i in 1..<pairs.length() {
    let (table, columns) = pairs[i]
    let unique = dedup_strings(columns)
    let ambiguous = unique.filter(c => all_columns.contains(c))
    let ambiguous_set : @set.Set[String] = @set.from_array(ambiguous)
    for c in columns {
      all_columns.add(c)
    }
    for column in ambiguous {
      match unnest_original_aliases.get(column) {
        Some(s) => {
          unambiguous_columns[column] = s
          continue
        }
        None => ()
      }
      unambiguous_columns.remove(column)
    }
    for column in unique {
      if !ambiguous_set.contains(column) {
        unambiguous_columns[column] = table
      }
    }
  }
  unambiguous_columns
}

///|
fn struct_field_names(col_type : @core.Expr?) -> Array[String] {
  let mut col_type = col_type
  if type_is(col_type, [ARRAY]) {
    col_type = col_type.unwrap().expressions().get(0)
  }
  match col_type {
    Some(ct) if ct.is_type([STRUCT]) => ct.expressions().map(k => k.name())
    _ => []
  }
}

///|
fn Resolver::get_unnest_column_type(
  self : Resolver,
  column : @core.Expr,
  scope : Scope,
) -> @core.Expr? raise @core.SqlglotError {
  let table_name = if column.table_name() != "" {
    column.table_name()
  } else {
    let parent_resolver = Resolver::new(
      scope,
      self.schema,
      infer_schema=self.infer_schema,
    )
    match parent_resolver.get_table(column) {
      Some(t) => t.name()
      None => return None
    }
  }
  match scope.sources.get(table_name) {
    Some(source) => self.get_column_type_from_scope(source, column)
    None => None
  }
}

///|
fn Resolver::get_column_type_from_scope(
  self : Resolver,
  source : Source,
  column : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  let source_id = match source {
    TableSource(t) => t.uid * 2
    ScopeSource(s) => s.id * 2 + 1
  }
  let cache_key = (source_id, column.name())
  match self.column_type_from_scope_cache.get(cache_key) {
    Some(r) => return r
    None => ()
  }
  let mut result : @core.Expr? = None
  match source {
    TableSource(t) => {
      let col_type = self.schema.get_column_type(t, column)
      if !col_type.is_type([UNKNOWN]) {
        result = Some(col_type)
      }
    }
    ScopeSource(s) =>
      for _, nested_source in s.sources {
        let nested_type = self.get_column_type_from_scope(nested_source, column)
        match nested_type {
          Some(nt) if !nt.is_type([UNKNOWN]) => {
            result = Some(nt)
            break
          }
          _ => ()
        }
      }
  }
  self.column_type_from_scope_cache[cache_key] = result
  result
}
