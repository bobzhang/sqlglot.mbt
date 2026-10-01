// Port of sqlglot/parser.py: data types, columns, column operators, primaries.

///|
pub fn Parser::parse_types(
  self : Parser,
  check_func? : Bool = false,
  schema? : Bool = false,
  allow_identifiers? : Bool = true,
  with_collation? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_types {
    Some(f) => f(self, check_func, schema, allow_identifiers, with_collation)
    None =>
      self.parse_types_base(
        check_func~,
        schema~,
        allow_identifiers~,
        with_collation~,
      )
  }
}

///|
pub fn Parser::parse_types_base(
  self : Parser,
  check_func? : Bool = false,
  schema? : Bool = false,
  allow_identifiers? : Bool = true,
  with_collation? : Bool = false,
) -> Expr? raise SqlglotError {
  let index = self.index
  let mut this : Expr? = None
  let mut type_token : TokenType? = None
  if self.match_set(self.cfg.type_tokens) {
    type_token = Some(self.prev.token_type)
  } else {
    let identifier = if allow_identifiers {
      self.parse_id_var(any_token=false, tokens=TokenSet::new([VAR]))
    } else {
      None
    }
    match identifier {
      Some(identifier) if identifier.kind == Identifier =>
        if identifier.has("quoted") &&
          self.cfg.quoted_types_to_preserve.contains(identifier.name()) {
          this = Some(
            mk(DataType, [("this", DType::USERDEFINED), ("kind", identifier)]),
          )
        } else {
          let tokens = self.dialect.tokenize(identifier.name()) catch {
            TokenError(_) => []
            e => raise e
          }
          if !tokens.is_empty() &&
            self.cfg.type_tokens.contains(tokens[0].token_type) {
            type_token = Some(tokens[0].token_type)
            if tokens.length() > 1 {
              return Some(
                datatype_from_str(identifier.name(), dialect=self.dialect),
              )
            }
          } else if self.dialect.cfg.supports_user_defined_types {
            this = self.parse_user_defined_type(identifier)
          } else {
            self.retreat(self.index - 1)
            return None
          }
        }
      _ => return None
    }
  }
  if type_token == Some(PSEUDO_TYPE) {
    return Some(self.expression(mk1(PseudoType, self.prev_upper())))
  }
  if type_token == Some(OBJECT_IDENTIFIER) {
    return Some(self.expression(mk1(ObjectIdentifier, self.prev_upper())))
  }
  if type_token == Some(MAP) && self.match_(L_BRACKET) {
    let key_type = self.parse_types(check_func~, schema~, allow_identifiers~)
    if !self.match_(FARROW) {
      self.retreat(index)
      return None
    }
    let value_type = self.parse_types(check_func~, schema~, allow_identifiers~)
    if !self.match_(R_BRACKET) {
      self.retreat(index)
      return None
    }
    return Some(
      mk(DataType, [
        ("this", DType::MAP),
        ("expressions", [key_type, value_type].filter_map(x => x)),
        ("nested", true),
      ]),
    )
  }
  let in_set = fn(s : TokenSet) {
    match type_token {
      Some(t) => s.contains(t)
      None => false
    }
  }
  let nested = in_set(self.cfg.nested_type_tokens)
  let is_struct = in_set(self.cfg.struct_type_tokens)
  let is_aggregate = in_set(self.cfg.aggregate_type_tokens)
  let mut expressions : Array[Expr]? = None
  let mut maybe_func = false
  if self.match_(L_PAREN) {
    if is_struct {
      expressions = Some(
        self.parse_csv(() => self.parse_struct_types(type_required=true)),
      )
    } else if nested {
      let exprs = self.parse_csv(() => {
        self.parse_types(check_func~, schema~, allow_identifiers~)
      })
      expressions = Some(exprs)
      if type_token == Some(NULLABLE) && exprs.length() == 1 {
        let this = exprs[0]
        this.set("nullable", true)
        self.match_r_paren()
        return Some(this)
      }
    } else if in_set(self.cfg.enum_type_tokens) {
      expressions = Some(self.parse_csv(() => self.parse_equality()))
    } else if type_token == Some(JSON) {
      expressions = Some(self.parse_csv(() => self.parse_json_type_arg()))
    } else if is_aggregate {
      let func_or_ident = expr_or(self.parse_function(anonymous=true), () => {
        self.parse_id_var(any_token=false, tokens=TokenSet::new([VAR, ANY]))
      })
      let foi = match func_or_ident {
        Some(f) => f
        None => return None
      }
      let exprs = [foi]
      if self.match_(COMMA) {
        exprs.append(
          self.parse_csv(() => {
            self.parse_types(check_func~, schema~, allow_identifiers~)
          }),
        )
      }
      expressions = Some(exprs)
    } else {
      let mut exprs = self.parse_csv(() => self.parse_type_size())
      if type_token == Some(VECTOR) && exprs.length() == 2 {
        exprs = self.parse_vector_expressions(exprs)
      }
      expressions = Some(exprs)
    }
    if !self.match_(R_PAREN) {
      self.retreat(index)
      return None
    }
    maybe_func = true
  }
  let mut values : Array[Expr]? = None
  if nested && self.match_(LT) {
    if is_struct {
      expressions = Some(
        self.parse_csv(() => self.parse_struct_types(type_required=true)),
      )
    } else {
      expressions = Some(
        self.parse_csv(() => {
          self.parse_types(
            check_func~,
            schema~,
            allow_identifiers~,
            with_collation=true,
          )
        }),
      )
    }
    if !self.match_(GT) {
      self.raise_error("Expecting >")
    }
    if self.match_any([L_BRACKET, L_PAREN]) {
      let vs = self.parse_csv(() => self.parse_disjunction())
      if vs.is_empty() && is_struct {
        values = None
        self.retreat(self.index - 1)
      } else {
        values = Some(vs)
        self.match_any([R_BRACKET, R_PAREN]) |> ignore
      }
    }
  }
  if in_set(self.cfg.timestamps) {
    if self.match_text_seq(["WITH", "TIME", "ZONE"]) {
      maybe_func = false
      let tz_type = if in_set(self.cfg.times) {
        DType::TIMETZ
      } else {
        DType::TIMESTAMPTZ
      }
      this = Some(
        mk(DataType, [("this", tz_type), ("expressions", expressions)]),
      )
    } else if self.match_text_seq(["WITH", "LOCAL", "TIME", "ZONE"]) {
      maybe_func = false
      this = Some(
        mk(DataType, [
          ("this", DType::TIMESTAMPLTZ),
          ("expressions", expressions),
        ]),
      )
    } else if self.match_text_seq(["WITHOUT", "TIME", "ZONE"]) {
      maybe_func = false
    }
  } else if type_token == Some(INTERVAL) {
    if self.dialect.cfg.valid_interval_units.contains(py_upper(self.curr.text)) {
      let mut unit = self.parse_var(upper=true)
      if self.match_text("TO") {
        unit = Some(
          mk(IntervalSpan, [
            ("this", unit),
            ("expression", self.parse_var(upper=true)),
          ]),
        )
      }
      let interval = self.expression(mk(Interval, [("unit", unit)]))
      this = Some(self.expression(mk1(DataType, interval)))
    } else {
      this = Some(self.expression(mk1(DataType, DType::INTERVAL)))
    }
  } else if type_token == Some(VOID) {
    this = Some(mk1(DataType, DType::NULL))
  }
  if maybe_func && check_func {
    let index2 = self.index
    let peek = self.parse_string()
    if peek is None {
      self.retreat(index)
      return None
    }
    self.retreat(index2)
  }
  let mut this = match this {
    Some(t) => {
      match expressions {
        Some(e) if !e.is_empty() => t.set("expressions", e)
        _ => ()
      }
      t
    }
    None => {
      let mut tt = type_token.unwrap()
      if self.match_text("UNSIGNED") {
        match self.cfg.signed_to_unsigned_type_token.get(tt) {
          Some(u) => tt = u
          None => self.raise_error("Cannot convert \{tt.name()} to unsigned.")
        }
      }
      let no_exprs = match expressions {
        Some(e) => e.is_empty()
        None => true
      }
      if tt == NULLABLE && no_exprs {
        self.retreat(index)
        return None
      }
      let dtype = match dtype_from_name(tt.name()) {
        Some(d) => d
        None => raise ValueError("No DType for \{tt.name()}")
      }
      let mut t = mk(DataType, [
        ("this", dtype),
        ("expressions", expressions),
        ("nested", nested),
      ])
      match values {
        Some(vs) => {
          let cls = if is_struct { Struct } else { Array }
          t = cast_to_type(mk(cls, [("expressions", vs)]), t)
        }
        None => ()
      }
      t
    }
  }
  while self.match_(LIST) {
    this = mk(DataType, [
      ("this", DType::LIST),
      ("expressions", [this]),
      ("nested", true),
    ])
  }
  let index = self.index
  let mut matched_array = self.match_(ARRAY)
  while self.curr.ok() {
    let datatype_token = self.prev.token_type
    let matched_l_bracket = self.match_(L_BRACKET)
    if (!matched_l_bracket && !matched_array) ||
      (datatype_token == ARRAY && self.match_(R_BRACKET)) {
      break
    }
    matched_array = false
    let vs = self.parse_csv(() => self.parse_disjunction())
    let values = if vs.is_empty() { None } else { Some(vs) }
    if values is Some(_) &&
      !schema &&
      (
        !self.dialect.cfg.supports_fixed_size_arrays ||
        datatype_token == ARRAY ||
        !self.match_(R_BRACKET, advance=false)
      ) {
      self.retreat(index)
      break
    }
    this = mk(DataType, [
      ("this", DType::ARRAY),
      ("expressions", [this]),
      ("values", values),
      ("nested", true),
    ])
    self.match_(R_BRACKET) |> ignore
  }
  if !self.fns.type_converters.is_empty() {
    match this.args.get("this") {
      Some(DT(d)) =>
        match self.fns.type_converters.get(d) {
          Some(converter) => this = converter(this)
          None => ()
        }
      _ => ()
    }
  }
  if with_collation && this.kind == DataType && self.match_(COLLATE) {
    this.set(
      "collate",
      expr_or(self.parse_identifier(), () => self.parse_column()),
    )
  }
  Some(this)
}

