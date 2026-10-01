// Port of sqlglot/parser.py: WHERE/GROUP/HAVING/QUALIFY/CONNECT/ORDER/LIMIT/
// OFFSET/locks and set operations.

///|
pub fn Parser::parse_prewhere(
  self : Parser,
  skip_where_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_where_token && !self.match_(PREWHERE) {
    return None
  }
  let comments = self.prev_comments
  Some(self.expression(mk1(PreWhere, self.parse_disjunction()), comments~))
}

///|
pub fn Parser::parse_where(
  self : Parser,
  skip_where_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_where_token && !self.match_(WHERE) {
    return None
  }
  let comments = self.prev_comments
  Some(self.expression(mk1(Where, self.parse_disjunction()), comments~))
}

///|
pub fn Parser::parse_group(
  self : Parser,
  skip_group_by_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_group_by_token && !self.match_(GROUP_BY) {
    return None
  }
  let comments = self.prev_comments
  let group = mk0(Group)
  fn list_of(key : String) -> Array[Value] {
    match group.args.get(key) {
      Some(List(l)) => l
      _ => {
        let l = []
        group.args[key] = List(l)
        l
      }
    }
  }

  if self.match_(ALL) {
    group.args["all"] = Bool(true)
  } else if self.match_(DISTINCT) {
    group.args["all"] = Bool(false)
  }
  while true {
    if self.match_set(self.cfg.query_modifier_tokens, advance=false) {
      break
    }
    let exprs = self.parse_csv(() => {
      expr_or(self.parse_grouping_sets(), () => {
        expr_or(self.parse_cube_or_rollup(), () => self.parse_disjunction())
      })
    })
    let l = list_of("expressions")
    for e in exprs {
      l.push(Node(e))
    }
    let before_with_index = self.index
    let mut handled = false
    if self.match_(WITH) {
      match self.parse_cube_or_rollup(with_prefix=true) {
        Some(cube_or_rollup) => {
          let key = if cube_or_rollup.kind == Rollup {
            "rollup"
          } else {
            "cube"
          }
          list_of(key).push(Node(cube_or_rollup))
          handled = true
        }
        None => ()
      }
    }
    if !handled {
      match self.parse_grouping_sets() {
        Some(grouping_sets) => {
          list_of("grouping_sets").push(Node(grouping_sets))
          break
        }
        None =>
          if self.match_text("TOTALS") {
            group.args["totals"] = Bool(true)
          }
      }
    }
    if before_with_index <= self.index && self.index <= before_with_index + 1 {
      self.retreat(before_with_index)
      break
    }
  }
  // re-establish parents for the lists built in place
  let g = Expr::new(Group, group.args)
  Some(self.expression(g, comments~))
}

///|
pub fn Parser::parse_cube_or_rollup(
  self : Parser,
  with_prefix? : Bool = false,
) -> Expr? raise SqlglotError {
  let kind = if self.match_(CUBE) {
    Cube
  } else if self.match_(ROLLUP) {
    Rollup
  } else {
    return None
  }
  let expressions = if with_prefix {
    []
  } else {
    self.parse_wrapped_csv(() => self.parse_bitwise())
  }
  Some(self.expression(mk(kind, [("expressions", expressions)])))
}

///|
pub fn Parser::parse_grouping_sets(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(GROUPING_SETS) {
    return Some(
      self.expression(
        mk(GroupingSets, [
          (
            "expressions",
            self.parse_wrapped_csv(() => self.parse_grouping_set()),
          ),
        ]),
      ),
    )
  }
  None
}

///|
pub fn Parser::parse_grouping_set(self : Parser) -> Expr? raise SqlglotError {
  expr_or(self.parse_grouping_sets(), () => {
    expr_or(self.parse_cube_or_rollup(), () => self.parse_bitwise())
  })
}

///|
pub fn Parser::parse_having(
  self : Parser,
  skip_having_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !skip_having_token && !self.match_(HAVING) {
    return None
  }
  let comments = self.prev_comments
  Some(self.expression(mk1(Having, self.parse_disjunction()), comments~))
}

///|
pub fn Parser::parse_qualify(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(QUALIFY) {
    return None
  }
  Some(self.expression(mk1(Qualify, self.parse_disjunction())))
}

///|
pub fn Parser::parse_connect_with_prior(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_connect_with_prior {
    Some(f) => f(self)
    None => self.parse_connect_with_prior_base()
  }
}

///|
pub fn Parser::parse_connect_with_prior_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  self.fns.no_paren_function_parsers["PRIOR"] = p => {
    Some(p.expression(mk1(Prior, p.parse_bitwise())))
  }
  let connect = self.parse_disjunction() catch {
    e => {
      self.fns.no_paren_function_parsers.remove("PRIOR")
      raise e
    }
  }
  self.fns.no_paren_function_parsers.remove("PRIOR")
  connect
}

