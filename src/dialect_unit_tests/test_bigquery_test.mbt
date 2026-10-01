// Direct assertions of tests/dialects/test_bigquery.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestBigQuery.test_bigquery" {
  let t = t(dialect="bigquery")
  // Presto's SHA512 takes VARBINARY, so annotated string args are wrapped in TO_UTF8
  let expr = t.parse_one("SELECT SHA512('foo')")
  let annotated = d_bq_annotate(expr)
  t.eq(sql(annotated, dialect="presto"), "SELECT SHA512(TO_UTF8('foo'))")
  for prefix in ["c.db.", "db.", ""] {
    let table = d_bq_table("`\{prefix}INFORMATION_SCHEMA.X`")
    let this = table.this_()
    t.ok(this.kind.is_a(Identifier))
    t.ok(this.bool_arg("quoted"))
    t.eq(this.name(), "INFORMATION_SCHEMA.X")
  }
  let table = d_bq_table("x-0._y.z")
  t.eq(table.catalog(), "x-0")
  t.eq(table.db(), "_y")
  t.eq(table.name(), "z")
  let table = d_bq_table("x-0._y")
  t.eq(table.db(), "x-0")
  t.eq(table.name(), "_y")
  // Domain-scoped (legacy) project IDs (`domain.com:project-id`)
  let table = d_bq_table(
    "`domain.com:project-id.region-us.INFORMATION_SCHEMA.JOBS`",
  )
  t.eq(table.catalog(), "domain.com:project-id")
  t.eq(table.db(), "region-us")
  t.eq(table.name(), "INFORMATION_SCHEMA.JOBS")
  let table = d_bq_table("`domain.com:project-id.mydataset.mytable`")
  t.eq(table.catalog(), "domain.com:project-id")
  t.eq(table.db(), "mydataset")
  t.eq(table.name(), "mytable")
  // A domain-scoped project with no dataset/table stays in the name position
  let table = d_bq_table("`domain.com:project-id`")
  t.eq(table.name(), "domain.com:project-id")
  t.ok(table.get("catalog") is None)
  t.ok(table.get("db") is None)
  // A colon without a domain is not a domain-scoped project
  let table = d_bq_table("`proj:weird.ds.tbl`")
  t.eq(table.catalog(), "proj:weird")
  t.eq(table.db(), "ds")
  t.eq(table.name(), "tbl")
  // Domains with multiple dots (e.g. `a.b.com:`) are kept intact too.
  let table = d_bq_table("`a.b.com:project-id.mydataset.mytable`")
  t.eq(table.catalog(), "a.b.com:project-id")
  t.eq(table.db(), "mydataset")
  t.eq(table.name(), "mytable")
  let table = d_bq_table(
    "`a.b.com:project-id.region-us.INFORMATION_SCHEMA.JOBS`",
  )
  t.eq(table.catalog(), "a.b.com:project-id")
  t.eq(table.db(), "region-us")
  t.eq(table.name(), "INFORMATION_SCHEMA.JOBS")
  let table = d_bq_table("`a.b.com:project-id`")
  t.eq(table.name(), "a.b.com:project-id")
  t.ok(table.get("catalog") is None)
  t.ok(table.get("db") is None)
  t.validate_identity("SAFE.SOME_RANDOM_FUNC(a, b, c)").assert_is(SafeFunc)
  |> ignore
  t.validate_identity("SAFE.SUBSTR('foo', 0, -2)").assert_is(SafeFunc).this_().assert_is(
    Substring,
  )
  |> ignore
  t.validate_identity("SAFE.TIMESTAMP(foo, zone)").assert_is(SafeFunc).this_().assert_is(
    Timestamp,
  )
  |> ignore
  t.validate_identity(
    "SAFE.PARSE_DATE('%Y-%m-%d', '2024-01-15')",
    write_sql="SAFE.PARSE_DATE('%F', '2024-01-15')",
  ).assert_is(SafeFunc).this_().assert_is(StrToDate)
  |> ignore
  t.validate_identity(
    "SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', '2024-01-15 10:30:00')",
    write_sql="SAFE.PARSE_DATETIME('%F %T', '2024-01-15 10:30:00')",
  ).assert_is(SafeFunc).this_().assert_is(ParseDatetime)
  |> ignore
  t.validate_identity(
    "SAFE.PARSE_TIMESTAMP('%Y-%m-%d %H:%M:%S', '2024-01-15 10:30:00')",
    write_sql="SAFE.PARSE_TIMESTAMP('%F %T', '2024-01-15 10:30:00')",
  ).assert_is(SafeFunc).this_().assert_is(StrToTime)
  |> ignore
  t.validate_identity("TIMESTAMP(foo, zone)").assert_is(Timestamp) |> ignore
  t.eq(
    sql(@sqlglot.to_table("`a.b`.`c.d`", dialect="bigquery")),
    "\"a\".\"b\".\"c\".\"d\"",
  )
  t.eq(
    sql(@sqlglot.to_table("`x`.`y.z`", dialect="bigquery")),
    "\"x\".\"y\".\"z\"",
  )
  t.eq(
    sql(@sqlglot.to_table("`x.y.z`", dialect="bigquery")),
    "\"x\".\"y\".\"z\"",
  )
  t.eq(
    sql(@sqlglot.to_table("`x.y.z`", dialect="bigquery"), dialect="bigquery"),
    "`x.y.z`",
  )
  t.eq(
    sql(@sqlglot.to_table("`x`.`y`", dialect="bigquery"), dialect="bigquery"),
    "`x`.`y`",
  )
  let column = t.validate_identity("SELECT `db.t`.`c` FROM `db.t`").selects()[0]
  t.eq(column.parts().length(), 3)
  let column = t.validate_identity("SELECT `p.d.t`.`c`.`f` FROM `p.d.t`").selects()[0]
  column.this_().assert_is(Dot) |> ignore
  let select_with_quoted_udf = t.validate_identity(
    "SELECT `p.d.UdF`(data) FROM `p.d.t`",
  )
  t.eq(select_with_quoted_udf.selects()[0].name(), "p.d.UdF")
  t.validate_identity("NET.HOST('http://example.com')").assert_is(NetFunc).this_().assert_is(
    Host,
  )
  |> ignore
  t.validate_identity("NET.REG_DOMAIN('http://example.com')").assert_is(NetFunc).this_().assert_is(
    RegDomain,
  )
  |> ignore
  t.validate_identity("DATE_TRUNC(x, @foo)").arg("unit").unwrap().assert_is(
    Parameter,
  )
  |> ignore
  let col = t.parse_one("SELECT data.144A_FLAG FROM t").selects()[0]
  t.ok(col.kind.is_a(Column))
  t.ok(
    col.parts() ==
    [
      @core.to_identifier("data"),
      @core.to_identifier("144A_FLAG", quoted=true),
    ],
    msg="col.parts",
  )
  for load_data_sql in [
    "LOAD DATA OVERWRITE mydataset.table1 FROM FILES(FORMAT='AVRO', uris=['gs://bucket/path/file.avro'])",
    "LOAD DATA INTO TABLE mydataset.table1 FROM FILES(FORMAT='AVRO', uris=['gs://bucket/path/file.avro'])",
    "LOAD DATA INTO TEMP TABLE mydataset.table1 FROM FILES(FORMAT='AVRO', uris=['gs://bucket/path/file.avro'])",
  ] {
    t.validate_identity(load_data_sql).assert_is(LoadData) |> ignore
  }
  t.validate_identity(
    "WITH t AS (SELECT '{\"x-y\": \"z\"}' AS c) SELECT JSON_EXTRACT(c, '$.x-y') FROM t",
  ).selects()[0].expression_().assert_is(JSONPath)
  |> ignore
  // annotated BYTES/BLOB handling from BigQuery to DuckDB
  for case in [
    (
      "SELECT TRIM(CAST('***apple***' AS BYTES), CAST('*' AS BYTES)) AS result",
      "SELECT CAST(TRIM(CAST(CAST('***apple***' AS BLOB) AS TEXT), CAST(CAST('*' AS BLOB) AS TEXT)) AS BLOB) AS result",
    ),
    (
      "SELECT TRIM('***apple***', '*') AS result",
      "SELECT TRIM('***apple***', '*') AS result",
    ),
    (
      "LOWER(CAST('HELLO' AS BYTES))",
      "CAST(LOWER(CAST(CAST('HELLO' AS BLOB) AS TEXT)) AS BLOB)",
    ),
    ("LOWER('HELLO')", "LOWER('HELLO')"),
    (
      "UPPER(CAST('hello' AS BYTES))",
      "CAST(UPPER(CAST(CAST('hello' AS BLOB) AS TEXT)) AS BLOB)",
    ),
    ("UPPER('hello')", "UPPER('hello')"),
    (
      "STARTS_WITH(CAST('foo' AS BYTES), CAST('f' AS BYTES))",
      "STARTS_WITH(CAST(CAST('foo' AS BLOB) AS TEXT), CAST(CAST('f' AS BLOB) AS TEXT))",
    ),
    (
      "STARTS_WITH(CAST('foo' AS BYTES), b'f')",
      "STARTS_WITH(CAST(CAST('foo' AS BLOB) AS TEXT), CAST(CAST(e'f' AS BLOB) AS TEXT))",
    ),
    (
      "SELECT REPLACE(CAST('apple pie' AS BYTES), CAST('pie' AS BYTES), CAST('cobbler' AS BYTES)) AS result",
      "SELECT CAST(REPLACE(CAST(CAST('apple pie' AS BLOB) AS TEXT), CAST(CAST('pie' AS BLOB) AS TEXT), CAST(CAST('cobbler' AS BLOB) AS TEXT)) AS BLOB) AS result",
    ),
    (
      "REPLACE('apple pie', 'pie', 'cobbler')",
      "REPLACE('apple pie', 'pie', 'cobbler')",
    ),
  ] {
    let (source, expected) = case
    let annotated = d_bq_annotate(t.parse_one(source))
    t.eq(sql(annotated, dialect="duckdb"), expected)
  }
  t.done()
}

