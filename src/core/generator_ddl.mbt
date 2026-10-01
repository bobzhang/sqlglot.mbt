// Generator methods for DDL: CREATE/DROP/ALTER, columns, constraints, properties.

///|
pub fn Generator::uncache_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let table = self.sql_key(expression, "this")
  let exists_sql = g_when(expression.has("exists"), " IF EXISTS")
  "UNCACHE TABLE" + exists_sql + " " + table
}

///|
pub fn Generator::cache_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let lazy_ = g_when(expression.has("lazy"), " LAZY")
  let table = self.sql_key(expression, "this")
  let options = expression.raw_list("options")
  let options = if options.length() >= 2 {
    " OPTIONS(" +
    self.sql_value(options[0]) +
    " = " +
    self.sql_value(options[1]) +
    ")"
  } else {
    ""
  }
  let sql = self.sql_key(expression, "expression")
  let sql = g_pfx(" AS" + self.sep(), sql)
  let sql = "CACHE" + lazy_ + " TABLE " + table + options + sql
  self.prepend_ctes(expression, sql)
}

///|
pub fn Generator::characterset_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let default = g_when(expression.has("default"), "DEFAULT ")
  default + "CHARACTER SET=" + self.sql_key(expression, "this")
}

///|
/// Virtual `column_parts`.
pub fn Generator::column_parts(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.column_parts {
    Some(f) => f(self, expression)
    None => self.column_parts_base(expression)
  }
}

///|
pub fn Generator::column_parts_base(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("shadow") &&
    self.dialect.cfg.projection_aliases_shadow_source_names {
    return self.sql_key(expression, "this")
  }
  let parts = []
  for k in ["catalog", "db", "table", "this"] {
    match expression.get(k) {
      Some(v) if v.truthy() => parts.push(self.sql_value(v))
      _ => ()
    }
  }
  parts.join(".")
}

///|
pub fn Generator::column_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut join_mark = g_when(expression.has("join_mark"), " (+)")
  if join_mark != "" && !self.dialect.cfg.supports_column_join_marks {
    join_mark = ""
    self.unsupported(
      "Outer join syntax using the (+) operator is not supported.",
    )
  }
  self.column_parts(expression) + join_mark
}

///|
pub fn Generator::pseudocolumn_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.call_method(Column, expression)
}

///|
pub fn Generator::columnposition_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let position = self.sql_key(expression, "position")
  position + this
}

///|
/// Virtual `columndef_sql(expression, sep)`.
pub fn Generator::columndef_sql_v(
  self : Generator,
  expression : Expr,
  sep? : String = " ",
) -> String raise SqlglotError {
  match self.fns.hooks.columndef_sql {
    Some(f) => f(self, expression, sep)
    None => self.columndef_sql(expression, sep~)
  }
}

///|
pub fn Generator::columndef_sql(
  self : Generator,
  expression : Expr,
  sep? : String = " ",
) -> String raise SqlglotError {
  let column = self.sql_key(expression, "this")
  let kind = self.sql_key(expression, "kind")
  let constraints = self.expressions(
    expression~,
    key="constraints",
    sep=" ",
    flat=true,
  )
  let exists = g_when(expression.has("exists"), "IF NOT EXISTS ")
  let mut kind = g_pfx(sep, kind)
  let constraints = g_pfx(" ", constraints)
  let position = g_pfx(" ", self.sql_key(expression, "position"))
  if expression.find([ComputedColumnConstraint]) is Some(_) &&
    !self.cfg.computed_column_with_type {
    kind = ""
  }
  exists + column + kind + constraints + position
}

///|
pub fn Generator::columnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind_sql = py_strip(self.sql_key(expression, "kind"))
  if this != "" {
    "CONSTRAINT " + this + " " + kind_sql
  } else {
    kind_sql
  }
}

///|
pub fn Generator::computedcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let persisted = if expression.has("not_null") {
    " PERSISTED NOT NULL"
  } else if expression.has("persisted") {
    " PERSISTED"
  } else {
    ""
  }
  "AS " + this + persisted
}

///|
pub fn Generator::autoincrementcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(expression)
  self.token_sql(TokenType::AUTO_INCREMENT)
}

///|
pub fn Generator::compresscolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = match expression.get("this") {
    Some(List(_)) =>
      self.wrap_str(self.expressions(expression~, key="this", flat=true))
    _ => self.sql_key(expression, "this")
  }
  "COMPRESS " + this
}

///|
pub fn Generator::generatedasidentitycolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = ""
  match expression.get("this") {
    Some(v) => {
      let on_null = g_when(expression.has("on_null"), " ON NULL")
      this = if v.truthy() { " ALWAYS" } else { " BY DEFAULT" + on_null }
    }
    None => ()
  }
  let start = match expression.get("start") {
    Some(v) if v.truthy() => "START WITH " + py_str_value(Some(v))
    _ => ""
  }
  let increment = match expression.get("increment") {
    Some(v) if v.truthy() => " INCREMENT BY " + py_str_value(Some(v))
    _ => ""
  }
  let minvalue = match expression.get("minvalue") {
    Some(v) if v.truthy() => " MINVALUE " + py_str_value(Some(v))
    _ => ""
  }
  let maxvalue = match expression.get("maxvalue") {
    Some(v) if v.truthy() => " MAXVALUE " + py_str_value(Some(v))
    _ => ""
  }
  let mut cycle_sql = ""
  match expression.get("cycle") {
    Some(cycle) => {
      cycle_sql = (if !cycle.truthy() { " NO" } else { "" }) + " CYCLE"
      if start == "" && increment == "" {
        cycle_sql = py_strip(cycle_sql)
      }
    }
    None => ()
  }
  let mut sequence_opts = ""
  if start != "" || increment != "" || cycle_sql != "" {
    sequence_opts = start + increment + minvalue + maxvalue + cycle_sql
    sequence_opts = " (" + py_strip(sequence_opts) + ")"
  }
  let expr = self.sql_key(expression, "expression")
  let expr = if expr != "" { "(" + expr + ")" } else { "IDENTITY" }
  "GENERATED" + this + " AS " + expr + sequence_opts
}

///|
pub fn Generator::generatedasrowcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let start = if expression.has("start") { "START" } else { "END" }
  let hidden = g_when(expression.has("hidden"), " HIDDEN")
  "GENERATED ALWAYS AS ROW " + start + hidden
}

///|
pub fn Generator::periodforsystemtimeconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "PERIOD FOR SYSTEM_TIME (" +
  self.sql_key(expression, "this") +
  ", " +
  self.sql_key(expression, "expression") +
  ")"
}

///|
pub fn Generator::notnullcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  (if expression.has("allow_null") { "" } else { "NOT " }) + "NULL"
}

///|
pub fn Generator::primarykeycolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.get("desc") {
    Some(desc) =>
      return "PRIMARY KEY" + (if desc.truthy() { " DESC" } else { " ASC" })
    None => ()
  }
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  "PRIMARY KEY" + options
}

///|
pub fn Generator::uniquecolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let index_type = match expression.get("index_type") {
    Some(v) if v.truthy() => " USING " + py_str_value(Some(v))
    _ => ""
  }
  let on_conflict = g_pfx(" ", self.sql_key(expression, "on_conflict"))
  let nulls_sql = g_when(expression.has("nulls"), " NULLS NOT DISTINCT")
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  "UNIQUE" + nulls_sql + this + index_type + on_conflict + options
}

///|
pub fn Generator::inoutcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String {
  let input_ = expression.has("input_")
  let output = expression.has("output")
  if expression.has("variadic") {
    return "VARIADIC"
  }
  if input_ && output {
    return "IN" + self.cfg.inout_separator + "OUT"
  }
  if input_ {
    return "IN"
  }
  if output {
    return "OUT"
  }
  ""
}

///|
/// Virtual `createable_sql`.
pub fn Generator::createable_sql(
  self : Generator,
  expression : Expr,
  locations : PropLocs,
) -> String raise SqlglotError {
  match self.fns.hooks.createable_sql {
    Some(f) => f(self, expression, locations)
    None => self.createable_sql_base(expression, locations)
  }
}

