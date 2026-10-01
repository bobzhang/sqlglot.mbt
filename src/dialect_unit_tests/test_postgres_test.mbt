// Direct assertions of tests/dialects/test_postgres.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestPostgres.test_postgres" {
  let t = t(dialect="postgres")
  let expr = t.parse_one(
    "SELECT * FROM r CROSS JOIN LATERAL UNNEST(ARRAY[1]) AS s(location)",
  )
  let unnest = expr.list("joins")[0].this_().this_()
  unnest.assert_is(Unnest) |> ignore
  let alter_table_only = "ALTER TABLE ONLY \"Album\" ADD CONSTRAINT \"FK_AlbumArtistId\" FOREIGN KEY (\"ArtistId\") REFERENCES \"Artist\" (\"ArtistId\") ON DELETE NO ACTION ON UPDATE NO ACTION"
  let expr = t.parse_one(alter_table_only)
  t.ok(expr.kind.is_a(Alter))
  t.eq(sql(expr, dialect="postgres"), alter_table_only)
  t
  .validate_identity(
    "x::JSON -> 'duration' ->> -1",
    write_sql="CAST(x AS JSON) -> 'duration' ->> -1",
  )
  .assert_is(JSONExtractScalar)
  .this_()
  .assert_is(JSONExtract)
  |> ignore
  t.validate_identity("SELECT ARRAY[1, 2, 3] <@ ARRAY[1, 2]").expressions()[0].assert_is(
    ArrayContainedBy,
  )
  |> ignore
  let infix_not_like = t.parse_one("SELECT a NOT LIKE ALL (b)").expressions()[0]
  let prefix_not_like = t.parse_one("SELECT NOT a LIKE ALL (b)").expressions()[0]
  t.ok(infix_not_like.kind.is_a(Like))
  t.ok(infix_not_like.bool_arg("negate"))
  t.ok(prefix_not_like.kind.is_a(Not))
  t.ok(prefix_not_like.this_().kind.is_a(Like))
  t.ok(!prefix_not_like.this_().bool_arg("negate"))
  t.ok(infix_not_like != prefix_not_like)
  t.validate_identity("JSONB_CONTAINS(x, y)").assert_is(JSONBContains) |> ignore
  t.ok(t.parse_one("id::UUID").kind.is_a(Cast))
  // the results of these two expressions are unused in Python
  t
  .validate_identity("1::\"int\"", write_sql="CAST(1 AS INT)")
  .arg("to")
  .unwrap()
  .is_type([INT])
  |> ignore
  let udt = t.validate_identity("1::\"udt\"", write_sql="CAST(1 AS \"udt\")")
  ignore(udt.arg("to").unwrap().datatype_this() == Some(USERDEFINED))
  t.eq(
    t.parse_one("CAST(65 AS \"char\")").arg("to").unwrap().datatype_this(),
    Some(USERDEFINED),
  )
  t.validate_identity("ARRAY[1, 2, 3] && ARRAY[1, 2]").assert_is(ArrayOverlaps)
  |> ignore
  t.validate_identity("a ? b").assert_is(JSONBContainsTopKey) |> ignore
  t.validate_identity("a @> b").assert_is(ArrayContainsAll) |> ignore
  t.validate_identity("a ?| b").assert_is(JSONBContainsAnyTopKeys) |> ignore
  t.validate_identity("a ?& b").assert_is(JSONBContainsAllTopKeys) |> ignore
  t.validate_identity("a #- b").assert_is(JSONBDeleteAtPath) |> ignore
  let width_bucket = t.validate_identity("WIDTH_BUCKET(10, ARRAY[5, 15])")
  t.ok(width_bucket.get("threshold") is Some(_))
  let width_bucket = t.validate_identity("WIDTH_BUCKET(10, 5, 15, 25)")
  t.ok(width_bucket.get("threshold") is None)
  t.done()
}

///|
test "TestPostgres.test_ddl" {
  let t = t(dialect="postgres")
  // user-defined types are parsed into DataType instead of Identifier
  t.parse_one("CREATE TABLE t (a udt)").this_().expressions()[0].arg("kind").unwrap().assert_is(
    DataType,
  )
  |> ignore
  let create_type = t
    .validate_identity("CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')")
    .assert_is(Create)
  t.ok(create_type.expression_().assert_is(DataType).is_type([ENUM]))
  t.validate_identity("CREATE TYPE mood AS ENUM ()").assert_is(Create) |> ignore
  let create_type = t
    .validate_identity(
      "CREATE TYPE inventory_item AS (name TEXT, supplier_id INT, price DECIMAL)",
    )
    .assert_is(Create)
  create_type.expression_().assert_is(Schema) |> ignore
  t.validate_identity("CREATE TYPE public.mood AS ENUM ('sad', 'ok')").assert_is(
    Create,
  )
  |> ignore
  // OID is parsed into a DataType (ObjectIdentifier)
  t.ok(
    t.parse_one("CREATE TABLE p.t (c oid)").find([DataType]).unwrap().kind.is_a(
      ObjectIdentifier,
    ),
  )
  let expr = t.parse_one("CREATE TABLE t (x INTERVAL day)")
  let cdef = expr.find([ColumnDef]).unwrap()
  cdef.arg("kind").unwrap().assert_is(DataType) |> ignore
  t.eq(sql(expr, dialect="postgres"), "CREATE TABLE t (x INTERVAL DAY)")
  t
  .validate_identity(
    "CREATE FUNCTION add(integer, integer) RETURNS integer AS 'select $1 + $2;' LANGUAGE SQL IMMUTABLE CALLED ON NULL INPUT",
    write_sql="CREATE FUNCTION add(integer, integer) RETURNS INT LANGUAGE SQL IMMUTABLE CALLED ON NULL INPUT AS 'select $1 + $2;'",
  )
  .assert_is(Create)
  |> ignore
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "CREATE TABLE products (price DECIMAL CHECK price > 0)",
        read="postgres",
      ),
    ),
    "ParseError",
  )
  |> ignore
  t.raises(
    () => ignore(
      @sqlglot.transpile(
        "CREATE TABLE products (price DECIMAL, CHECK price > 1)",
        read="postgres",
      ),
    ),
    "ParseError",
  )
  |> ignore
  t.done()
}

