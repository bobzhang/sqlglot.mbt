// Port of sqlglot/parsers/bigquery.py

///|
fn arg(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  args.get(i)
}

///|
fn build_contains_substring(args : Array[@core.Expr]) -> @core.Expr {
  let this = @core.mk1(Lower, arg(args, 0))
  let expr = @core.mk1(Lower, arg(args, 1))
  @core.mk(Contains, [
    ("this", Some(this)),
    ("expression", Some(expr)),
    ("json_scope", arg(args, 2)),
  ])
}

///|
fn build_date(args : Array[@core.Expr]) -> @core.Expr {
  let kind : @core.Kind = if args.length() == 3 { DateFromParts } else { Date }
  @core.from_arg_list(kind, args)
}

///|
/// In BigQuery, a bare WEEK date part is equivalent to WEEK(SUNDAY)
fn normalize_bare_week(expr : @core.Expr) -> @core.Expr {
  match expr.arg("unit") {
    Some(unit) if (unit.kind == Literal || unit.kind == Var) &&
      @core.py_upper(unit.name()) == "WEEK" =>
      expr.set("unit", @core.mk1(WeekStart, @core.var_("SUNDAY")))
    _ => ()
  }
  expr
}

///|
pub fn build_date_diff(kind : @core.Kind) -> @core.FuncBuilder {
  (args, _) => {
    normalize_bare_week(
      @core.mk(kind, [
        ("this", arg(args, 0)),
        ("expression", arg(args, 1)),
        ("unit", arg(args, 2)),
        ("date_part_boundary", Some(@core.Value::Bool(true))),
      ]),
    )
  }
}

///|
fn build_datetime(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 1 {
    return @core.from_arg_list(TsOrDsToDatetime, args)
  }
  if args.length() == 2 {
    return @core.from_arg_list(Datetime, args)
  }
  @core.from_arg_list(TimestampFromParts, args)
}

///|
fn build_extract_json_with_default_path(kind : @core.Kind) -> @core.FuncBuilder {
  (args, p) => {
    let args = args.copy()
    if args.length() == 1 {
      args.push(@core.literal_string("$"))
    }
    @core.build_extract_json_with_path(kind)(args, p)
  }
}

///|
fn build_format_time(kind : @core.Kind) -> @core.FuncBuilder {
  (args, p) => {
    let formatted_time = @core.build_formatted_time_expr(
      TimeToStr,
      [
        @core.mk1(kind, arg(args, 1)),
        ..arg(args, 0).map(x => [x]).unwrap_or([]),
      ],
      p.dialect,
    )
    formatted_time.set("zone", arg(args, 2))
    formatted_time
  }
}

///|
fn build_json_strip_nulls(args : Array[@core.Expr]) -> @core.Expr {
  let expression = @core.mk1(JSONStripNulls, arg(args, 0))
  for i in 1..<args.length() {
    let a = args[i]
    if a.kind == Kwarg {
      expression.set(@core.py_lower(a.this().unwrap().name()), a)
    } else {
      expression.set("expression", a)
    }
  }
  expression
}

///|
fn build_levenshtein(args : Array[@core.Expr]) -> @core.Expr {
  let max_dist = match arg(args, 2) {
    Some(m) => m.expression()
    None => None
  }
  @core.mk(Levenshtein, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    ("max_dist", max_dist),
  ])
}

///|
/// `build_formatted_time(kind)([args[1], args[0]], dialect)`
fn formatted_time_swapped(
  kind : @core.Kind,
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  // Python passes [seq_get(args, 1), seq_get(args, 0)]; a missing first element would
  // shift positions, so keep the list positional.
  let swapped : Array[@core.Expr] = []
  match arg(args, 1) {
    Some(a) => swapped.push(a)
    None => ()
  }
  match arg(args, 0) {
    Some(a) => swapped.push(a)
    None => ()
  }
  @core.build_formatted_time_expr(kind, swapped, p.dialect)
}

///|
fn build_parse_date(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let this = formatted_time_swapped(StrToDate, args, p)
  this.set("default_year", @core.literal_number("1970"))
  this
}

///|
fn build_parse_timestamp(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let this = formatted_time_swapped(StrToTime, args, p)
  this.set("zone", arg(args, 2))
  this.set("default_year", @core.literal_number("1970"))
  this
}

///|
fn build_parse_datetime(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let this = formatted_time_swapped(ParseDatetime, args, p)
  this.set("default_year", @core.literal_number("1970"))
  this
}

