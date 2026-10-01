// Port of sqlglot/tokens.py and sqlglot/tokenizer_core.py

///|
/// A lexical token.
pub struct Token {
  token_type : TokenType
  text : String
  line : Int
  col : Int
  start : Int
  end : Int
  comments : Array[String]
}

///|
pub fn Token::new(
  token_type : TokenType,
  text : String,
  line? : Int = 1,
  col? : Int = 1,
  start? : Int = 0,
  end? : Int = 0,
  comments? : Array[String] = [],
) -> Token {
  { token_type, text, line, col, start, end, comments }
}

///|
pub fn Token::number(n : Int) -> Token {
  Token::new(NUMBER, n.to_string())
}

///|
pub fn Token::string(s : String) -> Token {
  Token::new(STRING, s)
}

///|
pub fn Token::identifier(s : String) -> Token {
  Token::new(IDENTIFIER, s)
}

///|
pub fn Token::var_(s : String) -> Token {
  Token::new(VAR, s)
}

///|
pub impl Show for Token with output(self, logger) {
  logger.write_string(
    "<Token token_type: TokenType.\{self.token_type.name()}, text: \{self.text}, line: \{self.line}, col: \{self.col}, start: \{self.start}, end: \{self.end}, comments: \{self.comments}>",
  )
}

///|
/// A quote specification: either a symmetric delimiter or a (start, end) pair.
pub(all) enum QuoteSpec {
  Same(String)
  Pair(String, String)
}

///|
fn QuoteSpec::start(self : QuoteSpec) -> String {
  match self {
    Same(s) => s
    Pair(s, _) => s
  }
}

///|
fn QuoteSpec::end(self : QuoteSpec) -> String {
  match self {
    Same(s) => s
    Pair(_, e) => e
  }
}

///|
/// Numeric escape specification: (base, min digits, max digits, max value).
pub(all) struct NumericEscape {
  base : Int
  min_digits : Int
  max_digits : Int
  max_value : Int
}

///|
/// Tokenizer configuration of a dialect (the Python `Tokenizer` class attributes).
pub(all) struct TokenizerSettings {
  mut single_tokens : Map[Char, TokenType]
  mut bit_strings : Array[QuoteSpec]
  mut byte_strings : Array[QuoteSpec]
  mut hex_strings : Array[QuoteSpec]
  mut raw_strings : Array[QuoteSpec]
  mut heredoc_strings : Array[QuoteSpec]
  mut unicode_strings : Array[QuoteSpec]
  mut identifiers : Array[QuoteSpec]
  mut quotes : Array[QuoteSpec]
  mut string_escapes : Array[String]
  mut byte_string_escapes : Array[String]?
  mut var_single_tokens : Array[Char]
  mut escape_follow_chars : Array[String]
  mut identifier_escapes : Array[String]
  mut heredoc_tag_is_identifier : Bool
  mut heredoc_string_alternative : TokenType
  mut string_escapes_allowed_in_raw_strings : Bool
  mut numeric_escapes : Map[String, NumericEscape]
  mut drop_unknown_escapes : Bool
  mut nested_comments : Bool
  mut hint_start : String
  mut tokens_preceding_hint : Array[TokenType]
  mut keywords : Map[String, TokenType]
  mut commands : Array[TokenType]
  mut command_prefix_tokens : Array[TokenType]
  mut numeric_literals : Map[String, String]
  mut numbers_can_have_decimals : Bool
  mut comments : Array[QuoteSpec]
  // Derived (call `finalize`)
  mut quotes_map : Map[String, String]
  mut identifiers_map : Map[String, String]
  mut identifier_chars : Map[Char, String]
  mut format_strings : Map[String, (String, TokenType)]
  mut string_escapes_set : Map[String, Bool]
  mut byte_string_escapes_set : Map[String, Bool]
  mut escape_follow_chars_set : Map[String, Bool]
  mut identifier_escapes_set : Map[String, Bool]
  mut comments_map : Map[String, String?]
  mut keyword_trie : Trie
  mut commands_set : Map[TokenType, Bool]
}

