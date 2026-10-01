// Port of the `<key>_sql` method overrides of sqlglot/generators/snowflake.py

///|
fn opt_kind_is(e : @core.Expr?, kinds : Array[@core.Kind]) -> Bool {
  match e {
    Some(x) => x.kind.is_any(kinds)
    None => false
  }
}

///|
fn register_methods(d : @core.Dialect) -> Unit {
  let m = d.gen_fns.methods
  let h = d.gen_fns.hooks
  m[DynamicIdentifier] = dynamicidentifier_sql
  m[SortArray] = sortarray_sql
  h.with_properties = Some((g, properties) => {
    g.properties(properties, wrapped=false, prefix=g.sep(sep=""), sep=" ")
  })
  h.values_sql = Some((g, e, values_as_table) => {
    let values_as_table = if e.find([Map, StarMap, Struct, VarMap]) is Some(_) {
      false
    } else {
      values_as_table
    }
    g.values_sql(e, values_as_table~)
  })
  m[DataType] = datatype_sql
  m[ToNumber] = tonumber_sql
  m[TimestampFromParts] = timestampfromparts_sql
  h.cast_sql = Some((g, e, safe_prefix) => {
    if e.is_type([GEOGRAPHY]) {
      return g.func("TO_GEOGRAPHY", [e.this()])
    }
    if e.is_type([GEOMETRY]) {
      return g.func("TO_GEOMETRY", [e.this()])
    }
    g.cast_sql(e, safe_prefix?)
  })
  m[TryCast] = trycast_sql
  m[Log] = (g, e) => {
    if !e.has("expression") {
      g.func("LN", [e.this()])
    } else {
      g.log_sql(e)
    }
  }
  m[Greatest] = (g, e) => {
    let name = if e.has("ignore_nulls") {
      "GREATEST_IGNORE_NULLS"
    } else {
      "GREATEST"
    }
    g.func(
      name,
      [e.this(), ..e.expressions().map(x => (Some(x) : &@core.SqlArg))],
    )
  }
  m[Least] = (g, e) => {
    let name = if e.has("ignore_nulls") {
      "LEAST_IGNORE_NULLS"
    } else {
      "LEAST"
    }
    g.func(
      name,
      [e.this(), ..e.expressions().map(x => (Some(x) : &@core.SqlArg))],
    )
  }
  m[Generator] = generator_sql
  m[Unnest] = unnest_sql
  m[Undrop] = undrop_sql
  m[Show] = show_sql
  m[RowAccessProperty] = rowaccessproperty_sql
  m[Describe] = describe_sql
  m[GeneratedAsIdentityColumnConstraint] = generatedasidentitycolumnconstraint_sql
  m[Struct] = struct_sql
  m[ApproxQuantile] = (g, e) => {
    g.unsupported_args(e, ["weight", "accuracy"])
    g.func("APPROX_PERCENTILE", [e.this(), e.arg("quantile")])
  }
  m[AlterSet] = alterset_sql
  m[StrToTime] = strtotime_sql
  m[TimestampSub] = (g, e) => {
    let expression = e
      .expression()
      .map(x => @core.exp_binop(Mul, x, @core.literal_number("-1")))
    g.sql(
      Some(
        @core.mk(TimestampAdd, [
          ("this", e.this()),
          ("expression", expression),
          ("unit", e.arg("unit")),
        ]),
      ),
    )
  }
  m[JSONExtract] = jsonextract_sql
  m[TimeToStr] = (g, e) => {
    let mut this = e.this()
    if this is Some(t) && t.is_string() {
      this = Some(@core.exp_cast(t, TIMESTAMP))
    }
    g.func("TO_CHAR", [this, g.format_time(e)])
  }
  m[DateSub] = (g, e) => {
    match e.expression() {
      Some(value) =>
        value.replace(
          Some(@core.exp_binop(Mul, value, @core.literal_number("-1"))),
        )
        |> ignore
      None =>
        g.unsupported(
          "DateSub cannot be transpiled if the subtracted count is unknown",
        )
    }
    @core.date_delta_sql("DATEADD")(g, e)
  }
  m[Select] = (g, e) => {
    if e.has("offset") && !e.has("limit") {
      e.limit_(@core.null_()) |> ignore
    }
    g.select_sql(e)
  }
  h.createable_sql = Some(createable_sql)
  m[ArrayAgg] = arrayagg_sql
  m[ArrayDistinct] = (g, e) => {
    if e.has("check_null") {
      g.func("ARRAY_DISTINCT", [e.this()])
    } else {
      g.func("ARRAY_DISTINCT", [@core.mk1(ArrayCompact, e.this())])
    }
  }
  m[ArrayToString] = (g, e) => {
    g.func("ARRAY_TO_STRING", [e.this(), e.expression()])
  }
  m[Array] = array_sql
  m[CurrentDate] = currentdate_sql
  m[Dot] = dot_sql
  m[ModelAttribute] = (g, e) => {
    "\{g.sql_key(e, "this")}!\{g.sql_key(e, "expression")}"
  }
  m[Format] = (g, e) => {
    if @core.py_lower(e.name()) == "%s" && e.expressions().length() == 1 {
      g.func("TO_CHAR", [e.expressions()[0]])
    } else {
      g.function_fallback_sql(e)
    }
  }
  m[SplitPart] = (g, e) => {
    // Set part_index to 1 if missing
    if !e.has("delimiter") {
      e.set("delimiter", @core.literal_string(" "))
    }
    if !e.has("part_index") {
      e.set("part_index", @core.literal_number("1"))
    }
    @core.rename_func("SPLIT_PART")(g, e)
  }
  m[Uniform] = (g, e) => {
    let mut gen = e.arg("gen")
    let seed = e.arg("seed")
    // From Databricks UNIFORM(min, max, seed) -> Wrap gen in RANDOM(seed)
    if seed is Some(s) {
      gen = Some(@core.mk1(Rand, s))
    }
    // No gen argument (from Databricks 2-arg UNIFORM(min, max)) -> Add RANDOM()
    if gen is None {
      gen = Some(@core.mk0(Rand))
    }
    g.func("UNIFORM", [e.this(), e.expression(), gen])
  }
  m[Window] = window_sql
  m[Filter] = filter_sql
  m[WithinGroup] = withingroup_sql
}

