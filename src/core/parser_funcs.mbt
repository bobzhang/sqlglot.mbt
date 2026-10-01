// Port of sqlglot/parser.py: function calls, lambdas, schemas, column definitions,
// constraints, brackets.

///|
pub fn Parser::parse_function_args(
  self : Parser,
  alias? : Bool = false,
) -> Array[Expr] raise SqlglotError {
  self.parse_csv(() => self.parse_lambda(alias~))
}

///|
pub fn Parser::parse_connector_function(
  self : Parser,
  connector : Kind,
) -> Expr? raise SqlglotError {
  let args = self.parse_function_args(alias=false)
  if args.is_empty() {
    self.raise_error("Expected at least one argument")
  }
  Some(mk1(Paren, combine_conditions(args, connector)))
}

///|
pub fn Parser::parse_function_call(
  self : Parser,
  functions? : Map[String, FuncBuilder],
  anonymous? : Bool = false,
  optional_parens? : Bool = true,
  any_token? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_function_call {
    Some(f) => f(self, functions, anonymous, optional_parens, any_token)
    None =>
      self.parse_function_call_base(
        functions?,
        anonymous~,
        optional_parens~,
        any_token~,
      )
  }
}

///|
pub fn Parser::parse_function_call_base(
  self : Parser,
  functions? : Map[String, FuncBuilder],
  anonymous? : Bool = false,
  optional_parens? : Bool = true,
  any_token? : Bool = false,
) -> Expr? raise SqlglotError {
  if !self.curr.ok() {
    return None
  }
  let comments = self.curr.comments
  let prev = self.prev
  let token = self.curr
  let token_type = self.curr.token_type
  let this_text = self.curr.text
  let upper = py_upper(self.curr.text)
  let after_dot = prev.token_type == DOT
  let no_paren_parser = self.fns.no_paren_function_parsers.get(upper)
  match no_paren_parser {
    Some(parser) if optional_parens &&
      !self.cfg.invalid_func_name_tokens.contains(token_type) &&
      !after_dot => {
      self.advance()
      return self.parse_window(parser(self))
    }
    _ => ()
  }
  if self.next.token_type != L_PAREN {
    if optional_parens &&
      self.cfg.no_paren_functions.contains(token_type) &&
      !after_dot {
      self.advance()
      return Some(self.expression(mk0(self.cfg.no_paren_functions[token_type])))
    }
    return None
  }
  if any_token {
    if self.cfg.reserved_tokens.contains(token_type) {
      return None
    }
  } else if !self.cfg.func_tokens.contains(token_type) {
    return None
  }
  self.advance(times=2)
  let func_parser = self.fns.function_parsers.get(upper)
  let mut result : Expr? = None
  match func_parser {
    Some(parser) if !anonymous => result = parser(self)
    _ => {
      match self.cfg.subquery_predicates.get(token_type) {
        Some(subquery_predicate) => {
          let mut expr : Expr? = None
          if self.cfg.subquery_tokens.contains(self.curr.token_type) {
            expr = self.parse_select()
            self.match_r_paren()
          } else if prev.ok() &&
            (prev.token_type == LIKE || prev.token_type == ILIKE) {
            self.advance(times=-1)
            expr = self.parse_bitwise()
          }
          match expr {
            Some(e) =>
              return Some(
                self.expression(mk1(subquery_predicate, e), comments~),
              )
            None => ()
          }
        }
        None => ()
      }
      let functions = match functions {
        Some(f) => f
        None => self.fns.functions
      }
      let function = functions.get(upper)
      let mut known_function = function is Some(_) && !anonymous
      let alias = !known_function ||
        self.cfg.functions_with_aliased_args.contains(upper)
      let mut args = self.parse_function_args(alias~)
      let post_func_comments = if self.curr.ok() {
        Some(self.curr.comments)
      } else {
        None
      }
      match post_func_comments {
        Some(pfc) if known_function && !pfc.is_empty() =>
          if pfc.iter().any(c => c.trim_start().has_prefix(sqlglot_anonymous)) {
            known_function = false
          }
        _ => ()
      }
      if alias && known_function {
        args = self.kv_to_prop_eq(args)
      }
      if known_function {
        let func_builder = function.unwrap()
        let func = func_builder(args, self)
        let func = self.validate_expression(func, nargs=args.length())
        if self.dialect.cfg.preserve_original_names {
          func.get_meta()["name"] = Str(this_text)
        }
        result = Some(func)
      } else {
        let this : Value = if token_type == IDENTIFIER {
          Node(
            mk(Identifier, [("this", this_text), ("quoted", true)]).update_positions_from_token(
              token,
            ),
          )
        } else {
          Str(this_text)
        }
        result = Some(
          self.expression(
            mk(Anonymous, [("this", this), ("expressions", args)]),
          ),
        )
      }
      result = Some(result.unwrap().update_positions_from_token(token))
    }
  }
  match result {
    Some(r) => r.add_comments(Some(comments))
    None => ()
  }
  if func_parser is Some(_) {
    self.match_(R_PAREN, expression?=result) |> ignore
  } else {
    self.match_r_paren(expression?=result)
  }
  self.parse_window(result)
}

