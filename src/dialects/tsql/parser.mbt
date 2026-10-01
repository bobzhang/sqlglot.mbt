// Port of sqlglot/parsers/tsql.py

///|
let full_format_time_mapping : Map[String, String] = {
  "weekday": "%A",
  "dw": "%A",
  "w": "%A",
  "month": "%B",
  "mm": "%B",
  "m": "%B",
}

///|
let date_delta_interval : Map[String, String] = {
  "year": "year",
  "yyyy": "year",
  "yy": "year",
  "quarter": "quarter",
  "qq": "quarter",
  "q": "quarter",
  "month": "month",
  "mm": "month",
  "m": "month",
  "week": "week",
  "ww": "week",
  "wk": "week",
  "day": "day",
  "dd": "day",
  "d": "day",
}

///|
/// `FORMAT_TIME_MAPPING` of the TSQL dialect class.
let format_time_mapping : Map[String, String] = {
  "y": "%B %Y",
  "d": "%m/%d/%Y",
  "H": "%-H",
  "h": "%-I",
  "s": "%Y-%m-%d %H:%M:%S",
  "D": "%A,%B,%Y",
  "f": "%A,%B,%Y %-I:%M %p",
  "F": "%A,%B,%Y %-I:%M:%S %p",
  "g": "%m/%d/%Y %-I:%M %p",
  "G": "%m/%d/%Y %-I:%M:%S %p",
  "M": "%B %-d",
  "m": "%B %-d",
  "O": "%Y-%m-%dT%H:%M:%S",
  "u": "%Y-%M-%D %H:%M:%S%z",
  "U": "%A, %B %D, %Y %H:%M:%S%z",
  "T": "%-I:%M:%S %p",
  "t": "%-I:%M",
  "Y": "%a %Y",
}

///|
/// Unsupported options:
/// - OPTIMIZE FOR ( @variable_name { UNKNOWN | = <literal_constant> } [ , ...n ] )
/// - TABLE HINT
let options : Map[String, Array[Array[String]]] = {
  "DISABLE_OPTIMIZED_PLAN_FORCING": [],
  "FAST": [],
  "IGNORE_NONCLUSTERED_COLUMNSTORE_INDEX": [],
  "LABEL": [],
  "MAXDOP": [],
  "MAXRECURSION": [],
  "MAX_GRANT_PERCENT": [],
  "MIN_GRANT_PERCENT": [],
  "NO_PERFORMANCE_SPOOL": [],
  "QUERYTRACEON": [],
  "RECOMPILE": [],
  "CONCAT": [["UNION"]],
  "DISABLE": [["EXTERNALPUSHDOWN"], ["SCALEOUTEXECUTION"]],
  "EXPAND": [["VIEWS"]],
  "FORCE": [["EXTERNALPUSHDOWN"], ["ORDER"], ["SCALEOUTEXECUTION"]],
  "HASH": [["GROUP"], ["JOIN"], ["UNION"]],
  "KEEP": [["PLAN"]],
  "KEEPFIXED": [["PLAN"]],
  "LOOP": [["JOIN"]],
  "MERGE": [["JOIN"], ["UNION"]],
  "OPTIMIZE": [["FOR", "UNKNOWN"]],
  "ORDER": [["GROUP"]],
  "PARAMETERIZATION": [["FORCED"], ["SIMPLE"]],
  "ROBUST": [["PLAN"]],
  "USE": [["PLAN"]],
}

///|
let for_xml_options : Map[String, Array[Array[String]]] = {
  "AUTO": [],
  "EXPLICIT": [],
  "TYPE": [],
  "ELEMENTS": [["XSINIL"], ["ABSENT"]],
  "BINARY": [["BASE64"]],
}

///|
/// FOR JSON { AUTO | PATH } [, ROOT [ ( 'name' ) ] ] [, INCLUDE_NULL_VALUES ]
///                          [, WITHOUT_ARRAY_WRAPPER ]
let for_json_options : Map[String, Array[Array[String]]] = {
  "AUTO": [],
  "PATH": [],
  "INCLUDE_NULL_VALUES": [],
  "WITHOUT_ARRAY_WRAPPER": [],
}

///|
pub let options_that_require_equal : Array[String] = [
  "MAX_GRANT_PERCENT", "MIN_GRANT_PERCENT", "LABEL",
]

