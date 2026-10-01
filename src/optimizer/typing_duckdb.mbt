// Port of sqlglot/typing/duckdb.py.

///|
let duckdb_datetime_without_tz : Array[@core.DType] = [
  DATE,
  TIMESTAMP,
  TIMESTAMPNTZ,
  TIMESTAMP_S,
  TIMESTAMP_MS,
  TIMESTAMP_NS,
]

///|
fn duckdb_annotate_at_time_zone(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this()
  if opt_is_type(this, duckdb_datetime_without_tz) {
    s.set_dtype(expression, TIMESTAMPTZ)
  } else if opt_is_type(this, [TIMESTAMPTZ]) {
    s.set_dtype(expression, TIMESTAMP)
  } else if opt_is_type(this, [TIMETZ]) {
    s.set_dtype(expression, TIMETZ)
  } else {
    s.set_dtype(expression, UNKNOWN)
  }
}

///|
fn duckdb_annotate_date_trunc(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this()
  if opt_is_type(this, [DATE, TIMESTAMP_S, TIMESTAMP_MS, TIMESTAMP_NS]) {
    s.set_dtype(expression, TIMESTAMP)
  } else {
    s.set_type_of(expression, this)
  }
}

///|
/// Python `sqlglot.typing.duckdb.EXPRESSION_METADATA`.
fn duckdb_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(
    m,
    [
      BitLength,
      DateDiff,
      Day,
      DayOfMonth,
      DayOfWeek,
      DayOfWeekIso,
      DayOfYear,
      Extract,
      Hour,
      Length,
      Minute,
      Month,
      Quarter,
      Second,
      Week,
      Year,
    ],
    BIGINT,
  )
  returns_all(m, [CountIf, Factorial], INT128)
  returns_all(m, [Atan2, JarowinklerSimilarity, TimeToUnix], DOUBLE)
  returns_all(m, [Format, Reverse, Decode], VARCHAR)
  returns_all(m, [Encode, Unhex], VARBINARY)
  annotate_all(
    m,
    [BitwiseAndAgg, BitwiseOrAgg, BitwiseXorAgg, PercentileDisc],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  m[AtTimeZone] = Annotator((s, e) => duckdb_annotate_at_time_zone(s, e))
  m[DateBin] = Annotator((s, e) => s.annotate_by_args(e, [Key("expression")]))
  m[DateTrunc] = Annotator((s, e) => duckdb_annotate_date_trunc(s, e))
  m[TimestampTrunc] = Annotator((s, e) => duckdb_annotate_date_trunc(s, e))
  m[Localtimestamp] = Returns(D(TIMESTAMP))
  m[ToDays] = Returns(D(INTERVAL))
  m[TimeFromParts] = Returns(D(TIME))
  m[TimestampFromParts] = Returns(D(TIMESTAMP))
  m
}