///|
pub fn Parser::to_prop_eq(
  self : Parser,
  expression : Expr,
  index : Int,
) -> Expr raise SqlglotError {
  match self.fns.hooks.to_prop_eq {
    Some(f) => f(self, expression, index)
    None => expression
  }
}

///|
pub fn Parser::kv_to_prop_eq(
  self : Parser,
  expressions : Array[Expr],
  parse_map? : Bool = false,
) -> Array[Expr] raise SqlglotError {
  let transformed = []
  for index, e in expressions {
    let mut e = e
    if e.kind.is_any(self.cfg.key_value_definitions) {
      if e.kind.is_a(Alias) {
        e = self.expression(
          mk(PropertyEQ, [("this", e.arg("alias")), ("expression", e.this())]),
        )
      }
      if !e.kind.is_a(PropertyEQ) {
        let this = if parse_map {
          e.this()
        } else {
          match e.this() {
            Some(t) => Some(to_identifier(t.name()))
            None => Some(to_identifier(""))
          }
        }
        e = self.expression(
          mk(PropertyEQ, [("this", this), ("expression", e.expression())]),
        )
      }
      match e.this() {
        Some(t) if t.kind.is_a(Column) => t.replace(t.this()) |> ignore
        _ => ()
      }
    } else {
      e = self.to_prop_eq(e, index)
    }
    transformed.push(e)
  }
  transformed
}

///|
pub fn Parser::parse_function_properties(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_function_properties {
    Some(f) => f(self)
    None => self.parse_function_properties_base()
  }
}

