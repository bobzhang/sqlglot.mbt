// Port of sqlglot/parsers/trino.py

///|
let json_query_options : Map[String, Array[Array[String]]] = {
  let conts = [
    ["WRAPPER"],
    ["ARRAY", "WRAPPER"],
    ["CONDITIONAL", "WRAPPER"],
    ["CONDITIONAL", "ARRAY", "WRAPPED"],
    ["UNCONDITIONAL", "WRAPPER"],
    ["UNCONDITIONAL", "ARRAY", "WRAPPER"],
  ]
  { "WITH": conts, "WITHOUT": conts }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.functions["VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  fns.function_parsers["TRIM"] = p => p.parse_trim()
  fns.function_parsers["JSON_QUERY"] = parse_json_query
  fns.function_parsers["JSON_VALUE"] = p => p.parse_json_value()
  fns.function_parsers["LISTAGG"] = p => p.parse_string_agg()
  let parent_parse_cte = fns.hooks.parse_cte
  fns.hooks.parse_cte = Some(p => {
    // A `WITH` clause entry that starts with `FUNCTION <name>` is an inline SQL UDF
    // specification (https://trino.io/docs/current/udf/sql.html), as opposed to a
    // CTE that happens to be named "function", e.g. `WITH function AS (SELECT 1)`
    if p.match_(FUNCTION, advance=false) &&
      p.next.ok() &&
      p.cfg.id_var_tokens.contains(p.next.token_type) {
      p.advance()
      return parse_function_specification(p)
    }
    match parent_parse_cte {
      Some(f) => f(p)
      None => p.parse_cte_base()
    }
  })
}

///|
fn parse_json_query_quote(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if !(p.match_text_seq(["KEEP", "QUOTES"]) ||
    p.match_text_seq(["OMIT", "QUOTES"])) {
    return None
  }
  let option = @core.py_upper(p.tokens[p.index - 2].text)
  let scalar = p.match_text_seq(["ON", "SCALAR", "STRING"])
  Some(
    p.expression(
      @core.mk(JSONExtractQuote, [("option", option), ("scalar", scalar)]),
    ),
  )
}

///|
fn parse_json_query(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_bitwise()
  let expression = if p.match_(COMMA) { p.parse_bitwise() } else { None }
  let option = p.parse_var_from_options(
    json_query_options,
    raise_unmatched=false,
  )
  let quote = parse_json_query_quote(p)
  let on_condition = p.parse_on_condition()
  Some(
    p.expression(
      @core.mk(JSONExtract, [
        ("this", this),
        ("expression", expression),
        ("option", option),
        ("json_query", true),
        ("quote", quote),
        ("on_condition", on_condition),
      ]),
    ),
  )
}

///|
fn parse_function_specification(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_user_defined_function(kind=FUNCTION)
  // Collected separately (rather than one _parse_properties() call) so the
  // generator can place `WITH (...)` in its own bracketed clause at the end,
  // instead of it blending into the bare characteristics list.
  let characteristics : Array[@core.Expr] = []
  let properties : Array[@core.Expr] = []
  while true {
    if p.match_(WITH) {
      for x in p.parse_wrapped_csv(() => p.parse_key_value_property()) {
        properties.push(x)
      }
      continue
    }
    match p.parse_property() {
      None => break
      Some(Node(c)) => characteristics.push(c)
      Some(List(l)) =>
        for v in l {
          if v is Node(c) {
            characteristics.push(c)
          }
        }
      Some(_) => break
    }
  }
  let characteristics_e = if characteristics.is_empty() {
    None
  } else {
    Some(p.expression(@core.mk(Properties, [("expressions", characteristics)])))
  }
  let properties_e = if properties.is_empty() {
    None
  } else {
    Some(p.expression(@core.mk(Properties, [("expressions", properties)])))
  }
  let expression = parse_routine_statement(p)
  Some(
    p.expression(
      @core.mk(FunctionSpecification, [
        ("this", this),
        ("characteristics", characteristics_e),
        ("properties", properties_e),
        ("expression", expression),
      ]),
    ),
  )
}

///|
/// Unlike _parse_block(), stops on any of `terminators` even when tokens
/// follow (Trino's own END is always followed by the enclosing query, left
/// for the caller), matching them as text rather than just TokenType.END, so
/// this same chunk-continuation loop also serves IF/ELSEIF/ELSE.
fn parse_routine_statements(
  p : @core.Parser,
  terminators : Array[String],
) -> Array[@core.Expr] raise @core.SqlglotError {
  let statements : Array[@core.Expr] = []
  while !p.match_texts(terminators) {
    if !p.curr.ok() {
      if p.chunk_index >= p.chunks.length() {
        p.raise_error("Unexpected end of routine body")
        break
      }
      p.advance_chunk()
    } else if !p.match_(SEMICOLON) {
      match parse_routine_statement(p) {
        Some(statement) => statements.push(statement)
        None => break
      }
    }
  }
  statements
}

///|
fn parse_routine_block(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  p.match_(BEGIN) |> ignore
  let statements = parse_routine_statements(p, ["END"])
  statements.push(@core.mk0(EndStatement))
  p.expression(@core.mk(Block, [("expressions", statements), ("begin", true)]))
}

///|
/// https://trino.io/docs/current/udf/sql/if.html
/// ELSEIF chains nest into `false` rather than a flat list, reusing the
/// existing binary IfBlock instead of a new N-way expression.
fn parse_routine_if(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  fn parse_branch() raise @core.SqlglotError {
    let condition = p.parse_disjunction()
    p.match_text("THEN") |> ignore
    let true_ = p.expression(
      @core.mk(Block, [
        ("expressions", parse_routine_statements(p, ["ELSEIF", "ELSE", "END"])),
      ]),
    )
    p.expression(@core.mk(IfBlock, [("this", condition), ("true", true_)]))
  }

  let this = parse_branch()
  let mut tail = this
  while @core.py_upper(p.prev.text) == "ELSEIF" {
    let node = parse_branch()
    tail.set("false", node)
    tail = node
  }
  if @core.py_upper(p.prev.text) == "ELSE" {
    tail.set(
      "false",
      p.expression(
        @core.mk(Block, [("expressions", parse_routine_statements(p, ["END"]))]),
      ),
    )
  }
  p.match_text("IF") |> ignore
  this
}

///|
/// https://trino.io/docs/current/udf/sql/case.html
fn parse_routine_case(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  let this = p.parse_disjunction()
  fn parse_branch() raise @core.SqlglotError {
    let condition = p.parse_disjunction()
    p.match_text("THEN") |> ignore
    let true_ = p.expression(
      @core.mk(Block, [
        ("expressions", parse_routine_statements(p, ["WHEN", "ELSE", "END"])),
      ]),
    )
    p.expression(@core.mk(If, [("this", condition), ("true", true_)]))
  }

  let ifs = []
  p.match_text("WHEN") |> ignore
  while @core.py_upper(p.prev.text) == "WHEN" {
    ifs.push(parse_branch())
  }
  let mut default : @core.Expr? = None
  if @core.py_upper(p.prev.text) == "ELSE" {
    default = Some(
      p.expression(
        @core.mk(Block, [("expressions", parse_routine_statements(p, ["END"]))]),
      ),
    )
  }
  p.match_text("CASE") |> ignore
  p.expression(
    @core.mk(CaseStatement, [("this", this), ("ifs", ifs), ("default", default)]),
  )
}

///|
/// https://trino.io/docs/current/udf/sql/while.html
fn parse_routine_while(
  p : @core.Parser,
  label : @core.Expr?,
) -> @core.Expr raise @core.SqlglotError {
  let condition = p.parse_disjunction()
  p.match_text("DO") |> ignore
  let body = p.expression(
    @core.mk(Block, [("expressions", parse_routine_statements(p, ["END"]))]),
  )
  p.match_text("WHILE") |> ignore
  p.expression(
    @core.mk(WhileBlock, [("this", condition), ("body", body), ("label", label)]),
  )
}

///|
/// https://trino.io/docs/current/udf/sql/loop.html
fn parse_routine_loop(
  p : @core.Parser,
  label : @core.Expr?,
) -> @core.Expr raise @core.SqlglotError {
  let body = p.expression(
    @core.mk(Block, [("expressions", parse_routine_statements(p, ["END"]))]),
  )
  p.match_text("LOOP") |> ignore
  p.expression(@core.mk(LoopBlock, [("body", body), ("label", label)]))
}

///|
/// https://trino.io/docs/current/udf/sql/repeat.html - unlike WHILE/LOOP,
/// the body is evaluated at least once, with UNTIL <condition> tested after
fn parse_routine_repeat(
  p : @core.Parser,
  label : @core.Expr?,
) -> @core.Expr raise @core.SqlglotError {
  let body = p.expression(
    @core.mk(Block, [("expressions", parse_routine_statements(p, ["UNTIL"]))]),
  )
  let until = p.parse_disjunction()
  p.match_text_seq(["END", "REPEAT"]) |> ignore
  p.expression(
    @core.mk(RepeatBlock, [("body", body), ("until", until), ("label", label)]),
  )
}

///|
fn parse_routine_statement(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // An optional `label :` can precede WHILE, LOOP, or REPEAT to name the block for ITERATE/LEAVE.
  // Any non-reserved keyword (SET, IF, ITERATE etc) is a valid label name, so the colon lookahead
  // has to run first, before the statement keywords are matched.
  let mut label : @core.Expr? = None
  if p.next.ok() && p.next.token_type == COLON {
    label = p.parse_id_var()
    p.match_(COLON) |> ignore
  }
  if p.match_(BEGIN, advance=false) {
    return Some(parse_routine_block(p))
  }
  if p.match_text("RETURN") {
    return Some(p.expression(@core.mk1(Return, p.parse_disjunction())))
  }
  if p.match_text("IF") {
    return Some(parse_routine_if(p))
  }
  if p.match_text("CASE") {
    return Some(parse_routine_case(p))
  }
  if p.match_(DECLARE) {
    return p.parse_declare()
  }
  if p.match_(SET) {
    return p.parse_set()
  }
  if p.match_text("ITERATE") {
    return Some(p.expression(@core.mk1(Iterate, p.parse_id_var())))
  }
  if p.match_text("LEAVE") {
    return Some(p.expression(@core.mk1(Leave, p.parse_id_var())))
  }
  if p.match_text("WHILE") {
    return Some(parse_routine_while(p, label))
  }
  if p.match_text("LOOP") {
    return Some(parse_routine_loop(p, label))
  }
  if p.match_text("REPEAT") {
    return Some(parse_routine_repeat(p, label))
  }
  p.raise_error("Expected routine statement")
  None
}
