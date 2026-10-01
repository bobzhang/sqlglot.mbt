// Callable class attributes of the base Generator: TRANSFORMS,
// AFTER_HAVING_MODIFIER_TRANSFORMS, JSON_PATH_PART_TRANSFORMS, plus related tables.

///|
/// `exp.Properties.PROPERTY_TO_NAME`.
pub let property_to_name : Map[Kind, String] = {
  let m : Map[Kind, String] = Map([])
  m[AlgorithmProperty] = "ALGORITHM"
  m[AutoIncrementProperty] = "AUTO_INCREMENT"
  m[CharacterSetProperty] = "CHARACTER SET"
  m[ClusteredByProperty] = "CLUSTERED_BY"
  m[CollateProperty] = "COLLATE"
  m[SchemaCommentProperty] = "COMMENT"
  m[CredentialsProperty] = "CREDENTIALS"
  m[DefinerProperty] = "DEFINER"
  m[DistKeyProperty] = "DISTKEY"
  m[DistributedByProperty] = "DISTRIBUTED_BY"
  m[DistStyleProperty] = "DISTSTYLE"
  m[EngineProperty] = "ENGINE"
  m[ExecuteAsProperty] = "EXECUTE AS"
  m[FileFormatProperty] = "FORMAT"
  m[LanguageProperty] = "LANGUAGE"
  m[LocationProperty] = "LOCATION"
  m[LockProperty] = "LOCK"
  m[PartitionedByProperty] = "PARTITIONED_BY"
  m[ReturnsProperty] = "RETURNS"
  m[RowFormatProperty] = "ROW_FORMAT"
  m[SortKeyProperty] = "SORTKEY"
  m[EncodeProperty] = "ENCODE"
  m[IncludeProperty] = "INCLUDE"
  m
}

///|
/// `TSQL.CONVERT_FORMAT_MAPPING` (used by the base `convert_sql`).
pub let tsql_convert_format_mapping : Map[String, String] = Map::from_array([
  ("0", "%b %d %Y %-I:%M%p"),
  ("1", "%m/%d/%y"),
  ("2", "%y.%m.%d"),
  ("3", "%d/%m/%y"),
  ("4", "%d.%m.%y"),
  ("5", "%d-%m-%y"),
  ("6", "%d %b %y"),
  ("7", "%b %d, %y"),
  ("8", "%H:%M:%S"),
  ("9", "%b %d %Y %-I:%M:%S:%f%p"),
  ("10", "mm-dd-yy"),
  ("11", "yy/mm/dd"),
  ("12", "yymmdd"),
  ("13", "%d %b %Y %H:%M:ss:%f"),
  ("14", "%H:%M:%S:%f"),
  ("20", "%Y-%m-%d %H:%M:%S"),
  ("21", "%Y-%m-%d %H:%M:%S.%f"),
  ("22", "%m/%d/%y %-I:%M:%S %p"),
  ("23", "%Y-%m-%d"),
  ("24", "%H:%M:%S"),
  ("25", "%Y-%m-%d %H:%M:%S.%f"),
  ("100", "%b %d %Y %-I:%M%p"),
  ("101", "%m/%d/%Y"),
  ("102", "%Y.%m.%d"),
  ("103", "%d/%m/%Y"),
  ("104", "%d.%m.%Y"),
  ("105", "%d-%m-%Y"),
  ("106", "%d %b %Y"),
  ("107", "%b %d, %Y"),
  ("108", "%H:%M:%S"),
  ("109", "%b %d %Y %-I:%M:%S:%f%p"),
  ("110", "%m-%d-%Y"),
  ("111", "%Y/%m/%d"),
  ("112", "%Y%m%d"),
  ("113", "%d %b %Y %H:%M:%S:%f"),
  ("114", "%H:%M:%S:%f"),
  ("120", "%Y-%m-%d %H:%M:%S"),
  ("121", "%Y-%m-%d %H:%M:%S.%f"),
  ("126", "%Y-%m-%dT%H:%M:%S.%f"),
])

