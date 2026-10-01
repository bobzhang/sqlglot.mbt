// Port of sqlglot/parsers/mysql.py

///|
/// Python `seq_get(args, i)`.
pub fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i >= 0 && i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
/// All specifiers for time parts (as opposed to date parts)
/// https://dev.mysql.com/doc/refman/8.0/en/date-and-time-functions.html#function_date-format
fn has_time_specifier(date_format : String) -> Bool {
  let chars = date_format.to_array()
  let length = chars.length()
  let mut i = 0
  while i < length {
    if chars[i] == '%' {
      i += 1
      if i < length &&
        ['f', 'H', 'h', 'I', 'i', 'k', 'l', 'p', 'r', 'S', 's', 'T'].contains(
          chars[i],
        ) {
        return true
      }
    }
    i += 1
  }
  false
}

///|
/// Python `Dialect["mysql"].format_time(e)`.
pub fn mysql_format_time(e : @core.Expr?) -> @core.Expr? {
  dialect().format_time(e)
}

///|
fn str_to_date(args : Array[@core.Expr]) -> @core.Expr {
  let mysql_date_format = seq_get(args, 1)
  let date_format = mysql_format_time(mysql_date_format)
  let this = seq_get(args, 0)
  match mysql_date_format {
    Some(f) if has_time_specifier(f.name()) =>
      @core.mk(StrToTime, [("this", this), ("format", date_format)])
    _ => @core.mk(StrToDate, [("this", this), ("format", date_format)])
  }
}

///|
fn ts_or_ds_to_date(e : @core.Expr?) -> @core.Expr {
  @core.mk1(TsOrDsToDate, e)
}

///|
/// Python `_show_parser(this, target=..., full=..., global_=...)`.
/// `target`: `None` = False, `Some("")` = True, `Some(text)` = keywords to match.
pub fn show_parser(
  this : String,
  target? : String,
  full? : Bool = false,
  global_? : Bool = false,
) -> @core.ParseFn {
  p => Some(parse_show_mysql(p, this, target?, full~, global_~))
}

