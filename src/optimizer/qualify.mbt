// Port of sqlglot/optimizer/qualify.py and isolate_table_selects.py.

///|
/// Rewrite the AST to have normalized and qualified tables and columns.
pub fn qualify(
  expression : @core.Expr,
  dialect? : @core.Dialect,
  db? : String,
  catalog? : String,
  schema? : MappingSchema,
  expand_alias_refs? : Bool = true,
  expand_stars? : Bool = true,
  infer_schema? : Bool,
  isolate_tables? : Bool = false,
  qualify_columns? : Bool = true,
  allow_partial_qualification? : Bool = false,
  validate_qualify_columns? : Bool = true,
  quote_identifiers? : Bool = true,
  identify? : Bool = true,
  canonicalize_table_aliases? : Bool = false,
  on_qualify? : (@core.Expr) -> Unit,
  sql? : String,
) -> @core.Expr raise @core.SqlglotError {
  let schema = ensure_schema(schema?, dialect?)
  let dialect = get_dialect(dialect)
  let mut expression = normalize_identifiers(
    expression,
    dialect~,
    store_original_column_identifiers=true,
  )
  expression = qualify_tables(
    expression,
    db?,
    catalog?,
    dialect~,
    on_qualify?,
    canonicalize_table_aliases~,
  )
  if isolate_tables {
    expression = isolate_table_selects(expression, schema~)
  }
  if qualify_columns {
    expression = qualify_columns_fn(
      expression,
      schema,
      expand_alias_refs~,
      expand_stars~,
      infer_schema?,
      allow_partial_qualification~,
    )
  }
  if quote_identifiers {
    expression = quote_identifiers_fn(expression, dialect~, identify~)
  }
  if validate_qualify_columns {
    validate_qualify_columns_fn(expression, sql?) |> ignore
  }
  expression
}

///|
/// Wraps tables with known schemas in `(SELECT * FROM t AS t) AS t` when a scope selects
/// from more than one source.
pub fn isolate_table_selects(
  expression : @core.Expr,
  schema? : MappingSchema,
  dialect? : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  let schema = ensure_schema(schema?, dialect?)
  for scope in traverse_scope(expression) {
    let selected = scope.selected_sources()
    if selected.length() == 1 {
      continue
    }
    for _, v in selected {
      let source = match v.1 {
        TableSource(t) => t
        ScopeSource(_) => continue
      }
      if schema.column_names(source).is_empty() ||
        parent_is(source, [Subquery]) ||
        (match source.parent {
          Some(p) => parent_is(p, [Table])
          None => false
        }) {
        continue
      }
      if source.alias() == "" {
        raise @core.OptimizeError(
          "Tables require an alias. Run qualify_tables optimization.",
        )
      }
      let alias = source.alias()
      let aliased = @core.alias_table(source.copy(), source.alias_or_name())
      let wrapped = @core.select_([@core.mk0(Star)])
        .from_(aliased)
        .subquery(alias~, copy=false)
      source.replace(Some(wrapped)) |> ignore
    }
  }
  expression
}

///|
fn qualify_columns_fn(
  expression : @core.Expr,
  schema : MappingSchema,
  expand_alias_refs~ : Bool,
  expand_stars~ : Bool,
  infer_schema? : Bool,
  allow_partial_qualification~ : Bool,
) -> @core.Expr raise @core.SqlglotError {
  qualify_columns(
    expression,
    schema,
    expand_alias_refs~,
    expand_stars~,
    infer_schema?,
    allow_partial_qualification~,
  )
}

///|
fn quote_identifiers_fn(
  expression : @core.Expr,
  dialect~ : @core.Dialect,
  identify~ : Bool,
) -> @core.Expr {
  quote_identifiers(expression, dialect~, identify~)
}

///|
fn validate_qualify_columns_fn(
  expression : @core.Expr,
  sql? : String,
) -> @core.Expr raise @core.SqlglotError {
  validate_qualify_columns(expression, sql?)
}
