// Port of sqlglot/anonymize.py: replaces sensitive tokens (identifiers, strings,
// numbers) with fixed-width, length-preserving, consistent aliases and blanks out
// comments and hint bodies.
//
// Token positions (`start`, `end`) count characters (code points), like Python's
// string indices, so all source slicing below works on `Array[Char]`.

///|
let alphabet : Array[Char] = "abcdefghijklmnopqrstuvwxyz".to_array()

///|
fn is_anonymized_type(t : @core.TokenType) -> Bool {
  t
  is (BIT_STRING
  | BYTE_STRING
  | HEX_STRING
  | HEREDOC_STRING
  | IDENTIFIER
  | NATIONAL_STRING
  | NUMBER
  | RAW_STRING
  | STRING
  | UNICODE_STRING
  | VAR)
}

///|
/// `QUOTED_TYPES = ANONYMIZED_TYPES - {NUMBER, VAR}`
fn is_quoted_type(t : @core.TokenType) -> Bool {
  is_anonymized_type(t) && !(t is (NUMBER | VAR))
}

///|
/// `REWRITTEN_TYPES = {HINT, UNKNOWN}`
fn is_rewritten_type(t : @core.TokenType) -> Bool {
  t is (HINT | UNKNOWN)
}

///|
/// Replaces sensitive tokens (identifiers, strings, numbers) of `sql` with
/// fixed-width, length-preserving, consistent aliases, and blanks out comments and
/// hint bodies. `sql` is tokenized with `dialect` first; any un-tokenized remainder
/// (e.g. an unterminated literal) is appended as a blanked `UNKNOWN` token.
///
/// `dialect` is a dialect name as accepted by `Dialect::get_or_raise` (dialects
/// are registered by the `hongbozhang/sqlglot` facade package).
pub fn anonymize(
  sql : String,
  dialect? : String = "",
) -> Array[@core.Token] raise @core.SqlglotError {
  let d = @core.Dialect::get_or_raise(dialect)
  let (tokens, errored) = tokenize_partial(d, sql)
  anonymize_impl(tokens, d)
  if errored {
    let chars = sql.to_array()
    let length = chars.length()
    let mut start = match tokens.last() {
      Some(t) => t.end + 1
      None => 0
    }
    while start < length && @core.is_space(chars[start]) {
      start += 1
    }
    if start < length {
      // The first two characters are kept so that the delimiter the tokenizer choked
      // on is still visible, e.g. 'u, /*, $$, `u
      let text = String::from_array(slice(chars, start, start + 2)) +
        ".".repeat(@cmp.maximum(length - start - 2, 0))
      let mut newlines = 0
      let mut last_newline = -1
      for i in 0..<start {
        if chars[i] == '\n' {
          newlines += 1
          last_newline = i
        }
      }
      tokens.push(
        @core.Token::new(
          UNKNOWN,
          text,
          start~,
          end=length - 1,
          line=newlines + 1,
          col=start - last_newline,
        ),
      )
    }
  }
  tokens
}

///|
/// `anonymize` for an already tokenized statement: rewrites `tokens` in place and
/// returns it.
pub fn anonymize_tokens(
  tokens : Array[@core.Token],
  dialect? : String = "",
) -> Array[@core.Token] raise @core.SqlglotError {
  anonymize_impl(tokens, @core.Dialect::get_or_raise(dialect))
  tokens
}

///|
/// Tokenizes `sql` like `dialect.tokenizer().tokenize(sql)`, returning the tokens
/// produced before a `TokenError` (and whether one occurred).
fn tokenize_partial(
  d : @core.Dialect,
  sql : String,
) -> (Array[@core.Token], Bool) {
  let tokenizer = @core.Tokenizer::new(
    d.tokenizer,
    numbers_can_be_underscore_separated=d.cfg.numbers_can_be_underscore_separated,
    identifiers_can_start_with_digit=d.cfg.identifiers_can_start_with_digit,
    unescaped_sequences=d.cfg.unescaped_sequences,
  )
  match d.hooks.tokenize {
    // A tokenizer subclass overriding `tokenize` (Athena): on failure, the
    // tokenizer's own state is whatever its base `tokenize` produced.
    Some(f) =>
      try f(d, sql) catch {
        _ => {
          let tokens = tokenizer.tokenize(sql) catch { _ => tokenizer.tokens }
          (tokens, true)
        }
      } noraise {
        tokens => (tokens, false)
      }
    None =>
      try tokenizer.tokenize(sql) catch {
        _ => (tokenizer.tokens, true)
      } noraise {
        tokens => (tokens, false)
      }
  }
}