///|
/// `exp.cast(expression, to, copy=False)` for an already-built DataType.
pub fn cast_to_type(expression : Expr, to : Expr) -> Expr {
  let e = mk(Cast, [("this", expression), ("to", to)])
  e.type_ = Some(to)
  e
}

///|
pub fn Parser::parse_json_type_arg(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text("SKIP") {
    let regexp = self.match_(RLIKE)
    let mut arg = self.parse_column()
    match arg {
      Some(a) if a.kind.is_a(Column) => arg = Some(a.to_dot())
      _ => ()
    }
    return Some(
      self.expression(
        mk(SkipJSONColumn, [("regexp", regexp), ("expression", arg)]),
      ),
    )
  }
  let param_or_col = match self.parse_column() {
    Some(p) if p.kind.is_a(Column) => p
    _ => return None
  }
  if param_or_col.parts().length() == 1 && self.match_(EQ) {
    let param = param_or_col.name()
    let value = self.parse_primary()
    return Some(
      self.expression(mk(EQ, [("this", var_(param)), ("expression", value)])),
    )
  }
  let col = param_or_col.to_dot()
  let kind = self.parse_types(check_func=false, allow_identifiers=false)
  Some(self.expression(mk(ColumnDef, [("this", col), ("kind", kind)])))
}