///|
test "TestBigQuery.test_errors" {
  let t = t(dialect="bigquery")
  t.raises(() => ignore(t.parse_one("SELECT 'foo''bar'")), "ParseError")
  |> ignore
  t.raises(() => ignore(t.parse_one("SELECT * FROM a - b.c.d2")), "ParseError")
  |> ignore
  t.raises(
    () => ignore(@sqlglot.transpile("'\\'", read="bigquery")),
    "TokenError",
  )
  |> ignore
  for sql in [
    "SELECT * FROM a INTERSECT ALL SELECT * FROM b", "SELECT * FROM a EXCEPT ALL SELECT * FROM b",
  ] {
    t.raises(
      () => ignore(
        @sqlglot.transpile(sql, write="bigquery", unsupported_level=Raise),
      ),
      "UnsupportedError",
    )
    |> ignore
  }
  t.raises(
    () => ignore(
      @sqlglot.transpile("SELECT * FROM UNNEST(x) AS x(y)", read="bigquery"),
    ),
    "ParseError",
  )
  |> ignore
  t.raises(
    () => ignore(@sqlglot.transpile("DATE_ADD(x, day)", read="bigquery")),
    "ParseError",
  )
  |> ignore
  t.done()
}

///|
test "TestBigQuery.test_warnings" {
  let t = t(dialect="bigquery")
  let output = t.assert_logs(() => {
    t.validate_identity(
      "WITH cte(c) AS (SELECT * FROM t) SELECT * FROM cte",
      write_sql="WITH cte AS (SELECT * FROM t) SELECT * FROM cte",
    )
    |> ignore
  })
  t.contains(
    output.get(0).unwrap_or(""),
    "Can't push down CTE column names for star queries.",
  )
  t.contains(
    output.get(1).unwrap_or(""),
    "Named columns are not supported in table alias.",
  )
  let output = t.assert_logs(() => {
    t.validate_identity(
      "SELECT * FROM t AS t(c1, c2)",
      write_sql="SELECT * FROM t AS t",
    )
    |> ignore
  })
  t.contains(
    output.get(0).unwrap_or(""),
    "Named columns are not supported in table alias.",
  )
  let output = t.assert_logs(() => {
    let statements = @sqlglot.parse(
      (
        $|
        $|            BEGIN
        $|              DECLARE 1;
        $|              IF from_date IS NULL THEN SET x = 1;
        $|              END IF;
        $|            END
        $|
      ),
      read="bigquery",
    )
    t.d_bq_check_statements(statements, [
      "BEGIN DECLARE 1", "IF from_date IS NULL THEN SET x = 1", "END IF", "END",
    ])
  })
  t.contains(output.get(0).unwrap_or(""), "unsupported syntax")
  let output = t.assert_logs(() => {
    let statements = @sqlglot.parse(
      (
        $|
        $|                BEGIN CALL `project_id.dataset_id.stored_procedure_id`();
        $|                EXCEPTION WHEN ERROR THEN INSERT INTO `project_id.dataset_id.table_id` SELECT @@error.message, CURRENT_TIMESTAMP();
        $|                END
        $|
      ),
      read="bigquery",
    )
    t.d_bq_check_statements(statements, [
      "BEGIN CALL `project_id.dataset_id.stored_procedure_id`()", "EXCEPTION WHEN ERROR THEN INSERT INTO `project_id.dataset_id.table_id` SELECT @@error.message, CURRENT_TIMESTAMP()",
      "END",
    ])
  })
  t.contains(output.get(0).unwrap_or(""), "unsupported syntax")
  t.assert_logs(() => {
    let statements = @sqlglot.parse(
      (
        $|
        $|                BEGIN
        $|                    DECLARE MY_VAR INT64 DEFAULT 1;
        $|                    SET MY_VAR = (SELECT 0);
        $|
        $|                    IF MY_VAR = 1 THEN SELECT 'TRUE';
        $|                    ELSEIF MY_VAR = 0 THEN SELECT 'FALSE';
        $|                    ELSE SELECT 'NULL';
        $|                    END IF;
        $|                END
        $|
      ),
      read="bigquery",
    )
    t.d_bq_check_statements(statements, [
      "BEGIN DECLARE MY_VAR INT64 DEFAULT 1", "SET MY_VAR = (SELECT 0)", "IF MY_VAR = 1 THEN SELECT 'TRUE'",
      "ELSEIF MY_VAR = 0 THEN SELECT 'FALSE'", "ELSE SELECT 'NULL'", "END IF", "END",
    ])
  })
  |> ignore
  let output = t.assert_logs(() => {
    t.validate_identity(
      "SELECT * FROM t AS t(c1, c2)",
      write_sql="SELECT * FROM t AS t",
    )
    |> ignore
  })
  t.contains(
    output.get(0).unwrap_or(""),
    "Named columns are not supported in table alias.",
  )
  t.assert_logs(() => {
    t.validate_all(
      "SELECT a[1], b[OFFSET(1)], c[ORDINAL(1)], d[SAFE_OFFSET(1)], e[SAFE_ORDINAL(1)]",
      write={
        "duckdb": "SELECT a[2], b[2], c[1], d[2], e[1]",
        "bigquery": "SELECT a[1], b[OFFSET(1)], c[ORDINAL(1)], d[SAFE_OFFSET(1)], e[SAFE_ORDINAL(1)]",
        "presto": "SELECT a[2], b[2], c[1], ELEMENT_AT(d, 2), ELEMENT_AT(e, 1)",
      },
    )
    t.validate_all("a[0]", read={
      "bigquery": "a[0]",
      "duckdb": "a[1]",
      "presto": "a[1]",
    })
    t.validate_identity(
      "WITH foo AS (SELECT [1, 2, 3] AS array_col) SELECT array_col[offset] FROM foo CROSS JOIN UNNEST(array_col) WITH OFFSET AS offset",
    )
    |> ignore
  })
  |> ignore
  let output = t.assert_logs(() => {
    let for_in_stmts = @sqlglot.parse(
      "FOR record IN (SELECT word FROM shakespeare) DO SELECT record.word; END FOR;",
      read="bigquery",
    )
    t.eq(
      for_in_stmts.map(s => sql(s.unwrap(), dialect="bigquery")),
      [
        "FOR record IN (SELECT word FROM shakespeare) DO SELECT record.word", "END FOR",
      ],
    )
  })
  t.contains(output.get(0).unwrap_or(""), "'END FOR'")
  let output = t.assert_logs(() => {
    let for_in_stmts = @sqlglot.parse(
      "FOR record IN (SELECT word FROM shakespeare) DO BEGIN SET x = \"SELECT 1\"; EXECUTE IMMEDIATE x; END; END FOR;",
      read="bigquery",
    )
    t.eq(
      for_in_stmts.map(s => sql(s.unwrap(), dialect="bigquery")),
      [
        "FOR record IN (SELECT word FROM shakespeare) DO BEGIN SET x = \"SELECT 1\"",
        "EXECUTE IMMEDIATE x", "END", "END FOR",
      ],
    )
  })
  t.contains(output.get(0).unwrap_or(""), "FOR record")
  t.contains(output.get(1).unwrap_or(""), "EXECUTE IMMEDIATE")
  t.contains(output.get(2).unwrap_or(""), "END FOR")
  t.done()
}

