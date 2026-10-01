// Port of sqlglot/parsers/doris.py

///|
/// Accept both DATE_TRUNC(datetime, unit) and DATE_TRUNC(unit, datetime)
fn build_date_trunc(args : Array[@core.Expr]) -> @core.Expr {
  let a0 = @mysql.seq_get(args, 0)
  let a1 = @mysql.seq_get(args, 1)
  fn is_unit_like(e : @core.Expr?) -> Bool {
    match e {
      Some(l) if l.kind.is_a(Literal) && l.is_string() =>
        !l.text("this").iter().any(ch => ch.is_ascii_digit())
      _ => false
    }
  }
  // Determine which argument is the unit
  let (unit, this) = if is_unit_like(a0) { (a0, a1) } else { (a1, a0) }
  @core.mk(TimestampTrunc, [("this", this), ("unit", unit)])
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f["ADDDATE"] = @core.build_date_delta_with_interval(
    DateAdd,
    default_unit="DAY",
  )
  f["COLLECT_SET"] = @core.from_arg_list_builder(ArrayUniqueAgg)
  f["DATE_ADD"] = @core.build_date_delta_with_interval(
    DateAdd,
    default_unit="DAY",
  )
  f["DATE_SUB"] = @core.build_date_delta_with_interval(
    DateSub,
    default_unit="DAY",
  )
  f["DATE_TRUNC"] = (args, _) => build_date_trunc(args)
  f["L2_DISTANCE"] = @core.from_arg_list_builder(EuclideanDistance)
  f["MONTHS_ADD"] = @core.from_arg_list_builder(AddMonths)
  f["REGEXP"] = @core.from_arg_list_builder(RegexpLike)
  f["SUBDATE"] = @core.build_date_delta_with_interval(
    DateSub,
    default_unit="DAY",
  )
  f["TO_DATE"] = @core.from_arg_list_builder(TsOrDsToDate)
  fns.function_parsers.remove("GROUP_CONCAT")
  let pp = fns.property_parsers
  pp["PROPERTIES"] = (p, _) => {
    Some(List(p.parse_wrapped_properties().map(e => @core.Value::Node(e))))
  }
  pp["UNIQUE"] = (p, _) => {
    Some(Node(p.parse_composite_key_property(UniqueKeyProperty)))
  }
  // Plain KEY without UNIQUE/DUPLICATE/AGGREGATE prefixes should be treated as UniqueKeyProperty with unique=False
  pp["KEY"] = (p, _) => {
    Some(Node(p.parse_composite_key_property(UniqueKeyProperty)))
  }
  pp["BUILD"] = (p, _) => {
    Some(Node(p.expression(@core.mk1(BuildProperty, p.parse_var(upper=true)))))
  }
  pp["REFRESH"] = (p, _) => Some(Node(parse_refresh_property(p)))
  pp["PARTITION BY"] = (p, _) => parse_partition_property(p)
}

///|
fn parse_partition_property(
  p : @core.Parser,
) -> @core.Value? raise @core.SqlglotError {
  // super()._parse_partition_property(), dispatching to Doris' _parse_partition_range_value
  let expr = @mysql.parse_partition_property(p, parse_partition_range_value)
  let partition_expressions = match expr {
    None | Some(List([])) =>
      return match p.parse_partitioned_by() {
        Some(e) => Some(Node(e))
        None => None
      }
    Some(Node(e)) if e.kind.is_a(Property) => return expr
    Some(v) => v
  }
  p.match_l_paren()
  let create_expressions : Array[@core.Expr]? = if p.match_text_seq(
      ["FROM"],
      advance=false,
    ) {
    Some(p.parse_csv(() => Some(parse_partitioning_granularity_dynamic(p))))
  } else {
    None
  }
  p.match_r_paren()
  Some(
    Node(
      p.expression(
        @core.mk(PartitionByRangeProperty, [
          ("partition_expressions", partition_expressions),
          ("create_expressions", create_expressions),
        ]),
      ),
    ),
  )
}

///|
fn parse_partitioning_granularity_dynamic(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  p.match_text_seq(["FROM"]) |> ignore
  let start = p.parse_wrapped(() => p.parse_string())
  p.match_text_seq(["TO"]) |> ignore
  let end = p.parse_wrapped(() => p.parse_string())
  p.match_text_seq(["INTERVAL"]) |> ignore
  let number = p.parse_number()
  let unit = p.parse_var(any_token=true)
  let every = p.expression(
    @core.mk(Interval, [("this", number), ("unit", unit)]),
  )
  p.expression(
    @core.mk(PartitionByRangePropertyDynamic, [
      ("start", start),
      ("end", end),
      ("every", every),
    ]),
  )
}

///|
fn parse_partition_range_value(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let expr = @mysql.parse_partition_range_value(p)
  match expr {
    Some(e) if e.kind == Partition => return expr
    _ => ()
  }
  p.match_text_seq(["VALUES"]) |> ignore
  let name = expr
  // Doris-specific bracket syntax: VALUES [(...), (...))
  p.match_(L_BRACKET) |> ignore
  // self._parse_csv(lambda: self._parse_wrapped_csv(self._parse_expression))
  let values : Array[Array[@core.Expr]] = [
    p.parse_wrapped_csv(() => p.parse_expression()),
  ]
  while p.match_(COMMA) {
    values.push(p.parse_wrapped_csv(() => p.parse_expression()))
  }
  p.match_(R_BRACKET) |> ignore
  p.match_(R_PAREN) |> ignore
  let part_range = p.expression(
    @core.mk(PartitionRange, [("this", name), ("expressions", values)]),
  )
  Some(p.expression(@core.mk(Partition, [("expressions", [part_range])])))
}

///|
fn parse_refresh_property(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let method_ = p.parse_var(upper=true)
  p.match_(ON) |> ignore
  // Python `x and y` chains store False when the first operand fails
  let kind : @core.Value = if p.match_texts(["MANUAL", "COMMIT", "SCHEDULE"]) {
    Str(@core.py_upper(p.prev.text))
  } else {
    Bool(false)
  }
  let every : @core.Value? = if p.match_text_seq(["EVERY"]) {
    p.parse_number().map(e => @core.Value::Node(e))
  } else {
    Some(Bool(false))
  }
  let unit = match every {
    Some(Node(_)) => p.parse_var(any_token=true)
    _ => None
  }
  let starts : @core.Value? = if p.match_text_seq(["STARTS"]) {
    p.parse_string().map(e => @core.Value::Node(e))
  } else {
    Some(Bool(false))
  }
  p.expression(
    @core.mk(RefreshTriggerProperty, [
      ("method", method_),
      ("kind", kind),
      ("every", every),
      ("unit", unit),
      ("starts", starts),
    ]),
  )
}