///|
/// Number of capturing groups of a (Python) regular expression, or `None` if the
/// pattern is obviously invalid. Mirrors `re.compile(pattern).groups`.
fn regex_group_count(pattern : String) -> Int? {
  let chars = pattern.to_array()
  let n = chars.length()
  let mut groups = 0
  let mut depth = 0
  let mut i = 0
  let mut in_class = false
  while i < n {
    let c = chars[i]
    if c == '\\' {
      i += 2
      continue
    }
    if in_class {
      if c == ']' {
        in_class = false
      }
      i += 1
      continue
    }
    if c == '[' {
      in_class = true
      // a ']' right after '[' or '[^' is literal
      if i + 1 < n && chars[i + 1] == '^' {
        i += 1
      }
      if i + 1 < n && chars[i + 1] == ']' {
        i += 1
      }
    } else if c == '(' {
      depth += 1
      if i + 1 < n && chars[i + 1] == '?' {
        // (?P<name>...) is a named capturing group; (?P=name) is a backreference
        if i + 2 < n && chars[i + 2] == 'P' && i + 3 < n && chars[i + 3] == '<' {
          groups += 1
        }
      } else {
        groups += 1
      }
    } else if c == ')' {
      depth -= 1
      if depth < 0 {
        return None
      }
    }
    i += 1
  }
  if depth != 0 || in_class {
    return None
  }
  Some(groups)
}

///|
fn build_regexp_extract(
  kind : @core.Kind,
  default_group? : @core.Expr,
) -> @core.FuncBuilder {
  (args, p) => {
    let group = match arg(args, 1) {
      Some(a) => regex_group_count(a.name()) == Some(1)
      None => false
    }
    let e = @core.mk(kind, [
      ("this", arg(args, 0)),
      ("expression", arg(args, 1)),
      ("position", arg(args, 2)),
      ("occurrence", arg(args, 3)),
      (
        "group",
        if group {
          Some(@core.literal_number("1"))
        } else {
          default_group.map(g => g.copy())
        },
      ),
    ])
    if kind == RegexpExtract {
      e.set(
        "null_if_pos_overflow",
        p.dialect.cfg.regexp_extract_position_overflow_returns_null,
      )
    }
    e
  }
}

///|
fn build_time(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 1 {
    return @core.mk1(TsOrDsToTime, args[0])
  }
  if args.length() == 2 {
    return @core.from_arg_list(Time, args)
  }
  @core.from_arg_list(TimeFromParts, args)
}

///|
fn build_timestamp(args : Array[@core.Expr]) -> @core.Expr {
  let timestamp = @core.from_arg_list(Timestamp, args)
  timestamp.set("with_tz", true)
  timestamp
}

///|
fn build_to_hex(args : Array[@core.Expr]) -> @core.Expr {
  match arg(args, 0) {
    Some(a) if a.kind == MD5Digest => @core.mk1(MD5, a.this())
    a => @core.mk1(LowerHex, a)
  }
}

///|
/// placeholder; cannot occur in a SQL identifier
let domain_dot : String = "\u{0}"

///|
fn split_num_words(
  value : String,
  sep : String,
  min_num_words : Int,
) -> Array[String?] {
  let words : Array[String?] = value
    .split(sep)
    .map(w => Some(w.to_owned()))
    .collect()
  let out : Array[String?] = []
  for _ in 0..<(min_num_words - words.length()) {
    out.push(None)
  }
  out.append(words)
  out
}

///|
/// A dotted reference (e.g. `project.dataset.table`) is split into a fixed number of parts,
/// the first of which is the project. Domain-scoped (legacy) project IDs have the form
/// `domain.com:project-id`, where the dots belong to the domain, not the path.
fn split_qualified_name(name : String, min_num_words : Int) -> Array[String?] {
  match name.find(":") {
    Some(colon) if @core.substr(name, 0, colon).contains(".") => {
      let masked = @core.substr(name, 0, colon).replace_all(
          old=".",
          new=domain_dot,
        ) +
        @core.substr(name, colon, name.length())
      split_num_words(masked, ".", min_num_words).map(p => {
        p.map(s => s.replace_all(old=domain_dot, new="."))
      })
    }
    _ => split_num_words(name, ".", min_num_words)
  }
}

///|
fn to_quoted_identifiers(parts : Array[String?]) -> Array[@core.Expr?] {
  parts.map(p => p.map(s => @core.to_identifier(s, quoted=true)))
}

///|
let make_interval_kwargs : Array[String] = [
  "year", "month", "day", "hour", "minute", "second",
]

///|
let dashed_table_part_follow_tokens : @core.TokenSet = @core.TokenSet::new([
  @core.TokenType::DOT,
  L_PAREN,
  R_PAREN,
])

