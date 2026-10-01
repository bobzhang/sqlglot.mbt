// Port of sqlglot/generators/singlestore.py

///|
/// Python `@unsupported_args(*args)(f)`.
fn ua(args : Array[String], f : @core.GenFn) -> @core.GenFn {
  (g, e) => {
    g.unsupported_args(e, args)
    f(g, e)
  }
}

///|
/// `format_time` with MySQL's INVERSE_TIME_MAPPING / INVERSE_TIME_TRIE
/// (`MYSQL_INVERSE_TIME_MAPPING` / `MYSQL_INVERSE_TIME_TRIE`).
fn mysql_format_time(
  g : @core.Generator,
  e : @core.Expr,
) -> String? raise @core.SqlglotError {
  let m = @mysql.dialect()
  g.format_time(
    e,
    inverse_time_mapping=m.cfg.inverse_time_mapping,
    inverse_time_trie=m.inverse_time_trie,
  )
}

///|
fn hex_value(s : String) -> Int {
  let mut n = 0
  for c in s {
    let d = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      0
    }
    n = n * 16 + d
  }
  n
}

///|
fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.get("unit") is Some(_) {
    @core.timestampdiff_sql(g, e)
  } else {
    g.func("DATEDIFF", [e.this(), e.expression()])
  }
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  d.gen_fns.hooks.unicode_substitute = Some(code => {
    hex_value(code).unsafe_to_char().to_string()
  })
  d.gen_fns.type_param_settings[TIMESTAMP_MS] = ([6], [])
  let t = d.gen_fns.transforms
  t.remove(JSONExtractScalar)
  t.remove(CurrentDate)
  t[TsOrDsToDate] = (g, e) => {
    if e.has("format") {
      g.func("TO_DATE", [e.this(), g.format_time(e)])
    } else {
      g.func("DATE", [e.this()])
    }
  }
  t[StrToTime] = (g, e) => g.func("TO_TIMESTAMP", [e.this(), g.format_time(e)])
  t[ToChar] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[StrToDate] = (g, e) => {
    g.func("STR_TO_DATE", [e.this(), mysql_format_time(g, e)])
  }
  t[TimeToStr] = (g, e) => {
    g.func("DATE_FORMAT", [e.this(), mysql_format_time(g, e)])
  }
  t[Date] = ua(["zone", "expressions"], @core.rename_func("DATE"))
  t[Cast] = ua(["format", "action", "default"], (g, e) => {
    "\{g.sql_key(e, "this")} :> \{g.sql_key(e, "to")}"
  })
  t[TryCast] = ua(["format", "action", "default"], (g, e) => {
    "\{g.sql_key(e, "this")} !:> \{g.sql_key(e, "to")}"
  })
  t[CastToStrType] = (g, e) => {
    let to = @core.datatype_from_str(e.arg("to").unwrap().name())
    g.sql(Some(@core.cast_to(e.this_(), to)))
  }
  t[StrToUnix] = ua(["format"], @core.rename_func("UNIX_TIMESTAMP"))
  t[TimeToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[TimeStrToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[UnixSeconds] = @core.rename_func("UNIX_TIMESTAMP")
  t[UnixToStr] = (g, e) => {
    g.func("FROM_UNIXTIME", [e.this(), mysql_format_time(g, e)])
  }
  t[UnixToTime] = ua(["scale", "zone", "hours", "minutes"], (g, e) => {
    g.func("FROM_UNIXTIME", [e.this(), mysql_format_time(g, e)])
  })
  t[UnixToTimeStr] = (g, e) => "FROM_UNIXTIME(\{g.sql_key(e, "this")}) :> TEXT"
  t[DateBin] = ua(["unit", "zone"], (g, e) => {
    g.func("TIME_BUCKET", [e.this(), e.expression(), e.arg("origin")])
  })
  t[TimeStrToDate] = (g, e) => g.sql(Some(@core.cast_(e.this_(), DATE)))
  t[FromTimeZone] = (g, e) => {
    g.func("CONVERT_TZ", [
      Some(@core.Value::Node(e.this_())),
      e.get("zone"),
      Some(@core.Value::Str("'UTC'")),
    ])
  }
  t[DiToDate] = (g, e) => {
    "STR_TO_DATE(\{g.sql_key(e, "this")}, \{g.dialect.cfg.dateint_format})"
  }
  t[DateToDi] = (g, e) => {
    "(DATE_FORMAT(\{g.sql_key(e, "this")}, \{g.dialect.cfg.dateint_format}) :> INT)"
  }
  t[TsOrDiToDi] = (g, e) => {
    "(DATE_FORMAT(\{g.sql_key(e, "this")}, \{g.dialect.cfg.dateint_format}) :> INT)"
  }
  t[Time] = ua(["zone"], (g, e) => "\{g.sql_key(e, "this")} :> TIME")
  t[DatetimeAdd] = @core.remove_ts_or_ds_to_date(
    to_sql=@mysql.date_add_sql("ADD"),
  )
  t[DatetimeTrunc] = ua(["zone"], @core.timestamptrunc_sql())
  t[DatetimeSub] = @core.date_add_interval_sql("DATE", "SUB")
  t[DatetimeDiff] = @core.timestampdiff_sql
  t[DateTrunc] = ua(["zone"], @core.timestamptrunc_sql())
  t[DateDiff] = ua(["zone"], date_diff_sql)
  t[TsOrDsDiff] = date_diff_sql
  t[TimestampTrunc] = ua(["zone"], @core.timestamptrunc_sql())
  t[CurrentDatetime] = (g, _) => {
    g.sql(
      Some(
        cast_to_time6(
          Some(@core.mk1(CurrentTimestamp, @core.literal_number("6"))),
          time_type=DATETIME,
        ),
      ),
    )
  }
  t[JSONExtract] = ua(
    [
      "only_json_types", "expressions", "variant_extract", "json_query", "option",
      "quote", "on_condition", "requires_json",
    ],
    @core.json_extract_segments("JSON_EXTRACT_JSON"),
  )
  t[JSONBExtract] = @core.json_extract_segments("BSON_EXTRACT_BSON")
  t[JSONPathKey] = @core.json_path_key_only_name
  t[JSONPathSubscript] = (g, e) => g.json_path_part(e.get("this"))
  t[JSONPathRoot] = (_, _) => ""
  t[JSONFormat] = ua(["options", "is_json"], @core.rename_func("JSON_PRETTY"))
  t[JSONArrayAgg] = ua(["null_handling", "return_type", "strict"], (g, e) => {
    g.func("JSON_AGG", [e.this()], suffix="\{g.sql_key(e, "order")})")
  })
  t[JSONArray] = ua(
    ["null_handling", "return_type", "strict"],
    @core.rename_func("JSON_BUILD_ARRAY"),
  )
  t[JSONBExists] = (g, e) => {
    g.func("BSON_MATCH_ANY_EXISTS", [e.this(), e.arg("path")])
  }
  t[JSONExists] = (g, e) => {
    if e.has("from_dcolonqmark") {
      "\{g.sql(e.this())}::?\{g.sql_key(e, "path")}"
    } else {
      g.func("JSON_MATCH_ANY_EXISTS", [e.get("this"), e.get("path")])
    }
  }
  t[JSONObject] = ua(
    ["null_handling", "unique_keys", "return_type", "encoding"],
    @core.rename_func("JSON_BUILD_OBJECT"),
  )
  t[DayOfWeekIso] = (g, e) => "((\{g.func("DAYOFWEEK", [e.this()])} % 7) + 1)"
  t[DayOfMonth] = @core.rename_func("DAY")
  t[Hll] = @core.rename_func("APPROX_COUNT_DISTINCT")
  t[ApproxDistinct] = @core.rename_func("APPROX_COUNT_DISTINCT")
  t[CountIf] = @core.count_if_to_sum
  t[LogicalOr] = (g, e) => "MAX(ABS(\{g.sql_key(e, "this")}))"
  t[LogicalAnd] = (g, e) => "MIN(ABS(\{g.sql_key(e, "this")}))"
  t[ApproxQuantile] = ua(["accuracy", "weight"], (g, e) => {
    g.func("APPROX_PERCENTILE", [
      e.this(),
      e.arg("quantile"),
      e.arg("error_tolerance"),
    ])
  })
  t[Variance] = @core.rename_func("VAR_SAMP")
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[Xor] = @core.bool_xor_sql
  t[Cbrt] = (g, e) => {
    g.sql(
      Some(
        @core.mk(Pow, [
          ("this", e.this()),
          (
            "expression",
            @core.div_(@core.literal_number("1"), @core.literal_number("3")),
          ),
        ]),
      ),
    )
  }
  t[RegexpLike] = (g, e) => g.binary(e, "RLIKE")
  t[Repeat] = (g, e) => {
    g.func("LPAD", [
      @core.literal_string(""),
      @core.mk(Mul, [
        ("this", @core.var_(g.func("LENGTH", [e.this()]))),
        ("expression", e.arg("times")),
      ]),
      e.this_(),
    ])
  }
  t[IsAscii] = (g, e) => "(\{g.sql_key(e, "this")} RLIKE '^[\u{0}-\u{7f}]*$')"
  t[MD5Digest] = (g, e) => g.func("UNHEX", [g.func("MD5", [e.this()])])
  t[Contains] = @core.rename_func("INSTR")
  t[RegexpExtractAll] = ua(["position", "occurrence", "group"], (g, e) => {
    g.func("REGEXP_MATCH", [e.this(), e.expression(), e.arg("parameters")])
  })
  t[RegexpExtract] = ua(["group"], (g, e) => {
    g.func("REGEXP_SUBSTR", [
      e.this(),
      e.expression(),
      e.arg("position"),
      e.arg("occurrence"),
      e.arg("parameters"),
    ])
  })
  t[StartsWith] = (g, e) => {
    g.func("REGEXP_INSTR", [
      e.this(),
      g.func("CONCAT", [Some(@core.literal_string("^")), e.expression()]),
    ])
  }
  t[FromBase] = (g, e) => {
    g.func("CONV", [e.this(), e.expression(), Some(@core.literal_number("10"))])
  }
  t[RegexpILike] = (g, e) => {
    g.binary(
      @core.mk(RegexpLike, [
        ("this", @core.mk1(Lower, e.this())),
        ("expression", @core.mk1(Lower, e.expression())),
      ]),
      "RLIKE",
    )
  }
  t[Stuff] = (g, e) => {
    let start = e.arg("start").unwrap()
    g.func("CONCAT", [
      g.func("SUBSTRING", [
        e.this(),
        Some(@core.literal_number("1")),
        Some(@core.sub_(start, @core.literal_number("1"))),
      ]),
      g.sql(e.expression()),
      g.func("SUBSTRING", [
        e.this(),
        Some(@core.add_(start, e.arg("length").unwrap())),
      ]),
    ])
  }
  t[National] = (g, e) => g.national_sql(e, prefix="")
  t[Reduce] = ua(["finish"], (g, e) => {
    g.func("REDUCE", [e.arg("initial"), e.this(), e.arg("merge")])
  })
  t[MatchAgainst] = ua(["modifier"], (g, e) => g.matchagainst_sql(e))
  t[Show] = ua(
    [
      "history", "terse", "offset", "starts_with", "limit", "from_", "scope", "scope_kind",
      "mutex", "query", "channel", "log", "types", "privileges",
    ],
    @mysql.show_sql,
  )
  t[Describe] = ua(["style", "kind", "expressions", "partition", "format"], (
    g,
    e,
  ) => g.describe_sql(e))
  let m = d.gen_fns.methods
  m[JSONExtractScalar] = (g, e) => {
    let func_name = match e.get("json_type") {
      None => "JSON_EXTRACT_JSON"
      Some(v) => "JSON_EXTRACT_\{py_format(v)}"
    }
    @core.json_extract_segments(func_name)(g, e)
  }
  m[JSONBExtractScalar] = (g, e) => {
    let func_name = match e.get("json_type") {
      None => "BSON_EXTRACT_BSON"
      Some(v) => "BSON_EXTRACT_\{py_format(v)}"
    }
    @core.json_extract_segments(func_name)(g, e)
  }
  m[JSONExtractArray] = (g, e) => {
    g.unsupported("Arrays are not supported in SingleStore")
    g.function_fallback_sql(e)
  }
  m[JSONValue] = (g, e) => {
    if e.has("on_condition") {
      g.unsupported("JSON_VALUE does not support on_condition")
    }
    let mut res = @core.mk(JSONExtractScalar, [
      ("this", e.this()),
      ("expression", e.arg("path")),
      ("json_type", "STRING"),
    ])
    match e.arg("returning") {
      Some(returning) =>
        res = @core.mk(Cast, [("this", res), ("to", returning)])
      None => ()
    }
    g.sql(Some(res))
  }
  m[WithinGroup] = (g, e) => {
    // SingleStore includes trailing NULLs in percentile calculations, so we sort them first
    let mut e = e
    match (e.this(), e.expression()) {
      (Some(this), Some(order)) if this.kind.is_any([
          PercentileCont,
          PercentileDisc,
        ]) &&
        order.kind == Order => {
        e = e.copy()
        for ordered in e.expression_().expressions() {
          ordered.set("nulls_first", true)
        }
      }
      _ => ()
    }
    g.withingroup_sql(e)
  }
  m[All] = (g, e) => {
    g.unsupported("ALL subquery predicate is not supported in SingleStore")
    g.all_sql(e)
  }
  m[JSONArrayContains] = (g, e) => {
    let json_type = @core.py_upper(e.text("json_type"))
    if json_type != "" {
      return g.func("JSON_ARRAY_CONTAINS_\{json_type}", [
        e.expression(),
        e.this(),
      ])
    }
    g.func("JSON_ARRAY_CONTAINS_JSON", [
      Some(@core.Value::Node(e.expression_())),
      Some(@core.Value::Str(g.func("TO_JSON", [e.this()]))),
    ])
  }
  let parent_datatype_sql = m.get(DataType)
  m[DataType] = (g, e) => datatype_sql(g, e, parent_datatype_sql)
  m[Collate] = (g, e) => {
    // SingleStore does not support setting a collation for column in the SELECT query,
    // so we cast column to a LONGTEXT type with specific collation. If the cast is
    // already there (e.g. when regenerating previously generated SQL), don't add
    // another one, so that generation stays idempotent.
    match e.this() {
      Some(this) if this.kind == Cast &&
        this.arg("to") is Some(to) &&
        to.get("this") is Some(DT(LONGTEXT)) => g.binary(e, "COLLATE")
      _ => g.binary(e, ":> LONGTEXT COLLATE")
    }
  }
  m[CurrentDate] = (g, e) => {
    match e.this() {
      Some(timezone) => {
        if timezone.kind.is_a(Literal) &&
          @core.py_lower(timezone.name()) == "utc" {
          return g.func("UTC_DATE", [])
        }
        g.unsupported(
          "CurrentDate with timezone is not supported in SingleStore",
        )
      }
      None => ()
    }
    g.func("CURRENT_DATE", [])
  }
  m[CurrentTime] = (g, e) => current_time_sql(g, e, "TIME", "CurrentTime")
  m[CurrentTimestamp] = (g, e) => {
    current_time_sql(g, e, "TIMESTAMP", "CurrentTimestamp")
  }
  m[StandardHash] = (g, e) => {
    match e.expression() {
      None => g.func("SHA", [e.this()])
      Some(hash_function) if hash_function.kind.is_a(Literal) => {
        let n = @core.py_lower(hash_function.name())
        if n == "sha" {
          return g.func("SHA", [e.this()])
        }
        if n == "md5" {
          return g.func("MD5", [e.this()])
        }
        g.unsupported(
          "\{hash_function.text("this")} hash method is not supported in SingleStore",
        )
        g.func("SHA", [e.this()])
      }
      Some(_) => {
        g.unsupported("STANDARD_HASH function is not supported in SingleStore")
        g.func("SHA", [e.this()])
      }
    }
  }
  m[TruncateTable] = (g, e) => {
    for
      arg_name in [
        "is_database", "exists", "cluster", "identity", "option", "partition",
      ] {
      if e.has(arg_name) {
        g.unsupported("TRUNCATE TABLE does not support \{arg_name}")
      }
    }
    let statements = []
    for table in e.expressions() {
      statements.push("TRUNCATE \{g.sql(Some(table))}")
    }
    statements.join("; ")
  }
  m[RenameColumn] = (g, e) => {
    if e.has("exists") {
      g.unsupported("RENAME COLUMN does not support exists")
    }
    let old_column = g.sql_key(e, "this")
    let new_column = g.sql_key(e, "to")
    "CHANGE \{old_column} \{new_column}"
  }
  let parent_altercolumn_sql = m.get(AlterColumn)
  m[AlterColumn] = (g, e) => {
    for arg_name in ["drop", "comment", "visible", "using"] {
      if e.has(arg_name) {
        g.unsupported("ALTER COLUMN does not support \{arg_name}")
      }
    }
    let alter = match parent_altercolumn_sql {
      Some(f) => f(g, e)
      None => g.altercolumn_sql(e)
    }
    let collate = g.sql_key(e, "collate")
    let collate = if collate != "" { " COLLATE \{collate}" } else { "" }
    "\{alter}\{collate}"
  }
  m[ComputedColumnConstraint] = (g, e) => {
    let this = g.sql_key(e, "this")
    let not_null = if e.has("not_null") { " NOT NULL" } else { "" }
    let type_ = g.sql_key(e, "data_type")
    let type_ = if type_ == "" { "AUTO" } else { type_ }
    "AS \{this} PERSISTED \{type_}\{not_null}"
  }
}

///|
fn current_time_sql(
  g : @core.Generator,
  e : @core.Expr,
  kind : String,
  class_name : String,
) -> String raise @core.SqlglotError {
  match e.this() {
    Some(arg) => {
      if arg.kind.is_a(Literal) && @core.py_lower(arg.name()) == "utc" {
        return g.func("UTC_\{kind}", [])
      }
      if arg.kind.is_a(Literal) && arg.is_number() {
        return g.func("CURRENT_\{kind}", [arg])
      }
      g.unsupported(
        "\{class_name} with timezone is not supported in SingleStore",
      )
    }
    None => ()
  }
  g.func("CURRENT_\{kind}", [])
}

///|
fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
  parent : @core.GenFn?,
) -> String raise @core.SqlglotError {
  for arg_name in ["kind", "values"] {
    if e.has(arg_name) {
      g.unsupported("DATATYPE does not support \{arg_name}")
    }
  }
  if e.has("nested") && !e.is_type([STRUCT]) {
    let value = match e.datatype_this() {
      Some(dt) => dt.value()
      None => e.text("this")
    }
    g.unsupported(
      "Argument 'nested' is not supported for representation of '\{value}' in SingleStore",
    )
  }
  if e.is_type([VARBINARY]) && e.expressions().is_empty() {
    // `VARBINARY` must always have a size - if it doesn't, we always generate `BLOB`
    return "BLOB"
  }
  if e.is_type([DECIMAL32, DECIMAL64, DECIMAL128, DECIMAL256]) {
    let scale = g.expressions(expression=e, flat=true)
    let precision = if e.is_type([DECIMAL32]) {
      "9"
    } else if e.is_type([DECIMAL64]) {
      "18"
    } else if e.is_type([DECIMAL128]) {
      "38"
    } else {
      // 65 is a maximum precision supported in SingleStore
      "65"
    }
    // Python indexes the first character of the joined scale string
    guard scale.get_char(0) is Some(first) else {
      raise @core.ValueError("string index out of range")
    }
    return "DECIMAL(\{precision}, \{first})"
  }
  if e.is_type([VECTOR]) {
    let expressions = e.expressions()
    if expressions.length() == 2 {
      let mut type_name = g.sql(Some(expressions[0]))
      match g.dialect.cfg.inverse_vector_type_aliases.get(type_name) {
        Some(a) => type_name = a
        None => ()
      }
      return "VECTOR(\{g.sql(Some(expressions[1]))}, \{type_name})"
    }
  }
  match parent {
    Some(f) => f(g, e)
    None => g.datatype_sql(e)
  }
}

///|
/// Python f-string formatting of an argument value (`str(expr)` is its base SQL).
fn py_format(v : @core.Value) -> String raise @core.SqlglotError {
  match v {
    Node(e) => @core.expr_to_sql(e)
    Str(s) => s
    Bool(b) => if b { "True" } else { "False" }
    Int(i) => i.to_string()
    DT(d) => d.value()
    List(_) => ""
  }
}
