// Port of sqlglot/generators/druid.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(
    x => x.0 == "windows" || x.0 == "qualify",
  )
  let t = d.gen_fns.transforms
  t[CurrentTimestamp] = (_, _) => "CURRENT_TIMESTAMP"
  t[Mod] = @core.rename_func("MOD")
  t[Array] = (g, e) => "ARRAY[\{g.expressions(expression=e)}]"
}
