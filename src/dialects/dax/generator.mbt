// Port of sqlglot/generators/dax.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(x => {
      x.0 == "windows" || x.0 == "qualify"
    },
  )
}
