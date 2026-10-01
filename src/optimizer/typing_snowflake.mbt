// Port of sqlglot/typing/snowflake.py.

///|
let snowflake_date_parts : Array[String] = [
  "DAY", "WEEK", "MONTH", "QUARTER", "YEAR",
]

///|
const SNOWFLAKE_MAX_PRECISION : Int = 38

///|
const SNOWFLAKE_MAX_SCALE : Int = 37

///|
fn snowflake_datatype(
  sql : String,
  s : TypeAnnotator,
) -> @core.Expr raise @core.SqlglotError {
  datatype_from_str_in(sql, "snowflake", s.dialect)
}

///|
fn snowflake_annotate_reverse(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  s.annotate_by_args(expression, [Key("this")])
  if expression.is_type([NULL]) {
    // Snowflake treats REVERSE(NULL) as a VARCHAR
    s.set_dtype(expression, VARCHAR)
  }
}

///|
/// TIMESTAMP_FROM_PARTS with time_zone -> TIMESTAMPTZ, otherwise TIMESTAMP (NTZ).
fn snowflake_annotate_timestamp_from_parts(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  s.set_dtype(
    expression,
    if expression.has("zone") {
      TIMESTAMPTZ
    } else {
      TIMESTAMP
    },
  )
}

///|
fn snowflake_annotate_date_or_time_add(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  if opt_is_type(expression.this(), [DATE]) &&
    !snowflake_date_parts.contains(@core.py_upper(expression.text("unit"))) {
    s.set_dtype(expression, TIMESTAMPNTZ)
  } else {
    s.annotate_by_args(expression, [Key("this")])
  }
}

///|
/// DECODE(expr, val1, ret1, val2, ret2, ..., default): the type is inferred from the
/// return values only.
fn snowflake_annotate_decode_case(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let expressions = expression.expressions()
  let return_types : Array[TType?] = []
  for i = 2; i < expressions.length(); i = i + 2 {
    return_types.push(type_of(expressions[i]))
  }
  // If the total number of expressions is even, the last one is the default
  if expressions.length() % 2 == 0 && !expressions.is_empty() {
    return_types.push(type_of(expressions[expressions.length() - 1]))
  }
  let mut last_type : TType? = None
  for ret_type in return_types {
    let t1 = match last_type {
      Some(_) => last_type
      None => ret_type
    }
    last_type = s.maybe_coerce_opt(t1, ret_type)
  }
  s.set_type(expression, last_type)
}

///|
fn snowflake_annotate_arg_max_min(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  if expression.has("count") {
    s.set_dtype(expression, ARRAY)
  } else {
    s.set_type_of(expression, expression.this())
  }
}

///|
/// For PERCENTILE_DISC / PERCENTILE_CONT, the type is the ordered expression's type.
fn snowflake_annotate_within_group(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let this = expression.this()
  let ordered_this = match (this, expression.expression()) {
    (Some(t), Some(order)) if t.kind.is_any([PercentileDisc, PercentileCont]) &&
      order.kind.is_a(Order) &&
      order.expressions().length() == 1 &&
      order.expressions()[0].kind.is_a(Ordered) =>
      Some(order.expressions()[0].this())
    _ => None
  }
  match ordered_this {
    Some(ot) => s.set_type_of(expression, ot)
    None => s.set_type_of(expression, this)
  }
}

