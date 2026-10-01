// Port of sqlglot/generators/tsql.py

///|
let date_part_unmapping : Map[String, String] = {
  "WEEKISO": "ISO_WEEK",
  "DAYOFWEEK": "WEEKDAY",
  "TIMEZONE_MINUTE": "TZOFFSET",
}

///|
let bit_types : Array[@core.Kind] = [EQ, NEQ, Is, In, Select, Alias]

///|
let set_op_modifiers : Array[String] = [
  "limit", "offset", "order", "for_", "options",
]

///|
/// `TSQL.INVERSE_TIME_MAPPING` (captured from the tsql dialect configuration).
let tsql_inverse_time_mapping : Ref[Map[String, String]] = Ref({})

///|
fn format_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let fmt = e.arg("format")
  let fmt_sql = if e.kind != NumberToStr {
    match fmt {
      Some(f) if f.is_string() => {
        let mapped_fmt = @core.format_time_opt(
          f.name(),
          tsql_inverse_time_mapping.val,
        ).unwrap_or("")
        g.sql(Some(@core.literal_string(mapped_fmt)))
      }
      _ =>
        match g.format_time(e) {
          Some(s) if s != "" => s
          _ => g.sql(fmt)
        }
    }
  } else {
    g.sql(fmt)
  }
  g.func("FORMAT", [e.this(), fmt_sql, e.arg("culture")])
}

///|
fn string_agg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = e.this()
  match @optimizer.find_in_scope(e, [Distinct]) {
    Some(distinct) => {
      // exp.Distinct can appear below an exp.Order or an exp.GroupConcat expression
      g.unsupported("T-SQL STRING_AGG doesn't support DISTINCT.")
      this = distinct.pop().expressions().get(0)
    }
    None => ()
  }
  let mut order = ""
  match e.this() {
    Some(o) if o.kind.is_a(Order) => {
      match o.this() {
        Some(t) => this = Some(t.pop())
        None => ()
      }
      // Order has a leading space
      let s = g.sql(Some(o))
      order = " WITHIN GROUP (\{s.unsafe_substring(start=1, end=s.length())})"
    }
    _ => ()
  }
  let separator = match e.arg("separator") {
    Some(s) => s
    None => @core.literal_string(",")
  }
  "STRING_AGG(\{g.format_args([this, Some(separator)])})\{order}"
}

///|
/// Ensures all (unnamed) output columns are aliased for CTEs and Subqueries.
pub fn qualify_derived_table_outputs(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let alias = expression.arg("alias")
  match alias {
    Some(a) if expression.kind.is_any([CTE, Subquery]) &&
      a.kind == TableAlias &&
      a.list("columns").is_empty() => {
      // We keep track of the unaliased column projection indexes instead of the expressions
      // themselves, because the latter are going to be replaced by new nodes when the aliases
      // are added and hence we won't be able to reach these newly added Alias parents
      guard expression.this() is Some(query) else { return expression }
      let unaliased_column_indexes : Array[Int] = []
      for i, c in query.selects() {
        if c.kind.is_a(Column) && c.alias() == "" {
          unaliased_column_indexes.push(i)
        }
      }
      @optimizer.qualify_outputs(query, dialect())
      // Preserve the quoting information of columns for newly added Alias nodes
      let query_selects = query.selects()
      for select_index in unaliased_column_indexes {
        let alias = query_selects[select_index]
        match alias.this() {
          Some(column) =>
            match column.this() {
              Some(ci) if ci.kind == Identifier =>
                alias.arg("alias").unwrap().set("quoted", ci.has("quoted"))
              _ => ()
            }
          None => ()
        }
      }
    }
    _ => ()
  }
  expression
}

