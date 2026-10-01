// Port of sqlglot/generators/exasol.py

///|
fn sha2_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let length = e.text("length")
  let func_name = if length == "256" { "HASH_SHA256" } else { "HASH_SHA512" }
  g.func(func_name, [e.this()])
}

///|
fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = match @core.py_upper(e.text("unit")) {
    "" => "DAY"
    u => u
  }
  if !date_units.contains(unit) {
    g.unsupported("'\{unit}' is not supported in Exasol.")
    return g.function_fallback_sql(e)
  }
  g.func("\{unit}S_BETWEEN", [e.this(), e.expression()])
}

///|
fn local_key(dialect : @core.Dialect, ident : @core.Expr) -> String {
  dialect.normalize_identifier(ident.copy()).text("this")
}

///|
fn prefix_local(
  dialect : @core.Dialect,
  node : @core.Expr,
  visible_aliases : Map[String, @core.Expr],
) -> @core.Expr {
  if node.kind.is_a(Column) && node.text("table") == "" {
    match node.this() {
      Some(this) =>
        match visible_aliases.get(local_key(dialect, this)) {
          Some(a) =>
            return @core.mk(Column, [
              ("this", a),
              ("table", @core.to_identifier("LOCAL", quoted=false)),
            ])
          None => ()
        }
      None => ()
    }
  }
  node
}

///|
/// https://docs.exasol.com/db/latest/sql/select.htm
fn add_local_prefix_for_aliases(
  expression : @core.Expr,
  dialect : @core.Dialect,
) -> @core.Expr {
  if expression.kind != Select {
    return expression
  }
  let aliases : Map[String, @core.Expr] = Map([])
  for sel in expression.selects() {
    if sel.kind.is_a(Alias) {
      match sel.arg("alias") {
        Some(a) => aliases[local_key(dialect, a)] = a
        None => ()
      }
    }
  }
  match expression.find([Table]) {
    Some(table) =>
      match table.this() {
        Some(ti) if @core.py_upper(ti.name()) == "LOCAL" && !ti.has("quoted") =>
          ti.replace(
            Some(@core.to_identifier(@core.py_upper(ti.name()), quoted=true)),
          )
          |> ignore
        _ => ()
      }
    None => ()
  }
  for key in ["where", "group", "having"] {
    match expression.arg(key) {
      Some(arg) =>
        expression.set(
          key,
          arg.transform(node => Some(prefix_local(dialect, node, aliases))),
        )
      None => ()
    }
  }
  let seen_aliases : Map[String, @core.Expr] = Map([])
  let new_selects : Array[@core.Expr] = []
  for sel in expression.selects() {
    if sel.kind.is_a(Alias) {
      let inner = sel
        .this()
        .unwrap()
        .transform(node => Some(prefix_local(dialect, node, seen_aliases)))
      sel.set("this", inner)
      match sel.arg("alias") {
        Some(alias_node) =>
          seen_aliases[local_key(dialect, alias_node)] = alias_node
        None => ()
      }
      new_selects.push(sel)
    } else {
      new_selects.push(
        sel.transform(node => Some(prefix_local(dialect, node, seen_aliases))),
      )
    }
  }
  expression.set("expressions", new_selects)
  expression
}

///|
fn trunc_sql(
  g : @core.Generator,
  kind : String,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = match e.arg("unit") {
    Some(u) if u.kind == WeekStart => g.weekstart_name(u)
    _ => e.text("unit")
  }
  let node = match e.this() {
    Some(c) if c.kind.is_a(Cast) => c.this()
    x => x
  }
  let mut expr_sql = g.sql(node)
  match node {
    Some(n) if n.kind == Literal && n.is_string() => {
      let text = n.text("this")
      expr_sql = if kind == "TIMESTAMP" {
        "\{kind} '\{text.replace_all(old="T", new=" ")}'"
      } else {
        "DATE '\{text}'"
      }
    }
    _ => ()
  }
  "DATE_TRUNC('\{unit}', \{expr_sql})"
}

///|
fn is_case_insensitive(node : @core.Expr?) -> Bool {
  match node {
    Some(n) =>
      n.kind == Collate && @core.py_upper(n.text("expression")) == "UTF8_LCASE"
    None => false
  }
}

