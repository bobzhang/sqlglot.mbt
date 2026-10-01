// Port of sqlglot/generators/mysql.py

///|
/// MySQLGenerator class attributes that child dialects (Doris, StarRocks, ...)
/// override. They are read at call time through `settings_of(g.dialect)`.
pub(all) struct MySQLSettings {
  mut varchar_requires_size : Bool
  /// `CAST_MAPPING`
  mut cast_mapping : Map[@core.DType, String]
  /// `TIMESTAMP_FUNC_TYPES`
  mut timestamp_func_types : Array[@core.DType]
  /// `SQL_SECURITY_VIEW_LOCATION`
  mut sql_security_view_location : @core.PropertiesLocation
}

///|
let settings_registry : Map[String, MySQLSettings] = Map([])

///|
fn default_settings() -> MySQLSettings {
  {
    varchar_requires_size: true,
    cast_mapping: Map::from_array([
      (@core.DType::LONGTEXT, "CHAR"),
      (@core.DType::LONGBLOB, "CHAR"),
      (@core.DType::MEDIUMBLOB, "CHAR"),
      (@core.DType::MEDIUMTEXT, "CHAR"),
      (@core.DType::TEXT, "CHAR"),
      (@core.DType::TINYBLOB, "CHAR"),
      (@core.DType::TINYTEXT, "CHAR"),
      (@core.DType::VARCHAR, "CHAR"),
      (@core.DType::BIGINT, "SIGNED"),
      (@core.DType::BOOLEAN, "SIGNED"),
      (@core.DType::INT, "SIGNED"),
      (@core.DType::SMALLINT, "SIGNED"),
      (@core.DType::TINYINT, "SIGNED"),
      (@core.DType::MEDIUMINT, "SIGNED"),
      (@core.DType::UBIGINT, "UNSIGNED"),
    ]),
    timestamp_func_types: [TIMESTAMPTZ, TIMESTAMPLTZ],
    sql_security_view_location: PostCreate,
  }
}

///|
/// Registers the MySQL generator class attributes of a (child) dialect, starting
/// from a copy of its parent's settings.
pub fn register_settings(
  d : @core.Dialect,
  update : (MySQLSettings) -> Unit,
) -> Unit {
  let parent = match d.parent {
    Some(p) => settings_of(p)
    None => default_settings()
  }
  let s = {
    ..parent,
    cast_mapping: Map::from_iter(parent.cast_mapping.iter()),
  }
  update(s)
  settings_registry[d.name] = s
}

///|
/// The MySQL generator class attributes of `d` (or of its nearest ancestor).
pub fn settings_of(d : @core.Dialect) -> MySQLSettings {
  match settings_registry.get(d.name) {
    Some(s) => s
    None =>
      match d.parent {
        Some(p) => settings_of(p)
        None => default_settings()
      }
  }
}

///|
let unsigned_type_mapping : Array[@core.DType] = [
  UBIGINT,
  UINT,
  UMEDIUMINT,
  USMALLINT,
  UTINYINT,
  UDECIMAL,
  UDOUBLE,
]

///|
fn date_trunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let expr = g.sql_key(e, "this")
  let unit = match e.arg("unit") {
    Some(u) if u.kind == WeekStart => g.weekstart_name(u)
    _ => @core.py_upper(e.text("unit"))
  }
  let (concat, date_format) = match unit {
    "WEEK" => ("CONCAT(YEAR(\{expr}), ' ', WEEK(\{expr}, 1), ' 1')", "%Y %u %w")
    "MONTH" => ("CONCAT(YEAR(\{expr}), ' ', MONTH(\{expr}), ' 1')", "%Y %c %e")
    "QUARTER" =>
      ("CONCAT(YEAR(\{expr}), ' ', QUARTER(\{expr}) * 3 - 2, ' 1')", "%Y %c %e")
    "YEAR" => ("CONCAT(YEAR(\{expr}), ' 1 1')", "%Y %c %e")
    _ => {
      if unit != "DAY" {
        g.unsupported("Unexpected interval unit: \{unit}")
      }
      return g.func("DATE", [expr])
    }
  }
  g.func("STR_TO_DATE", [concat, "'\{date_format}'"])
}