///|
pub fn Parser::parse_vector_expressions(
  self : Parser,
  expressions : Array[Expr],
) -> Array[Expr] raise SqlglotError {
  match self.fns.hooks.parse_vector_expressions {
    Some(f) => f(self, expressions)
    None => {
      let out = [datatype_from_str(expressions[0].name(), dialect=self.dialect)]
      for i in 1..<expressions.length() {
        out.push(expressions[i])
      }
      out
    }
  }
}

///|
pub fn Parser::parse_struct_types(
  self : Parser,
  type_required? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_struct_types {
    Some(f) => f(self, type_required)
    None => self.parse_struct_types_base(type_required~)
  }
}

///|
pub fn Parser::parse_struct_types_base(
  self : Parser,
  type_required? : Bool = false,
) -> Expr? raise SqlglotError {
  let index = self.index
  let this = if self.curr.ok() &&
    self.next.ok() &&
    self.cfg.type_tokens.contains(self.curr.token_type) &&
    self.cfg.type_tokens.contains(self.next.token_type) {
    self.parse_id_var()
  } else {
    expr_or(
      self.parse_type(parse_interval=false, fallback_to_identifier=true),
      () => self.parse_id_var(),
    )
  }
  self.match_(COLON) |> ignore
  if type_required &&
    !(match this {
      Some(t) => t.kind == DataType
      None => false
    }) &&
    !self.match_set(self.cfg.type_tokens, advance=false) {
    self.retreat(index)
    return self.parse_types()
  }
  self.parse_column_def(this)
}

