// Port of sqlglot/jsonpath.py

///|
priv struct JsonPathParser {
  path : String
  tokens : Array[Token]
  var_tokens : Array[TokenType]
  mut i : Int
}

///|
fn JsonPathParser::curr(self : JsonPathParser) -> TokenType? {
  if self.i < self.tokens.length() {
    Some(self.tokens[self.i].token_type)
  } else {
    None
  }
}

///|
fn JsonPathParser::prev(self : JsonPathParser) -> Token {
  self.tokens[self.i - 1]
}

///|
fn JsonPathParser::advance(self : JsonPathParser) -> Token {
  self.i += 1
  self.prev()
}

///|
fn JsonPathParser::error(self : JsonPathParser, msg : String) -> String {
  "\{msg} at index \{self.i}: \{self.path}"
}

///|
fn JsonPathParser::match_(self : JsonPathParser, tt : TokenType) -> Token? {
  if self.curr() == Some(tt) {
    return Some(self.advance())
  }
  None
}

///|
fn JsonPathParser::match_set(
  self : JsonPathParser,
  types : Array[TokenType],
) -> Token? {
  match self.curr() {
    Some(t) if types.contains(t) => Some(self.advance())
    _ => None
  }
}

///|
/// Literal results: Str(text) | Node(expr) | Int(n) | Bool(false)
fn JsonPathParser::parse_literal(
  self : JsonPathParser,
) -> Value raise SqlglotError {
  match self.match_(STRING) {
    Some(t) => return Str(t.text)
    None => ()
  }
  match self.match_(IDENTIFIER) {
    Some(t) => return Str(t.text)
    None => ()
  }
  if self.match_(STAR) is Some(_) {
    return Node(mk0(JSONPathWildcard))
  }
  if self.match_(PLACEHOLDER) is Some(_) || self.match_(L_PAREN) is Some(_) {
    let script = self.prev().text == "("
    let start = self.i
    while true {
      if self.match_(L_BRACKET) is Some(_) {
        self.parse_bracket() |> ignore
      }
      match self.curr() {
        Some(R_BRACKET) | None => break
        _ => ()
      }
      self.advance() |> ignore
    }
    let kind = if script { JSONPathScript } else { JSONPathFilter }
    let size = self.tokens.length()
    let end = if self.i < size {
      self.tokens[self.i].end
    } else {
      self.tokens[size - 1].end
    }
    return Node(mk1(kind, substr(self.path, self.tokens[start].start, end)))
  }
  let mut number = if self.match_(DASH) is Some(_) { "-" } else { "" }
  match self.match_(NUMBER) {
    Some(t) => number += t.text
    None => ()
  }
  if !number.is_empty() {
    // Python `int(number)`: a ValueError (not a ParseError) for non-integers.
    return match parse_int_checked(number) {
      Some(n) => Int(n)
      None =>
        raise ValueError(
          "invalid literal for int() with base 10: \{py_repr_str(number)}",
        )
    }
  }
  Bool(false)
}

///|
fn JsonPathParser::parse_slice(
  self : JsonPathParser,
) -> Value raise SqlglotError {
  let start = self.parse_literal()
  let end : Value? = if self.match_(COLON) is Some(_) {
    Some(self.parse_literal())
  } else {
    None
  }
  let step : Value? = if self.match_(COLON) is Some(_) {
    Some(self.parse_literal())
  } else {
    None
  }
  if end is None && step is None {
    return start
  }
  Node(mk(JSONPathSlice, [("start", start), ("end", end), ("step", step)]))
}

///|
fn JsonPathParser::parse_bracket(
  self : JsonPathParser,
) -> Expr raise SqlglotError {
  let literal = self.parse_slice()
  if literal is Bool(false) {
    raise ParseError(self.error("Cannot have empty segment"), [])
  }
  let indexes = [literal]
  while self.match_(COMMA) is Some(_) {
    let literal = self.parse_slice()
    if !(literal is Bool(false)) {
      indexes.push(literal)
    }
  }
  let node = if indexes.length() == 1 {
    match indexes[0] {
      Str(s) => mk1(JSONPathKey, s)
      Node(n) if n.kind.is_any([JSONPathScript, JSONPathFilter]) =>
        mk1(JSONPathSelector, n)
      v => mk1(JSONPathSubscript, v)
    }
  } else {
    mk(JSONPathUnion, [("expressions", indexes)])
  }
  if self.match_(R_BRACKET) is None {
    raise ParseError(self.error("Expected \{TokenType::R_BRACKET}"), [])
  }
  node
}

