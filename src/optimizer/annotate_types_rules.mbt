// The annotator methods of TypeAnnotator (port of the `_annotate_*` methods).

///|
/// An argument reference for `annotate_by_args`: an arg key, or an expression.
pub(all) enum ArgRef {
  Key(String)
  Node(@core.Expr)
}

///|
pub fn TypeAnnotator::annotate_binary(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit raise @core.SqlglotError {
  let (left, right) = match (expression.this(), expression.expression()) {
    (Some(l), Some(r)) => (l, r)
    // Python's `Binary.left` is `self.args["this"]`, which raises a KeyError when the
    // node was built without a `this` key at all (e.g. Exasol's
    // `exp.JSONExtract(expressions=args)`). The port can't tell an absent key from an
    // explicit `None`, so a binary node missing both operands stands for the former
    // (one built through `exp.Binary(this=..., expression=...)` always has both keys).
    (None, None) => raise @core.OptimizeError("KeyError: 'this'")
    _ => {
      self.set_type(expression, None)
      return
    }
  }
  let left_type = type_this_or_unknown(left)
  let right_type = type_this_or_unknown(right)
  if expression.kind.is_any([Connector, Predicate]) {
    self.set_dtype(expression, BOOLEAN)
  } else {
    match self.binary_coercions.get((left_type, right_type)) {
      Some(f) => self.set_type(expression, f(left, right))
      None => self.annotate_by_args(expression, [Node(left), Node(right)])
    }
  }
  if expression.kind.is_a(Is) ||
    (left.meta_get("nonnull") is Some(Bool(true)) &&
    right.meta_get("nonnull") is Some(Bool(true))) {
    expression.get_meta()["nonnull"] = Bool(true)
  }
}

///|
pub fn TypeAnnotator::annotate_unary(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this_()
  if expression.kind.is_a(Not) {
    self.set_dtype(expression, BOOLEAN)
  } else {
    self.set_type(expression, type_of(this))
  }
  if this.meta_get("nonnull") is Some(Bool(true)) {
    expression.get_meta()["nonnull"] = Bool(true)
  }
}

///|
pub fn TypeAnnotator::annotate_literal(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  if expression.is_string() {
    self.set_dtype(expression, VARCHAR)
  } else if expression.is_int() {
    self.set_dtype(expression, INT)
  } else {
    self.set_dtype(expression, DOUBLE)
  }
  expression.get_meta()["nonnull"] = Bool(true)
}

///|
fn ttype_in(t : TType, set : Array[@core.DType]) -> Bool {
  match t.this() {
    Some(d) => set.contains(d)
    None => false
  }
}

///|
pub fn TypeAnnotator::annotate_by_args(
  self : TypeAnnotator,
  expression : @core.Expr,
  args : Array[ArgRef],
  promote? : Bool = false,
  array? : Bool = false,
) -> Unit {
  let mut literal_type : TType? = None
  let mut non_literal_type : TType? = None
  let mut nested_type : TType? = None
  for arg in args {
    let exprs = match arg {
      Key(k) =>
        match expression.get(k) {
          Some(Node(e)) => [e]
          Some(List(_)) => expression.list(k)
          _ => []
        }
      Node(e) => [e]
    }
    for expr in exprs {
      let expr_type = match expr.get_type() {
        Some(t) if !t.is_type([UNKNOWN]) => t
        _ => {
          self.set_dtype(expression, UNKNOWN)
          return
        }
      }
      if nested_type is Some(_) {
        continue
      }
      if expr_type.has("nested") {
        nested_type = Some(T(expr_type))
      } else if expr.kind.is_a(Literal) {
        literal_type = Some(
          self.maybe_coerce(literal_type.unwrap_or(T(expr_type)), T(expr_type)),
        )
      } else {
        non_literal_type = Some(
          self.maybe_coerce(
            non_literal_type.unwrap_or(T(expr_type)),
            T(expr_type),
          ),
        )
      }
    }
  }
  let mut result_type : TType? = None
  match (nested_type, literal_type, non_literal_type) {
    (Some(n), _, _) => result_type = Some(n)
    (None, Some(lt), Some(nlt)) => {
      if self.dialect.cfg.prioritize_non_literal_types {
        if (ttype_in(lt, @core.dtype_integer_types) &&
          ttype_in(nlt, @core.dtype_integer_types)) ||
          (ttype_in(lt, @core.dtype_real_types) &&
          ttype_in(nlt, @core.dtype_real_types)) {
          result_type = Some(nlt)
        }
      }
      if result_type is None {
        result_type = Some(self.maybe_coerce(nlt, lt))
      }
    }
    (None, Some(lt), None) => result_type = Some(lt)
    (None, None, Some(nlt)) => result_type = Some(nlt)
    (None, None, None) => result_type = Some(D(UNKNOWN))
  }
  self.set_type(expression, result_type)
  if promote {
    let rt = result_type.unwrap()
    if ttype_in(rt, @core.dtype_integer_types) {
      self.set_dtype(expression, BIGINT)
    } else if ttype_in(rt, @core.dtype_float_types) {
      self.set_dtype(expression, DOUBLE)
    }
  }
  if array {
    self.set_type(
      expression,
      Some(
        T(
          @core.mk(DataType, [
            ("this", @core.DType::ARRAY),
            ("expressions", [expression.get_type().unwrap()]),
            ("nested", true),
          ]),
        ),
      ),
    )
  }
}

///|
pub fn TypeAnnotator::annotate_timeunit(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this_()
  let t = type_this_or_unknown(this)
  let unit = expression.arg("unit")
  let datatype = if @core.dtype_text_types.contains(t) {
    coerce_date_literal(this, unit)
  } else if @core.dtype_temporal_types.contains(t) {
    coerce_date(this, unit)
  } else {
    D(UNKNOWN)
  }
  self.set_type(expression, Some(datatype))
}

///|
pub fn TypeAnnotator::annotate_bracket(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let bracket_arg = expression.expressions()[0]
  let this = expression.this_()
  if bracket_arg.kind.is_a(Slice) {
    self.set_type(expression, type_of(this))
  } else if this.is_type([ARRAY]) {
    self.set_type_expr(expression, this.get_type().unwrap().expressions().get(0))
  } else if this.kind.is_any([Map, VarMap]) &&
    map_keys(this).contains(bracket_arg) {
    let keys = map_keys(this)
    let mut index = 0
    for i, k in keys {
      if k == bracket_arg {
        index = i
        break
      }
    }
    match map_values(this).get(index) {
      Some(value) => self.set_type(expression, type_of(value))
      None => self.set_type(expression, None)
    }
  } else {
    self.set_dtype(expression, UNKNOWN)
  }
}

///|
fn map_keys(e : @core.Expr) -> Array[@core.Expr] {
  match e.arg("keys") {
    Some(k) => k.expressions()
    None => []
  }
}

///|
fn map_values(e : @core.Expr) -> Array[@core.Expr] {
  match e.arg("values") {
    Some(k) => k.expressions()
    None => []
  }
}

///|
pub fn TypeAnnotator::annotate_div(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let left_type = match expression.this() {
    Some(l) => type_this_or_unknown(l)
    None => UNKNOWN
  }
  let right_type = match expression.expression() {
    Some(r) => type_this_or_unknown(r)
    None => UNKNOWN
  }
  if expression.has("typed") &&
    @core.dtype_integer_types.contains(left_type) &&
    @core.dtype_integer_types.contains(right_type) {
    self.set_dtype(expression, BIGINT)
  } else {
    self.set_type(expression, Some(self.maybe_coerce(D(left_type), D(right_type))))
    match expression.get_type() {
      Some(t) =>
        match t.datatype_this() {
          Some(d) if @core.dtype_real_types.contains(d) => ()
          _ =>
            self.set_type(
              expression,
              Some(self.maybe_coerce(T(t), D(DOUBLE))),
            )
        }
      None => ()
    }
  }
}

///|
pub fn TypeAnnotator::annotate_dot(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  self.set_type(expression, None)
  match expression.expression() {
    Some(e) if e.kind.is_a(Anonymous) => {
      self.set_type(expression, type_of(e))
      return
    }
    _ => ()
  }
  match expression.this_().get_type() {
    Some(this_type) if this_type.is_type([STRUCT]) => {
      let name = match expression.expression() {
        Some(e) => e.name()
        None => ""
      }
      for e in this_type.expressions() {
        if e.name() == name {
          self.set_type_expr(expression, e.arg("kind"))
          break
        }
      }
    }
    _ => ()
  }
}

///|
pub fn TypeAnnotator::annotate_explode(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  match expression.this_().get_type() {
    Some(t) if t.is_type([ARRAY]) => self.set_type_expr(expression, t.expressions().get(0))
    _ => self.set_type(expression, None)
  }
}

///|
pub fn TypeAnnotator::annotate_unnest(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let expr_type = match expression.expressions().get(0) {
    Some(child) if child.is_type([ARRAY]) =>
      child.get_type().unwrap().expressions().get(0)
    _ => None
  }
  self.set_type_expr(expression, expr_type)
}

///|
pub fn TypeAnnotator::annotate_subquery(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let query = expression.unnest()
  if query.kind.is_a(Query) {
    let selects = query.selects()
    if selects.length() == 1 {
      self.set_type(expression, type_of(selects[0]))
      return
    }
  }
  self.set_dtype(expression, UNKNOWN)
}

///|
/// Returns `Err(())` for Python's `None` (unknown field type).
fn annotate_struct_value(expression : @core.Expr) -> @core.Expr? {
  let mut this : @core.Expr? = None
  let mut kind = expression.get_type()
  match expression.arg("alias") {
    Some(alias) => this = Some(alias.copy())
    None =>
      match expression.expression() {
        Some(e) => {
          this = expression.this().map(t => t.copy())
          kind = e.get_type()
        }
        None =>
          if expression.kind.is_a(Column) {
            this = expression.this().map(t => t.copy())
          }
      }
  }
  match kind {
    Some(k) if k.is_type([UNKNOWN]) => return None
    _ => ()
  }
  match this {
    Some(t) => Some(@core.mk(ColumnDef, [("this", Some(t)), ("kind", kind)]))
    None => kind
  }
}

///|
pub fn TypeAnnotator::annotate_struct(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let expressions = []
  for expr in expression.expressions() {
    match annotate_struct_value(expr) {
      Some(t) => expressions.push(t)
      None => {
        self.set_type(expression, None)
        return
      }
    }
  }
  self.set_type(expression, Some(T(struct_datatype(expressions))))
}

///|
pub fn TypeAnnotator::annotate_map(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let keys = expression.arg("keys")
  let values = expression.arg("values")
  let map_type = @core.datatype_of(MAP)
  match (keys, values) {
    (Some(k), Some(v)) if k.kind.is_a(Array) && v.kind.is_a(Array) => {
      let key_type = k.get_type().map(t => t.expressions()).unwrap_or([]).get(0)
      let value_type = v.get_type().map(t => t.expressions()).unwrap_or([]).get(0)
      match (key_type, value_type) {
        (Some(kt), Some(vt)) => {
          map_type.set("expressions", [kt, vt])
          map_type.set("nested", true)
        }
        _ => ()
      }
    }
    _ => ()
  }
  self.set_type(expression, Some(T(map_type)))
}

///|
pub fn TypeAnnotator::annotate_to_map(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let map_type = @core.datatype_of(MAP)
  let arg = expression.this_()
  if arg.is_type([STRUCT]) {
    match arg.get_type().unwrap().expressions().get(0) {
      Some(coldef) => {
        map_type.set("expressions", [
          Some(@core.datatype_of(VARCHAR)),
          coldef.arg("kind"),
        ])
        map_type.set("nested", true)
      }
      None => ()
    }
  }
  self.set_type(expression, Some(T(map_type)))
}

///|
pub fn TypeAnnotator::annotate_extract(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let part = expression.name()
  if part == "TIME" {
    self.set_dtype(expression, TIME)
  } else if part == "DATE" {
    self.set_dtype(expression, DATE)
  } else if bigint_extract_date_parts.contains(part) {
    self.set_dtype(expression, BIGINT)
  } else {
    self.set_dtype(expression, INT)
  }
}

///|
pub fn TypeAnnotator::annotate_within_group(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  if expression.this_().kind.is_a(PercentileDisc) {
    let order_expressions = match expression.arg("expression") {
      Some(o) => o.expressions()
      None => []
    }
    let sort_type = if order_expressions.is_empty() {
      Some(D(UNKNOWN))
    } else {
      type_of(order_expressions[0].this_())
    }
    self.set_type(expression, sort_type)
    return
  }
  self.annotate_by_args(expression, [Key("this")])
}

///|
pub fn TypeAnnotator::annotate_by_array_element(
  self : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let array_arg = expression.this_()
  match array_arg.get_type() {
    Some(t) if t.is_type([ARRAY]) =>
      match t.expressions().get(0) {
        Some(e) => self.set_type(expression, Some(T(e)))
        None => self.set_dtype(expression, UNKNOWN)
      }
    _ => self.set_dtype(expression, UNKNOWN)
  }
}
