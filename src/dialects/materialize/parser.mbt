// Port of sqlglot/parsers/materialize.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.no_paren_function_parsers["MAP"] = parse_map
  fns.lambdas[FARROW] = (p, expressions) => {
    let this = if expressions.length() > 0 {
      Some(expressions[0])
    } else {
      None
    }
    Some(
      p.expression(
        @core.mk(Kwarg, [("this", this), ("expression", p.parse_assignment())]),
      ),
    )
  }
  fns.hooks.parse_lambda_arg = Some(p => p.parse_field())
}

///|
fn parse_map(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_(L_PAREN) {
    let to_map = p.expression(@core.mk1(ToMap, p.parse_select()))
    p.match_r_paren()
    return Some(to_map)
  }
  if !p.match_(L_BRACKET) {
    p.raise_error("Expecting [")
  }
  let entries = p
    .parse_csv(() => p.parse_lambda())
    .map(e => {
      @core.mk(PropertyEQ, [("this", e.this()), ("expression", e.expression())])
    })
  if !p.match_(R_BRACKET) {
    p.raise_error("Expecting ]")
  }
  Some(
    p.expression(
      @core.mk1(
        ToMap,
        p.expression(@core.mk(Struct, [("expressions", entries)])),
      ),
    ),
  )
}