///|
pub fn TokenizerSettings::copy(self : TokenizerSettings) -> TokenizerSettings {
  {
    single_tokens: Map::from_iter(self.single_tokens.iter()),
    bit_strings: self.bit_strings.copy(),
    byte_strings: self.byte_strings.copy(),
    hex_strings: self.hex_strings.copy(),
    raw_strings: self.raw_strings.copy(),
    heredoc_strings: self.heredoc_strings.copy(),
    unicode_strings: self.unicode_strings.copy(),
    identifiers: self.identifiers.copy(),
    quotes: self.quotes.copy(),
    string_escapes: self.string_escapes.copy(),
    byte_string_escapes: match self.byte_string_escapes {
      Some(b) => Some(b.copy())
      None => None
    },
    var_single_tokens: self.var_single_tokens.copy(),
    escape_follow_chars: self.escape_follow_chars.copy(),
    identifier_escapes: self.identifier_escapes.copy(),
    heredoc_tag_is_identifier: self.heredoc_tag_is_identifier,
    heredoc_string_alternative: self.heredoc_string_alternative,
    string_escapes_allowed_in_raw_strings: self.string_escapes_allowed_in_raw_strings,
    numeric_escapes: Map::from_iter(self.numeric_escapes.iter()),
    drop_unknown_escapes: self.drop_unknown_escapes,
    nested_comments: self.nested_comments,
    hint_start: self.hint_start,
    tokens_preceding_hint: self.tokens_preceding_hint.copy(),
    keywords: Map::from_iter(self.keywords.iter()),
    commands: self.commands.copy(),
    command_prefix_tokens: self.command_prefix_tokens.copy(),
    numeric_literals: Map::from_iter(self.numeric_literals.iter()),
    numbers_can_have_decimals: self.numbers_can_have_decimals,
    comments: self.comments.copy(),
    quotes_map: Map([]),
    identifiers_map: Map([]),
    identifier_chars: Map([]),
    format_strings: Map([]),
    string_escapes_set: Map([]),
    byte_string_escapes_set: Map([]),
    escape_follow_chars_set: Map([]),
    identifier_escapes_set: Map([]),
    comments_map: Map([]),
    keyword_trie: Trie::new(),
    commands_set: Map([]),
  }
}

///|
fn convert_quotes(arr : Array[QuoteSpec]) -> Map[String, String] {
  let m : Map[_, _] = Map([])
  for q in arr {
    m[q.start()] = q.end()
  }
  m
}

///|
fn str_set(arr : Array[String]) -> Map[String, Bool] {
  let m : Map[_, _] = Map([])
  for s in arr {
    m[s] = true
  }
  m
}

///|
/// Computes the derived attributes (Python's `__init_subclass__`).
pub fn TokenizerSettings::finalize(self : TokenizerSettings) -> TokenizerSettings {
  self.quotes_map = convert_quotes(self.quotes)
  self.identifiers_map = convert_quotes(self.identifiers)
  self.identifier_chars = Map([])
  for k, v in self.identifiers_map {
    match k.get_char(0) {
      Some(c) => if k.length() == 1 { self.identifier_chars[c] = v }
      None => ()
    }
  }
  let fs : Map[String, (String, TokenType)] = Map([])
  for s, e in self.quotes_map {
    fs["n" + s] = (e, NATIONAL_STRING)
  }
  for s, e in self.quotes_map {
    fs["N" + s] = (e, NATIONAL_STRING)
  }
  // Python builds {n.., N..} with a single comprehension ordered by quotes then prefix
  let fs2 : Map[String, (String, TokenType)] = Map([])
  for s, e in self.quotes_map {
    fs2["n" + s] = (e, NATIONAL_STRING)
    fs2["N" + s] = (e, NATIONAL_STRING)
  }
  let fs = fs2
  for pair in [
    (self.bit_strings, BIT_STRING),
    (self.byte_strings, BYTE_STRING),
    (self.hex_strings, HEX_STRING),
    (self.raw_strings, RAW_STRING),
    (self.heredoc_strings, HEREDOC_STRING),
    (self.unicode_strings, UNICODE_STRING),
  ] {
    for k, v in convert_quotes(pair.0) {
      fs[k] = (v, pair.1)
    }
  }
  self.format_strings = fs
  let byte_escapes = match self.byte_string_escapes {
    Some(b) => b
    None => self.string_escapes.copy()
  }
  self.string_escapes_set = str_set(self.string_escapes)
  self.byte_string_escapes_set = str_set(byte_escapes)
  self.escape_follow_chars_set = str_set(self.escape_follow_chars)
  self.identifier_escapes_set = str_set(self.identifier_escapes)
  let cm : Map[String, String?] = Map([])
  for c in self.comments {
    match c {
      Same(s) => cm[s] = None
      Pair(_, _) => ()
    }
  }
  for c in self.comments {
    match c {
      Pair(s, e) => cm[s] = Some(e)
      Same(_) => ()
    }
  }
  cm["{#"] = Some("#}")
  if self.keywords.contains(self.hint_start) {
    cm[self.hint_start] = Some("*/")
  }
  self.comments_map = cm
  let trie = Trie::new()
  fn consider(key : String) -> Unit {
    let mut ok = key.contains(" ")
    if !ok {
      for c in key {
        if self.single_tokens.contains(c) {
          ok = true
          break
        }
      }
    }
    if ok {
      trie.add(py_upper(key))
    }
  }

  for k, _ in self.keywords {
    consider(k)
  }
  for k, _ in cm {
    consider(k)
  }
  for k, _ in self.quotes_map {
    consider(k)
  }
  for k, _ in fs {
    consider(k)
  }
  self.keyword_trie = trie
  self.commands_set = Map([])
  for t in self.commands {
    self.commands_set[t] = true
  }
  self
}