///|
test "TestPostgres.test_called_on_null_input_malformed" {
  let t = t(dialect="postgres")
  // a malformed property suffix must raise a ParseError (no zero-progress loop)
  for sql in [
    "CREATE FUNCTION f() RETURNS INT LANGUAGE SQL CALLED XYZ AS 'SELECT 1'",
    "CREATE FUNCTION f() RETURNS INT LANGUAGE SQL PARTITION XYZ AS 'SELECT 1'",
    "CREATE FUNCTION f() RETURNS INT LANGUAGE SQL COPY XYZ AS 'SELECT 1'",
  ] {
    t.raises(() => ignore(t.parse_one(sql)), "ParseError") |> ignore
  }
  t.done()
}

///|
test "TestPostgres.test_array_offset" {
  let t = t(dialect="postgres")
  let output = t.assert_logs(() => {
    t.validate_all("SELECT col[1]", write={
      "bigquery": "SELECT col[0]",
      "duckdb": "SELECT col[1]",
      "hive": "SELECT col[0]",
      "postgres": "SELECT col[1]",
      "presto": "SELECT col[1]",
    })
  })
  t.eq(output, [
    "INFO:sqlglot:Applying array index offset (-1)",
    "INFO:sqlglot:Applying array index offset (1)",
    "INFO:sqlglot:Applying array index offset (1)",
    "INFO:sqlglot:Applying array index offset (1)",
  ])
  t.done()
}

///|
test "TestPostgres.test_regexp_binary" {
  let t = t(dialect="postgres")
  t.ok(t.parse_one("'thomas' ~ '.*thomas.*'").kind.is_a(Binary))
  t.ok(t.parse_one("'thomas' ~* '.*thomas.*'").kind.is_a(Binary))
  t.done()
}

///|
test "TestPostgres.test_extract_date_parts" {
  let t = t(dialect="postgres")
  for part in ["DAY", "MONTH", "YEAR"] {
    // date input
    t.eqf(
      () => sql(
        a_annotate(parse_one("SELECT \{part}(CAST(x AS DATE))", read="tsql")),
        dialect="postgres",
      ),
      "SELECT EXTRACT(\{part} FROM CAST(x AS DATE))",
    )
    // integer input
    t.eqf(
      () => sql(
        a_annotate(
          parse_one("SELECT \{part}(t.col) FROM t", read="tsql"),
          schema="{\"t\": {\"col\": \"int\"}}",
        ),
        dialect="postgres",
      ),
      "SELECT EXTRACT(\{part} FROM CAST('1900-01-01' AS DATE) + t.col) FROM t",
    )
  }
  t.eq(
    sql(
      a_annotate(
        parse_one(
          "WITH t AS (SELECT 1 AS col) SELECT YEAR(t.col) FROM t",
          read="tsql",
        ),
      ),
      dialect="postgres",
    ),
    "WITH t AS (SELECT 1 AS col) SELECT EXTRACT(YEAR FROM CAST('1900-01-01' AS DATE) + t.col) FROM t",
  )
  t.done()
}

///|
test "TestPostgres.test_datatype" {
  let t = t(dialect="postgres")
  t.eq(
    sql(@sqlglot.datatype_build("XML", dialect="postgres"), dialect="postgres"),
    "XML",
  )
  t.done()
}

///|
test "TestPostgres.test_interval_span" {
  let t = t(dialect="postgres")
  // AND is not consumed as a unit following an omitted-span interval
  let day_time_str = "a > INTERVAL '1 00:00' AND TRUE"
  t.ok(t.parse_one(day_time_str).kind.is_a(And))
  t.done()
}

///|
test "TestPostgres.test_preserve_is_not_null" {
  let t = t(dialect="postgres")
  let is_not_null = t.parse_one("r IS NOT NULL")
  is_not_null.assert_is(Is) |> ignore
  t.ok(is_not_null.bool_arg("negate"))
  t.done()
}

///|
test "TestPostgres.test_udt" {
  let t = t(dialect="postgres")
  for sql_ in [
    "CAST(5 AS MyType)", "CAST(5 AS \"MyType\")", "CAST(5 AS MySchema.MyType)", "CAST(5 AS \"MySchema\".\"MyType\")",
    "CAST(5 AS MySchema.\"MyType\")", "CAST(5 AS \"MyCatalog\".\"MySchema\".\"MyType\")",
  ] {
    t.run(() => t.validate_identity(sql_).arg("to").unwrap().assert_is(DataType))
    |> ignore
  }
  t.done()
}

///|
test "TestPostgres.test_begin_transaction" {
  let t = t(dialect="postgres")
  for keyword in ["TRANSACTION", "WORK"] {
    for level in [
      "ISOLATION LEVEL SERIALIZABLE", "ISOLATION LEVEL READ COMMITTED", "NOT DEFFERABLE", "READ WRITE",
      "DEFERRABLE",
    ] {
      t.run(() => {
        t
        .validate_identity(
          "BEGIN \{keyword} \{level}, \{level}",
          write_sql="BEGIN \{level}, \{level}",
        )
        .assert_is(Transaction)
      })
      |> ignore
    }
  }
  t.done()
}
