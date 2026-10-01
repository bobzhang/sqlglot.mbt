// Port of sqlglot/parsers/snowflake.py (SnowflakeParser)

///|
/// `RANKING_WINDOW_FUNCTIONS_WITH_FRAME`
let ranking_window_functions_with_frame : Array[@core.Kind] = [
  FirstValue,
  LastValue,
  NthValue,
]

///|
fn is_ranking_with_frame(e : @core.Expr?) -> Bool {
  match e {
    Some(x) => x.kind.is_any(ranking_window_functions_with_frame)
    None => false
  }
}

///|
let flatten_columns : Array[String] = [
  "SEQ", "KEY", "PATH", "INDEX", "VALUE", "THIS",
]

///|
let schema_kinds : Array[String] = [
  "OBJECTS", "TABLES", "VIEWS", "SEQUENCES", "UNIQUE KEYS", "IMPORTED KEYS",
]

///|
let non_table_creatables : Array[String] = [
  "STORAGE INTEGRATION", "TAG", "WAREHOUSE", "STREAMLIT",
]

///|
fn undrop_objects() -> Map[String, Array[Array[String]]] {
  let m : Map[String, Array[Array[String]]] = Map([])
  for
    k in [
      "ACCOUNT", "DATABASE", "NOTEBOOK", "SCHEMA", "SNAPSHOT", "STREAMLIT", "TABLE",
      "TAG", "TYPE",
    ] {
    m[k] = []
  }
  m["DYNAMIC"] = [["TABLE"]]
  m["EXTERNAL"] = [["VOLUME"]]
  m["ICEBERG"] = [["TABLE"]]
  m
}