///|
pub fn Parser::parse_connect(
  self : Parser,
  skip_start_token? : Bool = false,
) -> Expr? raise SqlglotError {
  let mut start : Expr? = None
  if skip_start_token {
    start = None
  } else if self.match_text_seq(["START", "WITH"]) {
    start = self.parse_disjunction()
  } else {
    return None
  }
  self.match_(CONNECT_BY) |> ignore
  let nocycle = self.match_text("NOCYCLE")
  let connect = self.parse_connect_with_prior()
  if start is None && self.match_text_seq(["START", "WITH"]) {
    start = self.parse_disjunction()
  }
  Some(
    self.expression(
      mk(Connect, [("start", start), ("connect", connect), ("nocycle", nocycle)]),
    ),
  )
}

///|
pub fn Parser::parse_name_as_expression(
  self : Parser,
) -> Expr? raise SqlglotError {
  let mut this = self.parse_id_var(any_token=true)
  if self.match_(ALIAS) {
    this = Some(
      self.expression(
        mk(Alias, [("alias", this), ("this", self.parse_disjunction())]),
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_interpolate(
  self : Parser,
) -> Array[Expr]? raise SqlglotError {
  if self.match_text("INTERPOLATE") {
    return Some(self.parse_wrapped_csv(() => self.parse_name_as_expression()))
  }
  None
}

///|
pub fn Parser::parse_order(
  self : Parser,
  this? : Expr?,
  skip_order_token? : Bool = false,
) -> Expr? raise SqlglotError {
  let this : Expr? = match this {
    Some(t) => t
    None => None
  }
  let mut siblings : Bool? = None
  if !skip_order_token && !self.match_(ORDER_BY) {
    if !self.match_(ORDER_SIBLINGS_BY) {
      return this
    }
    siblings = Some(true)
  }
  let comments = self.prev_comments
  Some(
    self.expression(
      mk(Order, [
        ("this", this),
        ("expressions", self.parse_csv(() => self.parse_ordered())),
        ("siblings", siblings),
      ]),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_sort(
  self : Parser,
  kind : Kind,
  token : TokenType,
) -> Expr? raise SqlglotError {
  if !self.match_(token) {
    return None
  }
  Some(
    self.expression(
      mk(kind, [("expressions", self.parse_csv(() => self.parse_ordered()))]),
    ),
  )
}

///|
pub fn Parser::parse_ordered(
  self : Parser,
  parse_method? : () -> Expr? raise SqlglotError,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_ordered {
    Some(f) => f(self, parse_method)
    None => self.parse_ordered_base(parse_method?)
  }
}

///|
pub fn Parser::parse_ordered_base(
  self : Parser,
  parse_method? : () -> Expr? raise SqlglotError,
) -> Expr? raise SqlglotError {
  let mut this = match parse_method {
    Some(f) => f()
    None => self.parse_disjunction()
  }
  let t = match this {
    Some(t) => t
    None => return None
  }
  if py_upper(t.name()) == "ALL" && self.dialect.cfg.supports_order_by_all {
    this = Some(var_("ALL"))
  }
  let asc = self.match_(ASC)
  let desc : Bool? = if self.match_(DESC) {
    Some(true)
  } else if asc {
    Some(false)
  } else {
    None
  }
  let is_nulls_first = self.match_text_seq(["NULLS", "FIRST"])
  let is_nulls_last = self.match_text_seq(["NULLS", "LAST"])
  let mut nulls_first = is_nulls_first
  let explicitly_null_ordered = is_nulls_first || is_nulls_last
  let null_ordering = self.dialect.cfg.null_ordering
  let is_desc = desc == Some(true)
  if !explicitly_null_ordered &&
    (
      (!is_desc && null_ordering == "nulls_are_small") ||
      (is_desc && null_ordering != "nulls_are_small")
    ) &&
    null_ordering != "nulls_are_last" {
    nulls_first = true
  }
  let with_fill = if self.match_text_seq(["WITH", "FILL"]) {
    let from_ = self.andv(self.match_(FROM), () => self.parse_bitwise())
    let to = self.andv(self.match_text("TO"), () => self.parse_bitwise())
    let step = self.andv(self.match_text("STEP"), () => self.parse_bitwise())
    Some(
      self.expression(
        mk(WithFill, [
          ("from_", from_),
          ("to", to),
          ("step", step),
          ("interpolate", self.parse_interpolate()),
        ]),
      ),
    )
  } else {
    None
  }
  Some(
    self.expression(
      mk(Ordered, [
        ("this", this),
        ("desc", desc),
        ("nulls_first", nulls_first),
        ("with_fill", with_fill),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_limit_options(self : Parser) -> Expr? raise SqlglotError {
  let percent = self.match_any([PERCENT, MOD])
  let rows = self.match_texts(["ROW", "ROWS"])
  self.match_text("ONLY") |> ignore
  let with_ties = self.match_text_seq(["WITH", "TIES"])
  if !(percent || rows || with_ties) {
    return None
  }
  Some(
    self.expression(
      mk(LimitOptions, [
        ("percent", percent),
        ("rows", rows),
        ("with_ties", with_ties),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_limit(
  self : Parser,
  this? : Expr?,
  top? : Bool = false,
  skip_limit_token? : Bool = false,
) -> Expr? raise SqlglotError {
  let this : Expr? = match this {
    Some(t) => t
    None => None
  }
  if skip_limit_token || self.match_(if top { TOP } else { LIMIT }) {
    let comments = self.prev_comments
    let mut expression : Expr? = None
    if top {
      let limit_paren = self.match_(L_PAREN)
      expression = if limit_paren {
        expr_or(self.parse_term(), () => self.parse_select())
      } else {
        self.parse_number()
      }
      if limit_paren {
        self.match_r_paren()
      }
    } else {
      if self.dialect.cfg.supports_limit_all && self.match_(ALL) {
        return this
      }
      expression = self.parse_term(parse_mod=false)
    }
    let limit_options = self.parse_limit_options()
    let mut offset : Expr? = None
    if self.match_(COMMA) {
      offset = expression
      expression = self.parse_term()
    }
    let limit_exp = self.expression(
      mk(Limit, [
        ("this", this),
        ("expression", expression),
        ("offset", offset),
        ("limit_options", limit_options),
        ("expressions", self.parse_limit_by()),
      ]),
      comments~,
    )
    if top {
      limit_exp.get_meta()["top"] = Bool(true)
    }
    return Some(limit_exp)
  }
  if self.match_(FETCH) {
    let direction = if self.match_any([FIRST, NEXT]) {
      self.prev_upper()
    } else {
      "FIRST"
    }
    let count = if self.match_texts(["ROW", "ROWS"], advance=false) {
      None
    } else {
      self.parse_field(tokens=self.cfg.fetch_tokens)
    }
    return Some(
      self.expression(
        mk(Fetch, [
          ("direction", direction),
          ("count", count),
          ("limit_options", self.parse_limit_options()),
        ]),
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_offset(
  self : Parser,
  this? : Expr?,
) -> Expr? raise SqlglotError {
  let this : Expr? = match this {
    Some(t) => t
    None => None
  }
  if !self.match_(OFFSET) {
    return this
  }
  let count = self.parse_term()
  self.match_texts(["ROW", "ROWS"]) |> ignore
  Some(
    self.expression(
      mk(Offset, [
        ("this", this),
        ("expression", count),
        ("expressions", self.parse_limit_by()),
      ]),
    ),
  )
}

///|
pub fn Parser::can_parse_limit_or_offset(self : Parser) -> Bool {
  if !self.match_any(self.cfg.ambiguous_alias_tokens, advance=false) {
    return false
  }
  let index = self.index
  let mut result = self.try_parse(() => self.parse_limit(), retreat=true)
    is Some(_) ||
    self.try_parse(() => self.parse_offset(), retreat=true) is Some(_)
  self.retreat(index)
  if self.next.token_type == MATCH_CONDITION {
    result = false
  }
  result
}

///|
pub fn Parser::can_parse_named_window(self : Parser) -> Bool {
  if !self.match_(WINDOW, advance=false) {
    return false
  }
  let n = self.tokens.length()
  if self.index + 1 >= n ||
    !self.cfg.id_var_tokens.contains(self.tokens[self.index + 1].token_type) {
    return false
  }
  if self.index + 2 >= n || self.tokens[self.index + 2].token_type != ALIAS {
    return false
  }
  self.index + 3 < n && self.tokens[self.index + 3].token_type == L_PAREN
}

///|
pub fn Parser::parse_limit_by(self : Parser) -> Array[Expr]? raise SqlglotError {
  if self.match_text("BY") {
    Some(self.parse_csv(() => self.parse_bitwise()))
  } else {
    None
  }
}

///|
pub fn Parser::parse_locks(self : Parser) -> Array[Expr] raise SqlglotError {
  let locks = []
  while true {
    let mut update : Bool? = None
    let mut key : Bool? = None
    if self.match_text_seq(["FOR", "UPDATE"]) {
      update = Some(true)
    } else if self.match_text_seq(["FOR", "SHARE"]) ||
      self.match_text_seq(["LOCK", "IN", "SHARE", "MODE"]) {
      update = Some(false)
    } else if self.match_text_seq(["FOR", "KEY", "SHARE"]) {
      update = Some(false)
      key = Some(true)
    } else if self.match_text_seq(["FOR", "NO", "KEY", "UPDATE"]) {
      update = Some(true)
      key = Some(true)
    } else {
      break
    }
    let expressions = if self.match_text("OF") {
      Some(self.parse_csv(() => self.parse_table(schema=true)))
    } else {
      None
    }
    let mut wait : Value? = None
    if self.match_text("NOWAIT") {
      wait = Some(Bool(true))
    } else if self.match_text("WAIT") {
      wait = self.parse_primary().map(x => Node(x))
    } else if self.match_text_seq(["SKIP", "LOCKED"]) {
      wait = Some(Bool(false))
    }
    locks.push(
      self.expression(
        mk(Lock, [
          ("update", update),
          ("expressions", expressions),
          ("wait", wait),
          ("key", key),
        ]),
      ),
    )
  }
  locks
}

///|
pub fn Parser::parse_set_operation(
  self : Parser,
  this : Expr?,
  consume_pipe? : Bool = false,
) -> Expr? raise SqlglotError {
  let start = self.index
  let (_, side_token, kind_token) = self.parse_join_parts()
  let side = match side_token {
    Some(t) => Some(t.text)
    None => None
  }
  let mut kind = match kind_token {
    Some(t) => Some(t.text)
    None => None
  }
  if !self.match_set(self.cfg.set_operations) {
    self.retreat(start)
    return None
  }
  let token_type = self.prev.token_type
  let operation = if token_type == UNION {
    Union
  } else if token_type == EXCEPT {
    Except
  } else {
    Intersect
  }
  let comments = self.prev.comments
  let distinct : Bool? = if self.match_(DISTINCT) {
    Some(true)
  } else if self.match_(ALL) {
    Some(false)
  } else {
    let d = match self.dialect.cfg.set_op_distinct_by_default.get(operation) {
      Some(v) => v
      None => None
    }
    if d is None {
      self.raise_error("Expected DISTINCT or ALL for \{operation.name()}")
    }
    d
  }
  let mut by_name : Bool? = if self.match_text_seq(["BY", "NAME"]) ||
    self.match_text_seq(["STRICT", "CORRESPONDING"]) {
    Some(true)
  } else {
    None
  }
  if self.match_text("CORRESPONDING") {
    by_name = Some(true)
    if side is None && kind is None {
      kind = Some("INNER")
    }
  }
  let on_column_list = if by_name == Some(true) &&
    self.match_texts(["ON", "BY"]) {
    Some(self.parse_wrapped_csv(() => self.parse_column()))
  } else {
    None
  }
  let mut expression = self.parse_select(
    nested=true,
    parse_set_operation=false,
    consume_pipe~,
  )
  let mut this = this
  match this {
    Some(t) if t.kind == Values => this = Some(self.values_to_select(t))
    _ => ()
  }
  match expression {
    Some(e) if e.kind == Values => expression = Some(self.values_to_select(e))
    _ => ()
  }
  match this {
    Some(t) if t.kind.is_a(Alias) &&
      (match t.this() {
        Some(s) => s.kind.is_a(Subquery)
        None => false
      }) => {
      let subquery = t.this().unwrap()
      subquery.set("alias", mk1(TableAlias, t.arg("alias")))
      subquery.add_comments(Some(t.pop_comments()))
      this = Some(subquery)
    }
    _ => ()
  }
  Some(
    self.expression(
      mk(operation, [
        ("this", this),
        ("distinct", distinct),
        ("by_name", by_name),
        ("expression", expression),
        ("side", side),
        ("kind", kind),
        ("on", on_column_list),
      ]),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_set_operations(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  let mut this = this
  while this is Some(_) {
    match self.parse_set_operation(this) {
      Some(setop) => this = Some(setop)
      None => break
    }
  }
  match this {
    Some(t) if t.kind.is_a(SetOperation) &&
      self.cfg.modifiers_attached_to_set_op => {
      match t.expression() {
        Some(expression) =>
          for arg in self.cfg.set_op_modifiers {
            match expression.get(arg) {
              Some(Node(expr)) if arg == "limit" && expr.meta_bool("top") => ()
              Some(v) if v.truthy() => {
                expression.set(arg, null_arg)
                t.set(arg, v)
              }
              _ => ()
            }
          }
        None => ()
      }
      if self.curr.token_type == LIMIT || self.curr.token_type == FETCH {
        this = self.parse_query_modifiers(this)
      }
    }
    _ => ()
  }
  this
}
