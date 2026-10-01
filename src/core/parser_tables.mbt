// The base Parser's FUNCTIONS and *_PARSERS tables, plus the module-level builder
// helpers of sqlglot/parser.py (build_like, build_logarithm, ...), which dialects reuse.

///|
fn arg(args : Array[Expr], i : Int) -> Expr? {
  args.get(i)
}

///|
fn rest(args : Array[Expr], from : Int) -> Array[Expr] {
  if from >= args.length() {
    []
  } else {
    args[from:].to_array()
  }
}

///|
pub fn build_var_map(args : Array[Expr]) -> Expr {
  if args.length() == 1 && args[0].is_star() {
    return mk1(StarMap, args[0])
  }
  let keys = []
  let values = []
  let mut i = 0
  while i < args.length() {
    keys.push(args[i])
    if i + 1 < args.length() {
      values.push(args[i + 1])
    }
    i += 2
  }
  mk(VarMap, [
    ("keys", mk(Array, [("expressions", keys)])),
    ("values", mk(Array, [("expressions", values)])),
  ])
}

///|
pub fn build_like(args : Array[Expr]) -> Expr {
  let like = mk(Like, [("this", arg(args, 1)), ("expression", arg(args, 0))])
  if args.length() > 2 {
    mk(Escape, [("this", like), ("expression", arg(args, 2))])
  } else {
    like
  }
}

///|
/// `binary_range_parser(expr_type, reverse_args)`
pub fn binary_range_parser(
  kind : Kind,
  reverse_args? : Bool = false,
) -> ParseFn1 {
  fn(p, this) {
    let expression = p.parse_bitwise()
    let (a, b) = if reverse_args {
      (expression, this)
    } else {
      (this, expression)
    }
    p.parse_escape(
      Some(p.expression(mk(kind, [("this", a), ("expression", b)]))),
    )
  }
}

///|
pub fn build_logarithm(args : Array[Expr], p : Parser) -> Expr {
  let mut this = arg(args, 0)
  let mut expression = arg(args, 1)
  if expression is Some(_) {
    if p.dialect.cfg.log_base_first != Some(true) {
      let tmp = this
      this = expression
      expression = tmp
    }
    return mk(Log, [("this", this), ("expression", expression)])
  }
  mk1(if p.cfg.log_defaults_to_ln { Ln } else { Log }, this)
}

///|
pub fn build_hex(args : Array[Expr], p : Parser) -> Expr {
  let a = arg(args, 0)
  if p.dialect.cfg.hex_lowercase {
    mk1(LowerHex, a)
  } else {
    mk1(Hex, a)
  }
}

///|
pub fn build_lower(args : Array[Expr]) -> Expr {
  match arg(args, 0) {
    Some(a) if a.kind == Hex => mk1(LowerHex, a.this())
    a => mk1(Lower, a)
  }
}

///|
pub fn build_upper(args : Array[Expr]) -> Expr {
  match arg(args, 0) {
    Some(a) if a.kind == Hex => mk1(Hex, a.this())
    a => mk1(Upper, a)
  }
}

///|
pub fn build_extract_json_with_path(kind : Kind) -> FuncBuilder {
  fn(args, p) {
    let expression = mk(kind, [
      ("this", arg(args, 0)),
      ("expression", p.dialect.to_json_path(arg(args, 1))),
    ])
    if args.length() > 2 && kind == JSONExtract {
      expression.set("expressions", rest(args, 2))
    }
    if kind == JSONExtractScalar {
      expression.set(
        "scalar_only",
        p.dialect.cfg.json_extract_scalar_scalar_only,
      )
    }
    expression
  }
}

///|
pub fn build_mod(args : Array[Expr]) -> Expr {
  let wrap = fn(e : Expr?) -> Expr? {
    match e {
      Some(x) if x.kind.is_a(Binary) => Some(mk1(Paren, x))
      _ => e
    }
  }
  mk(Mod, [("this", wrap(arg(args, 0))), ("expression", wrap(arg(args, 1)))])
}

///|
pub fn build_pad(args : Array[Expr], is_left? : Bool = true) -> Expr {
  mk(Pad, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    ("fill_pattern", arg(args, 2)),
    ("is_left", is_left),
  ])
}

///|
pub fn build_convert_timezone(
  args : Array[Expr],
  default_source_tz? : String,
) -> Expr {
  if args.length() == 2 {
    let source_tz = match default_source_tz {
      Some(s) if !s.is_empty() => Some(literal_string(s))
      _ => None
    }
    return mk(ConvertTimezone, [
      ("source_tz", source_tz),
      ("target_tz", arg(args, 0)),
      ("timestamp", arg(args, 1)),
    ])
  }
  from_arg_list(ConvertTimezone, args)
}

///|
pub fn build_trim(
  args : Array[Expr],
  is_left? : Bool = true,
  reverse_args? : Bool = false,
) -> Expr {
  let mut this = arg(args, 0)
  let mut expression = arg(args, 1)
  if expression is Some(_) && reverse_args {
    let tmp = this
    this = expression
    expression = tmp
  }
  mk(Trim, [
    ("this", this),
    ("expression", expression),
    ("position", if is_left { "LEADING" } else { "TRAILING" }),
  ])
}

///|
pub fn build_coalesce(
  args : Array[Expr],
  is_nvl? : Bool,
  is_null? : Bool,
) -> Expr {
  mk(Coalesce, [
    ("this", arg(args, 0)),
    ("expressions", rest(args, 1)),
    ("is_nvl", is_nvl),
    ("is_null", is_null),
  ])
}

///|
pub fn build_locate_strposition(args : Array[Expr]) -> Expr {
  mk(StrPosition, [
    ("this", arg(args, 1)),
    ("substr", arg(args, 0)),
    ("position", arg(args, 2)),
  ])
}

///|
pub fn build_array_append(args : Array[Expr], p : Parser) -> Expr {
  mk(ArrayAppend, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    ("null_propagation", p.dialect.cfg.array_funcs_propagates_nulls),
  ])
}

///|
pub fn build_array_prepend(args : Array[Expr], p : Parser) -> Expr {
  mk(ArrayPrepend, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    ("null_propagation", p.dialect.cfg.array_funcs_propagates_nulls),
  ])
}

///|
pub fn build_array_concat(args : Array[Expr], p : Parser) -> Expr {
  mk(ArrayConcat, [
    ("this", arg(args, 0)),
    ("expressions", rest(args, 1)),
    ("null_propagation", p.dialect.cfg.array_funcs_propagates_nulls),
  ])
}

///|
pub fn build_array_remove(args : Array[Expr], p : Parser) -> Expr {
  mk(ArrayRemove, [
    ("this", arg(args, 0)),
    ("expression", arg(args, 1)),
    ("null_propagation", p.dialect.cfg.array_funcs_propagates_nulls),
  ])
}

