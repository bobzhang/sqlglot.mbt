// Installs the optimizer's annotate_types/simplify into the core hooks used by the
// generator (Python's generator imports sqlglot.optimizer lazily).

///|
/// Installs the real `annotate_types` and `simplify` implementations into core.
pub fn install() -> Unit {
  @core.annotate_types_hook.val = Some(fn(e, d) { annotate_types(e, dialect=d) })
  @core.simplify_hook.val = Some(fn(e, d) { simplify(e, dialect=d) })
}

///|
fn init {
  install()
}
