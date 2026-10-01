// Port of sqlglot/parsers/risingwave.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.property_parsers["ENCODE"] = (p, _) => {
    Some(Node(parse_encode_property(p, None)))
  }
  fns.property_parsers["INCLUDE"] = (p, _) => {
    match parse_include_property(p) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  fns.property_parsers["KEY"] = (p, _) => {
    Some(Node(parse_encode_property(p, Some(true))))
  }
  fns.constraint_parsers["WATERMARK"] = p => {
    let this = if p.match_(FOR) { p.parse_column() } else { None }
    let expression = if p.match_(ALIAS) { p.parse_disjunction() } else { None }
    Some(
      p.expression(
        @core.mk(WatermarkColumnConstraint, [
          ("this", this),
          ("expression", expression),
        ]),
      ),
    )
  }
  // There is no hint in risingwave.
  // Do nothing here to avoid WITH keywords conflict in CREATE SINK statement.
  fns.hooks.parse_table_hints = Some(_ => None)
}

///|
fn parse_include_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let mut coldef : @core.Expr? = None
  let this = p.parse_var_or_string()
  if !p.match_(ALIAS) {
    let header = p.parse_field()
    if header is Some(_) {
      coldef = Some(
        p.expression(
          @core.mk(ColumnDef, [("this", header), ("kind", p.parse_types())]),
        ),
      )
    }
  }
  p.match_(ALIAS) |> ignore
  let alias_ = p.parse_id_var(tokens=p.cfg.alias_tokens)
  Some(
    p.expression(
      @core.mk(IncludeProperty, [
        ("this", this),
        ("alias", alias_),
        ("column_def", coldef),
      ]),
    ),
  )
}

///|
fn parse_encode_property(
  p : @core.Parser,
  key : Bool?,
) -> @core.Expr raise @core.SqlglotError {
  p.match_text_seq(["ENCODE"]) |> ignore
  let this = p.parse_var_or_string()
  let properties = if p.match_(L_PAREN, advance=false) {
    Some(
      p.expression(
        @core.mk(Properties, [("expressions", p.parse_wrapped_properties())]),
      ),
    )
  } else {
    None
  }
  let e = @core.mk(EncodeProperty, [("this", this), ("properties", properties)])
  match key {
    Some(k) => e.set("key", k)
    None => ()
  }
  p.expression(e)
}
