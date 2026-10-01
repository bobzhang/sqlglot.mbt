// Generator overrides for the prql dialect.

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  // (the module-level table: only WINDOW and QUALIFY)
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
}