///|
fn JsonPathParser::parse_var_text(self : JsonPathParser) -> String {
  let prev_index = self.i - 2
  while self.match_set(self.var_tokens) is Some(_) {
    ()
  }
  let start = if prev_index < 0 { 0 } else { self.tokens[prev_index].end + 1 }
  if self.i >= self.tokens.length() {
    substr(self.path, start, py_len(self.path))
  } else {
    substr(self.path, start, self.tokens[self.i].start)
  }
}

///|
/// Takes in a JSON path string and parses it into a JSONPath expression.
pub fn parse_json_path(
  path : String,
  dialect : Dialect,
) -> Expr raise SqlglotError {
  let tokenizer = Tokenizer::new(
    dialect.jsonpath_tokenizer,
    numbers_can_be_underscore_separated=dialect.cfg.numbers_can_be_underscore_separated,
    identifiers_can_start_with_digit=dialect.cfg.identifiers_can_start_with_digit,
    unescaped_sequences=dialect.cfg.unescaped_sequences,
  )
  let p : JsonPathParser = {
    path,
    tokens: tokenizer.tokenize(path),
    var_tokens: dialect.jsonpath_var_tokens,
    i: 0,
  }
  p.match_(DOLLAR) |> ignore
  let expressions = [mk0(JSONPathRoot)]
  while p.curr() is Some(_) {
    if p.match_(DOT) is Some(_) || p.match_(COLON) is Some(_) {
      let recursive = p.prev().text == ".."
      let value : Value? = if p.match_set(p.var_tokens) is Some(_) {
        Some(Str(p.parse_var_text()))
      } else if p.match_(IDENTIFIER) is Some(_) {
        Some(Str(p.prev().text))
      } else if p.match_(STAR) is Some(_) {
        Some(Node(mk0(JSONPathWildcard)))
      } else {
        None
      }
      if recursive {
        expressions.push(mk1(JSONPathRecursive, value))
      } else if value is Some(v) && v.truthy() {
        expressions.push(mk1(JSONPathKey, v))
      } else if !dialect.cfg.json_path_single_dot_is_wildcard {
        raise ParseError(p.error("Expected key name or * after DOT"), [])
      }
    } else if p.match_(L_BRACKET) is Some(_) {
      expressions.push(p.parse_bracket())
    } else if p.match_set(p.var_tokens) is Some(_) {
      expressions.push(mk1(JSONPathKey, p.parse_var_text()))
    } else if p.match_(IDENTIFIER) is Some(_) {
      expressions.push(mk1(JSONPathKey, p.prev().text))
    } else if p.match_(STAR) is Some(_) {
      expressions.push(mk0(JSONPathWildcard))
    } else {
      raise ParseError(p.error("Unexpected \{p.tokens[p.i].token_type}"), [])
    }
  }
  mk(JSONPath, [("expressions", expressions)])
}

///|
/// `Dialect.to_json_path(path)`: parses string/number literals into JSONPath expressions.
pub fn Dialect::to_json_path(
  self : Dialect,
  path : Expr?,
) -> Expr? raise SqlglotError {
  match self.hooks.to_json_path {
    Some(f) => f(self, path)
    None => self.to_json_path_base(path)
  }
}

///|
/// The base `Dialect.to_json_path` implementation.
pub fn Dialect::to_json_path_base(
  self : Dialect,
  path : Expr?,
) -> Expr? raise SqlglotError {
  match path {
    Some(p) if p.kind == Literal => {
      let mut path_text = p.name()
      if p.is_number() {
        path_text = "[\{path_text}]"
      }
      Some(parse_json_path(path_text, self)) catch {
        // Python only catches ParseError and TokenError here
        e if !(e is (ParseError(_) | TokenError(_))) => raise e
        e => {
          let stripped = path_text.trim_start().to_owned()
          if self.cfg.strict_json_path_syntax &&
            !(stripped.has_prefix("lax") || stripped.has_prefix("strict")) {
            log_warning("Invalid JSON path syntax. \{e.message()}")
          }
          path
        }
      }
    }
    _ => path
  }
}
