// DataType helpers (port of parts of sqlglot/expressions/datatypes.py).

///|
/// `DataType(this=dtype)` (Python `DType.into_expr()` / `DataType.build(dtype)`).
pub fn datatype_of(dtype : DType) -> Expr {
  mk1(DataType, dtype)
}

///|
/// `DataType.build(dtype, **kwargs)` for a `DType`.
pub fn datatype_build(
  dtype : DType,
  kwargs? : ArrayView[(String, &IntoValue)] = [],
) -> Expr {
  let dt = datatype_of(dtype)
  for kv in kwargs {
    dt.set(kv.0, kv.1)
  }
  dt
}

///|
/// Python `DType.into_expr()`.
pub fn DType::into_expr(self : DType) -> Expr {
  datatype_of(self)
}

///|
/// The `DType` stored in a DataType's `this`, if it's a plain type.
pub fn Expr::datatype_this(self : Expr) -> DType? {
  match self.args.get("this") {
    Some(DT(d)) => Some(d)
    _ => None
  }
}

///|
/// `DataType.is_type(*dtypes)` for plain `DType`s.
pub fn datatype_is_type(dt : Expr, dtypes : ArrayView[DType]) -> Bool {
  let this = dt.datatype_this()
  for d in dtypes {
    let matches = if this == Some(DType::USERDEFINED) || d == DType::USERDEFINED {
      dt == datatype_of(d)
    } else {
      this == Some(d)
    }
    if matches {
      return true
    }
  }
  false
}

///|
/// `DataType.is_type(other)` for a DataType expression `other`.
pub fn datatype_is_type_expr(dt : Expr, other : Expr) -> Bool {
  let this = dt.datatype_this()
  let other_this = other.datatype_this()
  if !other.list("expressions").is_empty() ||
    this == Some(DType::USERDEFINED) ||
    other_this == Some(DType::USERDEFINED) {
    dt == other
  } else {
    match (dt.args.get("this"), other.args.get("this")) {
      (Some(DT(a)), Some(DT(b))) => a == b
      (None, None) => true
      (Some(Node(a)), Some(Node(b))) => a == b
      (Some(Str(a)), Some(Str(b))) => a == b
      _ => false
    }
  }
}

///|
/// Python `Expr.is_type(*dtypes)`.
pub fn Expr::is_type(self : Expr, dtypes : ArrayView[DType]) -> Bool {
  if self.kind.is_data_type() {
    return datatype_is_type(self, dtypes)
  }
  if self.kind.is_cast() {
    return match self.arg("to") {
      Some(to) => to.is_type(dtypes)
      None => false
    }
  }
  match self.type_ {
    Some(t) => datatype_is_type(t, dtypes)
    None => false
  }
}

///|
/// Python `Expr.is_type(data_type_expr)`.
pub fn Expr::is_type_expr(self : Expr, other : Expr) -> Bool {
  if self.kind.is_data_type() {
    return datatype_is_type_expr(self, other)
  }
  if self.kind.is_cast() {
    return match self.arg("to") {
      Some(to) => to.is_type_expr(other)
      None => false
    }
  }
  match self.type_ {
    Some(t) => datatype_is_type_expr(t, other)
    None => false
  }
}