///|
/// `sqlglot.dialects.dialect.WEEK_START_DAY_TO_DOW`.
pub let gen_week_start_day_to_dow : Map[String, Int] = Map::from_array([
  ("MONDAY", 1),
  ("TUESDAY", 2),
  ("WEDNESDAY", 3),
  ("THURSDAY", 4),
  ("FRIDAY", 5),
  ("SATURDAY", 6),
  ("SUNDAY", 7),
])

///|
/// `sqlglot.dialects.dialect.week_offset_to_dow`.
pub fn gen_week_offset_to_dow(offset : Int) -> Int {
  let m = offset % 7
  (if m < 0 { m + 7 } else { m }) + 1
}

///|
/// `sqlglot.jsonpath.JSON_PATH_PART_TRANSFORMS`.
pub fn json_path_part_transforms() -> Map[Kind, GenFn] {
  let t : Map[Kind, GenFn] = Map([])
  t[JSONPathFilter] = (_g, e) => "?" + py_str_value(e.get("this"))
  t[JSONPathKey] = (g, e) => g.jsonpathkey_sql(e)
  t[JSONPathRecursive] = (_g, e) => {
    match e.get("this") {
      Some(v) if v.truthy() => ".." + py_str_value(Some(v))
      _ => ".."
    }
  }
  t[JSONPathRoot] = (_g, _e) => "$"
  t[JSONPathScript] = (_g, e) => "(" + py_str_value(e.get("this"))
  t[JSONPathSelector] = (g, e) => "[" + g.json_path_part(e.get("this")) + "]"
  t[JSONPathSlice] = (g, e) => {
    let parts = []
    for k in ["start", "end", "step"] {
      match e.get(k) {
        None => ()
        Some(Bool(false)) => parts.push("")
        Some(v) => parts.push(g.json_path_part(Some(v)))
      }
    }
    parts.join(":")
  }
  t[JSONPathSubscript] = (g, e) => g.jsonpathsubscript_sql(e)
  t[JSONPathUnion] = (g, e) => {
    let parts = []
    for p in e.raw_list("expressions") {
      parts.push(g.json_path_part(Some(p)))
    }
    "[" + parts.join(",") + "]"
  }
  t[JSONPathWildcard] = (_g, _e) => "*"
  t
}