///|
pub fn Generator::createable_sql_base(
  self : Generator,
  expression : Expr,
  locations : PropLocs,
) -> String raise SqlglotError {
  ignore(locations)
  self.sql_key(expression, "this")
}

///|
fn g_locs_get(locs : PropLocs, loc : PropertiesLocation) -> Array[Expr] {
  match locs.get(loc) {
    Some(l) => l
    None => []
  }
}

///|
pub fn Generator::create_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut kind = self.sql_key(expression, "kind")
  match self.dialect.cfg.inverse_creatable_kind_mapping.get(kind) {
    Some(k) if k != "" => kind = k
    _ => ()
  }
  let properties = expression.arg("properties")
  match properties {
    Some(p) if kind == "TRIGGER" => {
      let exprs = p.expressions()
      if !exprs.is_empty() &&
        exprs[0].kind.is_a(TriggerProperties) &&
        exprs[0].has("constraint") {
        kind = "CONSTRAINT " + kind
      }
    }
    _ => ()
  }
  let properties_locs : PropLocs = match properties {
    Some(p) => self.locate_properties(p)
    None => Map([])
  }
  let this = self.createable_sql(expression, properties_locs)
  let mut properties_sql = ""
  let post_schema = g_locs_get(properties_locs, PostSchema)
  let post_with = g_locs_get(properties_locs, PostWith)
  if !post_schema.is_empty() || !post_with.is_empty() {
    let props_ast = mk(Properties, [("expressions", post_schema + post_with)])
    props_ast.parent = Some(expression)
    properties_sql = self.sql(Some(props_ast))
    if !post_schema.is_empty() {
      properties_sql = self.sep() + properties_sql
    } else if !self.pretty {
      properties_sql = " " + properties_sql
    }
  }
  let begin = g_when(expression.has("begin"), " BEGIN")
  let mut expression_sql = self.sql_key(expression, "expression")
  if expression_sql != "" {
    expression_sql = begin + self.sep() + expression_sql
    let expr_node = expression.expression()
    let is_macro = match expr_node {
      Some(x) => x.kind.is_a(MacroOverloads)
      None => false
    }
    let is_return = match expr_node {
      Some(x) => x.kind.is_a(Return)
      None => false
    }
    if !is_macro && (self.cfg.create_function_return_as || !is_return) {
      let mut postalias_props_sql = ""
      let post_alias = g_locs_get(properties_locs, PostAlias)
      if !post_alias.is_empty() {
        postalias_props_sql = self.properties(
          mk(Properties, [("expressions", post_alias)]),
          wrapped=false,
        )
      }
      let postalias_props_sql = g_pfx(" ", postalias_props_sql)
      expression_sql = " AS" + postalias_props_sql + expression_sql
    }
  }
  let mut postindex_props_sql = ""
  let post_index = g_locs_get(properties_locs, PostIndex)
  if !post_index.is_empty() {
    postindex_props_sql = self.properties(
      mk(Properties, [("expressions", post_index)]),
      wrapped=false,
      prefix=" ",
    )
  }
  let indexes = g_pfx(
    " ",
    self.expressions(expression~, key="indexes", indent=false, sep=" "),
  )
  let index_sql = indexes + postindex_props_sql
  let replace = g_when(expression.has("replace"), " OR REPLACE")
  let refresh = g_when(expression.has("refresh"), " OR REFRESH")
  let unique = g_when(expression.has("unique"), " UNIQUE")
  let clustered_sql = match expression.get("clustered") {
    None => ""
    Some(v) =>
      if v.truthy() {
        " CLUSTERED COLUMNSTORE"
      } else {
        " NONCLUSTERED COLUMNSTORE"
      }
  }
  let mut postcreate_props_sql = ""
  let post_create = g_locs_get(properties_locs, PostCreate)
  if !post_create.is_empty() {
    postcreate_props_sql = self.properties(
      mk(Properties, [("expressions", post_create)]),
      sep=" ",
      prefix=" ",
      wrapped=false,
    )
  }
  let modifiers = clustered_sql +
    replace +
    refresh +
    unique +
    postcreate_props_sql
  let mut postexpression_props_sql = ""
  let post_expression = g_locs_get(properties_locs, PostExpression)
  if !post_expression.is_empty() {
    postexpression_props_sql = self.properties(
      mk(Properties, [("expressions", post_expression)]),
      sep=" ",
      prefix=" ",
      wrapped=false,
    )
  }
  let concurrently = g_when(expression.has("concurrently"), " CONCURRENTLY")
  let exists_sql = g_when(expression.has("exists"), " IF NOT EXISTS")
  let no_schema_binding = g_when(
    expression.has("no_schema_binding"),
    " WITH NO SCHEMA BINDING",
  )
  let clone = g_pfx(" ", self.sql_key(expression, "clone"))
  let properties_expression = if self.cfg.expression_precedes_properties_creatables.contains(
      kind,
    ) {
    expression_sql + properties_sql
  } else {
    properties_sql + expression_sql
  }
  let expression_sql = "CREATE" +
    modifiers +
    " " +
    kind +
    concurrently +
    exists_sql +
    " " +
    this +
    properties_expression +
    postexpression_props_sql +
    index_sql +
    no_schema_binding +
    clone
  self.prepend_ctes(expression, expression_sql)
}

///|
pub fn Generator::sequenceproperties_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let start = g_pfx("START WITH ", self.sql_key(expression, "start"))
  let increment = g_pfx(" INCREMENT BY ", self.sql_key(expression, "increment"))
  let minvalue = g_pfx(" MINVALUE ", self.sql_key(expression, "minvalue"))
  let maxvalue = g_pfx(" MAXVALUE ", self.sql_key(expression, "maxvalue"))
  let owned = g_pfx(" OWNED BY ", self.sql_key(expression, "owned"))
  let cache_str = match expression.get("cache") {
    None => ""
    Some(Bool(true)) => " CACHE"
    Some(v) => " CACHE " + py_str_value(Some(v))
  }
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  py_lstrip(
    start + increment + minvalue + maxvalue + cache_str + options + owned,
  )
}

///|
pub fn Generator::triggerproperties_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let timing = match expression.get("timing") {
    Some(v) => py_str_value(Some(v))
    None => ""
  }
  let event_sqls = []
  for event in expression.raw_list("events") {
    event_sqls.push(self.sql_value(event))
  }
  let events = event_sqls.join(" OR ")
  let timing_events = if timing != "" || events != "" {
    py_strip(timing + " " + events)
  } else {
    ""
  }
  let parts = [timing_events, "ON", self.sql_key(expression, "table")]
  match expression.get("referenced_table") {
    Some(v) if v.truthy() => {
      parts.push("FROM")
      parts.push(self.sql_value(v))
    }
    _ => ()
  }
  match expression.get("deferrable") {
    Some(v) if v.truthy() => parts.push(py_str_value(Some(v)))
    _ => ()
  }
  match expression.get("initially") {
    Some(v) if v.truthy() => parts.push("INITIALLY " + py_str_value(Some(v)))
    _ => ()
  }
  match expression.get("referencing") {
    Some(v) if v.truthy() => parts.push(self.sql_value(v))
    _ => ()
  }
  match expression.get("for_each") {
    Some(v) if v.truthy() => parts.push("FOR EACH " + py_str_value(Some(v)))
    _ => ()
  }
  match expression.get("when") {
    Some(v) if v.truthy() => parts.push("WHEN (" + self.sql_value(v) + ")")
    _ => ()
  }
  parts.push(self.sql_key(expression, "execute"))
  parts.join(self.sep())
}

///|
pub fn Generator::triggerreferencing_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let parts = []
  match expression.get("old") {
    Some(v) if v.truthy() => parts.push("OLD TABLE AS " + self.sql_value(v))
    _ => ()
  }
  match expression.get("new") {
    Some(v) if v.truthy() => parts.push("NEW TABLE AS " + self.sql_value(v))
    _ => ()
  }
  "REFERENCING " + parts.join(" ")
}

///|
pub fn Generator::triggerevent_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("columns") {
    return py_str_value(expression.get("this")) +
      " OF " +
      self.expressions(expression~, key="columns", flat=true)
  }
  self.sql_key(expression, "this")
}

