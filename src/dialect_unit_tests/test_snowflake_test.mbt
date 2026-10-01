// Direct assertions of tests/dialects/test_snowflake.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
fn sf() -> @core.Dialect raise {
  @sqlglot.dialect("snowflake")
}

///|
/// `annotate_types(expression, dialect="snowflake")`
fn sf_annotate(e : @core.Expr) -> @core.Expr raise {
  @optimizer.annotate_types(e, dialect=sf())
}

///|
test "TestSnowflake.test_snowflake" {
  let t = t(dialect="snowflake")
  let ast = parse_one("BLA(x) FILTER (WHERE x = 5)")
  t.eq(
    sql(ast.this_().assert_is(Anonymous).parent.unwrap(), dialect="snowflake"),
    "BLA(IFF(x = 5, x, NULL))",
  )
  let ast = t.parse_one("DATEADD(DAY, n, d)")
  ast.set("unit", @core.literal_string("MONTH"))
  t.eq(sql(ast, dialect="snowflake"), "DATEADD(MONTH, n, d)")
  t.eq(
    sql(t.validate_identity("SELECT TRY_PARSE_JSON('{\"x: 1}')")),
    "SELECT PARSE_JSON('{\"x: 1}')",
  )
  t.validate_identity("APPROX_TOP_K(C4, 3, 5)").assert_is(AggFunc) |> ignore
  let ast = t.validate_identity(
    "SELECT RPAD(TO_BINARY('Hi', 'UTF8'), 10, TO_BINARY('_', 'UTF8'))",
  )
  let annotated = sf_annotate(ast)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SELECT ENCODE('Hi') || REPEAT(ENCODE('_'), GREATEST(0, 10 - OCTET_LENGTH(ENCODE('Hi'))))",
  )
  let expr = t.validate_identity("RIGHT('GAJGSKD', 2)")
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "CASE WHEN 2 < 0 THEN '' ELSE RIGHT('GAJGSKD', 2) END",
  )
  let expr = t.validate_identity("RIGHT(TO_BINARY('SNOWIKOPN', 'utf-8'), ABS(-3))")
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "CASE WHEN ABS(-3) < 0 THEN UNHEX('') ELSE UNHEX(RIGHT(HEX(ENCODE('SNOWIKOPN')), ABS(-3) * 2)) END",
  )
  t.validate_identity("SELECT number").selects()[0].assert_is(Column) |> ignore
  t.validate_identity("SELECT TO_TIMESTAMP(123.4)").selects()[0].assert_is(
    Anonymous,
  )
  |> ignore
  // TO_NUMBER / TRY_TO_NUMBER: (sql, format, precision, scale, safe)
  for case in [
    ("TO_NUMBER('12.3456')", None, "38", "0", false),
    ("TO_NUMBER('12.3456', 10, 1)", None, "10", "1", false),
    ("TO_NUMBER('12.3456', '99.99')", Some("99.99"), "38", "0", false),
    ("TO_NUMBER('12.3456', '99.99', 10, 1)", Some("99.99"), "10", "1", false),
    ("TO_NUMBER('12.3456', 3)", None, "3", "0", false),
    ("TRY_TO_NUMBER('12.3456')", None, "38", "0", true),
    ("TRY_TO_NUMBER('12.3456', 10, 1)", None, "10", "1", true),
    ("TRY_TO_NUMBER('12.3456', '99.99')", Some("99.99"), "38", "0", true),
    ("TRY_TO_NUMBER('12.3456', '99.99', 10, 1)", Some("99.99"), "10", "1", true),
    ("TRY_TO_NUMBER('12.3456', 3)", None, "3", "0", true),
  ] {
    let (q, format, precision, scale, safe) = case
    let ast = t.validate_identity(q)
    t.ok(ast.kind.is_a(ToNumber), msg="\{q}: not a ToNumber")
    match format {
      None => t.ok(ast.get("format") is None, msg="\{q}: format is not None")
      Some(f) => t.eq(b_name(ast.arg("format")), f)
    }
    t.eq(b_name(ast.arg("precision")), precision)
    t.eq(b_name(ast.arg("scale")), scale)
    if safe {
      t.ok(ast.bool_arg("safe"), msg="\{q}: safe is not set")
    }
  }
  for case in [
    ("SELECT * FROM IDENTIFIER(:tbl)", "tbl"),
    ("SELECT * FROM IDENTIFIER($tbl)", "tbl"),
    ("SELECT * FROM IDENTIFIER('mytable')", "mytable"),
  ] {
    let (q, name) = case
    let table = t.validate_identity(q).find([Table]).unwrap()
    t.ok(table.this_().kind.is_a(DynamicIdentifier), msg="\{q}: not dynamic")
    t.eq(table.name(), name)
  }
  t.raises(
    () => ignore(
      parse_one("OBJECT_CONSTRUCT_KEEP_NULL(t.*, 'a', 1)", read="snowflake"),
    ),
    "ParseError",
  )
  |> ignore
  t
  .validate_identity(
    "SELECT DATEADD(DAY, -7, DATEADD(t.m, 1, CAST('2023-01-03' AS DATE))) FROM (SELECT 'month' AS m) AS t",
  )
  .selects()[0]
  .this_()
  .arg("unit")
  .unwrap()
  .assert_is(Column)
  |> ignore
  t
  .validate_identity(
    "SELECT FILE_URL FROM DIRECTORY(@mystage) WHERE SIZE > 100000",
  )
  .arg("from_")
  .unwrap()
  .this_()
  .this_()
  .assert_is(DirectoryStage)
  .this_()
  .assert_is(Var)
  |> ignore
  t.validate_identity("TRY_TO_TIMESTAMP(foo)").assert_is(Anonymous) |> ignore
  t.validate_identity("TRY_TO_TIMESTAMP('12345')").assert_is(Anonymous)
  |> ignore
  t.raises(
    () => ignore(
      parse_one(
        "SELECT id, PRIOR name AS parent_name, name FROM tree CONNECT BY NOCYCLE PRIOR id = parent_id",
        read="snowflake",
      ),
    ),
    "ParseError",
  )
  |> ignore
  let expr = t.validate_identity("SELECT BASE64_ENCODE('Hello World')")
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SELECT TO_BASE64(ENCODE('Hello World'))",
  )
  t.done()
}