///|
fn json_extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // JSON_QUERY returns objects and arrays, JSON_VALUE returns scalars. A scalar-only
  // extraction maps to JSON_VALUE; a source that also returns non-scalar values as
  // text (e.g. SQLite's ->>) needs to try both, like a generic JSONExtract does
  if e.kind == JSONExtractScalar && e.has("scalar_only") {
    return g.func("JSON_VALUE", [e.this(), e.expression()])
  }
  let json_query = g.func("JSON_QUERY", [e.this(), e.expression()])
  if e.has("json_query") {
    return json_query
  }
  let json_value = g.func("JSON_VALUE", [e.this(), e.expression()])
  g.func("ISNULL", [json_query, json_value])
}

///|
fn timestrtotime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let sql = @core.timestrtotime_sql(g, e)
  if e.has("zone") {
    // If there is a timezone, produce an expression like:
    // CAST('2020-01-01 12:13:14-08:00' AS DATETIMEOFFSET) AT TIME ZONE 'UTC'
    // If you dont have AT TIME ZONE 'UTC', wrapping that expression in another cast back to DATETIME2 just drops the timezone information
    return g.sql(
      Some(
        @core.mk(AtTimeZone, [
          ("this", @core.var_(sql)),
          ("zone", @core.literal_string("UTC")),
        ]),
      ),
    )
  }
  sql
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  tsql_inverse_time_mapping.val = d.cfg.inverse_time_mapping
  let t = d.gen_fns.transforms
  t.remove(ReturnsProperty)
  t[AnyValue] = @core.any_value_to_max_sql
  t[Atan2] = @core.rename_func("ATN2")
  t[ArrayToString] = @core.rename_func("STRING_AGG")
  t[AutoIncrementColumnConstraint] = (_, _) => "IDENTITY"
  t[Ceil] = @core.rename_func("CEILING")
  t[Chr] = @core.rename_func("CHAR")
  t[DateAdd] = @core.date_delta_sql("DATEADD")
  t[CTE] = @core.preprocess([qualify_derived_table_outputs])
  t[CurrentDate] = @core.rename_func("GETDATE")
  t[CurrentTimestamp] = @core.rename_func("GETDATE")
  t[CurrentTimestampLTZ] = @core.rename_func("SYSDATETIMEOFFSET")
  t[DateStrToDate] = @core.datestrtodate_sql
  t[Day] = @core.remove_ts_or_ds_to_date()
  t[GeneratedAsIdentityColumnConstraint] = @core.generatedasidentitycolumnconstraint_sql
  t[GroupConcat] = string_agg_sql
  t[If] = @core.rename_func("IIF")
  t[JSONExtract] = json_extract_sql
  t[JSONExtractScalar] = json_extract_sql
  t[LastDay] = (g, e) => g.func("EOMONTH", [e.this()])
  t[Ln] = @core.rename_func("LOG")
  t[Max] = @core.max_or_greatest
  t[MD5] = (g, e) => {
    g.func("HASHBYTES", [Some(@core.literal_string("MD5")), e.this()])
  }
  t[Min] = @core.min_or_least
  t[Month] = @core.remove_ts_or_ds_to_date()
  t[NumberToStr] = format_sql
  t[Repeat] = @core.rename_func("REPLICATE")
  t[CurrentSchema] = @core.rename_func("SCHEMA_NAME")
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.eliminate_semi_and_anti_joins, @core.eliminate_qualify,
    @core.unnest_generate_date_array_using_recursive_cte,
  ])
  t[Stddev] = @core.rename_func("STDEV")
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(g, e, func_name="CHARINDEX", supports_position=true)
  }
  t[Subquery] = @core.preprocess([qualify_derived_table_outputs])
  t[SHA] = (g, e) => {
    g.func("HASHBYTES", [Some(@core.literal_string("SHA1")), e.this()])
  }
  t[SHA1Digest] = (g, e) => {
    g.func("HASHBYTES", [Some(@core.literal_string("SHA1")), e.this()])
  }
  t[SHA2] = (g, e) => {
    let length = match e.arg("length") {
      Some(l) => g.sql(Some(l))
      None => "256"
    }
    g.func("HASHBYTES", [Some(@core.literal_string("SHA2_\{length}")), e.this()])
  }
  t[TemporaryProperty] = (_, _) => ""
  t[TimeStrToTime] = timestrtotime_sql
  t[TimeToStr] = format_sql
  t[TimestampAdd] = @core.date_delta_sql("DATEADD")
  t[Trim] = (g, e) => @core.trim_sql(g, e)
  t[TsOrDsAdd] = @core.date_delta_sql("DATEADD", cast=true)
  t[TsOrDsDiff] = @core.date_delta_sql("DATEDIFF")
  t[TimestampTrunc] = (g, e) => g.func("DATETRUNC", [e.arg("unit"), e.this()])
  t[Trunc] = (g, e) => {
    let decimals = match e.arg("decimals") {
      Some(dd) => dd
      None => @core.literal_number("0")
    }
    g.func("ROUND", [e.this(), Some(decimals), Some(@core.literal_number("1"))])
  }
  t[Uuid] = (_, _) => "NEWID()"
  t[Year] = @core.remove_ts_or_ds_to_date()
  t[DateFromParts] = @core.rename_func("DATEFROMPARTS")
  let h = d.gen_fns.hooks
  h.scope_resolution = Some((_, rhs, scope_name) => "\{scope_name}::\{rhs}")
  h.set_operations = Some(set_operations)
  h.lateral_op = Some(lateral_op)
  h.createable_sql = Some(createable_sql)
  h.options_modifier = Some((g, e) => {
    let options = g.expressions(expression=e, key="options")
    if options != "" {
      " OPTION\{g.wrap_str(options)}"
    } else {
      ""
    }
  })
  h.columndef_sql = Some((g, e, sep) => {
    let this = g.columndef_sql(e, sep~)
    let default = g.sql_key(e, "default")
    let default = if default != "" { " = \{default}" } else { "" }
    let output = g.sql_key(e, "output")
    let output = if output != "" { " \{output}" } else { "" }
    "\{this}\{default}\{output}"
  })
  let m = d.gen_fns.methods
  m[Select] = select_sql
  m[Convert] = (g, e) => {
    let name = if e.has("safe") { "TRY_CONVERT" } else { "CONVERT" }
    g.func(name, [e.this(), e.expression(), e.arg("style")])
  }
  m[QueryOption] = (g, e) => {
    let option = g.sql_key(e, "this")
    let value = g.sql_key(e, "expression")
    if value != "" {
      let optional_equal_sign = if options_that_require_equal.contains(option) {
        "= "
      } else {
        ""
      }
      "\{option} \{optional_equal_sign}\{value}"
    } else {
      option
    }
  }
  m[SplitPart] = splitpart_sql
  m[Extract] = (g, e) => {
    let part = e.this()
    let name : &@core.SqlArg = match part {
      Some(p) =>
        match date_part_unmapping.get(@core.py_upper(p.name())) {
          Some(s) if s != "" => s as &@core.SqlArg
          _ => part as &@core.SqlArg
        }
      None => part as &@core.SqlArg
    }
    g.func("DATEPART", [name, e.expression()])
  }
  m[TimeFromParts] = (g, e) => {
    match e.arg("nano") {
      Some(nano) => {
        nano.pop() |> ignore
        g.unsupported(
          "Specifying nanoseconds is not supported in TIMEFROMPARTS.",
        )
      }
      None => ()
    }
    if e.arg("fractions") is None {
      e.set("fractions", @core.literal_number("0"))
    }
    if e.arg("precision") is None {
      e.set("precision", @core.literal_number("0"))
    }
    @core.rename_func("TIMEFROMPARTS")(g, e)
  }
  m[TimestampFromParts] = (g, e) => {
    match e.arg("zone") {
      Some(zone) => {
        zone.pop() |> ignore
        g.unsupported("Time zone is not supported in DATETIMEFROMPARTS.")
      }
      None => ()
    }
    match e.arg("nano") {
      Some(nano) => {
        nano.pop() |> ignore
        g.unsupported(
          "Specifying nanoseconds is not supported in DATETIMEFROMPARTS.",
        )
      }
      None => ()
    }
    if e.arg("milli") is None {
      e.set("milli", @core.literal_number("0"))
    }
    @core.rename_func("DATETIMEFROMPARTS")(g, e)
  }
  m[SetItem] = (g, e) => {
    match e.this() {
      Some(this) if this.kind == EQ &&
        !(this.this() is Some(l) && l.kind == Parameter) =>
        // T-SQL does not use '=' in SET command, except when the LHS is a variable.
        "\{g.sql(this.this())} \{g.sql(this.expression())}"
      _ => g.setitem_sql(e)
    }
  }
  m[Boolean] = (_, e) => {
    let in_bit_type = match e.parent {
      Some(p) => bit_types.contains(p.kind)
      None => false
    }
    let in_values = match e.find_ancestor([Values, Select]) {
      Some(a) => a.kind == Values
      None => false
    }
    if in_bit_type || in_values {
      if e.has("this") {
        "1"
      } else {
        "0"
      }
    } else if e.has("this") {
      "(1 = 1)"
    } else {
      "(1 = 0)"
    }
  }
  m[Is] = (g, e) => {
    let negate = e.has("negate")
    match e.expression() {
      Some(ex) if ex.kind == Boolean =>
        g.binary(e, if negate { "<>" } else { "=" })
      _ => g.binary(e, if negate { "IS NOT" } else { "IS" })
    }
  }
  m[Create] = create_sql
  m[Into] = (g, e) => {
    g.unsupported_args(e, ["unlogged", "expressions"])
    if e.has("temporary") {
      // If the Into expression has a temporary property, push this down to the Identifier
      match e.find([Table]) {
        Some(table) =>
          match table.this() {
            Some(ident) if ident.kind == Identifier =>
              ident.set("temporary", true)
            _ => ()
          }
        None => ()
      }
    }
    "\{g.seg("INTO")} \{g.sql_key(e, "this")}"
  }
  m[Count] = (g, e) => {
    let func_name = if e.has("big_int") { "COUNT_BIG" } else { "COUNT" }
    @core.rename_func(func_name)(g, e)
  }
  m[DateDiff] = (g, e) => {
    let func_name = if e.has("big_int") { "DATEDIFF_BIG" } else { "DATEDIFF" }
    @core.date_delta_sql(func_name)(g, e)
  }
  m[Offset] = (g, e) => "\{g.offset_sql(e)} ROWS"
  m[Version] = (g, e) => {
    let name = if e.name() == "TIMESTAMP" { "SYSTEM_TIME" } else { e.name() }
    let this = "FOR \{name}"
    let expr = e.expression()
    let kind = e.text("kind")
    let expr_sql = if kind == "FROM" || kind == "BETWEEN" {
      let args = match expr {
        Some(x) => x.expressions()
        None => []
      }
      let sep = if kind == "FROM" { "TO" } else { "AND" }
      "\{g.sql(args.get(0))} \{sep} \{g.sql(args.get(1))}"
    } else {
      g.sql(expr)
    }
    let expr_sql = if expr_sql != "" { " \{expr_sql}" } else { "" }
    "\{this} \{kind}\{expr_sql}"
  }
  m[ReturnsProperty] = (g, e) => {
    let table = g.sql_key(e, "table")
    let table = if table != "" { "\{table} " } else { "" }
    "RETURNS \{table}\{g.sql_key(e, "this")}"
  }
  m[Returning] = (g, e) => {
    let into = g.sql_key(e, "into")
    let into = if into != "" { g.seg("INTO \{into}") } else { "" }
    "\{g.seg("OUTPUT")} \{g.expressions(expression=e, flat=true)}\{into}"
  }
  m[Transaction] = (g, e) => {
    let this = g.sql_key(e, "this")
    let this = if this != "" { " \{this}" } else { "" }
    let mark = g.sql_key(e, "mark")
    let mark = if mark != "" { " WITH MARK \{mark}" } else { "" }
    "BEGIN TRANSACTION\{this}\{mark}"
  }
  m[Commit] = (g, e) => {
    let this = g.sql_key(e, "this")
    let this = if this != "" { " \{this}" } else { "" }
    let durability = match e.get("durability") {
      Some(Bool(b)) => {
        let on_off = if b { "ON" } else { "OFF" }
        " WITH (DELAYED_DURABILITY = \{on_off})"
      }
      _ => ""
    }
    "COMMIT TRANSACTION\{this}\{durability}"
  }
  m[Rollback] = (g, e) => {
    let this = g.sql_key(e, "this")
    let this = if this != "" { " \{this}" } else { "" }
    "ROLLBACK TRANSACTION\{this}"
  }
  m[Identifier] = (g, e) => {
    let identifier = g.identifier_sql(e)
    let prefix = if e.has("global_") {
      "##"
    } else if e.has("temporary") {
      "#"
    } else {
      return identifier
    }
    let start = g.identifier_start
    if e.has("quoted") && identifier.has_prefix(start) {
      return "\{start}\{prefix}\{identifier.unsafe_substring(start=start.length(), end=identifier.length())}"
    }
    "\{prefix}\{identifier}"
  }
  m[Constraint] = (g, e) => {
    let this = g.sql_key(e, "this")
    let expressions = g.expressions(expression=e, flat=true, sep=" ")
    "CONSTRAINT \{this} \{expressions}"
  }
  m[Length] = (g, e) => uncast_text(g, e, "LEN")
  m[Right] = (g, e) => uncast_text(g, e, "RIGHT")
  m[Left] = (g, e) => uncast_text(g, e, "LEFT")
  m[Partition] = (g, e) => {
    "WITH (PARTITIONS(\{g.expressions(expression=e, flat=true)}))"
  }
  m[Alter] = (g, e) => {
    match e.list("actions").get(0) {
      Some(action) if action.kind == AlterRename => {
        let name = match action.this() {
          Some(a) => a.name()
          None => ""
        }
        "EXEC sp_rename '\{g.sql(e.this())}', '\{name}'"
      }
      _ => g.alter_sql(e)
    }
  }
  m[Drop] = (g, e) => {
    if e.text("kind") == "VIEW" {
      for table in e.list("tables") {
        table.set("catalog", (None : @core.Expr?))
      }
    }
    g.drop_sql(e)
  }
  m[DPipe] = (g, e) => {
    let mut acc : @core.Expr? = None
    for x in e.flatten() {
      acc = match acc {
        None => Some(x)
        Some(a) => Some(@core.mk(Add, [("this", a), ("expression", x)]))
      }
    }
    g.sql(acc)
  }
  m[IsAscii] = (g, e) => {
    "(PATINDEX(CONVERT(VARCHAR(MAX), 0x255b5e002d7f5d25) COLLATE Latin1_General_BIN, \{g.sql(e.this())}) = 0)"
  }
  m[Coalesce] = (g, e) => {
    let func_name = if e.has("is_null") { "ISNULL" } else { "COALESCE" }
    @core.rename_func(func_name)(g, e)
  }
  m[StoredProcedure] = (g, e) => {
    let this = g.sql_key(e, "this")
    let expressions = g.expressions(expression=e)
    let expressions = if e.has("wrapped") {
      g.wrap_str(expressions)
    } else {
      " \{expressions}"
    }
    if @core.py_strip(expressions) != "" {
      "\{this}\{expressions}"
    } else {
      this
    }
  }
  m[IfBlock] = (g, e) => {
    let this = g.sql_key(e, "this")
    let true_ = g.sql_key(e, "true")
    let true_ = if true_ != "" { " \{true_}" } else { " " }
    let false_ = g.sql_key(e, "false")
    let false_ = if false_ != "" { "; ELSE BEGIN \{false_}" } else { "" }
    "IF \{this} BEGIN\{true_}\{false_}"
  }
  m[WhileBlock] = (g, e) => {
    let this = g.sql_key(e, "this")
    let body = g.sql_key(e, "body")
    let body = if body != "" { " \{body}" } else { " " }
    "WHILE \{this} BEGIN\{body}"
  }
  m[Execute] = execute_sql
  m[ExecuteSql] = (g, e) => g.call_method(Execute, e)
}