///|
fn dynamicidentifier_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.func("IDENTIFIER", [e.this()])
  if e.has_key("expressions") {
    // `IDENTIFIER(...)` invoked as a function, e.g. `IDENTIFIER('my_func')(1, 2)`
    return g.func(
      this,
      e.expressions().map(x => (x : &@core.SqlArg)),
      normalize=false,
    )
  }
  this
}

///|
fn sortarray_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let asc = e.arg("asc")
  let mut nulls_first = e.arg("nulls_first")
  let is_bool = (x : @core.Expr?, b : Bool) => {
    match x {
      Some(v) => v.kind == Boolean && v.bool_arg("this") == b
      None => false
    }
  }
  if is_bool(asc, false) && is_bool(nulls_first, true) {
    nulls_first = None
  }
  g.func("ARRAY_SORT", [e.this(), asc, nulls_first])
}

///|
fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Check if this is a FLOAT type nested inside a VECTOR type
  // VECTOR only accepts FLOAT (not DOUBLE), INT, and STRING as element types
  // https://docs.snowflake.com/en/sql-reference/data-types-vector
  if e.is_type([DOUBLE]) {
    match e.parent {
      Some(p) if p.kind.is_a(DataType) && p.is_type([VECTOR]) => return "FLOAT"
      _ => ()
    }
  }
  let expressions = e.expressions()
  if !expressions.is_empty() && e.is_type(@core.dtype_struct_types) {
    for field_type in expressions {
      // The correct syntax is OBJECT [ (<key> <value_type [NOT NULL] [, ...]) ]
      if field_type.kind.is_a(DataType) {
        return "OBJECT"
      }
      if field_type.kind == ColumnDef {
        match field_type.this() {
          Some(t) if t.is_string() =>
            // Doing OBJECT('foo' VARCHAR) is invalid snowflake Syntax. Moreover, besides
            // converting 'foo' into an identifier, we also need to quote it because these
            // keys are case-sensitive.
            t.replace(Some(@core.to_identifier(field_type.name(), quoted=true)))
            |> ignore
          _ => ()
        }
      }
    }
  }
  g.datatype_sql(e)
}

///|
fn tonumber_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut precision = e.arg("precision")
  let mut scale = e.arg("scale")
  let default_precision = match precision {
    Some(p) => p.kind == Literal && p.name() == "38"
    None => false
  }
  let default_scale = match scale {
    Some(s) => s.kind == Literal && s.name() == "0"
    None => false
  }
  if default_precision && default_scale {
    precision = None
    scale = None
  } else if default_scale {
    scale = None
  }
  let func_name = if e.has("safe") { "TRY_TO_NUMBER" } else { "TO_NUMBER" }
  g.func(func_name, [e.this(), e.arg("format"), precision, scale])
}

