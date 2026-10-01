// Small helpers shared by the per-dialect typing modules (typing_<dialect>.mbt).

///|
/// Python `self._maybe_coerce(type1, type2)` where either side may be `None`
/// (an expression without a type).
fn TypeAnnotator::maybe_coerce_opt(
  self : TypeAnnotator,
  type1 : TType?,
  type2 : TType?,
) -> TType? {
  match (type1, type2) {
    (Some(a), Some(b)) => Some(self.maybe_coerce(a, b))
    (None, None) => None
    (Some(a), None) =>
      match a {
        T(t) if !t.expressions().is_empty() => Some(a)
        _ =>
          match a.this() {
            None => Some(a)
            // `None in coerces_to[...]` is always false, so type1 wins unless it's NULL
            Some(NULL) => None
            Some(d) => Some(D(d))
          }
      }
    (None, Some(b)) =>
      match b {
        T(t) if !t.expressions().is_empty() => Some(b)
        _ =>
          match b.this() {
            None => Some(b)
            Some(UNKNOWN) => Some(D(UNKNOWN))
            Some(_) => None
          }
      }
  }
}

///|
/// Python `self._set_type(expression, other.type)`.
fn TypeAnnotator::set_type_of(
  self : TypeAnnotator,
  expression : @core.Expr,
  other : @core.Expr?,
) -> Unit {
  self.set_type_expr(expression, other.bind(o => o.get_type()))
}

///|
/// Python `expr.is_type(*dtypes)` for an optional expression (`None` -> false).
fn opt_is_type(e : @core.Expr?, dtypes : Array[@core.DType]) -> Bool {
  match e {
    Some(x) => x.is_type(dtypes)
    None => false
  }
}

///|
/// Python `exp.DataType.from_str(sql, dialect=name)`; falls back to `fallback` when
/// the named dialect isn't registered.
fn datatype_from_str_in(
  sql : String,
  name : String,
  fallback : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  let dialect = match @core.get_dialect(name) {
    Some(d) => d
    None => fallback
  }
  @core.datatype_from_str(sql, dialect~)
}

///|
/// An annotator setting the type parsed from `sql` in the dialect `name`
/// (Python `lambda self, e: self._set_type(e, exp.DataType.from_str(sql, dialect=name))`).
fn set_type_from_str(sql : String, name : String) -> TypeSpec {
  Annotator((s, e) => {
    s.set_type_expr(e, Some(datatype_from_str_in(sql, name, s.dialect)))
  })
}

///|
/// Python `{"returns": exp.DataType.from_str(sql)}` (base dialect).
fn returns_from_str(sql : String) -> TypeSpec {
  Returns(T(try! @core.datatype_from_str(sql)))
}

///|
/// The integer value of a DataType parameter (Python `param.this.to_py()`).
fn datatype_param_int(param : @core.Expr?, default : Int) -> Int {
  match param {
    Some(p) => {
      let v = match p.this() {
        Some(t) => t.to_py_int()
        None => p.to_py_int()
      }
      match v {
        Some(i) => i.to_int()
        None => default
      }
    }
    None => default
  }
}