///|
fn execute_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let expressions = g.expressions(expression=e)
  let expressions = if expressions != "" { " \{expressions}" } else { "" }
  let return_status = g.sql_key(e, "return_status")
  let return_status = if return_status != "" {
    "\{return_status} = "
  } else {
    ""
  }
  "EXECUTE \{return_status}\{this}\{expressions}"
}

///|
fn uncast_text(
  g : @core.Generator,
  e : @core.Expr,
  name : String,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let this_sql = match this {
    Some(t) if t.kind.is_a(Cast) && t.is_type([TEXT]) => g.sql_key(t, "this")
    _ => g.sql(this)
  }
  let expression_sql = g.sql_key(e, "expression")
  g.func(name, [
    Some(this_sql),
    if expression_sql != "" {
      Some(expression_sql)
    } else {
      None
    },
  ])
}

///|
fn select_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  prepare_limit_offset(e)
  // Handles transpiling a query like the following to T-SQL:
  //   SELECT 1 AS x ORDER BY x NULLS FIRST FETCH FIRST 1 ROWS ONLY UNION ALL SELECT 2 AS x
  match (e.parent, e.arg("limit")) {
    (Some(p), Some(l)) if p.kind.is_a(SetOperation) && l.kind == Fetch =>
      return g.sql(
        Some(
          @core.select_([@core.mk0(Star)]).from_(
            e.subquery(alias="_l_0", copy=false),
          ),
        ),
      )
    _ => ()
  }
  g.select_sql(e)
}

