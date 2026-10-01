// Port of sqlglot/optimizer/annotate_types.py.

///|
/// A type value: either a bare `DType` or a `DataType` expression
/// (Python's `exp.DataType | exp.DType`).
pub(all) enum TType {
  D(@core.DType)
  T(@core.Expr)
}

///|
/// An entry of the expression metadata (Python `{"returns": ...}` / `{"annotator": ...}`).
pub(all) enum TypeSpec {
  Returns(TType)
  Annotator((TypeAnnotator, @core.Expr) -> Unit raise @core.SqlglotError)
}

///|
/// Maps an expression kind to its type inference rule.
pub type ExprMetadata = Map[@core.Kind, TypeSpec]

///|
/// A binary coercion function: takes both sides and returns the resulting type.
pub type BinaryCoercion = (@core.Expr, @core.Expr) -> TType?

///|
/// EXTRACT/DATE_PART specifiers that return BIGINT instead of INT.
let bigint_extract_date_parts : Array[String] = [
  "EPOCH_SECOND", "EPOCH_MILLISECOND", "EPOCH_MICROSECOND", "EPOCH_NANOSECOND", "NANOSECOND",
]

///|
fn TType::this(self : TType) -> @core.DType? {
  match self {
    D(d) => Some(d)
    T(e) => e.datatype_this()
  }
}

///|
fn TType::to_expr(self : TType) -> @core.Expr {
  match self {
    D(d) => @core.datatype_of(d)
    T(e) => e
  }
}

///|
/// The type of an expression as a `TType`.
fn type_of(e : @core.Expr) -> TType? {
  e.get_type().map(t => T(t))
}

///|
/// The DType of an expression's type, or UNKNOWN.
fn type_this_or_unknown(e : @core.Expr) -> @core.DType {
  match e.get_type() {
    Some(t) =>
      match t.datatype_this() {
        Some(d) => d
        None => UNKNOWN
      }
    None => UNKNOWN
  }
}

///|
fn coerce_date_literal(l : @core.Expr, unit : @core.Expr?) -> TType {
  let date_text = l.name()
  let is_iso_date_ = is_iso_date(date_text)
  if is_iso_date_ && is_date_unit(unit) {
    return D(DATE)
  }
  if is_iso_date_ || is_iso_datetime(date_text) {
    return D(DATETIME)
  }
  D(UNKNOWN)
}

///|
fn coerce_date(l : @core.Expr, unit : @core.Expr?) -> TType {
  if l.is_type([DATE]) && !is_date_unit(unit) {
    return D(DATETIME)
  }
  match l.get_type() {
    Some(t) => T(t)
    None => D(UNKNOWN)
  }
}

///|
fn build_default_coerces_to() -> Map[@core.DType, @set.Set[@core.DType]] {
  let text_precedence : Array[@core.DType] = [TEXT, NVARCHAR, VARCHAR, NCHAR, CHAR]
  let numeric_precedence : Array[@core.DType] = [
    DECFLOAT, DOUBLE, FLOAT, BIGDECIMAL, DECIMAL, BIGINT, INT, SMALLINT, TINYINT,
  ]
  let timelike_precedence : Array[@core.DType] = [
    TIMESTAMPLTZ, TIMESTAMPTZ, TIMESTAMP, DATETIME, DATE,
  ]
  let result : Map[@core.DType, @set.Set[@core.DType]] = Map([])
  for type_precedence in [text_precedence, numeric_precedence, timelike_precedence] {
    let coerces_to : @set.Set[@core.DType] = @set.Set([])
    for data_type in type_precedence {
      result[data_type] = coerces_to.copy()
      coerces_to.add(data_type)
    }
  }
  result
}

///|
/// `TypeAnnotator.COERCES_TO`: highest-to-lowest type precedence (Spark ANSI).
pub let default_coerces_to : Map[@core.DType, @set.Set[@core.DType]] = build_default_coerces_to()

