// Port of sqlglot/optimizer/scope.py.

///|
pub(all) enum ScopeType {
  Root
  SubqueryScope
  DerivedTableScope
  CteScope
  SetOperationScope
  UdtfScope
} derive(Eq, Debug)

///|
/// A source of a scope: either a table or another scope.
pub enum Source {
  TableSource(@core.Expr)
  ScopeSource(Scope)
}

///|
/// Selection scope.
pub struct Scope {
  id : Int
  expression : @core.Expr
  sources : Map[String, Source]
  lateral_sources : Map[String, Source]
  cte_sources : Map[String, Source]
  outer_columns : Array[String]
  parent : Scope?
  scope_type : ScopeType
  subquery_scopes : Array[Scope]
  derived_table_scopes : Array[Scope]
  table_scopes : Array[Scope]
  cte_scopes : Array[Scope]
  mut set_operation_scopes : Array[Scope]
  udtf_scopes : Array[Scope]
  can_be_correlated : Bool
  priv mut collected : Bool
  priv mut scans_all_subscope_columns_ : Bool
  priv mut raw_columns : Array[@core.Expr]
  priv mut table_columns_ : Array[@core.Expr]
  priv mut stars_ : Array[@core.Expr]
  priv mut derived_tables_ : Array[@core.Expr]
  priv mut udtfs_ : Array[@core.Expr]
  priv mut tables_ : Array[@core.Expr]
  priv mut ctes_ : Array[@core.Expr]
  priv mut subqueries_ : Array[@core.Expr]
  priv mut join_hints_ : Array[@core.Expr]
  priv mut semi_anti_join_tables_ : @set.Set[String]
  priv mut column_index_ : @set.Set[Int]
  priv mut selected_sources_ : Map[String, (@core.Expr, Source)]?
  priv mut columns_ : Array[@core.Expr]?
  priv mut external_columns_ : Array[@core.Expr]?
  priv mut local_columns_ : Array[@core.Expr]?
  priv mut pivots_ : Array[@core.Expr]?
  priv mut references_ : Array[(String, @core.Expr)]?
}

///|
let scope_id_counter : Ref[Int] = Ref(0)

///|
pub fn Source::is_same(self : Source, other : Source) -> Bool {
  match (self, other) {
    (TableSource(a), TableSource(b)) => physical_equal(a, b)
    (ScopeSource(a), ScopeSource(b)) => physical_equal(a, b)
    _ => false
  }
}

///|
pub fn Source::as_table(self : Source) -> @core.Expr? {
  match self {
    TableSource(t) => Some(t)
    _ => None
  }
}

///|
pub fn Source::as_scope(self : Source) -> Scope? {
  match self {
    ScopeSource(s) => Some(s)
    _ => None
  }
}

///|
/// `source.expression` (Python attribute access on either a Table or a Scope).
pub fn Source::expression(self : Source) -> @core.Expr? {
  match self {
    ScopeSource(s) => Some(s.expression)
    TableSource(t) => t.arg("expression")
  }
}

///|
pub fn Scope::new(
  expression : @core.Expr,
  sources? : Map[String, Source],
  outer_columns? : Array[String] = [],
  parent? : Scope,
  scope_type? : ScopeType = Root,
  lateral_sources? : Map[String, Source],
  cte_sources? : Map[String, Source],
  can_be_correlated? : Bool = false,
) -> Scope {
  let lateral_sources = match lateral_sources {
    Some(s) => s
    None => {}
  }
  let cte_sources = match cte_sources {
    Some(s) => s
    None => {}
  }
  let sources = match sources {
    Some(s) => {
      for k, v in lateral_sources {
        s[k] = v
      }
      for k, v in cte_sources {
        s[k] = v
      }
      s
    }
    // (the common case of a branched scope: a copy of the CTE sources)
    None if lateral_sources.is_empty() => cte_sources.copy()
    None => {
      let s = {}
      for k, v in lateral_sources {
        s[k] = v
      }
      for k, v in cte_sources {
        s[k] = v
      }
      s
    }
  }
  scope_id_counter.val += 1
  {
    id: scope_id_counter.val,
    expression,
    sources,
    lateral_sources,
    cte_sources,
    outer_columns,
    parent,
    scope_type,
    subquery_scopes: [],
    derived_table_scopes: [],
    table_scopes: [],
    cte_scopes: [],
    set_operation_scopes: [],
    udtf_scopes: [],
    can_be_correlated,
    collected: false,
    scans_all_subscope_columns_: false,
    raw_columns: [],
    table_columns_: [],
    stars_: [],
    derived_tables_: [],
    udtfs_: [],
    tables_: [],
    ctes_: [],
    subqueries_: [],
    join_hints_: [],
    semi_anti_join_tables_: @set.new(),
    column_index_: @set.new(),
    selected_sources_: None,
    columns_: None,
    external_columns_: None,
    local_columns_: None,
    pivots_: None,
    references_: None,
  }
}

