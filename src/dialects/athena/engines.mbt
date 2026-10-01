// The engine-specific dialects Athena routes to (Python `_TrinoTokenizer`,
// `AthenaTrinoParser`, `AthenaTrinoGenerator` with a Trino dialect, and `_HiveGenerator`
// with a Hive dialect).

///|
let athena_trino_cell : Ref[@core.Dialect?] = Ref(None)

///|
/// Trino with Athena's extensions: the UNLOAD keyword, the USING statement and the
/// CTAS table property spellings.
pub fn athena_trino_dialect() -> @core.Dialect {
  match athena_trino_cell.val {
    Some(d) => d
    None => {
      let d = @core.Dialect::subclass(@trino.dialect(), "trino", d => {
        d.tokenizer.keywords["UNLOAD"] = COMMAND
        configure_athena_trino_parser(d)
        configure_athena_trino_generator(d)
      })
      athena_trino_cell.val = Some(d)
      d
    }
  }
}

///|
let athena_hive_cell : Ref[@core.Dialect?] = Ref(None)

///|
/// Hive, used for most of Athena's DDL.
pub fn athena_hive_dialect() -> @core.Dialect {
  match athena_hive_cell.val {
    Some(d) => d
    None => {
      let d = @core.Dialect::subclass(@hive.dialect(), "hive", d => {
        let parent_alter = d.gen_fns.methods.get(Alter)
        d.gen_fns.methods[Alter] = (g, e) => {
          if e.kind.is_a(Alter) && @core.py_upper(e.text("kind")) == "TABLE" {
            let actions = e.list("actions")
            if !actions.is_empty() && actions[0].kind.is_a(ColumnDef) {
              let new_actions = @core.mk(Schema, [("expressions", actions)])
              e.set("actions", [new_actions])
            }
          }
          match parent_alter {
            Some(f) => f(g, e)
            None => g.alter_sql(e)
          }
        }
      })
      athena_hive_cell.val = Some(d)
      d
    }
  }
}

///|
/// Python `AthenaTrinoParser.STATEMENT_PARSERS`.
fn configure_athena_trino_parser(d : @core.Dialect) -> Unit {
  d.parser_fns.statement_parsers[USING] = p => Some(p.parse_as_command(p.prev))
}

///|
/// Python `AthenaTrinoGenerator.TRANSFORMS`.
fn configure_athena_trino_generator(d : @core.Dialect) -> Unit {
  d.gen_cfg.properties_location[LocationProperty] = PostWith
  d.gen_fns.transforms[PartitionedByProperty] = partitioned_by_property_sql
  d.gen_fns.transforms[LocationProperty] = location_property_sql
}

///|
fn is_iceberg_table(properties : @core.Expr) -> Bool {
  for p in properties.expressions() {
    if p.kind.is_a(Property) && p.name() == "table_type" {
      return @core.py_lower(p.text("value")) == "iceberg"
    }
  }
  false
}

///|
/// If table_type='iceberg', the LocationProperty is called 'location'
/// Otherwise, it's called 'external_location'
/// ref: https://docs.aws.amazon.com/athena/latest/ug/create-table-as.html
fn location_property_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let prop_name = match e.parent {
    Some(p) if p.kind.is_a(Properties) && is_iceberg_table(p) => "location"
    _ => "external_location"
  }
  "\{prop_name}=\{g.sql_key(e, "this")}"
}

///|
/// If table_type='iceberg' then the table property for partitioning is called 'partitioning'
/// If table_type='hive' it's called 'partitioned_by'
/// ref: https://docs.aws.amazon.com/athena/latest/ug/create-table-as.html#ctas-table-properties
fn partitioned_by_property_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let prop_name = match e.parent {
    Some(p) if p.kind.is_a(Properties) && is_iceberg_table(p) => "partitioning"
    _ => "partitioned_by"
  }
  "\{prop_name}=\{g.sql_key(e, "this")}"
}