///|
test "TestSnowflake.test_pivot_output_column_names" {
  let t = t(dialect="snowflake")
  for case in [
    ("IN ('a', 'b')", ["ID", "'a'", "'b'"]),
    ("IN ('a' AS a, 'b' AS b)", ["ID", "A", "B"]),
  ] {
    let (pivot, expected) = case
    let expression = @optimizer.qualify(
      t.parse_one("SELECT * FROM t PIVOT(SUM(val) FOR cat \{pivot})"),
      schema=@optimizer.ensure_schema(
        mapping=@optimizer.schema_from_json_string(
          "{\"t\": {\"id\": \"int\", \"cat\": \"text\", \"val\": \"int\"}}",
        ),
        dialect=sf(),
      ),
      dialect=sf(),
    )
    t.eq(
      b_list(expression.selects().map(s => s.alias_or_name())),
      b_list(expected),
    )
  }
  t.done()
}

///|
test "TestSnowflake.test_staged_files" {
  let t = t(dialect="snowflake")
  let staged_file = parse_one("SELECT * FROM @foo", read="snowflake")
  t.eq(
    sql(
      @optimizer.normalize_identifiers(staged_file, dialect=sf()),
      dialect="snowflake",
    ),
    sql(staged_file, dialect="snowflake"),
  )
  t.done()
}

///|
test "TestSnowflake.test_ddl" {
  let t = t(dialect="snowflake")
  t.validate_identity("CREATE WAREHOUSE x").this_().assert_is(Identifier)
  |> ignore
  t.validate_identity("CREATE STREAMLIT x").this_().assert_is(Identifier)
  |> ignore
  t
  .validate_identity(
    "CREATE TEMPORARY STAGE stage1 FILE_FORMAT=(TYPE=PARQUET)",
  )
  .this_()
  .assert_is(Table)
  |> ignore
  t.raises(
    () => ignore(t.parse_one("CREATE STAGE stage1 FILE_FORMAT=123")),
    "ParseError",
  )
  |> ignore
  t
  .validate_identity(
    "CREATE OR REPLACE TAG IF NOT EXISTS cost_center COMMENT='cost_center tag'",
  )
  .this_()
  .assert_is(Identifier)
  |> ignore
  t
  .validate_identity(
    "CREATE TEMPORARY FILE FORMAT fileformat1 TYPE=PARQUET COMPRESSION=auto",
  )
  .this_()
  .assert_is(Table)
  |> ignore
  t
  .validate_identity(
    "CREATE OR REPLACE FUNCTION ibis_udfs.public.object_values(\"obj\" OBJECT) RETURNS ARRAY LANGUAGE JAVASCRIPT RETURNS NULL ON NULL INPUT AS ' return Object.values(obj) '",
  )
  .assert_is(Create)
  |> ignore
  t.done()
}

///|
test "TestSnowflake.test_rollback_as_identifier" {
  let t = t(dialect="snowflake")
  t.ok(t.parse_one("ROLLBACK WORK").kind.is_a(Rollback))
  t.done()
}

///|
test "TestSnowflake.test_flatten" {
  let t = t(dialect="snowflake")
  t.eq(
    sql(
      @sqlglot.select([
        @core.mk(Explode, [("this", @sqlglot.column("x"))]).as_("y", quoted=true),
      ]),
      dialect="snowflake",
      pretty=true,
    ),
    "SELECT\n  IFF(_u.pos = _u_2.pos_2, _u_2.\"y\", NULL) AS \"y\"\nFROM TABLE(FLATTEN(INPUT => ARRAY_GENERATE_RANGE(0, (\n  GREATEST(ARRAY_SIZE(x)) - 1\n) + 1))) AS _u(seq, key, path, index, pos, this)\nCROSS JOIN TABLE(FLATTEN(INPUT => x)) AS _u_2(seq, key, path, pos_2, \"y\", this)\nWHERE\n  _u.pos = _u_2.pos_2\n  OR (\n    _u.pos > (\n      ARRAY_SIZE(x) - 1\n    ) AND _u_2.pos_2 = (\n      ARRAY_SIZE(x) - 1\n    )\n  )",
  )
  t.done()
}

