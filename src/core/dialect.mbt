// Port of the `Dialect` class from sqlglot/dialects/dialect.py

///|
/// A SQL dialect: the Python `Dialect` class plus its Tokenizer, Parser and
/// Generator configuration.
pub struct Dialect {
  name : String
  cfg : DialectConfig
  tokenizer : TokenizerSettings
  /// `JSONPathTokenizer` settings and its `VAR_TOKENS`.
  jsonpath_tokenizer : TokenizerSettings
  mut jsonpath_var_tokens : Array[TokenType]
  parser_cfg : ParserConfig
  parser_fns : ParserFns
  gen_cfg : GeneratorConfig
  gen_fns : GeneratorFns
  hooks : DialectHooks
  mut normalization_strategy : NormalizationStrategy
  mut version : (Int, Int, Int)
  settings : Map[String, String]
  /// `SUPPORTED_SETTINGS`
  mut supported_settings : Array[String]
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
  /// `Dialect.tokenize` override (e.g. Athena routes to the Hive or Trino tokenizer).
  mut tokenize : ((Dialect, String) -> Array[Token] raise SqlglotError)?
  /// `can_quote(identifier, identify)` override; base is `Dialect::can_quote_base`.
  mut can_quote : ((Dialect, Expr, String) -> Bool)?
  /// `Dialect.to_json_path` override (e.g. DuckDB's JSON pointer passthrough).
  mut to_json_path : ((Dialect, Expr?) -> Expr? raise SqlglotError)?
  mut extra : Map[String, (Dialect, Expr) -> Expr?]
}

///|
pub fn DialectHooks::new() -> DialectHooks {
  {
    normalize_identifier: None,
    generate_values_aliases: None,
    tokenize: None,
    can_quote: None,
    to_json_path: None,
    extra: Map([]),
  }
}

