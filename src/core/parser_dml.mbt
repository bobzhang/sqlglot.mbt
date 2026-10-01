// Port of sqlglot/parser.py: DESCRIBE, INSERT, DELETE, UPDATE, USE, CACHE, ...

///|
/// Python `cond and f()`: `False` when `cond` is false, else the result of `f()`.
pub fn Parser::andv(
  self : Parser,
  cond : Bool,
  f : () -> Expr? raise SqlglotError,
) -> Value? raise SqlglotError {
  ignore(self)
  if cond {
    match f() {
      Some(e) => Some(Node(e))
      None => None
    }
  } else {
    Some(Bool(false))
  }
}

///|
/// Python `cond and f()` where `f` returns a list.
pub fn Parser::andl(
  self : Parser,
  cond : Bool,
  f : () -> Array[Expr] raise SqlglotError,
) -> Value? raise SqlglotError {
  ignore(self)
  if cond {
    Some(List(f().map(x => Node(x))))
  } else {
    Some(Bool(false))
  }
}

///|
/// Python `a or b` for values.
fn value_or(
  a : Value?,
  b : () -> Value? raise SqlglotError,
) -> Value? raise SqlglotError {
  match a {
    Some(v) if v.truthy() => a
    _ => b()
  }
}

///|
/// Python `a or b` for optional expressions.
pub fn expr_or(
  a : Expr?,
  b : () -> Expr? raise SqlglotError,
) -> Expr? raise SqlglotError {
  match a {
    Some(_) => a
    None => b()
  }
}

///|
pub fn Parser::parse_describe(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_describe {
    Some(f) => f(self)
    None => self.parse_describe_base()
  }
}

