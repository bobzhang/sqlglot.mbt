// Tokenizer overrides for the hive dialect.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  // JSONPathTokenizer.VAR_TOKENS = {*VAR_TOKENS, DASH}
  d.jsonpath_var_tokens.push(DASH)
}
