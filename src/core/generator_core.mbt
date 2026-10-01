// Core machinery of the SQL generator (port of sqlglot/generator.py `Generator`).
//
// Dispatch (mirrors Python `_build_dispatch`):
//   `sql(e)` -> `fns.transforms[kind]` (exact kind) -> `fns.methods[kind]` (dialect
//   `<key>_sql` overrides) -> `base_dispatch` (base `<key>_sql` methods) -> `Func`
//   fallback -> `Property` fallback -> error.
//
// Conventions for dialect overrides:
//   * `Generator::<key>_sql` is always the BASE implementation (call it as `super()`).
//   * A Python direct call `self.<key>_sql(e)` (virtual) is `self.call_method(Kind, e)`.
//   * `_sql` methods with extra parameters have a typed hook in `GeneratorHooks` and a
//     virtual wrapper `Generator::<key>_sql_v(...)`.
//   * Overridable helper methods (e.g. `column_parts`) have a typed hook, a virtual
//     wrapper `Generator::<name>` and the base implementation `Generator::<name>_base`.

///|
pub type GenFn = (Generator, Expr) -> String raise SqlglotError

///|
/// Result of `locate_properties`: properties grouped by their location.
pub type PropLocs = Map[PropertiesLocation, Array[Expr]]

///|
/// Typed hooks for Generator methods that dialects override and that are called
/// virtually from base code (or have extra parameters).
pub(all) struct GeneratorHooks {
  // Helper methods: virtual wrapper `Generator::<name>`, base `Generator::<name>_base`.
  mut add_column_sql : GenFn?
  mut after_limit_modifiers : ((Generator, Expr) -> Array[String] raise SqlglotError)?
  mut column_parts : GenFn?
  mut createable_sql : ((Generator, Expr, PropLocs) -> String raise SqlglotError)?
  mut format_time : ((Generator, Expr, Map[String, String]?, Trie?) -> String? raise SqlglotError)?
  mut generate : ((Generator, Expr, Bool) -> String raise SqlglotError)?
  mut in_unnest_op : GenFn?
  mut lateral_op : GenFn?
  mut locate_properties : ((Generator, Expr) -> PropLocs raise SqlglotError)?
  mut offset_limit_modifiers : ((Generator, Expr, Bool, Expr?) -> Array[String] raise SqlglotError)?
  mut options_modifier : GenFn?
  mut scope_resolution : ((Generator, String, String) -> String raise SqlglotError)?
  mut set_operations : GenFn?
  mut table_parts : GenFn?
  mut with_properties : GenFn?
  mut preprocess : GenExprFn?
  // `_sql` methods with extra parameters: virtual wrapper `Generator::<name>_v`,
  // base `Generator::<name>`. These hooks are also used by `sql()` dispatch.
  mut alterrename_sql : ((Generator, Expr, Bool) -> String raise SqlglotError)?
  mut arrayinsert_sql : ((Generator, Expr, Int) -> String raise SqlglotError)?
  mut cast_sql : ((Generator, Expr, String?) -> String raise SqlglotError)?
  mut chr_sql : ((Generator, Expr, String) -> String raise SqlglotError)?
  mut columndef_sql : ((Generator, Expr, String) -> String raise SqlglotError)?
  mut hexstring_sql : ((Generator, Expr, String?) -> String raise SqlglotError)?
  mut lambda_sql : ((Generator, Expr, String, Bool) -> String raise SqlglotError)?
  mut table_sql : ((Generator, Expr, String) -> String raise SqlglotError)?
  mut tablesample_sql : ((Generator, Expr, String?) -> String raise SqlglotError)?
  mut uniquekeyproperty_sql : ((Generator, Expr, String) -> String raise SqlglotError)?
  mut values_sql : ((Generator, Expr, Bool) -> String raise SqlglotError)?
  // Callable class attributes.
  /// `UNICODE_SUBSTITUTE`: receives the escaped code (regex group 1).
  mut unicode_substitute : ((String) -> String)?
  /// `SAFE_JSON_PATH_KEY_RE.match`; `None` means `SAFE_IDENTIFIER_RE`.
  mut safe_json_path_key_re : ((String) -> Bool)?
}

