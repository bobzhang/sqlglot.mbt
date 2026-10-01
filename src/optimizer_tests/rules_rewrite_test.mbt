// Fixture drivers for the remaining rewrite rules.

///|
test "optimizer unnest_subqueries" {
  run_fixtures("unnest_subqueries", unnest_subqueries_fixtures, pretty=false, (
    e,
    _,
  ) => @optimizer.unnest_subqueries(e))
}

///|
test "optimizer optimize_joins" {
  run_fixtures("optimize_joins", optimize_joins_fixtures, pretty=false, (e, _) => @optimizer.optimize_joins(
    e,
  ))
}

///|
test "optimizer eliminate_joins" {
  run_fixtures("eliminate_joins", eliminate_joins_fixtures, pretty=true, (e, _) => @optimizer.eliminate_joins(
    e,
  ))
}

///|
test "optimizer eliminate_subqueries" {
  run_fixtures(
    "eliminate_subqueries",
    eliminate_subqueries_fixtures,
    pretty=false,
    (e, _) => @optimizer.eliminate_subqueries(e),
  )
}

///|
test "optimizer merge_subqueries" {
  run_fixtures("merge_subqueries", merge_subqueries_fixtures, pretty=false, (
    e,
    c,
  ) => {
    let schema = c.schema(test_schema_json)
    let e = @optimizer.qualify_tables(e.copy(), dialect?=c.dialect)
    let e = @optimizer.qualify_columns(e, schema)
    @optimizer.merge_subqueries(
      e,
      leave_tables_isolated=c.meta_bool("leave_tables_isolated").unwrap_or(false),
    )
  })
}

///|
test "optimizer eliminate_ctes" {
  run_fixtures("eliminate_ctes", eliminate_ctes_fixtures, pretty=true, (e, _) => @optimizer.eliminate_ctes(
    e,
  ))
}
