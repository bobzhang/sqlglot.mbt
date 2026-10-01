// Direct assertions of tests/dialects/test_presto.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestPresto.test_time" {
  let t = t(dialect="presto")
  let expr = @sqlglot.parse_one(
    "TIME(7) WITH TIME ZONE",
    into=DataType,
    read="presto",
  )
  t.eq(expr.datatype_this(), Some(@core.DType::TIMETZ))
  t.done()
}

///|
test "TestPresto.test_presto" {
  let t = t(dialect="presto")
  t.eq(
    sql(
      @sqlglot.func("md5", args=[
        @sqlglot.func("concat", args=[
          @sqlglot.cast("x", "text"),
          @core.literal_string("s"),
        ]),
      ]),
      dialect="presto",
    ),
    "LOWER(TO_HEX(MD5(TO_UTF8(CONCAT(CAST(x AS VARCHAR), CAST('s' AS VARCHAR))))))",
  )
  t.eq(
    sql(
      @sqlglot.func("sha2", args=[
        @sqlglot.cast("x", "text"),
        @core.literal_number("256"),
      ]),
      dialect="presto",
    ),
    "LOWER(TO_HEX(SHA256(TO_UTF8(CAST(x AS VARCHAR)))))",
  )
  t.assert_logs(() => {
    t.validate_all(
      "SELECT COALESCE(ELEMENT_AT(MAP_FROM_ENTRIES(ARRAY[(51, '1')]), id), quantity) FROM my_table",
      write={
        "presto": "SELECT COALESCE(ELEMENT_AT(MAP_FROM_ENTRIES(ARRAY[(51, '1')]), id), quantity) FROM my_table",
      },
      write_unsupported=["postgres"],
    )
    t.validate_all("SELECT ELEMENT_AT(ARRAY[1, 2, 3], 4)", write={
      "": "SELECT ARRAY(1, 2, 3)[3]",
      "bigquery": "SELECT [1, 2, 3][SAFE_ORDINAL(4)]",
      "postgres": "SELECT (ARRAY[1, 2, 3])[4]",
      "presto": "SELECT ELEMENT_AT(ARRAY[1, 2, 3], 4)",
    })
  })
  |> ignore
  t.validate_identity("TRUNCATE(3.14159, 2)").assert_is(Trunc) |> ignore
  t.validate_identity("TRUNCATE(3.14159)").assert_is(Trunc) |> ignore
  t.done()
}

///|
test "TestPresto.test_json" {
  let t = t(dialect="presto")
  t.assert_logs(() => {
    t.validate_all(
      "SELECT JSON_EXTRACT_SCALAR(TRY(FILTER(CAST(JSON_EXTRACT('{\"k1\": [{\"k2\": \"{\\\"k3\\\": 1}\", \"k4\": \"v\"}]}', '$.k1') AS ARRAY(MAP(VARCHAR, VARCHAR))), x -> x['k4'] = 'v')[1]['k2']), '$.k3')",
      write={
        "presto": "SELECT JSON_EXTRACT_SCALAR(TRY(FILTER(CAST(JSON_EXTRACT('{\"k1\": [{\"k2\": \"{\\\"k3\\\": 1}\", \"k4\": \"v\"}]}', '$.k1') AS ARRAY(MAP(VARCHAR, VARCHAR))), x -> x['k4'] = 'v')[1]['k2']), '$.k3')",
        "spark": "SELECT GET_JSON_OBJECT(FILTER(FROM_JSON(GET_JSON_OBJECT('{\"k1\": [{\"k2\": \"{\\\\\"k3\\\\\": 1}\", \"k4\": \"v\"}]}', '$.k1'), 'ARRAY<MAP<STRING, STRING>>'), x -> x['k4'] = 'v')[0]['k2'], '$.k3')",
      },
    )
  })
  |> ignore
  t.done()
}

///|
test "TestPresto.test_json_vs_row_extract" {
  let t = t(dialect="presto")
  for dialect in ["trino", "presto"] {
    let s = parse_one("SELECT col:x:y.\"special string\"", read="snowflake")
    let dialect_json_extract_setting = "\{dialect}, variant_extract_is_json_extract=True"
    let dialect_row_access_setting = "\{dialect}, variant_extract_is_json_extract=False"
    // Snowflake VARIANT generates JSON_EXTRACT() in Presto/Trino by default
    let json_extract_result = "SELECT JSON_EXTRACT(col, '$.x.y[\"special string\"]')"
    t.eqf(() => sql(s, dialect~), json_extract_result)
    t.eqf(() => sql(s, dialect=dialect_json_extract_setting), json_extract_result)
    // overridden to False: ROW access (dot notation)
    t.eqf(
      () => sql(s, dialect=dialect_row_access_setting),
      "SELECT col.x.y.\"special string\"",
    )
  }
  t.done()
}
