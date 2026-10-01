// Port of sqlglot/generators/spark.py

///|
/// Normalize the expressions in PARTITION BY (<expression>, <expression>, ...)
fn normalize_partition(e : @core.Expr) -> @core.Expr {
  if e.kind == Literal {
    return @core.to_identifier(e.name())
  }
  e
}

///|
fn dateadd_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if !e.has("unit") ||
    (e.kind == TsOrDsAdd && @core.py_upper(e.text("unit")) == "DAY") {
    // Coming from Hive/Spark2 DATE_ADD or roundtripping the 2-arg version of Spark3/DB
    return g.func("DATE_ADD", [e.this(), e.expression()])
  }
  let mut this = g.func("DATE_ADD", [
    @core.unit_to_var(e),
    e.expression(),
    e.this(),
  ])
  if e.kind == TsOrDsAdd {
    // The 3 arg version of DATE_ADD produces a timestamp in Spark3/DB but possibly not
    // in other dialects
    let return_type = @core.ts_or_ds_add_return_type(e)
    if !return_type.is_type([TIMESTAMP, DATETIME]) {
      this = "CAST(\{this} AS \{@core.expr_to_sql(return_type)})"
    }
  }
  this
}

///|
fn groupconcat_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if g.dialect.version.0 < 4 {
    let separator = match e.arg("separator") {
      Some(s) => s
      None => @core.literal_string("")
    }
    let expr = @core.mk(ArrayToString, [
      ("this", @core.mk1(ArrayAgg, e.this())),
      ("expression", separator),
    ])
    return g.sql(Some(expr))
  }
  @core.groupconcat_sql(g, e)
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let cfg = d.gen_cfg
  cfg.type_mapping[MONEY] = "DECIMAL"
  cfg.type_mapping[SMALLMONEY] = "DECIMAL"
  cfg.type_mapping[UUID] = "STRING"
  cfg.type_mapping[TIMESTAMPLTZ] = "TIMESTAMP_LTZ"
  cfg.type_mapping[TIMESTAMPNTZ] = "TIMESTAMP_NTZ"
  d.gen_fns.type_param_settings[MONEY] = ([15, 4], [])
  d.gen_fns.type_param_settings[SMALLMONEY] = ([6, 4], [])
  let t = d.gen_fns.transforms
  t[ArrayConstructCompact] = (g, e) => {
    g.func("ARRAY_COMPACT", [g.func("ARRAY", e.expressions().map(x => x))])
  }
  t[ArrayAppend] = @core.array_append_sql("ARRAY_APPEND")
  t[ArrayPrepend] = @core.array_append_sql("ARRAY_PREPEND")
  t[BitwiseAndAgg] = @core.rename_func("BIT_AND")
  t[BitwiseOrAgg] = @core.rename_func("BIT_OR")
  t[BitwiseXorAgg] = @core.rename_func("BIT_XOR")
  t[BitwiseCount] = @core.rename_func("BIT_COUNT")
  t[Create] = @core.preprocess([
    @core.remove_unique_constraints,
    @core.ctas_with_tmp_tables_to_create_tmp_view(
      tmp_storage_provider=@spark2.temporary_storage_provider,
    ),
    @core.move_partitioned_by_to_schema_columns,
  ])
  t[CurrentVersion] = @core.rename_func("VERSION")
  t[DateFromUnixDate] = @core.rename_func("DATE_FROM_UNIX_DATE")
  t[DatetimeAdd] = @core.date_delta_to_binary_interval_op(cast=false)
  t[DatetimeSub] = @core.date_delta_to_binary_interval_op(cast=false)
  t[GroupConcat] = groupconcat_sql
  t[EndsWith] = @core.rename_func("ENDSWITH")
  t[JSONKeys] = @core.rename_func("JSON_OBJECT_KEYS")
  t[PartitionedByProperty] = (g, e) => {
    let sqls : Array[@core.Value] = e
      .this()
      .unwrap()
      .expressions()
      .map(x => Node(normalize_partition(x)))
    "PARTITIONED BY \{g.wrap_str(g.expressions(sqls~, skip_first=true))}"
  }
  t[SafeAdd] = @core.rename_func("TRY_ADD")
  t[SafeDivide] = @core.rename_func("TRY_DIVIDE")
  t[SafeMultiply] = @core.rename_func("TRY_MULTIPLY")
  t[SafeSubtract] = @core.rename_func("TRY_SUBTRACT")
  t[StartsWith] = @core.rename_func("STARTSWITH")
  t[StabilityProperty] = (_, e) => {
    if e.name() == "IMMUTABLE" {
      "DETERMINISTIC"
    } else {
      "NOT DETERMINISTIC"
    }
  }
  t[TimeAdd] = @core.date_delta_to_binary_interval_op(cast=false)
  t[TimeSub] = @core.date_delta_to_binary_interval_op(cast=false)
  t[TsOrDsAdd] = dateadd_sql
  t[TimestampAdd] = dateadd_sql
  t[TimestampFromParts] = @core.rename_func("MAKE_TIMESTAMP")
  t[TimestampSub] = @core.date_delta_to_binary_interval_op(cast=false)
  t[DatetimeDiff] = @core.timestampdiff_sql
  t[TimestampDiff] = @core.timestampdiff_sql
  t[TryCast] = (g, e) => {
    if e.has("safe") {
      g.call_method(TryCast, e)
    } else {
      g.cast_sql_v(e)
    }
  }
  t.remove(AnyValue)
  t.remove(DateDiff)
  t.remove(With)
  let m = d.gen_fns.methods
  // generator.Generator.ignorenulls_sql
  match @core.base_dialect().gen_fns.methods.get(IgnoreNulls) {
    Some(f) => m[IgnoreNulls] = f
    None => m.remove(IgnoreNulls)
  }
  let hooks = d.gen_fns.hooks
  let parent_arrayinsert = hooks.arrayinsert_sql
  hooks.arrayinsert_sql = Some((g, e, _index_offset) => {
    match parent_arrayinsert {
      Some(f) => f(g, e, 1)
      None => g.arrayinsert_sql(e, index_offset=1)
    }
  })
  let parent_bracket = m.get(Bracket)
  m[Bracket] = (g, e) => {
    if e.has("safe") {
      let key = g.bracket_offset_expressions(e, index_offset=1).get(0)
      return g.func("TRY_ELEMENT_AT", [e.this(), key])
    }
    match parent_bracket {
      Some(f) => f(g, e)
      None => g.bracket_sql(e)
    }
  }
  m[ComputedColumnConstraint] = (g, e) => {
    "GENERATED ALWAYS AS (\{g.sql_key(e, "this")})"
  }
  m[AnyValue] = (g, e) => g.function_fallback_sql(e)
  m[DateDiff] = datediff_sql
  let parent_placeholder = m.get(Placeholder)
  m[Placeholder] = (g, e) => {
    if !e.has("widget") {
      return match parent_placeholder {
        Some(f) => f(g, e)
        None => g.placeholder_sql(e)
      }
    }
    "{\{e.name()}}"
  }
  m[ReadParquet] = (g, e) => {
    let exprs = e.expressions()
    if exprs.length() != 1 {
      g.unsupported("READ_PARQUET with multiple arguments is not supported")
      return ""
    }
    "parquet.`\{exprs[0].name()}`"
  }
  let parent_ifblock = m.get(IfBlock)
  m[IfBlock] = (g, e) => {
    match ifblock_drop(g, e) {
      Some(s) => s
      None =>
        match parent_ifblock {
          Some(f) => f(g, e)
          None => g.ifblock_sql(e)
        }
    }
  }
}

