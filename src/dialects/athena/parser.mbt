// Port of sqlglot/parsers/athena.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  configure_athena_trino_parser(d)
  d.parser_fns.hooks.parse = Some((p, raw_tokens, sql) => {
    if !raw_tokens.is_empty() && raw_tokens[0].token_type == HIVE_TOKEN_STREAM {
      let hive = athena_hive_dialect()
      let hp = engine_parser(p, hive)
      return match hive.parser_fns.hooks.parse {
        Some(f) => f(hp, raw_tokens[1:].to_array(), sql)
        None => hp.parse(raw_tokens[1:].to_array(), sql)
      }
    }
    let trino = athena_trino_dialect()
    let tp = engine_parser(p, trino)
    match trino.parser_fns.hooks.parse {
      Some(f) => f(tp, raw_tokens, sql)
      None => tp.parse(raw_tokens, sql)
    }
  })
  d.parser_fns.hooks.parse_into = Some((p, expression_types, raw_tokens, sql) => {
    if !raw_tokens.is_empty() && raw_tokens[0].token_type == HIVE_TOKEN_STREAM {
      let hive = athena_hive_dialect()
      let hp = engine_parser(p, hive)
      return match hive.parser_fns.hooks.parse_into {
        Some(f) => f(hp, expression_types, raw_tokens[1:].to_array(), sql)
        None => hp.parse_into(expression_types, raw_tokens[1:].to_array(), sql~)
      }
    }
    let trino = athena_trino_dialect()
    let tp = engine_parser(p, trino)
    match trino.parser_fns.hooks.parse_into {
      Some(f) => f(tp, expression_types, raw_tokens, sql)
      None => tp.parse_into(expression_types, raw_tokens, sql~)
    }
  })
}

///|
/// A parser of the engine dialect `d` with the same error settings as `p`.
fn engine_parser(p : @core.Parser, d : @core.Dialect) -> @core.Parser {
  d.parser(
    error_level=p.error_level,
    error_message_context=p.error_message_context,
    max_errors=p.max_errors,
    max_nodes=p.max_nodes,
  )
}