///|
test "TestSnowflake.test_values" {
  let t = t(dialect="snowflake")
  let select = @sqlglot.select(["*"]).from_("values (map(['a'], [1]))")
  t.eq(
    sql(select, dialect="snowflake"),
    "SELECT * FROM (SELECT OBJECT_CONSTRUCT('a', 1))",
  )
  t.done()
}

///|
test "TestSnowflake.test_describe" {
  let t = t(dialect="snowflake")
  for case in [
    ("DYNAMIC TABLE", "db.schema.t1", @core.Kind::DynamicProperty),
    ("MATERIALIZED VIEW", "my_view", MaterializedProperty),
    ("EXTERNAL VOLUME", "vol1", ExternalProperty),
    ("COMPUTE POOL", "pool1", ComputeProperty),
    ("MASKING POLICY", "db.schema.pol1", MaskingProperty),
    ("ROW ACCESS POLICY", "pol1", RowAccessProperty),
    ("API INTEGRATION", "int1", ApiProperty),
    ("APPLICATION PACKAGE", "pkg1", ApplicationProperty),
    ("SECURITY INTEGRATION", "int1", SecurityIntegrationProperty),
    ("NETWORK RULE", "rule1", NetworkProperty),
    ("ICEBERG TABLE", "db.schema.t1", IcebergProperty),
    ("HYBRID TABLE", "t1", HybridProperty),
    ("CATALOG INTEGRATION", "int1", CatalogProperty),
    ("DATABASE ROLE", "role1", DatabaseProperty),
  ] {
    let (kind, object_name, prop_type) = case
    let ast = t.validate_identity("DESCRIBE \{kind} \{object_name}")
    let words = kind.split(" ").to_array()
    t.eq(b_str(ast.get("kind")), words[words.length() - 1].to_owned())
    t.ok(ast.find([prop_type]) is Some(_), msg="\{kind}: no \{prop_type}")
  }
  t.done()
}

///|
test "TestSnowflake.test_regexp_functions" {
  let t = t(dialect="snowflake")
  let ast = t.validate_identity("SELECT SEARCH(line, 'king')")
  let search_ast = ast.find([Search]).unwrap()
  t.eq(
    b_list(search_ast.args.keys().collect()),
    b_list(["this", "expression"]),
  )
  t.ok(search_ast.get("analyzer") is None)
  t.ok(search_ast.get("search_mode") is None)
  let ast = t.validate_identity(
    "SELECT SEARCH(line, 'king', ANALYZER => 'UNICODE_ANALYZER')",
  )
  let search_ast = ast.find([Search]).unwrap()
  t.ok(search_ast.get("analyzer") is Some(_))
  t.ok(search_ast.get("search_mode") is None)
  let ast = t.validate_identity(
    "SELECT SEARCH(character, 'king queen', SEARCH_MODE => 'AND')",
  )
  let search_ast = ast.find([Search]).unwrap()
  t.ok(search_ast.get("analyzer") is None)
  t.ok(search_ast.get("search_mode") is Some(_))
  let ast = t.validate_identity(
    "SELECT SEARCH(line, 'king', SEARCH_MODE => 'AND', ANALYZER => 'PATTERN_ANALYZER')",
    write_sql="SELECT SEARCH(line, 'king', ANALYZER => 'PATTERN_ANALYZER', SEARCH_MODE => 'AND')",
  )
  let search_ast = ast.find([Search]).unwrap()
  t.eq(
    b_list(search_ast.args.keys().collect()),
    b_list(["this", "expression", "search_mode", "analyzer"]),
  )
  let analyzer = search_ast.get("analyzer")
  t.ok(analyzer is Some(_))
  let search_mode = search_ast.get("search_mode")
  t.ok(search_mode is Some(_))
  t.validate_identity("SELECT SEARCH_IP(col, '192.168.0.0')").selects()[0].assert_is(
    SearchIp,
  )
  |> ignore
  t.done()
}

///|
test "TestSnowflake.test_show_databases" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW DATABASES IN ACCOUNT", read="snowflake")
  t.eq(b_str(ast.get("this")), "DATABASES")
  t.eq(b_str(ast.get("scope_kind")), "ACCOUNT")
  t.done()
}

///|
test "TestSnowflake.test_show_file_formats" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW FILE FORMATS IN ACCOUNT", read="snowflake")
  t.eq(b_str(ast.get("this")), "FILE FORMATS")
  t.eq(b_str(ast.get("scope_kind")), "ACCOUNT")
  t.done()
}

///|
test "TestSnowflake.test_show_functions" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW FUNCTIONS IN ACCOUNT", read="snowflake")
  t.eq(b_str(ast.get("this")), "FUNCTIONS")
  t.eq(b_str(ast.get("scope_kind")), "ACCOUNT")
  t.done()
}

///|
test "TestSnowflake.test_show_procedures" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW PROCEDURES IN ACCOUNT", read="snowflake")
  t.eq(b_str(ast.get("this")), "PROCEDURES")
  t.eq(b_str(ast.get("scope_kind")), "ACCOUNT")
  t.done()
}

///|
test "TestSnowflake.test_show_stages" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW STAGES IN ACCOUNT", read="snowflake")
  t.eq(b_str(ast.get("this")), "STAGES")
  t.eq(b_str(ast.get("scope_kind")), "ACCOUNT")
  t.done()
}

