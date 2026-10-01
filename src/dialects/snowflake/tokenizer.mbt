// Tokenizer (and Dialect-level method) overrides for the snowflake dialect.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  // JSONPathTokenizer.SINGLE_TOKENS.pop("$")
  d.jsonpath_tokenizer.single_tokens.remove('$')
  // Dialect.can_quote (registered here since dialect.mbt is generated)
  d.hooks.can_quote = Some(can_quote)
}

///|
/// This disables quoting DUAL in SELECT ... FROM DUAL, because Snowflake treats an
/// unquoted DUAL keyword in a special way and does not map it to a user-defined table
fn can_quote(
  d : @core.Dialect,
  identifier : @core.Expr,
  identify : String,
) -> Bool {
  d.can_quote_base(identifier, identify~) &&
  !((match identifier.parent {
    Some(p) => p.kind == Table
    None => false
  }) &&
  !identifier.has("quoted") &&
  @core.py_lower(identifier.name()) == "dual")
}