///|
/// Deep copy of a coercion map.
pub fn copy_coerces_to(
  m : Map[@core.DType, @set.Set[@core.DType]],
) -> Map[@core.DType, @set.Set[@core.DType]] {
  let out : Map[@core.DType, @set.Set[@core.DType]] = Map([])
  for k, v in m {
    out[k] = v.copy()
  }
  out
}

///|
fn swap_all(
  coercions : Array[((@core.DType, @core.DType), BinaryCoercion)],
  out : Map[(@core.DType, @core.DType), BinaryCoercion],
) -> Unit {
  for c in coercions {
    out[c.0] = c.1
  }
  for c in coercions {
    let (a, b) = c.0
    let f = c.1
    out[(b, a)] = (l, r) => f(r, l)
  }
}

///|
fn build_binary_coercions() -> Map[(@core.DType, @core.DType), BinaryCoercion] {
  let out : Map[(@core.DType, @core.DType), BinaryCoercion] = Map([])
  swap_all(
    @core.dtype_text_types.map(t => (
      (t, @core.DType::INTERVAL),
      fn(l : @core.Expr, r : @core.Expr) -> TType? {
        Some(coerce_date_literal(l, r.arg("unit")))
      },
    )),
    out,
  )
  let text_numeric = []
  for text in @core.dtype_text_types {
    for numeric in @core.dtype_numeric_types {
      text_numeric.push((
        (text, numeric),
        fn(l : @core.Expr, r : @core.Expr) -> TType? {
          match l.get_type() {
            Some(lt) if (match lt.datatype_this() {
                Some(d) => @core.dtype_numeric_types.contains(d)
                None => false
              }) => Some(T(lt))
            _ => type_of(r)
          }
        },
      ))
    }
  }
  swap_all(text_numeric, out)
  swap_all(
    [
      (
        (DATE, INTERVAL),
        fn(l : @core.Expr, r : @core.Expr) -> TType? {
          Some(coerce_date(l, r.arg("unit")))
        },
      ),
    ],
    out,
  )
  out
}

///|
/// `TypeAnnotator.BINARY_COERCIONS`.
pub let default_binary_coercions : Map[
  (@core.DType, @core.DType),
  BinaryCoercion,
] = build_binary_coercions()

///|
/// Infers the types of expressions.
pub struct TypeAnnotator {
  schema : MappingSchema
  dialect : @core.Dialect
  expression_metadata : ExprMetadata
  coerces_to : Map[@core.DType, @set.Set[@core.DType]]
  binary_coercions : Map[(@core.DType, @core.DType), BinaryCoercion]
  priv visited : @set.Set[Int]
  priv null_expressions : Map[Int, @core.Expr]
  priv supports_null_type : Bool
  priv setop_column_types : Map[Int, Array[(String, TType)]]
  priv overwrite_types : Bool
  priv scope_source_selects : Map[(Int, String), Map[String, TType?]]
}

///|
pub fn TypeAnnotator::new(
  schema : MappingSchema,
  expression_metadata? : ExprMetadata,
  coerces_to? : Map[@core.DType, @set.Set[@core.DType]],
  binary_coercions? : Map[(@core.DType, @core.DType), BinaryCoercion],
  overwrite_types? : Bool = true,
) -> TypeAnnotator {
  let dialect = schema.dialect
  let expression_metadata = match expression_metadata {
    Some(m) if !m.is_empty() => m
    _ => dialect_expression_metadata(dialect)
  }
  let coerces_to = match coerces_to {
    Some(c) if !c.is_empty() => c
    _ => {
      let dc = dialect_coerces_to(dialect)
      if dc.is_empty() {
        default_coerces_to
      } else {
        dc
      }
    }
  }
  {
    schema,
    dialect,
    expression_metadata,
    coerces_to,
    binary_coercions: match binary_coercions {
      Some(b) if !b.is_empty() => b
      _ => default_binary_coercions
    },
    visited: @set.Set([]),
    null_expressions: {},
    supports_null_type: dialect.cfg.supports_null_type,
    setop_column_types: {},
    overwrite_types,
    scope_source_selects: {},
  }
}

