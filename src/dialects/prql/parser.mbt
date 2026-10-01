// Port of sqlglot/parsers/prql.py

///|
fn select_all(table : @core.Expr?) -> @core.Expr? {
  match table {
    Some(t) => Some(@core.select_([@core.mk0(Star)]).from_(t))
    None => None
  }
}

///|
fn resolve_projection(
  s : @core.Expr,
  projections : Map[String, @core.Expr],
) -> @core.Expr {
  if s.kind == Column {
    match projections.get(s.name()) {
      Some(p) => return p.copy()
      None => ()
    }
  }
  s
}

///|
fn set_op(
  kind : @core.Kind,
  query : @core.Expr,
  other : @core.Expr?,
) -> @core.Expr raise @core.SqlglotError {
  match other {
    Some(o) => @core.set_operation(kind, query, o, distinct=false)
    None => raise @core.ParseError("Invalid set operation operand", [])
  }
}

///|
fn transform_parser(
  name : String,
) -> ((@core.Parser, @core.Expr) -> @core.Expr? raise @core.SqlglotError)? {
  match name {
    "DERIVE" => Some((p, query) => Some(parse_selection(p, query)))
    "SELECT" =>
      Some((p, query) => Some(parse_selection(p, query, append=false)))
    "TAKE" => Some(parse_take)
    "FILTER" =>
      Some((p, query) => {
        match p.parse_disjunction() {
          Some(cond) => Some(query.where_([cond]))
          None => Some(query)
        }
      })
    "APPEND" =>
      Some((p, query) => Some(set_op(Union, query, select_all(p.parse_table()))))
    "REMOVE" =>
      Some((p, query) => {
        Some(set_op(Except, query, select_all(p.parse_table())))
      })
    "INTERSECT" =>
      Some((p, query) => {
        Some(set_op(Intersect, query, select_all(p.parse_table())))
      })
    "SORT" => Some(parse_order_by)
    "AGGREGATE" =>
      Some((p, query) => {
        Some(
          parse_selection(p, query, parse_method=parse_aggregate, append=false),
        )
      })
    _ => None
  }
}

///|
let transform_parser_names : Array[String] = [
  "DERIVE", "SELECT", "TAKE", "FILTER", "APPEND", "REMOVE", "INTERSECT", "SORT",
  "AGGREGATE",
]

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.functions["AVERAGE"] = @core.from_arg_list_builder(Avg)
  fns.functions["SUM"] = (args, p) => {
    let sum = @core.mk1(
      Sum,
      if args.length() > 0 {
        Some(args[0])
      } else {
        None
      },
    )
    @core.func_("COALESCE", [sum, @core.literal_number("0")], dialect=p.dialect)
  }
  let hooks = fns.hooks
  hooks.parse_equality = Some(parse_equality)
  hooks.parse_statement = Some(p => {
    match p.parse_expression() {
      Some(e) => Some(e)
      None => parse_query(p)
    }
  })
  let parent_ordered = hooks.parse_ordered
  hooks.parse_ordered = Some((p, parse_method) => {
    let asc = p.match_(PLUS)
    let desc = p.match_(DASH) || (asc && false)
    let term = match parent_ordered {
      Some(f) => f(p, parse_method)
      None => p.parse_ordered_base(parse_method?)
    }
    match term {
      Some(t) if desc => {
        t.set("desc", true)
        t.set("nulls_first", false)
      }
      _ => ()
    }
    term
  })
  hooks.parse_expression = Some(p => {
    if p.next.token_type == ALIAS {
      let alias_ = p.parse_id_var(any_token=true)
      p.match_(ALIAS) |> ignore
      let this = p.parse_assignment()
      return Some(
        p.expression(@core.mk(Alias, [("this", this), ("alias", alias_)])),
      )
    }
    p.parse_assignment()
  })
  hooks.parse_table = Some((p, _) => p.parse_table_parts())
  hooks.parse_from = Some((p, joins, skip_from_token, _consume_pipe) => {
    if !skip_from_token && !p.match_(FROM) {
      return None
    }
    let comments = p.prev_comments
    let table = p.parse_table(joins~)
    Some(p.expression(@core.mk1(From, table), comments~))
  })
}