///|
let column_definition_modes : Array[String] = ["OUT", "OUTPUT", "READONLY"]

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  args.get(i)
}

///|
/// `TSQL.TIME_MAPPING` (captured from the tsql dialect configuration).
let tsql_time_mapping : Ref[Map[String, String]] = Ref({})

///|
fn build_formatted_time(
  kind : @core.Kind,
  full_format_mapping? : Bool = false,
) -> @core.FuncBuilder {
  (args, _) => {
    let fmt = match seq_get(args, 0) {
      Some(f) => {
        let mapping = if full_format_mapping {
          let m = Map::from_iter(tsql_time_mapping.val.iter())
          for k, v in full_format_time_mapping {
            m[k] = v
          }
          m
        } else {
          tsql_time_mapping.val
        }
        Some(
          @core.literal_string(
            @core.format_time_opt(@core.py_lower(f.name()), mapping).unwrap_or(
              "",
            ),
          ),
        )
      }
      None => None
    }
    let this = match seq_get(args, 1) {
      Some(t) => Some(@core.exp_cast(t, DATETIME2))
      None => None
    }
    @core.mk(kind, [("this", this), ("format", fmt)])
  }
}

///|
/// `DATE_FMT_RE.search(name)`.
fn date_fmt_re_search(s : String) -> Bool {
  let chars = s.to_array()
  for i, c in chars {
    match c {
      'd' | 'D' | 'm' | 'M' | 'y' | 'Y' | 'h' | 'H' | 's' | 'S' => return true
      'f' | 'F' =>
        if i + 1 < chars.length() &&
          (chars[i + 1] == 'f' || chars[i + 1] == 'F') {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn build_format(args : Array[@core.Expr], _p : @core.Parser) -> @core.Expr {
  let this = seq_get(args, 0)
  let fmt = seq_get(args, 1)
  let culture = seq_get(args, 2)
  let number_fmt = match fmt {
    Some(f) =>
      f.name() == "N" || f.name() == "C" || !date_fmt_re_search(f.name())
    None => false
  }
  if number_fmt {
    return @core.mk(NumberToStr, [
      ("this", this),
      ("format", fmt),
      ("culture", culture),
    ])
  }
  let fmt = match fmt {
    Some(f) => {
      let name = f.name()
      let mapping = if name.length() == 1 {
        format_time_mapping
      } else {
        tsql_time_mapping.val
      }
      Some(
        @core.literal_string(@core.format_time_opt(name, mapping).unwrap_or("")),
      )
    }
    None => None
  }
  @core.mk(TimeToStr, [("this", this), ("format", fmt), ("culture", culture)])
}

///|
fn build_eomonth(args : Array[@core.Expr], _p : @core.Parser) -> @core.Expr {
  let date = @core.mk1(TsOrDsToDate, seq_get(args, 0))
  let this = match seq_get(args, 1) {
    None => date
    Some(month_lag) =>
      @core.mk(DateAdd, [
        ("this", date),
        ("expression", month_lag),
        ("unit", @core.var_("month")),
      ])
  }
  @core.mk1(LastDay, this)
}

///|
fn build_hashbytes(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  if args.length() != 2 {
    p.raise_error(
      "ValueError: expected 2 values to unpack, got \{args.length()}",
    )
  }
  let kind_e = args[0]
  let data = args[1]
  let kind = if kind_e.is_string() { @core.py_upper(kind_e.name()) } else { "" }
  if kind == "MD5" {
    args.remove(0) |> ignore
    return @core.mk1(MD5, data)
  }
  if kind == "SHA" || kind == "SHA1" {
    args.remove(0) |> ignore
    return @core.mk1(SHA, data)
  }
  if kind == "SHA2_256" {
    return @core.mk(SHA2, [
      ("this", data),
      ("length", @core.literal_number("256")),
    ])
  }
  if kind == "SHA2_512" {
    return @core.mk(SHA2, [
      ("this", data),
      ("length", @core.literal_number("512")),
    ])
  }
  @core.func_("HASHBYTES", args)
}

///|
/// Days since 1970-01-01 → (year, month, day) (Howard Hinnant's algorithm).
fn civil_from_days(z : Int64) -> (Int64, Int64, Int64) {
  let z = z + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  (if m <= 2L { y + 1L } else { y }, m, d)
}

///|
fn pad_int(n : Int64, width : Int) -> String {
  let s = n.to_string()
  if s.length() >= width {
    s
  } else {
    String::make(width - s.length(), '0') + s
  }
}

///|
/// `DEFAULT_START_DATE + timedelta(days=n)` formatted as `%F`.
fn default_start_date_plus(days : Int64) -> String {
  // 1900-01-01 is 25567 days before 1970-01-01
  let (y, m, d) = civil_from_days(days - 25567L)
  "\{pad_int(y, 4)}-\{pad_int(m, 2)}-\{pad_int(d, 2)}"
}

///|
fn build_date_delta(
  kind : @core.Kind,
  unit_mapping? : Map[String, String],
  big_int? : Bool = false,
) -> @core.FuncBuilder {
  (args, _) => {
    let mut unit = seq_get(args, 0)
    match (unit, unit_mapping) {
      (Some(u), Some(m)) =>
        unit = Some(
          @core.var_(m.get(@core.py_lower(u.name())).unwrap_or(u.name())),
        )
      _ => ()
    }
    let mut start_date = seq_get(args, 1)
    match start_date {
      Some(sd) if sd.is_number() =>
        // Numeric types are valid DATETIME values
        if sd.is_int() {
          let days = sd.to_py_int().unwrap_or(0L)
          start_date = Some(@core.literal_string(default_start_date_plus(days)))
        } else {
          // We currently don't handle float values, i.e. they're not converted to equivalent DATETIMEs.
          // This is not a problem when generating T-SQL code, it is when transpiling to other dialects.
          return @core.mk(kind, [
            ("this", seq_get(args, 2)),
            ("expression", start_date),
            ("unit", unit),
            ("big_int", big_int),
          ])
        }
      _ => ()
    }
    @core.mk(kind, [
      ("this", @core.mk1(TimeStrToTime, seq_get(args, 2))),
      ("expression", @core.mk1(TimeStrToTime, start_date)),
      ("unit", unit),
      ("big_int", big_int),
    ])
  }
}

///|
fn build_datetimefromparts(
  args : Array[@core.Expr],
  _p : @core.Parser,
) -> @core.Expr {
  @core.mk(TimestampFromParts, [
    ("year", seq_get(args, 0)),
    ("month", seq_get(args, 1)),
    ("day", seq_get(args, 2)),
    ("hour", seq_get(args, 3)),
    ("min", seq_get(args, 4)),
    ("sec", seq_get(args, 5)),
    ("milli", seq_get(args, 6)),
  ])
}

///|
fn build_timefromparts(
  args : Array[@core.Expr],
  _p : @core.Parser,
) -> @core.Expr {
  @core.mk(TimeFromParts, [
    ("hour", seq_get(args, 0)),
    ("min", seq_get(args, 1)),
    ("sec", seq_get(args, 2)),
    ("fractions", seq_get(args, 3)),
    ("precision", seq_get(args, 4)),
  ])
}

///|
fn build_with_arg_as_text(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    let this = match seq_get(args, 0) {
      Some(t) if !t.is_string() => Some(@core.exp_cast(t, TEXT))
      t => t
    }
    @core.mk(kind, [("this", this), ("expression", seq_get(args, 1))])
  }
}

///|
/// https://learn.microsoft.com/en-us/sql/t-sql/functions/parsename-transact-sql
fn build_parsename(args : Array[@core.Expr], _p : @core.Parser) -> @core.Expr {
  // PARSENAME(...) will be stored into exp.SplitPart if:
  // - All args are literals
  // - The part index (2nd arg) is <= 4 (max valid value, otherwise TSQL returns NULL)
  if args.length() == 2 && args.iter().all(a => a.kind == Literal) {
    let this = args[0]
    let part_index = args[1]
    let split_count = @core.py_split(this.name(), ".").length()
    if split_count <= 4 {
      let idx = part_index.to_py_int().unwrap_or(0L)
      return @core.mk(SplitPart, [
        ("this", this),
        ("delimiter", @core.literal_string(".")),
        (
          "part_index",
          @core.literal_number((split_count.to_int64() + 1L - idx).to_string()),
        ),
      ])
    }
  }
  @core.mk(Anonymous, [("this", "PARSENAME"), ("expressions", args)])
}

///|
fn build_json_query(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  if args.length() == 1 {
    // The default value for path is '$'. As a result, if you don't provide a
    // value for path, JSON_QUERY returns the input expression.
    args.push(@core.literal_string("$"))
  }
  let json_extract = @core.build_extract_json_with_path(JSONExtract)(args, p)
  json_extract.set("json_query", true)
  json_extract
}

///|
fn build_datetrunc(args : Array[@core.Expr], _p : @core.Parser) -> @core.Expr {
  let unit = seq_get(args, 0)
  let this = match seq_get(args, 1) {
    Some(t) if t.is_string() => Some(@core.exp_cast(t, DATETIME2))
    t => t
  }
  @core.mk(TimestampTrunc, [("this", this), ("unit", unit)])
}

///|
fn ts_or_ds_part(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    @core.mk1(
      kind,
      @core.mk(TsOrDsToDate, [
        ("this", seq_get(args, 0)),
        ("default_date", @core.literal_string("1900-01-01")),
      ]),
    )
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  tsql_time_mapping.val = d.cfg.time_mapping
  let cfg = d.parser_cfg
  let fns = d.parser_fns
  let f = fns.functions
  f["ATN2"] = @core.from_arg_list_builder(Atan2)
  f["CHARINDEX"] = (args, _) => {
    @core.mk(StrPosition, [
      ("this", seq_get(args, 1)),
      ("substr", seq_get(args, 0)),
      ("position", seq_get(args, 2)),
    ])
  }
  f["COUNT"] = (args, _) => {
    @core.mk(Count, [
      ("this", seq_get(args, 0)),
      ("expressions", args[1:].to_owned()),
      ("big_int", false),
    ])
  }
  f["COUNT_BIG"] = (args, _) => {
    @core.mk(Count, [
      ("this", seq_get(args, 0)),
      ("expressions", args[1:].to_owned()),
      ("big_int", true),
    ])
  }
  f["DATEADD"] = @core.build_date_delta(
    DateAdd,
    unit_mapping=date_delta_interval,
  )
  f["DATEDIFF"] = build_date_delta(DateDiff, unit_mapping=date_delta_interval)
  f["DATEDIFF_BIG"] = build_date_delta(
    DateDiff,
    unit_mapping=date_delta_interval,
    big_int=true,
  )
  f["DATENAME"] = build_formatted_time(TimeToStr, full_format_mapping=true)
  f["DATETIMEFROMPARTS"] = (args, p) => build_datetimefromparts(args, p)
  f["DAY"] = ts_or_ds_part(Day)
  f["EOMONTH"] = (args, p) => build_eomonth(args, p)
  f["FORMAT"] = (args, p) => build_format(args, p)
  f["GETDATE"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["HASHBYTES"] = build_hashbytes
  f["ISNULL"] = (args, _) => @core.build_coalesce(args, is_null=true)
  f["JSON_QUERY"] = build_json_query
  f["JSON_VALUE"] = @core.build_extract_json_with_path(JSONExtractScalar)
  f["LEN"] = build_with_arg_as_text(Length)
  f["LEFT"] = build_with_arg_as_text(Left)
  f["MONTH"] = ts_or_ds_part(Month)
  f["NEWID"] = @core.from_arg_list_builder(Uuid)
  f["RIGHT"] = build_with_arg_as_text(Right)
  f["PARSENAME"] = (args, p) => build_parsename(args, p)
  f["REPLICATE"] = @core.from_arg_list_builder(Repeat)
  f["SCHEMA_NAME"] = @core.from_arg_list_builder(CurrentSchema)
  f["SQUARE"] = (args, _) => {
    @core.mk(Pow, [
      ("this", seq_get(args, 0)),
      ("expression", @core.literal_number("2")),
    ])
  }
  f["SYSDATETIME"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["SUSER_NAME"] = @core.from_arg_list_builder(CurrentUser)
  f["SUSER_SNAME"] = @core.from_arg_list_builder(CurrentUser)
  f["SYSDATETIMEOFFSET"] = @core.from_arg_list_builder(CurrentTimestampLTZ)
  f["SYSTEM_USER"] = @core.from_arg_list_builder(CurrentUser)
  f["TIMEFROMPARTS"] = (args, p) => build_timefromparts(args, p)
  f["DATETRUNC"] = (args, p) => build_datetrunc(args, p)
  f["YEAR"] = ts_or_ds_part(Year)
  fns.query_modifier_parsers[OPTION] = p => {
    (
      "options",
      parse_options(p).map(l => @core.Value::List(l.map(x => Node(x)))),
    )
  }
  fns.query_modifier_parsers[FOR] = p => {
    ("for_", parse_for(p).map(x => Node(x)))
  }
  fns.statement_parsers[EXECUTE] = parse_execute
  fns.range_parsers[DCOLON] = (p, this) => {
    let expression = match p.parse_function() {
      Some(e) => Some(e)
      None => p.parse_var(any_token=true)
    }
    Some(
      p.expression(
        @core.mk(ScopeResolution, [("this", this), ("expression", expression)]),
      ),
    )
  }
  fns.no_paren_function_parsers["NEXT"] = p => p.parse_next_value_for()
  fns.function_parsers["JSON_ARRAYAGG"] = p => {
    let this = p.parse_bitwise()
    let order = p.parse_order()
    let null_handling = p.parse_on_handling("NULL", ["NULL", "ABSENT"])
    Some(
      p.expression(
        @core.mk(JSONArrayAgg, [
          ("this", this),
          ("order", order),
          ("null_handling", null_handling),
        ]),
      ),
    )
  }
  fns.function_parsers["DATEPART"] = parse_datepart
  // The DCOLON (::) operator serves as a scope resolution (exp.ScopeResolution) operator in T-SQL
  fns.column_operators[DCOLON] = Some((p, this, to) => {
    match to {
      Some(t) if t.kind.is_a(DataType) && t.datatype_this() != Some(USERDEFINED) =>
        Some(p.expression(@core.mk(Cast, [("this", this), ("to", to)])))
      _ =>
        Some(
          p.expression(
            @core.mk(ScopeResolution, [("this", this), ("expression", to)]),
          ),
        )
    }
  })
  // RETURNS_TABLE_TOKENS = base ID_VAR_TOKENS - {TABLE, *base TYPE_TOKENS}
  let base_cfg = @core.base_dialect().parser_cfg
  let returns_table_tokens = base_cfg.id_var_tokens.minus_set(
    base_cfg.type_tokens,
  )
  returns_table_tokens.remove(TABLE)
  ignore(cfg)
  let h = fns.hooks
  h.parse_alter_table_set = Some(p => {
    p.parse_wrapped(() => p.parse_alter_table_set_base())
  })
  h.parse_wrapped_select = Some(parse_wrapped_select)
  h.parse_dcolon = Some(parse_dcolon)
  h.parse_projections = Some(parse_projections)
  h.parse_commit_or_rollback = Some(parse_commit_or_rollback)
  h.parse_transaction = Some(parse_transaction)
  h.parse_returns = Some(p => {
    let table = p.parse_id_var(any_token=false, tokens=returns_table_tokens)
    let returns = p.parse_returns_base()
    match returns {
      Some(r) => r.set("table", table)
      None => ()
    }
    returns
  })
  h.parse_convert = Some(parse_convert)
  h.parse_column_def = Some(parse_column_def)
  h.parse_user_defined_function = Some(parse_user_defined_function)
  h.parse_into_clause = Some(parse_into)
  h.parse_id_var = Some(parse_id_var)
  h.parse_table_parts = Some(parse_table_parts)
  h.parse_create = Some(parse_create)
  h.parse_if = Some(parse_if)
  h.parse_unique = Some(parse_unique)
  h.parse_update = Some(p => {
    let expression = p.parse_update_base()
    match expression {
      Some(e) =>
        e.set(
          "options",
          parse_options(p).map(l => @core.Value::List(l.map(x => Node(x)))),
        )
      None => ()
    }
    expression
  })
  h.parse_partition = Some(parse_partition)
  h.parse_alter_table_alter = Some(parse_alter_table_alter)
  h.parse_primary_key_part = Some(p => p.parse_ordered())
}

///|
fn parse_execute(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let mut return_status : @core.Expr? = None
  let index = p.index
  if p.match_(PARAMETER) {
    let param = p.parse_parameter()
    if p.match_(EQ) {
      return_status = param
    } else {
      p.retreat(index)
    }
  }
  let this = p.parse_table(schema=true)
  let expressions = p.parse_csv(() => p.parse_expression())
  let mut execute = p.expression(
    @core.mk(Execute, [
      ("this", this),
      ("expressions", expressions),
      ("return_status", return_status),
    ]),
  )
  if @core.py_lower(execute.name()) == "sp_executesql" {
    execute = p.expression(
      @core.Expr::new(ExecuteSql, @core.Args::from_iter(execute.args.iter())),
    )
  }
  Some(execute)
}

///|
fn parse_datepart(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_var(tokens=@core.TokenSet::new([IDENTIFIER]))
  let expression = if p.match_(COMMA) { p.parse_bitwise() } else { None }
  let name = @core.map_date_part(this, dialect=p.dialect)
  Some(
    p.expression(
      @core.mk(Extract, [("this", name), ("expression", expression)]),
    ),
  )
}

///|
fn parse_wrapped_select(
  p : @core.Parser,
  table : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  if p.match_(MERGE) {
    let comments = p.prev_comments
    let merge = p.parse_merge()
    match merge {
      Some(m) => m.add_comments(Some(comments), prepend=true)
      None => ()
    }
    return merge
  }
  p.parse_wrapped_select_base(table~)
}

///|
fn parse_dcolon(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // We want to use _parse_types() if the first token after :: is a known type,
  // otherwise we could parse something like x::varchar(max) into a function
  if p.match_set(p.cfg.type_tokens, advance=false) {
    return p.parse_types()
  }
  match p.parse_function() {
    Some(e) => Some(e)
    None => p.parse_types()
  }
}

///|
fn parse_options(
  p : @core.Parser,
) -> Array[@core.Expr]? raise @core.SqlglotError {
  if !p.match_(OPTION) {
    return None
  }
  let parse_option = fn() -> @core.Expr? raise @core.SqlglotError {
    let option = p.parse_var_from_options(options)
    guard option is Some(_) else { return None }
    p.match_(EQ) |> ignore
    Some(
      p.expression(
        @core.mk(QueryOption, [
          ("this", option),
          ("expression", p.parse_primary_or_var()),
        ]),
      ),
    )
  }
  Some(p.parse_wrapped_csv(parse_option))
}

///|
fn parse_key_value_option(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_primary_or_var()
  let expression = if p.match_(L_PAREN, advance=false) {
    p.parse_wrapped(() => p.parse_string())
  } else {
    None
  }
  Some(
    @core.mk(XMLKeyValueOption, [("this", this), ("expression", expression)]),
  )
}

///|
fn parse_for_clause_option(
  p : @core.Parser,
  opts : Map[String, Array[Array[String]]],
) -> @core.Expr? raise @core.SqlglotError {
  let this = match p.parse_var_from_options(opts, raise_unmatched=false) {
    Some(e) => Some(e)
    None => parse_key_value_option(p)
  }
  Some(p.expression(@core.mk1(QueryOption, this)))
}

///|
fn parse_for(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_pair(FOR, XML) {
    let expressions = p.parse_csv(() => {
      parse_for_clause_option(p, for_xml_options)
    })
    return Some(
      p.expression(
        @core.mk(ForClause, [("kind", "XML"), ("expressions", expressions)]),
      ),
    )
  }
  if p.match_pair(FOR, JSON) {
    let expressions = p.parse_csv(() => {
      parse_for_clause_option(p, for_json_options)
    })
    return Some(
      p.expression(
        @core.mk(ForClause, [("kind", "JSON"), ("expressions", expressions)]),
      ),
    )
  }
  // FOR BROWSE — bare keyword, no options. BROWSE has no dedicated TokenType.
  if p.match_text_seq(["FOR", "BROWSE"]) {
    return Some(p.expression(@core.mk(ForClause, [("kind", "BROWSE")])))
  }
  None
}

///|
/// T-SQL supports the syntax alias = expression in the SELECT's projection list,
/// so we transform all parsed Selects to convert their EQ projections into Aliases.
fn parse_projections(
  p : @core.Parser,
) -> (Array[@core.Expr], Array[@core.Expr]?) raise @core.SqlglotError {
  let projections = p.parse_expressions()
  let out = projections.map(projection => {
    match projection.this() {
      Some(col) if projection.kind == EQ && col.kind.is_a(Column) =>
        @core.alias_expr(
          projection.expression().unwrap(),
          col.this(),
          copy=false,
        )
      _ => projection
    }
  })
  (out, None)
}

///|
/// COMMIT [ { TRAN | TRANSACTION } [ transaction_name | @tran_name_variable ] ]
///   [ WITH ( DELAYED_DURABILITY = { OFF | ON } ) ]
/// ROLLBACK { TRAN | TRANSACTION } [ transaction_name | @tran_name_variable
///   | savepoint_name | @savepoint_variable ]
fn parse_commit_or_rollback(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let rollback = p.prev.token_type == ROLLBACK
  p.match_texts(["TRAN", "TRANSACTION"]) |> ignore
  let this = p.parse_id_var()
  if rollback {
    return Some(p.expression(@core.mk1(Rollback, this)))
  }
  let mut durability : Bool? = None
  if p.match_pair(WITH, L_PAREN) {
    p.match_text_seq(["DELAYED_DURABILITY"]) |> ignore
    p.match_(EQ) |> ignore
    if p.match_text_seq(["OFF"]) {
      durability = Some(false)
    } else {
      p.match_(ON) |> ignore
      durability = Some(true)
    }
    p.match_r_paren()
  }
  Some(
    p.expression(@core.mk(Commit, [("this", this), ("durability", durability)])),
  )
}

///|
/// BEGIN { TRAN | TRANSACTION }
/// [ { transaction_name | @tran_name_variable } [ WITH MARK [ 'description' ] ] ]
fn parse_transaction(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_texts(["TRAN", "TRANSACTION"]) {
    let transaction = p.expression(@core.mk1(Transaction, p.parse_id_var()))
    if p.match_text_seq(["WITH", "MARK"]) {
      transaction.set("mark", p.parse_string())
    }
    return Some(transaction)
  }
  Some(p.parse_as_command(p.prev))
}

///|
fn parse_convert(
  p : @core.Parser,
  _strict : Bool,
  safe : Bool?,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_types()
  p.match_(COMMA) |> ignore
  let args : Array[@core.Expr] = []
  match this {
    Some(t) => args.push(t)
    None => ()
  }
  let rest = p.parse_csv(() => p.parse_assignment())
  let convert = if this is None {
    // Python keeps a positional None for `this`
    @core.mk(Convert, [("expression", rest.get(0)), ("style", rest.get(1))])
  } else {
    args.append(rest)
    @core.from_arg_list(Convert, args)
  }
  convert.set("safe", safe)
  Some(convert)
}

///|
fn parse_column_def(
  p : @core.Parser,
  this : @core.Expr?,
  computed_column : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_column_def_base(this, computed_column~)
  guard this is Some(t) else { return None }
  if p.match_(EQ) {
    t.set("default", p.parse_disjunction())
  }
  if p.match_texts(column_definition_modes) {
    t.set("output", p.prev.text)
  }
  this
}

///|
fn parse_user_defined_function(
  p : @core.Parser,
  kind : @core.TokenType?,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_user_defined_function_base(kind?)
  if kind == Some(FUNCTION) ||
    (this is Some(t) && t.kind == UserDefinedFunction) {
    return this
  }
  match this {
    Some(t) if kind == Some(PROCEDURE) => {
      let mut expressions = t.expressions()
      if !(!expressions.is_empty() ||
        p.match_set(@core.TokenSet::new([ALIAS, WITH]), advance=false)) {
        expressions = p.parse_csv(() => p.parse_function_parameter())
      }
      Some(
        p.expression(
          @core.mk(StoredProcedure, [
            ("this", if t.kind == Table { Some(t) } else { t.this() }),
            ("expressions", expressions),
            ("wrapped", t.get("wrapped")),
          ]),
        ),
      )
    }
    _ => Some(p.expression(@core.mk1(UserDefinedFunction, this)))
  }
}

///|
fn parse_into(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let into = p.parse_into_clause_base()
  match into {
    Some(i) if i.kind == Into =>
      match i.find([Table]) {
        Some(table) =>
          match table.this() {
            Some(ident) if ident.has("temporary") =>
              // Promote the temporary property from the Identifier to the Into expression
              i.set("temporary", true)
            _ => ()
          }
        None => ()
      }
    _ => ()
  }
  into
}

///|
fn parse_id_var(
  p : @core.Parser,
  any_token : Bool,
  tokens : @core.TokenSet?,
) -> @core.Expr? raise @core.SqlglotError {
  let is_temporary = p.match_(HASH)
  let is_global = is_temporary && p.match_(HASH)
  let this = p.parse_id_var_base(any_token~, tokens?)
  match this {
    Some(t) =>
      if is_global {
        t.set("global_", true)
      } else if is_temporary {
        t.set("temporary", true)
      }
    None => ()
  }
  this
}

///|
fn parse_table_parts(
  p : @core.Parser,
  schema : Bool,
  is_db_reference : Bool,
  wildcard : Bool,
  fast : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let table = p.parse_table_parts_base(
    schema~,
    is_db_reference~,
    wildcard~,
    fast~,
  )
  match table {
    Some(t) if t.kind == Table =>
      match t.this() {
        Some(ident) if ident.kind == Identifier => {
          let table_name = t.name()
          if table_name.has_prefix("##") {
            ident.set(
              "this",
              table_name.unsafe_substring(start=2, end=table_name.length()),
            )
            ident.set("global_", true)
          } else if table_name.has_prefix("#") {
            ident.set(
              "this",
              table_name.unsafe_substring(start=1, end=table_name.length()),
            )
            ident.set("temporary", true)
          }
        }
        _ => ()
      }
    _ => ()
  }
  table
}

///|
fn parse_create(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let create = p.parse_create_base()
  match create {
    Some(c) if c.kind == Create => {
      let table = match c.this() {
        Some(s) if s.kind == Schema => s.this()
        t => t
      }
      match table {
        Some(t) if t.kind == Table &&
          t.this() is Some(ident) &&
          ident.has("temporary") => {
          if !c.has("properties") {
            c.set(
              "properties",
              @core.mk(Properties, [("expressions", ([] : Array[@core.Expr]))]),
            )
          }
          c
          .arg("properties")
          .unwrap()
          .append("expressions", @core.mk0(TemporaryProperty))
        }
        _ => ()
      }
    }
    _ => ()
  }
  create
}

///|
fn parse_if(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_condition()
  let true_ = p.parse_block()
  let false_ = if p.match_(ELSE) { Some(p.parse_block()) } else { None }
  Some(
    p.expression(
      @core.mk(IfBlock, [("this", this), ("true", true_), ("false", false_)]),
    ),
  )
}

///|
fn parse_unique(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = if p.match_texts(["CLUSTERED", "NONCLUSTERED"]) {
    p.fns.constraint_parsers[@core.py_upper(p.prev.text)](p)
  } else {
    p.parse_schema(this=p.parse_id_var(any_token=false))
  }
  Some(p.expression(@core.mk1(UniqueColumnConstraint, this)))
}

///|
fn parse_partition(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if !p.match_text_seq(["WITH", "(", "PARTITIONS"]) {
    return None
  }
  let parse_range = fn() -> @core.Expr? raise @core.SqlglotError {
    let low = p.parse_bitwise()
    let high = if p.match_text_seq(["TO"]) { p.parse_bitwise() } else { None }
    if high is Some(_) {
      Some(
        p.expression(
          @core.mk(PartitionRange, [("this", low), ("expression", high)]),
        ),
      )
    } else {
      low
    }
  }
  let partition = p.expression(
    @core.mk(Partition, [("expressions", p.parse_wrapped_csv(parse_range))]),
  )
  p.match_r_paren()
  Some(partition)
}

///|
fn parse_alter_table_alter(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let expression = p.parse_alter_table_alter_base()
  match expression {
    Some(e) => {
      match e.arg("collate") {
        Some(collation) if collation.kind.is_a(Column) &&
          collation.this() is Some(identifier) &&
          identifier.kind == Identifier =>
          collation.set("this", @core.var_(identifier.name()))
        _ => ()
      }
      if e.has("dtype") {
        if p.match_pair(NOT, NULL) {
          e.set("allow_null", false)
        } else if p.match_(NULL) {
          e.set("allow_null", true)
        }
      }
    }
    None => ()
  }
  expression
}