///|
pub type GenExprFn = (Generator, Expr) -> Expr raise SqlglotError

///|
pub fn GeneratorHooks::new() -> GeneratorHooks {
  {
    add_column_sql: None,
    after_limit_modifiers: None,
    column_parts: None,
    createable_sql: None,
    format_time: None,
    generate: None,
    in_unnest_op: None,
    lateral_op: None,
    locate_properties: None,
    offset_limit_modifiers: None,
    options_modifier: None,
    scope_resolution: None,
    set_operations: None,
    table_parts: None,
    with_properties: None,
    preprocess: None,
    alterrename_sql: None,
    arrayinsert_sql: None,
    cast_sql: None,
    chr_sql: None,
    columndef_sql: None,
    hexstring_sql: None,
    lambda_sql: None,
    table_sql: None,
    tablesample_sql: None,
    uniquekeyproperty_sql: None,
    values_sql: None,
    unicode_substitute: None,
    safe_json_path_key_re: None,
  }
}

///|
pub fn GeneratorHooks::copy(self : GeneratorHooks) -> GeneratorHooks {
  { ..self, }
}

///|
/// Callable class attributes of the Python `Generator` plus method override hooks.
pub(all) struct GeneratorFns {
  /// `TRANSFORMS`: exact kind -> generator function. Takes precedence over methods
  /// (mirrors Python `_build_dispatch`).
  mut transforms : Map[Kind, GenFn]
  /// Dialect `<key>_sql` method overrides. Used by `sql()` dispatch after
  /// `transforms`, and by virtual calls `Generator::call_method`.
  mut methods : Map[Kind, GenFn]
  /// Typed overrides of helper methods / methods with extra parameters.
  mut hooks : GeneratorHooks
  /// `TYPE_PARAM_SETTINGS`: dtype -> (defaults, bounds)
  mut type_param_settings : Map[DType, (Array[Int], Array[Int?])]
  /// `AFTER_HAVING_MODIFIER_TRANSFORMS`
  mut after_having_modifier_transforms : Array[(String, GenFn)]
}

///|
pub fn GeneratorFns::copy(self : GeneratorFns) -> GeneratorFns {
  {
    transforms: Map::from_iter(self.transforms.iter()),
    methods: Map::from_iter(self.methods.iter()),
    hooks: self.hooks.copy(),
    type_param_settings: Map::from_iter(self.type_param_settings.iter()),
    after_having_modifier_transforms: self.after_having_modifier_transforms.copy(),
  }
}

///|
/// Converts a given syntax tree to the corresponding SQL string.
pub(all) struct Generator {
  dialect : Dialect
  cfg : GeneratorConfig
  fns : GeneratorFns
  pretty : Bool
  /// Python `identify`: "" (False), "always" (True), "safe" or "unsafe".
  mut identify : String
  normalize : Bool
  pad : Int
  indent_size : Int
  /// Python `normalize_functions`: "upper", "lower" or "" (False).
  normalize_functions : String
  unsupported_level : ErrorLevel
  max_unsupported : Int
  leading_comma : Bool
  max_text_width : Int
  comments : Bool
  mut unsupported_messages : Array[String]
  escaped_quote_end : String
  escaped_byte_quote_end : String
  escaped_identifier_end : String
  next_name : () -> String
  identifier_start : String
  identifier_end : String
  mut quote_json_path_key_using_brackets : Bool
}

///|
/// Python's module-level `sqlglot.pretty`: the default for generators created without
/// an explicit `pretty` option.
pub let default_pretty : Ref[Bool] = Ref(false)

