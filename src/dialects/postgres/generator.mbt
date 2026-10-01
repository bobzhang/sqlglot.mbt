// Port of sqlglot/generators/postgres.py

///|
fn date_diff_factor(unit : String) -> String? {
  match unit {
    "MICROSECOND" => Some(" * 1000000")
    "MILLISECOND" => Some(" * 1000")
    "SECOND" => Some("")
    "MINUTE" => Some(" / 60")
    "HOUR" => Some(" / 3600")
    "DAY" => Some(" / 86400")
    _ => None
  }
}

///|
/// Python `to_py()` rendered as a string, for number expressions.
fn number_to_py_str(e : @core.Expr) -> String {
  match e.to_py_int() {
    Some(v) => v.to_string()
    None =>
      match e.kind {
        Neg => "-" + e.this().unwrap().name()
        _ => e.name()
      }
  }
}

///|
pub fn date_add_sql(kind : String) -> @core.GenFn {
  (g, e) => {
    let e = if e.kind == TsOrDsAdd { @core.ts_or_ds_add_cast(e) } else { e }
    let this = g.sql_key(e, "this")
    let unit = e.arg("unit")
    let mut v = g.simplify_unless_literal(e.expression().unwrap())
    if v.kind.is_a(Interval) {
      return "\{this} \{kind} \{g.sql(Some(v))}"
    } else if v.kind.is_a(Literal) {
      v.set("is_string", true)
    } else if v.is_number() {
      v = @core.literal_string(number_to_py_str(v))
    } else {
      let one = @core.literal_number("1")
      let interval_times_value = @core.exp_binop(
        Mul,
        @core.mk(Interval, [("this", one), ("unit", unit)]),
        v,
      )
      return "\{this} \{kind} \{g.sql(Some(interval_times_value))}"
    }
    "\{this} \{kind} \{g.sql(Some(@core.mk(Interval, [("this", v), ("unit", unit)])))}"
  }
}

///|
fn day_month_year_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this().unwrap()
  let value = if this.kind.is_a(TsOrDsToDate) {
    this.this().unwrap()
  } else {
    this
  }
  if value.is_type(@core.dtype_integer_types) {
    match this.arg("default_date") {
      Some(default_date) =>
        this = @core.exp_add(@core.exp_cast(default_date, DATE), value)
      None => ()
    }
  }
  g.sql(
    Some(
      @core.mk(Extract, [
        ("this", @core.var_(e.kind.sql_names()[0])),
        ("expression", this),
      ]),
    ),
  )
}

///|
pub fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut unit = @core.py_upper(e.text("unit"))
  if unit == "" {
    unit = "DAY"
  }
  // Dialects like MySQL count crossed day boundaries, which maps to DATE subtraction
  if unit == "DAY" && e.has("date_part_boundary") {
    let this = @core.exp_cast(e.this().unwrap(), DATE)
    let expr = @core.exp_cast(e.expression().unwrap(), DATE)
    return g.sql(Some(@core.exp_paren(@core.exp_binop(Sub, this, expr))))
  }
  let factor = date_diff_factor(unit)
  let end = "CAST(\{g.sql_key(e, "this")} AS TIMESTAMP)"
  let start = "CAST(\{g.sql_key(e, "expression")} AS TIMESTAMP)"
  match factor {
    Some(f) =>
      return "CAST(EXTRACT(epoch FROM \{end} - \{start})\{f} AS BIGINT)"
    None => ()
  }
  let age = "AGE(\{end}, \{start})"
  let unit = match unit {
    "WEEK" => "EXTRACT(days FROM (\{end} - \{start})) / 7"
    "MONTH" => "EXTRACT(year FROM \{age}) * 12 + EXTRACT(month FROM \{age})"
    "QUARTER" =>
      "EXTRACT(year FROM \{age}) * 4 + EXTRACT(month FROM \{age}) / 3"
    "YEAR" => "EXTRACT(year FROM \{age})"
    _ => age
  }
  "CAST(\{unit} AS BIGINT)"
}

///|
fn substring_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let start = g.sql_key(e, "start")
  let length = g.sql_key(e, "length")
  let from_part = if start != "" { " FROM \{start}" } else { "" }
  let for_part = if length != "" { " FOR \{length}" } else { "" }
  "SUBSTRING(\{this}\{from_part}\{for_part})"
}

