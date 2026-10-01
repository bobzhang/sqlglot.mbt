// Port of sqlglot/generators/spark2.py

///|
fn json_format_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this().unwrap()
  if @core.is_parse_json(this) {
    let inner = this.this().unwrap()
    if inner.is_string() {
      // Since FROM_JSON requires a nested type, we always wrap the json string with
      // an array to ensure that "naked" strings like "'a'" will be handled correctly
      let wrapped_json = @core.literal_string("[\{inner.name()}]")
      let from_json = g.func("FROM_JSON", [
        wrapped_json,
        g.func("SCHEMA_OF_JSON", [wrapped_json]),
      ])
      let to_json = g.func("TO_JSON", [from_json])
      // This strips the [, ] delimiters of the dummy array printed by TO_JSON
      return g.func("REGEXP_EXTRACT", [to_json, "'^.(.*).$'", "1"])
    }
    return g.sql(Some(this))
  }
  g.func("TO_JSON", [Some(this), e.arg("options")])
}

///|
fn map_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let keys = e.get("keys")
  let values = e.get("values")
  match (keys, values) {
    (Some(k), Some(v)) if k.truthy() && v.truthy() =>
      g.func("MAP_FROM_ARRAYS", [k, v])
    _ => g.func("MAP", [])
  }
}

///|
fn str_to_date(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let time_format = g.format_time(e)
  if time_format == Some(@hive.hive_date_format) {
    return g.func("TO_DATE", [e.this()])
  }
  g.func("TO_DATE", [e.this(), time_format])
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let timestamp = e.this().unwrap()
  match e.arg("scale") {
    None =>
      g.sql(
        Some(
          @core.exp_cast(@core.func_("from_unixtime", [timestamp]), TIMESTAMP),
        ),
      )
    Some(scale) =>
      if scale == @core.literal_int(0) {
        g.func("TIMESTAMP_SECONDS", [timestamp])
      } else if scale == @core.literal_int(3) {
        g.func("TIMESTAMP_MILLIS", [timestamp])
      } else if scale == @core.literal_int(6) {
        g.func("TIMESTAMP_MICROS", [timestamp])
      } else {
        let unix_seconds = @core.mk2(
          Div,
          timestamp,
          @core.func_("POW", [@core.literal_int(10), scale]),
        )
        g.func("TIMESTAMP_SECONDS", [unix_seconds])
      }
  }
}

///|
/// Spark doesn't allow PIVOT aliases, so we need to remove them and possibly wrap a
/// pivoted source in a subquery with the same alias to preserve the query's semantics.
fn unalias_pivot(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == From && expression.this() is Some(this) {
    let pivots = this.list("pivots")
    if !pivots.is_empty() {
      let pivot = pivots[0]
      if pivot.alias_() != "" {
        let alias_ = pivot.arg("alias").unwrap().pop()
        let sub = @core.exp_subquery_with_alias_expr(
          @core.select_([@core.mk0(Star)]).from_(this.copy(), copy=false),
          Some(alias_),
          copy=false,
        )
        return @core.mk1(From, this.replace(Some(sub)))
      }
    }
  }
  expression
}