///|
pub fn Generator::clone_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let shallow = g_when(expression.has("shallow"), "SHALLOW ")
  let keyword = if expression.has("copy") && self.cfg.supports_table_copy {
    "COPY"
  } else {
    "CLONE"
  }
  shallow + keyword + " " + this
}

///|
pub fn Generator::describe_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let style = match expression.get("style") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let partition = g_pfx(" ", self.sql_key(expression, "partition"))
  let format = g_pfx(" ", self.sql_key(expression, "format"))
  let as_json = g_when(expression.has("as_json"), " AS JSON")
  "DESCRIBE" +
  style +
  format +
  " " +
  self.sql_key(expression, "this") +
  partition +
  as_json
}

///|
pub fn Generator::drop_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let tables = self.expressions(expression~, key="tables", flat=true)
  let expressions = g_around(" (", self.expressions(expression~, flat=true), ")")
  let mut kind = py_str_value(expression.get("kind"))
  match self.dialect.cfg.inverse_creatable_kind_mapping.get(kind) {
    Some(k) if k != "" => kind = k
    _ => ()
  }
  let iceberg = g_when(
    expression.has("iceberg") && self.cfg.supports_drop_alter_iceberg_property,
    " ICEBERG",
  )
  let exists_sql = if expression.has("exists") { " IF EXISTS " } else { " " }
  let concurrently_sql = g_when(expression.has("concurrently"), " CONCURRENTLY")
  let on_cluster = g_pfx(" ", self.sql_key(expression, "cluster"))
  let temporary = g_when(expression.has("temporary"), " TEMPORARY")
  let materialized = g_when(expression.has("materialized"), " MATERIALIZED")
  let cascade = g_when(expression.has("cascade"), " CASCADE")
  let restrict = g_when(expression.has("restrict"), " RESTRICT")
  let constraints = g_when(expression.has("constraints"), " CONSTRAINTS")
  let purge = g_when(expression.has("purge"), " PURGE")
  let sync = g_when(expression.has("sync"), " SYNC")
  let force = g_when(expression.has("force"), " FORCE")
  "DROP" +
  temporary +
  materialized +
  iceberg +
  " " +
  kind +
  concurrently_sql +
  exists_sql +
  tables +
  on_cluster +
  expressions +
  cascade +
  restrict +
  constraints +
  purge +
  sync +
  force
}

///|
pub fn Generator::indexparameters_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let using_ = g_pfx(" USING ", self.sql_key(expression, "using"))
  let columns = g_around(
    "(",
    self.expressions(expression~, key="columns", flat=true),
    ")",
  )
  let partition_by = g_pfx(
    " PARTITION BY ",
    self.expressions(expression~, key="partition_by", flat=true),
  )
  let where_ = self.sql_key(expression, "where")
  let include_ = g_around(
    " INCLUDE (",
    self.expressions(expression~, key="include", flat=true),
    ")",
  )
  let with_storage = g_around(
    " WITH (",
    self.expressions(expression~, key="with_storage", flat=true),
    ")",
  )
  let tablespace = g_pfx(
    " USING INDEX TABLESPACE ",
    self.sql_key(expression, "tablespace"),
  )
  let on = g_pfx(" ON ", self.sql_key(expression, "on"))
  using_ +
  columns +
  include_ +
  with_storage +
  tablespace +
  partition_by +
  where_ +
  on
}

///|
pub fn Generator::index_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let unique = g_when(expression.has("unique"), "UNIQUE ")
  let primary = g_when(expression.has("primary"), "PRIMARY ")
  let amp = g_when(expression.has("amp"), "AMP ")
  let name = self.sql_key(expression, "this")
  let name = if name != "" { name + " " } else { "" }
  let table = g_pfx(self.cfg.index_on + " ", self.sql_key(expression, "table"))
  let index = if table == "" { "INDEX " } else { "" }
  let params = self.sql_key(expression, "params")
  unique + primary + amp + index + name + table + params
}

///|
pub fn Generator::inputoutputformat_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let input_format = g_pfx(
    "INPUTFORMAT ",
    self.sql_key(expression, "input_format"),
  )
  let output_format = g_pfx(
    "OUTPUTFORMAT ",
    self.sql_key(expression, "output_format"),
  )
  [input_format, output_format].join(self.sep())
}

///|
pub fn Generator::partition_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let partition_keyword = if expression.has("subpartition") {
    "SUBPARTITION"
  } else {
    "PARTITION"
  }
  partition_keyword + "(" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::property_location(
  self : Generator,
  p : Expr,
) -> PropertiesLocation raise SqlglotError {
  match self.cfg.properties_location.get(p.kind) {
    Some(loc) => loc
    None =>
      raise ValueError(
        "KeyError: <class 'sqlglot.expressions.\{p.kind.name()}'>",
      )
  }
}

///|
pub fn Generator::properties_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let root_properties = []
  let with_properties = []
  for p in expression.expressions() {
    let p_loc = self.property_location(p)
    if p_loc == PostWith {
      with_properties.push(p)
    } else if p_loc == PostSchema {
      root_properties.push(p)
    }
  }
  let root_props_ast = mk(Properties, [("expressions", root_properties)])
  root_props_ast.parent = expression.parent
  let with_props_ast = mk(Properties, [("expressions", with_properties)])
  with_props_ast.parent = expression.parent
  let root_props = self.root_properties(root_props_ast)
  let mut with_props = self.with_properties(with_props_ast)
  if root_props != "" && with_props != "" && !self.pretty {
    with_props = " " + with_props
  }
  root_props + with_props
}

///|
pub fn Generator::root_properties(
  self : Generator,
  properties : Expr,
) -> String raise SqlglotError {
  if !properties.expressions().is_empty() {
    return self.expressions(expression=properties, indent=false, sep=" ")
  }
  ""
}

///|
pub fn Generator::properties(
  self : Generator,
  properties : Expr,
  prefix? : String = "",
  sep? : String = ", ",
  suffix? : String = "",
  wrapped? : Bool = true,
) -> String raise SqlglotError {
  if !properties.expressions().is_empty() {
    let expressions = self.expressions(
      expression=properties,
      sep~,
      indent=false,
    )
    if expressions != "" {
      let expressions = if wrapped {
        self.wrap_str(expressions)
      } else {
        expressions
      }
      return prefix +
        (if py_strip(prefix) != "" { " " } else { "" }) +
        expressions +
        suffix
    }
  }
  ""
}

///|
/// Virtual `with_properties`.
pub fn Generator::with_properties(
  self : Generator,
  properties : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.with_properties {
    Some(f) => f(self, properties)
    None => self.with_properties_base(properties)
  }
}

///|
pub fn Generator::with_properties_base(
  self : Generator,
  properties : Expr,
) -> String raise SqlglotError {
  self.properties(
    properties,
    prefix=self.seg(self.cfg.with_properties_prefix, sep=""),
  )
}

///|
/// Virtual `locate_properties`.
pub fn Generator::locate_properties(
  self : Generator,
  properties : Expr,
) -> PropLocs raise SqlglotError {
  match self.fns.hooks.locate_properties {
    Some(f) => f(self, properties)
    None => self.locate_properties_base(properties)
  }
}

///|
pub fn Generator::locate_properties_base(
  self : Generator,
  properties : Expr,
) -> PropLocs raise SqlglotError {
  let properties_locs : PropLocs = Map([])
  for p in properties.expressions() {
    let p_loc = self.property_location(p)
    if p_loc != Unsupported {
      match properties_locs.get(p_loc) {
        Some(l) => l.push(p)
        None => properties_locs[p_loc] = [p]
      }
    } else {
      self.unsupported("Unsupported property \{p.kind.key()}")
    }
  }
  properties_locs
}

///|
pub fn Generator::property_name(
  self : Generator,
  expression : Expr,
  string_key? : Bool = false,
) -> String raise SqlglotError {
  match expression.this() {
    Some(t) if t.kind.is_a(Dot) => return self.sql_key(expression, "this")
    _ => ()
  }
  if string_key {
    "'" + expression.name() + "'"
  } else {
    expression.name()
  }
}