///|
pub fn Parser::parse_at_time_zone(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if !self.match_text_seq(["AT", "TIME", "ZONE"]) {
    return this
  }
  let e = self.expression(
    mk(AtTimeZone, [("this", this), ("zone", self.parse_unary())]),
  )
  self.parse_at_time_zone(Some(e))
}

///|
pub fn Parser::parse_atom(self : Parser) -> Expr? raise SqlglotError {
  if self.cfg.identifier_tokens.contains(self.curr.token_type) {
    match self.parse_column() {
      Some(column) => return Some(column)
      None => ()
    }
  }
  let token = self.curr
  let token_type = token.token_type
  let primary_parser = match self.fns.primary_parsers.get(token_type) {
    Some(p) => p
    None => return None
  }
  let next_type = self.next.token_type
  if self.fns.column_operators.contains(next_type) ||
    self.cfg.column_postfix_tokens.contains(next_type) ||
    (token_type == STRING && next_type == STRING) {
    return None
  }
  self.advance()
  primary_parser(self, token)
}

///|
pub fn Parser::parse_column(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_column {
    Some(f) => f(self)
    None => self.parse_column_base()
  }
}

///|
pub fn Parser::parse_column_base(self : Parser) -> Expr? raise SqlglotError {
  let mut column = self.parse_column_parts_fast()
  if column is None {
    let mut this = self.parse_column_reference()
    if this is None {
      this = self.parse_bracket(this)
    }
    column = match this {
      Some(_) => self.parse_column_ops(this)
      None => this
    }
  }
  match column {
    Some(c) => {
      if self.dialect.cfg.supports_column_join_marks {
        c.set("join_mark", self.match_(JOIN_MARKER))
      }
      if self.cfg.colon_is_variant_extract {
        column = self.parse_colon_as_variant_extract(column)
      }
    }
    None => ()
  }
  column
}

///|
pub fn Parser::parse_column_parts_fast(
  self : Parser,
) -> Expr? raise SqlglotError {
  let index = self.index
  let mut parts : Array[Expr]? = None
  let mut all_comments : Array[String]? = None
  while self.match_set(self.cfg.identifier_tokens) {
    let token = self.prev
    let comments = self.prev_comments
    if parts is None &&
      self.fns.no_paren_function_parsers.contains(py_upper(token.text)) {
      self.retreat(index)
      return None
    }
    let has_dot = self.match_(DOT)
    let curr_tt = self.curr.token_type
    if !has_dot {
      if self.fns.column_operators.contains(curr_tt) ||
        self.cfg.column_postfix_tokens.contains(curr_tt) {
        self.retreat(index)
        return None
      }
    } else if !self.cfg.identifier_tokens.contains(curr_tt) {
      self.retreat(index)
      return None
    }
    if parts is None {
      parts = Some([])
    }
    if !comments.is_empty() {
      if all_comments is None {
        all_comments = Some([])
      }
      all_comments.unwrap().append(comments)
      self.prev_comments = []
    }
    parts
    .unwrap()
    .push(
      self.expression(
        mk(Identifier, [
          ("this", token.text),
          ("quoted", token.token_type == IDENTIFIER),
        ]),
        token~,
      ),
    )
    if !has_dot {
      break
    }
  }
  let parts = match parts {
    Some(p) => p
    None => return None
  }
  let n = parts.length()
  let mut column = if n == 1 {
    mk1(Column, parts[0])
  } else if n == 2 {
    mk(Column, [("this", parts[1]), ("table", parts[0])])
  } else if n == 3 {
    mk(Column, [("this", parts[2]), ("table", parts[1]), ("db", parts[0])])
  } else {
    mk(Column, [
      ("this", parts[3]),
      ("table", parts[2]),
      ("db", parts[1]),
      ("catalog", parts[0]),
    ])
  }
  for i in 4..<n {
    column = mk(Dot, [("this", column), ("expression", parts[i])])
  }
  match all_comments {
    Some(c) if !c.is_empty() => column.add_comments(Some(c))
    _ => ()
  }
  Some(column)
}