///|
fn anonymize_impl(tokens : Array[@core.Token], d : @core.Dialect) -> Unit {
  let settings = d.tokenizer
  let hint_start = settings.hint_start
  let hint_end = match settings.comments_map.get(hint_start) {
    Some(Some(e)) => Some(e)
    _ => None
  }
  let nested = settings.nested_comments
  let functions = d.parser_fns.functions
  let function_parsers = d.parser_fns.function_parsers
  let seen : Map[(Bool, String), String] = Map([])
  let mut counter = 0
  for i in 0..<tokens.length() {
    let token = tokens[i]
    let comments = token.comments.map(c => blank(c.to_array()))
    fn update(text : String) -> Unit {
      tokens[i] = @core.Token::new(
        token.token_type,
        text,
        line=token.line,
        col=token.col,
        start=token.start,
        end=token.end,
        comments~,
      )
    }

    if token.token_type is HINT {
      // A hint's text is the whole /*+ ... */ comment, so its body is blanked as well
      let text = token.text.to_array()
      let (blanked, stop) = blank_comment(text, 0, hint_start, hint_end, nested)
      update(blanked + blank(slice(text, stop, text.length())))
      continue
    }
    if token.token_type is VAR &&
      i + 1 < tokens.length() &&
      tokens[i + 1].token_type is L_PAREN {
      // A function name can live in either registry, e.g. JSON_OBJECT is only in
      // FUNCTION_PARSERS.
      let name = @core.py_upper(token.text)
      if functions.contains(name) || function_parsers.contains(name) {
        update(token.text)
        continue
      }
    }
    if !is_anonymized_type(token.token_type) || token.text.is_empty() {
      update(token.text)
      continue
    }
    let is_number = token.token_type is NUMBER
    let key = (is_number, token.text)
    if seen.get(key) is None {
      seen[key] = if is_number {
        number_alias(counter, token.text)
      } else {
        word_alias(counter, token.text)
      }
      counter += 1
    }
    update(seen[key])
  }
}

///|
/// Recreates the (anonymized) SQL string from the original `sql` and token
/// positions. Every token is rendered over its own source span, so the result is
/// always as long as `sql`: a token that wasn't anonymized is emitted verbatim, and
/// an anonymized one has its alias fitted between the quotes of its span. The gaps
/// between tokens are redacted: comment markers and whitespace survive, everything
/// else is blanked.
pub fn render(
  sql : String,
  tokens : Array[@core.Token],
  dialect? : String = "",
) -> String raise @core.SqlglotError {
  let settings = @core.Dialect::get_or_raise(dialect).tokenizer
  let comments : Array[(String, String?)] = settings.comments_map
    .to_array()
    .map(kv => (kv.0, kv.1))
  stable_sort_desc(comments, c => [c.0.to_array().length()])
  let nested = settings.nested_comments
  let quote_map : Map[String, String] = Map([])
  for k, v in settings.quotes_map {
    quote_map[k] = v
  }
  for k, v in settings.format_strings {
    quote_map[k] = v.0
  }
  for k, v in settings.identifiers_map {
    quote_map[k] = v
  }
  let quotes = quote_map.to_array()
  stable_sort_desc(quotes, q => {
    [q.0.to_array().length(), q.1.to_array().length()]
  })
  let chars = sql.to_array()
  let result = StringBuilder()
  let mut prev = 0
  for token in tokens {
    result.write_string(
      redact(slice(chars, prev, token.start), comments, nested),
    )
    prev = token.end + 1
    let span = slice(chars, token.start, prev)
    if is_rewritten_type(token.token_type) {
      // Blanked in place by `anonymize`, or synthesized by it, so already span-shaped
      result.write_string(token.text)
    } else if is_anonymized_type(token.token_type) {
      result.write_string(fit(span, token.text, quotes, token.token_type))
    } else {
      result.write_string(String::from_array(span))
    }
  }
  result.write_string(
    redact(slice(chars, prev, chars.length()), comments, nested),
  )
  result.to_string()
}

///|
/// Python `s[a:b]` for non-negative bounds.
fn slice(s : Array[Char], a : Int, b : Int) -> ArrayView[Char] {
  let n = s.length()
  let a = @cmp.minimum(@cmp.maximum(a, 0), n)
  let b = @cmp.minimum(@cmp.maximum(b, 0), n)
  if a >= b {
    s[0:0]
  } else {
    s[a:b]
  }
}

