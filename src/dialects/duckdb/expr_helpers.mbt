// Small Python-expression-API shims used by the DuckDB generator.

///|
/// Python `exp.func(name, *args)`: copies the arguments (like `maybe_parse(copy=True)`)
/// and builds a known function of the base dialect, or an `Anonymous` function.
fn func(
  name : String,
  args : Array[@core.Expr],
) -> @core.Expr raise @core.SqlglotError {
  @core.func_(name, args.map(a => a.copy()))
}

///|
/// Python `exp.func(name, *args)` where some arguments are SQL strings to be parsed.
fn parse(sql : String) -> @core.Expr raise @core.SqlglotError {
  @core.maybe_parse_str(sql)
}

///|
fn num(n : Int) -> @core.Expr {
  @core.literal_int(n)
}

///|
fn numstr(s : String) -> @core.Expr {
  @core.literal_number(s)
}

///|
fn str_lit(s : String) -> @core.Expr {
  @core.literal_string(s)
}

///|
/// Python `a + b` on expressions.
fn add(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Add, a, b)
}

///|
/// Python `a - b` on expressions.
fn sub(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Sub, a, b)
}

///|
/// Python `a * b` on expressions.
fn mul(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Mul, a, b)
}

///|
/// Python `a / b` on expressions.
fn div(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Div, a, b)
}

///|
/// Python `a // b` on expressions.
fn intdiv(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(IntDiv, a, b)
}

///|
/// Python `a % b` on expressions.
fn mod_(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Mod, a, b)
}

///|
/// Python `a < b` on expressions.
fn lt(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(LT, a, b)
}

///|
/// Python `a.eq(b)`.
fn eq(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(EQ, a, b)
}

///|
/// Python `a.is_(b)`.
fn is_(a : @core.Expr, b : @core.Expr) -> @core.Expr {
  @core.exp_binop(Is, a, b)
}

///|
/// Python `a.is_(exp.null())`.
fn is_null(a : @core.Expr) -> @core.Expr {
  is_(a, @core.null_())
}

///|
/// Python `a.not_()`.
fn not_(a : @core.Expr) -> @core.Expr {
  @core.exp_not(a)
}

///|
/// Python `a[index]` (`Expr.__getitem__`).
fn getitem(a : @core.Expr, index : @core.Expr) -> @core.Expr {
  @core.mk(Bracket, [("this", a.copy()), ("expressions", [index.copy()])])
}

///|
/// Python `exp.cast(e, dtype)` (copies).
fn cast(e : @core.Expr, to : @core.DType) -> @core.Expr {
  @core.exp_cast(e, to)
}

///|
/// Python `exp.cast(e, data_type_expr)` (copies).
fn cast_to(e : @core.Expr, to : @core.Expr) -> @core.Expr {
  @core.exp_cast_to(e, to)
}

///|
/// Python `exp.DataType.from_str(s, dialect="duckdb")`.
fn duck_type(s : String) -> @core.Expr raise @core.SqlglotError {
  @core.datatype_from_str(s, dialect=dialect())
}

///|
/// Python `exp.DataType.from_str(s)` / `DataType.build(s)` with the base dialect.
fn base_type(s : String) -> @core.Expr raise @core.SqlglotError {
  @core.datatype_from_str(s)
}

///|
/// Python `exp.case()`.
fn case_() -> @core.Expr {
  @core.exp_case()
}

///|
/// Python `case.when(condition, then)` (copies).
fn when(
  case_ : @core.Expr,
  condition : @core.Expr,
  then : @core.Expr,
) -> @core.Expr {
  @core.case_when(case_, condition, then)
}

///|
/// Python `case.else_(value)` (copies).
fn else_(case_ : @core.Expr, value : @core.Expr) -> @core.Expr {
  @core.case_else(case_, value)
}

///|
/// Python `exp.If(this=..., true=..., false=...)`.
fn if_(cond : @core.Expr, t : @core.Expr, f : &@core.IntoValue) -> @core.Expr {
  @core.mk(If, [("this", cond), ("true", t), ("false", f)])
}

///|
/// Python `exp.Interval(this=..., unit=exp.var(unit))`.
fn interval(this : @core.Expr, unit : String) -> @core.Expr {
  @core.mk(Interval, [("this", this), ("unit", @core.var_(unit))])
}

///|
/// Python `exp.replace_placeholders(template, **kwargs)` (copies the template).
fn tmpl(
  template : @core.Expr,
  kwargs : Array[(String, @core.Expr)],
) -> @core.Expr {
  @core.replace_placeholders(template.copy(), Map::from_array(kwargs))
}

///|
/// Python `expression.to_py()` for an integer literal.
fn to_int(e : @core.Expr) -> Int {
  match e.to_py_int() {
    Some(v) => v.to_int()
    None => 0
  }
}

///|
/// Python `expression.type` is set (truthy).
fn has_type(e : @core.Expr) -> Bool {
  e.get_type() is Some(_)
}

///|
/// Python `DType.X in exp.DataType.TEXT_TYPES` etc.
fn is_text(e : @core.Expr) -> Bool {
  e.is_type(@core.dtype_text_types)
}

///|
fn is_real(e : @core.Expr) -> Bool {
  e.is_type(@core.dtype_real_types)
}

///|
fn is_integer(e : @core.Expr) -> Bool {
  e.is_type(@core.dtype_integer_types)
}

///|
/// Python `helper.is_date_unit(expression)`.
fn is_date_unit(e : @core.Expr?) -> Bool {
  match e {
    Some(u) =>
      ["day", "week", "month", "quarter", "year", "year_month"].contains(
        @core.py_lower(u.name()),
      )
    None => false
  }
}

///|
/// Lazily parsed SQL template (Python class-level `exp.maybe_parse(...)`).
priv struct Template {
  sql : String
  mut cell : @core.Expr?
}

///|
fn Template::new(sql : String) -> Template {
  { sql, cell: None, }
}

///|
fn Template::get(self : Template) -> @core.Expr raise @core.SqlglotError {
  match self.cell {
    Some(e) => e
    None => {
      let e = @core.parse_one(self.sql)
      self.cell = Some(e)
      e
    }
  }
}

///|
/// Python `expression.this` where the generator code requires it to be set: raises
/// (like Python's AttributeError on `None`) instead of aborting.
fn this_of(e : @core.Expr) -> @core.Expr raise @core.SqlglotError {
  req(e, "this")
}

///|
/// Python `expression.expression` where the generator code requires it to be set.
fn expr_of(e : @core.Expr) -> @core.Expr raise @core.SqlglotError {
  req(e, "expression")
}

///|
/// Python `expression.args["key"]`: raises when the argument is missing.
fn req(e : @core.Expr, key : String) -> @core.Expr raise @core.SqlglotError {
  match e.arg(key) {
    Some(x) => x
    None =>
      raise @core.ValueError("\{e.kind.name()} has no `\{key}` expression")
  }
}
