// Extra helpers of this package (prefixed with `c_` to avoid clashes).

///|
/// Python truthiness of `e.args[key]` (a missing arg is falsy).
fn c_truthy(e : @core.Expr, key : String) -> Bool {
  match e.get(key) {
    Some(v) => v.truthy()
    None => false
  }
}

///|
/// Python `isinstance(e.args[key], kind)`.
fn c_arg_is(e : @core.Expr, key : String, kind : @core.Kind) -> Bool {
  match e.arg(key) {
    Some(a) => a.kind.is_a(kind)
    None => false
  }
}

///|
/// `e.args[key].sql()` ("" when the arg is missing).
fn c_arg_sql(e : @core.Expr, key : String) -> String raise {
  match e.arg(key) {
    Some(a) => sql(a)
    None => ""
  }
}