///|
pub fn Generator::property_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.kind == Property {
    return self.property_name(expression) +
      "=" +
      self.sql_key(expression, "value")
  }
  let property_name = match property_to_name.get(expression.kind) {
    Some(n) => n
    None => {
      self.unsupported("Unsupported property \{expression.kind.key()}")
      "None"
    }
  }
  property_name + "=" + self.sql_key(expression, "this")
}

///|
pub fn Generator::naked_property(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let property_name = match property_to_name.get(expression.kind) {
    Some(n) => n
    None => {
      self.unsupported("Unsupported property \{expression.kind.name()}")
      "None"
    }
  }
  property_name + " " + self.sql_key(expression, "this")
}

///|
pub fn Generator::uuidproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "UUID " + self.sql_key(expression, "this")
}

///|
pub fn Generator::likeproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.supports_create_table_like {
    let opts = []
    for e in expression.expressions() {
      opts.push(e.name() + " " + self.sql_key(e, "value"))
    }
    let options = g_pfx(" ", opts.join(" "))
    let mut like = "LIKE " + self.sql_key(expression, "this") + options
    if self.cfg.like_property_inside_schema &&
      !(match expression.parent {
        Some(p) => p.kind.is_a(Schema)
        None => false
      }) {
      like = "(" + like + ")"
    }
    return like
  }
  if !expression.expressions().is_empty() {
    self.unsupported("Transpilation of LIKE property options is unsupported")
  }
  let select = exp_select_from([mk0(Star)], expression.this_())
  select.set("limit", mk(Limit, [("expression", literal_int(0))]))
  "AS " + self.sql(Some(select))
}

///|
pub fn Generator::fallbackproperty_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let no = g_when(expression.has("no"), "NO ")
  let protection = g_when(expression.has("protection"), " PROTECTION")
  no + "FALLBACK" + protection
}

///|
pub fn Generator::journalproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(self)
  let no = g_when(expression.has("no"), "NO ")
  let local_ = match expression.get("local") {
    Some(v) if v.truthy() => py_str_value(Some(v)) + " "
    _ => ""
  }
  let dual = g_when(expression.has("dual"), "DUAL ")
  let before = g_when(expression.has("before"), "BEFORE ")
  let after = g_when(expression.has("after"), "AFTER ")
  no + local_ + dual + before + after + "JOURNAL"
}

///|
pub fn Generator::freespaceproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let freespace = self.sql_key(expression, "this")
  let percent = g_when(expression.has("percent"), " PERCENT")
  "FREESPACE=" + freespace + percent
}

///|
pub fn Generator::checksumproperty_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let property = if expression.has("default") {
    "DEFAULT"
  } else if expression.has("on") {
    "ON"
  } else {
    "OFF"
  }
  "CHECKSUM=" + property
}

///|
pub fn Generator::mergeblockratioproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("no") {
    return "NO MERGEBLOCKRATIO"
  }
  if expression.has("default") {
    return "DEFAULT MERGEBLOCKRATIO"
  }
  let percent = g_when(expression.has("percent"), " PERCENT")
  "MERGEBLOCKRATIO=" + self.sql_key(expression, "this") + percent
}

///|
pub fn Generator::moduleproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = g_around("(", self.expressions(expression~, flat=true), ")")
  "USING " + self.sql_key(expression, "this") + expressions
}

///|
pub fn Generator::datablocksizeproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let default = expression.has("default")
  let minimum = expression.has("minimum")
  let maximum = expression.has("maximum")
  if default || minimum || maximum {
    let prop = if default {
      "DEFAULT"
    } else if minimum {
      "MINIMUM"
    } else {
      "MAXIMUM"
    }
    return prop + " DATABLOCKSIZE"
  }
  let units = match expression.get("units") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  "DATABLOCKSIZE=" + self.sql_key(expression, "size") + units
}

///|
pub fn Generator::blockcompressionproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let prop = match expression.arg("autotemp") {
    Some(autotemp) => "AUTOTEMP(" + self.expressions(expression=autotemp) + ")"
    None =>
      if expression.has("always") {
        "ALWAYS"
      } else if expression.has("default") {
        "DEFAULT"
      } else if expression.has("manual") {
        "MANUAL"
      } else if expression.has("never") {
        "NEVER"
      } else {
        raise ValueError(
          "UnboundLocalError: cannot access local variable 'prop'",
        )
      }
  }
  "BLOCKCOMPRESSION=" + prop
}

///|
pub fn Generator::isolatedloadingproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let no = g_when(expression.has("no"), " NO")
  let concurrent = g_when(expression.has("concurrent"), " CONCURRENT")
  let target = g_pfx(" ", self.sql_key(expression, "target"))
  "WITH" + no + concurrent + " ISOLATED LOADING" + target
}

///|
pub fn Generator::partitionboundspec_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.get("this") {
    Some(List(_)) =>
      return "IN (" + self.expressions(expression~, key="this", flat=true) + ")"
    Some(v) if v.truthy() => {
      let modulus = self.sql_key(expression, "this")
      let remainder = self.sql_key(expression, "expression")
      return "WITH (MODULUS " + modulus + ", REMAINDER " + remainder + ")"
    }
    _ => ()
  }
  let from_expressions = self.expressions(
    expression~,
    key="from_expressions",
    flat=true,
  )
  let to_expressions = self.expressions(
    expression~,
    key="to_expressions",
    flat=true,
  )
  "FROM (" + from_expressions + ") TO (" + to_expressions + ")"
}

///|
pub fn Generator::partitionedofproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let for_values_or_default = match expression.expression() {
    Some(e) if e.kind.is_a(PartitionBoundSpec) =>
      " FOR VALUES " + self.sql(Some(e))
    _ => " DEFAULT"
  }
  "PARTITION OF " + this + for_values_or_default
}

///|
pub fn Generator::lockingproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = py_str_value(expression.get("kind"))
  let this = if expression.has("this") {
    " " + self.sql_key(expression, "this")
  } else {
    ""
  }
  let for_or_in = match expression.get("for_or_in") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let lock_type = py_str_value(expression.get("lock_type"))
  let override_ = g_when(expression.has("override"), " OVERRIDE")
  "LOCKING " + kind + this + for_or_in + " " + lock_type + override_
}

///|
pub fn Generator::withdataproperty_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let data_sql = "WITH " + g_when(expression.has("no"), "NO ") + "DATA"
  let statistics_sql = match expression.get("statistics") {
    Some(v) => " AND " + (if !v.truthy() { "NO " } else { "" }) + "STATISTICS"
    None => ""
  }
  data_sql + statistics_sql
}

///|
pub fn Generator::withsystemversioningproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = g_pfx("HISTORY_TABLE=", self.sql_key(expression, "this"))
  let data_consistency = self.sql_key(expression, "data_consistency")
  let data_consistency : String? = if data_consistency != "" {
    Some("DATA_CONSISTENCY_CHECK=" + data_consistency)
  } else {
    None
  }
  let retention_period = self.sql_key(expression, "retention_period")
  let retention_period : String? = if retention_period != "" {
    Some("HISTORY_RETENTION_PERIOD=" + retention_period)
  } else {
    None
  }
  let on_sql = if this != "" {
    self.func("ON", [this, data_consistency, retention_period])
  } else if expression.has("on") {
    "ON"
  } else {
    "OFF"
  }
  let sql = "SYSTEM_VERSIONING=" + on_sql
  if expression.has("with_") {
    "WITH(" + sql + ")"
  } else {
    sql
  }
}

///|
pub fn Generator::introducer_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " " +
  self.sql_key(expression, "expression")
}

///|
pub fn Generator::kill_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  "KILL" + kind + this
}

///|
pub fn Generator::rowformatdelimitedproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let fields = g_pfx(" FIELDS TERMINATED BY ", self.sql_key(expression, "fields"))
  let escaped = g_pfx(" ESCAPED BY ", self.sql_key(expression, "escaped"))
  let items = g_pfx(
    " COLLECTION ITEMS TERMINATED BY ",
    self.sql_key(expression, "collection_items"),
  )
  let keys = g_pfx(
    " MAP KEYS TERMINATED BY ",
    self.sql_key(expression, "map_keys"),
  )
  let lines = g_pfx(" LINES TERMINATED BY ", self.sql_key(expression, "lines"))
  let null = g_pfx(" NULL DEFINED AS ", self.sql_key(expression, "null"))
  "ROW FORMAT DELIMITED" + fields + escaped + items + keys + lines + null
}

