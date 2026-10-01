// Port of sqlglot/parsers/redshift.py

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i >= 0 && i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn build_date_delta(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    let expr = @core.mk(kind, [
      ("this", seq_get(args, 2)),
      ("expression", seq_get(args, 1)),
      ("unit", @core.map_date_part(seq_get(args, 0))),
    ])
    if kind == TsOrDsAdd {
      expr.set("return_type", @core.datatype_of(TIMESTAMP))
    }
    expr
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f.remove("GET_BIT")
  f["ADD_MONTHS"] = (args, _) => {
    @core.mk(TsOrDsAdd, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("unit", @core.var_("month")),
      ("return_type", @core.datatype_of(TIMESTAMP)),
    ])
  }
  f["CONVERT_TIMEZONE"] = (args, _) => {
    @core.build_convert_timezone(args, default_source_tz="UTC")
  }
  f["DATEADD"] = build_date_delta(TsOrDsAdd)
  f["DATE_ADD"] = build_date_delta(TsOrDsAdd)
  f["DATEDIFF"] = build_date_delta(TsOrDsDiff)
  f["DATE_DIFF"] = build_date_delta(TsOrDsDiff)
  f["GETDATE"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["LISTAGG"] = @core.from_arg_list_builder(GroupConcat)
  f["REGEXP_SUBSTR"] = (args, _) => {
    @core.mk(RegexpExtract, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("position", seq_get(args, 2)),
      ("occurrence", seq_get(args, 3)),
      ("parameters", seq_get(args, 4)),
    ])
  }
  f["SPLIT_TO_ARRAY"] = (args, _) => {
    let expression = match seq_get(args, 1) {
      Some(e) => e
      None => @core.literal_string(",")
    }
    @core.mk(StringToArray, [
      ("this", seq_get(args, 0)),
      ("expression", expression),
    ])
  }
  f["ARRAY_CONTAINS"] = (args, _) => {
    @core.mk(ArrayContains, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("check_null", seq_get(args, 2)),
    ])
  }
  f["STRTOL"] = @core.from_arg_list_builder(FromBase)
  f["TEXTLEN"] = @core.from_arg_list_builder(Length)
  fns.no_paren_function_parsers["APPROXIMATE"] = parse_approximate_count
  fns.no_paren_function_parsers["SYSDATE"] = p => {
    Some(p.expression(@core.mk(CurrentTimestamp, [("sysdate", true)])))
  }
  fns.function_parsers["OBJECT_TRANSFORM"] = parse_object_transform
  let hooks = fns.hooks
  let parent_table = hooks.parse_table
  hooks.parse_table = Some((p, args) => {
    // Redshift supports UNPIVOTing SUPER objects, e.g. `UNPIVOT foo.obj[0] AS val AT attr`
    let unpivot = p.match_(UNPIVOT)
    let args = { ..args, parse_partition: false, consume_pipe: false, }
    let table = match parent_table {
      Some(f) => f(p, args)
      None => p.parse_table_base(args)
    }
    if unpivot {
      Some(p.expression(@core.mk(Pivot, [("this", table), ("unpivot", true)])))
    } else {
      table
    }
  })
  hooks.parse_convert = Some((p, _strict, safe) => {
    let to = p.parse_types()
    p.match_(COMMA) |> ignore
    let this = p.parse_bitwise()
    let cast = @core.mk(Cast, [("this", this), ("to", to)])
    match safe {
      Some(s) => cast.set("safe", s)
      None => ()
    }
    Some(p.expression(cast))
  })
  let parent_projections = hooks.parse_projections
  hooks.parse_projections = Some(p => {
    let (projections, _) = match parent_projections {
      Some(f) => f(p)
      None => (p.parse_expressions(), None)
    }
    if @core.py_upper(p.prev.text) == "EXCLUDE" && p.curr.ok() {
      p.retreat(p.index - 1)
    }
    // EXCLUDE clause always comes at the end of the projection list and applies to it as a whole
    let exclude = if p.match_text_seq(["EXCLUDE"]) {
      p.parse_wrapped_csv(() => p.parse_expression(), optional=true)
    } else {
      []
    }
    if !exclude.is_empty() && projections.length() > 0 {
      let expr = projections[projections.length() - 1]
      if expr.kind.is_a(Alias) && @core.py_upper(expr.alias_()) == "EXCLUDE" {
        projections[projections.length() - 1] = expr.this().unwrap().pop()
      }
    }
    (projections, Some(exclude))
  })
}

///|
fn parse_object_transform(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_column()
  let mut keep : Array[@core.Expr] = []
  let mut set_ : Array[@core.Expr] = []
  if p.match_(KEEP) {
    keep = p.parse_csv(() => p.parse_primary())
  }
  if p.match_(SET) {
    set_ = p.parse_csv(() => p.parse_expression())
  }
  Some(
    p.expression(
      @core.mk(ObjectTransform, [("this", this), ("keep", keep), ("set_", set_)]),
    ),
  )
}

///|
fn parse_approximate_count(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index - 1
  let func = p.parse_function()
  match func {
    Some(f) if f.kind == Count && f.this() is Some(d) && d.kind == Distinct =>
      return Some(
        p.expression(@core.mk1(ApproxDistinct, seq_get(d.expressions(), 0))),
      )
    Some(f) if f.kind == WithinGroup &&
      f.this() is Some(pd) &&
      pd.kind == PercentileDisc => {
      let ordered = match f.expression() {
        Some(o) => seq_get(o.expressions(), 0)
        None => None
      }
      return Some(
        p.expression(
          @core.mk(ApproxQuantile, [
            (
              "this",
              match ordered {
                Some(o) => o.this()
                None => None
              },
            ),
            ("quantile", pd.this()),
          ]),
        ),
      )
    }
    _ => ()
  }
  p.retreat(index)
  None
}
