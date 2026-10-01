// Port of sqlglot/lineage.py.

///|
/// A node of the lineage graph.
pub struct Node {
  id : Int
  name : String
  expression : @core.Expr
  source : @core.Expr
  downstream : Array[Node]
  source_name : String
  reference_node_name : String
  /// Caller-injected per-node data, populated via the `on_node` hook of `lineage`.
  payload : Map[String, Json]
}

///|
let node_counter : Ref[Int] = Ref(0)

///|
fn Node::new(
  name : String,
  expression : @core.Expr,
  source : @core.Expr,
  source_name? : String = "",
  reference_node_name? : String = "",
) -> Node {
  node_counter.val += 1
  {
    id: node_counter.val,
    name,
    expression,
    source,
    downstream: [],
    source_name,
    reference_node_name,
    payload: {},
  }
}

///|
/// Iterates the graph from this node (depth first, each node once).
pub fn Node::walk(self : Node) -> Array[Node] {
  let visited : @set.Set[Int] = @set.new()
  let out = []
  let queue = [self]
  while queue.pop() is Some(node) {
    if visited.contains(node.id) {
      continue
    }
    visited.add(node.id)
    out.push(node)
    let ds = node.downstream.copy()
    ds.rev_in_place()
    for d in ds {
      queue.push(d)
    }
  }
  out
}

///|
fn sql_nc(e : @core.Expr, dialect : @core.Dialect?) -> String raise @core.SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => @core.base_dialect()
  }
  @core.Generator::new(d, comments=false).generate(e)
}

///|
/// A column of a query: by output name, or by position.
priv enum ColumnRef {
  ByName(String)
  ByIndex(Int)
}

///|
fn ColumnRef::to_string(self : ColumnRef) -> String {
  match self {
    ByName(n) => n
    ByIndex(i) => i.to_string()
  }
}

///|
priv struct Ctx {
  dialect : @core.Dialect?
  trim_selects : Bool
  schema : @optimizer.MappingSchema?
  cache : Map[String, Node]
  scope_meta : Map[Int, (Bool, Map[String, @core.Expr])]
  on_node : ((Node) -> Unit)?
}

///|
fn opt_key(s : String?) -> String {
  match s {
    Some(x) => "S" + x
    None => "N"
  }
}

///|
/// Build the lineage graph of output column `column` of a query.
pub fn lineage(
  column : String,
  expression : @core.Expr,
  schema? : @optimizer.MappingSchema,
  sources? : Map[String, @core.Expr],
  dialect? : @core.Dialect,
  scope? : @optimizer.Scope,
  trim_selects? : Bool = true,
  copy? : Bool = true,
  on_node? : (Node) -> Unit,
) -> Node raise @core.SqlglotError {
  let (scope, schema) = prepare(expression, schema, sources, dialect, scope, copy)
  let selectable = scope.expression
  let ctx : Ctx = {
    dialect,
    trim_selects,
    schema: Some(schema),
    cache: {},
    scope_meta: {},
    on_node,
  }
  let column_name = @optimizer.normalize_identifier_str(column, dialect?).name()
  if !selectable.selects().iter().any(s => s.alias_or_name() == column_name) {
    raise @core.SqlglotError::ValueError(
      "Cannot find column '\{column_name}' in query.",
    )
  }
  to_node(ByName(column_name), scope, ctx, None, None, None, None)
}

///|
/// Build the lineage graphs of every output column of a query (with a shared cache).
pub fn lineage_all(
  expression : @core.Expr,
  schema? : @optimizer.MappingSchema,
  sources? : Map[String, @core.Expr],
  dialect? : @core.Dialect,
  scope? : @optimizer.Scope,
  trim_selects? : Bool = true,
  copy? : Bool = true,
  on_node? : (Node) -> Unit,
) -> Map[String, Node] raise @core.SqlglotError {
  let (scope, schema) = prepare(expression, schema, sources, dialect, scope, copy)
  let selectable = scope.expression
  let ctx : Ctx = {
    dialect,
    trim_selects,
    schema: Some(schema),
    cache: {},
    scope_meta: {},
    on_node,
  }
  let result : Map[String, Node] = {}
  for sel in selectable.selects() {
    let name = sel.alias_or_name()
    if name == "" {
      raise @core.SqlglotError::ValueError(
        "Cannot fetch lineage for unnamed projection: \{@optimizer.sql_of(sel, dialect?)}.",
      )
    }
    result[name] = to_node(ByName(name), scope, ctx, None, None, None, None)
  }
  result
}

