// Direct assertions of tests/dialects/test_oracle.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestOracle.test_pivot_syntax_restrictions" {
  let t = t(dialect="oracle")
  let oracle = @core.Dialect::get_or_raise("oracle")
  // qualify qualifies the IN-list in the AST, which must not reach the generated SQL
  let schema = @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(
      "{\"t\": {\"id\": \"int\", \"jan\": \"int\", \"feb\": \"int\"}}",
    ),
    dialect=oracle,
  )
  t.eq(
    sql(
      @optimizer.qualify(
        parse_one(
          "SELECT * FROM t UNPIVOT(revenue FOR month IN (jan, feb))",
          read="oracle",
        ),
        schema~,
        dialect=oracle,
      ),
      dialect="oracle",
    ),
    "SELECT \"T\".\"ID\" AS \"ID\", \"T\".\"MONTH\" AS \"MONTH\", \"T\".\"REVENUE\" AS \"REVENUE\" " +
    "FROM \"T\" \"T\" UNPIVOT(\"REVENUE\" FOR \"MONTH\" IN (\"JAN\", \"FEB\")) \"T\"",
  )
  t.done()
}

///|
test "TestOracle.test_unrecognized_query_restriction" {
  let t = t(dialect="oracle")
  for
    sql in [
      "SELECT * FROM tbl WITH", "SELECT * FROM tbl WITH READ", "SELECT * FROM tbl WITH GRANT OPTION",
      "SELECT * FROM t WITH x AS (SELECT 1) SELECT * FROM x",
    ] {
    t.raises(
      () => ignore(@sqlglot.parse_one(sql, read="oracle", error_level=Raise)),
      "ParseError",
    )
    |> ignore
  }
  t.done()
}

///|
test "TestOracle.test_prior" {
  let t = t(dialect="oracle")
  t.raises(() => ignore(parse_one("PRIOR as foo", read="oracle")), "ParseError")
  |> ignore
  t.done()
}

///|
test "TestOracle.test_merge_builder_alias" {
  let t = t(dialect="oracle")
  let merge_stmt = @sqlglot.merge(
    [
      "WHEN MATCHED THEN UPDATE SET my_table.col1 = source_table.col1", "WHEN NOT MATCHED THEN INSERT (my_table.id, my_table.col1) VALUES (source_table.id, source_table.col1)",
    ],
    into="my_table",
    using_="(SELECT * FROM something) source_table",
    on="my_table.id = source_table.id",
    dialect="oracle",
  )
  t.eq(
    sql(merge_stmt, dialect="oracle"),
    "MERGE INTO my_table USING (SELECT * FROM something) source_table ON my_table.id = source_table.id WHEN MATCHED THEN UPDATE SET my_table.col1 = source_table.col1 WHEN NOT MATCHED THEN INSERT (my_table.id, my_table.col1) VALUES (source_table.id, source_table.col1)",
  )
  t.done()
}

///|
test "TestOracle.test_pseudocolumns" {
  let t = t(dialect="oracle")
  let ast = t.validate_identity(
    "WITH t AS (SELECT 1 AS COL) SELECT col, ROWID FROM t WHERE ROWNUM = 1",
  )
  t.ok(ast.find([Pseudocolumn]) is None)
  let qualified = @optimizer.qualify(
    ast,
    dialect=@core.Dialect::get_or_raise("oracle"),
  )
  t.ok(qualified.find([Pseudocolumn]) is Some(_))
  t.eq(
    sql(qualified, dialect="oracle"),
    "WITH \"T\" AS (SELECT 1 AS \"COL\") SELECT \"T\".\"COL\" AS \"COL\", ROWID AS \"ROWID\" FROM \"T\" \"T\" WHERE ROWNUM = 1",
  )
  t.done()
}

///|
test "TestOracle.test_full_procedure" {
  let t = t(dialect="oracle")
  let cases = [
    (
      (
        #|
        #|        CREATE OR REPLACE PROCEDURE query_emp(
        #|            p_id     IN  VARCHAR2,
        #|            p_name   OUT VARCHAR2,
        #|            p_salary OUT NUMBER
        #|        ) AS
        #|        BEGIN
        #|            SELECT last_name, salary
        #|            INTO p_name, p_salary
        #|            FROM employees
        #|            WHERE employee_id = p_id;
        #|        END;
        #|
      ),
      [
        "CREATE OR REPLACE PROCEDURE query_emp(p_id IN VARCHAR2, p_name OUT VARCHAR2, p_salary OUT NUMBER) AS BEGIN SELECT last_name, salary INTO p_name, p_salary FROM employees WHERE employee_id = p_id; END",
      ],
    ),
    (
      (
        #|
        #|        CREATE OR REPLACE PROCEDURE test_proc (
        #|            a NUMBER,
        #|            b IN NUMBER,
        #|            c IN OUT NUMBER,
        #|            d OUT NUMBER
        #|        ) AS
        #|        BEGIN
        #|            c := c + a + b;
        #|            d := 42 + c;
        #|        END;
        #|
      ),
      [
        "CREATE OR REPLACE PROCEDURE test_proc(a NUMBER, b IN NUMBER, c IN OUT NUMBER, d OUT NUMBER) AS BEGIN c := c + a + b; d := 42 + c; END",
      ],
    ),
  ]
  for case in cases {
    let (sql_, expected_sqls) = case
    let exprs = @sqlglot.parse(sql_, read="oracle")
    // zip(): stops at the shorter sequence
    for i in 0..<@cmp.minimum(exprs.length(), expected_sqls.length()) {
      t.eq(
        match exprs[i] {
          Some(e) => sql(e, dialect="oracle")
          None => "None"
        },
        expected_sqls[i],
      )
    }
  }
  t.done()
}

///|
test "TestOracle.test_oracle" {
  let t = t(dialect="oracle")
  t.is_a(
    Some(t.parse_one("ALTER TABLE tbl_name DROP FOREIGN KEY fk_symbol")),
    Alter,
  )
  |> ignore
  t.is_a(Some(t.validate_identity("DBMS_RANDOM.VALUE(low, high)")), Rand)
  |> ignore
  t.is_a(Some(t.validate_identity("DBMS_RANDOM.VALUE()")), Rand) |> ignore
  t.is_a(Some(t.validate_identity("SYSTIMESTAMP")), Systimestamp) |> ignore
  t.done()
}

///|
test "TestOracle.test_trunc" {
  let t = t(dialect="oracle")
  t.is_a(Some(t.validate_identity("TRUNC(3.14159)")), Trunc) |> ignore
  t.done()
}

///|
test "TestOracle.test_trunc_type_inference" {
  let t = t(dialect="oracle")
  t.is_a(Some(t.parse_one("TRUNC(CAST(x AS DATE), 'MONTH')")), DateTrunc)
  |> ignore
  t.is_a(Some(t.parse_one("TRUNC(SYSDATE, 'MONTH')")), DateTrunc) |> ignore
  t.is_a(Some(t.parse_one("TRUNC(col, 'MONTH')")), DateTrunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(3.14159, 2)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(price, 0)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNC(foo, bar)")), Anonymous) |> ignore
  t.done()
}

///|
test "TestOracle.test_utc_time" {
  let t = t(dialect="oracle")
  t.is_a(Some(t.validate_identity("UTC_TIME()")), UtcTime) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIME(6)")), UtcTime) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIMESTAMP()")), UtcTimestamp) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIMESTAMP(6)")), UtcTimestamp) |> ignore
  t.done()
}