///|
fn timestampfromparts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.arg("milli") {
    Some(milli) => {
      let milli_to_nano = @core.exp_binop(
        Mul,
        milli.pop(),
        @core.literal_number("1000000"),
      )
      e.set("nano", milli_to_nano)
    }
    None => ()
  }
  @core.rename_func("TIMESTAMP_FROM_PARTS")(g, e)
}

///|
fn trycast_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut value = e.this_()
  if value.get_type() is None {
    value = @core.gen_annotate_types(value, g.dialect)
  }
  // Snowflake requires that TRY_CAST's value be a string
  // If TRY_CAST is being roundtripped (since Snowflake is the only dialect that sets "requires_string") or
  // if we can deduce that the value is a string, then we can generate TRY_CAST
  if e.has("requires_string") || value.is_type(@core.dtype_text_types) {
    return g.trycast_sql(e)
  }
  g.cast_sql_v(e)
}

///|
fn generator_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let args : Array[&@core.SqlArg] = []
  match e.arg("rowcount") {
    Some(rowcount) =>
      args.push(
        @core.mk(Kwarg, [
          ("this", @core.var_("ROWCOUNT")),
          ("expression", rowcount),
        ]),
      )
    None => ()
  }
  match e.arg("timelimit") {
    Some(timelimit) =>
      args.push(
        @core.mk(Kwarg, [
          ("this", @core.var_("TIMELIMIT")),
          ("expression", timelimit),
        ]),
      )
    None => ()
  }
  g.func("GENERATOR", args)
}

///|
fn unnest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut unnest_alias = e.arg("alias")
  let offset = e.arg("offset")
  let unnest_alias_columns = match unnest_alias {
    Some(a) => a.list("columns")
    None => []
  }
  let value = match unnest_alias_columns.get(0) {
    Some(v) => v
    None => @core.to_identifier("value")
  }
  let columns = [
    @core.to_identifier("seq"),
    @core.to_identifier("key"),
    @core.to_identifier("path"),
    match offset {
      Some(o) => o.pop()
      None => @core.to_identifier("index")
    },
    value,
    @core.to_identifier("this"),
  ]
  match unnest_alias {
    Some(a) => a.set("columns", columns)
    None =>
      unnest_alias = Some(
        @core.mk(TableAlias, [("this", "_u"), ("columns", columns)]),
      )
  }
  let mut table_input = g.sql(e.expressions().get(0))
  if !table_input.has_prefix("INPUT =>") {
    table_input = "INPUT => \{table_input}"
  }
  let expression_parent = e.parent
  let explode = if opt_kind_is(expression_parent, [Lateral]) {
    "FLATTEN(\{table_input})"
  } else {
    "TABLE(FLATTEN(\{table_input}))"
  }
  let alias_sql = g.sql(unnest_alias)
  let alias_sql = if alias_sql != "" { " AS \{alias_sql}" } else { "" }
  let value_sql = if opt_kind_is(expression_parent, [From, Join, Lateral]) {
    ""
  } else {
    "\{@core.expr_to_sql(value)} FROM "
  }
  "\{value_sql}\{explode}\{alias_sql}"
}

///|
fn undrop_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let kind = e.text("kind")
  let rename = g.sql_key(e, "rename")
  let rename = if rename != "" { " RENAME TO \{rename}" } else { "" }
  "UNDROP \{kind} \{this}\{rename}"
}

///|
fn show_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let terse = if e.has("terse") { "TERSE " } else { "" }
  let iceberg = if e.has("iceberg") { "ICEBERG " } else { "" }
  let history = if e.has("history") { " HISTORY" } else { "" }
  let like = g.sql_key(e, "like")
  let like = if like != "" { " LIKE \{like}" } else { "" }
  let scope = g.sql_key(e, "scope")
  let scope = if scope != "" { " \{scope}" } else { "" }
  let scope_kind = g.sql_key(e, "scope_kind")
  let scope_kind = if scope_kind != "" { " IN \{scope_kind}" } else { "" }
  let starts_with = g.sql_key(e, "starts_with")
  let starts_with = if starts_with != "" {
    " STARTS WITH \{starts_with}"
  } else {
    ""
  }
  let limit = g.sql_key(e, "limit")
  let from_ = g.sql_key(e, "from_")
  let from_ = if from_ != "" { " FROM \{from_}" } else { "" }
  let privileges = g.expressions(expression=e, key="privileges", flat=true)
  let privileges = if privileges != "" {
    " WITH PRIVILEGES \{privileges}"
  } else {
    ""
  }
  "SHOW \{terse}\{iceberg}\{e.name()}\{history}\{like}\{scope_kind}\{scope}\{starts_with}\{limit}\{from_}\{privileges}"
}