///|
pub fn Parser::parse_describe_base(self : Parser) -> Expr? raise SqlglotError {
  let kind = if self.match_set(self.cfg.creatables) {
    Some(self.prev.text)
  } else {
    None
  }
  let mut style : String? = if self.match_text_set(self.cfg.describe_styles) {
    Some(self.prev_upper())
  } else {
    None
  }
  if self.match_(DOT) {
    style = None
    self.retreat(self.index - 2)
  }
  let format = if self.match_(FORMAT, advance=false) {
    self.parse_property()
  } else {
    None
  }
  let this = if self.match_keys(self.fns.statement_parsers, advance=false) {
    self.parse_statement()
  } else {
    self.parse_table(schema=true)
  }
  let properties = self.parse_properties()
  let expressions = match properties {
    Some(p) => Some(p.expressions())
    None => None
  }
  let partition = self.parse_partition()
  Some(
    self.expression(
      mk(Describe, [
        ("this", this),
        ("style", style),
        ("kind", kind),
        ("expressions", expressions),
        ("partition", partition),
        ("format", format),
        ("as_json", self.match_text_seq(["AS", "JSON"])),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_multitable_inserts(
  self : Parser,
  comments : Array[String],
) -> Expr raise SqlglotError {
  let kind = self.prev_upper()
  let expressions = []
  fn parse_conditional_insert() -> Expr? raise SqlglotError {
    let expression = if self.match_(WHEN) {
      let e = self.parse_disjunction()
      self.match_(THEN) |> ignore
      e
    } else {
      None
    }
    let else_ = self.match_(ELSE)
    if !self.match_(INTO) {
      return None
    }
    let this = self.parse_table(schema=true)
    let insert = self.expression(
      mk(Insert, [
        ("this", this),
        ("expression", self.parse_derived_table_values()),
      ]),
    )
    Some(
      self.expression(
        mk(ConditionalInsert, [
          ("this", insert),
          ("expression", expression),
          ("else_", else_),
        ]),
      ),
    )
  }

  let mut expression = parse_conditional_insert()
  while expression is Some(e) {
    expressions.push(e)
    expression = parse_conditional_insert()
  }
  self.expression(
    mk(MultitableInserts, [
      ("kind", kind),
      ("expressions", expressions),
      ("source", self.parse_table()),
    ]),
    comments~,
  )
}

///|
pub fn Parser::parse_insert(self : Parser) -> Expr? raise SqlglotError {
  let comments : Array[String] = []
  let hint = self.parse_hint()
  let overwrite = self.match_(OVERWRITE)
  let ignore_ = self.match_(IGNORE)
  let local = self.match_text("LOCAL")
  let mut alternative : Value? = None
  let mut is_function : Bool? = None
  let mut this : Expr? = None
  if self.match_text("DIRECTORY") {
    let t = self.parse_var_or_string()
    this = Some(
      self.expression(
        mk(Directory, [
          ("this", t),
          ("local", local),
          ("row_format", self.parse_row_format(match_row=true)),
        ]),
      ),
    )
  } else {
    if self.match_any([FIRST, ALL]) {
      comments.append(self.prev_comments)
      return Some(self.parse_multitable_inserts(comments))
    }
    if self.match_(OR) {
      alternative = if self.match_text_set(self.cfg.insert_alternatives) {
        Some(Str(self.prev.text))
      } else {
        Some(Bool(false))
      }
    }
    self.match_(INTO) |> ignore
    comments.append(self.prev_comments)
    self.match_(TABLE) |> ignore
    let f = self.match_(FUNCTION)
    is_function = Some(f)
    this = if f { self.parse_function() } else { self.parse_insert_table() }
  }
  let mut set_values : Expr? = None
  if self.match_(SET) {
    let columns = []
    let values = []
    fn parse_set_assignment() -> Expr? raise SqlglotError {
      let target = self.parse_column()
      match target {
        Some(t) if t.kind.is_a(Column) && self.match_(EQ) => {
          let value = if self.dialect.cfg.supports_values_default &&
            self.match_(DEFAULT) {
            Some(var_(self.prev_upper()))
          } else {
            self.parse_disjunction()
          }
          match value {
            Some(v) => {
              match t.this() {
                Some(c) => columns.push(c)
                None => ()
              }
              values.push(v)
              return Some(v)
            }
            None => ()
          }
        }
        _ => ()
      }
      self.raise_error("Expected column assignment in INSERT ... SET")
      None
    }

    self.parse_csv(parse_set_assignment) |> ignore
    this = Some(
      self.expression(mk(Schema, [("this", this), ("expressions", columns)])),
    )
    let alias = self.parse_table_alias()
    set_values = Some(
      self.expression(
        mk(Values, [
          ("expressions", [mk(Tuple, [("expressions", values)])]),
          ("alias", alias),
        ]),
      ),
    )
  }
  let returning = self.parse_returning()
  let stored = self.andv(self.match_text("STORED"), () => {
    Some(self.parse_stored())
  })
  let by_name = self.match_text_seq(["BY", "NAME"])
  let exists = self.parse_exists()
  let mut replace_where : Expr? = None
  let mut replace_using : Array[Expr]? = None
  if self.match_(REPLACE) {
    if self.match_(WHERE) {
      replace_where = self.parse_disjunction()
    } else if self.match_(USING) {
      replace_using = Some(self.parse_using_identifiers())
    }
  }
  let partition = self.andv(self.match_(PARTITION_BY), () => {
    self.parse_partitioned_by()
  })
  let settings = self.andv(self.match_text("SETTINGS"), () => {
    Some(self.parse_settings_property())
  })
  let default = self.match_text_seq(["DEFAULT", "VALUES"])
  let expression = expr_or(set_values, () => {
    expr_or(self.parse_derived_table_values(allow_value_synonym=true), () => {
      self.parse_ddl_select()
    })
  })
  let conflict = self.parse_on_conflict()
  let returning = expr_or(returning, () => self.parse_returning())
  let source = self.andv(self.match_(TABLE), () => self.parse_table())
  Some(
    self.expression(
      mk(Insert, [
        ("hint", hint),
        ("is_function", is_function),
        ("this", this),
        ("stored", stored),
        ("by_name", by_name),
        ("exists", exists),
        ("where", replace_where),
        ("using", replace_using),
        ("partition", partition),
        ("settings", settings),
        ("default", default),
        ("expression", expression),
        ("conflict", conflict),
        ("returning", returning),
        ("overwrite", overwrite),
        ("alternative", alternative),
        ("ignore", ignore_),
        ("source", source),
      ]),
      comments~,
    ),
  )
}

///|
pub fn Parser::parse_insert_table(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_insert_table {
    Some(f) => f(self)
    None => self.parse_insert_table_base()
  }
}

///|
pub fn Parser::parse_insert_table_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let this = self.parse_table(schema=true, parse_partition=true)
  match this {
    Some(t) if t.kind == Table && self.match_(ALIAS, advance=false) =>
      t.set("alias", self.parse_table_alias())
    _ => ()
  }
  this
}

///|
pub fn Parser::parse_kill(self : Parser) -> Expr? raise SqlglotError {
  let kind = if self.match_texts(["CONNECTION", "QUERY"]) {
    Some(var_(self.prev.text))
  } else {
    None
  }
  Some(
    self.expression(mk(Kill, [("this", self.parse_primary()), ("kind", kind)])),
  )
}

///|
pub fn Parser::parse_on_conflict(self : Parser) -> Expr? raise SqlglotError {
  let conflict = self.match_text_seq(["ON", "CONFLICT"])
  let duplicate = self.match_text_seq(["ON", "DUPLICATE", "KEY"])
  if !conflict && !duplicate {
    return None
  }
  let mut conflict_keys : Array[Expr]? = None
  let mut constraint : Expr? = None
  if conflict {
    if self.match_text_seq(["ON", "CONSTRAINT"]) {
      constraint = self.parse_id_var()
    } else if self.match_(L_PAREN) {
      conflict_keys = Some(self.parse_csv(() => self.parse_indexed_column()))
      self.match_r_paren()
    }
  }
  let index_predicate = self.parse_where()
  let action = self.parse_var_from_options(self.cfg.conflict_actions)
  let expressions = if self.prev.token_type == UPDATE {
    self.match_(SET) |> ignore
    Some(self.parse_csv(() => self.parse_update_assignment()))
  } else {
    None
  }
  Some(
    self.expression(
      mk(OnConflict, [
        ("duplicate", duplicate),
        ("expressions", expressions),
        ("action", action),
        ("conflict_keys", conflict_keys),
        ("index_predicate", index_predicate),
        ("constraint", constraint),
        ("where", self.parse_where()),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_returning(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(RETURNING) {
    return None
  }
  let expressions = self.parse_csv(() => self.parse_expression())
  Some(
    self.expression(
      mk(Returning, [
        ("expressions", expressions),
        ("into", self.andv(self.match_(INTO), () => self.parse_table_part())),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_row(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(FORMAT) {
    return None
  }
  self.parse_row_format()
}

///|
pub fn Parser::parse_serde_properties(
  self : Parser,
  with_? : Bool = false,
) -> Expr? raise SqlglotError {
  let index = self.index
  let with_ = with_ || self.match_text("WITH")
  if !self.match_(SERDE_PROPERTIES) {
    self.retreat(index)
    return None
  }
  Some(
    self.expression(
      mk(SerdeProperties, [
        ("expressions", self.parse_wrapped_properties()),
        ("with_", with_),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_row_format(
  self : Parser,
  match_row? : Bool = false,
) -> Expr? raise SqlglotError {
  if match_row && !self.match_pair(ROW, FORMAT) {
    return None
  }
  if self.match_text("SERDE") {
    let this = self.parse_string()
    let serde_properties = self.parse_serde_properties()
    return Some(
      self.expression(
        mk(RowFormatSerdeProperty, [
          ("this", this),
          ("serde_properties", serde_properties),
        ]),
      ),
    )
  }
  self.match_text("DELIMITED") |> ignore
  let e = mk0(RowFormatDelimitedProperty)
  if self.match_text_seq(["FIELDS", "TERMINATED", "BY"]) {
    e.set("fields", self.parse_string())
    if self.match_text_seq(["ESCAPED", "BY"]) {
      e.set("escaped", self.parse_string())
    }
  }
  if self.match_text_seq(["COLLECTION", "ITEMS", "TERMINATED", "BY"]) {
    e.set("collection_items", self.parse_string())
  }
  if self.match_text_seq(["MAP", "KEYS", "TERMINATED", "BY"]) {
    e.set("map_keys", self.parse_string())
  }
  if self.match_text_seq(["LINES", "TERMINATED", "BY"]) {
    e.set("lines", self.parse_string())
  }
  if self.match_text_seq(["NULL", "DEFINED", "AS"]) {
    e.set("null", self.parse_string())
  }
  Some(self.expression(e))
}

///|
pub fn Parser::parse_load(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text("DATA") {
    let local = self.match_text("LOCAL")
    self.match_text("INPATH") |> ignore
    let inpath = self.parse_string()
    let overwrite = self.match_(OVERWRITE)
    let mut temp : Bool? = None
    if self.match_(INTO) {
      temp = Some(self.match_(TEMPORARY))
      self.match_(TABLE) |> ignore
    }
    let this = self.parse_table(schema=true)
    let files = self.andv(self.match_text_seq(["FROM", "FILES"]), () => {
      Some(mk(Properties, [("expressions", self.parse_wrapped_properties())]))
    })
    let partition = self.parse_partition()
    let input_format = self.andv(self.match_text("INPUTFORMAT"), () => {
      self.parse_string()
    })
    let serde = self.andv(self.match_text("SERDE"), () => self.parse_string())
    return Some(
      self.expression(
        mk(LoadData, [
          ("this", this),
          ("local", local),
          ("overwrite", overwrite),
          ("temp", temp),
          ("inpath", inpath),
          ("files", files),
          ("partition", partition),
          ("input_format", input_format),
          ("serde", serde),
        ]),
      ),
    )
  }
  Some(self.parse_as_command(self.prev))
}

///|
pub fn Parser::parse_delete(self : Parser) -> Expr? raise SqlglotError {
  let hint = self.parse_hint()
  let mut tables : Array[Expr]? = None
  if !self.match_(FROM, advance=false) {
    let t = self.parse_csv(() => self.parse_table())
    tables = if t.is_empty() { None } else { Some(t) }
  }
  let returning = self.parse_returning()
  let this = self.andv(self.match_(FROM), () => self.parse_table(joins=true))
  let using_ = self.andl(self.match_(USING), () => {
    self.parse_csv(() => self.parse_table(joins=true))
  })
  let cluster = self.andv(self.match_(ON), () => self.parse_on_property())
  let where_ = self.parse_where()
  let returning = expr_or(returning, () => self.parse_returning())
  let order = self.parse_order()
  let limit = self.parse_limit()
  Some(
    self.expression(
      mk(Delete, [
        ("hint", hint),
        ("tables", tables),
        ("this", this),
        ("using", using_),
        ("cluster", cluster),
        ("where", where_),
        ("returning", returning),
        ("order", order),
        ("limit", limit),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_update_assignment(
  self : Parser,
) -> Expr? raise SqlglotError {
  let mut this = self.parse_comparison()
  if self.match_(EQ) {
    let comments = self.prev_comments
    this = Some(
      self.expression(
        mk(EQ, [("this", this), ("expression", self.parse_disjunction())]),
        comments~,
      ),
    )
  }
  this
}

///|
pub fn Parser::parse_update(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_update {
    Some(f) => f(self)
    None => self.parse_update_base()
  }
}

///|
pub fn Parser::parse_update_base(self : Parser) -> Expr? raise SqlglotError {
  let hint = self.parse_hint()
  let e = mk(Update, [
    ("hint", hint),
    (
      "this",
      self.parse_table(joins=true, alias_tokens=self.cfg.update_alias_tokens),
    ),
  ])
  while self.curr.ok() {
    if self.match_(SET) {
      e.set("expressions", self.parse_csv(() => self.parse_update_assignment()))
    } else if self.match_(RETURNING, advance=false) {
      e.set("returning", self.parse_returning())
    } else if self.match_(FROM, advance=false) {
      let from_ = self.parse_from(joins=true)
      match from_ {
        Some(f) =>
          match f.this() {
            Some(table) =>
              if table.kind.is_a(Subquery) && self.match_(JOIN, advance=false) {
                let joins = self.parse_joins()
                table.set(
                  "joins",
                  if joins.is_empty() {
                    None
                  } else {
                    Some(joins)
                  },
                )
              }
            None => ()
          }
        None => ()
      }
      e.set("from_", from_)
    } else if self.match_(WHERE, advance=false) {
      e.set("where", self.parse_where())
    } else if self.match_(ORDER_BY, advance=false) {
      e.set("order", self.parse_order())
    } else if self.match_(LIMIT, advance=false) {
      e.set("limit", self.parse_limit())
    } else {
      break
    }
  }
  Some(self.expression(e))
}

///|
pub fn Parser::parse_use(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_use {
    Some(f) => f(self)
    None => self.parse_use_base()
  }
}

///|
pub fn Parser::parse_use_base(self : Parser) -> Expr? raise SqlglotError {
  let kind = self.parse_var_from_options(
    self.cfg.usables,
    raise_unmatched=false,
  )
  Some(
    self.expression(
      mk(Use, [("kind", kind), ("this", self.parse_table(schema=false))]),
    ),
  )
}

///|
pub fn Parser::parse_uncache(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(TABLE) {
    self.raise_error("Expecting TABLE after UNCACHE")
  }
  let exists = self.parse_exists()
  Some(
    self.expression(
      mk(Uncache, [("exists", exists), ("this", self.parse_table(schema=true))]),
    ),
  )
}

///|
pub fn Parser::parse_cache(self : Parser) -> Expr? raise SqlglotError {
  let lazy = self.match_text("LAZY")
  self.match_(TABLE) |> ignore
  let table = self.parse_table(schema=true)
  let options : Array[Expr?] = []
  if self.match_text("OPTIONS") {
    self.match_l_paren()
    let k = self.parse_string()
    self.match_(EQ) |> ignore
    let v = self.parse_string()
    options.push(k)
    options.push(v)
    self.match_r_paren()
  }
  self.match_(ALIAS) |> ignore
  Some(
    self.expression(
      mk(Cache, [
        ("this", table),
        ("lazy", lazy),
        ("options", options.filter_map(x => x)),
        ("expression", self.parse_select(nested=true)),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_partition(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_partition {
    Some(f) => f(self)
    None => self.parse_partition_base()
  }
}

///|
pub fn Parser::parse_partition_base(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text_set(self.cfg.partition_keywords) {
    return None
  }
  let sub = self.prev_upper() == "SUBPARTITION"
  Some(
    self.expression(
      mk(Partition, [
        ("subpartition", sub),
        ("expressions", self.parse_wrapped_csv(() => self.parse_disjunction())),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_value(
  self : Parser,
  values? : Bool = true,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_value {
    Some(f) => f(self, values)
    None => self.parse_value_base(values~)
  }
}

///|
pub fn Parser::parse_value_base(
  self : Parser,
  values? : Bool = true,
) -> Expr? raise SqlglotError {
  ignore(values)
  fn parse_value_expression() -> Expr? raise SqlglotError {
    if self.dialect.cfg.supports_values_default && self.match_(DEFAULT) {
      return Some(var_(self.prev_upper()))
    }
    self.parse_expression()
  }

  if self.match_(L_PAREN) {
    let expressions = self.parse_csv(parse_value_expression)
    self.match_r_paren()
    return Some(self.expression(mk(Tuple, [("expressions", expressions)])))
  }
  match self.parse_expression() {
    Some(e) => Some(self.expression(mk(Tuple, [("expressions", [e])])))
    None => None
  }
}

///|
pub fn Parser::parse_projections(
  self : Parser,
) -> (Array[Expr], Array[Expr]?) raise SqlglotError {
  match self.fns.hooks.parse_projections {
    Some(f) => f(self)
    None => (self.parse_expressions(), None)
  }
}

///|
pub fn Parser::parse_wrapped_select(
  self : Parser,
  table? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_wrapped_select {
    Some(f) => f(self, table)
    None => self.parse_wrapped_select_base(table~)
  }
}

///|
pub fn Parser::parse_wrapped_select_base(
  self : Parser,
  table? : Bool = false,
) -> Expr? raise SqlglotError {
  let mut this : Expr? = None
  if self.match_any([PIVOT, UNPIVOT]) {
    this = self.parse_simplified_pivot(
      is_unpivot=self.prev.token_type == UNPIVOT,
    )
  } else if self.match_(FROM) {
    let from_ = self.parse_from(
      joins=true,
      skip_from_token=true,
      consume_pipe=true,
    )
    let select = self.parse_select(from_?)
    match select {
      Some(s) => {
        if !s.has("from_") {
          s.set("from_", from_)
        }
        this = Some(s)
      }
      None => {
        let sel = select_star_from(from_)
        this = self.parse_query_modifiers(self.parse_set_operations(Some(sel)))
      }
    }
  } else {
    this = if table {
      self.parse_table(consume_pipe=true)
    } else {
      self.parse_select(nested=true, parse_set_operation=false)
    }
    match this {
      Some(t) if table && t.kind == Values && !t.alias().is_empty() => {
        let alias = t.arg("alias").unwrap().pop()
        this = Some(mk(Table, [("this", t), ("alias", alias)]))
      }
      _ => ()
    }
    this = self.parse_query_modifiers(self.parse_set_operations(this))
  }
  this
}

///|
/// `exp.select("*").from_(from_)`
pub fn select_star_from(from_ : Expr?) -> Expr {
  let sel = mk(Select, [("expressions", [mk0(Star)])])
  match from_ {
    Some(f) =>
      if f.kind == From {
        sel.set("from_", f)
      } else {
        sel.set("from_", mk1(From, f))
      }
    None => ()
  }
  sel
}
