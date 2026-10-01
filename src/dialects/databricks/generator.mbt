// Port of sqlglot/generators/databricks.py

///|
fn regr_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let name = e.kind.sql_name()
  match e.expression() {
    Some(x) if x.kind == Distinct => {
      let args : Array[&@core.SqlArg] = [
        @core.mk(Distinct, [("expressions", [e.this().unwrap()])]),
      ]
      for a in x.expressions() {
        args.push(a)
      }
      g.func(name, args)
    }
    x => g.func(name, [e.this(), x])
  }
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  d.gen_cfg.type_mapping[NULL] = "VOID"
  // SAFE_JSON_PATH_KEY_RE = exp.SAFE_IDENTIFIER_RE
  d.gen_fns.hooks.safe_json_path_key_re = None
  let t = d.gen_fns.transforms
  t[CurrentVersion] = (_, _) => "CURRENT_VERSION()"
  t[DateAdd] = @core.date_delta_sql("DATEADD")
  t[DateDiff] = @core.date_delta_sql("DATEDIFF")
  t[DatetimeAdd] = (g, e) => {
    g.func("TIMESTAMPADD", [e.arg("unit"), e.expression(), e.this()])
  }
  t[DatetimeSub] = (g, e) => {
    g.func("TIMESTAMPADD", [
      e.arg("unit"),
      Some(@core.mk2(Mul, e.expression(), @core.literal_int(-1))),
      e.this(),
    ])
  }
  t[DatetimeTrunc] = @core.timestamptrunc_sql()
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e)
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on,
    @core.unnest_to_explode(),
    @core.any_to_exists,
  ])
  t[JSONExtract] = (g, e) => {
    "\{g.sql_key(e, "this")}:\{g.sql_key(e, "expression")}"
  }
  t[JSONPathRoot] = (_, e) => {
    match e.parent {
      Some(p) if p.parent is Some(pp) && pp.kind == JSONExtractScalar => "$"
      _ => ""
    }
  }
  t[ToChar] = (g, e) => {
    if e.has("is_numeric") {
      g.cast_sql_v(
        @core.mk(Cast, [
          ("this", e.this()),
          ("to", Some(@core.datatype_of(TEXT))),
        ]),
      )
    } else {
      g.function_fallback_sql(e)
    }
  }
  t[CurrentCatalog] = (_, _) => "CURRENT_CATALOG()"
  t.remove(RegexpLike)
  t.remove(TryCast)
  t[RegrAvgx] = regr_sql
  t[RegrSxx] = regr_sql
  t[RegrSyy] = regr_sql
  let m = d.gen_fns.methods
  let parent_create = m.get(Create)
  m[Create] = (g, e) => {
    match e.expression() {
      Some(body) if body.kind != Return &&
        @core.py_upper(e.text("kind")) == "FUNCTION" &&
        e.find_all([ReturnsProperty]).any(p => p.has("is_table")) =>
        e.set("expression", @core.mk1(Return, body))
      _ => ()
    }
    match parent_create {
      Some(f) => f(g, e)
      None => g.create_sql(e)
    }
  }
  let parent_columndef = d.gen_fns.hooks.columndef_sql
  d.gen_fns.hooks.columndef_sql = Some((g, e, sep) => {
    let constraint = e.find([GeneratedAsIdentityColumnConstraint])
    match (constraint, e.arg("kind")) {
      (Some(_), Some(kind)) if kind.kind == DataType &&
        (match kind.datatype_this() {
          Some(dt) => @core.dtype_integer_types.contains(dt)
          None => false
        }) =>
        // only BIGINT generated identity constraints are supported
        e.set("kind", @core.datatype_of(BIGINT))
      _ => ()
    }
    match parent_columndef {
      Some(f) => f(g, e, sep)
      None => g.columndef_sql(e, sep~)
    }
  })
  m[TimeseriesKey] = (g, e) => "\{g.sql_key(e, "this")} TIMESERIES"
  let parent_jsonpath = m.get(JSONPath)
  m[JSONPath] = (g, e) => {
    let path = match parent_jsonpath {
      Some(f) => f(g, e)
      None => g.jsonpath_sql(e)
    }
    match e.parent {
      Some(p) if p.kind == JSONExtractScalar => {
        let path = g.escape_str(path)
        "\{g.dialect.cfg.quote_start}\{path}\{g.dialect.cfg.quote_end}"
      }
      _ => path
    }
  }
  m[Uniform] = (g, e) => {
    let gen = e.arg("gen")
    // From Snowflake UNIFORM(min, max, gen) as RANDOM(), RANDOM(seed), or constant value -> Extract seed
    let seed = match gen {
      Some(gn) => gn.this()
      None => e.arg("seed")
    }
    g.func("UNIFORM", [e.this(), e.expression(), seed])
  }
  m[ClusterProperty] = (g, e) => {
    let this = match g.sql_key(e, "this") {
      "" => "(\{g.expressions(expression=e, flat=true)})"
      s => s
    }
    "CLUSTER BY \{this}"
  }
}
