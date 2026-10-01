// Port of sqlglot/generators/bigquery.py

///|
fn derived_table_values_to_unnest(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.find_ancestor([From, Join]) is None {
    return g.values_sql_v(e)
  }
  let structs : Array[@core.Expr] = []
  let alias_ = e.arg("alias")
  for tup in e.find_all([Tuple]).collect() {
    let field_aliases : Array[@core.Expr] = match alias_ {
      Some(a) if !a.list("columns").is_empty() => a.list("columns")
      _ =>
        Array::makei(tup.expressions().length(), i => {
          @core.to_identifier("_c\{i}")
        })
    }
    let fields = tup.expressions()
    let n = if field_aliases.length() < fields.length() {
      field_aliases.length()
    } else {
      fields.length()
    }
    let expressions = Array::makei(n, i => {
      @core.mk(PropertyEQ, [
        ("this", @core.to_identifier_expr(field_aliases[i])),
        ("expression", fields[i]),
      ])
    })
    structs.push(@core.mk(Struct, [("expressions", expressions)]))
  }
  // Due to `UNNEST_COLUMN_ONLY`, it is expected that the table alias be contained in the columns expression
  let alias_name_only = match alias_ {
    Some(a) => Some(@core.mk(TableAlias, [("columns", a.this().map(t => [t]))]))
    None => None
  }
  g.call_method(
    Unnest,
    @core.mk(Unnest, [
      ("expressions", [@core.array_(structs)]),
      ("alias", alias_name_only),
    ]),
  )
}

///|
fn returnsproperty_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = match e.this() {
    Some(t) if t.kind == Schema =>
      "\{g.sql_key(t, "this")} <\{g.expressions(expression=t)}>"
    t => g.sql(t)
  }
  "RETURNS \{this}"
}

///|
fn create_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let returns = e.find([ReturnsProperty])
  match returns {
    Some(r) if e.text("kind") == "FUNCTION" && r.has("is_table") => {
      e.set("kind", "TABLE FUNCTION")
      match e.expression() {
        Some(x) if x.kind == Subquery || x.kind == Literal =>
          e.set("expression", x.get("this"))
        _ => ()
      }
    }
    _ => ()
  }
  g.call_method(Create, e)
}

///|
/// https://issuetracker.google.com/issues/162294746
/// workaround for bigquery bug when grouping by an expression and then ordering
fn alias_ordered_group(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == Select {
    match (expression.arg("group"), expression.arg("order")) {
      (Some(group), Some(_)) => {
        let aliases : Array[(@core.Expr, @core.Expr)] = []
        for select in expression.selects() {
          if select.kind.is_a(Alias) {
            match (select.this(), select.arg("alias")) {
              (Some(t), Some(a)) => aliases.push((t, a))
              _ => ()
            }
          }
        }
        for grouped in group.expressions() {
          if grouped.is_int() {
            continue
          }
          // dict semantics: the last duplicate key wins
          let mut found : @core.Expr? = None
          for kv in aliases {
            if kv.0 == grouped {
              found = Some(kv.1)
            }
          }
          match found {
            Some(a) =>
              grouped.replace(Some(@core.mk1(Column, a.copy()))) |> ignore
            None => ()
          }
        }
      }
      _ => ()
    }
  }
  expression
}

///|
/// BigQuery doesn't allow column names when defining a CTE, so we try to push them down.
fn pushdown_cte_column_names(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == CTE && !expression.alias_column_names().is_empty() {
    let cte_query = expression.this().unwrap()
    if cte_query.is_star() {
      @core.log_warning(
        "Can't push down CTE column names for star queries. Run the query through" +
        " the optimizer or use 'qualify' to expand the star projections first.",
      )
      return expression
    }
    let column_names = expression.alias_column_names()
    expression.arg("alias").unwrap().set("columns", (None : @core.Expr?))
    let selects = cte_query.selects()
    let n = if column_names.length() < selects.length() {
      column_names.length()
    } else {
      selects.length()
    }
    for i in 0..<n {
      let name = column_names[i]
      let to_replace = selects[i]
      let select = if to_replace.kind.is_a(Alias) {
        to_replace.this().unwrap()
      } else {
        to_replace
      }
      // Inner aliases are shadowed by the CTE column names
      to_replace.replace(Some(@core.alias_(select, name))) |> ignore
    }
  }
  expression
}