///|
pub fn Generator::withtablehint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "WITH (" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::indextablehint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this") + " INDEX"
  let target = g_pfx(" FOR ", self.sql_key(expression, "target"))
  this + target + " (" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::historicaldata_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = self.sql_key(expression, "kind")
  let expr = self.sql_key(expression, "expression")
  this + " (" + kind + " => " + expr + ")"
}

///|
pub fn Generator::directory_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let local_ = g_when(expression.has("local"), "LOCAL ")
  let row_format = g_pfx(" ", self.sql_key(expression, "row_format"))
  local_ + "DIRECTORY " + self.sql_key(expression, "this") + row_format
}

///|
pub fn Generator::check_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "CHECK (" + self.sql_key(expression, "this") + ")"
}

///|
pub fn Generator::foreignkey_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = g_around(" (", self.expressions(expression~, flat=true), ")")
  let reference = g_pfx(" ", self.sql_key(expression, "reference"))
  let delete = g_pfx(" ON DELETE ", self.sql_key(expression, "delete"))
  let update = g_pfx(" ON UPDATE ", self.sql_key(expression, "update"))
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  "FOREIGN KEY" + expressions + reference + delete + update + options
}

///|
pub fn Generator::primarykey_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let expressions = self.expressions(expression~, flat=true)
  let include_ = self.sql_key(expression, "include")
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  "PRIMARY KEY" + this + " (" + expressions + ")" + include_ + options
}

///|
pub fn Generator::timeserieskey_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.unsupported("TIMESERIES primary key columns are not supported")
  self.sql_key(expression, "this")
}

///|
pub fn Generator::constraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expressions = self.expressions(expression~, flat=true)
  "CONSTRAINT " + this + " " + expressions
}

///|
pub fn Generator::reference_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expressions = g_around("(", self.expressions(expression~, flat=true), ")")
  let options = g_pfx(
    " ",
    self.expressions(expression~, key="options", flat=true, sep=" "),
  )
  "REFERENCES " + this + expressions + options
}

///|
pub fn Generator::comment_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = py_str_value(expression.get("kind"))
  let materialized = g_when(expression.has("materialized"), " MATERIALIZED")
  let exists_sql = if expression.has("exists") { " IF EXISTS " } else { " " }
  let expression_sql = self.sql_key(expression, "expression")
  "COMMENT" +
  exists_sql +
  "ON" +
  materialized +
  " " +
  kind +
  " " +
  this +
  " IS " +
  expression_sql
}

///|
pub fn Generator::mergetreettlaction_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let delete = g_when(expression.has("delete"), " DELETE")
  let recompress = g_pfx(" RECOMPRESS ", self.sql_key(expression, "recompress"))
  let to_disk = g_pfx(" TO DISK ", self.sql_key(expression, "to_disk"))
  let to_volume = g_pfx(" TO VOLUME ", self.sql_key(expression, "to_volume"))
  this + delete + recompress + to_disk + to_volume
}

///|
pub fn Generator::mergetreettl_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let where_ = self.sql_key(expression, "where")
  let group = self.sql_key(expression, "group")
  let aggregates = self.expressions(expression~, key="aggregates")
  let aggregates = if aggregates != "" {
    self.seg("SET") + self.seg(aggregates)
  } else {
    ""
  }
  if where_ == "" &&
    group == "" &&
    aggregates == "" &&
    expression.expressions().length() == 1 {
    return "TTL " + self.expressions(expression~, flat=true)
  }
  "TTL" + self.seg(self.expressions(expression~)) + where_ + group + aggregates
}

///|
pub fn Generator::transaction_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let modes = g_pfx(" ", self.expressions(expression~, key="modes"))
  "BEGIN" + modes
}

///|
pub fn Generator::commit_sql(self : Generator, expression : Expr) -> String {
  ignore(self)
  let chain = match expression.get("chain") {
    Some(v) => if v.truthy() { " AND CHAIN" } else { " AND NO CHAIN" }
    None => ""
  }
  "COMMIT" + chain
}

///|
pub fn Generator::rollback_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(self)
  let savepoint = match expression.get("savepoint") {
    Some(v) if v.truthy() => " TO " + py_str_value(Some(v))
    _ => ""
  }
  "ROLLBACK" + savepoint
}

///|
pub fn Generator::altercolumn_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let mut exists = ""
  if expression.has("exists") {
    if self.cfg.supports_alter_column_if_exists {
      exists = " IF EXISTS"
    } else {
      self.unsupported(
        "ALTER COLUMN IF EXISTS is not supported by this dialect",
      )
    }
  }
  let dtype = self.sql_key(expression, "dtype")
  if dtype != "" {
    let collate = g_pfx(" COLLATE ", self.sql_key(expression, "collate"))
    let using_ = g_pfx(" USING ", self.sql_key(expression, "using"))
    let alter_set_type = g_pfx("", self.cfg.alter_set_type)
    let alter_set_type = if alter_set_type != "" {
      alter_set_type + " "
    } else {
      ""
    }
    let null_constraint = self.alter_column_null_constraint_sql(expression)
    return "ALTER COLUMN" +
      exists +
      " " +
      this +
      " " +
      alter_set_type +
      dtype +
      collate +
      using_ +
      null_constraint
  }
  let default = self.sql_key(expression, "default")
  if default != "" {
    return "ALTER COLUMN" + exists + " " + this + " SET DEFAULT " + default
  }
  let comment = self.sql_key(expression, "comment")
  if comment != "" {
    return "ALTER COLUMN" + exists + " " + this + " COMMENT " + comment
  }
  match expression.get("visible") {
    Some(v) if v.truthy() =>
      return "ALTER COLUMN" +
        exists +
        " " +
        this +
        " SET " +
        py_str_value(Some(v))
    _ => ()
  }
  let allow_null = expression.get("allow_null")
  let drop = expression.has("drop")
  let allow_null_truthy = match allow_null {
    Some(v) => v.truthy()
    None => false
  }
  if !drop && !allow_null_truthy {
    self.unsupported("Unsupported ALTER COLUMN syntax")
  }
  if allow_null is Some(_) {
    let keyword = if drop { "DROP" } else { "SET" }
    return "ALTER COLUMN" + exists + " " + this + " " + keyword + " NOT NULL"
  }
  "ALTER COLUMN" + exists + " " + this + " DROP DEFAULT"
}

///|
/// Python `_alter_column_null_constraint_sql`.
pub fn Generator::alter_column_null_constraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.get("allow_null") {
    None => ""
    Some(v) => {
      if !self.cfg.supports_alter_column_nullability {
        self.unsupported(
          "ALTER COLUMN cannot set nullability along with a type",
        )
        return ""
      }
      if v.truthy() {
        " NULL"
      } else {
        " NOT NULL"
      }
    }
  }
}

///|
pub fn Generator::modifycolumn_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let rename_from = self.sql_key(expression, "rename_from")
  if rename_from != "" {
    if !self.cfg.supports_change_column {
      self.unsupported("CHANGE COLUMN is not supported in this dialect")
    }
    return "CHANGE COLUMN " + rename_from + " " + this
  }
  if !self.cfg.supports_modify_column {
    self.unsupported("MODIFY COLUMN is not supported in this dialect")
  }
  "MODIFY COLUMN " + this
}

///|
pub fn Generator::alterindex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let visible_sql = if expression.has("visible") {
    "VISIBLE"
  } else {
    "INVISIBLE"
  }
  "ALTER INDEX " + this + " " + visible_sql
}

///|
pub fn Generator::alterdiststyle_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  match expression.this() {
    Some(t) if t.kind.is_a(Var) => ()
    _ => this = "KEY DISTKEY " + this
  }
  "ALTER DISTSTYLE " + this
}

///|
pub fn Generator::altersortkey_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let compound = g_when(expression.has("compound"), " COMPOUND")
  let this = self.sql_key(expression, "this")
  let expressions = g_around("(", self.expressions(expression~, flat=true), ")")
  "ALTER" +
  compound +
  " SORTKEY " +
  (if this != "" { this } else { expressions })
}

