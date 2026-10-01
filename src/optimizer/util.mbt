// Small helpers shared by the optimizer rules.

///|
/// Whether `node.parent` is an instance of one of `kinds`.
fn parent_is(node : @core.Expr, kinds : Array[@core.Kind]) -> Bool {
  match node.parent {
    Some(p) => p.kind.is_any(kinds)
    None => false
  }
}

///|
/// `Join.is_semi_or_anti_join`
fn is_semi_or_anti_join(join : @core.Expr) -> Bool {
  let kind = @core.py_upper(join.text("kind"))
  kind == "SEMI" || kind == "ANTI"
}

///|
/// Python `str(expression)` (best effort).
fn expr_sql(e : @core.Expr) -> String {
  @core.expr_to_sql(e) catch {
    _ => e.kind.name()
  }
}

///|
/// Generates SQL for `e` in `dialect` (Python `e.sql(dialect=..., pretty=...)`).
pub fn sql_of(
  e : @core.Expr,
  dialect? : @core.Dialect,
  pretty? : Bool = false,
) -> String raise @core.SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => @core.base_dialect()
  }
  @core.Generator::new(d, pretty~).generate(e)
}

///|
/// Python `Dialect.get_or_raise(dialect)` for an optional dialect.
fn get_dialect(dialect : @core.Dialect?) -> @core.Dialect {
  match dialect {
    Some(d) => d
    None => @core.base_dialect()
  }
}

///|
/// Python `id(node)` set.
priv struct IdSet {
  ids : @set.Set[Int]
}

///|
fn IdSet::new() -> IdSet {
  { ids: @set.new() }
}

///|
fn IdSet::add(self : IdSet, e : @core.Expr) -> Unit {
  self.ids.add(e.uid)
}

///|
fn IdSet::contains(self : IdSet, e : @core.Expr) -> Bool {
  self.ids.contains(e.uid)
}

///|
/// Python `seq_get(seq, -1)`.
fn[T] last_of(xs : Array[T]) -> T? {
  xs.last()
}

///|
/// `exp.column(name, table=table)` with string parts.
fn column_with_table(name : String, table? : String, quoted? : Bool) -> @core.Expr {
  let col = @core.mk1(Column, @core.to_identifier(name, quoted?))
  match table {
    Some(t) if t != "" => col.set("table", @core.to_identifier(t, quoted?))
    _ => ()
  }
  col
}

///|
/// `exp.column(identifier, table=identifier)`.
fn column_with_ident(name : @core.Expr, table? : @core.Expr) -> @core.Expr {
  @core.mk(Column, [("this", name.copy()), ("table", table.map(t => t.copy()))])
}

///|
/// Python `exp.Literal.number(i)`
fn lit_num(i : Int) -> @core.Expr {
  @core.literal_number(i.to_string())
}

///|
/// Python `Expr.is_type(...)` with an optional type expression.
fn type_is(t : @core.Expr?, dtypes : Array[@core.DType]) -> Bool {
  match t {
    Some(t) => t.is_type(dtypes)
    None => false
  }
}

///|
/// Python string ordering (lexicographic by code point); MoonBit's `compare` on
/// strings orders by length first.
fn py_str_cmp(a : String, b : String) -> Int {
  let ai = a.iter()
  let bi = b.iter()
  for ;; {
    match (ai.next(), bi.next()) {
      (None, None) => return 0
      (None, Some(_)) => return -1
      (Some(_), None) => return 1
      (Some(x), Some(y)) =>
        if x != y {
          return if x < y { -1 } else { 1 }
        }
    }
  }
}

///|
/// Python attribute access on a possibly missing child (raises like AttributeError).
fn req(e : @core.Expr?, what : String) -> @core.Expr raise @core.SqlglotError {
  match e {
    Some(x) => x
    None =>
      raise @core.OptimizeError(
        "AttributeError: 'NoneType' object has no attribute '\{what}'",
      )
  }
}