///|
fn str_to_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.func("STR_TO_DATE", [e.this(), g.format_time(e)])
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let timestamp = e.this()
  match scale {
    None => return g.func("FROM_UNIXTIME", [timestamp, g.format_time(e)])
    Some(s) if s == @core.literal_number("0") =>
      return g.func("FROM_UNIXTIME", [timestamp, g.format_time(e)])
    Some(s) =>
      g.func("FROM_UNIXTIME", [
        Some(
          @core.mk(Div, [
            ("this", timestamp),
            (
              "expression",
              @core.mk(Anonymous, [
                ("this", "POW"),
                ("expressions", [@core.literal_number("10"), s]),
              ]),
            ),
          ]),
        ),
        g.format_time(e),
      ])
  }
}

///|
/// Python `date_add_sql(kind)`.
pub fn date_add_sql(kind : String) -> @core.GenFn {
  (g, e) => {
    g.func("DATE_\{kind}", [
      e.get("this"),
      Some(
        @core.Value::Node(
          @core.mk(Interval, [
            ("this", e.expression()),
            ("unit", @core.unit_to_var(e)),
          ]),
        ),
      ),
    ])
  }
}

///|
fn ts_or_ds_to_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("format") {
    str_to_date_sql(g, e)
  } else {
    g.func("DATE", [e.this()])
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
  t[ArrayAgg] = @core.rename_func("GROUP_CONCAT")
  t[BitwiseAndAgg] = @core.rename_func("BIT_AND")
  t[BitwiseOrAgg] = @core.rename_func("BIT_OR")
  t[BitwiseXorAgg] = @core.rename_func("BIT_XOR")
  t[BitwiseCount] = @core.rename_func("BIT_COUNT")
  t[Chr] = (g, e) => g.chr_sql_v(e, name="CHAR")
  t[CurrentDate] = @core.no_paren_current_date_sql
  t[CurrentVersion] = @core.rename_func("VERSION")
  t[DateDiff] = @core.remove_ts_or_ds_to_date(
    to_sql=(g, e) => g.func("DATEDIFF", [e.this(), e.expression()]),
    args=["this", "expression"],
  )
  t[DateAdd] = date_add_sql("ADD")
  t[DateStrToDate] = @core.datestrtodate_sql
  t[DateSub] = date_add_sql("SUB")
  t[DateTrunc] = date_trunc_sql
  t[Day] = @core.remove_ts_or_ds_to_date()
  t[DayOfMonth] = @core.remove_ts_or_ds_to_date(
    to_sql=@core.rename_func("DAYOFMONTH"),
  )
  t[DayOfWeek] = @core.remove_ts_or_ds_to_date(
    to_sql=@core.rename_func("DAYOFWEEK"),
  )
  t[DayOfYear] = @core.remove_ts_or_ds_to_date(
    to_sql=@core.rename_func("DAYOFYEAR"),
  )
  t[GroupConcat] = (g, e) => {
    let sep = g.sql_key(e, "separator")
    let sep = if sep == "" { "','" } else { sep }
    "GROUP_CONCAT(\{g.sql_key(e, "this")} SEPARATOR \{sep})"
  }
  t[ILike] = @core.no_ilike_sql
  // https://dev.mysql.com/doc/refman/9.7/en/flow-control-functions.html#function_if
  t[If] = @core.if_sql_str("NULL")
  t[JSONExtractScalar] = (g, e) => @core.arrow_json_extract_sql(g, e)
  t[Length] = @core.length_or_char_length_sql
  t[LogicalOr] = @core.rename_func("MAX")
  t[LogicalAnd] = @core.rename_func("MIN")
  t[Max] = @core.max_or_greatest
  t[Min] = @core.min_or_least
  t[Month] = @core.remove_ts_or_ds_to_date()
  t[NullSafeEQ] = (g, e) => g.binary(e, "<=>")
  t[NullSafeNEQ] = (g, e) => "NOT \{g.binary(e, "<=>")}"
  t[NumberToStr] = @core.rename_func("FORMAT")
  t[Pivot] = @core.no_pivot_sql
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.eliminate_semi_and_anti_joins, @core.eliminate_qualify,
    @core.eliminate_full_outer_join, @core.unnest_generate_date_array_using_recursive_cte,
  ])
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(g, e, func_name="LOCATE", supports_position=true)
  }
  t[StrToDate] = str_to_date_sql
  t[StrToTime] = str_to_date_sql
  t[Stuff] = @core.rename_func("INSERT")
  t[SessionUser] = (_, _) => "SESSION_USER()"
  t[TableSample] = @core.no_tablesample_sql
  t[TimeFromParts] = @core.rename_func("MAKETIME")
  t[TimestampAdd] = @core.date_add_interval_sql("DATE", "ADD")
  t[TimestampDiff] = (g, e) => {
    g.func("TIMESTAMPDIFF", [
      @core.unit_to_var(e),
      e.get("expression"),
      e.get("this"),
    ])
  }
  t[TimestampSub] = @core.date_add_interval_sql("DATE", "SUB")
  t[TimeStrToUnix] = @core.rename_func("UNIX_TIMESTAMP")
  t[TimeStrToTime] = (g, e) => {
    @core.timestrtotime_sql(g, e, include_precision=!e.has("zone"))
  }
  t[TimeToStr] = @core.remove_ts_or_ds_to_date(to_sql=(g, e) => {
    g.func("DATE_FORMAT", [e.this(), g.format_time(e)])
  })
  t[Trim] = (g, e) => @core.trim_sql(g, e)
  t[Trunc] = @core.rename_func("TRUNCATE")
  t[TryCast] = @core.no_trycast_sql
  t[TsOrDsAdd] = date_add_sql("ADD")
  t[TsOrDsDiff] = (g, e) => g.func("DATEDIFF", [e.this(), e.expression()])
  t[TsOrDsToDate] = ts_or_ds_to_date_sql
  t[Unicode] = (g, e) => "ORD(CONVERT(\{g.sql(e.this())} USING utf32))"
  t[UnixToTime] = unix_to_time_sql
  t[Week] = @core.remove_ts_or_ds_to_date()
  t[WeekOfYear] = @core.remove_ts_or_ds_to_date(
    to_sql=@core.rename_func("WEEKOFYEAR"),
  )
  t[Year] = @core.remove_ts_or_ds_to_date()
  t[UtcTimestamp] = @core.rename_func("UTC_TIMESTAMP")
  t[UtcTime] = @core.rename_func("UTC_TIME")
  let m = d.gen_fns.methods
  m[MakeInterval] = makeinterval_sql
  m[ComputedColumnConstraint] = (g, e) => {
    let persisted = if e.has("persisted") { "STORED" } else { "VIRTUAL" }
    "GENERATED ALWAYS AS (\{g.sql(Some(e.this_().unnest()))}) \{persisted}"
  }
  m[Array] = (g, e) => {
    g.unsupported("Arrays are not supported by MySQL")
    g.function_fallback_sql(e)
  }
  m[ArrayContainsAll] = (g, e) => {
    g.unsupported("Array operations are not supported by MySQL")
    g.function_fallback_sql(e)
  }
  m[ArrayContainedBy] = (g, e) => {
    g.unsupported("Array operations are not supported by MySQL")
    g.function_fallback_sql(e)
  }
  m[DPipe] = (g, e) => {
    let args : Array[&@core.SqlArg] = []
    for x in e.flatten() {
      args.push(x)
    }
    g.func("CONCAT", args)
  }
  m[Extract] = (g, e) => {
    let unit = e.name()
    if unit != "" && @core.py_lower(unit) == "epoch" {
      return g.func("UNIX_TIMESTAMP", [e.expression()])
    }
    g.extract_sql(e)
  }
  m[DataType] = datatype_sql
  m[JSONArrayContains] = (g, e) => {
    "\{g.sql_key(e, "this")} MEMBER OF(\{g.sql_key(e, "expression")})"
  }
  d.gen_fns.hooks.cast_sql = Some(cast_sql)
  m[Show] = show_sql
  // To avoid TO keyword in ALTER ... RENAME statements.
  // It's moved from Doris, because it's the same for all MySQL, Doris, and StarRocks.
  d.gen_fns.hooks.alterrename_sql = Some((g, e, _) => {
    g.alterrename_sql(e, include_to=false)
  })
  m[AlterColumn] = altercolumn_sql
  m[TimestampTrunc] = timestamptrunc_sql
  m[ConvertTimezone] = (g, e) => {
    g.func("CONVERT_TZ", [
      e.arg("timestamp"),
      e.arg("source_tz"),
      e.arg("target_tz"),
    ])
  }
  m[AtTimeZone] = (g, e) => {
    g.unsupported("AT TIME ZONE is not supported by MySQL")
    g.sql(e.this())
  }
  m[IsAscii] = (g, e) => "REGEXP_LIKE(\{g.sql(e.this())}, '^[[:ascii:]]*$')"
  m[IgnoreNulls] = (g, e) => {
    // https://dev.mysql.com/doc/refman/8.4/en/window-function-descriptions.html
    g.unsupported("MySQL does not support IGNORE NULLS.")
    g.sql(e.this())
  }
  m[CurrentSchema] = (g, e) => {
    g.unsupported_args(e, ["this"])
    g.func("SCHEMA", [])
  }
  m[Partition] = (g, e) => {
    match e.parent {
      Some(parent) if parent.kind.is_any([
          PartitionByRangeProperty,
          PartitionByListProperty,
        ]) => g.expressions(expression=e, flat=true)
      _ => g.partition_sql(e)
    }
  }
  m[PartitionByRangeProperty] = (g, e) => partition_by_sql(g, e, "RANGE")
  m[PartitionByListProperty] = (g, e) => partition_by_sql(g, e, "LIST")
  m[PartitionList] = (g, e) => {
    let name = g.sql_key(e, "this")
    let values = g.expressions(expression=e, flat=true)
    "PARTITION \{name} VALUES IN (\{values})"
  }
  m[PartitionRange] = (g, e) => {
    let name = g.sql_key(e, "this")
    let values = g.expressions(expression=e, flat=true)
    "PARTITION \{name} VALUES LESS THAN (\{values})"
  }
  d.gen_fns.hooks.locate_properties = Some(locate_properties)
}

