// Port of sqlglot/generators/doris.py

///|
fn lag_lead_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let offset = match e.arg("offset") {
    Some(o) => o
    None => @core.literal_number("1")
  }
  let default = match e.arg("default") {
    Some(o) => o
    None => @core.null_()
  }
  g.func(if e.kind == Lag { "LAG" } else { "LEAD" }, [
    e.this_(),
    offset,
    default,
  ])
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  @mysql.register_settings(d, s => {
    s.varchar_requires_size = false
    s.cast_mapping = Map([])
    s.timestamp_func_types = []
  })
  let t = d.gen_fns.transforms
  t[AddMonths] = @core.rename_func("MONTHS_ADD")
  t[ApproxDistinct] = @core.approx_count_distinct_sql
  t[ArgMax] = @core.rename_func("MAX_BY")
  t[ArgMin] = @core.rename_func("MIN_BY")
  t[ArrayAgg] = @core.rename_func("COLLECT_LIST")
  t[ArrayToString] = @core.rename_func("ARRAY_JOIN")
  t[ArrayUniqueAgg] = @core.rename_func("COLLECT_SET")
  t[CurrentDate] = (g, _) => g.func("CURRENT_DATE", [])
  t[CurrentTimestamp] = (g, _) => g.func("NOW", [])
  t[DateTrunc] = (g, e) => {
    g.func("DATE_TRUNC", [e.this(), @core.weekstart_unit_to_str(g, e)])
  }
  t[EuclideanDistance] = @core.rename_func("L2_DISTANCE")
  t[GroupConcat] = (g, e) => {
    let sep = match e.arg("separator") {
      Some(s) => s
      None => @core.literal_string(",")
    }
    g.func("GROUP_CONCAT", [e.this_(), sep])
  }
  t[JSONExtractScalar] = (g, e) => {
    g.func("JSON_EXTRACT", [e.this(), e.expression()])
  }
  t[Lag] = lag_lead_sql
  t[Lead] = lag_lead_sql
  t[Map] = @core.rename_func("ARRAY_MAP")
  t[Property] = @core.property_sql
  t[RegexpLike] = @core.rename_func("REGEXP")
  t[RegexpSplit] = @core.rename_func("SPLIT_BY_STRING")
  t[SchemaCommentProperty] = (g, e) => g.naked_property(e)
  t[Split] = @core.rename_func("SPLIT_BY_STRING")
  t[StringToArray] = @core.rename_func("SPLIT_BY_STRING")
  t[StrToUnix] = (g, e) => {
    g.func("UNIX_TIMESTAMP", [e.this(), g.format_time(e)])
  }
  t[TimeStrToDate] = @core.rename_func("TO_DATE")
  t[TsOrDsAdd] = (g, e) => g.func("DATE_ADD", [e.this(), e.expression()])
  t[TsOrDsToDate] = (g, e) => g.func("TO_DATE", [e.this()])
  t[TimeToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[TimestampTrunc] = (g, e) => {
    g.func("DATE_TRUNC", [e.this(), @core.weekstart_unit_to_str(g, e)])
  }
  t[UnixToStr] = (g, e) => {
    g.func("FROM_UNIXTIME", [e.this(), @core.time_format(dialect="doris")(g, e)])
  }
  t[UnixToTime] = @core.rename_func("FROM_UNIXTIME")
  let hooks = d.gen_fns.hooks
  let parent_uniquekeyproperty_sql = hooks.uniquekeyproperty_sql
  let super_uniquekeyproperty_sql = (g : @core.Generator, e, prefix) => {
    match parent_uniquekeyproperty_sql {
      Some(f) => f(g, e, prefix)
      None => g.uniquekeyproperty_sql(e, prefix~)
    }
  }
  hooks.uniquekeyproperty_sql = Some((g, e, prefix) => {
    match e.find_ancestor([Create]) {
      Some(create_stmt) if create_stmt.arg("properties") is Some(props) &&
        props.find([MaterializedProperty]) is Some(_) =>
        super_uniquekeyproperty_sql(g, e, "KEY")
      _ => super_uniquekeyproperty_sql(g, e, prefix)
    }
  })
  let m = d.gen_fns.methods
  m[PartitionRange] = partitionrange_sql
  m[PartitionByRangePropertyDynamic] = (g, e) => {
    // Generates: FROM ("start") TO ("end") INTERVAL N UNIT
    let start = g.sql_key(e, "start")
    let end = g.sql_key(e, "end")
    let interval = match e.arg("every") {
      Some(every) =>
        "INTERVAL \{g.sql_key(every, "this")} \{g.sql_key(every, "unit")}"
      None => ""
    }
    "FROM (\{start}) TO (\{end}) \{interval}"
  }
  m[PartitionedByProperty] = (g, e) => {
    match e.this() {
      Some(this) if this.kind == Schema =>
        "PARTITION BY (\{g.expressions(expression=this, flat=true)})"
      this => "PARTITION BY (\{g.sql(this)})"
    }
  }
  let parent_table_sql = hooks.table_sql
  hooks.table_sql = Some((g, e, sep) => {
    // Override table_sql to avoid AS keyword in UPDATE and DELETE statements.
    let sep = match e.find_ancestor([Update, Delete, Select]) {
      Some(a) if a.kind == Select => sep
      _ => " "
    }
    match parent_table_sql {
      Some(f) => f(g, e, sep)
      None => g.table_sql(e, sep~)
    }
  })
}

///|
fn partitionrange_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let name = g.sql_key(e, "this")
  let values = e.raw_list("expressions")
  if values.length() != 1 {
    // Multiple values: use VALUES [ ... )
    let parts = []
    if values.length() > 0 && values[0] is List(_) {
      for inner in values {
        let inner_sqls = []
        if inner is List(xs) {
          for v in xs {
            inner_sqls.push(g.sql_value(v))
          }
        }
        parts.push("(\{inner_sqls.join(", ")})")
      }
    } else {
      for v in values {
        parts.push("(\{g.sql_value(v)})")
      }
    }
    return "PARTITION \{name} VALUES [\{parts.join(", ")})"
  }
  "PARTITION \{name} VALUES LESS THAN (\{g.sql_value(values[0])})"
}