///|
fn substring_index_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let delimiter = e.arg("delimiter")
  let count_node = e.arg("count").unwrap()
  let count_sql = g.sql_key(e, "count")
  let num = if count_node.is_number() {
    match count_node.to_py_float() {
      Some(v) => v
      None => 0.0
    }
  } else {
    0.0
  }
  let haystack_sql = g.sql(this)
  if num == 0.0 {
    return g.func("SUBSTR", [haystack_sql, "1", "0"])
  }
  let from_right = num < 0.0
  let direction = if from_right { "-1" } else { "1" }
  let occur = if from_right { g.func("ABS", [count_sql]) } else { count_sql }
  let delimiter_sql = g.sql(delimiter)
  let position = g.func("INSTR", [
    if is_case_insensitive(this) {
      g.func("LOWER", [haystack_sql])
    } else {
      haystack_sql
    },
    if is_case_insensitive(delimiter) {
      g.func("LOWER", [delimiter_sql])
    } else {
      delimiter_sql
    },
    direction,
    occur,
  ])
  let nullable_pos = g.func("NULLIF", [position, "0"])
  if from_right {
    let start = g.func("NVL", [
      "\{nullable_pos} + \{g.func("LENGTH", [delimiter_sql])}",
      direction,
    ])
    return g.func("SUBSTR", [haystack_sql, start])
  }
  let length = g.func("NVL", [
    "\{nullable_pos} - 1",
    g.func("LENGTH", [haystack_sql]),
  ])
  g.func("SUBSTR", [haystack_sql, direction, length])
}

///|
fn is_bare_star(e : @core.Expr) -> Bool {
  e.kind == Star && e.this() is None
}

///|
/// Exasol doesn't support a bare * alongside other select items, so we rewrite it
fn qualify_unscoped_star(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind != Select {
    return expression
  }
  let select_expressions = expression.expressions()
  let mut has_other_expression = false
  let mut bare_star_expr : @core.Expr? = None
  for expr in select_expressions {
    let has_bare_star = is_bare_star(expr)
    if has_bare_star && bare_star_expr is None {
      bare_star_expr = Some(expr)
    } else if !has_bare_star {
      has_other_expression = true
    }
    if bare_star_expr is Some(_) && has_other_expression {
      break
    }
  }
  guard bare_star_expr is Some(star) && has_other_expression else {
    return expression
  }
  let scope = @optimizer.build_scope(expression)
  guard scope is Some(scope) && !scope.selected_sources().is_empty() else {
    return expression
  }
  let table_identifiers : Array[@core.Expr] = []
  for source_name, src in scope.selected_sources() {
    let (source_expr, _) = src
    let ident = match source_expr.this() {
      Some(t) if source_expr.kind == Table && t.kind == Identifier => t.copy()
      _ => @core.to_identifier(source_name)
    }
    table_identifiers.push(ident)
  }
  let new_select_expressions : Array[@core.Expr] = []
  for select_expr in select_expressions {
    if is_bare_star(select_expr) {
      for ident in table_identifiers {
        new_select_expressions.push(
          @core.mk(Column, [("this", star.copy()), ("table", ident)]),
        )
      }
    } else {
      new_select_expressions.push(select_expr)
    }
  }
  expression.set("expressions", new_select_expressions)
  expression
}

///|
fn add_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let interval = match e.expression() {
    Some(i) if i.kind == Interval => Some(i)
    _ => None
  }
  let unit_text = match interval {
    Some(i) => i.text("unit")
    None => e.text("unit")
  }
  let unit = @core.py_upper(if unit_text == "" { "DAY" } else { unit_text })
  if !date_units.contains(unit) {
    g.unsupported("'\{unit}' is not supported in Exasol.")
    return g.function_fallback_sql(e)
  }
  let mut offset_expr = e.expression()
  match interval {
    Some(i) => offset_expr = i.this()
    None => ()
  }
  if e.kind == DateSub {
    offset_expr = Some(@core.mk1(Neg, offset_expr))
  }
  g.func("ADD_\{unit}S", [e.this(), offset_expr])
}

///|
/// `find_in_scope(proj, exp.AggFunc)` is truthy
fn has_agg_in_scope(proj : @core.Expr) -> Bool {
  @optimizer.find_in_scope(proj, [AggFunc]) is Some(_)
}

