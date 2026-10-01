///|
/// Builds a string literal.
pub fn literal_string(s : String) -> Expr {
  mk(Literal, [("this", s), ("is_string", true)])
}

///|
/// Builds a number literal from its textual representation. Negative numbers
/// are wrapped in `Neg`.
pub fn literal_number(text : String) -> Expr {
  if text.has_prefix("-") {
    let rest = text.unsafe_substring(start=1, end=text.length())
    if is_float_str(rest) {
      return mk1(Neg, mk(Literal, [("this", rest), ("is_string", false)]))
    }
  }
  mk(Literal, [("this", text), ("is_string", false)])
}

///|
/// Builds a number literal from an integer.
pub fn literal_int(n : Int) -> Expr {
  literal_number(n.to_string())
}

///|
pub fn null_() -> Expr {
  mk0(Null)
}

///|
pub fn boolean(b : Bool) -> Expr {
  mk1(Boolean, b)
}

///|
pub fn true_() -> Expr {
  boolean(true)
}

///|
pub fn false_() -> Expr {
  boolean(false)
}

///|
pub fn var_(name : String) -> Expr {
  mk1(Var, name)
}

///|
/// Builds an identifier. When `quoted` is not given, the identifier is quoted
/// only if it's not a safe identifier.
pub fn to_identifier(name : String, quoted? : Bool) -> Expr {
  let q = match quoted {
    Some(q) => q
    None => !is_safe_identifier(name)
  }
  mk(Identifier, [("this", name), ("quoted", q)])
}

///|
pub fn ident(name : String) -> Expr {
  to_identifier(name)
}