///|
let profile_types : Map[String, Array[Array[String]]] = {
  "ALL": [],
  "CPU": [],
  "IPC": [],
  "MEMORY": [],
  "SOURCE": [],
  "SWAPS": [],
  "BLOCK": [["IO"]],
  "CONTEXT": [["SWITCHES"]],
  "PAGE": [["FAULTS"]],
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.range_parsers[MEMBER_OF] = (p, this) => {
    Some(
      p.expression(
        @core.mk(JSONArrayContains, [
          ("this", this),
          ("expression", p.parse_wrapped(() => p.parse_expression())),
        ]),
      ),
    )
  }
  let f = fns.functions
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["BIT_XOR"] = @core.from_arg_list_builder(BitwiseXorAgg)
  f["BIT_COUNT"] = @core.from_arg_list_builder(BitwiseCount)
  f["CONVERT_TZ"] = (args, _) => {
    @core.mk(ConvertTimezone, [
      ("source_tz", seq_get(args, 1)),
      ("target_tz", seq_get(args, 2)),
      ("timestamp", seq_get(args, 0)),
    ])
  }
  f["CURDATE"] = @core.from_arg_list_builder(CurrentDate)
  f["CURTIME"] = @core.from_arg_list_builder(CurrentTime)
  f["DATE"] = (args, _) => ts_or_ds_to_date(seq_get(args, 0))
  f["DATEDIFF"] = (args, _) => {
    @core.mk(DateDiff, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("date_part_boundary", true),
    ])
  }
  f["DATE_ADD"] = @core.build_date_delta_with_interval(DateAdd)
  f["DATE_FORMAT"] = (args, _) => {
    @core.mk(TimeToStr, [
      ("this", @core.mk1(TsOrDsToTimestamp, seq_get(args, 0))),
      ("format", mysql_format_time(seq_get(args, 1))),
    ])
  }
  f["DATE_SUB"] = @core.build_date_delta_with_interval(DateSub)
  f["DAY"] = (args, _) => @core.mk1(Day, ts_or_ds_to_date(seq_get(args, 0)))
  f["DAYOFMONTH"] = (args, _) => {
    @core.mk1(DayOfMonth, ts_or_ds_to_date(seq_get(args, 0)))
  }
  f["DAYOFWEEK"] = (args, _) => {
    @core.mk1(DayOfWeek, ts_or_ds_to_date(seq_get(args, 0)))
  }
  f["DAYOFYEAR"] = (args, _) => {
    @core.mk1(DayOfYear, ts_or_ds_to_date(seq_get(args, 0)))
  }
  f["FORMAT"] = @core.from_arg_list_builder(NumberToStr)
  f["FROM_UNIXTIME"] = @core.build_formatted_time(UnixToTime)
  f["ISNULL"] = (args, _) => @core.isnull_to_is_null(args)
  f["LENGTH"] = (args, _) => {
    @core.mk(Length, [("this", seq_get(args, 0)), ("binary", true)])
  }
  f["MAKETIME"] = @core.from_arg_list_builder(TimeFromParts)
  f["MONTH"] = (args, _) => @core.mk1(Month, ts_or_ds_to_date(seq_get(args, 0)))
  f["MONTHNAME"] = (args, _) => {
    @core.mk(TimeToStr, [
      ("this", ts_or_ds_to_date(seq_get(args, 0))),
      ("format", @core.literal_string("%B")),
    ])
  }
  f["SCHEMA"] = @core.from_arg_list_builder(CurrentSchema)
  f["DATABASE"] = @core.from_arg_list_builder(CurrentSchema)
  f["STR_TO_DATE"] = (args, _) => str_to_date(args)
  f["TIMESTAMPDIFF"] = @core.build_date_delta(TimestampDiff)
  f["TO_DAYS"] = (args, _) => {
    @core.paren(
      @core.add_(
        @core.mk(DateDiff, [
          ("this", ts_or_ds_to_date(seq_get(args, 0))),
          (
            "expression",
            ts_or_ds_to_date(Some(@core.literal_string("0000-01-01"))),
          ),
          ("unit", @core.var_("DAY")),
        ]),
        @core.literal_number("1"),
      ),
    )
  }
  f["VERSION"] = @core.from_arg_list_builder(CurrentVersion)
  f["WEEK"] = (args, _) => {
    @core.mk(Week, [
      ("this", ts_or_ds_to_date(seq_get(args, 0))),
      ("mode", seq_get(args, 1)),
    ])
  }
  f["WEEKOFYEAR"] = (args, _) => {
    @core.mk1(WeekOfYear, ts_or_ds_to_date(seq_get(args, 0)))
  }
  f["YEAR"] = (args, _) => @core.mk1(Year, ts_or_ds_to_date(seq_get(args, 0)))
  let fp = fns.function_parsers
  fp["GROUP_CONCAT"] = p => p.parse_group_concat()
  // https://dev.mysql.com/doc/refman/5.7/en/miscellaneous-functions.html#function_values
  fp["VALUES"] = p => {
    Some(
      p.expression(
        @core.mk(Anonymous, [
          ("this", "VALUES"),
          ("expressions", [p.parse_id_var()]),
        ]),
      ),
    )
  }
  fp["JSON_VALUE"] = p => p.parse_json_value()
  fp["SUBSTR"] = p => p.parse_substring()
  fns.statement_parsers[SHOW] = p => p.parse_show()
  let sp = fns.show_parsers
  sp["BINARY LOGS"] = show_parser("BINARY LOGS")
  sp["MASTER LOGS"] = show_parser("BINARY LOGS")
  sp["BINLOG EVENTS"] = show_parser("BINLOG EVENTS")
  sp["CHARACTER SET"] = show_parser("CHARACTER SET")
  sp["CHARSET"] = show_parser("CHARACTER SET")
  sp["COLLATION"] = show_parser("COLLATION")
  sp["FULL COLUMNS"] = show_parser("COLUMNS", target="FROM", full=true)
  sp["COLUMNS"] = show_parser("COLUMNS", target="FROM")
  sp["CREATE DATABASE"] = show_parser("CREATE DATABASE", target="")
  sp["CREATE EVENT"] = show_parser("CREATE EVENT", target="")
  sp["CREATE FUNCTION"] = show_parser("CREATE FUNCTION", target="")
  sp["CREATE PROCEDURE"] = show_parser("CREATE PROCEDURE", target="")
  sp["CREATE TABLE"] = show_parser("CREATE TABLE", target="")
  sp["CREATE TRIGGER"] = show_parser("CREATE TRIGGER", target="")
  sp["CREATE VIEW"] = show_parser("CREATE VIEW", target="")
  sp["DATABASES"] = show_parser("DATABASES")
  sp["SCHEMAS"] = show_parser("DATABASES")
  sp["ENGINE"] = show_parser("ENGINE", target="")
  sp["STORAGE ENGINES"] = show_parser("ENGINES")
  sp["ENGINES"] = show_parser("ENGINES")
  sp["ERRORS"] = show_parser("ERRORS")
  sp["EVENTS"] = show_parser("EVENTS")
  sp["FUNCTION CODE"] = show_parser("FUNCTION CODE", target="")
  sp["FUNCTION STATUS"] = show_parser("FUNCTION STATUS")
  sp["GRANTS"] = show_parser("GRANTS", target="FOR")
  sp["INDEX"] = show_parser("INDEX", target="FROM")
  sp["MASTER STATUS"] = show_parser("MASTER STATUS")
  sp["OPEN TABLES"] = show_parser("OPEN TABLES")
  sp["PLUGINS"] = show_parser("PLUGINS")
  sp["PROCEDURE CODE"] = show_parser("PROCEDURE CODE", target="")
  sp["PROCEDURE STATUS"] = show_parser("PROCEDURE STATUS")
  sp["PRIVILEGES"] = show_parser("PRIVILEGES")
  sp["FULL PROCESSLIST"] = show_parser("PROCESSLIST", full=true)
  sp["PROCESSLIST"] = show_parser("PROCESSLIST")
  sp["PROFILE"] = show_parser("PROFILE")
  sp["PROFILES"] = show_parser("PROFILES")
  sp["RELAYLOG EVENTS"] = show_parser("RELAYLOG EVENTS")
  sp["REPLICAS"] = show_parser("REPLICAS")
  sp["SLAVE HOSTS"] = show_parser("REPLICAS")
  sp["REPLICA STATUS"] = show_parser("REPLICA STATUS")
  sp["SLAVE STATUS"] = show_parser("REPLICA STATUS")
  sp["GLOBAL STATUS"] = show_parser("STATUS", global_=true)
  sp["SESSION STATUS"] = show_parser("STATUS")
  sp["STATUS"] = show_parser("STATUS")
  sp["TABLE STATUS"] = show_parser("TABLE STATUS")
  sp["FULL TABLES"] = show_parser("TABLES", full=true)
  sp["TABLES"] = show_parser("TABLES")
  sp["TRIGGERS"] = show_parser("TRIGGERS")
  sp["GLOBAL VARIABLES"] = show_parser("VARIABLES", global_=true)
  sp["SESSION VARIABLES"] = show_parser("VARIABLES")
  sp["VARIABLES"] = show_parser("VARIABLES")
  sp["WARNINGS"] = show_parser("WARNINGS")
  fns.property_parsers["LOCK"] = (p, _) => {
    Some(Node(p.parse_property_assignment(LockProperty)))
  }
  fns.property_parsers["PARTITION BY"] = (p, _) => {
    parse_partition_property(p, parse_partition_range_value)
  }
  let setp = fns.set_parsers
  setp["PERSIST"] = p => p.parse_set_item_assignment(kind="PERSIST")
  setp["PERSIST_ONLY"] = p => p.parse_set_item_assignment(kind="PERSIST_ONLY")
  setp["CHARACTER SET"] = p => Some(parse_set_item_charset(p, "CHARACTER SET"))
  setp["CHARSET"] = p => Some(parse_set_item_charset(p, "CHARACTER SET"))
  setp["NAMES"] = p => Some(parse_set_item_names(p))
  let cp = fns.constraint_parsers
  cp["BINARY"] = p => Some(p.expression(@core.mk0(BinaryColumnConstraint)))
  cp["FULLTEXT"] = p => Some(parse_index_constraint(p, kind="FULLTEXT"))
  cp["INDEX"] = p => Some(parse_index_constraint(p))
  cp["KEY"] = p => Some(parse_index_constraint(p))
  cp["SPATIAL"] = p => Some(parse_index_constraint(p, kind="SPATIAL"))
  cp["ZEROFILL"] = p => Some(p.expression(@core.mk0(ZeroFillColumnConstraint)))
  cp["INVISIBLE"] = p => {
    Some(p.expression(@core.mk0(InvisibleColumnConstraint)))
  }
  let ap = fns.alter_parsers
  ap["CHANGE"] = p => {
    match parse_alter_table_modify(p, rename=true) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  ap["MODIFY"] = p => {
    match parse_alter_table_modify(p) {
      Some(e) => Some(Node(e))
      None => None
    }
  }
  ap["AUTO_INCREMENT"] = p => {
    Some(Node(p.parse_property_assignment(AutoIncrementProperty)))
  }
  ap["COMMENT"] = p => {
    Some(Node(p.parse_property_assignment(SchemaCommentProperty)))
  }
  fns.alter_alter_parsers["INDEX"] = p => Some(parse_alter_table_alter_index(p))
  let h = fns.hooks
  h.parse_column_constraint = Some(p => {
    if p.match_(KEY) {
      return Some(
        p.expression(
          @core.mk(ColumnConstraint, [("kind", p.parse_primary_key())]),
        ),
      )
    }
    p.parse_column_constraint_base()
  })
  h.parse_range = Some(parse_range)
  h.parse_alter_table_rename = Some(p => {
    if p.match_texts(["INDEX", "KEY"]) {
      let old = p.parse_field(any_token=true)
      p.match_text_seq(["TO"]) |> ignore
      let new = p.parse_field(any_token=true)
      return Some(
        p.expression(@core.mk(RenameIndex, [("this", old), ("to", new)])),
      )
    }
    p.parse_alter_table_rename_base()
  })
  h.parse_alter_drop_action = Some(p => {
    if p.match_pair(DROP, PRIMARY_KEY) {
      return Some(p.expression(@core.mk0(DropPrimaryKey)))
    }
    p.parse_drop_column()
  })
  h.parse_generated_as_identity = Some(parse_generated_as_identity)
  h.parse_primary_key_part = Some(parse_primary_key_part)
  h.parse_unique = Some(parse_unique)
  h.parse_charset_name = Some(parse_charset_name)
  h.parse_type = Some((p, parse_interval, fallback_to_identifier) => {
    // mysql binary is special and can work anywhere, even in order by operations
    // it operates like a no paren func
    if p.match_(BINARY, advance=false) {
      let data_type = p.parse_types(check_func=true, allow_identifiers=false)
      match data_type {
        Some(dt) if dt.kind == DataType =>
          return Some(
            p.expression(
              @core.mk(Cast, [("this", p.parse_column()), ("to", dt)]),
            ),
          )
        _ => ()
      }
    }
    p.parse_type_base(parse_interval~, fallback_to_identifier~)
  })
  h.parse_primary_key = Some((p, wrapped_optional, in_props, _) => {
    p.parse_primary_key_base(
      wrapped_optional~,
      in_props~,
      named_primary_key=true,
    )
  })
}