///|
/// Rewrites exploding GENERATE_SERIES projections into table references.
fn unnest_explode_generate_series(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == Select {
    for projection in expression.selects() {
      let series = projection.unalias()
      if series.kind == ExplodingGenerateSeries {
        let column_name = match projection.output_name() {
          "" => "_gen_series_value"
          n => n
        }
        projection.replace(Some(@core.column_of(column_name))) |> ignore
        let table = @core.mk(Table, [
          ("this", series),
          ("alias", @core.mk1(TableAlias, @core.to_identifier(column_name))),
        ])
        if expression.has("from_") {
          expression.join_(table, kind="CROSS") |> ignore
        } else {
          expression.set("from_", @core.mk1(From, table))
        }
      }
    }
  }
  expression
}

///|
fn array_contains_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unnest = @core.alias_table(
    @core.mk(Unnest, [("expressions", e.this().map(t => [t]))]),
    "_unnest",
    columns=["_col"],
  )
  let query = @core.select_([@core.literal_number("1")])
    .from_(unnest)
    .where_([@core.exp_eq(@core.column_of("_col"), e.expression().unwrap())])
  g.sql(Some(@core.mk1(Exists, query)))
}

///|
fn ts_or_ds_add_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  @core.date_add_interval_sql("DATE", "ADD")(g, @core.ts_or_ds_add_cast(e))
}

///|
fn ts_or_ds_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this().unwrap()
  this.replace(Some(@core.exp_cast(this, TIMESTAMP))) |> ignore
  let expr = e.expression().unwrap()
  expr.replace(Some(@core.exp_cast(expr, TIMESTAMP))) |> ignore
  let unit = @core.unit_to_var(e)
  g.func("DATE_DIFF", [e.this(), e.expression(), unit])
}

///|
fn literal_number_eq(e : @core.Expr, n : String) -> Bool {
  e.kind == Literal && !e.is_string() && e.text("this") == n
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let timestamp = e.this()
  match scale {
    None => g.func("TIMESTAMP_SECONDS", [timestamp])
    Some(s) if literal_number_eq(s, "0") =>
      g.func("TIMESTAMP_SECONDS", [timestamp])
    Some(s) if literal_number_eq(s, "3") =>
      g.func("TIMESTAMP_MILLIS", [timestamp])
    Some(s) if literal_number_eq(s, "6") =>
      g.func("TIMESTAMP_MICROS", [timestamp])
    Some(s) => {
      let unix_seconds = @core.exp_cast(
        @core.mk(Div, [
          ("this", timestamp),
          (
            "expression",
            Some(@core.func_("POW", [@core.literal_number("10"), s])),
          ),
        ]),
        BIGINT,
      )
      g.func("TIMESTAMP_SECONDS", [unix_seconds])
    }
  }
}

///|
fn str_to_datetime_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = g.sql_key(e, "this")
  let dtype = if e.kind == StrToDate { "DATE" } else { "TIMESTAMP" }
  if e.has("safe") {
    let fmt = g.format_time(
      e,
      inverse_time_mapping=g.dialect.cfg.inverse_format_mapping,
      inverse_time_trie=g.dialect.inverse_format_trie,
    )
    return "SAFE_CAST(\{this} AS \{dtype} FORMAT \{fmt.unwrap_or("")})"
  }
  let fmt = g.format_time(e)
  g.func("PARSE_\{dtype}", [fmt, this, e.arg("zone")])
}

///|
fn levenshtein_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost"])
  let max_dist = match e.arg("max_dist") {
    Some(m) =>
      Some(
        @core.mk(Kwarg, [
          ("this", @core.var_("max_distance")),
          ("expression", m),
        ]),
      )
    None => None
  }
  g.func("EDIT_DISTANCE", [e.this(), e.expression(), max_dist])
}

///|
let dquotes_escaping_json_functions : Array[String] = [
  "JSON_QUERY", "JSON_VALUE", "JSON_QUERY_ARRAY",
]

