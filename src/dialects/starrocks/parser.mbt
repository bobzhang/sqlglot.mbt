// Port of sqlglot/parsers/starrocks.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f["ADDDATE"] = @core.build_date_delta_with_interval(
    DateAdd,
    default_unit="DAY",
  )
  f["DATE_ADD"] = @core.build_date_delta_with_interval(
    DateAdd,
    default_unit="DAY",
  )
  f["DATE_SUB"] = @core.build_date_delta_with_interval(
    DateSub,
    default_unit="DAY",
  )
  f["SUBDATE"] = @core.build_date_delta_with_interval(
    DateSub,
    default_unit="DAY",
  )
  f["DATE_TRUNC"] = (args, _) => @core.build_timestamp_trunc(args)
  f["DATEDIFF"] = (args, _) => {
    @core.mk(DateDiff, [
      ("this", @mysql.seq_get(args, 0)),
      ("expression", @mysql.seq_get(args, 1)),
      ("unit", @core.literal_string("DAY")),
    ])
  }
  f["DATE_DIFF"] = (args, _) => {
    @core.mk(DateDiff, [
      ("this", @mysql.seq_get(args, 1)),
      ("expression", @mysql.seq_get(args, 2)),
      ("unit", @mysql.seq_get(args, 0)),
    ])
  }
  f["ARRAY_FLATTEN"] = @core.from_arg_list_builder(Flatten)
  f["REGEXP"] = @core.from_arg_list_builder(RegexpLike)
  // StarRocks' MAP() is a variadic constructor: MAP(k1, v1, k2, v2, ...)
  // https://docs.starrocks.io/docs/sql-reference/sql-functions/map-functions/map/
  f["MAP"] = (args, _) => @core.build_var_map(args)
  // TABLE(<tvf>) wraps a table function invocation whose arguments are constants
  // https://docs.starrocks.io/docs/sql-reference/sql-functions/table-functions/generate_series/
  f["TABLE"] = (args, _) => @core.mk1(TableFromRows, @mysql.seq_get(args, 0))
  let pp = fns.property_parsers
  pp["PROPERTIES"] = (p, _) => {
    Some(List(p.parse_wrapped_properties().map(e => @core.Value::Node(e))))
  }
  pp["UNIQUE"] = (p, _) => {
    Some(Node(p.parse_composite_key_property(UniqueKeyProperty)))
  }
  pp["ROLLUP"] = (p, _) => Some(Node(parse_rollup_property(p)))
  pp["REFRESH"] = (p, _) => Some(Node(parse_refresh_property(p)))
  pp["PARTITION BY"] = (p, _) => parse_partition_property(p)
  let h = fns.hooks
  let parent_parse_create = h.parse_create
  h.parse_create = Some(p => {
    let create = match parent_parse_create {
      Some(f) => f(p)
      None => p.parse_create_base()
    }
    // Starrocks' primary key is defined outside of the schema, so we need to move it there
    // https://docs.starrocks.io/docs/table_design/table_types/primary_key_table/#usage
    match create {
      Some(c) if c.kind == Create &&
        c.this() is Some(schema) &&
        schema.kind == Schema =>
        match c.arg("properties") {
          Some(props) =>
            match props.find([PrimaryKey]) {
              Some(primary_key) =>
                schema.append("expressions", primary_key.pop())
              None => ()
            }
          None => ()
        }
      _ => ()
    }
    create
  })
  let parent_parse_unnest = h.parse_unnest
  h.parse_unnest = Some((p, with_alias) => {
    let unnest = match parent_parse_unnest {
      Some(f) => f(p, with_alias)
      None => p.parse_unnest_base(with_alias~)
    }
    match unnest {
      Some(u) =>
        match u.arg("alias") {
          None => {
            // Starrocks defaults to naming the table alias as "unnest"
            let table_alias = @core.mk(TableAlias, [
              ("this", @core.to_identifier("unnest")),
              ("columns", [@core.to_identifier("unnest")]),
            ])
            u.set("alias", table_alias)
          }
          Some(table_alias) =>
            if !table_alias.has("columns") {
              // Starrocks defaults to naming the UNNEST column as "unnest"
              // if it's not otherwise specified
              table_alias.set("columns", [@core.to_identifier("unnest")])
            }
        }
      None => ()
    }
    unnest
  })
  h.parse_partitioned_by = Some(p => {
    Some(
      p.expression(
        @core.mk1(
          PartitionedByProperty,
          @core.mk(Schema, [
            (
              "expressions",
              p.parse_wrapped_csv(() => p.parse_assignment(), optional=true),
            ),
          ]),
        ),
      ),
    )
  })
}

