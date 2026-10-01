// Port of sqlglot/typing/presto.py.

///|
/// Python `sqlglot.typing.presto.EXPRESSION_METADATA`.
fn presto_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(
    m,
    [
      BitwiseAnd,
      BitwiseNot,
      BitwiseOr,
      BitwiseXor,
      Length,
      Levenshtein,
      StrPosition,
      WidthBucket,
    ],
    BIGINT,
  )
  annotate_all(m, [Ceil, Floor, Round, Sign], (s, e) => {
    s.annotate_by_args(e, [Key("this")])
  })
  m[Mod] = Annotator((s, e) => {
    s.annotate_by_args(e, [Key("this"), Key("expression")])
  })
  m[Rand] = Annotator((s, e) => {
    if e.this() is Some(_) {
      s.annotate_by_args(e, [Key("this")])
    } else {
      s.set_dtype(e, DOUBLE)
    }
  })
  m[MD5Digest] = Returns(D(VARBINARY))
  m
}