///|
fn set_operations(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let limit = e.arg("limit")
  let offset = e.arg("offset")
  let order = e.arg("order")
  // Set operations cannot order by the CASE used to emulate null ordering,
  // or by expressions that aren't in their select list.
  let mut wrap_order = false
  match order {
    Some(o) => {
      let selects = e.selects().map(s => s.unalias().unnest())
      for ordered in o.expressions() {
        let this = ordered.this().unwrap().unnest()
        if this.is_int() {
          continue
        }
        let desc = ordered.has("desc")
        let nulls_first = ordered.has("nulls_first")
        let emulate_null_ordering = (desc && nulls_first) ||
          (!desc && !nulls_first)
        if emulate_null_ordering ||
          (!this.kind.is_a(Column) && !selects.contains(this)) {
          wrap_order = true
          break
        }
      }
    }
    None => ()
  }
  let limit_is_limit = limit is Some(l) && l.kind == Limit
  let limit_is_fetch = limit is Some(l) && l.kind == Fetch
  if wrap_order ||
    (limit_is_limit && offset is None) ||
    (order is None && (offset is Some(_) || limit_is_fetch)) {
    let select = g.move_ctes_to_top_level(
      @core.select_([@core.mk0(Star)]).from_(
        e.subquery(alias="_l_0", copy=false),
      ),
    )
    for arg in set_op_modifiers {
      match e.get(arg) {
        Some(value) if value.truthy() => {
          e.set(arg, (None : @core.Expr?))
          select.set(arg, value)
        }
        _ => ()
      }
    }
    return g.sql(Some(select))
  }
  prepare_limit_offset(e)
  g.set_operations_base(e)
}