///|
test "TestBigQuery.test_user_defined_functions" {
  let t = t(dialect="bigquery")
  t.ok(
    t.validate_identity("SELECT NOT deterministic FROM t").selects()[0].kind.is_a(
      Not,
    ),
  )
  t.done()
}

///|
test "TestBigQuery.test_ml_functions" {
  let t = t(dialect="bigquery")
  let ast = t.validate_identity(
    "SELECT * FROM ML.PREDICT(MODEL mydataset.mymodel, (SELECT label, column1, column2 FROM mydataset.mytable))",
  )
  t.ok(ast.find([Predict]) is Some(_))
  let ast = t.validate_identity(
    "SELECT * FROM ML.FEATURES_AT_TIME((SELECT 1), num_rows => 1)",
  )
  t.ok(ast.find([FeaturesAtTime]) is Some(_))
  let ast = t.validate_identity(
    "SELECT * FROM VECTOR_SEARCH(TABLE mydataset.base_table, 'column_to_search', TABLE mydataset.query_table, 'query_column_to_search', top_k => 2, distance_type => 'cosine', options => '{\"fraction_lists_to_search\":0.15}')",
  )
  t.ok(ast.find([VectorSearch]) is Some(_))
  t.validate_identity(
    "SELECT * FROM ML.TRANSLATE(MODEL `mydataset.mymodel`, (SELECT comment AS text_content FROM mydataset.mytable), STRUCT('translate_text' AS translate_mode, 'en' AS target_language_code))",
  ).find([MLTranslate]).unwrap().assert_is(MLTranslate)
  |> ignore
  t.validate_identity("TRANSLATE(x, y, z)").assert_is(Translate) |> ignore
  let ast = t.validate_identity(
    "SELECT * FROM ML.FORECAST(MODEL `mydataset.mymodel`, STRUCT(2 AS horizon))",
  )
  t.ok(ast.find([MLForecast]) is Some(_))
  for name in ["GENERATE_EMBEDDING", "GENERATE_TEXT_EMBEDDING"] {
    let ast = t.validate_identity(
      "SELECT * FROM ML.\{name}(MODEL mydataset.mymodel, (SELECT label, column1, column2 FROM mydataset.mytable))",
    )
    t.ok(ast.find([GenerateEmbedding]) is Some(_))
  }
  for case in [
    ("SELECT AI.EMBED('hello')", @core.Kind::AIEmbed),
    ("SELECT AI.SIMILARITY('a', 'b')", AISimilarity),
    ("SELECT AI.GENERATE('Write a haiku')", AIGenerate),
  ] {
    let (sql, kind) = case
    let ast = t.validate_identity(sql)
    t.ok(ast.expressions()[0].kind.is_a(Dot))
    t.ok(ast.expressions()[0].expression_().kind.is_a(kind))
  }
  t.done()
}

