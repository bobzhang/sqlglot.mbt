// Port of sqlglot/typing/__init__.py: the base dialect's expression metadata, and the
// registry of per-dialect metadata (Python `Dialect.EXPRESSION_METADATA` / `COERCES_TO`).

///|
fn returns_all(
  m : ExprMetadata,
  kinds : Array[@core.Kind],
  dtype : @core.DType,
) -> Unit {
  for k in kinds {
    m[k] = Returns(D(dtype))
  }
}

///|
fn annotate_all(
  m : ExprMetadata,
  kinds : Array[@core.Kind],
  f : (TypeAnnotator, @core.Expr) -> Unit raise @core.SqlglotError,
) -> Unit {
  for k in kinds {
    m[k] = Annotator(f)
  }
}

///|
/// Python `subclasses(exp.__name__, classes)`: every expression class that is a subclass
/// of one of `bases` (including the bases themselves).
fn subclasses(bases : Array[@core.Kind]) -> Array[@core.Kind] {
  let out = []
  for b in bases {
    for k in @core.subclasses_of(b) {
      if !out.contains(k) {
        out.push(k)
      }
    }
    if !b.is_trait() && !out.contains(b) {
      out.push(b)
    }
  }
  out
}

///|
let timestamp_expressions : Array[@core.Kind] = [
  CurrentTimestamp, StrToTime, TimeStrToTime, TimestampAdd, TimestampSub, UnixToTime,
]

