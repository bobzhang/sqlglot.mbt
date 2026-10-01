// Port of sqlglot/parsers/spark2.py

///|
/// Python `build_as_cast(to_type)`.
pub fn build_as_cast(to_type : String) -> @core.FuncBuilder {
  (args, _) => {
    @core.mk(Cast, [
      ("this", args.get(0)),
      ("to", Some(@core.datatype_from_str(to_type))),
    ])
  }
}

///|
fn build_int_div(args : Array[@core.Expr]) -> @core.Expr {
  let this = args.get(0)
  let expression = args.get(1)
  match (this, expression) {
    (Some(t), Some(e)) => {
      let t = if t.kind.is_a(Binary) { @core.mk1(Paren, t) } else { t }
      let e = if e.kind.is_a(Binary) { @core.mk1(Paren, e) } else { e }
      @core.mk1(Paren, @core.mk2(IntDiv, t, e))
    }
    _ => @core.mk(IntDiv, [("this", this), ("expression", expression)])
  }
}

///|
fn tz_cast_arg(args : Array[@core.Expr], p : @core.Parser) -> @core.Expr {
  let this = match args.get(0) {
    Some(a) => a
    None => @core.var_("")
  }
  @core.exp_cast(this, TIMESTAMP, dialect=p.dialect)
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  @hive.register_parser_settings("spark2", {
    normalize_decimal_literals: false,
    decimal_literals_allow_negative_scale: true,
    change_column_alter_syntax: true,
  })
  let fns = d.parser_fns
  let f = fns.functions
  f["AGGREGATE"] = @core.from_arg_list_builder(Reduce)
  f["BOOLEAN"] = build_as_cast("boolean")
  f["DATE"] = build_as_cast("date")
  f["DATE_TRUNC"] = (args, _) => {
    @core.mk(TimestampTrunc, [
      ("this", args.get(1)),
      ("unit", args.get(0).map(a => @core.var_(a.name()))),
    ])
  }
  f["DAYOFMONTH"] = (args, _) => {
    @core.mk1(DayOfMonth, @core.mk1(TsOrDsToDate, args.get(0)))
  }
  f["DAYOFWEEK"] = (args, _) => {
    @core.mk1(DayOfWeek, @core.mk1(TsOrDsToDate, args.get(0)))
  }
  f["DAYOFYEAR"] = (args, _) => {
    @core.mk1(DayOfYear, @core.mk1(TsOrDsToDate, args.get(0)))
  }
  f["DIV"] = (args, _) => build_int_div(args)
  f["DOUBLE"] = build_as_cast("double")
  f["ELEMENT_AT"] = (args, _) => {
    @core.mk(Bracket, [
      ("this", args.get(0)),
      ("expressions", @core.opt_list(args.get(1))),
      ("offset", Some(1)),
      ("safe", Some(false)),
    ])
  }
  f["FLOAT"] = build_as_cast("float")
  f["FORMAT_STRING"] = @core.from_arg_list_builder(Format)
  f["FROM_UTC_TIMESTAMP"] = (args, p) => {
    @core.mk(AtTimeZone, [("this", tz_cast_arg(args, p)), ("zone", args.get(1))])
  }
  f["LTRIM"] = (args, _) => @core.build_trim(args, reverse_args=true)
  f["INT"] = build_as_cast("int")
  f["MAP_FROM_ARRAYS"] = @core.from_arg_list_builder(Map)
  f["RLIKE"] = @core.from_arg_list_builder(RegexpLike)
  f["RTRIM"] = (args, _) => {
    @core.build_trim(args, is_left=false, reverse_args=true)
  }
  f["SHIFTLEFT"] = @core.binary_from_function(BitwiseLeftShift)
  f["SHIFTRIGHT"] = @core.binary_from_function(BitwiseRightShift)
  f["STRING"] = build_as_cast("string")
  f["SLICE"] = @core.from_arg_list_builder(ArraySlice)
  f["TIMESTAMP"] = build_as_cast("timestamp")
  f["TO_TIMESTAMP"] = (args, p) => {
    if args.length() == 1 {
      build_as_cast("timestamp")(args, p)
    } else {
      @core.build_formatted_time(StrToTime)(args, p)
    }
  }
  f["TO_UNIX_TIMESTAMP"] = @core.from_arg_list_builder(StrToUnix)
  f["TO_UTC_TIMESTAMP"] = (args, p) => {
    @core.mk(FromTimeZone, [
      ("this", tz_cast_arg(args, p)),
      ("zone", args.get(1)),
    ])
  }
  f["TRUNC"] = (args, _) => {
    @core.mk(DateTrunc, [("unit", args.get(1)), ("this", args.get(0))])
  }
  f["WEEKOFYEAR"] = (args, _) => {
    @core.mk1(WeekOfYear, @core.mk1(TsOrDsToDate, args.get(0)))
  }
  let fp = fns.function_parsers
  fp["AND"] = p => p.parse_connector_function(And)
  fp["APPROX_PERCENTILE"] = p => p.parse_distinct_arg_function(ApproxQuantile)
  for
    hint in [
      "BROADCAST", "BROADCASTJOIN", "MAPJOIN", "MERGE", "SHUFFLEMERGE", "MERGEJOIN",
      "SHUFFLE_HASH", "SHUFFLE_REPLICATE_NL",
    ] {
    fp[hint] = p => p.parse_join_hint(hint)
  }
  fp["OR"] = p => p.parse_connector_function(Or)
  fns.hooks.parse_drop_column = Some(p => {
    if p.match_text_seq(["DROP", "COLUMNS"]) {
      Some(
        p.expression(
          @core.mk(Drop, [
            ("tables", [p.parse_schema()].filter_map(x => x)),
            ("kind", "COLUMNS"),
          ]),
        ),
      )
    } else {
      None
    }
  })
  fns.hooks.pivot_column_names = Some((_, aggregations) => {
    if aggregations.length() == 1 {
      return []
    }
    @core.pivot_column_names(aggregations, @core.Dialect::get_or_raise("spark"))
  })
}
