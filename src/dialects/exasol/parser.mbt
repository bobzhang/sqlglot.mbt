// Port of sqlglot/parsers/exasol.py

///|
pub let date_units : Array[String] = [
  "DAY", "WEEK", "MONTH", "YEAR", "HOUR", "MINUTE", "SECOND",
]

///|
/// https://docs.exasol.com/db/latest/sql_references/functions/alphabeticallistfunctions/zeroifnull.htm
fn build_zeroifnull(args : Array[@core.Expr]) -> @core.Expr {
  let cond = @core.mk(Is, [
    ("this", args.get(0)),
    ("expression", Some(@core.null_())),
  ])
  @core.mk(If, [
    ("this", Some(cond)),
    ("true", Some(@core.literal_int(0))),
    ("false", args.get(0)),
  ])
}

///|
/// https://docs.exasol.com/db/latest/sql_references/functions/alphabeticallistfunctions/nullifzero.htm
fn build_nullifzero(args : Array[@core.Expr]) -> @core.Expr {
  let cond = @core.mk(EQ, [
    ("this", args.get(0)),
    ("expression", Some(@core.literal_int(0))),
  ])
  @core.mk(If, [
    ("this", Some(cond)),
    ("true", Some(@core.null_())),
    ("false", args.get(0)),
  ])
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  for unit in date_units {
    f["ADD_\{unit}S"] = @core.build_date_delta(DateAdd, default_unit=unit)
    f["\{unit}S_BETWEEN"] = @core.build_date_delta(DateDiff, default_unit=unit)
  }
  f["APPROXIMATE_COUNT_DISTINCT"] = @core.from_arg_list_builder(ApproxDistinct)
  f["BIT_AND"] = @core.binary_from_function(BitwiseAnd)
  f["BIT_OR"] = @core.binary_from_function(BitwiseOr)
  f["BIT_XOR"] = @core.binary_from_function(BitwiseXor)
  f["BIT_NOT"] = (args, _) => @core.mk1(BitwiseNot, args.get(0))
  f["BIT_LSHIFT"] = @core.binary_from_function(BitwiseLeftShift)
  f["BIT_RSHIFT"] = @core.binary_from_function(BitwiseRightShift)
  f["CONVERT_TZ"] = (args, _) => {
    @core.mk(ConvertTimezone, [
      ("source_tz", args.get(1)),
      ("target_tz", args.get(2)),
      ("timestamp", args.get(0)),
      ("options", args.get(3)),
    ])
  }
  f["CURDATE"] = @core.from_arg_list_builder(CurrentDate)
  f["DATE_TRUNC"] = (args, _) => {
    @core.mk(TimestampTrunc, [("this", args.get(1)), ("unit", args.get(0))])
  }
  f["DIV"] = @core.binary_from_function(IntDiv)
  f["EVERY"] = (args, _) => @core.mk1(All, args.get(0))
  f["EDIT_DISTANCE"] = @core.from_arg_list_builder(Levenshtein)
  f["FROM_POSIX_TIME"] = @core.from_arg_list_builder(UnixToTime)
  f["HASH_SHA"] = @core.from_arg_list_builder(SHA)
  f["HASH_SHA1"] = @core.from_arg_list_builder(SHA)
  f["HASH_MD5"] = @core.from_arg_list_builder(MD5)
  f["HASHTYPE_MD5"] = @core.from_arg_list_builder(MD5Digest)
  f["HASH_SHA256"] = (args, _) => {
    @core.mk(SHA2, [
      ("this", args.get(0)),
      ("length", Some(@core.literal_int(256))),
    ])
  }
  f["HASH_SHA512"] = (args, _) => {
    @core.mk(SHA2, [
      ("this", args.get(0)),
      ("length", Some(@core.literal_int(512))),
    ])
  }
  f["NOW"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["NULLIFZERO"] = (args, _) => build_nullifzero(args)
  f["REGEXP_LIKE"] = (args, _) => {
    @core.mk(RegexpLike, [
      ("this", args.get(0)),
      ("expression", args.get(1)),
      ("flag", args.get(2)),
      ("full_match", Some(true)),
    ])
  }
  f["REGEXP_SUBSTR"] = @core.from_arg_list_builder(RegexpExtract)
  f["REGEXP_REPLACE"] = (args, _) => {
    @core.mk(RegexpReplace, [
      ("this", args.get(0)),
      ("expression", args.get(1)),
      ("replacement", args.get(2)),
      ("position", args.get(3)),
      ("occurrence", args.get(4)),
    ])
  }
  f["TRUNC"] = (args, p) => @core.build_trunc(args, p.dialect)
  f["TRUNCATE"] = (args, p) => @core.build_trunc(args, p.dialect)
  f["TO_CHAR"] = (args, p) => @core.build_timetostr_or_tochar(args, p.dialect)
  f["TO_DATE"] = @core.build_formatted_time(TsOrDsToDate)
  f["USER"] = @core.from_arg_list_builder(CurrentUser)
  f["VAR_POP"] = @core.from_arg_list_builder(VariancePop)
  f["ZEROIFNULL"] = (args, _) => build_zeroifnull(args)
  fns.constraint_parsers["COMMENT"] = p => {
    let this = if p.match_(IS) { p.parse_string() } else { None }
    Some(p.expression(@core.mk1(CommentColumnConstraint, this)))
  }
  fns.range_parsers[RLIKE] = (p, this) => {
    Some(
      p.expression(
        @core.mk(RegexpLike, [
          ("this", this),
          ("expression", p.parse_bitwise()),
          ("full_match", Some(true)),
        ]),
      ),
    )
  }
  let fp = fns.function_parsers
  fp["GROUP_CONCAT"] = p => p.parse_group_concat()
  fp["LISTAGG"] = p => p.parse_string_agg()
  fp["JSON_VALUE"] = p => p.parse_json_value()
  fp["JSON_EXTRACT"] = parse_json_extract
  let parent_statement = fns.hooks.parse_statement
  fns.hooks.parse_statement = Some(p => {
    // https://docs.exasol.com/db/latest/sql/open_schema.htm
    if p.match_text_seq(["OPEN", "SCHEMA"]) {
      return Some(p.expression(@core.mk1(Use, p.parse_table(schema=false))))
    }
    match parent_statement {
      Some(f) => f(p)
      None => p.parse_statement_base()
    }
  })
  let parent_column = fns.hooks.parse_column
  fns.hooks.parse_column = Some(p => {
    let column = match parent_column {
      Some(f) => f(p)
      None => p.parse_column_base()
    }
    match column {
      Some(c) if c.kind.is_a(Column) =>
        match c.arg("table") {
          Some(t) if t.kind == Identifier &&
            @core.py_upper(t.name()) == "LOCAL" &&
            !t.has("quoted") => c.set("table", (None : @core.Expr?))
          _ => ()
        }
      _ => ()
    }
    column
  })
}

///|
fn parse_json_extract(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let args = p.parse_expressions()
  p.match_r_paren()
  let expression = @core.mk(JSONExtract, [("expressions", args)])
  if p.match_text_seq(["EMITS"]) {
    expression.set("emits", p.parse_schema())
  }
  Some(expression)
}
