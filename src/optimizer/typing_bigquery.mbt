// Port of sqlglot/typing/bigquery.py and the `COERCES_TO` of
// sqlglot/dialects/bigquery.py.

///|
/// DATE_ADD / DATE_SUB / *_TRUNC return the type of their first argument. BigQuery
/// implicitly casts a string literal first arg to the function's own temporal type
/// (Python `_DATE_FUNC_LITERAL_TYPE`).
fn bigquery_date_func_literal_type(kind : @core.Kind) -> @core.DType {
  match kind {
    DatetimeTrunc => DATETIME
    TimestampTrunc => TIMESTAMPTZ
    _ => DATE // DateAdd, DateSub, DateTrunc
  }
}

///|
/// Annotates DATE_ADD / DATE_SUB / *_TRUNC, which return their first arg's type.
fn bigquery_annotate_date_func(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  match expression.this() {
    // BigQuery rejects expressions like DATE_ADD(c, ...); it requires the first argument to be a literal
    Some(this) if this.kind == Literal && this.is_string() =>
      s.set_dtype(expression, bigquery_date_func_literal_type(expression.kind))
    _ => s.annotate_by_args(expression, [Key("this")])
  }
}

///|
/// Many BigQuery math functions such as CEIL, FLOOR etc follow this return type convention:
/// INT64 -> FLOAT64, NUMERIC -> NUMERIC, BIGNUMERIC -> BIGNUMERIC, FLOAT64 -> FLOAT64.
fn bigquery_annotate_math_functions(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this()
  if opt_is_type(this, @core.dtype_integer_types) {
    s.set_dtype(expression, DOUBLE)
  } else {
    s.set_type_of(expression, this)
  }
}

///|
fn bigquery_annotate_safe_divide(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  if opt_is_type(expression.this(), @core.dtype_integer_types) &&
    opt_is_type(expression.expression(), @core.dtype_integer_types) {
    s.set_dtype(expression, DOUBLE)
  } else {
    bigquery_annotate_by_args_with_coerce(s, expression)
  }
}

///|
fn bigquery_annotate_by_args_with_coerce(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let t1 = expression.this().bind(e => type_of(e))
  let t2 = expression.expression().bind(e => type_of(e))
  s.set_type(expression, s.maybe_coerce_opt(t1, t2))
}

///|
fn bigquery_annotate_by_args_approx_top(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this_type = expression.this().bind(e => e.get_type())
  let struct_type = @core.mk(DataType, [
    ("this", @core.DType::STRUCT),
    ("expressions", [this_type, Some(@core.datatype_of(BIGINT))]),
    ("nested", true),
  ])
  s.set_type_expr(
    expression,
    Some(
      @core.mk(DataType, [
        ("this", @core.DType::ARRAY),
        ("expressions", [struct_type]),
        ("nested", true),
      ]),
    ),
  )
}

///|
fn bigquery_annotate_concat(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  s.annotate_by_args(expression, [Key("expressions")])
  // Args must be BYTES or types that can be cast to STRING, return type is either BYTES or STRING
  if !expression.is_type([BINARY, UNKNOWN]) {
    s.set_dtype(expression, VARCHAR)
  }
}

///|
fn bigquery_annotate_array(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  let array_args = expression.expressions()
  // SELECT t, TYPEOF(t) FROM (SELECT 'foo') AS t            -- foo, STRUCT<STRING>
  // SELECT ARRAY(SELECT 'foo'), TYPEOF(ARRAY(SELECT 'foo')) -- foo, ARRAY<STRING>
  // ARRAY(SELECT ... UNION ALL SELECT ...)                  -- ARRAY<type from coerced projections>
  // ARRAY(SELECT AS STRUCT 1 AS a, 'b' AS b)                -- ARRAY<STRUCT<INT64, STRING>>
  if array_args.length() == 1 {
    let unnested = array_args[0].unnest()
    let mut projection_type : TType? = None
    if unnested.kind.is_a(Select) {
      match unnested.meta_get("query_type") {
        Some(Node(query_type)) if query_type.is_type([STRUCT]) => {
          let query_exprs = query_type.expressions()
          let col_defs = query_exprs.filter(e => {
            e.kind.is_a(ColumnDef) && !opt_is_type(e.arg("kind"), [UNKNOWN])
          })
          if col_defs.length() == query_exprs.length() {
            if unnested.get("kind") is Some(Str("STRUCT")) {
              // ARRAY(SELECT AS STRUCT ...) -> ARRAY<STRUCT<col1, col2, ...>>
              projection_type = Some(T(query_type))
            } else if col_defs.length() == 1 &&
              col_defs[0].arg("kind") is Some(col_type) {
              // ARRAY(SELECT col FROM ...) -> ARRAY<col_type>
              projection_type = Some(T(col_type))
            }
          }
        }
        _ => ()
      }
    } else if unnested.kind.is_a(SetOperation) {
      let col_types = s.get_setop_column_types(unnested)
      let left_selects = match unnested.this() {
        Some(l) => l.selects()
        None => []
      }
      if !col_types.is_empty() && !left_selects.is_empty() {
        let first_col_name = left_selects[0].alias_or_name()
        for kv in col_types {
          if kv.0 == first_col_name {
            projection_type = Some(kv.1)
            break
          }
        }
      }
    }
    match projection_type {
      Some(pt) if pt.this() != Some(UNKNOWN) => {
        let element_type = match pt {
          T(t) => t.copy()
          D(d) => @core.datatype_of(d)
        }
        s.set_type_expr(
          expression,
          Some(
            @core.mk(DataType, [
              ("this", @core.DType::ARRAY),
              ("expressions", [element_type]),
              ("nested", true),
            ]),
          ),
        )
        return
      }
      _ => ()
    }
  }
  s.annotate_by_args(expression, [Key("expressions")], array=true)
}

