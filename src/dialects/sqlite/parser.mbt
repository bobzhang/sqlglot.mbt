// Port of sqlglot/parsers/sqlite.py

///|
fn build_strftime(
  args : Array[@core.Expr],
  _p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let args = args.copy()
  if args.length() == 1 {
    args.push(@core.mk0(CurrentTimestamp))
  }
  if args.length() == 2 {
    return @core.mk(TimeToStr, [
      ("this", @core.mk1(TsOrDsToTimestamp, args[1])),
      ("format", args[0]),
    ])
  }
  @core.mk(Anonymous, [("this", "STRFTIME"), ("expressions", args)])
}

///|
fn build_dpipe(
  p : @core.Parser,
  this : @core.Expr?,
  expression : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  Some(
    p.expression(
      @core.mk(DPipe, [
        ("this", this),
        ("expression", expression),
        ("safe", !p.dialect.cfg.strict_string_concat),
      ]),
    ),
  )
}

///|
fn build_json_extract(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // Single-path json_extract() returns an SQL representation like ->>, except
  // that object/array results keep the JSON subtype (json_subtype); the
  // multi-path form returns a JSON array. https://www.sqlite.org/json1.html#jex
  if args.length() == 2 {
    let extract = @core.build_extract_json_with_path(JSONExtractScalar)(args, p)
    extract.set("json_subtype", true)
    return extract
  }
  @core.build_extract_json_with_path(JSONExtract)(args, p)
}

///|
fn anonymous_builder(name : String) -> @core.FuncBuilder {
  (args, _) => @core.mk(Anonymous, [("this", name), ("expressions", args)])
}