///|
/// Infers the types of an expression, annotating its AST accordingly.
pub fn annotate_types(
  expression : @core.Expr,
  schema? : MappingSchema,
  expression_metadata? : ExprMetadata,
  coerces_to? : Map[@core.DType, @set.Set[@core.DType]],
  dialect? : @core.Dialect,
  overwrite_types? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let schema = ensure_schema(schema?, dialect?)
  TypeAnnotator::new(schema, expression_metadata?, coerces_to?, overwrite_types~).annotate(
    expression,
  )
}

///|
pub fn TypeAnnotator::clear(self : TypeAnnotator) -> Unit {
  self.visited.clear()
  self.null_expressions.clear()
  self.setop_column_types.clear()
  self.scope_source_selects.clear()
}

///|
/// Evicts `expression` (or its subtree, if `deep`) from the annotation caches.
pub fn TypeAnnotator::uncache(
  self : TypeAnnotator,
  expression : @core.Expr,
  deep? : Bool = true,
) -> Unit {
  let nodes = if deep { expression.walk().collect() } else { [expression] }
  for node in nodes {
    self.visited.remove(node.uid)
    self.null_expressions.remove(node.uid)
    self.setop_column_types.remove(node.uid)
  }
}

///|
/// Sets the type of `expression` (Python `_set_type`).
pub fn TypeAnnotator::set_type(
  self : TypeAnnotator,
  expression : @core.Expr,
  target_type : TType?,
) -> Unit {
  let prev_type = expression.get_type()
  let dtype = match target_type {
    Some(D(d)) => @core.datatype_of(d)
    Some(T(t)) => t
    None => @core.datatype_of(UNKNOWN)
  }
  expression.set_type(Some(dtype))
  self.visited.add(expression.uid)
  let this = match expression.get_type() {
    Some(t) => t.datatype_this()
    None => None
  }
  if !self.supports_null_type && this == Some(NULL) {
    self.null_expressions[expression.uid] = expression
  } else {
    match prev_type {
      Some(p) if p.datatype_this() == Some(NULL) =>
        self.null_expressions.remove(expression.uid)
      _ => ()
    }
  }
}

///|
/// Sets the type of `expression` to a `DType`.
pub fn TypeAnnotator::set_dtype(
  self : TypeAnnotator,
  expression : @core.Expr,
  dtype : @core.DType,
) -> Unit {
  self.set_type(expression, Some(D(dtype)))
}

///|
/// Sets the type of `expression` to a type expression (or UNKNOWN when `None`).
pub fn TypeAnnotator::set_type_expr(
  self : TypeAnnotator,
  expression : @core.Expr,
  t : @core.Expr?,
) -> Unit {
  self.set_type(expression, t.map(x => T(x)))
}

///|
pub fn TypeAnnotator::annotate(
  self : TypeAnnotator,
  expression : @core.Expr,
  annotate_scope? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  if annotate_scope {
    for scope in traverse_scope(expression) {
      self.annotate_scope(scope)
    }
  }
  self.annotate_expression(expression, None)
  for _, expr in self.null_expressions.copy() {
    self.set_type(expr, Some(D(self.dialect.cfg.default_null_type)))
  }
  expression
}

