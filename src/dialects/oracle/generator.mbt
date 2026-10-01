// Port of sqlglot/generators/oracle.py

///|
fn trim_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let position = @core.py_upper(e.text("position"))
  if position == "LEADING" || position == "TRAILING" {
    return g.trim_sql(e)
  }
  @core.trim_sql(g, e)
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let cfg = d.gen_cfg
  cfg.type_mapping[BLOB] = "BLOB"
  cfg.type_mapping[TINYINT] = "SMALLINT"
  cfg.type_mapping[SMALLINT] = "SMALLINT"
  cfg.type_mapping[INT] = "INT"
  cfg.type_mapping[BIGINT] = "INT"
  cfg.type_mapping[DECIMAL] = "NUMBER"
  cfg.type_mapping[DOUBLE] = "DOUBLE PRECISION"
  cfg.type_mapping[VARCHAR] = "VARCHAR2"
  cfg.type_mapping[NVARCHAR] = "NVARCHAR2"
  cfg.type_mapping[NCHAR] = "NCHAR"
  cfg.type_mapping[TEXT] = "CLOB"
  cfg.type_mapping[TIMETZ] = "TIME"
  cfg.type_mapping[TIMESTAMPNTZ] = "TIMESTAMP"
  cfg.type_mapping[TIMESTAMPTZ] = "TIMESTAMP"
  cfg.type_mapping[BINARY] = "BLOB"
  cfg.type_mapping[VARBINARY] = "BLOB"
  cfg.type_mapping[ROWVERSION] = "BLOB"
  d.hooks.can_quote = Some((dialect, identifier, identify) => {
    // Disable quoting for pseudocolumns as it may break queries e.g
    // `WHERE "ROWNUM" = ...` does not work but `WHERE ROWNUM = ...` does
    let not_pseudo = match identifier.parent {
      Some(p) => p.kind != Pseudocolumn
      None => true
    }
    (identifier.has("quoted") || not_pseudo) &&
    dialect.can_quote_base(identifier, identify~)
  })
  let t = d.gen_fns.transforms
  t[Pivot] = @core.preprocess([@core.unqualify_pivot_fields])
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e, on_overflow=true)
  t[DateStrToDate] = (g, e) => {
    g.func("TO_DATE", [e.this(), Some(@core.literal_string("YYYY-MM-DD"))])
  }
  t[DateTrunc] = (g, e) => g.func("TRUNC", [e.this(), e.arg("unit")])
  t[EuclideanDistance] = @core.rename_func("L2_DISTANCE")
  t[ILike] = @core.no_ilike_sql
  t[LogicalOr] = @core.rename_func("MAX")
  t[LogicalAnd] = @core.rename_func("MIN")
  t[Mod] = @core.rename_func("MOD")
  t[NthValue] = @core.nth_value_from_sql
  t[Rand] = @core.rename_func("DBMS_RANDOM.VALUE")
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.eliminate_qualify,
  ])
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(
      g,
      e,
      func_name="INSTR",
      supports_position=true,
      supports_occurrence=true,
    )
  }
  t[StrToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), g.format_time(e)])
  t[StrToDate] = (g, e) => g.func("TO_DATE", [e.this(), g.format_time(e)])
  t[Subquery] = (g, e) => g.subquery_sql(e, sep=" ")
  t[Substring] = @core.rename_func("SUBSTR")
  t[Table] = (g, e) => g.table_sql(e, sep=" ")
  t[TableSample] = (g, e) => g.tablesample_sql(e)
  t[TemporaryProperty] = (_, e) => {
    let name = e.name()
    "\{if name != "" { name } else { "GLOBAL" }} TEMPORARY"
  }
  t[TimeToStr] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[ToChar] = (g, e) => g.function_fallback_sql(e)
  t[Trim] = trim_sql
  t[Unicode] = (g, e) => "ASCII(UNISTR(\{g.sql(e.this())}))"
  t[UnixToTime] = (g, e) => {
    "TO_DATE('1970-01-01', 'YYYY-MM-DD') + (\{g.sql_key(e, "this")} / 86400)"
  }
  t[UtcTimestamp] = @core.rename_func("UTC_TIMESTAMP")
  t[UtcTime] = @core.rename_func("UTC_TIME")
  t[Systimestamp] = (_, _) => "SYSTIMESTAMP"
  let m = d.gen_fns.methods
  m[CurrentTimestamp] = (g, e) => {
    if e.has("sysdate") {
      return "SYSDATE"
    }
    match e.this() {
      Some(this) => g.func("CURRENT_TIMESTAMP", [this])
      None => "CURRENT_TIMESTAMP"
    }
  }
  m[Offset] = (g, e) => "\{g.offset_sql(e)} ROWS"
  let h = d.gen_fns.hooks
  h.add_column_sql = Some((g, e) => "ADD \{g.sql(Some(e))}")
  m[QueryOption] = (g, e) => {
    let option = g.sql_key(e, "this")
    let value = g.sql_key(e, "expression")
    let value = if value != "" { " CONSTRAINT \{value}" } else { "" }
    "\{option}\{value}"
  }
  m[Coalesce] = (g, e) => {
    let func_name = if e.has("is_nvl") { "NVL" } else { "COALESCE" }
    @core.rename_func(func_name)(g, e)
  }
  m[Into] = (g, e) => {
    let into = if !e.has("bulk_collect") { "INTO" } else { "BULK COLLECT INTO" }
    if e.this() is Some(_) {
      return "\{g.seg(into)} \{g.sql_key(e, "this")}"
    }
    "\{g.seg(into)} \{g.expressions(expression=e)}"
  }
  m[Hint] = (g, e) => {
    let expressions : Array[@core.Value] = []
    for value in e.raw_list("expressions") {
      match value {
        Node(hint) if hint.kind == Anonymous => {
          let args : Array[&@core.SqlArg] = hint
            .expressions()
            .map(x => x as &@core.SqlArg)
          let formatted_args = g.format_args(args, sep=" ")
          expressions.push(Str("\{g.sql_key(hint, "this")}(\{formatted_args})"))
        }
        v => expressions.push(Str(g.sql_value(v)))
      }
    }
    let body = @core.py_strip(
      g.expressions(sqls=expressions, sep=g.cfg.query_hint_sep),
    )
    " /*+ \{body} */"
  }
  m[IsAscii] = (g, e) => {
    "NVL(REGEXP_LIKE(\{g.sql(e.this())}, '^[' || CHR(1) || '-' || CHR(127) || ']*$'), TRUE)"
  }
  m[Interval] = (g, e) => {
    let prefix = match e.this() {
      Some(t) if t.kind == Literal => "INTERVAL "
      _ => ""
    }
    "\{prefix}\{g.sql_key(e, "this")} \{g.sql_key(e, "unit")}"
  }
  m[ToNumber] = (g, e) => {
    let mut this = g.sql_key(e, "this")
    let default = g.sql_key(e, "default")
    if default != "" {
      this = "\{this} DEFAULT \{default} ON CONVERSION ERROR"
    }
    g.func("TO_NUMBER", [Some(this), e.arg("format"), e.arg("nlsparam")])
  }
  h.columndef_sql = Some((g, e, sep) => {
    let mut sep = sep
    match e.find([InOutColumnConstraint]) {
      Some(param_constraint) => {
        sep = " \{g.sql(Some(param_constraint))} "
        param_constraint.pop() |> ignore
      }
      None => ()
    }
    g.columndef_sql(e, sep~)
  })
}