///|
pub fn Generator::new(
  dialect : Dialect,
  pretty? : Bool,
  identify? : String = "",
  normalize? : Bool = false,
  pad? : Int = 2,
  indent? : Int = 2,
  normalize_functions? : String,
  unsupported_level? : ErrorLevel = Warn,
  max_unsupported? : Int = 3,
  leading_comma? : Bool = false,
  max_text_width? : Int = 80,
  comments? : Bool = true,
) -> Generator {
  let normalize_functions = match normalize_functions {
    Some(n) => n
    None =>
      match dialect.cfg.normalize_functions {
        S(s) => s
        B(true) => "upper"
        B(false) => ""
      }
  }
  let pretty = match pretty {
    Some(p) => p
    None => default_pretty.val
  }
  let identify = match identify {
    "true" | "True" => "always"
    "false" | "False" => ""
    s => s
  }
  let string_escapes = dialect.tokenizer.string_escapes
  let first_escape = if string_escapes.is_empty() {
    ""
  } else {
    string_escapes[0]
  }
  {
    dialect,
    cfg: dialect.gen_cfg,
    fns: dialect.gen_fns,
    pretty,
    identify,
    normalize,
    pad,
    indent_size: indent,
    normalize_functions,
    unsupported_level,
    max_unsupported,
    leading_comma,
    max_text_width,
    comments,
    unsupported_messages: [],
    escaped_quote_end: first_escape + dialect.cfg.quote_end,
    escaped_byte_quote_end: match dialect.cfg.byte_end {
      Some(e) if e != "" => first_escape + e
      _ => ""
    },
    escaped_identifier_end: dialect.cfg.identifier_end +
    dialect.cfg.identifier_end,
    next_name: name_sequence("_t"),
    identifier_start: dialect.cfg.identifier_start,
    identifier_end: dialect.cfg.identifier_end,
    quote_json_path_key_using_brackets: true,
  }
}

///|
/// Generates SQL for `expression` with the base dialect and default settings
/// (Python `str(expression)` / `expression.sql()`).
pub fn expr_to_sql(expression : Expr) -> String raise SqlglotError {
  Generator::new(base_dialect()).generate(expression)
}

///|
/// Generates the SQL string corresponding to the given syntax tree (virtual).
pub fn Generator::generate(
  self : Generator,
  expression : Expr,
  copy? : Bool = true,
) -> String raise SqlglotError {
  match self.fns.hooks.generate {
    Some(f) => f(self, expression, copy)
    None => self.generate_base(expression, copy~)
  }
}

///|
pub fn Generator::generate_base(
  self : Generator,
  expression : Expr,
  copy? : Bool = true,
) -> String raise SqlglotError {
  let expression = if copy { expression.copy() } else { expression }
  let expression = self.preprocess(expression)
  self.unsupported_messages = []
  let mut sql = py_strip(self.sql(Some(expression)))
  if self.pretty {
    sql = sql.replace_all(old=self.cfg.sentinel_line_break, new="\n")
  }
  match self.unsupported_level {
    Ignore => return sql
    Warn =>
      for msg in self.unsupported_messages {
        log_warning(msg)
      }
    Raise =>
      if !self.unsupported_messages.is_empty() {
        raise UnsupportedError(
          concat_messages(self.unsupported_messages, self.max_unsupported),
        )
      }
    Immediate => ()
  }
  sql
}

///|
/// Apply generic preprocessing transformations to a given expression.
pub fn Generator::preprocess(
  self : Generator,
  expression : Expr,
) -> Expr raise SqlglotError {
  match self.fns.hooks.preprocess {
    Some(f) => f(self, expression)
    None => self.preprocess_base(expression)
  }
}

///|
pub fn Generator::preprocess_base(
  self : Generator,
  expression : Expr,
) -> Expr raise SqlglotError {
  let mut expression = self.move_ctes_to_top_level(expression)
  if self.cfg.ensure_bools {
    expression = ensure_bools(expression)
  }
  expression
}

