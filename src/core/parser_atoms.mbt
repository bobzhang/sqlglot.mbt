// Port of sqlglot/parser.py: aliases, identifiers, literals and other atoms.

///|
pub fn Parser::parse_alias(
  self : Parser,
  this : Expr?,
  explicit? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_alias {
    Some(f) => f(self, this, explicit)
    None => self.parse_alias_base(this, explicit~)
  }
}

///|
pub fn Parser::parse_alias_base(
  self : Parser,
  this : Expr?,
  explicit? : Bool = false,
) -> Expr? raise SqlglotError {
  if self.can_parse_limit_or_offset() {
    return this
  }
  if self.can_parse_named_window() {
    return this
  }
  let any_token = self.match_(ALIAS)
  let comments = self.prev_comments
  if explicit && !any_token {
    return this
  }
  if self.match_(L_PAREN) {
    let aliases = self.expression(
      mk(Aliases, [
        ("this", this),
        ("expressions", self.parse_csv(() => self.parse_id_var(any_token~))),
      ]),
      comments~,
    )
    self.match_r_paren(expression=aliases)
    return Some(aliases)
  }
  let alias_ = match
    self.parse_id_var(any_token~, tokens=self.cfg.alias_tokens) {
    Some(a) => Some(a)
    None =>
      if self.cfg.string_aliases {
        self.parse_string_as_identifier()
      } else {
        None
      }
  }
  match alias_ {
    Some(a) => {
      let comments = comments + a.pop_comments()
      let e = self.expression(
        mk(Alias, [("this", this), ("alias", a)]),
        comments~,
      )
      match e.this() {
        Some(column) =>
          if e.comments.unwrap_or([]).is_empty() &&
            !column.comments.unwrap_or([]).is_empty() {
            e.comments = Some(column.pop_comments())
          }
        None => ()
      }
      Some(e)
    }
    None => this
  }
}

///|
pub fn Parser::parse_id_var(
  self : Parser,
  any_token? : Bool = true,
  tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_id_var {
    Some(f) => f(self, any_token, tokens)
    None => self.parse_id_var_base(any_token~, tokens?)
  }
}

///|
pub fn Parser::parse_id_var_base(
  self : Parser,
  any_token? : Bool = true,
  tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  let mut expression = self.parse_identifier()
  if expression is None {
    let matched = (any_token && self.advance_any() is Some(_)) ||
      self.match_set(
        match tokens {
          Some(t) => t
          None => self.cfg.id_var_tokens
        },
      )
    if matched {
      let quoted = self.prev.token_type == STRING
      expression = Some(self.identifier_expression(quoted~))
    }
  }
  expression
}

///|
pub fn Parser::parse_string(self : Parser) -> Expr? raise SqlglotError {
  if self.match_keys(self.fns.string_parsers) {
    return self.fns.string_parsers[self.prev.token_type](self, self.prev)
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_string_as_identifier(
  self : Parser,
) -> Expr? raise SqlglotError {
  if !self.match_(STRING) {
    return None
  }
  let output = to_identifier(self.prev.text, quoted=true)
  output.update_positions_from_token(self.prev) |> ignore
  Some(output)
}

///|
pub fn Parser::parse_number(self : Parser) -> Expr? raise SqlglotError {
  if self.match_keys(self.fns.numeric_parsers) {
    return self.fns.numeric_parsers[self.prev.token_type](self, self.prev)
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_identifier(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(IDENTIFIER) {
    return Some(self.identifier_expression(quoted=true))
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_var(
  self : Parser,
  any_token? : Bool = false,
  tokens? : TokenSet,
  upper? : Bool = false,
) -> Expr? raise SqlglotError {
  if (any_token && self.advance_any() is Some(_)) ||
    self.match_(VAR) ||
    (match tokens {
      Some(t) => self.match_set(t)
      None => false
    }) {
    let text = if upper { self.prev_upper() } else { self.prev.text }
    return Some(self.expression(mk1(Var, text)))
  }
  self.parse_placeholder()
}

///|
pub fn Parser::advance_any(
  self : Parser,
  ignore_reserved? : Bool = false,
) -> Token? {
  if self.curr.ok() &&
    (
      ignore_reserved ||
      !self.cfg.reserved_tokens.contains(self.curr.token_type)
    ) {
    self.advance()
    return Some(self.prev)
  }
  None
}

///|
pub fn Parser::parse_var_or_string(
  self : Parser,
  upper? : Bool = false,
) -> Expr? raise SqlglotError {
  expr_or(self.parse_string(), () => self.parse_var(any_token=true, upper~))
}

///|
pub fn Parser::parse_primary_or_var(self : Parser) -> Expr? raise SqlglotError {
  expr_or(self.parse_primary(), () => self.parse_var(any_token=true))
}

///|
pub fn Parser::parse_null(self : Parser) -> Expr? raise SqlglotError {
  if self.match_any([NULL, UNKNOWN]) {
    return self.fns.primary_parsers[NULL](self, self.prev)
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_boolean(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(TRUE) {
    return self.fns.primary_parsers[TRUE](self, self.prev)
  }
  if self.match_(FALSE) {
    return self.fns.primary_parsers[FALSE](self, self.prev)
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_star(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(STAR) {
    return self.fns.primary_parsers[STAR](self, self.prev)
  }
  self.parse_placeholder()
}

///|
pub fn Parser::parse_parameter(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_parameter {
    Some(f) => f(self)
    None => {
      let this = expr_or(self.parse_identifier(), () => {
        self.parse_primary_or_var()
      })
      Some(self.expression(mk1(Parameter, this)))
    }
  }
}

///|
pub fn Parser::parse_placeholder(self : Parser) -> Expr? raise SqlglotError {
  if self.match_keys(self.fns.placeholder_parsers) {
    let placeholder = self.fns.placeholder_parsers[self.prev.token_type](self)
    match placeholder {
      Some(_) => return placeholder
      None => ()
    }
    self.advance(times=-1)
  }
  None
}

///|
pub fn Parser::parse_star_op(
  self : Parser,
  keywords : ArrayView[String],
) -> Array[Expr]? raise SqlglotError {
  if !self.match_texts(keywords) {
    return None
  }
  if self.match_(L_PAREN, advance=false) {
    return Some(self.parse_wrapped_csv(() => self.parse_expression()))
  }
  let expression = self.parse_alias(self.parse_disjunction(), explicit=true)
  match expression {
    Some(e) => Some([e])
    None => None
  }
}

///|
pub fn Parser::parse_select_or_expression(
  self : Parser,
  alias_? : Bool = false,
) -> Expr? raise SqlglotError {
  let first = if alias_ {
    self.parse_alias(self.parse_assignment(), explicit=true)
  } else {
    self.parse_assignment()
  }
  expr_or(self.parse_set_operations(first), () => self.parse_select())
}

///|
pub fn Parser::parse_ddl_select(self : Parser) -> Expr? raise SqlglotError {
  self.parse_query_modifiers(
    self.parse_set_operations(
      self.parse_select(nested=true, parse_subquery_alias=false),
    ),
  )
}