///|
/// Virtual `alterrename_sql(expression, include_to)`.
pub fn Generator::alterrename_sql_v(
  self : Generator,
  expression : Expr,
  include_to? : Bool = true,
) -> String raise SqlglotError {
  match self.fns.hooks.alterrename_sql {
    Some(f) => f(self, expression, include_to)
    None => self.alterrename_sql(expression, include_to~)
  }
}

///|
pub fn Generator::alterrename_sql(
  self : Generator,
  expression : Expr,
  include_to? : Bool = true,
) -> String raise SqlglotError {
  let mut expression = expression
  if !self.cfg.rename_table_with_db {
    let mut err : SqlglotError? = None
    expression = expression.transform(n => {
      if n.kind.is_a(Table) {
        Some(exp_table_from_identifier(n.this())) catch {
          e => {
            err = Some(e)
            Some(n)
          }
        }
      } else {
        Some(n)
      }
    })
    match err {
      Some(e) => raise e
      None => ()
    }
  }
  let this = self.sql_key(expression, "this")
  let to_kw = g_when(include_to, " TO")
  "RENAME" + to_kw + " " + this
}

///|
pub fn Generator::renamecolumn_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let exists = g_when(expression.has("exists"), " IF EXISTS")
  let old_column = self.sql_key(expression, "this")
  let new_column = self.sql_key(expression, "to")
  "RENAME COLUMN" + exists + " " + old_column + " TO " + new_column
}

///|
pub fn Generator::alterset_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut exprs = self.expressions(expression~, flat=true)
  if self.cfg.alter_set_wrapped {
    exprs = "(" + exprs + ")"
  }
  "SET " + exprs
}

///|
pub fn Generator::alter_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let actions = expression.list("actions")
  let actions_sql = if !self.dialect.cfg.alter_table_add_required_for_each_column &&
    !actions.is_empty() &&
    actions[0].kind.is_a(ColumnDef) {
    "ADD " + self.expressions(expression~, key="actions", flat=true)
  } else {
    let actions_list : Array[&SqlArg] = []
    for action in actions {
      if action.kind.is_any([ColumnDef, Schema]) {
        actions_list.push(self.add_column_sql(action))
      } else {
        let mut action_sql = self.sql(Some(action))
        if action.kind.is_a(Query) {
          action_sql = "AS " + action_sql
        }
        actions_list.push(action_sql)
      }
    }
    lstrip_chars(self.format_args(actions_list), "\n")
  }
  let iceberg = g_when(
    expression.has("iceberg") && self.cfg.supports_drop_alter_iceberg_property,
    "ICEBERG ",
  )
  let exists = g_when(expression.has("exists"), " IF EXISTS")
  let on_cluster = g_pfx(" ", self.sql_key(expression, "cluster"))
  let only = g_when(expression.has("only"), " ONLY")
  let options = g_pfx(", ", self.expressions(expression~, key="options"))
  let kind = self.sql_key(expression, "kind")
  let not_valid = g_when(expression.has("not_valid"), " NOT VALID")
  let check = g_when(expression.has("check"), " WITH CHECK")
  let cascade = g_when(
    expression.has("cascade") && self.dialect.cfg.alter_table_supports_cascade,
    " CASCADE",
  )
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  "ALTER " +
  iceberg +
  kind +
  exists +
  only +
  this +
  on_cluster +
  check +
  self.sep() +
  actions_sql +
  not_valid +
  options +
  cascade
}

///|
pub fn Generator::altersession_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let items_sql = self.expressions(expression~, flat=true)
  let keyword = if expression.has("unset") { "UNSET" } else { "SET" }
  keyword + " " + items_sql
}

///|
/// Virtual `add_column_sql`.
pub fn Generator::add_column_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.add_column_sql {
    Some(f) => f(self, expression)
    None => self.add_column_sql_base(expression)
  }
}

///|
pub fn Generator::add_column_sql_base(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let sql = self.sql(Some(expression))
  let column_text = if expression.kind.is_a(Schema) {
    " COLUMNS"
  } else if expression.kind.is_a(ColumnDef) &&
    self.cfg.alter_table_include_column_keyword {
    " COLUMN"
  } else {
    ""
  }
  "ADD" + column_text + " " + sql
}

///|
pub fn Generator::droppartition_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~)
  let exists = if expression.has("exists") { " IF EXISTS " } else { " " }
  "DROP" + exists + expressions
}

///|
pub fn Generator::dropprimarykey_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore((self, expression))
  "DROP PRIMARY KEY"
}

///|
pub fn Generator::addconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "ADD " + self.expressions(expression~, indent=false)
}

///|
pub fn Generator::addpartition_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let exists = g_when(expression.has("exists"), "IF NOT EXISTS ")
  let location = g_pfx(" ", self.sql_key(expression, "location"))
  "ADD " + exists + self.sql(expression.this()) + location
}

///|
pub fn Generator::dictproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = self.sql_key(expression, "kind")
  let settings_sql = self.expressions(expression~, key="settings", sep=" ")
  let args = if settings_sql != "" {
    "(" + self.sep(sep="") + settings_sql + self.seg(")", sep="")
  } else {
    "()"
  }
  this + "(" + kind + args + ")"
}

///|
pub fn Generator::dictrange_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let max = self.sql_key(expression, "max")
  let min = self.sql_key(expression, "min")
  this + "(MIN " + min + " MAX " + max + ")"
}

///|
pub fn Generator::dictsubproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") + " " + self.sql_key(expression, "value")
}

///|
pub fn Generator::duplicatekeyproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "DUPLICATE KEY (" + self.expressions(expression~, flat=true) + ")"
}

///|
/// Virtual `uniquekeyproperty_sql(expression, prefix)`.
pub fn Generator::uniquekeyproperty_sql_v(
  self : Generator,
  expression : Expr,
  prefix? : String = "UNIQUE KEY",
) -> String raise SqlglotError {
  match self.fns.hooks.uniquekeyproperty_sql {
    Some(f) => f(self, expression, prefix)
    None => self.uniquekeyproperty_sql(expression, prefix~)
  }
}

///|
pub fn Generator::uniquekeyproperty_sql(
  self : Generator,
  expression : Expr,
  prefix? : String = "UNIQUE KEY",
) -> String raise SqlglotError {
  prefix + " (" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::distributedbyproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, flat=true)
  let expressions = if expressions != "" {
    " " + self.wrap_str(expressions)
  } else {
    ""
  }
  let buckets = self.sql_key(expression, "buckets")
  let kind = self.sql_key(expression, "kind")
  let buckets = g_pfx(" BUCKETS ", buckets)
  let order = self.sql_key(expression, "order")
  "DISTRIBUTED BY " + kind + expressions + buckets + order
}

///|
pub fn Generator::oncluster_sql(self : Generator, expression : Expr) -> String {
  ignore((self, expression))
  ""
}

///|
pub fn Generator::clusteredbyproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, key="expressions", flat=true)
  let sorted_by = g_around(
    " SORTED BY (",
    self.expressions(expression~, key="sorted_by", flat=true),
    ")",
  )
  let buckets = self.sql_key(expression, "buckets")
  "CLUSTERED BY (" +
  expressions +
  ")" +
  sorted_by +
  " INTO " +
  buckets +
  " BUCKETS"
}

///|
pub fn Generator::indexconstraintoption_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let key_block_size = self.sql_key(expression, "key_block_size")
  if key_block_size != "" {
    return "KEY_BLOCK_SIZE = " + key_block_size
  }
  let using_ = self.sql_key(expression, "using")
  if using_ != "" {
    return "USING " + using_
  }
  let parser = self.sql_key(expression, "parser")
  if parser != "" {
    return "WITH PARSER " + parser
  }
  let comment = self.sql_key(expression, "comment")
  if comment != "" {
    return "COMMENT " + comment
  }
  match expression.get("visible") {
    Some(v) => return if v.truthy() { "VISIBLE" } else { "INVISIBLE" }
    None => ()
  }
  let engine_attr = self.sql_key(expression, "engine_attr")
  if engine_attr != "" {
    return "ENGINE_ATTRIBUTE = " + engine_attr
  }
  let secondary_engine_attr = self.sql_key(expression, "secondary_engine_attr")
  if secondary_engine_attr != "" {
    return "SECONDARY_ENGINE_ATTRIBUTE = " + secondary_engine_attr
  }
  self.unsupported("Unsupported index constraint option.")
  ""
}

