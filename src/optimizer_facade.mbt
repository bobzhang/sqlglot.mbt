// Optimizer entry points of the facade (Python `sqlglot.optimizer`).

///|
fn init {
  // The generator relies on annotate_types/simplify for some transpilations.
  @optimizer.install()
}