///|
fn prepare_limit_offset(e : @core.Expr) -> Unit raise @core.SqlglotError {
  let limit = e.arg("limit")
  let mut offset = e.arg("offset")
  match limit {
    Some(l) if l.kind == Fetch && offset is None => {
      // Dialects like Oracle can FETCH directly from a row set but
      // T-SQL requires an ORDER BY + OFFSET clause in order to FETCH
      let o = @core.mk(Offset, [("expression", @core.literal_number("0"))])
      e.set("offset", o)
      offset = Some(o)
    }
    _ => ()
  }
  if offset is Some(_) {
    if !e.has("order") {
      // ORDER BY is required in order to use OFFSET in a query, so we use
      // a noop order by, since we don't really care about the order.
      // See: https://www.microsoftpressstore.com/articles/article.aspx?p=2314819
      e.order_by([@core.select_([@core.null_()]).subquery()]) |> ignore
    }
    match limit {
      Some(l) if l.kind == Limit =>
        // TOP and OFFSET can't be combined, we need use FETCH instead of TOP
        // we replace here because otherwise TOP would be generated in select_sql
        l.replace(
          Some(
            @core.mk(Fetch, [("direction", "FIRST"), ("count", l.expression())]),
          ),
        )
        |> ignore
      _ => ()
    }
  }
}