///|
fn prepare(
  expression : @core.Expr,
  schema : @optimizer.MappingSchema?,
  sources : Map[String, @core.Expr]?,
  dialect : @core.Dialect?,
  scope : @optimizer.Scope?,
  copy : Bool,
) -> (@optimizer.Scope, @optimizer.MappingSchema) raise @core.SqlglotError {
  let mut expression = if copy { expression.copy() } else { expression }
  match sources {
    Some(s) if !s.is_empty() => {
      let srcs : Map[String, @core.Expr] = {}
      for k, v in s {
        srcs[k] = if copy { v.copy() } else { v }
      }
      expression = @optimizer.expand(expression, srcs, dialect?, copy~)
    }
    _ => ()
  }
  let schema = @optimizer.ensure_schema(schema?, dialect?)
  let scope = match scope {
    Some(s) => Some(s)
    None => {
      expression = @optimizer.qualify(
        expression,
        dialect?,
        schema~,
        validate_qualify_columns=false,
        identify=false,
      )
      @optimizer.build_scope(expression)
    }
  }
  let scope = match scope {
    Some(s) => s
    None =>
      raise @core.SqlglotError::ValueError(
        "Cannot build lineage, sql must be SELECT",
      )
  }
  if !scope.expression.kind.is_a(Selectable) {
    raise @core.SqlglotError::ValueError(
      "Cannot build lineage, sql must be a query",
    )
  }
  (scope, schema)
}

///|
fn emit(ctx : Ctx, node : Node) -> Unit {
  match ctx.on_node {
    Some(f) => f(node)
    None => ()
  }
}

