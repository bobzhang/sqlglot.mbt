// Callable class attributes of the Python `Parser` (FUNCTIONS, *_PARSERS, ...) and
// method override hooks used to emulate dialect subclassing.

///|
pub type ParseFn = (Parser) -> Expr? raise SqlglotError

///|
pub type ParseFn1 = (Parser, Expr?) -> Expr? raise SqlglotError

///|
pub type TokenParseFn = (Parser, Token) -> Expr? raise SqlglotError

///|
/// A function builder: `FUNCTIONS[name](args)`.
pub type FuncBuilder = (Array[Expr], Parser) -> Expr raise SqlglotError

///|
/// `COLUMN_OPERATORS` / `JSON_OPERATORS` value: `(self, this, rhs) -> Expr`.
pub type ColumnOpFn = (Parser, Expr?, Expr?) -> Expr? raise SqlglotError

///|
/// Keyword arguments passed to property parsers (`no=True`, `dual=True`, ...).
pub type PropKwargs = Map[String, Bool]

///|
/// A property parser may return an expression, a list of expressions or nothing.
pub type PropertyFn = (Parser, PropKwargs) -> Value? raise SqlglotError

///|
pub(all) struct ParserFns {
  mut functions : Map[String, FuncBuilder]
  mut function_parsers : Map[String, ParseFn]
  mut no_paren_function_parsers : Map[String, ParseFn]
  mut statement_parsers : Map[TokenType, ParseFn]
  mut unary_parsers : Map[TokenType, ParseFn]
  mut string_parsers : Map[TokenType, TokenParseFn]
  mut numeric_parsers : Map[TokenType, TokenParseFn]
  mut primary_parsers : Map[TokenType, TokenParseFn]
  mut placeholder_parsers : Map[TokenType, ParseFn]
  mut range_parsers : Map[TokenType, ParseFn1]
  /// `None` value means "handled inline" (e.g. DOT).
  mut column_operators : Map[TokenType, ColumnOpFn?]
  mut json_operators : Map[TokenType, ColumnOpFn]
  mut lambdas : Map[
    TokenType,
    (Parser, Array[Expr]) -> Expr? raise SqlglotError,
  ]
  mut expression_parsers : Map[Kind, ParseFn]
  mut property_parsers : Map[String, PropertyFn]
  mut constraint_parsers : Map[String, ParseFn]
  mut alter_parsers : Map[String, (Parser) -> Value? raise SqlglotError]
  mut alter_alter_parsers : Map[String, ParseFn]
  mut query_modifier_parsers : Map[
    TokenType,
    (Parser) -> (String, Value?) raise SqlglotError,
  ]
  mut set_parsers : Map[String, ParseFn]
  mut show_parsers : Map[String, ParseFn]
  mut type_literal_parsers : Map[
    DType,
    (Parser, Expr, Expr) -> Expr raise SqlglotError,
  ]
  mut type_converters : Map[DType, (Expr) -> Expr]
  mut pipe_syntax_transform_parsers : Map[
    String,
    (Parser, Expr) -> Expr? raise SqlglotError,
  ]
  mut analyze_expression_parsers : Map[String, ParseFn]
  /// Method overrides (see parser_hooks.mbt).
  mut hooks : ParserHooks
  // derived
  mut show_trie : WordTrie
  mut set_trie : WordTrie
}

///|
pub fn ParserFns::copy(self : ParserFns) -> ParserFns {
  {
    functions: Map::from_iter(self.functions.iter()),
    function_parsers: Map::from_iter(self.function_parsers.iter()),
    no_paren_function_parsers: Map::from_iter(
      self.no_paren_function_parsers.iter(),
    ),
    statement_parsers: Map::from_iter(self.statement_parsers.iter()),
    unary_parsers: Map::from_iter(self.unary_parsers.iter()),
    string_parsers: Map::from_iter(self.string_parsers.iter()),
    numeric_parsers: Map::from_iter(self.numeric_parsers.iter()),
    primary_parsers: Map::from_iter(self.primary_parsers.iter()),
    placeholder_parsers: Map::from_iter(self.placeholder_parsers.iter()),
    range_parsers: Map::from_iter(self.range_parsers.iter()),
    column_operators: Map::from_iter(self.column_operators.iter()),
    json_operators: Map::from_iter(self.json_operators.iter()),
    lambdas: Map::from_iter(self.lambdas.iter()),
    expression_parsers: Map::from_iter(self.expression_parsers.iter()),
    property_parsers: Map::from_iter(self.property_parsers.iter()),
    constraint_parsers: Map::from_iter(self.constraint_parsers.iter()),
    alter_parsers: Map::from_iter(self.alter_parsers.iter()),
    alter_alter_parsers: Map::from_iter(self.alter_alter_parsers.iter()),
    query_modifier_parsers: Map::from_iter(self.query_modifier_parsers.iter()),
    set_parsers: Map::from_iter(self.set_parsers.iter()),
    show_parsers: Map::from_iter(self.show_parsers.iter()),
    type_literal_parsers: Map::from_iter(self.type_literal_parsers.iter()),
    type_converters: Map::from_iter(self.type_converters.iter()),
    pipe_syntax_transform_parsers: Map::from_iter(
      self.pipe_syntax_transform_parsers.iter(),
    ),
    analyze_expression_parsers: Map::from_iter(
      self.analyze_expression_parsers.iter(),
    ),
    hooks: self.hooks.copy(),
    show_trie: self.show_trie,
    set_trie: self.set_trie,
  }
}

///|
/// Recomputes SHOW_TRIE / SET_TRIE.
pub fn ParserFns::finalize(self : ParserFns) -> Unit {
  self.show_trie = WordTrie::from_keys(self.show_parsers.keys())
  self.set_trie = WordTrie::from_keys(self.set_parsers.keys())
}
