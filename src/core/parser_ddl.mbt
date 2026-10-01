// Port of sqlglot/parser.py: statements, DROP/CREATE and properties.

///|
fn Parser::prev_upper(self : Parser) -> String {
  py_upper(self.prev.text)
}

///|
/// `self._match_set(types) and self._prev.text.upper()`
fn Parser::match_set_text(self : Parser, types : TokenSet) -> String? {
  if self.match_set(types) {
    Some(self.prev_upper())
  } else {
    None
  }
}

///|
/// `self._match_texts(texts) and self._prev.text.upper()`
fn Parser::match_texts_upper(self : Parser, texts : ArrayView[String]) -> String? {
  if self.match_texts(texts) {
    Some(self.prev_upper())
  } else {
    None
  }
}

///|
pub fn Parser::parse_comment(
  self : Parser,
  allow_exists? : Bool = true,
) -> Expr? raise SqlglotError {
  let start = self.prev
  let exists = if allow_exists { self.parse_exists() } else { None }
  self.match_(ON) |> ignore
  let materialized = self.match_text("MATERIALIZED")
  let kind = if self.match_set(self.cfg.creatables) {
    Some(self.prev)
  } else {
    None
  }
  let kind = match kind {
    Some(k) => k
    None => return Some(self.parse_as_command(start))
  }
  let this = if kind.token_type == FUNCTION || kind.token_type == PROCEDURE {
    self.parse_user_defined_function(kind=kind.token_type)
  } else if kind.token_type == TABLE {
    self.parse_table(alias_tokens=self.cfg.comment_table_alias_tokens)
  } else if kind.token_type == COLUMN {
    self.parse_column()
  } else {
    self.parse_table_parts(schema=true)
  }
  self.match_(IS) |> ignore
  Some(
    self.expression(
      mk(Comment, [
        ("this", this),
        ("kind", kind.text),
        ("expression", self.parse_string()),
        ("exists", exists),
        ("materialized", materialized),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_to_table(self : Parser) -> Expr? raise SqlglotError {
  let table = self.parse_table_parts(schema=true)
  Some(self.expression(mk1(ToTableProperty, table)))
}

///|
pub fn Parser::parse_ttl(self : Parser) -> Expr? raise SqlglotError {
  fn parse_ttl_action() -> Expr? raise SqlglotError {
    let this = self.parse_bitwise()
    if self.match_text("DELETE") {
      return Some(
        self.expression(mk(MergeTreeTTLAction, [("this", this), ("delete", true)])),
      )
    }
    if self.match_text("RECOMPRESS") {
      return Some(
        self.expression(
          mk(MergeTreeTTLAction, [
            ("this", this),
            ("recompress", self.parse_bitwise()),
          ]),
        ),
      )
    }
    if self.match_text_seq(["TO", "DISK"]) {
      return Some(
        self.expression(
          mk(MergeTreeTTLAction, [("this", this), ("to_disk", self.parse_string())]),
        ),
      )
    }
    if self.match_text_seq(["TO", "VOLUME"]) {
      return Some(
        self.expression(
          mk(MergeTreeTTLAction, [
            ("this", this),
            ("to_volume", self.parse_string()),
          ]),
        ),
      )
    }
    this
  }

  let expressions = self.parse_csv(parse_ttl_action)
  let where_ = self.parse_where()
  let group = self.parse_group()
  let mut aggregates : Array[Expr]? = None
  if group is Some(_) && self.match_(SET) {
    aggregates = Some(self.parse_csv(() => self.parse_set_item()))
  }
  Some(
    self.expression(
      mk(MergeTreeTTL, [
        ("expressions", expressions),
        ("where", where_),
        ("group", group),
        ("aggregates", aggregates),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_condition(self : Parser) -> Expr? raise SqlglotError {
  self.parse_wrapped(() => self.parse_expression(), optional=true)
}

///|
pub fn Parser::parse_block(self : Parser) -> Expr raise SqlglotError {
  let stmts = self.parse_batch_statements(p => p.parse_statement())
  self.expression(mk(Block, [("expressions", stmts.filter_map(x => x))]))
}

///|
pub fn Parser::parse_whileblock(self : Parser) -> Expr raise SqlglotError {
  let cond = self.parse_condition()
  let body = self.parse_block()
  self.expression(mk(WhileBlock, [("this", cond), ("body", body)]))
}

///|
pub fn Parser::parse_statement(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_statement {
    Some(f) => f(self)
    None => self.parse_statement_base()
  }
}

///|
pub fn Parser::parse_statement_base(self : Parser) -> Expr? raise SqlglotError {
  if !self.curr.ok() {
    return None
  }
  if self.match_keys(self.fns.statement_parsers) {
    let comments = self.prev_comments
    let parser = self.fns.statement_parsers[self.prev.token_type]
    let stmt = parser(self)
    match stmt {
      Some(s) => s.add_comments(Some(comments), prepend=true)
      None => ()
    }
    return stmt
  }
  if self.dialect.tokenizer.commands_set.contains(self.curr.token_type) {
    self.advance()
    return Some(self.parse_command())
  }
  if self.match_text("WHILE") {
    return Some(self.parse_whileblock())
  }
  let mut expression = self.parse_expression()
  expression = match expression {
    Some(e) => self.parse_set_operations(Some(e))
    None => self.parse_select()
  }
  match expression {
    Some(e) =>
      if e.kind.is_a(Subquery) && self.match_(PIPE_GT, advance=false) {
        expression = self.parse_pipe_syntax_query(e)
      }
    None => ()
  }
  self.parse_query_modifiers(expression)
}

///|
pub fn Parser::parse_drop(
  self : Parser,
  exists? : Bool = false,
) -> Expr? raise SqlglotError {
  let start = self.prev
  let temporary = self.match_(TEMPORARY)
  let materialized = self.match_text("MATERIALIZED")
  let iceberg = self.match_text("ICEBERG")
  let kind = self.match_set_text(self.cfg.creatables)
  let kind = match kind {
    None => return Some(self.parse_as_command(start))
    Some(k) =>
      if iceberg && k != "TABLE" {
        return Some(self.parse_as_command(start))
      } else {
        k
      }
  }
  let concurrently = self.match_text("CONCURRENTLY")
  let if_exists : Bool? = if exists { Some(true) } else { self.parse_exists() }
  let tables : Array[Expr] = if kind == "COLUMN" {
    match self.parse_column() {
      Some(c) => [c]
      None => []
    }
  } else if kind == "TABLE" || kind == "VIEW" {
    self.parse_csv(() => self.parse_table_parts(schema=true))
  } else {
    match self.parse_table_parts(schema=true, is_db_reference=kind == "SCHEMA") {
      Some(t) => [t]
      None => []
    }
  }
  let cluster = if self.match_(ON) { self.parse_on_property() } else { None }
  let expressions = if self.match_(L_PAREN, advance=false) {
    Some(self.parse_wrapped_csv(() => self.parse_types()))
  } else {
    None
  }
  let cascade_or_restrict = self.match_texts_upper(["CASCADE", "RESTRICT"])
  let kind_ = match self.dialect.cfg.creatable_kind_mapping.get(kind) {
    Some(k) if !k.is_empty() => k
    _ => kind
  }
  let constraints = self.match_text("CONSTRAINTS")
  let purge = self.match_text("PURGE")
  let sync = self.match_text("SYNC")
  let force = self.match_text("FORCE")
  Some(
    self.expression(
      mk(Drop, [
        ("exists", if_exists),
        ("tables", tables),
        ("expressions", expressions),
        ("kind", kind_),
        ("temporary", temporary),
        ("materialized", materialized),
        ("cascade", cascade_or_restrict == Some("CASCADE")),
        ("restrict", cascade_or_restrict == Some("RESTRICT")),
        ("constraints", constraints),
        ("purge", purge),
        ("cluster", cluster),
        ("concurrently", concurrently),
        ("sync", sync),
        ("iceberg", iceberg),
        ("force", force),
      ]),
    ),
  )
}

///|
/// `IF [NOT] EXISTS`. Returns None when `IF` isn't matched (Python `None`).
pub fn Parser::parse_exists(
  self : Parser,
  not_? : Bool = false,
) -> Bool? raise SqlglotError {
  if !self.match_text("IF") {
    return Some(false)
  }
  if not_ && !self.match_(NOT) {
    return Some(false)
  }
  Some(self.match_(EXISTS))
}

///|
pub fn Parser::parse_create(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_create {
    Some(f) => f(self)
    None => self.parse_create_base()
  }
}

///|
pub fn Parser::parse_create_base(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  let replace = start.token_type == REPLACE ||
    self.match_pair(OR, REPLACE) ||
    self.match_pair(OR, ALTER)
  let refresh = self.match_pair(OR, REFRESH)
  let unique = self.match_(UNIQUE)
  let clustered : Bool? = if self.match_text_seq(["CLUSTERED", "COLUMNSTORE"]) {
    Some(true)
  } else if self.match_text_seq(["NONCLUSTERED", "COLUMNSTORE"]) ||
    self.match_text("COLUMNSTORE") {
    Some(false)
  } else {
    None
  }
  if self.match_pair(TABLE, FUNCTION, advance=false) {
    self.advance()
  }
  let mut properties : Expr? = None
  let mut create_token = if self.match_set(self.cfg.creatables) {
    Some(self.prev)
  } else {
    None
  }
  if create_token is None {
    properties = self.parse_properties()
    create_token = if self.match_set(self.cfg.creatables) {
      Some(self.prev)
    } else {
      None
    }
    if properties is None || create_token is None {
      return Some(self.parse_as_command(start))
    }
  }
  let mut create_token = create_token.unwrap()
  let create_token_type = create_token.token_type
  let concurrently = self.match_text("CONCURRENTLY")
  let exists = self.parse_exists(not_=true)
  let mut this : Expr? = None
  let mut expression : Expr? = None
  let mut indexes : Array[Expr]? = None
  let mut no_schema_binding : Bool? = None
  let mut begin : Bool? = None
  let mut clone : Expr? = None
  fn extend_props(temp_props : Expr?) -> Unit {
    match (properties, temp_props) {
      (Some(p), Some(t)) =>
        for e in t.expressions() {
          p.append("expressions", e)
        }
      (None, Some(t)) => properties = Some(t)
      _ => ()
    }
  }

  if create_token_type == FUNCTION || create_token_type == PROCEDURE {
    this = self.parse_user_defined_function(kind=create_token_type)
    extend_props(self.parse_properties())
    expression = if self.match_(ALIAS) { self.parse_heredoc() } else { None }
    let mut is_table = false
    let mut overload_mode = false
    if expression is None &&
      create_token_type == FUNCTION &&
      (match this {
        Some(t) => t.kind == UserDefinedFunction && t.has("wrapped")
        None => false
      }) {
      let pre_table_index = self.index
      is_table = self.match_(TABLE)
      expression = self.parse_expression()
      overload_mode = expression is Some(_) &&
        self.curr.token_type == COMMA &&
        self.next.token_type == L_PAREN
      if !overload_mode {
        self.retreat(pre_table_index)
        is_table = false
        expression = None
      }
    }
    extend_props(self.parse_function_properties())
    if expression is None {
      if self.match_(COMMAND) {
        expression = Some(self.parse_as_command(self.prev))
      } else {
        begin = Some(self.match_(BEGIN))
        let return_ = self.match_text("RETURN")
        if self.match_(STRING, advance=false) {
          expression = self.parse_string()
          extend_props(self.parse_properties())
        } else {
          expression = if create_token_type == FUNCTION {
            self.parse_user_defined_function_expression()
          } else {
            Some(self.parse_block())
          }
        }
        if return_ {
          expression = Some(self.expression(mk1(Return, expression)))
        }
      }
    }
    if overload_mode && expression is Some(_) {
      expression = self.parse_macro_overloads(this.unwrap(), expression.unwrap(), is_table)
    }
  } else if create_token_type == INDEX {
    let (index, anonymous) = if !self.match_(ON) {
      (self.parse_id_var(), false)
    } else {
      (None, true)
    }
    this = self.parse_index(index~, anonymous~)
  } else if (create_token_type == CONSTRAINT && self.match_(TRIGGER)) ||
    create_token_type == TRIGGER {
    let is_constraint = create_token_type == CONSTRAINT
    if is_constraint {
      create_token = self.prev
    }
    let trigger_name = match self.parse_id_var() {
      Some(t) => t
      None => return Some(self.parse_as_command(start))
    }
    let timing_var = self.parse_var_from_options(
      self.cfg.trigger_timing,
      raise_unmatched=false,
    )
    let timing = match timing_var {
      Some(v) => v.text("this")
      None => ""
    }
    if timing.is_empty() {
      return Some(self.parse_as_command(start))
    }
    let events = self.parse_trigger_events()
    if !self.match_(ON) {
      self.raise_error("Expected ON in trigger definition")
    }
    let table = self.parse_table_parts()
    let referenced_table = if self.match_(FROM) {
      self.parse_table_parts()
    } else {
      None
    }
    let (deferrable, initially) = self.parse_trigger_deferrable()
    let referencing = self.parse_trigger_referencing()
    let for_each = self.parse_trigger_for_each()
    let when = if self.match_text("WHEN") {
      self.parse_wrapped(() => self.parse_disjunction(), optional=true)
    } else {
      None
    }
    let execute = self.parse_trigger_execute()
    if execute is None {
      return Some(self.parse_as_command(start))
    }
    let trigger_props = self.expression(
      mk(TriggerProperties, [
        ("table", table),
        ("timing", timing),
        ("events", events),
        ("execute", execute),
        ("constraint", is_constraint),
        ("referenced_table", referenced_table),
        ("deferrable", deferrable),
        ("initially", initially),
        ("referencing", referencing),
        ("for_each", for_each),
        ("when", when),
      ]),
    )
    this = Some(trigger_name)
    extend_props(Some(mk(Properties, [("expressions", [trigger_props])])))
  } else if create_token_type == TYPE {
    this = self.parse_table_parts(schema=true)
    if this is None || !self.match_(ALIAS) {
      return Some(self.parse_as_command(start))
    }
    if self.match_(ENUM) {
      expression = Some(
        mk(DataType, [
          ("this", DType::ENUM),
          ("expressions", self.parse_wrapped_csv(() => self.parse_string())),
        ]),
      )
    } else if self.match_(L_PAREN, advance=false) {
      expression = self.parse_schema()
    } else {
      return Some(self.parse_as_command(start))
    }
  } else if self.cfg.db_creatables.contains(create_token_type) {
    let table_parts = self.parse_table_parts(
      schema=true,
      is_db_reference=create_token_type == SCHEMA,
    )
    self.match_(COMMA) |> ignore
    extend_props(self.parse_properties(before=true))
    this = self.parse_schema(this=table_parts)
    extend_props(self.parse_properties())
    let has_alias = self.match_(ALIAS)
    if !self.match_set(self.cfg.ddl_select_tokens, advance=false) {
      extend_props(self.parse_properties())
    }
    if create_token_type == SEQUENCE {
      expression = self.parse_types()
      let props = self.parse_properties()
      match props {
        Some(props) => {
          let sequence_props = mk0(SequenceProperties)
          let options : Array[Expr] = []
          for prop in props.expressions() {
            if prop.kind == SequenceProperties {
              for arg, value in prop.args {
                if arg == "options" {
                  match value {
                    List(l) =>
                      for v in l {
                        match v {
                          Node(n) => options.push(n)
                          _ => ()
                        }
                      }
                    _ => ()
                  }
                } else {
                  sequence_props.set(arg, value)
                }
              }
              prop.pop() |> ignore
            }
          }
          if !options.is_empty() {
            sequence_props.set("options", options)
          }
          props.append("expressions", sequence_props)
          extend_props(Some(props))
        }
        None => ()
      }
    } else {
      expression = self.parse_ddl_select()
      if expression is None && has_alias {
        expression = self.try_parse(() => self.parse_table_parts())
      }
    }
    if create_token_type == TABLE {
      extend_props(self.parse_properties())
      let idx : Array[Expr] = []
      while true {
        let index = self.parse_index()
        extend_props(self.parse_properties())
        match index {
          None => break
          Some(i) => {
            self.match_(COMMA) |> ignore
            idx.push(i)
          }
        }
      }
      indexes = Some(idx)
    } else if create_token_type == VIEW {
      if self.match_text_seq(["WITH", "NO", "SCHEMA", "BINDING"]) {
        no_schema_binding = Some(true)
      }
    } else if create_token_type == SINK || create_token_type == SOURCE {
      extend_props(self.parse_properties())
    }
    let shallow = self.match_text("SHALLOW")
    if self.match_text_set(self.cfg.clone_keywords) {
      let copy = py_lower(self.prev.text) == "copy"
      clone = Some(
        self.expression(
          mk(Clone, [
            ("this", self.parse_table(schema=true)),
            ("shallow", shallow),
            ("copy", copy),
          ]),
        ),
      )
    }
  }
  if self.curr.ok() && !self.match_any([R_PAREN, COMMA], advance=false) {
    return Some(self.parse_as_command(start))
  }
  let create_kind_text = py_upper(create_token.text)
  let kind = match self.dialect.cfg.creatable_kind_mapping.get(create_kind_text) {
    Some(k) if !k.is_empty() => k
    _ => create_kind_text
  }
  Some(
    self.expression(
      mk(Create, [
        ("this", this),
        ("kind", kind),
        ("replace", replace),
        ("refresh", refresh),
        ("unique", unique),
        ("expression", expression),
        ("exists", exists),
        ("properties", properties),
        ("indexes", indexes),
        ("no_schema_binding", no_schema_binding),
        ("begin", begin),
        ("clone", clone),
        ("concurrently", concurrently),
        ("clustered", clustered),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_sequence_properties(self : Parser) -> Expr? raise SqlglotError {
  let seq = mk0(SequenceProperties)
  let options : Array[Expr] = []
  let index = self.index
  while self.curr.ok() {
    self.match_(COMMA) |> ignore
    if self.match_text("INCREMENT") {
      self.match_text("BY") |> ignore
      self.match_text("=") |> ignore
      seq.set("increment", self.parse_term())
    } else if self.match_text("MINVALUE") {
      seq.set("minvalue", self.parse_term())
    } else if self.match_text("MAXVALUE") {
      seq.set("maxvalue", self.parse_term())
    } else if self.match_text("START") {
      self.match_text("WITH") |> ignore
      self.match_text("=") |> ignore
      seq.set("start", self.parse_term())
    } else if self.match_text("CACHE") {
      match self.parse_number() {
        Some(n) => seq.set("cache", n)
        None => seq.set("cache", true)
      }
    } else if self.match_text_seq(["OWNED", "BY"]) {
      if self.match_text("NONE") {
        seq.set("owned", null_arg)
      } else {
        seq.set("owned", self.parse_column())
      }
    } else {
      match self.parse_var_from_options(self.cfg.create_sequence, raise_unmatched=false) {
        Some(opt) => options.push(opt)
        None => break
      }
    }
  }
  seq.set("options", if options.is_empty() { None } else { Some(options) })
  if self.index == index {
    None
  } else {
    Some(seq)
  }
}

///|
pub fn Parser::parse_trigger_events(self : Parser) -> Array[Expr] raise SqlglotError {
  let events = []
  while true {
    let event_type = self.match_set_text(self.cfg.trigger_events)
    if event_type is None {
      self.raise_error("Expected trigger event (INSERT, UPDATE, DELETE, TRUNCATE)")
    }
    let columns = if event_type == Some("UPDATE") && self.match_text("OF") {
      Some(self.parse_csv(() => self.parse_column()))
    } else {
      None
    }
    let et : Value? = match event_type {
      Some(e) => Some(Str(e))
      None => Some(Bool(false))
    }
    events.push(
      self.expression(mk(TriggerEvent, [("this", et), ("columns", columns)])),
    )
    if !self.match_(OR) {
      break
    }
  }
  events
}

///|
pub fn Parser::parse_trigger_deferrable(
  self : Parser,
) -> (String?, String?) raise SqlglotError {
  let deferrable_var = self.parse_var_from_options(
    self.cfg.trigger_deferrable,
    raise_unmatched=false,
  )
  let deferrable = match deferrable_var {
    Some(v) => Some(v.text("this"))
    None => None
  }
  let mut initially = None
  if deferrable is Some(d) && !d.is_empty() && self.match_text("INITIALLY") {
    initially = if self.match_texts(["IMMEDIATE", "DEFERRED"]) {
      Some(self.prev_upper())
    } else {
      None
    }
  }
  (deferrable, initially)
}

///|
pub fn Parser::parse_trigger_referencing_clause(
  self : Parser,
  keyword : String,
) -> Expr? raise SqlglotError {
  if !self.match_text(keyword) {
    return None
  }
  if !self.match_text("TABLE") {
    self.raise_error("Expected TABLE after \{keyword} in REFERENCING clause")
  }
  self.match_text("AS") |> ignore
  self.parse_id_var()
}

///|
pub fn Parser::parse_trigger_referencing(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text("REFERENCING") {
    return None
  }
  let mut old_alias : Expr? = None
  let mut new_alias : Expr? = None
  while true {
    match self.parse_trigger_referencing_clause("OLD") {
      Some(alias) => {
        if old_alias is Some(_) {
          self.raise_error("Duplicate OLD clause in REFERENCING")
        }
        old_alias = Some(alias)
      }
      None =>
        match self.parse_trigger_referencing_clause("NEW") {
          Some(alias) => {
            if new_alias is Some(_) {
              self.raise_error("Duplicate NEW clause in REFERENCING")
            }
            new_alias = Some(alias)
          }
          None => break
        }
    }
  }
  if old_alias is None && new_alias is None {
    self.raise_error("REFERENCING clause requires at least OLD TABLE or NEW TABLE")
  }
  Some(
    self.expression(
      mk(TriggerReferencing, [("old", old_alias), ("new", new_alias)]),
    ),
  )
}

///|
pub fn Parser::parse_trigger_for_each(self : Parser) -> String? raise SqlglotError {
  if !self.match_text_seq(["FOR", "EACH"]) {
    return None
  }
  if self.match_texts(["ROW", "STATEMENT"]) {
    Some(self.prev_upper())
  } else {
    None
  }
}

///|
pub fn Parser::parse_trigger_execute(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(EXECUTE) {
    return None
  }
  if !self.match_any([FUNCTION, PROCEDURE]) {
    self.raise_error("Expected FUNCTION or PROCEDURE after EXECUTE")
  }
  let func_call = self.parse_column()
  Some(self.expression(mk1(TriggerExecute, func_call)))
}

///|
pub fn Parser::parse_property_before(self : Parser) -> Value? raise SqlglotError {
  match self.fns.hooks.parse_property_before {
    Some(f) => f(self)
    None => self.parse_property_before_base()
  }
}

///|
pub fn Parser::parse_property_before_base(self : Parser) -> Value? raise SqlglotError {
  self.match_(COMMA) |> ignore
  let kwargs : PropKwargs = Map([])
  let no = self.match_text("NO")
  let dual = self.match_text("DUAL")
  let before = self.match_text("BEFORE")
  let default = self.match_text("DEFAULT")
  let local = if self.match_text("LOCAL") {
    Some("LOCAL")
  } else if self.match_text_seq(["NOT", "LOCAL"]) {
    Some("NOT LOCAL")
  } else {
    None
  }
  let after = self.match_text("AFTER")
  let minimum = self.match_texts(["MIN", "MINIMUM"])
  let maximum = self.match_texts(["MAX", "MAXIMUM"])
  if no {
    kwargs["no"] = true
  }
  if dual {
    kwargs["dual"] = true
  }
  if before {
    kwargs["before"] = true
  }
  if default {
    kwargs["default"] = true
  }
  match local {
    Some("LOCAL") => kwargs["local"] = true
    Some(_) => kwargs["not_local"] = true
    None => ()
  }
  if after {
    kwargs["after"] = true
  }
  if minimum {
    kwargs["minimum"] = true
  }
  if maximum {
    kwargs["maximum"] = true
  }
  if self.match_text_keys(self.fns.property_parsers) {
    let parser = self.fns.property_parsers[self.prev_upper()]
    return parser(self, kwargs)
  }
  if self.match_text_seq(["CHARACTER", "SET"]) {
    return Some(Node(self.parse_character_set(default~)))
  }
  None
}

///|
pub fn Parser::parse_wrapped_properties(self : Parser) -> Array[Expr] raise SqlglotError {
  self.parse_wrapped(fn() raise SqlglotError {
    let out = []
    fn push(v : Value?) -> Unit {
      match v {
        Some(Node(e)) => out.push(e)
        Some(List(l)) =>
          for x in l {
            match x {
              Node(e) => out.push(e)
              _ => ()
            }
          }
        _ => ()
      }
    }

    push(self.parse_property())
    while self.match_(COMMA) {
      if !out.is_empty() {
        self.add_comments(Some(out[out.length() - 1]))
      }
      push(self.parse_property())
    }
    out
  })
}

///|
fn prop_value_is_some(v : Value?) -> Bool {
  match v {
    Some(Node(_)) => true
    Some(List(l)) => !l.is_empty()
    _ => false
  }
}

///|
pub fn Parser::parse_property(self : Parser) -> Value? raise SqlglotError {
  if self.match_text_keys(self.fns.property_parsers) {
    let parser = self.fns.property_parsers[self.prev_upper()]
    return parser(self, Map([]))
  }
  if self.match_text_seq(["CHARACTER", "SET"]) {
    return Some(Node(self.parse_character_set()))
  }
  if self.match_(DEFAULT) {
    if self.match_text_keys(self.fns.property_parsers) {
      let parser = self.fns.property_parsers[self.prev_upper()]
      return parser(self, { "default": true })
    }
    if self.match_text_seq(["CHARACTER", "SET"]) {
      return Some(Node(self.parse_character_set(default=true)))
    }
  }
  if self.match_text_seq(["COMPOUND", "SORTKEY"]) {
    return Some(Node(self.parse_sortkey(compound=true)))
  }
  if self.match_text_seq(["PARAMETER", "STYLE", "PANDAS"]) {
    return Some(Node(self.expression(mk1(ParameterStyleProperty, "PANDAS"))))
  }
  if self.match_text_seq(["NOT", "DETERMINISTIC"]) {
    return Some(
      Node(self.expression(mk1(StabilityProperty, literal_string("VOLATILE")))),
    )
  }
  let index = self.index
  match self.parse_sequence_properties() {
    Some(seq_props) => return Some(Node(seq_props))
    None => ()
  }
  self.retreat(index)
  match self.parse_key_value_property() {
    Some(e) => Some(Node(e))
    None => None
  }
}

///|
pub fn Parser::parse_key_value_property(
  self : Parser,
  parse_value? : () -> Expr? raise SqlglotError,
) -> Expr? raise SqlglotError {
  let index = self.index
  let mut key = self.parse_column()
  if !self.match_(EQ) {
    self.retreat(index)
    return None
  }
  match key {
    Some(k) if k.kind.is_a(Column) =>
      key = if k.parts().length() > 1 {
        Some(k.to_dot())
      } else {
        Some(var_(k.name()))
      }
    _ => ()
  }
  let mut value = match parse_value {
    Some(pv) => pv()
    None =>
      match self.parse_bitwise() {
        Some(v) => Some(v)
        None => self.parse_var(any_token=true)
      }
  }
  match value {
    Some(v) if v.kind.is_a(Column) => value = Some(var_(v.name()))
    _ => ()
  }
  Some(self.expression(mk(Property, [("this", key), ("value", value)])))
}

///|
pub fn Parser::parse_stored(self : Parser) -> Expr raise SqlglotError {
  if self.match_text("BY") {
    return self.expression(
      mk1(StorageHandlerProperty, self.parse_var_or_string()),
    )
  }
  self.match_(ALIAS) |> ignore
  let input_format = if self.match_text("INPUTFORMAT") {
    self.parse_string()
  } else {
    None
  }
  let output_format = if self.match_text("OUTPUTFORMAT") {
    self.parse_string()
  } else {
    None
  }
  let this = if input_format is Some(_) || output_format is Some(_) {
    Some(
      self.expression(
        mk(InputOutputFormat, [
          ("input_format", input_format),
          ("output_format", output_format),
        ]),
      ),
    )
  } else {
    match self.parse_var_or_string() {
      Some(v) => Some(v)
      None =>
        match self.parse_number() {
          Some(n) => Some(n)
          None => self.parse_id_var()
        }
    }
  }
  self.expression(mk(FileFormatProperty, [("this", this), ("hive_format", true)]))
}

///|
pub fn Parser::parse_unquoted_field(self : Parser) -> Expr? raise SqlglotError {
  let field = self.parse_field()
  match field {
    Some(f) if f.kind == Identifier && !f.has("quoted") => Some(var_of_expr(f))
    _ => field
  }
}

///|
/// `exp.var(expr)`: builds a Var from an expression's name.
pub fn var_of_expr(e : Expr) -> Expr {
  var_(e.name())
}

///|
pub fn Parser::parse_property_assignment(
  self : Parser,
  kind : Kind,
  kwargs? : ArrayView[(String, &IntoValue)] = [],
) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  self.match_(ALIAS) |> ignore
  let e = mk1(kind, self.parse_unquoted_field())
  for kv in kwargs {
    e.set(kv.0, kv.1)
  }
  self.expression(e)
}

///|
pub fn Parser::parse_properties(
  self : Parser,
  before? : Bool = false,
) -> Expr? raise SqlglotError {
  let properties = []
  while true {
    let prop = if before {
      self.parse_property_before()
    } else {
      self.parse_property()
    }
    if !prop_value_is_some(prop) {
      break
    }
    match prop {
      Some(Node(p)) => properties.push(p)
      Some(List(l)) =>
        for x in l {
          match x {
            Node(p) => properties.push(p)
            _ => ()
          }
        }
      _ => ()
    }
  }
  if !properties.is_empty() {
    Some(self.expression(mk(Properties, [("expressions", properties)])))
  } else {
    None
  }
}

///|
pub fn Parser::parse_fallback(self : Parser, no? : Bool = false) -> Expr raise SqlglotError {
  self.expression(
    mk(FallbackProperty, [("no", no), ("protection", self.match_text("PROTECTION"))]),
  )
}

///|
pub fn Parser::parse_sql_security(self : Parser) -> Expr raise SqlglotError {
  let this : Value = if self.match_text_set(self.cfg.security_property_keywords) {
    Str(self.prev_upper())
  } else {
    Bool(false)
  }
  self.expression(mk1(SqlSecurityProperty, this))
}

///|
pub fn Parser::parse_settings_property(self : Parser) -> Expr raise SqlglotError {
  self.expression(
    mk(SettingsProperty, [
      ("expressions", self.parse_csv(() => self.parse_assignment())),
    ]),
  )
}

///|
pub fn Parser::parse_called_on_null_input_property(
  self : Parser,
) -> Expr? raise SqlglotError {
  if !self.match_text_seq(["ON", "NULL", "INPUT"]) {
    self.retreat(self.index - 1)
    return None
  }
  Some(self.expression(mk0(CalledOnNullInputProperty)))
}

///|
pub fn Parser::parse_volatile_property(self : Parser) -> Expr raise SqlglotError {
  let pre_volatile_token = if self.index >= 2 {
    Some(self.tokens[self.index - 2])
  } else {
    None
  }
  match pre_volatile_token {
    Some(t) if t.ok() && self.cfg.pre_volatile_tokens.contains(t.token_type) =>
      return mk0(VolatileProperty)
    _ => ()
  }
  self.expression(mk1(StabilityProperty, literal_string("VOLATILE")))
}

///|
pub fn Parser::parse_retention_period(self : Parser) -> Expr raise SqlglotError {
  let number = self.parse_number()
  let number_str = match number {
    Some(n) => self.dialect_sql(n) + " "
    None => ""
  }
  let unit = self.parse_var(any_token=true)
  let unit_str = match unit {
    Some(u) => self.dialect_sql(u)
    None => "None"
  }
  var_("\{number_str}\{unit_str}")
}

///|
pub fn Parser::parse_system_versioning_property(
  self : Parser,
  with_? : Bool = false,
) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let prop = self.expression(
    mk(WithSystemVersioningProperty, [("on", true), ("with_", with_)]),
  )
  if self.match_text("OFF") {
    prop.set("on", false)
    return prop
  }
  self.match_(ON) |> ignore
  if self.match_(L_PAREN) {
    while self.curr.ok() && !self.match_(R_PAREN) {
      if self.match_text_seq(["HISTORY_TABLE", "="]) {
        prop.set("this", self.parse_table_parts())
      } else if self.match_text_seq(["DATA_CONSISTENCY_CHECK", "="]) {
        match self.advance_any() {
          Some(_) => prop.set("data_consistency", self.prev_upper())
          None => prop.set("data_consistency", null_arg)
        }
      } else if self.match_text_seq(["HISTORY_RETENTION_PERIOD", "="]) {
        prop.set("retention_period", self.parse_retention_period())
      }
      self.match_(COMMA) |> ignore
    }
  }
  prop
}

///|
pub fn Parser::parse_data_deletion_property(self : Parser) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let on = self.match_text("ON") || !self.match_text("OFF")
  let prop = self.expression(mk(DataDeletionProperty, [("on", on)]))
  if self.match_(L_PAREN) {
    while self.curr.ok() && !self.match_(R_PAREN) {
      if self.match_text_seq(["FILTER_COLUMN", "="]) {
        prop.set("filter_column", self.parse_column())
      } else if self.match_text_seq(["RETENTION_PERIOD", "="]) {
        prop.set("retention_period", self.parse_retention_period())
      }
      self.match_(COMMA) |> ignore
    }
  }
  prop
}

///|
pub fn Parser::parse_distributed_property(self : Parser) -> Expr raise SqlglotError {
  let mut kind = "HASH"
  let mut expressions : Array[Expr]? = None
  if self.match_text_seq(["BY", "HASH"]) {
    expressions = Some(self.parse_wrapped_csv(() => self.parse_id_var()))
  } else if self.match_text_seq(["BY", "RANDOM"]) {
    kind = "RANDOM"
  }
  let mut buckets : Expr? = None
  if self.match_text("BUCKETS") && !self.match_text("AUTO") {
    buckets = self.parse_number()
  }
  self.expression(
    mk(DistributedByProperty, [
      ("expressions", expressions),
      ("kind", kind),
      ("buckets", buckets),
      ("order", self.parse_order()),
    ]),
  )
}

///|
pub fn Parser::parse_composite_key_property(
  self : Parser,
  kind : Kind,
) -> Expr raise SqlglotError {
  self.match_text("KEY") |> ignore
  let expressions = self.parse_wrapped_id_vars()
  self.expression(mk(kind, [("expressions", expressions)]))
}

///|
pub fn Parser::parse_with_property(self : Parser) -> Value? raise SqlglotError {
  match self.fns.hooks.parse_with_property {
    Some(f) => f(self)
    None => self.parse_with_property_base()
  }
}

///|
pub fn Parser::parse_with_property_base(self : Parser) -> Value? raise SqlglotError {
  if self.match_text_seq(["(", "SYSTEM_VERSIONING"]) {
    let prop = self.parse_system_versioning_property(with_=true)
    self.match_r_paren()
    return Some(Node(prop))
  }
  if self.match_(L_PAREN, advance=false) {
    let result = self.parse_wrapped_properties()
    return Some(List(result.map(x => Node(x))))
  }
  if self.match_text("JOURNAL") {
    return Some(Node(self.parse_withjournaltable()))
  }
  if self.match_text_set(self.cfg.view_attributes) {
    return Some(
      Node(self.expression(mk1(ViewAttributeProperty, self.prev_upper()))),
    )
  }
  if self.match_text("DATA") {
    return Some(Node(self.parse_withdata(no=false)))
  } else if self.match_text_seq(["NO", "DATA"]) {
    return Some(Node(self.parse_withdata(no=true)))
  }
  if self.match_(SERDE_PROPERTIES, advance=false) {
    return self.parse_serde_properties(with_=true).map(x => Node(x))
  }
  if self.match_(SCHEMA) {
    return Some(
      Node(
        self.expression(
          mk1(
            WithSchemaBindingProperty,
            self.parse_var_from_options(self.cfg.schema_binding_options),
          ),
        ),
      ),
    )
  }
  if self.match_text_keys(self.cfg.procedure_options, advance=false) {
    return Some(
      Node(
        self.expression(
          mk(WithProcedureOptions, [
            ("expressions", self.parse_csv(() => self.parse_procedure_option())),
          ]),
        ),
      ),
    )
  }
  if !self.next.ok() {
    return None
  }
  self.parse_withisolatedloading().map(x => Node(x))
}

///|
pub fn Parser::parse_procedure_option(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["EXECUTE", "AS"]) {
    let this = match
      self.parse_var_from_options(
        self.cfg.execute_as_options,
        raise_unmatched=false,
      ) {
      Some(v) => Some(v)
      None => self.parse_string()
    }
    return Some(self.expression(mk1(ExecuteAsProperty, this)))
  }
  self.parse_var_from_options(self.cfg.procedure_options)
}

///|
pub fn Parser::parse_definer(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_definer {
    Some(f) => f(self)
    None => self.parse_definer_base()
  }
}

///|
pub fn Parser::parse_definer_base(self : Parser) -> Expr? raise SqlglotError {
  self.match_(EQ) |> ignore
  let user = self.parse_id_var()
  self.match_(PARAMETER) |> ignore
  let host : String? = match self.parse_id_var() {
    Some(h) => Some(self.dialect_sql(h))
    None => if self.match_(MOD) { Some(self.prev.text) } else { None }
  }
  match (user, host) {
    (Some(u), Some(h)) =>
      Some(mk1(DefinerProperty, "\{self.dialect_sql(u)}@\{h}"))
    _ => None
  }
}

///|
pub fn Parser::parse_withjournaltable(self : Parser) -> Expr raise SqlglotError {
  self.match_(TABLE) |> ignore
  self.match_(EQ) |> ignore
  self.expression(mk1(WithJournalTableProperty, self.parse_table_parts()))
}

///|
pub fn Parser::parse_log(self : Parser, no? : Bool = false) -> Expr raise SqlglotError {
  self.expression(mk(LogProperty, [("no", no)]))
}

///|
pub fn Parser::parse_journal(self : Parser, kwargs : PropKwargs) -> Expr raise SqlglotError {
  let e = mk0(JournalProperty)
  for k, v in kwargs {
    if k == "not_local" {
      e.set("local", "NOT LOCAL")
    } else if k == "local" {
      e.set("local", "LOCAL")
    } else {
      e.set(k, v)
    }
  }
  self.expression(e)
}

///|
pub fn Parser::parse_checksum(self : Parser) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let on : Bool? = if self.match_(ON) {
    Some(true)
  } else if self.match_text("OFF") {
    Some(false)
  } else {
    None
  }
  self.expression(
    mk(ChecksumProperty, [("on", on), ("default", self.match_(DEFAULT))]),
  )
}

///|
pub fn Parser::parse_cluster(self : Parser) -> Expr raise SqlglotError {
  self.match_(CLUSTER_BY) |> ignore
  self.expression(
    mk(Cluster, [("expressions", self.parse_csv(() => self.parse_column()))]),
  )
}

///|
pub fn Parser::parse_cluster_property(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_cluster_property {
    Some(f) => f(self)
    None => self.parse_cluster_property_base()
  }
}

///|
pub fn Parser::parse_cluster_property_base(self : Parser) -> Expr? raise SqlglotError {
  Some(
    self.expression(
      mk(ClusterProperty, [
        ("expressions", self.parse_wrapped_csv(() => self.parse_column())),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_clustered_by(self : Parser) -> Expr raise SqlglotError {
  self.match_text("BY") |> ignore
  self.match_l_paren()
  let expressions = self.parse_csv(() => self.parse_column())
  self.match_r_paren()
  let sorted_by = if self.match_text_seq(["SORTED", "BY"]) {
    self.match_l_paren()
    let s = self.parse_csv(() => self.parse_ordered())
    self.match_r_paren()
    Some(s)
  } else {
    None
  }
  self.match_(INTO) |> ignore
  let buckets = self.parse_number()
  self.match_text("BUCKETS") |> ignore
  self.expression(
    mk(ClusteredByProperty, [
      ("expressions", expressions),
      ("sorted_by", sorted_by),
      ("buckets", buckets),
    ]),
  )
}

///|
pub fn Parser::parse_copy_property(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text("GRANTS") {
    self.retreat(self.index - 1)
    return None
  }
  Some(self.expression(mk0(CopyGrantsProperty)))
}

///|
pub fn Parser::parse_freespace(self : Parser) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let this = self.parse_number()
  self.expression(
    mk(FreespaceProperty, [("this", this), ("percent", self.match_(PERCENT))]),
  )
}

///|
pub fn Parser::parse_mergeblockratio(
  self : Parser,
  no? : Bool = false,
  default? : Bool = false,
) -> Expr raise SqlglotError {
  if self.match_(EQ) {
    let this = self.parse_number()
    return self.expression(
      mk(MergeBlockRatioProperty, [
        ("this", this),
        ("percent", self.match_(PERCENT)),
      ]),
    )
  }
  self.expression(mk(MergeBlockRatioProperty, [("no", no), ("default", default)]))
}

///|
pub fn Parser::parse_datablocksize(
  self : Parser,
  default? : Bool,
  minimum? : Bool,
  maximum? : Bool,
) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let size = self.parse_number()
  let units = if self.match_texts(["BYTES", "KBYTES", "KILOBYTES"]) {
    Some(self.prev.text)
  } else {
    None
  }
  self.expression(
    mk(DataBlocksizeProperty, [
      ("size", size),
      ("units", units),
      ("default", default),
      ("minimum", minimum),
      ("maximum", maximum),
    ]),
  )
}

///|
pub fn Parser::parse_blockcompression(self : Parser) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  let always = self.match_text("ALWAYS")
  let manual = self.match_text("MANUAL")
  let never = self.match_text("NEVER")
  let default = self.match_text("DEFAULT")
  let autotemp = if self.match_text("AUTOTEMP") {
    self.parse_schema()
  } else {
    None
  }
  self.expression(
    mk(BlockCompressionProperty, [
      ("always", always),
      ("manual", manual),
      ("never", never),
      ("default", default),
      ("autotemp", autotemp),
    ]),
  )
}

///|
pub fn Parser::parse_withisolatedloading(self : Parser) -> Expr? raise SqlglotError {
  let index = self.index
  let no = self.match_text("NO")
  let concurrent = self.match_text("CONCURRENT")
  if !self.match_text_seq(["ISOLATED", "LOADING"]) {
    self.retreat(index)
    return None
  }
  let target = self.parse_var_from_options(
    self.cfg.isolated_loading_options,
    raise_unmatched=false,
  )
  Some(
    self.expression(
      mk(IsolatedLoadingProperty, [
        ("no", no),
        ("concurrent", concurrent),
        ("target", target),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_locking(self : Parser) -> Expr raise SqlglotError {
  let kind : String? = if self.match_(TABLE) {
    Some("TABLE")
  } else if self.match_(VIEW) {
    Some("VIEW")
  } else if self.match_(ROW) {
    Some("ROW")
  } else if self.match_text("DATABASE") {
    Some("DATABASE")
  } else {
    None
  }
  let this = match kind {
    Some("DATABASE" | "TABLE" | "VIEW") => self.parse_table_parts()
    _ => None
  }
  let for_or_in : String? = if self.match_(FOR) {
    Some("FOR")
  } else if self.match_(IN) {
    Some("IN")
  } else {
    None
  }
  let lock_type : String? = if self.match_text("ACCESS") {
    Some("ACCESS")
  } else if self.match_texts(["EXCL", "EXCLUSIVE"]) {
    Some("EXCLUSIVE")
  } else if self.match_text("SHARE") {
    Some("SHARE")
  } else if self.match_text("READ") {
    Some("READ")
  } else if self.match_text("WRITE") {
    Some("WRITE")
  } else if self.match_text("CHECKSUM") {
    Some("CHECKSUM")
  } else {
    None
  }
  let override_ = self.match_text("OVERRIDE")
  self.expression(
    mk(LockingProperty, [
      ("this", this),
      ("kind", kind),
      ("for_or_in", for_or_in),
      ("lock_type", lock_type),
      ("override", override_),
    ]),
  )
}

///|
pub fn Parser::parse_partition_by(self : Parser) -> Array[Expr] raise SqlglotError {
  if self.match_(PARTITION_BY) {
    return self.parse_csv(() => self.parse_disjunction())
  }
  []
}

///|
pub fn Parser::parse_partition_bound_spec(self : Parser) -> Expr raise SqlglotError {
  fn parse_partition_bound_expr() -> Expr? raise SqlglotError {
    if self.match_text("MINVALUE") {
      return Some(var_("MINVALUE"))
    }
    if self.match_text("MAXVALUE") {
      return Some(var_("MAXVALUE"))
    }
    self.parse_bitwise()
  }

  let mut this : Value? = None
  let mut expression : Expr? = None
  let mut from_expressions : Array[Expr]? = None
  let mut to_expressions : Array[Expr]? = None
  if self.match_(IN) {
    this = Some(
      List(self.parse_wrapped_csv(() => self.parse_bitwise()).map(x => Node(x))),
    )
  } else if self.match_(FROM) {
    from_expressions = Some(self.parse_wrapped_csv(parse_partition_bound_expr))
    self.match_text("TO") |> ignore
    to_expressions = Some(self.parse_wrapped_csv(parse_partition_bound_expr))
  } else if self.match_text_seq(["WITH", "(", "MODULUS"]) {
    this = self.parse_number().map(x => Node(x))
    self.match_text_seq([",", "REMAINDER"]) |> ignore
    expression = self.parse_number()
    self.match_r_paren()
  } else {
    self.raise_error("Failed to parse partition bound spec.")
  }
  self.expression(
    mk(PartitionBoundSpec, [
      ("this", this),
      ("expression", expression),
      ("from_expressions", from_expressions),
      ("to_expressions", to_expressions),
    ]),
  )
}

///|
pub fn Parser::parse_partitioned_of(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text("OF") {
    self.retreat(self.index - 1)
    return None
  }
  let this = self.parse_table(schema=true)
  let mut expression : Expr? = None
  if self.match_(DEFAULT) {
    expression = Some(var_("DEFAULT"))
  } else if self.match_text_seq(["FOR", "VALUES"]) {
    expression = Some(self.parse_partition_bound_spec())
  } else {
    self.raise_error("Expecting either DEFAULT or FOR VALUES clause.")
  }
  Some(
    self.expression(
      mk(PartitionedOfProperty, [("this", this), ("expression", expression)]),
    ),
  )
}

///|
pub fn Parser::parse_partitioned_by(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_partitioned_by {
    Some(f) => f(self)
    None => self.parse_partitioned_by_base()
  }
}

///|
pub fn Parser::parse_partitioned_by_base(self : Parser) -> Expr? raise SqlglotError {
  self.match_(EQ) |> ignore
  let this = match self.parse_schema() {
    Some(s) => Some(s)
    None => self.parse_bracket(self.parse_field())
  }
  Some(self.expression(mk1(PartitionedByProperty, this)))
}

///|
pub fn Parser::parse_withdata(self : Parser, no? : Bool = false) -> Expr raise SqlglotError {
  let statistics : Bool? = if self.match_text_seq(["AND", "STATISTICS"]) {
    Some(true)
  } else if self.match_text_seq(["AND", "NO", "STATISTICS"]) {
    Some(false)
  } else {
    None
  }
  self.expression(mk(WithDataProperty, [("no", no), ("statistics", statistics)]))
}

///|
pub fn Parser::parse_contains_property(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text("SQL") {
    return Some(self.expression(mk1(SqlReadWriteProperty, "CONTAINS SQL")))
  }
  None
}

///|
pub fn Parser::parse_modifies_property(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["SQL", "DATA"]) {
    return Some(self.expression(mk1(SqlReadWriteProperty, "MODIFIES SQL DATA")))
  }
  None
}

///|
pub fn Parser::parse_no_property(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["PRIMARY", "INDEX"]) {
    return Some(mk0(NoPrimaryIndexProperty))
  }
  if self.match_text("SQL") {
    return Some(self.expression(mk1(SqlReadWriteProperty, "NO SQL")))
  }
  None
}

///|
pub fn Parser::parse_on_property(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_on_property {
    Some(f) => f(self)
    None => self.parse_on_property_base()
  }
}

///|
pub fn Parser::parse_on_property_base(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["COMMIT", "PRESERVE", "ROWS"]) {
    return Some(mk0(OnCommitProperty))
  }
  if self.match_text_seq(["COMMIT", "DELETE", "ROWS"]) {
    return Some(mk(OnCommitProperty, [("delete", true)]))
  }
  Some(self.expression(mk1(OnProperty, self.parse_schema(this=self.parse_id_var()))))
}

///|
pub fn Parser::parse_reads_property(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["SQL", "DATA"]) {
    return Some(self.expression(mk1(SqlReadWriteProperty, "READS SQL DATA")))
  }
  None
}

///|
pub fn Parser::parse_distkey(self : Parser) -> Expr raise SqlglotError {
  self.expression(mk1(DistKeyProperty, self.parse_wrapped(() => self.parse_id_var())))
}

///|
pub fn Parser::parse_create_like(self : Parser) -> Expr? raise SqlglotError {
  let table = self.parse_table(schema=true)
  let options = []
  while self.match_texts(["INCLUDING", "EXCLUDING"]) {
    let this = self.prev_upper()
    let id_var = match self.parse_id_var() {
      Some(v) => v
      None => return None
    }
    options.push(
      self.expression(
        mk(Property, [
          ("this", this),
          ("value", var_(py_upper(id_var.text("this")))),
        ]),
      ),
    )
  }
  Some(self.expression(mk(LikeProperty, [("this", table), ("expressions", options)])))
}

///|
pub fn Parser::parse_sortkey(self : Parser, compound? : Bool = false) -> Expr raise SqlglotError {
  self.expression(
    mk(SortKeyProperty, [
      ("this", self.parse_wrapped_id_vars()),
      ("compound", compound),
    ]),
  )
}

///|
pub fn Parser::parse_character_set(
  self : Parser,
  default? : Bool = false,
) -> Expr raise SqlglotError {
  self.match_(EQ) |> ignore
  self.expression(
    mk(CharacterSetProperty, [
      ("this", self.parse_var_or_string()),
      ("default", default),
    ]),
  )
}

///|
pub fn Parser::parse_remote_with_connection(self : Parser) -> Expr raise SqlglotError {
  self.match_text_seq(["WITH", "CONNECTION"]) |> ignore
  self.expression(mk1(RemoteWithConnectionModelProperty, self.parse_table_parts()))
}

///|
pub fn Parser::parse_returns(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_returns {
    Some(f) => f(self)
    None => self.parse_returns_base()
  }
}

///|
pub fn Parser::parse_returns_base(self : Parser) -> Expr? raise SqlglotError {
  let mut value : Expr? = None
  let mut null : Bool? = None
  let is_table = self.match_(TABLE)
  if is_table {
    if self.match_(LT) {
      value = Some(
        self.expression(
          mk(Schema, [
            ("this", "TABLE"),
            ("expressions", self.parse_csv(() => self.parse_struct_types())),
          ]),
        ),
      )
      if !self.match_(GT) {
        self.raise_error("Expecting >")
      }
    } else {
      value = self.parse_schema(this=Some(var_("TABLE")))
    }
  } else if self.match_text_seq(["NULL", "ON", "NULL", "INPUT"]) {
    null = Some(true)
    value = None
  } else {
    value = self.parse_types()
  }
  Some(
    self.expression(
      mk(ReturnsProperty, [("this", value), ("is_table", is_table), ("null", null)]),
    ),
  )
}

///|
/// Python `f"{expr}"`: the SQL of an expression with the base dialect.
pub fn Parser::dialect_sql(self : Parser, e : Expr) -> String raise SqlglotError {
  ignore(self)
  expr_to_sql(e)
}