///|
fn lateral_op(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.get("cross_apply") {
    Some(Bool(true)) => return "CROSS APPLY"
    Some(Bool(false)) => return "OUTER APPLY"
    _ => ()
  }
  // TODO: perhaps we can check if the parent is a Join and transpile it appropriately
  g.unsupported("LATERAL clause is not supported.")
  "LATERAL"
}

///|
fn splitpart_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let split_count = match this {
    Some(t) => @core.py_split(t.name(), ".").length()
    None => 1
  }
  let delimiter = e.arg("delimiter")
  let part_index = e.arg("part_index")
  let all_literals = [this, delimiter, part_index]
    .iter()
    .all(a => a is Some(x) && x.kind == Literal)
  if !all_literals ||
    (delimiter is Some(dl) && dl.name() != ".") ||
    part_index is None ||
    split_count > 4 {
    g.unsupported(
      "SPLIT_PART can be transpiled to PARSENAME only for '.' delimiter and literal values",
    )
    return ""
  }
  let idx = part_index.unwrap().to_py_int().unwrap_or(0L)
  g.func("PARSENAME", [
    this,
    Some(@core.literal_number((split_count.to_int64() + 1L - idx).to_string())),
  ])
}

///|
fn createable_sql(
  g : @core.Generator,
  e : @core.Expr,
  _locations : @core.PropLocs,
) -> String raise @core.SqlglotError {
  let sql = g.sql_key(e, "this")
  let properties = match e.arg("properties") {
    Some(p) => p.expressions()
    None => []
  }
  let start = g.identifier_start
  if !sql.has_prefix("#") &&
    !sql.has_prefix("\{start}#") &&
    properties.iter().any(p => p.kind == TemporaryProperty) {
    if start != "" && sql.has_prefix(start) {
      return "\{start}#\{sql.unsafe_substring(start=start.length(), end=sql.length())}"
    }
    return "#\{sql}"
  }
  sql
}