///|
/// Python `sqlglot.typing.bigquery.EXPRESSION_METADATA`.
fn bigquery_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  annotate_all(m, [Avg, Ceil, Exp, Floor, Ln, Log, Round, Sqrt], (s, e) => {
    bigquery_annotate_math_functions(s, e)
  })
  annotate_all(
    m,
    [
      ArgMax,
      ArgMin,
      GroupConcat,
      IgnoreNulls,
      JSONExtract,
      Left,
      Lower,
      NetFunc,
      Pad,
      PercentileDisc,
      RegexpExtract,
      RegexpReplace,
      Repeat,
      Replace,
      RespectNulls,
      Reverse,
      Right,
      SafeFunc,
      SafeNegate,
      Sign,
      Substring,
      Translate,
      Trim,
      Upper,
    ],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  annotate_all(
    m,
    [DateAdd, DateSub, DateTrunc, DatetimeTrunc, TimestampTrunc],
    (s, e) => bigquery_annotate_date_func(s, e),
  )
  returns_all(
    m,
    [
      BitwiseAndAgg,
      BitwiseCount,
      BitwiseOrAgg,
      BitwiseXorAgg,
      ByteLength,
      FarmFingerprint,
      Grouping,
      LaxInt64,
      Length,
      RangeBucket,
      RegexpInstr,
      UnixDate,
    ],
    BIGINT,
  )
  returns_all(
    m,
    [
      ByteString,
      CodePointsToBytes,
      MD5Digest,
      SHA,
      SHA2,
      SHA1Digest,
      SHA2Digest,
      Unhex,
    ],
    BINARY,
  )
  returns_all(m, [JSONBool, LaxBool], BOOLEAN)
  returns_all(m, [ParseDatetime, TimestampFromParts], DATETIME)
  returns_all(
    m,
    [
      Atan2,
      Corr,
      CosineDistance,
      Coth,
      Csc,
      Csch,
      EuclideanDistance,
      Float64,
      LaxFloat64,
      Sec,
      Sech,
    ],
    DOUBLE,
  )
  returns_all(
    m,
    [
      JSONArray,
      JSONArrayAppend,
      JSONArrayInsert,
      JSONObject,
      JSONRemove,
      JSONSet,
      JSONStripNulls,
    ],
    JSON,
  )
  returns_all(m, [ParseTime, TimeFromParts, TimeTrunc, TsOrDsToTime], TIME)
  returns_all(
    m,
    [
      CodePointsToString,
      Format,
      Host,
      JSONExtractScalar,
      JSONType,
      LaxString,
      LowerHex,
      Normalize,
      RegDomain,
      SafeConvertBytesToString,
      Soundex,
      Uuid,
    ],
    VARCHAR,
  )
  annotate_all(
    m,
    [PercentileCont, SafeAdd, SafeDivide, SafeMultiply, SafeSubtract],
    (s, e) => bigquery_annotate_by_args_with_coerce(s, e),
  )
  annotate_all(
    m,
    [ApproxQuantiles, JSONExtractArray, RegexpExtractAll, Split],
    (s, e) => s.annotate_by_args(e, [Key("this")], array=true),
  )
  returns_all(m, timestamp_expressions, TIMESTAMPTZ)
  m[ApproxTopK] = Annotator((s, e) => bigquery_annotate_by_args_approx_top(s, e))
  m[ApproxTopSum] = Annotator((s, e) => {
    bigquery_annotate_by_args_approx_top(s, e)
  })
  m[Array] = Annotator((s, e) => bigquery_annotate_array(s, e))
  m[Concat] = Annotator((s, e) => bigquery_annotate_concat(s, e))
  m[DateFromUnixDate] = Returns(D(DATE))
  m[GenerateTimestampArray] = set_type_from_str("ARRAY<TIMESTAMP>", "bigquery")
  m[JSONFormat] = Annotator((s, e) => {
    s.set_dtype(e, if e.has("to_json") { JSON } else { VARCHAR })
  })
  m[JSONKeysAtDepth] = set_type_from_str("ARRAY<VARCHAR>", "bigquery")
  m[JSONValueArray] = set_type_from_str("ARRAY<VARCHAR>", "bigquery")
  m[ParseBignumeric] = Returns(D(BIGDECIMAL))
  m[ParseNumeric] = Returns(D(DECIMAL))
  m[SafeDivide] = Annotator((s, e) => bigquery_annotate_safe_divide(s, e))
  m[ToCodePoints] = set_type_from_str("ARRAY<BIGINT>", "bigquery")
  m
}

///|
/// Python `BigQuery.COERCES_TO`.
///
/// Note: Python's `COERCES_TO[...] |= {...}` mutates the sets it shares with
/// `TypeAnnotator.COERCES_TO`; here the default mapping is left untouched.
fn bigquery_coerces_to() -> Map[@core.DType, @set.Set[@core.DType]] {
  let m = copy_coerces_to(default_coerces_to)
  m[BIGDECIMAL] = @set.from_array([DOUBLE])
  fn add_all(key : @core.DType, types : Array[@core.DType]) {
    let set = match m.get(key) {
      Some(x) => x
      None => {
        let x = @set.new()
        m[key] = x
        x
      }
    }
    for t in types {
      set.add(t)
    }
  }

  add_all(DECIMAL, [BIGDECIMAL])
  add_all(BIGINT, [BIGDECIMAL])
  add_all(VARCHAR, [DATE, DATETIME, TIME, TIMESTAMP, TIMESTAMPTZ])
  m
}