///|
fn parse_range(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = match this {
    Some(_) => this
    None => p.parse_bitwise()
  }
  if p.match_text_seq(["SOUNDS", "LIKE"]) {
    this = Some(
      p.expression(
        @core.mk(EQ, [
          ("this", p.expression(@core.mk1(Soundex, this))),
          ("expression", p.expression(@core.mk1(Soundex, p.parse_bitwise()))),
        ]),
      ),
    )
    // MySQL evaluates = and IS left to right because they have the same precedence.
    if p.match_(IS, advance=false) {
      this = Some(p.expression(@core.mk1(Paren, this)))
    }
  }
  p.parse_range_base(this)
}

///|
/// MODIFY [COLUMN]            col_name      column_definition [FIRST | AFTER col_name]
/// CHANGE [COLUMN] old_col_name new_col_name column_definition [FIRST | AFTER col_name]
fn parse_alter_table_modify(
  p : @core.Parser,
  rename? : Bool = false,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_(COLUMN) |> ignore
  guard p.parse_field(any_token=true) is Some(column) else { return None }
  let mut column = column
  let mut rename_from : @core.Expr? = None
  if rename {
    rename_from = Some(column)
    guard p.parse_field(any_token=true) is Some(c) else { return None }
    column = c
  }
  match p.parse_column_def(Some(column)) {
    Some(column_def) if column_def.kind == ColumnDef =>
      Some(
        p.expression(
          @core.mk(ModifyColumn, [
            ("this", column_def),
            ("rename_from", rename_from),
          ]),
        ),
      )
    _ => None
  }
}