///|
test "TestBigQuery.test_pushdown_cte_column_names" {
  let t = t(dialect="bigquery")
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "WITH cte(foo) AS (SELECT * FROM tbl) SELECT foo FROM cte",
        read="spark",
        write="bigquery",
        unsupported_level=Raise,
      ),
    ),
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestBigQuery.test_json_object" {
  let t = t(dialect="bigquery")
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "SELECT JSON_OBJECT('a', 1, 'b') AS json_data",
        read="bigquery",
      ),
    ),
    "ParseError",
  )
  |> ignore
  t.done()
}

///|
test "TestBigQuery.test_convert" {
  let t = t(dialect="bigquery")
  let dt = (h : Int, m : Int, s : Int, tz : (String, Int)?) => @core.PyDateTime(
    year=2023,
    month=1,
    day=1,
    hour=h,
    minute=m,
    second=s,
    microsecond=0,
    tz~,
  )
  for case in [
    (dt(0, 0, 0, None), "CAST('2023-01-01 00:00:00' AS DATETIME)"),
    (dt(12, 13, 14, None), "CAST('2023-01-01 12:13:14' AS DATETIME)"),
    (
      dt(12, 13, 14, Some(("UTC", 0))),
      "CAST('2023-01-01 12:13:14+00:00' AS TIMESTAMP)",
    ),
    // pytz.timezone("America/Los_Angeles").localize(datetime(2023, 1, 1, 12, 13, 14))
    (
      dt(12, 13, 14, Some(("America/Los_Angeles", -8 * 60))),
      "CAST('2023-01-01 12:13:14-08:00' AS TIMESTAMP)",
    ),
  ] {
    let (value, expected) = case
    t.eq(sql(@core.convert(value), dialect=t.dialect), expected)
  }
  t.done()
}