///|
fn remove_equal(list : Array[@core.Value], node : @core.Expr) -> Unit {
  for i, v in list {
    if v is Node(e) && e == node {
      list.remove(i) |> ignore
      return
    }
  }
}

///|
fn contains_equal(list : Array[@core.Expr], node : @core.Expr) -> Bool {
  for e in list {
    if e == node {
      return true
    }
  }
  false
}

///|
fn auto_increment_to_serial(expression : @core.Expr) -> @core.Expr {
  match expression.find([AutoIncrementColumnConstraint]) {
    Some(auto) => {
      remove_equal(expression.raw_list("constraints"), auto.parent.unwrap())
      let kind = expression.arg("kind").unwrap()
      let new_type : @core.DType? = match kind.datatype_this() {
        Some(INT) => Some(SERIAL)
        Some(SMALLINT) => Some(SMALLSERIAL)
        Some(BIGINT) => Some(BIGSERIAL)
        _ => None
      }
      match new_type {
        Some(t) => kind.replace(Some(@core.datatype_of(t))) |> ignore
        None => ()
      }
    }
    None => ()
  }
  expression
}

///|
fn serial_to_generated(expression : @core.Expr) -> @core.Expr {
  guard expression.kind == ColumnDef else { return expression }
  guard expression.arg("kind") is Some(kind) else { return expression }
  let data_type : @core.DType? = match kind.datatype_this() {
    Some(SERIAL) => Some(INT)
    Some(SMALLSERIAL) => Some(SMALLINT)
    Some(BIGSERIAL) => Some(BIGINT)
    _ => None
  }
  match data_type {
    Some(dt) => {
      kind.replace(Some(@core.datatype_of(dt))) |> ignore
      let constraints = expression.list("constraints")
      let generated = @core.mk(ColumnConstraint, [
        ("kind", @core.mk1(GeneratedAsIdentityColumnConstraint, false)),
      ])
      let notnull = @core.mk(ColumnConstraint, [
        ("kind", @core.mk0(NotNullColumnConstraint)),
      ])
      let mut new_constraints = constraints
      if !contains_equal(new_constraints, notnull) {
        new_constraints = [notnull, ..new_constraints]
      }
      if !contains_equal(new_constraints, generated) {
        new_constraints = [generated, ..new_constraints]
      }
      expression.set("constraints", new_constraints)
    }
    None => ()
  }
  expression
}

///|
fn json_extract_sql(name : String, op : String) -> @core.GenFn {
  (g, e) => {
    let path = e.expression().unwrap()
    // Single non-literal segment: render as infix, not JSON_EXTRACT_PATH[_TEXT] (jsonb-unsafe).
    if !path.kind.is_any([JSONPath, Variadic]) && !e.has("expressions") {
      return @core.arrow_json_extract_sql(g, e, op~)
    }
    // JSON_EXTRACT_PATH requires a key, so use an empty variadic array for the root path
    let path_exprs = path.expressions()
    if path_exprs.length() == 1 && path_exprs[0].kind.is_a(JSONPathRoot) {
      e.set("expression", @core.mk1(Variadic, @core.literal_string("{}")))
    }
    if e.has("only_json_types") {
      @core.json_extract_segments(name, quoted_index=false, op~)(g, e)
    } else {
      @core.json_extract_segments(name)(g, e)
    }
  }
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let timestamp = e.this()
  match scale {
    None => g.func("TO_TIMESTAMP", [timestamp, g.format_time(e)])
    Some(s) if s == @core.literal_number("0") =>
      g.func("TO_TIMESTAMP", [timestamp, g.format_time(e)])
    Some(s) =>
      g.func("TO_TIMESTAMP", [
        @core.mk(Div, [
          ("this", timestamp),
          ("expression", @core.func_("POW", [@core.literal_number("10"), s])),
        ]),
        g.format_time(e),
      ])
  }
}

///|
fn levenshtein_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let name = if e.has("max_dist") {
    "LEVENSHTEIN_LESS_EQUAL"
  } else {
    "LEVENSHTEIN"
  }
  @core.rename_func(name)(g, e)
}