///|
let make_interval_unit_aliases : Map[String, String] = {
  "years": "year",
  "months": "month",
  "weeks": "week",
  "days": "day",
  "hours": "hour",
  "minutes": "minute",
  "mins": "minute",
  "seconds": "second",
  "secs": "second",
}

///|
fn makeinterval_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let intervals : Array[@core.Expr] = []
  for arg_key, v in e.args {
    guard v is Node(value) else { continue }
    let (unit_name, value) = if value.kind == Kwarg {
      let n = @core.py_lower(value.this_().name())
      let unit_name = match make_interval_unit_aliases.get(n) {
        Some(u) => u
        None => n
      }
      (unit_name, value.expression_())
    } else {
      (arg_key, value)
    }
    intervals.push(
      @core.mk(Interval, [
        ("this", value.copy()),
        ("unit", @core.var_(@core.py_upper(unit_name))),
      ]),
    )
  }
  if intervals.is_empty() {
    return g.function_fallback_sql(e)
  }
  let sep = match e.parent {
    Some(parent) if parent.kind == Sub &&
      parent.expression() is Some(pe) &&
      physical_equal(pe, e) => " - "
    _ => " + "
  }
  let parts = []
  for interval in intervals {
    parts.push(g.sql(Some(interval)))
  }
  parts.join(sep)
}

