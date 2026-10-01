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
test "optimizer eliminate_ctes" {
  run_fixtures("eliminate_ctes", eliminate_ctes_fixtures, pretty=true, (e, _) => @optimizer.eliminate_ctes(
    e,
  ))
}