///|
/// `exp.table_name(table)`.
fn table_name(table : @core.Expr) -> String {
  table
  .parts()
  .map(part => {
    let name = part.name()
    if @core.is_safe_identifier(name) {
      name
    } else {
      // part.sql(identify=True) in the default dialect
      "\"\{name.replace_all(old="\"", new="\"\"")}\""
    }
  })
  .join(".")
}

///|
fn create_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let kind = e.text("kind")
  let exists = e.has("exists")
  e.set("exists", (None : @core.Expr?))
  let like_property = e.find([LikeProperty])
  let mut ctas_expression = match like_property {
    Some(lp) => lp.this()
    None => e.expression()
  }
  if kind == "VIEW" {
    match e.this() {
      Some(t) => t.set("catalog", (None : @core.Expr?))
      None => ()
    }
    match (ctas_expression, e.arg("with_")) {
      (Some(ctas), Some(with_)) =>
        // We've already preprocessed the Create expression to bubble up any nested CTEs,
        // but CREATE VIEW actually requires the WITH clause to come after it so we need
        // to amend the AST by moving the CTEs to the CREATE VIEW statement's query.
        ctas.set("with_", with_.pop())
      _ => ()
    }
  } else if kind == "FUNCTION" {
    match (ctas_expression, e.arg("with_")) {
      (Some(ctas), Some(with_)) if ctas.kind == Return &&
        ctas.this() is Some(body0) &&
        body0.unnest().kind.is_a(Query) =>
        // Similar to the VIEW branch, the table-valued functions require the WITH clause
        // to stay inside the RETURN body, so we move back any CTEs that were bubbled up.
        body0.unnest().set("with_", with_.pop())
      _ => ()
    }
  }
  let table = e.find([Table])
  let mut sql = ""
  // Convert CTAS statement to SELECT .. INTO ..
  match ctas_expression {
    Some(ctas0) if kind == "TABLE" => {
      let ctas = if ctas0.kind == Select || ctas0.kind.is_a(SetOperation) {
        ctas0.subquery()
      } else {
        ctas0
      }
      ctas_expression = Some(ctas)
      let properties = match e.arg("properties") {
        Some(p) => p.expressions()
        None => []
      }
      let is_temp = properties.iter().any(p => p.kind == TemporaryProperty)
      let select_into = @core.select_([@core.mk0(Star)]).from_(
        @core.alias_table(ctas.copy(), "temp"),
      )
      select_into.set(
        "into",
        @core.mk(Into, [("this", table), ("temporary", is_temp)]),
      )
      if like_property is Some(_) {
        select_into.limit_(@core.literal_number("0")) |> ignore
      }
      sql = g.sql(Some(select_into))
    }
    _ => sql = g.create_sql(e)
  }
  if exists {
    let identifier = g.sql(
      Some(
        @core.literal_string(
          match table {
            Some(t) => table_name(t)
            None => ""
          },
        ),
      ),
    )
    let sql_with_ctes = g.prepend_ctes(e, sql)
    let sql_literal = g.sql(Some(@core.literal_string(sql_with_ctes)))
    if kind == "SCHEMA" {
      return "IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = \{identifier}) EXEC(\{sql_literal})"
    } else if kind == "TABLE" {
      let t = table.unwrap()
      let conds : Array[@core.Expr] = [
        @core.exp_eq(
          @core.column_of("TABLE_NAME"),
          @core.literal_string(t.name()),
        ),
      ]
      if t.db() != "" {
        conds.push(
          @core.exp_eq(
            @core.column_of("TABLE_SCHEMA"),
            @core.literal_string(t.db()),
          ),
        )
      }
      if t.catalog() != "" {
        conds.push(
          @core.exp_eq(
            @core.column_of("TABLE_CATALOG"),
            @core.literal_string(t.catalog()),
          ),
        )
      }
      let where_ = @core.and_(conds)
      let where_sql = @core.Generator::new(@core.base_dialect()).generate(
        where_,
      )
      return "IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE \{where_sql}) EXEC(\{sql_literal})"
    } else if kind == "INDEX" {
      let index_name = match e.this() {
        Some(t) => t.text("this")
        None => ""
      }
      let index = g.sql(Some(@core.literal_string(index_name)))
      return "IF NOT EXISTS (SELECT * FROM sys.indexes WHERE object_id = object_id(\{identifier}) AND name = \{index}) EXEC(\{sql_literal})"
    }
  } else if e.has("replace") {
    sql = replace_first(sql, "CREATE OR REPLACE ", "CREATE OR ALTER ")
  }
  g.prepend_ctes(e, sql)
}

///|
fn replace_first(s : String, old : String, new : String) -> String {
  match s.find(old) {
    Some(i) =>
      s.unsafe_substring(start=0, end=i) +
      new +
      s.unsafe_substring(start=i + old.length(), end=s.length())
    None => s
  }
}