///|
/// Invalidate the column-classification caches after columns are qualified in place.
pub fn Scope::clear_column_cache(self : Scope) -> Unit {
  self.columns_ = None
  self.external_columns_ = None
  self.local_columns_ = None
}

///|
pub fn Scope::clear_cache(self : Scope) -> Unit {
  self.collected = false
  self.scans_all_subscope_columns_ = false
  self.raw_columns = []
  self.table_columns_ = []
  self.stars_ = []
  self.derived_tables_ = []
  self.udtfs_ = []
  self.tables_ = []
  self.ctes_ = []
  self.subqueries_ = []
  self.join_hints_ = []
  self.semi_anti_join_tables_ = @set.new()
  self.column_index_ = @set.new()
  self.selected_sources_ = None
  self.columns_ = None
  self.external_columns_ = None
  self.local_columns_ = None
  self.pivots_ = None
  self.references_ = None
}

///|
fn copy_sources(m : Map[String, Source]?) -> Map[String, Source]? {
  match m {
    Some(m) if !m.is_empty() => Some(m.copy())
    _ => None
  }
}

///|
/// Branch from the current scope to a new, inner scope.
pub fn Scope::branch(
  self : Scope,
  expression : @core.Expr,
  scope_type : ScopeType,
  sources? : Map[String, Source],
  cte_sources? : Map[String, Source],
  lateral_sources? : Map[String, Source],
  outer_columns? : Array[String] = [],
) -> Scope {
  let ctes = self.cte_sources.copy()
  match cte_sources {
    Some(c) => for k, v in c { ctes[k] = v }
    None => ()
  }
  Scope::new(
    expression.unnest(),
    sources?=copy_sources(sources),
    parent=self,
    scope_type~,
    cte_sources=ctes,
    lateral_sources?=copy_sources(lateral_sources),
    can_be_correlated=self.can_be_correlated ||
      scope_type is (SubqueryScope | UdtfScope),
    outer_columns~,
  )
}

///|
fn is_unwrapped_query(e : @core.Expr) -> Bool {
  e.kind.is_any([Select, SetOperation])
}

///|
fn Scope::collect(self : Scope) -> Unit {
  self.tables_ = []
  self.ctes_ = []
  self.subqueries_ = []
  self.derived_tables_ = []
  self.udtfs_ = []
  self.raw_columns = []
  self.table_columns_ = []
  self.stars_ = []
  self.join_hints_ = []
  self.semi_anti_join_tables_ = @set.new()
  self.column_index_ = @set.new()
  let inner_query = if self.expression.kind.is_a(Subquery) {
    Some(self.expression.unnest())
  } else {
    None
  }
  for node in self.walk() {
    if physical_equal(node, self.expression) {
      continue
    }
    let k = node.kind
    if !k.is_any([
        Column, Dot, Table, Query, UDTF, CTE, Star, TableColumn, JoinHint,
      ]) {
      continue
    }
    if k.is_a(Dot) && node.is_star() {
      self.stars_.push(node)
    } else if k == Column {
      self.column_index_.add(node.uid)
      if node.this() is Some(t) && t.kind.is_a(Star) {
        self.stars_.push(node)
      } else {
        self.raw_columns.push(node)
      }
    } else if k.is_a(Table) && !parent_is(node, [JoinHint]) {
      match node.parent {
        Some(p) if p.kind.is_a(Join) && is_semi_or_anti_join(p) =>
          self.semi_anti_join_tables_.add(node.alias_or_name())
        _ => ()
      }
      self.tables_.push(node)
    } else if k.is_a(JoinHint) {
      self.join_hints_.push(node)
    } else if k == Lateral || (k.is_a(UDTF) && parent_is(node, [From, Join])) {
      self.udtfs_.push(node)
    } else if k.is_a(CTE) {
      self.ctes_.push(node)
    } else if is_derived_table(node) && is_from_or_join(node) {
      self.derived_tables_.push(node)
    } else if is_unwrapped_query(node) &&
      !is_from_or_join(node) &&
      !(match inner_query {
        Some(q) => physical_equal(node, q)
        None => false
      }) {
      self.subqueries_.push(node)
    } else if k.is_a(TableColumn) {
      self.table_columns_.push(node)
    } else if k.is_a(Star) &&
      (node.has("except_") || !parent_is(node, [Count])) {
      self.scans_all_subscope_columns_ = true
    }
  }
  self.collected = true
}

