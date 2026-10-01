// Port of sqlglot/parser.py: SELECT, WITH/CTE, aliases, subqueries, query modifiers.

///|
pub fn Parser::parse_select(
  self : Parser,
  nested? : Bool = false,
  table? : Bool = false,
  parse_subquery_alias? : Bool = true,
  parse_set_operation? : Bool = true,
  consume_pipe? : Bool = true,
  from_? : Expr,
) -> Expr? raise SqlglotError {
  let mut query = self.parse_select_query(
    nested~,
    table~,
    parse_subquery_alias~,
    parse_set_operation~,
  )
  if consume_pipe && self.match_(PIPE_GT, advance=false) {
    if query is None && from_ is Some(f) {
      query = Some(select_star_from(Some(f)))
    }
    match query {
      Some(q) if q.kind.is_a(Query) => {
        query = self.parse_pipe_syntax_query(q)
        match query {
          Some(q2) if table => query = Some(q2.subquery(copy=false))
          _ => ()
        }
      }
      _ => ()
    }
  }
  query
}

///|
pub fn Parser::parse_select_query(
  self : Parser,
  nested? : Bool = false,
  table? : Bool = false,
  parse_subquery_alias? : Bool = true,
  parse_set_operation? : Bool = true,
) -> Expr? raise SqlglotError {
  let cte = self.parse_with()
  match cte {
    Some(cte) => {
      let mut this = match self.parse_statement() {
        Some(t) => t
        None => {
          self.raise_error("Failed to parse any statement following CTE")
          return Some(cte)
        }
      }
      while this.kind.is_a(Subquery) && this.is_wrapper() {
        match this.this() {
          Some(t) => this = t
          None => break
        }
      }
      if this.kind.has_arg("with_") {
        match this.arg("with_") {
          Some(inner_cte) => {
            cte.set("expressions", cte.expressions() + inner_cte.expressions())
            if inner_cte.has("recursive") {
              cte.set("recursive", true)
            }
          }
          None => ()
        }
        this.set("with_", cte)
      } else {
        self.raise_error("\{this.kind.key()} does not support CTE")
        this = cte
      }
      return Some(this)
    }
    None => ()
  }
  let mut from_ = if self.match_(FROM, advance=false) {
    self.parse_from(joins=true, consume_pipe=true)
  } else {
    None
  }
  let mut this : Expr? = None
  if self.match_(SELECT) {
    let comments = self.prev_comments
    let hint = self.parse_hint()
    let mut all_ : Bool? = None
    let mut matched_distinct = false
    if self.next.ok() && self.next.token_type != DOT {
      all_ = Some(self.match_(ALL))
      matched_distinct = self.match_set(self.cfg.distinct_tokens)
    }
    let kind = if self.match_(ALIAS) && self.match_texts(["STRUCT", "VALUE"]) {
      Some(self.prev_upper())
    } else {
      None
    }
    let mut distinct : Expr? = if matched_distinct {
      let on = if self.match_(ON) { self.parse_value(values=false) } else { None }
      Some(self.expression(mk(Distinct, [("on", on)])))
    } else {
      None
    }
    let operation_modifiers = []
    while self.curr.ok() && self.match_text_set(self.cfg.operation_modifiers) {
      operation_modifiers.push(var_(self.prev_upper()))
    }
    let limit = self.parse_limit(top=true)
    if limit is Some(_) && !matched_distinct && all_ != Some(true) {
      matched_distinct = self.match_set(self.cfg.distinct_tokens)
      if matched_distinct {
        let on = if self.match_(ON) { self.parse_value(values=false) } else { None }
        distinct = Some(self.expression(mk(Distinct, [("on", on)])))
      } else {
        all_ = Some(self.match_(ALL))
      }
    }
    if all_ == Some(true) && distinct is Some(_) {
      self.raise_error("Cannot specify both ALL and DISTINCT after SELECT")
    }
    let (projections, exclude) = self.parse_projections()
    let sel = self.expression(
      mk(Select, [
        ("kind", kind),
        ("hint", hint),
        ("distinct", distinct),
        ("expressions", projections),
        ("limit", limit),
        ("exclude", exclude),
        (
          "operation_modifiers",
          if operation_modifiers.is_empty() {
            None
          } else {
            Some(operation_modifiers)
          },
        ),
      ]),
    )
    sel.comments = Some(comments)
    match self.parse_into_clause() {
      Some(into) => sel.set("into", into)
      None => ()
    }
    if from_ is None {
      from_ = self.parse_from()
    }
    match from_ {
      Some(f) => sel.set("from_", f)
      None => ()
    }
    this = self.parse_query_modifiers(Some(sel))
  } else if (table || nested) && self.match_(L_PAREN) {
    let comments = self.prev_comments
    let this = self.parse_wrapped_select(table~)
    match this {
      Some(t) => t.add_comments(Some(comments), prepend=true)
      None => ()
    }
    self.match_r_paren()
    return self.parse_subquery(this, parse_alias=parse_subquery_alias)
  } else if self.match_(VALUES, advance=false) {
    this = self.parse_derived_table_values()
  } else if from_ is Some(f) {
    let sel = mk(Select, [("expressions", [mk0(Star)])])
    sel.set("from_", mk1(From, f.this()))
    this = self.parse_query_modifiers(Some(sel))
  } else if self.match_(SUMMARIZE) {
    let table = self.match_(TABLE)
    let this = expr_or(self.parse_select(), () => expr_or(
      self.parse_string(),
      () => self.parse_table(),
    ))
    return Some(self.expression(mk(Summarize, [("this", this), ("table", table)])))
  } else if self.match_(DESCRIBE) {
    this = self.parse_describe()
  } else {
    this = None
  }
  if parse_set_operation {
    self.parse_set_operations(this)
  } else {
    this
  }
}