///|
fn TypeAnnotator::get_scope_source_selects(
  self : TypeAnnotator,
  scope : Scope,
  source_name : String,
) -> Map[String, TType?] raise @core.SqlglotError {
  let key = (scope.id, source_name)
  match self.scope_source_selects.get(key) {
    Some(s) => return s
    None => ()
  }
  let mut selects : Map[String, TType?] = Map([])
  let source = scope.sources.get(source_name)
  match source {
    Some(ScopeSource(s)) => selects = self.get_source_scope_selects(s)
    _ => {
      let pivots = match source {
        Some(TableSource(t)) => t.list("pivots")
        _ => scope.pivots()
      }
      if !pivots.is_empty() &&
        pivots[pivots.length() - 1].alias_or_name() == source_name {
        let parent = pivots[pivots.length() - 1].parent
        let mut parent_source = match parent {
          Some(p) => scope.sources.get(p.alias_or_name())
          None => None
        }
        match (parent_source, parent) {
          (Some(ScopeSource(_)), _) => ()
          (_, Some(p)) if p.kind.is_a(Table) && p.db() == "" =>
            parent_source = scope.cte_sources.get(p.name())
          _ => ()
        }
        let mut src_types : Map[String, TType?] = match (parent_source, parent) {
          (Some(ScopeSource(ps)), _) => self.get_source_scope_selects(ps)
          (_, Some(p)) if p.kind.is_a(Table) => {
            let m : Map[String, TType?] = Map([])
            match self.schema.find_column_types(p) {
              Some(cols) =>
                for k, v in cols {
                  m[k] = v.map(x => T(x))
                }
              None => ()
            }
            m
          }
          _ => {}
        }
        for pivot in pivots {
          src_types = if pivot.has("unpivot") {
            self.get_unpivot_column_types(pivot, src_types)
          } else {
            self.get_pivot_column_types(pivot, src_types)
          }
        }
        selects = src_types
      }
    }
  }
  self.scope_source_selects[key] = selects
  selects
}

///|
fn TypeAnnotator::get_source_scope_selects(
  self : TypeAnnotator,
  source : Scope,
) -> Map[String, TType?] raise @core.SqlglotError {
  let expression = source.expression
  if expression.kind.is_a(UDTF) {
    let values = if expression.kind.is_a(Lateral) {
      match expression.this() {
        Some(t) if t.kind.is_a(Explode) => @core.opt_list(t.this())
        _ => []
      }
    } else if expression.kind.is_a(Unnest) {
      [expression]
    } else if !expression.kind.is_a(TableFromRows) {
      match expression.expressions().get(0) {
        Some(e) => e.expressions()
        None => []
      }
    } else {
      []
    }
    if values.is_empty() {
      return {}
    }
    let alias_column_names = expression.alias_column_names()
    let exp_type = if expression.kind.is_a(Unnest) {
      expression.get_type()
    } else if expression.kind.is_a(Lateral) &&
      (match expression.this() {
        Some(t) => t.kind.is_a(Explode)
        None => false
      }) {
      expression.this_().get_type()
    } else {
      None
    }
    match exp_type {
      Some(st) if st.is_type([STRUCT]) => {
        let out : Map[String, TType?] = Map([])
        for col_def in st.expressions() {
          if col_def.kind.is_a(ColumnDef) {
            match col_def.arg("kind") {
              Some(k) => out[col_def.name()] = Some(T(k))
              None => ()
            }
          }
        }
        return out
      }
      _ => ()
    }
    let out : Map[String, TType?] = Map([])
    for i in 0..<@core.min_int(alias_column_names.length(), values.length()) {
      out[alias_column_names[i]] = type_of(values[i])
    }
    return out
  }
  if expression.kind.is_a(SetOperation) &&
    (expression.has("by_name") ||
    selects_of(expression.this_()).length() ==
    selects_of(expression.expression_()).length()) {
    let out : Map[String, TType?] = Map([])
    for kv in self.get_setop_column_types(expression) {
      out[kv.0] = Some(kv.1)
    }
    return out
  }
  if expression.kind.is_a(Selectable) {
    let out : Map[String, TType?] = Map([])
    for s in selects_of(expression) {
      match s.get_type() {
        Some(t) => out[s.alias_or_name()] = Some(T(t))
        None => ()
      }
    }
    return out
  }
  {}
}

///|
fn struct_datatype(expressions : Array[@core.Expr]) -> @core.Expr {
  @core.mk(DataType, [
    ("this", @core.DType::STRUCT),
    ("expressions", expressions),
    ("nested", true),
  ])
}

