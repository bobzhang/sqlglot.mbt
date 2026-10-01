// TEMPORARY stubs for parser methods not yet ported. Remove each as it is implemented.

///|
pub fn Parser::parse_statement(self : Parser) -> Expr? raise SqlglotError {
  ignore(self)
  ...
}

///|
pub fn Parser::parse_string(self : Parser) -> Expr? raise SqlglotError {
  ignore(self)
  ...
}

///|
pub fn Parser::parse_id_var(
  self : Parser,
  any_token? : Bool = true,
  tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  ignore((self, any_token, tokens))
  ...
}

///|
pub fn Parser::parse_expression(self : Parser) -> Expr? raise SqlglotError {
  ignore(self)
  ...
}

///|
/// Parses a single SQL statement (TEMP stub, implemented in parser_api.mbt later).
pub fn parse_one(
  sql : String,
  dialect? : Dialect,
  into? : Array[Kind],
) -> Expr raise SqlglotError {
  ignore((sql, dialect, into))
  ...
}