///|
fn node(e : @core.Expr?) -> @core.Value? {
  match e {
    Some(x) => Some(Node(x))
    None => None
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  register_functions(fns)
  // FUNCTION_PARSERS
  let fp = fns.function_parsers
  fp["DATE_PART"] = parse_date_part
  fp["DIRECTORY"] = parse_directory
  fp["OBJECT_CONSTRUCT_KEEP_NULL"] = parse_object_construct_keep_null
  fp["LISTAGG"] = p => p.parse_string_agg()
  fp["SEMANTIC_VIEW"] = parse_semantic_view
  fp["SUBSTR"] = p => p.parse_substring()
  fp.remove("TRIM")
  // RANGE_PARSERS
  fns.range_parsers[RLIKE] = (p, this) => {
    let expression = p.parse_bitwise()
    Some(
      p.expression(
        @core.mk(RegexpLike, [
          ("this", this),
          ("expression", expression),
          ("full_match", true),
        ]),
      ),
    )
  }
  // ALTER_PARSERS
  fns.alter_parsers["MODIFY"] = p => node(p.parse_alter_table_alter())
  fns.alter_parsers["SESSION"] = p => node(p.parse_alter_session())
  fns.alter_parsers["UNSET"] = p => {
    let tag = p.match_text_seq(["TAG"])
    let expressions = p.parse_csv(() => p.parse_id_var())
    Some(
      Node(
        p.expression(
          @core.mk(Set, [
            ("tag", tag),
            ("expressions", expressions),
            ("unset", true),
          ]),
        ),
      ),
    )
  }
  // STATEMENT_PARSERS
  fns.statement_parsers[GET] = parse_get
  fns.statement_parsers[PUT] = parse_put
  fns.statement_parsers[SHOW] = p => p.parse_show()
  fns.statement_parsers[UNDROP] = parse_undrop
  // PROPERTY_PARSERS
  let pp = fns.property_parsers
  pp["CREDENTIALS"] = (p, _) => node(parse_credentials_property(p))
  pp["FILE_FORMAT"] = (p, _) => node(parse_file_format_property(p))
  pp["LOCATION"] = (p, _) => node(parse_location_property(p))
  pp["ROW"] = (p, _) => {
    if p.match_text_seq(["ACCESS", "POLICY"]) {
      node(parse_row_access_policy(p))
    } else {
      node(p.parse_row())
    }
  }
  pp["TAG"] = (p, _) => node(parse_tag(p))
  pp["USING"] = (p, _) => {
    if p.match_text_seq(["TEMPLATE"]) {
      let this = p.parse_statement()
      Some(Node(p.expression(@core.mk1(UsingTemplateProperty, this))))
    } else {
      Some(Bool(false))
    }
  }
  // TYPE_CONVERTERS
  fns.type_converters.clear()
  fns.type_converters[DECIMAL] = @core.build_default_decimal_type(
    precision=38,
    scale=0,
  )
  // SHOW_PARSERS
  fns.show_parsers.clear()
  let sp = fns.show_parsers
  for
    name in [
      "DATABASES", "SCHEMAS", "OBJECTS", "TABLES", "VIEWS", "PRIMARY KEYS", "IMPORTED KEYS",
      "UNIQUE KEYS", "SEQUENCES", "STAGES", "COLUMNS", "USERS", "FILE FORMATS", "FUNCTIONS",
      "PROCEDURES", "WAREHOUSES",
    ] {
    sp[name] = show_parser(name)
  }
  sp["ICEBERG TABLES"] = show_parser("TABLES", iceberg=true)
  sp["TERSE ICEBERG TABLES"] = show_parser("TABLES", terse=true, iceberg=true)
  for
    name in [
      "DATABASES", "SCHEMAS", "OBJECTS", "TABLES", "VIEWS", "SEQUENCES", "USERS",
    ] {
    sp["TERSE " + name] = show_parser(name, terse=true)
  }
  // TERSE has no semantic effect for KEYS, so we do not set the terse AST arg
  for name in ["PRIMARY KEYS", "IMPORTED KEYS", "UNIQUE KEYS"] {
    sp["TERSE " + name] = show_parser(name)
  }
  // CONSTRAINT_PARSERS
  for name in ["WITH", "MASKING", "PROJECTION", "TAG"] {
    fns.constraint_parsers[name] = parse_with_constraint
  }
  // LAMBDAS
  fns.lambdas[ARROW] = (p, expressions) => {
    let body = p.replace_lambda(p.parse_assignment(), expressions)
    let args = expressions.map(e => {
      if e.kind == Cast {
        e.this().unwrap()
      } else {
        e
      }
    })
    Some(
      p.expression(@core.mk(Lambda, [("this", body), ("expressions", args)])),
    )
  }
  // COLUMN_OPERATORS
  fns.column_operators[EXCLAMATION] = Some((p, this, attr) => {
    Some(
      p.expression(
        @core.mk(ModelAttribute, [("this", this), ("expression", attr)]),
      ),
    )
  })
  // Method overrides
  let h = fns.hooks
  h.parse_describe = Some(parse_describe)
  h.parse_use = Some(parse_use)
  h.negate_range = Some(negate_range)
  h.parse_property_before = Some(parse_property_before)
  h.parse_with_property = Some(parse_with_property)
  h.parse_create = Some(parse_create)
  h.parse_bracket_key_value = Some(parse_bracket_key_value)
  h.parse_lateral = Some(parse_lateral)
  h.parse_table_parts = Some(parse_table_parts)
  h.parse_function_call = Some(parse_function_call)
  h.parse_id_var = Some(parse_id_var)
  h.parse_file_location = Some(parse_file_location)
  h.parse_lambda_arg = Some(parse_lambda_arg)
  h.parse_foreign_key = Some(parse_foreign_key)
  h.parse_set = Some(parse_set)
  h.parse_position = Some(parse_position)
  h.parse_substring = Some(parse_substring)
  h.build_cast = Some(build_cast)
  h.parse_window = Some(parse_window)
}

///|
fn parse_directory(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let table = p.parse_table_parts()
  let this = match table {
    Some(t) if t.kind == Table => t.this()
    _ => table
  }
  Some(p.expression(@core.mk1(DirectoryStage, this)))
}

///|
fn describe_qualifier(
  p : @core.Parser,
  name : String,
) -> @core.Expr? raise @core.SqlglotError {
  let curr_upper = if p.curr.ok() { @core.py_upper(p.curr.text) } else { "" }
  let simple = (k : @core.Kind) => Some(p.expression(@core.mk0(k)))
  match name {
    "API" => simple(ApiProperty)
    "APPLICATION" => simple(ApplicationProperty)
    "CATALOG" => simple(CatalogProperty)
    "COMPUTE" => simple(ComputeProperty)
    "DATABASE" =>
      if curr_upper == "ROLE" {
        simple(DatabaseProperty)
      } else {
        None
      }
    "DYNAMIC" => simple(DynamicProperty)
    "EXTERNAL" => simple(ExternalProperty)
    "HYBRID" => simple(HybridProperty)
    "ICEBERG" => simple(IcebergProperty)
    "MASKING" => simple(MaskingProperty)
    "MATERIALIZED" => simple(MaterializedProperty)
    "NETWORK" => simple(NetworkProperty)
    "ROW" =>
      if p.match_text_seq(["ACCESS"]) {
        simple(RowAccessProperty)
      } else {
        None
      }
    "SECURITY" =>
      if curr_upper == "INTEGRATION" {
        simple(SecurityIntegrationProperty)
      } else {
        None
      }
    _ => None
  }
}

///|
let describe_qualifiers : Array[String] = [
  "API", "APPLICATION", "CATALOG", "COMPUTE", "DATABASE", "DYNAMIC", "EXTERNAL",
  "HYBRID", "ICEBERG", "MASKING", "MATERIALIZED", "NETWORK", "ROW", "SECURITY",
]

///|
fn parse_describe(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  if p.match_texts(describe_qualifiers) {
    let qualifier = describe_qualifier(p, p.prev_upper())
    if qualifier is Some(q) {
      if p.match_set_text(p.cfg.creatables) is Some(kind) {
        let this = p.parse_table(schema=true)
        let properties = p.expression(
          @core.mk(Properties, [("expressions", [q])]),
        )
        let post_props = p.parse_properties()
        let expressions = match post_props {
          Some(pp) => Some(pp.expressions())
          None => None
        }
        return Some(
          p.expression(
            @core.mk(Describe, [
              ("this", this),
              ("kind", kind),
              ("properties", properties),
              ("expressions", expressions),
            ]),
          ),
        )
      }
    }
  }
  p.retreat(index)
  p.parse_describe_base()
}

///|
fn parse_use(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.match_text_seq(["SECONDARY", "ROLES"]) {
    let this = if p.match_texts(["ALL", "NONE"]) {
      Some(@core.var_(p.prev_upper()))
    } else {
      None
    }
    let roles = if this is Some(_) {
      None
    } else {
      Some(p.parse_csv(() => p.parse_table(schema=false)))
    }
    return Some(
      p.expression(
        @core.mk(Use, [
          ("kind", "SECONDARY ROLES"),
          (
            "this",
            match this {
              Some(t) => @core.Value::Node(t)
              None => @core.Value::Bool(false)
            },
          ),
          ("expressions", roles),
        ]),
      ),
    )
  }
  p.parse_use_base()
}

///|
fn negate_range(
  p : @core.Parser,
  this : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  guard this is Some(t) else { return this }
  match t.arg("query") {
    Some(query) if t.kind == In && query.kind.is_a(Query) =>
      // Snowflake treats `value NOT IN (subquery)` as `VALUE <> ALL (subquery)`, so
      // we do this conversion here to avoid parsing it into `NOT value IN (subquery)`
      // which can produce different results (most likely a SnowFlake bug).
      //
      // https://docs.snowflake.com/en/sql-reference/functions/in
      // Context: https://github.com/tobymao/sqlglot/issues/3890
      return Some(
        p.expression(
          @core.mk(NEQ, [
            ("this", t.this()),
            ("expression", @core.mk1(All, query.unnest())),
          ]),
        ),
      )
    _ => ()
  }
  Some(p.expression(@core.mk1(Not, t)))
}

///|
fn parse_tag(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let expressions = p.parse_wrapped_csv(() => {
    match p.parse_property() {
      Some(Node(e)) => Some(e)
      _ => None
    }
  })
  Some(p.expression(@core.mk(Tags, [("expressions", expressions)])))
}

///|
fn parse_property_before(
  p : @core.Parser,
) -> @core.Value? raise @core.SqlglotError {
  let prop = p.parse_property_before_base()
  if prop is Some(v) && v.truthy() {
    return prop
  }
  if !p.next.ok() || p.next.token_type != EQ {
    return None
  }
  match p.parse_sequence_properties() {
    Some(e) => Some(Node(e))
    None =>
      node(
        p.parse_key_value_property(parse_value=() => p.parse_primary_or_var()),
      )
  }
}

///|
fn policy_to_dot(policy : @core.Expr?) -> @core.Expr? {
  match policy {
    Some(c) if c.kind == Column => Some(c.to_dot())
    _ => policy
  }
}

///|
fn parse_with_constraint(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if p.prev.token_type != WITH {
    p.retreat(p.index - 1)
  }
  if p.match_text_seq(["MASKING", "POLICY"]) {
    let policy = p.parse_column()
    let this = policy_to_dot(policy)
    let expressions = p.andl(p.match_(USING), () => {
      p.parse_wrapped_csv(() => p.parse_id_var())
    })
    return Some(
      p.expression(
        @core.mk(MaskingPolicyColumnConstraint, [
          ("this", this),
          ("expressions", expressions),
        ]),
      ),
    )
  }
  if p.match_text_seq(["PROJECTION", "POLICY"]) {
    let policy = p.parse_column()
    return Some(
      p.expression(
        @core.mk1(ProjectionPolicyColumnConstraint, policy_to_dot(policy)),
      ),
    )
  }
  if p.match_(TAG) {
    return parse_tag(p)
  }
  None
}

///|
fn parse_with_property(
  p : @core.Parser,
) -> @core.Value? raise @core.SqlglotError {
  if p.match_(TAG) {
    return node(parse_tag(p))
  }
  if p.match_text_seq(["ROW", "ACCESS", "POLICY"]) {
    return node(parse_row_access_policy(p))
  }
  p.parse_with_property_base()
}

///|
fn parse_row_access_policy(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // GET_DDL outputs #unknown_policy when the user lacks privileges to see the policy name
  let (policy, expressions) = if p.match_(HASH) {
    let mut policy = p.parse_var(any_token=true)
    if policy is Some(pol) {
      policy = Some(@core.var_("#" + pol.name()))
    }
    (policy, None)
  } else {
    let policy = policy_to_dot(p.parse_column())
    if !p.match_(ON) {
      p.raise_error("Expected ON after ROW ACCESS POLICY name")
    }
    (policy, Some(p.parse_wrapped_csv(() => p.parse_id_var())))
  }
  Some(
    p.expression(
      @core.mk(RowAccessProperty, [
        ("this", policy),
        ("expressions", expressions),
      ]),
    ),
  )
}

///|
fn parse_create(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let expression = p.parse_create_base()
  match expression {
    Some(e) if e.kind == Create && non_table_creatables.contains(e.text("kind")) =>
      // Replace the Table node with the enclosed Identifier
      match e.this() {
        Some(t) => t.replace(t.this()) |> ignore
        None => ()
      }
    _ => ()
  }
  expression
}

///|
fn parse_object_construct_keep_null(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let index = p.index
  let column = p.parse_column()
  if column is Some(c) && c.is_star() {
    return Some(p.expression(@core.mk(JSONObject, [("expressions", [c])])))
  }
  p.retreat(index)
  p.parse_json_object(agg=false)
}

///|
/// https://docs.snowflake.com/en/sql-reference/functions/date_part.html
fn parse_date_part(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = match p.parse_var() {
    Some(v) => Some(v)
    None => p.parse_type()
  }
  guard this is Some(t) else { return None }
  // Handle both syntaxes: DATE_PART(part, expr) and DATE_PART(part FROM expr)
  let expression = if p.match_set(@core.TokenSet::new([FROM, COMMA])) {
    p.parse_bitwise()
  } else {
    None
  }
  Some(
    p.expression(
      @core.mk(Extract, [
        ("this", @core.map_date_part(Some(t), dialect=p.dialect)),
        ("expression", expression),
      ]),
    ),
  )
}

///|
fn parse_bracket_key_value(
  p : @core.Parser,
  is_map : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  if is_map {
    // Keys are strings in Snowflake's objects, see also:
    // - https://docs.snowflake.com/en/sql-reference/data-types-semistructured
    // - https://docs.snowflake.com/en/sql-reference/functions/object_construct
    return match p.parse_slice(p.parse_string()) {
      Some(e) => Some(e)
      None => p.parse_assignment()
    }
  }
  p.parse_slice(p.parse_alias(p.parse_assignment(), explicit=true))
}

///|
fn parse_lateral(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let lateral = p.parse_lateral_base()
  guard lateral is Some(l) else { return lateral }
  if l.this() is Some(t) && t.kind == Explode {
    let table_alias = l.arg("alias")
    match table_alias {
      Some(ta) =>
        if !ta.has("columns") {
          ta.set("columns", flatten_columns.map(c => @core.to_identifier(c)))
        }
      None =>
        @core.alias_table(l, "_flattened", columns=flatten_columns) |> ignore
    }
  }
  lateral
}

///|
fn parse_table_parts(
  p : @core.Parser,
  schema : Bool,
  is_db_reference : Bool,
  _wildcard : Bool,
  fast : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  // https://docs.snowflake.com/en/user-guide/querying-stage
  let table = if p.match_(STRING, advance=false) {
    p.parse_string()
  } else if p.match_text_seq(["@"], advance=false) {
    Some(parse_location_path(p))
  } else {
    None
  }
  match table {
    Some(_) => {
      let mut file_format : @core.Expr? = None
      let mut pattern : @core.Expr? = None
      let wrapped = p.match_(L_PAREN)
      while p.curr.ok() && wrapped && !p.match_(R_PAREN) {
        if p.match_text_seq(["FILE_FORMAT", "=>"]) {
          file_format = match p.parse_string() {
            Some(s) => Some(s)
            None => p.parse_table_parts_base(is_db_reference~)
          }
        } else if p.match_text_seq(["PATTERN", "=>"]) {
          pattern = p.parse_string()
        } else {
          break
        }
        p.match_(COMMA) |> ignore
      }
      Some(
        p.expression(
          @core.mk(Table, [
            ("this", table),
            ("format", file_format),
            ("pattern", pattern),
          ]),
        ),
      )
    }
    None => p.parse_table_parts_base(schema~, is_db_reference~, fast~)
  }
}

///|
fn parse_function_call(
  p : @core.Parser,
  functions : Map[String, @core.FuncBuilder]?,
  anonymous : Bool,
  optional_parens : Bool,
  any_token : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_function_call_base(
    functions?,
    anonymous~,
    optional_parens~,
    any_token~,
  )
  // Snowflake can invoke a function whose name is dynamically resolved, e.g.
  // `IDENTIFIER('my_func')(1, 2)`. The trailing argument list is the call's arguments.
  //
  // https://docs.snowflake.com/en/sql-reference/identifier-literal
  match this {
    Some(t) if t.kind == DynamicIdentifier && p.match_(L_PAREN, advance=false) =>
      t.set("expressions", p.parse_wrapped_csv(() => p.parse_lambda()))
    _ => ()
  }
  this
}

///|
fn parse_id_var(
  p : @core.Parser,
  any_token : Bool,
  tokens : @core.TokenSet?,
) -> @core.Expr? raise @core.SqlglotError {
  if p.match_text_seq(["IDENTIFIER", "("]) {
    let identifier = match p.parse_id_var_base(any_token~, tokens?) {
      Some(i) => Some(i)
      None => p.parse_string()
    }
    p.match_r_paren()
    return Some(p.expression(@core.mk1(DynamicIdentifier, identifier)))
  }
  p.parse_id_var_base(any_token~, tokens?)
}

///|
fn show_parser(
  this : String,
  terse? : Bool = false,
  iceberg? : Bool = false,
) -> @core.ParseFn {
  p => parse_show_snowflake(p, this, terse, iceberg)
}

///|
fn parse_show_snowflake(
  p : @core.Parser,
  this : String,
  terse : Bool,
  iceberg : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let mut scope : @core.Expr? = None
  let mut scope_kind : String? = None
  let history = p.match_text_seq(["HISTORY"])
  let like = if p.match_(LIKE) { p.parse_string() } else { None }
  if p.match_(IN) {
    if p.match_text_seq(["ACCOUNT"]) {
      scope_kind = Some("ACCOUNT")
    } else if p.match_text_seq(["CLASS"]) {
      scope_kind = Some("CLASS")
      scope = p.parse_table_parts()
    } else if p.match_text_seq(["APPLICATION"]) {
      scope_kind = Some(
        if p.match_text_seq(["PACKAGE"]) {
          "APPLICATION PACKAGE"
        } else {
          "APPLICATION"
        },
      )
      scope = p.parse_table_parts()
    } else if p.match_set(p.cfg.db_creatables) {
      scope_kind = Some(p.prev_upper())
      if p.curr.ok() {
        scope = p.parse_table_parts()
      }
    } else if p.curr.ok() {
      scope_kind = Some(
        if schema_kinds.contains(this) {
          "SCHEMA"
        } else {
          "TABLE"
        },
      )
      scope = p.parse_table_parts()
    }
  }
  let starts_with = p.andv(p.match_text_seq(["STARTS", "WITH"]), () => {
    p.parse_string()
  })
  let limit = p.parse_limit()
  let from_ = if p.match_(FROM) { p.parse_string() } else { None }
  let privileges = p.andl(p.match_text_seq(["WITH", "PRIVILEGES"]), () => {
    p.parse_csv(() => p.parse_var(any_token=true, upper=true))
  })
  Some(
    p.expression(
      @core.mk(Show, [
        ("terse", terse),
        ("iceberg", iceberg),
        ("this", this),
        ("history", history),
        ("like", like),
        ("scope", scope),
        ("scope_kind", scope_kind),
        ("starts_with", starts_with),
        ("limit", limit),
        ("from_", from_),
        ("privileges", privileges),
      ]),
    ),
  )
}

///|
fn parse_undrop(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let start = p.prev
  let kind = p.parse_var_from_options(undrop_objects(), raise_unmatched=false)
  guard kind is Some(k) else { return Some(p.parse_as_command(start)) }
  let this = p.parse_table_parts(
    is_db_reference=["ACCOUNT", "DATABASE", "SCHEMA"].contains(k.name()),
  )
  let rename = if p.match_text_seq(["RENAME", "TO"]) {
    p.parse_table_parts()
  } else {
    None
  }
  Some(
    p.expression(
      @core.mk(Undrop, [("this", this), ("kind", k.name()), ("rename", rename)]),
    ),
  )
}

///|
fn parse_put(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  if p.curr.token_type != STRING && p.curr.token_type != URI_START {
    return Some(p.parse_as_command(p.prev))
  }
  let this = match p.parse_string() {
    Some(s) => s
    None => @core.literal_string(parse_location_path(p).name())
  }
  let target = parse_location_path(p)
  let properties = p.parse_properties()
  Some(
    p.expression(
      @core.mk(Put, [
        ("this", this),
        ("target", target),
        ("properties", properties),
      ]),
    ),
  )
}

///|
fn parse_get(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let start = p.prev
  // If we detect GET( then we need to parse a function, not a statement
  if p.match_(L_PAREN) {
    p.retreat(p.index - 2)
    return p.parse_expression()
  }
  let target = parse_location_path(p)
  // Parse as command if unquoted file path
  if p.curr.token_type == URI_START {
    return Some(p.parse_as_command(start))
  }
  let this = p.parse_string()
  let properties = p.parse_properties()
  Some(
    p.expression(
      @core.mk(Get, [
        ("this", this),
        ("target", target),
        ("properties", properties),
      ]),
    ),
  )
}

///|
fn parse_location_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_(EQ) |> ignore
  Some(p.expression(@core.mk1(LocationProperty, parse_location_path(p))))
}

