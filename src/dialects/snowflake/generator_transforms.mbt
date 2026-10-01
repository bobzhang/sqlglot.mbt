// Port of the preprocessing transforms of sqlglot/generators/snowflake.py

///|
/// Snowflake doesn't allow columns referenced in UNPIVOT to be qualified,
/// so we need to unqualify them. Same goes for ANY ORDER BY <column>.
fn unqualify_pivot_columns(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == Pivot {
    if expression.has("unpivot") {
      return @core.unqualify_columns(expression)
    }
    for field in expression.list("fields") {
      match field.expressions().get(0) {
        Some(field_expr) if field_expr.kind == PivotAny => {
          let unqualified_field_expr = @core.unqualify_columns(field_expr)
          field.set_at("expressions", unqualified_field_expr, 0)
        }
        _ => ()
      }
    }
  }
  expression
}

///|
fn eliminate_dot_variant_lookup(expression : @core.Expr) -> @core.Expr {
  if expression.kind == Select {
    // This transformation is used to facilitate transpilation of BigQuery `UNNEST` operations
    // to Snowflake. It should not affect roundtrip because `Unnest` nodes cannot be produced
    // by Snowflake's parser.
    //
    // Additionally, at the time of writing this, BigQuery is the only dialect that produces a
    // `TableAlias` node that only fills `columns` and not `this`, due to `UNNEST_COLUMN_ONLY`.
    let unnest_aliases : Array[String] = []
    for unnest in @optimizer.find_all_in_scope(expression, [Unnest]) {
      match unnest.arg("alias") {
        Some(unnest_alias) if unnest_alias.kind == TableAlias &&
          !unnest_alias.has("this") &&
          unnest_alias.list("columns").length() == 1 => {
          let name = unnest_alias.list("columns")[0].name()
          if !unnest_aliases.contains(name) {
            unnest_aliases.push(name)
          }
        }
        _ => ()
      }
    }
    if !unnest_aliases.is_empty() {
      for c in @optimizer.find_all_in_scope(expression, [Column]) {
        if unnest_aliases.contains(c.text("table")) {
          let bracket_lhs = c.arg("table")
          let bracket_rhs = @core.literal_string(c.name())
          let bracket = @core.mk(Bracket, [
            ("this", bracket_lhs),
            ("expressions", [bracket_rhs]),
          ])
          match c.parent {
            Some(p) if physical_equal(p, expression) =>
              // Retain column projection names by using aliases
              c.replace(Some(@core.alias_expr(bracket, Some(c.this_().copy()))))
              |> ignore
            _ => c.replace(Some(bracket)) |> ignore
          }
        }
      }
    }
  }
  expression
}
