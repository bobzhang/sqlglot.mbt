// Port of sqlglot/parser.py: transactions, ALTER, ANALYZE, MERGE, SHOW/SET, dictionaries,
// comprehensions and heredocs.

///|
pub fn Parser::parse_transaction(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_transaction {
    Some(f) => f(self)
    None => self.parse_transaction_base()
  }
}

///|
pub fn Parser::parse_transaction_base(self : Parser) -> Expr? raise SqlglotError {
  let mut this : String? = None
  if self.match_text_set(self.cfg.transaction_kind) {
    this = Some(self.prev.text)
  }
  self.match_texts(["TRANSACTION", "WORK"]) |> ignore
  let modes = []
  while true {
    let mode = []
    while self.match_(VAR) || self.match_(NOT) {
      mode.push(self.prev.text)
    }
    if !mode.is_empty() {
      modes.push(mode.join(" "))
    }
    if !self.match_(COMMA) {
      break
    }
  }
  Some(self.expression(mk(Transaction, [("this", this), ("modes", modes)])))
}

///|
pub fn Parser::parse_commit_or_rollback(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_commit_or_rollback {
    Some(f) => f(self)
    None => self.parse_commit_or_rollback_base()
  }
}

///|
pub fn Parser::parse_commit_or_rollback_base(self : Parser) -> Expr? raise SqlglotError {
  let mut chain : Bool? = None
  let mut savepoint : Expr? = None
  let is_rollback = self.prev.token_type == ROLLBACK
  self.match_texts(["TRANSACTION", "WORK"]) |> ignore
  if self.match_text("TO") {
    self.match_text("SAVEPOINT") |> ignore
    savepoint = self.parse_id_var()
  }
  if self.match_(AND) {
    chain = Some(!self.match_text("NO"))
    self.match_text("CHAIN") |> ignore
  }
  if is_rollback {
    return Some(self.expression(mk(Rollback, [("savepoint", savepoint)])))
  }
  Some(self.expression(mk(Commit, [("chain", chain)])))
}

///|
pub fn Parser::parse_refresh(self : Parser) -> Expr? raise SqlglotError {
  let kind = if self.match_text_seq(["EXTERNAL", "TABLE"]) {
    "EXTERNAL TABLE"
  } else if self.match_(TABLE) {
    "TABLE"
  } else if self.match_text_seq(["MATERIALIZED", "VIEW"]) {
    "MATERIALIZED VIEW"
  } else {
    ""
  }
  let this = expr_or(self.parse_string(), () => self.parse_table())
  let is_literal = match this {
    Some(t) => t.kind == Literal
    None => false
  }
  if kind.is_empty() && !is_literal {
    return Some(self.parse_as_command(self.prev))
  }
  Some(self.expression(mk(Refresh, [("this", this), ("kind", kind)])))
}

///|
pub fn Parser::parse_column_def_with_exists(self : Parser) -> Expr? raise SqlglotError {
  let start = self.index
  self.match_(COLUMN) |> ignore
  let exists_column = self.parse_exists(not_=true)
  let expression = self.parse_field_def()
  match expression {
    Some(e) if e.kind == ColumnDef => {
      e.set("exists", exists_column)
      Some(e)
    }
    _ => {
      self.retreat(start)
      None
    }
  }
}

///|
pub fn Parser::parse_add_column(self : Parser) -> Expr? raise SqlglotError {
  if self.prev_upper() != "ADD" {
    return None
  }
  self.parse_column_def_with_exists()
}

///|
pub fn Parser::parse_drop_column(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_drop_column {
    Some(f) => f(self)
    None => self.parse_drop_column_base()
  }
}

///|
pub fn Parser::parse_drop_column_base(self : Parser) -> Expr? raise SqlglotError {
  let drop = if self.match_(DROP) { self.parse_drop() } else { None }
  match drop {
    Some(d) if d.kind != Command =>
      if !d.args.contains("kind") {
        d.set("kind", "COLUMN")
      }
    _ => ()
  }
  drop
}