///|
/// ROLLUP (rollup_name (col1, col2) [FROM from_index] [PROPERTIES (...)], ...)
fn parse_rollup_property(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let parse_rollup_index = () => {
    let this = p.parse_id_var()
    let expressions = p.parse_wrapped_id_vars()
    let from_index = if p.match_text_seq(["FROM"]) {
      p.parse_id_var()
    } else {
      None
    }
    let properties = if p.match_text_seq(["PROPERTIES"]) {
      Some(
        p.expression(
          @core.mk(Properties, [("expressions", p.parse_wrapped_properties())]),
        ),
      )
    } else {
      None
    }
    Some(
      p.expression(
        @core.mk(RollupIndex, [
          ("this", this),
          ("expressions", expressions),
          ("from_index", from_index),
          ("properties", properties),
        ]),
      ),
    )
  }
  p.expression(
    @core.mk(RollupProperty, [
      ("expressions", p.parse_wrapped_csv(parse_rollup_index)),
    ]),
  )
}

///|
fn parse_partition_property(
  p : @core.Parser,
) -> @core.Value? raise @core.SqlglotError {
  // super()._parse_partition_property() (StarRocks keeps MySQL's _parse_partition_range_value)
  let expr = @mysql.parse_partition_property(
    p, @mysql.parse_partition_range_value,
  )
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
      ["START"],
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
  p.match_text_seq(["START"]) |> ignore
  let start = p.parse_wrapped(() => p.parse_string())
  p.match_text_seq(["END"]) |> ignore
  let end = p.parse_wrapped(() => p.parse_string())
  p.match_text_seq(["EVERY"]) |> ignore
  let every = p.parse_wrapped(() => {
    match p.parse_interval() {
      Some(i) => Some(i)
      None => p.parse_number()
    }
  })
  p.expression(
    @core.mk(PartitionByRangePropertyDynamic, [
      ("start", start),
      ("end", end),
      ("every", every),
    ]),
  )
}

///|
/// REFRESH [DEFERRED | IMMEDIATE]
///         [ASYNC | ASYNC [START (<start_time>)] EVERY (INTERVAL <refresh_interval>) | MANUAL]
fn parse_refresh_property(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let method_ : String? = if p.match_texts(["DEFERRED", "IMMEDIATE"]) {
    Some(@core.py_upper(p.prev.text))
  } else {
    None
  }
  let kind : String? = if p.match_texts(["ASYNC", "MANUAL"]) {
    Some(@core.py_upper(p.prev.text))
  } else {
    None
  }
  let start = if p.match_text_seq(["START"]) {
    p.parse_wrapped(() => p.parse_string())
  } else {
    None
  }
  let (every, unit) = if p.match_text_seq(["EVERY"]) {
    p.match_l_paren()
    p.match_text_seq(["INTERVAL"]) |> ignore
    let every = p.parse_number()
    let unit = p.parse_var(any_token=true)
    p.match_r_paren()
    (every, unit)
  } else {
    (None, None)
  }
  p.expression(
    @core.mk(RefreshTriggerProperty, [
      ("method", method_),
      ("kind", kind),
      ("starts", start),
      ("every", every),
      ("unit", unit),
    ]),
  )
}