///|
pub fn Parser::parse_column_reference(
  self : Parser,
) -> Expr? raise SqlglotError {
  let mut this = self.parse_field()
  if this is None &&
    self.match_(VALUES, advance=false) &&
    self.cfg.values_followed_by_paren &&
    (!self.next.ok() || self.next.token_type != L_PAREN) {
    this = self.parse_id_var()
  }
  match this {
    Some(t) if t.kind == Identifier => {
      let comments = t.pop_comments()
      this = Some(self.expression(mk1(Column, t), comments~))
    }
    _ => ()
  }
  this
}

///|
pub fn Parser::build_json_extract(
  self : Parser,
  this : Expr?,
  path_parts : Array[Expr],
) -> (Expr?, Array[Expr]) raise SqlglotError {
  if path_parts.length() > 1 {
    let e = self.expression(
      mk(JSONExtract, [
        ("this", this),
        ("expression", mk(JSONPath, [("expressions", path_parts)])),
        ("variant_extract", true),
        ("requires_json", self.cfg.json_extract_requires_json_expression),
      ]),
    )
    return (Some(e), [mk0(JSONPathRoot)])
  }
  (this, path_parts)
}

///|
pub fn Parser::parse_colon_as_variant_extract(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  let mut this = this
  let mut path_parts : Array[Expr] = [mk0(JSONPathRoot)]
  while self.match_(COLON) {
    if !self.cfg.colon_chain_is_single_extract {
      let (t, p) = self.build_json_extract(this, path_parts)
      this = t
      path_parts = p
    }
    let key = self.parse_id_var(any_token=true, tokens=TokenSet::new([SELECT]))
    match key {
      Some(k) => {
        let quoted = k.kind == Identifier && k.has("quoted")
        path_parts.push(
          mk(JSONPathKey, [("this", k.name()), ("quoted", quoted)]),
        )
      }
      None => ()
    }
    while true {
      if self.match_(DOT) {
        match
          self.parse_id_var(any_token=true, tokens=TokenSet::new([SELECT])) {
          Some(next_key) => {
            let quoted = next_key.kind == Identifier && next_key.has("quoted")
            path_parts.push(
              mk(JSONPathKey, [("this", next_key.name()), ("quoted", quoted)]),
            )
          }
          None => ()
        }
      } else if self.match_(L_BRACKET) {
        let bracket_expr = self.parse_bracket_key_value()
        if !self.match_(R_BRACKET) {
          self.raise_error("Expected ]")
        }
        match bracket_expr {
          Some(be) =>
            if be.is_string() {
              path_parts.push(
                mk(JSONPathKey, [("this", be.name()), ("quoted", true)]),
              )
            } else if be.is_star() {
              path_parts.push(mk1(JSONPathSubscript, mk0(JSONPathWildcard)))
            } else if be.is_number() {
              path_parts.push(mk1(JSONPathSubscript, number_value(be)))
            } else {
              let (t, p) = self.build_json_extract(this, path_parts)
              this = t
              path_parts = p
              this = Some(
                self.expression(
                  mk(Bracket, [
                    ("this", this),
                    ("expressions", [be]),
                    ("json_access", true),
                  ]),
                ),
              )
            }
          None => ()
        }
      } else if self.match_(DCOLON) {
        let (t, p) = self.build_json_extract(this, path_parts)
        this = t
        path_parts = p
        match self.parse_types() {
          Some(cast_type) =>
            this = Some(
              self.expression(mk(Cast, [("this", this), ("to", cast_type)])),
            )
          None => self.raise_error("Expected type after '::'")
        }
      } else {
        break
      }
    }
  }
  let (t, _) = self.build_json_extract(this, path_parts)
  t
}

