// Port of the core machinery of sqlglot/parser.py: token cursor, matching,
// error handling and generic list/wrapper helpers.

///|
let sentinel_none : Token = Token::new(SENTINEL, "SENTINEL")

///|
/// Python truthiness of a token (`Token.__bool__`).
pub fn Token::ok(self : Token) -> Bool {
  self.token_type != SENTINEL
}

///|
/// Parser consumes a list of tokens produced by the Tokenizer and produces a parsed syntax tree.
pub struct Parser {
  dialect : Dialect
  cfg : ParserConfig
  fns : ParserFns
  mut error_level : ErrorLevel
  error_message_context : Int
  max_errors : Int
  max_nodes : Int
  mut sql : String
  mut errors : Array[SqlglotError]
  mut tokens : Array[Token]
  mut tokens_size : Int
  mut index : Int
  mut curr : Token
  mut next : Token
  mut prev : Token
  mut prev_comments : Array[String]
  mut pipe_cte_counter : Int
  mut chunks : Array[Array[Token]]
  mut chunk_index : Int
  mut node_count : Int
}

///|
pub fn Parser::new(
  dialect : Dialect,
  error_level? : ErrorLevel = Immediate,
  error_message_context? : Int = 100,
  max_errors? : Int = 3,
  max_nodes? : Int = -1,
) -> Parser {
  {
    dialect,
    cfg: dialect.parser_cfg,
    fns: dialect.parser_fns,
    error_level,
    error_message_context,
    max_errors,
    max_nodes,
    sql: "",
    errors: [],
    tokens: [],
    tokens_size: 0,
    index: 0,
    curr: sentinel_none,
    next: sentinel_none,
    prev: sentinel_none,
    prev_comments: [],
    pipe_cte_counter: 0,
    chunks: [],
    chunk_index: 0,
    node_count: 0,
  }
}

///|
pub fn Parser::reset(self : Parser) -> Unit {
  self.sql = ""
  self.errors = []
  self.tokens = []
  self.tokens_size = 0
  self.index = 0
  self.curr = sentinel_none
  self.next = sentinel_none
  self.prev = sentinel_none
  self.prev_comments = []
  self.pipe_cte_counter = 0
  self.chunks = []
  self.chunk_index = 0
  self.node_count = 0
}

///|
pub fn Parser::advance(self : Parser, times? : Int = 1) -> Unit {
  let index = self.index + times
  self.index = index
  let tokens = self.tokens
  let size = self.tokens_size
  self.curr = if index >= 0 && index < size { tokens[index] } else { sentinel_none }
  self.next = if index + 1 >= 0 && index + 1 < size {
    tokens[index + 1]
  } else {
    sentinel_none
  }
  if index > 0 {
    let prev = tokens[index - 1]
    self.prev = prev
    self.prev_comments = prev.comments
  } else {
    self.prev = sentinel_none
    self.prev_comments = []
  }
}

///|
fn Parser::advance_chunk(self : Parser) -> Unit {
  self.index = -1
  self.tokens = self.chunks[self.chunk_index]
  self.tokens_size = self.tokens.length()
  self.chunk_index += 1
  self.advance()
}

///|
pub fn Parser::retreat(self : Parser, index : Int) -> Unit {
  if index != self.index {
    self.advance(times=index - self.index)
  }
}

///|
pub fn Parser::add_comments(self : Parser, expression : Expr?) -> Unit {
  match expression {
    Some(e) =>
      if !self.prev_comments.is_empty() {
        e.add_comments(Some(self.prev_comments))
        self.prev_comments = []
      }
    None => ()
  }
}

///|
pub fn Parser::match_(
  self : Parser,
  token_type : TokenType,
  advance? : Bool = true,
  expression? : Expr,
) -> Bool {
  if self.curr.token_type == token_type {
    if advance {
      self.advance()
    }
    self.add_comments(expression)
    return true
  }
  false
}