///|
/// Python `_move_ctes_to_top_level`.
pub fn Generator::move_ctes_to_top_level(
  self : Generator,
  expression : Expr,
) -> Expr {
  if expression.parent is None &&
    self.cfg.expressions_without_nested_ctes.contains(expression.kind) &&
    expression
    .find_all([With])
    .any(node => {
      match node.parent {
        Some(p) => !physical_equal(p, expression)
        None => true
      }
    }) {
    move_ctes_to_top_level(expression)
  } else {
    expression
  }
}

///|
pub fn Generator::unsupported(
  self : Generator,
  message : String,
) -> Unit raise SqlglotError {
  if self.unsupported_level == Immediate {
    raise UnsupportedError(message)
  }
  self.unsupported_messages.push(message)
}

///|
pub fn Generator::sep(self : Generator, sep? : String = " ") -> String {
  if self.pretty {
    py_strip(sep) + "\n"
  } else {
    sep
  }
}

///|
pub fn Generator::seg(
  self : Generator,
  sql : String,
  sep? : String = " ",
) -> String {
  self.sep(sep~) + sql
}

///|
pub fn Generator::sanitize_comment(
  self : Generator,
  comment : String,
) -> String {
  ignore(self)
  let mut comment = comment
  match g_first_char(comment) {
    Some(c) if !is_space(c) => comment = " " + comment
    _ => ()
  }
  match g_last_char(comment) {
    Some(c) if !is_space(c) => comment = comment + " "
    _ => ()
  }
  comment.replace_all(old="*/", new="* /").replace_all(old="/*", new="/ *")
}

///|
pub fn Generator::maybe_comment(
  self : Generator,
  sql : String,
  expression? : Expr,
  comments? : Array[String],
  separated? : Bool = false,
) -> String {
  let comments = if self.comments {
    match comments {
      Some(c) => Some(c)
      None =>
        match expression {
          Some(e) => e.comments
          None => None
        }
    }
  } else {
    None
  }
  let comments = match comments {
    Some(c) if !c.is_empty() => c
    _ => return sql
  }
  match expression {
    Some(e) => if e.kind.is_any(self.cfg.exclude_comments) { return sql }
    None => ()
  }
  let comments_list = []
  for comment in comments {
    if comment != "" {
      comments_list.push(
        "/*" + self.replace_line_breaks(self.sanitize_comment(comment)) + "*/",
      )
    }
  }
  if comments_list.is_empty() {
    return sql
  }
  let sep_comments = separated ||
    (match expression {
      Some(e) => e.kind.is_any(self.cfg.with_separated_comments)
      None => false
    })
  if sep_comments {
    let comments_sql = comments_list.join(self.sep())
    match g_first_char(sql) {
      None => self.sep() + comments_sql + sql
      Some(c) if is_space(c) => self.sep() + comments_sql + sql
      _ => comments_sql + self.sep() + sql
    }
  } else {
    sql + " " + comments_list.join(" ")
  }
}

///|
/// `wrap(expression)` for an expression.
pub fn Generator::wrap(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = if expression.kind.is_any([Select, SetOperation]) {
    self.sql(Some(expression))
  } else {
    self.sql_key(expression, "this")
  }
  self.wrap_sql(this_sql)
}

///|
/// `wrap(sql)` for an already generated SQL string.
pub fn Generator::wrap_str(self : Generator, sql : String) -> String {
  self.wrap_sql(sql)
}

///|
pub fn Generator::wrap_sql(self : Generator, this_sql : String) -> String {
  if this_sql == "" {
    return "()"
  }
  let this_sql = self.indent(this_sql, level=1, pad=0)
  "(" + self.sep(sep="") + this_sql + self.seg(")", sep="")
}

///|
/// Runs `f` with `identify` disabled.
pub fn[T] Generator::no_identify(
  self : Generator,
  f : () -> T raise SqlglotError,
) -> T raise SqlglotError {
  let original = self.identify
  self.identify = ""
  let result = f()
  self.identify = original
  result
}