///|
test "TestBigQuery.test_range_type" {
  let t = t(dialect="bigquery")
  for type_ in ["RANGE<DATE>", "RANGE<DATE>", "RANGE<DATETIME>", "RANGE<TIMESTAMP>"] {
    t.eq_expr(
      Some(t.parse_one(type_)),
      Some(@sqlglot.datatype_build(type_, dialect="bigquery")),
    )
  }
  t.done()
}

///|
test "TestBigQuery.test_json_extract" {
  let t = t(dialect="bigquery")
  // `sql` is left over from the last iteration of the loop over
  // ("JSON_EXTRACT_SCALAR", "JSON_VALUE") in Python
  let sql_ = "SELECT JSON_VALUE('{\"name\": \"Jakob\", \"age\": \"6\"}', '$.age')"
  t.eq(
    @sqlglot.generate(
      t.parse_one(sql_),
      dialect="bigquery",
      normalize_functions="upper",
    ),
    sql_,
  )
  t.done()
}

///|
test "TestBigQuery.test_json_extract_array" {
  let t = t(dialect="bigquery")
  for func in ["JSON_QUERY_ARRAY", "JSON_EXTRACT_ARRAY"] {
    let sql_ = "SELECT \{func}('{\"fruits\": [1, \"oranges\"]}', '$.fruits')"
    t.eq(
      @sqlglot.generate(
        t.parse_one(sql_),
        dialect="bigquery",
        normalize_functions="upper",
      ),
      sql_,
    )
  }
  t.done()
}