///|
pub fn Parser::parse_function_properties_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let properties = []
  while true {
    let mut keyword = ""
    let prop = if self.match_text_keys(self.fns.property_parsers) {
      keyword = self.prev_upper()
      self.fns.property_parsers[keyword](self, Map([]))
    } else if self.match_(DEFAULT) &&
      self.match_text_keys(self.fns.property_parsers) {
      keyword = self.prev_upper()
      self.fns.property_parsers[keyword](self, { "default": true })
    } else {
      break
    }
    if !prop_value_is_some(prop) {
      self.raise_error("Failed to parse property '\{keyword}'")
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
  if properties.is_empty() {
    None
  } else {
    Some(self.expression(mk(Properties, [("expressions", properties)])))
  }
}

///|
pub fn Parser::parse_user_defined_function_expression(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_user_defined_function_expression {
    Some(f) => f(self)
    None => self.parse_statement()
  }
}

///|
pub fn Parser::parse_function_parameter(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_function_parameter {
    Some(f) => f(self)
    None => self.parse_column_def(self.parse_id_var(), computed_column=false)
  }
}

///|
pub fn Parser::parse_user_defined_function(
  self : Parser,
  kind? : TokenType,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_user_defined_function {
    Some(f) => f(self, kind)
    None => self.parse_user_defined_function_base(kind?)
  }
}

///|
pub fn Parser::parse_user_defined_function_base(
  self : Parser,
  kind? : TokenType,
) -> Expr? raise SqlglotError {
  ignore(kind)
  let this = self.parse_table_parts(schema=true)
  if !self.match_(L_PAREN) {
    return this
  }
  let expressions = self.parse_csv(() => self.parse_function_parameter())
  self.match_r_paren()
  Some(
    self.expression(
      mk(UserDefinedFunction, [
        ("this", this),
        ("expressions", expressions),
        ("wrapped", true),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_macro_overloads(
  self : Parser,
  this : Expr,
  first_body : Expr,
  first_is_table : Bool,
) -> Expr? raise SqlglotError {
  let exprs = this.expressions()
  let overloads = [
    self.expression(
      mk(MacroOverload, [
        ("this", first_body),
        ("expressions", if exprs.is_empty() { None } else { Some(exprs) }),
        ("is_table", first_is_table),
      ]),
    ),
  ]
  this.set("expressions", null_arg)
  this.set("wrapped", false)
  while self.match_(COMMA) {
    if !self.match_(L_PAREN) {
      break
    }
    let params = self.parse_csv(() => self.parse_function_parameter())
    self.match_r_paren()
    if !self.match_(ALIAS) {
      break
    }
    let is_table = self.match_(TABLE)
    let body = self.parse_expression()
    let macro_ = mk(MacroOverload, [
      ("this", body),
      ("expressions", params),
      ("is_table", is_table),
    ])
    overloads.push(self.expression(macro_))
  }
  Some(self.expression(mk(MacroOverloads, [("expressions", overloads)])))
}

///|
pub fn Parser::parse_introducer(
  self : Parser,
  token : Token,
) -> Expr? raise SqlglotError {
  match self.parse_primary() {
    Some(literal) =>
      Some(
        self.expression(
          mk(Introducer, [("this", token.text), ("expression", literal)]),
          token~,
        ),
      )
    None => Some(self.identifier_expression(token~))
  }
}

///|
pub fn Parser::parse_session_parameter(
  self : Parser,
) -> Expr? raise SqlglotError {
  let mut kind : String? = None
  let mut this = expr_or(self.parse_id_var(), () => self.parse_primary())
  if this is Some(t) && self.match_(DOT) {
    kind = Some(t.name())
    this = expr_or(self.parse_var(), () => self.parse_primary())
  }
  Some(self.expression(mk(SessionParameter, [("this", this), ("kind", kind)])))
}

///|
pub fn Parser::parse_lambda_arg(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_lambda_arg {
    Some(f) => f(self)
    None => self.parse_id_var()
  }
}

///|
pub fn Parser::parse_lambda(
  self : Parser,
  alias? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_lambda {
    Some(f) => f(self, alias)
    None => self.parse_lambda_base(alias~)
  }
}

///|
pub fn Parser::parse_lambda_base(
  self : Parser,
  alias? : Bool = false,
) -> Expr? raise SqlglotError {
  let next_token_type = self.next.token_type
  if self.cfg.lambda_arg_terminators.contains(next_token_type) {
    match self.parse_atom() {
      Some(atom) => return Some(atom)
      None => ()
    }
  }
  let index = self.index
  if self.match_(L_PAREN) {
    let expressions = self.parse_csv(() => self.parse_lambda_arg())
    if !self.match_(R_PAREN) {
      self.retreat(index)
    } else if self.match_keys(self.fns.lambdas) {
      return self.fns.lambdas[self.prev.token_type](self, expressions)
    } else {
      self.retreat(index)
    }
  } else if self.cfg.typed_lambda_args ||
    self.fns.lambdas.contains(next_token_type) {
    let expressions = [self.parse_lambda_arg()].filter_map(x => x)
    if self.match_keys(self.fns.lambdas) {
      return self.fns.lambdas[self.prev.token_type](self, expressions)
    }
    self.retreat(index)
  }
  let this = if self.match_(DISTINCT) {
    Some(
      self.expression(
        mk(Distinct, [
          ("expressions", self.parse_csv(() => self.parse_disjunction())),
        ]),
      ),
    )
  } else {
    self.match_(ALL) |> ignore
    self.parse_select_or_expression(alias~)
  }
  self.parse_limit(
    this=self.parse_respect_or_ignore_nulls(
      self.parse_order(
        this=self.parse_having_max(self.parse_respect_or_ignore_nulls(this)),
      ),
    ),
  )
}

///|
pub fn Parser::parse_schema(
  self : Parser,
  this? : Expr?,
) -> Expr? raise SqlglotError {
  let this : Expr? = match this {
    Some(t) => t
    None => None
  }
  let index = self.index
  if !self.match_(L_PAREN) {
    return this
  }
  if self.match_set(self.cfg.select_start_tokens) {
    self.retreat(index)
    return this
  }
  let args = self.parse_csv(() => {
    expr_or(self.parse_constraint(), () => self.parse_field_def())
  })
  self.match_r_paren()
  Some(self.expression(mk(Schema, [("this", this), ("expressions", args)])))
}

///|
pub fn Parser::parse_field_def(self : Parser) -> Expr? raise SqlglotError {
  self.parse_column_def(self.parse_field(any_token=true))
}

///|
pub fn Parser::parse_column_def(
  self : Parser,
  this : Expr?,
  computed_column? : Bool = true,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_column_def {
    Some(f) => f(self, this, computed_column)
    None => self.parse_column_def_base(this, computed_column~)
  }
}

///|
pub fn Parser::parse_column_def_base(
  self : Parser,
  this : Expr?,
  computed_column? : Bool = true,
) -> Expr? raise SqlglotError {
  let mut this = this
  match this {
    Some(t) if t.kind.is_a(Column) => this = t.this()
    _ => ()
  }
  if !computed_column {
    self.match_(ALIAS) |> ignore
  }
  let mut kind = self.parse_types(schema=true)
  if self.match_text_seq(["FOR", "ORDINALITY"]) {
    return Some(
      self.expression(mk(ColumnDef, [("this", this), ("ordinality", true)])),
    )
  }
  let constraints = []
  if (kind is None && self.match_(ALIAS)) ||
    self.match_texts(["ALIAS", "MATERIALIZED"]) {
    let mut persisted = self.prev_upper() == "MATERIALIZED"
    let expression = self.parse_disjunction()
    if !persisted {
      if self.match_text("PERSISTED") {
        persisted = true
      } else if self.match_texts(["STORED", "VIRTUAL"]) {
        persisted = self.prev_upper() == "STORED"
      }
    }
    let data_type = if self.match_text("AUTO") {
      Some(mk1(Var, "AUTO"))
    } else {
      self.parse_types()
    }
    let constraint_kind = mk(ComputedColumnConstraint, [
      ("this", expression),
      ("persisted", persisted),
      ("data_type", data_type),
      ("not_null", self.match_pair(NOT, NULL)),
    ])
    constraints.push(
      self.expression(mk(ColumnConstraint, [("kind", constraint_kind)])),
    )
  } else if kind is None && self.match_any([IN, OUT], advance=false) {
    let input_ = self.match_(IN)
    let output = self.match_(OUT)
    let in_out_constraint = self.expression(
      mk(InOutColumnConstraint, [("input_", input_), ("output", output)]),
    )
    constraints.push(in_out_constraint)
    kind = self.parse_types()
  } else if kind is Some(_) &&
    self.match_(ALIAS, advance=false) &&
    (
      !self.cfg.wrapped_transform_column_constraint ||
      self.next.token_type == L_PAREN
    ) {
    self.advance()
    let expr = self.parse_disjunction()
    let persisted : Bool = self.match_texts(["STORED", "VIRTUAL"]) &&
      self.prev_upper() == "STORED"
    constraints.push(
      self.expression(
        mk(ColumnConstraint, [
          (
            "kind",
            mk(ComputedColumnConstraint, [
              ("this", expr),
              ("persisted", persisted),
            ]),
          ),
        ]),
      ),
    )
  }
  while true {
    match self.parse_column_constraint() {
      Some(c) => constraints.push(c)
      None => break
    }
  }
  if kind is None && constraints.is_empty() {
    return this
  }
  let mut position : Expr? = None
  if self.match_texts(["FIRST", "AFTER"]) {
    let pos = self.prev.text
    position = Some(
      self.expression(
        mk(ColumnPosition, [("this", self.parse_column()), ("position", pos)]),
      ),
    )
  }
  Some(
    self.expression(
      mk(ColumnDef, [
        ("this", this),
        ("kind", kind),
        ("constraints", constraints),
        ("position", position),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_auto_increment(self : Parser) -> Expr? raise SqlglotError {
  let mut start : Expr? = None
  let mut increment : Expr? = None
  let mut order : Bool? = None
  if self.match_(L_PAREN, advance=false) {
    let args = self.parse_wrapped_csv(() => self.parse_bitwise())
    start = args.get(0)
    increment = args.get(1)
  }
  while true {
    if self.match_text("START") {
      start = self.parse_bitwise()
    } else if self.match_text("INCREMENT") {
      increment = self.parse_bitwise()
    } else if self.match_text("ORDER") {
      order = Some(true)
    } else if self.match_text("NOORDER") {
      order = Some(false)
    } else {
      break
    }
  }
  if start is Some(_) || increment is Some(_) || order is Some(_) {
    return Some(
      mk(GeneratedAsIdentityColumnConstraint, [
        ("start", start),
        ("increment", increment),
        ("this", false),
        ("order", order),
      ]),
    )
  }
  Some(mk0(AutoIncrementColumnConstraint))
}

///|
pub fn Parser::parse_check_constraint(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_check_constraint {
    Some(f) => f(self)
    None => self.parse_check_constraint_base()
  }
}

///|
pub fn Parser::parse_check_constraint_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  if !self.match_(L_PAREN, advance=false) {
    return None
  }
  let this = self.parse_wrapped(() => self.parse_assignment())
  Some(
    self.expression(
      mk(CheckColumnConstraint, [
        ("this", this),
        ("enforced", self.match_text("ENFORCED")),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_auto_property(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_text("REFRESH") {
    self.retreat(self.index - 1)
    return None
  }
  Some(self.expression(mk1(AutoRefreshProperty, self.parse_var(upper=true))))
}

///|
pub fn Parser::parse_compress(self : Parser) -> Expr? raise SqlglotError {
  if self.match_(L_PAREN, advance=false) {
    return Some(
      self.expression(
        mk1(
          CompressColumnConstraint,
          self.parse_wrapped_csv(() => self.parse_bitwise()),
        ),
      ),
    )
  }
  Some(self.expression(mk1(CompressColumnConstraint, self.parse_bitwise())))
}

///|
pub fn Parser::parse_generated_as_identity(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_generated_as_identity {
    Some(f) => f(self)
    None => self.parse_generated_as_identity_base()
  }
}

///|
pub fn Parser::parse_generated_as_identity_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let this = if self.match_text_seq(["BY", "DEFAULT"]) {
    let on_null = self.match_pair(ON, NULL)
    self.expression(
      mk(GeneratedAsIdentityColumnConstraint, [
        ("this", false),
        ("on_null", on_null),
      ]),
    )
  } else {
    self.match_text("ALWAYS") |> ignore
    self.expression(mk(GeneratedAsIdentityColumnConstraint, [("this", true)]))
  }
  self.match_(ALIAS) |> ignore
  if self.match_text("ROW") {
    let start = self.match_text("START")
    if !start {
      self.match_(END) |> ignore
    }
    let hidden = self.match_text("HIDDEN")
    return Some(
      self.expression(
        mk(GeneratedAsRowColumnConstraint, [
          ("start", start),
          ("hidden", hidden),
        ]),
      ),
    )
  }
  let identity = self.match_text("IDENTITY")
  if self.match_(L_PAREN) {
    if self.match_text_seq(["START", "WITH"]) {
      this.set("start", self.parse_bitwise())
    }
    if self.match_text_seq(["INCREMENT", "BY"]) {
      this.set("increment", self.parse_bitwise())
    }
    if self.match_text("MINVALUE") {
      this.set("minvalue", self.parse_bitwise())
    }
    if self.match_text("MAXVALUE") {
      this.set("maxvalue", self.parse_bitwise())
    }
    if self.match_text("CYCLE") {
      this.set("cycle", true)
    } else if self.match_text_seq(["NO", "CYCLE"]) {
      this.set("cycle", false)
    }
    if !identity {
      this.set("expression", self.parse_range())
    } else if !this.has("start") && self.match_(NUMBER, advance=false) {
      let args = self.parse_csv(() => self.parse_bitwise())
      this.set("start", args.get(0))
      this.set("increment", args.get(1))
    }
    self.match_r_paren()
  }
  Some(this)
}

///|
pub fn Parser::parse_inline(self : Parser) -> Expr? raise SqlglotError {
  self.match_text("LENGTH") |> ignore
  Some(self.expression(mk1(InlineLengthColumnConstraint, self.parse_bitwise())))
}

///|
pub fn Parser::parse_not_constraint(self : Parser) -> Expr? raise SqlglotError {
  if self.match_text("NULL") {
    return Some(self.expression(mk0(NotNullColumnConstraint)))
  }
  if self.match_text("CASESPECIFIC") {
    return Some(
      self.expression(mk(CaseSpecificColumnConstraint, [("not_", true)])),
    )
  }
  if self.match_text_seq(["FOR", "REPLICATION"]) {
    return Some(self.expression(mk0(NotForReplicationColumnConstraint)))
  }
  self.retreat(self.index - 1)
  None
}

///|
pub fn Parser::parse_column_constraint(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_column_constraint {
    Some(f) => f(self)
    None => self.parse_column_constraint_base()
  }
}

///|
pub fn Parser::parse_column_constraint_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let this = if self.match_(CONSTRAINT) { self.parse_id_var() } else { None }
  let procedure_option_follows = self.match_(WITH, advance=false) &&
    self.next.ok() &&
    self.cfg.procedure_options.contains(py_upper(self.next.text))
  let index = self.index
  if !procedure_option_follows &&
    self.match_text_keys(self.fns.constraint_parsers) {
    let constraint = self.fns.constraint_parsers[self.prev_upper()](self)
    match constraint {
      None => {
        self.retreat(index)
        return None
      }
      Some(c) =>
        return Some(
          self.expression(mk(ColumnConstraint, [("this", this), ("kind", c)])),
        )
    }
  }
  if self.match_text_seq(["CHARACTER", "SET"]) {
    let kind = self.expression(
      mk1(CharacterSetColumnConstraint, self.parse_var_or_string()),
    )
    return Some(
      self.expression(mk(ColumnConstraint, [("this", this), ("kind", kind)])),
    )
  }
  this
}

///|
pub fn Parser::parse_constraint(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_constraint {
    Some(f) => f(self)
    None => self.parse_constraint_base()
  }
}

///|
pub fn Parser::parse_constraint_base(self : Parser) -> Expr? raise SqlglotError {
  if !self.match_(CONSTRAINT) {
    return self.parse_unnamed_constraint(
      constraints=self.cfg.schema_unnamed_constraints,
    )
  }
  let this = self.parse_id_var()
  Some(
    self.expression(
      mk(Constraint, [
        ("this", this),
        ("expressions", self.parse_unnamed_constraints()),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_unnamed_constraints(
  self : Parser,
) -> Array[Expr] raise SqlglotError {
  let constraints = []
  while true {
    match
      expr_or(self.parse_unnamed_constraint(), () => self.parse_function()) {
      Some(c) => constraints.push(c)
      None => break
    }
  }
  constraints
}

///|
pub fn Parser::parse_unnamed_constraint(
  self : Parser,
  constraints? : @set.Set[String],
) -> Expr? raise SqlglotError {
  let index = self.index
  if self.match_(IDENTIFIER, advance=false) {
    return None
  }
  let matched = match constraints {
    Some(c) => self.match_text_set(c)
    None => self.match_text_keys(self.fns.constraint_parsers)
  }
  if !matched {
    return None
  }
  let constraint_key = self.prev_upper()
  match self.fns.constraint_parsers.get(constraint_key) {
    None => {
      self.raise_error(
        "No parser found for schema constraint \{constraint_key}.",
      )
      None
    }
    Some(parser) => {
      let result = parser(self)
      if result is None {
        self.retreat(index)
      }
      result
    }
  }
}

///|
pub fn Parser::parse_unique_key(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_unique_key {
    Some(f) => f(self)
    None => self.parse_unique_key_base()
  }
}

///|
pub fn Parser::parse_unique_key_base(self : Parser) -> Expr? raise SqlglotError {
  if self.curr.ok() &&
    self.curr.token_type != IDENTIFIER &&
    self.fns.constraint_parsers.contains(py_upper(self.curr.text)) {
    return None
  }
  self.parse_id_var(any_token=false)
}

///|
pub fn Parser::parse_unique(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_unique {
    Some(f) => f(self)
    None => self.parse_unique_base()
  }
}

///|
pub fn Parser::parse_unique_base(self : Parser) -> Expr? raise SqlglotError {
  self.match_texts(["KEY", "INDEX"]) |> ignore
  let nulls = self.match_text_seq(["NULLS", "NOT", "DISTINCT"])
  let this = self.parse_schema(this=self.parse_unique_key())
  let index_type : Value = if self.match_(USING) {
    match self.advance_any() {
      Some(_) => Str(self.prev.text)
      None => Bool(false)
    }
  } else {
    Bool(false)
  }
  let on_conflict = self.parse_on_conflict()
  let options = self.parse_key_constraint_options()
  Some(
    self.expression(
      mk(UniqueColumnConstraint, [
        ("nulls", nulls),
        ("this", this),
        ("index_type", index_type),
        ("on_conflict", on_conflict),
        ("options", options),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_key_constraint_options(
  self : Parser,
) -> Array[String] raise SqlglotError {
  let options = []
  while true {
    if !self.curr.ok() {
      break
    }
    if self.match_(ON) {
      let mut action = "None"
      let on = match self.advance_any() {
        Some(_) => self.prev.text
        None => "None"
      }
      if self.match_text_seq(["NO", "ACTION"]) {
        action = "NO ACTION"
      } else if self.match_text("CASCADE") {
        action = "CASCADE"
      } else if self.match_text("RESTRICT") {
        action = "RESTRICT"
      } else if self.match_pair(SET, NULL) {
        action = "SET NULL"
      } else if self.match_pair(SET, DEFAULT) {
        action = "SET DEFAULT"
      } else {
        self.raise_error("Invalid key constraint")
      }
      options.push("ON \{on} \{action}")
    } else {
      match
        self.parse_var_from_options(
          self.cfg.key_constraint_options,
          raise_unmatched=false,
        ) {
        Some(v) => options.push(v.name())
        None => break
      }
    }
  }
  options
}

///|
pub fn Parser::parse_references(
  self : Parser,
  match_? : Bool = true,
) -> Expr? raise SqlglotError {
  if match_ && !self.match_(REFERENCES) {
    return None
  }
  let this = self.parse_table(schema=true)
  let options = self.parse_key_constraint_options()
  Some(self.expression(mk(Reference, [("this", this), ("options", options)])))
}

///|
pub fn Parser::parse_foreign_key(self : Parser) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_foreign_key {
    Some(f) => f(self)
    None => self.parse_foreign_key_base()
  }
}

///|
pub fn Parser::parse_foreign_key_base(
  self : Parser,
) -> Expr? raise SqlglotError {
  let expressions = if !self.match_(REFERENCES, advance=false) {
    Some(self.parse_wrapped_id_vars())
  } else {
    None
  }
  let reference = self.parse_references()
  let on_options : Array[(String, String)] = []
  while self.match_(ON) {
    if !self.match_any([DELETE, UPDATE]) {
      self.raise_error("Expected DELETE or UPDATE")
    }
    let kind = py_lower(self.prev.text)
    let action = if self.match_text_seq(["NO", "ACTION"]) {
      "NO ACTION"
    } else if self.match_(SET) {
      self.match_any([NULL, DEFAULT]) |> ignore
      "SET " + self.prev_upper()
    } else {
      self.advance()
      self.prev_upper()
    }
    on_options.push((kind, action))
  }
  let e = mk(ForeignKey, [
    ("expressions", expressions),
    ("reference", reference),
    ("options", self.parse_key_constraint_options()),
  ])
  for kv in on_options {
    e.set(kv.0, kv.1)
  }
  Some(self.expression(e))
}

///|
pub fn Parser::parse_primary_key_part(
  self : Parser,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_primary_key_part {
    Some(f) => f(self)
    None => self.parse_field()
  }
}

///|
pub fn Parser::parse_period_for_system_time(
  self : Parser,
) -> Expr? raise SqlglotError {
  if !self.match_text_seq(["FOR", "SYSTEM_TIME"]) {
    self.retreat(self.index - 1)
    return None
  }
  let id_vars = self.parse_wrapped_id_vars()
  Some(
    self.expression(
      mk(PeriodForSystemTimeConstraint, [
        ("this", id_vars.get(0)),
        ("expression", id_vars.get(1)),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_primary_key(
  self : Parser,
  wrapped_optional? : Bool = false,
  in_props? : Bool = false,
  named_primary_key? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_primary_key {
    Some(f) => f(self, wrapped_optional, in_props, named_primary_key)
    None =>
      self.parse_primary_key_base(
        wrapped_optional~,
        in_props~,
        named_primary_key~,
      )
  }
}

///|
pub fn Parser::parse_primary_key_base(
  self : Parser,
  wrapped_optional? : Bool = false,
  in_props? : Bool = false,
  named_primary_key? : Bool = false,
) -> Expr? raise SqlglotError {
  let desc : Bool? = if self.match_any([ASC, DESC]) {
    Some(self.prev.token_type == DESC)
  } else {
    None
  }
  let mut this : Expr? = None
  if named_primary_key &&
    !self.fns.constraint_parsers.contains(py_upper(self.curr.text)) &&
    self.next.ok() &&
    self.next.token_type == L_PAREN {
    this = self.parse_id_var()
  }
  if !in_props && !self.match_(L_PAREN, advance=false) {
    return Some(
      self.expression(
        mk(PrimaryKeyColumnConstraint, [
          ("desc", desc),
          ("options", self.parse_key_constraint_options()),
        ]),
      ),
    )
  }
  let expressions = self.parse_wrapped_csv(
    () => self.parse_primary_key_part(),
    optional=wrapped_optional,
  )
  let include = self.parse_index_params()
  let options = self.parse_key_constraint_options()
  Some(
    self.expression(
      mk(PrimaryKey, [
        ("this", this),
        ("expressions", expressions),
        ("include", include),
        ("options", options),
      ]),
    ),
  )
}

///|
pub fn Parser::parse_bracket_key_value(
  self : Parser,
  is_map? : Bool = false,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_bracket_key_value {
    Some(f) => f(self, is_map)
    None =>
      self.parse_slice(
        self.parse_alias(self.parse_disjunction(), explicit=true),
      )
  }
}

///|
pub fn Parser::parse_odbc_datetime_literal(
  self : Parser,
) -> Expr raise SqlglotError {
  self.match_(VAR) |> ignore
  let kind = match
    self.cfg.odbc_datetime_literals.get(py_lower(self.prev.text)) {
    Some(k) => k
    None => raise ParseError("Unknown ODBC literal", [])
  }
  let expression = self.expression(mk1(kind, self.parse_string()))
  if !self.match_(R_BRACE) {
    self.raise_error("Expected }")
  }
  expression
}

///|
pub fn build_array_constructor(
  kind : Kind,
  args : Array[Expr],
  bracket_kind : TokenType,
  dialect : Dialect,
) -> Expr {
  let array_exp = mk(kind, [("expressions", args)])
  if kind == Array && dialect.cfg.has_distinct_array_constructors {
    array_exp.set("bracket_notation", bracket_kind == L_BRACKET)
  }
  array_exp
}

///|
pub fn Parser::parse_bracket(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  match self.fns.hooks.parse_bracket {
    Some(f) => f(self, this)
    None => self.parse_bracket_base(this)
  }
}

///|
pub fn Parser::parse_bracket_base(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if !self.match_set(self.cfg.brackets) {
    return this
  }
  let parse_map = if self.cfg.map_keys_are_arbitrary_expressions {
    let i = self.index - 2
    i >= 0 && i < self.tokens.length() && py_upper(self.tokens[i].text) == "MAP"
  } else {
    false
  }
  let bracket_kind = self.prev.token_type
  if bracket_kind == L_BRACE &&
    self.curr.ok() &&
    self.curr.token_type == VAR &&
    self.cfg.odbc_datetime_literals.contains(py_lower(self.curr.text)) {
    return Some(self.parse_odbc_datetime_literal())
  }
  let expressions = self.parse_csv(() => {
    self.parse_bracket_key_value(is_map=bracket_kind == L_BRACE)
  })
  if bracket_kind == L_BRACKET && !self.match_(R_BRACKET) {
    self.raise_error("Expected ]")
  } else if bracket_kind == L_BRACE && !self.match_(R_BRACE) {
    self.raise_error("Expected }")
  }
  let mut this = this
  if bracket_kind == L_BRACE {
    this = Some(
      self.expression(
        mk(Struct, [
          ("expressions", self.kv_to_prop_eq(expressions, parse_map~)),
        ]),
      ),
    )
  } else {
    match this {
      None =>
        this = Some(
          build_array_constructor(
            Array,
            expressions,
            bracket_kind,
            self.dialect,
          ),
        )
      Some(t) => {
        match self.cfg.array_constructors.get(py_upper(t.name())) {
          Some(constructor_type) =>
            return Some(
              build_array_constructor(
                constructor_type,
                expressions,
                bracket_kind,
                self.dialect,
              ),
            )
          None => ()
        }
        let expressions = apply_index_offset(
          t,
          expressions,
          -self.dialect.cfg.index_offset,
          self.dialect,
        )
        let comments = t.pop_comments()
        this = Some(
          self.expression(
            mk(Bracket, [("this", t), ("expressions", expressions)]),
            comments~,
          ),
        )
      }
    }
  }
  self.add_comments(this)
  self.parse_bracket(this)
}

///|
pub fn Parser::parse_slice(
  self : Parser,
  this : Expr?,
) -> Expr? raise SqlglotError {
  if !self.match_(COLON) {
    return this
  }
  let end = if self.match_pair(DASH, COLON, advance=false) {
    self.advance()
    Some(mk1(Neg, literal_number("1")))
  } else {
    self.parse_assignment()
  }
  let step = if self.match_(COLON) { self.parse_unary() } else { None }
  Some(
    self.expression(
      mk(Slice, [("this", this), ("expression", end), ("step", step)]),
    ),
  )
}

///|
pub fn Parser::identifier_expression(
  self : Parser,
  token? : Token,
  quoted? : Bool,
) -> Expr raise SqlglotError {
  let token = match token {
    Some(t) => t
    None => self.prev
  }
  self.expression(
    mk(Identifier, [("this", token.text), ("quoted", quoted)]),
    token~,
  )
}

///|
pub fn Parser::parse_distinct_arg_function(
  self : Parser,
  kind : Kind,
  distinct_index? : Int = 0,
) -> Expr? raise SqlglotError {
  let is_distinct = self.match_(DISTINCT)
  if !is_distinct {
    self.match_(ALL) |> ignore
  }
  let args = [self.parse_lambda()].filter_map(x => x)
  if self.match_(COMMA) {
    args.append(self.parse_function_args())
  }
  if is_distinct && distinct_index < args.length() {
    args[distinct_index] = self.expression(
      mk(Distinct, [("expressions", [args[distinct_index]])]),
    )
  }
  Some(from_arg_list(kind, args))
}