///|
/// Tokenizer state for a single `tokenize` call.
pub struct Tokenizer {
  settings : TokenizerSettings
  // dialect-level settings
  numbers_can_be_underscore_separated : Bool
  identifiers_can_start_with_digit : Bool
  unescaped_sequences : Map[String, String]
  mut sql : Array[Char]
  mut sql_str : String
  mut size : Int
  mut tokens : Array[Token]
  mut start : Int
  mut current : Int
  mut line : Int
  mut col : Int
  mut comments : Array[String]
  mut char : Char
  mut end : Bool
  mut peek : Char
  mut prev_token_line : Int
}

///|
/// The "empty string" character used where Python uses `""` (a noncharacter that
/// never appears in SQL text).
let nul : Char = '\u{10FFFF}'

///|
pub fn Tokenizer::new(
  settings : TokenizerSettings,
  numbers_can_be_underscore_separated? : Bool = false,
  identifiers_can_start_with_digit? : Bool = false,
  unescaped_sequences? : Map[String, String] = Map([]),
) -> Tokenizer {
  {
    settings,
    numbers_can_be_underscore_separated,
    identifiers_can_start_with_digit,
    unescaped_sequences,
    sql: [],
    sql_str: "",
    size: 0,
    tokens: [],
    start: 0,
    current: 0,
    line: 1,
    col: 0,
    comments: [],
    char: nul,
    end: false,
    peek: nul,
    prev_token_line: -1,
  }
}

///|
fn Tokenizer::reset(self : Tokenizer) -> Unit {
  self.sql = []
  self.sql_str = ""
  self.size = 0
  self.tokens = []
  self.start = 0
  self.current = 0
  self.line = 1
  self.col = 0
  self.comments = []
  self.char = nul
  self.end = false
  self.peek = nul
  self.prev_token_line = -1
}

///|
/// Returns a list of tokens corresponding to the SQL string `sql`.
pub fn Tokenizer::tokenize(
  self : Tokenizer,
  sql : String,
) -> Array[Token] raise SqlglotError {
  self.reset()
  self.sql_str = sql
  self.sql = sql.to_array()
  self.size = self.sql.length()
  self.scan() catch {
    e => {
      let start = @cmp.maximum(self.current - 50, 0)
      let end = @cmp.minimum(self.current + 50, self.size - 1)
      let context = self.slice(start, end)
      raise TokenError("Error tokenizing '\{context}'") // original: \{e}
      |> ignore_err(e)
    }
  }
  self.tokens
}

///|
fn[T] ignore_err(x : T, _e : Error) -> T {
  x
}

///|
fn Tokenizer::slice(self : Tokenizer, start : Int, end : Int) -> String {
  let n = self.size
  let a = if start < 0 { 0 } else if start > n { n } else { start }
  let b = if end < 0 { 0 } else if end > n { n } else { end }
  if a >= b {
    ""
  } else {
    String::from_array(self.sql[a:b])
  }
}

///|
fn Tokenizer::at(self : Tokenizer, i : Int) -> Char {
  if i >= 0 && i < self.size {
    self.sql[i]
  } else {
    nul
  }
}

