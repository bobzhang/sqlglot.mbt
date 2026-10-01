// Port of sqlglot/generators/drill.py

///|
/// `Drill.DATE_FORMAT`
let drill_date_format : String = "'yyyy-MM-dd'"

///|
/// `Drill.DATEINT_FORMAT`
let drill_dateint_format : String = "'yyyyMMdd'"

///|
/// Python `sqlglot.generators.mysql.date_add_sql(kind)`.
fn date_add_sql(kind : String) -> @core.GenFn {
  (g, e) => {
    g.func("DATE_\{kind}", [
      e.this(),
      @core.mk(Interval, [
        ("this", e.expression()),
        ("unit", @core.unit_to_var(e)),
      ]),
    ])
  }
}

///|
fn str_to_date(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let time_format = g.format_time(e)
  if time_format == Some(drill_date_format) {
    return g.sql(Some(@core.exp_cast(@core.parse_one(this), DATE)))
  }
  g.func("TO_DATE", [this, time_format])
}

///|
fn ilike_func_sql(
  g : @core.Generator,
  e : @core.Expr,
  escape : @core.Expr?,
) -> String raise @core.SqlglotError {
  let ilike = g.func("ILIKE", [e.this(), e.expression(), escape])
  if e.has("negate") {
    "NOT \{ilike}"
  } else {
    ilike
  }
}

///|
fn is_quantified(e : @core.Expr) -> Bool {
  match e.expression() {
    Some(x) => x.kind.is_any([All, Any])
    None => false
  }
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
  t[CurrentTimestamp] = (_, _) => "CURRENT_TIMESTAMP"
  t[ArrayContains] = @core.rename_func("REPEATED_CONTAINS")
  t[Create] = @core.preprocess([@core.move_schema_columns_to_partitioned_by])
  t[DateAdd] = date_add_sql("ADD")
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateSub] = date_add_sql("SUB")
  t[DateToDi] = (g, e) => {
    "CAST(TO_DATE(\{g.sql_key(e, "this")}, \{drill_dateint_format}) AS INT)"
  }
  t[DiToDate] = (g, e) => {
    "TO_DATE(CAST(\{g.sql_key(e, "this")} AS VARCHAR), \{drill_dateint_format})"
  }
  t[If] = (g, e) => {
    "`IF`(\{g.format_args([e.this(), e.arg("true"), e.arg("false")])})"
  }
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("LEVENSHTEIN_DISTANCE")(g, e)
  }
  t[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  t[RegexpLike] = @core.rename_func("REGEXP_MATCHES")
  t[StrToDate] = str_to_date
  t[Pow] = @core.rename_func("POW")
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.eliminate_semi_and_anti_joins,
  ])
  t[StrPosition] = (g, e) => @core.strposition_sql(g, e)
  t[StrToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), g.format_time(e)])
  t[TimeStrToDate] = (g, e) => {
    g.sql(Some(@core.exp_cast(e.this().unwrap(), DATE)))
  }
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeStrToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[TimeToStr] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[TimeToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[ToChar] = (g, e) => g.function_fallback_sql(e)
  t[TryCast] = @core.no_trycast_sql
  t[TsOrDsAdd] = (g, e) => {
    let interval = @core.mk(Interval, [
      ("this", e.expression()),
      ("unit", @core.var_("DAY")),
    ])
    "DATE_ADD(CAST(\{g.sql_key(e, "this")} AS DATE), \{g.sql(Some(interval))})"
  }
  t[TsOrDiToDi] = (g, e) => {
    "CAST(SUBSTR(REPLACE(CAST(\{g.sql_key(e, "this")} AS VARCHAR), '-', ''), 1, 8) AS INT)"
  }
  let m = d.gen_fns.methods
  m[ILike] = (g, e) => {
    if is_quantified(e) {
      g.ilike_sql(e)
    } else {
      ilike_func_sql(g, e, None)
    }
  }
  m[Escape] = (g, e) => {
    // Drill takes the escape character as ILIKE's third argument instead of an ESCAPE clause
    match e.this() {
      Some(this) if this.kind.is_a(ILike) && !is_quantified(this) =>
        ilike_func_sql(g, this, e.expression())
      _ => g.escape_sql(e)
    }
  }
}
