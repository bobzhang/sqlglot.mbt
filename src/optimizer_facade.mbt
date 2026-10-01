// Optimizer and executor entry points of the facade (Python `sqlglot.optimizer.optimize`
// and `sqlglot.executor.execute`).

///|
fn init {
  // The generator relies on annotate_types/simplify for some transpilations.
  @optimizer.install()
}

///|
/// Rewrites `expression` (an expression, or SQL parsed in `dialect`) into an optimized
/// form (Python `sqlglot.optimizer.optimize`). The expression is copied, not modified.
///
/// - `schema`: the database schema, as `{table: {col: type}}`, `{db: {table: {col: type}}}`
///   or `{catalog: {db: {table: {col: type}}}}` (see `SchemaNode`).
/// - `mapping_schema`: the schema as a `MappingSchema` (takes precedence over `schema`).
/// - `db`, `catalog`: the default database and catalog of unqualified tables.
/// - `identify`: whether the final `quote_identifiers` rule quotes every identifier.
/// - The other options are those of the optimizer rules (see `@optimizer.optimize`).
pub fn[T : @core.IntoPy] optimize(
  expression : T,
  schema? : Map[String, @optimizer.SchemaNode],
  mapping_schema? : @optimizer.MappingSchema,
  db? : String,
  catalog? : String,
  dialect? : String = "",
  infer_schema? : Bool,
  identify? : Bool = true,
  leave_tables_isolated? : Bool = false,
  validate_qualify_columns? : Bool = true,
  expand_stars? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let d = @core.Dialect::get_or_raise(dialect)
  let expression = @core.maybe_parse(expression, dialect=d, copy=true)
  @optimizer.optimize(
    expression,
    schema?=mapping_schema,
    mapping?=schema,
    db?,
    catalog?,
    dialect=d,
    infer_schema?,
    identify~,
    leave_tables_isolated~,
    validate_qualify_columns~,
    expand_stars~,
  )
}

///|
pub using @executor {execute}