///|
pub fn Parser::match_set(
  self : Parser,
  types : TokenSet,
  advance? : Bool = true,
) -> Bool {
  if types.contains(self.curr.token_type) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn Parser::match_any(
  self : Parser,
  types : ArrayView[TokenType],
  advance? : Bool = true,
) -> Bool {
  if types.contains(self.curr.token_type) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn[V] Parser::match_keys(
  self : Parser,
  m : Map[TokenType, V],
  advance? : Bool = true,
) -> Bool {
  if m.contains(self.curr.token_type) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn Parser::match_pair(
  self : Parser,
  a : TokenType,
  b : TokenType,
  advance? : Bool = true,
) -> Bool {
  if self.curr.token_type == a && self.next.token_type == b {
    if advance {
      self.advance(times=2)
    }
    return true
  }
  false
}

///|
pub fn Parser::match_texts(
  self : Parser,
  texts : ArrayView[String],
  advance? : Bool = true,
) -> Bool {
  if !self.cfg.text_match_excluded_tokens.contains(self.curr.token_type) &&
    texts.contains(py_upper(self.curr.text)) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn Parser::match_text_set(
  self : Parser,
  texts : @set.Set[String],
  advance? : Bool = true,
) -> Bool {
  if !self.cfg.text_match_excluded_tokens.contains(self.curr.token_type) &&
    texts.contains(py_upper(self.curr.text)) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn[V] Parser::match_text_keys(
  self : Parser,
  texts : Map[String, V],
  advance? : Bool = true,
) -> Bool {
  if !self.cfg.text_match_excluded_tokens.contains(self.curr.token_type) &&
    texts.contains(py_upper(self.curr.text)) {
    if advance {
      self.advance()
    }
    return true
  }
  false
}

///|
pub fn Parser::match_text_seq(
  self : Parser,
  texts : ArrayView[String],
  advance? : Bool = true,
) -> Bool {
  let index = self.index
  let excluded = self.cfg.text_match_excluded_tokens
  for text in texts {
    if !excluded.contains(self.curr.token_type) &&
      py_upper(self.curr.text) == text {
      self.advance()
    } else {
      self.retreat(index)
      return false
    }
  }
  if !advance {
    self.retreat(index)
  }
  true
}

///|
/// `self._match_text_seq("X")` for a single keyword.
pub fn Parser::match_text(self : Parser, text : String, advance? : Bool = true) -> Bool {
  self.match_text_seq([text], advance~)
}

///|
pub fn Parser::is_connected(self : Parser) -> Bool {
  self.prev.ok() && self.curr.ok() && self.prev.end + 1 == self.curr.start
}

///|
pub fn Parser::find_sql(self : Parser, start : Token, end : Token) -> String {
  substr(self.sql, start.start, end.end + 1)
}

///|
/// Appends an error in the list of recorded errors or raises it, depending on the chosen
/// error level setting.
pub fn Parser::raise_error(
  self : Parser,
  message : String,
  token? : Token = sentinel_none,
) -> Unit raise SqlglotError {
  let token = if token.ok() {
    token
  } else if self.curr.ok() {
    self.curr
  } else if self.prev.ok() {
    self.prev
  } else {
    Token::string("")
  }
  let (formatted_sql, start_context, highlight, end_context) = highlight_sql(
    self.sql,
    [(token.start, token.end)],
    context_length=self.error_message_context,
  )
  let formatted_message = "\{message}. Line \{token.line}, Col: \{token.col}.\n  \{formatted_sql}"
  let error = ParseError(formatted_message, [
    {
      description: message,
      line: token.line,
      col: token.col,
      start_context,
      highlight,
      end_context,
      into_expression: None,
    },
  ])
  if self.error_level == Immediate {
    raise error
  }
  self.errors.push(error)
}

///|
/// Validates an Expr, making sure that all its mandatory arguments are set.
pub fn Parser::validate_expression(
  self : Parser,
  expression : Expr,
  nargs? : Int = 0,
) -> Expr raise SqlglotError {
  if self.max_nodes > -1 {
    self.node_count += 1
    if self.node_count > self.max_nodes {
      self.raise_error(
        "Maximum number of AST nodes (\{self.max_nodes}) exceeded",
      )
    }
  }
  if self.error_level != Ignore {
    for error_message in expression.error_messages(nargs~) {
      self.raise_error(error_message)
    }
  }
  expression
}

///|
/// Attempts to backtrack if a parse function that contains a try/catch internally raises an error.
pub fn[T] Parser::try_parse(
  self : Parser,
  parse_method : () -> T? raise SqlglotError,
  retreat? : Bool = false,
) -> T? {
  let index = self.index
  let error_level = self.error_level
  self.error_level = Immediate
  let this = parse_method() catch {
    ParseError(_, _) => None
    _ => None
  }
  if this is None || retreat {
    self.retreat(index)
  }
  self.error_level = error_level
  this
}

///|
/// Parses a list of tokens and returns a list of syntax trees, one tree per parsed SQL statement.
pub fn Parser::parse(
  self : Parser,
  raw_tokens : Array[Token],
  sql : String,
) -> Array[Expr?] raise SqlglotError {
  self.parse_with(p => p.parse_statement(), raw_tokens, sql)
}

///|
/// Parses a list of tokens into a given Expr type.
pub fn Parser::parse_into(
  self : Parser,
  expression_types : ArrayView[Kind],
  raw_tokens : Array[Token],
  sql? : String = "",
) -> Array[Expr?] raise SqlglotError {
  let errors : Array[ParseErrorInfo] = []
  let mut last_message = ""
  for expression_type in expression_types {
    let parser = match self.fns.expression_parsers.get(expression_type) {
      Some(p) => p
      None =>
        raise ValueError("No parser registered for \{expression_type.name()}")
    }
    try self.parse_with(parser, raw_tokens, sql) catch {
      ParseError(msg, infos) => {
        last_message = msg
        for i, info in infos {
          errors.push(
            if i == 0 {
              { ..info, into_expression: Some(expression_type.name()) }
            } else {
              info
            },
          )
        }
      }
      e => raise e
    } noraise {
      r => return r
    }
  }
  ignore(last_message)
  let names = expression_types.iter().map(k => k.name()).collect()
  raise ParseError(
    "Failed to parse '\{sql}' into \{if names.length() == 1 { names[0] } else { names.to_string() }}",
    errors,
  )
}

///|
/// Logs or raises any found errors, depending on the chosen error level setting.
pub fn Parser::check_errors(self : Parser) -> Unit raise SqlglotError {
  if self.error_level == Warn {
    for e in self.errors {
      log_error(e.to_string())
    }
  } else if self.error_level == Raise && !self.errors.is_empty() {
    let msgs = self.errors.map(e => e.message())
    let infos = []
    for e in self.errors {
      match e {
        ParseError(_, i) => infos.append(i)
        _ => ()
      }
    }
    raise ParseError(concat_messages(msgs, self.max_errors), infos)
  }
}

///|
/// Creates a new, validated Expr: attaches comments and position info.
pub fn Parser::expression(
  self : Parser,
  instance : Expr,
  token? : Token,
  comments? : Array[String],
) -> Expr raise SqlglotError {
  match token {
    Some(t) => instance.update_positions_from_token(t) |> ignore
    None => ()
  }
  match comments {
    Some(c) if !c.is_empty() => instance.add_comments(Some(c))
    _ => self.add_comments(Some(instance))
  }
  if !instance.kind.is_primitive() {
    self.validate_expression(instance)
  } else {
    instance
  }
}

///|
/// `self.expression(...)` for an optional instance.
pub fn Parser::expression_opt(self : Parser, instance : Expr?) -> Expr? raise SqlglotError {
  match instance {
    Some(e) => Some(self.expression(e))
    None => None
  }
}

///|
fn Parser::parse_batch_statements(
  self : Parser,
  parse_method : (Parser) -> Expr? raise SqlglotError,
  sep_first_statement? : Bool = true,
) -> Array[Expr?] raise SqlglotError {
  let expressions : Array[Expr?] = []
  if sep_first_statement {
    self.match_(BEGIN) |> ignore
    expressions.push(parse_method(self))
  }
  let chunks_length = self.chunks.length()
  while self.chunk_index < chunks_length {
    self.advance_chunk()
    if self.match_(ELSE, advance=false) {
      return expressions
    }
    if !expressions.is_empty() && !self.next.ok() && self.match_(END) {
      expressions.push(Some(mk0(EndStatement)))
      continue
    }
    expressions.push(parse_method(self))
    if self.index < self.tokens_size {
      self.raise_error("Invalid expression / Unexpected token")
    }
    self.check_errors()
  }
  expressions
}

///|
fn Parser::parse_with(
  self : Parser,
  parse_method : (Parser) -> Expr? raise SqlglotError,
  raw_tokens : Array[Token],
  sql : String,
) -> Array[Expr?] raise SqlglotError {
  self.reset()
  self.sql = sql
  let total = raw_tokens.length()
  let chunks : Array[Array[Token]] = [[]]
  for i, token in raw_tokens {
    if token.token_type == SEMICOLON {
      if !token.comments.is_empty() {
        chunks.push([token])
      }
      if i < total - 1 {
        chunks.push([])
      }
    } else {
      chunks[chunks.length() - 1].push(token)
    }
  }
  self.chunks = chunks
  self.parse_batch_statements(parse_method, sep_first_statement=false)
}

///|
fn Parser::warn_unsupported(self : Parser) -> Unit {
  if self.tokens_size <= 1 {
    return
  }
  let sql = substr(
    self.find_sql(self.tokens[0], self.tokens[self.tokens_size - 1]),
    0,
    self.error_message_context,
  )
  log_warning(
    "'\{sql}' contains unsupported syntax. Falling back to parsing as a 'Command'.",
  )
}

///|
pub fn Parser::parse_command(self : Parser) -> Expr raise SqlglotError {
  self.warn_unsupported()
  let comments = self.prev_comments
  self.expression(
    mk(Command, [
      ("this", py_upper(self.prev.text)),
      ("expression", self.parse_string()),
    ]),
    comments~,
  )
}

///|
/// Parses a comma (or `sep`) separated list.
pub fn Parser::parse_csv(
  self : Parser,
  parse_method : () -> Expr? raise SqlglotError,
  sep? : TokenType = COMMA,
) -> Array[Expr] raise SqlglotError {
  let mut parse_result = parse_method()
  let items = match parse_result {
    Some(r) => [r]
    None => []
  }
  while self.match_(sep) {
    self.add_comments(parse_result)
    parse_result = parse_method()
    match parse_result {
      Some(r) => items.push(r)
      None => ()
    }
  }
  items
}

///|
/// `_parse_csv` for methods that don't return expressions.
pub fn[T] Parser::parse_csv_any(
  self : Parser,
  parse_method : () -> T? raise SqlglotError,
  sep? : TokenType = COMMA,
) -> Array[T] raise SqlglotError {
  let items = match parse_method() {
    Some(r) => [r]
    None => []
  }
  while self.match_(sep) {
    match parse_method() {
      Some(r) => items.push(r)
      None => ()
    }
  }
  items
}

///|
pub fn Parser::parse_wrapped_id_vars(
  self : Parser,
  optional? : Bool = false,
) -> Array[Expr] raise SqlglotError {
  match self.fns.hooks.parse_wrapped_id_vars {
    Some(f) => f(self, optional)
    None => self.parse_wrapped_csv(() => self.parse_id_var(), optional~)
  }
}

///|
pub fn Parser::parse_wrapped_csv(
  self : Parser,
  parse_method : () -> Expr? raise SqlglotError,
  sep? : TokenType = COMMA,
  optional? : Bool = false,
) -> Array[Expr] raise SqlglotError {
  self.parse_wrapped(() => self.parse_csv(parse_method, sep~), optional~)
}

///|
pub fn[T] Parser::parse_wrapped(
  self : Parser,
  parse_method : () -> T raise SqlglotError,
  optional? : Bool = false,
) -> T raise SqlglotError {
  let wrapped = self.match_(L_PAREN)
  if !wrapped && !optional {
    self.raise_error("Expecting (")
  }
  let parse_result = parse_method()
  if wrapped {
    self.match_r_paren()
  }
  parse_result
}

///|
pub fn Parser::parse_expressions(self : Parser) -> Array[Expr] raise SqlglotError {
  self.parse_csv(() => self.parse_expression())
}

///|
pub fn Parser::match_l_paren(
  self : Parser,
  expression? : Expr,
) -> Unit raise SqlglotError {
  if !self.match_(L_PAREN, expression?) {
    self.raise_error("Expecting (")
  }
}

///|
pub fn Parser::match_r_paren(
  self : Parser,
  expression? : Expr,
) -> Unit raise SqlglotError {
  if !self.match_(R_PAREN, expression?) {
    self.raise_error("Expecting )")
  }
}

///|
pub fn Parser::parse_var_from_options(
  self : Parser,
  options : Map[String, Array[Array[String]]],
  raise_unmatched? : Bool = true,
) -> Expr? raise SqlglotError {
  let start = self.curr
  if !start.ok() {
    return None
  }
  let mut option = py_upper(start.text)
  let continuations = if self.cfg.text_match_excluded_tokens.contains(
      start.token_type,
    ) {
    None
  } else {
    options.get(option)
  }
  let index = self.index
  self.advance()
  let mut matched = false
  match continuations {
    Some(conts) =>
      for keywords in conts {
        if self.match_text_seq(keywords) {
          option = option + " " + keywords.join(" ")
          matched = true
          break
        }
      }
    None => ()
  }
  if !matched {
    let unmatched = match continuations {
      None => true
      Some(c) => !c.is_empty()
    }
    if unmatched {
      if raise_unmatched {
        self.raise_error("Unknown option \{option}")
      }
      self.retreat(index)
      return None
    }
  }
  Some(var_(option))
}

///|
pub fn Parser::parse_as_command(self : Parser, start : Token) -> Expr {
  while self.curr.ok() {
    self.advance()
  }
  let text = self.find_sql(start, self.prev)
  let size = py_len(start.text)
  self.warn_unsupported()
  mk(Command, [
    ("this", substr(text, 0, size)),
    ("expression", substr(text, size, py_len(text))),
  ])
}

///|
pub fn[V] Parser::find_parser(
  self : Parser,
  parsers : Map[String, V],
  trie : WordTrie,
) -> V? {
  if !self.curr.ok() {
    return None
  }
  let index = self.index
  let this = []
  let mut trie = trie
  while true {
    let curr = py_upper(self.curr.text)
    let key = py_split(curr, " ")
    this.push(curr)
    self.advance()
    let (result, sub) = trie.lookup(key)
    trie = sub
    if result == Failed {
      break
    }
    if result == Exists {
      return parsers.get(this.join(" "))
    }
  }
  self.retreat(index)
  None
}

// ---------------------------------------------------------------------------
// Logging

///|
let log_messages : Array[String] = []

///|
pub fn log_warning(msg : String) -> Unit {
  log_messages.push("WARNING: " + msg)
}

///|
pub fn log_error(msg : String) -> Unit {
  log_messages.push("ERROR: " + msg)
}

///|
/// Returns and clears the collected log messages.
pub fn take_log_messages() -> Array[String] {
  let out = log_messages.copy()
  log_messages.clear()
  out
}