///|
fn parse_equality(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut eq = p.parse_comparison()
  while p.match_keys(p.cfg.equality) {
    let comments = p.prev_comments
    let kind = p.cfg.equality[p.prev.token_type]
    eq = Some(
      p.expression(
        @core.mk(kind, [("this", eq), ("expression", p.parse_comparison())]),
        comments~,
      ),
    )
  }
  guard eq is Some(e) && (e.kind == EQ || e.kind == NEQ) else { return eq }
  // https://prql-lang.org/book/reference/spec/null.html
  match (e.this(), e.expression()) {
    (_, Some(r)) if r.kind == Null => {
      let is_exp = @core.mk(Is, [("this", e.this()), ("expression", r)])
      Some(if e.kind == EQ { is_exp } else { @core.mk1(Not, is_exp) })
    }
    (Some(l), _) if l.kind == Null => {
      let is_exp = @core.mk(Is, [("this", e.expression()), ("expression", l)])
      Some(if e.kind == EQ { is_exp } else { @core.mk1(Not, is_exp) })
    }
    _ => eq
  }
}

///|
fn parse_query(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let from_ = match p.parse_from() {
    Some(f) => f
    None => return None
  }
  let mut query = @core.select_([@core.mk0(Star)]).from_(from_)
  while p.match_texts(transform_parser_names) {
    let name = @core.py_upper(p.prev.text)
    guard transform_parser(name) is Some(f) else { break }
    match f(p, query) {
      Some(q) => query = q
      None => return None
    }
  }
  Some(query)
}

///|
fn parse_selection(
  p : @core.Parser,
  query : @core.Expr,
  parse_method? : (@core.Parser) -> @core.Expr? raise @core.SqlglotError,
  append? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let parse_method = match parse_method {
    Some(f) => f
    None => (p : @core.Parser) => p.parse_expression()
  }
  let selects = if p.match_(L_BRACE) {
    let selects = p.parse_csv(() => parse_method(p))
    if !p.match_(R_BRACE, expression=query) {
      p.raise_error("Expecting }")
    }
    selects
  } else {
    match parse_method(p) {
      Some(e) => [e]
      None => []
    }
  }
  let projections : Map[String, @core.Expr] = Map([])
  for select in query.selects() {
    projections[select.alias_or_name()] = if select.kind.is_a(Alias) {
      select.this().unwrap()
    } else {
      select
    }
  }
  let resolved = selects.map(select => {
    select.transform(s => Some(resolve_projection(s, projections)), copy=false)
  })
  query.select_(resolved, append~)
}

///|
fn parse_take(
  p : @core.Parser,
  query : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  match p.parse_number() { // TODO: TAKE for ranges a..b
    Some(num) => Some(query.limit_(num))
    None => None
  }
}

///|
fn parse_order_by(
  p : @core.Parser,
  query : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  let l_brace = p.match_(L_BRACE)
  let expressions = p.parse_csv(() => p.parse_ordered())
  if l_brace && !p.match_(R_BRACE) {
    p.raise_error("Expecting }")
  }
  Some(
    query.order_by([
      p.expression(@core.mk(Order, [("expressions", expressions)])),
    ]),
  )
}

///|
fn parse_aggregate(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut alias_ : @core.Expr? = None
  if p.next.token_type == ALIAS {
    alias_ = p.parse_id_var(any_token=true)
    p.match_(ALIAS) |> ignore
  }
  let name = @core.py_upper(p.curr.text)
  let func = match p.fns.functions.get(name) {
    Some(func_builder) => {
      p.advance()
      let args = p.parse_column()
      func_builder(
        match args {
          Some(a) => [a]
          None => []
        },
        p,
      )
    }
    None => {
      p.raise_error("Unsupported aggregation function \{name}")
      return None
    }
  }
  match alias_ {
    Some(a) =>
      Some(p.expression(@core.mk(Alias, [("this", func), ("alias", a)])))
    None => Some(func)
  }
}
