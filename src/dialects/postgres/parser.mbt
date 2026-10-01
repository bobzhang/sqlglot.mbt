// Port of sqlglot/parsers/postgres.py

///|
/// Python `exp.to_interval(str)`: builds an interval expression from a string like
/// '1 day' or '5 months'.
pub fn to_interval(interval : String) -> @core.Expr raise @core.SqlglotError {
  @core.parse_one("INTERVAL " + interval)
}

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i >= 0 && i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn build_generate_series(
  args : Array[@core.Expr],
  _p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // The goal is to convert step values like '1 day' or INTERVAL '1 day' into INTERVAL '1' day
  // Note: postgres allows calls with just two arguments -- the "step" argument defaults to 1
  let args = args.copy()
  match seq_get(args, 2) {
    Some(step) =>
      if step.is_string() {
        args[2] = to_interval(step.text("this"))
      } else if step.kind.is_a(Interval) && !step.has("unit") {
        args[2] = to_interval(step.this().unwrap().text("this"))
      }
    None => ()
  }
  @core.from_arg_list(ExplodingGenerateSeries, args)
}

///|
fn build_to_timestamp(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // TO_TIMESTAMP accepts either a single double argument or (text, text)
  if args.length() == 1 {
    // https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-TABLE
    return @core.from_arg_list(UnixToTime, args)
  }
  // https://www.postgresql.org/docs/current/functions-formatting.html
  @core.build_formatted_time(StrToTime)(args, p)
}

///|
pub fn build_regexp_replace(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // The signature of REGEXP_REPLACE is:
  // regexp_replace(source, pattern, replacement [, start [, N ]] [, flags ])
  //
  // Any one of `start`, `N` and `flags` can be column references, meaning that
  // unless we can statically see that the last argument is a non-integer string
  // (eg. not '0'), then it's not possible to construct the correct AST
  let mut regexp_replace : @core.Expr? = None
  if args.length() > 3 {
    let mut last = args[args.length() - 1]
    if !@core.is_int_str(last.name()) {
      let no_type = match last.get_type() {
        None => true
        Some(_) => last.is_type([UNKNOWN, NULL])
      }
      if no_type {
        last = @core.gen_annotate_types(last, p.dialect)
      }
      if last.is_type(@core.dtype_text_types) {
        let rr = @core.from_arg_list(
          RegexpReplace,
          args[:args.length() - 1].to_owned(),
        )
        rr.set("modifiers", last)
        regexp_replace = Some(rr)
      }
    }
  }
  let regexp_replace = match regexp_replace {
    Some(r) => r
    None => @core.from_arg_list(RegexpReplace, args)
  }
  regexp_replace.set("single_replace", true)
  regexp_replace
}