///|
/// JSON operator builders shared between COLUMN_OPERATORS and JSON_OPERATORS.
pub fn build_json_extract_op(
  p : Parser,
  this : Expr?,
  path : Expr?,
) -> Expr? raise SqlglotError {
  Some(
    p.expression(
      mk(JSONExtract, [
        ("this", this),
        ("expression", p.dialect.to_json_path(path)),
        ("only_json_types", p.cfg.json_arrows_require_json_type),
      ]),
    ),
  )
}

///|
pub fn build_json_extract_scalar_op(
  p : Parser,
  this : Expr?,
  path : Expr?,
) -> Expr? raise SqlglotError {
  Some(
    p.expression(
      mk(JSONExtractScalar, [
        ("this", this),
        ("expression", p.dialect.to_json_path(path)),
        ("only_json_types", p.cfg.json_arrows_require_json_type),
        ("scalar_only", p.dialect.cfg.json_extract_scalar_scalar_only),
      ]),
    ),
  )
}

///|
pub fn build_jsonb_extract_op(
  p : Parser,
  this : Expr?,
  path : Expr?,
) -> Expr? raise SqlglotError {
  Some(p.expression(mk(JSONBExtract, [("this", this), ("expression", path)])))
}

///|
pub fn build_jsonb_extract_scalar_op(
  p : Parser,
  this : Expr?,
  path : Expr?,
) -> Expr? raise SqlglotError {
  Some(
    p.expression(mk(JSONBExtractScalar, [("this", this), ("expression", path)])),
  )
}

///|
pub fn build_jsonb_contains_top_key_op(
  p : Parser,
  this : Expr?,
  key : Expr?,
) -> Expr? raise SqlglotError {
  Some(
    p.expression(mk(JSONBContainsTopKey, [("this", this), ("expression", key)])),
  )
}

///|
fn text_cast(e : Expr?) -> Expr {
  mk(Cast, [("this", e), ("to", mk1(DataType, DType::TEXT))])
}

///|
fn base_functions() -> Map[String, FuncBuilder] {
  let f : Map[String, FuncBuilder] = Map([])
  for nk in function_by_name {
    f[nk.0] = from_arg_list_builder(nk.1)
  }
  for name in ["COALESCE", "IFNULL", "NVL"] {
    f[name] = fn(args, _p) { build_coalesce(args) }
  }
  f["ARRAY"] = fn(args, _p) { mk(Array, [("expressions", args)]) }
  let array_agg : FuncBuilder = fn(args, p) {
    mk(ArrayAgg, [
      ("this", arg(args, 0)),
      (
        "nulls_excluded",
        if p.dialect.cfg.array_agg_includes_nulls is None {
          Some(true)
        } else {
          None
        },
      ),
    ])
  }
  f["ARRAYAGG"] = array_agg
  f["ARRAY_AGG"] = array_agg
  f["ARRAY_APPEND"] = fn(args, p) { build_array_append(args, p) }
  f["ARRAY_CAT"] = fn(args, p) { build_array_concat(args, p) }
  f["ARRAY_CONCAT"] = fn(args, p) { build_array_concat(args, p) }
  f["ARRAY_INTERSECT"] = fn(args, _p) {
    mk(ArrayIntersect, [("expressions", args)])
  }
  f["ARRAY_INTERSECTION"] = fn(args, _p) {
    mk(ArrayIntersect, [("expressions", args)])
  }
  f["ARRAY_PREPEND"] = fn(args, p) { build_array_prepend(args, p) }
  f["ARRAY_REMOVE"] = fn(args, p) { build_array_remove(args, p) }
  f["COUNT"] = fn(args, _p) {
    mk(Count, [
      ("this", arg(args, 0)),
      ("expressions", rest(args, 1)),
      ("big_int", true),
    ])
  }
  f["CONCAT"] = fn(args, p) {
    mk(Concat, [
      ("expressions", args),
      ("safe", !p.dialect.cfg.strict_string_concat),
      ("coalesce", p.dialect.cfg.concat_coalesce),
    ])
  }
  f["CONCAT_WS"] = fn(args, p) {
    mk(ConcatWs, [
      ("expressions", args),
      ("safe", !p.dialect.cfg.strict_string_concat),
      ("coalesce", p.dialect.cfg.concat_ws_coalesce),
    ])
  }
  f["CONVERT_TIMEZONE"] = fn(args, _p) { build_convert_timezone(args) }
  f["DATE_TO_DATE_STR"] = fn(args, _p) { text_cast(arg(args, 0)) }
  f["GENERATE_DATE_ARRAY"] = fn(args, _p) {
    let step = match arg(args, 2) {
      Some(s) => s
      None =>
        mk(Interval, [("this", literal_string("1")), ("unit", var_("DAY"))])
    }
    mk(GenerateDateArray, [
      ("start", arg(args, 0)),
      ("end", arg(args, 1)),
      ("step", step),
    ])
  }
  f["GENERATE_UUID"] = fn(_args, p) {
    mk(Uuid, [
      (
        "is_string",
        if p.dialect.cfg.uuid_is_string_type {
          Some(true)
        } else {
          None
        },
      ),
    ])
  }
  f["GLOB"] = fn(args, _p) {
    mk(Glob, [("this", arg(args, 1)), ("expression", arg(args, 0))])
  }
  f["GREATEST"] = fn(args, p) {
    mk(Greatest, [
      ("this", arg(args, 0)),
      ("expressions", rest(args, 1)),
      ("ignore_nulls", p.dialect.cfg.least_greatest_ignores_nulls),
    ])
  }
  f["LEAST"] = fn(args, p) {
    mk(Least, [
      ("this", arg(args, 0)),
      ("expressions", rest(args, 1)),
      ("ignore_nulls", p.dialect.cfg.least_greatest_ignores_nulls),
    ])
  }
  f["HEX"] = fn(args, p) { build_hex(args, p) }
  f["JSON_EXTRACT"] = build_extract_json_with_path(JSONExtract)
  f["JSON_EXTRACT_SCALAR"] = build_extract_json_with_path(JSONExtractScalar)
  f["JSON_EXTRACT_PATH_TEXT"] = build_extract_json_with_path(JSONExtractScalar)
  f["JSON_KEYS"] = fn(args, p) {
    mk(JSONKeys, [
      ("this", arg(args, 0)),
      ("expression", p.dialect.to_json_path(arg(args, 1))),
    ])
  }
  f["LIKE"] = fn(args, _p) { build_like(args) }
  f["LOG"] = fn(args, p) { build_logarithm(args, p) }
  f["LOG2"] = fn(args, _p) {
    mk(Log, [("this", literal_int(2)), ("expression", arg(args, 0))])
  }
  f["LOG10"] = fn(args, _p) {
    mk(Log, [("this", literal_int(10)), ("expression", arg(args, 0))])
  }
  f["LOWER"] = fn(args, _p) { build_lower(args) }
  f["LPAD"] = fn(args, _p) { build_pad(args) }
  f["LEFTPAD"] = fn(args, _p) { build_pad(args) }
  f["LTRIM"] = fn(args, _p) { build_trim(args) }
  f["MOD"] = fn(args, _p) { build_mod(args) }
  f["RIGHTPAD"] = fn(args, _p) { build_pad(args, is_left=false) }
  f["RPAD"] = fn(args, _p) { build_pad(args, is_left=false) }
  f["RTRIM"] = fn(args, _p) { build_trim(args, is_left=false) }
  f["SCOPE_RESOLUTION"] = fn(args, _p) {
    if args.length() != 2 {
      mk(ScopeResolution, [("expression", arg(args, 0))])
    } else {
      mk(ScopeResolution, [("this", arg(args, 0)), ("expression", arg(args, 1))])
    }
  }
  f["STRPOS"] = from_arg_list_builder(StrPosition)
  f["CHARINDEX"] = fn(args, _p) { build_locate_strposition(args) }
  f["INSTR"] = from_arg_list_builder(StrPosition)
  f["LOCATE"] = fn(args, _p) { build_locate_strposition(args) }
  f["TIME_TO_TIME_STR"] = fn(args, _p) { text_cast(arg(args, 0)) }
  f["TO_HEX"] = fn(args, p) { build_hex(args, p) }
  f["TS_OR_DS_TO_DATE_STR"] = fn(args, _p) {
    mk(Substring, [
      ("this", text_cast(arg(args, 0))),
      ("start", literal_int(1)),
      ("length", literal_int(10)),
    ])
  }
  f["UNNEST"] = fn(args, _p) {
    mk(Unnest, [("expressions", opt_list(arg(args, 0)))])
  }
  f["UPPER"] = fn(args, _p) { build_upper(args) }
  f["UUID"] = fn(_args, p) {
    mk(Uuid, [
      (
        "is_string",
        if p.dialect.cfg.uuid_is_string_type {
          Some(true)
        } else {
          None
        },
      ),
    ])
  }
  f["UUID_STRING"] = fn(args, p) {
    mk(Uuid, [
      ("this", arg(args, 0)),
      ("name", arg(args, 1)),
      (
        "is_string",
        if p.dialect.cfg.uuid_is_string_type {
          Some(true)
        } else {
          None
        },
      ),
    ])
  }
  f["VAR_MAP"] = fn(args, _p) { build_var_map(args) }
  f
}