///|
fn parse_file_location(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // Parse either a subquery or a staged file
  if p.match_(L_PAREN, advance=false) {
    p.parse_select(table=true, parse_subquery_alias=false)
  } else {
    p.parse_table_parts()
  }
}

///|
fn parse_location_path(p : @core.Parser) -> @core.Expr {
  let start = p.curr
  p.advance_any(ignore_reserved=true) |> ignore
  // We avoid consuming a comma token because external tables like @foo and @bar
  // can be joined in a query with a comma separator, as well as closing paren
  // in case of subqueries
  while p.is_connected() &&
        !p.match_set(
          @core.TokenSet::new([COMMA, L_PAREN, R_PAREN]),
          advance=false,
        ) {
    p.advance_any(ignore_reserved=true) |> ignore
  }
  @core.var_(p.find_sql(start, p.prev))
}

///|
fn parse_lambda_arg(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_id_var()
  guard this is Some(_) else { return this }
  let typ = p.parse_types()
  match typ {
    Some(_) => Some(p.expression(@core.mk(Cast, [("this", this), ("to", typ)])))
    None => this
  }
}

///|
fn parse_foreign_key(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // inlineFK, the REFERENCES columns are implied
  if p.match_(REFERENCES, advance=false) {
    return Some(p.expression(@core.mk0(ForeignKey)))
  }
  // outoflineFK, explicitly names the columns
  p.parse_foreign_key_base()
}