///|
fn versioned_anyvalue_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // https://www.postgresql.org/docs/16/functions-aggregate.html
  // https://www.postgresql.org/about/featurematrix/
  let (major, _, _) = g.dialect.version
  if major < 16 {
    return @core.any_value_to_max_sql(g, e)
  }
  @core.rename_func("ANY_VALUE")(g, e)
}

///|
fn round_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = g.sql_key(e, "this")
  let decimals = g.sql_key(e, "decimals")
  if decimals == "" {
    return g.func("ROUND", [this])
  }
  let e = if e.get_type() is None {
    @core.gen_annotate_types(e, g.dialect)
  } else {
    e
  }
  // ROUND(double precision, integer) is not permitted in Postgres
  // so it's necessary to cast to decimal before rounding.
  if e.this().unwrap().is_type([DOUBLE]) {
    let decimal_type = @core.mk(DataType, [
      ("this", @core.DType::DECIMAL),
      ("expressions", e.expressions()),
    ])
    this = g.sql(Some(@core.mk(Cast, [("this", this), ("to", decimal_type)])))
  }
  g.func("ROUND", [this, decimals])
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  // (the module-level table: only WINDOW and QUALIFY)
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
  let t = d.gen_fns.transforms
  t.remove(CommentColumnConstraint)
  t[AnyValue] = versioned_anyvalue_sql
  t[ArrayConcat] = @core.array_concat_sql("ARRAY_CAT")
  t[ArrayFilter] = @core.filter_array_using_unnest
  t[ArrayAppend] = @core.array_append_sql("ARRAY_APPEND")
  t[ArrayPrepend] = @core.array_append_sql("ARRAY_PREPEND", swap_params=true)
  t[BitwiseAndAgg] = @core.rename_func("BIT_AND")
  t[BitwiseOrAgg] = @core.rename_func("BIT_OR")
  t[BitwiseXor] = (g, e) => g.binary(e, "#")
  t[BitwiseXorAgg] = @core.rename_func("BIT_XOR")
  t[ColumnDef] = @core.preprocess([
    e => auto_increment_to_serial(e),
    e => serial_to_generated(e),
  ])
  t[CurrentDate] = @core.no_paren_current_date_sql
  t[CurrentTimestamp] = (_, _) => "CURRENT_TIMESTAMP"
  t[CurrentUser] = (_, _) => "CURRENT_USER"
  t[CurrentVersion] = @core.rename_func("VERSION")
  t[DateAdd] = date_add_sql("+")
  t[DateDiff] = date_diff_sql
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateSub] = date_add_sql("-")
  t[Day] = day_month_year_sql
  t[Explode] = @core.rename_func("UNNEST")
  t[ExplodingGenerateSeries] = @core.rename_func("GENERATE_SERIES")
  t[GenerateSeries] = @core.generate_series_sql("GENERATE_SERIES")
  t[Getbit] = @core.getbit_sql
  t[GroupConcat] = (g, e) => {
    @core.groupconcat_sql(g, e, func_name="STRING_AGG", within_group=false)
  }
  t[IntDiv] = @core.rename_func("DIV")
  t[JSONArrayAgg] = (g, e) => {
    g.func(
      "JSON_AGG",
      [g.sql_key(e, "this")],
      suffix="\{g.sql_key(e, "order")})",
    )
  }
  t[JSONExtract] = json_extract_sql("JSON_EXTRACT_PATH", "->")
  t[JSONExtractScalar] = json_extract_sql("JSON_EXTRACT_PATH_TEXT", "->>")
  t[JSONBExtract] = (g, e) => @core.arrow_json_extract_sql(g, e, op="#>")
  t[JSONBExtractScalar] = (g, e) => @core.arrow_json_extract_sql(g, e, op="#>>")
  t[ParseJSON] = (g, e) => g.sql(Some(@core.exp_cast(e.this().unwrap(), JSON)))
  t[JSONPathKey] = @core.json_path_key_only_name
  t[JSONPathRoot] = (_, _) => ""
  t[JSONPathSubscript] = (g, e) => g.json_path_part(e.get("this"))
  t[LastDay] = @core.no_last_day_sql
  t[LogicalOr] = @core.rename_func("BOOL_OR")
  t[LogicalAnd] = @core.rename_func("BOOL_AND")
  t[Max] = @core.max_or_greatest
  t[MapFromEntries] = @core.no_map_from_entries_sql
  t[Min] = @core.min_or_least
  t[Merge] = @core.merge_without_target_sql
  t[Month] = day_month_year_sql
  t[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  t[PercentileCont] = @core.preprocess([@core.add_within_group_for_percentiles])
  t[PercentileDisc] = @core.preprocess([@core.add_within_group_for_percentiles])
  t[Pivot] = @core.no_pivot_sql
  t[Rand] = @core.rename_func("RANDOM")
  t[RegexpLike] = (g, e) => g.binary(e, "~")
  t[RegexpILike] = (g, e) => g.binary(e, "~*")
  t[RegexpReplace] = (g, e) => {
    g.func("REGEXP_REPLACE", [
      e.this(),
      e.expression(),
      e.arg("replacement"),
      e.arg("position"),
      e.arg("occurrence"),
      @core.regexp_replace_global_modifier(e),
    ])
  }
  t[Round] = round_sql
  t[Select] = @core.preprocess([
    @core.eliminate_semi_and_anti_joins, @core.eliminate_qualify,
  ])
  t[SHA2] = @core.sha256_sql
  t[SHA2Digest] = @core.sha2_digest_sql
  t[StrPosition] = (g, e) => @core.strposition_sql(g, e, func_name="POSITION")
  t[StrToDate] = (g, e) => g.func("TO_DATE", [e.this(), g.format_time(e)])
  t[StrToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), g.format_time(e)])
  t[StructExtract] = @core.struct_extract_sql
  t[Substring] = substring_sql
  t[TimeFromParts] = @core.rename_func("MAKE_TIME")
  t[TimestampFromParts] = @core.rename_func("MAKE_TIMESTAMP")
  t[TimestampTrunc] = @core.timestamptrunc_sql(zone=true)
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeToStr] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[ToChar] = (g, e) => {
    if e.has("format") {
      g.function_fallback_sql(e)
    } else {
      g.tochar_sql(e)
    }
  }
  t[Trim] = (g, e) => @core.trim_sql(g, e)
  t[TryCast] = @core.no_trycast_sql
  t[TsOrDsAdd] = date_add_sql("+")
  t[TsOrDsDiff] = date_diff_sql
  t[Uuid] = (_, _) => "GEN_RANDOM_UUID()"
  t[TimeToUnix] = (g, e) => {
    g.func("DATE_PART", [@core.literal_string("epoch"), e.this()])
  }
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[Variance] = @core.rename_func("VAR_SAMP")
  t[Xor] = @core.bool_xor_sql
  t[Year] = day_month_year_sql
  t[Unicode] = @core.rename_func("ASCII")
  t[UnixToTime] = unix_to_time_sql
  t[Levenshtein] = levenshtein_sql
  t[JSONObjectAgg] = @core.rename_func("JSON_OBJECT_AGG")
  t[JSONBObjectAgg] = @core.rename_func("JSONB_OBJECT_AGG")
  t[CountIf] = @core.count_if_to_sum
  // `<key>_sql` method overrides
  let m = d.gen_fns.methods
  let parent_lateral = m.get(Lateral)
  m[Lateral] = (g, e) => {
    let mut sql = match parent_lateral {
      Some(f) => f(g, e)
      None => g.lateral_sql(e)
    }
    if e.get("cross_apply") is Some(_) {
      sql = "\{sql} ON TRUE"
    }
    sql
  }
  m[SchemaCommentProperty] = (g, _) => {
    g.unsupported("Table comments are not supported in the CREATE statement")
    ""
  }
  m[CommentColumnConstraint] = (g, _) => {
    g.unsupported("Column comments are not supported in the CREATE statement")
    ""
  }
  let hooks = d.gen_fns.hooks
  let parent_columndef = hooks.columndef_sql
  hooks.columndef_sql = Some((g, e, sep) => {
    let base = (g : @core.Generator, e : @core.Expr) => {
      match parent_columndef {
        Some(f) => f(g, e, sep)
        None => g.columndef_sql(e, sep~)
      }
    }
    // PostgreSQL places parameter modes BEFORE parameter name
    match e.find([InOutColumnConstraint]) {
      Some(param_constraint) => {
        let mode_sql = g.sql(Some(param_constraint))
        param_constraint.pop() |> ignore // Remove to prevent double-rendering
        let base_sql = base(g, e)
        "\{mode_sql} \{base_sql}"
      }
      None => base(g, e)
    }
  })
  let parent_unnest = m.get(Unnest)
  m[Unnest] = (g, e) => {
    match unnest_sql(g, e) {
      Some(s) => s
      None =>
        match parent_unnest {
          Some(f) => f(g, e)
          None => g.unnest_sql(e)
        }
    }
  }
  let parent_bracket = m.get(Bracket)
  m[Bracket] = (g, e) => {
    // Forms like ARRAY[1, 2, 3][3] aren't allowed; we need to wrap the ARRAY.
    match e.this() {
      Some(this) if this.kind.is_a(Array) =>
        e.set("this", @core.exp_paren(this, copy=false))
      _ => ()
    }
    match parent_bracket {
      Some(f) => f(g, e)
      None => g.bracket_sql(e)
    }
  }
  m[MatchAgainst] = (g, e) => {
    let this = g.sql_key(e, "this")
    let expressions = e.expressions().map(x => "\{g.sql(Some(x))} @@ \{this}")
    let sql = expressions.join(" OR ")
    if expressions.length() > 1 {
      "(\{sql})"
    } else {
      sql
    }
  }
  m[AlterSet] = (g, e) => {
    let exprs = g.expressions(expression=e, flat=true)
    let exprs = if exprs != "" { "(\{exprs})" } else { "" }
    let access_method = g.sql_key(e, "access_method")
    let access_method = if access_method != "" {
      "ACCESS METHOD \{access_method}"
    } else {
      ""
    }
    let tablespace = g.sql_key(e, "tablespace")
    let tablespace = if tablespace != "" {
      "TABLESPACE \{tablespace}"
    } else {
      ""
    }
    let option = g.sql_key(e, "option")
    "SET \{exprs}\{access_method}\{tablespace}\{option}"
  }
  let parent_datatype = m.get(DataType)
  m[DataType] = (g, e) => {
    if e.is_type([ARRAY]) {
      if !e.expressions().is_empty() {
        let values = g.expressions(expression=e, key="values", flat=true)
        return "\{g.expressions(expression=e, flat=true)}[\{values}]"
      }
      return "ARRAY"
    }
    if e.is_type([ENUM]) {
      return "ENUM (\{g.expressions(expression=e, flat=true)})"
    }
    if e.is_type([DOUBLE, FLOAT]) && !e.expressions().is_empty() {
      // Postgres doesn't support precision for REAL and DOUBLE PRECISION types
      return "FLOAT(\{g.expressions(expression=e, flat=true)})"
    }
    match parent_datatype {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
  let parent_cast = hooks.cast_sql
  hooks.cast_sql = Some((g, e, safe_prefix) => {
    // Postgres casts DIV() to decimal for transpilation but when roundtripping it's superfluous
    match (e.this(), e.arg("to")) {
      (Some(this), Some(to)) if this.kind.is_a(IntDiv) &&
        to == @core.datatype_of(DECIMAL) => return g.sql(Some(this))
      _ => ()
    }
    match parent_cast {
      Some(f) => f(g, e, safe_prefix)
      None => g.cast_sql(e, safe_prefix?)
    }
  })
  m[Array] = (g, e) => {
    let exprs = e.expressions()
    let func_name = g.normalize_func("ARRAY")
    if exprs.length() > 0 && exprs[0].kind.is_a(Query) {
      return "\{func_name}(\{g.sql(Some(exprs[0]))})"
    }
    "\{func_name}\{@core.inline_array_sql(g, e)}"
  }
  m[ComputedColumnConstraint] = (g, e) => {
    "GENERATED ALWAYS AS (\{g.sql_key(e, "this")}) STORED"
  }
  m[IsAscii] = (g, e) => "(\{g.sql(e.this())} ~ '^[[:ascii:]]*$')"
  m[IgnoreNulls] = (g, e) => {
    // https://www.postgresql.org/docs/current/functions-window.html
    g.unsupported("PostgreSQL does not support IGNORE NULLS.")
    g.sql(e.this())
  }
  m[RespectNulls] = (g, e) => {
    // https://www.postgresql.org/docs/current/functions-window.html
    g.unsupported("PostgreSQL does not support RESPECT NULLS.")
    g.sql(e.this())
  }
  m[CurrentSchema] = (g, e) => {
    g.unsupported_args(e, ["this"])
    "CURRENT_SCHEMA"
  }
  let parent_interval = m.get(Interval)
  m[Interval] = (g, e) => {
    let unit = @core.py_lower(e.text("unit"))
    match e.this() {
      Some(this) if unit.has_prefix("quarter") && this.kind.is_a(Literal) => {
        let n = match this.to_py_int() {
          Some(v) => v
          None =>
            match @core.parse_int_str(this.name()) {
              Some(v) => v
              None => 0L
            }
        }
        this.replace(Some(@core.literal_string((n * 3L).to_string()))) |> ignore
        e.arg("unit").unwrap().replace(Some(@core.var_("MONTH"))) |> ignore
      }
      _ => ()
    }
    match parent_interval {
      Some(f) => f(g, e)
      None => g.interval_sql(e)
    }
  }
  m[Placeholder] = (g, e) => {
    if e.has("jdbc") {
      return "?"
    }
    let this = if e.has("this") { "(\{e.name()})" } else { "" }
    "\{g.cfg.named_placeholder_token}\{this}s"
  }
  m[ArrayContains] = (g, e) => {
    // Convert DuckDB's LIST_CONTAINS(array, value) to PostgreSQL:
    // CASE WHEN value IS NULL THEN NULL ELSE COALESCE(value = ANY(array), FALSE) END
    let value = e.expression().unwrap()
    let array = e.this().unwrap()
    let coalesce_expr = @core.mk(Coalesce, [
      (
        "this",
        @core.exp_eq(value, @core.mk1(Any, @core.exp_paren(array, copy=false))),
      ),
      ("expressions", [@core.false_()]),
    ])
    let case_expr = @core.case_else(
      @core.case_when(
        @core.exp_case(),
        @core.mk(Is, [("this", value), ("expression", @core.null_())]),
        @core.null_(),
        copy=false,
      ),
      coalesce_expr,
      copy=false,
    )
    g.sql(Some(case_expr))
  }
}

///|
/// The Postgres-specific part of `unnest_sql`; `None` means "defer to super()".
fn unnest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String? raise @core.SqlglotError {
  let exprs = e.expressions()
  if exprs.length() != 1 {
    return None
  }
  let arg = exprs[0]
  if arg.kind.is_a(GenerateDateArray) {
    let mut generate_series = @core.Expr::new(
      GenerateSeries,
      @core.Args::from_iter(arg.args.iter()),
    )
    match e.parent {
      Some(parent) if parent.kind.is_any([From, Join]) => {
        let table = @core.alias_table(@core.mk1(Table, generate_series), "_t", columns=[
          "value",
        ])
        let query = @core.select_([@core.parse_one("value::date")]).from_(table)
        generate_series = match e.arg("alias") {
          Some(a) => @core.exp_subquery_with_alias_expr(query, Some(a))
          None =>
            @core.exp_subquery_of(query, alias_="_unnested_generate_series")
        }
      }
      _ => ()
    }
    return Some(g.sql(Some(generate_series)))
  }
  let mut this = @core.gen_annotate_types(arg, g.dialect)
  if this.is_type_expr(@core.datatype_from_str("array<json>")) {
    while this.kind.is_a(Cast) {
      this = this.this().unwrap()
    }
    let arg_as_json = g.sql(Some(@core.exp_cast(this, JSON)))
    let alias_sql = g.sql_key(e, "alias")
    let alias_sql = if alias_sql != "" { " AS \{alias_sql}" } else { "" }
    if e.has("offset") {
      g.unsupported("Unsupported JSON_ARRAY_ELEMENTS with offset")
    }
    return Some("JSON_ARRAY_ELEMENTS(\{arg_as_json})\{alias_sql}")
  }
  None
}