///|
fn parse_generated_as_identity(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = p.parse_generated_as_identity_base()
  if p.match_texts(["STORED", "VIRTUAL"]) {
    let persisted = @core.py_upper(p.prev.text) == "STORED"
    match this {
      Some(t) if t.kind == ComputedColumnConstraint =>
        t.set("persisted", persisted)
      Some(t) if t.kind == GeneratedAsIdentityColumnConstraint =>
        this = Some(
          p.expression(
            @core.mk(ComputedColumnConstraint, [
              ("this", t.expression()),
              ("persisted", persisted),
            ]),
          ),
        )
      _ => ()
    }
  }
  this
}

///|
fn parse_primary_key_part(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_id_var()
  if !p.match_(L_PAREN) {
    return this
  }
  let expression = p.parse_number()
  p.match_r_paren()
  Some(
    p.expression(
      @core.mk(ColumnPrefix, [("this", this), ("expression", expression)]),
    ),
  )
}

///|
fn parse_index_constraint_part(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // key_part: {col_name [(length)] | (expr)}, so only a prefixed column is followed by "("
  if !p.match_(L_PAREN, advance=false) &&
    p.next.ok() &&
    p.next.token_type == L_PAREN {
    return p.parse_primary_key_part()
  }
  p.parse_disjunction()
}

