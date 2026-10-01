// Core machinery of the SQL generator (port of sqlglot/generator.py `Generator`).

///|
pub type GenFn = (Generator, Expr) -> String raise SqlglotError

///|
/// Callable class attributes of the Python `Generator` plus method override hooks.
pub(all) struct GeneratorFns {
  /// `TRANSFORMS`: exact kind -> generator function. Takes precedence over methods
  /// (mirrors Python `_build_dispatch`).
  mut transforms : Map[Kind, GenFn]
  /// Dialect `<key>_sql` method overrides. Used by `sql()` dispatch after
  /// `transforms`, and by virtual calls `Generator::call_method`.
  mut methods : Map[Kind, GenFn]
  /// Overrides of helper methods with custom signatures, keyed by Python method name.
  mut hooks : Map[String, (Generator, Array[Value]) -> Value raise SqlglotError]
  /// `TYPE_PARAM_SETTINGS`
  mut type_param_settings : Map[DType, (Array[Int], Array[Int])]
  /// `AFTER_HAVING_MODIFIER_TRANSFORMS`
  mut after_having_modifier_transforms : Array[(String, GenFn)]
}

///|
pub fn GeneratorFns::copy(self : GeneratorFns) -> GeneratorFns {
  {
    transforms: Map::from_iter(self.transforms.iter()),
    methods: Map::from_iter(self.methods.iter()),
    hooks: Map::from_iter(self.hooks.iter()),
    type_param_settings: Map::from_iter(self.type_param_settings.iter()),
    after_having_modifier_transforms: self.after_having_modifier_transforms.copy(),
  }
}

///|
/// Converts a given syntax tree to the corresponding SQL string.
pub struct Generator {
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
pub fn Generator::new(
  dialect : Dialect,
  pretty? : Bool = false,
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
      Some(e) => first_escape + e
      None => ""
    },
    escaped_identifier_end: dialect.cfg.identifier_end + dialect.cfg.identifier_end,
    next_name: name_sequence("_t"),
    identifier_start: dialect.cfg.identifier_start,
    identifier_end: dialect.cfg.identifier_end,
    quote_json_path_key_using_brackets: true,
  }
}
