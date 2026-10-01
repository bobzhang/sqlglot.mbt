// Port of sqlglot/typing/spark.py.

///|
/// Python `sqlglot.typing.spark.EXPRESSION_METADATA`.
fn spark_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(spark2_expression_metadata())
  returns_all(m, [BitmapConstructAgg, ToBinary], BINARY)
  // 2-arg `date_add(startDate, numDays)` / `date_sub` are routed to TsOrDsAdd by
  // Hive/Spark parsers; both return DATE per the Spark and Databricks contracts.
  returns_all(m, [DateFromUnixDate, TsOrDsAdd], DATE)
  returns_all(m, [Sec], DOUBLE)
  returns_all(m, [Collation, CurrentTimezone, Randstr, ToChar], VARCHAR)
  annotate_all(
    m,
    [
      ArrayCompact,
      ArrayInsert,
      BitwiseAndAgg,
      BitwiseOrAgg,
      BitwiseXorAgg,
      Left,
      Overlay,
    ],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  m[BitmapCount] = Returns(D(BIGINT))
  m[Grouping] = Returns(D(TINYINT))
  m[Localtimestamp] = Returns(D(TIMESTAMPNTZ))
  m
}