///|
test "TestSnowflake.test_show_warehouses" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW WAREHOUSES", read="snowflake")
  t.eq(b_str(ast.get("this")), "WAREHOUSES")
  t.done()
}

///|
test "TestSnowflake.test_show_schemas" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW SCHEMAS IN DATABASE db1", read="snowflake")
  t.eq(b_str(ast.get("scope_kind")), "DATABASE")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1")
  t.done()
}

///|
test "TestSnowflake.test_show_objects" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW OBJECTS IN db1.schema1", read="snowflake")
  t.eq(b_str(ast.get("scope_kind")), "SCHEMA")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1.schema1")
  t.done()
}

///|
test "TestSnowflake.test_show_columns" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW COLUMNS LIKE '_testing%' IN dt_test", read="snowflake")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "dt_test")
  t.eq(sql(ast.find([Literal]).unwrap(), dialect="snowflake"), "'_testing%'")
  t.done()
}

///|
test "TestSnowflake.test_show_tables" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW TABLES IN db1.schema1", read="snowflake")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1.schema1")
  t.ok(!ast.bool_arg("iceberg"))
  let ast = parse_one("SHOW ICEBERG TABLES IN db1.schema1", read="snowflake")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1.schema1")
  t.ok(ast.bool_arg("iceberg"))
  let ast = parse_one("SHOW TERSE ICEBERG TABLES IN db1.schema1", read="snowflake")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1.schema1")
  t.ok(ast.bool_arg("terse"))
  t.ok(ast.bool_arg("iceberg"))
  t.done()
}

///|
test "TestSnowflake.test_alter_iceberg_table" {
  let t = t(dialect="snowflake")
  let ast = t.validate_identity("ALTER ICEBERG TABLE t RENAME TO x")
  t.ok(ast.bool_arg("iceberg"))
  // the parser warning is mocked away in Python
  let ast = parse_one("ALTER ICEBERG VIEW v RENAME TO x", read="snowflake")
  @core.take_log_messages() |> ignore
  t.ok(ast.kind.is_a(Command))
  t.done()
}

///|
test "TestSnowflake.test_drop_iceberg_table" {
  let t = t(dialect="snowflake")
  let ast = t.validate_identity("DROP ICEBERG TABLE t")
  t.ok(ast.bool_arg("iceberg"))
  let ast = t.validate_identity("DROP ICEBERG TABLE t RESTRICT")
  t.ok(ast.bool_arg("restrict"))
  t.done()
}

///|
test "TestSnowflake.test_show_primary_keys" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW PRIMARY KEYS IN \"TEST\".\"PUBLIC\".\"foo\"", read="snowflake")
  t.eq(
    sql(ast.find([Table]).unwrap(), dialect="snowflake"),
    "\"TEST\".\"PUBLIC\".\"foo\"",
  )
  t.done()
}

///|
test "TestSnowflake.test_show_views" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW VIEWS IN db1.schema1", read="snowflake")
  t.eq(sql(ast.find([Table]).unwrap(), dialect="snowflake"), "db1.schema1")
  t.done()
}

///|
test "TestSnowflake.test_show_unique_keys" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW UNIQUE KEYS IN \"TEST\".\"PUBLIC\".\"foo\"", read="snowflake")
  t.eq(
    sql(ast.find([Table]).unwrap(), dialect="snowflake"),
    "\"TEST\".\"PUBLIC\".\"foo\"",
  )
  t.done()
}

///|
test "TestSnowflake.test_show_imported_keys" {
  let t = t(dialect="snowflake")
  let ast = parse_one(
    "SHOW IMPORTED KEYS IN \"TEST\".\"PUBLIC\".\"foo\"",
    read="snowflake",
  )
  t.eq(
    sql(ast.find([Table]).unwrap(), dialect="snowflake"),
    "\"TEST\".\"PUBLIC\".\"foo\"",
  )
  t.done()
}

///|
test "TestSnowflake.test_show_sequences" {
  let t = t(dialect="snowflake")
  let ast = parse_one("SHOW SEQUENCES IN dt_test", read="snowflake")
  t.eq(b_str(ast.get("scope_kind")), "SCHEMA")
  t.done()
}

///|
test "TestSnowflake.test_swap" {
  let t = t(dialect="snowflake")
  let ast = parse_one("ALTER TABLE a SWAP WITH b", read="snowflake")
  t.ok(ast.kind.is_a(Alter))
  t.ok(ast.list("actions")[0].kind.is_a(SwapTable))
  t.done()
}

///|
test "TestSnowflake.test_try_cast" {
  let t = t(dialect="snowflake")
  let mut expression = parse_one("SELECT CAST(t.x AS STRING) FROM t", read="hive")
  for value_type in ["string", "int"] {
    let func = if value_type == "string" { "TRY_CAST" } else { "CAST" }
    expression = @optimizer.annotate_types(
      expression,
      schema=@optimizer.ensure_schema(
        mapping=@optimizer.schema_from_json_string(
          "{\"t\": {\"x\": \"\{value_type}\"}}",
        ),
      ),
    )
    t.eq(
      sql(expression, dialect="snowflake"),
      "SELECT \{func}(t.x AS VARCHAR) FROM t",
    )
  }
  t.done()
}

