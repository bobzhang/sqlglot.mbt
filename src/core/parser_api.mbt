// Top-level parsing API (port of sqlglot/__init__.py parse/parse_one and
// Dialect.parse / Dialect.tokenize).

///|
/// Tokenizes `sql` with this dialect's tokenizer.
pub fn Dialect::tokenize(self : Dialect, sql : String) -> Array[Token] raise SqlglotError {
  Tokenizer::new(
    self.tokenizer,
    numbers_can_be_underscore_separated=self.cfg.numbers_can_be_underscore_separated,
    identifiers_can_start_with_digit=self.cfg.identifiers_can_start_with_digit,
    unescaped_sequences=self.cfg.unescaped_sequences,
  ).tokenize(sql)
}

///|
/// Creates a parser for this dialect.
pub fn Dialect::parser(
  self : Dialect,
  error_level? : ErrorLevel = Immediate,
  error_message_context? : Int = 100,
  max_errors? : Int = 3,
  max_nodes? : Int = -1,
) -> Parser {
  Parser::new(self, error_level~, error_message_context~, max_errors~, max_nodes~)
}

///|
/// Parses `sql` into a list of syntax trees, one per statement.
pub fn Dialect::parse(
  self : Dialect,
  sql : String,
  error_level? : ErrorLevel = Immediate,
) -> Array[Expr?] raise SqlglotError {
  let p = self.parser(error_level~)
  match self.parser_fns.hooks.parse {
    Some(f) => f(p, self.tokenize(sql), sql)
    None => p.parse(self.tokenize(sql), sql)
  }
}

///|
/// Parses `sql` into the given expression type(s).
pub fn Dialect::parse_into(
  self : Dialect,
  into : Array[Kind],
  sql : String,
  error_level? : ErrorLevel = Immediate,
) -> Array[Expr?] raise SqlglotError {
  let p = self.parser(error_level~)
  match self.parser_fns.hooks.parse_into {
    Some(f) => f(p, into, self.tokenize(sql), sql)
    None => p.parse_into(into, self.tokenize(sql), sql~)
  }
}

///|
/// Parses the given SQL string and returns a syntax tree.
pub fn parse_one(
  sql : String,
  dialect? : Dialect,
  into? : Array[Kind],
  error_level? : ErrorLevel = Immediate,
) -> Expr raise SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => base_dialect()
  }
  let result = match into {
    Some(i) => d.parse_into(i, sql, error_level~)
    None => d.parse(sql, error_level~)
  }
  if result.is_empty() || result[0] is None {
    raise ParseError("No expression was parsed from '\{sql}'", [])
  }
  if result.length() > 1 {
    mk(Block, [("expressions", result.filter_map(x => x))])
  } else {
    result[0].unwrap()
  }
}

///|
/// Parses with a dialect given by name (e.g. "duckdb").
pub fn parse_one_with(
  sql : String,
  read : String,
  into? : Array[Kind],
) -> Expr raise SqlglotError {
  parse_one(sql, dialect=Dialect::get_or_raise(read), into?)
}

///|
/// Parses all statements of `sql`.
pub fn parse(sql : String, dialect? : Dialect) -> Array[Expr?] raise SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => base_dialect()
  }
  d.parse(sql)
}

///|
/// Python `DataType.from_str`.
pub fn datatype_from_str(
  dtype : String,
  dialect? : Dialect,
  udt? : Bool = false,
) -> Expr raise SqlglotError {
  if py_upper(dtype) == "UNKNOWN" {
    return mk1(DataType, DType::UNKNOWN)
  }
  parse_one(dtype, dialect?, into=[DataType], error_level=Ignore) catch {
    ParseError(_, _) as e =>
      if udt {
        mk(DataType, [("this", DType::USERDEFINED), ("kind", dtype)])
      } else {
        raise e
      }
    e => raise e
  }
}