///|
fn json_extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let name = match e.meta_get("name") {
    Some(Str(n)) if n != "" => n
    _ => e.kind.sql_name()
  }
  let upper = @core.py_upper(name)
  let dquote_escaping = dquotes_escaping_json_functions.contains(upper)
  if dquote_escaping {
    g.quote_json_path_key_using_brackets = false
  }
  let sql = @core.rename_func(upper)(g, e)
  if dquote_escaping {
    g.quote_json_path_key_using_brackets = true
  }
  sql
}

///|
let ts_or_ds_types : Array[@core.Kind] = [
  TsOrDsToDatetime,
  TsOrDsToTimestamp,
  TsOrDsToTime,
  TsOrDsToDate,
]

///|
fn safe_json_path_key(s : String) -> Bool {
  // ^[\-\w]*$
  for c in s {
    if !(c == '-' ||
      c == '_' ||
      c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      c.to_int() > 127) {
      return false
    }
  }
  true
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  d.gen_fns.hooks.safe_json_path_key_re = Some(safe_json_path_key)
  // WINDOW comes after QUALIFY
  let ah = d.gen_fns.after_having_modifier_transforms
  let qualify = ah.filter(kv => kv.0 == "qualify")
  let windows = ah.filter(kv => kv.0 == "windows")
  d.gen_fns.after_having_modifier_transforms = qualify + windows
  let t = d.gen_fns.transforms
  t[AIEmbed] = @core.rename_func("EMBED")
  t[AIGenerate] = @core.rename_func("GENERATE")
  t[AISimilarity] = @core.rename_func("SIMILARITY")
  t[ApproxTopK] = @core.rename_func("APPROX_TOP_COUNT")
  t[ApproxDistinct] = @core.rename_func("APPROX_COUNT_DISTINCT")
  t[ArgMax] = @core.arg_max_or_min_no_count("MAX_BY")
  t[ArgMin] = @core.arg_max_or_min_no_count("MIN_BY")
  t[Array] = @core.inline_array_unless_query
  t[ArrayContains] = array_contains_sql
  t[ArrayFilter] = @core.filter_array_using_unnest
  t[ArrayRemove] = @core.filter_array_using_unnest
  t[BitwiseAndAgg] = @core.rename_func("BIT_AND")
  t[BitwiseOrAgg] = @core.rename_func("BIT_OR")
  t[BitwiseXorAgg] = @core.rename_func("BIT_XOR")
  t[BitwiseCount] = @core.rename_func("BIT_COUNT")
  t[ByteLength] = @core.rename_func("BYTE_LENGTH")
  t[Cast] = @core.preprocess([@core.remove_precision_parameterized_types])
  t[CollateProperty] = (g, e) => {
    if e.has("default") {
      "DEFAULT COLLATE \{g.sql_key(e, "this")}"
    } else {
      "COLLATE \{g.sql_key(e, "this")}"
    }
  }
  t[Commit] = (_, _) => "COMMIT TRANSACTION"
  t[CountIf] = @core.rename_func("COUNTIF")
  t[Create] = create_sql
  t[CTE] = @core.preprocess([pushdown_cte_column_names])
  t[DateAdd] = @core.date_add_interval_sql("DATE", "ADD")
  t[DateDiff] = (g, e) => {
    g.func("DATE_DIFF", [e.this(), e.expression(), @core.unit_to_var(e)])
  }
  t[DateFromParts] = @core.rename_func("DATE")
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateSub] = @core.date_add_interval_sql("DATE", "SUB")
  t[DatetimeAdd] = @core.date_add_interval_sql("DATETIME", "ADD")
  t[DatetimeSub] = @core.date_add_interval_sql("DATETIME", "SUB")
  t[DateFromUnixDate] = @core.rename_func("DATE_FROM_UNIX_DATE")
  t[FromTimeZone] = (g, e) => {
    g.func("DATETIME", [g.func("TIMESTAMP", [e.this(), e.arg("zone")]), "'UTC'"])
  }
  t[GenerateSeries] = @core.generate_series_sql("GENERATE_ARRAY")
  t[GroupConcat] = (g, e) => {
    @core.groupconcat_sql(
      g,
      e,
      func_name="STRING_AGG",
      within_group=false,
      sep="",
    )
  }
  t[Hex] = (g, e) => g.func("UPPER", [g.func("TO_HEX", [g.sql_key(e, "this")])])
  t[HexString] = (g, e) => g.hexstring_sql_v(e, binary_function_repr="FROM_HEX")
  t[If] = @core.if_sql_str("NULL")
  t[ILike] = @core.no_ilike_sql
  t[IntDiv] = @core.rename_func("DIV")
  t[Int64] = @core.rename_func("INT64")
  t[JSONBool] = @core.rename_func("BOOL")
  t[JSONExtract] = json_extract_sql
  t[JSONExtractArray] = json_extract_sql
  t[JSONExtractScalar] = json_extract_sql
  t[JSONFormat] = (g, e) => {
    g.func(if e.has("to_json") { "TO_JSON" } else { "TO_JSON_STRING" }, [
      e.this(),
      e.arg("options"),
    ])
  }
  t[JSONKeysAtDepth] = @core.rename_func("JSON_KEYS")
  t[JSONValueArray] = @core.rename_func("JSON_VALUE_ARRAY")
  t[Levenshtein] = levenshtein_sql
  t[Max] = @core.max_or_greatest
  t[MD5] = (g, e) => g.func("TO_HEX", [g.func("MD5", [e.this()])])
  t[MD5Digest] = @core.rename_func("MD5")
  t[Min] = @core.min_or_least
  t[Normalize] = (g, e) => {
    g.func(
      if e.has("is_casefold") {
        "NORMALIZE_AND_CASEFOLD"
      } else {
        "NORMALIZE"
      },
      [e.this(), e.arg("form")],
    )
  }
  t[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  t[RegexpExtract] = (g, e) => {
    g.func("REGEXP_EXTRACT", [
      e.this(),
      e.expression(),
      e.arg("position"),
      e.arg("occurrence"),
    ])
  }
  t[RegexpExtractAll] = (g, e) => {
    g.func("REGEXP_EXTRACT_ALL", [e.this(), e.expression()])
  }
  t[RegexpReplace] = @core.regexp_replace_sql
  t[RegexpLike] = @core.rename_func("REGEXP_CONTAINS")
  t[ReturnsProperty] = returnsproperty_sql
  t[Rollback] = (_, _) => "ROLLBACK TRANSACTION"
  t[ParseTime] = (g, e) => g.func("PARSE_TIME", [g.format_time(e), e.this()])
  t[ParseDatetime] = (g, e) => {
    g.func("PARSE_DATETIME", [g.format_time(e), e.this()])
  }
  t[Select] = @core.preprocess([
    unnest_explode_generate_series,
    @optimizer.explode_projection_to_unnest(index_offset=0),
    @core.unqualify_unnest,
    @core.eliminate_distinct_on,
    alias_ordered_group,
    @core.eliminate_semi_and_anti_joins,
  ])
  t[SHA] = @core.rename_func("SHA1")
  t[SHA2] = @core.sha256_sql
  t[SHA1Digest] = @core.rename_func("SHA1")
  t[SHA2Digest] = @core.sha2_digest_sql
  t[StabilityProperty] = (_, e) => {
    if e.name() == "IMMUTABLE" {
      "DETERMINISTIC"
    } else {
      "NOT DETERMINISTIC"
    }
  }
  t[String] = @core.rename_func("STRING")
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(
      g,
      e,
      func_name="INSTR",
      supports_position=true,
      supports_occurrence=true,
    )
  }
  t[StrToDate] = str_to_datetime_sql
  t[StrToTime] = str_to_datetime_sql
  t[SessionUser] = (_, _) => "SESSION_USER()"
  t[Table] = @core.preprocess([@core.unnest_generate_series])
  t[TimeAdd] = @core.date_add_interval_sql("TIME", "ADD")
  t[TimeFromParts] = @core.rename_func("TIME")
  t[TimestampFromParts] = @core.rename_func("DATETIME")
  t[TimeSub] = @core.date_add_interval_sql("TIME", "SUB")
  t[TimestampAdd] = @core.date_add_interval_sql("TIMESTAMP", "ADD")
  t[TimestampDiff] = @core.rename_func("TIMESTAMP_DIFF")
  t[TimestampSub] = @core.date_add_interval_sql("TIMESTAMP", "SUB")
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[Transaction] = (_, _) => "BEGIN TRANSACTION"
  t[TsOrDsAdd] = ts_or_ds_add_sql
  t[TsOrDsDiff] = ts_or_ds_diff_sql
  t[TsOrDsToTime] = @core.rename_func("TIME")
  t[TsOrDsToDatetime] = @core.rename_func("DATETIME")
  t[TsOrDsToTimestamp] = @core.rename_func("TIMESTAMP")
  t[Unhex] = @core.rename_func("FROM_HEX")
  t[UnixDate] = @core.rename_func("UNIX_DATE")
  t[UnixToTime] = unix_to_time_sql
  t[Uuid] = (_, _) => "GENERATE_UUID()"
  t[Values] = derived_table_values_to_unnest
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[SafeDivide] = @core.rename_func("SAFE_DIVIDE")
  let m = d.gen_fns.methods
  m[WeekStart] = (g, e) => {
    if @core.py_upper(e.this().map(t => t.name()).unwrap_or("")) == "SUNDAY" {
      // BigQuery specific optimization since WEEK(SUNDAY) == WEEK
      return "WEEK"
    }
    g.func("WEEK", [e.this()])
  }
  m[DateTrunc] = (g, e) => {
    let unit = e.arg("unit")
    let unit_sql = match unit {
      Some(u) if u.is_string() => u.name()
      u => g.sql(u)
    }
    g.func("DATE_TRUNC", [e.this(), unit_sql, e.arg("zone")])
  }
  m[Mod] = (g, e) => {
    let unparen = (x : @core.Expr?) => {
      match x {
        Some(p) if p.kind == Paren => Some(p.unnest())
        _ => x
      }
    }
    g.func("MOD", [unparen(e.this()), unparen(e.expression())])
  }
  d.gen_fns.hooks.column_parts = Some((g, e) => {
    if e.meta_bool("quoted_column") {
      // If a column reference is of the form `dataset.table`.name, we need
      // to preserve the quoted table path, otherwise the reference breaks
      let parts = e.parts()
      let table_parts = parts[:parts.length() - 1]
        .to_owned()
        .map(p => p.name())
        .join(".")
      let table_path = g.sql(
        Some(@core.to_identifier(table_parts, quoted=true)),
      )
      return "\{table_path}.\{g.sql_key(e, "this")}"
    }
    g.column_parts_base(e)
  })
  d.gen_fns.hooks.table_parts = Some((g, e) => {
    // Depending on the context, `x.y` may not resolve to the same data source as `x`.`y`, so
    // we need to make sure the correct quoting is used in each case.
    if e.meta_bool("quoted_table") {
      let table_parts = e.parts().map(p => p.name()).join(".")
      return g.sql(Some(@core.to_identifier(table_parts, quoted=true)))
    }
    g.table_parts_base(e)
  })
  m[TimeToStr] = (g, e) => {
    let this = e.this()
    let func_name = match this {
      Some(x) if x.kind == TsOrDsToDatetime => "FORMAT_DATETIME"
      Some(x) if x.kind == TsOrDsToTimestamp => "FORMAT_TIMESTAMP"
      Some(x) if x.kind == TsOrDsToTime => "FORMAT_TIME"
      _ => "FORMAT_DATE"
    }
    let time_expr = match this {
      Some(x) if x.kind.is_any(ts_or_ds_types) => x
      _ => e
    }
    g.func(func_name, [g.format_time(e), time_expr.this(), e.arg("zone")])
  }
  m[EQ] = (g, e) => {
    // Operands of = cannot be NULL in BigQuery
    let is_null = (x : @core.Expr?) => x is Some(n) && n.kind == Null
    if is_null(e.this()) || is_null(e.expression()) {
      match e.parent {
        Some(p) if p.kind == Update => ()
        _ => return "NULL"
      }
    }
    g.binary(e, "=")
  }
  m[AtTimeZone] = (g, e) => {
    // BigQuery allows CAST(.. AS {STRING|TIMESTAMP} [FORMAT <fmt> [AT TIME ZONE <tz>]]).
    // Only the TIMESTAMP one should use the below conversion, when AT TIME ZONE is included.
    let is_text_cast = match e.parent {
      Some(p) if p.kind.is_a(Cast) =>
        match p.arg("to") {
          Some(to) => to.is_type(@core.dtype_text_types)
          None => false
        }
      _ => false
    }
    if !is_text_cast {
      return g.func("TIMESTAMP", [g.func("DATETIME", [e.this(), e.arg("zone")])])
    }
    g.attimezone_sql(e)
  }
  m[TryCast] = (g, e) => g.cast_sql_v(e, safe_prefix="SAFE_")
  m[Bracket] = bracket_sql
  d.gen_fns.hooks.in_unnest_op = Some((g, e) => g.sql(Some(e)))
  m[Version] = (g, e) => {
    if e.name() == "TIMESTAMP" {
      e.set("this", "SYSTEM_TIME")
    }
    g.version_sql(e)
  }
  m[Contains] = (g, e) => {
    let mut this = e.this()
    let mut expr = e.expression()
    match (this, expr) {
      (Some(a), Some(b)) if a.kind == Lower && b.kind == Lower => {
        this = a.this()
        expr = b.this()
      }
      _ => ()
    }
    g.func("CONTAINS_SUBSTR", [this, expr, e.arg("json_scope")])
  }
  m[ParseJSON] = (g, e) => {
    if e.has("is_literal") {
      return "JSON \{g.sql_key(e, "this")}"
    }
    g.parsejson_sql(e)
  }
  d.gen_fns.hooks.cast_sql = Some((g, e, safe_prefix) => {
    // This ensures that inline type-annotated ARRAY literals like ARRAY<INT64>[1, 2, 3]
    // are roundtripped unaffected. The inner check excludes ARRAY(SELECT ...) expressions,
    // because they aren't literals and so the above syntax is invalid BigQuery.
    match e.this() {
      Some(this) if this.kind == Array => {
        let has_query = match this.expressions().get(0) {
          Some(elem) => elem.find([Query]) is Some(_)
          None => false
        }
        if !has_query {
          return "\{g.sql_key(e, "to")}\{g.sql(Some(this))}"
        }
      }
      _ => ()
    }
    g.cast_sql(e, safe_prefix?)
  })
  m[ClusterProperty] = (g, e) => {
    if e.has("this") {
      g.unsupported("Unsupported CLUSTER BY \{g.sql_key(e, "this")}")
      return ""
    }
    g.op_expressions("CLUSTER BY", e)
  }
}

