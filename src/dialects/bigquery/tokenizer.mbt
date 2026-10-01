// Tokenizer overrides for the bigquery dialect (the Tokenizer settings are data and live
// in gen_config.mbt). The JSONPathTokenizer and dialect-level method overrides are set here.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  // JSONPathTokenizer.VAR_TOKENS = {*VAR_TOKENS, DASH, NUMBER}
  for tt in [@core.TokenType::DASH, NUMBER] {
    if !d.jsonpath_var_tokens.contains(tt) {
      d.jsonpath_var_tokens.push(tt)
    }
  }
  d.hooks.normalize_identifier = Some(normalize_identifier)
}

///|
fn ascii_lower(s : String) -> String {
  let sb = StringBuilder::new()
  for c in s {
    sb.write_char(if c >= 'A' && c <= 'Z' { c.to_ascii_lowercase() } else { c })
  }
  sb.to_string()
}

///|
fn normalize_identifier(
  d : @core.Dialect,
  expression : @core.Expr,
) -> @core.Expr {
  if expression.kind == Identifier &&
    d.normalization_strategy == CaseInsensitive {
    let mut parent = expression.parent
    while parent is Some(p) && p.kind == Dot {
      parent = p.parent
    }
    // In BigQuery, CTEs are case-insensitive, but UDF and table names are case-sensitive
    // by default. The following check uses a heuristic to detect tables based on whether
    // they are qualified. This should generally be correct, because tables in BigQuery
    // must be qualified with at least a dataset, unless @@dataset_id is set.
    let case_sensitive = match parent {
      Some(p) if p.kind == UserDefinedFunction => true
      Some(p) if p.kind == Table &&
        p.db() != "" &&
        (p.meta_bool("quoted_table") || !p.meta_bool("maybe_column")) => true
      _ => expression.meta_bool("is_table")
    }
    if !case_sensitive {
      expression.set("this", ascii_lower(expression.text("this")))
    }
    return expression
  }
  d.normalize_identifier_base(expression)
}