///|
fn base_property_parsers() -> Map[String, PropertyFn] {
  let m : Map[String, PropertyFn] = Map([])
  let node = fn(e : Expr) -> Value? { Some(Node(e)) }
  let opt = fn(e : Expr?) -> Value? { e.map(x => Node(x)) }
  m["ALLOWED_VALUES"] = fn(p, _) {
    node(
      p.expression(
        mk(AllowedValuesProperty, [
          ("expressions", p.parse_csv(() => p.parse_primary())),
        ]),
      ),
    )
  }
  m["ALGORITHM"] = fn(p, _) {
    node(p.parse_property_assignment(AlgorithmProperty))
  }
  m["AUTO"] = fn(p, _) { opt(p.parse_auto_property()) }
  m["AUTO_INCREMENT"] = fn(p, _) {
    node(p.parse_property_assignment(AutoIncrementProperty))
  }
  m["BACKUP"] = fn(p, _) {
    node(p.expression(mk1(BackupProperty, p.parse_var(any_token=true))))
  }
  m["BLOCKCOMPRESSION"] = fn(p, _) { node(p.parse_blockcompression()) }
  m["CALLED"] = fn(p, _) { opt(p.parse_called_on_null_input_property()) }
  m["CHARSET"] = fn(p, kw) {
    node(p.parse_character_set(default=kw.get("default").unwrap_or(false)))
  }
  m["CHECKSUM"] = fn(p, _) { node(p.parse_checksum()) }
  m["CLUSTER BY"] = fn(p, _) { opt(p.parse_cluster_property()) }
  m["CLUSTERED"] = fn(p, _) { node(p.parse_clustered_by()) }
  m["COLLATE"] = fn(p, kw) {
    let kwargs : Array[(String, &IntoValue)] = []
    for k, v in kw {
      kwargs.push((k, v))
    }
    node(p.parse_property_assignment(CollateProperty, kwargs~))
  }
  m["COMMENT"] = fn(p, _) {
    node(p.parse_property_assignment(SchemaCommentProperty))
  }
  m["CONTAINS"] = fn(p, _) { opt(p.parse_contains_property()) }
  m["COPY"] = fn(p, _) { opt(p.parse_copy_property()) }
  m["DATABLOCKSIZE"] = fn(p, kw) {
    node(
      p.parse_datablocksize(
        default?=kw.get("default"),
        minimum?=kw.get("minimum"),
        maximum?=kw.get("maximum"),
      ),
    )
  }
  m["DATA_DELETION"] = fn(p, _) { node(p.parse_data_deletion_property()) }
  m["DEFINER"] = fn(p, _) { opt(p.parse_definer()) }
  m["DETERMINISTIC"] = fn(p, _) {
    node(p.expression(mk1(StabilityProperty, literal_string("IMMUTABLE"))))
  }
  m["DISTRIBUTED"] = fn(p, _) { node(p.parse_distributed_property()) }
  m["DUPLICATE"] = fn(p, _) {
    node(p.parse_composite_key_property(DuplicateKeyProperty))
  }
  m["DYNAMIC"] = fn(p, _) { node(p.expression(mk0(DynamicProperty))) }
  m["DISTKEY"] = fn(p, _) { node(p.parse_distkey()) }
  m["DISTSTYLE"] = fn(p, _) {
    node(p.parse_property_assignment(DistStyleProperty))
  }
  m["EMPTY"] = fn(p, _) { node(p.expression(mk0(EmptyProperty))) }
  m["ENGINE"] = fn(p, _) { node(p.parse_property_assignment(EngineProperty)) }
  m["ENVIRONMENT"] = fn(p, _) {
    node(
      p.expression(
        mk(EnviromentProperty, [
          ("expressions", p.parse_wrapped_csv(() => p.parse_assignment())),
        ]),
      ),
    )
  }
  m["HANDLER"] = fn(p, _) { node(p.parse_property_assignment(HandlerProperty)) }
  m["EXECUTE"] = fn(p, _) {
    node(p.parse_property_assignment(ExecuteAsProperty))
  }
  m["EXTERNAL"] = fn(p, _) { node(p.expression(mk0(ExternalProperty))) }
  m["FALLBACK"] = fn(p, kw) {
    node(p.parse_fallback(no=kw.get("no").unwrap_or(false)))
  }
  m["FORMAT"] = fn(p, _) {
    node(p.parse_property_assignment(FileFormatProperty))
  }
  m["FREESPACE"] = fn(p, _) { node(p.parse_freespace()) }
  m["GLOBAL"] = fn(p, _) { node(p.expression(mk0(GlobalProperty))) }
  m["HEAP"] = fn(p, _) { node(p.expression(mk0(HeapProperty))) }
  m["ICEBERG"] = fn(p, _) { node(p.expression(mk0(IcebergProperty))) }
  m["IMMUTABLE"] = fn(p, _) {
    node(p.expression(mk1(StabilityProperty, literal_string("IMMUTABLE"))))
  }
  m["INHERITS"] = fn(p, _) {
    node(
      p.expression(
        mk(InheritsProperty, [
          ("expressions", p.parse_wrapped_csv(() => p.parse_table())),
        ]),
      ),
    )
  }
  m["INPUT"] = fn(p, _) {
    node(p.expression(mk1(InputModelProperty, p.parse_schema())))
  }
  m["JOURNAL"] = fn(p, kw) { node(p.parse_journal(kw)) }
  m["LANGUAGE"] = fn(p, _) {
    node(p.parse_property_assignment(LanguageProperty))
  }
  m["LAYOUT"] = fn(p, _) { opt(p.parse_dict_property("LAYOUT")) }
  m["LIFETIME"] = fn(p, _) { opt(p.parse_dict_range("LIFETIME")) }
  m["LIKE"] = fn(p, _) { opt(p.parse_create_like()) }
  m["LOCATION"] = fn(p, _) {
    node(p.parse_property_assignment(LocationProperty))
  }
  m["LOCK"] = fn(p, _) { node(p.parse_locking()) }
  m["LOCKING"] = fn(p, _) { node(p.parse_locking()) }
  m["LOG"] = fn(p, kw) { node(p.parse_log(no=kw.get("no").unwrap_or(false))) }
  m["MATERIALIZED"] = fn(p, _) { node(p.expression(mk0(MaterializedProperty))) }
  m["MERGEBLOCKRATIO"] = fn(p, kw) {
    node(
      p.parse_mergeblockratio(
        no=kw.get("no").unwrap_or(false),
        default=kw.get("default").unwrap_or(false),
      ),
    )
  }
  m["MODIFIES"] = fn(p, _) { opt(p.parse_modifies_property()) }
  m["MULTISET"] = fn(p, _) {
    node(p.expression(mk(SetProperty, [("multi", true)])))
  }
  m["NO"] = fn(p, _) { opt(p.parse_no_property()) }
  m["ON"] = fn(p, _) { opt(p.parse_on_property()) }
  m["ORDER BY"] = fn(p, _) { opt(p.parse_order(skip_order_token=true)) }
  m["OUTPUT"] = fn(p, _) {
    node(p.expression(mk1(OutputModelProperty, p.parse_schema())))
  }
  m["PARTITION"] = fn(p, _) { opt(p.parse_partitioned_of()) }
  m["PARTITION BY"] = fn(p, _) { opt(p.parse_partitioned_by()) }
  m["PARTITIONED BY"] = fn(p, _) { opt(p.parse_partitioned_by()) }
  m["PARTITIONED_BY"] = fn(p, _) { opt(p.parse_partitioned_by()) }
  m["PRIMARY KEY"] = fn(p, _) { opt(p.parse_primary_key(in_props=true)) }
  m["RANGE"] = fn(p, _) { opt(p.parse_dict_range("RANGE")) }
  m["READS"] = fn(p, _) { opt(p.parse_reads_property()) }
  m["REMOTE"] = fn(p, _) { node(p.parse_remote_with_connection()) }
  m["RETURNS"] = fn(p, _) { opt(p.parse_returns()) }
  m["STRICT"] = fn(p, _) { node(p.expression(mk0(StrictProperty))) }
  m["STREAMING"] = fn(p, _) { node(p.expression(mk0(StreamingTableProperty))) }
  m["ROW"] = fn(p, _) { opt(p.parse_row()) }
  m["ROW_FORMAT"] = fn(p, _) {
    node(p.parse_property_assignment(RowFormatProperty))
  }
  m["SAMPLE"] = fn(p, _) {
    let this = p.andv(p.match_text("BY"), () => p.parse_bitwise())
    node(p.expression(mk1(SampleProperty, this)))
  }
  m["SECURE"] = fn(p, _) { node(p.expression(mk0(SecureProperty))) }
  m["SECURITY"] = fn(p, _) { node(p.parse_sql_security()) }
  m["SQL SECURITY"] = fn(p, _) { node(p.parse_sql_security()) }
  m["SET"] = fn(p, _) {
    node(p.expression(mk(SetProperty, [("multi", false)])))
  }
  m["SETTINGS"] = fn(p, _) { node(p.parse_settings_property()) }
  m["SHARING"] = fn(p, _) { node(p.parse_property_assignment(SharingProperty)) }
  m["SORTKEY"] = fn(p, _) { node(p.parse_sortkey()) }
  m["SOURCE"] = fn(p, _) { opt(p.parse_dict_property("SOURCE")) }
  m["STABLE"] = fn(p, _) {
    node(p.expression(mk1(StabilityProperty, literal_string("STABLE"))))
  }
  m["STORED"] = fn(p, _) { node(p.parse_stored()) }
  m["SYSTEM_VERSIONING"] = fn(p, _) {
    node(p.parse_system_versioning_property())
  }
  m["TBLPROPERTIES"] = fn(p, _) {
    Some(List(p.parse_wrapped_properties().map(x => Node(x))))
  }
  m["TEMP"] = fn(p, _) { node(p.expression(mk0(TemporaryProperty))) }
  m["TEMPORARY"] = fn(p, _) { node(p.expression(mk0(TemporaryProperty))) }
  m["TO"] = fn(p, _) { opt(p.parse_to_table()) }
  m["TRANSIENT"] = fn(p, _) { node(p.expression(mk0(TransientProperty))) }
  m["TRANSFORM"] = fn(p, _) {
    node(
      p.expression(
        mk(TransformModelProperty, [
          ("expressions", p.parse_wrapped_csv(() => p.parse_expression())),
        ]),
      ),
    )
  }
  m["TTL"] = fn(p, _) { opt(p.parse_ttl()) }
  m["USING"] = fn(p, _) {
    node(p.parse_property_assignment(FileFormatProperty))
  }
  m["UNLOGGED"] = fn(p, _) { node(p.expression(mk0(UnloggedProperty))) }
  m["VOLATILE"] = fn(p, _) { node(p.parse_volatile_property()) }
  m["WITH"] = fn(p, _) { p.parse_with_property() }
  m
}