///|
/// MEDIAN: FLOAT/DOUBLE -> DOUBLE, NUMBER(p, s) -> NUMBER(min(p+3, 38), min(s+3, 37)).
fn snowflake_annotate_median(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit raise @core.SqlglotError {
  s.annotate_by_args(expression, [Key("this")])
  let input_type = expression.this().bind(e => e.get_type())
  if opt_is_type(input_type, [DOUBLE]) {
    s.set_dtype(expression, DOUBLE)
  } else {
    let exprs = input_type.map(t => t.expressions()).unwrap_or([])
    let precision = datatype_param_int(exprs.get(0), SNOWFLAKE_MAX_PRECISION)
    let scale = datatype_param_int(exprs.get(1), 0)
    let new_precision = @core.min_int(precision + 3, SNOWFLAKE_MAX_PRECISION)
    let new_scale = @core.min_int(scale + 3, SNOWFLAKE_MAX_SCALE)
    s.set_type_expr(
      expression,
      Some(snowflake_datatype("NUMBER(\{new_precision}, \{new_scale})", s)),
    )
  }
}

///|
/// VAR_POP, VAR_SAMP, VARIANCE, VARIANCE_POP: DECFLOAT -> DECFLOAT(38),
/// FLOAT/DOUBLE -> DOUBLE, INT/NUMBER(p, 0) -> NUMBER(38, 6), NUMBER(p, s) -> NUMBER(38, max(12, s)).
fn snowflake_annotate_variance(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit raise @core.SqlglotError {
  s.annotate_by_args(expression, [Key("this")])
  let input_type = expression.this().bind(e => e.get_type())
  if opt_is_type(input_type, [DECFLOAT]) {
    s.set_type_expr(expression, Some(snowflake_datatype("DECFLOAT", s)))
  } else if opt_is_type(input_type, [FLOAT, DOUBLE]) {
    s.set_dtype(expression, DOUBLE)
  } else {
    let exprs = input_type.map(t => t.expressions()).unwrap_or([])
    let scale = datatype_param_int(exprs.get(1), 0)
    let new_scale = if scale == 0 { 6 } else if scale > 12 { scale } else { 12 }
    s.set_type_expr(
      expression,
      Some(
        snowflake_datatype(
          "NUMBER(\{SNOWFLAKE_MAX_PRECISION}, \{new_scale})",
          s,
        ),
      ),
    )
  }
}

///|
/// KURTOSIS: DECFLOAT -> DECFLOAT, DOUBLE/FLOAT -> DOUBLE, other numerics -> NUMBER(38, 12).
fn snowflake_annotate_kurtosis(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit raise @core.SqlglotError {
  s.annotate_by_args(expression, [Key("this")])
  let input_type = expression.this().bind(e => e.get_type())
  if opt_is_type(input_type, [DECFLOAT]) {
    s.set_type_expr(expression, Some(snowflake_datatype("DECFLOAT", s)))
  } else if opt_is_type(input_type, [FLOAT, DOUBLE]) {
    s.set_dtype(expression, DOUBLE)
  } else {
    s.set_type_expr(
      expression,
      Some(snowflake_datatype("NUMBER(\{SNOWFLAKE_MAX_PRECISION}, 12)", s)),
    )
  }
}

///|
/// Math functions that preserve DECFLOAT but return DOUBLE for other inputs.
fn snowflake_annotate_math_with_float_decfloat(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  s.annotate_by_args(expression, [Key("this")])
  if opt_is_type(expression.this(), [DECFLOAT]) {
    s.set_type_of(expression, expression.this())
  } else {
    s.set_dtype(expression, DOUBLE)
  }
}

///|
fn snowflake_annotate_str_to_time(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  // target_type is stored as a DataType instance
  match expression.arg("target_type") {
    Some(t) if t.kind.is_a(DataType) =>
      match t.datatype_this() {
        Some(d) => s.set_dtype(expression, d)
        None => s.set_type(expression, None)
      }
    _ => s.set_dtype(expression, TIMESTAMP)
  }
}

///|
/// Python `sqlglot.typing.snowflake.EXPRESSION_METADATA`.
fn snowflake_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  annotate_all(
    m,
    [
      AddMonths,
      Ceil,
      DateTrunc,
      Floor,
      Left,
      Mode,
      Pad,
      Right,
      Round,
      Stuff,
      Substring,
      TimeSlice,
      TimestampTrunc,
    ],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  returns_all(
    m,
    [
      ApproxTopK,
      ApproxTopKEstimate,
      Array,
      ArrayAgg,
      ArrayAppend,
      ArrayCompact,
      ArrayConcat,
      ArrayConstructCompact,
      ArrayPrepend,
      ArrayRemove,
      ArraysZip,
      ArrayUniqueAgg,
      ArrayUnionAgg,
      MapKeys,
      RegexpExtractAll,
      Split,
      StringToArray,
      StrtokToArray,
    ],
    ARRAY,
  )
  returns_all(
    m,
    [
      BitmapBitPosition,
      BitmapBucketNumber,
      BitmapCount,
      Factorial,
      GroupingId,
      MD5NumberLower64,
      MD5NumberUpper64,
      Rand,
      Seq8,
      Zipf,
    ],
    BIGINT,
  )
  returns_all(
    m,
    [
      Base64DecodeBinary,
      BitmapConstructAgg,
      BitmapOrAgg,
      Compress,
      DecompressBinary,
      Decrypt,
      DecryptRaw,
      Encrypt,
      EncryptRaw,
      HexString,
      MD5Digest,
      SHA1Digest,
      SHA2Digest,
      ToBinary,
      TryBase64DecodeBinary,
      TryHexDecodeBinary,
      Unhex,
    ],
    BINARY,
  )
  returns_all(
    m,
    [
      Booland,
      Boolnot,
      Boolor,
      BoolxorAgg,
      EqualNull,
      IsNullValue,
      MapContainsKey,
      Search,
      SearchIp,
      ToBoolean,
    ],
    BOOLEAN,
  )
  returns_all(m, [NextDay, PreviousDay], DATE)
  annotate_all(
    m,
    [
      BitwiseAndAgg,
      BitwiseOrAgg,
      BitwiseXorAgg,
      RegexpCount,
      RegexpInstr,
      ToNumber,
    ],
    (s, e) => s.set_type_expr(e, Some(snowflake_datatype("NUMBER", s))),
  )
  returns_all(
    m,
    [
      ApproxPercentileEstimate,
      ApproximateSimilarity,
      CosineDistance,
      DotProduct,
      EuclideanDistance,
      ManhattanDistance,
      MonthsBetween,
      Normal,
    ],
    DOUBLE,
  )
  m[Kurtosis] = Annotator((s, e) => snowflake_annotate_kurtosis(s, e))
  returns_all(m, [ToDecfloat, TryToDecfloat], DECFLOAT)
  annotate_all(
    m,
    [
      Acos,
      Asin,
      Atan,
      Atan2,
      Cbrt,
      Cos,
      Cot,
      Degrees,
      Exp,
      Ln,
      Log,
      Pow,
      Radians,
      RegrAvgx,
      RegrAvgy,
      RegrCount,
      RegrIntercept,
      RegrR2,
      RegrSlope,
      RegrSxx,
      RegrSxy,
      RegrSyy,
      RegrValx,
      RegrValy,
      Sin,
      Sqrt,
      Tan,
      Tanh,
    ],
    (s, e) => snowflake_annotate_math_with_float_decfloat(s, e),
  )
  returns_all(
    m,
    [
      ByteLength,
      DenseRank,
      Grouping,
      JarowinklerSimilarity,
      MapSize,
      Minute,
      Ntile,
      Rank,
      RowNumber,
      RtrimmedLength,
      Second,
      Seq1,
      Seq2,
      Seq4,
      WidthBucket,
    ],
    INT,
  )
  returns_all(
    m,
    [
      ApproxPercentileAccumulate,
      ApproxPercentileCombine,
      ApproxTopKAccumulate,
      ApproxTopKCombine,
      ObjectAgg,
      ParseIp,
      ParseUrl,
      XMLGet,
    ],
    OBJECT,
  )
  returns_all(m, [MapCat, MapDelete, MapInsert, MapPick], MAP)
  returns_all(m, [ToFile], FILE)
  returns_all(m, [TimeFromParts, TsOrDsToTime], TIME)
  returns_all(m, [CurrentTimestamp, Localtimestamp], TIMESTAMPLTZ)
  returns_all(m, [DayOfMonth, DayOfWeek, DayOfYear, Quarter], TINYINT)
  returns_all(
    m,
    [
      AIAgg,
      AIClassify,
      AISummarizeAgg,
      Base64DecodeString,
      Base64Encode,
      CheckJson,
      CheckXml,
      Collate,
      Collation,
      CurrentAccount,
      CurrentAccountName,
      CurrentAvailableRoles,
      CurrentClient,
      CurrentDatabase,
      CurrentIpAddress,
      CurrentSchemas,
      CurrentSecondaryRoles,
      CurrentSession,
      CurrentStatement,
      CurrentTransaction,
      CurrentWarehouse,
      CurrentOrganizationUser,
      CurrentRegion,
      CurrentRoleType,
      CurrentOrganizationName,
      DecompressString,
      HexDecodeString,
      Hex,
      Randstr,
      RegexpExtract,
      RegexpReplace,
      Replace,
      Soundex,
      SoundexP123,
      SplitPart,
      Strtok,
      TryBase64DecodeString,
      TryHexDecodeString,
      Uuid,
    ],
    VARCHAR,
  )
  returns_all(m, [Minhash, MinhashCombine], VARIANT)
  annotate_all(m, [Variance, VariancePop], (s, e) => {
    snowflake_annotate_variance(s, e)
  })
  m[ArgMax] = Annotator((s, e) => snowflake_annotate_arg_max_min(s, e))
  m[ArgMin] = Annotator((s, e) => snowflake_annotate_arg_max_min(s, e))
  m[ConcatWs] = Annotator((s, e) => s.annotate_by_args(e, [Key("expressions")]))
  m[ConvertTimezone] = Annotator((s, e) => {
    s.set_dtype(e, if e.has("source_tz") { TIMESTAMPNTZ } else { TIMESTAMPTZ })
  })
  m[DateAdd] = Annotator((s, e) => snowflake_annotate_date_or_time_add(s, e))
  m[DecodeCase] = Annotator((s, e) => snowflake_annotate_decode_case(s, e))
  m[HashAgg] = Annotator((s, e) => {
    s.set_type_expr(e, Some(snowflake_datatype("NUMBER(19, 0)", s)))
  })
  m[Median] = Annotator((s, e) => snowflake_annotate_median(s, e))
  m[Reverse] = Annotator((s, e) => snowflake_annotate_reverse(s, e))
  m[StrToTime] = Annotator((s, e) => snowflake_annotate_str_to_time(s, e))
  m[TimeAdd] = Annotator((s, e) => snowflake_annotate_date_or_time_add(s, e))
  m[TimestampFromParts] = Annotator((s, e) => {
    snowflake_annotate_timestamp_from_parts(s, e)
  })
  m[WithinGroup] = Annotator((s, e) => snowflake_annotate_within_group(s, e))
  m
}