///|
pub fn TypeAnnotator::annotate_scope(
  self : TypeAnnotator,
  scope : Scope,
) -> Unit raise @core.SqlglotError {
  for table_column in scope.table_columns() {
    match scope.sources.get(table_column.name()) {
      Some(TableSource(source)) => {
        let schema = match self.schema.find_column_types(source) {
          Some(s) => s
          None => continue
        }
        let defs = []
        for c, kind in schema {
          defs.push(
            @core.mk(ColumnDef, [("this", @core.to_identifier(c)), ("kind", kind)]),
          )
        }
        self.set_type(table_column, Some(T(struct_datatype(defs))))
      }
      Some(ScopeSource(source)) if source.expression.kind.is_a(Query) => {
        let qt = match source.expression.meta_get("query_type") {
          Some(Node(e)) => Some(e)
          _ => None
        }
        let is_struct = match qt {
          Some(t) => t.is_type([STRUCT])
          None => false
        }
        if is_struct {
          self.set_type(table_column, Some(T(qt.unwrap())))
        }
      }
      _ => ()
    }
  }
  self.annotate_expression(scope.expression, Some(scope))
  self.fixup_order_by_aliases(scope)
  if self.dialect.cfg.query_results_are_structs &&
    scope.expression.kind.is_a(Query) {
    let defs = []
    for select in selects_of(scope.expression) {
      defs.push(
        @core.mk(ColumnDef, [
          ("this", @core.to_identifier(select.output_name())),
          ("kind", select.get_type().map(t => t.copy())),
        ]),
      )
    }
    let struct_type = struct_datatype(defs)
    let any_unknown = struct_type
      .expressions()
      .iter()
      .any(cd => match cd.arg("kind") {
        Some(k) => k.is_type([UNKNOWN])
        None => false
      })
    if !any_unknown {
      scope.expression.get_meta()["query_type"] = Node(struct_type)
    }
  }
}

///|
fn TypeAnnotator::annotate_expression(
  self : TypeAnnotator,
  expression : @core.Expr,
  scope : Scope?,
) -> Unit raise @core.SqlglotError {
  let stack : Array[(@core.Expr, Bool)] = [(expression, false)]
  while stack.pop() is Some((expr, children_annotated)) {
    if self.visited.contains(expr.uid) ||
      (!self.overwrite_types &&
      expr.get_type() is Some(_) &&
      !expr.is_type([UNKNOWN])) {
      continue
    }
    if !children_annotated {
      stack.push((expr, true))
      for child in expr.iter_expressions() {
        stack.push((child, false))
      }
      continue
    }
    match scope {
      Some(scope) if expr.kind.is_a(Column) &&
        expr.table_name() != "" &&
        !expr.is_star() => {
        self.annotate_column(expr, scope)
        restore_dot_parts(expr)
        match expr.get_type() {
          Some(t) =>
            match t.get("nullable") {
              Some(Bool(false)) => expr.get_meta()["nonnull"] = Bool(true)
              _ => ()
            }
          None => ()
        }
        continue
      }
      _ => ()
    }
    match self.expression_metadata.get(expr.kind) {
      Some(Annotator(f)) => f(self, expr)
      Some(Returns(t)) => self.set_type(expr, Some(t))
      None => self.set_type(expr, Some(D(UNKNOWN)))
    }
    restore_dot_parts(expr)
  }
}

///|
fn TypeAnnotator::annotate_column(
  self : TypeAnnotator,
  expr : @core.Expr,
  scope : Scope,
) -> Unit raise @core.SqlglotError {
  let table = expr.table_name()
  let mut source : Source? = None
  let mut source_scope : Scope? = Some(scope)
  while source_scope is Some(ss) && source is None {
    source = ss.sources.get(table)
    if source is None {
      source_scope = ss.parent
    }
  }
  match source {
    Some(TableSource(src)) => {
      let mut table_col_type = Some(T(self.schema.get_column_type(src, expr)))
      match table_col_type {
        Some(T(t)) if t.is_type([UNKNOWN]) && src.has("pivots") => {
          let ss = match source_scope {
            Some(s) => s
            None => scope
          }
          table_col_type = match
            self.get_scope_source_selects(ss, table).get(expr.name()) {
            Some(Some(t)) => Some(t)
            _ => Some(D(UNKNOWN))
          }
        }
        _ => ()
      }
      self.set_type(expr, table_col_type)
    }
    Some(src) if source_scope is Some(ss) => {
      let col_type = self.get_scope_source_selects(ss, table).get(expr.name())
      match col_type {
        Some(Some(t)) => self.set_type(expr, Some(t))
        _ =>
          match src.expression() {
            Some(se) if se.kind.is_a(Unnest) => self.set_type(expr, type_of(se))
            _ => self.set_type(expr, Some(D(UNKNOWN)))
          }
      }
    }
    None if !scope.pivots().is_empty() =>
      match self.get_scope_source_selects(scope, table).get(expr.name()) {
        Some(Some(t)) => self.set_type(expr, Some(t))
        _ => self.set_type(expr, Some(D(UNKNOWN)))
      }
    _ => self.set_type(expr, Some(D(UNKNOWN)))
  }
}