///|
fn to_node(
  column : ColumnRef,
  scope : @optimizer.Scope,
  ctx : Ctx,
  scope_name : String?,
  upstream : Node?,
  source_name : String?,
  reference_node_name : String?,
) -> Node raise @core.SqlglotError {
  let cache_key = "\{column.to_string()}|\{scope.id}|\{opt_key(scope_name)}|\{opt_key(source_name)}|\{opt_key(reference_node_name)}"
  match ctx.cache.get(cache_key) {
    Some(cached) => {
      match upstream {
        Some(u) => u.downstream.push(cached)
        None => ()
      }
      return cached
    }
    None => ()
  }
  let selectable = scope.expression
  let select = match column {
    ByIndex(i) => {
      let selects = selectable.selects()
      if i >= selects.length() {
        raise @core.SqlglotError::ValueError(
          "Cannot find column's source with index \{i} in query: \{@optimizer.sql_of(selectable, dialect?=ctx.dialect)}",
        )
      }
      selects[i]
    }
    ByName(name) => {
      let meta = match ctx.scope_meta.get(scope.id) {
        Some(m) => m
        None => {
          let by_name : Map[String, @core.Expr] = {}
          for sel in selectable.selects() {
            if !by_name.contains(sel.alias_or_name()) {
              by_name[sel.alias_or_name()] = sel
            }
          }
          let m = (selectable.is_star(), by_name)
          ctx.scope_meta[scope.id] = m
          m
        }
      }
      match meta.1.get(name) {
        Some(s) => s
        None => if meta.0 { @core.mk0(Star) } else { scope.expression }
      }
    }
  }
  if scope.expression.kind.is_a(Subquery) {
    for inner_scope in scope.subquery_scopes {
      let result = to_node(
        column, inner_scope, ctx, None, upstream, source_name, reference_node_name,
      )
      let is_upstream = match upstream {
        Some(u) => physical_equal(u, result)
        None => false
      }
      if !is_upstream {
        ctx.cache[cache_key] = result
      }
      return result
    }
  }
  if scope.expression.kind.is_a(SetOperation) {
    let name = @core.py_upper(scope.expression.kind.name())
    let created_setop = upstream is None
    let upstream = match upstream {
      Some(u) => u
      None => Node::new(name, select, scope.expression)
    }
    let index = match column {
      ByIndex(i) => i
      ByName(n) => {
        let mut idx = -1
        for i, s in selectable.selects() {
          if s.alias_or_name() == n || s.is_star() {
            idx = i
            break
          }
        }
        idx
      }
    }
    if index == -1 {
      raise @core.SqlglotError::ValueError(
        "Could not find \{column.to_string()} in \{@optimizer.sql_of(scope.expression)}",
      )
    }
    for s in scope.set_operation_scopes {
      to_node(
        ByIndex(index),
        s,
        ctx,
        None,
        Some(upstream),
        source_name,
        reference_node_name,
      )
      |> ignore
    }
    if created_setop {
      ctx.cache[cache_key] = upstream
      emit(ctx, upstream)
    }
    return upstream
  }
  let source = if ctx.trim_selects && scope.expression.kind.is_a(Select) {
    scope.expression.select_([select], append=false, copy=true)
  } else {
    scope.expression
  }
  let node = Node::new(
    match scope_name {
      Some(s) if s != "" => "\{s}.\{column.to_string()}"
      _ => column.to_string()
    },
    select,
    source,
    source_name=source_name.unwrap_or(""),
    reference_node_name=reference_node_name.unwrap_or(""),
  )
  match upstream {
    Some(u) => u.downstream.push(node)
    None => ()
  }
  let subquery_scopes : Map[Int, @optimizer.Scope] = {}
  for s in scope.subquery_scopes {
    subquery_scopes[s.expression.uid] = s
  }
  for subquery in @optimizer.find_all_in_scope(select, [Select, SetOperation]).collect() {
    let subquery_scope = match subquery_scopes.get(subquery.uid) {
      Some(s) => s
      None => continue
    }
    for name in subquery.named_selects() {
      to_node(ByName(name), subquery_scope, ctx, None, Some(node), None, None)
      |> ignore
    }
  }
  if select.kind.is_a(Star) {
    for _, src in scope.sources {
      let src_expr = match src {
        ScopeSource(s) => s.expression
        TableSource(t) => t
      }
      let star_node = Node::new(sql_nc(select, ctx.dialect), src_expr, src_expr)
      node.downstream.push(star_node)
      emit(ctx, star_node)
    }
  }
  let source_columns = []
  for c in @optimizer.find_all_in_scope(select, [Column]) {
    if !source_columns.contains(c) {
      source_columns.push(c)
    }
  }
  let derived_tables = if source.kind.is_a(UDTF) {
    for c in source.find_all([Column]) {
      if !source_columns.contains(c) {
        source_columns.push(c)
      }
    }
    let dts = []
    for _, src in scope.sources {
      match src {
        ScopeSource(s) if s.is_derived_table() =>
          match s.expression.parent {
            Some(p) => dts.push(p)
            None => ()
          }
        _ => ()
      }
    }
    dts
  } else {
    scope.derived_tables()
  }
  let source_names : Map[String, String] = {}
  for dt in derived_tables {
    match dt.comments {
      Some(cs) if !cs.is_empty() && cs[0].has_prefix("source: ") => {
        let parts = @core.py_split_ws(cs[0])
        if parts.length() > 1 {
          source_names[dt.alias()] = parts[1]
        }
      }
      _ => ()
    }
  }
  let mut pivots = scope.pivots()
  if !pivots.is_empty() {
    let same = match (pivots[0].parent, pivots[pivots.length() - 1].parent) {
      (Some(a), Some(b)) => physical_equal(a, b)
      (None, None) => true
      _ => false
    }
    if !same {
      pivots = []
    }
  }
  let (pivot_renames, pivot_column_mapping) = if pivots.is_empty() {
    ({}, [])
  } else {
    pivot_chain_mapping(pivots, scope, ctx.schema)
  }
  for c in source_columns {
    let table = c.table_name()
    let col_source = scope.sources.get(table)
    match col_source {
      Some(ScopeSource(cs)) => {
        let mut ref_name : String? = None
        if cs.scope_type == DerivedTableScope && !source_names.contains(table) {
          ref_name = Some(table)
        } else if cs.scope_type == CteScope {
          ref_name = match scope.selected_sources().get(table) {
            Some((n, _)) => Some(n.name())
            None => None
          }
        }
        let sn = match source_names.get(table) {
          Some(s) if s != "" => Some(s)
          _ => source_name
        }
        to_node(ByName(c.name()), cs, ctx, Some(table), Some(node), sn, ref_name)
        |> ignore
      }
      _ =>
        if !pivots.is_empty() &&
          pivots[pivots.length() - 1].alias_or_name() == c.table_name() {
          let pivot_parent = pivots[pivots.length() - 1].parent
          let parent_name = match pivot_parent {
            Some(p) => Some(p.alias_or_name())
            None => None
          }
          let downstream_columns = []
          let column_name = c.name()
          match assoc_cols(pivot_column_mapping, column_name) {
            Some(cols) =>
              for x in cols {
                downstream_columns.push(x)
              }
            None => {
              let this = match pivot_renames.get(c.name()) {
                Some(r) => @core.to_identifier(r)
                None => c.this_().copy()
              }
              downstream_columns.push(
                @core.mk(Column, [
                  ("this", this),
                  ("table", parent_name.map(n => @core.to_identifier(n))),
                ]),
              )
            }
          }
          for downstream_column0 in downstream_columns {
            let downstream_column = if downstream_column0.table_name() == "" {
              @core.mk(Column, [
                ("this", downstream_column0.this_().copy()),
                ("table", parent_name.map(n => @core.to_identifier(n))),
              ])
            } else {
              downstream_column0
            }
            let table = downstream_column.table_name()
            let mut col_source = scope.sources.get(table)
            match col_source {
              Some(TableSource(t)) if t.db() == "" =>
                match scope.cte_sources.get(t.name()) {
                  Some(s) => col_source = Some(s)
                  None => ()
                }
              _ => ()
            }
            match col_source {
              Some(ScopeSource(cs)) => {
                let sn = match source_names.get(table) {
                  Some(s) if s != "" => Some(s)
                  _ => source_name
                }
                to_node(
                  ByName(downstream_column.name()),
                  cs,
                  ctx,
                  Some(table),
                  Some(node),
                  sn,
                  reference_node_name,
                )
                |> ignore
              }
              _ => {
                let col_expr = match col_source {
                  Some(TableSource(t)) => t
                  _ => @core.mk0(Placeholder)
                }
                let pivot_leaf = Node::new(
                  sql_nc(downstream_column, None),
                  col_expr,
                  col_expr,
                )
                node.downstream.push(pivot_leaf)
                emit(ctx, pivot_leaf)
              }
            }
          }
        } else {
          let col_expr = match col_source {
            Some(TableSource(t)) => t
            _ => @core.mk0(Placeholder)
          }
          let leaf = Node::new(sql_nc(c, None), col_expr, col_expr)
          node.downstream.push(leaf)
          emit(ctx, leaf)
        }
    }
  }
  ctx.cache[cache_key] = node
  emit(ctx, node)
  node
}

