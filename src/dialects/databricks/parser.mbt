// Port of sqlglot/parsers/databricks.py

///|
fn node_value(e : @core.Expr?) -> @core.Value? {
  match e {
    Some(x) => Some(Node(x))
    None => None
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f["IFF"] = @core.from_arg_list_builder(If)
  f["GETDATE"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["DATEDIFF"] = @core.build_date_delta(DateDiff)
  f["DATE_DIFF"] = @core.build_date_delta(DateDiff)
  f["NOW"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["TO_DATE"] = @core.build_formatted_time(TsOrDsToDate)
  f["UNIFORM"] = (args, _) => {
    @core.mk(Uniform, [
      ("this", args.get(0)),
      ("expression", args.get(1)),
      ("seed", args.get(2)),
    ])
  }
  fns.no_paren_function_parsers["CURDATE"] = p => {
    // CURDATE, an alias for CURRENT_DATE, has optional parentheses
    if p.match_(L_PAREN) {
      p.match_r_paren()
    }
    Some(p.expression(@core.mk0(CurrentDate)))
  }
  let fp = fns.function_parsers
  fp["REGR_AVGX"] = p => {
    p.parse_distinct_arg_function(RegrAvgx, distinct_index=1)
  }
  fp["REGR_AVGY"] = p => p.parse_distinct_arg_function(RegrAvgy)
  fp["REGR_SXX"] = p => p.parse_distinct_arg_function(RegrSxx, distinct_index=1)
  fp["REGR_SXY"] = p => p.parse_distinct_arg_function(RegrSxy)
  fp["REGR_SYY"] = p => p.parse_distinct_arg_function(RegrSyy, distinct_index=1)
  // COLUMN_OPERATORS = {**parser.Parser.COLUMN_OPERATORS, QDCOLON: ...}
  fns.column_operators = Map::from_iter(
    @core.base_dialect().parser_fns.column_operators.iter(),
  )
  fns.column_operators[QDCOLON] = Some((p, this, to) => {
    Some(
      p.build_cast(false, [("this", node_value(this)), ("to", node_value(to))]),
    )
  })
  let parent_pk_part = fns.hooks.parse_primary_key_part
  fns.hooks.parse_primary_key_part = Some(p => {
    let this = match parent_pk_part {
      Some(f) => f(p)
      None => p.parse_field()
    }
    if this is Some(_) && p.match_text_seq(["TIMESERIES"]) {
      return Some(p.expression(@core.mk1(TimeseriesKey, this)))
    }
    this
  })
  let parent_cluster = fns.hooks.parse_cluster_property
  fns.hooks.parse_cluster_property = Some(p => {
    if p.match_texts(["AUTO", "NONE"]) {
      return Some(
        p.expression(@core.mk1(ClusterProperty, @core.py_upper(p.prev.text))),
      )
    }
    match parent_cluster {
      Some(f) => f(p)
      None => p.parse_cluster_property_base()
    }
  })
}
