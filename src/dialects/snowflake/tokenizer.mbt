// Tokenizer overrides for the snowflake dialect.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  // JSONPathTokenizer.SINGLE_TOKENS.pop("$")
  d.jsonpath_tokenizer.single_tokens.remove('$')
}