///|
fn Tokenizer::scan(
  self : Tokenizer,
  check_semicolon? : Bool = false,
) -> Unit raise SqlglotError {
  while self.size > 0 && !self.end {
    let mut current = self.current
    while current < self.size {
      let char = self.sql[current]
      if char == ' ' || char == '\t' {
        current += 1
      } else {
        break
      }
    }
    let offset = if current > self.current {
      current - self.current
    } else {
      1
    }
    self.start = current
    self.advance(i=offset)
    if !is_space(self.char) {
      if is_digit_char(self.char) {
        self.scan_number()
      } else if self.settings.identifier_chars.get(self.char) is Some(id_end) {
        self.scan_identifier(id_end)
      } else {
        self.scan_keywords()
      }
    }
    if check_semicolon && self.peek == ';' {
      break
    }
  }
  if !self.tokens.is_empty() && !self.comments.is_empty() {
    self.tokens[self.tokens.length() - 1].comments.append(self.comments)
  }
}

///|
fn Tokenizer::chars(self : Tokenizer, size : Int) -> String {
  if size == 1 {
    return if self.char == nul { "" } else { self.char.to_string() }
  }
  let start = self.current - 1
  let end = start + size
  if end <= self.size {
    self.slice(start, end)
  } else {
    ""
  }
}

///|
fn Tokenizer::advance(self : Tokenizer, i? : Int = 1, alnum? : Bool = false) -> Unit {
  let char = self.char
  if char == '\n' || char == '\r' {
    if !(char == '\r' && self.peek == '\n') {
      self.col = i
      self.line += 1
    }
  } else {
    self.col += i
  }
  self.current += i
  self.end = self.current >= self.size
  self.char = self.at(self.current - 1)
  self.peek = if self.end { nul } else { self.sql[self.current] }
  if alnum && is_alnum(self.char) {
    let mut col = self.col
    let mut current = self.current
    let mut end = self.end
    let mut peek = self.peek
    while peek != nul && is_alnum(peek) {
      col += 1
      current += 1
      end = current >= self.size
      peek = if end { nul } else { self.sql[current] }
    }
    self.col = col
    self.current = current
    self.end = end
    self.peek = peek
    self.char = self.sql[current - 1]
  }
}

///|
fn Tokenizer::text(self : Tokenizer) -> String {
  self.slice(self.start, self.current)
}

///|
fn Tokenizer::add(
  self : Tokenizer,
  token_type : TokenType,
  text? : String,
) -> Unit raise SqlglotError {
  self.prev_token_line = self.line
  if !self.comments.is_empty() &&
    token_type == SEMICOLON &&
    !self.tokens.is_empty() {
    self.tokens[self.tokens.length() - 1].comments.append(self.comments)
    self.comments = []
  }
  let text = match text {
    Some(t) => t
    None => self.slice(self.start, self.current)
  }
  self.tokens.push({
    token_type,
    text,
    line: self.line,
    col: self.col,
    start: self.start,
    end: self.current - 1,
    comments: self.comments,
  })
  self.comments = []
  if self.settings.commands_set.contains(token_type) &&
    self.peek != ';' &&
    (self.tokens.length() == 1 ||
    self.settings.command_prefix_tokens.contains(
      self.tokens[self.tokens.length() - 2].token_type,
    )) {
    let start = self.current
    let ntokens = self.tokens.length()
    self.scan(check_semicolon=true)
    while self.tokens.length() > ntokens {
      self.tokens.pop() |> ignore
    }
    let text = py_strip(self.slice(start, self.current))
    if !text.is_empty() {
      self.add(STRING, text~)
    }
  }
}