///|
fn parse_index_key_part(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // Only keep the Ordered wrapper for an explicit ASC/DESC, otherwise the implicit
  // nulls_first leaks into other dialects as NULLS FIRST
  let ordered = p.parse_ordered(parse_method=() => {
    parse_index_constraint_part(p)
  })
  match ordered {
    Some(o) if o.get("desc") is None => o.this()
    _ => ordered
  }
}

///|
fn parse_index_constraint(
  p : @core.Parser,
  kind? : String,
) -> @core.Expr raise @core.SqlglotError {
  if kind is Some(_) {
    p.match_texts(["INDEX", "KEY"]) |> ignore
  }
  let this = p.parse_id_var(any_token=false)
  let index_type = parse_index_type(p)
  let expressions = p.parse_wrapped_csv(() => parse_index_key_part(p))
  p.expression(
    @core.mk(IndexColumnConstraint, [
      ("this", this),
      ("expressions", expressions),
      ("kind", kind),
      ("index_type", index_type),
      ("options", parse_index_constraint_options(p)),
    ]),
  )
}

///|
fn parse_index_constraint_options(
  p : @core.Parser,
) -> Array[@core.Expr] raise @core.SqlglotError {
  let options = []
  while true {
    let opt : @core.Expr? = if p.match_text_seq(["KEY_BLOCK_SIZE"]) {
      p.match_(EQ) |> ignore
      Some(
        @core.mk(IndexConstraintOption, [("key_block_size", p.parse_number())]),
      )
    } else if p.match_(USING) {
      let using_ : String? = match p.advance_any() {
        Some(_) => Some(p.prev.text)
        None => None
      }
      Some(@core.mk(IndexConstraintOption, [("using", using_)]))
    } else if p.match_text_seq(["WITH", "PARSER"]) {
      Some(
        @core.mk(IndexConstraintOption, [
          ("parser", p.parse_var(any_token=true)),
        ]),
      )
    } else if p.match_(COMMENT) {
      Some(@core.mk(IndexConstraintOption, [("comment", p.parse_string())]))
    } else if p.match_text_seq(["VISIBLE"]) {
      Some(@core.mk(IndexConstraintOption, [("visible", true)]))
    } else if p.match_text_seq(["INVISIBLE"]) {
      Some(@core.mk(IndexConstraintOption, [("visible", false)]))
    } else if p.match_text_seq(["ENGINE_ATTRIBUTE"]) {
      p.match_(EQ) |> ignore
      Some(@core.mk(IndexConstraintOption, [("engine_attr", p.parse_string())]))
    } else if p.match_text_seq(["SECONDARY_ENGINE_ATTRIBUTE"]) {
      p.match_(EQ) |> ignore
      Some(
        @core.mk(IndexConstraintOption, [
          ("secondary_engine_attr", p.parse_string()),
        ]),
      )
    } else {
      None
    }
    match opt {
      Some(o) => options.push(o)
      None => break
    }
  }
  options
}

