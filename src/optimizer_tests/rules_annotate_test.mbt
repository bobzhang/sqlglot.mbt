// Fixture drivers for annotate_types.

///|
fn type_sql(e : @core.Expr, c : Case) -> String raise {
  match e.get_type() {
    Some(t) => @optimizer.sql_of(t, dialect?=c.dialect)
    None => "None"
  }
}

///|
test "optimizer annotate_types" {
  run_fixtures(
    "annotate_types",
    annotate_types_fixtures,
    pretty=false,
    (e, c) => @optimizer.annotate_types(e, dialect?=c.dialect),
    output=type_sql,
    check_parents=false,
  )
}

///|
test "optimizer annotate_functions" {
  run_fixtures(
    "annotate_functions",
    annotate_functions_fixtures,
    pretty=false,
    (e, c) => {
      let schema = @optimizer.MappingSchema::new(
        schema=@optimizer.schema_from_json_string(annotate_funcs_schema_json),
        dialect?=c.dialect,
      )
      @optimizer.annotate_types(e, schema~, dialect?=c.dialect).expressions()[0]
    },
    output=type_sql,
    check_parents=false,
  )
}