///|
test "TestSnowflake.test_copy" {
  let t = t(dialect="snowflake")
  let copy_ast = parse_one(
    "COPY INTO 's3://example/contacts.csv' FROM db.tbl STORAGE_INTEGRATION = PROD_S3_SIDETRADE_INTEGRATION FILE_FORMAT = (FORMAT_NAME=my_csv_format TYPE=CSV COMPRESSION=NONE NULL_IF=('') FIELD_OPTIONALLY_ENCLOSED_BY='\"') MATCH_BY_COLUMN_NAME = CASE_SENSITIVE OVERWRITE = TRUE SINGLE = TRUE INCLUDE_METADATA = (col1 = METADATA$START_SCAN_TIME)",
    read="snowflake",
  )
  t.eq(
    sql(@optimizer.quote_identifiers(copy_ast, dialect=sf()), dialect="snowflake"),
    "COPY INTO 's3://example/contacts.csv' FROM \"db\".\"tbl\" STORAGE_INTEGRATION = \"PROD_S3_SIDETRADE_INTEGRATION\" FILE_FORMAT = (FORMAT_NAME=\"my_csv_format\" TYPE=CSV COMPRESSION=NONE NULL_IF=('') FIELD_OPTIONALLY_ENCLOSED_BY='\"') MATCH_BY_COLUMN_NAME = CASE_SENSITIVE OVERWRITE = TRUE SINGLE = TRUE INCLUDE_METADATA = (\"col1\" = \"METADATA$START_SCAN_TIME\")",
  )
  t.done()
}

///|
/// `{prop.this.this: prop.args["value"].this for prop in properties.expressions}`
/// rendered by `sf_dict` (values rendered by `b_value_repr`).
fn sf_props_dict(ast : @core.Expr) -> String {
  let props = []
  match ast.arg("properties") {
    Some(properties) =>
      for prop in properties.expressions() {
        let key = prop.this_().str_arg("this").unwrap_or("<None>")
        let value = match prop.arg("value") {
          Some(v) => b_value_repr(v.get("this"))
          None => "<no value>"
        }
        props.push((key, value))
      }
    None => ()
  }
  sf_dict(props)
}

///|
/// A dict `{'k': v, ...}` with sorted keys (order-insensitive comparison).
fn sf_dict(pairs : Array[(String, String)]) -> String {
  let items = pairs.map(p => "'\{p.0}': \{p.1}")
  items.sort()
  "{" + items.join(", ") + "}"
}

///|
fn sf_literal(s : String, is_string : Bool) -> @core.Expr {
  @core.mk(Literal, [("this", s), ("is_string", is_string)])
}

///|
fn sf_var(s : String) -> @core.Expr {
  @core.mk(Var, [("this", s)])
}

///|
test "TestSnowflake.test_put_to_stage" {
  let t = t(dialect="snowflake")
  let ast = parse_one("PUT 'file://my file.txt' '@s1/my folder'", read="snowflake")
  t.ok(ast.kind.is_a(Put))
  t.eq_expr(ast.this(), Some(sf_literal("file://my file.txt", true)))
  t.eq_expr(ast.arg("target"), Some(sf_var("'@s1/my folder'")))
  t.eq(sql(ast, dialect="snowflake"), "PUT 'file://my file.txt' '@s1/my folder'")
  let ast = parse_one(
    "PUT 'file:///tmp/my.txt' @stage1/folder PARALLEL = 1 AUTO_COMPRESS=false source_compression=gzip OVERWRITE=TRUE",
    read="snowflake",
  )
  t.ok(ast.kind.is_a(Put))
  t.eq_expr(ast.this(), Some(sf_literal("file:///tmp/my.txt", true)))
  t.eq_expr(ast.arg("target"), Some(sf_var("@stage1/folder")))
  t.eq(
    sf_props_dict(ast),
    sf_dict([
      ("PARALLEL", "'1'"),
      ("AUTO_COMPRESS", "False"),
      ("source_compression", "'gzip'"),
      ("OVERWRITE", "True"),
    ]),
  )
  let ast = t
    .validate_identity(
      "PUT file:///dir/tmp.csv @%table",
      write_sql="PUT 'file:///dir/tmp.csv' @%table",
    )
    .assert_is(Put)
  t.eq_expr(ast.this(), Some(@core.literal_string("file:///dir/tmp.csv")))
  t.eq_expr(ast.arg("target"), Some(sf_var("@%table")))
  t
  .validate_identity(
    "PUT file:///dir/tmp.csv @s1/test PARALLEL=1 AUTO_COMPRESS=FALSE source_compression=gzip OVERWRITE=TRUE",
    write_sql="PUT 'file:///dir/tmp.csv' @s1/test PARALLEL=1 AUTO_COMPRESS=FALSE source_compression=gzip OVERWRITE=TRUE",
  )
  .assert_is(Put)
  |> ignore
  t.done()
}

