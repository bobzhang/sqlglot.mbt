// Extra helpers of dialect_unit_tests_b (prefixed `b_` to avoid clashes).

///|
/// `e.name` of an optional expression ("<None>" when absent).
fn b_name(e : @core.Expr?) -> String {
  match e {
    Some(e) => e.name()
    None => "<None>"
  }
}

///|
/// The `DataType.Type` of an optional DataType expression ("<None>" when absent).
fn b_dtype(e : @core.Expr?) -> String {
  match e {
    Some(e) =>
      match e.datatype_this() {
        Some(d) => d.to_string()
        None => "<no type>"
      }
    None => "<None>"
  }
}

///|
/// Python `repr` of a scalar arg value (`'s'`, `True`, ...), "None" when absent.
fn b_value_repr(v : @core.Value?) -> String {
  match v {
    None => "None"
    Some(Str(s)) => "'\{s}'"
    Some(Bool(true)) => "True"
    Some(Bool(false)) => "False"
    Some(Int(i)) => i.to_string()
    Some(DT(d)) => d.to_string()
    Some(Node(e)) => e.canonical()
    Some(List(l)) => "[" + l.map(x => b_value_repr(Some(x))).join(", ") + "]"
  }
}

///|
/// A string arg value as is (other values as `b_value_repr`).
fn b_str(v : @core.Value?) -> String {
  match v {
    Some(Str(s)) => s
    v => b_value_repr(v)
  }
}

///|
/// Python `repr` of a list of strings.
fn b_list(l : Array[String]) -> String {
  "[" + l.map(s => "'\{s}'").join(", ") + "]"
}

///|
/// `expression.sql(dialect)` with `identify` given as a mode ("safe", "always", ...).
fn b_sql_identify(
  e : @core.Expr,
  dialect~ : String,
  identify_mode~ : String,
) -> String raise {
  @sqlglot.generate(e, dialect~, identify_mode~)
}