///|
/// Dot access into semi-structured values is a case sensitive data lookup, so we
/// undo the normalization of its keys.
fn restore_dot_parts(expr : @core.Expr) -> Unit {
  let dot_parts : Array[String] = match expr.meta_get("dot_parts") {
    Some(List(l)) => l.filter_map(v => v.as_str())
    _ => []
  }
  if dot_parts.is_empty() || !expr.is_type([JSON, MAP, VARIANT]) {
    if !dot_parts.is_empty() {
      expr.get_meta().remove("dot_parts")
    }
    return
  }
  let mut parent = expr.parent
  for part in dot_parts {
    let p = match parent {
      Some(p) if p.kind.is_a(Dot) => p
      _ => break
    }
    match p.expression() {
      Some(identifier) if identifier.kind == Identifier => {
        identifier.set("this", part)
        identifier.set("quoted", true)
      }
      Some(identifier) =>
        identifier.replace(Some(@core.to_identifier(part, quoted=true))) |> ignore
      None => ()
    }
    parent = p.parent
  }
  expr.get_meta().remove("dot_parts")
}

///|
fn TypeAnnotator::fixup_order_by_aliases(
  self : TypeAnnotator,
  scope : Scope,
) -> Unit raise @core.SqlglotError {
  let query = scope.expression
  if !query.kind.is_a(Query) {
    return
  }
  let order = match query.arg("order") {
    Some(o) => o
    None => return
  }
  let alias_types : Map[String, @core.Expr] = Map([])
  for sel in selects_of(query) {
    if sel.kind.is_a(Alias) {
      match sel.this_().get_type() {
        Some(t) if !sel.this_().is_type([UNKNOWN]) => alias_types[sel.alias_()] = t
        _ => ()
      }
    }
  }
  if alias_types.is_empty() {
    return
  }
  for ordered in order.expressions() {
    let alias_cols = ordered
      .find_all([Column])
      .filter(c => c.table_name() == "" && alias_types.contains(c.name()))
      .collect()
    for col in alias_cols {
      self.set_type(col, Some(T(alias_types[col.name()])))
    }
    if !alias_cols.is_empty() {
      for node in ordered.walk(prune=n => n.kind.is_a(Subquery)) {
        if !node.kind.is_any([Column, Literal]) {
          self.visited.remove(node.uid)
        }
      }
      self.annotate_expression(ordered, Some(scope))
    }
  }
}

///|
/// Returns type2 if type1 can be coerced into it, otherwise type1.
pub fn TypeAnnotator::maybe_coerce(
  self : TypeAnnotator,
  type1 : TType,
  type2 : TType,
) -> TType {
  let type1_value = match type1 {
    T(t) =>
      if !t.expressions().is_empty() {
        return type1
      } else {
        match t.datatype_this() {
          Some(d) => d
          None => return type1
        }
      }
    D(d) => d
  }
  let type2_value = match type2 {
    T(t) =>
      if !t.expressions().is_empty() {
        return type2
      } else {
        match t.datatype_this() {
          Some(d) => d
          None => return type2
        }
      }
    D(d) => d
  }
  if type1_value == UNKNOWN || type2_value == UNKNOWN {
    return D(UNKNOWN)
  }
  if type1_value == NULL {
    return D(type2_value)
  }
  if type2_value == NULL {
    return D(type1_value)
  }
  match self.coerces_to.get(type1_value) {
    Some(s) if s.contains(type2_value) => D(type2_value)
    _ => D(type1_value)
  }
}

