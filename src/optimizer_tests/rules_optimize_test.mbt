// Fixture drivers for the full optimizer (`optimize` with the default rules).

///|
fn run_optimize(
  e : @core.Expr,
  c : Case,
  default_schema : String,
  infer_schema? : Bool,
) -> @core.Expr raise {
  @optimizer.optimize(
    e,
    schema=c.schema(default_schema),
    dialect?=c.dialect,
    infer_schema?,
    leave_tables_isolated=c.meta_bool("leave_tables_isolated").unwrap_or(false),
    validate_qualify_columns=c.meta_bool("validate_qualify_columns").unwrap_or(
      true,
    ),
    canonicalize_table_aliases=c.meta_bool("canonicalize_table_aliases").unwrap_or(
      false,
    ),
  )
}

///|
test "optimizer optimizer" {
  run_fixtures("optimizer", optimizer_fixtures, pretty=true, (e, c) => run_optimize(
    e,
    c,
    optimizer_schema_json,
    infer_schema=true,
  ))
}

///|
test "optimizer tpch" {
  run_fixtures("tpch", tpch_fixtures, pretty=true, (e, c) => run_optimize(
    e, c, tpch_schema_json,
  ))
}

///|
test "optimizer tpcds" {
  run_fixtures("tpcds", tpcds_fixtures, pretty=true, (e, c) => run_optimize(
    e, c, tpcds_schema_json,
  ))
}
