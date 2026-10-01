// Port of the Athena Tokenizer (sqlglot/dialects/athena.py): it consumes a combination
// of HiveQL and Trino SQL and then processes the tokens to disambiguate which dialect
// needs to be actually used in order to tokenize correctly.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  d.hooks.tokenize = Some(tokenize)
}

///|
fn tokenize(
  d : @core.Dialect,
  sql : String,
) -> Array[@core.Token] raise @core.SqlglotError {
  let tokens = d.tokenize_base(sql)
  if tokenize_as_hive(tokens) {
    return [
      @core.Token::new(HIVE_TOKEN_STREAM, ""),
      ..athena_hive_dialect().tokenize(sql),
    ]
  }
  athena_trino_dialect().tokenize(sql)
}

///|
fn tokenize_as_hive(tokens : Array[@core.Token]) -> Bool {
  if tokens.length() < 2 {
    return false
  }
  let first = tokens[0]
  let second = tokens[1]
  let first_type = first.token_type
  let first_text = @core.py_upper(first.text)
  let second_type = second.token_type
  let second_text = @core.py_upper(second.text)
  if first_type == DESCRIBE || first_type == SHOW || first_text == "MSCK REPAIR" {
    return true
  }
  if first_type == ALTER || first_type == CREATE || first_type == DROP {
    if second_text == "DATABASE" ||
      second_text == "EXTERNAL" ||
      second_text == "SCHEMA" {
      return true
    }
    if second_type == VIEW {
      return false
    }
    for i in 2..<tokens.length() {
      if tokens[i].token_type == SELECT {
        return false
      }
    }
    return true
  }
  false
}