///|
fn build_levenshtein_less_equal(args : Array[@core.Expr]) -> @core.Expr {
  // Postgres has two signatures for levenshtein_less_equal function, but in both cases
  // max_dist is the last argument
  let args = args.copy()
  let max_dist = args.pop()
  @core.mk(Levenshtein, [
    ("this", seq_get(args, 0)),
    ("expression", seq_get(args, 1)),
    ("ins_cost", seq_get(args, 2)),
    ("del_cost", seq_get(args, 3)),
    ("sub_cost", seq_get(args, 4)),
    ("max_dist", max_dist),
  ])
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  // PROPERTY_PARSERS
  fns.property_parsers.remove("INPUT")
  fns.property_parsers["SET"] = (p, _) => {
    Some(Node(p.expression(@core.mk1(SetConfigProperty, p.parse_set()))))
  }
  // PLACEHOLDER_PARSERS
  fns.placeholder_parsers[PLACEHOLDER] = p => {
    Some(p.expression(@core.mk(Placeholder, [("jdbc", true)])))
  }
  fns.placeholder_parsers[MOD] = parse_query_parameter
  // FUNCTIONS
  let f = fns.functions
  f["ARRAY_PREPEND"] = (args, _) => {
    @core.mk(ArrayPrepend, [
      ("this", seq_get(args, 1)),
      ("expression", seq_get(args, 0)),
    ])
  }
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["BIT_XOR"] = @core.from_arg_list_builder(BitwiseXorAgg)
  f["BTRIM"] = @core.from_arg_list_builder(Trim)
  f["VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  f["DATE_TRUNC"] = (args, _) => @core.build_timestamp_trunc(args)
  f["DIV"] = (args, p) => {
    @core.exp_cast(@core.binary_from_function(IntDiv)(args, p), DECIMAL)
  }
  f["GENERATE_SERIES"] = build_generate_series
  f["GET_BIT"] = (args, _) => {
    @core.mk(Getbit, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("zero_is_msb", true),
    ])
  }
  f["JSON_EXTRACT_PATH"] = @core.build_json_extract_path(JSONExtract)
  f["JSON_EXTRACT_PATH_TEXT"] = @core.build_json_extract_path(JSONExtractScalar)
  f["LENGTH"] = (args, _) => {
    @core.mk(Length, [
      ("this", seq_get(args, 0)),
      ("encoding", seq_get(args, 1)),
    ])
  }
  f["MAKE_TIME"] = @core.from_arg_list_builder(TimeFromParts)
  f["MAKE_TIMESTAMP"] = @core.from_arg_list_builder(TimestampFromParts)
  f["NOW"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["REGEXP_REPLACE"] = build_regexp_replace
  f["TO_CHAR"] = @core.build_formatted_time(TimeToStr)
  f["TO_DATE"] = @core.build_formatted_time(StrToDate)
  f["TO_TIMESTAMP"] = build_to_timestamp
  f["UNNEST"] = @core.from_arg_list_builder(Explode)
  for bits in ["256", "384", "512"] {
    f["SHA" + bits] = (args, _) => {
      @core.mk(SHA2, [
        ("this", seq_get(args, 0)),
        ("length", @core.literal_number(bits)),
      ])
    }
  }
  f["LEVENSHTEIN_LESS_EQUAL"] = (args, _) => build_levenshtein_less_equal(args)
  f["JSON_OBJECT_AGG"] = (args, _) => {
    @core.mk(JSONObjectAgg, [("expressions", args)])
  }
  f["JSONB_OBJECT_AGG"] = @core.from_arg_list_builder(JSONBObjectAgg)
  f["WIDTH_BUCKET"] = (args, _) => {
    if args.length() == 2 {
      @core.mk(WidthBucket, [
        ("this", seq_get(args, 0)),
        ("threshold", seq_get(args, 1)),
      ])
    } else {
      @core.from_arg_list(WidthBucket, args)
    }
  }
  f["UUID"] = (args, _) => {
    if args.is_empty() {
      @core.mk0(Uuid)
    } else {
      @core.exp_cast(args[0], UUID)
    }
  }
  // NO_PAREN_FUNCTION_PARSERS
  fns.no_paren_function_parsers["VARIADIC"] = p => {
    Some(p.expression(@core.mk1(Variadic, p.parse_bitwise())))
  }
  // FUNCTION_PARSERS
  fns.function_parsers["DATE_PART"] = parse_date_part
  fns.function_parsers["JSON_AGG"] = p => {
    let this = p.parse_lambda()
    let order = p.parse_order()
    Some(
      p.expression(@core.mk(JSONArrayAgg, [("this", this), ("order", order)])),
    )
  }
  fns.function_parsers["JSONB_EXISTS"] = parse_jsonb_exists
  // RANGE_PARSERS
  fns.range_parsers[DAMP] = @core.binary_range_parser(ArrayOverlaps)
  fns.range_parsers[DAT] = (p, this) => {
    let bitwise = p.parse_bitwise()
    Some(
      p.expression(
        @core.mk(MatchAgainst, [("this", bitwise), ("expressions", [this])]),
      ),
    )
  }
  // STATEMENT_PARSERS
  fns.statement_parsers[END] = p => p.parse_commit_or_rollback()
  // UNARY_PARSERS
  // The `~` token is remapped from TILDE to RLIKE in Postgres due to the binary REGEXP LIKE operator
  fns.unary_parsers[RLIKE] = p => {
    Some(p.expression(@core.mk1(BitwiseNot, p.parse_unary())))
  }
  // COLUMN_OPERATORS
  for
    tt in [@core.TokenType::ARROW, DARROW, HASH_ARROW, DHASH_ARROW, PLACEHOLDER] {
    fns.column_operators.remove(tt)
  }
  // JSON_OPERATORS
  fns.json_operators[ARROW] = (p, this, path) => {
    let e = @core.build_json_extract_path(
      JSONExtract,
      arrow_req_json_type=p.cfg.json_arrows_require_json_type,
    )([this.unwrap(), path.unwrap()], p)
    Some(p.validate_expression(e))
  }
  fns.json_operators[DARROW] = (p, this, path) => {
    let e = @core.build_json_extract_path(
      JSONExtractScalar,
      arrow_req_json_type=p.cfg.json_arrows_require_json_type,
    )([this.unwrap(), path.unwrap()], p)
    Some(p.validate_expression(e))
  }
  fns.json_operators[HASH_ARROW] = @core.build_jsonb_extract_op
  fns.json_operators[DHASH_ARROW] = @core.build_jsonb_extract_scalar_op
  fns.json_operators[PLACEHOLDER] = @core.build_jsonb_contains_top_key_op
  // Method overrides
  let hooks = fns.hooks
  hooks.parse_function_parameter = Some(parse_function_parameter)
  hooks.parse_unique_key = Some(_ => None)
  let parent_generated_as_identity = hooks.parse_generated_as_identity
  hooks.parse_generated_as_identity = Some(p => {
    parse_generated_as_identity(p, parent_generated_as_identity)
  })
  hooks.parse_user_defined_type = Some(parse_user_defined_type)
}

///|
let arg_mode_tokens : @core.TokenSet = @core.TokenSet::new([
  IN,
  OUT,
  INOUT,
  VARIADIC,
])

///|
/// Parse PostgreSQL function parameter mode (IN, OUT, INOUT, VARIADIC).
///
/// Disambiguates between mode keywords and identifiers with the same name:
/// - MODE TYPE      -> keyword is identifier (e.g., "out INT")
/// - MODE NAME TYPE -> keyword is mode (e.g., "OUT x INT")
fn parse_parameter_mode(p : @core.Parser) -> @core.TokenType? {
  if !p.match_set(arg_mode_tokens, advance=false) || !p.next.ok() {
    return None
  }
  let mode_token = p.curr
  // Check Pattern 1: MODE TYPE
  // Try parsing next token as a built-in type (not UDT)
  // If successful, the keyword is an identifier, not a mode
  let is_followed_by_builtin_type = p.try_parse(
    () => {
      p.advance()
      p.parse_types(check_func=false, allow_identifiers=false)
    },
    retreat=true,
  )
  if is_followed_by_builtin_type is Some(_) {
    return None // Pattern: "out INT" -> out is parameter name
  }
  // Check Pattern 2: MODE NAME TYPE
  // If next token is an identifier, check if there's a type after it
  // The type can be built-in or user-defined (allow_identifiers=True)
  if !p.cfg.id_var_tokens.contains(p.next.token_type) {
    return None
  }
  let is_followed_by_any_type = p.try_parse(
    () => {
      p.advance(times=2)
      p.parse_types(check_func=false, allow_identifiers=true)
    },
    retreat=true,
  )
  if is_followed_by_any_type is Some(_) {
    return Some(mode_token.token_type) // Pattern: "OUT x INT" -> OUT is mode
  }
  None
}

///|
fn create_mode_constraint(
  p : @core.Parser,
  param_mode : @core.TokenType,
) -> @core.Expr raise @core.SqlglotError {
  p.expression(
    @core.mk(InOutColumnConstraint, [
      ("input_", param_mode == IN || param_mode == INOUT),
      ("output", param_mode == OUT || param_mode == INOUT),
      ("variadic", param_mode == VARIADIC),
    ]),
  )
}

///|
fn parse_function_parameter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let param_mode = parse_parameter_mode(p)
  if param_mode is Some(_) {
    p.advance()
  }
  // Parse parameter name and type
  let param_name = p.parse_id_var()
  let column_def = p.parse_column_def(param_name, computed_column=false)
  // Attach mode as constraint
  match (param_mode, column_def) {
    (Some(mode), Some(cd)) => {
      let constraint = create_mode_constraint(p, mode)
      cd.set("constraints", [constraint, ..cd.list("constraints")])
    }
    _ => ()
  }
  column_def
}

