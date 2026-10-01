// Port of sqlglot/typing/spark2.py.

///|
/// Type inference for CONCAT-family expressions (CONCAT, LPAD, RPAD).
///
/// - All-BINARY -> BINARY (the binary overload).
/// - Otherwise, if any arg has a known, non-array, non-binary type -> STRING.
/// - Else -> UNKNOWN.
fn spark2_annotate_by_similar_args(
  s : TypeAnnotator,
  expression : @core.Expr,
  arg_keys : Array[String],
) -> Unit {
  let arg_exprs : Array[@core.Expr] = []
  for key in arg_keys {
    match expression.get(key) {
      Some(Node(e)) => arg_exprs.push(e)
      Some(List(_)) =>
        for e in expression.list(key) {
          arg_exprs.push(e)
        }
      _ => ()
    }
  }
  let result : @core.DType = if !arg_exprs.is_empty() &&
    arg_exprs.iter().all(e => e.is_type([BINARY])) {
    BINARY
  } else if arg_exprs
    .iter()
    .any(e => e.get_type() is Some(_) && !e.is_type([UNKNOWN, ARRAY, BINARY])) {
    TEXT
  } else {
    UNKNOWN
  }
  s.set_dtype(expression, result)
}

///|
/// Python `sqlglot.typing.spark2.EXPRESSION_METADATA`.
fn spark2_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(hive_expression_metadata())
  returns_all(m, [Atan2, Randn], DOUBLE)
  returns_all(m, [Format, Right], VARCHAR)
  annotate_all(m, [ArrayFilter, Shuffle, Substring], (s, e) => {
    s.annotate_by_args(e, [Key("this")])
  })
  returns_all(m, [Nanvl], DOUBLE)
  m[AddMonths] = Returns(D(DATE))
  m[ApproxQuantile] = Annotator((s, e) => {
    s.annotate_by_args(
      e,
      [Key("this")],
      array=opt_is_type(e.arg("quantile"), [ARRAY]),
    )
  })
  m[AtTimeZone] = Returns(D(TIMESTAMP))
  m[Concat] = Annotator((s, e) => {
    spark2_annotate_by_similar_args(s, e, ["expressions"])
  })
  m[NextDay] = Returns(D(DATE))
  m[Pad] = Annotator((s, e) => {
    spark2_annotate_by_similar_args(s, e, ["this", "fill_pattern"])
  })
  m
}