///|
test "TestBigQuery.test_annotate_timestamps" {
  let t = t(dialect="bigquery")
  let sql_ =
    #|
    #|        SELECT
    #|          CURRENT_TIMESTAMP() AS curr_ts,
    #|          TIMESTAMP_SECONDS(2) AS ts_seconds,
    #|          PARSE_TIMESTAMP('%c', 'Thu Dec 25 07:30:00 2008', 'UTC') AS parsed_ts,
    #|          TIMESTAMP_ADD(TIMESTAMP "2008-12-25 15:30:00+00", INTERVAL 10 MINUTE) AS ts_add,
    #|          TIMESTAMP_SUB(TIMESTAMP "2008-12-25 15:30:00+00", INTERVAL 10 MINUTE) AS ts_sub,
    #|
  let annotated = d_bq_annotate(t.parse_one(sql_))
  for select in annotated.selects() {
    t.eq(sql(select.get_type().unwrap(), dialect="bigquery"), "TIMESTAMP")
  }
  t.done()
}

///|
test "TestBigQuery.test_set_operations" {
  let t = t(dialect="bigquery")
  let union = t.validate_identity(
    "(SELECT 1 AS foo) FULL OUTER UNION ALL BY NAME (SELECT 2 AS foo, 3 AS bar)",
  )
  t.eq(union.text("side"), "FULL")
  t.eq(union.text("kind"), "OUTER")
  let union = t.validate_identity("(SELECT 1) AS x UNION ALL (SELECT 2)")
  t.ok(union.this_().kind.is_a(Subquery))
  t.done()
}