///|
pub fn Parser::parse_alter_drop_action(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_alter_drop_action {
    Some(f) => f(self)
    None => self.parse_drop_column()
  }
}

///|
pub fn Parser::parse_drop_partition(self : Parser, exists? : Bool?) -> Expr? raise SqlglotError {
  let exists : Bool? = match exists {
    Some(e) => e
    None => None
  }
  Some(
    self.expression(
      mk(DropPartition, [
        ("expressions", self.parse_csv(() => self.parse_partition())),
        ("exists", exists),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_alter_table_add(self : Parser) -> Array[Expr] raise SqlglotError {
  fn parse_add_alteration() -> Expr? raise SqlglotError {
    self.match_text("ADD") |> ignore
    if self.match_set(self.cfg.add_constraint_tokens, advance=false) {
      return Some(
        self.expression(
          mk(AddConstraint, [
            ("expressions", self.parse_csv(() => self.parse_constraint())),
          ]),
        ),
      )
    }
    match self.parse_add_column() {
      Some(c) if c.kind == ColumnDef => return Some(c)
      _ => ()
    }
    let exists = self.parse_exists(not_=true)
    if self.match_pair(PARTITION, L_PAREN, advance=false) {
      let this = self.parse_field(any_token=true)
      let location : Value? = if self.match_text("LOCATION", advance=false) {
        self.parse_property()
      } else {
        Some(Bool(false))
      }
      return Some(
        self.expression(
          mk(AddPartition, [
            ("exists", exists),
            ("this", this),
            ("location", location),
          ]),
        ),
      )
    }
    None
  }

  if !self.match_set(self.cfg.add_constraint_tokens, advance=false) &&
    (
      !self.dialect.cfg.alter_table_add_required_for_each_column ||
      self.match_text("COLUMNS")
    ) {
    let schema = self.parse_schema()
    return match schema {
      Some(s) => [s]
      None => self.parse_csv(() => self.parse_column_def_with_exists())
    }
  }
  self.parse_csv(parse_add_alteration)
}

///|
pub fn Parser::parse_alter_table_alter(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_alter_table_alter {
    Some(f) => f(self)
    None => self.parse_alter_table_alter_base()
  }
}

///|
pub fn Parser::parse_alter_table_alter_base(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_keys(self.fns.alter_alter_parsers) {
    return self.fns.alter_alter_parsers[self.prev_upper()](self)
  }
  self.match_(COLUMN) |> ignore
  let exists = match self.parse_exists() {
    Some(true) => Some(true)
    _ => None
  }
  let column = self.parse_field(any_token=true)
  if self.match_pair(DROP, DEFAULT) {
    return Some(
      self.expression(
        mk(AlterColumn, [("this", column), ("drop", true), ("exists", exists)]),
      ),
    )
  }
  if self.match_pair(SET, DEFAULT) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("default", self.parse_disjunction()),
          ("exists", exists),
        ]),
      ),
    )
  }
  if self.match_(COMMENT) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("comment", self.parse_string()),
          ("exists", exists),
        ]),
      ),
    )
  }
  if self.match_text_seq(["DROP", "NOT", "NULL"]) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("drop", true),
          ("allow_null", true),
          ("exists", exists),
        ]),
      ),
    )
  }
  if self.match_text_seq(["SET", "NOT", "NULL"]) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("allow_null", false),
          ("exists", exists),
        ]),
      ),
    )
  }
  if self.match_text_seq(["SET", "VISIBLE"]) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("visible", "VISIBLE"),
          ("exists", exists),
        ]),
      ),
    )
  }
  if self.match_text_seq(["SET", "INVISIBLE"]) {
    return Some(
      self.expression(
        mk(AlterColumn, [
          ("this", column),
          ("visible", "INVISIBLE"),
          ("exists", exists),
        ]),
      ),
    )
  }
  self.match_text_seq(["SET", "DATA"]) |> ignore
  self.match_text("TYPE") |> ignore
  let dtype = self.parse_types()
  let collate = self.andv(self.match_(COLLATE), () => self.parse_term())
  let using_ = self.andv(self.match_(USING), () => self.parse_disjunction())
  Some(
    self.expression(
      mk(AlterColumn, [
        ("this", column),
        ("dtype", dtype),
        ("collate", collate),
        ("using", using_),
        ("exists", exists),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_alter_diststyle(self : Parser) -> Expr? raise SqlglotError {
  if self.match_texts(["ALL", "EVEN", "AUTO"]) {
    return Some(self.expression(mk1(AlterDistStyle, var_(self.prev_upper()))))
  }
  self.match_text_seq(["KEY", "DISTKEY"]) |> ignore
  Some(self.expression(mk1(AlterDistStyle, self.parse_column())))
}

///|
pub fn Parser::parse_alter_sortkey(self : Parser, compound? : Bool) -> Expr? raise SqlglotError {
  if compound == Some(true) {
    self.match_text("SORTKEY") |> ignore
  }
  if self.match_(L_PAREN, advance=false) {
    return Some(
      self.expression(
        mk(AlterSortKey, [
          ("expressions", self.parse_wrapped_id_vars()),
          ("compound", compound),
        ]),
      ),
    )
  }
  self.match_texts(["AUTO", "NONE"]) |> ignore
  Some(
    self.expression(
      mk(AlterSortKey, [("this", var_(self.prev_upper())), ("compound", compound)]),
    ),
  )
}

///|
pub fn Parser::parse_alter_table_drop(self : Parser) -> Array[Expr] raise SqlglotError {
  let index = self.index - 1
  let partition_exists = self.parse_exists()
  if self.match_(PARTITION, advance=false) {
    return self.parse_csv(() => self.parse_drop_partition(exists=partition_exists))
  }
  self.retreat(index)
  self.parse_csv(() => self.parse_alter_drop_action())
}

///|
pub fn Parser::parse_alter_table_rename(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_alter_table_rename {
    Some(f) => f(self)
    None => self.parse_alter_table_rename_base()
  }
}

///|
pub fn Parser::parse_alter_table_rename_base(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(COLUMN) ||
    (
      !self.cfg.alter_rename_requires_column &&
      !self.match_text("TO", advance=false)
    ) {
    let exists = self.parse_exists()
    let old_column = self.parse_column()
    let to = self.match_text("TO")
    let new_column = self.parse_column()
    if old_column is None || !to || new_column is None {
      return None
    }
    return Some(
      self.expression(
        mk(RenameColumn, [
          ("this", old_column),
          ("to", new_column),
          ("exists", exists),
        ]),
      ),
    )
  }
  self.match_text("TO") |> ignore
  Some(self.expression(mk1(AlterRename, self.parse_table(schema=true))))
}

///|
pub fn Parser::parse_alter_table_set(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_alter_table_set {
    Some(f) => f(self)
    None => self.parse_alter_table_set_base()
  }
}

///|
pub fn Parser::parse_alter_table_set_base(self : Parser) -> Expr? raise SqlglotError {
  let alter_set = self.expression(mk0(AlterSet))
  if self.match_(L_PAREN, advance=false) ||
    self.match_text_seq(["TABLE", "PROPERTIES"]) {
    alter_set.set("expressions", self.parse_wrapped_csv(() => self.parse_assignment()))
  } else if self.match_text("FILESTREAM_ON", advance=false) {
    alter_set.set("expressions", [self.parse_assignment()].filter_map(x => x))
  } else if self.match_texts(["LOGGED", "UNLOGGED"]) {
    alter_set.set("option", var_(self.prev_upper()))
  } else if self.match_text("WITHOUT") && self.match_texts(["CLUSTER", "OIDS"]) {
    alter_set.set("option", var_("WITHOUT \{self.prev_upper()}"))
  } else if self.match_text("LOCATION") {
    alter_set.set("location", self.parse_field())
  } else if self.match_text_seq(["ACCESS", "METHOD"]) {
    alter_set.set("access_method", self.parse_field())
  } else if self.match_text("TABLESPACE") {
    alter_set.set("tablespace", self.parse_field())
  } else if self.match_text_seq(["FILE", "FORMAT"]) || self.match_text("FILEFORMAT") {
    alter_set.set("file_format", [self.parse_field()].filter_map(x => x))
  } else if self.match_text("STAGE_FILE_FORMAT") {
    alter_set.set("file_format", self.parse_wrapped_options())
  } else if self.match_text("STAGE_COPY_OPTIONS") {
    alter_set.set("copy_options", self.parse_wrapped_options())
  } else if self.match_text("TAG") || self.match_text("TAGS") {
    alter_set.set("tag", self.parse_csv(() => self.parse_assignment()))
  } else {
    if self.match_text("SERDE") {
      alter_set.set("serde", self.parse_field())
    }
    let properties = self.parse_wrapped(() => self.parse_properties(), optional=true)
    alter_set.set("expressions", [properties].filter_map(x => x))
  }
  Some(alter_set)
}

///|
pub fn Parser::parse_alter_session(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(SET) {
    let expressions = self.parse_csv(() => self.parse_set_item_assignment())
    return Some(
      self.expression(
        mk(AlterSession, [("expressions", expressions), ("unset", false)]),
      ),
    )
  }
  self.match_text("UNSET") |> ignore
  let expressions = self.parse_csv(() => Some(
    self.expression(mk1(SetItem, self.parse_id_var(any_token=true))),
  ))
  Some(
    self.expression(
      mk(AlterSession, [("expressions", expressions), ("unset", true)]),
    ),
  )
}

///|
pub fn Parser::parse_alter(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  let iceberg = self.match_text("ICEBERG")
  let alter_token = if self.match_set(self.cfg.alterables) {
    self.prev
  } else {
    return Some(self.parse_as_command(start))
  }
  if iceberg && alter_token.token_type != TABLE {
    return Some(self.parse_as_command(start))
  }
  let exists = self.parse_exists()
  let only = self.match_text("ONLY")
  let mut this : Expr? = None
  let mut check : Bool? = None
  let mut cluster : Expr? = None
  if alter_token.token_type != SESSION {
    this = self.parse_table(schema=true, parse_partition=self.cfg.alter_table_partitions)
    check = Some(self.match_text_seq(["WITH", "CHECK"]))
    cluster = if self.match_(ON) { self.parse_on_property() } else { None }
    if self.next.ok() {
      self.advance()
    }
  }
  let parser = if self.prev.ok() {
    self.fns.alter_parsers.get(self.prev_upper())
  } else {
    None
  }
  match parser {
    Some(parser) => {
      let actions = match parser(self) {
        Some(Node(e)) => [e]
        Some(List(l)) => l.filter_map(x => x.as_node())
        _ => []
      }
      let not_valid = self.match_text_seq(["NOT", "VALID"])
      let options = self.parse_csv_any(() => self.parse_property()).filter_map(x => x.as_node())
      let cascade = self.dialect.cfg.alter_table_supports_cascade &&
        self.match_text("CASCADE")
      if !self.curr.ok() && !actions.is_empty() {
        return Some(
          self.expression(
            mk(Alter, [
              ("this", this),
              ("kind", py_upper(alter_token.text)),
              ("exists", exists),
              ("actions", actions),
              ("only", only),
              ("options", options),
              ("cluster", cluster),
              ("not_valid", not_valid),
              ("check", check),
              ("cascade", cascade),
              ("iceberg", iceberg),
            ]),
          ),
        )
      }
    }
    None => ()
  }
  Some(self.parse_as_command(start))
}

///|
pub fn Parser::parse_analyze(self : Parser) -> Expr? raise SqlglotError {
  let start = self.prev
  if !self.curr.ok() {
    return Some(self.expression(mk0(Analyze)))
  }
  let options = []
  while self.match_text_set(self.cfg.analyze_styles) {
    if self.prev_upper() == "BUFFER_USAGE_LIMIT" {
      let n = match self.parse_number() {
        Some(n) => expr_to_sql(n)
        None => "None"
      }
      options.push("BUFFER_USAGE_LIMIT \{n}")
    } else {
      options.push(self.prev_upper())
    }
  }
  let mut tables : Array[Expr] = []
  let mut inner_expression : Expr? = None
  let mut kind : String? = if self.curr.ok() {
    Some(py_upper(self.curr.text))
  } else {
    None
  }
  if self.match_(TABLE) {
    tables = self.parse_csv(() => self.parse_table_parts())
  } else if self.match_(INDEX) {
    tables = self.parse_table_parts()|> opt_list
  } else if self.match_text("TABLES") {
    if self.match_any([FROM, IN]) {
      kind = Some("\{kind.unwrap_or("None")} \{self.prev_upper()}")
      tables = self.parse_table(schema=true, is_db_reference=true)|> opt_list
    }
  } else if self.match_text("DATABASE") {
    tables = self.parse_table(schema=true, is_db_reference=true)|> opt_list
  } else if self.match_text("CLUSTER") {
    tables = self.parse_table()|> opt_list
  } else if self.match_text_keys(self.fns.analyze_expression_parsers) {
    kind = None
    inner_expression = self.fns.analyze_expression_parsers[self.prev_upper()](self)
  } else {
    kind = None
    tables = self.parse_csv(() => self.parse_table_parts())
  }
  let partition = self.try_parse(() => self.parse_partition())
  if partition is None && self.match_text_set(self.cfg.partition_keywords) {
    return Some(self.parse_as_command(start))
  }
  let mode = if self.match_text_seq(["WITH", "SYNC", "MODE"]) ||
    self.match_text_seq(["WITH", "ASYNC", "MODE"]) {
    Some("WITH \{py_upper(self.tokens[self.index - 2].text)} MODE")
  } else {
    None
  }
  if self.match_text_keys(self.fns.analyze_expression_parsers) {
    inner_expression = self.fns.analyze_expression_parsers[self.prev_upper()](self)
  }
  let properties = self.parse_properties()
  Some(
    self.expression(
      mk(Analyze, [
        ("kind", kind),
        ("tables", tables),
        ("mode", mode),
        ("partition", partition),
        ("properties", properties),
        ("expression", inner_expression),
        ("options", options),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_analyze_statistics(self : Parser) -> Expr? raise SqlglotError {
  let mut this : String? = None
  let kind = self.prev_upper()
  let option = if self.match_text("DELTA") {
    Some(self.prev_upper())
  } else {
    None
  }
  let mut expressions = []
  if !self.match_text("STATISTICS") {
    self.raise_error("Expecting token STATISTICS")
  }
  if self.match_text("NOSCAN") {
    this = Some("NOSCAN")
  } else if self.match_(FOR) {
    if self.match_text_seq(["ALL", "COLUMNS"]) {
      this = Some("FOR ALL COLUMNS")
    }
    if self.match_text("COLUMNS") {
      this = Some("FOR COLUMNS")
      expressions = self.parse_csv(() => self.parse_column_reference())
    }
  } else if self.match_text("SAMPLE") {
    let sample = self.parse_number()
    let k = if self.match_(PERCENT) {
      Some(self.prev_upper())
    } else {
      None
    }
    expressions = [
      self.expression(mk(AnalyzeSample, [("sample", sample), ("kind", k)])),
    ]
  }
  Some(
    self.expression(
      mk(AnalyzeStatistics, [
        ("kind", kind),
        ("option", option),
        ("this", this),
        ("expressions", expressions),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_analyze_validate(self : Parser) -> Expr? raise SqlglotError {
  let mut kind : String? = None
  let mut this : String? = None
  let mut expression : Expr? = None
  if self.match_text_seq(["REF", "UPDATE"]) {
    kind = Some("REF")
    this = Some("UPDATE")
    if self.match_text_seq(["SET", "DANGLING", "TO", "NULL"]) {
      this = Some("UPDATE SET DANGLING TO NULL")
    }
  } else if self.match_text("STRUCTURE") {
    kind = Some("STRUCTURE")
    if self.match_text_seq(["CASCADE", "FAST"]) {
      this = Some("CASCADE FAST")
    } else if self.match_text_seq(["CASCADE", "COMPLETE"]) &&
      self.match_texts(["ONLINE", "OFFLINE"]) {
      this = Some("CASCADE COMPLETE \{self.prev_upper()}")
      expression = self.parse_into_clause()
    }
  }
  Some(
    self.expression(
      mk(AnalyzeValidate, [("kind", kind), ("this", this), ("expression", expression)]),
    ),
  )
}

///|
pub fn Parser::parse_analyze_columns(self : Parser) -> Expr? raise SqlglotError {
  let this = self.prev_upper()
  if self.match_text("COLUMNS") {
    return Some(self.expression(mk1(AnalyzeColumns, "\{this} \{self.prev_upper()}")))
  }
  None
}

///|
pub fn Parser::parse_analyze_delete(self : Parser) -> Expr? raise SqlglotError {
  let kind = if self.match_text("SYSTEM") {
    Some(self.prev_upper())
  } else {
    None
  }
  if self.match_text("STATISTICS") {
    return Some(self.expression(mk(AnalyzeDelete, [("kind", kind)])))
  }
  None
}

///|
pub fn Parser::parse_analyze_list(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text_seq(["CHAINED", "ROWS"]) {
    return Some(
      self.expression(
        mk(AnalyzeListChainedRows, [("expression", self.parse_into_clause())]),
      ),
    )
  }
  None
}

///|
pub fn Parser::parse_analyze_histogram(self : Parser) -> Expr? raise SqlglotError {
  let this = self.prev_upper()
  let mut expression : Expr? = None
  let mut expressions = []
  let mut update_options : String? = None
  if self.match_text_seq(["HISTOGRAM", "ON"]) {
    expressions = self.parse_csv(() => self.parse_column_reference())
    let with_expressions = []
    while self.match_(WITH) {
      if self.match_texts(["SYNC", "ASYNC"]) {
        if self.match_text("MODE", advance=false) {
          with_expressions.push("\{self.prev_upper()} MODE")
          self.advance()
        }
      } else {
        let buckets = self.parse_number()
        if self.match_text("BUCKETS") {
          let b = match buckets {
            Some(b) => expr_to_sql(b)
            None => "None"
          }
          with_expressions.push("\{b} BUCKETS")
        }
      }
    }
    if !with_expressions.is_empty() {
      expression = Some(
        self.expression(mk(AnalyzeWith, [("expressions", with_expressions)])),
      )
    }
    if self.match_texts(["MANUAL", "AUTO"]) && self.match_(UPDATE, advance=false) {
      update_options = Some(self.prev_upper())
      self.advance()
    } else if self.match_text_seq(["USING", "DATA"]) {
      expression = Some(self.expression(mk1(UsingData, self.parse_string())))
    }
  }
  Some(
    self.expression(
      mk(AnalyzeHistogram, [
        ("this", this),
        ("expressions", expressions),
        ("expression", expression),
        ("update_options", update_options),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_merge(self : Parser) -> Expr? raise SqlglotError {
  self.match_(INTO) |> ignore
  let target = self.parse_table()
  match target {
    Some(t) if self.match_(ALIAS, advance=false) =>
      t.set("alias", self.parse_table_alias())
    _ => ()
  }
  self.match_(USING) |> ignore
  let using_ = self.parse_table()
  let on = self.andv(self.match_(ON), () => self.parse_disjunction())
  let using_cond = self.andl(self.match_(USING), () => self.parse_using_identifiers())
  let whens = self.parse_when_matched()
  let returning = self.parse_returning()
  Some(
    self.expression(
      mk(Merge, [
        ("this", target),
        ("using", using_),
        ("on", on),
        ("using_cond", using_cond),
        ("whens", whens),
        ("returning", returning),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_when_matched(self : Parser) -> Expr? raise SqlglotError {
  let whens = []
  while self.match_(WHEN) {
    let matched = !self.match_(NOT)
    self.match_text("MATCHED") |> ignore
    let source = if self.match_text_seq(["BY", "TARGET"]) {
      false
    } else {
      self.match_text_seq(["BY", "SOURCE"])
    }
    let condition = if self.match_(AND) { self.parse_disjunction() } else { None }
    self.match_(THEN) |> ignore
    let then = if self.match_(INSERT) {
      match self.parse_star() {
        Some(this) => Some(self.expression(mk1(Insert, this)))
        None => {
          let this = if self.match_text("ROW") {
            Some(var_("ROW"))
          } else {
            self.parse_value(values=false)
          }
          let expression = self.andv(self.match_text("VALUES"), () => self.parse_value())
          let where_ = self.parse_where()
          Some(
            self.expression(
              mk(Insert, [
                ("this", this),
                ("expression", expression),
                ("where", where_),
              ]),
            ),
          )
        }
      }
    } else if self.match_(UPDATE) {
      match self.parse_star() {
        Some(expressions) =>
          Some(self.expression(mk(Update, [("expressions", expressions)])))
        None => {
          let expressions = self.andl(self.match_(SET), () => self.parse_csv(() => self.parse_update_assignment()))
          let where_ = self.parse_where()
          Some(
            self.expression(
              mk(Update, [("expressions", expressions), ("where", where_)]),
            ),
          )
        }
      }
    } else if self.match_(DELETE) {
      Some(self.expression(mk1(Var, self.prev.text)))
    } else {
      self.parse_var_from_options(self.cfg.conflict_actions)
    }
    whens.push(
      self.expression(
        mk(When, [
          ("matched", matched),
          ("source", source),
          ("condition", condition),
          ("then", then),
        ]),
      ),
    )
  }
  Some(self.expression(mk(Whens, [("expressions", whens)])))
}

///|
pub fn Parser::parse_show(self : Parser) -> Expr? raise SqlglotError {
  match self.find_parser(self.fns.show_parsers, self.fns.show_trie) {
    Some(parser) => parser(self)
    None => Some(self.parse_as_command(self.prev))
  }
}

///|
pub fn Parser::parse_set_item_assignment(
  self : Parser,
  kind? : String,
) -> Expr? raise SqlglotError {
  let index = self.index
  if (kind == Some("GLOBAL") || kind == Some("SESSION")) &&
    self.match_text("TRANSACTION") {
    return Some(self.parse_set_transaction(global_=kind == Some("GLOBAL")))
  }
  let left = expr_or(self.parse_primary(), () => self.parse_column())
  let assignment_delimiter = self.match_text_set(self.cfg.set_assignment_delimiters)
  if left is None || (self.cfg.set_requires_assignment_delimiter && !assignment_delimiter) {
    self.retreat(index)
    return None
  }
  let mut right = expr_or(self.parse_statement(), () => self.parse_id_var())
  match right {
    Some(r) if r.kind.is_any([Column, Identifier]) => right = Some(var_(r.name()))
    _ => ()
  }
  let this = self.expression(mk(EQ, [("this", left), ("expression", right)]))
  Some(self.expression(mk(SetItem, [("this", this), ("kind", kind)])))
}

///|
pub fn Parser::parse_set_transaction(
  self : Parser,
  global_? : Bool = false,
) -> Expr raise SqlglotError {
  self.match_text("TRANSACTION") |> ignore
  let characteristics = self.parse_csv(() => self.parse_var_from_options(
    self.cfg.transaction_characteristics,
  ))
  self.expression(
    mk(SetItem, [
      ("expressions", characteristics),
      ("kind", "TRANSACTION"),
      ("global_", global_),
    ]),
  )
}

///|
pub fn Parser::parse_set_item(self : Parser) -> Expr? raise SqlglotError {
  match self.find_parser(self.fns.set_parsers, self.fns.set_trie) {
    Some(parser) => parser(self)
    None => self.parse_set_item_assignment()
  }
}

///|
pub fn Parser::parse_set(
  self : Parser,
  unset? : Bool = false,
  tag? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_set {
    Some(f) => f(self, unset, tag)
    None => self.parse_set_base(unset~, tag~)
  }
}

///|
pub fn Parser::parse_set_base(
  self : Parser,
  unset? : Bool = false,
  tag? : Bool = false,
) -> Expr? raise SqlglotError {
  let index = self.index
  let set_ = self.expression(
    mk(Set, [
      ("expressions", self.parse_csv(() => self.parse_set_item())),
      ("unset", unset),
      ("tag", tag),
    ]),
  )
  if self.curr.ok() {
    self.retreat(index)
    return Some(self.parse_as_command(self.prev))
  }
  Some(set_)
}

///|
pub fn Parser::parse_dict_property(self : Parser, this : String) -> Expr? raise SqlglotError {
  let settings = []
  self.match_l_paren()
  let kind = self.parse_id_var()
  if self.match_(L_PAREN) {
    while true {
      let key = self.parse_id_var()
      let value = expr_or(self.parse_function(), () => self.parse_primary_or_var())
      if key is None && value is None {
        break
      }
      settings.push(
        self.expression(mk(DictSubProperty, [("this", key), ("value", value)])),
      )
    }
    self.match_(R_PAREN) |> ignore
  }
  self.match_r_paren()
  let kind_v : Value? = match kind {
    Some(k) => k.args.get("this")
    None => None
  }
  Some(
    self.expression(
      mk(DictProperty, [("this", this), ("kind", kind_v), ("settings", settings)]),
    ),
  )
}

///|
pub fn Parser::parse_dict_range(self : Parser, this : String) -> Expr? raise SqlglotError {
  self.match_l_paren()
  let has_min = self.match_text("MIN")
  let (min, max) = if has_min {
    let min = expr_or(self.parse_var(), () => self.parse_primary())
    self.match_text("MAX") |> ignore
    let max = expr_or(self.parse_var(), () => self.parse_primary())
    (min, max)
  } else {
    let max = expr_or(self.parse_var(), () => self.parse_primary())
    (Some(literal_int(0)), max)
  }
  self.match_r_paren()
  Some(
    self.expression(mk(DictRange, [("this", this), ("min", min), ("max", max)])),
  )
}

///|
pub fn Parser::parse_comprehension(self : Parser, this : Expr?) -> Expr? raise SqlglotError {
  let index = self.index
  let expression = self.parse_column()
  let position = self.andv(self.match_(COMMA), () => self.parse_column())
  if !self.match_(IN) {
    self.retreat(index - 1)
    return None
  }
  let iterator = self.parse_column()
  let condition = if self.match_text("IF") {
    self.parse_disjunction()
  } else {
    None
  }
  Some(
    self.expression(
      mk(Comprehension, [
        ("this", this),
        ("expression", expression),
        ("position", position),
        ("iterator", iterator),
        ("condition", condition),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_heredoc(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(HEREDOC_STRING) {
    return Some(self.expression(mk1(Heredoc, self.prev.text)))
  }
  if !self.match_text("$") {
    return None
  }
  let tags = ["$"]
  let mut tag_text : String? = None
  if self.is_connected() {
    self.advance()
    tags.push(self.prev_upper())
  } else {
    self.raise_error("No closing $ found")
  }
  if tags[tags.length() - 1] != "$" {
    if self.is_connected() && self.match_text("$") {
      tag_text = Some(tags[tags.length() - 1])
      tags.push("$")
    } else {
      self.raise_error("No closing $ found")
    }
  }
  let heredoc_start = self.curr
  while self.curr.ok() {
    if self.match_text_seq(tags, advance=false) {
      let this = self.find_sql(heredoc_start, self.prev)
      self.advance(times=tags.length())
      return Some(self.expression(mk(Heredoc, [("this", this), ("tag", tag_text)])))
    }
    self.advance()
  }
  self.raise_error("No closing \{tags.join("")} found")
  None
}