///|
fn base_constraint_parsers() -> Map[String, ParseFn] {
  let m : Map[String, ParseFn] = Map([])
  m["AUTOINCREMENT"] = p => p.parse_auto_increment()
  m["AUTO_INCREMENT"] = p => p.parse_auto_increment()
  m["CASESPECIFIC"] = p => {
    Some(p.expression(mk(CaseSpecificColumnConstraint, [("not_", false)])))
  }
  m["CHECK"] = p => p.parse_check_constraint()
  m["COLLATE"] = p => {
    Some(
      p.expression(
        mk1(
          CollateColumnConstraint,
          expr_or(p.parse_identifier(), () => p.parse_column()),
        ),
      ),
    )
  }
  m["COMMENT"] = p => {
    Some(p.expression(mk1(CommentColumnConstraint, p.parse_string())))
  }
  m["COMPRESS"] = p => p.parse_compress()
  m["CLUSTERED"] = p => {
    Some(
      p.expression(
        mk1(
          ClusteredColumnConstraint,
          p.parse_wrapped_csv(() => p.parse_ordered()),
        ),
      ),
    )
  }
  m["NONCLUSTERED"] = p => {
    Some(
      p.expression(
        mk1(
          NonClusteredColumnConstraint,
          p.parse_wrapped_csv(() => p.parse_ordered()),
        ),
      ),
    )
  }
  m["DEFAULT"] = p => {
    Some(p.expression(mk1(DefaultColumnConstraint, p.parse_bitwise())))
  }
  m["ENCODE"] = p => {
    Some(p.expression(mk1(EncodeColumnConstraint, p.parse_var())))
  }
  m["EPHEMERAL"] = p => {
    Some(p.expression(mk1(EphemeralColumnConstraint, p.parse_bitwise())))
  }
  m["EXCLUDE"] = p => {
    Some(p.expression(mk1(ExcludeColumnConstraint, p.parse_index_params())))
  }
  m["FOREIGN KEY"] = p => p.parse_foreign_key()
  m["FORMAT"] = p => {
    Some(p.expression(mk1(DateFormatColumnConstraint, p.parse_var_or_string())))
  }
  m["GENERATED"] = p => p.parse_generated_as_identity()
  m["IDENTITY"] = p => p.parse_auto_increment()
  m["INLINE"] = p => p.parse_inline()
  m["LIKE"] = p => p.parse_create_like()
  m["NOT"] = p => p.parse_not_constraint()
  m["NULL"] = p => {
    Some(p.expression(mk(NotNullColumnConstraint, [("allow_null", true)])))
  }
  m["ON"] = p => {
    if p.match_(UPDATE) {
      Some(p.expression(mk1(OnUpdateColumnConstraint, p.parse_function())))
    } else {
      Some(p.expression(mk1(OnProperty, p.parse_id_var())))
    }
  }
  m["PATH"] = p => {
    Some(p.expression(mk1(PathColumnConstraint, p.parse_string())))
  }
  m["PERIOD"] = p => p.parse_period_for_system_time()
  m["PRIMARY KEY"] = p => p.parse_primary_key()
  m["REFERENCES"] = p => p.parse_references(match_=false)
  m["TITLE"] = p => {
    Some(p.expression(mk1(TitleColumnConstraint, p.parse_var_or_string())))
  }
  m["TTL"] = p => {
    Some(
      p.expression(
        mk(MergeTreeTTL, [
          ("expressions", [p.parse_bitwise()].filter_map(x => x)),
        ]),
      ),
    )
  }
  m["UNIQUE"] = p => p.parse_unique()
  m["UPPERCASE"] = p => Some(p.expression(mk0(UppercaseColumnConstraint)))
  m["WITH"] = p => {
    Some(
      p.expression(
        mk(Properties, [("expressions", p.parse_wrapped_properties())]),
      ),
    )
  }
  m["BUCKET"] = p => p.parse_partitioned_by_bucket_or_truncate()
  m["TRUNCATE"] = p => p.parse_partitioned_by_bucket_or_truncate()
  m
}

