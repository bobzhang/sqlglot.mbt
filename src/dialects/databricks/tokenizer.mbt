// Tokenizer overrides for the databricks dialect.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  // JSONPathTokenizer.IDENTIFIERS = ["`", '"']
  d.jsonpath_tokenizer.identifiers = [
    @core.QuoteSpec::Same("`"),
    @core.QuoteSpec::Same("\""),
  ]
}