///|
/// The base Generator's `TRANSFORMS`.
pub fn base_generator_transforms() -> Map[Kind, GenFn] {
  let t = json_path_part_transforms()
  t[Adjacent] = (g, e) => g.binary(e, "-|-")
  t[AllowedValuesProperty] = (g, e) => {
    "ALLOWED_VALUES " + g.expressions(expression=e, flat=true)
  }
  t[AnalyzeColumns] = (g, e) => g.sql_key(e, "this")
  t[AnalyzeWith] = (g, e) => {
    g.expressions(expression=e, prefix="WITH ", sep=" ")
  }
  t[ArrayContainedBy] = (g, e) => g.binary(e, "<@")
  t[ArrayContainsAll] = (g, e) => g.binary(e, "@>")
  t[ArrayOverlaps] = (g, e) => g.binary(e, "&&")
  t[AssumeColumnConstraint] = (g, e) => "ASSUME (" + g.sql_key(e, "this") + ")"
  t[AutoRefreshProperty] = (g, e) => "AUTO REFRESH " + g.sql_key(e, "this")
  t[BackupProperty] = (g, e) => "BACKUP " + g.sql_key(e, "this")
  t[BinaryColumnConstraint] = (_g, _e) => "BINARY"
  t[CaseSpecificColumnConstraint] = (_g, e) => {
    (if e.has("not_") { "NOT " } else { "" }) + "CASESPECIFIC"
  }
  t[CalledOnNullInputProperty] = (_g, _e) => "CALLED ON NULL INPUT"
  t[Ceil] = (g, e) => g.ceil_floor(e)
  t[CharacterSetColumnConstraint] = (g, e) => {
    "CHARACTER SET " + g.sql_key(e, "this")
  }
  t[CharacterSetProperty] = (g, e) => {
    (if e.has("default") { "DEFAULT " } else { "" }) +
    "CHARACTER SET=" +
    g.sql_key(e, "this")
  }
  t[ClusteredColumnConstraint] = (g, e) => {
    "CLUSTERED (" + g.expressions(expression=e, key="this", indent=false) + ")"
  }
  t[CollateColumnConstraint] = (g, e) => "COLLATE " + g.sql_key(e, "this")
  t[CommentColumnConstraint] = (g, e) => "COMMENT " + g.sql_key(e, "this")
  t[ConnectByRoot] = (g, e) => "CONNECT_BY_ROOT " + g.sql_key(e, "this")
  t[ConvertToCharset] = (g, e) => {
    g.func("CONVERT", [e.get("this"), e.get("dest"), e.get("source")])
  }
  t[CopyGrantsProperty] = (_g, _e) => "COPY GRANTS"
  t[CredentialsProperty] = (g, e) => {
    "CREDENTIALS=(" +
    g.expressions(expression=e, key="expressions", sep=" ") +
    ")"
  }
  t[CurrentCatalog] = (_g, _e) => "CURRENT_CATALOG"
  t[SessionUser] = (_g, _e) => "SESSION_USER"
  t[DateFormatColumnConstraint] = (g, e) => "FORMAT " + g.sql_key(e, "this")
  t[DefaultColumnConstraint] = (g, e) => "DEFAULT " + g.sql_key(e, "this")
  t[ApiProperty] = (_g, _e) => "API"
  t[ApplicationProperty] = (_g, _e) => "APPLICATION"
  t[CatalogProperty] = (_g, _e) => "CATALOG"
  t[ComputeProperty] = (_g, _e) => "COMPUTE"
  t[DatabaseProperty] = (_g, _e) => "DATABASE"
  t[DynamicProperty] = (_g, _e) => "DYNAMIC"
  t[EmptyProperty] = (_g, _e) => "EMPTY"
  t[EncodeColumnConstraint] = (g, e) => "ENCODE " + g.sql_key(e, "this")
  t[EndStatement] = (_g, _e) => "END"
  t[EnviromentProperty] = (g, e) => {
    "ENVIRONMENT (" + g.expressions(expression=e, flat=true) + ")"
  }
  t[HandlerProperty] = (g, e) => "HANDLER " + g.sql_key(e, "this")
  t[ParameterStyleProperty] = (g, e) => {
    "PARAMETER STYLE " + g.sql_key(e, "this")
  }
  t[EphemeralColumnConstraint] = (g, e) => {
    "EPHEMERAL" +
    (match e.get("this") {
      Some(v) if v.truthy() => " " + g.sql_key(e, "this")
      _ => ""
    })
  }
  t[ExcludeColumnConstraint] = (g, e) => {
    "EXCLUDE " + py_lstrip(g.sql_key(e, "this"))
  }
  t[ExecuteAsProperty] = (g, e) => g.naked_property(e)
  t[Except] = (g, e) => g.set_operations(e)
  t[ExternalProperty] = (_g, _e) => "EXTERNAL"
  t[Floor] = (g, e) => g.ceil_floor(e)
  t[Get] = (g, e) => g.get_put_sql(e)
  t[GlobalProperty] = (_g, _e) => "GLOBAL"
  t[HeapProperty] = (_g, _e) => "HEAP"
  t[HybridProperty] = (_g, _e) => "HYBRID"
  t[IcebergProperty] = (_g, _e) => "ICEBERG"
  t[InheritsProperty] = (g, e) => {
    "INHERITS (" + g.expressions(expression=e, flat=true) + ")"
  }
  t[InlineLengthColumnConstraint] = (g, e) => {
    "INLINE LENGTH " + g.sql_key(e, "this")
  }
  t[InputModelProperty] = (g, e) => "INPUT" + g.sql_key(e, "this")
  t[Intersect] = (g, e) => g.set_operations(e)
  t[IntervalSpan] = (g, e) => {
    g.sql_key(e, "this") + " TO " + g.sql_key(e, "expression")
  }
  t[Int64] = (g, e) => g.sql(Some(exp_cast(e.this_(), DType::BIGINT)))
  t[JSONBContainsAnyTopKeys] = (g, e) => g.binary(e, "?|")
  t[JSONBContainsAllTopKeys] = (g, e) => g.binary(e, "?&")
  t[JSONBContainsTopKey] = (g, e) => g.binary(e, "?")
  t[JSONBDeleteAtPath] = (g, e) => g.binary(e, "#-")
  t[JSONBPathExists] = (g, e) => g.binary(e, "@?")
  t[JSONObject] = (g, e) => g.jsonobject_sql(e)
  t[JSONObjectAgg] = (g, e) => g.jsonobject_sql(e)
  t[LanguageProperty] = (g, e) => g.naked_property(e)
  t[LocationProperty] = (g, e) => g.naked_property(e)
  t[LogProperty] = (_g, e) => (if e.has("no") { "NO " } else { "" }) + "LOG"
  t[MaskingProperty] = (_g, _e) => "MASKING"
  t[MaterializedProperty] = (_g, _e) => "MATERIALIZED"
  t[NetFunc] = (g, e) => "NET." + g.sql_key(e, "this")
  t[NetworkProperty] = (_g, _e) => "NETWORK"
  t[NonClusteredColumnConstraint] = (g, e) => {
    "NONCLUSTERED (" +
    g.expressions(expression=e, key="this", indent=false) +
    ")"
  }
  t[NoPrimaryIndexProperty] = (_g, _e) => "NO PRIMARY INDEX"
  t[NotForReplicationColumnConstraint] = (_g, _e) => "NOT FOR REPLICATION"
  t[OnCommitProperty] = (_g, e) => {
    "ON COMMIT " +
    (if e.has("delete") { "DELETE" } else { "PRESERVE" }) +
    " ROWS"
  }
  t[OnProperty] = (g, e) => "ON " + g.sql_key(e, "this")
  t[OnUpdateColumnConstraint] = (g, e) => "ON UPDATE " + g.sql_key(e, "this")
  t[Operator] = (g, e) => g.binary(e, "")
  t[OutputModelProperty] = (g, e) => "OUTPUT" + g.sql_key(e, "this")
  t[ExtendsLeft] = (g, e) => g.binary(e, "&<")
  t[ExtendsRight] = (g, e) => g.binary(e, "&>")
  t[PathColumnConstraint] = (g, e) => "PATH " + g.sql_key(e, "this")
  t[PartitionedByBucket] = (g, e) => {
    g.func("BUCKET", [e.get("this"), e.get("expression")])
  }
  t[PartitionByTruncate] = (g, e) => {
    g.func("TRUNCATE", [e.get("this"), e.get("expression")])
  }
  t[PivotAny] = (g, e) => "ANY" + g.sql_key(e, "this")
  t[PositionalColumn] = (g, e) => "#" + g.sql_key(e, "this")
  t[ProjectionPolicyColumnConstraint] = (g, e) => {
    "PROJECTION POLICY " + g.sql_key(e, "this")
  }
  t[InvisibleColumnConstraint] = (_g, _e) => "INVISIBLE"
  t[ZeroFillColumnConstraint] = (_g, _e) => "ZEROFILL"
  t[Put] = (g, e) => g.get_put_sql(e)
  t[RemoteWithConnectionModelProperty] = (g, e) => {
    "REMOTE WITH CONNECTION " + g.sql_key(e, "this")
  }
  t[ReturnsProperty] = (g, e) => {
    if e.has("null") {
      "RETURNS NULL ON NULL INPUT"
    } else {
      g.naked_property(e)
    }
  }
  t[RowAccessProperty] = (_g, _e) => "ROW ACCESS"
  t[SafeFunc] = (g, e) => "SAFE." + g.sql_key(e, "this")
  t[SampleProperty] = (g, e) => "SAMPLE BY " + g.sql_key(e, "this")
  t[SecureProperty] = (_g, _e) => "SECURE"
  t[SecurityIntegrationProperty] = (_g, _e) => "SECURITY"
  t[SetConfigProperty] = (g, e) => g.sql_key(e, "this")
  t[SetProperty] = (_g, e) => {
    (if e.has("multi") { "MULTI" } else { "" }) + "SET"
  }
  t[SettingsProperty] = (g, e) => {
    "SETTINGS" + g.seg("") + g.expressions(expression=e)
  }
  t[SharingProperty] = (g, e) => "SHARING=" + g.sql_key(e, "this")
  t[SqlReadWriteProperty] = (_g, e) => e.name()
  t[SqlSecurityProperty] = (g, e) => "SQL SECURITY " + g.sql_key(e, "this")
  t[StabilityProperty] = (_g, e) => e.name()
  t[Stream] = (g, e) => "STREAM " + g.sql_key(e, "this")
  t[StreamingTableProperty] = (_g, _e) => "STREAMING"
  t[StrictProperty] = (_g, _e) => "STRICT"
  t[SwapTable] = (g, e) => "SWAP WITH " + g.sql_key(e, "this")
  t[TableColumn] = (g, e) => g.sql(e.this())
  t[Tags] = (g, e) => "TAG (" + g.expressions(expression=e, flat=true) + ")"
  t[TemporaryProperty] = (_g, _e) => "TEMPORARY"
  t[TitleColumnConstraint] = (g, e) => "TITLE " + g.sql_key(e, "this")
  t[ToMap] = (g, e) => "MAP " + g.sql_key(e, "this")
  t[ToTableProperty] = (g, e) => "TO " + g.sql(e.this())
  t[TransformModelProperty] = (g, e) => {
    g.func("TRANSFORM", e.expressions().map(x => (x : &SqlArg)))
  }
  t[TransientProperty] = (_g, _e) => "TRANSIENT"
  t[VirtualProperty] = (_g, _e) => "VIRTUAL"
  t[TriggerExecute] = (g, e) => "EXECUTE FUNCTION " + g.sql_key(e, "this")
  t[Union] = (g, e) => g.set_operations(e)
  t[UnloggedProperty] = (_g, _e) => "UNLOGGED"
  t[UsingTemplateProperty] = (g, e) => "USING TEMPLATE " + g.sql_key(e, "this")
  t[UsingData] = (g, e) => "USING DATA " + g.sql_key(e, "this")
  t[UppercaseColumnConstraint] = (_g, _e) => "UPPERCASE"
  t[UtcDate] = (g, _e) => g.sql(Some(mk1(CurrentDate, literal_string("UTC"))))
  t[UtcTime] = (g, _e) => g.sql(Some(mk1(CurrentTime, literal_string("UTC"))))
  t[UtcTimestamp] = (g, _e) => {
    g.sql(Some(mk1(CurrentTimestamp, literal_string("UTC"))))
  }
  t[Variadic] = (g, e) => "VARIADIC " + g.sql_key(e, "this")
  t[VarMap] = (g, e) => g.func("MAP", [e.get("keys"), e.get("values")])
  t[ViewAttributeProperty] = (g, e) => "WITH " + g.sql_key(e, "this")
  t[VolatileProperty] = (_g, _e) => "VOLATILE"
  t[WithJournalTableProperty] = (g, e) => {
    "WITH JOURNAL TABLE=" + g.sql_key(e, "this")
  }
  t[WithProcedureOptions] = (g, e) => {
    "WITH " + g.expressions(expression=e, flat=true)
  }
  t[WithSchemaBindingProperty] = (g, e) => "WITH SCHEMA " + g.sql_key(e, "this")
  t[WithOperator] = (g, e) => {
    g.sql_key(e, "this") + " WITH " + g.sql_key(e, "op")
  }
  t[ForceProperty] = (_g, _e) => "FORCE"
  t
}

///|
/// The base Generator's `AFTER_HAVING_MODIFIER_TRANSFORMS`.
pub fn base_after_having_modifier_transforms() -> Array[(String, GenFn)] {
  [
    ("cluster", (g, e) => g.sql_key(e, "cluster")),
    ("distribute", (g, e) => g.sql_key(e, "distribute")),
    ("sort", (g, e) => g.sql_key(e, "sort")),
    (
      "windows",
      (g, e) => {
        if e.has("windows") {
          g.seg("WINDOW ") +
          g.expressions(expression=e, key="windows", flat=true)
        } else {
          ""
        }
      },
    ),
    ("qualify", (g, e) => g.sql_key(e, "qualify")),
  ]
}

///|
/// The base Generator's TRANSFORMS and other callable tables.
pub fn base_generator_fns() -> GeneratorFns {
  {
    transforms: base_generator_transforms(),
    methods: Map([]),
    hooks: GeneratorHooks::new(),
    type_param_settings: Map([]),
    after_having_modifier_transforms: base_after_having_modifier_transforms(),
  }
}