///|
fn parse_unique(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  p.match_texts(["KEY", "INDEX"]) |> ignore
  let this = p.parse_unique_key()
  let index_type = parse_index_type(p)
  // UNIQUE [INDEX | KEY] [index_name] [index_type] (key_part,...) [index_option] ...
  if !p.match_(L_PAREN, advance=false) {
    return Some(
      p.expression(
        @core.mk(UniqueColumnConstraint, [
          ("this", this),
          ("index_type", index_type),
        ]),
      ),
    )
  }
  let expressions = p.parse_wrapped_csv(() => parse_index_key_part(p))
  let index_type = match index_type {
    Some(_) => index_type
    None => parse_index_type(p)
  }
  Some(
    p.expression(
      @core.mk(UniqueColumnConstraint, [
        (
          "this",
          p.expression(
            @core.mk(Schema, [("this", this), ("expressions", expressions)]),
          ),
        ),
        ("index_type", index_type),
        ("options", parse_index_constraint_options(p)),
      ]),
    ),
  )
}

///|
fn parse_index_type(p : @core.Parser) -> String? {
  if p.match_(USING) && p.advance_any() is Some(_) {
    return Some(p.prev.text)
  }
  None
}

///|
/// Python `_parse_show_mysql`.
pub fn parse_show_mysql(
  p : @core.Parser,
  this : String,
  target? : String,
  full? : Bool = false,
  global_? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  let json = p.match_text_seq(["JSON"])
  let mut target_id = match target {
    Some(t) => {
      if t != "" {
        p.match_text_seq(@core.py_split(t, " ")) |> ignore
      }
      p.parse_id_var()
    }
    None => None
  }
  let index = p.index
  let log = if p.match_text_seq(["IN"]) {
    let log = p.parse_string()
    if log is None {
      p.retreat(index)
    }
    log
  } else {
    None
  }
  let mut position : @core.Expr? = None
  let mut db : @core.Expr? = None
  if this == "BINLOG EVENTS" || this == "RELAYLOG EVENTS" {
    position = if p.match_text_seq(["FROM"]) { p.parse_number() } else { None }
  } else if p.match_(FROM) || p.match_text_seq(["IN"]) {
    db = p.parse_id_var()
  } else if p.match_(DOT) {
    db = target_id
    target_id = p.parse_id_var()
  }
  let channel = if p.match_text_seq(["FOR", "CHANNEL"]) {
    p.parse_id_var()
  } else {
    None
  }
  let like = if p.match_text_seq(["LIKE"]) { p.parse_string() } else { None }
  let where_ = p.parse_where()
  let mut types : Array[@core.Expr]? = None
  let mut query : @core.Expr? = None
  let mut offset : @core.Expr? = None
  let mut limit : @core.Expr? = None
  if this == "PROFILE" {
    types = Some(p.parse_csv(() => p.parse_var_from_options(profile_types)))
    query = if p.match_text_seq(["FOR", "QUERY"]) {
      p.parse_number()
    } else {
      None
    }
    offset = if p.match_text_seq(["OFFSET"]) { p.parse_number() } else { None }
    limit = if p.match_text_seq(["LIMIT"]) { p.parse_number() } else { None }
  } else {
    let (o, l) = parse_oldstyle_limit(p)
    offset = o
    limit = l
  }
  let mut mutex : Bool? = if p.match_text_seq(["MUTEX"]) {
    Some(true)
  } else {
    None
  }
  if p.match_text_seq(["STATUS"]) {
    mutex = Some(false)
  }
  let for_table = if p.match_text_seq(["FOR", "TABLE"]) {
    p.parse_id_var()
  } else {
    None
  }
  let for_group = if p.match_text_seq(["FOR", "GROUP"]) {
    p.parse_string()
  } else {
    None
  }
  let for_user = if p.match_text_seq(["FOR", "USER"]) {
    p.parse_string()
  } else {
    None
  }
  let for_role = if p.match_text_seq(["FOR", "ROLE"]) {
    p.parse_string()
  } else {
    None
  }
  let into_outfile = if p.match_text_seq(["INTO", "OUTFILE"]) {
    p.parse_string()
  } else {
    None
  }
  p.expression(
    @core.mk(Show, [
      ("this", this),
      ("target", target_id),
      ("full", if full { Some(true) } else { None }),
      ("log", log),
      ("position", position),
      ("db", db),
      ("channel", channel),
      ("like", like),
      ("where", where_),
      ("types", types),
      ("query", query),
      ("offset", offset),
      ("limit", limit),
      ("mutex", mutex),
      ("for_table", for_table),
      ("for_group", for_group),
      ("for_user", for_user),
      ("for_role", for_role),
      ("into_outfile", into_outfile),
      ("json", json),
      ("global_", if global_ { Some(true) } else { None }),
    ]),
  )
}

