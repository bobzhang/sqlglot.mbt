// Port of sqlglot/typing/clickhouse.py.

///|
/// Python `sqlglot.typing.clickhouse.EXPRESSION_METADATA`.
fn clickhouse_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(m, [CountIf], UBIGINT)
  m[MD5Digest] = set_type_from_str("FixedString(16)", "clickhouse")
  m[Corr] = set_type_from_str("Float64", "clickhouse")
  m
}
