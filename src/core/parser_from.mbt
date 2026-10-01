// Port of sqlglot/parser.py: MATCH_RECOGNIZE, LATERAL, joins, indexes, tables,
// UNNEST, VALUES, TABLESAMPLE and PIVOT.

///|
pub fn Parser::parse_match_recognize(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(MATCH_RECOGNIZE) {
    return None
  }
  self.match_l_paren()
  let partition = self.parse_partition_by()
  let order = self.parse_order()
  let measures = if self.match_text("MEASURES") {
    Some(self.parse_csv(() => Some(self.parse_match_recognize_measure())))
  } else {
    None
  }
  let rows = if self.match_text_seq(["ONE", "ROW", "PER", "MATCH"]) {
    Some(var_("ONE ROW PER MATCH"))
  } else if self.match_text_seq(["ALL", "ROWS", "PER", "MATCH"]) {
    let mut text = "ALL ROWS PER MATCH"
    if self.match_text_seq(["SHOW", "EMPTY", "MATCHES"]) {
      text += " SHOW EMPTY MATCHES"
    } else if self.match_text_seq(["OMIT", "EMPTY", "MATCHES"]) {
      text += " OMIT EMPTY MATCHES"
    } else if self.match_text_seq(["WITH", "UNMATCHED", "ROWS"]) {
      text += " WITH UNMATCHED ROWS"
    }
    Some(var_(text))
  } else {
    None
  }
  let after = if self.match_text_seq(["AFTER", "MATCH", "SKIP"]) {
    let mut text = "AFTER MATCH SKIP"
    if self.match_text_seq(["PAST", "LAST", "ROW"]) {
      text += " PAST LAST ROW"
    } else if self.match_text_seq(["TO", "NEXT", "ROW"]) {
      text += " TO NEXT ROW"
    } else if self.match_text_seq(["TO", "FIRST"]) ||
      self.match_text_seq(["TO", "LAST"]) {
      let direction = self.prev_upper()
      let pattern_var = self.advance_any()
      if pattern_var is None {
        self.raise_error(
          "Expecting pattern variable after AFTER MATCH SKIP TO \{direction}",
        )
      }
      let pv = match pattern_var {
        Some(t) => t.text
        None => ""
      }
      text += " TO \{direction} \{pv}"
    }
    Some(var_(text))
  } else {
    None
  }
  let pattern = if self.match_text("PATTERN") {
    self.match_l_paren()
    if !self.curr.ok() {
      self.raise_error("Expecting )", token=self.curr)
    }
    let mut paren = 1
    let start = self.curr
    let mut end = self.prev
    while self.curr.ok() && paren > 0 {
      if self.curr.token_type == L_PAREN {
        paren += 1
      }
      if self.curr.token_type == R_PAREN {
        paren -= 1
      }
      end = self.prev
      self.advance()
    }
    if paren > 0 {
      self.raise_error("Expecting )", token=self.curr)
    }
    Some(var_(self.find_sql(start, end)))
  } else {
    None
  }
  let define = if self.match_text("DEFINE") {
    Some(self.parse_csv(() => self.parse_name_as_expression()))
  } else {
    None
  }
  self.match_r_paren()
  let alias = self.parse_table_alias()
  Some(
    self.expression(
      mk(MatchRecognize, [
        ("partition_by", partition),
        ("order", order),
        ("measures", measures),
        ("rows", rows),
        ("after", after),
        ("pattern", pattern),
        ("define", define),
        ("alias", alias),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_lateral(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_lateral {
    Some(f) => f(self)
    None => self.parse_lateral_base()
  }
}

///|
pub fn Parser::parse_lateral_base(self : Parser) -> Expr? raise SqlglotError {
  let cross_apply : Bool? = if self.match_pair(CROSS, APPLY) {
    Some(true)
  } else if self.match_pair(OUTER, APPLY) {
    Some(false)
  } else {
    None
  }
  let mut this : Expr? = None
  let mut view : Bool? = None
  let mut outer : Bool? = None
  if cross_apply is Some(_) {
    this = self.parse_select(table=true)
  } else if self.match_(LATERAL) {
    this = self.parse_select(table=true)
    view = Some(self.match_(VIEW))
    outer = Some(self.match_(OUTER))
  } else {
    return None
  }
  if this is None {
    this = expr_or(self.parse_unnest(), () => expr_or(self.parse_function(), () => self.parse_id_var(
      any_token=false,
    )))
    while self.match_(DOT) {
      let expression = expr_or(self.parse_function(), () => self.parse_id_var(
        any_token=false,
      ))
      this = Some(mk(Dot, [("this", this), ("expression", expression)]))
    }
  }
  let mut ordinality : Bool? = None
  let mut table_alias : Expr? = None
  if view == Some(true) {
    let table = self.parse_id_var(any_token=false)
    let columns = if self.match_(ALIAS) {
      self.parse_csv(() => self.parse_id_var())
    } else {
      []
    }
    table_alias = Some(
      self.expression(mk(TableAlias, [("this", table), ("columns", columns)])),
    )
  } else {
    match this {
      Some(t) if t.kind.is_any([Subquery, Unnest]) && !t.alias().is_empty() =>
        table_alias = Some(t.arg("alias").unwrap().pop())
      _ => {
        ordinality = Some(self.match_pair(WITH, ORDINALITY))
        table_alias = self.parse_table_alias()
      }
    }
  }
  Some(
    self.expression(
      mk(Lateral, [
        ("this", this),
        ("view", view),
        ("outer", outer),
        ("alias", table_alias),
        ("cross_apply", cross_apply),
        ("ordinality", ordinality),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_stream(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  if self.match_(STREAM) {
    match self.try_parse(() => self.parse_table()) {
      Some(this) => return Some(self.expression(mk1(Stream, this)))
      None => ()
    }
    self.retreat(index)
  }
  None
}

///|
pub fn Parser::parse_join_parts(
  self : Parser,
) -> (Token?, Token?, Token?) raise SqlglotError {
  match self.fns.hooks.parse_join_parts {
    Some(f) => f(self)
    None => self.parse_join_parts_base()
  }
}

///|
pub fn Parser::parse_join_parts_base(self : Parser) -> (Token?, Token?, Token?) {
  let method = if self.match_set(self.cfg.join_methods) {
    Some(self.prev)
  } else {
    None
  }
  let side = if self.match_set(self.cfg.join_sides) {
    Some(self.prev)
  } else {
    None
  }
  let kind = if self.match_set(self.cfg.join_kinds) {
    Some(self.prev)
  } else {
    None
  }
  (method, side, kind)
}

///|
pub fn Parser::parse_using_identifiers(self : Parser) -> Array[Expr] raise SqlglotError {
  fn parse_column_as_identifier() -> Expr? raise SqlglotError {
    let this = self.parse_column()
    match this {
      Some(t) if t.kind.is_a(Column) => t.this()
      _ => this
    }
  }

  self.parse_wrapped_csv(parse_column_as_identifier, optional=true)
}

///|
pub fn Parser::parse_join(
  self : Parser,
  skip_join_token? : Bool = false,
  parse_bracket? : Bool = false,
  alias_tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_join {
    Some(f) => f(self, skip_join_token, parse_bracket, alias_tokens)
    None => self.parse_join_base(skip_join_token~, parse_bracket~, alias_tokens?)
  }
}

///|
pub fn Parser::parse_join_base(
  self : Parser,
  skip_join_token? : Bool = false,
  parse_bracket? : Bool = false,
  alias_tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  if self.match_(COMMA) {
    let table = self.try_parse(() => self.parse_table(alias_tokens?))
    let cross_join = match table {
      Some(t) => Some(self.expression(mk1(Join, t)))
      None => None
    }
    match cross_join {
      Some(cj) if self.cfg.joins_have_equal_precedence => cj.set("kind", "CROSS")
      _ => ()
    }
    return cross_join
  }
  let index = self.index
  let (method0, side0, kind0) = self.parse_join_parts()
  let mut method = method0
  let mut side = side0
  let mut kind = kind0
  let directed = self.match_text("DIRECTED")
  let hint = if self.match_text_set(self.cfg.join_hints) {
    Some(self.prev.text)
  } else {
    None
  }
  let join = self.match_(JOIN) ||
    (match kind {
      Some(k) => k.token_type == STRAIGHT_JOIN
      None => false
    })
  let join_comments = self.prev_comments
  if !skip_join_token && !join {
    self.retreat(index)
    kind = None
    method = None
    side = None
  }
  let outer_apply = self.match_pair(OUTER, APPLY, advance=false)
  let cross_apply = self.match_pair(CROSS, APPLY, advance=false)
  if !skip_join_token && !join && !outer_apply && !cross_apply {
    return None
  }
  let this = self.parse_table(parse_bracket~, alias_tokens?)
  let j = mk1(Join, this)
  match kind {
    Some(k) if k.token_type == ARRAY && self.match_(COMMA) =>
      j.set(
        "expressions",
        self.parse_csv(() => self.parse_table(parse_bracket~, alias_tokens?)),
      )
    _ => ()
  }
  match method {
    Some(m) => j.set("method", py_upper(m.text))
    None => ()
  }
  match side {
    Some(s) => j.set("side", py_upper(s.text))
    None => ()
  }
  match kind {
    Some(k) => j.set("kind", py_upper(k.text))
    None => ()
  }
  match hint {
    Some(h) if !h.is_empty() => j.set("hint", h)
    _ => ()
  }
  if self.match_(MATCH_CONDITION) {
    j.set("match_condition", self.parse_wrapped(() => self.parse_comparison()))
  }
  if self.match_(ON) {
    j.set("on", self.parse_disjunction())
  } else if self.match_(USING) {
    j.set("using", self.parse_using_identifiers())
  } else if method is None &&
    !(outer_apply || cross_apply) &&
    !(match this {
      Some(t) => t.kind.is_a(Unnest)
      None => false
    }) &&
    !(match kind {
      Some(k) => k.token_type == CROSS || k.token_type == ARRAY
      None => false
    }) {
    let index = self.index
    let mut joins : Array[Expr]? = Some(self.parse_joins(alias_tokens?))
    let has_joins = match joins {
      Some(js) => !js.is_empty()
      None => false
    }
    if has_joins && self.match_(ON) {
      j.set("on", self.parse_disjunction())
    } else if has_joins && self.match_(USING) {
      j.set("using", self.parse_using_identifiers())
    } else {
      joins = None
      self.retreat(index)
    }
    match this {
      Some(t) =>
        t.set(
          "joins",
          match joins {
            Some(js) if !js.is_empty() => Some(js)
            _ => None
          },
        )
      None => ()
    }
  }
  j.set("pivots", self.parse_pivots())
  let comments = join_comments.copy()
  for token in [method, side, kind] {
    match token {
      Some(t) => comments.append(t.comments)
      None => ()
    }
  }
  if self.cfg.add_join_on_true &&
    !j.has("on") &&
    !j.has("using") &&
    !j.has("method") &&
    (match j.str_arg("kind") {
      None => true
      Some("INNER" | "OUTER") => true
      _ => false
    }) {
    j.set("on", true_())
  }
  if directed {
    j.set("directed", directed)
  }
  Some(self.expression(j, comments~))
}

///|
pub fn Parser::parse_opclass(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_disjunction()
  if self.match_text_set(self.cfg.opclass_follow_keywords, advance=false) {
    return this
  }
  if !self.match_set(self.cfg.optype_follow_tokens, advance=false) {
    return Some(
      self.expression(
        mk(Opclass, [("this", this), ("expression", self.parse_table_parts())]),
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_index_params(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_index_params {
    Some(f) => f(self)
    None => self.parse_index_params_base()
  }
}

///|
pub fn Parser::parse_index_params_base(self : Parser) -> Expr? raise SqlglotError {
  let using = if self.match_(USING) {
    self.parse_var(any_token=true)
  } else {
    None
  }
  let columns = if self.match_(L_PAREN, advance=false) {
    Some(self.parse_wrapped_csv(() => self.parse_with_operator()))
  } else {
    None
  }
  let include = if self.match_text("INCLUDE") {
    Some(self.parse_wrapped_id_vars())
  } else {
    None
  }
  let partition_by = self.parse_partition_by()
  let with_storage = self.andl(self.match_(WITH), () => self.parse_wrapped_properties())
  let tablespace = if self.match_text_seq(["USING", "INDEX", "TABLESPACE"]) {
    self.parse_var(any_token=true)
  } else {
    None
  }
  let where_ = self.parse_where()
  let on = if self.match_(ON) { self.parse_field() } else { None }
  Some(
    self.expression(
      mk(IndexParameters, [
        ("using", using),
        ("columns", columns),
        ("include", include),
        ("partition_by", partition_by),
        ("where", where_),
        ("with_storage", with_storage),
        ("tablespace", tablespace),
        ("on", on),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_index(
  self : Parser,
  index? : Expr?,
  anonymous? : Bool = false,
) -> Expr? raise SqlglotError {
  let mut index : Expr? = match index {
    Some(i) => i
    None => None
  }
  let mut unique : Bool? = None
  let mut primary : Bool? = None
  let mut amp : Bool? = None
  let mut table : Expr? = None
  if index is Some(_) || anonymous {
    self.match_(ON) |> ignore
    self.match_(TABLE) |> ignore
    table = self.parse_table_parts(schema=true)
  } else {
    unique = Some(self.match_(UNIQUE))
    primary = Some(self.match_text("PRIMARY"))
    amp = Some(self.match_text("AMP"))
    if !self.match_(INDEX) {
      return None
    }
    index = self.parse_id_var()
    table = None
  }
  let params = self.parse_index_params()
  Some(
    self.expression(
      mk(Index, [
        ("this", index),
        ("table", table),
        ("unique", unique),
        ("primary", primary),
        ("amp", amp),
        ("params", params),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_table_hints(self : Parser) -> Array[Expr]? raise SqlglotError {
  match self.fns.hooks.parse_table_hints {
    Some(f) => f(self)
    None => self.parse_table_hints_base()
  }
}

///|
pub fn Parser::parse_table_hints_base(self : Parser) -> Array[Expr]? raise SqlglotError {
  let hints = []
  if self.match_pair(WITH, L_PAREN) {
    hints.push(
      self.expression(
        mk(WithTableHint, [
          (
            "expressions",
            self.parse_csv(() => expr_or(self.parse_function(), () => self.parse_var(
              any_token=true,
            ))),
          ),
        ]),
      ),
    )
    self.match_r_paren()
  } else {
    while self.match_set(self.cfg.table_index_hint_tokens) {
      let hint = mk1(IndexTableHint, self.prev_upper())
      self.match_any([INDEX, KEY]) |> ignore
      if self.match_(FOR) {
        match self.advance_any() {
          Some(_) => hint.set("target", self.prev_upper())
          None => hint.set("target", false)
        }
      }
      hint.set("expressions", self.parse_wrapped_id_vars())
      hints.push(hint)
    }
  }
  if hints.is_empty() {
    None
  } else {
    Some(hints)
  }
}

///|
pub fn Parser::parse_table_part(self : Parser, schema? : Bool = false) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_table_part {
    Some(f) => f(self, schema)
    None => self.parse_table_part_base(schema~)
  }
}

///|
pub fn Parser::parse_table_part_base(
  self : Parser,
  schema? : Bool = false,
) -> Expr? raise SqlglotError {
  let f = if !schema {
    self.parse_function(optional_parens=false)
  } else {
    None
  }
  match f {
    Some(_) => f
    None =>
      expr_or(self.parse_id_var(any_token=false), () => expr_or(
        self.parse_string_as_identifier(),
        () => self.parse_placeholder(),
      ))
  }
}

///|
pub fn Parser::parse_table_parts_fast(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  let mut parts : Array[Expr]? = None
  let mut all_comments : Array[String]? = None
  while self.match_set(self.cfg.identifier_tokens) {
    let token = self.prev
    let comments = self.prev_comments
    let has_dot = self.match_(DOT)
    let curr_tt = self.curr.token_type
    if !has_dot {
      if self.cfg.table_postfix_tokens.contains(curr_tt) {
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
  let table = if n == 1 {
    mk1(Table, parts[0])
  } else if n == 2 {
    mk(Table, [("this", parts[1]), ("db", parts[0])])
  } else {
    let mut this = parts[2]
    for i in 3..<n {
      this = mk(Dot, [("this", this), ("expression", parts[i])])
    }
    mk(Table, [("this", this), ("db", parts[1]), ("catalog", parts[0])])
  }
  match all_comments {
    Some(c) if !c.is_empty() => table.add_comments(Some(c))
    _ => ()
  }
  Some(table)
}

///|
pub fn Parser::parse_table_parts(
  self : Parser,
  schema? : Bool = false,
  is_db_reference? : Bool = false,
  wildcard? : Bool = false,
  fast? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_table_parts {
    Some(f) => f(self, schema, is_db_reference, wildcard, fast)
    None => self.parse_table_parts_base(schema~, is_db_reference~, wildcard~, fast~)
  }
}

///|
pub fn Parser::parse_table_parts_base(
  self : Parser,
  schema? : Bool = false,
  is_db_reference? : Bool = false,
  wildcard? : Bool = false,
  fast? : Bool = false,
) -> Expr? raise SqlglotError {
  if fast {
    return self.parse_table_parts_fast()
  }
  let mut catalog : Value? = None
  let mut db : Value? = None
  let mut table : Value? = self.parse_table_part(schema~).map(x => Node(x))
  while self.match_(DOT) {
    if catalog is Some(c) && c.truthy() {
      let expression = self.parse_table_part(schema~)
      table = Some(
        Node(self.expression(mk(Dot, [("this", table), ("expression", expression)]))),
      )
    } else {
      catalog = db
      db = table
      table = match self.parse_table_part(schema~) {
        Some(t) => Some(Node(t))
        None => Some(Str(""))
      }
    }
  }
  let table_truthy = match table {
    Some(v) => v.truthy()
    None => false
  }
  let table_is_ident = match table {
    Some(Node(t)) => t.kind == Identifier
    _ => false
  }
  if wildcard &&
    self.is_connected() &&
    (table_is_ident || !table_truthy) &&
    self.match_(STAR) {
    match table {
      Some(Node(t)) if t.kind == Identifier =>
        t.args["this"] = Str(t.text("this") + "*")
      _ => table = Some(Node(mk1(Identifier, "*")))
    }
  }
  if is_db_reference {
    catalog = db
    db = table
    table = None
  }
  let table_truthy = match table {
    Some(v) => v.truthy()
    None => false
  }
  let db_truthy = match db {
    Some(v) => v.truthy()
    None => false
  }
  if !table_truthy && !is_db_reference {
    self.raise_error("Expected table name but got \{token_repr(self.curr)}")
  }
  if !db_truthy && is_db_reference {
    self.raise_error("Expected database name but got \{token_repr(self.curr)}")
  }
  let table = self.expression(
    mk(Table, [("this", table), ("db", db), ("catalog", catalog)]),
  )
  let comments = []
  for part in table.parts() {
    let pc = part.pop_comments()
    if !pc.is_empty() {
      comments.append(pc)
    }
  }
  if !comments.is_empty() {
    table.add_comments(Some(comments))
  }
  match self.parse_changes() {
    Some(c) => table.set("changes", c)
    None => ()
  }
  match self.parse_historical_data() {
    Some(at_before) => table.set("when", at_before)
    None => ()
  }
  match self.parse_pivots() {
    Some(p) => table.set("pivots", p)
    None => ()
  }
  Some(table)
}

///|
/// Python `repr(token)`.
pub fn token_repr(t : Token) -> String {
  let comments = "[" +
    t.comments.map(c => py_repr_str(c)).join(", ") +
    "]"
  "<Token token_type: TokenType.\{t.token_type.name()}, text: \{t.text}, line: \{t.line}, col: \{t.col}, start: \{t.start}, end: \{t.end}, comments: \{comments}>"
}

///|
pub fn Parser::parse_table(
  self : Parser,
  schema? : Bool = false,
  joins? : Bool = false,
  alias_tokens? : TokenSet,
  parse_bracket? : Bool = false,
  is_db_reference? : Bool = false,
  parse_partition? : Bool = false,
  consume_pipe? : Bool = false,
) -> Expr? raise SqlglotError {
  let args : TableArgs = {
    schema,
    joins,
    alias_tokens,
    parse_bracket,
    is_db_reference,
    parse_partition,
    consume_pipe,
  }
  match self.fns.hooks.parse_table {
    Some(f) => f(self, args)
    None => self.parse_table_base(args)
  }
}

///|
pub fn Parser::parse_table_base(self : Parser, args : TableArgs) -> Expr? raise SqlglotError {
  let { schema, joins, alias_tokens, parse_bracket, is_db_reference, parse_partition, consume_pipe } = args
  let tokens = match alias_tokens {
    Some(t) => t
    None => self.cfg.table_alias_tokens
  }
  if !schema && !is_db_reference && !consume_pipe && !joins {
    let index = self.index
    match self.parse_table_parts(fast=true) {
      Some(table) => {
        let curr_tt = self.curr.token_type
        let next_tt = self.next.token_type
        let fast_terminators = self.cfg.table_terminators
        if fast_terminators.contains(curr_tt) && next_tt != MATCH_CONDITION {
          return Some(table)
        }
        let postfix_tokens = self.cfg.table_postfix_tokens
        if !postfix_tokens.contains(curr_tt) && !postfix_tokens.contains(next_tt) {
          match self.parse_table_alias(alias_tokens=tokens) {
            Some(alias) => table.set("alias", alias)
            None => ()
          }
          if fast_terminators.contains(self.curr.token_type) {
            return Some(table)
          }
        }
        self.retreat(index)
      }
      None => ()
    }
  }
  match self.parse_stream() {
    Some(s) => return Some(s)
    None => ()
  }
  match self.parse_lateral() {
    Some(l) => return Some(l)
    None => ()
  }
  match self.parse_unnest() {
    Some(u) => return Some(u)
    None => ()
  }
  match self.parse_derived_table_values() {
    Some(v) => return Some(v)
    None => ()
  }
  match self.parse_select(table=true, consume_pipe~) {
    Some(subquery) => {
      if !subquery.has("pivots") {
        subquery.set("pivots", self.parse_pivots())
      }
      if joins {
        for join in self.parse_joins() {
          subquery.append("joins", join)
        }
      }
      return Some(subquery)
    }
    None => ()
  }
  let bracket = if parse_bracket { self.parse_bracket(None) } else { None }
  let bracket = match bracket {
    Some(b) => Some(self.expression(mk1(Table, b)))
    None => None
  }
  let rows_from_tables = if self.match_text_seq(["ROWS", "FROM"]) {
    Some(self.parse_wrapped_csv(() => self.parse_table()))
  } else {
    None
  }
  let rows_from = match rows_from_tables {
    Some(t) if !t.is_empty() =>
      Some(self.expression(mk(Table, [("rows_from", t)])))
    _ => None
  }
  let only = self.match_(ONLY)
  let mut this = match bracket {
    Some(b) => b
    None =>
      match rows_from {
        Some(r) => r
        None =>
          match
            self.parse_bracket(
              self.parse_table_parts(schema~, is_db_reference~),
            ) {
            Some(t) => t
            None => return None
          }
      }
  }
  if only {
    this.set("only", only)
  }
  self.match_(STAR) |> ignore
  let parse_partition = parse_partition || self.cfg.supports_partition_selection
  if parse_partition && self.match_(PARTITION, advance=false) {
    this.set("partition", self.parse_partition())
  }
  if schema {
    return self.parse_schema(this=Some(this))
  }
  if self.dialect.cfg.alias_post_version {
    this.set("version", self.parse_version())
  }
  if self.dialect.cfg.alias_post_tablesample {
    this.set("sample", self.parse_table_sample())
  }
  match self.parse_table_alias(alias_tokens=tokens) {
    Some(alias) => {
      this.set("alias", alias)
      if this.kind == Table && !this.has("when") {
        this.set("when", self.parse_historical_data())
      }
    }
    None => ()
  }
  if self.match_(INDEXED_BY) {
    this.set("indexed", self.parse_table_parts())
  } else if self.match_text_seq(["NOT", "INDEXED"]) {
    this.set("indexed", false)
  }
  if this.kind == Table && self.match_text("AT") {
    let col = this.to_column(copy=false)
    return Some(
      self.expression(
        mk(AtIndex, [("this", col), ("expression", self.parse_id_var())]),
      ),
    )
  }
  this.set("hints", self.parse_table_hints())
  if !this.has("pivots") {
    this.set("pivots", self.parse_pivots())
  }
  if !self.dialect.cfg.alias_post_tablesample {
    this.set("sample", self.parse_table_sample())
  }
  if !self.dialect.cfg.alias_post_version {
    this.set("version", self.parse_version())
  }
  if joins {
    for join in self.parse_joins(alias_tokens?) {
      this.append("joins", join)
    }
  }
  if self.match_pair(WITH, ORDINALITY) {
    this.set("ordinality", true)
    this.set("alias", self.parse_table_alias())
  }
  match this.this() {
    Some(table_from_rows) if this.kind == Table &&
      table_from_rows.kind == TableFromRows => {
      for kv in TableFromRows.arg_types() {
        let arg = kv.0
        if arg != "this" {
          table_from_rows.set(arg, this.args.get(arg))
        }
      }
      this = table_from_rows
    }
    _ => ()
  }
  Some(this)
}

///|
pub fn Parser::parse_version(self : Parser) -> Expr? raise SqlglotError {
  let mut this : String? = None
  for pv in self.cfg.version_phrases {
    if self.match_text_seq(pv.0) {
      this = Some(pv.1)
      break
    }
  }
  let this = match this {
    Some(t) => t
    None => return None
  }
  let mut kind = ""
  let mut expression : Expr? = None
  if self.match_any([FROM, BETWEEN]) {
    kind = self.prev_upper()
    let start = self.parse_bitwise()
    self.match_texts(["TO", "AND"]) |> ignore
    let end = self.parse_bitwise()
    expression = Some(
      self.expression(mk(Tuple, [("expressions", [start, end].filter_map(x => x))])),
    )
  } else if self.match_text_seq(["CONTAINED", "IN"]) {
    kind = "CONTAINED IN"
    expression = Some(
      self.expression(
        mk(Tuple, [
          ("expressions", self.parse_wrapped_csv(() => self.parse_bitwise())),
        ]),
      ),
    )
  } else if self.match_(ALL) {
    kind = "ALL"
    expression = None
  } else {
    self.match_text_seq(["AS", "OF"]) |> ignore
    kind = "AS OF"
    expression = self.parse_type()
  }
  Some(
    self.expression(
      mk(Version, [("this", this), ("expression", expression), ("kind", kind)]),
    ),
  )
}

///|
pub fn Parser::parse_historical_data(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  let mut historical_data : Expr? = None
  if self.match_text_set(self.cfg.historical_data_prefix) {
    let this = self.prev_upper()
    let kind : Value = if self.match_(L_PAREN) &&
      self.match_text_set(self.cfg.historical_data_kind) {
      Str(self.prev_upper())
    } else {
      Bool(false)
    }
    let expression = if self.match_(FARROW) {
      self.parse_bitwise()
    } else {
      None
    }
    match expression {
      Some(e) => {
        self.match_r_paren()
        historical_data = Some(
          self.expression(
            mk(HistoricalData, [("this", this), ("kind", kind), ("expression", e)]),
          ),
        )
      }
      None => self.retreat(index)
    }
  }
  historical_data
}

///|
pub fn Parser::parse_changes(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text_seq(["CHANGES", "(", "INFORMATION", "=>"]) {
    return None
  }
  let information = self.parse_var(any_token=true)
  self.match_r_paren()
  let at_before = self.parse_historical_data()
  let end = self.parse_historical_data()
  Some(
    self.expression(
      mk(Changes, [
        ("information", information),
        ("at_before", at_before),
        ("end", end),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_unnest(self : Parser, with_alias? : Bool = true) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_unnest {
    Some(f) => f(self, with_alias)
    None => self.parse_unnest_base(with_alias~)
  }
}

///|
pub fn Parser::parse_unnest_base(
  self : Parser,
  with_alias? : Bool = true,
) -> Expr? raise SqlglotError {
  if !self.match_pair(UNNEST, L_PAREN, advance=false) {
    return None
  }
  self.advance()
  let expressions = self.parse_wrapped_csv(() => self.parse_equality())
  let mut offset : Value? = Some(Bool(self.match_pair(WITH, ORDINALITY)))
  let alias = if with_alias { self.parse_table_alias() } else { None }
  match alias {
    Some(alias) => {
      if self.dialect.cfg.unnest_column_only {
        if alias.has("columns") {
          self.raise_error("Unexpected extra column alias in unnest.")
        }
        alias.set("columns", [alias.this()].filter_map(x => x))
        alias.set("this", null_arg)
      }
      let columns = alias.list("columns")
      if offset == Some(Bool(true)) && expressions.length() < columns.length() {
        let last = columns[columns.length() - 1]
        let raw = alias.raw_list("columns")
        raw.pop() |> ignore
        offset = Some(Node(last))
      }
    }
    None => ()
  }
  let offset_truthy = match offset {
    Some(v) => v.truthy()
    None => false
  }
  if !offset_truthy && self.match_pair(WITH, OFFSET) {
    self.match_(ALIAS) |> ignore
    offset = match
      self.parse_id_var(any_token=false, tokens=self.cfg.unnest_offset_alias_tokens) {
      Some(o) => Some(Node(o))
      None => Some(Node(to_identifier("offset")))
    }
  }
  Some(
    self.expression(
      mk(Unnest, [
        ("expressions", expressions),
        ("alias", alias),
        ("offset", offset),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_derived_table_values(
  self : Parser,
  allow_value_synonym? : Bool = false,
) -> Expr? raise SqlglotError {
  let is_derived = self.match_pair(L_PAREN, VALUES)
  if !is_derived &&
    !(
      self.match_text("VALUES") ||
      self.match_text_seq(["FORMAT", "VALUES"]) ||
      (allow_value_synonym && self.match_text("VALUE"))
    ) {
    return None
  }
  let expressions = self.parse_csv(() => self.parse_value())
  let alias = self.parse_table_alias()
  if is_derived {
    self.match_r_paren()
  }
  let alias = expr_or(alias, () => self.parse_table_alias())
  Some(
    self.expression(mk(Values, [("expressions", expressions), ("alias", alias)])),
  )
}

///|
pub fn Parser::parse_table_sample(
  self : Parser,
  as_modifier? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_table_sample {
    Some(f) => f(self, as_modifier)
    None => self.parse_table_sample_base(as_modifier~)
  }
}

///|
pub fn Parser::parse_table_sample_base(
  self : Parser,
  as_modifier? : Bool = false,
) -> Expr? raise SqlglotError {
  if !self.match_(TABLE_SAMPLE) &&
    !(as_modifier && self.match_text_seq(["USING", "SAMPLE"])) {
    return None
  }
  let mut bucket_numerator : Expr? = None
  let mut bucket_denominator : Expr? = None
  let mut bucket_field : Expr? = None
  let mut percent : Expr? = None
  let mut size : Expr? = None
  let mut seed : Value? = None
  let mut method = self.parse_var(tokens=TokenSet::new([ROW]), upper=true)
  let matched_l_paren = self.match_(L_PAREN)
  let mut num : Expr? = None
  let mut expressions : Array[Expr]? = None
  if self.cfg.tablesample_csv {
    expressions = Some(self.parse_csv(() => self.parse_primary()))
  } else {
    num = if self.match_(NUMBER, advance=false) {
      self.parse_factor(parse_mod=false)
    } else {
      expr_or(self.parse_primary(), () => self.parse_placeholder())
    }
  }
  if self.match_text("BUCKET") {
    bucket_numerator = self.parse_number()
    self.match_text_seq(["OUT", "OF"]) |> ignore
    bucket_denominator = self.parse_number()
    self.match_(ON) |> ignore
    bucket_field = self.parse_field()
  } else if self.match_any([PERCENT, MOD]) {
    percent = num
  } else if self.match_(ROWS) || !self.dialect.cfg.tablesample_size_is_percent {
    size = num
  } else {
    percent = num
  }
  if matched_l_paren {
    self.match_r_paren()
  }
  if self.match_(L_PAREN) {
    method = self.parse_var(upper=true)
    seed = self.andv(self.match_(COMMA), () => self.parse_number())
    self.match_r_paren()
  } else if self.match_texts(["SEED", "REPEATABLE"]) {
    seed = self.parse_wrapped(() => self.parse_number()).map(x => Node(x))
  }
  if method is None {
    match self.cfg.default_sampling_method {
      Some(m) if !m.is_empty() => method = Some(var_(m))
      _ => ()
    }
  }
  Some(
    self.expression(
      mk(TableSample, [
        ("expressions", expressions),
        ("method", method),
        ("bucket_numerator", bucket_numerator),
        ("bucket_denominator", bucket_denominator),
        ("bucket_field", bucket_field),
        ("percent", percent),
        ("size", size),
        ("seed", seed),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_pivots(self : Parser) -> Array[Expr]? raise SqlglotError {
  if self.curr.token_type != PIVOT && self.curr.token_type != UNPIVOT {
    return None
  }
  let out = []
  while self.parse_pivot() is Some(p) {
    out.push(p)
  }
  if out.is_empty() {
    None
  } else {
    Some(out)
  }
}

///|
pub fn Parser::parse_joins(
  self : Parser,
  alias_tokens? : TokenSet,
) -> Array[Expr] raise SqlglotError {
  let out = []
  while self.parse_join(alias_tokens?) is Some(j) {
    out.push(j)
  }
  out
}

///|
pub fn Parser::parse_unpivot_columns(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(INTO) {
    return None
  }
  let this = self.andv(self.match_text("NAME"), () => self.parse_column())
  let expressions = self.andl(self.match_text("VALUE"), () => self.parse_csv(() => self.parse_column()))
  Some(
    self.expression(
      mk(UnpivotColumns, [("this", this), ("expressions", expressions)]),
    ),
  )
}

///|
pub fn Parser::parse_simplified_pivot(
  self : Parser,
  is_unpivot? : Bool,
) -> Expr? raise SqlglotError {
  fn parse_on() -> Expr? raise SqlglotError {
    let this = self.parse_bitwise()
    if self.match_(IN) {
      return self.parse_in(this)
    }
    if self.match_(ALIAS, advance=false) {
      return self.parse_alias(this)
    }
    this
  }

  let this = self.parse_table()
  let expressions = self.andl(self.match_(ON), () => self.parse_csv(parse_on))
  let into = self.parse_unpivot_columns()
  let using = self.andl(self.match_(USING), () => self.parse_csv(() => self.parse_alias(
    self.parse_column(),
  )))
  let group = self.parse_group()
  Some(
    self.expression(
      mk(Pivot, [
        ("this", this),
        ("expressions", expressions),
        ("using", using),
        ("group", group),
        ("unpivot", is_unpivot),
        ("into", into),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_pivot_in(self : Parser) -> Expr? raise SqlglotError {
  fn parse_aliased_expression() -> Expr? raise SqlglotError {
    let this = self.parse_select_or_expression()
    self.match_(ALIAS) |> ignore
    let alias = self.parse_bitwise()
    match alias {
      Some(a) => {
        let a = if a.kind.is_a(Column) && a.db().is_empty() {
          match a.this() {
            Some(t) => t
            None => a
          }
        } else {
          a
        }
        Some(self.expression(mk(PivotAlias, [("this", this), ("alias", a)])))
      }
      None => this
    }
  }

  let value = self.parse_column()
  if !self.match_(IN) {
    self.raise_error("Expecting IN")
  }
  if self.match_(L_PAREN) {
    let exprs = if self.match_(ANY) {
      [mk1(PivotAny, self.parse_order())]
    } else {
      self.parse_csv(parse_aliased_expression)
    }
    self.match_r_paren()
    return Some(self.expression(mk(In, [("this", value), ("expressions", exprs)])))
  }
  Some(self.expression(mk(In, [("this", value), ("field", self.parse_id_var())])))
}

///|
pub fn Parser::parse_pivot_aggregation(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_pivot_aggregation {
    Some(f) => f(self)
    None => self.parse_pivot_aggregation_base()
  }
}

///|
pub fn Parser::parse_pivot_aggregation_base(self : Parser) -> Expr? raise SqlglotError {
  let func = self.parse_function()
  if func is None {
    if self.prev.token_type == COMMA {
      return None
    }
    self.raise_error("Expecting an aggregation function in PIVOT")
  }
  self.parse_alias(func)
}

///|
fn unpivot_target(e : Expr) -> Expr {
  if e.kind.is_a(Column) && e.table_name().is_empty() {
    match e.this() {
      Some(t) => return t
      None => ()
    }
  }
  if e.kind == Tuple {
    e.set("expressions", e.expressions().map(unpivot_target))
  }
  e
}

///|
fn cartesian_product(lists : Array[Array[String]]) -> Array[Array[String]] {
  let mut result : Array[Array[String]] = [[]]
  for l in lists {
    let next = []
    for prefix in result {
      for x in l {
        next.push(prefix + [x])
      }
    }
    result = next
  }
  result
}

///|
pub fn Parser::parse_pivot(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  let mut include_nulls : Bool? = None
  let mut unpivot = false
  if self.match_(PIVOT) {
    unpivot = false
  } else if self.match_(UNPIVOT) {
    unpivot = true
    if self.match_text_seq(["INCLUDE", "NULLS"]) {
      include_nulls = Some(true)
    } else if self.match_text_seq(["EXCLUDE", "NULLS"]) {
      include_nulls = Some(false)
    }
  } else {
    return None
  }
  if !self.match_(L_PAREN) {
    self.retreat(index)
    return None
  }
  let expressions = if unpivot {
    self.parse_csv(() => self.parse_column())
  } else {
    self.parse_csv(() => self.parse_pivot_aggregation())
  }
  if expressions.is_empty() {
    self.raise_error("Failed to parse PIVOT's aggregation list")
  }
  if !self.match_(FOR) {
    self.raise_error("Expecting FOR")
  }
  let fields = []
  while true {
    match self.try_parse(() => self.parse_pivot_in()) {
      Some(f) => fields.push(f)
      None => break
    }
  }
  let default_on_null = self.andv(
    self.match_text_seq(["DEFAULT", "ON", "NULL"]),
    () => self.parse_wrapped(() => self.parse_bitwise()),
  )
  let group = self.parse_group()
  self.match_r_paren()
  let pivot = self.expression(
    mk(Pivot, [
      ("expressions", expressions),
      ("fields", fields),
      ("unpivot", unpivot),
      ("include_nulls", include_nulls),
      ("default_on_null", default_on_null),
      ("group", group),
    ]),
  )
  if unpivot {
    pivot.set("expressions", pivot.expressions().map(unpivot_target))
    for pivot_field in pivot.list("fields") {
      if pivot_field.kind == In {
        match pivot_field.this() {
          Some(t) => pivot_field.set("this", unpivot_target(t))
          None => ()
        }
      }
    }
    pivot.set("value_columns_first", self.cfg.unpivot_value_columns_first)
  }
  if !self.match_any([PIVOT, UNPIVOT], advance=false) {
    pivot.set("alias", self.parse_table_alias())
  }
  if !unpivot {
    let names = self.pivot_column_names(expressions)
    let columns = []
    let all_fields : Array[Array[String]] = []
    for pivot_field in pivot.list("fields") {
      let pivot_field_expressions = pivot_field.expressions()
      if !pivot_field_expressions.is_empty() &&
        pivot_field_expressions[0].kind == PivotAny {
        continue
      }
      all_fields.push(
        pivot_field_expressions.map(fld => if self.cfg.identify_pivot_strings &&
          fld.kind != PivotAlias {
          expr_to_sql(fld, base_dialect())
        } else {
          fld.alias_or_name()
        }),
      )
    }
    if !all_fields.is_empty() {
      if !names.is_empty() {
        all_fields.push(names)
      }
      for fld_parts in cartesian_product(all_fields) {
        let fld_parts = fld_parts.copy()
        if !names.is_empty() && self.cfg.prefixed_pivot_columns {
          let last = fld_parts.pop().unwrap()
          fld_parts.insert(0, last)
        }
        columns.push(to_identifier(fld_parts.join("_")))
      }
    }
    pivot.set("columns", columns)
    pivot.set("identify_pivot_strings", self.cfg.identify_pivot_strings)
    pivot.set("prefixed_pivot_columns", self.cfg.prefixed_pivot_columns)
    pivot.set("pivot_column_naming", self.cfg.pivot_column_naming)
  }
  Some(pivot)
}

///|
pub fn Parser::pivot_column_names(
  self : Parser,
  aggregations : Array[Expr],
) -> Array[String] raise SqlglotError {
  match self.fns.hooks.pivot_column_names {
    Some(f) => f(self, aggregations)
    None => {
      let out = []
      for agg in aggregations {
        let a = agg.alias()
        if !a.is_empty() {
          out.push(a)
        }
      }
      out
    }
  }
}
