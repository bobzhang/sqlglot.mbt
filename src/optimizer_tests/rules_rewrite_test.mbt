// Fixture drivers for the remaining rewrite rules.

///|
test "optimizer unnest_subqueries" {
  run_fixtures("unnest_subqueries", unnest_subqueries_fixtures, pretty=false, (
    e,
    _,
  ) => @optimizer.unnest_subqueries(e))
}