///|
pub fn Parser::parse_partitioned_by_bucket_or_truncate(
  self : Parser,
) -> Expr? raise SqlglotError {
  if !self.match_(L_PAREN, advance=false) {
    self.retreat(self.index - 1)
    return None
  }
  let klass = if self.prev_upper() == "BUCKET" {
    PartitionedByBucket
  } else {
    PartitionByTruncate
  }
  let args = self.parse_wrapped_csv(() => {
    expr_or(self.parse_primary(), () => self.parse_column())
  })
  let mut this = args.get(0)
  let mut expression = args.get(1)
  match this {
    Some(t) if t.kind == Literal => {
      let tmp = this
      this = expression
      expression = tmp
    }
    _ => ()
  }
  Some(self.expression(mk(klass, [("this", this), ("expression", expression)])))
}

///|
/// The base Parser's FUNCTIONS and *_PARSERS tables.
pub fn base_parser_fns() -> ParserFns {
  let function_parsers : Map[String, ParseFn] = Map([])
  for name in ArgMax.sql_names() {
    function_parsers[name] = p => p.parse_distinct_arg_function(ArgMax)
  }
  for name in ArgMin.sql_names() {
    function_parsers[name] = p => p.parse_distinct_arg_function(ArgMin)
  }
  function_parsers["CAST"] = p => p.parse_cast(p.cfg.strict_cast)
  function_parsers["CEIL"] = p => p.parse_ceil_floor(Ceil)
  function_parsers["CONVERT"] = p => p.parse_convert(p.cfg.strict_cast)
  function_parsers["CHAR"] = p => p.parse_char()
  function_parsers["CHR"] = p => p.parse_char()
  function_parsers["DECODE"] = p => p.parse_decode()
  function_parsers["EXTRACT"] = p => p.parse_extract()
  function_parsers["FLOOR"] = p => p.parse_ceil_floor(Floor)
  function_parsers["GAP_FILL"] = p => p.parse_gap_fill()
  function_parsers["INITCAP"] = p => p.parse_initcap()
  function_parsers["JSON_OBJECT"] = p => p.parse_json_object()
  function_parsers["JSON_OBJECTAGG"] = p => p.parse_json_object(agg=true)
  function_parsers["JSON_TABLE"] = p => p.parse_json_table()
  function_parsers["MATCH"] = p => p.parse_match_against()
  function_parsers["NORMALIZE"] = p => p.parse_normalize()
  function_parsers["OPENJSON"] = p => p.parse_open_json()
  function_parsers["OVERLAY"] = p => p.parse_overlay()
  function_parsers["POSITION"] = p => p.parse_position()
  function_parsers["SAFE_CAST"] = p => p.parse_cast(false, safe=true)
  function_parsers["STRING_AGG"] = p => p.parse_string_agg()
  function_parsers["SUBSTRING"] = p => p.parse_substring()
  function_parsers["TRIM"] = p => p.parse_trim()
  function_parsers["TRY_CAST"] = p => p.parse_cast(false, safe=true)
  function_parsers["TRY_CONVERT"] = p => p.parse_convert(false, safe=true)
  function_parsers["XMLELEMENT"] = p => p.parse_xml_element()
  function_parsers["XMLTABLE"] = p => p.parse_xml_table()
  let no_paren_function_parsers : Map[String, ParseFn] = {
    "ANY": p => Some(p.expression(mk1(Any, p.parse_bitwise()))),
    "CASE": p => p.parse_case(),
    "CONNECT_BY_ROOT": p => {
      Some(p.expression(mk1(ConnectByRoot, p.parse_column())))
    },
    "IF": p => p.parse_if(),
  }
  let statement_parsers : Map[TokenType, ParseFn] = Map::from_array([
    (ALTER, p => p.parse_alter()),
    (ANALYZE, p => p.parse_analyze()),
    (BEGIN, p => p.parse_transaction()),
    (CACHE, p => p.parse_cache()),
    (COMMENT, p => p.parse_comment()),
    (COMMIT, p => p.parse_commit_or_rollback()),
    (COPY, p => p.parse_copy()),
    (CREATE, p => p.parse_create()),
    (DECLARE, p => p.parse_declare()),
    (DELETE, p => p.parse_delete()),
    (DESC, p => p.parse_describe()),
    (DESCRIBE, p => p.parse_describe()),
    (DROP, p => p.parse_drop()),
    (GRANT, p => p.parse_grant()),
    (REVOKE, p => p.parse_revoke()),
    (INSERT, p => p.parse_insert()),
    (KILL, p => p.parse_kill()),
    (LOAD, p => p.parse_load()),
    (MERGE, p => p.parse_merge()),
    (PIVOT, p => p.parse_simplified_pivot()),
    (PRAGMA, p => Some(p.expression(mk1(Pragma, p.parse_expression())))),
    (REFRESH, p => p.parse_refresh()),
    (ROLLBACK, p => p.parse_commit_or_rollback()),
    (SET, p => p.parse_set()),
    (TRUNCATE, p => p.parse_truncate_table()),
    (UNCACHE, p => p.parse_uncache()),
    (UNPIVOT, p => p.parse_simplified_pivot(is_unpivot=true)),
    (UPDATE, p => p.parse_update()),
    (USE, p => p.parse_use()),
    (SEMICOLON, _p => Some(mk0(Semicolon))),
  ])
  let unary_parsers : Map[TokenType, ParseFn] = Map::from_array([
    (PLUS, p => p.parse_unary()),
    (NOT, p => Some(p.expression(mk1(Not, p.parse_equality())))),
    (TILDE, p => Some(p.expression(mk1(BitwiseNot, p.parse_unary())))),
    (DASH, p => Some(p.expression(mk1(Neg, p.parse_unary())))),
    (PIPE_SLASH, p => Some(p.expression(mk1(Sqrt, p.parse_unary())))),
    (DPIPE_SLASH, p => Some(p.expression(mk1(Cbrt, p.parse_unary())))),
  ])
  let string_parsers : Map[TokenType, TokenParseFn] = Map::from_array([
    (
      HEREDOC_STRING,
      (p, t) => Some(p.expression(mk1(RawString, t.text), token=t)),
    ),
    (
      NATIONAL_STRING,
      (p, t) => Some(p.expression(mk1(National, t.text), token=t)),
    ),
    (RAW_STRING, (p, t) => Some(p.expression(mk1(RawString, t.text), token=t))),
    (
      STRING,
      (p, t) => {
        Some(
          p.expression(
            mk(Literal, [("this", t.text), ("is_string", true)]),
            token=t,
          ),
        )
      },
    ),
    (
      UNICODE_STRING,
      (p, t) => {
        let escape = p.andv(p.match_text("UESCAPE"), () => p.parse_string())
        Some(
          p.expression(
            mk(UnicodeString, [("this", t.text), ("escape", escape)]),
            token=t,
          ),
        )
      },
    ),
  ])
  let numeric_parsers : Map[TokenType, TokenParseFn] = Map::from_array([
    (BIT_STRING, (p, t) => Some(p.expression(mk1(BitString, t.text), token=t))),
    (
      BYTE_STRING,
      (p, t) => {
        Some(
          p.expression(
            mk(ByteString, [
              ("this", t.text),
              (
                "is_bytes",
                if p.dialect.cfg.byte_string_is_bytes_type {
                  Some(true)
                } else {
                  None
                },
              ),
            ]),
            token=t,
          ),
        )
      },
    ),
    (
      HEX_STRING,
      (p, t) => {
        Some(
          p.expression(
            mk(HexString, [
              ("this", t.text),
              (
                "is_integer",
                if p.dialect.cfg.hex_string_is_integer_type {
                  Some(true)
                } else {
                  None
                },
              ),
            ]),
            token=t,
          ),
        )
      },
    ),
    (
      NUMBER,
      (p, t) => {
        Some(
          p.expression(
            mk(Literal, [("this", t.text), ("is_string", false)]),
            token=t,
          ),
        )
      },
    ),
  ])
  let primary_parsers : Map[TokenType, TokenParseFn] = Map([])
  for k, v in string_parsers {
    primary_parsers[k] = v
  }
  for k, v in numeric_parsers {
    primary_parsers[k] = v
  }
  primary_parsers[INTRODUCER] = (p, t) => p.parse_introducer(t)
  primary_parsers[NULL] = (p, _) => Some(p.expression(mk0(Null)))
  primary_parsers[TRUE] = (p, _) => Some(p.expression(mk1(Boolean, true)))
  primary_parsers[FALSE] = (p, _) => Some(p.expression(mk1(Boolean, false)))
  primary_parsers[SESSION_PARAMETER] = (p, _) => p.parse_session_parameter()
  primary_parsers[STAR] = (p, _) => p.parse_star_ops()
  let placeholder_parsers : Map[TokenType, ParseFn] = Map::from_array([
    (PLACEHOLDER, p => Some(p.expression(mk0(Placeholder)))),
    (PARAMETER, p => p.parse_parameter()),
    (
      COLON,
      p => {
        if p.match_set(p.cfg.colon_placeholder_tokens) {
          Some(p.expression(mk1(Placeholder, p.prev.text)))
        } else {
          None
        }
      },
    ),
  ])
  let range_parsers : Map[TokenType, ParseFn1] = Map::from_array([
    (AT_GT, binary_range_parser(ArrayContainsAll)),
    (BETWEEN, (p, this) => p.parse_between(this)),
    (GLOB, binary_range_parser(Glob)),
    (ILIKE, binary_range_parser(ILike)),
    (IN, (p, this) => p.parse_in(this)),
    (IRLIKE, binary_range_parser(RegexpILike)),
    (IS, (p, this) => p.parse_is(this)),
    (LIKE, binary_range_parser(Like)),
    (LT_AT, binary_range_parser(ArrayContainedBy)),
    (OVERLAPS, binary_range_parser(Overlaps)),
    (RLIKE, binary_range_parser(RegexpLike)),
    (SIMILAR_TO, binary_range_parser(SimilarTo)),
    (FOR, (p, this) => p.parse_comprehension(this)),
    (QMARK_AMP, binary_range_parser(JSONBContainsAllTopKeys)),
    (QMARK_PIPE, binary_range_parser(JSONBContainsAnyTopKeys)),
    (HASH_DASH, binary_range_parser(JSONBDeleteAtPath)),
    (AT_QMARK, binary_range_parser(JSONBPathExists)),
    (ADJACENT, binary_range_parser(Adjacent)),
    (OPERATOR, (p, this) => p.parse_operator(this)),
    (AMP_LT, binary_range_parser(ExtendsLeft)),
    (AMP_GT, binary_range_parser(ExtendsRight)),
  ])
  let column_operators : Map[TokenType, ColumnOpFn?] = Map::from_array([
    (DOT, None),
    (
      DOTCOLON,
      Some(fn(p : Parser, this : Expr?, to : Expr?) raise SqlglotError {
        Some(p.expression(mk(JSONCast, [("this", this), ("to", to)])))
      }),
    ),
    (
      DCOLON,
      Some(fn(p : Parser, this : Expr?, to : Expr?) raise SqlglotError {
        Some(
          p.build_cast(p.cfg.strict_cast, [
            ("this", this.map(x => Node(x))),
            ("to", to.map(x => Node(x))),
          ]),
        )
      }),
    ),
    (ARROW, Some(build_json_extract_op)),
    (DARROW, Some(build_json_extract_scalar_op)),
    (HASH_ARROW, Some(build_jsonb_extract_op)),
    (DHASH_ARROW, Some(build_jsonb_extract_scalar_op)),
    (PLACEHOLDER, Some(build_jsonb_contains_top_key_op)),
  ])
  let lambdas : Map[
    TokenType,
    (Parser, Array[Expr]) -> Expr? raise SqlglotError,
  ] = Map::from_array([
    (
      ARROW,
      fn(p : Parser, expressions : Array[Expr]) raise SqlglotError {
        let body = p.replace_lambda(p.parse_disjunction(), expressions)
        Some(
          p.expression(
            mk(Lambda, [("this", body), ("expressions", expressions)]),
          ),
        )
      },
    ),
    (
      FARROW,
      fn(p : Parser, expressions : Array[Expr]) raise SqlglotError {
        let name = if expressions.is_empty() {
          ""
        } else {
          expressions[0].name()
        }
        let e = expr_or(p.parse_disjunction(), () => p.parse_select())
        Some(p.expression(mk(Kwarg, [("this", var_(name)), ("expression", e)])))
      },
    ),
  ])
  let expression_parsers : Map[Kind, ParseFn] = Map::from_array([
    (Cluster, p => p.parse_sort(Cluster, CLUSTER_BY)),
    (Column, p => p.parse_column()),
    (ColumnDef, p => p.parse_column_def(p.parse_column())),
    (Condition, p => p.parse_disjunction()),
    (DataType, p => p.parse_types(allow_identifiers=false, schema=true)),
    (From, p => p.parse_from(joins=true)),
    (GrantPrincipal, p => p.parse_grant_principal()),
    (GrantPrivilege, p => p.parse_grant_privilege()),
    (Group, p => p.parse_group()),
    (Having, p => p.parse_having()),
    (Hint, p => p.parse_hint_body()),
    (Identifier, p => p.parse_id_var()),
    (Join, p => p.parse_join()),
    (Lambda, p => p.parse_lambda()),
    (Lateral, p => p.parse_lateral()),
    (Limit, p => p.parse_limit()),
    (Offset, p => p.parse_offset()),
    (Order, p => p.parse_order()),
    (Ordered, p => p.parse_ordered()),
    (Properties, p => p.parse_properties()),
    (PartitionedByProperty, p => p.parse_partitioned_by()),
    (Qualify, p => p.parse_qualify()),
    (Returning, p => p.parse_returning()),
    (Select, p => p.parse_select()),
    (Sort, p => p.parse_sort(Sort, SORT_BY)),
    (Table, p => p.parse_table_parts()),
    (TableAlias, p => p.parse_table_alias()),
    (Tuple, p => p.parse_value(values=false)),
    (Whens, p => p.parse_when_matched()),
    (Where, p => p.parse_where()),
    (Window, p => p.parse_named_window()),
    (With, p => p.parse_with()),
  ])
  let alter_parsers : Map[String, (Parser) -> Value? raise SqlglotError] = {
    "ADD": p => Some(List(p.parse_alter_table_add().map(x => Node(x)))),
    "AS": p => p.parse_select().map(x => Node(x)),
    "ALTER": p => p.parse_alter_table_alter().map(x => Node(x)),
    "CLUSTER BY": p => p.parse_cluster_property().map(x => Node(x)),
    "DELETE": p => {
      Some(Node(p.expression(mk(Delete, [("where", p.parse_where())]))))
    },
    "DROP": p => Some(List(p.parse_alter_table_drop().map(x => Node(x)))),
    "RENAME": p => p.parse_alter_table_rename().map(x => Node(x)),
    "SET": p => p.parse_alter_table_set().map(x => Node(x)),
    "SWAP": p => {
      let this = p.andv(p.match_(WITH), () => p.parse_table(schema=true))
      Some(Node(p.expression(mk1(SwapTable, this))))
    },
  }
  let alter_alter_parsers : Map[String, ParseFn] = {
    "DISTKEY": p => p.parse_alter_diststyle(),
    "DISTSTYLE": p => p.parse_alter_diststyle(),
    "SORTKEY": p => p.parse_alter_sortkey(),
    "COMPOUND": p => p.parse_alter_sortkey(compound=true),
  }
  let qm = fn(
    key : String,
    f : (Parser) -> Expr? raise SqlglotError,
  ) -> (Parser) -> (String, Value?) raise SqlglotError {
    fn(p) { (key, f(p).map(x => Node(x))) }
  }
  let query_modifier_parsers : Map[
    TokenType,
    (Parser) -> (String, Value?) raise SqlglotError,
  ] = Map::from_array([
    (MATCH_RECOGNIZE, qm("match", p => p.parse_match_recognize())),
    (PREWHERE, qm("prewhere", p => p.parse_prewhere())),
    (WHERE, qm("where", p => p.parse_where())),
    (GROUP_BY, qm("group", p => p.parse_group())),
    (HAVING, qm("having", p => p.parse_having())),
    (QUALIFY, qm("qualify", p => p.parse_qualify())),
    (
      WINDOW,
      fn(p : Parser) raise SqlglotError {
        ("windows", p.parse_window_clause().map(l => List(l.map(x => Node(x)))))
      },
    ),
    (ORDER_BY, qm("order", p => p.parse_order())),
    (LIMIT, qm("limit", p => p.parse_limit())),
    (FETCH, qm("limit", p => p.parse_limit())),
    (OFFSET, qm("offset", p => p.parse_offset())),
    (
      FOR,
      fn(p : Parser) raise SqlglotError {
        ("locks", Some(List(p.parse_locks().map(x => Node(x)))))
      },
    ),
    (
      LOCK,
      fn(p : Parser) raise SqlglotError {
        ("locks", Some(List(p.parse_locks().map(x => Node(x)))))
      },
    ),
    (TABLE_SAMPLE, qm("sample", p => p.parse_table_sample(as_modifier=true))),
    (USING, qm("sample", p => p.parse_table_sample(as_modifier=true))),
    (CLUSTER_BY, qm("cluster", p => Some(p.parse_cluster()))),
    (
      DISTRIBUTE_BY,
      qm("distribute", p => p.parse_sort(Distribute, DISTRIBUTE_BY)),
    ),
    (SORT_BY, qm("sort", p => p.parse_sort(Sort, SORT_BY))),
    (CONNECT_BY, qm("connect", p => p.parse_connect(skip_start_token=true))),
  ])
  let set_parsers : Map[String, ParseFn] = {
    "GLOBAL": p => p.parse_set_item_assignment(kind="GLOBAL"),
    "LOCAL": p => p.parse_set_item_assignment(kind="LOCAL"),
    "SESSION": p => p.parse_set_item_assignment(kind="SESSION"),
    "TRANSACTION": p => Some(p.parse_set_transaction()),
  }
  let type_literal_parsers : Map[
    DType,
    (Parser, Expr, Expr) -> Expr raise SqlglotError,
  ] = Map::from_array([
    (
      DType::JSON,
      fn(p : Parser, this : Expr, _dt : Expr) raise SqlglotError {
        p.expression(mk(ParseJSON, [("this", this), ("is_literal", true)]))
      },
    ),
  ])
  let pipe : Map[String, (Parser, Expr) -> Expr? raise SqlglotError] = {
    "AGGREGATE": (p, q) => p.parse_pipe_syntax_aggregate(q),
    "AS": (p, q) => {
      let alias = p.parse_table_alias()
      Some(p.build_pipe_cte(q, [mk0(Star)], alias_cte?=alias))
    },
    "DISTINCT": (p, q) => {
      p.advance()
      q.set("distinct", mk0(Distinct))
      Some(q)
    },
    "EXTEND": (p, q) => p.parse_pipe_syntax_extend(q),
    "LIMIT": (p, q) => p.parse_pipe_syntax_limit(q),
    "ORDER BY": (p, q) => {
      q.set("order", p.parse_order())
      Some(q)
    },
    "PIVOT": (p, q) => p.parse_pipe_syntax_pivot(q),
    "SELECT": (p, q) => p.parse_pipe_syntax_select(q),
    "TABLESAMPLE": (p, q) => p.parse_pipe_syntax_tablesample(q),
    "UNPIVOT": (p, q) => p.parse_pipe_syntax_pivot(q),
    "WHERE": (p, q) => {
      match p.parse_where() {
        Some(w) =>
          match q.arg("where") {
            Some(existing) =>
              q.set(
                "where",
                mk1(Where, and_([existing.this().unwrap(), w.this().unwrap()])),
              )
            None => q.set("where", w)
          }
        None => ()
      }
      Some(q)
    },
  }
  let analyze_expression_parsers : Map[String, ParseFn] = {
    "ALL": p => p.parse_analyze_columns(),
    "COMPUTE": p => p.parse_analyze_statistics(),
    "DELETE": p => p.parse_analyze_delete(),
    "DROP": p => p.parse_analyze_histogram(),
    "ESTIMATE": p => p.parse_analyze_statistics(),
    "LIST": p => p.parse_analyze_list(),
    "PREDICATE": p => p.parse_analyze_columns(),
    "UPDATE": p => p.parse_analyze_histogram(),
    "VALIDATE": p => p.parse_analyze_validate(),
  }
  {
    functions: base_functions(),
    function_parsers,
    no_paren_function_parsers,
    statement_parsers,
    unary_parsers,
    string_parsers,
    numeric_parsers,
    primary_parsers,
    placeholder_parsers,
    range_parsers,
    column_operators,
    json_operators: Map([]),
    lambdas,
    expression_parsers,
    property_parsers: base_property_parsers(),
    constraint_parsers: base_constraint_parsers(),
    alter_parsers,
    alter_alter_parsers,
    query_modifier_parsers,
    set_parsers,
    show_parsers: Map([]),
    type_literal_parsers,
    type_converters: Map([]),
    pipe_syntax_transform_parsers: pipe,
    analyze_expression_parsers,
    hooks: ParserHooks::new(),
    show_trie: WordTrie::new(),
    set_trie: WordTrie::new(),
  }
}

