// Port of sqlglot/parsers/spark.py

///|
/// Although Spark docs don't mention the "unit" argument, Spark3 added support for
/// it at some point. Databricks also supports this variant.
fn build_datediff(args : Array[@core.Expr]) -> @core.Expr {
  let mut unit : @core.Expr? = None
  let mut this = args.get(0)
  let expression = args.get(1)
  if args.length() == 3 {
    unit = Some(@core.var_(this.unwrap().name()))
    this = Some(args[2])
  }
  @core.mk(DateDiff, [
    ("this", @core.mk1(TsOrDsToDate, this)),
    ("expression", @core.mk1(TsOrDsToDate, expression)),
    ("unit", unit),
  ])
}

///|
fn build_dateadd(args : Array[@core.Expr]) -> @core.Expr {
  let expression = args.get(1)
  if args.length() == 2 {
    // DATE_ADD(startDate, numDays INTEGER)
    return @core.mk(TsOrDsAdd, [
      ("this", args.get(0)),
      ("expression", expression),
      ("unit", Some(@core.literal_string("DAY"))),
    ])
  }
  // DATE_ADD / DATEADD / TIMESTAMPADD(unit, value integer, expr)
  @core.mk(TimestampAdd, [
    ("this", args.get(2)),
    ("expression", expression),
    ("unit", args.get(0)),
  ])
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  @hive.register_parser_settings("spark", {
    normalize_decimal_literals: false,
    decimal_literals_allow_negative_scale: false,
    change_column_alter_syntax: true,
  })
  let fns = d.parser_fns
  fns.set_parsers["VAR"] = p => p.parse_set_item_assignment(kind="VARIABLE")
  fns.set_parsers["VARIABLE"] = p => {
    p.parse_set_item_assignment(kind="VARIABLE")
  }
  let f = fns.functions
  f["ANY_VALUE"] = @hive.build_with_ignore_nulls(AnyValue)
  f["ARRAY_INSERT"] = (args, _) => {
    @core.mk(ArrayInsert, [
      ("this", args.get(0)),
      ("position", args.get(1)),
      ("expression", args.get(2)),
      ("offset", Some(1)),
    ])
  }
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_GET"] = @core.from_arg_list_builder(Getbit)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["BIT_XOR"] = @core.from_arg_list_builder(BitwiseXorAgg)
  f["BIT_COUNT"] = @core.from_arg_list_builder(BitwiseCount)
  f["CURDATE"] = @core.from_arg_list_builder(CurrentDate)
  f["DATE_ADD"] = (args, _) => build_dateadd(args)
  f["DATEADD"] = (args, _) => build_dateadd(args)
  f["MAKE_TIMESTAMP"] = @core.from_arg_list_builder(TimestampFromParts)
  f["TIMESTAMPADD"] = (args, _) => build_dateadd(args)
  f["TIMESTAMPDIFF"] = @core.build_date_delta(TimestampDiff)
  f["TRY_ADD"] = @core.from_arg_list_builder(SafeAdd)
  f["TRY_DIVIDE"] = @core.from_arg_list_builder(SafeDivide)
  f["TRY_MULTIPLY"] = @core.from_arg_list_builder(SafeMultiply)
  f["TRY_SUBTRACT"] = @core.from_arg_list_builder(SafeSubtract)
  f["DATEDIFF"] = (args, _) => build_datediff(args)
  f["DATE_DIFF"] = (args, _) => build_datediff(args)
  f["JSON_OBJECT_KEYS"] = @core.from_arg_list_builder(JSONKeys)
  f["LISTAGG"] = @core.from_arg_list_builder(GroupConcat)
  f["TIMESTAMP_LTZ"] = @spark2.build_as_cast("TIMESTAMP_LTZ")
  f["TIMESTAMP_NTZ"] = @spark2.build_as_cast("TIMESTAMP_NTZ")
  f["TRY_ELEMENT_AT"] = (args, _) => {
    @core.mk(Bracket, [
      ("this", args.get(0)),
      ("expressions", @core.opt_list(args.get(1))),
      ("offset", Some(1)),
      ("safe", Some(true)),
    ])
  }
  f["LIKE"] = @core.build_like_fn(Like)
  f["ILIKE"] = @core.build_like_fn(ILike)
  fns.placeholder_parsers[L_BRACE] = parse_query_parameter
  fns.function_parsers["SUBSTR"] = p => p.parse_substring()
  let parent_generated = fns.hooks.parse_generated_as_identity
  fns.hooks.parse_generated_as_identity = Some(p => {
    let this = match parent_generated {
      Some(f) => f(p)
      None => p.parse_generated_as_identity_base()
    }
    match this {
      Some(t) if t.expression() is Some(e) =>
        Some(p.expression(@core.mk1(ComputedColumnConstraint, e)))
      _ => this
    }
  })
  fns.hooks.parse_pivot_aggregation = Some(p => {
    // Spark 3+ and Databricks support non aggregate functions in PIVOT too
    let aggregate_expr = @core.expr_or(p.parse_function(), () => {
      p.parse_disjunction()
    })
    p.parse_alias(aggregate_expr)
  })
}

///|
fn parse_query_parameter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_id_var()
  p.match_(R_BRACE) |> ignore
  Some(
    p.expression(
      @core.mk(Placeholder, [("this", this), ("widget", Some(true))]),
    ),
  )
}