///|
test "TestSnowflake.test_get_from_stage" {
  let t = t(dialect="snowflake")
  t.validate_identity("GET @s1/test 'file:///dir/tmp.csv'").assert_is(Get)
  |> ignore
  let ast = parse_one("GET '@s1/my folder' 'file://my file.txt'", read="snowflake")
  t.ok(ast.kind.is_a(Get))
  t.eq_expr(ast.arg("target"), Some(sf_var("'@s1/my folder'")))
  t.eq_expr(ast.this(), Some(sf_literal("file://my file.txt", true)))
  t.eq(sql(ast, dialect="snowflake"), "GET '@s1/my folder' 'file://my file.txt'")
  let ast = parse_one(
    "GET @stage1/folder 'file:///tmp/my.txt' PARALLEL = 1",
    read="snowflake",
  )
  t.ok(ast.kind.is_a(Get))
  t.eq_expr(ast.arg("target"), Some(sf_var("@stage1/folder")))
  t.eq_expr(ast.this(), Some(sf_literal("file:///tmp/my.txt", true)))
  t.eq(sf_props_dict(ast), sf_dict([("PARALLEL", "'1'")]))
  t.done()
}

///|
fn sf_ident(name : String) -> @core.Expr {
  @core.mk(Identifier, [("this", name), ("quoted", false)])
}

///|
test "TestSnowflake.test_alter_session" {
  let t = t(dialect="snowflake")
  let expr = t.validate_identity(
    "ALTER SESSION SET autocommit = FALSE, QUERY_TAG = 'qtag', JSON_INDENT = 1",
  )
  let set_item = (name : String, value : @core.Expr) => @core.mk(SetItem, [
    (
      "this",
      @core.mk(EQ, [
        ("this", @core.mk(Column, [("this", sf_ident(name))])),
        ("expression", value),
      ]),
    ),
  ])
  t.eq_expr(
    expr.find([AlterSession]),
    Some(
      @core.mk(AlterSession, [
        (
          "expressions",
          [
            set_item("autocommit", @core.mk(Boolean, [("this", false)])),
            set_item("QUERY_TAG", sf_literal("qtag", true)),
            set_item("JSON_INDENT", sf_literal("1", false)),
          ],
        ),
        ("unset", false),
      ]),
    ),
  )
  let expr = t.validate_identity("ALTER SESSION UNSET autocommit, QUERY_TAG")
  t.eq_expr(
    expr.find([AlterSession]),
    Some(
      @core.mk(AlterSession, [
        (
          "expressions",
          [
            @core.mk(SetItem, [("this", sf_ident("autocommit"))]),
            @core.mk(SetItem, [("this", sf_ident("QUERY_TAG"))]),
          ],
        ),
        ("unset", true),
      ]),
    ),
  )
  t.done()
}

///|
test "TestSnowflake.test_window_function_arg" {
  let t = t(dialect="snowflake")
  let query = "SELECT * FROM TABLE(db.schema.FUNC(a) OVER ())"
  let ast = t.parse_one(query)
  let window = ast.find([Window]).unwrap()
  t.eq(sql(ast, dialect="snowflake"), query)
  t.eq(ast.find_all([Column]).count(), 1)
  t.eq(sql(window.this_(), dialect="snowflake"), "db.schema.FUNC(a)")
  t.done()
}

///|
test "TestSnowflake.test_parameter" {
  let t = t(dialect="snowflake")
  let expr = t.validate_identity("SELECT :1")
  t.eq_expr(expr.find([Placeholder]), Some(@core.mk(Placeholder, [("this", "1")])))
  t.done()
}

///|
test "TestSnowflake.test_max_by_min_by" {
  let t = t(dialect="snowflake")
  let max_by = t.validate_identity("MAX_BY(DISTINCT selected_col, filtered_col)")
  let min_by = t.validate_identity("MIN_BY(DISTINCT selected_col, filtered_col)")
  for node in [max_by, min_by] {
    t.eq(node.this_().expressions().length(), 1)
    t.ok(node.expression() is Some(e) && e.kind.is_a(Column))
  }
  let max_by_3 = t.validate_identity("MAX_BY(selected_col, filtered_col, 5)")
  let min_by_3 = t.validate_identity("MIN_BY(selected_col, filtered_col, 3)")
  for node in [max_by_3, min_by_3] {
    t.ok(node.get("count") is Some(_), msg="\{sql(node, dialect="snowflake")}")
  }
  t.done()
}

///|
test "TestSnowflake.test_create_view_row_access_policy" {
  let t = t(dialect="snowflake")
  t.raises(
    () => ignore(
      parse_one(
        "CREATE VIEW v WITH ROW ACCESS POLICY p AS SELECT 1",
        read="snowflake",
      ),
    ),
    "ParseError",
  )
  |> ignore
  t.eq(
    sql(
      parse_one(
        "CREATE VIEW v WITH ROW ACCESS POLICY #unknown_policy AS SELECT 1",
        read="snowflake",
      ),
      dialect="snowflake",
      identify=true,
    ),
    "CREATE VIEW \"v\" WITH ROW ACCESS POLICY #unknown_policy AS SELECT 1",
  )
  t.done()
}

///|
test "TestSnowflake.test_sha1" {
  let t = t(dialect="snowflake")
  let expr = t.validate_identity("SHA1('text')")
  let annotated = sf_annotate(expr)
  t.eq(sql(annotated, dialect="duckdb"), "SHA1('text')")
  t.eq(sql(annotated, dialect="snowflake"), "SHA1('text')")
  let expr = t.validate_identity("SHA1(123)")
  let annotated = sf_annotate(expr)
  t.eq(sql(annotated, dialect="snowflake"), "SHA1(123)")
  t.eq(sql(annotated, dialect="duckdb"), "SHA1(CAST(123 AS TEXT))")
  let expr = t.validate_identity(
    "SHA1(DATE '2024-01-15')",
    write_sql="SHA1(CAST('2024-01-15' AS DATE))",
  )
  let annotated = sf_annotate(expr)
  t.eq(sql(annotated, dialect="snowflake"), "SHA1(CAST('2024-01-15' AS DATE))")
  t.eq(
    sql(annotated, dialect="duckdb"),
    "SHA1(CAST(CAST('2024-01-15' AS DATE) AS TEXT))",
  )
  t.done()
}