///|
fn assoc_cols(
  m : Array[(String, Array[@core.Expr])],
  k : String,
) -> Array[@core.Expr]? {
  for kv in m {
    if kv.0 == k {
      return Some(kv.1)
    }
  }
  None
}

///|
fn assoc_set(
  m : Array[(String, Array[@core.Expr])],
  k : String,
  v : Array[@core.Expr],
) -> Unit {
  for i, kv in m {
    if kv.0 == k {
      m[i] = (k, v)
      return
    }
  }
  m.push((k, v))
}

///|
/// The columns the first operator of a pivot chain sees.
fn pre_pivot_columns(
  pivot : @core.Expr,
  scope : @optimizer.Scope,
  schema : @optimizer.MappingSchema?,
) -> Array[String] raise @core.SqlglotError {
  let mut columns = []
  match pivot.parent {
    Some(parent) if parent.kind.is_a(DerivedTable) &&
      (match parent.this() {
        Some(t) => t.kind.is_a(Query)
        None => false
      }) => columns = parent.this_().named_selects()
    Some(parent) if parent.kind.is_a(Table) => {
      let cte_source = if parent.db() == "" {
        scope.cte_sources.get(parent.name())
      } else {
        None
      }
      match cte_source {
        Some(ScopeSource(s)) if s.expression.kind.is_a(Query) =>
          columns = s.expression.named_selects()
        _ =>
          match schema {
            Some(sch) => columns = sch.column_names(parent, only_visible=true)
            None => ()
          }
      }
    }
    _ => ()
  }
  if columns.contains("*") {
    []
  } else {
    columns
  }
}