///|
pub fn Generator::normalize_func(self : Generator, name : String) -> String {
  if self.normalize_functions == "upper" {
    py_upper(name)
  } else if self.normalize_functions == "lower" {
    py_lower(name)
  } else {
    name
  }
}

///|
pub fn Generator::indent(
  self : Generator,
  sql : String,
  level? : Int = 0,
  pad? : Int,
  skip_first? : Bool = false,
  skip_last? : Bool = false,
) -> String {
  if !self.pretty || sql == "" {
    return sql
  }
  let pad = match pad {
    Some(p) => p
    None => self.pad
  }
  let lines = py_split(sql, "\n")
  let n = lines.length()
  let prefix = " ".repeat(level * self.indent_size + pad)
  let out = []
  for i, line in lines {
    if (skip_first && i == 0) || (skip_last && i == n - 1) {
      out.push(line)
    } else {
      out.push(prefix + line)
    }
  }
  out.join("\n")
}

///|
/// Generates SQL for an expression (Python `self.sql(expression)`).
pub fn Generator::sql(
  self : Generator,
  expression : Expr?,
  comment? : Bool = true,
) -> String raise SqlglotError {
  guard expression is Some(e) else { return "" }
  let kind = e.kind
  let sql = match self.fns.transforms.get(kind) {
    Some(f) => f(self, e)
    None =>
      match self.fns.methods.get(kind) {
        Some(f) => f(self, e)
        None => self.default_sql(kind, e)
      }
  }
  if self.comments && comment {
    self.maybe_comment(sql, expression=e)
  } else {
    sql
  }
}

///|
/// The base generation of `e` (no dialect transform or method override applies).
fn Generator::default_sql(
  self : Generator,
  kind : Kind,
  e : Expr,
) -> String raise SqlglotError {
  if is_unary_chain_kind(kind) {
    match self.unary_chain_sql(e) {
      Some(s) => return s
      None => ()
    }
  }
  match self.base_dispatch(kind, e) {
    Some(s) => s
    None =>
      if kind.is_a(Func) {
        self.function_fallback_sql(e)
      } else if kind.is_a(Property) {
        self.call_method(Property, e)
      } else {
        raise ValueError("Unsupported expression type \{kind.name()}")
      }
  }
}

///|
fn is_unary_chain_kind(kind : Kind) -> Bool {
  kind is (Neg | Not | Paren | BitwiseNot)
}

///|
/// Chains shorter than this are generated recursively.
let unary_chain_min_length : Int = 64

///|
/// Generates a long chain of NOT / unary minus / ~ / parentheses (e.g. `NOT NOT ... x`
/// or `((((x))))`) without one level of recursion per link: the innermost operand is
/// generated, then each link's base `*_sql` formatting (and comment) is applied from the
/// inside out, producing exactly what the recursive calls produce. Links whose
/// generation a dialect overrides end the chain. Returns `None` for short chains.
fn Generator::unary_chain_sql(
  self : Generator,
  e : Expr,
) -> String? raise SqlglotError {
  let chain = [e]
  let mut cur = e
  for ;; {
    match cur.args.get("this") {
      Some(Node(c)) if is_unary_chain_kind(c.kind) &&
        self.fns.transforms.get(c.kind) is None &&
        self.fns.methods.get(c.kind) is None => {
        chain.push(c)
        cur = c
      }
      _ => break
    }
  }
  if chain.length() < unary_chain_min_length {
    return None
  }
  // The text is `prefixes (outermost last) + inner + suffixes (innermost first)`, kept
  // apart so that each link costs O(1) instead of copying the text built so far;
  // pretty parentheses (which re-indent their contents) and comments materialize it.
  let mut inner = self.sql_key(cur, "this")
  let prefixes : Array[String] = []
  let suffixes : Array[String] = []
  let materialize = () => {
    if prefixes.is_empty() && suffixes.is_empty() {
      return inner
    }
    let sb = StringBuilder()
    for i = prefixes.length() - 1; i >= 0; i = i - 1 {
      sb.write_string(prefixes[i])
    }
    sb.write_string(inner)
    for x in suffixes {
      sb.write_string(x)
    }
    prefixes.clear()
    suffixes.clear()
    sb.to_string()
  }
  for i = chain.length() - 1; i >= 0; i = i - 1 {
    let node = chain[i]
    match node.kind {
      Neg => {
        let starts_with_minus = match prefixes.last() {
          Some(p) => p.has_prefix("-")
          None => inner.has_prefix("-")
        }
        prefixes.push(if starts_with_minus { "- " } else { "-" })
      }
      Not => prefixes.push("NOT ")
      BitwiseNot => prefixes.push("~")
      _ =>
        if self.pretty {
          inner = "(" +
            self.seg(self.indent(materialize()), sep="") +
            self.seg(")", sep="")
        } else {
          prefixes.push("(")
          suffixes.push(")")
        }
    }
    // the inner links are generated through `sql_key`, i.e. with their comments
    if i > 0 &&
      self.comments &&
      (match node.comments {
        Some(c) => !c.is_empty()
        None => false
      }) {
      inner = self.maybe_comment(materialize(), expression=node)
    }
  }
  Some(materialize())
}