///|
/// Python `MySQLGenerator.locate_properties`.
pub fn locate_properties(
  g : @core.Generator,
  properties : @core.Expr,
) -> @core.PropLocs raise @core.SqlglotError {
  let locations = g.locate_properties_base(properties)
  // MySQL puts SQL SECURITY before VIEW but after the schema for functions/procedures
  match properties.parent {
    Some(create) if create.kind == Create && create.text("kind") == "VIEW" => {
      let post_schema = match locations.get(PostSchema) {
        Some(l) => l
        None => {
          let l = []
          locations[PostSchema] = l
          l
        }
      }
      for i, p in post_schema {
        if p.kind == SqlSecurityProperty {
          post_schema.remove(i) |> ignore
          let loc = settings_of(g.dialect).sql_security_view_location
          match locations.get(loc) {
            Some(l) => l.push(p)
            None => locations[loc] = [p]
          }
          break
        }
      }
    }
    _ => ()
  }
  locations
}

///|
/// Python `MySQLGenerator.datatype_sql`.
pub fn datatype_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if settings_of(g.dialect).varchar_requires_size &&
    e.is_type([VARCHAR]) &&
    e.expressions().is_empty() {
    // `VARCHAR` must always have a size - if it doesn't, we always generate `TEXT`
    return "TEXT"
  }
  // https://dev.mysql.com/doc/refman/8.0/en/numeric-type-syntax.html
  let result = g.datatype_sql(e)
  match e.get("this") {
    Some(DT(dt)) if unsigned_type_mapping.contains(dt) => "\{result} UNSIGNED"
    _ => result
  }
}