///|
fn parse_oldstyle_limit(
  p : @core.Parser,
) -> (@core.Expr?, @core.Expr?) raise @core.SqlglotError {
  let mut limit = None
  let mut offset = None
  if p.match_text_seq(["LIMIT"]) {
    let parts = p.parse_csv(() => p.parse_number())
    if parts.length() == 1 {
      limit = Some(parts[0])
    } else if parts.length() == 2 {
      limit = Some(parts[1])
      offset = Some(parts[0])
    }
  }
  (offset, limit)
}

///|
fn parse_set_item_charset(
  p : @core.Parser,
  kind : String,
) -> @core.Expr raise @core.SqlglotError {
  let this = match p.parse_string() {
    Some(s) => Some(s)
    None => p.parse_unquoted_field()
  }
  p.expression(@core.mk(SetItem, [("this", this), ("kind", kind)]))
}

///|
/// Preserve quoting when a charset name has characters that require it (e.g. spaces, as allowed
/// for custom XML-registered charsets). Safe names unwrap to a bare Var so roundtrips remain minimal.
fn parse_charset_name(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  match p.parse_identifier() {
    Some(identifier) => {
      let name = identifier.name()
      if @core.is_safe_identifier(name) {
        Some(@core.var_(name))
      } else {
        Some(identifier)
      }
    }
    None => p.parse_var(tokens=@core.TokenSet::new([BINARY]))
  }
}