///|
fn Tokenizer::scan_keywords(self : Tokenizer) -> Unit raise SqlglotError {
  let single_tokens = self.settings.single_tokens
  let mut size = 0
  let mut word : String? = None
  let chars = StringBuilder()
  chars.write_char(self.char)
  let mut char = self.char
  let mut prev_space = false
  let mut skip = false
  let mut trie = self.settings.keyword_trie
  let mut single_token = single_tokens.contains(char)
  let mut has_chars = true
  while has_chars {
    if !skip {
      let up = if char.to_int() < 128 { char.to_ascii_uppercase() } else { char }
      match trie.get(up) {
        None => break
        Some(sub) => {
          trie = sub
          if trie.terminal {
            word = Some(chars.to_string())
          }
        }
      }
    }
    let end = self.current + size
    size += 1
    if end < self.size {
      char = self.sql[end]
      single_token = single_token || single_tokens.contains(char)
      let is_space_ = is_space(char)
      if !is_space_ || !prev_space {
        if is_space_ {
          char = ' '
        }
        chars.write_char(char)
        prev_space = is_space_
        skip = false
      } else {
        skip = true
      }
    } else {
      char = nul
      has_chars = false
      break
    }
  }
  match word {
    Some(w) => {
      if self.scan_string(w) {
        return
      }
      if self.scan_comment(w) {
        return
      }
      if prev_space || single_token || char == nul {
        self.advance(i=size - 1)
        let w = py_upper(w)
        match self.settings.keywords.get(w) {
          Some(tt) => {
            self.add(tt, text=w)
            return
          }
          None => raise TokenError("Unknown keyword \{w}")
        }
      }
    }
    None => ()
  }
  match single_tokens.get(self.char) {
    Some(tt) => {
      self.add(tt, text=self.char.to_string())
      return
    }
    None => ()
  }
  self.scan_var()
}

///|
fn Tokenizer::scan_comment(
  self : Tokenizer,
  comment_start : String,
) -> Bool raise SqlglotError {
  let comment_end = match self.settings.comments_map.get(comment_start) {
    Some(e) => e
    None => return false
  }
  let comment_start_line = self.line
  let comment_start_size = py_len(comment_start)
  match comment_end {
    Some(comment_end) => {
      self.advance(i=comment_start_size)
      let mut comment_count = 1
      let comment_end_size = py_len(comment_end)
      while !self.end {
        if self.chars(comment_end_size) == comment_end {
          comment_count -= 1
          if comment_count == 0 {
            break
          }
        }
        self.advance(alnum=true)
        if self.settings.nested_comments &&
          !self.end &&
          self.chars(comment_end_size) == comment_start {
          self.advance(i=comment_start_size)
          comment_count += 1
        }
      }
      let text = self.text()
      self.comments.push(
        substr(text, comment_start_size, -comment_end_size + 1),
      )
      self.advance(i=comment_end_size - 1)
    }
    None => {
      while !self.end && self.peek != '\n' && self.peek != '\r' {
        self.advance(alnum=true)
      }
      let text = self.text()
      self.comments.push(substr(text, comment_start_size, py_len(text)))
    }
  }
  if comment_start == self.settings.hint_start &&
    !self.tokens.is_empty() &&
    self.settings.tokens_preceding_hint.contains(
      self.tokens[self.tokens.length() - 1].token_type,
    ) {
    self.add(HINT)
  }
  if comment_start_line == self.prev_token_line {
    self.tokens[self.tokens.length() - 1].comments.append(self.comments)
    self.comments = []
    self.prev_token_line = self.line
  }
  true
}

///|
fn upper_char(c : Char) -> Char {
  if c.to_int() < 128 {
    c.to_ascii_uppercase()
  } else {
    c
  }
}