///|
/// Fold a chain of (UN)PIVOT operators into a single view of its output.
fn pivot_chain_mapping(
  pivots : Array[@core.Expr],
  scope : @optimizer.Scope,
  schema : @optimizer.MappingSchema?,
) -> (Map[String, String], Array[(String, Array[@core.Expr])]) raise @core.SqlglotError {
  let mut available = pre_pivot_columns(pivots[0], scope, schema)
  let mut renames : Map[String, String] = {}
  let mut mapping : Array[(String, Array[@core.Expr])] = []
  for pivot in pivots {
    let step_renames = if !pivot.alias_column_names().is_empty() &&
      !available.is_empty() {
      @optimizer.pivot_output_columns(pivot, available)
    } else {
      []
    }
    let mut step_mapping = pivot_column_mapping(pivot)
    if !step_renames.is_empty() {
      let sm = []
      for kv in step_renames {
        let (post, pre) = kv
        match assoc_cols(step_mapping, pre) {
          Some(cols) => assoc_set(sm, post, cols)
          None => ()
        }
      }
      step_mapping = sm
    }
    let mapping_now = mapping
    let renames_now = renames
    let resolve = fn(col : @core.Expr) -> Array[@core.Expr] {
      match assoc_cols(mapping_now, col.name()) {
        Some(cols) => cols
        None =>
          match renames_now.get(col.name()) {
            Some(r) => [@core.mk1(Column, @core.to_identifier(r))]
            None => [col]
          }
      }
    }
    let composed : Array[(String, Array[@core.Expr])] = []
    for kv in step_mapping {
      let resolved = []
      for col in kv.1 {
        for r in resolve(col) {
          resolved.push(r)
        }
      }
      assoc_set(composed, kv.0, resolved)
    }
    let consumed : @set.Set[String] = @set.new()
    for kv in step_mapping {
      for col in kv.1 {
        consumed.add(col.name())
      }
    }
    let pre_to_post : Map[String, String] = {}
    for kv in step_renames {
      pre_to_post[kv.1] = kv.0
    }
    for kv in mapping {
      if !consumed.contains(kv.0) {
        let key = pre_to_post.get(kv.0).unwrap_or(kv.0)
        if assoc_cols(composed, key) is None {
          composed.push((key, kv.1))
        }
      }
    }
    if !step_renames.is_empty() {
      let nr : Map[String, String] = {}
      for kv in step_renames {
        nr[kv.0] = renames.get(kv.1).unwrap_or(kv.1)
      }
      renames = nr
    }
    mapping = composed
    available = if available.is_empty() {
      []
    } else {
      @optimizer.pivot_output_columns(pivot, available).map(kv => kv.0)
    }
  }
  (renames, mapping)
}