///|
fn parse_file_format_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  p.match_(EQ) |> ignore
  let expressions = if p.match_(L_PAREN, advance=false) {
    p.parse_wrapped_options()
  } else {
    [p.parse_format_name()]
  }
  Some(
    p.expression(@core.mk(FileFormatProperty, [("expressions", expressions)])),
  )
}

///|
fn parse_credentials_property(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let expressions = p.parse_wrapped_options()
  Some(
    p.expression(@core.mk(CredentialsProperty, [("expressions", expressions)])),
  )
}

///|
fn parse_semantic_view(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  let e = @core.mk(SemanticView, [("this", p.parse_table_parts())])
  while p.curr.ok() && !p.match_(R_PAREN, advance=false) {
    if p.match_texts(["DIMENSIONS", "METRICS", "FACTS"]) {
      let keyword = @core.py_lower(p.prev.text)
      e.set(
        keyword,
        p.parse_csv(() => p.parse_alias(p.parse_disjunction(), explicit=true)),
      )
    } else if p.match_text_seq(["WHERE"]) {
      e.set("where", p.parse_expression())
    } else {
      p.raise_error("Expecting ) or encountered unexpected keyword")
      break
    }
  }
  Some(p.expression(e))
}

///|
fn parse_set(
  p : @core.Parser,
  unset : Bool,
  tag : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let set = p.parse_set_base(unset~, tag~)
  match set {
    Some(s) if s.kind == Set =>
      for expr in s.expressions() {
        if expr.kind == SetItem {
          expr.set("kind", "VARIABLE")
        }
      }
    _ => ()
  }
  set
}

