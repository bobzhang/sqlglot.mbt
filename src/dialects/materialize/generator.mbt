// Port of sqlglot/generators/materialize.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  t.remove(ToMap)
  t[AutoIncrementColumnConstraint] = (_, _) => ""
  t[Create] = @core.preprocess([
    @core.remove_unique_constraints,
    @core.ctas_with_tmp_tables_to_create_tmp_view(),
  ])
  t[GeneratedAsIdentityColumnConstraint] = (_, _) => ""
  t[OnConflict] = (_, _) => ""
  t[PrimaryKeyColumnConstraint] = (_, _) => ""
  let m = d.gen_fns.methods
  m[PropertyEQ] = (g, e) => g.binary(e, "=>")
  let parent_datatype = m.get(DataType)
  m[DataType] = (g, e) => {
    if e.is_type([LIST]) {
      if !e.expressions().is_empty() {
        return "\{g.expressions(expression=e, flat=true)} LIST"
      }
      return "LIST"
    }
    let exprs = e.expressions()
    if e.is_type([MAP]) && exprs.length() == 2 {
      return "MAP[\{g.sql(Some(exprs[0]))} => \{g.sql(Some(exprs[1]))}]"
    }
    match parent_datatype {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
  m[List] = (g, e) => {
    let exprs = e.expressions()
    if exprs.length() > 0 && exprs[0].kind.is_a(Select) {
      return g.func("LIST", [exprs[0]])
    }
    "\{g.normalize_func("LIST")}[\{g.expressions(expression=e, flat=true)}]"
  }
  m[ToMap] = (g, e) => {
    match e.this() {
      Some(this) if this.kind.is_a(Select) => g.func("MAP", [this])
      this => "\{g.normalize_func("MAP")}[\{g.expressions(expression?=this)}]"
    }
  }
}
