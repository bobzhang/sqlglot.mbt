// Public facade of the sqlglot port: all built-in dialects are registered (through the
// `bobzhang/sqlglot/dialects` registry) and the main entry points take dialect names.

///|
/// Parses `sql` (possibly several statements) in dialect `read` and generates it in
/// dialect `write` (Python `sqlglot.transpile`). When `identity` is true (the default)
/// and `write` is omitted, `write` defaults to `read`; otherwise to the base dialect.
/// `error_level`, `error_message_context`, `max_errors` and `max_nodes` are the parser
/// options (see `parse`); the remaining options are the generator options (see
/// `generate`).
pub fn transpile(
  sql : String,
  read? : String = "",
  write? : String,
  identity? : Bool = true,
  error_level? : @core.ErrorLevel = Immediate,
  error_message_context? : Int = 100,
  max_errors? : Int = 3,
  max_nodes? : Int = -1,
  pretty? : Bool,
  identify? : Identify = Never,
  normalize? : Bool = false,
  pad? : Int = 2,
  indent? : Int = 2,
  normalize_functions? : NormalizeFunctions,
  unsupported_level? : @core.ErrorLevel = Warn,
  max_unsupported? : Int = 3,
  leading_comma? : Bool = false,
  max_text_width? : Int = 80,
  comments? : Bool = true,
) -> Array[String] raise @core.SqlglotError {
  let r = @core.Dialect::get_or_raise(read)
  let w = match write {
    Some(w) => @core.Dialect::get_or_raise(w)
    None => if identity { r } else { @core.Dialect::get_or_raise("") }
  }
  let out = []
  let expressions = r.parse(
    sql,
    error_level~,
    error_message_context~,
    max_errors~,
    max_nodes~,
  )
  for e in expressions {
    match e {
      Some(expr) =>
        out.push(
          @core.Generator::new(
            w,
            pretty?,
            identify=identify.to_option(),
            normalize~,
            pad~,
            indent~,
            normalize_functions?=normalize_functions.map(n => n.to_option()),
            unsupported_level~,
            max_unsupported~,
            leading_comma~,
            max_text_width~,
            comments~,
          ).generate(expr, copy=false),
        )
      None => out.push("")
    }
  }
  out
}

///|
/// Parses a single SQL statement in dialect `read` (Python `sqlglot.parse_one`).
/// `into` (Python `into=exp.X`) parses into the given expression type; `into_any`
/// (Python `into=[exp.X, exp.Y]`) tries each type in turn.
pub fn parse_one(
  sql : String,
  read? : String = "",
  into? : @core.Kind,
  into_any? : Array[@core.Kind],
  error_level? : @core.ErrorLevel = Immediate,
  error_message_context? : Int = 100,
  max_errors? : Int = 3,
  max_nodes? : Int = -1,
) -> @core.Expr raise @core.SqlglotError {
  let (into, into_is_list) = match (into, into_any) {
    (Some(k), _) => (Some([k]), false)
    (None, Some(ks)) => (Some(ks), true)
    (None, None) => (None, false)
  }
  @core.parse_one(
    sql,
    dialect=@core.Dialect::get_or_raise(read),
    into?,
    into_is_list~,
    error_level~,
    error_message_context~,
    max_errors~,
    max_nodes~,
  )
}

///|
/// Parses all statements of `sql` in dialect `read` (Python `sqlglot.parse`).
pub fn parse(
  sql : String,
  read? : String = "",
  error_level? : @core.ErrorLevel = Immediate,
  error_message_context? : Int = 100,
  max_errors? : Int = 3,
  max_nodes? : Int = -1,
) -> Array[@core.Expr?] raise @core.SqlglotError {
  @core.parse(
    sql,
    dialect=@core.Dialect::get_or_raise(read),
    error_level~,
    error_message_context~,
    max_errors~,
    max_nodes~,
  )
}

///|
/// Generates SQL for `expression` in dialect `dialect` (Python `Expr.sql`).
///
/// - `pretty`: whether to format the produced SQL (default: `@core.default_pretty`).
/// - `identify`: when to quote identifiers (default: `Never`).
/// - `normalize`: whether to normalize identifiers to lowercase.
/// - `pad`, `indent`: indentation sizes of the pretty output.
/// - `normalize_functions`: how to normalize function names (default: the dialect's).
/// - `unsupported_level`, `max_unsupported`: how unsupported expressions are reported.
/// - `leading_comma`, `max_text_width`, `comments`: further formatting options.
pub fn generate(
  expression : @core.Expr,
  dialect? : String = "",
  copy? : Bool = true,
  pretty? : Bool,
  identify? : Identify = Never,
  normalize? : Bool = false,
  pad? : Int = 2,
  indent? : Int = 2,
  normalize_functions? : NormalizeFunctions,
  unsupported_level? : @core.ErrorLevel = Warn,
  max_unsupported? : Int = 3,
  leading_comma? : Bool = false,
  max_text_width? : Int = 80,
  comments? : Bool = true,
) -> String raise @core.SqlglotError {
  @core.Generator::new(
    @core.Dialect::get_or_raise(dialect),
    pretty?,
    identify=identify.to_option(),
    normalize~,
    pad~,
    indent~,
    normalize_functions?=normalize_functions.map(n => n.to_option()),
    unsupported_level~,
    max_unsupported~,
    leading_comma~,
    max_text_width~,
    comments~,
  ).generate(expression, copy~)
}

///|
/// Looks up a dialect by name (`""` is the base sqlglot dialect).
pub fn dialect(name : String) -> @core.Dialect raise @core.SqlglotError {
  @core.Dialect::get_or_raise(name)
}