///|
fn Tokenizer::scan_number(self : Tokenizer) -> Unit raise SqlglotError {
  if self.char == '0' {
    let peek = upper_char(self.peek)
    if peek == 'B' && !self.settings.bit_strings.is_empty() {
      return self.scan_bits()
    } else if peek == 'X' {
      if !self.settings.hex_strings.is_empty() {
        return self.scan_hex()
      } else {
        return self.add(NUMBER)
      }
    }
  }
  let mut decimal = false
  let mut scientific = 0
  let mut is_underscore_separated = false
  let mut number_text = ""
  let numeric_literal = StringBuilder()
  let mut numeric_type : TokenType? = None
  while true {
    if is_digit_char(self.peek) {
      let mut end = self.current + 1
      while end < self.size && is_digit_char(self.sql[end]) {
        end += 1
      }
      self.advance(i=end - self.current)
    } else if self.peek == '.' && !decimal {
      if (!self.tokens.is_empty() &&
        self.tokens[self.tokens.length() - 1].token_type == PARAMETER) ||
        !self.settings.numbers_can_have_decimals {
        break
      }
      decimal = true
      self.advance()
    } else if (self.peek == '-' || self.peek == '+') && scientific == 1 {
      if self.current + 1 < self.size &&
        is_digit_char(self.sql[self.current + 1]) {
        scientific += 1
        self.advance()
      } else {
        break
      }
    } else if upper_char(self.peek) == 'E' && scientific == 0 {
      scientific += 1
      self.advance()
    } else if self.peek == '_' && self.numbers_can_be_underscore_separated {
      is_underscore_separated = true
      self.advance()
    } else if self.peek != nul && is_identifier_char(self.peek) {
      number_text = self.text()
      while self.peek != nul &&
            !is_space(self.peek) &&
            !self.settings.single_tokens.contains(self.peek) {
        numeric_literal.write_char(self.peek)
        self.advance()
      }
      let lit = numeric_literal.to_string()
      numeric_type = match self.settings.numeric_literals.get(py_upper(lit)) {
        Some(k) => self.settings.keywords.get(k)
        None => None
      }
      if numeric_type is Some(_) {
        break
      } else if self.identifiers_can_start_with_digit {
        return self.add(VAR)
      }
      self.advance(i=-py_len(lit))
      numeric_literal.reset()
      break
    } else {
      break
    }
  }
  if number_text.is_empty() {
    number_text = self.slice(self.start, self.current)
  }
  if is_underscore_separated {
    number_text = number_text.replace_all(old="_", new="")
  }
  self.add(NUMBER, text=number_text)
  match numeric_type {
    Some(nt) => {
      self.add(DCOLON, text="::")
      self.add(nt, text=numeric_literal.to_string())
    }
    None => ()
  }
}

///|
fn is_valid_int(value : String, base : Int) -> Bool {
  // Python int(value, base) accepts an optional 0b/0x prefix and underscores
  let mut v = py_strip(value)
  if v.is_empty() {
    return false
  }
  if v.has_prefix("+") || v.has_prefix("-") {
    v = substr(v, 1, py_len(v))
  }
  let lower = py_lower(v)
  if base == 2 && lower.has_prefix("0b") {
    v = substr(v, 2, py_len(v))
    if v.has_prefix("_") {
      v = substr(v, 1, py_len(v))
    }
  } else if base == 16 && lower.has_prefix("0x") {
    v = substr(v, 2, py_len(v))
    if v.has_prefix("_") {
      v = substr(v, 1, py_len(v))
    }
  }
  if v.is_empty() {
    return false
  }
  let mut prev_us = true
  for c in v {
    if c == '_' {
      if prev_us {
        return false
      }
      prev_us = true
      continue
    }
    let ok = if base == 2 {
      c == '0' || c == '1'
    } else {
      c.is_ascii_hexdigit()
    }
    if !ok {
      return false
    }
    prev_us = false
  }
  !prev_us
}

///|
fn Tokenizer::scan_bits(self : Tokenizer) -> Unit raise SqlglotError {
  self.advance()
  let value = self.extract_value()
  if is_valid_int(value, 2) {
    self.add(BIT_STRING, text=substr(value, 2, py_len(value)))
  } else {
    self.add(IDENTIFIER)
  }
}

///|
fn Tokenizer::scan_hex(self : Tokenizer) -> Unit raise SqlglotError {
  self.advance()
  let value = self.extract_value()
  if is_valid_int(value, 16) {
    self.add(HEX_STRING, text=substr(value, 2, py_len(value)))
  } else {
    self.add(IDENTIFIER)
  }
}

///|
fn Tokenizer::extract_value(self : Tokenizer) -> String {
  while true {
    let char = self.peek
    if char != nul &&
      !is_space(char) &&
      !self.settings.single_tokens.contains(char) {
      self.advance(alnum=true)
    } else {
      break
    }
  }
  self.text()
}