///|
/// `CONCAT_OPERATORS`: `||`, `->` and `->>` form a single left-associative precedence
/// tier that binds tighter than multiplication.
fn concat_operator(tt : @core.TokenType) -> @core.ColumnOpFn? {
  match tt {
    DPIPE => Some(build_dpipe)
    ARROW => Some(@core.build_json_extract_op)
    DARROW => Some(@core.build_json_extract_scalar_op)
    _ => None
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let cfg = d.parser_cfg
  let fns = d.parser_fns
  fns.column_operators.remove(ARROW)
  fns.column_operators.remove(DARROW)
  // ARITHMETIC_TOKENS = BITWISE | TERM | FACTOR - {COLLATE}
  let arithmetic = @core.TokenSet::empty()
  for m in [cfg.bitwise, cfg.term, cfg.factor] {
    for tt, _ in m {
      arithmetic.add(tt)
    }
  }
  arithmetic.remove(COLLATE)
  fns.functions["DATETIME"] = anonymous_builder("DATETIME")
  fns.functions["EDITDIST3"] = @core.from_arg_list_builder(Levenshtein)
  fns.functions["JSON_EXTRACT"] = build_json_extract
  fns.functions["JSON_GROUP_ARRAY"] = @core.from_arg_list_builder(JSONArrayAgg)
  fns.functions["JSON_GROUP_OBJECT"] = (args, _) => {
    @core.mk(JSONObjectAgg, [("expressions", args)])
  }
  fns.functions["STRFTIME"] = build_strftime
  fns.functions["SQLITE_VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  fns.functions["TIME"] = anonymous_builder("TIME")
  fns.function_parsers["GROUP_CONCAT"] = p => p.parse_string_agg()
  fns.property_parsers["USING"] = (p, _) => {
    match parse_module_property(p) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  fns.property_parsers["VIRTUAL"] = (p, _) => {
    Some(Node(p.expression(@core.mk0(VirtualProperty))))
  }
  fns.statement_parsers[ATTACH] = p => parse_attach_detach(p, true)
  fns.statement_parsers[DETACH] = p => parse_attach_detach(p, false)
  fns.statement_parsers[PRAGMA] = parse_pragma
  fns.range_parsers[MATCH] = @core.binary_range_parser(Match)
  fns.hooks.parse_factor_operand = Some(p => parse_factor_operand(p, arithmetic))
  fns.hooks.parse_unique = Some(parse_unique)
  fns.hooks.parse_generated_as_identity = Some(parse_generated_as_identity)
}

///|
fn parse_factor_operand(
  p : @core.Parser,
  arithmetic : @core.TokenSet,
) -> @core.Expr? raise @core.SqlglotError {
  let in_arithmetic_operand = arithmetic.contains(p.prev.token_type)
  let mut this = parse_concat_operand(p)
  let mut parsed_op = false
  while p.curr.ok() {
    guard concat_operator(p.curr.token_type) is Some(build) else { break }
    if p.curr.token_type != DPIPE && this is Some(t) && t.kind == DPipe {
      // Parenthesize so that dialects where the arrows bind tighter
      // than || still produce the same, left-associative grouping
      this = Some(p.expression(@core.mk1(Paren, t)))
    }
    p.advance()
    this = build(p, this, parse_concat_operand(p))
    parsed_op = true
  }
  if parsed_op &&
    (
      in_arithmetic_operand ||
      (p.curr.ok() && arithmetic.contains(p.curr.token_type))
    ) {
    // This tier binds tighter than arithmetic in SQLite but looser elsewhere,
    // so parenthesize it to preserve the grouping in other dialects
    this = Some(p.expression(@core.mk1(Paren, this)))
  }
  this
}

///|
fn parse_concat_operand(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.parse_unary()
  // COLLATE binds tighter than any binary operator, including this tier
  while p.match_(COLLATE) {
    let collate = p.expression(
      @core.mk(Collate, [("this", this), ("expression", p.parse_unary())]),
    )
    p.normalize_collate(collate)
    this = Some(collate)
  }
  this
}

///|
fn parse_unique(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // Do not consume more tokens if UNIQUE is used as a standalone constraint, e.g:
  // CREATE TABLE foo (bar TEXT UNIQUE REFERENCES baz ...)
  if p.fns.constraint_parsers.contains(@core.py_upper(p.curr.text)) {
    return Some(p.expression(@core.mk0(UniqueColumnConstraint)))
  }
  p.parse_unique_base()
}

///|
fn parse_module_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let name = p.parse_id_var()
  let expressions = if p.match_(L_PAREN, advance=false) {
    Some(p.parse_wrapped_csv(() => p.parse_id_var()))
  } else {
    None
  }
  Some(
    p.expression(
      @core.mk(ModuleProperty, [("this", name), ("expressions", expressions)]),
    ),
  )
}

///|
fn parse_pragma(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut name = p.parse_var(any_token=true)
  if p.match_(DOT) {
    name = Some(
      @core.mk(Dot, [
        ("this", name),
        ("expression", p.parse_var(any_token=true)),
      ]),
    )
  }
  p.match_(EQ) |> ignore
  let value = p.parse_wrapped(
    () => {
      match p.parse_unary() {
        Some(e) => Some(e)
        None => p.parse_var(any_token=true)
      }
    },
    optional=true,
  )
  match value {
    Some(v) =>
      Some(
        p.expression(
          @core.mk1(Pragma, @core.mk(EQ, [("this", name), ("expression", v)])),
        ),
      )
    None => Some(p.expression(@core.mk1(Pragma, name)))
  }
}

///|
fn parse_attach_detach(
  p : @core.Parser,
  is_attach : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_(DATABASE) |> ignore
  let this = p.parse_expression()
  Some(p.expression(@core.mk1(if is_attach { Attach } else { Detach }, this)))
}

///|
/// https://www.sqlite.org/gencol.html
fn parse_generated_as_identity(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_generated_as_identity_base()
  // Only expression-bearing GENERATED ALWAYS AS (expr) forms are computed
  // columns. Match STORED/VIRTUAL inside this branch so true identity
  // (AS IDENTITY) does not silently consume a trailing storage keyword.
  match this {
    Some(t) if t.kind == GeneratedAsIdentityColumnConstraint &&
      t.expression() is Some(expression) => {
      let persisted = p.match_texts(["STORED", "VIRTUAL"]) &&
        @core.py_upper(p.prev.text) == "STORED"
      Some(
        p.expression(
          @core.mk(ComputedColumnConstraint, [
            ("this", expression),
            ("persisted", persisted),
          ]),
        ),
      )
    }
    _ => this
  }
}
