// Direct assertions of tests/dialects/test_starrocks.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestStarrocks.test_starrocks" {
  let t = t(dialect="starrocks")
  t.eq_expr(
    t.validate_identity("arr[1]").expressions().get(0),
    Some(@core.literal_number("0")),
  )
  t.validate_identity("ARRAY_FLATTEN(arr)").assert_is(Flatten) |> ignore
  t.done()
}

///|
test "TestStarrocks.test_ddl" {
  let t = t(dialect="starrocks")
  let multi_column_cluster = @core.mk(ClusterProperty, [
    ("expressions", [@sqlglot.column("c"), @sqlglot.column("d")]),
  ])
  t.eq(sql(multi_column_cluster, dialect="starrocks"), "ORDER BY (c, d)")
  let single_column_cluster = @core.mk(ClusterProperty, [
    ("expressions", [@sqlglot.column("c")]),
  ])
  t.eq(sql(single_column_cluster, dialect="starrocks"), "ORDER BY (c)")
  t.done()
}

///|
test "TestStarrocks.test_table_function" {
  let t = t(dialect="starrocks")
  t
  .validate_identity("SELECT * FROM TABLE(GENERATE_SERIES(0, 10))")
  .arg("from_")
  .unwrap()
  .this_()
  .assert_is(TableFromRows)
  .this_()
  .assert_is(GenerateSeries)
  |> ignore
  t.done()
}