///|
/// Python `literal.to_py()` for a numeric literal, as an argument value (int when
/// integral, else the textual decimal).
pub fn number_value(e : Expr) -> Value {
  match e.to_py_int() {
    Some(i) =>
      if i >= -2147483648L && i <= 2147483647L {
        Int(i.to_int())
      } else {
        Str(i.to_string())
      }
    None => Str(decimal_str(e))
  }
}

///|
pub fn Parser::parse_dcolon(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_dcolon {
    Some(f) => f(self)
    None => self.parse_types()
  }
}

///|
pub fn Parser::parse_column_ops(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_column_ops {
    Some(f) => f(self, this)
    None => self.parse_column_ops_base(this)
  }
}

///|
pub fn Parser::parse_column_ops_base(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  let mut this = this
  while self.cfg.brackets.contains(self.curr.token_type) {
    this = self.parse_bracket(this)
  }
  let column_operators = self.fns.column_operators
  let cast_column_operators = self.cfg.cast_column_operators
  while self.curr.ok() {
    let op_token = self.curr.token_type
    let op = match column_operators.get(op_token) {
      Some(o) => o
      None => break
    }
    self.advance()
    let mut field : Expr? = None
    if cast_column_operators.contains(op_token) {
      field = self.parse_dcolon()
      if field is None {
        self.raise_error("Expected type")
      }
    } else if op is Some(_) && self.curr.ok() {
      field = expr_or(self.parse_column_reference(), () => self.parse_bitwise())
      match field {
        Some(f) if f.kind.is_a(Column) && self.match_(DOT, advance=false) =>
          field = self.parse_column_ops(field)
        _ => ()
      }
    } else {
      let dot = self.is_connected() && self.prev.token_type == DOT
      field = self.parse_field(any_token=true, anonymous_func=true)
      match field {
        Some(f) if dot && f.kind.is_any([Null, Boolean]) =>
          field = Some(
            self.expression(
              mk1(Identifier, self.prev.text),
              comments=f.comments.unwrap_or([]),
            ),
          )
        _ => ()
      }
    }
    match (field, this) {
      (Some(f), Some(t)) if f.kind.is_any([Func, Window]) =>
        this = Some(
          t.transform(n => {
            if n.kind.is_a(Column) {
              Some(n.to_dot(include_dots=false))
            } else {
              Some(n)
            }
          }),
        )
      _ => ()
    }
    match op {
      Some(op) => this = op(self, this, field)
      None =>
        match this {
          Some(t) if t.kind.is_a(Column) && !t.has("catalog") =>
            this = Some(
              self.expression(
                mk(Column, [
                  ("this", field),
                  ("table", t.this()),
                  ("db", t.arg("table")),
                  ("catalog", t.arg("db")),
                ]),
                comments=t.comments.unwrap_or([]),
              ),
            )
          _ =>
            match field {
              Some(f) if f.kind.is_a(Window) => {
                let window_func = self.expression(
                  mk(Dot, [("this", this), ("expression", f.this())]),
                )
                f.set("this", window_func)
                this = Some(f)
              }
              _ =>
                this = Some(
                  self.expression(
                    mk(Dot, [("this", this), ("expression", field)]),
                  ),
                )
            }
        }
    }
    match field {
      Some(f) =>
        match f.comments {
          Some(c) if !c.is_empty() =>
            match this {
              Some(t) => t.add_comments(Some(f.pop_comments()))
              None => ()
            }
          _ => ()
        }
      None => ()
    }
    this = self.parse_bracket(this)
  }
  this
}

