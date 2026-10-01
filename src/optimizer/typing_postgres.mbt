// Port of sqlglot/typing/postgres.py.

///|
/// Python `sqlglot.typing.postgres.EXPRESSION_METADATA`.
fn postgres_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(m, [Ntile, WidthBucket], INT)
  returns_all(
    m,
    [
      Encode,
      Left,
      Right,
      Overlay,
      Reverse,
      Pad,
      Format,
      Hex,
      SplitPart,
      Normalize,
      RegexpReplace,
      Replace,
    ],
    TEXT,
  )
  returns_all(m, [Decode], VARBINARY)
  returns_all(m, [TimeFromParts], TIME)
  returns_all(m, [TimestampFromParts, Localtimestamp], TIMESTAMP)
  annotate_all(m, [BitwiseAndAgg, BitwiseOrAgg, BitwiseXorAgg], (s, e) => {
    s.annotate_by_args(e, [Key("this")])
  })
  m[ToNumber] = Returns(D(DECIMAL))
  m
}