///|
fn parse_position(
  p : @core.Parser,
  haystack_first : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let result = p.parse_position_base(haystack_first~)
  match result {
    Some(r) => r.set("clamp_position", true)
    None => ()
  }
  result
}

///|
fn parse_substring(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let result = p.parse_substring_base()
  match result {
    Some(r) => r.set("zero_start", true)
    None => ()
  }
  result
}

///|
fn kwarg_expr(
  kwargs : Array[(String, @core.Value?)],
  key : String,
) -> @core.Expr? {
  for kv in kwargs {
    if kv.0 == key {
      return match kv.1 {
        Some(Node(e)) => Some(e)
        _ => None
      }
    }
  }
  None
}

///|
fn build_cast(
  p : @core.Parser,
  strict : Bool,
  kwargs : Array[(String, @core.Value?)],
) -> @core.Expr raise @core.SqlglotError {
  let to = kwarg_expr(kwargs, "to")
  let to_dtype = match to {
    Some(t) => t.datatype_this()
    None => None
  }
  if !strict && to_dtype == Some(BOOLEAN) {
    return p.expression(
      @core.mk(ToBoolean, [("this", kwarg_expr(kwargs, "this")), ("safe", true)]),
    )
  }
  let cast = p.build_cast_base(strict, kwargs)
  if cast.kind == TryCast && to is Some(t) {
    if to_dtype is Some(dt) &&
      @core.dtype_text_types.contains(dt) &&
      !t.expressions().is_empty() {
      cast.set("null_on_text_overflow", true)
    } else if to_dtype == Some(DATE) &&
      cast.this() is Some(ct) &&
      ct.is_string() {
      cast.set("probe_date_format", true)
    }
  }
  cast
}

///|
fn parse_window(
  p : @core.Parser,
  this : @core.Expr?,
  alias_ : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  let result = p.parse_window_base(this, alias=alias_)
  // Set default window frame for ranking functions if not present
  match result {
    Some(r) if r.kind == Window && is_ranking_with_frame(this) && !r.has("spec") => {
      let frame = @core.mk(WindowSpec, [
        ("kind", "ROWS"),
        ("start", "UNBOUNDED"),
        ("start_side", "PRECEDING"),
        ("end", "UNBOUNDED"),
        ("end_side", "FOLLOWING"),
      ])
      r.set("spec", frame)
    }
    _ => ()
  }
  result
}