///|
fn rowaccessproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if !e.has("this") {
    return "ROW ACCESS"
  }
  let on = if !e.expressions().is_empty() {
    " ON (\{g.expressions(expression=e, flat=true)})"
  } else {
    ""
  }
  "WITH ROW ACCESS POLICY \{g.sql_key(e, "this")}\{on}"
}

///|
fn describe_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let kind_value = match e.get("kind") {
    Some(v) if v.truthy() => g.sql_value(v)
    _ => "TABLE"
  }
  let kind = match e.arg("properties") {
    Some(properties) => {
      let qualifier = g.expressions(expression=properties, sep=" ")
      " \{qualifier} \{kind_value}"
    }
    None => " \{kind_value}"
  }
  let this = " \{g.sql_key(e, "this")}"
  let expressions = g.expressions(expression=e, flat=true)
  let expressions = if expressions != "" { " \{expressions}" } else { "" }
  "DESCRIBE\{kind}\{this}\{expressions}"
}

///|
fn py_str_value(v : @core.Value) -> String raise @core.SqlglotError {
  match v {
    Node(x) => @core.expr_to_sql(x)
    Str(s) => s
    Int(i) => i.to_string()
    Bool(b) => if b { "True" } else { "False" }
    _ => ""
  }
}

///|
fn generatedasidentitycolumnconstraint_sql(
  _g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let start = match e.get("start") {
    Some(v) if v.truthy() => " START \{py_str_value(v)}"
    _ => ""
  }
  let increment = match e.get("increment") {
    Some(v) if v.truthy() => " INCREMENT \{py_str_value(v)}"
    _ => ""
  }
  let order_clause = match e.get("order") {
    Some(v) => if v.truthy() { " ORDER" } else { " NOORDER" }
    None => ""
  }
  "AUTOINCREMENT\{start}\{increment}\{order_clause}"
}

///|
fn struct_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let exprs = e.expressions()
  if exprs.length() == 1 {
    let arg = exprs[0]
    if arg.is_star() ||
      (arg.kind == ILike && arg.this() is Some(l) && l.is_star()) {
      // Wildcard syntax: https://docs.snowflake.com/en/sql-reference/data-types-semistructured#object
      return "{\{g.sql(Some(arg))}}"
    }
  }
  let args : Array[&@core.SqlArg] = []
  for i, x in exprs {
    if x.kind == PropertyEQ {
      let key = match x.this() {
        Some(t) if t.kind == Identifier => Some(@core.literal_string(x.name()))
        other => other
      }
      args.push(key)
      args.push(x.expression())
    } else {
      args.push(@core.literal_string("_\{i}"))
      args.push(x)
    }
  }
  g.func("OBJECT_CONSTRUCT", args)
}

///|
fn alterset_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let exprs = g.expressions(expression=e, flat=true)
  let exprs = if exprs != "" { " \{exprs}" } else { "" }
  let file_format = g.expressions(
    expression=e,
    key="file_format",
    flat=true,
    sep=" ",
  )
  let file_format = if file_format != "" {
    " STAGE_FILE_FORMAT = (\{file_format})"
  } else {
    ""
  }
  let copy_options = g.expressions(
    expression=e,
    key="copy_options",
    flat=true,
    sep=" ",
  )
  let copy_options = if copy_options != "" {
    " STAGE_COPY_OPTIONS = (\{copy_options})"
  } else {
    ""
  }
  let tag = g.expressions(expression=e, key="tag", flat=true)
  let tag = if tag != "" { " TAG \{tag}" } else { "" }
  "SET\{exprs}\{file_format}\{copy_options}\{tag}"
}