///|
/// Python `MySQLGenerator.cast_sql`.
pub fn cast_sql(
  g : @core.Generator,
  e : @core.Expr,
  _safe_prefix : String?,
) -> String raise @core.SqlglotError {
  let settings = settings_of(g.dialect)
  let to = e.arg("to")
  match to {
    Some(to) =>
      match to.get("this") {
        Some(DT(dt)) => {
          if settings.timestamp_func_types.contains(dt) {
            return g.func("TIMESTAMP", [e.this()])
          }
          match settings.cast_mapping.get(dt) {
            Some(mapped) => to.set("this", mapped)
            None => ()
          }
        }
        _ => ()
      }
    None => ()
  }
  g.cast_sql(e)
}

///|
fn prefixed_sql(
  g : @core.Generator,
  prefix : String,
  e : @core.Expr,
  arg : String,
) -> String raise @core.SqlglotError {
  let sql = g.sql_key(e, arg)
  if sql != "" {
    " \{prefix} \{sql}"
  } else {
    ""
  }
}

///|
fn oldstyle_limit_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let limit = g.sql_key(e, "limit")
  let offset = g.sql_key(e, "offset")
  if limit != "" {
    let limit_offset = if offset != "" { "\{offset}, \{limit}" } else { limit }
    return " LIMIT \{limit_offset}"
  }
  ""
}

