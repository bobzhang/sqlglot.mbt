// Ports of `exp.normalize_table_name` and `exp.expand` (they need normalize_identifiers).

///|
/// Returns a case normalized table name without quotes.
pub fn normalize_table_name(
  table : @core.Expr,
  dialect? : @core.Dialect,
  copy? : Bool = true,
) -> String {
  let t = if copy { table.copy() } else { table }
  normalize_identifiers(t, dialect?).parts().map(p => p.name()).join(".")
}

///|
/// `normalize_table_name` for a table name given as SQL.
pub fn normalize_table_name_str(
  table : String,
  dialect? : @core.Dialect,
) -> String raise @core.SqlglotError {
  let t = @core.parse_one(table, dialect?, into=[Table])
  normalize_table_name(t, dialect?, copy=false)
}

///|
/// Transforms an expression by expanding all referenced sources into subqueries.
pub fn expand(
  expression : @core.Expr,
  sources : Map[String, @core.Expr],
  dialect? : @core.Dialect,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let normalized_sources : Map[String, @core.Expr] = {}
  for k, v in sources {
    normalized_sources[normalize_table_name_str(k, dialect?)] = v
  }
  fn expand_node(node : @core.Expr) -> @core.Expr? {
    if node.kind.is_a(Table) {
      let name = normalize_table_name(node, dialect?)
      match normalized_sources.get(name) {
        Some(source) => {
          let alias = if node.alias() != "" { node.alias() } else { name }
          let subquery = source.subquery(alias~)
          subquery.add_comments(Some(["source: \{name}"]))
          return Some(subquery.transform(expand_node, copy=false))
        }
        None => ()
      }
    }
    Some(node)
  }

  expression.transform(expand_node, copy~)
}