///|
pub fn Parser::parse_recursive_with_search(self : Parser) -> Expr? raise SqlglotError {
  self.match_text("SEARCH") |> ignore
  let kind = if self.match_text_set(self.cfg.recursive_cte_search_kind) {
    self.prev_upper()
  } else {
    return None
  }
  self.match_text_seq(["FIRST", "BY"]) |> ignore
  let this = self.parse_id_var()
  let expression = self.andv(self.match_text("SET"), () => self.parse_id_var())
  let using_ = self.andv(self.match_text("USING"), () => self.parse_id_var())
  Some(
    self.expression(
      mk(RecursiveWithSearch, [
        ("kind", kind),
        ("this", this),
        ("expression", expression),
        ("using", using_),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_with(
  self : Parser,
  skip_with_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_with_token && !self.match_(WITH) {
    return None
  }
  let comments = self.prev_comments
  let mut recursive = self.match_(RECURSIVE)
  let mut last_comments : Array[String]? = None
  let expressions = []
  let udfs = []
  while true {
    let cte = self.parse_cte()
    match cte {
      Some(c) => {
        if c.kind == FunctionSpecification {
          udfs.push(c)
        } else {
          expressions.push(c)
        }
        match last_comments {
          Some(lc) if !lc.is_empty() => c.add_comments(Some(lc))
          _ => ()
        }
      }
      None => ()
    }
    if !self.match_(COMMA) && !self.match_(WITH) {
      break
    } else {
      self.match_(WITH) |> ignore
      recursive = self.match_(RECURSIVE) || recursive
    }
    last_comments = Some(self.prev_comments)
  }
  let search = self.parse_recursive_with_search()
  Some(
    self.expression(
      mk(With, [
        ("expressions", expressions),
        ("recursive", if recursive { Some(true) } else { None }),
        ("search", search),
        ("udfs", if udfs.is_empty() { None } else { Some(udfs) }),
      ]),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_cte(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_cte {
    Some(f) => f(self)
    None => self.parse_cte_base()
  }
}

///|
pub fn Parser::parse_cte_base(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  let alias = self.parse_table_alias(alias_tokens=self.cfg.id_var_tokens)
  match alias {
    Some(a) if a.this() is Some(_) => ()
    _ => self.raise_error("Expected CTE to have alias")
  }
  let key_expressions = if self.match_text_seq(["USING", "KEY"]) {
    Some(self.parse_wrapped_id_vars())
  } else {
    None
  }
  if !self.match_(ALIAS) && !self.cfg.optional_alias_token_cte {
    self.retreat(index)
    return None
  }
  let comments = self.prev_comments
  let materialized : Bool? = if self.match_text_seq(["NOT", "MATERIALIZED"]) {
    Some(false)
  } else if self.match_text("MATERIALIZED") {
    Some(true)
  } else {
    None
  }
  let this = self.parse_wrapped(() => self.parse_statement())
  let cte = self.expression(
    mk(CTE, [
      ("this", this),
      ("alias", alias),
      ("materialized", materialized),
      ("key_expressions", key_expressions),
    ]),
    comments~,
  )
  match cte.this() {
    Some(values) if values.kind == Values =>
      cte.set("this", self.values_to_select(values))
    _ => ()
  }
  Some(cte)
}

///|
pub fn Parser::values_to_select(self : Parser, values : Expr) -> Expr {
  ignore(self)
  if !values.alias().is_empty() {
    return select_star_from(Some(values))
  }
  select_star_from(Some(alias_table(values, "_values")))
}

///|
pub fn Parser::parse_table_alias(
  self : Parser,
  alias_tokens? : TokenSet,
) -> Expr? raise SqlglotError {
  if self.can_parse_limit_or_offset() {
    return None
  }
  if py_upper(self.curr.text) == "START" && py_upper(self.next.text) == "WITH" {
    return None
  }
  let any_token = self.match_(ALIAS)
  let tokens = match alias_tokens {
    Some(t) => t
    None => self.cfg.table_alias_tokens
  }
  let alias = expr_or(self.parse_id_var(any_token~, tokens~), () => self.parse_string_as_identifier())
  let index = self.index
  let columns = if self.match_(L_PAREN) {
    let columns = self.parse_csv(() => self.parse_function_parameter())
    if !columns.is_empty() {
      self.match_r_paren()
    } else {
      self.retreat(index)
    }
    Some(columns)
  } else {
    None
  }
  let has_columns = match columns {
    Some(c) => !c.is_empty()
    None => false
  }
  if alias is None && !has_columns {
    return None
  }
  let table_alias = self.expression(
    mk(TableAlias, [("this", alias), ("columns", columns)]),
  )
  match alias {
    Some(a) if a.kind == Identifier => table_alias.add_comments(Some(a.pop_comments()))
    _ => ()
  }
  Some(table_alias)
}

///|
pub fn Parser::parse_subquery(
  self : Parser,
  this : Expr?,
  parse_alias? : Bool = true,
) -> Expr? raise SqlglotError {
  let this = match this {
    Some(t) => t
    None => return None
  }
  let pivots = self.parse_pivots()
  let alias = if parse_alias { self.parse_table_alias() } else { None }
  let sample = self.parse_table_sample()
  Some(
    self.expression(
      mk(Subquery, [
        ("this", this),
        ("pivots", pivots),
        ("alias", alias),
        ("sample", sample),
      ]),
    ),
  )
}

///|
fn Parser::implicit_unnests_to_explicit(self : Parser, this : Expr) -> Expr {
  let refs : @set.Set[String] = @set.Set::new()
  match this.arg("from_") {
    Some(f) =>
      match f.this() {
        Some(t) =>
          refs.add(normalize_identifiers(t.copy(), self.dialect).alias_or_name())
        None => ()
      }
    None => ()
  }
  for join in this.list("joins") {
    let table = match join.this() {
      Some(t) => t
      None => continue
    }
    let normalized_table = table.copy()
    normalized_table.get_meta()["maybe_column"] = Bool(true)
    let normalized_table = normalize_identifiers(normalized_table, self.dialect)
    if table.kind == Table && !join.has("on") {
      let parts = normalized_table.parts()
      if parts.length() > 1 && refs.contains(parts[0].name()) {
        let table_as_column = table.to_column()
        let unnest = mk(Unnest, [("expressions", [table_as_column])])
        match table.arg("alias") {
          Some(a) if a.kind == TableAlias => {
            match table_as_column.this() {
              Some(inner) => table_as_column.replace(Some(inner)) |> ignore
              None => ()
            }
            let ta = mk1(TableAlias, null_arg)
            match a.this() {
              Some(at) => ta.append("columns", to_identifier_expr(at))
              None => ()
            }
            unnest.set("alias", ta)
          }
          _ => ()
        }
        table.replace(Some(unnest)) |> ignore
      }
    }
    refs.add(normalized_table.alias_or_name())
  }
  this
}

///|
pub fn Parser::parse_query_modifiers(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let this = match this {
    Some(t) => t
    None => return None
  }
  if this.kind.is_any(self.cfg.modifiables) {
    for join in self.parse_joins() {
      this.append("joins", join)
    }
    while self.parse_lateral() is Some(lateral) {
      this.append("laterals", lateral)
    }
    while true {
      if self.match_keys(self.fns.query_modifier_parsers, advance=false) {
        let modifier_token = self.curr
        if modifier_token.token_type == LIMIT || modifier_token.token_type == FETCH {
          match this.arg("limit") {
            Some(limit) if limit.meta_bool("top") => break
            _ => ()
          }
        }
        let parser = self.fns.query_modifier_parsers[modifier_token.token_type]
        let (key, expression) = parser(self)
        match expression {
          Some(ev) if ev.truthy() => {
            if this.has(key) {
              self.raise_error(
                "Found multiple '\{py_upper(modifier_token.text)}' clauses",
                token=modifier_token,
              )
            }
            this.set(key, ev)
            if key == "limit" {
              match ev {
                Node(expr) => {
                  let offset = expr.arg("offset")
                  expr.set("offset", null_arg)
                  match offset {
                    Some(off) => {
                      if this.has("offset") {
                        self.raise_error(
                          "Found multiple 'OFFSET' clauses",
                          token=modifier_token,
                        )
                      }
                      let offset = mk(Offset, [("expression", off)])
                      this.set("offset", offset)
                      let limit_by_expressions = expr.expressions()
                      expr.set("expressions", null_arg)
                      offset.set("expressions", limit_by_expressions)
                    }
                    None => ()
                  }
                }
                _ => ()
              }
            }
            continue
          }
          _ => ()
        }
      }
      if py_upper(self.curr.text) == "START" {
        let modifier_token = self.curr
        match self.parse_connect() {
          Some(connect) => {
            if this.has("connect") {
              self.raise_error(
                "Found multiple 'START WITH' clauses",
                token=modifier_token,
              )
            }
            this.set("connect", connect)
            continue
          }
          None => ()
        }
      }
      break
    }
  }
  if self.cfg.supports_implicit_unnest && this.has("from_") {
    return Some(self.implicit_unnests_to_explicit(this))
  }
  Some(this)
}

///|
pub fn Parser::parse_hint_fallback_to_string(self : Parser) -> Expr? raise SqlglotError {
  let start = self.curr
  while self.curr.ok() {
    self.advance()
  }
  let end = self.tokens[self.index - 1]
  Some(mk(Hint, [("expressions", [self.find_sql(start, end)])]))
}

///|
pub fn Parser::parse_hint_function_call(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_hint_function_call {
    Some(f) => f(self)
    None => self.parse_function_call()
  }
}

///|
pub fn Parser::parse_hint_body(self : Parser) -> Expr? raise SqlglotError {
  let start_index = self.index
  let mut should_fallback_to_string = false
  let hints = []
  try {
    while true {
      let hint = self.parse_csv(() => expr_or(self.parse_hint_function_call(), () => self.parse_var(
        upper=true,
      )))
      if hint.is_empty() {
        break
      }
      hints.append(hint)
    }
  } catch {
    ParseError(_, _) => should_fallback_to_string = true
    e => raise e
  }
  if should_fallback_to_string || self.curr.ok() {
    self.retreat(start_index)
    return self.parse_hint_fallback_to_string()
  }
  Some(self.expression(mk(Hint, [("expressions", hints)])))
}

///|
pub fn Parser::parse_hint(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(HINT) && !self.prev_comments.is_empty() {
    return Some(parse_one(self.prev_comments[0], dialect=self.dialect, into=[Hint]))
  }
  None
}

///|
pub fn Parser::parse_into_clause(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_into_clause {
    Some(f) => f(self)
    None => self.parse_into_clause_base()
  }
}

///|
pub fn Parser::parse_into_clause_base(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(INTO) {
    return None
  }
  let temp = self.match_(TEMPORARY)
  let unlogged = self.match_text("UNLOGGED")
  self.match_(TABLE) |> ignore
  Some(
    self.expression(
      mk(Into, [
        ("this", self.parse_table(schema=true)),
        ("temporary", temp),
        ("unlogged", unlogged),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_from(
  self : Parser,
  joins? : Bool = false,
  skip_from_token? : Bool = false,
  consume_pipe? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_from {
    Some(f) => f(self, joins, skip_from_token, consume_pipe)
    None => self.parse_from_base(joins~, skip_from_token~, consume_pipe~)
  }
}

///|
pub fn Parser::parse_from_base(
  self : Parser,
  joins? : Bool = false,
  skip_from_token? : Bool = false,
  consume_pipe? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_from_token && !self.match_(FROM) {
    return None
  }
  let comments = self.prev_comments
  Some(
    self.expression(
      mk1(From, self.parse_table(joins~, consume_pipe~)),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_match_recognize_measure(self : Parser) -> Expr raise SqlglotError {
  let window_frame : Value = if self.match_texts(["FINAL", "RUNNING"]) {
    Str(self.prev_upper())
  } else {
    Bool(false)
  }
  self.expression(
    mk(MatchRecognizeMeasure, [
      ("window_frame", window_frame),
      ("this", self.parse_expression()),
    ]),
  )
}
