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

///|
/// Python `DataType.from_str` (TEMP stub, provided by the parser side).
pub fn datatype_from_str(
  dtype : String,
  dialect? : Dialect,
  udt? : Bool = false,
) -> Expr raise SqlglotError {
  ignore((dtype, dialect, udt))
  ...
}

///|
/// TEMP stub (real one in parser_tables.mbt, js-only during the port).
pub fn base_parser_fns() -> ParserFns {
  {
    functions: Map([]),
    function_parsers: Map([]),
    no_paren_function_parsers: Map([]),
    statement_parsers: Map([]),
    unary_parsers: Map([]),
    string_parsers: Map([]),
    numeric_parsers: Map([]),
    primary_parsers: Map([]),
    placeholder_parsers: Map([]),
    range_parsers: Map([]),
    column_operators: Map([]),
    json_operators: Map([]),
    lambdas: Map([]),
    expression_parsers: Map([]),
    property_parsers: Map([]),
    constraint_parsers: Map([]),
    alter_parsers: Map([]),
    alter_alter_parsers: Map([]),
    query_modifier_parsers: Map([]),
    set_parsers: Map([]),
    show_parsers: Map([]),
    type_literal_parsers: Map([]),
    type_converters: Map([]),
    pipe_syntax_transform_parsers: Map([]),
    analyze_expression_parsers: Map([]),
    hooks: ParserHooks::new(),
    show_trie: WordTrie::new(),
    set_trie: WordTrie::new(),
  }
}