///|
fn strtotime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // target_type is stored as a DataType instance
  let type_enum = match e.arg("target_type") {
    Some(t) if t.kind.is_a(DataType) => t.datatype_this()
    _ =>
      match e.get_type() {
        Some(t) => t.datatype_this()
        None => Some(@core.DType::TIMESTAMP)
      }
  }
  let func_name = match type_enum {
    Some(dt) =>
      match timestamp_type_func(dt) {
        Some(n) => n
        None => "TO_TIMESTAMP"
      }
    None => "TO_TIMESTAMP"
  }
  g.func(try_prefix(e) + func_name, [e.this(), g.format_time(e)])
}

///|
fn jsonextract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this()
  // JSON strings are valid coming from other dialects such as BQ so
  // for these cases we PARSE_JSON preemptively
  if !opt_kind_is(this, [ParseJSON, JSONExtract]) && !e.has("requires_json") {
    this = Some(@core.mk1(ParseJSON, this))
  }
  g.func("GET_PATH", [this, e.expression()])
}

///|
fn createable_sql(
  g : @core.Generator,
  e : @core.Expr,
  locations : @core.PropLocs,
) -> String raise @core.SqlglotError {
  let is_materialized = e.find([MaterializedProperty])
  let copy_grants_property = e.find([CopyGrantsProperty])
  if e.text("kind") == "VIEW" &&
    is_materialized is Some(_) &&
    copy_grants_property is Some(cgp) {
    // For materialized views, COPY GRANTS is located *before* the columns list
    // This is in contrast to normal views where COPY GRANTS is located *after* the columns list
    // We default CopyGrantsProperty to POST_SCHEMA which means we need to output it POST_NAME if a materialized view is detected
    // ref: https://docs.snowflake.com/en/sql-reference/sql/create-materialized-view#syntax
    // ref: https://docs.snowflake.com/en/sql-reference/sql/create-view#syntax
    match locations.get(PostSchema) {
      Some(post_schema_properties) =>
        for i, p in post_schema_properties {
          if physical_equal(p, cgp) {
            post_schema_properties.remove(i) |> ignore
            break
          }
        }
      None => ()
    }
    let this = e.this_()
    let this_name = g.sql_key(this, "this")
    let copy_grants = g.sql(Some(cgp))
    let this_schema = g.schema_columns_sql(this)
    let this_schema = if this_schema != "" {
      "\{g.sep()}\{this_schema}"
    } else {
      ""
    }
    return "\{this_name}\{g.sep()}\{copy_grants}\{this_schema}"
  }
  g.createable_sql_base(e, locations)
}

///|
fn arrayagg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // If an ORDER BY clause is present, we need to remove it from ARRAY_AGG
  // and add it later as part of the WITHIN GROUP clause
  let order = match e.this() {
    Some(t) if t.kind.is_a(Order) => Some(t)
    _ => None
  }
  if order is Some(o) {
    e.set("this", o.this().map(x => x.pop()))
  }
  let mut expr_sql = g.arrayagg_sql(e)
  if order is Some(o) {
    expr_sql = g.sql(
      Some(@core.mk(WithinGroup, [("this", expr_sql), ("expression", o)])),
    )
  }
  expr_sql
}

///|
fn array_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let expressions = e.expressions()
  match expressions.get(0) {
    Some(first_expr) if first_expr.kind == Select &&
      @core.py_upper(first_expr.text("kind")) == "STRUCT" => {
      // SELECT AS STRUCT foo AS alias_foo -> ARRAY_AGG(OBJECT_CONSTRUCT('alias_foo', foo))
      let object_construct_args = []
      for expr in first_expr.expressions() {
        // Alias case: SELECT AS STRUCT foo AS alias_foo -> OBJECT_CONSTRUCT('alias_foo', foo)
        // Column case: SELECT AS STRUCT foo -> OBJECT_CONSTRUCT('foo', foo)
        let name = if expr.kind.is_a(Alias) { expr.this_() } else { expr }
        object_construct_args.push(@core.literal_string(expr.alias_or_name()))
        object_construct_args.push(name)
      }
      let array_agg = @core.mk1(
        ArrayAgg,
        build_object_construct(object_construct_args),
      )
      first_expr.set("kind", (None : @core.Expr?))
      first_expr.set("expressions", [array_agg])
      return g.sql(Some(first_expr.subquery()))
    }
    _ => ()
  }
  @core.inline_array_sql(g, e)
}

