// Types re-exported by the facade, so that a user importing only `hongbozhang/sqlglot`
// can name the principal types, errors and options (Python's `sqlglot` re-exports
// `Expr`, `Dialect`, `ErrorLevel`, the errors, `Generator`, `MappingSchema`, ...).

///|
pub using @core {
  type Expr,
  type Kind,
  type Value,
  type DType,
  type Dialect,
  type Generator,
  type ErrorLevel,
  type SqlglotError,
  type ParseErrorInfo,
  type PyObj,
  trait IntoPy,
}

///|
pub using @optimizer {type MappingSchema, type SchemaNode}

///|
pub using @executor {type Table, type TableData, type ExecuteError}

///|
/// A value of a table row in the executor (Python value semantics).
pub type ExecutorValue = @executor.Value

///|
pub using @dialects {register_dialects, dialect_names}

///|
/// When identifiers should be quoted by the generator (Python `identify`).
pub(all) enum Identify {
  /// Never quote, except where it's mandatory for the dialect (Python `False`).
  Never
  /// Always quote, except for special cases (Python `True`).
  Always
  /// Only quote case-insensitive identifiers (Python `"safe"`).
  Safe
  /// Only quote case-sensitive identifiers (Python `"unsafe"`).
  Unsafe
} derive(Eq, Debug)

///|
/// The generator's `identify` option for an `Identify` mode.
fn Identify::to_option(self : Identify) -> String {
  match self {
    Never => ""
    Always => "always"
    Safe => "safe"
    Unsafe => "unsafe"
  }
}

///|
/// How the generator normalizes function names (Python `normalize_functions`).
pub(all) enum NormalizeFunctions {
  /// Convert names to uppercase (Python `"upper"` or `True`).
  Upper
  /// Convert names to lowercase (Python `"lower"`).
  Lower
  /// Keep names as written (Python `False`).
  Keep
} derive(Eq, Debug)

///|
/// The generator's `normalize_functions` option for a `NormalizeFunctions` mode.
fn NormalizeFunctions::to_option(self : NormalizeFunctions) -> String {
  match self {
    Upper => "upper"
    Lower => "lower"
    Keep => ""
  }
}
