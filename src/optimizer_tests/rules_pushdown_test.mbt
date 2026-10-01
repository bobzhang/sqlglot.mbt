// Fixture drivers for the pushdown rules.

///|
test "optimizer pushdown_predicates" {
  run_fixtures("pushdown_predicates", pushdown_predicates_fixtures, pretty=false, (
    e,
    c,
  ) => @optimizer.pushdown_predicates(e, dialect?=c.dialect))
}

///|
test "optimizer pushdown_projections" {
  run_fixtures(
    "pushdown_projections",
    pushdown_projections_fixtures,
    pretty=false,
    (e, c) => {
      let schema = c.schema(test_schema_json)
      let e = @optimizer.qualify_tables(e)
      let e = @optimizer.qualify_columns(e, schema, infer_schema=true)
      @optimizer.pushdown_projections(e)
    },
  )
}