///|
/// spark2, spark, Databricks require a storage provider for temporary tables
pub fn temporary_storage_provider(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let provider = @core.mk1(FileFormatProperty, @core.literal_string("parquet"))
  expression.arg("properties").unwrap().append("expressions", provider)
  expression
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  @hive.register_ts_or_ds_expressions(
    "spark2",
    [
      ..@hive.hive_ts_or_ds_expressions,
      DayOfMonth,
      DayOfWeek,
      DayOfYear,
      WeekOfYear,
    ],
  )
  let t = d.gen_fns.transforms
  t[ApproxDistinct] = @core.rename_func("APPROX_COUNT_DISTINCT")
  t[ArraySum] = (g, e) => {
    "AGGREGATE(\{g.sql_key(e, "this")}, 0, (acc, x) -> acc + x, acc -> acc)"
  }
  t[ArrayToString] = @core.rename_func("ARRAY_JOIN")
  t[ArraySlice] = @core.rename_func("SLICE")
  t[AtTimeZone] = (g, e) => {
    g.func("FROM_UTC_TIMESTAMP", [e.this(), e.arg("zone")])
  }
  t[BitwiseLeftShift] = @core.rename_func("SHIFTLEFT")
  t[BitwiseRightShift] = @core.rename_func("SHIFTRIGHT")
  t[Create] = @core.preprocess([
    @core.remove_unique_constraints,
    @core.ctas_with_tmp_tables_to_create_tmp_view(
      tmp_storage_provider=temporary_storage_provider,
    ),
    @core.move_schema_columns_to_partitioned_by,
  ])
  t[DateFromParts] = @core.rename_func("MAKE_DATE")
  t[DateTrunc] = (g, e) => {
    g.func("TRUNC", [e.this(), @core.weekstart_unit_to_str(g, e)])
  }
  t[DayOfMonth] = @core.rename_func("DAYOFMONTH")
  t[DayOfWeek] = @core.rename_func("DAYOFWEEK")
  // (DAY_OF_WEEK(datetime) % 7) + 1 is equivalent to DAYOFWEEK_ISO(datetime)
  t[DayOfWeekIso] = (g, e) => "((\{g.func("DAYOFWEEK", [e.this()])} % 7) + 1)"
  t[DayOfYear] = @core.rename_func("DAYOFYEAR")
  t[Format] = @core.rename_func("FORMAT_STRING")
  t[From] = @core.preprocess([unalias_pivot])
  t[FromTimeZone] = (g, e) => {
    g.func("TO_UTC_TIMESTAMP", [e.this(), e.arg("zone")])
  }
  t[JSONFormat] = json_format_sql
  t[LogicalAnd] = @core.rename_func("BOOL_AND")
  t[LogicalOr] = @core.rename_func("BOOL_OR")
  t[Map] = map_sql
  t[Pivot] = @core.preprocess([@core.unqualify_pivot_fields])
  t[Reduce] = @core.rename_func("AGGREGATE")
  t[RegexpReplace] = (g, e) => {
    g.func("REGEXP_REPLACE", [
      e.this(),
      e.expression(),
      e.arg("replacement"),
      e.arg("position"),
    ])
  }
  t[Select] = @core.preprocess([
    @core.eliminate_qualify,
    @core.eliminate_distinct_on,
    @core.unnest_to_explode(),
    @core.any_to_exists,
  ])
  t[SHA2Digest] = (g, e) => {
    let length = match e.arg("length") {
      Some(l) => l
      None => @core.literal_int(256)
    }
    g.func("SHA2", [e.this(), Some(length)])
  }
  t[StrToDate] = str_to_date
  t[StrToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), g.format_time(e)])
  t[TimestampTrunc] = @core.timestamptrunc_sql()
  t[UnixToTime] = unix_to_time_sql
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[WeekOfYear] = @core.rename_func("WEEKOFYEAR")
  t[WithinGroup] = @core.preprocess([@core.remove_within_group_for_percentiles])
  t.remove(ArraySort)
  t.remove(ILike)
  t.remove(Left)
  t.remove(MonthsBetween)
  t.remove(Right)
  let m = d.gen_fns.methods
  let base = @hive.dialect().parent.unwrap().gen_fns
  // Generator.struct_sql (skipping HiveGenerator.struct_sql)
  restore_method(m, base.methods, Struct)
  // super(HiveGenerator, self).cast_sql: the grandparent (base) implementation.
  let base_cast = base.hooks.cast_sql
  d.gen_fns.hooks.cast_sql = Some((g, e, safe_prefix) => {
    cast_sql(g, e, safe_prefix, base_cast)
  })
  let parent_fileformat = m.get(FileFormatProperty)
  m[FileFormatProperty] = (g, e) => {
    if e.has("hive_format") {
      match parent_fileformat {
        Some(f) => f(g, e)
        None => g.call_method(FileFormatProperty, e)
      }
    } else {
      "USING \{@core.py_upper(e.name())}"
    }
  }
  base_altercolumn.val = base.methods.get(AlterColumn)
  m[AlterColumn] = altercolumn_sql
  // super(HiveGenerator, self).renamecolumn_sql
  restore_method(m, base.methods, RenameColumn)
  let parent_bracket = m.get(Bracket)
  m[Bracket] = (g, e) => {
    if e.get("safe") is Some(Bool(false)) {
      return @core.bracket_to_element_at_sql(g, e)
    }
    match parent_bracket {
      Some(f) => f(g, e)
      None => g.bracket_sql(e)
    }
  }
}

///|
/// Python `super(HiveGenerator, self).<key>_sql`: reinstates the grandparent's method.
fn restore_method(
  m : Map[@core.Kind, @core.GenFn],
  base : Map[@core.Kind, @core.GenFn],
  kind : @core.Kind,
) -> Unit {
  match base.get(kind) {
    Some(f) => m[kind] = f
    None => m.remove(kind)
  }
}

///|
fn cast_sql(
  g : @core.Generator,
  e : @core.Expr,
  safe_prefix : String?,
  base_cast : ((@core.Generator, @core.Expr, String?) -> String raise @core.SqlglotError)?,
) -> String raise @core.SqlglotError {
  let arg = e.this().unwrap()
  let to = e.arg("to").unwrap()
  let to_exprs = to.expressions()
  if arg.kind == Literal &&
    arg.is_number() &&
    to.is_type([DECIMAL]) &&
    to_exprs.length() == 2 &&
    to_exprs[1].this() is Some(n) &&
    n.kind == Neg {
    // Spark 2 supports negative scales in literals, but not in DECIMAL type syntax.
    return "\{g.sql(Some(arg))}BD"
  }
  let is_json_extract = arg.kind.is_any([JSONExtract, JSONExtractScalar]) &&
    !arg.has("variant_extract")
  // We can't use a non-nested type (eg. STRING) as a schema
  if to.has("nested") && (@core.is_parse_json(arg) || is_json_extract) {
    let schema = "'\{g.sql_key(e, "to")}'"
    return g.func("FROM_JSON", [
      if is_json_extract {
        Some(arg)
      } else {
        arg.this()
      },
      schema,
    ])
  }
  if @core.is_parse_json(e) {
    return g.func("TO_JSON", [arg])
  }
  match base_cast {
    Some(f) => f(g, e, safe_prefix)
    None => g.cast_sql(e, safe_prefix?)
  }
}

///|
let base_altercolumn : Ref[@core.GenFn?] = Ref(None)

///|
fn altercolumn_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("exists") {
    g.unsupported("ALTER COLUMN IF EXISTS is not supported by this dialect")
  }
  let this = g.sql_key(e, "this")
  let new_name = match g.sql_key(e, "rename_to") {
    "" => this
    s => s
  }
  let comment = g.sql_key(e, "comment")
  if new_name == this {
    if comment != "" {
      return "ALTER COLUMN \{this} COMMENT \{comment}"
    }
    // super(HiveGenerator, self).altercolumn_sql
    return match base_altercolumn.val {
      Some(f) => f(g, e)
      None => g.altercolumn_sql(e)
    }
  }
  "RENAME COLUMN \{this} TO \{new_name}"
}
