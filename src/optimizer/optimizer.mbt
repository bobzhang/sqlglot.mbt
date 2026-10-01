// Port of sqlglot/optimizer/optimizer.py.

///|
/// The keyword arguments `optimize` passes to its rules (Python's `possible_kwargs`).
pub struct OptimizeOptions {
  schema : MappingSchema
  db : String?
  catalog : String?
  dialect : @core.Dialect
  sql : String?
  isolate_tables : Bool
  quote_identifiers : Bool
  infer_schema : Bool?
  identify : Bool
  leave_tables_isolated : Bool
  validate_qualify_columns : Bool
  canonicalize_table_aliases : Bool
  expand_alias_refs : Bool
  expand_stars : Bool
  allow_partial_qualification : Bool
  on_qualify : ((@core.Expr) -> Unit)?
  constant_propagation : Bool
  coalesce_simplification : Bool
}

///|
/// An optimizer rule.
pub(all) enum Rule {
  Qualify
  QualifyTables
  QualifyColumns
  IsolateTableSelects
  PushdownProjections
  Normalize
  UnnestSubqueries
  PushdownPredicates
  OptimizeJoins
  EliminateSubqueries
  MergeSubqueries
  EliminateJoins
  EliminateCtes
  QuoteIdentifiers
  AnnotateTypes
  Canonicalize
  Simplify
  CanonicalizeInternalNames
  Custom((@core.Expr, OptimizeOptions) -> @core.Expr raise @core.SqlglotError)
}

///|
/// The default optimizer rules (Python `RULES`), in order.
pub let rules : Array[Rule] = [
  Qualify, PushdownProjections, Normalize, UnnestSubqueries, PushdownPredicates, OptimizeJoins,
  EliminateSubqueries, MergeSubqueries, EliminateJoins, EliminateCtes, QuoteIdentifiers,
  AnnotateTypes, Canonicalize, Simplify,
]

///|
/// Applies a single rule with the given options.
pub fn Rule::apply(
  self : Rule,
  expression : @core.Expr,
  o : OptimizeOptions,
) -> @core.Expr raise @core.SqlglotError {
  match self {
    Qualify =>
      qualify(
        expression,
        dialect=o.dialect,
        db?=o.db,
        catalog?=o.catalog,
        schema=o.schema,
        expand_alias_refs=o.expand_alias_refs,
        expand_stars=o.expand_stars,
        infer_schema?=o.infer_schema,
        isolate_tables=o.isolate_tables,
        allow_partial_qualification=o.allow_partial_qualification,
        validate_qualify_columns=o.validate_qualify_columns,
        quote_identifiers=o.quote_identifiers,
        identify=o.identify,
        canonicalize_table_aliases=o.canonicalize_table_aliases,
        on_qualify?=o.on_qualify,
        sql?=o.sql,
      )
    QualifyTables =>
      qualify_tables(
        expression,
        db?=o.db,
        catalog?=o.catalog,
        on_qualify?=o.on_qualify,
        dialect=o.dialect,
        canonicalize_table_aliases=o.canonicalize_table_aliases,
      )
    QualifyColumns =>
      qualify_columns(
        expression,
        o.schema,
        expand_alias_refs=o.expand_alias_refs,
        expand_stars=o.expand_stars,
        infer_schema?=o.infer_schema,
        allow_partial_qualification=o.allow_partial_qualification,
      )
    IsolateTableSelects =>
      isolate_table_selects(expression, schema=o.schema, dialect=o.dialect)
    PushdownProjections => pushdown_projections(expression)
    Normalize => normalize(expression)
    UnnestSubqueries => unnest_subqueries(expression)
    PushdownPredicates => pushdown_predicates(expression, dialect=o.dialect)
    OptimizeJoins => optimize_joins(expression)
    EliminateSubqueries => eliminate_subqueries(expression)
    MergeSubqueries =>
      merge_subqueries(expression, leave_tables_isolated=o.leave_tables_isolated)
    EliminateJoins => eliminate_joins(expression)
    EliminateCtes => eliminate_ctes(expression)
    QuoteIdentifiers =>
      quote_identifiers(expression, dialect=o.dialect, identify=o.identify)
    AnnotateTypes =>
      annotate_types(expression, schema=o.schema, dialect=o.dialect)
    Canonicalize => canonicalize(expression, dialect=o.dialect)
    Simplify =>
      simplify(
        expression,
        constant_propagation=o.constant_propagation,
        coalesce_simplification=o.coalesce_simplification,
        dialect=o.dialect,
      )
    CanonicalizeInternalNames => canonicalize_internal_names(expression)
    Custom(f) => f(expression, o)
  }
}

///|
/// Rewrite a sqlglot AST into an optimized form.
///
/// `identify` only applies to the `QuoteIdentifiers` rule (the `Qualify` rule receives
/// `quote_identifiers=false`, as in Python). Unless given, `schema` is built from `mapping`.
pub fn optimize(
  expression : @core.Expr,
  schema? : MappingSchema,
  mapping? : Map[String, SchemaNode],
  db? : String,
  catalog? : String,
  dialect? : @core.Dialect,
  rules? : Array[Rule] = rules,
  sql? : String,
  infer_schema? : Bool,
  identify? : Bool = true,
  leave_tables_isolated? : Bool = false,
  validate_qualify_columns? : Bool = true,
  canonicalize_table_aliases? : Bool = false,
  expand_alias_refs? : Bool = true,
  expand_stars? : Bool = true,
  allow_partial_qualification? : Bool = false,
  isolate_tables? : Bool = true,
  quote_identifiers? : Bool = false,
  on_qualify? : (@core.Expr) -> Unit,
  constant_propagation? : Bool = false,
  coalesce_simplification? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  let schema = ensure_schema(schema?, mapping?, dialect?)
  let options : OptimizeOptions = {
    schema,
    db,
    catalog,
    dialect: get_dialect(dialect),
    sql,
    isolate_tables,
    quote_identifiers,
    infer_schema,
    identify,
    leave_tables_isolated,
    validate_qualify_columns,
    canonicalize_table_aliases,
    expand_alias_refs,
    expand_stars,
    allow_partial_qualification,
    on_qualify,
    constant_propagation,
    coalesce_simplification,
  }
  let mut optimized = expression.copy()
  for rule in rules {
    optimized = rule.apply(optimized, options)
  }
  optimized
}

///|
/// Parses `sql` (in `dialect`) and optimizes it.
pub fn optimize_sql(
  sql : String,
  schema? : MappingSchema,
  mapping? : Map[String, SchemaNode],
  dialect? : @core.Dialect,
  rules? : Array[Rule] = rules,
  infer_schema? : Bool,
  identify? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let expression = @core.parse_one(sql, dialect?)
  optimize(
    expression,
    schema?,
    mapping?,
    dialect?,
    rules~,
    infer_schema?,
    identify~,
  )
}