///|
fn currentdate_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let zone = g.sql_key(e, "this")
  if zone == "" {
    return g.currentdate_sql(e)
  }
  let expr = @core.mk(Cast, [
    (
      "this",
      @core.mk(ConvertTimezone, [
        ("target_tz", zone),
        ("timestamp", @core.mk0(CurrentTimestamp)),
      ]),
    ),
    ("to", @core.mk1(DataType, @core.DType::DATE)),
  ])
  g.sql(Some(expr))
}

///|
fn dot_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this_()
  if this.get_type() is None {
    this = @core.gen_annotate_types(this, g.dialect)
  }
  if this.kind != Dot && this.is_type([STRUCT]) {
    // Generate colon notation for the top level STRUCT
    return "\{g.sql(Some(this))}:\{g.sql_key(e, "expression")}"
  }
  g.dot_sql(e)
}

///|
fn window_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let spec = e.arg("spec")
  let this = e.this()
  let ranking = is_ranking_with_frame(this) ||
    (
      opt_kind_is(this, [RespectNulls, IgnoreNulls]) &&
      is_ranking_with_frame(this.unwrap().this())
    )
  match spec {
    Some(s) if ranking &&
      @core.py_upper(s.text("kind")) == "ROWS" &&
      @core.py_upper(s.text("start")) == "UNBOUNDED" &&
      @core.py_upper(s.text("start_side")) == "PRECEDING" &&
      @core.py_upper(s.text("end")) == "UNBOUNDED" &&
      @core.py_upper(s.text("end_side")) == "FOLLOWING" =>
      // omit the default window from window ranking functions
      e.set("spec", (None : @core.Expr?))
    _ => ()
  }
  g.window_sql(e)
}

///|
fn wrap_in_if(target : @core.Expr, cond : @core.Expr) -> Unit {
  target.replace(
    Some(@core.mk(If, [("this", cond.copy()), ("true", target.copy())])),
  )
  |> ignore
}

///|
fn filter_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Snowflake doesn't support FILTER (WHERE cond), so we rewrite it into an
  // equivalent conditional aggregation, i.e. wrap the input values in an IFF
  let agg = e.this_()
  let mut agg_arg = if agg.kind == Anonymous {
    agg.expressions().get(0)
  } else {
    agg.this()
  }
  let cond = e.expression_().this_()
  if agg.kind == WithinGroup {
    // Ordered-set aggregates take their input from the ORDER BY key, so the
    // condition has to wrap that instead of the aggregate's own argument
    if opt_kind_is(agg_arg, [Mode, PercentileCont, PercentileDisc]) {
      match agg.expression() {
        Some(order) =>
          for ordered in order.expressions() {
            match ordered.this() {
              Some(key) => wrap_in_if(key, cond)
              None => ()
            }
          }
        None => ()
      }
      return g.sql(Some(agg))
    }
    // Besides the percentile functions, these are the only functions Snowflake
    // accepts WITHIN GROUP for, so anything else can't be rewritten correctly
    if opt_kind_is(agg_arg, [ArrayAgg, GroupConcat]) {
      agg_arg = agg_arg.unwrap().this()
    } else {
      g.unsupported("Unable to rewrite FILTER into the aggregate's arguments")
      return g.sql(Some(agg))
    }
  }
  // `COUNT(*/t.*) FILTER (WHERE cond)` counts qualifying rows, but a star can't be an IFF
  // argument. Use its native COUNT_IF instead.
  if agg.kind == Count && agg_arg is Some(a) && a.is_star() {
    return g.func("COUNT_IF", [cond])
  }
  // `DISTINCT` and `ORDER BY` are part of the aggregate's own argument list, so the
  // condition has to wrap the values underneath them rather than the whole clause
  if agg_arg is Some(a) && a.kind.is_a(Order) {
    agg_arg = a.this()
  }
  let targets = match agg_arg {
    Some(a) if a.kind == Distinct => a.expressions()
    Some(a) => [a]
    None => []
  }
  for target in targets {
    wrap_in_if(target, cond)
  }
  g.sql(Some(agg))
}

///|
fn withingroup_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Snowflake's MODE doesn't support the ordered-set syntax, i.e. it only
  // accepts the value to aggregate as an argument: MODE(<expr>)
  match e.this() {
    Some(t) if t.kind == Mode && !t.has("this") =>
      match e.expression() {
        Some(order) if order.kind.is_a(Order) &&
          order.expressions().length() == 1 =>
          return g.sql(Some(@core.mk1(Mode, order.expressions()[0].this())))
        _ => ()
      }
    _ => ()
  }
  g.withingroup_sql(e)
}