///|
test "TestSnowflake.test_set_item_kind_attribute" {
  let t = t(dialect="snowflake")
  let expr = parse_one("ALTER SESSION SET autocommit = FALSE", read="snowflake")
  let set_item = expr.find([SetItem])
  t.ok(set_item is Some(_))
  t.ok(set_item.unwrap().get("kind") is None)
  let expr = parse_one("SET a = 1", read="snowflake")
  let set_item = expr.find([SetItem])
  t.ok(set_item is Some(_))
  t.eq(b_str(set_item.unwrap().get("kind")), "VARIABLE")
  t.done()
}

///|
test "TestSnowflake.test_get_bit" {
  let t = t(dialect="snowflake")
  let expr = t.validate_identity("GETBIT(11, 1)")
  let annotated = sf_annotate(expr)
  t.eq(sql(annotated, dialect="duckdb"), "(11 >> 1) & 1")
  t.eq(sql(annotated, dialect="postgres"), "11 >> 1 & 1")
  t.done()
}

///|
test "TestSnowflake.test_to_binary" {
  let t = t(dialect="snowflake")
  for case in [
    ("TO_BINARY('48454C50', 'HEX')", "UNHEX('48454C50')"),
    ("TO_BINARY('48454C50')", "UNHEX('48454C50')"),
    ("TO_BINARY('TEST', 'UTF-8')", "ENCODE('TEST')"),
    ("TO_BINARY('SEVMUA==', 'BASE64')", "FROM_BASE64('SEVMUA==')"),
    ("TRY_TO_BINARY('48454C50', 'HEX')", "TRY(UNHEX('48454C50'))"),
    ("TRY_TO_BINARY('48454C50')", "TRY(UNHEX('48454C50'))"),
    ("TRY_TO_BINARY('Hello', 'UTF-8')", "TRY(ENCODE('Hello'))"),
    ("TRY_TO_BINARY('SGVsbG8=', 'BASE64')", "TRY(FROM_BASE64('SGVsbG8='))"),
    ("TRY_TO_BINARY('Hello', 'UTF-16')", "NULL"),
  ] {
    let (q, duckdb) = case
    let expr = t.validate_identity(q)
    let annotated = sf_annotate(expr)
    t.eq(sql(annotated, dialect="duckdb"), duckdb)
  }
  t.done()
}

///|
test "TestSnowflake.test_reverse" {
  let t = t(dialect="snowflake")
  for case in [
    (
      "REVERSE(TO_BINARY('ABC', 'UTF-8'))", "CAST(REVERSE(CAST(ENCODE('ABC') AS TEXT)) AS BLOB)",
    ),
    (
      "REVERSE(TO_BINARY('414243', 'HEX'))", "CAST(REVERSE(CAST(UNHEX('414243') AS TEXT)) AS BLOB)",
    ),
    (
      "REVERSE(HEX_DECODE_BINARY('414243'))", "CAST(REVERSE(CAST(UNHEX('414243') AS TEXT)) AS BLOB)",
    ),
    ("REVERSE('ABC')", "REVERSE('ABC')"),
  ] {
    let (q, duckdb) = case
    let expr = t.validate_identity(q)
    let annotated = sf_annotate(expr)
    t.eq(sql(annotated, dialect="duckdb"), duckdb)
  }
  t.done()
}

///|
test "TestSnowflake.test_float_interval" {
  let t = t(dialect="snowflake")
  let expr = t.validate_identity("TIMEADD(HOUR, 2.5, CAST('10:30:00' AS TIME))")
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "CAST('10:30:00' AS TIME) + INTERVAL (CAST(ROUND(2.5) AS INT)) HOUR",
  )
  let expr = t.validate_identity(
    "DATEADD(HOUR, CAST(3.8 AS DECIMAL(10, 2)), CAST('2024-01-01 10:00:00' AS TIMESTAMP))",
  )
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "CAST('2024-01-01 10:00:00' AS TIMESTAMP) + INTERVAL (CAST(ROUND(CAST(3.8 AS DECIMAL(10, 2))) AS INT)) HOUR",
  )
  let expr = t.parse_one(
    "TIMESTAMPADD(MINUTE, 30.9, CAST('2024-01-01 10:00:00' AS TIMESTAMP))",
  )
  t.eq(
    sql(expr, dialect="snowflake"),
    "DATEADD(MINUTE, 30.9, CAST('2024-01-01 10:00:00' AS TIMESTAMP))",
  )
  let annotated = sf_annotate(expr)
  t.eq(
    sql(annotated, dialect="duckdb"),
    "CAST('2024-01-01 10:00:00' AS TIMESTAMP) + INTERVAL (CAST(ROUND(30.9) AS INT)) MINUTE",
  )
  t.done()
}