///|
fn build_base_expression_metadata() -> ExprMetadata {
  let m : ExprMetadata = Map([])
  annotate_all(m, subclasses([Binary]), (s, e) => s.annotate_binary(e))
  annotate_all(m, subclasses([Unary, Alias, IgnoreNulls, RespectNulls]), (s, e) => s.annotate_unary(
    e,
  ))
  returns_all(
    m,
    [
      ApproxDistinct, ArraySize, CountIf, DenseRank, Int64, Ntile, Rank, RowNumber,
      UnixSeconds, UnixMicros, UnixMillis,
    ],
    BIGINT,
  )
  returns_all(m, [FromBase32, FromBase64], BINARY)
  returns_all(
    m,
    [
      All, Any, Between, Boolean, Contains, EndsWith, Exists, In, IsInf, IsNan, LogicalAnd,
      LogicalOr, StartsWith,
    ],
    BOOLEAN,
  )
  returns_all(
    m,
    [
      CurrentDate, Date, DateFromParts, DateStrToDate, DiToDate, LastDay, StrToDate,
      TimeStrToDate, TsOrDsToDate,
    ],
    DATE,
  )
  returns_all(m, [CurrentDatetime, Datetime, DatetimeAdd, DatetimeSub], DATETIME)
  returns_all(
    m,
    [
      Asin, Asinh, Acos, CovarPop, CovarSamp, Acosh, ApproxQuantile, Atan, Atanh, Avg,
      Cbrt, Cos, Cosh, Cot, Degrees, Exp, Kurtosis, Ln, Log, Pi, Pow, PercentileCont, Quantile,
      Radians, Round, SafeDivide, Sin, Sinh, Sqrt, Stddev, StddevPop, StddevSamp, Rand,
      Tan, Tanh, ToDouble, CumeDist, PercentRank, Variance, VariancePop, Skewness,
    ],
    DOUBLE,
  )
  returns_all(
    m,
    [
      Ascii, BitLength, Ceil, DatetimeDiff, DayOfMonth, DayOfWeek, DayOfYear, Floor, Getbit,
      Hour, TimestampDiff, TimeDiff, Unicode, DateToDi, Levenshtein, Length, Sign, StrPosition,
      TsOrDiToDi, Quarter, UnixDate,
    ],
    INT,
  )
  returns_all(
    m,
    [Interval, JustifyDays, JustifyHours, JustifyInterval, MakeInterval],
    INTERVAL,
  )
  returns_all(m, [ParseJSON], JSON)
  returns_all(m, [CurrentTime, Localtime, Time, TimeAdd, TimeSub], TIME)
  returns_all(m, [TimestampLtzFromParts], TIMESTAMPLTZ)
  returns_all(m, [CurrentTimestampLTZ, TimestampTzFromParts], TIMESTAMPTZ)
  returns_all(m, timestamp_expressions, TIMESTAMP)
  returns_all(
    m,
    [Day, DayOfWeekIso, Month, Week, WeekOfYear, Year, YearOfWeek, YearOfWeekIso],
    TINYINT,
  )
  returns_all(
    m,
    [
      ArrayToString, Concat, ConcatWs, Chr, CurrentCatalog, CurrentRole, CurrentSchema,
      CurrentVersion, CurrentUser, Dayname, DateToDateStr, DPipe, GroupConcat, Initcap,
      Lower, MD5, Monthname, RawString, Repeat, SHA, SHA2, SessionUser, Space, String, Substring,
      TimeToStr, TimeToTimeStr, Trim, ToBase32, ToBase64, Translate, TsOrDsToDateStr, Typeof,
      UnixToStr, UnixToTimeStr, Upper,
    ],
    VARCHAR,
  )
  annotate_all(
    m,
    [
      Abs, AnyValue, ArrayConcatAgg, ArrayReverse, ArraySlice, Filter, FirstValue, HavingMax,
      LastValue, Limit, NthValue, Order, SortArray, Window,
    ],
    (s, e) => s.annotate_by_args(e, [Key("this")]),
  )
  annotate_all(
    m,
    [ArrayConcat, Coalesce, Greatest, Least, Max, Min],
    (s, e) => s.annotate_by_args(e, [Key("this"), Key("expressions")]),
  )
  annotate_all(m, [ArrayFirst, ArrayLast], (s, e) => s.annotate_by_array_element(
    e,
  ))
  m[Anonymous] = Annotator((s, e) => s.set_type(
    e,
    Some(T(s.schema.get_udf_type(e))),
  ))
  annotate_all(m, [DateAdd, DateSub, DateTrunc], (s, e) => s.annotate_timeunit(e))
  annotate_all(m, [Cast, TryCast], (s, e) => s.set_type_expr(e, e.arg("to")))
  annotate_all(m, [Map, VarMap], (s, e) => s.annotate_map(e))
  m[Array] = Annotator((s, e) => s.annotate_by_args(
    e,
    [Key("expressions")],
    array=true,
  ))
  m[ArrayAgg] = Annotator((s, e) => s.annotate_by_args(e, [Key("this")], array=true))
  m[Bracket] = Annotator((s, e) => s.annotate_bracket(e))
  m[Case] = Annotator((s, e) => {
    let args = e.list("ifs").map(if_expr => ArgRef::Node(if_expr.arg("true").unwrap()))
    args.push(Key("default"))
    s.annotate_by_args(e, args)
  })
  m[Count] = Annotator((s, e) => s.set_dtype(
    e,
    if e.has("big_int") {
      BIGINT
    } else {
      INT
    },
  ))
  m[DateDiff] = Annotator((s, e) => s.set_dtype(
    e,
    if e.has("big_int") {
      BIGINT
    } else {
      INT
    },
  ))
  m[DataType] = Annotator((_, _) => ())
  m[Div] = Annotator((s, e) => s.annotate_div(e))
  m[Distinct] = Annotator((s, e) => s.annotate_by_args(e, [Key("expressions")]))
  m[Dot] = Annotator((s, e) => s.annotate_dot(e))
  m[Explode] = Annotator((s, e) => s.annotate_explode(e))
  m[Extract] = Annotator((s, e) => s.annotate_extract(e))
  m[HexString] = Annotator((s, e) => s.set_dtype(
    e,
    if e.has("is_integer") {
      BIGINT
    } else {
      BINARY
    },
  ))
  m[GenerateSeries] = Annotator((s, e) => s.annotate_by_args(
    e,
    [Key("start"), Key("end"), Key("step")],
    array=true,
  ))
  m[GenerateDateArray] = Annotator((s, e) => s.set_type_expr(
    e,
    Some(@core.datatype_from_str("ARRAY<DATE>")),
  ))
  m[GenerateTimestampArray] = Annotator((s, e) => s.set_type_expr(
    e,
    Some(@core.datatype_from_str("ARRAY<TIMESTAMP>")),
  ))
  m[If] = Annotator((s, e) => s.annotate_by_args(e, [Key("true"), Key("false")]))
  m[Lag] = Annotator((s, e) => s.annotate_by_args(e, [Key("this"), Key("default")]))
  m[Lead] = Annotator((s, e) => s.annotate_by_args(e, [Key("this"), Key("default")]))
  m[Literal] = Annotator((s, e) => s.annotate_literal(e))
  m[Null] = Returns(D(NULL))
  m[Nullif] = Annotator((s, e) => s.annotate_by_args(e, [
    Key("this"),
    Key("expression"),
  ]))
  m[PropertyEQ] = Annotator((s, e) => s.annotate_by_args(e, [Key("expression")]))
  m[Struct] = Annotator((s, e) => s.annotate_struct(e))
  m[Sum] = Annotator((s, e) => s.annotate_by_args(
    e,
    [Key("this"), Key("expressions")],
    promote=true,
  ))
  m[Timestamp] = Annotator((s, e) => s.set_dtype(
    e,
    if e.has("with_tz") {
      TIMESTAMPTZ
    } else {
      TIMESTAMP
    },
  ))
  m[ToMap] = Annotator((s, e) => s.annotate_to_map(e))
  m[Unnest] = Annotator((s, e) => s.annotate_unnest(e))
  m[WithinGroup] = Annotator((s, e) => s.annotate_within_group(e))
  m[Subquery] = Annotator((s, e) => s.annotate_subquery(e))
  m
}