///|
/// Python's `sorted(items, key=key, reverse=True)`: stable, descending.
fn[T] stable_sort_desc(items : Array[T], key : (T) -> Array[Int]) -> Unit {
  fn greater(a : Array[Int], b : Array[Int]) -> Bool {
    for i in 0..<a.length() {
      if a[i] != b[i] {
        return a[i] > b[i]
      }
    }
    false
  }

  // insertion sort: only moves an item past strictly smaller keys
  for i in 1..<items.length() {
    let item = items[i]
    let k = key(item)
    let mut j = i
    while j > 0 && greater(k, key(items[j - 1])) {
      items[j] = items[j - 1]
      j -= 1
    }
    items[j] = item
  }
}

///|
fn starts_with_at(s : ArrayView[Char], prefix : String, i : Int) -> Bool {
  let p = prefix.to_array()
  if i < 0 || i + p.length() > s.length() {
    return false
  }
  for k in 0..<p.length() {
    if s[i + k] != p[k] {
      return false
    }
  }
  true
}

///|
/// Python `s.find(needle, start)`.
fn find_from(s : ArrayView[Char], needle : String, start : Int) -> Int {
  let n = needle.to_array().length()
  for i = @cmp.maximum(start, 0); i + n <= s.length(); i = i + 1 {
    if starts_with_at(s, needle, i) {
      return i
    }
  }
  -1
}

///|
/// Python `s.rfind(needle, 0, end)`.
fn rfind_before(s : ArrayView[Char], needle : String, end : Int) -> Int {
  let n = needle.to_array().length()
  for i = @cmp.minimum(end, s.length()) - n; i >= 0; i = i - 1 {
    if starts_with_at(s, needle, i) {
      return i
    }
  }
  -1
}

///|
fn word_alias(counter : Int, text : String) -> String {
  let digits : Array[Char] = []
  let mut c = counter
  while c != 0 {
    digits.push(alphabet[c % 26])
    c = c / 26
  }
  digits.rev_in_place()
  let mut width = 0
  for ch in text {
    if !@core.is_space(ch) {
      width += 1
    }
  }
  let letters : Array[Char] = []
  for _ in digits.length()..<width {
    letters.push('a')
  }
  letters.append(digits)
  let sb = StringBuilder()
  let mut i = 0
  for ch in text {
    if @core.is_space(ch) {
      sb.write_char(ch)
    } else {
      sb.write_char(letters[i])
      i += 1
    }
  }
  sb.to_string()
}

///|
fn pow10(n : Int) -> @bigint.BigInt {
  @bigint.BigInt::from_int(10).pow(@bigint.BigInt::from_int(n))
}

///|
fn number_alias(counter : Int, text : String) -> String {
  let chars = text.to_array()
  if chars.length() > 4000 {
    let mut digits_seen = false
    let sb = StringBuilder()
    for ch in chars {
      if @core.is_py_digit(ch) {
        sb.write_char(if digits_seen { '0' } else { '1' })
        digits_seen = true
      } else {
        sb.write_char(ch)
      }
    }
    return sb.to_string()
  }
  let sep = if text.contains("e") {
    "e"
  } else if text.contains("E") {
    "E"
  } else {
    ""
  }
  let (mantissa, exponent) = if sep.is_empty() {
    (text, "")
  } else {
    let parts = @core.py_split(text, sep)
    (parts[0], parts[1:].join(sep))
  }
  let (sign, exponent) = if exponent.has_prefix("-") || exponent.has_prefix("+") {
    (
      exponent.view(end_offset=1).to_owned(),
      exponent.view(start_offset=1).to_owned(),
    )
  } else {
    ("", exponent)
  }
  let exponent_length = exponent.length()
  let (integer, has_dot, fraction) = match mantissa.find(".") {
    Some(p) =>
      (
        mantissa.view(end_offset=p).to_owned(),
        true,
        mantissa.view(start_offset=p + 1).to_owned(),
      )
    None => (mantissa, false, "")
  }
  let integer_length = integer.length()
  let digits = integer_length + fraction.length()
  let counter_b = @bigint.BigInt::from_int(counter)
  let nine = @bigint.BigInt::from_int(9)
  let modulus = nine * pow10(digits - 1)
  let mantissa_value = pow10(digits - 1) + counter_b % modulus
  let mut result = mantissa_value.to_string()
  if has_dot {
    let rc = result.to_array()
    result = String::from_array(slice(rc, 0, integer_length)) +
      "." +
      String::from_array(slice(rc, integer_length, rc.length()))
  }
  if !sep.is_empty() {
    // The exponent marker is kept even when there are no digits after it, e.g. 1e
    result = result + sep + sign
    if exponent_length > 0 {
      let exponent_value = pow10(exponent_length - 1) +
        counter_b / modulus % (nine * pow10(exponent_length - 1))
      result = result + exponent_value.to_string()
    }
  }
  result
}

