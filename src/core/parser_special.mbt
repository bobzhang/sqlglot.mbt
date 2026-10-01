// Port of sqlglot/parser.py: special function parsers and window functions.

///|
pub fn Parser::parse_case(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(DOT, advance=false) {
    self.retreat(self.index - 1)
    return None
  }
  let ifs = []
  let mut default : Expr? = None
  let comments = self.prev_comments
  let expression = self.parse_disjunction()
  while self.match_(WHEN) {
    let this = self.parse_disjunction()
    self.match_(THEN) |> ignore
    let then = self.parse_disjunction()
    ifs.push(self.expression(mk(If, [("this", this), ("true", then)])))
  }
  if self.match_(ELSE) {
    default = self.parse_disjunction()
  }
  if !self.match_(END) {
    let is_end_interval = match default {
      Some(d) if d.kind == Interval =>
        match d.this() {
          Some(t) => py_upper(expr_to_sql(t)) == "END"
          None => false
        }
      _ => false
    }
    if is_end_interval {
      default = Some(column_of("interval"))
    } else {
      self.raise_error("Expected END after CASE", token=self.prev)
    }
  }
  Some(
    self.expression(
      mk(Case, [("this", expression), ("ifs", ifs), ("default", default)]),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_if(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_if {
    Some(f) => f(self)
    None => self.parse_if_base()
  }
}

///|
pub fn Parser::parse_if_base(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(L_PAREN) {
    let args = self.parse_csv(() => {
      self.parse_alias(self.parse_assignment(), explicit=true)
    })
    let this = self.validate_expression(
      from_arg_list(If, args),
      nargs=args.length(),
    )
    self.match_r_paren()
    Some(this)
  } else {
    let index = self.index - 1
    if self.cfg.no_paren_if_commands && index == 0 {
      return Some(self.parse_as_command(self.prev))
    }
    let condition = match self.parse_disjunction() {
      Some(c) => c
      None => {
        self.retreat(index)
        return None
      }
    }
    self.match_(THEN) |> ignore
    let true_ = self.parse_disjunction()
    let false_ = if self.match_(ELSE) { self.parse_disjunction() } else { None }
    self.match_(END) |> ignore
    Some(
      self.expression(
        mk(If, [("this", condition), ("true", true_), ("false", false_)]),
      ),
    )
  }
}

///|
pub fn Parser::parse_next_value_for(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text_seq(["VALUE", "FOR"]) {
    self.retreat(self.index - 1)
    return None
  }
  let this = self.parse_column()
  let order = self.andv(self.match_(OVER), () => {
    self.parse_wrapped(() => self.parse_order())
  })
  Some(self.expression(mk(NextValueFor, [("this", this), ("order", order)])))
}

///|
pub fn Parser::parse_extract(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_extract {
    Some(f) => f(self)
    None => self.parse_extract_base()
  }
}

///|
pub fn Parser::parse_extract_base(self : Parser) -> Expr? raise SqlglotError {
  let this = expr_or(self.parse_function(), () => {
    self.parse_var_or_string(upper=true)
  })
  if self.match_(FROM) {
    return Some(
      self.expression(
        mk(Extract, [("this", this), ("expression", self.parse_bitwise())]),
      ),
    )
  }
  if !self.match_(COMMA) {
    self.raise_error("Expected FROM or comma after EXTRACT", token=self.prev)
  }
  Some(
    self.expression(
      mk(Extract, [("this", this), ("expression", self.parse_bitwise())]),
    ),
  )
}

///|
pub fn Parser::parse_gap_fill(self : Parser) -> Expr? raise SqlglotError {
  self.match_(TABLE) |> ignore
  let this = self.parse_table()
  self.match_(COMMA) |> ignore
  let args = [this].filter_map(x => x)
  args.append(self.parse_csv(() => self.parse_lambda()))
  let gap_fill = from_arg_list(GapFill, args)
  Some(self.validate_expression(gap_fill, nargs=args.length()))
}

///|
pub fn Parser::parse_char(self : Parser) -> Expr? raise SqlglotError {
  let expressions = self.parse_csv(() => self.parse_assignment())
  let charset = self.andv(self.match_(USING), () => self.parse_charset_name())
  Some(
    self.expression(
      mk(Chr, [("expressions", expressions), ("charset", charset)]),
    ),
  )
}

///|
pub fn Parser::parse_charset_name(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_charset_name {
    Some(f) => f(self)
    None => self.parse_var(tokens=TokenSet::new([BINARY, IDENTIFIER]))
  }
}

///|
pub fn Parser::parse_cast(
  self : Parser,
  strict : Bool,
  safe? : Bool,
) -> Expr? raise SqlglotError {
  let mut this = self.parse_assignment()
  if !self.match_(ALIAS) {
    if self.match_(COMMA) {
      return Some(
        self.expression(
          mk(CastToStrType, [("this", this), ("to", self.parse_string())]),
        ),
      )
    }
    self.raise_error("Expected AS after CAST")
  }
  let mut fmt : Expr? = None
  let mut to = self.parse_types(with_collation=true)
  let mut default : Expr? = None
  if self.match_(DEFAULT) {
    default = self.parse_bitwise()
    self.match_text_seq(["ON", "CONVERSION", "ERROR"]) |> ignore
  }
  if self.match_any([FORMAT, COMMA]) {
    let fmt_string = self.parse_wrapped(
      () => self.parse_string(),
      optional=true,
    )
    fmt = self.parse_at_time_zone(fmt_string)
    let to_ = match to {
      Some(t) => t
      None => mk1(DataType, DType::UNKNOWN)
    }
    to = Some(to_)
    match to_.args.get("this") {
      Some(DT(d)) if dtype_temporal_types.contains(d) => {
        let fmt_text = match fmt_string {
          Some(f) => f.text("this")
          None => ""
        }
        let mapping = if self.dialect.cfg.format_mapping.is_empty() {
          self.dialect.cfg.time_mapping
        } else {
          self.dialect.cfg.format_mapping
        }
        let trie = if self.dialect.cfg.format_mapping.is_empty() {
          self.dialect.time_trie
        } else {
          self.dialect.format_trie
        }
        let kind = if d == DType::DATE { StrToDate } else { StrToTime }
        let result = self.expression(
          mk(kind, [
            ("this", this),
            ("format", literal_string(format_time(fmt_text, mapping, trie))),
            ("safe", safe),
          ]),
        )
        match fmt {
          Some(f) if f.kind == AtTimeZone && result.kind == StrToTime =>
            result.set("zone", f.arg("zone"))
          _ => ()
        }
        return Some(result)
      }
      _ => ()
    }
  } else {
    match to {
      None => self.raise_error("Expected TYPE after CAST")
      Some(t) if t.kind == Identifier =>
        to = Some(datatype_from_str(t.name(), dialect=self.dialect, udt=true))
      Some(t) =>
        match t.args.get("this") {
          Some(DT(DType::CHAR)) if self.match_(CHARACTER_SET) ||
            self.match_text_seq(["CHARACTER", "SET"]) =>
            to = Some(
              mk(DataType, [
                ("this", DType::CHARACTER_SET),
                ("kind", self.parse_var_or_string()),
              ]),
            )
          _ => ()
        }
    }
  }
  let action = self.parse_var_from_options(
    self.cfg.cast_actions,
    raise_unmatched=false,
  )
  this = Some(
    self.build_cast(strict, [
      ("this", this.map(x => Node(x))),
      ("to", to.map(x => Node(x))),
      ("format", fmt.map(x => Node(x))),
      ("safe", safe.map(x => Bool(x))),
      ("action", action.map(x => Node(x))),
      ("default", default.map(x => Node(x))),
    ]),
  )
  this
}

///|
pub fn Parser::build_cast(
  self : Parser,
  strict : Bool,
  kwargs : Array[(String, Value?)],
) -> Expr raise SqlglotError {
  match self.fns.hooks.build_cast {
    Some(f) => f(self, strict, kwargs)
    None => self.build_cast_base(strict, kwargs)
  }
}

///|
pub fn Parser::build_cast_base(
  self : Parser,
  strict : Bool,
  kwargs : Array[(String, Value?)],
) -> Expr raise SqlglotError {
  let kind = if strict { Cast } else { TryCast }
  let args = Args::new()
  for kv in kwargs {
    match kv.1 {
      Some(v) => args[kv.0] = v
      None => ()
    }
  }
  if kind == TryCast {
    match self.dialect.cfg.try_cast_requires_string {
      Some(b) => args["requires_string"] = Bool(b)
      None => ()
    }
  }
  self.expression(Expr::new(kind, args))
}

///|
pub fn Parser::parse_string_agg(self : Parser) -> Expr? raise SqlglotError {
  let args : Array[Expr] = if self.match_(DISTINCT) {
    let a = [
      self.expression(
        mk(Distinct, [
          ("expressions", [self.parse_disjunction()].filter_map(x => x)),
        ]),
      ),
    ]
    if self.match_(COMMA) {
      a.append(self.parse_csv(() => self.parse_disjunction()))
    }
    a
  } else {
    self.parse_csv(() => self.parse_disjunction())
  }
  let on_overflow = if self.match_text_seq(["ON", "OVERFLOW"]) {
    if self.match_text("ERROR") {
      Some(var_("ERROR"))
    } else {
      self.match_text("TRUNCATE") |> ignore
      let this = self.parse_string()
      let with_count = self.match_text_seq(["WITH", "COUNT"]) ||
        !self.match_text_seq(["WITHOUT", "COUNT"])
      Some(
        self.expression(
          mk(OverflowTruncateBehavior, [
            ("this", this),
            ("with_count", with_count),
          ]),
        ),
      )
    }
  } else {
    None
  }
  let index = self.index
  if !self.match_(R_PAREN) && !args.is_empty() {
    let first = self.parse_limit(this=self.parse_order(this=Some(args[0])))
    return Some(
      self.expression(
        mk(GroupConcat, [("this", first), ("separator", args.get(1))]),
      ),
    )
  }
  if !self.match_text_seq(["WITHIN", "GROUP"]) {
    self.retreat(index)
    return Some(
      self.validate_expression(
        from_arg_list(GroupConcat, args),
        nargs=args.length(),
      ),
    )
  }
  self.match_l_paren()
  Some(
    self.expression(
      mk(GroupConcat, [
        ("this", self.parse_order(this=args.get(0))),
        ("separator", args.get(1)),
        ("on_overflow", on_overflow),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_convert(
  self : Parser,
  strict : Bool,
  safe? : Bool,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_convert {
    Some(f) => f(self, strict, safe)
    None => self.parse_convert_base(strict, safe?)
  }
}

///|
pub fn Parser::parse_convert_base(
  self : Parser,
  strict : Bool,
  safe? : Bool,
) -> Expr? raise SqlglotError {
  let this = self.parse_bitwise()
  let to = if self.match_(USING) {
    Some(
      mk(DataType, [
        ("this", DType::CHARACTER_SET),
        ("kind", self.parse_charset_name()),
      ]),
    )
  } else if self.match_(COMMA) {
    self.parse_types()
  } else {
    None
  }
  Some(
    self.build_cast(strict, [
      ("this", this.map(x => Node(x))),
      ("to", to.map(x => Node(x))),
      ("safe", safe.map(x => Bool(x))),
    ]),
  )
}

///|
pub fn Parser::parse_xml_element(self : Parser) -> Expr? raise SqlglotError {
  let mut evalname : Bool? = None
  let this = if self.match_text("EVALNAME") {
    evalname = Some(true)
    self.parse_bitwise()
  } else {
    self.match_text("NAME") |> ignore
    self.parse_id_var()
  }
  let expressions = self.andl(self.match_(COMMA), () => {
    self.parse_csv(() => self.parse_bitwise())
  })
  Some(
    self.expression(
      mk(XMLElement, [
        ("this", this),
        ("expressions", expressions),
        ("evalname", evalname),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_xml_table(self : Parser) -> Expr? raise SqlglotError {
  let mut namespaces : Array[Expr]? = None
  let mut passing : Array[Expr]? = None
  let mut columns : Array[Expr]? = None
  if self.match_text_seq(["XMLNAMESPACES", "("]) {
    namespaces = Some(self.parse_xml_namespace())
    self.match_text_seq([")", ","]) |> ignore
  }
  let this = self.parse_string()
  if self.match_text("PASSING") {
    self.match_text_seq(["BY", "VALUE"]) |> ignore
    passing = Some(self.parse_csv(() => self.parse_column()))
  }
  let by_ref = self.match_text_seq(["RETURNING", "SEQUENCE", "BY", "REF"])
  if self.match_text("COLUMNS") {
    columns = Some(self.parse_csv(() => self.parse_field_def()))
  }
  Some(
    self.expression(
      mk(XMLTable, [
        ("this", this),
        ("namespaces", namespaces),
        ("passing", passing),
        ("columns", columns),
        ("by_ref", by_ref),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_xml_namespace(
  self : Parser,
) -> Array[Expr] raise SqlglotError {
  let namespaces = []
  while true {
    let uri = if self.match_(DEFAULT) {
      self.parse_string()
    } else {
      self.parse_alias(self.parse_string())
    }
    namespaces.push(self.expression(mk1(XMLNamespace, uri)))
    if !self.match_(COMMA) {
      break
    }
  }
  namespaces
}

///|
pub fn Parser::parse_decode(self : Parser) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_disjunction())
  if args.length() < 3 {
    return Some(
      self.expression(
        mk(Decode, [("this", args.get(0)), ("charset", args.get(1))]),
      ),
    )
  }
  Some(self.expression(mk(DecodeCase, [("expressions", args)])))
}

///|
pub fn Parser::parse_json_key_value(self : Parser) -> Expr? raise SqlglotError {
  self.match_text("KEY") |> ignore
  let key = self.parse_column()
  self.match_set(self.cfg.json_key_value_separator_tokens) |> ignore
  self.match_text("VALUE") |> ignore
  let value = self.parse_bitwise()
  if key is None && value is None {
    return None
  }
  Some(
    self.expression(mk(JSONKeyValue, [("this", key), ("expression", value)])),
  )
}

///|
pub fn Parser::parse_format_json(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if this is None || !self.match_text_seq(["FORMAT", "JSON"]) {
    return this
  }
  Some(self.expression(mk1(FormatJson, this)))
}

///|
pub fn Parser::parse_on_condition(self : Parser) -> Expr? raise SqlglotError {
  let values = self.cfg.on_condition_tokens.iter().collect()
  let (empty, error) = if self.dialect.cfg.on_condition_empty_before_error {
    let empty = self.parse_on_handling("EMPTY", values)
    let error = self.parse_on_handling("ERROR", values)
    (empty, error)
  } else {
    let error = self.parse_on_handling("ERROR", values)
    let empty = self.parse_on_handling("EMPTY", values)
    (empty, error)
  }
  let null = self.parse_on_handling("NULL", values)
  if empty is None && error is None && null is None {
    return None
  }
  Some(
    self.expression(
      mk(OnCondition, [("empty", empty), ("error", error), ("null", null)]),
    ),
  )
}

///|
/// Parses "X ON Y" or "DEFAULT <expr> ON Y". Returns a string or an expression.
pub fn Parser::parse_on_handling(
  self : Parser,
  on : String,
  values : Array[String],
) -> Value? raise SqlglotError {
  for value in values {
    if self.match_text_seq([value, "ON", on]) {
      return Some(Str("\{value} ON \{on}"))
    }
  }
  let index = self.index
  if self.match_(DEFAULT) {
    let default_value = self.parse_bitwise()
    if self.match_text_seq(["ON", on]) {
      return default_value.map(x => Node(x))
    }
    self.retreat(index)
  }
  None
}

///|
pub fn Parser::parse_json_object(
  self : Parser,
  agg? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_json_object {
    Some(f) => f(self, agg)
    None => self.parse_json_object_base(agg~)
  }
}

///|
pub fn Parser::parse_json_object_base(
  self : Parser,
  agg? : Bool = false,
) -> Expr? raise SqlglotError {
  let star = self.parse_star()
  let expressions = match star {
    Some(s) => [s]
    None =>
      self.parse_csv(() => self.parse_format_json(self.parse_json_key_value()))
  }
  let null_handling = self.parse_on_handling("NULL", ["NULL", "ABSENT"])
  let mut unique_keys : Bool? = None
  if self.match_text_seq(["WITH", "UNIQUE"]) {
    unique_keys = Some(true)
  } else if self.match_text_seq(["WITHOUT", "UNIQUE"]) {
    unique_keys = Some(false)
  }
  self.match_text("KEYS") |> ignore
  let return_type = self.andv(self.match_text("RETURNING"), () => {
    self.parse_format_json(self.parse_type())
  })
  let encoding = self.andv(self.match_text("ENCODING"), () => self.parse_var())
  let kind = if agg { JSONObjectAgg } else { JSONObject }
  Some(
    self.expression(
      mk(kind, [
        ("expressions", expressions),
        ("null_handling", null_handling),
        ("unique_keys", unique_keys),
        ("return_type", return_type),
        ("encoding", encoding),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_json_column_def(self : Parser) -> Expr? raise SqlglotError {
  let mut this : Expr? = None
  let mut ordinality : Bool? = None
  let mut kind : Expr? = None
  let mut nested : Bool? = None
  if !self.match_text("NESTED") {
    this = self.parse_id_var()
    ordinality = Some(self.match_pair(FOR, ORDINALITY))
    kind = self.parse_types(allow_identifiers=false)
  } else {
    nested = Some(true)
  }
  let format_json = self.match_text_seq(["FORMAT", "JSON"])
  let path = self.andv(self.match_text("PATH"), () => self.parse_string())
  let nested_schema : Value? = match nested {
    Some(true) => Some(Node(self.parse_json_schema()))
    _ => nested.map(x => Bool(x))
  }
  Some(
    self.expression(
      mk(JSONColumnDef, [
        ("this", this),
        ("kind", kind),
        ("path", path),
        ("nested_schema", nested_schema),
        ("ordinality", ordinality),
        ("format_json", format_json),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_json_schema(self : Parser) -> Expr raise SqlglotError {
  self.match_text("COLUMNS") |> ignore
  self.expression(
    mk(JSONSchema, [
      (
        "expressions",
        self.parse_wrapped_csv(
          () => self.parse_json_column_def(),
          optional=true,
        ),
      ),
    ]),
  )
}

///|
pub fn Parser::parse_json_table(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_format_json(self.parse_bitwise())
  let path = self.andv(self.match_(COMMA), () => self.parse_string())
  let error_handling = self.parse_on_handling("ERROR", ["ERROR", "NULL"])
  let empty_handling = self.parse_on_handling("EMPTY", ["ERROR", "NULL"])
  let schema = self.parse_json_schema()
  Some(
    mk(JSONTable, [
      ("this", this),
      ("schema", schema),
      ("path", path),
      ("error_handling", error_handling),
      ("empty_handling", empty_handling),
    ]),
  )
}

///|
pub fn Parser::parse_match_against(self : Parser) -> Expr? raise SqlglotError {
  let expressions = if self.match_text("TABLE") {
    match self.parse_table() {
      Some(t) => [t]
      None => []
    }
  } else {
    self.parse_csv(() => self.parse_column())
  }
  self.match_text_seq([")", "AGAINST", "("]) |> ignore
  let this = self.parse_string()
  let modifier = if self.match_text_seq(["IN", "NATURAL", "LANGUAGE", "MODE"]) {
    if self.match_text_seq(["WITH", "QUERY", "EXPANSION"]) {
      Some("IN NATURAL LANGUAGE MODE WITH QUERY EXPANSION")
    } else {
      Some("IN NATURAL LANGUAGE MODE")
    }
  } else if self.match_text_seq(["IN", "BOOLEAN", "MODE"]) {
    Some("IN BOOLEAN MODE")
  } else if self.match_text_seq(["WITH", "QUERY", "EXPANSION"]) {
    Some("WITH QUERY EXPANSION")
  } else {
    None
  }
  Some(
    self.expression(
      mk(MatchAgainst, [
        ("this", this),
        ("expressions", expressions),
        ("modifier", modifier),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_open_json(self : Parser) -> Expr? raise SqlglotError {
  let this = self.parse_bitwise()
  let path = self.andv(self.match_(COMMA), () => self.parse_string())
  fn parse_open_json_column_def() -> Expr? raise SqlglotError {
    let this = self.parse_field(any_token=true)
    let kind = self.parse_types()
    let path = self.parse_string()
    let as_json = self.match_pair(ALIAS, JSON)
    Some(
      self.expression(
        mk(OpenJSONColumnDef, [
          ("this", this),
          ("kind", kind),
          ("path", path),
          ("as_json", as_json),
        ]),
      ),
    )
  }

  let expressions = if self.match_pair(R_PAREN, WITH) {
    self.match_l_paren()
    Some(self.parse_csv(parse_open_json_column_def))
  } else {
    None
  }
  Some(
    self.expression(
      mk(OpenJSON, [
        ("this", this),
        ("path", path),
        ("expressions", expressions),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_position(
  self : Parser,
  haystack_first? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_position {
    Some(f) => f(self, haystack_first)
    None => self.parse_position_base(haystack_first~)
  }
}

///|
pub fn Parser::parse_position_base(
  self : Parser,
  haystack_first? : Bool = false,
) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_bitwise())
  if self.match_(IN) {
    return Some(
      self.expression(
        mk(StrPosition, [
          ("this", self.parse_bitwise()),
          ("substr", args.get(0)),
        ]),
      ),
    )
  }
  let (haystack, needle) = if haystack_first {
    (args.get(0), args.get(1))
  } else {
    (args.get(1), args.get(0))
  }
  Some(
    self.expression(
      mk(StrPosition, [
        ("this", haystack),
        ("substr", needle),
        ("position", args.get(2)),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_join_hint(
  self : Parser,
  func_name : String,
) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_table())
  Some(mk(JoinHint, [("this", py_upper(func_name)), ("expressions", args)]))
}

///|
pub fn Parser::parse_substring(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_substring {
    Some(f) => f(self)
    None => self.parse_substring_base()
  }
}

///|
pub fn Parser::parse_substring_base(self : Parser) -> Expr? raise SqlglotError {
  let args = self.parse_csv(() => self.parse_bitwise())
  let mut start : Expr? = None
  let mut length : Expr? = None
  while self.curr.ok() {
    if self.match_(FROM) {
      start = self.parse_bitwise()
    } else if self.match_(FOR) {
      if start is None {
        start = Some(literal_int(1))
      }
      length = self.parse_bitwise()
    } else {
      break
    }
  }
  match start {
    Some(s) => args.push(s)
    None => ()
  }
  match length {
    Some(l) => args.push(l)
    None => ()
  }
  Some(
    self.validate_expression(
      from_arg_list(Substring, args),
      nargs=args.length(),
    ),
  )
}

///|
pub fn Parser::parse_trim(self : Parser) -> Expr? raise SqlglotError {
  let mut position : String? = None
  let mut collation : Expr? = None
  let mut expression : Expr? = None
  if self.match_text_set(self.cfg.trim_types) {
    position = Some(self.prev_upper())
  }
  let mut this = self.parse_bitwise()
  if self.match_any([FROM, COMMA]) {
    let invert_order = self.prev.token_type == FROM ||
      self.cfg.trim_pattern_first
    expression = self.parse_bitwise()
    if invert_order {
      let tmp = this
      this = expression
      expression = tmp
    }
  }
  if self.match_(COLLATE) {
    collation = self.parse_bitwise()
  }
  Some(
    self.expression(
      mk(Trim, [
        ("this", this),
        ("position", position),
        ("expression", expression),
        ("collation", collation),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_window_clause(
  self : Parser,
) -> Array[Expr]? raise SqlglotError {
  if self.match_(WINDOW) {
    Some(self.parse_csv(() => self.parse_named_window()))
  } else {
    None
  }
}

///|
pub fn Parser::parse_named_window(self : Parser) -> Expr? raise SqlglotError {
  self.parse_window(self.parse_id_var(), alias_=true)
}

///|
pub fn Parser::parse_respect_or_ignore_nulls(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if self.curr.token_type == VAR {
    if self.match_text_seq(["IGNORE", "NULLS"]) {
      return Some(self.expression(mk1(IgnoreNulls, this)))
    }
    if self.match_text_seq(["RESPECT", "NULLS"]) {
      return Some(self.expression(mk1(RespectNulls, this)))
    }
  }
  this
}

///|
pub fn Parser::parse_having_max(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if self.match_(HAVING) {
    self.match_texts(["MAX", "MIN"]) |> ignore
    let max = self.prev_upper() != "MIN"
    return Some(
      self.expression(
        mk(HavingMax, [
          ("this", this),
          ("expression", self.parse_column()),
          ("max", max),
        ]),
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_window(
  self : Parser,
  this : Expr?,
  alias_? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_window {
    Some(f) => f(self, this, alias_)
    None => self.parse_window_base(this, alias_~)
  }
}

///|
pub fn Parser::parse_window_base(
  self : Parser,
  this : Expr?,
  alias_? : Bool = false,
) -> Expr? raise SqlglotError {
  let func = this
  let comments = match func {
    Some(f) => f.comments
    None => None
  }
  let mut this = this
  match this {
    Some(t) if self.cfg.supports_nth_value_from_modifier && t.kind == NthValue =>
      if self.match_text_seq(["FROM", "FIRST"]) {
        t.set("from_first", true)
      } else if self.match_text_seq(["FROM", "LAST"]) {
        t.set("from_first", false)
      }
    _ => ()
  }
  if self.match_text_seq(["WITHIN", "GROUP"]) {
    let order = self.parse_wrapped(() => self.parse_order())
    this = Some(
      self.expression(mk(WithinGroup, [("this", this), ("expression", order)])),
    )
  }
  if self.match_pair(FILTER, L_PAREN) {
    self.match_(WHERE) |> ignore
    this = Some(
      self.expression(
        mk(Filter, [
          ("this", this),
          ("expression", self.parse_where(skip_where_token=true)),
        ]),
      ),
    )
    self.match_r_paren()
  }
  match this {
    Some(t) if t.kind.is_a(AggFunc) =>
      match find_in_scope(t, [IgnoreNulls, RespectNulls]) {
        Some(ignore_respect) if !physical_equal(ignore_respect, t) => {
          ignore_respect.replace(ignore_respect.this()) |> ignore
          this = Some(self.expression(mk1(ignore_respect.kind, this)))
        }
        _ => ()
      }
    _ => ()
  }
  this = self.parse_respect_or_ignore_nulls(this)
  let mut over : String? = None
  if alias_ {
    over = None
    self.match_(ALIAS) |> ignore
  } else if !self.match_set(self.cfg.window_before_paren_tokens) {
    return this
  } else {
    over = Some(self.prev_upper())
  }
  match (comments, func) {
    (Some(c), Some(f)) if !c.is_empty() => f.pop_comments() |> ignore
    _ => ()
  }
  let comments = comments.unwrap_or([])
  if !self.match_(L_PAREN) {
    return Some(
      self.expression(
        mk(Window, [
          ("this", this),
          ("alias", self.parse_id_var(any_token=false)),
          ("over", over),
        ]),
        comments~,
      ),
    )
  }
  let window_alias = self.parse_id_var(
    any_token=false,
    tokens=self.cfg.window_alias_tokens,
  )
  let mut first : Bool? = if self.match_(FIRST) { Some(true) } else { None }
  if self.match_text("LAST") {
    first = Some(false)
  }
  let (partition, order) = self.parse_partition_and_order()
  let kind = if self.match_any([ROWS, RANGE]) || self.match_text("GROUPS") {
    Some(self.prev.text)
  } else {
    None
  }
  let spec = match kind {
    Some(k) => {
      self.match_(BETWEEN) |> ignore
      let start = self.parse_window_spec()
      let end = if self.match_(AND) {
        self.parse_window_spec()
      } else {
        (None, None)
      }
      let exclude = if self.match_text("EXCLUDE") {
        self.parse_var_from_options(self.cfg.window_exclude_options)
      } else {
        None
      }
      Some(
        self.expression(
          mk(WindowSpec, [
            ("kind", k),
            ("start", start.0),
            ("start_side", start.1),
            ("end", end.0),
            ("end_side", end.1),
            ("exclude", exclude),
          ]),
        ),
      )
    }
    None => None
  }
  self.match_r_paren()
  let window = self.expression(
    mk(Window, [
      ("this", this),
      ("partition_by", partition),
      ("order", order),
      ("spec", spec),
      ("alias", window_alias),
      ("over", over),
      ("first", first),
    ]),
    comments~,
  )
  if self.match_set(self.cfg.window_before_paren_tokens, advance=false) {
    return self.parse_window(Some(window), alias_~)
  }
  Some(window)
}

///|
pub fn Parser::parse_partition_and_order(
  self : Parser,
) -> (Array[Expr], Expr?) raise SqlglotError {
  match self.fns.hooks.parse_partition_and_order {
    Some(f) => f(self)
    None => {
      let p = self.parse_partition_by()
      let o = self.parse_order()
      (p, o)
    }
  }
}

///|
/// Returns (value, side).
pub fn Parser::parse_window_spec(
  self : Parser,
) -> (Value?, String?) raise SqlglotError {
  self.match_(BETWEEN) |> ignore
  let value : Value? = if self.match_text("UNBOUNDED") {
    Some(Str("UNBOUNDED"))
  } else if self.match_text_seq(["CURRENT", "ROW"]) {
    Some(Str("CURRENT ROW"))
  } else {
    self.parse_bitwise().map(x => Node(x))
  }
  let side = if self.match_text_set(self.cfg.window_sides) {
    Some(self.prev.text)
  } else {
    None
  }
  (value, side)
}

// ---------------------------------------------------------------------------
// Scope walking helpers (sqlglot.optimizer.scope)

///|
fn is_derived_table(e : Expr) -> Bool {
  e.kind.is_a(Subquery) &&
  (
    !e.alias_().is_empty() ||
    (match e.this() {
      Some(t) => t.kind.is_any([Select, SetOperation])
      None => false
    })
  )
}

///|
/// Visits all nodes in the syntax tree, stopping at nodes that start child scopes.
pub fn walk_in_scope(expression : Expr, prune? : (Expr) -> Bool) -> Array[Expr] {
  let out = []
  fn go(expression : Expr) -> Unit {
    let stack = [expression]
    while stack.pop() is Some(node) {
      out.push(node)
      if !physical_equal(node, expression) &&
        node.kind.is_any([CTE, Query]) &&
        (
          node.kind.is_a(CTE) ||
          (match node.parent {
            Some(p) => p.kind.is_any([From, Join]) && is_derived_table(node)
            None => false
          }) ||
          (match node.parent {
            Some(p) => p.kind.is_a(UDTF)
            None => false
          }) ||
          node.kind.is_any([Select, SetOperation])
        ) {
        if node.kind.is_any([Subquery, UDTF]) {
          for key in ["joins", "laterals", "pivots"] {
            for arg in node.list(key) {
              go(arg)
            }
          }
        }
        continue
      }
      match prune {
        Some(p) => if p(node) { continue }
        None => ()
      }
      for v in node.iter_expressions(reverse=true) {
        stack.push(v)
      }
    }
  }

  go(expression)
  out
}

///|
pub fn find_all_in_scope(
  expression : Expr,
  kinds : ArrayView[Kind],
) -> Array[Expr] {
  walk_in_scope(expression).filter(n => n.kind.is_any(kinds))
}

///|
pub fn find_in_scope(expression : Expr, kinds : ArrayView[Kind]) -> Expr? {
  for n in walk_in_scope(expression) {
    if n.kind.is_any(kinds) {
      return Some(n)
    }
  }
  None
}
