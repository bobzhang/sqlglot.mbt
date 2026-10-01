// Port of sqlglot/typing/redshift.py.

///|
/// Python `sqlglot.typing.redshift.EXPRESSION_METADATA`.
fn redshift_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(postgres_expression_metadata())
  // Redshift's TO_TIMESTAMP returns TIMESTAMPTZ, not TIMESTAMP
  m[StrToTime] = Returns(D(TIMESTAMPTZ))
  // Redshift's RANK returns INTEGER; DENSE_RANK/NTILE/ROW_NUMBER return BIGINT (base default)
  m[Rank] = Returns(D(INT))
  // Postgres NTILE is INT, but Redshift's is BIGINT: restore the base default
  m[Ntile] = Returns(D(BIGINT))
  m
}
