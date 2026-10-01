// Port of sqlglot/generators/athena.py

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  // (the module-level table: only WINDOW and QUALIFY)
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
  configure_athena_trino_generator(d)
  d.gen_fns.hooks.generate = Some((g, e, copy) => {
    let engine = if generate_as_hive(e) {
      athena_hive_dialect()
    } else {
      athena_trino_dialect()
    }
    @core.Generator::new(
      engine,
      pretty=g.pretty,
      identify=g.identify,
      normalize=g.normalize,
      pad=g.pad,
      indent=g.indent_size,
      normalize_functions=g.normalize_functions,
      unsupported_level=g.unsupported_level,
      max_unsupported=g.max_unsupported,
      leading_comma=g.leading_comma,
      max_text_width=g.max_text_width,
      comments=g.comments,
    ).generate(e, copy~)
  })
}

///|
fn generate_as_hive(e : @core.Expr) -> Bool {
  if e.kind.is_a(Create) {
    if @core.py_upper(e.text("kind")) == "TABLE" {
      // CREATE EXTERNAL TABLE is Hive
      match e.arg("properties") {
        Some(properties) if properties.find([ExternalProperty]) is Some(_) =>
          return true
        _ => ()
      }
      // Any CREATE TABLE other than CREATE TABLE ... As <query> is Hive
      match e.expression() {
        Some(q) if q.kind.is_a(Query) => ()
        _ => return true
      }
    } else {
      // CREATE VIEW is Trino, but CREATE SCHEMA, CREATE DATABASE, etc, is Hive
      return @core.py_upper(e.text("kind")) != "VIEW"
    }
  } else if e.kind.is_any([Alter, Drop, Describe, Show]) {
    if e.kind.is_a(Drop) && @core.py_upper(e.text("kind")) == "VIEW" {
      // DROP VIEW is Trino, because CREATE VIEW is as well
      return false
    }
    // Everything else, e.g., ALTER statements, is Hive
    return true
  }
  false
}
