// Port of sqlglot/parsers/oracle.py

///|
fn build_to_timestamp(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  if args.length() == 1 {
    return @core.mk(Anonymous, [("this", "TO_TIMESTAMP"), ("expressions", args)])
  }
  @core.build_formatted_time(StrToTime)(args, p)
}

///|
let query_restrictions : Map[String, Array[Array[String]]] = {
  "WITH": [["READ", "ONLY"], ["CHECK", "OPTION"]],
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f.remove("TO_BOOLEAN")
  f["CONVERT"] = @core.from_arg_list_builder(ConvertToCharset)
  f["L2_DISTANCE"] = @core.from_arg_list_builder(EuclideanDistance)
  f["NVL"] = (args, _) => @core.build_coalesce(args, is_nvl=true)
  f["SQUARE"] = (args, _) => {
    @core.mk(Pow, [
      ("this", args.get(0)),
      ("expression", @core.literal_number("2")),
    ])
  }
  f["TO_CHAR"] = (args, p) => @core.build_timetostr_or_tochar(args, p.dialect)
  f["TO_TIMESTAMP"] = build_to_timestamp
  f["TO_DATE"] = @core.build_formatted_time(StrToDate)
  f["TRUNC"] = (args, p) => {
    @core.build_trunc(
      args,
      p.dialect,
      date_trunc_unabbreviate=false,
      default_date_trunc_unit="DD",
    )
  }
  let np = fns.no_paren_function_parsers
  np["NEXT"] = p => p.parse_next_value_for()
  np["PRIOR"] = p => Some(p.expression(@core.mk1(Prior, p.parse_bitwise())))
  np["SYSDATE"] = p => {
    Some(p.expression(@core.mk(CurrentTimestamp, [("sysdate", true)])))
  }
  np["DBMS_RANDOM"] = parse_dbms_random
  let fp = fns.function_parsers
  fp.remove("CONVERT")
  fp["JSON_ARRAY"] = parse_oracle_json_array
  fp["JSON_ARRAYAGG"] = parse_oracle_json_arrayagg
  fp["JSON_EXISTS"] = parse_json_exists
  fp["LISTAGG"] = p => p.parse_string_agg()
  fp["TO_NUMBER"] = parse_to_number
  let pp = fns.property_parsers
  pp["GLOBAL"] = (p, _) => {
    if p.match_text_seq(["TEMPORARY"]) {
      Some(Node(p.expression(@core.mk1(TemporaryProperty, "GLOBAL"))))
    } else {
      None
    }
  }
  pp["PRIVATE"] = (p, _) => {
    if p.match_text_seq(["TEMPORARY"]) {
      Some(Node(p.expression(@core.mk1(TemporaryProperty, "PRIVATE"))))
    } else {
      None
    }
  }
  pp["FORCE"] = (p, _) => Some(Node(p.expression(@core.mk0(ForceProperty))))
  let qm = fns.query_modifier_parsers
  qm[ORDER_SIBLINGS_BY] = p => ("order", p.parse_order().map(x => Node(x)))
  qm[WITH] = p => {
    let restrictions = match parse_query_restrictions(p) {
      Some(e) => [@core.Value::Node(e)]
      None => []
    }
    ("options", Some(List(restrictions)))
  }
  fns.type_literal_parsers.clear()
  fns.type_literal_parsers[DATE] = (p, this, _) => {
    p.expression(@core.mk1(DateStrToDate, this))
  }
  // https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/NLS_TIMESTAMP_FORMAT.html
  fns.type_literal_parsers[TIMESTAMP] = (p, this, _) => {
    @core.mk(StrToTime, [
      ("this", this),
      ("format", p.dialect.format_time_str("\"%Y-%m-%d %H:%M:%S.%f\"")),
    ])
  }
  let h = fns.hooks
  h.parse_hint_function_call = Some(parse_hint_function_call)
  h.parse_into_clause = Some(parse_into)
  h.parse_connect_with_prior = Some(p => p.parse_assignment())
  let parent_parse_column_ops = h.parse_column_ops
  h.parse_column_ops = Some((p, this) => {
    let this = match parent_parse_column_ops {
      Some(f) => f(p, this)
      None => p.parse_column_ops_base(this)
    }
    guard this is Some(_) else { return this }
    let index = p.index
    // https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/Interval-Exprs.html
    let interval_span = p.try_parse(() => Some(p.parse_interval_span(this)))
    match interval_span {
      Some(span) if span.arg("unit") is Some(u) && u.kind == IntervalSpan =>
        return Some(span)
      _ => ()
    }
    p.retreat(index)
    this
  })
  h.parse_insert_table = Some(parse_insert_table)
}

///|
/// https://docs.oracle.com/en/database/oracle/oracle-database/19/sqlrf/TO_NUMBER.html
fn parse_to_number(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_bitwise()
  let mut default : @core.Expr? = None
  if p.match_(DEFAULT) {
    default = p.parse_bitwise()
    p.match_text_seq(["ON", "CONVERSION", "ERROR"]) |> ignore
  }
  let mut fmt : @core.Expr? = None
  let mut nlsparam : @core.Expr? = None
  if p.match_(COMMA) {
    fmt = p.parse_bitwise()
    if p.match_(COMMA) {
      nlsparam = p.parse_bitwise()
    }
  }
  Some(
    p.expression(
      @core.mk(ToNumber, [
        ("this", this),
        ("format", fmt),
        ("nlsparam", nlsparam),
        ("default", default),
      ]),
    ),
  )
}