///|
/// Map each (UN)PIVOT output column name to the source columns it's derived from.
fn pivot_column_mapping(pivot : @core.Expr) -> Array[(String, Array[@core.Expr])] {
  let mapping : Array[(String, Array[@core.Expr])] = []
  if pivot.has("unpivot") {
    let value_columns = []
    for e in pivot.expressions() {
      for i in e.find_all([Identifier]) {
        value_columns.push(i)
      }
    }
    for vc in value_columns {
      assoc_set(mapping, vc.name(), [])
    }
    for field in pivot.list("fields") {
      if !field.kind.is_a(In) {
        continue
      }
      let field_name = field.this_().name()
      if assoc_cols(mapping, field_name) is None {
        mapping.push((field_name, []))
      }
      let name_columns = assoc_cols(mapping, field_name).unwrap()
      for entry in field.expressions() {
        let entry_columns = entry.find_all([Column]).collect()
        for c in entry_columns {
          name_columns.push(c)
        }
        if entry_columns.length() == value_columns.length() {
          for i, vc in value_columns {
            assoc_cols(mapping, vc.name()).unwrap().push(entry_columns[i])
          }
        } else {
          for vc in value_columns {
            let target = assoc_cols(mapping, vc.name()).unwrap()
            for c in entry_columns {
              target.push(c)
            }
          }
        }
      }
    }
    return mapping
  }
  let pivot_columns = pivot.list("columns")
  let pivot_aggs_count = pivot.expressions().length()
  for i, agg in pivot.expressions() {
    let agg_cols = agg.find_all([Column]).collect()
    let mut col_index = i
    while col_index < pivot_columns.length() {
      assoc_set(mapping, pivot_columns[col_index].name(), agg_cols)
      col_index += pivot_aggs_count
    }
  }
  mapping
}

///|
/// Renders the lineage graph rooted at `self` as HTML (vis.js).
pub fn Node::to_html(
  self : Node,
  dialect? : @core.Dialect,
  imports? : Bool = true,
) -> String raise @core.SqlglotError {
  let nodes : Array[Json] = []
  let edges : Array[Json] = []
  for node in self.walk() {
    let (label, title, group) = if node.expression.kind.is_a(Table) {
      let this = @optimizer.sql_of(node.expression.this_())
      ("FROM \{this}", "<pre>SELECT \{node.name} FROM \{this}</pre>", 1)
    } else {
      let label = @optimizer.sql_of(node.expression, dialect?, pretty=true)
      let target = node.expression
      let source = node.source.transform(
        n => if physical_equal(n, target) {
          Some(
            @core.mk(Tag, [("this", n), ("prefix", "<b>"), ("postfix", "</b>")]),
          )
        } else {
          Some(n)
        },
        copy=false,
      )
      let src = @optimizer.sql_of(source, dialect?, pretty=true)
      (label, "<pre>\{src}</pre>", 0)
    }
    nodes.push({
      "id": node.id.to_json(),
      "label": label.to_json(),
      "title": title.to_json(),
      "group": group.to_json(),
    })
    for d in node.downstream {
      edges.push({ "from": node.id.to_json(), "to": d.id.to_json() })
    }
  }
  let options : Json = {
    "height": "500px",
    "width": "100%",
    "layout": {
      "hierarchical": {
        "enabled": true,
        "nodeSpacing": 200,
        "sortMethod": "directed",
      },
    },
    "interaction": { "dragNodes": false, "selectable": false },
    "physics": { "enabled": false },
    "edges": { "arrows": "to" },
    "nodes": {
      "font": "20px monaco",
      "shape": "box",
      "widthConstraint": { "maximum": 300 },
    },
  }
  let imports_html = if imports {
    "<script type=\"text/javascript\" src=\"https://unpkg.com/vis-data@latest/peer/umd/vis-data.min.js\"></script>\n  <script type=\"text/javascript\" src=\"https://unpkg.com/vis-network@latest/peer/umd/vis-network.min.js\"></script>\n  <link rel=\"stylesheet\" type=\"text/css\" href=\"https://unpkg.com/vis-network/styles/vis-network.min.css\" />"
  } else {
    ""
  }
  let nodes_json = Json::array(nodes).stringify()
  let edges_json = Json::array(edges).stringify()
  let options_json = options.stringify()
  $|<div>
  $|  <div id="sqlglot-lineage"></div>
  $|  \{imports_html}
  $|  <script type="text/javascript">
  $|    var nodes = new vis.DataSet(\{nodes_json})
  $|    nodes.forEach(row => row["title"] = new DOMParser().parseFromString(row["title"], "text/html").body.childNodes[0])
  $|
  $|    new vis.Network(
  $|        document.getElementById("sqlglot-lineage"),
  $|        {
  $|            nodes: nodes,
  $|            edges: new vis.DataSet(\{edges_json})
  $|        },
  $|        \{options_json},
  $|    )
  $|  </script>
  $|</div>
}