///|
test "TestBigQuery.test_identifier_meta" {
  let t = t(dialect="bigquery")
  let ast = parse_one(
    "SELECT a, b FROM test_schema.test_table_a UNION ALL SELECT c, d FROM test_catalog.test_schema.test_table_b",
    read="bigquery",
  )
  for identifier in ast.find_all([Identifier]) {
    t.eq(d_meta_keys(identifier), ["col", "end", "line", "start"])
  }
  let from_this = ast.this_().arg("from_").unwrap().this_()
  t.eq(d_meta(from_this.arg("this").unwrap()), {
    "line": 1,
    "col": 41,
    "start": 29,
    "end": 40,
  })
  t.eq(d_meta(from_this.arg("db").unwrap()), {
    "line": 1,
    "col": 28,
    "start": 17,
    "end": 27,
  })
  let from_expression = ast.expression_().arg("from_").unwrap().this_()
  t.eq(d_meta(from_expression.arg("this").unwrap()), {
    "line": 1,
    "col": 106,
    "start": 94,
    "end": 105,
  })
  t.eq(d_meta(from_expression.arg("db").unwrap()), {
    "line": 1,
    "col": 93,
    "start": 82,
    "end": 92,
  })
  t.eq(d_meta(from_expression.arg("catalog").unwrap()), {
    "line": 1,
    "col": 81,
    "start": 69,
    "end": 80,
  })
  let information_schema_sql = "SELECT a, b FROM region.INFORMATION_SCHEMA.COLUMNS"
  let ast = parse_one(information_schema_sql, read="bigquery")
  let meta = d_meta(ast.arg("from_").unwrap().this_().this_())
  t.eq(meta, { "line": 1, "col": 50, "start": 24, "end": 49 })
  t.eq(
    d_slice(information_schema_sql, meta["start"], meta["end"] + 1),
    "INFORMATION_SCHEMA.COLUMNS",
  )
  t.done()
}

///|
test "TestBigQuery.test_quoted_identifier_meta" {
  let t = t(dialect="bigquery")
  let sql_ = "SELECT `a` FROM `test_schema`.`test_table_a`"
  let ast = parse_one(sql_, read="bigquery")
  let db_meta = d_meta(ast.arg("from_").unwrap().this_().arg("db").unwrap())
  t.eq(d_slice(sql_, db_meta["start"], db_meta["end"] + 1), "`test_schema`")
  let table_meta = d_meta(ast.arg("from_").unwrap().this_().this_())
  t.eq(
    d_slice(sql_, table_meta["start"], table_meta["end"] + 1),
    "`test_table_a`",
  )
  let information_schema_sql = "SELECT a, b FROM `region.INFORMATION_SCHEMA.COLUMNS`"
  let ast = parse_one(information_schema_sql, read="bigquery")
  let table_meta = d_meta(ast.arg("from_").unwrap().this_().this_())
  t.eq(
    d_slice(
      information_schema_sql,
      table_meta["start"],
      table_meta["end"] + 1,
    ),
    "`region.INFORMATION_SCHEMA.COLUMNS`",
  )
  t.done()
}

///|
test "TestBigQuery.test_override_normalization_strategy" {
  let t = t(dialect="bigquery")
  let sql_ = "SELECT * FROM p.d.t"
  let ast = t.parse_one(sql_)
  let qualified = @optimizer.qualify(
    ast.copy(),
    dialect=@sqlglot.dialect("bigquery,normalization_strategy=uppercase"),
  )
  t.eq(sql(qualified, dialect="bigquery"), "SELECT * FROM `P`.`D`.`T` AS `T`")
  // BigQuery.NORMALIZATION_STRATEGY = NormalizationStrategy.UPPERCASE
  let bigquery = @core.get_dialect("bigquery").unwrap()
  let saved = bigquery.cfg.normalization_strategy
  bigquery.cfg.normalization_strategy = Uppercase
  let qualified = @optimizer.qualify(
    ast.copy(),
    dialect=@sqlglot.dialect("bigquery,normalization_strategy=uppercase"),
  ) catch {
    e => {
      bigquery.cfg.normalization_strategy = saved
      raise e
    }
  }
  bigquery.cfg.normalization_strategy = saved
  t.eq(sql(qualified, dialect="bigquery"), "SELECT * FROM `P`.`D`.`T` AS `T`")
  t.done()
}

