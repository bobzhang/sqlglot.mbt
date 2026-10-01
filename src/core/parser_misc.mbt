// Port of sqlglot/parser.py: TRUNCATE, COPY, GRANT/REVOKE, pipe syntax, DECLARE and
// other miscellaneous parsers.

///|
pub fn Parser::parse_truncate_table(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  if self.match_(L_PAREN) {
    self.retreat(self.index - 2)
    return self.parse_function()
  }
  let is_database = self.match_(DATABASE)
  self.match_(TABLE) |> ignore
  let exists = self.parse_exists(not_=false)
  let expressions = self.parse_csv(() => {
    self.parse_table(schema=true, is_db_reference=is_database)
  })
  let cluster = if self.match_(ON) { self.parse_on_property() } else { None }
  let identity = if self.match_text_seq(["RESTART", "IDENTITY"]) {
    Some("RESTART")
  } else if self.match_text_seq(["CONTINUE", "IDENTITY"]) {
    Some("CONTINUE")
  } else {
    None
  }
  let option = if self.match_text("CASCADE") || self.match_text("RESTRICT") {
    Some(self.prev.text)
  } else {
    None
  }
  let partition = self.parse_partition()
  if self.curr.ok() {
    return Some(self.parse_as_command(start))
  }
  Some(
    self.expression(
      mk(TruncateTable, [
        ("expressions", expressions),
        ("is_database", is_database),
        ("exists", exists),
        ("cluster", cluster),
        ("identity", identity),
        ("option", option),
        ("partition", partition),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_indexed_column(self : Parser) -> Expr? raise SqlglotError {
  self.parse_ordered(parse_method=() => self.parse_opclass())
}

///|
pub fn Parser::parse_with_operator(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_indexed_column()
  if !self.match_(WITH) {
    return this
  }
  let op = self.parse_var(any_token=true, tokens=self.cfg.reserved_tokens)
  Some(self.expression(mk(WithOperator, [("this", this), ("op", op)])))
}

///|
pub fn Parser::parse_wrapped_options(
  self : Parser,
) -> Array[Expr] raise SqlglotError {
  self.match_(EQ) |> ignore
  self.match_(L_PAREN) |> ignore
  let opts = []
  while self.curr.ok() && !self.match_(R_PAREN) {
    let option : Value? = if self.match_text_seq(["FORMAT_NAME", "="]) {
      Some(Node(self.parse_format_name()))
    } else {
      self.parse_property()
    }
    match option {
      None => {
        self.raise_error("Unable to parse option")
        break
      }
      Some(Node(o)) => opts.push(o)
      Some(List(l)) =>
        for x in l {
          match x {
            Node(o) => opts.push(o)
            _ => ()
          }
        }
      _ => ()
    }
  }
  opts
}

///|
pub fn Parser::parse_copy_parameters(
  self : Parser,
) -> Array[Expr] raise SqlglotError {
  let sep : TokenType? = if self.dialect.cfg.copy_params_are_csv {
    Some(COMMA)
  } else {
    None
  }
  let options = []
  while self.curr.ok() && !self.match_(R_PAREN, advance=false) {
    let option = self.parse_var(any_token=true)
    let prev = self.prev_upper()
    self.match_(EQ) |> ignore
    self.match_(ALIAS) |> ignore
    let param = self.expression(mk1(CopyParameter, option))
    if self.cfg.copy_into_varlen_options.contains(prev) &&
      self.match_(L_PAREN, advance=false) {
      param.set("expressions", self.parse_wrapped_options())
    } else if prev == "FILE_FORMAT" {
      param.set("expression", self.parse_field())
    } else if prev == "FORMAT" &&
      self.prev.token_type == ALIAS &&
      self.match_texts(["AVRO", "JSON"]) {
      param.set("this", var_("FORMAT AS \{self.prev_upper()}"))
      param.set("expression", self.parse_field())
    } else {
      param.set(
        "expression",
        expr_or(self.parse_unquoted_field(), () => self.parse_bracket(None)),
      )
    }
    options.push(param)
    match sep {
      Some(s) => self.match_(s) |> ignore
      None => ()
    }
  }
  options
}

///|
pub fn Parser::parse_credentials(self : Parser) -> Expr? raise SqlglotError {
  let expr = self.expression(mk0(Credentials))
  if self.match_text_seq(["STORAGE_INTEGRATION", "="]) {
    expr.set("storage", self.parse_field())
  }
  if self.match_text("CREDENTIALS") {
    if self.match_(EQ) {
      expr.set("credentials", self.parse_wrapped_options())
    } else {
      expr.set("credentials", self.parse_field())
    }
  }
  if self.match_text("ENCRYPTION") {
    expr.set("encryption", self.parse_wrapped_options())
  }
  if self.match_text("IAM_ROLE") {
    let role = if self.match_(DEFAULT) {
      Some(var_(self.prev.text))
    } else {
      self.parse_field()
    }
    expr.set("iam_role", role)
  }
  if self.match_text("REGION") {
    expr.set("region", self.parse_field())
  }
  Some(expr)
}

///|
pub fn Parser::parse_file_location(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_file_location {
    Some(f) => f(self)
    None => self.parse_field()
  }
}

///|
pub fn Parser::parse_copy(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  self.match_(INTO) |> ignore
  let this = if self.match_(L_PAREN, advance=false) {
    self.parse_select(nested=true, parse_subquery_alias=false)
  } else {
    self.parse_table(schema=true)
  }
  let kind = self.match_(FROM) || !self.match_text("TO")
  let mut files = self.parse_csv(() => self.parse_file_location())
  if self.match_(EQ, advance=false) {
    self.advance(times=-1)
    files = []
  }
  let credentials = self.parse_credentials()
  self.match_text("WITH") |> ignore
  let params = self.parse_wrapped(
    () => self.parse_copy_parameters(),
    optional=true,
  )
  if self.curr.ok() {
    return Some(self.parse_as_command(start))
  }
  Some(
    self.expression(
      mk(Copy, [
        ("this", this),
        ("kind", kind),
        ("credentials", credentials),
        ("files", files),
        ("params", params),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_normalize(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_bitwise()
  let form = self.andv(self.match_(COMMA), () => self.parse_var())
  Some(self.expression(mk(Normalize, [("this", this), ("form", form)])))
}

///|
pub fn Parser::parse_ceil_floor(
  self : Parser,
  kind : Kind,
) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_lambda())
  let this = args.get(0)
  let decimals = args.get(1)
  let to = if self.match_text("TO") { self.parse_var() } else { None }
  Some(mk(kind, [("this", this), ("decimals", decimals), ("to", to)]))
}

///|
pub fn Parser::parse_star_ops(self : Parser) -> Expr? raise SqlglotError {
  let star_token = self.prev
  if self.match_text_seq(["COLUMNS", "("], advance=false) {
    let this = self.parse_function()
    match this {
      Some(t) if t.kind == Columns => t.set("unpack", true)
      _ => ()
    }
    return this
  }
  let index = self.index
  let ilike = if self.match_(ILIKE) { self.parse_string() } else { None }
  if ilike is None {
    self.retreat(index)
  }
  let except_ = self.parse_star_op(["EXCEPT", "EXCLUDE"])
  let replace = self.parse_star_op(["REPLACE"])
  let rename = self.parse_star_op(["RENAME"])
  Some(
    self
    .expression(
      mk(Star, [
        ("ilike", ilike),
        ("except_", except_),
        ("replace", replace),
        ("rename", rename),
      ]),
    )
    .update_positions_from_token(star_token),
  )
}

///|
pub fn Parser::parse_grant_privilege(self : Parser) -> Expr? raise SqlglotError {
  let privilege_parts = []
  while self.curr.ok() &&
        !self.match_set(self.cfg.privilege_follow_tokens, advance=false) {
    privilege_parts.push(py_upper(self.curr.text))
    self.advance()
  }
  if privilege_parts.is_empty() {
    self.raise_error("Expected privilege")
    return None
  }
  let this = var_(privilege_parts.join(" "))
  let expressions = if self.match_(L_PAREN, advance=false) {
    Some(self.parse_wrapped_csv(() => self.parse_column()))
  } else {
    None
  }
  Some(
    self.expression(
      mk(GrantPrivilege, [("this", this), ("expressions", expressions)]),
    ),
  )
}

///|
pub fn Parser::parse_grant_principal(self : Parser) -> Expr? raise SqlglotError {
  let kind : Value = if self.match_texts(["ROLE", "GROUP"]) {
    Str(self.prev_upper())
  } else {
    Bool(false)
  }
  let principal = match self.parse_id_var() {
    Some(p) => p
    None => return None
  }
  Some(
    self.expression(mk(GrantPrincipal, [("this", principal), ("kind", kind)])),
  )
}

///|
pub fn Parser::parse_grant_revoke_common(
  self : Parser,
) -> (Array[Expr], String?, Expr?) raise SqlglotError {
  let privileges = self.parse_csv(() => self.parse_grant_privilege())
  self.match_(ON) |> ignore
  let kind = if self.match_set(self.cfg.creatables) {
    Some(self.prev_upper())
  } else {
    None
  }
  let securable = self.try_parse(() => self.parse_table_parts())
  (privileges, kind, securable)
}

///|
pub fn Parser::parse_grant(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  let (privileges, kind, securable) = self.parse_grant_revoke_common()
  if securable is None || !self.match_text("TO") {
    return Some(self.parse_as_command(start))
  }
  let principals = self.parse_csv(() => self.parse_grant_principal())
  let grant_option = self.match_text_seq(["WITH", "GRANT", "OPTION"])
  if self.curr.ok() {
    return Some(self.parse_as_command(start))
  }
  Some(
    self.expression(
      mk(Grant, [
        ("privileges", privileges),
        ("kind", kind),
        ("securable", securable),
        ("principals", principals),
        ("grant_option", grant_option),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_revoke(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  let grant_option = self.match_text_seq(["GRANT", "OPTION", "FOR"])
  let (privileges, kind, securable) = self.parse_grant_revoke_common()
  if securable is None || !self.match_text("FROM") {
    return Some(self.parse_as_command(start))
  }
  let principals = self.parse_csv(() => self.parse_grant_principal())
  let cascade = if self.match_texts(["CASCADE", "RESTRICT"]) {
    Some(self.prev_upper())
  } else {
    None
  }
  if self.curr.ok() {
    return Some(self.parse_as_command(start))
  }
  Some(
    self.expression(
      mk(Revoke, [
        ("privileges", privileges),
        ("kind", kind),
        ("securable", securable),
        ("principals", principals),
        ("grant_option", grant_option),
        ("cascade", cascade),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_overlay(self : Parser) -> Expr? raise SqlglotError {
  fn parse_overlay_arg(text : String) -> Expr? raise SqlglotError {
    if self.match_(COMMA) || self.match_text(text) {
      self.parse_bitwise()
    } else {
      None
    }
  }

  let this = self.parse_bitwise()
  let expression = parse_overlay_arg("PLACING")
  let from_ = parse_overlay_arg("FROM")
  let for_ = parse_overlay_arg("FOR")
  Some(
    self.expression(
      mk(Overlay, [
        ("this", this),
        ("expression", expression),
        ("from_", from_),
        ("for_", for_),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_format_name(self : Parser) -> Expr raise SqlglotError {
  let value = expr_or(self.parse_string(), () => self.parse_table_parts())
  self.expression(
    mk(Property, [("this", var_("FORMAT_NAME")), ("value", value)]),
  )
}

// ---------------------------------------------------------------------------
// Pipe syntax

///|
pub fn Parser::build_pipe_cte(
  self : Parser,
  query : Expr,
  expressions : Array[Expr],
  alias_cte? : Expr,
) -> Expr {
  let new_cte : Expr = match alias_cte {
    Some(a) => a
    None => {
      self.pipe_cte_counter += 1
      mk1(TableAlias, to_identifier("__tmp\{self.pipe_cte_counter}"))
    }
  }
  let ctes = match query.arg("with_") {
    Some(w) => Some(w.pop())
    None => None
  }
  let new_select = mk(Select, [("expressions", expressions)])
  let table_name = match new_cte.this() {
    Some(i) => i.copy()
    None => to_identifier("")
  }
  new_select.set("from_", mk1(From, mk1(Table, table_name)))
  match ctes {
    Some(c) => new_select.set("with_", c)
    None => ()
  }
  let cte = mk(CTE, [("this", query), ("alias", new_cte)])
  match new_select.arg("with_") {
    Some(w) => w.append("expressions", cte)
    None => new_select.set("with_", mk(With, [("expressions", [cte])]))
  }
  new_select
}

///|
pub fn Parser::parse_pipe_syntax_select(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  match self.parse_select(consume_pipe=false) {
    None => Some(query)
    Some(select) => {
      query.set("expressions", select.expressions().map(e => e))
      Some(self.build_pipe_cte(query, [mk0(Star)]))
    }
  }
}

///|
pub fn Parser::parse_pipe_syntax_limit(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let limit = self.parse_limit()
  let offset = self.parse_offset()
  match limit {
    Some(l) => {
      let curr_limit = match query.arg("limit") {
        Some(c) => c
        None => l
      }
      let cur = curr_limit.expression().bind(x => x.to_py_float())
      let new = l.expression().bind(x => x.to_py_float())
      match (cur, new) {
        (Some(c), Some(n)) if c >= n => {
          let lim = if l.kind == Limit {
            l
          } else {
            mk(Limit, [("expression", l)])
          }
          query.set("limit", lim)
        }
        _ => ()
      }
    }
    None => ()
  }
  match offset {
    Some(o) => {
      let curr = match query.arg("offset") {
        Some(c) => c.expression().bind(x => x.to_py_int()).unwrap_or(0L)
        None => 0L
      }
      let add = o.expression().bind(x => x.to_py_int()).unwrap_or(0L)
      query.set(
        "offset",
        mk(Offset, [("expression", literal_number((curr + add).to_string()))]),
      )
    }
    None => ()
  }
  Some(query)
}

///|
pub fn Parser::parse_pipe_syntax_aggregate_fields(
  self : Parser,
) -> Expr? raise SqlglotError {
  let this = self.parse_disjunction()
  if self.match_text_seq(["GROUP", "AND"], advance=false) {
    return this
  }
  let this = self.parse_alias(this)
  if self.match_any([ASC, DESC], advance=false) {
    return self.parse_ordered(parse_method=() => this)
  }
  this
}

///|
pub fn Parser::parse_pipe_syntax_aggregate_group_order_by(
  self : Parser,
  query : Expr,
  group_by_exists? : Bool = true,
) -> Expr raise SqlglotError {
  let expr = self.parse_csv(() => self.parse_pipe_syntax_aggregate_fields())
  let aggregates_or_groups = []
  let orders = []
  for element in expr {
    let this = if element.kind == Ordered {
      let t = element.this().unwrap()
      if t.kind.is_a(Alias) {
        element.set("this", t.arg("alias"))
      }
      orders.push(element)
      t
    } else {
      element
    }
    aggregates_or_groups.push(this)
  }
  if group_by_exists {
    let projections = aggregates_or_groups + query.expressions()
    query.set("expressions", projections)
    let groups = aggregates_or_groups.map(p => {
      match p.arg("alias") {
        Some(a) => a
        None => p
      }
    })
    let existing = match query.arg("group") {
      Some(g) => g.expressions()
      None => []
    }
    query.set(
      "group",
      mk(Group, [("expressions", existing + groups.map(g => g.copy()))]),
    )
  } else {
    query.set("expressions", aggregates_or_groups)
  }
  if !orders.is_empty() {
    query.set("order", mk(Order, [("expressions", orders)]))
  }
  query
}

///|
pub fn Parser::parse_pipe_syntax_aggregate(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  self.match_text("AGGREGATE") |> ignore
  let mut query = self.parse_pipe_syntax_aggregate_group_order_by(
    query,
    group_by_exists=false,
  )
  if self.match_(GROUP_BY) ||
    (self.match_text_seq(["GROUP", "AND"]) && self.match_(ORDER_BY)) {
    query = self.parse_pipe_syntax_aggregate_group_order_by(query)
  }
  Some(self.build_pipe_cte(query, [mk0(Star)]))
}

///|
pub fn Parser::parse_pipe_syntax_set_operator(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let first_setop = match self.parse_set_operation(Some(query)) {
    Some(s) => s
    None => return None
  }
  fn parse_and_unwrap_query() -> Expr? raise SqlglotError {
    match self.parse_paren() {
      Some(e) => Some(e.unnest())
      None => None
    }
  }

  match first_setop.this() {
    Some(t) => t.pop() |> ignore
    None => ()
  }
  let setops = [first_setop.expression().unwrap().pop().unnest()]
  setops.append(self.parse_csv(parse_and_unwrap_query))
  let mut query = self.build_pipe_cte(query, [mk0(Star)])
  let ctes = match query.arg("with_") {
    Some(w) => Some(w.pop())
    None => None
  }
  for s in setops {
    let op = mk(first_setop.kind, [("this", query), ("expression", s)])
    for k, v in first_setop.args {
      if k != "this" && k != "expression" {
        op.set(k, v)
      }
    }
    query = op
  }
  query.set("with_", ctes)
  Some(self.build_pipe_cte(query, [mk0(Star)]))
}

///|
pub fn Parser::parse_pipe_syntax_join(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let join = match self.parse_join() {
    Some(j) => j
    None => return None
  }
  if query.kind == Select {
    query.append("joins", join)
  }
  Some(query)
}

///|
pub fn Parser::parse_pipe_syntax_pivot(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let pivots = match self.parse_pivots() {
    Some(p) => p
    None => return Some(query)
  }
  match query.arg("from_") {
    Some(f) =>
      match f.this() {
        Some(t) => t.set("pivots", pivots)
        None => ()
      }
    None => ()
  }
  Some(self.build_pipe_cte(query, [mk0(Star)]))
}

///|
pub fn Parser::parse_pipe_syntax_extend(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  self.match_text("EXTEND") |> ignore
  query.set("expressions", [mk0(Star)] + self.parse_expressions())
  Some(self.build_pipe_cte(query, [mk0(Star)]))
}

///|
pub fn Parser::parse_pipe_syntax_tablesample(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let sample = self.parse_table_sample()
  match query.arg("with_") {
    Some(w) => {
      let exprs = w.expressions()
      match exprs[exprs.length() - 1].this() {
        Some(t) => t.set("sample", sample)
        None => ()
      }
    }
    None => query.set("sample", sample)
  }
  Some(query)
}

///|
pub fn Parser::parse_pipe_syntax_query(
  self : Parser,
  query : Expr,
) -> Expr? raise SqlglotError {
  let mut query = query
  if query.kind.is_a(Subquery) {
    query = select_star_from(Some(query))
  }
  if !query.has("from_") {
    query = select_star_from(Some(query.subquery(copy=false)))
  }
  while self.match_(PIPE_GT) {
    let start_index = self.index
    let start_text = py_upper(self.curr.text)
    match self.fns.pipe_syntax_transform_parsers.get(start_text) {
      None => {
        let parsed_query = match self.parse_pipe_syntax_set_operator(query) {
          Some(q) => Some(q)
          None => self.parse_pipe_syntax_join(query)
        }
        match parsed_query {
          Some(q) => query = q
          None => {
            self.retreat(start_index)
            self.raise_error(
              "Unsupported pipe syntax operator: '\{start_text}'.",
            )
            break
          }
        }
      }
      Some(parser) =>
        match parser(self, query) {
          Some(q) => query = q
          None => ()
        }
    }
  }
  Some(query)
}

// ---------------------------------------------------------------------------

///|
pub fn Parser::parse_declareitem(self : Parser) -> Expr? raise SqlglotError {
  self.match_texts(["VAR", "VARIABLE"]) |> ignore
  let vars = self.parse_csv(() => self.parse_id_var())
  if vars.is_empty() {
    return None
  }
  self.match_(ALIAS) |> ignore
  let kind = if self.match_(TABLE) {
    self.parse_schema()
  } else {
    self.parse_types()
  }
  let default = self.andv(self.match_(DEFAULT) || self.match_(EQ), () => {
    self.parse_bitwise()
  })
  Some(
    self.expression(
      mk(DeclareItem, [("this", vars), ("kind", kind), ("default", default)]),
    ),
  )
}

///|
pub fn Parser::parse_declare(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  let replace = self.match_text_seq(["OR", "REPLACE"])
  let expressions = self.try_parse(fn() raise SqlglotError {
    let r = self.parse_csv(() => self.parse_declareitem())
    if r.is_empty() {
      None
    } else {
      Some(r)
    }
  })
  match expressions {
    Some(e) if !self.curr.ok() =>
      Some(
        self.expression(mk(Declare, [("expressions", e), ("replace", replace)])),
      )
    _ => Some(self.parse_as_command(start))
  }
}

///|
pub fn Parser::parse_json_value(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_bitwise()
  self.match_(COMMA) |> ignore
  let path = self.parse_bitwise()
  let returning = self.andv(self.match_(RETURNING), () => self.parse_type())
  let on_condition = self.parse_on_condition()
  Some(
    self.expression(
      mk(JSONValue, [
        ("this", this),
        ("path", self.dialect.to_json_path(path)),
        ("returning", returning),
        ("on_condition", on_condition),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_group_concat(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_group_concat {
    Some(f) => f(self)
    None => self.parse_group_concat_base()
  }
}

///|
pub fn Parser::parse_group_concat_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_lambda())
  fn concat_exprs(
    node : Expr?,
    exprs : Array[Expr],
  ) -> Expr raise SqlglotError {
    match node {
      Some(n) if n.kind == Distinct && n.expressions().length() > 1 => {
        let c = self.expression(
          mk(Concat, [
            ("expressions", n.expressions()),
            ("safe", true),
            ("coalesce", self.dialect.cfg.concat_coalesce),
          ]),
        )
        n.set("expressions", [c])
        return n
      }
      _ => ()
    }
    if exprs.length() == 1 {
      return exprs[0]
    }
    self.expression(
      mk(Concat, [
        ("expressions", args),
        ("safe", true),
        ("coalesce", self.dialect.cfg.concat_coalesce),
      ]),
    )
  }

  let this = if !args.is_empty() {
    let last = args[args.length() - 1]
    let order = if last.kind.is_a(Order) { Some(last) } else { None }
    match order {
      Some(o) => {
        args[args.length() - 1] = o.this().unwrap()
        o.set("this", concat_exprs(o.this(), args))
        Some(o)
      }
      None => Some(concat_exprs(Some(args[0]), args))
    }
  } else {
    None
  }
  let separator = if self.match_(SEPARATOR) { self.parse_field() } else { None }
  Some(
    self.expression(mk(GroupConcat, [("this", this), ("separator", separator)])),
  )
}

///|
pub fn Parser::parse_initcap(self : Parser) -> Expr? raise SqlglotError {
  let expr = from_arg_list(Initcap, self.parse_function_args())
  if !expr.args.contains("expression") {
    expr.set(
      "expression",
      literal_string(self.dialect.cfg.initcap_default_delimiter_chars),
    )
  }
  Some(expr)
}

///|
pub fn Parser::parse_operator(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if !self.match_(L_PAREN) {
    self.retreat(self.index - 1)
    return None
  }
  let op = StringBuilder()
  while self.curr.ok() && !self.match_(R_PAREN) {
    op.write_string(self.curr.text)
    self.advance()
  }
  let comments = self.prev_comments
  Some(
    self.expression(
      mk(Operator, [
        ("this", this),
        ("operator", op.to_string()),
        ("expression", self.parse_bitwise()),
      ]),
      comments~,
    ),
  )
}