///|
fn datediff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let end = g.sql_key(e, "this")
  let start = g.sql_key(e, "expression")
  if e.has("unit") {
    return g.func("DATEDIFF", [@core.unit_to_var(e), start, end])
  }
  g.func("DATEDIFF", [end, start])
}

///|
fn ifblock_drop(
  g : @core.Generator,
  e : @core.Expr,
) -> String? raise @core.SqlglotError {
  let condition = e.this()
  let true_block = e.arg("true")
  let mut condition_expr : @core.Expr? = None
  match condition {
    Some(c) if c.kind == Not =>
      match c.this() {
        Some(inner) if inner.kind == Is &&
          inner.expression() is Some(n) &&
          n.kind == Null => condition_expr = inner.this()
        _ => ()
      }
    _ => ()
  }
  match condition_expr {
    Some(ce) if ce.kind == ObjectId => {
      let object_type = ce.expression()
      let type_ok = match object_type {
        None => true
        Some(o) => @core.py_upper(o.name()) == "U"
      }
      match true_block {
        Some(tb) if type_ok && tb.kind == Block => {
          let exprs = tb.expressions()
          if !exprs.is_empty() && exprs[0].kind == Drop {
            let drop = exprs[0]
            drop.set("exists", true)
            return Some(g.sql(Some(drop)))
          }
        }
        _ => ()
      }
    }
    _ => ()
  }
  None
}