///|
/// Fits `alias_text` into the quoted region of `span`, so the two are always the same length.
fn fit(
  span : ArrayView[Char],
  alias_text : String,
  quotes : Array[(String, String)],
  token_type : @core.TokenType,
) -> String {
  let mut start = 0
  let mut end = 0
  let n = span.length()
  if is_quoted_type(token_type) {
    for q in quotes {
      let (open_quote, close_quote) = q
      let lo = open_quote.to_array().length()
      let lc = close_quote.to_array().length()
      if n >= lo + lc &&
        starts_with_at(span, open_quote, 0) &&
        starts_with_at(span, close_quote, n - lc) {
        start = lo
        end = lc
        if token_type is HEREDOC_STRING {
          // A heredoc's tag is part of its delimiter, e.g. $tag$body$tag$
          let open_end = find_from(span, close_quote, start)
          let close_start = rfind_before(span, open_quote, n - end)
          if start <= open_end && open_end < close_start {
            start = open_end + lc
            end = n - close_start
          }
        }
        break
      }
    }
  }
  let width = n - start - end
  let pad = if token_type is NUMBER { '0' } else { 'a' }
  let a = alias_text.to_array()
  let body = slice(a, 0, width)
  let sb = StringBuilder()
  sb.write_string(String::from_array(span[0:start]))
  for _ in body.length()..<width {
    sb.write_char(pad)
  }
  sb.write_string(String::from_array(body))
  sb.write_string(String::from_array(span[n - end:n]))
  sb.to_string()
}

///|
fn blank(s : ArrayView[Char]) -> String {
  let sb = StringBuilder()
  for ch in s {
    sb.write_char(if @core.is_space(ch) { ch } else { '.' })
  }
  sb.to_string()
}

///|
/// Blanks the body of the comment at `i`, returning its text and the index past it.
fn blank_comment(
  sql : ArrayView[Char],
  i : Int,
  start : String,
  end : String?,
  nested : Bool,
) -> (String, Int) {
  let body = i + start.to_array().length()
  let end = match end {
    Some(e) if !e.is_empty() => e
    _ => {
      let mut stop = -1
      for j in @cmp.minimum(body, sql.length())..<sql.length() {
        if sql[j] == '\n' {
          stop = j
          break
        }
      }
      let stop = if stop == -1 { sql.length() } else { stop }
      return (start + blank(slice_view(sql, body, stop)), stop)
    }
  }
  let end_length = end.to_array().length()
  let mut depth = 1
  let mut j = body
  while j < sql.length() {
    if nested && starts_with_at(sql, start, j) {
      depth += 1
      j += start.to_array().length()
    } else if starts_with_at(sql, end, j) {
      j += end_length
      depth -= 1
      if depth == 0 {
        return (start + blank(slice_view(sql, body, j - end_length)) + end, j)
      }
    } else {
      j += 1
    }
  }
  (start + blank(slice_view(sql, body, sql.length())), sql.length())
}

///|
fn slice_view(s : ArrayView[Char], a : Int, b : Int) -> ArrayView[Char] {
  let n = s.length()
  let a = @cmp.minimum(@cmp.maximum(a, 0), n)
  let b = @cmp.minimum(@cmp.maximum(b, 0), n)
  if a >= b {
    s[0:0]
  } else {
    s[a:b]
  }
}

///|
fn redact(
  sql : ArrayView[Char],
  comments : Array[(String, String?)],
  nested : Bool,
) -> String {
  if sql.iter().all(@core.is_space) {
    // empty, or only whitespace
    return String::from_array(sql)
  }
  let result = StringBuilder()
  let mut i = 0
  let length = sql.length()
  while i < length {
    let mut matched = false
    for c in comments {
      let (start, end) = c
      if starts_with_at(sql, start, i) {
        let (text, stop) = blank_comment(sql, i, start, end, nested)
        result.write_string(text)
        i = stop
        matched = true
        break
      }
    }
    if !matched {
      let ch = sql[i]
      result.write_char(if @core.is_space(ch) { ch } else { '.' })
      i += 1
    }
  }
  result.to_string()
}