///|
fn Scope::ensure_collected(self : Scope) -> Unit {
  if !self.collected {
    self.collect()
  }
}

///|
pub fn Scope::walk(self : Scope, prune? : (@core.Expr) -> Bool) -> Iter[@core.Expr] {
  walk_in_scope(self.expression, prune?)
}

///|
pub fn Scope::find(self : Scope, kinds : Array[@core.Kind]) -> @core.Expr? {
  find_in_scope(self.expression, kinds)
}

///|
pub fn Scope::find_all(
  self : Scope,
  kinds : Array[@core.Kind],
) -> Iter[@core.Expr] {
  find_all_in_scope(self.expression, kinds)
}

///|
/// Replace `old` with `new`, keeping the scope up to date.
pub fn Scope::replace(self : Scope, old : @core.Expr, new : @core.Expr) -> Unit {
  old.replace(Some(new)) |> ignore
  self.clear_cache()
}

///|
pub fn Scope::tables(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.tables_
}

///|
pub fn Scope::ctes(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.ctes_
}

///|
pub fn Scope::derived_tables(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.derived_tables_
}

///|
pub fn Scope::udtfs(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.udtfs_
}

///|
pub fn Scope::subqueries(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.subqueries_
}

///|
pub fn Scope::scans_all_subscope_columns(self : Scope) -> Bool {
  self.ensure_collected()
  self.scans_all_subscope_columns_
}

///|
pub fn Scope::stars(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.stars_
}

///|
pub fn Scope::column_index(self : Scope) -> @set.Set[Int] {
  self.ensure_collected()
  self.column_index_
}

///|
pub fn Scope::table_columns(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.table_columns_
}

///|
pub fn Scope::join_hints(self : Scope) -> Array[@core.Expr] {
  self.ensure_collected()
  self.join_hints_
}

///|
pub fn Scope::semi_or_anti_join_tables(self : Scope) -> @set.Set[String] {
  self.ensure_collected()
  self.semi_anti_join_tables_
}