///|
fn Tokenizer::scan_string(self : Tokenizer, start : String) -> Bool raise SqlglotError {
  let mut base = 0
  let mut token_type = STRING
  let mut end = ""
  match self.settings.quotes_map.get(start) {
    Some(e) => end = e
    None =>
      match self.settings.format_strings.get(start) {
        Some((e, tt)) => {
          end = e
          token_type = tt
          if tt == HEX_STRING {
            base = 16
          } else if tt == BIT_STRING {
            base = 2
          } else if tt == HEREDOC_STRING {
            self.advance()
            let tag = if self.char.to_string() == end {
              ""
            } else {
              self.extract_string(
                end,
                raw_string=true,
                raise_unmatched=!self.settings.heredoc_tag_is_identifier,
              )
            }
            if !tag.is_empty() &&
              self.settings.heredoc_tag_is_identifier &&
              (self.end || str_is_digit(tag) || tag.iter().any(is_space)) {
              if !self.end {
                self.advance(i=-1)
              }
              self.advance(i=-py_len(tag))
              self.add(self.settings.heredoc_string_alternative)
              return true
            }
            end = start + tag + end
          }
        }
        None => return false
      }
  }
  self.advance(i=py_len(start))
  let escapes = if token_type == BYTE_STRING {
    self.settings.byte_string_escapes_set
  } else {
    self.settings.string_escapes_set
  }
  let text = self.extract_string(
    end,
    escapes~,
    raw_string=token_type == RAW_STRING,
  )
  if base != 0 && !text.is_empty() {
    if !is_valid_int(text, base) {
      raise TokenError(
        "Numeric string contains invalid characters from \{self.line}:\{self.start}",
      )
    }
  }
  self.add(token_type, text~)
  true
}

///|
fn Tokenizer::scan_identifier(
  self : Tokenizer,
  identifier_end : String,
) -> Unit raise SqlglotError {
  self.advance()
  let escapes = Map::from_iter(self.settings.identifier_escapes_set.iter())
  escapes[identifier_end] = true
  let text = self.extract_string(identifier_end, escapes~)
  self.add(IDENTIFIER, text~)
}

///|
fn Tokenizer::scan_var(self : Tokenizer) -> Unit raise SqlglotError {
  while true {
    let peek = self.peek
    if peek == nul || is_space(peek) {
      break
    }
    if !self.settings.var_single_tokens.contains(peek) &&
      self.settings.single_tokens.contains(peek) {
      break
    }
    self.advance(alnum=true)
  }
  let tt = if !self.tokens.is_empty() &&
    self.tokens[self.tokens.length() - 1].token_type == PARAMETER {
    VAR
  } else {
    match self.settings.keywords.get(py_upper(self.slice(self.start, self.current))) {
      Some(t) => t
      None => VAR
    }
  }
  self.add(tt)
}

///|
fn digit_value(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    16
  }
}

///|
fn Tokenizer::read_numeric_escape(
  self : Tokenizer,
  start : Int,
  spec : NumericEscape,
) -> (Int, Int) {
  let mut value = 0
  let mut end = start
  let limit = @cmp.minimum(start + spec.max_digits, self.size)
  while end < limit {
    let digit = digit_value(self.sql[end])
    if digit >= spec.base || value * spec.base + digit > spec.max_value {
      break
    }
    value = value * spec.base + digit
    end += 1
  }
  if end - start >= spec.min_digits {
    (value, end)
  } else {
    (-1, end)
  }
}

///|
fn Tokenizer::scan_numeric_escape(self : Tokenizer) -> String {
  let start = self.current
  let peek = self.peek
  let is_octal = peek >= '0' && peek <= '7'
  let key = if is_octal { "0" } else { peek.to_string() }
  match self.settings.numeric_escapes.get(key) {
    Some(spec) => {
      let (value0, end0) = self.read_numeric_escape(
        if is_octal {
          start
        } else {
          start + 1
        },
        spec,
      )
      let mut value = value0
      let mut end = end0
      if value >= 0xD800 && value <= 0xDFFF {
        let mut low = -1
        let mut low_end = end
        if value <= 0xDBFF &&
          self.slice(end, end + 2) == "\\" + peek.to_string() {
          let (l, le) = self.read_numeric_escape(end + 2, spec)
          low = l
          low_end = le
        }
        if low >= 0xDC00 && low <= 0xDFFF {
          value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
          end = low_end
        } else {
          value = -1
        }
      }
      if value >= 0 && end < self.size {
        self.advance(i=end - start + 1)
        return Int::unsafe_to_char(value).to_string()
      }
      ""
    }
    None => ""
  }
}

