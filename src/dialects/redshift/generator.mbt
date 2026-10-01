// Port of sqlglot/generators/redshift.py

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = g.sql(e.this())
  match e.arg("scale") {
    Some(scale) if scale != @core.literal_number("0") && scale.is_int() => {
      let v = match scale.to_py_int() {
        Some(v) => v.to_string()
        None => scale.name()
      }
      this = "(\{this} / POWER(10, \{v}))"
    }
    _ => ()
  }
  "(TIMESTAMP 'epoch' + \{this} * INTERVAL '1 SECOND')"
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  for
    k in [
      @core.Kind::Pivot,
      ParseJSON,
      AnyValue,
      LastDay,
      SHA2,
      Getbit,
      Round,
      TryCast,
    ] {
    t.remove(k)
  }
  t[ArrayConcat] = @core.array_concat_sql("ARRAY_CONCAT")
  t[Concat] = @core.concat_to_dpipe_sql
  t[ConcatWs] = @core.concat_ws_to_dpipe_sql
  t[ApproxDistinct] = (g, e) => {
    "APPROXIMATE COUNT(DISTINCT \{g.sql_key(e, "this")})"
  }
  t[CurrentTimestamp] = (_, e) => {
    if e.has("sysdate") {
      "SYSDATE"
    } else {
      "GETDATE()"
    }
  }
  t[CurrentUserId] = (_, _) => "CURRENT_USER_ID"
  t[DateAdd] = @core.date_delta_sql("DATEADD")
  t[DateDiff] = @core.date_delta_sql("DATEDIFF")
  t[DistKeyProperty] = (g, e) => g.func("DISTKEY", [e.this()])
  t[DistStyleProperty] = (g, e) => g.naked_property(e)
  t[Explode] = (g, e) => g.call_method(Explode, e)
  t[FarmFingerprint] = @core.rename_func("FARMFINGERPRINT64")
  t[FromBase] = @core.rename_func("STRTOL")
  t[GeneratedAsIdentityColumnConstraint] = @core.generatedasidentitycolumnconstraint_sql
  t[JSONExtract] = @core.json_extract_segments("JSON_EXTRACT_PATH_TEXT")
  t[JSONExtractScalar] = @core.json_extract_segments("JSON_EXTRACT_PATH_TEXT")
  t[GroupConcat] = @core.rename_func("LISTAGG")
  t[Hex] = (g, e) => g.func("UPPER", [g.func("TO_HEX", [g.sql_key(e, "this")])])
  t[RegexpExtract] = @core.rename_func("REGEXP_SUBSTR")
  t[Select] = @core.preprocess([
    @core.eliminate_window_clause, @core.eliminate_distinct_on, @core.eliminate_semi_and_anti_joins,
    @core.unqualify_unnest, @core.unnest_generate_date_array_using_recursive_cte,
  ])
  t[SortKeyProperty] = (g, e) => {
    let compound = if e.has("compound") { "COMPOUND " } else { "" }
    let args : Array[&@core.SqlArg] = []
    for x in e.list("this") {
      args.push(x)
    }
    "\{compound}SORTKEY(\{g.format_args(args)})"
  }
  t[StartsWith] = (g, e) => {
    "\{g.sql(e.this())} LIKE \{g.sql(e.expression())} || '%'"
  }
  t[StringToArray] = @core.rename_func("SPLIT_TO_ARRAY")
  t[TableSample] = @core.no_tablesample_sql
  t[TsOrDsAdd] = @core.date_delta_sql("DATEADD")
  t[TsOrDsDiff] = @core.date_delta_sql("DATEDIFF")
  t[UnixToTime] = unix_to_time_sql
  t[SHA2Digest] = (g, e) => {
    let length = match e.arg("length") {
      Some(l) => l
      None => @core.literal_number("256")
    }
    g.func("SHA2", [e.this(), length])
  }
  let m = d.gen_fns.methods
  m[StPoint] = (g, e) => {
    // ST_POINT only accepts 2 args in Redshift; use ST_MAKEPOINT for 3 or 4 args
    if e.has("z") || e.has("m") {
      g.func("ST_MAKEPOINT", [e.this(), e.expression(), e.arg("z"), e.arg("m")])
    } else {
      g.func("ST_POINT", [e.this(), e.expression()])
    }
  }
  m[ArrayContains] = (g, e) => {
    g.func("ARRAY_CONTAINS", [e.this(), e.expression(), e.arg("check_null")])
  }
  m[ObjectTransform] = (g, e) => {
    let this = g.sql_key(e, "this")
    let keep = g.expressions(expression=e, key="keep", flat=true)
    let set_ = g.expressions(expression=e, key="set_", flat=true)
    let keep_sql = if keep != "" { " KEEP " + keep } else { "" }
    let set_sql = if set_ != "" { " SET " + set_ } else { "" }
    "OBJECT_TRANSFORM(\{this}\{keep_sql}\{set_sql})"
  }
  m[ApproxQuantile] = (g, e) => {
    "APPROXIMATE " +
    g.sql(
      Some(
        @core.mk(WithinGroup, [
          ("this", @core.mk1(PercentileDisc, e.arg("quantile"))),
          (
            "expression",
            @core.mk(Order, [("expressions", [@core.mk1(Ordered, e.this())])]),
          ),
        ]),
      ),
    )
  }
  m[Unnest] = (g, e) => {
    let args = e.expressions()
    let num_args = args.length()
    if num_args != 1 {
      g.unsupported("Unsupported number of arguments in UNNEST: \{num_args}")
      return ""
    }
    match e.find_ancestor([From, Join, Select]) {
      Some(a) if a.kind == Select => {
        g.unsupported("Unsupported UNNEST when not used in FROM/JOIN clauses")
        return ""
      }
      _ => ()
    }
    let arg = g.sql(Some(args[0]))
    let alias_sql = match e.arg("alias") {
      Some(a) => g.expressions(expression=a, key="columns", flat=true)
      None => ""
    }
    if alias_sql != "" {
      "\{arg} AS \{alias_sql}"
    } else {
      arg
    }
  }
  let hooks = d.gen_fns.hooks
  let parent_cast = hooks.cast_sql
  hooks.cast_sql = Some((g, e, safe_prefix) => {
    if e.is_type([JSON]) {
      // Redshift doesn't support a JSON type, so casting to it is treated as a noop
      return g.sql_key(e, "this")
    }
    match parent_cast {
      Some(f) => f(g, e, safe_prefix)
      None => g.cast_sql(e, safe_prefix?)
    }
  })
  let parent_datatype = m.get(DataType)
  m[DataType] = (g, e) => {
    // Redshift converts the `TEXT` data type to `VARCHAR(255)` by default when people more
    // generally mean VARCHAR of max length which is `VARCHAR(max)` in Redshift.
    if e.is_type([TEXT]) {
      e.set("this", @core.DType::VARCHAR)
      if e.expressions().is_empty() {
        e.append("expressions", @core.var_("MAX"))
      }
    }
    match parent_datatype {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
  m[AlterSet] = (g, e) => {
    let exprs = g.expressions(expression=e, flat=true)
    let exprs = if exprs != "" { " TABLE PROPERTIES (\{exprs})" } else { "" }
    let location = g.sql_key(e, "location")
    let location = if location != "" { " LOCATION \{location}" } else { "" }
    let file_format = g.expressions(
      expression=e,
      key="file_format",
      flat=true,
      sep=" ",
    )
    let file_format = if file_format != "" {
      " FILE FORMAT \{file_format}"
    } else {
      ""
    }
    "SET\{exprs}\{location}\{file_format}"
  }
  let parent_array = m.get(Array)
  m[Array] = (g, e) => {
    if e.has("bracket_notation") {
      return match parent_array {
        Some(f) => f(g, e)
        None => g.base_dispatch(Array, e).unwrap()
      }
    }
    @core.rename_func("ARRAY")(g, e)
  }
  m[IgnoreNulls] = (g, e) => g.ignorenulls_sql(e)
  m[RespectNulls] = (g, e) => g.respectnulls_sql(e)
  m[Explode] = (g, _) => {
    g.unsupported("Unsupported EXPLODE() function")
    ""
  }
}
