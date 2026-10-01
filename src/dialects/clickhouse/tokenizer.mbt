// Tokenizer overrides for the clickhouse dialect (all tokenizer settings are data and
// live in gen_config.mbt). Dialect-level method overrides are installed here too.

///|
fn configure_tokenizer(d : @core.Dialect) -> Unit {
  d.hooks.generate_values_aliases = Some(generate_values_aliases)
}

///|
/// Clickhouse allows VALUES to have an embedded structure e.g:
/// VALUES('person String, place String', ('Noah', 'Paris'), ...)
/// In this case, we don't want to qualify the columns
fn generate_values_aliases(
  _d : @core.Dialect,
  expression : @core.Expr,
) -> Array[@core.Expr] {
  let values = expression.expressions()[0].expressions()
  let structure = if values.length() > 1 &&
    values[0].is_string() &&
    values[1].kind == Tuple {
    Some(values[0])
  } else {
    None
  }
  match structure {
    Some(s) =>
      // Split each column definition into the column name e.g:
      // 'person String, place String' -> ['person', 'place']
      s
      .name()
      .split(",")
      .map(coldef => {
        let coldef = @core.py_strip(coldef.to_owned())
        let name = match coldef.find(" ") {
          Some(i) => @core.substr(coldef, 0, i)
          None => coldef
        }
        @core.to_identifier(name)
      })
      .collect()
    None =>
      // Default column aliases in CH are "c1", "c2", etc.
      Array::makei(values[0].expressions().length(), i => {
        @core.to_identifier("c\{i + 1}")
      })
  }
}