///|
fn Tokenizer::extract_string(
  self : Tokenizer,
  delimiter : String,
  escapes? : Map[String, Bool],
  raw_string? : Bool = false,
  raise_unmatched? : Bool = true,
) -> String raise SqlglotError {
  let text = StringBuilder()
  let delim_size = py_len(delimiter)
  let escapes = match escapes {
    Some(e) => e
    None => self.settings.string_escapes_set
  }
  let unescaped_sequences = self.unescaped_sequences
  let escape_follow_chars = self.settings.escape_follow_chars_set
  let numeric_escapes = self.settings.numeric_escapes
  let drop_unknown_escapes = self.settings.drop_unknown_escapes
  let string_escapes_allowed_in_raw_strings = self.settings.string_escapes_allowed_in_raw_strings
  let quotes = self.settings.quotes_map
  let backslash_in_escapes = escapes.contains("\\")
  if delim_size == 1 {
    let delim = delimiter.get_char(0).unwrap()
    let pos = self.current - 1
    let mut end = -1
    for i in pos..<self.size {
      if self.sql[i] == delim {
        end = i
        break
      }
    }
    let mut ok = end != -1
    if ok {
      ok = end + 1 >= self.size ||
        self.sql[end + 1] != delim ||
        !escapes.contains(delimiter)
    }
    if ok && (!unescaped_sequences.is_empty() || backslash_in_escapes) {
      for i in pos..<end {
        if self.sql[i] == '\\' {
          ok = false
          break
        }
      }
    }
    if ok {
      let mut newlines = 0
      let mut last_nl = -1
      for i in pos..<end {
        if self.sql[i] == '\n' {
          newlines += 1
          last_nl = i
        }
      }
      if newlines > 0 {
        self.line += newlines
        self.col = end - last_nl
      } else {
        self.col += end - pos
      }
      self.current = end + 1
      self.end = self.current >= self.size
      self.char = self.sql[end]
      self.peek = if self.end { nul } else { self.sql[self.current] }
      return self.slice(pos, end)
    }
  }
  while true {
    let backslash_escape = !raw_string && self.char == '\\' && backslash_in_escapes
    if backslash_escape && !numeric_escapes.is_empty() {
      let decoded = self.scan_numeric_escape()
      if !decoded.is_empty() {
        text.write_string(decoded)
        continue
      }
    }
    let char_s = self.char.to_string()
    if !raw_string &&
      !unescaped_sequences.is_empty() &&
      escapes.contains(char_s) &&
      self.current + 1 < self.size {
      match unescaped_sequences.get(char_s + self.peek.to_string()) {
        Some(seq) if !seq.is_empty() => {
          if self.peek == '\n' || self.peek == '\r' {
            self.advance()
            self.advance()
          } else {
            self.advance(i=2)
          }
          text.write_string(seq)
          continue
        }
        _ => ()
      }
    }
    if backslash_escape &&
      drop_unknown_escapes &&
      self.current + 1 < self.size {
      let peek = self.peek
      self.advance()
      self.advance()
      text.write_char(peek)
      continue
    }
    let peek_s = if self.peek == nul { "" } else { self.peek.to_string() }
    let is_valid_custom_escape = !escape_follow_chars.is_empty() &&
      self.char == '\\' &&
      !escape_follow_chars.contains(peek_s)
    let escaped_delimiter = peek_s == delimiter ||
      (delim_size > 1 &&
      self.peek == delimiter.get_char(0).unwrap() &&
      quotes.contains(peek_s))
    if (string_escapes_allowed_in_raw_strings || !raw_string) &&
      escapes.contains(char_s) &&
      (escaped_delimiter || escapes.contains(peek_s) || is_valid_custom_escape) &&
      (!quotes.contains(char_s) || self.char == self.peek) {
      if escaped_delimiter {
        if !raw_string {
          text.write_string(peek_s)
        } else {
          text.write_string(char_s + peek_s)
        }
      } else if is_valid_custom_escape && self.char != self.peek {
        text.write_string(peek_s)
      } else {
        text.write_string(char_s + peek_s)
      }
      if self.current + 1 < self.size {
        self.advance(i=2)
      } else {
        raise TokenError("Missing \{delimiter} from \{self.line}:\{self.current}")
      }
    } else {
      if self.chars(delim_size) == delimiter {
        if delim_size > 1 {
          self.advance(i=delim_size - 1)
        }
        break
      }
      if self.end {
        if !raise_unmatched {
          return text.to_string() + char_s
        }
        raise TokenError("Missing \{delimiter} from \{self.line}:\{self.start}")
      }
      let current = self.current - 1
      self.advance(alnum=true)
      text.write_string(self.slice(current, self.current - 1))
    }
  }
  text.to_string()
}