///|
fn parse_query_parameter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = if p.match_(L_PAREN, advance=false) {
    p.parse_wrapped(() => p.parse_id_var())
  } else {
    None
  }
  p.match_text_seq(["S"]) |> ignore
  Some(p.expression(@core.mk1(Placeholder, this)))
}

///|
fn parse_date_part(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut part = p.parse_type()
  p.match_(COMMA) |> ignore
  let value = p.parse_bitwise()
  match part {
    Some(pt) if pt.kind.is_a(Column) || pt.kind == Literal =>
      part = Some(@core.var_(@core.py_upper(pt.name())))
    _ => ()
  }
  Some(p.expression(@core.mk(Extract, [("this", part), ("expression", value)])))
}

///|
fn parse_jsonb_exists(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_bitwise()
  let path = if p.match_(COMMA) {
    p.dialect.to_json_path(p.parse_bitwise())
  } else {
    None
  }
  Some(p.expression(@core.mk(JSONBExists, [("this", this), ("path", path)])))
}

///|
fn parse_generated_as_identity(
  p : @core.Parser,
  parent : @core.ParseFn?,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = match parent {
    Some(f) => f(p)
    None => p.parse_generated_as_identity_base()
  }
  if p.match_text_seq(["STORED"]) {
    this = Some(
      p.expression(
        @core.mk1(ComputedColumnConstraint, this.unwrap().expression()),
      ),
    )
  }
  this
}

///|
fn parse_user_defined_type(
  p : @core.Parser,
  identifier : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  let mut udt_type = identifier
  while p.match_(DOT) {
    match p.parse_id_var() {
      Some(part) =>
        udt_type = @core.mk(Dot, [("this", udt_type), ("expression", part)])
      None => ()
    }
  }
  Some(
    @core.mk(DataType, [("this", @core.DType::USERDEFINED), ("kind", udt_type)]),
  )
}
