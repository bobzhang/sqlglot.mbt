// Port of sqlglot/typing/mysql.py.

///|
let mysql_compress_longblob_types : Array[@core.DType] = [
  TEXT,
  MEDIUMTEXT,
  LONGTEXT,
  BLOB,
  MEDIUMBLOB,
  LONGBLOB,
  JSON,
]

///|
let mysql_compress_varbinary_types : Array[@core.DType] = [
  CHAR,
  VARCHAR,
  BINARY,
  VARBINARY,
  TINYBLOB,
  ENUM,
  INT,
  BIGINT,
  DECIMAL,
  DOUBLE,
  DATE,
  DATETIME,
]

///|
fn mysql_annotate_reverse(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  if opt_is_type(expression.this(), [BINARY, VARBINARY, UNKNOWN]) {
    s.annotate_by_args(expression, [Key("this")])
  } else {
    s.set_dtype(expression, VARCHAR)
  }
}

///|
fn mysql_annotate_truncate(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  if opt_is_type(expression.this(), @core.dtype_text_types) {
    s.set_dtype(expression, DOUBLE)
  } else {
    s.annotate_by_args(expression, [Key("this")])
  }
}

///|
fn mysql_annotate_regexp_replace(
  s : TypeAnnotator,
  expression : @core.Expr,
) -> Unit {
  let args = [
    expression.this(),
    expression.expression(),
    expression.arg("replacement"),
  ]
  let mut has_binary = false
  for arg in args {
    match arg {
      Some(a) => {
        if a.is_type([UNKNOWN]) {
          s.set_dtype(expression, UNKNOWN)
          return
        }
        has_binary = has_binary || a.is_type(@core.dtype_binary_types)
      }
      None => ()
    }
  }
  s.set_dtype(expression, if has_binary { LONGBLOB } else { LONGTEXT })
}

///|
fn mysql_annotate_compress(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  let this = expression.this()
  if opt_is_type(this, mysql_compress_varbinary_types) {
    s.set_dtype(expression, VARBINARY)
  } else if opt_is_type(this, mysql_compress_longblob_types) {
    s.set_dtype(expression, LONGBLOB)
  } else if opt_is_type(this, [TINYTEXT]) {
    s.set_dtype(expression, BLOB)
  } else {
    s.set_dtype(expression, UNKNOWN)
  }
}

///|
fn mysql_annotate_bit_func(s : TypeAnnotator, expression : @core.Expr) -> Unit {
  let this = expression.this()
  if opt_is_type(this, [UNKNOWN]) {
    s.set_dtype(expression, UNKNOWN)
  } else if opt_is_type(this, @core.dtype_binary_types) {
    s.set_dtype(expression, VARBINARY)
  } else {
    s.set_dtype(expression, UBIGINT)
  }
}

///|
/// Python `sqlglot.typing.mysql.EXPRESSION_METADATA`.
fn mysql_expression_metadata() -> ExprMetadata {
  let m = extend_metadata(base_expression_metadata)
  returns_all(m, [Atan2, MatchAgainst, StDistance], DOUBLE)
  returns_all(
    m,
    [CurrentTimestamp, ConvertTimezone, Localtime, Localtimestamp, UtcTimestamp],
    DATETIME,
  )
  returns_all(m, [UtcDate], DATE)
  returns_all(
    m,
    [
      Elt,
      Hex,
      NumberToStr,
      Replace,
      Stuff,
      SubstringIndex,
      RegexpSubstr,
      Collation,
      JSONType,
      Uuid,
    ],
    VARCHAR,
  )
  returns_all(m, [Month, Second, Week, Minute], INT)
  returns_all(m, [RegexpInstr, Grouping], BIGINT)
  returns_all(m, [TimeFromParts, UtcTime], TIME)
  returns_all(m, [Unhex], VARBINARY)
  returns_all(
    m,
    [
      JSONObjectAgg,
      JSONObject,
      JSONExtract,
      JSONKeys,
      JSONArrayAppend,
      JSONArrayInsert,
      JSONRemove,
      JSONSet,
    ],
    JSON,
  )
  returns_all(m, [CurrentRole], LONGTEXT)
  annotate_all(m, [Pad, Left, Right, Lead, Lag], (s, e) => {
    s.annotate_by_args(e, [Key("this")])
  })
  annotate_all(m, [BitwiseAndAgg, BitwiseXorAgg, BitwiseOrAgg], (s, e) => {
    mysql_annotate_bit_func(s, e)
  })
  m[Reverse] = Annotator((s, e) => mysql_annotate_reverse(s, e))
  m[Trunc] = Annotator((s, e) => mysql_annotate_truncate(s, e))
  m[RegexpReplace] = Annotator((s, e) => mysql_annotate_regexp_replace(s, e))
  m[Compress] = Annotator((s, e) => mysql_annotate_compress(s, e))
  m
}
