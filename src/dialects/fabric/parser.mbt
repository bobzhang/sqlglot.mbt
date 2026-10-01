// Port of sqlglot/parsers/fabric.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let h = d.parser_fns.hooks
  let parent_parse_create = h.parse_create
  h.parse_create = Some(p => {
    let create = match parent_parse_create {
      Some(f) => f(p)
      None => p.parse_create_base()
    }
    match create {
      Some(c) if c.kind == Create &&
        c.text("kind") == "TABLE" &&
        c.this() is Some(schema) &&
        schema.kind == Schema =>
        // Transform VARCHAR/CHAR without precision to VARCHAR(1)/CHAR(1)
        for column in c.this().unwrap().expressions() {
          if column.kind != ColumnDef {
            continue
          }
          match column.arg("kind") {
            Some(column_type) if column_type.kind == DataType &&
              (
                column_type.datatype_this() == Some(VARCHAR) ||
                column_type.datatype_this() == Some(CHAR)
              ) &&
              column_type.expressions().is_empty() =>
              // Add default precision of 1 to VARCHAR/CHAR without precision
              // When n isn't specified in a data definition or variable declaration statement, the default length is 1.
              column_type.set("expressions", [@core.literal_number("1")])
            _ => ()
          }
        }
      _ => ()
    }
    create
  })
}