///|
fn parse_dbms_random(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_text_seq([".", "VALUE"]) {
    let mut lower : @core.Expr? = None
    let mut upper : @core.Expr? = None
    if p.match_(L_PAREN, advance=false) {
      let lower_upper = p.parse_wrapped_csv(() => p.parse_bitwise())
      if lower_upper.length() == 2 {
        lower = Some(lower_upper[0])
        upper = Some(lower_upper[1])
      }
    }
    return Some(@core.mk(Rand, [("lower", lower), ("upper", upper)]))
  }
  p.retreat(p.index - 1)
  None
}

///|
fn parse_json_array(
  p : @core.Parser,
  kind : @core.Kind,
  kwargs : Array[(String, &@core.IntoValue)],
) -> @core.Expr? raise @core.SqlglotError {
  let null_handling = p.parse_on_handling("NULL", ["NULL", "ABSENT"])
  let return_type : @core.Expr? = if p.match_text_seq(["RETURNING"]) {
    p.parse_type()
  } else {
    None
  }
  let strict = p.match_text_seq(["STRICT"])
  let args : Array[(String, &@core.IntoValue)] = [
    ("null_handling", null_handling),
    ("return_type", return_type),
    ("strict", strict),
  ]
  args.append(kwargs)
  Some(p.expression(@core.mk(kind, args)))
}

///|
fn parse_oracle_json_array(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let expressions = p.parse_csv(() => p.parse_format_json(p.parse_bitwise()))
  parse_json_array(p, JSONArray, [("expressions", expressions)])
}

///|
fn parse_oracle_json_arrayagg(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_format_json(p.parse_bitwise())
  let order = p.parse_order()
  parse_json_array(p, JSONArrayAgg, [("this", this), ("order", order)])
}

///|
fn parse_hint_function_call(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if !p.curr.ok() || !p.next.ok() || p.next.token_type != L_PAREN {
    return None
  }
  let name = p.curr.text
  p.advance(times=2)
  let args = parse_hint_args(p)
  let this = p.expression(
    @core.mk(Anonymous, [("this", name), ("expressions", args)]),
  )
  p.match_r_paren(expression=this)
  Some(this)
}

///|
fn parse_hint_args(
  p : @core.Parser,
) -> Array[@core.Expr] raise @core.SqlglotError {
  let args = []
  let mut result = p.parse_var()
  while result is Some(r) {
    args.push(r)
    result = p.parse_var()
  }
  args
}

///|
fn parse_query_restrictions(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let kind = p.parse_var_from_options(query_restrictions, raise_unmatched=false)
  guard kind is Some(_) else { return None }
  let expression = if p.match_(CONSTRAINT) { p.parse_field() } else { None }
  Some(
    p.expression(
      @core.mk(QueryOption, [("this", kind), ("expression", expression)]),
    ),
  )
}

///|
fn parse_json_exists(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_format_json(p.parse_bitwise())
  p.match_(COMMA) |> ignore
  let path = p.dialect.to_json_path(p.parse_bitwise())
  let passing = if p.match_text_seq(["PASSING"]) {
    Some(p.parse_csv(() => p.parse_alias(p.parse_bitwise())))
  } else {
    None
  }
  let on_condition = p.parse_on_condition()
  Some(
    p.expression(
      @core.mk(JSONExists, [
        ("this", this),
        ("path", path),
        ("passing", passing),
        ("on_condition", on_condition),
      ]),
    ),
  )
}

///|
/// https://docs.oracle.com/en/database/oracle/oracle-database/19/lnpls/SELECT-INTO-statement.html
fn parse_into(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let bulk_collect = p.match_(BULK_COLLECT_INTO)
  if !bulk_collect && !p.match_(INTO) {
    return None
  }
  let index = p.index
  let expressions = p.parse_expressions()
  if expressions.length() == 1 {
    p.retreat(index)
    p.match_(TABLE) |> ignore
    return Some(
      p.expression(
        @core.mk(Into, [
          ("this", p.parse_table(schema=true)),
          ("bulk_collect", bulk_collect),
        ]),
      ),
    )
  }
  Some(
    p.expression(
      @core.mk(Into, [
        ("bulk_collect", bulk_collect),
        ("expressions", expressions),
      ]),
    ),
  )
}

///|
fn parse_insert_table(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // Oracle does not use AS for INSERT INTO alias
  // https://docs.oracle.com/en/database/oracle/oracle-database/18/sqlrf/INSERT.html
  // Parse table parts without schema to avoid parsing the alias with its columns
  let this = p.parse_table_parts(schema=true)
  match this {
    Some(t) if t.kind == Table => {
      match p.parse_id_var(any_token=false) {
        Some(alias_name) => t.set("alias", @core.mk1(TableAlias, alias_name))
        None => ()
      }
      t.set("partition", p.parse_partition())
      // Now parse the schema (column list) if present
      p.parse_schema(this=Some(t))
    }
    _ => this
  }
}
