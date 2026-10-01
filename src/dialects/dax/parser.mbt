// Port of sqlglot/parsers/dax.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let h = d.parser_fns.hooks
  h.parse_statement = Some(parse_statement)
  h.parse_column = Some(parse_column)
}

///|
fn parse_statement(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if !p.match_text_seq(["EVALUATE"]) {
    return None
  }
  let mut query = parse_table_expression(p)
  if query is Some(q) && p.match_(ORDER_BY) {
    let order = @core.mk(Order, [
      ("expressions", p.parse_csv(() => p.parse_ordered())),
    ])
    query = Some(q.order_by([p.expression(order)], copy=false))
  }
  query
}

///|
fn parse_table_expression(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if p.match_pair(FILTER, L_PAREN) {
    let query = parse_table_expression(p)
    p.match_(COMMA) |> ignore
    let where_ = p.parse_disjunction()
    p.match_r_paren()
    return match (query, where_) {
      (Some(q), Some(w)) => Some(q.where_([w], copy=false))
      (Some(q), None) => Some(q)
      _ => None
    }
  }
  let table = p.parse_table_parts()
  match table {
    Some(t) => Some(@core.select_([@core.mk0(Star)]).from_(t, copy=false))
    None => None
  }
}

///|
fn parse_column(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.parse_column_base()
  // Combine adjacent identifiers into a column reference: Table[Column]
  match this {
    Some(t) if t.kind == Column =>
      match p.parse_identifier() {
        Some(column) =>
          this = Some(
            p.expression(
              @core.mk(Column, [("this", column), ("table", t.this())]),
            ),
          )
        None => ()
      }
    _ => ()
  }
  this
}