///|
/// Computes the coerced column types for a set operation.
fn TypeAnnotator::get_setop_column_types(
  self : TypeAnnotator,
  setop : @core.Expr,
) -> Array[(String, TType)] {
  match self.setop_column_types.get(setop.uid) {
    Some(c) => return c
    None => ()
  }
  let col_types : Array[(String, TType)] = []
  fn col_get(name : String) -> TType? {
    for kv in col_types {
      if kv.0 == name {
        return Some(kv.1)
      }
    }
    None
  }

  fn col_set(name : String, t : TType) {
    for i, kv in col_types {
      if kv.0 == name {
        col_types[i] = (name, t)
        return
      }
    }
    col_types.push((name, t))
  }

  let left_selects = match setop.this() {
    Some(t) => selects_of(t)
    None => []
  }
  let right_selects = match setop.expression() {
    Some(t) => selects_of(t)
    None => []
  }
  if !(setop.kind.is_a(SetOperation) &&
    !left_selects.is_empty() &&
    !right_selects.is_empty() &&
    (setop.has("by_name") || left_selects.length() == right_selects.length())) {
    return col_types
  }
  for set_op in setop.walk(prune=n => !n.kind.is_any([SetOperation, Subquery])) {
    if !set_op.kind.is_a(SetOperation) {
      continue
    }
    let setop_cols : Array[(String, TType)] = []
    if set_op.has("by_name") {
      let r_type_by_select : Array[(String, TType?)] = []
      for s in selects_of(set_op.expression_()) {
        let name = s.alias_or_name()
        let t = type_of(s)
        let mut found = false
        for i, kv in r_type_by_select {
          if kv.0 == name {
            r_type_by_select[i] = (name, t)
            found = true
          }
        }
        if !found {
          r_type_by_select.push((name, t))
        }
      }
      for s in selects_of(set_op.this_()) {
        let name = s.alias_or_name()
        let mut r : TType? = Some(D(NULL))
        for i, kv in r_type_by_select {
          if kv.0 == name {
            r = kv.1
            r_type_by_select.remove(i) |> ignore
            break
          }
        }
        let r = match r {
          Some(t) => t
          None => D(UNKNOWN)
        }
        let l = match type_of(s) {
          Some(t) => t
          None => D(UNKNOWN)
        }
        let v = self.maybe_coerce(l, r)
        let mut replaced = false
        for i, kv in setop_cols {
          if kv.0 == name {
            setop_cols[i] = (name, v)
            replaced = true
          }
        }
        if !replaced {
          setop_cols.push((name, v))
        }
      }
      for kv in r_type_by_select {
        let t = match kv.1 {
          Some(t) => t
          None => D(UNKNOWN)
        }
        let mut replaced = false
        for i, c in setop_cols {
          if c.0 == kv.0 {
            setop_cols[i] = (kv.0, t)
            replaced = true
          }
        }
        if !replaced {
          setop_cols.push((kv.0, t))
        }
      }
    } else {
      let ls = selects_of(set_op.this_())
      let rs = selects_of(set_op.expression_())
      for i in 0..<@core.min_int(ls.length(), rs.length()) {
        let name = ls[i].alias_or_name()
        let l = match type_of(ls[i]) {
          Some(t) => t
          None => D(UNKNOWN)
        }
        let r = match type_of(rs[i]) {
          Some(t) => t
          None => D(UNKNOWN)
        }
        let v = self.maybe_coerce(l, r)
        let mut replaced = false
        for j, kv in setop_cols {
          if kv.0 == name {
            setop_cols[j] = (name, v)
            replaced = true
          }
        }
        if !replaced {
          setop_cols.push((name, v))
        }
      }
    }
    for kv in setop_cols {
      let prev = match col_get(kv.0) {
        Some(t) => t
        None => D(NULL)
      }
      col_set(kv.0, self.maybe_coerce(kv.1, prev))
    }
  }
  self.setop_column_types[setop.uid] = col_types
  col_types
}

