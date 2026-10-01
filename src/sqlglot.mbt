// Public facade of the sqlglot port: registers all dialects (see registry.mbt) and
// exposes the main entry points taking dialect names.

///|
/// Parses `sql` (possibly several statements) in dialect `read` and generates it in
/// dialect `write` (defaults to `read`).
pub fn transpile(
  sql : String,
  read? : String = "",
  write? : String,
  pretty? : Bool = false,
  identify? : Bool = false,
  error_level? : @core.ErrorLevel = Immediate,
  unsupported_level? : @core.ErrorLevel = Warn,
) -> Array[String] raise @core.SqlglotError {
  let r = @core.Dialect::get_or_raise(read)
  let w = match write {
    Some(w) => @core.Dialect::get_or_raise(w)
    None => r
  }
  @core.transpile(
    sql,
    read=r,
    write=w,
    pretty~,
    identify=if identify { "always" } else { "" },
    error_level~,
    unsupported_level~,
  )
}

///|
/// Parses a single SQL statement in dialect `read`.
pub fn parse_one(
  sql : String,
  read? : String = "",
) -> @core.Expr raise @core.SqlglotError {
  @core.parse_one(sql, dialect=@core.Dialect::get_or_raise(read))
}

///|
/// Parses all statements of `sql` in dialect `read`.
pub fn parse(
  sql : String,
  read? : String = "",
) -> Array[@core.Expr?] raise @core.SqlglotError {
  @core.parse(sql, dialect=@core.Dialect::get_or_raise(read))
}

///|
/// Generates SQL for `expression` in dialect `dialect`.
pub fn generate(
  expression : @core.Expr,
  dialect? : String = "",
  pretty? : Bool = false,
  identify? : Bool = false,
) -> String raise @core.SqlglotError {
  @core.Generator::new(
    @core.Dialect::get_or_raise(dialect),
    pretty~,
    identify=if identify { "always" } else { "" },
  ).generate(expression)
}

///|
/// Looks up a dialect by name (`""` is the base sqlglot dialect).
pub fn dialect(name : String) -> @core.Dialect raise @core.SqlglotError {
  @core.Dialect::get_or_raise(name)
}