///|
/// List of columns in this scope, plus columns of correlated subqueries referencing it.
pub fn Scope::columns(self : Scope) -> Array[@core.Expr] {
  match self.columns_ {
    Some(c) => return c
    None => ()
  }
  self.ensure_collected()
  let columns = self.raw_columns
  let external_columns = []
  for scope in self.subquery_scopes {
    external_columns.append(scope.external_columns())
  }
  for scope in self.udtf_scopes {
    external_columns.append(scope.external_columns())
  }
  for scope in self.derived_table_scopes {
    if scope.can_be_correlated {
      external_columns.append(scope.external_columns())
    }
  }
  let expr = self.expression
  // computed on first use (`named_selects` of a set operation walks its left spine)
  let mut named_selects_ : @set.Set[String]? = None
  let named_selects = () => {
    match named_selects_ {
      Some(s) => s
      None => {
        let s : @set.Set[String] = if expr.kind.is_a(Query) {
          @set.from_array(expr.named_selects())
        } else {
          @set.new()
        }
        named_selects_ = Some(s)
        s
      }
    }
  }
  let result = []
  let ancestors = AncestorCache::new([
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
  for column in columns.iter().concat(external_columns.iter()) {
    let ancestor = ancestors.find(column)
    let keep = match ancestor {
      None => true
      Some(a) =>
        column.text("table") != "" ||
        a.kind.is_a(Select) ||
        (a.kind.is_a(Table) &&
        !(match a.this() {
          Some(t) => t.kind.is_a(Func)
          None => false
        })) ||
        (a.kind.is_any([Order, Cluster, Distinct]) &&
        (parent_is(a, [Window, WithinGroup]) ||
        !parent_is(a, [Select]) ||
        !named_selects().contains(column.name()))) ||
        (a.kind.is_a(Star) && column.arg_key != Some("except_"))
    }
    if keep {
      result.push(column)
    }
  }
  self.columns_ = Some(result)
  result
}

///|
/// Mapping of nodes and sources that are actually selected from in this scope.
pub fn Scope::selected_sources(
  self : Scope,
) -> Map[String, (@core.Expr, Source)] raise @core.SqlglotError {
  match self.selected_sources_ {
    Some(s) => return s
    None => ()
  }
  let result : Map[String, (@core.Expr, Source)] = {}
  for r in self.references() {
    let (name, node) = r
    if self.semi_anti_join_tables_.contains(name) {
      continue
    }
    if result.contains(name) {
      raise @core.OptimizeError("Alias already used: \{name}")
    }
    match self.sources.get(name) {
      Some(s) => result[name] = (node, s)
      None => ()
    }
  }
  self.selected_sources_ = Some(result)
  result
}

///|
/// `selected_sources` for callers that know it cannot fail (it was computed before).
pub fn Scope::selected_sources_or_empty(
  self : Scope,
) -> Map[String, (@core.Expr, Source)] {
  self.selected_sources() catch {
    _ => {}
  }
}

///|
pub fn Scope::references(self : Scope) -> Array[(String, @core.Expr)] {
  match self.references_ {
    Some(r) => return r
    None => ()
  }
  let refs = []
  for table in self.tables() {
    refs.push((table.alias_or_name(), table))
  }
  for expression in self.derived_tables().iter().concat(self.udtfs().iter()) {
    refs.push(
      (
        get_source_alias(expression),
        if expression.has("pivots") {
          expression
        } else {
          expression.unnest()
        },
      ),
    )
  }
  self.references_ = Some(refs)
  refs
}

///|
/// Columns that appear to reference sources in outer scopes.
pub fn Scope::external_columns(self : Scope) -> Array[@core.Expr] {
  match self.external_columns_ {
    Some(c) => return c
    None => ()
  }
  let result = if self.expression.kind.is_a(SetOperation) &&
    self.set_operation_scopes.length() == 2 {
    let left = self.set_operation_scopes[0]
    let right = self.set_operation_scopes[1]
    left.external_columns() + right.external_columns()
  } else {
    let local_source_names : @set.Set[String] = @set.new()
    for r in self.references() {
      local_source_names.add(r.0)
    }
    let semi = self.semi_or_anti_join_tables()
    self
    .columns()
    .filter(c => {
      let t = c.text("table")
      !local_source_names.contains(t) && !semi.contains(t)
    })
  }
  self.external_columns_ = Some(result)
  result
}

///|
/// Columns in this scope that are not external.
pub fn Scope::local_columns(self : Scope) -> Array[@core.Expr] {
  match self.local_columns_ {
    Some(c) => return c
    None => ()
  }
  let ids : @set.Set[Int] = @set.new()
  for c in self.external_columns() {
    ids.add(c.uid)
  }
  let result = self.columns().filter(c => !ids.contains(c.uid))
  self.local_columns_ = Some(result)
  result
}

///|
pub fn Scope::unqualified_columns(self : Scope) -> Array[@core.Expr] {
  self.columns().filter(c => c.text("table") == "")
}

///|
pub fn Scope::pivots(self : Scope) -> Array[@core.Expr] {
  match self.pivots_ {
    Some(p) => return p
    None => ()
  }
  let result = []
  for r in self.references() {
    for p in r.1.list("pivots") {
      result.push(p)
    }
  }
  self.pivots_ = Some(result)
  result
}

///|
pub fn Scope::source_columns(self : Scope, source_name : String) -> Array[@core.Expr] {
  self.columns().filter(c => c.text("table") == source_name)
}

///|
pub fn Scope::is_subquery(self : Scope) -> Bool {
  self.scope_type == SubqueryScope
}

///|
pub fn Scope::is_derived_table(self : Scope) -> Bool {
  self.scope_type == DerivedTableScope
}

///|
pub fn Scope::is_set_operation(self : Scope) -> Bool {
  self.scope_type == SetOperationScope
}

///|
pub fn Scope::is_cte(self : Scope) -> Bool {
  self.scope_type == CteScope
}

///|
pub fn Scope::is_root(self : Scope) -> Bool {
  self.scope_type == Root
}

///|
pub fn Scope::is_udtf(self : Scope) -> Bool {
  self.scope_type == UdtfScope
}

///|
pub fn Scope::is_correlated_subquery(self : Scope) -> Bool {
  self.can_be_correlated && !self.external_columns().is_empty()
}

///|
/// Rename a source in this scope.
pub fn Scope::rename_source(self : Scope, old_name : String?, new_name : String) -> Unit {
  let old_name = match old_name {
    Some(n) => n
    None => ""
  }
  match self.sources.get(old_name) {
    Some(s) => {
      self.sources.remove(old_name)
      self.sources[new_name] = s
    }
    None => ()
  }
}

///|
pub fn Scope::add_source(self : Scope, name : String, source : Source) -> Unit {
  self.sources[name] = source
  self.clear_cache()
}

///|
pub fn Scope::remove_source(self : Scope, name : String) -> Unit {
  self.sources.remove(name)
  self.clear_cache()
}

///|
/// Traverse the scope tree from this node, in DFS post-order.
pub fn Scope::traverse(self : Scope) -> Array[Scope] {
  let stack = [self]
  let result = []
  while stack.pop() is Some(scope) {
    result.push(scope)
    for s in scope.cte_scopes {
      stack.push(s)
    }
    for s in scope.set_operation_scopes {
      stack.push(s)
    }
    for s in scope.table_scopes {
      stack.push(s)
    }
    for s in scope.subquery_scopes {
      stack.push(s)
    }
  }
  result.rev_in_place()
  result
}

///|
/// Identity key of a source (Python `id(source)`).
pub fn Source::key(self : Source) -> Int {
  match self {
    TableSource(t) => t.uid * 2
    ScopeSource(s) => s.id * 2 + 1
  }
}

///|
/// Identity key of a scope as a source (`Source::key` of `ScopeSource(scope)`).
pub fn Scope::key(self : Scope) -> Int {
  self.id * 2 + 1
}

///|
/// Count the number of times each source in this tree is referenced
/// (keyed by `Source::key`).
pub fn Scope::ref_count(self : Scope) -> Map[Int, Int] {
  let counts : Map[Int, Int] = {}
  fn bump(s : Source) {
    let k = s.key()
    counts[k] = counts.get_or_default(k, 0) + 1
  }

  for scope in self.traverse() {
    for _, v in scope.selected_sources_or_empty() {
      bump(v.1)
    }
    for name in scope.semi_anti_join_tables_ {
      match scope.sources.get(name) {
        Some(s) => bump(s)
        None => ()
      }
    }
  }
  counts
}

///|
/// Traverse an expression by its "scopes", in depth-first post-order.
pub fn traverse_scope(
  expression : @core.Expr,
) -> Array[Scope] raise @core.SqlglotError {
  if expression.kind.is_any([Query, DDL, DML]) {
    let out = []
    traverse_scope_impl(Scope::new(expression), out)
    out
  } else {
    []
  }
}

///|
/// Build a scope tree, returning the root scope.
pub fn build_scope(expression : @core.Expr) -> Scope? raise @core.SqlglotError {
  traverse_scope(expression).last()
}

///|
fn traverse_scope_impl(
  scope : Scope,
  out : Array[Scope],
) -> Unit raise @core.SqlglotError {
  let expression = scope.expression
  if expression.kind.is_a(Select) {
    traverse_select(scope, out)
  } else if expression.kind.is_a(SetOperation) {
    traverse_ctes(scope, out)
    traverse_set_operation(scope, out)
    return
  } else if expression.kind.is_a(Subquery) {
    if scope.is_root() {
      traverse_select(scope, out)
    } else {
      traverse_subqueries(scope, out)
    }
  } else if expression.kind.is_a(Table) {
    traverse_tables(scope, out)
  } else if expression.kind.is_a(UDTF) {
    traverse_udtfs(scope, out)
  } else if expression.kind.is_a(DDL) {
    match expression.arg("expression") {
      Some(ddl_expression) if ddl_expression.kind.is_a(Query) => {
        traverse_ctes(scope, out)
        traverse_scope_impl(
          Scope::new(ddl_expression, cte_sources=scope.cte_sources),
          out,
        )
      }
      _ => ()
    }
    return
  } else if expression.kind.is_a(DML) {
    traverse_ctes(scope, out)
    let relations = []
    match expression.arg("from_") {
      Some(f) if f.kind.is_a(From) =>
        match f.this() {
          Some(t) => relations.push(t)
          None => ()
        }
      _ => ()
    }
    match expression.get("using") {
      Some(List(_)) => relations.append(expression.list("using"))
      Some(Node(u)) => relations.push(u)
      _ => ()
    }
    for relation in relations {
      if relation.kind.is_a(Table) {
        traverse_scope_impl(
          Scope::new(relation, cte_sources=scope.cte_sources),
          out,
        )
      }
    }
    for query in find_all_in_scope(expression, [Query]).collect() {
      if parent_is(query, [CTE, Subquery]) {
        continue
      }
      if is_from_or_join(query) {
        match query.parent {
          Some(p) if p.kind.is_a(Join) && parent_is(p, [Subquery, Table]) =>
            continue
          _ => ()
        }
        traverse_scope_impl(
          Scope::new(query, cte_sources=scope.cte_sources),
          out,
        )
      } else {
        traverse_scope_impl(scope.branch(query, SubqueryScope), out)
      }
    }
    return
  } else {
    @core.log_warning(
      "Cannot traverse scope \{expr_sql(expression)} with type '\{expression.kind}'",
    )
    return
  }
  out.push(scope)
}

///|
fn traverse_select(scope : Scope, out : Array[Scope]) -> Unit raise @core.SqlglotError {
  traverse_ctes(scope, out)
  traverse_tables(scope, out)
  traverse_subqueries(scope, out)
}

///|
fn traverse_set_operation(
  scope : Scope,
  out : Array[Scope],
) -> Unit raise @core.SqlglotError {
  let mut prev_scope : Scope? = None
  let set_op_scope_stack = [scope]
  let set_op = scope.expression
  let expression_stack : Array[@core.Expr] = []
  match set_op.expression() {
    Some(e) => expression_stack.push(e)
    None => ()
  }
  match set_op.this() {
    Some(e) => expression_stack.push(e)
    None => ()
  }
  while expression_stack.pop() is Some(expression) {
    let set_op_scope = set_op_scope_stack[set_op_scope_stack.length() - 1]
    let new_scope = set_op_scope.branch(
      expression,
      SetOperationScope,
      outer_columns=set_op_scope.outer_columns,
    )
    if expression.kind.is_a(SetOperation) {
      traverse_ctes(new_scope, out)
      set_op_scope_stack.push(new_scope)
      match expression.expression() {
        Some(e) => expression_stack.push(e)
        None => ()
      }
      match expression.this() {
        Some(e) => expression_stack.push(e)
        None => ()
      }
      continue
    }
    let before = out.length()
    traverse_scope_impl(new_scope, out)
    if out.length() == before {
      raise @core.OptimizeError(
        "Cannot build a scope for set operation operand: \{expr_sql(expression)}",
      )
    }
    let branch_scope = out[out.length() - 1]
    match prev_scope {
      Some(prev) => {
        set_op_scope_stack.pop() |> ignore
        set_op_scope.set_operation_scopes = [prev, branch_scope]
        prev_scope = Some(set_op_scope)
        out.push(set_op_scope)
      }
      None => prev_scope = Some(branch_scope)
    }
  }
}

///|
fn traverse_ctes(scope : Scope, out : Array[Scope]) -> Unit raise @core.SqlglotError {
  let sources : Map[String, Source] = {}
  for cte in scope.ctes() {
    let cte_name = cte.alias_()
    match scope.expression.arg("with_") {
      Some(w) if w.has("recursive") =>
        match cte.this() {
          Some(union) if union.kind.is_a(SetOperation) =>
            sources[cte_name] = ScopeSource(
              scope.branch(union.this_(), CteScope),
            )
          _ => ()
        }
      _ => ()
    }
    let before = out.length()
    traverse_scope_impl(
      scope.branch(
        cte.this_(),
        CteScope,
        cte_sources=sources,
        outer_columns=cte.alias_column_names(),
      ),
      out,
    )
    if out.length() > before {
      let child_scope = out[out.length() - 1]
      sources[cte_name] = ScopeSource(child_scope)
      scope.cte_scopes.push(child_scope)
    }
  }
  for k, v in sources {
    scope.sources[k] = v
    scope.cte_sources[k] = v
  }
}

///|
/// We represent (tbl1 JOIN tbl2) as a Subquery, but it's not really a "derived table".
fn is_derived_table(expression : @core.Expr) -> Bool {
  expression.kind.is_a(Subquery) &&
  (expression.alias_() != "" ||
  (match expression.this() {
    Some(t) => is_unwrapped_query(t)
    None => false
  }))
}

///|
/// Determine if `expression` is the FROM or JOIN clause of a SELECT statement.
fn is_from_or_join(expression : @core.Expr) -> Bool {
  let mut parent = expression.parent
  while parent is Some(p) && p.kind == Subquery {
    parent = p.parent
  }
  match parent {
    Some(p) => p.kind == From || p.kind == Join
    None => false
  }
}

///|
fn traverse_tables(scope : Scope, out : Array[Scope]) -> Unit raise @core.SqlglotError {
  let sources : Map[String, Source] = {}
  let expressions : Array[@core.Expr] = []
  match scope.expression.arg("from_") {
    Some(f) =>
      match f.this() {
        Some(t) => expressions.push(t)
        None => ()
      }
    None => ()
  }
  for join in scope.expression.list("joins") {
    match join.this() {
      Some(t) => expressions.push(t)
      None => ()
    }
  }
  if scope.expression.kind.is_any([Table, Subquery]) {
    expressions.push(scope.expression)
  }
  expressions.append(scope.expression.list("laterals"))
  let mut i = 0
  while i < expressions.length() {
    let mut expression = expressions[i]
    i += 1
    if expression.kind.is_a(Final) {
      expression = expression.this_()
    }
    if expression.kind.is_a(Table) {
      let table_name = expression.name()
      let source_name = expression.alias_or_name()
      if scope.sources.contains(table_name) && expression.db() == "" {
        let pivots = expression.list("pivots")
        if !pivots.is_empty() {
          sources[pivots[pivots.length() - 1].alias_()] = TableSource(expression)
        } else {
          sources[source_name] = scope.sources[table_name]
        }
      } else if sources.contains(source_name) {
        sources[@core.find_new_name(n => sources.contains(n), table_name)] = TableSource(
          expression,
        )
      } else {
        sources[source_name] = TableSource(expression)
      }
      if !physical_equal(expression, scope.expression) {
        for join in expression.list("joins") {
          expressions.push(join.this_())
        }
      }
      continue
    }
    if !expression.kind.is_a(DerivedTable) {
      continue
    }
    let node = expression
    let (lateral_sources, scope_type, scopes) = if expression.kind.is_a(UDTF) {
      (Some(sources), UdtfScope, scope.udtf_scopes)
    } else if is_derived_table(expression) {
      if !physical_equal(node, scope.expression) {
        for join in node.list("joins") {
          expressions.push(join.this_())
        }
      }
      (None, DerivedTableScope, scope.derived_table_scopes)
    } else {
      expressions.push(node.this_())
      if !physical_equal(node, scope.expression) {
        for join in node.list("joins") {
          expressions.push(join.this_())
        }
      }
      continue
    }
    let before = out.length()
    let child_out = []
    traverse_scope_impl(
      scope.branch(
        node,
        scope_type,
        lateral_sources?,
        outer_columns=node.alias_column_names(),
      ),
      child_out,
    )
    for child in child_out {
      out.push(child)
      sources[get_source_alias(node)] = ScopeSource(child)
    }
    if out.length() > before {
      let child_scope = out[out.length() - 1]
      scopes.push(child_scope)
      scope.table_scopes.push(child_scope)
    }
  }
  for k, v in sources {
    scope.sources[k] = v
  }
}

///|
fn traverse_subqueries(scope : Scope, out : Array[Scope]) -> Unit raise @core.SqlglotError {
  for subquery in scope.subqueries() {
    let before = out.length()
    traverse_scope_impl(scope.branch(subquery, SubqueryScope), out)
    if out.length() > before {
      scope.subquery_scopes.push(out[out.length() - 1])
    }
  }
}

///|
fn traverse_udtfs(scope : Scope, out : Array[Scope]) -> Unit raise @core.SqlglotError {
  let udtf_expressions = if scope.expression.kind.is_a(Unnest) {
    scope.expression.expressions()
  } else if scope.expression.kind.is_a(Lateral) {
    @core.opt_list(scope.expression.this())
  } else {
    []
  }
  let sources : Map[String, Source] = {}
  for expression in udtf_expressions {
    if expression.kind.is_a(Subquery) {
      let child_out = []
      traverse_scope_impl(
        scope.branch(
          expression,
          SubqueryScope,
          outer_columns=expression.alias_column_names(),
        ),
        child_out,
      )
      for child in child_out {
        out.push(child)
        sources[get_source_alias(expression)] = ScopeSource(child)
      }
      if !child_out.is_empty() {
        scope.subquery_scopes.push(child_out[child_out.length() - 1])
      }
    }
  }
  for k, v in sources {
    scope.sources[k] = v
  }
}

///|
/// Visits all nodes in the syntax tree, stopping at nodes that start child scopes.
pub fn walk_in_scope(
  expression : @core.Expr,
  prune? : (@core.Expr) -> Bool,
) -> Iter[@core.Expr] {
  // Each frame is a nested `walk_in_scope` call: (root, stack)
  let frames : Array[(@core.Expr, Array[@core.Expr])] = [(expression, [expression])]
  let mut pending : (@core.Expr, @core.Expr, Bool)? = None
  Iter::new(fn() {
    match pending {
      Some((node, root, is_top)) => {
        pending = None
        let mut expand = true
        if !physical_equal(node, root) &&
          node.kind.is_any([CTE, Query]) &&
          (node.kind.is_a(CTE) ||
          (parent_is(node, [From, Join]) && is_derived_table(node)) ||
          parent_is(node, [UDTF]) ||
          is_unwrapped_query(node)) {
          expand = false
          if node.kind.is_any([Subquery, UDTF]) {
            let sub = []
            for key in ["joins", "laterals", "pivots"] {
              for arg in node.list(key) {
                sub.push(arg)
              }
            }
            sub.rev_in_place()
            for arg in sub {
              frames.push((arg, [arg]))
            }
          }
        }
        if expand {
          // only the top-level walk is pruned
          let pruned = is_top &&
            (match prune {
              Some(p) => p(node)
              None => false
            })
          if !pruned {
            // the frame that produced `node` is identified by its root
            for i = frames.length() - 1; i >= 0; i = i - 1 {
              if physical_equal(frames[i].0, root) {
                for v in node.iter_expressions(reverse=true) {
                  frames[i].1.push(v)
                }
                break
              }
            }
          }
        }
      }
      None => ()
    }
    while frames.length() > 0 {
      let top = frames[frames.length() - 1]
      match top.1.pop() {
        Some(node) => {
          pending = Some((node, top.0, frames.length() == 1))
          return Some(node)
        }
        None => frames.pop() |> ignore
      }
    }
    None
  })
}

///|
/// Returns all nodes in this scope matching at least one of the kinds.
pub fn find_all_in_scope(
  expression : @core.Expr,
  kinds : Array[@core.Kind],
) -> Iter[@core.Expr] {
  walk_in_scope(expression).filter(n => n.kind.is_any(kinds))
}

///|
/// Returns the first node in this scope matching at least one of the kinds.
pub fn find_in_scope(
  expression : @core.Expr,
  kinds : Array[@core.Kind],
) -> @core.Expr? {
  find_all_in_scope(expression, kinds).head()
}

///|
fn get_source_alias(expression : @core.Expr) -> String {
  let alias_name = expression.alias_()
  if alias_name == "" {
    match expression.arg("alias") {
      Some(a) if a.kind.is_a(TableAlias) && a.list("columns").length() == 1 =>
        return a.list("columns")[0].name()
      _ => ()
    }
  }
  alias_name
}
