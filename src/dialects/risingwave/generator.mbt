// Port of sqlglot/generators/risingwave.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  t[FileFormatProperty] = (g, e) => "FORMAT \{g.sql_key(e, "this")}"
  let m = d.gen_fns.methods
  // Python calls the base `Generator.computedcolumnconstraint_sql`, skipping Postgres.
  m[ComputedColumnConstraint] = (g, e) => g.computedcolumnconstraint_sql(e)
  let parent_datatype = m.get(DataType)
  m[DataType] = (g, e) => {
    let exprs = e.expressions()
    if e.is_type([MAP]) && exprs.length() == 2 {
      return "MAP(\{g.sql(Some(exprs[0]))}, \{g.sql(Some(exprs[1]))})"
    }
    match parent_datatype {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
}