///|
pub fn Parser::parse_paren(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(L_PAREN) {
    return None
  }
  let comments = self.prev_comments
  let query = self.parse_select()
  let expressions = match query {
    Some(q) => [q]
    None => self.parse_expressions()
  }
  let mut this : Expr? = if expressions.is_empty() {
    None
  } else {
    Some(expressions[0])
  }
  if this is None && self.match_(R_PAREN, advance=false) {
    this = Some(self.expression(mk0(Tuple)))
  } else if expressions.length() > 1 || self.prev.token_type == COMMA {
    this = Some(self.expression(mk(Tuple, [("expressions", expressions)])))
  } else {
    match this {
      Some(t) if t.kind.is_any([Select, SetOperation]) =>
        this = self.parse_subquery(this, parse_alias=false)
      Some(t) if t.kind.is_any([Subquery, Values]) =>
        this = self.parse_subquery(
          self.parse_query_modifiers(self.parse_set_operations(this)),
          parse_alias=false,
        )
      _ => this = Some(self.expression(mk1(Paren, this)))
    }
  }
  match this {
    Some(t) => t.add_comments(Some(comments))
    None => ()
  }
  self.match_r_paren(expression?=this)
  match this {
    Some(t) if t.kind == Paren &&
      (match t.this() {
        Some(x) => x.kind.is_a(AggFunc)
        None => false
      }) => return self.parse_window(this)
    _ => ()
  }
  this
}

///|
pub fn Parser::parse_primary(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_primary {
    Some(f) => f(self)
    None => self.parse_primary_base()
  }
}

///|
pub fn Parser::parse_primary_base(self : Parser) -> Expr? raise SqlglotError {
  if self.match_keys(self.fns.primary_parsers) {
    let token_type = self.prev.token_type
    let primary = self.fns.primary_parsers[token_type](self, self.prev)
    if token_type == STRING {
      let expressions = [primary].filter_map(x => x)
      while self.match_(STRING, advance=false) {
        if self.is_connected() && self.cfg.adjacent_strings_cannot_be_connected {
          self.raise_error(
            "Adjacent string literals need to be separated by whitespace or comments",
          )
        }
        self.advance()
        expressions.push(literal_string(self.prev.text))
      }
      if expressions.length() > 1 {
        return Some(
          self.expression(
            mk(Concat, [
              ("expressions", expressions),
              ("coalesce", self.dialect.cfg.concat_coalesce),
            ]),
          ),
        )
      }
    }
    return primary
  }
  if self.match_pair(DOT, NUMBER) {
    return Some(literal_number("0.\{self.prev.text}"))
  }
  self.parse_paren()
}

///|
pub fn Parser::parse_field(
  self : Parser,
  any_token? : Bool = false,
  tokens? : TokenSet,
  anonymous_func? : Bool = false,
) -> Expr? raise SqlglotError {
  let after_dot = self.cfg.supports_digit_prefixed_field_names &&
    self.prev.token_type == DOT
  let mut field = if anonymous_func {
    expr_or(self.parse_function(anonymous=anonymous_func, any_token~), () => {
      self.parse_primary()
    })
  } else {
    expr_or(self.parse_primary(), () => {
      self.parse_function(anonymous=anonymous_func, any_token~)
    })
  }
  if field is None {
    field = self.parse_id_var(any_token~, tokens?)
  }
  match field {
    Some(f) if after_dot && f.kind == Literal && f.is_number() => {
      let mut name = f.name()
      if self.is_connected() && self.parse_var(any_token=true) is Some(_) {
        name += self.prev.text
      }
      field = Some(
        mk(Identifier, [("this", name), ("quoted", true)]).update_positions(
          Some(f),
        ),
      )
    }
    _ => ()
  }
  field
}

///|
pub fn Parser::parse_function(
  self : Parser,
  functions? : Map[String, FuncBuilder],
  anonymous? : Bool = false,
  optional_parens? : Bool = true,
  any_token? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_function {
    Some(f) => f(self, functions, anonymous, optional_parens, any_token)
    None =>
      self.parse_function_base(
        functions?,
        anonymous~,
        optional_parens~,
        any_token~,
      )
  }
}

///|
pub fn Parser::parse_function_base(
  self : Parser,
  functions? : Map[String, FuncBuilder],
  anonymous? : Bool = false,
  optional_parens? : Bool = true,
  any_token? : Bool = false,
) -> Expr? raise SqlglotError {
  let mut fn_syntax = false
  if self.match_(L_BRACE, advance=false) &&
    self.next.ok() &&
    py_upper(self.next.text) == "FN" {
    self.advance(times=2)
    fn_syntax = true
  }
  let func = self.parse_function_call(
    functions?,
    anonymous~,
    optional_parens~,
    any_token~,
  )
  if fn_syntax {
    self.match_(R_BRACE) |> ignore
  }
  func
}
