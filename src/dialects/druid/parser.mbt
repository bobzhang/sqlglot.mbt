// Port of sqlglot/parsers/druid.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  d.parser_fns.function_parsers["JSON_VALUE"] = p => p.parse_json_value()
}
