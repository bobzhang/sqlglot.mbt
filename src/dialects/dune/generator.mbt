// Port of sqlglot/generators/dune.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  d.gen_fns.transforms[HexString] = (_, e) => "0x\{e.text("this")}"
}