///|
fn bracket_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = e.this()
  let expressions = e.expressions()
  match this {
    Some(t) if expressions.length() == 1 && t.is_type([STRUCT]) => {
      let mut a = expressions[0]
      if a.get_type() is None {
        a = @core.gen_annotate_types(a, g.dialect)
      }
      match a.get_type() {
        Some(ty) if ty.is_type(@core.dtype_text_types) =>
          // BQ doesn't support bracket syntax with string values for structs
          return "\{g.sql(this)}.\{a.name()}"
        _ => ()
      }
    }
    _ => ()
  }
  let mut expressions_sql = g.expressions(expression=e, flat=true)
  // Python compares with `==`, so booleans compare equal to 0 / 1
  let offset : Int64? = match e.get("offset") {
    Some(Int(i)) => Some(i)
    Some(Bool(b)) => Some(if b { 1 } else { 0 })
    Some(Node(n)) if n.is_int() => n.to_py_int()
    Some(_) => Some(-1)
    None => None
  }
  match offset {
    Some(0) => expressions_sql = "OFFSET(\{expressions_sql})"
    Some(1) => expressions_sql = "ORDINAL(\{expressions_sql})"
    Some(o) => g.unsupported("Unsupported array offset: \{o}")
    None => ()
  }
  if e.has("safe") {
    expressions_sql = "SAFE_\{expressions_sql}"
  }
  "\{g.sql(this)}[\{expressions_sql}]"
}