///|
/// Python `self.sql(expression, key)`.
pub fn Generator::sql_key(
  self : Generator,
  expression : Expr,
  key : String,
) -> String raise SqlglotError {
  match expression.args.get(key) {
    Some(v) if v.truthy() => self.sql_value(v)
    _ => ""
  }
}

///|
/// Python `self.sql(value)` for an argument value.
pub fn Generator::sql_value(
  self : Generator,
  value : Value,
  comment? : Bool = true,
) -> String raise SqlglotError {
  match value {
    Node(e) => self.sql(Some(e), comment~)
    Str(s) => s
    List(l) =>
      if l.is_empty() {
        ""
      } else {
        raise ValueError("Unsupported expression type list")
      }
    Bool(b) =>
      if b {
        raise ValueError("Unsupported expression type bool")
      } else {
        ""
      }
    Int(i) => if i == 0 { "" } else { i.to_string() }
    DT(d) => raise ValueError("Unsupported expression type \{d}")
  }
}

///|
/// Virtual call of a `<key>_sql` method: a dialect override if present, else the
/// base implementation (Python `self.<key>_sql(expression)`).
pub fn Generator::call_method(
  self : Generator,
  kind : Kind,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.methods.get(kind) {
    Some(f) => f(self, expression)
    None =>
      match self.base_dispatch(kind, expression) {
        Some(s) => s
        None =>
          if kind == Property || kind.is_a(Property) {
            self.property_sql(expression)
          } else {
            raise ValueError("No generator method for \{kind.name()}")
          }
      }
  }
}

///|
/// An argument of `func` / `format_args`: an expression, a SQL string or `None`.
pub trait SqlArg {
  fn arg_sql(Self, Generator) -> String? raise SqlglotError
}

///|
pub impl SqlArg for Expr with fn arg_sql(self, g) {
  Some(g.sql(Some(self)))
}

///|
pub impl SqlArg for String with fn arg_sql(self, _g) {
  Some(self)
}

///|
pub impl SqlArg for Value with fn arg_sql(self, g) {
  match self {
    Bool(_) => None
    v => Some(g.sql_value(v))
  }
}

///|
pub impl[T : SqlArg] SqlArg for T? with fn arg_sql(self, g) {
  match self {
    Some(x) => x.arg_sql(g)
    None => None
  }
}

///|
pub fn Generator::func(
  self : Generator,
  name : String,
  args : Array[&SqlArg],
  prefix? : String = "(",
  suffix? : String = ")",
  normalize? : Bool = true,
) -> String raise SqlglotError {
  let name = if normalize { self.normalize_func(name) } else { name }
  name + prefix + self.format_args(args) + suffix
}