///|
/// Python `MySQLGenerator.show_sql`.
pub fn show_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let name = e.name()
  let this = " \{name}"
  let full = if e.has("full") { " FULL" } else { "" }
  let global_ = if e.has("global_") { " GLOBAL" } else { "" }
  let mut target = g.sql_key(e, "target")
  // SHOW CREATE ... takes a possibly qualified name, it has no FROM clause
  // https://dev.mysql.com/doc/refman/8.4/en/show-create-table.html
  let db_id = g.sql_key(e, "db")
  let db = if name.has_prefix("CREATE") && db_id != "" {
    target = "\{db_id}.\{target}"
    ""
  } else {
    prefixed_sql(g, "FROM", e, "db")
  }
  target = if target != "" { " \{target}" } else { "" }
  if name == "COLUMNS" || name == "INDEX" {
    target = " FROM\{target}"
  } else if name == "GRANTS" {
    target = " FOR\{target}"
  } else if name == "LINKS" || name == "PARTITIONS" {
    target = if target != "" { " ON\{target}" } else { "" }
  } else if name == "PROJECTIONS" {
    target = if target != "" { " ON TABLE\{target}" } else { "" }
  }
  let like = prefixed_sql(g, "LIKE", e, "like")
  let where_ = g.sql_key(e, "where")
  let types = g.expressions(expression=e, key="types")
  let types = if types != "" { " \{types}" } else { types }
  let query = prefixed_sql(g, "FOR QUERY", e, "query")
  let (offset, limit) = if name == "PROFILE" {
    (
      prefixed_sql(g, "OFFSET", e, "offset"),
      prefixed_sql(g, "LIMIT", e, "limit"),
    )
  } else {
    ("", oldstyle_limit_sql(g, e))
  }
  let log = prefixed_sql(g, "IN", e, "log")
  let position = prefixed_sql(g, "FROM", e, "position")
  let channel = prefixed_sql(g, "FOR CHANNEL", e, "channel")
  let mutex_or_status = if name == "ENGINE" {
    if e.has("mutex") {
      " MUTEX"
    } else {
      " STATUS"
    }
  } else {
    ""
  }
  let for_table = prefixed_sql(g, "FOR TABLE", e, "for_table")
  let for_group = prefixed_sql(g, "FOR GROUP", e, "for_group")
  let for_user = prefixed_sql(g, "FOR USER", e, "for_user")
  let for_role = prefixed_sql(g, "FOR ROLE", e, "for_role")
  let into_outfile = prefixed_sql(g, "INTO OUTFILE", e, "into_outfile")
  let json = if e.has("json") { " JSON" } else { "" }
  "SHOW\{full}\{global_}\{this}\{json}\{target}\{for_table}\{types}\{db}\{query}\{log}\{position}\{channel}\{mutex_or_status}\{like}\{where_}\{offset}\{limit}\{for_group}\{for_user}\{for_role}\{into_outfile}"
}

///|
/// Python `MySQLGenerator.altercolumn_sql`.
pub fn altercolumn_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let dtype = g.sql_key(e, "dtype")
  if dtype == "" {
    return g.altercolumn_sql(e)
  }
  if e.has("exists") {
    g.unsupported("ALTER COLUMN IF EXISTS is not supported by this dialect")
  }
  let this = g.sql_key(e, "this")
  let null_constraint = g.alter_column_null_constraint_sql(e)
  "MODIFY COLUMN \{this} \{dtype}\{null_constraint}"
}

///|
/// Python `MySQLGenerator.timestamptrunc_sql`.
pub fn timestamptrunc_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut unit = e.arg("unit")
  match unit {
    Some(u) if u.kind == WeekStart =>
      unit = Some(@core.var_(g.weekstart_name(u)))
    _ => ()
  }
  // Pick an old-enough date to avoid negative timestamp diffs
  let start_ts = "'0000-01-01 00:00:00'"
  // Source: https://stackoverflow.com/a/32955740
  // build_date_delta(exp.TimestampDiff)([unit, start_ts, expression.this])
  let timestamp_diff = @core.mk(TimestampDiff, [
    ("this", e.get("this")),
    ("expression", Some(@core.Value::Str(start_ts))),
    ("unit", unit),
  ])
  let interval = @core.mk(Interval, [("this", timestamp_diff), ("unit", unit)])
  // build_date_delta_with_interval(exp.DateAdd)([start_ts, interval])
  let dateadd = @core.mk(DateAdd, [
    ("this", Some(@core.Value::Str(start_ts))),
    ("expression", interval.this()),
    ("unit", @core.unit_to_str(interval)),
  ])
  g.sql(Some(dateadd))
}

///|
fn partition_by_sql(
  g : @core.Generator,
  e : @core.Expr,
  kind : String,
) -> String raise @core.SqlglotError {
  let partitions = g.expressions(
    expression=e,
    key="partition_expressions",
    flat=true,
  )
  let create = g.expressions(expression=e, key="create_expressions", flat=true)
  "PARTITION BY \{kind} (\{partitions}) (\{create})"
}
