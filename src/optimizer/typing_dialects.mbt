// Registration of the per-dialect typing rules (Python sqlglot/typing/<dialect>.py).
//
// Only dialects whose Python class defines `EXPRESSION_METADATA` / `COERCES_TO` are
// registered; the others inherit them through their parent chain (e.g. trino -> presto,
// doris -> mysql, spark -> spark2 -> hive).

///|
fn register_dialect_typings() -> Unit {
  register_expression_metadata("bigquery", bigquery_expression_metadata)
  register_expression_metadata("clickhouse", clickhouse_expression_metadata)
  register_expression_metadata("databricks", databricks_expression_metadata)
  register_expression_metadata("duckdb", duckdb_expression_metadata)
  register_expression_metadata("hive", hive_expression_metadata)
  register_expression_metadata("mysql", mysql_expression_metadata)
  register_expression_metadata("postgres", postgres_expression_metadata)
  register_expression_metadata("presto", presto_expression_metadata)
  register_expression_metadata("redshift", redshift_expression_metadata)
  register_expression_metadata("snowflake", snowflake_expression_metadata)
  register_expression_metadata("spark", spark_expression_metadata)
  register_expression_metadata("spark2", spark2_expression_metadata)
  register_expression_metadata("tsql", tsql_expression_metadata)
  register_coerces_to("bigquery", bigquery_coerces_to)
  register_coerces_to("databricks", databricks_coerces_to)
  register_coerces_to("hive", hive_coerces_to)
}
