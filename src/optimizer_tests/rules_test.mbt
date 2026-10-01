// Drives each optimizer rule over its fixtures, mirroring tests/test_optimizer.py.

///|
test "optimizer qualify_tables" {
  run_fixtures("qualify_tables", qualify_tables_fixtures, pretty=false, (
    e,
    c,
  ) => @optimizer.qualify_tables(
    e,
    db="db",
    catalog="c",
    dialect?=c.dialect,
    canonicalize_table_aliases=c.meta_bool("canonicalize_table_aliases").unwrap_or(
      false,
    ),
  ))
}
