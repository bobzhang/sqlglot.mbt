// Port of sqlglot/generators/trino.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  t[ArraySum] = (g, e) => {
    "REDUCE(\{g.sql_key(e, "this")}, 0, (acc, x) -> acc + x, acc -> acc)"
  }
  t[ArrayUniqueAgg] = (g, e) => "ARRAY_AGG(DISTINCT \{g.sql_key(e, "this")})"
  t[CurrentVersion] = @core.rename_func("VERSION")
  t[FromISO8601TimestampNanos] = @core.rename_func(
    "FROM_ISO8601_TIMESTAMP_NANOS",
  )
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e, on_overflow=true)
  t[LocationProperty] = (g, e) => g.property_sql(e)
  t[Merge] = @core.merge_without_target_sql
  t[Select] = @core.preprocess([
    @core.eliminate_qualify,
    @core.eliminate_distinct_on,
    @core.explode_projection_to_unnest(index_offset=1, unnest_map=true),
    @core.eliminate_semi_and_anti_joins,
    @presto.amend_exploded_column_table,
  ])
  t[StabilityProperty] = (_, e) => {
    if e.name() == "IMMUTABLE" {
      "DETERMINISTIC"
    } else {
      "NOT DETERMINISTIC"
    }
  }
  t[TimeStrToTime] = (g, e) => {
    @core.timestrtotime_sql(g, e, include_precision=true)
  }
  t[Trim] = (g, e) => @core.trim_sql(g, e)
  let m = d.gen_fns.methods
  m[ConcatWs] = concatws_sql
  m[FunctionSpecification] = functionspecification_sql
  m[IfBlock] = ifblock_sql
  m[CaseStatement] = casestatement_sql
  m[WhileBlock] = (g, e) => {
    "\{label_sql(g, e)}WHILE \{g.sql_key(e, "this")} DO \{g.sql_key(e, "body")}; END WHILE"
  }
  m[LoopBlock] = (g, e) => {
    "\{label_sql(g, e)}LOOP \{g.sql_key(e, "body")}; END LOOP"
  }
  m[RepeatBlock] = (g, e) => {
    "\{label_sql(g, e)}REPEAT \{g.sql_key(e, "body")}; UNTIL \{g.sql_key(e, "until")} END REPEAT"
  }
  m[Leave] = (g, e) => "LEAVE \{g.sql_key(e, "this")}"
  m[Iterate] = (g, e) => "ITERATE \{g.sql_key(e, "this")}"
  // super().jsonextract_sql is Presto's override, captured before installing ours
  let parent_jsonextract = m.get(JSONExtract)
  m[JSONExtract] = (g, e) => {
    if !e.has("json_query") {
      return match parent_jsonextract {
        Some(f) => f(g, e)
        None => g.call_method(JSONExtract, e)
      }
    }
    jsonextract_json_query_sql(g, e)
  }
}

///|
fn label_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.arg("label") {
    Some(label) => "\{g.sql(Some(label))}: "
    None => ""
  }
}

///|
fn concatws_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("flatten") {
    let arrays : Array[@core.Expr] = []
    let mut has_array = false
    let mut has_unknown = false
    let exprs = e.expressions()
    for i in 1..<exprs.length() {
      let mut arg = exprs[i]
      if arg.kind.is_a(Array) || arg.is_type([ARRAY]) {
        has_array = true
        arg = @core.func_("COALESCE", [
          @core.exp_cast_to(arg, @core.datatype_from_str("ARRAY<TEXT>")),
          @core.mk0(Array),
        ])
      } else {
        let untyped = match arg.get_type() {
          None => true
          Some(t) => t.is_type([UNKNOWN])
        }
        if untyped && !arg.kind.is_any([Literal, Boolean, Null]) {
          has_unknown = true
        }
        arg = @core.array_([@core.exp_cast(arg, TEXT)])
      }
      arrays.push(arg)
    }
    if has_unknown {
      g.unsupported(
        "Cannot transpile CONCAT_WS with unknown argument types to Trino.",
      )
    }
    if has_array {
      let array = if arrays.length() > 1 {
        @core.mk(ArrayConcat, [
          ("this", arrays[0]),
          ("expressions", arrays[1:].to_array()),
        ])
      } else {
        arrays[0]
      }
      return g.func("CONCAT_WS", [exprs[0], array])
    }
  }
  g.concatws_sql(e)
}

///|
fn functionspecification_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let characteristics_sql = match e.arg("characteristics") {
    Some(c) => g.properties(c, prefix=" ", sep=" ", wrapped=false)
    None => ""
  }
  let with_sql = match e.arg("properties") {
    Some(p) => " \{g.with_properties(p)}"
    None => ""
  }
  let body = g.sql_key(e, "expression")
  "FUNCTION \{g.sql_key(e, "this")}\{characteristics_sql}\{with_sql} \{body}"
}

///|
/// ELSEIF chains are nested into `false` at parse time, so this flattens them back out
/// rather than recursing on ifblock_sql itself, which would re-wrap each link in
/// its own IF ... END IF.
fn ifblock_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let branches : Array[String] = []
  let mut node : @core.Expr? = Some(e)
  while node is Some(n) && n.kind.is_a(IfBlock) {
    let keyword = if branches.is_empty() { "IF" } else { "ELSEIF" }
    branches.push(
      "\{keyword} \{g.sql_key(n, "this")} THEN \{g.sql_key(n, "true")};",
    )
    node = n.arg("false")
  }
  if node is Some(n) {
    branches.push("ELSE \{g.sql(Some(n))};")
  }
  "\{branches.join(" ")} END IF"
}

///|
/// Mirrors case_sql, using `;`-terminated statement bodies and END CASE
/// instead of a single value expression per branch and bare END.
fn casestatement_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let branches = [if this != "" { "CASE \{this}" } else { "CASE" }]
  for node in e.list("ifs") {
    branches.push(
      "WHEN \{g.sql_key(node, "this")} THEN \{g.sql_key(node, "true")};",
    )
  }
  match e.arg("default") {
    Some(default) => branches.push("ELSE \{g.sql(Some(default))};")
    None => ()
  }
  branches.push("END CASE")
  branches.join(" ")
}

///|
fn jsonextract_json_query_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut json_path = g.sql_key(e, "expression")
  // Trino's JSON_QUERY requires the path to start with a mode specifier. Paths coming from
  // dialects that don't have one (e.g. T-SQL) are parsed into a JSONPath, so we prefix the
  // standard default mode. Paths that failed to parse stay literals and keep their own mode.
  if e.expression() is Some(x) && x.kind.is_a(JSONPath) {
    let quote = g.dialect.cfg.quote_start
    let rest = if json_path.has_prefix(quote) {
      json_path.unsafe_substring(start=quote.length(), end=json_path.length())
    } else {
      json_path
    }
    json_path = "\{quote}lax \{rest}"
  }
  let option = g.sql_key(e, "option")
  let option = if option != "" { " " + option } else { "" }
  let quote = g.sql_key(e, "quote")
  let quote = if quote != "" { " " + quote } else { "" }
  let on_condition = g.sql_key(e, "on_condition")
  let on_condition = if on_condition != "" { " " + on_condition } else { "" }
  g.func("JSON_QUERY", [e.this(), json_path + option + quote + on_condition])
}
