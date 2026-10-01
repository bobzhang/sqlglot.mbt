// Port of sqlglot/generators/tableau.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(x => {
      x.0 == "windows" || x.0 == "qualify"
    },
  )
  let t = d.gen_fns.transforms
  t[Coalesce] = @core.rename_func("IFNULL")
  t[Select] = @core.preprocess([@core.eliminate_distinct_on])
  let m = d.gen_fns.methods
  m[If] = (g, e) => {
    let this = g.sql_key(e, "this")
    let true_ = g.sql_key(e, "true")
    let false_ = g.sql_key(e, "false")
    "IF \{this} THEN \{true_} ELSE \{false_} END"
  }
  m[Count] = (g, e) => {
    match e.this() {
      Some(this) if this.kind == Distinct =>
        g.func("COUNTD", this.expressions().map(x => (x : &@core.SqlArg)))
      this => g.func("COUNT", [this])
    }
  }
  m[StrPosition] = (g, e) => {
    let has_occurrence = e.args.contains("occurrence")
    @core.strposition_sql(
      g,
      e,
      func_name=if has_occurrence { "FINDNTH" } else { "FIND" },
      supports_occurrence=has_occurrence,
    )
  }
}
