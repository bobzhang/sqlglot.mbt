///|
/// Errors raised by sqlglot.
pub(all) suberror SqlglotError {
  /// Error raised when tokenizing fails. When available, `start` and `end` are the
  /// offsets in the source SQL of the context snippet quoted in the message, i.e.
  /// the snippet is `sql[start:end]`.
  TokenError(String, start~ : Int?, end~ : Int?)
  ParseError(String, Array[ParseErrorInfo])
  UnsupportedError(String)
  OptimizeError(String)
  SchemaError(String)
  ExecuteError(String)
  ValueError(String)
}

///|
/// Details of a single parse error.
pub(all) struct ParseErrorInfo {
  description : String
  line : Int
  col : Int
  start_context : String
  highlight : String
  end_context : String
  into_expression : String?
} derive(Debug)

///|
pub fn SqlglotError::message(self : SqlglotError) -> String {
  match self {
    TokenError(m, ..) => m
    ParseError(m, _) => m
    UnsupportedError(m) => m
    OptimizeError(m) => m
    SchemaError(m) => m
    ExecuteError(m) => m
    ValueError(m) => m
  }
}

///|
pub impl Show for SqlglotError with fn output(self, logger) {
  let name = match self {
    TokenError(_, ..) => "TokenError"
    ParseError(_, _) => "ParseError"
    UnsupportedError(_) => "UnsupportedError"
    OptimizeError(_) => "OptimizeError"
    SchemaError(_) => "SchemaError"
    ExecuteError(_) => "ExecuteError"
    ValueError(_) => "ValueError"
  }
  logger.write_string(name)
  logger.write_string(": ")
  logger.write_string(self.message())
}

///|
pub(all) enum ErrorLevel {
  Ignore
  Warn
  Raise
  Immediate
} derive(Eq, Show)

///|
/// Highlight a SQL string using ANSI codes at the given (inclusive) positions.
pub fn highlight_sql(
  sql : String,
  positions : Array[(Int, Int)],
  context_length? : Int = 100,
) -> (String, String, String, String) raise SqlglotError {
  if positions.is_empty() {
    raise ValueError("positions must contain at least one (start, end) tuple")
  }
  let chars = sql.to_array()
  let n = chars.length()
  fn sl(a : Int, b : Int) -> String {
    let a = if a < 0 { 0 } else if a > n { n } else { a }
    let b = if b < 0 { 0 } else if b > n { n } else { b }
    if a >= b {
      ""
    } else {
      String::from_array(chars[a:b])
    }
  }

  let mut start_context = ""
  let mut end_context = ""
  let mut first_highlight_start = 0
  let parts = StringBuilder()
  let mut previous_part_end = 0
  let sorted = positions.copy()
  sorted.sort_by((a, b) => a.0 - b.0)
  if sorted[0].0 > 0 {
    first_highlight_start = sorted[0].0
    let s0 = first_highlight_start - context_length
    start_context = sl(if s0 < 0 { 0 } else { s0 }, first_highlight_start)
    parts.write_string(start_context)
    previous_part_end = first_highlight_start
  }
  for p in sorted {
    let (start, end) = p
    let highlight_start = if start > previous_part_end {
      start
    } else {
      previous_part_end
    }
    let highlight_end = end + 1
    if highlight_start >= highlight_end {
      continue
    }
    if highlight_start > previous_part_end {
      parts.write_string(sl(previous_part_end, highlight_start))
    }
    parts.write_string("\u{1b}[4m")
    parts.write_string(sl(highlight_start, highlight_end))
    parts.write_string("\u{1b}[0m")
    previous_part_end = highlight_end
  }
  if previous_part_end < n {
    end_context = sl(previous_part_end, previous_part_end + context_length)
    parts.write_string(end_context)
  }
  let highlight = sl(first_highlight_start, previous_part_end)
  (parts.to_string(), start_context, highlight, end_context)
}

///|
pub fn concat_messages(errors : Array[String], maximum : Int) -> String {
  let msg = []
  for i, e in errors {
    if i >= maximum {
      break
    }
    msg.push(e)
  }
  let remaining = errors.length() - maximum
  if remaining > 0 {
    msg.push("... and \{remaining} more")
  }
  msg.join("\n\n")
}