///|
test "TestBigQuery.test_avoid_generating_nested_comment" {
  let t = t(dialect="bigquery")
  let sql_ =
    #|
    #|        select
    #|            id,
    #|            foo,
    #|            -- bar, /* the thing */
    #|        from facts
    #|
  let expected = "SELECT\n  id,\n  foo\n/* bar, / * the thing * / */\nFROM facts"
  t.eq(sql(t.parse_one(sql_), dialect="bigquery", pretty=true), expected)
  t.done()
}

///|
test "TestBigQuery.test_pseudocolumns" {
  let t = t(dialect="bigquery")
  let bigquery = @sqlglot.dialect("bigquery")
  let schema_json = "{\"t\": {\"col\": \"INT\", \"a\": \"TIMESTAMP\", \"b\": \"TIMESTAMP\"}}"
  let ast = t.validate_identity(
    "SELECT col FROM t WHERE _PARTITIONTIME BETWEEN a AND b",
  )
  t.ok(ast.find([Pseudocolumn]) is None)
  let qualified = @optimizer.qualify(
    ast,
    schema=d_schema(schema_json, dialect="bigquery"),
    dialect=bigquery,
  )
  t.ok(qualified.find([Pseudocolumn]) is Some(_))
  t.eq(
    sql(qualified, dialect="bigquery"),
    "SELECT `t`.`col` AS `col` FROM `t` AS `t` WHERE `_partitiontime` BETWEEN `t`.`a` AND `t`.`b`",
  )
  let ast = t.validate_identity("SELECT _DBT_MAX_PARTITION FROM t")
  t.ok(ast.find([Pseudocolumn]) is None)
  let qualified = @optimizer.qualify(
    ast,
    schema=d_schema(schema_json, dialect="bigquery"),
    dialect=bigquery,
  )
  t.ok(qualified.find([Pseudocolumn]) is Some(_))
  t.done()
}

///|
test "TestBigQuery.test_approx_quantiles_to_duckdb" {
  let t = t(dialect="bigquery")
  // APPROX_QUANTILES 100 buckets
  let result = sql(t.parse_one("APPROX_QUANTILES(x, 100)"), dialect="duckdb")
  t.eq(d_count(result, "APPROX_QUANTILE("), 1)
  t.contains(result, "0.01")
  t.contains(result, "0.99")
  // assertRegex(result, r"APPROX_QUANTILE\(x, \[.*\]\)")
  let regex_ok = match result.find("APPROX_QUANTILE(x, [") {
    Some(i) =>
      result
      .unsafe_substring(start=i, end=result.length())
      .contains("])")
    None => false
  }
  t.ok(regex_ok, msg="regex mismatch: \{result}")
  for sql_ in [
    "APPROX_QUANTILES(x, bucket_count)", "APPROX_QUANTILES(x, 0)", "APPROX_QUANTILES(x, -1)",
    "APPROX_QUANTILES(x, 2.5)", "APPROX_QUANTILES(x, NULL)", "APPROX_QUANTILES(x)", "APPROX_QUANTILES(DISTINCT x)",
  ] {
    t.raises(
      () => ignore(
        sql(t.parse_one(sql_), dialect="duckdb", unsupported_level=Raise),
      ),
      "UnsupportedError",
    )
    |> ignore
  }
  // APPROX_QUANTILES IGNORE NULLS: no warning (IGNORE NULLS is DuckDB's default)
  @core.take_log_messages() |> ignore
  t.validate_all("APPROX_QUANTILES(x, 2 IGNORE NULLS)", write={
    "duckdb": "APPROX_QUANTILE(x, [0, 0.5, 1])",
  })
  t.eq(captured_logs(level="WARNING"), [])
  t.raises(
    () => ignore(
      sql(
        t.parse_one("APPROX_QUANTILES(x, 2 RESPECT NULLS)"),
        dialect="duckdb",
        unsupported_level=Raise,
      ),
    ),
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestBigQuery.test_unix_seconds" {
  let t = t(dialect="bigquery")
  for dialect in ["bigquery", "spark", "databricks"] {
    t.is_a(Some(parse_one("UNIX_SECONDS(col)", read=dialect)), UnixSeconds) |> ignore
  }
  t.done()
}