///|
pub fn Generator::checkcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let enforced = g_when(expression.has("enforced"), " ENFORCED")
  "CHECK (" + self.sql_key(expression, "this") + ")" + enforced
}

///|
pub fn Generator::indexcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let kind = if kind != "" { kind + " INDEX" } else { "INDEX" }
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let index_type = g_pfx(" USING ", self.sql_key(expression, "index_type"))
  let expressions = g_around(" (", self.expressions(expression~, flat=true), ")")
  let options = g_pfx(" ", self.expressions(expression~, key="options", sep=" "))
  kind + this + index_type + expressions + options
}

///|
pub fn Generator::truncatetable_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let target = if expression.has("is_database") { "DATABASE" } else { "TABLE" }
  let tables = " " + self.expressions(expression~)
  let exists = g_when(expression.has("exists"), " IF EXISTS")
  let on_cluster = g_pfx(" ", self.sql_key(expression, "cluster"))
  let identity = g_around(" ", self.sql_key(expression, "identity"), " IDENTITY")
  let option = g_pfx(" ", self.sql_key(expression, "option"))
  let partition = g_pfx(" ", self.sql_key(expression, "partition"))
  "TRUNCATE " +
  target +
  exists +
  tables +
  on_cluster +
  identity +
  option +
  partition
}

///|
pub fn Generator::copyparameter_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let option = self.sql_key(expression, "this")
  if !expression.expressions().is_empty() {
    let upper = py_upper(option)
    let sep = if upper == "FILE_FORMAT" { " " } else { ", " }
    let op = if upper == "COPY_OPTIONS" || upper == "FORMAT_OPTIONS" {
      " "
    } else {
      " = "
    }
    let values = self.expressions(expression~, flat=true, sep~)
    return option + op + "(" + values + ")"
  }
  let value = self.sql_key(expression, "expression")
  if value == "" {
    return option
  }
  let op = if self.cfg.copy_params_eq_required { " = " } else { " " }
  option + op + value
}

///|
pub fn Generator::credentials_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let cred_expr = expression.get("credentials")
  let credentials = match cred_expr {
    Some(Node(c)) if c.kind.is_a(Literal) =>
      g_pfx("CREDENTIALS ", self.sql_key(expression, "credentials"))
    _ => {
      let credentials = self.expressions(
        expression~,
        key="credentials",
        flat=true,
        sep=" ",
      )
      if cred_expr is Some(_) {
        "CREDENTIALS = (" + credentials + ")"
      } else {
        ""
      }
    }
  }
  let storage = g_pfx(
    "STORAGE_INTEGRATION = ",
    self.sql_key(expression, "storage"),
  )
  let encryption = g_around(
    " ENCRYPTION = (",
    self.expressions(expression~, key="encryption", flat=true, sep=" "),
    ")",
  )
  let iam_role = g_pfx("IAM_ROLE ", self.sql_key(expression, "iam_role"))
  let region = g_pfx(" REGION ", self.sql_key(expression, "region"))
  credentials + storage + encryption + iam_role + region
}

///|
pub fn Generator::copy_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let this = if self.cfg.copy_has_into_keyword {
    " INTO " + this
  } else {
    " " + this
  }
  let credentials = self.sql_key(expression, "credentials")
  let credentials = if credentials != "" { self.seg(credentials) } else { "" }
  let files = self.expressions(expression~, key="files", flat=true)
  let kind = if files != "" {
    self.seg(if expression.has("kind") { "FROM" } else { "TO" })
  } else {
    ""
  }
  let sep = if self.dialect.cfg.copy_params_are_csv { ", " } else { " " }
  let mut params = self.expressions(
    expression~,
    key="params",
    sep~,
    new_line=true,
    skip_last=true,
    skip_first=true,
    indent=self.cfg.copy_params_are_wrapped,
  )
  if params != "" {
    if self.cfg.copy_params_are_wrapped {
      params = " WITH (" + params + ")"
    } else if !self.pretty && (files != "" || credentials != "") {
      params = " " + params
    }
  }
  "COPY" + this + kind + " " + files + credentials + params
}

///|
pub fn Generator::datadeletionproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut on_sql = if expression.has("on") { "ON" } else { "OFF" }
  let filter_col = self.sql_key(expression, "filter_column")
  let filter_col : String? = if filter_col != "" {
    Some("FILTER_COLUMN=" + filter_col)
  } else {
    None
  }
  let retention_period = self.sql_key(expression, "retention_period")
  let retention_period : String? = if retention_period != "" {
    Some("RETENTION_PERIOD=" + retention_period)
  } else {
    None
  }
  if filter_col is Some(_) || retention_period is Some(_) {
    on_sql = self.func("ON", [filter_col, retention_period])
  }
  "DATA_DELETION=" + on_sql
}

///|
pub fn Generator::maskingpolicycolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expressions = g_around(
    " USING (",
    self.expressions(expression~, flat=true),
    ")",
  )
  "MASKING POLICY " + this + expressions
}

///|
pub fn Generator::attach_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let exists_sql = g_when(expression.has("exists"), " IF NOT EXISTS")
  let expressions = g_around(" (", self.expressions(expression~), ")")
  "ATTACH" + exists_sql + " " + this + expressions
}

///|
pub fn Generator::detach_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let exists = g_when(expression.has("exists"), " IF EXISTS")
  if exists != "" && kind == "" {
    kind = " DATABASE"
  }
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let cluster = g_pfx(" ", self.sql_key(expression, "cluster"))
  let permanent = g_when(expression.has("permanent"), " PERMANENTLY")
  let sync = g_when(expression.has("sync"), " SYNC")
  "DETACH" + kind + exists + this + cluster + permanent + sync
}

///|
pub fn Generator::attachoption_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let value = g_pfx(" ", self.sql_key(expression, "expression"))
  this + value
}

///|
pub fn Generator::watermarkcolumnconstraint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "WATERMARK FOR " +
  self.sql_key(expression, "this") +
  " AS " +
  self.sql_key(expression, "expression")
}

///|
pub fn Generator::encodeproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let encode = if expression.has("key") { "KEY ENCODE" } else { "ENCODE" }
  let mut encode = encode + " " + self.sql_key(expression, "this")
  match expression.arg("properties") {
    Some(p) => encode = encode + " " + self.properties(p)
    None => ()
  }
  encode
}

///|
pub fn Generator::includeproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let mut include_ = "INCLUDE " + this
  let column_def = self.sql_key(expression, "column_def")
  if column_def != "" {
    include_ = include_ + " " + column_def
  }
  let alias_ = self.sql_key(expression, "alias")
  if alias_ != "" {
    include_ = include_ + " AS " + alias_
  }
  include_
}

///|
pub fn Generator::partitionbyrangeproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let partitions = self.expressions(expression~, key="partition_expressions")
  let create = self.expressions(expression~, key="create_expressions")
  "PARTITION BY RANGE " +
  self.wrap_str(partitions) +
  " " +
  self.wrap_str(create)
}

///|
pub fn Generator::partitionbyrangepropertydynamic_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let start = self.sql_key(expression, "start")
  let end = self.sql_key(expression, "end")
  let every = expression.arg("every")
  match every {
    Some(ev) if ev.kind.is_a(Interval) =>
      match ev.this() {
        Some(t) if t.is_string() =>
          t.replace(Some(literal_number(ev.name()))) |> ignore
        _ => ()
      }
    _ => ()
  }
  "START " +
  self.wrap_str(start) +
  " END " +
  self.wrap_str(end) +
  " EVERY " +
  self.wrap_str(self.sql(every))
}

///|
pub fn Generator::unpivotcolumns_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let name = self.sql_key(expression, "this")
  let values = self.expressions(expression~, flat=true)
  "NAME " + name + " VALUE " + values
}

///|
pub fn Generator::analyzesample_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let sample = self.sql_key(expression, "sample")
  "SAMPLE " + sample + " " + kind
}