///|
test "TestSnowflake.test_transpile_bitwise_ops" {
  let t = t(dialect="snowflake")
  for case in [
    (
      "SELECT BITOR(x'FF', x'0F')", "SELECT CAST(CAST(UNHEX('FF') AS BIT) | CAST(UNHEX('0F') AS BIT) AS BLOB)",
    ),
    (
      "SELECT BITAND(x'FF', x'0F')", "SELECT CAST(CAST(UNHEX('FF') AS BIT) & CAST(UNHEX('0F') AS BIT) AS BLOB)",
    ),
    (
      "SELECT BITXOR(x'FF', x'0F')", "SELECT CAST(XOR(CAST(UNHEX('FF') AS BIT), CAST(UNHEX('0F') AS BIT)) AS BLOB)",
    ),
    ("SELECT BITNOT(x'FF')", "SELECT CAST(~CAST(UNHEX('FF') AS BIT) AS BLOB)"),
  ] {
    let (q, duckdb) = case
    let expr = t.parse_one(q)
    let annotated = sf_annotate(expr)
    t.eq(sql(annotated, dialect="duckdb"), duckdb)
    t.eq(sql(annotated, dialect="snowflake"), q)
  }
  t.done()
}

///|
test "TestSnowflake.test_quoting" {
  let t = t(dialect="snowflake")
  t.eq(
    b_sql_identify(
      parse_one("select a, B from DUAL", read="snowflake"),
      dialect="snowflake",
      identify_mode="safe",
    ),
    "SELECT a, \"B\" FROM DUAL",
  )
  t.done()
}

///|
test "TestSnowflake.test_type_sensitive_bitshift_transpilation" {
  let t = t(dialect="snowflake")
  let ast = sf_annotate(t.parse_one("SELECT BITSHIFTLEFT(X'FF', 4)"))
  t.eq(
    sql(ast, dialect="duckdb"),
    "SELECT CAST(CAST(UNHEX('FF') AS BIT) << 4 AS BLOB)",
  )
  let ast = sf_annotate(t.parse_one("SELECT BITSHIFTRIGHT(X'FF', 4)"))
  t.eq(
    sql(ast, dialect="duckdb"),
    "SELECT CAST(CAST(UNHEX('FF') AS BIT) >> 4 AS BLOB)",
  )
  t.done()
}

///|
test "TestSnowflake.test_get_extract" {
  let t = t(dialect="snowflake")
  t.is_a(Some(t.validate_identity("GET(foo, bar)")), GetExtract) |> ignore
  t.done()
}

///|
test "TestSnowflake.test_storage_integration" {
  let t = t(dialect="snowflake")
  let sql =
    #|CREATE STORAGE INTEGRATION s3_int
    #|TYPE=EXTERNAL_STAGE
    #|STORAGE_PROVIDER='S3'
    #|STORAGE_AWS_ROLE_ARN='arn:aws:iam::001234567890:role/myrole'
    #|ENABLED=TRUE
    #|STORAGE_ALLOWED_LOCATIONS=('s3://mybucket1/path1/', 's3://mybucket2/path2/')
  t.is_a(t.validate_identity(sql, pretty=true).this(), Identifier) |> ignore
  t.done()
}

///|
test "TestSnowflake.test_timestamps" {
  let t = t(dialect="snowflake")
  for case in [
    (
      "SELECT DATE_PART(year FROM CAST('2024-04-08' AS DATE))",
      "SELECT DATE_PART(year, CAST('2024-04-08' AS DATE))",
    ),
    (
      "SELECT DATE_PART('month' FROM CAST('2024-04-08' AS DATE))",
      "SELECT DATE_PART('month', CAST('2024-04-08' AS DATE))",
    ),
    ("SELECT DATE_PART(day FROM a)", "SELECT DATE_PART(day, a)"),
  ] {
    let (sql, write_sql) = case
    t.is_a(Some(t.validate_identity(sql, write_sql~).expressions()[0]), Extract)
    |> ignore
  }
  t.done()
}

///|
test "TestSnowflake.test_to_date" {
  let t = t(dialect="snowflake")
  t.is_a(Some(t.validate_identity("TO_DATE('12345')")), Anonymous) |> ignore
  t.is_a(Some(t.validate_identity("TO_DATE(x)")), TsOrDsToDate) |> ignore
  t.is_a(Some(t.validate_identity("TRY_TO_DATE(x)")), TsOrDsToDate) |> ignore
  t.done()
}

///|
test "TestSnowflake.test_trunc" {
  let t = t(dialect="snowflake")
  t.is_a(Some(t.validate_identity("TRUNC(3.14159, 2)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(price, 0)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(3.14159)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(col)")), Trunc) |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS DATE), 'MONTH')")), DateTrunc) |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS TIMESTAMP), 'MONTH')")), DateTrunc)
  |> ignore
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS DATETIME), 'MONTH')")), DateTrunc)
  |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(foo, bar)")), Anonymous) |> ignore
  t.done()
}

///|
test "TestSnowflake.test_user_defined_functions" {
  let t = t(dialect="snowflake")
  t.is_a(
    Some(
      t.validate_identity(
        "CREATE FUNCTION a(x DOUBLE) RETURNS DOUBLE LANGUAGE SQL CALLED ON NULL INPUT AS ' x * 2 '",
      ),
    ),
    Create,
  )
  |> ignore
  t.done()
}
