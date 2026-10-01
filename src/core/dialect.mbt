// Port of the `Dialect` class from sqlglot/dialects/dialect.py

///|
/// A SQL dialect: the Python `Dialect` class plus its Tokenizer, Parser and
/// Generator configuration.
pub struct Dialect {
  name : String
  cfg : DialectConfig
  tokenizer : TokenizerSettings
  parser_cfg : ParserConfig
  parser_fns : ParserFns
  gen_cfg : GeneratorConfig
  gen_fns : GeneratorFns
  hooks : DialectHooks
  mut normalization_strategy : NormalizationStrategy
  mut version : (Int, Int, Int)
  settings : Map[String, String]
  mut time_trie : Trie
  mut format_trie : Trie
  mut inverse_time_trie : Trie
  mut inverse_format_trie : Trie
  /// The parent dialect, e.g. `spark2` for `spark`.
  parent : Dialect?
}

///|
/// Overridable dialect-level methods.
pub(all) struct DialectHooks {
  mut normalize_identifier : ((Dialect, Expr) -> Expr)?
  mut generate_values_aliases : ((Dialect, Expr) -> Array[Expr])?
  mut extra : Map[String, (Dialect, Expr) -> Expr?]
}

///|
pub fn DialectHooks::new() -> DialectHooks {
  { normalize_identifier: None, generate_values_aliases: None, extra: Map([]) }
}

///|
pub fn DialectHooks::copy(self : DialectHooks) -> DialectHooks {
  {
    normalize_identifier: self.normalize_identifier,
    generate_values_aliases: self.generate_values_aliases,
    extra: Map::from_iter(self.extra.iter()),
  }
}

///|
fn trie_of_keys(m : Map[String, String]) -> Trie {
  let t = Trie::new()
  for k, _ in m {
    t.add(k)
  }
  t
}

///|
/// Recomputes derived tables after the configuration has been modified.
pub fn Dialect::finalize(self : Dialect) -> Dialect {
  self.tokenizer.finalize() |> ignore
  self.parser_fns.finalize()
  self.time_trie = trie_of_keys(self.cfg.time_mapping)
  self.format_trie = if self.cfg.format_mapping.is_empty() {
    self.time_trie
  } else {
    trie_of_keys(self.cfg.format_mapping)
  }
  self.inverse_time_trie = trie_of_keys(self.cfg.inverse_time_mapping)
  self.inverse_format_trie = trie_of_keys(self.cfg.inverse_format_mapping)
  self.normalization_strategy = self.cfg.normalization_strategy
  self
}

///|
/// Builds the base ("sqlglot") dialect.
pub fn Dialect::base() -> Dialect {
  {
    name: "",
    cfg: base_dialect_config(),
    tokenizer: base_tokenizer_settings_raw(),
    parser_cfg: base_parser_config(),
    parser_fns: base_parser_fns(),
    gen_cfg: base_generator_config(),
    gen_fns: base_generator_fns(),
    hooks: DialectHooks::new(),
    normalization_strategy: Lowercase,
    version: (2147483647, 0, 0),
    settings: Map([]),
    time_trie: Trie::new(),
    format_trie: Trie::new(),
    inverse_time_trie: Trie::new(),
    inverse_format_trie: Trie::new(),
    parent: None,
  }.finalize()
}

///|
/// Derives a new dialect from `parent`: copies all of its configuration, then
/// applies `configure` and recomputes derived tables.
pub fn Dialect::subclass(
  parent : Dialect,
  name : String,
  configure : (Dialect) -> Unit,
) -> Dialect {
  let d = {
    name,
    cfg: parent.cfg.copy(),
    tokenizer: parent.tokenizer.copy(),
    parser_cfg: parent.parser_cfg.copy(),
    parser_fns: parent.parser_fns.copy(),
    gen_cfg: parent.gen_cfg.copy(),
    gen_fns: parent.gen_fns.copy(),
    hooks: parent.hooks.copy(),
    normalization_strategy: parent.normalization_strategy,
    version: parent.version,
    settings: Map([]),
    time_trie: parent.time_trie,
    format_trie: parent.format_trie,
    inverse_time_trie: parent.inverse_time_trie,
    inverse_format_trie: parent.inverse_format_trie,
    parent: Some(parent),
  }
  configure(d)
  d.finalize()
}

///|
/// Returns a shallow instance copy (shares class-level configuration) so that
/// instance settings can be changed without affecting the registered dialect.
pub fn Dialect::instance(self : Dialect) -> Dialect {
  { ..self, settings: Map::from_iter(self.settings.iter()) }
}

///|
pub impl Eq for Dialect with equal(self, other) {
  self.name == other.name
}

///|
pub impl Show for Dialect with output(self, logger) {
  logger.write_string(if self.name.is_empty() { "sqlglot" } else { self.name })
}

// ---------------------------------------------------------------------------
// Registry

///|
let dialect_registry : Map[String, () -> Dialect] = Map([])

///|
let dialect_cache : Map[String, Dialect] = Map([])

///|
let base_dialect_cell : Ref[Dialect?] = Ref::new(None)

///|
/// Registers a dialect constructor under `name`.
pub fn register_dialect(name : String, make : () -> Dialect) -> Unit {
  dialect_registry[name] = make
  dialect_cache.remove(name)
}

///|
/// The base sqlglot dialect (cached).
pub fn base_dialect() -> Dialect {
  match base_dialect_cell.val {
    Some(d) => d
    None => {
      let d = Dialect::base()
      base_dialect_cell.val = Some(d)
      d
    }
  }
}