///|
pub fn Generator::analyzestatistics_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let option = g_pfx(" ", self.sql_key(expression, "option"))
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let columns = g_pfx(" ", self.expressions(expression~))
  kind + option + " STATISTICS" + this + columns
}

///|
pub fn Generator::analyzehistogram_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let columns = self.expressions(expression~)
  let inner_expression = g_pfx(" ", self.sql_key(expression, "expression"))
  let update_options = g_around(
    " ",
    self.sql_key(expression, "update_options"),
    " UPDATE",
  )
  this + " HISTOGRAM ON " + columns + inner_expression + update_options
}

///|
pub fn Generator::analyzedelete_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  "DELETE" + kind + " STATISTICS"
}

///|
pub fn Generator::analyzelistchainedrows_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "LIST CHAINED ROWS" + self.sql_key(expression, "expression")
}

///|
pub fn Generator::analyzevalidate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let inner_expression = self.sql_key(expression, "expression")
  "VALIDATE " + kind + this + inner_expression
}

///|
pub fn Generator::analyze_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let options = g_pfx(" ", self.expressions(expression~, key="options", sep=" "))
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let tables = g_pfx(" ", self.expressions(expression~, key="tables", flat=true))
  let mode = g_pfx(" ", self.sql_key(expression, "mode"))
  let properties = g_pfx(" ", self.sql_key(expression, "properties"))
  let partition = g_pfx(" ", self.sql_key(expression, "partition"))
  let inner_expression = g_pfx(" ", self.sql_key(expression, "expression"))
  "ANALYZE" +
  options +
  kind +
  tables +
  partition +
  mode +
  inner_expression +
  properties
}

///|
pub fn Generator::declare_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let replace = g_when(expression.has("replace"), "OR REPLACE ")
  "DECLARE " + replace + self.expressions(expression~, flat=true)
}

///|
pub fn Generator::declareitem_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let variables = self.expressions(expression~, key="this")
  let default = g_pfx(
    " " + self.cfg.declare_default_assignment + " ",
    self.sql_key(expression, "default"),
  )
  let mut kind = self.sql_key(expression, "kind")
  match expression.arg("kind") {
    Some(k) if k.kind.is_a(Schema) => kind = "TABLE " + kind
    _ => ()
  }
  let kind = g_pfx(" ", kind)
  variables + kind + default
}

///|
pub fn Generator::recursivewithsearch_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let this = self.sql_key(expression, "this")
  let set = self.sql_key(expression, "expression")
  let using_ = g_pfx(" USING ", self.sql_key(expression, "using"))
  let kind_sql = if kind == "CYCLE" {
    kind
  } else {
    "SEARCH " + kind + " FIRST BY"
  }
  kind_sql + " " + this + " SET " + set + using_
}

///|
pub fn Generator::show_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported("Unsupported SHOW statement")
  ""
}

///|
pub fn Generator::install_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported("Unsupported INSTALL statement")
  ""
}

///|
pub fn Generator::get_put_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let props_sql = match expression.arg("properties") {
    Some(p) => self.properties(p, prefix=" ", sep=" ", wrapped=false)
    None => ""
  }
  let this = self.sql_key(expression, "this")
  let target = self.sql_key(expression, "target")
  if expression.kind.is_a(Put) {
    "PUT " + this + " " + target + props_sql
  } else {
    "GET " + target + " " + this + props_sql
  }
}

///|
pub fn Generator::buildproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "BUILD " + self.sql_key(expression, "this")
}

///|
pub fn Generator::refreshtriggerproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let method_ = self.sql_key(expression, "method")
  let kind = match expression.get("kind") {
    Some(v) if v.truthy() => py_str_value(Some(v))
    _ => return "REFRESH " + method_
  }
  let every = self.sql_key(expression, "every")
  let unit = self.sql_key(expression, "unit")
  let every = if every != "" { " EVERY " + every + " " + unit } else { "" }
  let starts = g_pfx(" STARTS ", self.sql_key(expression, "starts"))
  "REFRESH " + method_ + " ON " + kind + every + starts
}

///|
pub fn Generator::altermodifysqlsecurity_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let props = self.expressions(expression~, sep=" ")
  "MODIFY " + props
}

///|
pub fn Generator::usingproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = py_str_value(expression.get("kind"))
  "USING " + kind + " " + self.sql_key(expression, "this")
}

///|
pub fn Generator::renameindex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let to = self.sql_key(expression, "to")
  "RENAME INDEX " + this + " TO " + to
}

///|
pub fn Generator::export_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let connection = g_around(
    "WITH CONNECTION ",
    self.sql_key(expression, "connection"),
    " ",
  )
  let options = self.sql_key(expression, "options")
  "EXPORT DATA " + connection + options + " AS " + this
}

///|
pub fn Generator::use_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let this = self.sql_key(expression, "this")
  let this = if this != "" {
    this
  } else {
    self.expressions(expression~, flat=true)
  }
  let this = g_pfx(" ", this)
  "USE" + kind + this
}

///|
pub fn Generator::command_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " " +
  py_strip(expression.text("expression"))
}

///|
pub fn Generator::loaddata_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let is_overwrite = expression.has("overwrite")
  let overwrite = g_when(is_overwrite, " OVERWRITE")
  let mut this = self.sql_key(expression, "this")
  match expression.arg("files") {
    Some(files) => {
      let files_sql = self.expressions(expression=files, flat=true)
      let files_sql = "FILES" + self.wrap_str(files_sql)
      if is_overwrite {
        this = " " + this
      } else if expression.has("temp") {
        this = " INTO TEMP TABLE " + this
      } else {
        this = " INTO TABLE " + this
      }
      return "LOAD DATA" + overwrite + this + " FROM " + files_sql
    }
    None => ()
  }
  let local_ = g_when(expression.has("local"), " LOCAL")
  let inpath = " INPATH " + self.sql_key(expression, "inpath")
  let this = " INTO TABLE " + this
  let partition = g_pfx(" ", self.sql_key(expression, "partition"))
  let input_format = g_pfx(
    " INPUTFORMAT ",
    self.sql_key(expression, "input_format"),
  )
  let serde = g_pfx(" SERDE ", self.sql_key(expression, "serde"))
  "LOAD DATA" +
  local_ +
  inpath +
  overwrite +
  this +
  partition +
  input_format +
  serde
}

///|
pub fn Generator::token_sql(self : Generator, token_type : TokenType) -> String {
  match self.cfg.token_mapping.get(token_type) {
    Some(s) => s
    None => token_type.name()
  }
}

///|
/// Python `_grant_or_revoke_sql`.
pub fn Generator::grant_or_revoke_sql(
  self : Generator,
  expression : Expr,
  keyword~ : String,
  preposition~ : String,
  grant_option_prefix? : String = "",
  grant_option_suffix? : String = "",
) -> String raise SqlglotError {
  let privileges_sql = self.expressions(
    expression~,
    key="privileges",
    flat=true,
  )
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let securable = g_pfx(" ", self.sql_key(expression, "securable"))
  let principals = self.expressions(expression~, key="principals", flat=true)
  let (grant_option_prefix, grant_option_suffix) = if !expression.has(
      "grant_option",
    ) {
    ("", "")
  } else {
    (grant_option_prefix, grant_option_suffix)
  }
  let cascade = g_pfx(" ", self.sql_key(expression, "cascade"))
  keyword +
  " " +
  grant_option_prefix +
  privileges_sql +
  " ON" +
  kind +
  securable +
  " " +
  preposition +
  " " +
  principals +
  grant_option_suffix +
  cascade
}

///|
pub fn Generator::grant_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.grant_or_revoke_sql(
    expression,
    keyword="GRANT",
    preposition="TO",
    grant_option_suffix=" WITH GRANT OPTION",
  )
}

///|
pub fn Generator::revoke_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.grant_or_revoke_sql(
    expression,
    keyword="REVOKE",
    preposition="FROM",
    grant_option_prefix="GRANT OPTION FOR ",
  )
}

///|
pub fn Generator::grantprivilege_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let columns = g_around("(", self.expressions(expression~, flat=true), ")")
  this + columns
}

///|
pub fn Generator::grantprincipal_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = self.sql_key(expression, "kind")
  let kind = if kind != "" { kind + " " } else { "" }
  kind + this
}