///|
fn group_by_all(expression : @core.Expr) -> @core.Expr raise @core.SqlglotError {
  if expression.kind != Select {
    return expression
  }
  guard expression.arg("group") is Some(group) && group.has("all") else {
    return expression
  }
  if expression.is_star() {
    if expression.expressions().iter().any(has_agg_in_scope) {
      raise @core.UnsupportedError(
        "GROUP BY ALL with star projection and aggregates is not supported by Exasol",
      )
    }
    expression.set("distinct", @core.mk0(Distinct))
    expression.set("group", (None : @core.Expr?))
    return expression
  }
  let group_positions : Array[@core.Expr] = []
  for i, proj in expression.expressions() {
    if !has_agg_in_scope(proj) {
      group_positions.push(@core.literal_int(i + 1))
    }
  }
  if group_positions.is_empty() {
    expression.set("group", (None : @core.Expr?))
    return expression
  }
  group.set("expressions", group_positions)
  group.set("all", (None : @core.Expr?))
  expression
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 != "cluster" && kv.0 != "distribute" && kv.0 != "sort"
    },
  )
  let t = d.gen_fns.transforms
  t[All] = @core.rename_func("EVERY")
  t[BitwiseAnd] = @core.rename_func("BIT_AND")
  t[BitwiseOr] = @core.rename_func("BIT_OR")
  t[BitwiseNot] = @core.rename_func("BIT_NOT")
  t[BitwiseLeftShift] = @core.rename_func("BIT_LSHIFT")
  t[BitwiseRightShift] = @core.rename_func("BIT_RSHIFT")
  t[BitwiseXor] = @core.rename_func("BIT_XOR")
  t[CurrentSchema] = (_, _) => "CURRENT_SCHEMA"
  t[DateDiff] = date_diff_sql
  t[DateAdd] = add_date_sql
  t[TsOrDsAdd] = add_date_sql
  t[DateSub] = add_date_sql
  t[IntDiv] = @core.rename_func("DIV")
  t[TsOrDsDiff] = date_diff_sql
  t[DateTrunc] = (g, e) => trunc_sql(g, "DATE", e)
  t[DayOfWeek] = (g, e) => {
    "CAST(TO_CHAR(\{g.sql_key(e, "this")}, 'D') AS INTEGER)"
  }
  t[DatetimeTrunc] = @core.timestamptrunc_sql()
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e, on_overflow=true)
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("EDIT_DISTANCE")(g, e)
  }
  t[Mod] = @core.rename_func("MOD")
  t[UnixToTime] = (g, e) => g.func("FROM_POSIX_TIME", [e.this()])
  t[Rank] = (g, e) => {
    g.unsupported_args(e, ["expressions"])
    "RANK()"
  }
  t[DenseRank] = (g, e) => {
    g.unsupported_args(e, ["expressions"])
    "DENSE_RANK()"
  }
  t[RegexpExtract] = (g, e) => {
    g.unsupported_args(e, ["parameters", "group"])
    @core.rename_func("REGEXP_SUBSTR")(g, e)
  }
  t[RegexpReplace] = (g, e) => {
    g.unsupported_args(e, ["modifiers"])
    @core.rename_func("REGEXP_REPLACE")(g, e)
  }
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[ApproxDistinct] = (g, e) => {
    g.unsupported_args(e, ["accuracy"])
    @core.rename_func("APPROXIMATE_COUNT_DISTINCT")(g, e)
  }
  t[TimeToStr] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[ToChar] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[TsOrDsToDate] = (g, e) => g.func("TO_DATE", [e.this(), g.format_time(e)])
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimestampTrunc] = (g, e) => trunc_sql(g, "TIMESTAMP", e)
  t[StrToTime] = (g, e) => g.func("TO_DATE", [e.this(), g.format_time(e)])
  t[CurrentUser] = (_, _) => "CURRENT_USER"
  t[AtTimeZone] = (g, e) => {
    g.func("CONVERT_TZ", [e.this(), "'UTC'", e.arg("zone")])
  }
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(
      g,
      e,
      func_name="INSTR",
      supports_position=true,
      supports_occurrence=true,
    )
  }
  t[SHA] = @core.rename_func("HASH_SHA")
  t[SHA2] = sha2_sql
  t[MD5] = @core.rename_func("HASH_MD5")
  t[MD5Digest] = @core.rename_func("HASHTYPE_MD5")
  t[CommentColumnConstraint] = (g, e) => "COMMENT IS \{g.sql_key(e, "this")}"
  t[SubstringIndex] = substring_index_sql
  t[WeekOfYear] = @core.rename_func("WEEK")
  t[Date] = @core.rename_func("TO_DATE")
  t[Timestamp] = @core.rename_func("TO_TIMESTAMP")
  t[Quarter] = (g, e) => "CEIL(MONTH(TO_DATE(\{g.sql_key(e, "this")}))/3)"
  t[LastDay] = @core.no_last_day_sql
  let m = d.gen_fns.methods
  m[Select] = (g, e) => {
    let processed = qualify_unscoped_star(e)
    let processed = add_local_prefix_for_aliases(processed, g.dialect)
    let processed = group_by_all(processed)
    g.select_sql(processed)
  }
  m[DataType] = (g, e) => {
    // Exasol supports a fixed default precision of 3 for TIMESTAMP WITH LOCAL TIME ZONE
    if e.is_type([TIMESTAMPLTZ]) {
      return "TIMESTAMP WITH LOCAL TIME ZONE"
    }
    g.datatype_sql(e)
  }
  m[ConvertTimezone] = (g, e) => {
    g.func("CONVERT_TZ", [
      e.arg("timestamp"),
      e.arg("source_tz"),
      e.arg("target_tz"),
      e.arg("options"),
    ])
  }
  m[If] = (g, e) => {
    let this = g.sql_key(e, "this")
    let true_ = g.sql_key(e, "true")
    let false_ = g.sql_key(e, "false")
    "IF \{this} THEN \{true_} ELSE \{false_} ENDIF"
  }
  m[Use] = (g, e) => {
    match e.arg("kind") {
      Some(kind) if @core.py_upper(g.sql(Some(kind))) != "SCHEMA" => {
        g.unsupported("'USE \{g.sql(Some(kind))}' is not supported in Exasol")
        return g.use_sql(e)
      }
      _ => ()
    }
    "OPEN SCHEMA \{g.sql_key(e, "this")}"
  }
  m[Show] = show_sql
  m[Collate] = (g, e) => g.sql(e.this())
  m[JSONExtract] = (g, e) => {
    let args : Array[&@core.SqlArg] = [e.this(), e.expression()]
    for x in e.expressions() {
      args.push(x)
    }
    let sql = g.func("JSON_EXTRACT", args)
    let emits = g.sql_key(e, "emits")
    if emits != "" {
      "\{sql} EMITS \{emits}"
    } else {
      sql
    }
  }
  m[RegexpLike] = (g, e) => {
    g.unsupported_args(e, ["flag"])
    if !e.has("full_match") {
      let pattern = e.expression().unwrap()
      if pattern.is_string() {
        e.set("expression", @core.literal_string(".*\{pattern.name()}.*"))
      } else {
        e.set(
          "expression",
          @core.mk1(
            Paren,
            @core.mk(Concat, [
              (
                "expressions",
                [
                  @core.literal_string(".*"),
                  pattern,
                  @core.literal_string(".*"),
                ],
              ),
            ]),
          ),
        )
      }
    }
    g.binary(e, "REGEXP_LIKE")
  }
}

///|
/// https://docs.exasol.com/db/latest/sql_references/metadata/metadata_system_tables.htm
fn show_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.name() == "TABLES" {
    let db_name = e.text("db")
    let schema_filter = if db_name != "" {
      @core.literal_string(@core.py_upper(db_name))
    } else {
      @core.mk0(CurrentSchema)
    }
    let select = @core.select_([@core.column_of("TABLE_NAME")])
      .from_(sys_table("EXA_ALL_TABLES"))
      .where_([@core.exp_eq(@core.column_of("TABLE_SCHEMA"), schema_filter)])
    return g.sql(Some(select))
  }
  if e.name() == "DATABASES" {
    let select = @core.select_([@core.column_of("SCHEMA_NAME")]).from_(
      sys_table("EXA_SCHEMAS"),
    )
    return g.sql(Some(select))
  }
  g.show_sql(e)
}

///|
fn sys_table(name : String) -> @core.Expr {
  @core.mk(Table, [
    ("this", @core.to_identifier(name)),
    ("db", @core.to_identifier("SYS")),
  ])
}