///|
/// Looks up a registered dialect by name (cached).
pub fn get_dialect(name : String) -> Dialect? {
  if name.is_empty() {
    return Some(base_dialect())
  }
  match dialect_cache.get(name) {
    Some(d) => Some(d)
    None =>
      match dialect_registry.get(name) {
        Some(make) => {
          let d = make()
          dialect_cache[name] = d
          Some(d)
        }
        None => None
      }
  }
}

///|
/// Names of all registered dialects.
pub fn dialect_names() -> Array[String] {
  dialect_registry.keys().collect()
}

///|
/// Look up a dialect in the global registry. The string can be followed by
/// settings, e.g. `"mysql, normalization_strategy = case_sensitive"`.
pub fn Dialect::get_or_raise(spec : String) -> Dialect raise SqlglotError {
  let parts = py_split(spec, ",")
  let name = py_strip(parts[0])
  let d = match get_dialect(name) {
    Some(d) => d
    None => raise ValueError("Unknown dialect '\{name}'.")
  }
  if parts.length() == 1 {
    return d
  }
  let inst = d.instance()
  for i in 1..<parts.length() {
    let kv = py_split(parts[i], "=")
    let key = py_strip(kv[0])
    let value = if kv.length() == 1 { "true" } else { py_strip(kv[1]) }
    if key == "normalization_strategy" {
      inst.normalization_strategy = match py_upper(value) {
        "LOWERCASE" => Lowercase
        "UPPERCASE" => Uppercase
        "CASE_SENSITIVE" => CaseSensitive
        "CASE_INSENSITIVE" => CaseInsensitive
        "CASE_INSENSITIVE_UPPERCASE" => CaseInsensitiveUppercase
        _ => raise ValueError("Invalid normalization strategy '\{value}'")
      }
    } else if key == "version" {
      let vs = py_split(value, ".")
      let nums = vs.map(v => match parse_int_str(v) {
        Some(n) => n.to_int()
        None => 0
      })
      while nums.length() < 3 {
        nums.push(0)
      }
      inst.version = (nums[0], nums[1], nums[2])
    } else {
      inst.settings[key] = value
    }
  }
  inst
}

// ---------------------------------------------------------------------------
// Dialect methods

///|
/// Transforms an identifier in a way that resembles how it'd be resolved by this dialect.
pub fn Dialect::normalize_identifier(self : Dialect, expression : Expr) -> Expr {
  match self.hooks.normalize_identifier {
    Some(f) => f(self, expression)
    None => self.normalize_identifier_base(expression)
  }
}

///|
pub fn Dialect::normalize_identifier_base(self : Dialect, expression : Expr) -> Expr {
  if expression.kind == Identifier &&
    self.normalization_strategy != CaseSensitive &&
    (!expression.has("quoted") ||
    self.normalization_strategy is (CaseInsensitive | CaseInsensitiveUppercase)) {
    let text = expression.text("this")
    let normalized = if self.normalization_strategy is (Uppercase | CaseInsensitiveUppercase) {
      if self.cfg.ascii_only_normalization {
        text.to_upper()
      } else {
        py_upper(text)
      }
    } else if self.cfg.ascii_only_normalization {
      text.to_lower()
    } else {
      py_lower(text)
    }
    expression.set("this", normalized)
  }
  expression
}

///|
/// Checks if text contains any case sensitive characters.
pub fn Dialect::case_sensitive(self : Dialect, text : String) -> Bool {
  if self.normalization_strategy == CaseInsensitive {
    return false
  }
  for c in text {
    let unsafe_ = if self.normalization_strategy == Uppercase {
      char_upper(c) != c || (c.is_ascii_lowercase())
    } else {
      char_lower(c) != c || c.is_ascii_uppercase()
    }
    if unsafe_ {
      return true
    }
  }
  false
}

///|
/// Checks if an identifier can be quoted. `identify` is "always", "safe" or "unsafe".
pub fn Dialect::can_quote(
  self : Dialect,
  identifier : Expr,
  identify? : String = "safe",
) -> Bool {
  if identifier.has("quoted") {
    return true
  }
  if identify == "" || identify == "false" {
    return false
  }
  match identifier.parent {
    Some(p) => if p.kind.is_a(Func) { return false }
    None => ()
  }
  if identify == "always" || identify == "true" {
    return true
  }
  let text = identifier.text("this")
  let is_safe = !self.case_sensitive(text) && is_safe_identifier(text)
  if identify == "safe" {
    is_safe
  } else {
    !is_safe
  }
}

///|
/// Adds quotes to a given identifier.
pub fn Dialect::quote_identifier(
  self : Dialect,
  expression : Expr,
  identify? : Bool = true,
) -> Expr {
  if expression.kind == Identifier {
    expression.set(
      "quoted",
      self.can_quote(expression, identify=if identify { "always" } else { "unsafe" }),
    )
  }
  expression
}

///|
pub fn Dialect::generate_values_aliases(
  self : Dialect,
  expression : Expr,
) -> Array[Expr] {
  match self.hooks.generate_values_aliases {
    Some(f) => f(self, expression)
    None => {
      let first = expression.expressions()[0]
      let out = []
      for i in 0..<first.expressions().length() {
        out.push(to_identifier("_col_\{i}"))
      }
      out
    }
  }
}

///|
/// Converts a time format in this dialect to a python/strftime time format.
pub fn Dialect::format_time(self : Dialect, expression : Expr?) -> Expr? {
  match expression {
    Some(e) if e.is_string() =>
      Some(
        literal_string(
          format_time(e.text("this"), self.cfg.time_mapping, self.time_trie),
        ),
      )
    _ => expression
  }
}

///|
/// `Dialect.format_time` with a quoted python string (e.g. `"'%Y-%m-%d'"`).
pub fn Dialect::format_time_str(self : Dialect, s : String) -> Expr {
  literal_string(
    format_time(substr(s, 1, -1), self.cfg.time_mapping, self.time_trie),
  )
}