///|
pub fn DialectHooks::copy(self : DialectHooks) -> DialectHooks {
  {
    normalize_identifier: self.normalize_identifier,
    generate_values_aliases: self.generate_values_aliases,
    tokenize: self.tokenize,
    can_quote: self.can_quote,
    to_json_path: self.to_json_path,
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
  self.jsonpath_tokenizer.finalize() |> ignore
  self.parser_fns.finalize()
  // Remove transforms that correspond to unsupported JSONPathPart expressions
  for part in all_json_path_parts {
    if !self.gen_cfg.supported_json_path_parts.contains(part) {
      self.gen_fns.transforms.remove(part)
    }
  }
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
    jsonpath_tokenizer: base_jsonpath_tokenizer_settings_raw(),
    jsonpath_var_tokens: [VAR],
    parser_cfg: base_parser_config(),
    parser_fns: base_parser_fns(),
    gen_cfg: base_generator_config(),
    gen_fns: base_generator_fns(),
    hooks: DialectHooks::new(),
    normalization_strategy: Lowercase,
    version: (2147483647, 0, 0),
    settings: Map([]),
    supported_settings: ["normalization_strategy", "version"],
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
    jsonpath_tokenizer: parent.jsonpath_tokenizer.copy(),
    jsonpath_var_tokens: parent.jsonpath_var_tokens.copy(),
    parser_cfg: parent.parser_cfg.copy(),
    parser_fns: parent.parser_fns.copy(),
    gen_cfg: parent.gen_cfg.copy(),
    gen_fns: parent.gen_fns.copy(),
    hooks: parent.hooks.copy(),
    normalization_strategy: parent.normalization_strategy,
    version: parent.version,
    settings: Map([]),
    supported_settings: parent.supported_settings.copy(),
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
/// Like Python's `Dialect.__init__`, the instance's normalization strategy
/// defaults to the class-level `NORMALIZATION_STRATEGY` (`cfg`).
pub fn Dialect::instance(self : Dialect) -> Dialect {
  {
    ..self,
    normalization_strategy: self.cfg.normalization_strategy,
    settings: Map::from_iter(self.settings.iter()),
  }
}

///|
pub impl Eq for Dialect with fn equal(self, other) {
  self.name == other.name
}

///|
#deprecated
pub extend Dialect with Eq::{not_equal, equal}

///|
pub impl Show for Dialect with fn output(self, logger) {
  logger.write_string(if self.name.is_empty() { "sqlglot" } else { self.name })
}

///|
pub extend Dialect with Show::{to_string}

///|
#deprecated
pub extend Dialect with Show::{output}

// ---------------------------------------------------------------------------
// Registry

///|
let dialect_registry : Map[String, () -> Dialect] = Map([])

///|
let dialect_cache : Map[String, Dialect] = Map([])

///|
let base_dialect_cell : Ref[Dialect?] = Ref(None)

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
  // kwargs: the values are `to_bool`-ed (Ok(bool)) or kept as strings (Err(str))
  let kwargs : Map[String, Result[Bool, String]] = Map([])
  for i in 1..<parts.length() {
    let kv = py_split(parts[i], "=")
    let key = py_strip(kv[0])
    kwargs[key] = match kv.length() {
      1 => Ok(true)
      2 =>
        match py_lower(py_strip(kv[1])) {
          "true" | "1" => Ok(true)
          "false" | "0" => Ok(false)
          _ => Err(py_strip(kv[1]))
        }
      _ =>
        raise ValueError(
          "Invalid dialect format: '\{spec}'. Please use the correct format: 'dialect [, k1 = v2 [, ...]]'.",
        )
    }
  }
  let d = match get_dialect(name) {
    Some(d) => d
    None => {
      let names = dialect_names()
      names.push("")
      suggest_closest_match_and_fail("dialect", name, names)
    }
  }
  // Python constructs a fresh instance for every string lookup (`Dialect.__init__`).
  let inst = d.instance()
  if kwargs.get("version") is Some(value) {
    kwargs.remove("version")
    // str(value).split("."), padded to 3 parts
    let value = match value {
      Ok(b) => if b { "True" } else { "False" }
      Err(s) => s
    }
    let vs = py_split(value, ".")
    let nums = []
    for v in vs[:@cmp.minimum(vs.length(), 3)] {
      match parse_int_str(py_strip(v)) {
        Some(n) => nums.push(n.to_int())
        None =>
          raise ValueError("invalid literal for int() with base 10: '\{v}'")
      }
    }
    while nums.length() < 3 {
      nums.push(0)
    }
    inst.version = (nums[0], nums[1], nums[2])
  }
  if kwargs.get("normalization_strategy") is Some(value) {
    kwargs.remove("normalization_strategy")
    let value = match value {
      Ok(_) => raise ValueError("'bool' object has no attribute 'upper'")
      Err(s) => py_upper(s)
    }
    inst.normalization_strategy = match value {
      "LOWERCASE" => Lowercase
      "UPPERCASE" => Uppercase
      "CASE_SENSITIVE" => CaseSensitive
      "CASE_INSENSITIVE" => CaseInsensitive
      "CASE_INSENSITIVE_UPPERCASE" => CaseInsensitiveUppercase
      _ => raise ValueError("'\{value}' is not a valid NormalizationStrategy")
    }
  }
  // the port stores the booleans as "true" / "false"
  for key, value in kwargs {
    inst.settings[key] = match value {
      Ok(b) => if b { "true" } else { "false" }
      Err(s) => s
    }
  }
  for key, _ in kwargs {
    if !d.supported_settings.contains(key) {
      suggest_closest_match_and_fail("setting", key, d.supported_settings)
    }
  }
  inst
}

///|
/// Python `suggest_closest_match_and_fail`: raises a ValueError naming the closest
/// candidate (similarity >= 0.6, approximating difflib.get_close_matches).
pub fn[T] suggest_closest_match_and_fail(
  kind : String,
  word : String,
  possibilities : Array[String],
) -> T raise SqlglotError {
  let mut best = ""
  let mut best_score = 0.6
  for p in possibilities {
    let score = similarity_ratio(word, p)
    if score >= best_score && (best.is_empty() || score > best_score) {
      best = p
      best_score = score
    }
  }
  let similar = if best.is_empty() { "" } else { " Did you mean \{best}?" }
  raise ValueError("Unknown \{kind} '\{word}'.\{similar}")
}

///|
/// difflib.SequenceMatcher-style ratio: 2 * matches / total length, where matches are
/// counted via longest common subsequence.
fn similarity_ratio(a : String, b : String) -> Double {
  let a = a.to_array()
  let b = b.to_array()
  let total = a.length() + b.length()
  if total == 0 {
    return 1.0
  }
  let prev = Array::make(b.length() + 1, 0)
  for i in 0..<a.length() {
    let cur = Array::make(b.length() + 1, 0)
    for j in 0..<b.length() {
      cur[j + 1] = if a[i] == b[j] {
        prev[j] + 1
      } else if prev[j + 1] > cur[j] {
        prev[j + 1]
      } else {
        cur[j]
      }
    }
    for j in 0..=b.length() {
      prev[j] = cur[j]
    }
  }
  2.0 * prev[b.length()].to_double() / total.to_double()
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
pub fn Dialect::normalize_identifier_base(
  self : Dialect,
  expression : Expr,
) -> Expr {
  if expression.kind == Identifier &&
    self.normalization_strategy != CaseSensitive &&
    (
      !expression.has("quoted") ||
      self.normalization_strategy
      is (CaseInsensitive | CaseInsensitiveUppercase)
    ) {
    let text = expression.text("this")
    let normalized = if self.normalization_strategy
      is (Uppercase | CaseInsensitiveUppercase) {
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
      is_lower_char(c)
    } else {
      is_upper_char(c)
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
  match self.hooks.can_quote {
    Some(f) => f(self, identifier, identify)
    None => self.can_quote_base(identifier, identify~)
  }
}

///|
pub fn Dialect::can_quote_base(
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
      self.can_quote(
        expression,
        identify=if identify { "always" } else { "unsafe" },
      ),
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

///|
/// Python `ALL_JSON_PATH_PARTS`.
pub let all_json_path_parts : Array[Kind] = [
  JSONPathFilter,
  JSONPathKey,
  JSONPathRecursive,
  JSONPathRoot,
  JSONPathScript,
  JSONPathSelector,
  JSONPathSlice,
  JSONPathSubscript,
  JSONPathUnion,
  JSONPathWildcard,
]