///|
fn TypeAnnotator::get_unpivot_column_types(
  self : TypeAnnotator,
  pivot : @core.Expr,
  src_types : Map[String, TType?],
) -> Map[String, TType?] {
  ignore(self)
  let new_types : Map[String, TType?] = Map([])
  for field in pivot.list("fields") {
    let field_col = field.this_()
    let first = field.expressions().get(0)
    let in_src = match first {
      Some(f) if f.kind.is_a(PivotAlias) && f.arg("alias") is Some(alias_node) => {
        new_types[field_col.name()] = type_of(alias_node)
        f.this()
      }
      _ => {
        new_types[field_col.name()] = Some(T(@core.datatype_of(VARCHAR)))
        first
      }
    }
    let in_cols = match in_src {
      Some(s) if s.kind.is_a(Tuple) => s.expressions()
      Some(s) => [s]
      None => []
    }
    let val_expr = pivot.expressions().get(0)
    let val_cols = match val_expr {
      Some(v) if v.kind.is_a(Tuple) => v.expressions()
      Some(v) => [v]
      None => []
    }
    for i in 0..<@core.min_int(val_cols.length(), in_cols.length()) {
      let val_col = val_cols[i]
      let in_col = in_cols[i]
      let mut in_type = type_of(in_col)
      let unknown = match in_col.get_type() {
        None => true
        Some(t) => t.is_type([UNKNOWN])
      }
      if unknown {
        match src_types.get(in_col.output_name()) {
          Some(Some(t)) => in_type = Some(t)
          _ => ()
        }
      }
      new_types[val_col.output_name()] = in_type
    }
  }
  let out : Map[String, TType?] = Map([])
  let src_names = src_types.keys().collect()
  for kv in pivot_output_columns(pivot, src_names) {
    let name = kv.0
    let t = match new_types.get(name) {
      Some(Some(t)) => Some(t)
      _ =>
        match src_types.get(name) {
          Some(Some(t)) => Some(t)
          _ => None
        }
    }
    match t {
      Some(t) => out[name] = Some(t)
      None => ()
    }
  }
  out
}

///|
fn TypeAnnotator::get_pivot_column_types(
  self : TypeAnnotator,
  pivot : @core.Expr,
  src_types : Map[String, TType?],
) -> Map[String, TType?] raise @core.SqlglotError {
  ignore(self)
  let first_field = match pivot.list("fields").get(0) {
    Some(f) if f.kind.is_a(In) => f
    _ => raise @core.OptimizeError("Expected In expression for pivot field")
  }
  let pivot_constants = first_field.expressions()
  let output_to_src = pivot_output_columns(pivot, src_types.keys().collect())
  let agg_types = pivot
    .expressions()
    .map(agg => if agg.kind.is_a(Alias) {
      type_of(agg.this_())
    } else {
      type_of(agg)
    })
  let agg_cols_offset = output_to_src.length() -
    pivot_constants.length() * agg_types.length()
  if agg_cols_offset < 0 {
    raise @core.OptimizeError(
      "Negative pivot column offset: \{agg_cols_offset}",
    )
  }
  let new_types : Map[String, TType?] = Map([])
  for i in 0..<agg_cols_offset {
    let (name, src) = output_to_src[i]
    match src_types.get(src) {
      Some(Some(t)) => new_types[name] = Some(t)
      _ => ()
    }
  }
  let repeated = []
  for _ in pivot_constants {
    for a in agg_types {
      repeated.push(a)
    }
  }
  let rest = output_to_src.length() - agg_cols_offset
  for i in 0..<@core.min_int(rest, repeated.length()) {
    match repeated[i] {
      Some(t) => new_types[output_to_src[agg_cols_offset + i].0] = Some(t)
      None => ()
    }
  }
  new_types
}