///|
pub fn Generator::format_args(
  self : Generator,
  args : Array[&SqlArg],
  sep? : String = ", ",
) -> String raise SqlglotError {
  let arg_sqls = []
  for arg in args {
    match arg.arg_sql(self) {
      Some(s) => arg_sqls.push(s)
      None => ()
    }
  }
  if self.pretty && self.too_wide(arg_sqls) {
    return self.indent(
      "\n" + arg_sqls.join(py_strip(sep) + "\n") + "\n",
      skip_first=true,
      skip_last=true,
    )
  }
  arg_sqls.join(sep)
}

///|
pub fn Generator::too_wide(self : Generator, args : Array[String]) -> Bool {
  let mut total = 0
  for a in args {
    total += py_len(a)
  }
  total > self.max_text_width
}

///|
/// Virtual `format_time`.
pub fn Generator::format_time(
  self : Generator,
  expression : Expr,
  inverse_time_mapping? : Map[String, String],
  inverse_time_trie? : Trie,
) -> String? raise SqlglotError {
  match self.fns.hooks.format_time {
    Some(f) => f(self, expression, inverse_time_mapping, inverse_time_trie)
    None =>
      self.format_time_base(
        expression,
        inverse_time_mapping?,
        inverse_time_trie?,
      )
  }
}

///|
pub fn Generator::format_time_base(
  self : Generator,
  expression : Expr,
  inverse_time_mapping? : Map[String, String],
  inverse_time_trie? : Trie,
) -> String? raise SqlglotError {
  let mapping = match inverse_time_mapping {
    Some(m) if !m.is_empty() => m
    _ => self.dialect.cfg.inverse_time_mapping
  }
  let trie = match inverse_time_trie {
    Some(t) if !t.children.is_empty() || t.terminal => t
    _ => self.dialect.inverse_time_trie
  }
  format_time_opt(self.sql_key(expression, "format"), mapping, trie~)
}

///|
/// Python `self.expressions(...)`.
pub fn Generator::expressions(
  self : Generator,
  expression? : Expr,
  key? : String,
  sqls? : Array[Value],
  flat? : Bool = false,
  indent? : Bool = true,
  skip_first? : Bool = false,
  skip_last? : Bool = false,
  sep? : String = ", ",
  prefix? : String = "",
  dynamic? : Bool = false,
  new_line? : Bool = false,
) -> String raise SqlglotError {
  let items : Array[Value] = match expression {
    Some(e) => {
      let k = match key {
        Some(k) if k != "" => k
        _ => "expressions"
      }
      match e.args.get(k) {
        Some(List(l)) => l
        Some(v) if v.truthy() => [v]
        _ => []
      }
    }
    None =>
      match sqls {
        Some(s) => s
        None => []
      }
  }
  if items.is_empty() {
    return ""
  }
  if flat {
    let out = []
    for v in items {
      let s = self.sql_value(v)
      if s != "" {
        out.push(s)
      }
    }
    return out.join(sep)
  }
  let num_sqls = items.length()
  let result_sqls : Array[String] = []
  for i, v in items {
    let sql = self.sql_value(v, comment=false)
    if sql == "" {
      continue
    }
    let comments = match v {
      Node(e) => self.maybe_comment("", expression=e)
      _ => ""
    }
    if self.pretty {
      if self.leading_comma {
        result_sqls.push(
          (if i > 0 { sep } else { "" }) + prefix + sql + comments,
        )
      } else {
        let tail = if i + 1 < num_sqls {
          if comments != "" {
            py_rstrip(sep)
          } else {
            sep
          }
        } else {
          ""
        }
        result_sqls.push(prefix + sql + tail + comments)
      }
    } else {
      result_sqls.push(
        prefix + sql + comments + (if i + 1 < num_sqls { sep } else { "" }),
      )
    }
  }
  let result_sql = if self.pretty && (!dynamic || self.too_wide(result_sqls)) {
    if new_line {
      result_sqls.insert(0, "")
      result_sqls.push("")
    }
    result_sqls.map(s => py_rstrip(s)).join("\n")
  } else {
    result_sqls.join("")
  }
  if indent {
    self.indent(result_sql, skip_first~, skip_last~)
  } else {
    result_sql
  }
}

