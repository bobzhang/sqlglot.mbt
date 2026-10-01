// Port of sqlglot/parser.py: the expression precedence chain.

///|
pub fn Parser::parse_expression(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_expression {
    Some(f) => f(self)
    None => self.parse_alias(self.parse_assignment())
  }
}

///|
pub fn Parser::parse_assignment(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_assignment {
    Some(f) => f(self)
    None => self.parse_assignment_base()
  }
}

///|
pub fn Parser::parse_assignment_base(self : Parser) -> Expr? raise SqlglotError {
  let mut this = self.parse_disjunction()
  if this is None && self.cfg.assignment.contains(self.next.token_type) {
    let name = match self.advance_any(ignore_reserved=true) {
      Some(_) => self.prev.text
      None => "False"
    }
    this = Some(column_of(name))
  }
  while self.match_keys(self.cfg.assignment) {
    match this {
      Some(t) if t.kind.is_a(Column) && t.parts().length() == 1 => this = t.this()
      _ => ()
    }
    let comments = self.prev_comments
    let kind = self.cfg.assignment[self.prev.token_type]
    let expression = self.parse_assignment()
    this = Some(
      self.expression(
        mk(kind, [("this", this), ("expression", expression)]),
        comments~,
      ),
    )
  }
  this
}

///|
/// Parses a left-associative binary operator level.
fn Parser::parse_binary_level(
  self : Parser,
  table : Map[TokenType, Kind],
  next : () -> Expr? raise SqlglotError,
) -> Expr? raise SqlglotError {
  let mut this = next()
  while self.match_keys(table) {
    let comments = self.prev_comments
    let kind = table[self.prev.token_type]
    let expression = next()
    this = Some(
      self.expression(
        mk(kind, [("this", this), ("expression", expression)]),
        comments~,
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_disjunction(self : Parser) -> Expr? raise SqlglotError {
  self.parse_binary_level(self.cfg.disjunction, () => self.parse_conjunction())
}

///|
pub fn Parser::parse_conjunction(self : Parser) -> Expr? raise SqlglotError {
  self.parse_binary_level(self.cfg.conjunction, () => self.parse_equality())
}

///|
pub fn Parser::parse_equality(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_equality {
    Some(f) => f(self)
    None =>
      self.parse_binary_level(self.cfg.equality, () => self.parse_comparison())
  }
}

///|
pub fn Parser::parse_comparison(self : Parser) -> Expr? raise SqlglotError {
  self.parse_binary_level(self.cfg.comparison, () => self.parse_range())
}

///|
pub fn Parser::parse_range(self : Parser, this? : Expr?) -> Expr? raise SqlglotError {
  let this : Expr? = match this {
    Some(t) => t
    None => None
  }
  match self.fns.hooks.parse_range {
    Some(f) => f(self, this)
    None => self.parse_range_base(this)
  }
}

///|
pub fn Parser::parse_range_base(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let mut this = expr_or(this, () => self.parse_bitwise())
  while true {
    let negate = self.match_(NOT)
    if self.match_keys(self.fns.range_parsers) {
      let parser = self.fns.range_parsers[self.prev.token_type]
      match parser(self, this) {
        None => return this
        Some(e) => this = Some(e)
      }
    } else if self.match_(ISNULL) || (negate && self.match_(NULL)) {
      this = Some(self.expression(mk(Is, [("this", this), ("expression", null_())])))
    } else if self.match_(NOTNULL) {
      if self.dialect.cfg.normalize_not_null {
        this = Some(self.expression(mk(Is, [("this", this), ("expression", null_())])))
        this = Some(self.expression(mk1(Not, this)))
      } else {
        this = Some(
          self.expression(
            mk(Is, [("this", this), ("expression", null_()), ("negate", true)]),
          ),
        )
      }
    } else {
      if negate {
        self.retreat(self.index - 1)
      }
      break
    }
    if negate {
      this = self.negate_range(this)
      if self.curr.ok() &&
        (
          self.curr.token_type == NOT ||
          self.fns.range_parsers.contains(self.curr.token_type)
        ) {
        this = Some(self.expression(mk1(Paren, this)))
      }
    }
  }
  this
}

///|
pub fn Parser::negate_range(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  match self.fns.hooks.negate_range {
    Some(f) => f(self, this)
    None => self.negate_range_base(this)
  }
}

///|
pub fn Parser::negate_range_base(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let t = match this {
    Some(t) => t
    None => return this
  }
  let expression = if t.kind == Escape {
    match t.this() {
      Some(x) => x
      None => t
    }
  } else {
    t
  }
  if expression.kind.is_any([Like, ILike]) {
    expression.set("negate", true)
    return this
  }
  Some(self.expression(mk1(Not, this)))
}

///|
pub fn Parser::parse_is(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let index = self.index - 1
  let negate = self.match_(NOT)
  if self.match_text_seq(["DISTINCT", "FROM"]) {
    let klass = if negate { NullSafeEQ } else { NullSafeNEQ }
    return Some(
      self.expression(
        mk(klass, [("this", this), ("expression", self.parse_bitwise())]),
      ),
    )
  }
  let mut expression : Expr? = None
  if self.match_(JSON) {
    let kind : Value = if self.match_text_set(self.cfg.is_json_predicate_kind) {
      Str(self.prev_upper())
    } else {
      Bool(false)
    }
    let with_ : Bool? = if self.match_text("WITH") {
      Some(true)
    } else if self.match_text("WITHOUT") {
      Some(false)
    } else {
      None
    }
    let unique = self.match_(UNIQUE)
    self.match_text("KEYS") |> ignore
    expression = Some(
      self.expression(
        mk(JSON, [("this", kind), ("with_", with_), ("unique", unique)]),
      ),
    )
  } else {
    expression = expr_or(self.parse_null(), () => self.parse_bitwise())
    if expression is None {
      self.retreat(index)
      return None
    }
  }
  let mut this = this
  match expression {
    Some(e) if negate && e.kind == Null && !self.dialect.cfg.normalize_not_null =>
      this = Some(
        self.expression(
          mk(Is, [("this", this), ("expression", e), ("negate", true)]),
        ),
      )
    _ => {
      this = Some(self.expression(mk(Is, [("this", this), ("expression", expression)])))
      if negate {
        this = Some(self.expression(mk1(Not, this)))
      }
    }
  }
  self.parse_column_ops(this)
}

///|
pub fn Parser::parse_in(
  self : Parser,
  this : Expr?,
  alias? : Bool = false,
) -> Expr? raise SqlglotError {
  let mut this = this
  match self.parse_unnest(with_alias=false) {
    Some(unnest) =>
      this = Some(self.expression(mk(In, [("this", this), ("unnest", unnest)])))
    None =>
      if self.match_any([L_PAREN, L_BRACKET]) {
        let matched_l_paren = self.prev.token_type == L_PAREN
        let expressions = self.parse_csv(() => self.parse_select_or_expression(
          alias~,
        ))
        if expressions.length() == 1 && expressions[0].kind.is_a(Query) {
          let query = expressions[0]
          let q = self.parse_query_modifiers(Some(query)).unwrap()
          this = Some(
            self.expression(
              mk(In, [("this", this), ("query", q.subquery(copy=false))]),
            ),
          )
        } else {
          this = Some(
            self.expression(mk(In, [("this", this), ("expressions", expressions)])),
          )
        }
        if matched_l_paren {
          self.match_r_paren(expression?=this)
        } else if !self.match_(R_BRACKET, expression?=this) {
          self.raise_error("Expecting ]")
        }
      } else {
        this = Some(
          self.expression(mk(In, [("this", this), ("field", self.parse_column())])),
        )
      }
  }
  this
}

///|
pub fn Parser::parse_between(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let symmetric : Bool? = if self.match_text("SYMMETRIC") {
    Some(true)
  } else if self.match_text("ASYMMETRIC") {
    Some(false)
  } else {
    None
  }
  let low = self.parse_bitwise()
  self.match_(AND) |> ignore
  let high = self.parse_bitwise()
  Some(
    self.expression(
      mk(Between, [
        ("this", this),
        ("low", low),
        ("high", high),
        ("symmetric", symmetric),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_escape(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  if !self.match_(ESCAPE) {
    return this
  }
  let expression = expr_or(self.parse_string(), () => self.parse_null())
  Some(self.expression(mk(Escape, [("this", this), ("expression", expression)])))
}

///|
/// `INTERVAL_DAY_TIME_RE.match(text)`:
/// `\s*-?\s*\d+(?:\.\d+)?\s+(?:-?(?:\d+:)?\d+:\d+(?:\.\d+)?|-?(?:\d+:){1,2}|:)\s*`
pub fn interval_day_time_match(text : String) -> Bool {
  let s = text.to_array()
  let n = s.length()
  let mut i = 0
  fn skip_ws() {
    while i < n && is_space(s[i]) {
      i += 1
    }
  }

  fn digits() -> Bool {
    let st = i
    while i < n && is_digit_char(s[i]) {
      i += 1
    }
    i > st
  }

  skip_ws()
  if i < n && s[i] == '-' {
    i += 1
  }
  skip_ws()
  if !digits() {
    return false
  }
  if i < n && s[i] == '.' {
    let save = i
    i += 1
    if !digits() {
      i = save
    }
  }
  let ws_start = i
  skip_ws()
  if i == ws_start {
    return false
  }
  // alternatives (prefix match only, `re.match`)
  let start = i
  // alt 1: -?(?:\d+:)?\d+:\d+(?:\.\d+)?
  fn alt1() -> Bool {
    i = start
    if i < n && s[i] == '-' {
      i += 1
    }
    let save = i
    // try (\d+:) prefix then \d+:\d+
    fn tail() -> Bool {
      if !digits() {
        return false
      }
      if !(i < n && s[i] == ':') {
        return false
      }
      i += 1
      if !digits() {
        return false
      }
      if i < n && s[i] == '.' {
        let sv = i
        i += 1
        if !digits() {
          i = sv
        }
      }
      true
    }

    if digits() && i < n && s[i] == ':' {
      i += 1
      let save2 = i
      if tail() {
        return true
      }
      i = save2
    }
    i = save
    tail()
  }

  // alt 2: -?(?:\d+:){1,2}
  fn alt2() -> Bool {
    i = start
    if i < n && s[i] == '-' {
      i += 1
    }
    let mut count = 0
    while count < 2 {
      let save = i
      if digits() && i < n && s[i] == ':' {
        i += 1
        count += 1
      } else {
        i = save
        break
      }
    }
    count >= 1
  }

  alt1() || alt2() || (start < n && s[start] == ':')
}

///|
/// `INTERVAL_STRING_RE.findall(text)` returning (value, unit) pairs:
/// `\s*(-?[0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]+)\s*`
pub fn interval_string_findall(text : String) -> Array[(String, String)] {
  let s = text.to_array()
  let n = s.length()
  let out = []
  let mut pos = 0
  while pos <= n {
    // try to match at pos
    let mut i = pos
    while i < n && is_space(s[i]) {
      i += 1
    }
    let num_start = i
    if i < n && s[i] == '-' {
      i += 1
    }
    let d0 = i
    while i < n && s[i] >= '0' && s[i] <= '9' {
      i += 1
    }
    let mut ok = i > d0
    if ok && i < n && s[i] == '.' {
      let save = i
      i += 1
      let d1 = i
      while i < n && s[i] >= '0' && s[i] <= '9' {
        i += 1
      }
      if i == d1 {
        i = save
      }
    }
    let num_end = i
    if ok {
      while i < n && is_space(s[i]) {
        i += 1
      }
      let u0 = i
      while i < n && s[i].is_ascii_alphabetic() {
        i += 1
      }
      if i > u0 {
        let unit = String::from_array(s[u0:i])
        while i < n && is_space(s[i]) {
          i += 1
        }
        out.push((String::from_array(s[num_start:num_end]), unit))
        pos = i
        continue
      }
      ok = false
    }
    pos += 1
  }
  out
}

///|
pub fn Parser::parse_interval_span(
  self : Parser,
  this : Expr?,
  parse_function_unit? : Bool = true,
) -> Expr raise SqlglotError {
  let mut this = this
  let mut interval_span_units_omitted : Bool? = None
  match this {
    Some(t) if t.is_string() &&
      self.cfg.supports_omitted_interval_span_unit &&
      interval_day_time_match(t.name()) => {
      let index = self.index
      let first_unit = self.parse_var(any_token=true, upper=true)
      let mut second_unit : Expr? = None
      if first_unit is Some(_) && self.match_text("TO") {
        second_unit = self.parse_var(any_token=true, upper=true)
      }
      interval_span_units_omitted = Some(
        !(first_unit is Some(_) && second_unit is Some(_)),
      )
      self.retreat(index)
    }
    _ => ()
  }
  let unit_index = self.index
  let mut unit : Expr? = None
  if interval_span_units_omitted == Some(true) {
    unit = None
  } else {
    let is_unit = self.curr.ok() &&
      (
        self.curr.token_type == VAR ||
        self.dialect.cfg.valid_interval_units.contains(py_upper(self.curr.text))
      )
    unit = if parse_function_unit && is_unit {
      self.parse_function()
    } else {
      None
    }
    if unit is None && is_unit {
      unit = self.parse_var(any_token=true, upper=true)
    }
  }
  match this {
    Some(t) if t.is_number() =>
      match t.to_py_int() {
        Some(v) => this = Some(literal_string(v.to_string()))
        None =>
          match t.to_py_float() {
            Some(_) => this = Some(literal_string(decimal_str(t)))
            None =>
              self.raise_error(
                "Invalid numeric interval literal: \{py_repr_str(t.name())}",
              )
          }
      }
    Some(t) if t.is_string() => {
      let parts = interval_string_findall(t.name())
      if !parts.is_empty() && unit is Some(_) {
        unit = None
        self.retreat(unit_index)
      }
      if parts.length() == 1 {
        this = Some(literal_string(parts[0].0))
        unit = Some(self.expression(mk1(Var, py_upper(parts[0].1))))
      }
    }
    _ => ()
  }
  if self.cfg.interval_spans && self.match_text("TO") {
    let expression = expr_or(self.parse_function(), () => self.parse_var(
      any_token=true,
      upper=true,
    ))
    unit = Some(
      self.expression(mk(IntervalSpan, [("this", unit), ("expression", expression)])),
    )
  }
  self.expression(mk(Interval, [("this", this), ("unit", unit)]))
}

///|
/// Python `str(Decimal(text))` for a numeric literal (used for INTERVAL values).
fn decimal_str(t : Expr) -> String {
  let neg = t.kind == Neg
  let lit = if neg {
    match t.this() {
      Some(x) => x
      None => t
    }
  } else {
    t
  }
  let text = lit.text("this")
  let s = py_decimal_str(text)
  if neg {
    "-" + s
  } else {
    s
  }
}

///|
/// Python `str(Decimal(text))`: keeps the literal mostly as written, normalizing
/// exponent formatting and leading `+`/`.`.
pub fn py_decimal_str(text : String) -> String {
  let t = py_strip(text)
  let lower = py_lower(t)
  match lower.find("e") {
    Some(epos) => {
      // Decimal('1e5') -> '1E+5'; Decimal('1.5e-3') -> '0.0015'
      let mant = substr(t, 0, epos)
      let exp_s = substr(t, epos + 1, py_len(t))
      let exp_v = match parse_int_str(exp_s) {
        Some(v) => v.to_int()
        None => 0
      }
      let (sign, digits0) = if mant.has_prefix("-") {
        ("-", substr(mant, 1, py_len(mant)))
      } else if mant.has_prefix("+") {
        ("", substr(mant, 1, py_len(mant)))
      } else {
        ("", mant)
      }
      let (int_part, frac_part) = match digits0.find(".") {
        Some(d) => (substr(digits0, 0, d), substr(digits0, d + 1, py_len(digits0)))
        None => (digits0, "")
      }
      let mut coeff = int_part + frac_part
      let mut exponent = exp_v - py_len(frac_part)
      // strip leading zeros of the coefficient (keep at least one digit)
      while py_len(coeff) > 1 && coeff.has_prefix("0") {
        coeff = substr(coeff, 1, py_len(coeff))
      }
      let ndigits = py_len(coeff)
      let adjusted = exponent + ndigits - 1
      if exponent <= 0 && adjusted >= -6 {
        // fixed point
        if exponent == 0 {
          sign + coeff
        } else {
          let point = ndigits + exponent
          if point > 0 {
            sign + substr(coeff, 0, point) + "." + substr(coeff, point, ndigits)
          } else {
            sign + "0." + "0".repeat(-point) + coeff
          }
        }
      } else {
        // scientific
        let first = substr(coeff, 0, 1)
        let rest = substr(coeff, 1, ndigits)
        let mant_s = if rest.is_empty() { first } else { first + "." + rest }
        let es = if adjusted >= 0 {
          "+\{adjusted}"
        } else {
          "\{adjusted}"
        }
        exponent = adjusted
        ignore(exponent)
        sign + mant_s + "E" + es
      }
    }
    None => {
      let mut s = t
      let mut sign = ""
      if s.has_prefix("+") {
        s = substr(s, 1, py_len(s))
      } else if s.has_prefix("-") {
        sign = "-"
        s = substr(s, 1, py_len(s))
      }
      if s.has_prefix(".") {
        s = "0" + s
      }
      if s.has_suffix(".") {
        s = substr(s, 0, -1)
      }
      // strip leading zeros of the integer part
      while py_len(s) > 1 && s.has_prefix("0") && substr(s, 1, 2) != "." {
        s = substr(s, 1, py_len(s))
      }
      sign + s
    }
  }
}

///|
pub fn Parser::parse_interval(
  self : Parser,
  require_interval? : Bool = true,
  parse_function_unit? : Bool = true,
) -> Expr? raise SqlglotError {
  let index = self.index
  if !self.match_(INTERVAL) && require_interval {
    return None
  }
  let this = if self.match_(STRING, advance=false) {
    self.parse_primary()
  } else {
    self.parse_term()
  }
  let reject = match this {
    None => true
    Some(t) =>
      t.kind.is_a(Column) &&
      t.table_name().is_empty() &&
      !(match t.this() {
        Some(i) => i.has("quoted")
        None => false
      }) &&
      self.curr.ok() &&
      !self.dialect.cfg.valid_interval_units.contains(py_upper(self.curr.text))
  }
  if reject {
    self.retreat(index)
    return None
  }
  let interval = self.parse_interval_span(this, parse_function_unit~)
  let index = self.index
  self.match_(PLUS) |> ignore
  if self.match_any([STRING, NUMBER], advance=false) {
    let rest = self.parse_interval(require_interval=false, parse_function_unit~)
    return Some(
      self.expression(mk(Add, [("this", interval), ("expression", rest)])),
    )
  }
  self.retreat(index)
  Some(interval)
}

///|
pub fn Parser::parse_bitwise(self : Parser) -> Expr? raise SqlglotError {
  let mut this = self.parse_term()
  while true {
    if self.match_keys(self.cfg.bitwise) {
      let kind = self.cfg.bitwise[self.prev.token_type]
      this = Some(
        self.expression(mk(kind, [("this", this), ("expression", self.parse_term())])),
      )
    } else if self.dialect.cfg.dpipe_is_string_concat && self.match_(DPIPE) {
      this = Some(
        self.expression(
          mk(DPipe, [
            ("this", this),
            ("expression", self.parse_term()),
            ("safe", !self.dialect.cfg.strict_string_concat),
          ]),
        ),
      )
    } else if self.match_(DQMARK) {
      let t = self.parse_term()
      this = Some(
        self.expression(
          mk(Coalesce, [("this", this), ("expressions", [t].filter_map(x => x))]),
        ),
      )
    } else if self.match_pair(LT, LT) {
      this = Some(
        self.expression(
          mk(BitwiseLeftShift, [("this", this), ("expression", self.parse_term())]),
        ),
      )
    } else if self.match_pair(GT, GT) {
      this = Some(
        self.expression(
          mk(BitwiseRightShift, [("this", this), ("expression", self.parse_term())]),
        ),
      )
    } else if !self.fns.json_operators.is_empty() &&
      self.match_keys(self.fns.json_operators) {
      let op = self.fns.json_operators[self.prev.token_type]
      this = op(self, this, self.parse_term())
    } else {
      break
    }
  }
  this
}

///|
pub fn Parser::parse_term(self : Parser, parse_mod? : Bool = true) -> Expr? raise SqlglotError {
  let mut this = self.parse_factor(parse_mod~)
  while self.match_keys(self.cfg.term) {
    let klass = self.cfg.term[self.prev.token_type]
    let comments = self.prev_comments
    let expression = self.parse_factor(parse_mod~)
    let e = self.expression(
      mk(klass, [("this", this), ("expression", expression)]),
      comments~,
    )
    if e.kind == Collate {
      self.normalize_collate(e)
    }
    this = Some(e)
  }
  this
}

///|
fn Parser::normalize_collate(self : Parser, collate : Expr) -> Unit {
  ignore(self)
  match collate.expression() {
    Some(expr) if expr.kind.is_a(Column) && expr.parts().length() == 1 =>
      match expr.this() {
        Some(ident) if ident.kind == Identifier =>
          collate.set(
            "expression",
            if ident.has("quoted") {
              ident
            } else {
              var_(ident.name())
            },
          )
        _ => ()
      }
    _ => ()
  }
}

///|
pub fn Parser::parse_factor(self : Parser, parse_mod? : Bool = true) -> Expr? raise SqlglotError {
  let mut this = self.parse_at_time_zone(self.parse_factor_operand())
  while self.match_keys(self.cfg.factor, advance=false) {
    if !parse_mod && self.curr.token_type == MOD {
      break
    }
    self.advance()
    let klass = self.cfg.factor[self.prev.token_type]
    let comments = self.prev_comments
    let expression = self.parse_factor_operand()
    if expression is None &&
      klass == IntDiv &&
      self.prev.text.iter().all(is_alpha) &&
      !self.prev.text.is_empty() {
      self.retreat(self.index - 1)
      return this
    }
    let e = self.expression(
      mk(klass, [("this", this), ("expression", expression)]),
      comments~,
    )
    if e.kind == Div {
      e.set("typed", self.dialect.cfg.typed_division)
      e.set("safe", self.dialect.cfg.safe_division)
    }
    this = Some(e)
  }
  this
}

///|
pub fn Parser::parse_factor_operand(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_factor_operand {
    Some(f) => f(self)
    None =>
      if !self.cfg.exponent.is_empty() {
        self.parse_exponent()
      } else {
        self.parse_unary()
      }
  }
}

///|
pub fn Parser::parse_exponent(self : Parser) -> Expr? raise SqlglotError {
  self.parse_binary_level(self.cfg.exponent, () => self.parse_unary())
}

///|
pub fn Parser::parse_unary(self : Parser) -> Expr? raise SqlglotError {
  if self.match_keys(self.fns.unary_parsers) {
    let parser = self.fns.unary_parsers[self.prev.token_type]
    return parser(self)
  }
  self.parse_type()
}

///|
/// `TIME_ZONE_RE.search(text)`: `:.*?[a-zA-Z\+\-]` (`.` doesn't match newlines)
fn time_zone_re_search(text : String) -> Bool {
  let chars = text.to_array()
  for i, c in chars {
    if c == ':' {
      for j in (i + 1)..<chars.length() {
        let d = chars[j]
        if d == '\n' {
          break
        }
        if d.is_ascii_alphabetic() || d == '+' || d == '-' {
          return true
        }
      }
    }
  }
  false
}

///|
pub fn Parser::parse_type(
  self : Parser,
  parse_interval? : Bool = true,
  fallback_to_identifier? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_type {
    Some(f) => f(self, parse_interval, fallback_to_identifier)
    None => self.parse_type_base(parse_interval~, fallback_to_identifier~)
  }
}

///|
pub fn Parser::parse_type_base(
  self : Parser,
  parse_interval? : Bool = true,
  fallback_to_identifier? : Bool = false,
) -> Expr? raise SqlglotError {
  if !fallback_to_identifier {
    match self.parse_atom() {
      Some(atom) => return Some(atom)
      None => ()
    }
  }
  if parse_interval {
    match self.parse_interval() {
      Some(interval) => return self.parse_column_ops(Some(interval))
      None => ()
    }
  }
  let index = self.index
  let data_type = self.parse_types(check_func=true, allow_identifiers=false)
  match data_type {
    Some(dt) if dt.kind.is_a(Cast) => return self.parse_column_ops(Some(dt))
    Some(dt) => {
      let index2 = self.index
      let this = self.parse_primary()
      match this {
        Some(lit) if lit.kind == Literal => {
          let literal = lit.name()
          let this = self.parse_column_ops(Some(lit))
          match dt.args.get("this") {
            Some(DT(dtype)) =>
              match self.fns.type_literal_parsers.get(dtype) {
                Some(parser) => return Some(parser(self, this.unwrap(), dt))
                None => ()
              }
            _ => ()
          }
          let mut data_type = dt
          if self.cfg.zone_aware_timestamp_constructor &&
            time_zone_re_search(literal) {
            if data_type.is_type([DType::TIMESTAMP]) {
              data_type = mk1(DataType, DType::TIMESTAMPTZ)
            } else if data_type.is_type([DType::TIME]) {
              data_type = mk1(DataType, DType::TIMETZ)
            }
          }
          return Some(
            self.expression(mk(Cast, [("this", this), ("to", data_type)])),
          )
        }
        _ => ()
      }
      if !dt.expressions().is_empty() && index2 - index > 1 {
        self.retreat(index2)
        return self.parse_column_ops(Some(dt))
      }
      self.retreat(index)
    }
    None => ()
  }
  if fallback_to_identifier {
    return self.parse_id_var()
  }
  self.parse_column()
}

///|
pub fn Parser::parse_type_size(self : Parser) -> Expr? raise SqlglotError {
  let mut this = match self.parse_type() {
    Some(t) => t
    None => return None
  }
  if this.kind.is_a(Column) && this.table_name().is_empty() {
    this = var_(py_upper(this.name()))
  }
  Some(
    self.expression(
      mk(DataTypeParam, [
        ("this", this),
        ("expression", self.parse_var(any_token=true)),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_user_defined_type(
  self : Parser,
  identifier : Expr,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_user_defined_type {
    Some(f) => f(self, identifier)
    None => self.parse_user_defined_type_base(identifier)
  }
}

///|
pub fn Parser::parse_user_defined_type_base(
  self : Parser,
  identifier : Expr,
) -> Expr? raise SqlglotError {
  let mut type_name = identifier.name()
  while self.match_(DOT) {
    let part = match self.advance_any() {
      Some(_) => self.prev.text
      None => "None"
    }
    type_name = "\{type_name}.\{part}"
  }
  Some(datatype_from_str(type_name, dialect=self.dialect, udt=true))
}
