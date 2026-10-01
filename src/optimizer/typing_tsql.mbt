// Port of sqlglot/typing/tsql.py.

///|
/// Python `sqlglot.typing.tsql.EXPRESSION_METADATA`.
fn tsql_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(m, [Acos, Asin, Atan, Atan2, Cos, Cot, Sin, Tan], FLOAT)
  returns_all(m, [Soundex, Stuff], VARCHAR)
  annotate_all(m, [Degrees, Radians], (s, e) => {
    s.annotate_by_args(e, [Key("this")])
  })
  m[CurrentTimezone] = Returns(D(NVARCHAR))
  m[CurrentTimestamp] = Returns(D(DATETIME))
  m
}