///|
/// The base dialect's expression metadata (Python `sqlglot.typing.EXPRESSION_METADATA`).
pub let base_expression_metadata : ExprMetadata = build_base_expression_metadata()

///|
/// Builders of per-dialect expression metadata, keyed by dialect name.
let expression_metadata_builders : Map[String, () -> ExprMetadata] = Map([])

///|
let expression_metadata_cache : Map[String, ExprMetadata] = Map([])

///|
/// Per-dialect `COERCES_TO`, keyed by dialect name.
let coerces_to_builders : Map[
  String,
  () -> Map[@core.DType, @set.Set[@core.DType]],
] = Map([])

///|
let coerces_to_cache : Map[String, Map[@core.DType, @set.Set[@core.DType]]] = Map([])

///|
/// Registers the expression metadata of a dialect (by name). Dialects that don't register
/// metadata inherit the metadata of their parent dialect.
pub fn register_expression_metadata(
  dialect_name : String,
  build : () -> ExprMetadata,
) -> Unit {
  expression_metadata_builders[dialect_name] = build
  expression_metadata_cache.remove(dialect_name)
}

///|
/// Registers the `COERCES_TO` mapping of a dialect (by name).
pub fn register_coerces_to(
  dialect_name : String,
  build : () -> Map[@core.DType, @set.Set[@core.DType]],
) -> Unit {
  coerces_to_builders[dialect_name] = build
  coerces_to_cache.remove(dialect_name)
}

///|
/// The expression metadata of `dialect` (Python `dialect.EXPRESSION_METADATA`).
pub fn dialect_expression_metadata(dialect : @core.Dialect) -> ExprMetadata {
  ensure_typing_registered()
  let mut d : @core.Dialect? = Some(dialect)
  while d is Some(x) {
    match expression_metadata_cache.get(x.name) {
      Some(m) => return m
      None => ()
    }
    match expression_metadata_builders.get(x.name) {
      Some(b) => {
        let m = b()
        expression_metadata_cache[x.name] = m
        return m
      }
      None => ()
    }
    d = x.parent
  }
  base_expression_metadata
}

///|
/// The `COERCES_TO` of `dialect` (empty when the dialect uses the default one).
pub fn dialect_coerces_to(
  dialect : @core.Dialect,
) -> Map[@core.DType, @set.Set[@core.DType]] {
  ensure_typing_registered()
  let mut d : @core.Dialect? = Some(dialect)
  while d is Some(x) {
    match coerces_to_cache.get(x.name) {
      Some(m) => return m
      None => ()
    }
    match coerces_to_builders.get(x.name) {
      Some(b) => {
        let m = b()
        coerces_to_cache[x.name] = m
        return m
      }
      None => ()
    }
    d = x.parent
  }
  {}
}

///|
let typing_registered : Ref[Bool] = Ref(false)

///|
/// Registers the built-in per-dialect typing rules (see typing_*.mbt).
fn ensure_typing_registered() -> Unit {
  if typing_registered.val {
    return
  }
  typing_registered.val = true
  register_dialect_typings()
}

///|
/// Copies the metadata of a parent and applies updates (Python `{**parent, ...}`).
pub fn extend_metadata(parent : ExprMetadata) -> ExprMetadata {
  parent.copy()
}