///|
fn bracket_offset(name : String) -> (Int, Bool)? {
  match name {
    "OFFSET" => Some((0, false))
    "ORDINAL" => Some((1, false))
    "SAFE_OFFSET" => Some((0, true))
    "SAFE_ORDINAL" => Some((1, true))
    _ => None
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f.remove("SEARCH")
  f["APPROX_TOP_COUNT"] = @core.from_arg_list_builder(ApproxTopK)
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["BIT_XOR"] = @core.from_arg_list_builder(BitwiseXorAgg)
  f["BIT_COUNT"] = @core.from_arg_list_builder(BitwiseCount)
  f["BOOL"] = @core.from_arg_list_builder(JSONBool)
  f["CONTAINS_SUBSTR"] = (args, _) => build_contains_substring(args)
  f["DATE"] = (args, _) => build_date(args)
  f["DATE_ADD"] = @core.build_date_delta_with_interval(DateAdd)
  f["DATE_DIFF"] = build_date_diff(DateDiff)
  f["DATE_SUB"] = @core.build_date_delta_with_interval(DateSub)
  f["DATE_TRUNC"] = (args, _) => {
    normalize_bare_week(
      @core.mk(DateTrunc, [
        ("unit", arg(args, 1)),
        ("this", arg(args, 0)),
        ("zone", arg(args, 2)),
      ]),
    )
  }
  f["DATETIME"] = (args, _) => build_datetime(args)
  f["DATETIME_ADD"] = @core.build_date_delta_with_interval(DatetimeAdd)
  f["DATETIME_DIFF"] = build_date_diff(DatetimeDiff)
  f["DATETIME_SUB"] = @core.build_date_delta_with_interval(DatetimeSub)
  f["DATETIME_TRUNC"] = (args, _) => {
    normalize_bare_week(@core.from_arg_list(DatetimeTrunc, args))
  }
  f["DIV"] = @core.binary_from_function(IntDiv)
  f["EDIT_DISTANCE"] = (args, _) => build_levenshtein(args)
  f["EMBED"] = @core.from_arg_list_builder(AIEmbed)
  f["FORMAT_DATE"] = build_format_time(TsOrDsToDate)
  f["GENERATE"] = @core.from_arg_list_builder(AIGenerate)
  f["GENERATE_ARRAY"] = @core.from_arg_list_builder(GenerateSeries)
  f["JSON_EXTRACT_SCALAR"] = build_extract_json_with_default_path(
    JSONExtractScalar,
  )
  f["JSON_EXTRACT_ARRAY"] = build_extract_json_with_default_path(
    JSONExtractArray,
  )
  f["JSON_EXTRACT_STRING_ARRAY"] = build_extract_json_with_default_path(
    JSONValueArray,
  )
  f["JSON_KEYS"] = @core.from_arg_list_builder(JSONKeysAtDepth)
  f["JSON_QUERY"] = @core.build_extract_json_with_path(JSONExtract)
  f["JSON_QUERY_ARRAY"] = build_extract_json_with_default_path(JSONExtractArray)
  f["JSON_STRIP_NULLS"] = (args, _) => build_json_strip_nulls(args)
  f["JSON_VALUE"] = build_extract_json_with_default_path(JSONExtractScalar)
  f["JSON_VALUE_ARRAY"] = build_extract_json_with_default_path(JSONValueArray)
  f["LAST_DAY"] = (args, _) => {
    normalize_bare_week(@core.from_arg_list(LastDay, args))
  }
  f["LENGTH"] = (args, _) => {
    @core.mk(Length, [
      ("this", arg(args, 0)),
      ("binary", Some(@core.Value::Bool(true))),
    ])
  }
  f["MD5"] = @core.from_arg_list_builder(MD5Digest)
  f["SHA1"] = @core.from_arg_list_builder(SHA1Digest)
  f["NORMALIZE_AND_CASEFOLD"] = (args, _) => {
    @core.mk(Normalize, [
      ("this", arg(args, 0)),
      ("form", arg(args, 1)),
      ("is_casefold", Some(@core.Value::Bool(true))),
    ])
  }
  f["OCTET_LENGTH"] = @core.from_arg_list_builder(ByteLength)
  f["TO_HEX"] = (args, _) => build_to_hex(args)
  f["PARSE_DATE"] = build_parse_date
  f["PARSE_TIME"] = (args, p) => formatted_time_swapped(ParseTime, args, p)
  f["PARSE_TIMESTAMP"] = build_parse_timestamp
  f["PARSE_DATETIME"] = build_parse_datetime
  f["REGEXP_CONTAINS"] = @core.from_arg_list_builder(RegexpLike)
  f["REGEXP_EXTRACT"] = build_regexp_extract(RegexpExtract)
  f["REGEXP_SUBSTR"] = build_regexp_extract(RegexpExtract)
  f["REGEXP_EXTRACT_ALL"] = build_regexp_extract(
    RegexpExtractAll,
    default_group=@core.literal_number("0"),
  )
  f["SHA256"] = (args, _) => {
    @core.mk(SHA2Digest, [
      ("this", arg(args, 0)),
      ("length", Some(@core.literal_number("256"))),
    ])
  }
  f["SHA512"] = (args, _) => {
    @core.mk(SHA2Digest, [
      ("this", arg(args, 0)),
      ("length", Some(@core.literal_number("512"))),
    ])
  }
  f["SIMILARITY"] = @core.from_arg_list_builder(AISimilarity)
  f["SPLIT"] = (args, _) => {
    // https://cloud.google.com/bigquery/docs/reference/standard-sql/string_functions#split
    @core.mk(Split, [
      ("this", arg(args, 0)),
      (
        "expression",
        Some(
          match arg(args, 1) {
            Some(e) => e
            None => @core.literal_string(",")
          },
        ),
      ),
    ])
  }
  f["STRPOS"] = @core.from_arg_list_builder(StrPosition)
  f["TIME"] = (args, _) => build_time(args)
  f["TIME_ADD"] = @core.build_date_delta_with_interval(TimeAdd)
  f["TIME_SUB"] = @core.build_date_delta_with_interval(TimeSub)
  f["TIMESTAMP"] = (args, _) => build_timestamp(args)
  f["TIMESTAMP_ADD"] = @core.build_date_delta_with_interval(TimestampAdd)
  f["TIMESTAMP_SUB"] = @core.build_date_delta_with_interval(TimestampSub)
  f["TIMESTAMP_MICROS"] = (args, _) => {
    @core.mk(UnixToTime, [
      ("this", arg(args, 0)),
      ("scale", Some(@core.literal_number("6"))),
    ])
  }
  f["TIMESTAMP_MILLIS"] = (args, _) => {
    @core.mk(UnixToTime, [
      ("this", arg(args, 0)),
      ("scale", Some(@core.literal_number("3"))),
    ])
  }
  f["TIMESTAMP_SECONDS"] = (args, _) => @core.mk1(UnixToTime, arg(args, 0))
  f["TIMESTAMP_TRUNC"] = (args, _) => {
    normalize_bare_week(@core.from_arg_list(TimestampTrunc, args))
  }
  f["TO_JSON"] = (args, _) => {
    @core.mk(JSONFormat, [
      ("this", arg(args, 0)),
      ("options", arg(args, 1)),
      ("to_json", Some(@core.Value::Bool(true))),
    ])
  }
  f["TO_JSON_STRING"] = @core.from_arg_list_builder(JSONFormat)
  f["FORMAT_DATETIME"] = build_format_time(TsOrDsToDatetime)
  f["FORMAT_TIMESTAMP"] = build_format_time(TsOrDsToTimestamp)
  f["FORMAT_TIME"] = build_format_time(TsOrDsToTime)
  f["FROM_HEX"] = @core.from_arg_list_builder(Unhex)
  f["WEEK"] = (args, _) => {
    @core.mk1(
      WeekStart,
      @core.var_(arg(args, 0).map(a => a.name()).unwrap_or("")),
    )
  }

  // FUNCTION_PARSERS
  let fp = fns.function_parsers
  fp.remove("TRIM")
  fp["ARRAY"] = p => {
    let stmt = p.parse_statement()
    Some(
      p.expression(
        @core.mk(Array, [
          ("expressions", stmt.map(s => [s]).unwrap_or([])),
          ("struct_name_inheritance", true),
        ]),
      ),
    )
  }
  fp["JSON_ARRAY"] = p => {
    Some(
      p.expression(
        @core.mk(JSONArray, [
          ("expressions", p.parse_csv(() => p.parse_bitwise())),
        ]),
      ),
    )
  }
  fp["MAKE_INTERVAL"] = p => Some(parse_make_interval(p))
  fp["PREDICT"] = p => Some(parse_ml(p, Predict))
  fp["TRANSLATE"] = p => Some(parse_translate(p))
  fp["FEATURES_AT_TIME"] = p => Some(parse_features_at_time(p))
  fp["GENERATE_EMBEDDING"] = p => Some(parse_ml(p, GenerateEmbedding))
  fp["GENERATE_TEXT_EMBEDDING"] = p => {
    Some(parse_ml(p, GenerateEmbedding, is_text=true))
  }
  fp["GENERATE_TEXT"] = p => Some(parse_generate(p, GenerateText))
  fp["GENERATE_TABLE"] = p => Some(parse_generate(p, GenerateTable))
  fp["GENERATE_BOOL"] = p => Some(parse_generate(p, GenerateBool))
  fp["GENERATE_INT"] = p => Some(parse_generate(p, GenerateInt))
  fp["GENERATE_DOUBLE"] = p => Some(parse_generate(p, GenerateDouble))
  fp["VECTOR_SEARCH"] = p => Some(parse_vector_search(p))
  fp["FORECAST"] = p => Some(parse_forecast(p))
  fns.property_parsers["OPTIONS"] = (p, _) => p.parse_with_property()
  fns.constraint_parsers["OPTIONS"] = p => {
    Some(@core.mk(Properties, [("expressions", p.parse_with_property())]))
  }
  fns.range_parsers.remove(OVERLAPS)
  fns.statement_parsers[ELSE] = p => Some(p.parse_as_command(p.prev))
  fns.statement_parsers[END] = p => Some(p.parse_as_command(p.prev))
  fns.statement_parsers[FOR] = p => Some(parse_for_in(p))
  fns.statement_parsers[EXPORT] = p => Some(parse_export_data(p))

  // Method overrides
  let h = fns.hooks
  h.parse_table_part = Some(parse_table_part)
  h.parse_table_parts = Some(parse_table_parts)
  h.parse_column = Some(parse_column)
  h.parse_cluster_property = Some(p => {
    Some(
      p.expression(
        @core.mk(ClusterProperty, [
          ("expressions", p.parse_csv(() => p.parse_column())),
        ]),
      ),
    )
  })
  h.parse_json_object = Some(parse_json_object)
  h.parse_bracket = Some(parse_bracket)
  h.parse_unnest = Some(parse_unnest)
  h.parse_column_ops = Some(parse_column_ops)
}

///|
fn parse_for_in(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  let index = p.index
  let this = p.parse_range()
  p.match_text_seq(["DO"]) |> ignore
  if p.match_(COMMAND) {
    p.retreat(index)
    return p.parse_as_command(p.prev)
  }
  p.expression(
    @core.mk(ForIn, [("this", this), ("expression", p.parse_statement())]),
  )
}

///|
fn parse_table_part(
  p : @core.Parser,
  schema : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let mut this = match p.parse_table_part_base(schema~) {
    Some(t) => Some(t)
    None => p.parse_number()
  }
  // https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#table_names
  match this {
    Some(t) if t.kind == Identifier => {
      let mut table_name = t.name()
      while p.match_(DASH, advance=false) && p.next.ok() {
        let start = p.curr
        let start_index = p.index
        while p.is_connected() &&
              !p.match_set(dashed_table_part_follow_tokens, advance=false) {
          p.advance()
        }
        if start_index == p.index {
          break
        }
        table_name = table_name + p.find_sql(start, p.prev)
      }
      this = Some(
        @core.mk(Identifier, [
          ("this", @core.Value::Str(table_name)),
          ("quoted", t.get("quoted")),
        ]).update_positions(Some(t)),
      )
    }
    Some(t) if t.kind == Literal => {
      let mut table_name = t.name()
      if p.is_connected() && p.parse_var(any_token=true) is Some(_) {
        table_name = table_name + p.prev.text
      }
      this = Some(
        @core.mk(Identifier, [
          ("this", @core.Value::Str(table_name)),
          ("quoted", @core.Value::Bool(true)),
        ]).update_positions(Some(t)),
      )
    }
    _ => ()
  }
  this
}

///|
fn identifier_quoted(e : @core.Expr?) -> Bool {
  match e {
    Some(x) => x.has("quoted")
    None => false
  }
}

///|
fn parse_table_parts(
  p : @core.Parser,
  schema : Bool,
  is_db_reference : Bool,
  _wildcard : Bool,
  fast : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let table = p.parse_table_parts_base(
    schema~,
    is_db_reference~,
    wildcard=true,
    fast~,
  )
  guard table is Some(table) && table.kind == Table else { return table }
  let mut table = table
  // proj-1.db.tbl -- `1.` is tokenized as a float so we need to unravel it here
  if table.catalog() == "" {
    if table.db() != "" {
      let previous_db = table.arg("db")
      let parts = table.db().split(".").map(x => x.to_owned()).collect()
      if parts.length() == 2 && !identifier_quoted(previous_db) {
        table.set(
          "catalog",
          @core.mk1(Identifier, parts[0]).update_positions(previous_db),
        )
        table.set(
          "db",
          @core.mk1(Identifier, parts[1]).update_positions(previous_db),
        )
      }
    } else {
      let previous_this = table.this()
      let parts = table.name().split(".").map(x => x.to_owned()).collect()
      if parts.length() == 2 && !identifier_quoted(previous_this) {
        table.set(
          "db",
          @core.mk1(Identifier, parts[0]).update_positions(previous_this),
        )
        table.set(
          "this",
          @core.mk1(Identifier, parts[1]).update_positions(previous_this),
        )
      }
    }
  }
  let mut alias_ident : @core.Expr? = None
  match table.this() {
    Some(this_ident) if this_ident.kind == Identifier &&
      table.parts().iter().any(part => part.name().contains(".")) => {
      alias_ident = Some(this_ident)
      let joined = table.parts().map(part => part.name()).join(".")
      let ids = to_quoted_identifiers(split_qualified_name(joined, 3))
      let catalog = ids[0]
      let db = ids[1]
      let this_id = ids[2]
      let rest : Array[@core.Expr] = []
      for i in 3..<ids.length() {
        match ids[i] {
          Some(x) => rest.push(x)
          None => ()
        }
      }
      for part in [catalog, db, this_id] {
        match part {
          Some(x) => x.update_positions(Some(this_ident)) |> ignore
          None => ()
        }
      }
      let mut this = this_id
      if !rest.is_empty() && this is Some(t) {
        this = Some(@core.dot_build([t, ..rest]))
      }
      table = @core.mk(Table, [
        ("this", this),
        ("db", db),
        ("catalog", catalog),
        ("pivots", table.get("pivots")),
      ])
      table.get_meta()["quoted_table"] = Bool(true)
    }
    _ => ()
  }
  // The `INFORMATION_SCHEMA` views in BigQuery need to be qualified by a region or
  // dataset, so if the project identifier is omitted we need to fix the ast so that
  // the `INFORMATION_SCHEMA.X` bit is represented as a single (quoted) Identifier.
  let table_parts = table.parts()
  let n = table_parts.length()
  if n > 1 && @core.py_upper(table_parts[n - 2].name()) == "INFORMATION_SCHEMA" {
    // We need to alias the table here to avoid breaking existing qualified columns.
    let alias_node = match alias_ident {
      Some(a) => a
      None => table_parts[n - 1]
    }
    table.set("alias", @core.mk1(TableAlias, alias_node))
    let info_schema_view = "\{table_parts[n - 2].name()}.\{table_parts[n - 1].name()}"
    let new_this = @core.mk(Identifier, [
      ("this", @core.Value::Str(info_schema_view)),
      ("quoted", @core.Value::Bool(true)),
    ])
    let m = new_this.get_meta()
    match table_parts[n - 2].meta_get("line") {
      Some(v) => m["line"] = v
      None => ()
    }
    match table_parts[n - 1].meta_get("col") {
      Some(v) => m["col"] = v
      None => ()
    }
    match table_parts[n - 2].meta_get("start") {
      Some(v) => m["start"] = v
      None => ()
    }
    match table_parts[n - 1].meta_get("end") {
      Some(v) => m["end"] = v
      None => ()
    }
    table.set("this", new_this)
    table.set("db", if n >= 3 { Some(table_parts[n - 3]) } else { None })
    table.set("catalog", if n >= 4 { Some(table_parts[n - 4]) } else { None })
  }
  Some(table)
}

///|
fn parse_column(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let column = p.parse_column_base()
  match column {
    Some(c) if c.kind.is_a(Column) => {
      let parts = c.parts()
      if parts.iter().any(part => part.name().contains(".")) {
        let joined = parts.map(part => part.name()).join(".")
        let ids = to_quoted_identifiers(split_qualified_name(joined, 4))
        let catalog = ids[0]
        let db = ids[1]
        let table = ids[2]
        let this_id = ids[3]
        let rest : Array[@core.Expr] = []
        for i in 4..<ids.length() {
          match ids[i] {
            Some(x) => rest.push(x)
            None => ()
          }
        }
        let mut this = this_id
        if !rest.is_empty() && this is Some(t) {
          this = Some(@core.dot_build([t, ..rest]))
        }
        let column = @core.mk(Column, [
          ("this", this),
          ("table", table),
          ("db", db),
          ("catalog", catalog),
        ])
        column.get_meta()["quoted_column"] = Bool(true)
        return Some(column)
      }
      column
    }
    _ => column
  }
}

///|
fn parse_json_object(
  p : @core.Parser,
  _agg : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let json_object = p.parse_json_object_base()
  guard json_object is Some(jo) else { return json_object }
  // Converts BQ's "signature 2" of JSON_OBJECT into SQLGlot's canonical representation
  // https://cloud.google.com/bigquery/docs/reference/standard-sql/json_functions#json_object_signature2
  match jo.expressions().get(0) {
    Some(array_kv_pair) =>
      match (array_kv_pair.this(), array_kv_pair.expression()) {
        (Some(keys), Some(values)) if keys.kind == Array && values.kind == Array => {
          let ks = keys.expressions()
          let vs = values.expressions()
          let n = if ks.length() < vs.length() {
            ks.length()
          } else {
            vs.length()
          }
          let kvs = Array::makei(n, i => {
            @core.mk(JSONKeyValue, [("this", ks[i]), ("expression", vs[i])])
          })
          jo.set("expressions", kvs)
        }
        _ => ()
      }
    None => ()
  }
  json_object
}

///|
fn parse_bracket(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let bracket = p.parse_bracket_base(this)
  match bracket {
    Some(b) if b.kind == Array => b.set("struct_name_inheritance", true)
    _ => ()
  }
  match (this, bracket) {
    (Some(t), Some(b)) if physical_equal(t, b) => return bracket
    (None, None) => return bracket
    _ => ()
  }
  match bracket {
    Some(b) if b.kind == Bracket =>
      for expression in b.expressions() {
        let name = @core.py_upper(expression.name())
        let expressions = expression.expressions()
        guard bracket_offset(name) is Some((offset, safe)) &&
          !expressions.is_empty() else {
          break
        }
        b.set("offset", offset)
        b.set("safe", safe)
        expression.replace(Some(expressions[0])) |> ignore
      }
    _ => ()
  }
  bracket
}

///|
fn parse_unnest(
  p : @core.Parser,
  with_alias : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let unnest = p.parse_unnest_base(with_alias~)
  guard unnest is Some(u) else { return None }
  match u.expressions().get(0) {
    Some(unnest_expr) => {
      let unnest_expr = @core.gen_annotate_types(unnest_expr, p.dialect)
      // Unnesting a nested array (i.e array of structs) explodes the top-level struct fields,
      // in contrast to other dialects such as DuckDB which flattens only the array by default
      if unnest_expr.is_type([ARRAY]) {
        let elems = match unnest_expr.get_type() {
          Some(t) => t.expressions()
          None => []
        }
        // Until the optimizer's annotate_types is available, the element type of an
        // array literal is approximated by its first non-NULL element.
        let first_elem = unnest_expr
          .expressions()
          .iter()
          .find_first(x => x.kind != Null)
        let literal_struct_elems = unnest_expr.kind == Array &&
          first_elem is Some(first) &&
          first.kind == Struct
        if elems.iter().any(elem => elem.is_type([STRUCT])) ||
          (elems.is_empty() && literal_struct_elems) {
          u.set("explode_array", true)
        }
      }
    }
    None => ()
  }
  unnest
}

///|
fn parse_make_interval(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  let expr = @core.mk0(MakeInterval)
  for key in make_interval_kwargs {
    let value = p.parse_lambda()
    guard value is Some(v) else { break }
    // Non-named arguments are filled sequentially, (optionally) followed by named arguments
    // that can appear in any order e.g MAKE_INTERVAL(1, minute => 5, day => 2)
    let arg_key = if v.kind == Kwarg { v.this().unwrap().name() } else { key }
    expr.set(arg_key, v)
    p.match_(COMMA) |> ignore
  }
  expr
}

///|
fn parse_ml(
  p : @core.Parser,
  kind : @core.Kind,
  is_text? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  p.match_text_seq(["MODEL"]) |> ignore
  let this = p.parse_table()
  p.match_(COMMA) |> ignore
  p.match_text_seq(["TABLE"]) |> ignore
  // Certain functions like ML.FORECAST require a STRUCT argument but not a TABLE/SELECT one
  let expression = if !p.match_(STRUCT, advance=false) {
    p.parse_table()
  } else {
    None
  }
  p.match_(COMMA) |> ignore
  let e = @core.mk(kind, [
    ("this", this),
    ("expression", expression),
    ("params_struct", p.parse_bitwise()),
  ])
  if is_text {
    e.set("is_text", true)
  }
  p.expression(e)
}

///|
fn parse_generate(
  p : @core.Parser,
  kind : @core.Kind,
) -> @core.Expr raise @core.SqlglotError {
  p.match_text_seq(["MODEL"]) |> ignore
  let this = p.parse_table()
  p.match_(COMMA) |> ignore
  let expression = if p.match_text_seq(["TABLE"]) {
    p.parse_table()
  } else if p.match_(L_PAREN, advance=false) {
    p.parse_table()
  } else {
    p.parse_bitwise()
  }
  let params_struct : @core.Value? = if p.match_(COMMA) {
    p.parse_bitwise().map(e => @core.Value::Node(e))
  } else {
    Some(Bool(false))
  }
  p.expression(
    @core.mk(kind, [
      ("this", this),
      ("expression", expression),
      ("params_struct", params_struct),
    ]),
  )
}

///|
fn token_text_at(p : @core.Parser, index : Int) -> String? {
  if index >= 0 && index < p.tokens.length() {
    Some(p.tokens[index].text)
  } else if index < 0 && -index <= p.tokens.length() {
    // Python negative indexing
    Some(p.tokens[p.tokens.length() + index].text)
  } else {
    None
  }
}

///|
fn parse_translate(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  // Check if this is ML.TRANSLATE by looking at previous tokens
  if token_text_at(p, p.index - 4).map(@core.py_upper) == Some("ML") {
    return parse_ml(p, MLTranslate)
  }
  @core.from_arg_list(Translate, p.parse_function_args())
}

///|
fn parse_forecast(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  // Check if this is ML.FORECAST by looking at previous tokens.
  if token_text_at(p, p.index - 4).map(@core.py_upper) == Some("ML") {
    return parse_ml(p, MLForecast)
  }
  // AI.FORECAST is a TVF, where the first argument is either TABLE <table>
  // or a parenthesized query statement, followed by named arguments.
  p.match_(TABLE) |> ignore
  let this = p.parse_table()
  if this is None {
    p.raise_error("Expected table or query statement")
  }
  let expr = p.expression(@core.mk1(AIForecast, this))
  while p.match_(COMMA) {
    let a = p.parse_lambda()
    match a {
      Some(kw) if kw.kind == Kwarg => expr.set(kw.this().unwrap().name(), kw)
      _ => {
        p.raise_error(
          "Expected key => value syntax for AI.FORECAST, got \{a.map(x => @core.expr_to_sql(x)).unwrap_or("None")}",
        )
        break
      }
    }
  }
  expr
}

///|
fn parse_features_at_time(
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  p.match_(TABLE) |> ignore
  let this = p.parse_table()
  let expr = p.expression(@core.mk1(FeaturesAtTime, this))
  while p.match_(COMMA) {
    let a = p.parse_lambda()
    // Get the LHS of the Kwarg and set the arg to that value, e.g
    // "num_rows => 1" sets the expr's `num_rows` arg
    match a {
      Some(kw) => expr.set(kw.this().map(t => t.name()).unwrap_or(""), kw)
      None => ()
    }
  }
  expr
}

///|
fn parse_vector_search(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  p.match_(TABLE) |> ignore
  let base_table = p.parse_table()
  p.match_(COMMA) |> ignore
  let column_to_search = p.parse_bitwise()
  p.match_(COMMA) |> ignore
  p.match_(TABLE) |> ignore
  let query_table = p.parse_table()
  let expr = p.expression(
    @core.mk(VectorSearch, [
      ("this", base_table),
      ("column_to_search", column_to_search),
      ("query_table", query_table),
    ]),
  )
  while p.match_(COMMA) {
    // query_column_to_search can be named argument or positional
    if p.match_(STRING, advance=false) {
      let query_column = p.parse_string()
      expr.set("query_column_to_search", query_column)
    } else {
      match p.parse_lambda() {
        Some(kw) => expr.set(kw.this().map(t => t.name()).unwrap_or(""), kw)
        None => ()
      }
    }
  }
  expr
}

///|
fn parse_export_data(p : @core.Parser) -> @core.Expr raise @core.SqlglotError {
  p.match_text_seq(["DATA"]) |> ignore
  let connection : @core.Value? = if p.match_text_seq(["WITH", "CONNECTION"]) {
    p.parse_table_parts().map(e => @core.Value::Node(e))
  } else {
    Some(Bool(false))
  }
  let options = p.parse_properties()
  let this = if p.match_text_seq(["AS"]) {
    p.parse_select(nested=true)
  } else {
    None
  }
  p.expression(
    @core.mk(Export, [
      ("connection", connection),
      ("options", options),
      ("this", this),
    ]),
  )
}

///|
fn parse_column_ops(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  let func_index = p.index + 1
  let mut this = p.parse_column_ops_base(this)
  match this {
    Some(dot) if dot.kind == Dot &&
      dot.expression() is Some(fe) &&
      fe.kind.is_a(Func) => {
      let prefix = @core.py_upper(dot.this().map(t => t.name()).unwrap_or(""))
      let func : @core.Kind? = if prefix == "NET" {
        Some(NetFunc)
      } else if prefix == "SAFE" {
        Some(SafeFunc)
      } else {
        None
      }
      match func {
        Some(k) => {
          // Retreat to try and parse a known function instead of an anonymous one,
          // which is parsed by the base column ops parser due to anonymous_func=true
          p.retreat(func_index)
          this = Some(@core.mk1(k, p.parse_function(any_token=true)))
        }
        None =>
          if prefix == "AI" || prefix == "ML" {
            // AI.* and ML.* function calls can use custom BigQuery signatures that rely on
            // function parsers, so re-parse the function in non-anonymous mode.
            p.retreat(func_index)
            let parsed = p.parse_function(any_token=true)
            if parsed is Some(_) {
              this = Some(
                p.expression(
                  @core.mk(Dot, [("this", dot.this()), ("expression", parsed)]),
                ),
              )
            }
          }
      }
    }
    _ => ()
  }
  this
}