///|
pub fn Parser::replace_lambda(
  self : Parser,
  node : Expr?,
  expressions : Array[Expr],
) -> Expr? raise SqlglotError {
  let mut node = match node {
    Some(n) => n
    None => return None
  }
  let lambda_types : Map[String, Expr?] = Map([])
  for e in expressions {
    lambda_types[e.name()] = e.arg("to")
  }
  for column in node.find_all([Column]).collect() {
    let parts = column.parts()
    if parts.is_empty() {
      continue
    }
    match lambda_types.get(parts[0].name()) {
      Some(typ) => {
        let mut dot_or_id = if !column.table_name().is_empty() {
          column.to_dot()
        } else {
          column.this().unwrap()
        }
        match typ {
          Some(t) =>
            dot_or_id = self.expression(
              mk(Cast, [("this", dot_or_id), ("to", t)]),
            )
          None => ()
        }
        let mut parent = column.parent
        let mut replaced = false
        while parent is Some(par) && par.kind == Dot {
          let pp_is_dot = match par.parent {
            Some(pp) => pp.kind == Dot
            None => false
          }
          if !pp_is_dot {
            par.replace(Some(dot_or_id)) |> ignore
            replaced = true
            break
          }
          parent = par.parent
        }
        if !replaced {
          if physical_equal(column, node) {
            node = dot_or_id
          } else {
            column.replace(Some(dot_or_id)) |> ignore
          }
        }
      }
      None => ()
    }
  }
  Some(node)
}