///|
pub fn Generator::op_expressions(
  self : Generator,
  op : String,
  expression : Expr,
  flat? : Bool = false,
) -> String raise SqlglotError {
  let flat = flat ||
    (match expression.parent {
      Some(p) => p.kind.is_a(Properties)
      None => false
    })
  let expressions_sql = self.expressions(expression~, flat~)
  if flat {
    return op + " " + expressions_sql
  }
  self.seg(op) +
  (if expressions_sql != "" { self.sep() } else { "" }) +
  expressions_sql
}

///|
priv enum BinItem {
  BNode(Expr?)
  BStr(String)
}

///|
/// An operand of a binary node; Python's `self.sql(str)` returns raw strings as-is.
fn bin_item(node : Expr, key : String) -> BinItem {
  match node.args.get(key) {
    Some(Str(s)) => BStr(s)
    _ => BNode(node.arg(key))
  }
}

///|
pub fn Generator::binary(
  self : Generator,
  expression : Expr,
  op : String,
) -> String raise SqlglotError {
  let sqls : Array[String] = []
  let stack : Array[BinItem] = [BNode(Some(expression))]
  let binary_type = expression.kind
  let mut op = op
  while stack.pop() is Some(item) {
    match item {
      BNode(Some(node)) if node.kind == binary_type => {
        match node.args.get("operator") {
          Some(op_func) if op_func.truthy() =>
            op = "OPERATOR(" + self.sql_value(op_func) + ")"
          _ => ()
        }
        stack.push(bin_item(node, "expression"))
        stack.push(
          BStr(" " + self.maybe_comment(op, comments?=node.comments) + " "),
        )
        stack.push(bin_item(node, "this"))
      }
      BNode(n) => sqls.push(self.sql(n))
      BStr(s) => sqls.push(s)
    }
  }
  sqls.join("")
}

///|
pub fn Generator::connector_sql(
  self : Generator,
  expression : Expr,
  op : String,
) -> String raise SqlglotError {
  ignore(op)
  let stack : Array[BinItem] = [BNode(Some(expression))]
  let sqls : Array[String] = []
  let ops : @set.Set[String] = @set.Set([])
  while stack.pop() is Some(item) {
    match item {
      BNode(Some(node)) if node.kind.is_a(Connector) => {
        let mut node_op = match node.kind {
          And => "AND"
          Or => "OR"
          Xor => "XOR"
          k => py_upper(k.key())
        }
        stack.push(BNode(node.arg("expression")))
        match node.comments {
          Some(c) if !c.is_empty() && self.comments =>
            node_op = self.maybe_comment(node_op, comments=c)
          _ => ()
        }
        stack.push(BStr(node_op))
        stack.push(BNode(node.arg("this")))
        ops.add(node_op)
      }
      other => {
        let sql = match other {
          BNode(n) => self.sql(n)
          BStr(s) => s
        }
        let n = sqls.length()
        if n > 0 && ops.contains(sqls[n - 1]) {
          sqls[n - 1] = sqls[n - 1] + " " + sql
        } else {
          sqls.push(sql)
        }
      }
    }
  }
  let sep = if self.pretty && self.too_wide(sqls) { "\n" } else { " " }
  sqls.join(sep)
}

///|
/// Python `_replace_line_breaks`.
pub fn Generator::replace_line_breaks(
  self : Generator,
  string : String,
) -> String {
  if self.pretty {
    string.replace_all(old="\n", new=self.cfg.sentinel_line_break)
  } else {
    string
  }
}
