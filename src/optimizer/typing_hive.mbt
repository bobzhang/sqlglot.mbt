// Port of sqlglot/typing/hive.py and the `COERCES_TO` of sqlglot/dialects/hive.py.

///|
/// Python `sqlglot.typing.hive.EXPRESSION_METADATA`.
fn hive_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(m, [Encode, Unhex], BINARY)
  returns_all(m, [Corr, MonthsBetween, Sign], DOUBLE)
  returns_all(
    m,
    [
      AddMonths,
      CurrentDatabase,
      Hex,
      JSONExtractScalar,
      JSONFormat,
      NextDay,
      RegexpExtract,
      RegexpReplace,
      Replace,
      Soundex,
    ],
    VARCHAR,
  )
  returns_all(m, [Factorial, IntDiv, StrToUnix], BIGINT)
  returns_all(
    m,
    [ArraySize, DenseRank, Month, Ntile, Rank, RowNumber, Second, Minute],
    INT,
  )
  annotate_all(
    m,
    [ArrayDistinct, ArrayExcept, First, Last, Negative, Reverse],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  m[ArrayIntersect] = Annotator((s, e) => {
    s.annotate_by_args(e, [Key("expressions")])
  })
  m[ApproxQuantile] = Annotator((s, e) => {
    s.annotate_by_args(e, [Key("quantile")])
  })
  m[Coalesce] = Annotator((s, e) => {
    s.annotate_by_args(e, [Key("this"), Key("expressions")], promote=true)
  })
  m[Grouping] = Returns(D(BIGINT))
  m[If] = Annotator((s, e) => {
    s.annotate_by_args(e, [Key("true"), Key("false")], promote=true)
  })
  m[PercentileDisc] = Returns(D(DOUBLE))
  m[Quantile] = Annotator((s, e) => s.annotate_by_args(e, [Key("quantile")]))
  m[RegexpSplit] = returns_from_str("ARRAY<STRING>")
  m[StrToMap] = returns_from_str("MAP<STRING, STRING>")
  m[WithinGroup] = Annotator((s, e) => s.annotate_by_args(e, [Key("this")]))
  m
}

///|
/// Python `Hive.COERCES_TO` (non-ANSI mode: numeric/temporal/interval types accept text).
fn hive_coerces_to() -> Map[@core.DType, @set.Set[@core.DType]] {
  let m = copy_coerces_to(default_coerces_to)
  let targets : Array[@core.DType] = []
  for t in @core.dtype_numeric_types {
    targets.push(t)
  }
  for t in @core.dtype_temporal_types {
    targets.push(t)
  }
  targets.push(INTERVAL)
  for target in targets {
    let s = match m.get(target) {
      Some(s) => s
      None => {
        let s = @set.Set([])
        m[target] = s
        s
      }
    }
    for text in @core.dtype_text_types {
      s.add(text)
    }
  }
  m
}
