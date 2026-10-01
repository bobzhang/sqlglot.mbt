// Port of sqlglot/typing/databricks.py and the `COERCES_TO` of
// sqlglot/dialects/databricks.py.

///|
/// Python `sqlglot.typing.databricks.EXPRESSION_METADATA`.
fn databricks_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(spark_expression_metadata())
  returns_all(
    m,
    [
      RegrAvgx,
      RegrAvgy,
      RegrIntercept,
      RegrR2,
      RegrSlope,
      RegrSxx,
      RegrSxy,
      RegrSyy,
      Rint,
    ],
    DOUBLE,
  )
  returns_all(m, [RegexpCount, RegexpInstr], INT)
  returns_all(m, [RegexpSubstr, Secret], VARCHAR)
  m[RegrCount] = Returns(D(BIGINT))
  m[Search] = Returns(D(BOOLEAN))
  m[RegexpExtractAll] = set_type_from_str("ARRAY<STRING>", "databricks")
  m
}

///|
/// Python `Databricks.COERCES_TO`: text types can be coerced to numeric, temporal,
/// binary, boolean and interval types.
fn databricks_coerces_to() -> Map[@core.DType, @set.Set[@core.DType]] {
  let m = copy_coerces_to(default_coerces_to)
  for text_type in @core.dtype_text_types {
    let s = match m.get(text_type) {
      Some(s) => s
      None => {
        let s = @set.Set([])
        m[text_type] = s
        s
      }
    }
    for t in @core.dtype_numeric_types {
      s.add(t)
    }
    for t in @core.dtype_temporal_types {
      s.add(t)
    }
    s.add(BINARY)
    s.add(BOOLEAN)
    s.add(INTERVAL)
  }
  m
}