///|
fn parse_set_item_names(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let charset = match p.parse_string() {
    Some(s) => Some(s)
    None => p.parse_unquoted_field()
  }
  let collate = if p.match_text_seq(["COLLATE"]) {
    match p.parse_string() {
      Some(s) => Some(s)
      None => p.parse_unquoted_field()
    }
  } else {
    None
  }
  p.expression(
    @core.mk(SetItem, [
      ("this", charset),
      ("collate", collate),
      ("kind", "NAMES"),
    ]),
  )
}

///|
fn parse_alter_table_alter_index(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let index = p.parse_field(any_token=true)
  let visible : Bool? = if p.match_text_seq(["VISIBLE"]) {
    Some(true)
  } else if p.match_text_seq(["INVISIBLE"]) {
    Some(false)
  } else {
    None
  }
  p.expression(@core.mk(AlterIndex, [("this", index), ("visible", visible)]))
}

///|
/// Python `MySQLParser._parse_partition_property`; `range_value` is the (possibly
/// overridden) `_parse_partition_range_value` method.
pub fn parse_partition_property(
  p : @core.Parser,
  range_value : (@core.Parser) -> @core.Expr? raise @core.SqlglotError,
) -> @core.Value? raise @core.SqlglotError {
  let (partition_kind, value_parser) : (
    @core.Kind,
    (@core.Parser) -> @core.Expr? raise @core.SqlglotError,
  ) = if p.match_text_seq(["RANGE"]) {
    (PartitionByRangeProperty, range_value)
  } else if p.match_text_seq(["LIST"]) {
    (PartitionByListProperty, parse_partition_list_value)
  } else {
    return None
  }
  let partition_expressions = p.parse_wrapped_csv(() => p.parse_assignment())
  // For Doris and Starrocks
  if !p.match_text_seq(["(", "PARTITION"], advance=false) {
    return Some(List(partition_expressions.map(e => @core.Value::Node(e))))
  }
  let create_expressions = p.parse_wrapped_csv(() => value_parser(p))
  Some(
    Node(
      p.expression(
        @core.mk(partition_kind, [
          ("partition_expressions", partition_expressions),
          ("create_expressions", create_expressions),
        ]),
      ),
    ),
  )
}

///|
/// Python `MySQLParser._parse_partition_range_value`.
pub fn parse_partition_range_value(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_text_seq(["PARTITION"]) |> ignore
  let name = p.parse_id_var()
  if !p.match_text_seq(["VALUES", "LESS", "THAN"]) {
    return name
  }
  let mut values = p.parse_wrapped_csv(() => p.parse_expression())
  if values.length() == 1 &&
    values[0].kind == Column &&
    @core.py_upper(values[0].name()) == "MAXVALUE" {
    values = [@core.var_("MAXVALUE")]
  }
  let part_range = p.expression(
    @core.mk(PartitionRange, [("this", name), ("expressions", values)]),
  )
  Some(p.expression(@core.mk(Partition, [("expressions", [part_range])])))
}

///|
fn parse_partition_list_value(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_text_seq(["PARTITION"]) |> ignore
  let name = p.parse_id_var()
  p.match_text_seq(["VALUES", "IN"]) |> ignore
  let values = p.parse_wrapped_csv(() => p.parse_expression())
  let part_list = p.expression(
    @core.mk(PartitionList, [("this", name), ("expressions", values)]),
  )
  Some(p.expression(@core.mk(Partition, [("expressions", [part_list])])))
}
