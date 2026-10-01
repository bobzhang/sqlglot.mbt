// Direct assertions of tests/dialects/test_tsql.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestTSQL.test_set_operation_unordered_pagination" {
  let t = t(dialect="tsql")
  let expression = t
    .parse_one("SELECT a FROM x UNION ALL SELECT TOP 1 a FROM y")
    .offset_(1, copy=true)
  let sql_ = "SELECT * FROM (SELECT a FROM x UNION ALL SELECT TOP 1 a FROM y) AS _l_0 ORDER BY (SELECT NULL) OFFSET 1 ROWS"
  t.eq(sql(expression, dialect="tsql"), sql_)
  t.done()
}

///|
test "TestTSQL.test_set_operation_pagination" {
  let t = t(dialect="tsql")
  let expression = t.validate_identity(
    "SELECT -1 AS x UNION ALL SELECT TOP 2 x FROM (VALUES (2), (1), (0)) AS t(x) ORDER BY x OFFSET 0 ROWS FETCH FIRST 1 ROWS ONLY",
  )
  t.ok(c_arg_is(expression, "limit", Fetch))
  t.ok(c_arg_is(expression.expression_(), "limit", Limit))
  for
    sql in [
      "SELECT TOP 2 x FROM t ORDER BY x OFFSET 0 ROWS FETCH FIRST 1 ROWS ONLY", "SELECT x FROM t ORDER BY x OFFSET 0 ROWS FETCH FIRST 1 ROWS ONLY FETCH FIRST 2 ROWS ONLY",
    ] {
    t.raises(() => ignore(parse_one(sql, read="tsql")), "ParseError") |> ignore
  }
  t.done()
}

///|
test "TestTSQL.test_set_operation_trailing_clauses" {
  let t = t(dialect="tsql")
  for op in ["UNION", "UNION ALL", "INTERSECT", "EXCEPT"] {
    for
      pagination in [
        "", " OFFSET 0 ROWS", " OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY",
      ] {
      for
        clause in [
          "OPTION(RECOMPILE)", "FOR JSON PATH", "FOR XML PATH", "FOR JSON PATH OPTION(RECOMPILE)",
          "FOR XML PATH OPTION(RECOMPILE)",
        ] {
        let expression = t.validate_identity(
          "SELECT 1 AS x \{op} SELECT 2 AS x ORDER BY x\{pagination} \{clause}",
        )
        for arg in ["for_", "options"] {
          t.ok(
            !expression.expression_().args.contains(arg),
            msg="\{arg} in expression.expression.args",
          )
        }
        if clause.has_prefix("FOR") {
          t.ok(c_arg_is(expression, "for_", ForClause))
        }
        if clause.contains("OPTION") {
          t.eq(expression.list("options").length(), 1)
        }
      }
    }
  }
  for clause in ["OPTION(RECOMPILE)", "FOR JSON PATH OPTION(RECOMPILE)"] {
    let expression = t.parse_one(
      "SELECT 1 AS x UNION ALL SELECT 2 AS x \{clause}",
    )
    // Python's builders default to copy=True (the port's to copy=false)
    for
      case in [
        (
          expression.limit_(1, copy=true),
          "SELECT TOP 1 * FROM (SELECT 1 AS x UNION ALL SELECT 2 AS x) AS _l_0 \{clause}",
        ),
        (
          expression.offset_(1, copy=true),
          "SELECT * FROM (SELECT 1 AS x UNION ALL SELECT 2 AS x) AS _l_0 ORDER BY (SELECT NULL) OFFSET 1 ROWS \{clause}",
        ),
      ] {
      let (paginated, expected) = case
      t.eq(sql(paginated, dialect="tsql"), expected)
    }
  }
  t.done()
}

///|
test "TestTSQL.test_tsql" {
  let t = t(dialect="tsql")
  t.run(() => t.validate_identity("GO").assert_is(Command)) |> ignore
  t.run(() => t.validate_identity("SELECT go").selects()[0].assert_is(Column))
  |> ignore
  t.eq(
    sql(
      @optimizer.annotate_types(
        t.validate_identity("SELECT 1 WHERE EXISTS(SELECT 1)"),
      ),
      dialect="tsql",
    ),
    "SELECT 1 WHERE EXISTS(SELECT 1)",
  )
  t.run(() => {
    t.validate_identity("SELECT a = 1", write_sql="SELECT 1 AS a").selects()[0]
    .assert_is(Alias)
    .arg("alias")
    .unwrap()
    .assert_is(Identifier)
  })
  |> ignore
  t.raises(() => ignore(parse_one("SELECT begin", read="tsql")), "ParseError")
  |> ignore
  t.done()
}

///|
test "TestTSQL.test_unpivot_value_column_comes_first" {
  let t = t(dialect="tsql")
  let schema_json = "{\"t\": {\"id\": \"int\", \"jan\": \"int\", \"feb\": \"int\"}}"
  for
    case in [
      ("tsql", ["id", "revenue", "month"]),
      ("duckdb", ["id", "month", "revenue"]),
    ] {
    let (dialect, expected) = case
    let d = @core.Dialect::get_or_raise(dialect)
    let expression = @optimizer.qualify(
      parse_one(
        "SELECT * FROM t UNPIVOT(revenue FOR month IN (jan, feb)) AS u",
        read=dialect,
      ),
      schema=@optimizer.MappingSchema::new(
        schema=@optimizer.schema_from_json_string(schema_json),
        dialect=d,
      ),
      dialect=d,
    )
    t.eq(expression.selects().map(s => s.alias_or_name()), expected)
  }
  t.done()
}

///|
test "TestTSQL.test_option" {
  let t = t(dialect="tsql")
  let possible_options = [
    "HASH GROUP", "ORDER GROUP", "CONCAT UNION", "HASH UNION", "MERGE UNION", "LOOP JOIN",
    "MERGE JOIN", "HASH JOIN", "DISABLE_OPTIMIZED_PLAN_FORCING", "EXPAND VIEWS",
    "FAST 15", "FORCE ORDER", "FORCE EXTERNALPUSHDOWN", "DISABLE EXTERNALPUSHDOWN",
    "FORCE SCALEOUTEXECUTION", "DISABLE SCALEOUTEXECUTION", "IGNORE_NONCLUSTERED_COLUMNSTORE_INDEX",
    "KEEP PLAN", "KEEPFIXED PLAN", "MAX_GRANT_PERCENT = 5", "MIN_GRANT_PERCENT = 10",
    "MAXDOP 13", "MAXRECURSION 8", "NO_PERFORMANCE_SPOOL", "OPTIMIZE FOR UNKNOWN",
    "PARAMETERIZATION SIMPLE", "PARAMETERIZATION FORCED", "QUERYTRACEON 99", "RECOMPILE",
    "ROBUST PLAN", "USE PLAN N'<xml_plan>'", "LABEL = 'MyLabel'",
  ]
  let possible_statements = [
    "SELECT * FROM Table1", "SELECT * FROM Table1 WHERE id = 2", "UPDATE t1 SET k = t2.k FROM t2",
  ]
  for statement in possible_statements {
    for option in possible_options {
      let query = "\{statement} OPTION(\{option})"
      let result = t.validate_identity(query)
      match result.get("options") {
        Some(List(options)) =>
          t.ok(
            options
            .iter()
            .all(o => o.as_node() is Some(n) && n.kind.is_a(QueryOption)),
            msg="When parsing query \{query}",
          )
        _ => t.ok(false, msg="When parsing query \{query}")
      }
    }
  }
  let raising_queries = [
    // Missing parentheses
    "SELECT * FROM Table1 OPTION HASH GROUP",
    // Must be followed by 'PLAN"
     "SELECT * FROM Table1 OPTION(KEEPFIXED)",
    // Missing commas
     "SELECT * FROM Table1 OPTION(HASH GROUP HASH GROUP)",
  ]
  for query in raising_queries {
    t.raises(() => ignore(t.parse_one(query)), "ParseError") |> ignore
  }
  t.done()
}

///|
test "TestTSQL.test_ddl" {
  let t = t(dialect="tsql")
  t.run(() => {
    t
    .validate_identity("ALTER TABLE dbo.DocExe DROP CONSTRAINT FK_Column_B")
    .assert_is(Alter)
    .list("actions")[0].assert_is(Drop)
  })
  |> ignore
  let constraint = t
    .validate_identity(
      "ALTER TABLE tbl ADD CONSTRAINT cnstr PRIMARY KEY CLUSTERED (ID), CONSTRAINT cnstr2 UNIQUE CLUSTERED (ID)",
    )
    .find([AddConstraint])
  t.ok(constraint is Some(_))
  t.eq(
    constraint.map(c => c.find_all([Constraint]).to_array().length()),
    Some(2),
  )
  t.done()
}

///|
test "TestTSQL.test_identifier_prefixes" {
  let t = t(dialect="tsql")
  t.ok(
    t
    .run(() => {
      t.validate_identity("#x").assert_is(Column).this_().assert_is(Identifier)
    })
    .map(e => c_truthy(e, "temporary"))
    .unwrap_or(false),
  )
  t.ok(
    t
    .run(() => {
      t.validate_identity("##x").assert_is(Column).this_().assert_is(Identifier)
    })
    .map(e => c_truthy(e, "global_"))
    .unwrap_or(false),
  )
  // Quoted bracket form: the # must live inside the brackets in T-SQL
  match
    t.run(() => {
      t
      .validate_identity("SELECT * FROM [#temp_table]")
      .arg("from_")
      .unwrap()
      .this_()
      .assert_is(Table)
      .this_()
      .assert_is(Identifier)
    }) {
    Some(temp_ident) => {
      t.ok(c_truthy(temp_ident, "temporary"))
      t.eq(temp_ident.name(), "temp_table")
    }
    None => ()
  }
  match
    t.run(() => {
      t
      .validate_identity("SELECT * FROM [##temp_table]")
      .arg("from_")
      .unwrap()
      .this_()
      .assert_is(Table)
      .this_()
      .assert_is(Identifier)
    }) {
    Some(global_ident) => {
      t.ok(c_truthy(global_ident, "global_"))
      t.eq(global_ident.name(), "temp_table")
    }
    None => ()
  }
  t.run(() => {
    t.validate_identity("@x").assert_is(Parameter).this_().assert_is(Var)
  })
  |> ignore
  t.run(() => {
    t
    .validate_identity("SELECT * FROM @x")
    .arg("from_")
    .unwrap()
    .this_()
    .assert_is(Table)
    .this_()
    .assert_is(Parameter)
    .this_()
    .assert_is(Var)
  })
  |> ignore
  t.done()
}

///|
test "TestTSQL.test_scope_resolution_op" {
  let t = t(dialect="tsql")
  for
    case in [
      ("", "FOO(a, b)"),
      ("bar", "baZ(1, 2)"),
      ("LOGIN", "EricKurjan"),
      ("GEOGRAPHY", "Point(latitude, longitude, 4326)"),
      (
        "GEOGRAPHY", "STGeomFromText('POLYGON((-122.358 47.653 , -122.348 47.649, -122.348 47.658, -122.358 47.658, -122.358 47.653))', 4326)",
      ),
    ] {
    let (lhs, rhs) = case
    let expr = t.validate_identity("\{lhs}::\{rhs}")
    let base_sql = sql(expr)
    let prefix = if lhs != "" { lhs + ", " } else { "" }
    t.eq(base_sql, "SCOPE_RESOLUTION(\{prefix}\{rhs})")
    t.eq(sql(parse_one(base_sql), dialect="tsql"), "\{lhs}::\{rhs}")
  }
  t.done()
}

///|
test "TestTSQL.test_count" {
  let t = t(dialect="tsql")
  let type_this = (e : @core.Expr) => {
    match e.get_type() {
      Some(ty) => ty.datatype_this()
      None => None
    }
  }
  let count = @optimizer.annotate_types(
    t.validate_identity("SELECT COUNT(1) FROM x"),
  )
  t.eq(type_this(count.expressions()[0]), Some(@core.DType::INT))
  let count_big = @optimizer.annotate_types(
    t.validate_identity("SELECT COUNT_BIG(1) FROM x"),
  )
  t.eq(type_this(count_big.expressions()[0]), Some(@core.DType::BIGINT))
  t.done()
}

///|
test "TestTSQL.test_odbc_date_literals" {
  let t = t(dialect="tsql")
  for
    case in [
      ("{d'2024-01-01'}", @core.Kind::Date),
      ("{t'12:00:00'}", Time),
      ("{ts'2024-01-01 12:00:00'}", Timestamp),
    ] {
    let (value, cls) = case
    let sql = "INSERT INTO tab(ds) VALUES (\{value})"
    let expr = t.parse_one(sql)
    t.ok(expr.kind.is_a(Insert))
    t.ok(
      expr.expression_().expressions()[0].expressions()[0].kind.is_a(cls),
      msg="Testing ODBC date literal: \{value}",
    )
  }
  t.done()
}

///|
/// `" ".join(line for line in (l.strip() for l in sql.splitlines()) if line)`
fn c_join_stripped_lines(sql : String) -> String {
  sql
  .split("\n")
  .map(l => @core.py_strip(l.to_string()))
  .filter(l => l != "")
  .collect()
  .join(" ")
}

///|
test "TestTSQL.test_procedures" {
  let t = t(dialect="tsql")
  t.run(() => t.validate_identity("SELECT 1; SELECT 2").assert_is(Block))
  |> ignore
  let sqls = [
    "EXECUTE test @in1 = 100, @in2",
    "EXECUTE sp_executesql @payload, @param_str, @param1 = value1, @param2 = value2",
    "EXECUTE sp_executesql @stmt = @payload, @params = param_str, @param1 = value1, @param2 = value2",
    (
      #|
      #|            CREATE
      #|            PROCEDURE test1
      #|            AS
      #|            BEGIN
      #|                SELECT 1;
      #|                SELECT 2;
      #|                SELECT 3;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test2(@in1 INTEGER, @c CHAR(1))
      #|            AS
      #|            BEGIN
      #|                IF @in1 > 1 AND @c = 'c'
      #|                BEGIN
      #|                    SELECT col1 FROM t WHERE t.col2 = @in1;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER)
      #|            AS
      #|            BEGIN
      #|                SELECT 1;
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT 1;
      #|                    SELECT 2;
      #|                END;
      #|                ELSE
      #|                BEGIN
      #|                    SELECT 3;
      #|                    SELECT 4;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER)
      #|            AS
      #|            BEGIN
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT col1 FROM t WHERE t.col2 = @in1;
      #|                    SELECT 100;
      #|                END;
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT col2 FROM t1;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER)
      #|            AS
      #|            BEGIN
      #|                DECLARE @q1 INTEGER, @q2 INTEGER, @q3 INTEGER;
      #|                SET @q1 = (SELECT MAX(col1) FROM t1);
      #|                SET @q2 = (SELECT MIN(col1) FROM t2);
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT 3;
      #|                    SET @q3 = (SELECT MAX(col2) FROM t1);
      #|                    IF @q3 < 5
      #|                    BEGIN
      #|                        SELECT 1;
      #|                        SELECT 2;
      #|                    END;
      #|                END;
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT 1;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER)
      #|            AS
      #|            BEGIN
      #|                SELECT 1;
      #|                IF @in1 > 1
      #|                BEGIN
      #|                    SELECT 3;
      #|                END;
      #|                ELSE
      #|                BEGIN
      #|                    SELECT 4;
      #|                    SELECT 5;
      #|                    IF @in1 < 0
      #|                    BEGIN
      #|                        SELECT 1;
      #|                    END;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER, @c CHAR(1))
      #|            AS
      #|            BEGIN
      #|                WHILE @in1 > 100
      #|                BEGIN
      #|                    SELECT col1 FROM t WHERE t.col2 = @in1 AND t.col3 = @c;
      #|                    SET @in1 = @in1 - 1;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test(@in1 INTEGER)
      #|            AS
      #|            BEGIN
      #|                DECLARE @temp INTEGER;
      #|                WHILE @in1 > 100
      #|                BEGIN
      #|                    SET @temp = (SELECT MAX(col1) FROM t WHERE t.col2 = @in1);
      #|                    SET @in1 = @in1 - @temp;
      #|                END;
      #|                SET @in1 = 50;
      #|                WHILE @in1 > 5
      #|                BEGIN
      #|                    SELECT col2 FROM t1 WHERE t1.col3 = @in1;
      #|                    SET @in1 = @in1 - 1;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE dbo.test(@in1 INTEGER = 5, @in2 VARCHAR(40) = 'empty', @in3 INTEGER = 1)
      #|            AS
      #|            BEGIN
      #|                INSERT INTO t (id, col1, col2) VALUES (@in1, @in2, @in3);
      #|            END;
      #|            CREATE PROCEDURE c.s.test2
      #|            AS
      #|            BEGIN
      #|                EXECUTE dbo.test;
      #|                DECLARE @i INTEGER = 0;
      #|                WHILE @i < 100
      #|                BEGIN
      #|                    EXECUTE test @in2 = 'temp_new';
      #|                    SET @i = @i + 100;
      #|                END;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE DropTableIfExists
      #|                @TableName NVARCHAR(128)
      #|            AS
      #|            BEGIN
      #|                DECLARE @SQL NVARCHAR(MAX);
      #|                SET @SQL = N'DROP TABLE IF EXISTS [' + @TableName + ']';
      #|                EXECUTE sp_executesql 'SELECT 1 AS c';
      #|                EXECUTE sp_executesql N'SELECT 1 AS c';
      #|                EXECUTE sp_executesql @SQL;
      #|                EXECUTE sp_executesql @stmt = @SQL;
      #|            END
      #|
    ),
    (
      #|
      #|            CREATE PROCEDURE test
      #|            AS
      #|            BEGIN
      #|                DECLARE @x INTEGER = 100;
      #|                IF @x > ANY (SELECT 100)
      #|                BEGIN
      #|                    SET @x = 100;
      #|                END;
      #|                ELSE
      #|                BEGIN
      #|                    SET @x = 0;
      #|                END;
      #|            END
      #|
    ),
  ]
  for sql_ in sqls {
    let roundtripped_sql = t.run(() => {
      sql(parse_one(sql_, read="tsql"), dialect="tsql")
    })
    match roundtripped_sql {
      Some(r) => t.eq(c_join_stripped_lines(sql_), r)
      None => ()
    }
  }
  t.run(() => {
    t
    .validate_identity(
      "EXEC sp_executesql @payload",
      write_sql="EXECUTE sp_executesql @payload",
    )
    .assert_is(ExecuteSql)
  })
  |> ignore
  let cases = [
    (
      (
        #|
        #|            CREATE procedure [TRANSF].[SP_Merge_Sales_Real]
        #|                @Loadid INTEGER
        #|               ,@NumberOfRows INTEGER
        #|            WITH EXECUTE AS OWNER, SCHEMABINDING, NATIVE_COMPILATION
        #|            AS
        #|            BEGIN
        #|                SET XACT_ABORT ON;
        #|
        #|                DECLARE @DWH_DateCreated AS DATETIME = CONVERT(DATETIME, getdate(), 104);
        #|                DECLARE @DWH_DateModified DATETIME2 = CONVERT(DATETIME2, GETDATE(), 104);
        #|                DECLARE @DWH_IdUserCreated INTEGER = SUSER_ID (CURRENT_USER());
        #|                DECLARE @DWH_IdUserModified INTEGER = SUSER_ID (SYSTEM_USER);
        #|
        #|                DECLARE @SalesAmountBefore float;
        #|                SELECT @SalesAmountBefore=SUM(SalesAmount) FROM TRANSF.[Pre_Merge_Sales_Real] S;
        #|            END
        #|
      ),
      [
        "CREATE PROCEDURE [TRANSF].[SP_Merge_Sales_Real] @Loadid INTEGER, @NumberOfRows INTEGER WITH EXECUTE AS OWNER, SCHEMABINDING, NATIVE_COMPILATION AS BEGIN SET XACT_ABORT ON",
        "DECLARE @DWH_DateCreated DATETIME = CONVERT(DATETIME, GETDATE(), 104)",
        "DECLARE @DWH_DateModified DATETIME2 = CONVERT(DATETIME2, GETDATE(), 104)",
        "DECLARE @DWH_IdUserCreated INTEGER = SUSER_ID(CURRENT_USER())", "DECLARE @DWH_IdUserModified INTEGER = SUSER_ID(CURRENT_USER())",
        "DECLARE @SalesAmountBefore FLOAT", "SELECT @SalesAmountBefore = SUM(SalesAmount) FROM TRANSF.[Pre_Merge_Sales_Real] AS S",
        "END",
      ],
    ),
    (
      (
        #|
        #|            CREATE PROC [dbo].[transform_proc] AS
        #|
        #|            DECLARE @CurrentDate VARCHAR(20);
        #|            SET @CurrentDate = CONVERT(VARCHAR(20), GETDATE(), 120);
        #|
        #|            CREATE TABLE [target_schema].[target_table]
        #|            (a INTEGER)
        #|            WITH (DISTRIBUTION = REPLICATE, HEAP);
        #|
      ),
      [
        "CREATE PROC [dbo].[transform_proc] AS DECLARE @CurrentDate VARCHAR(20)",
        "SET @CurrentDate = CONVERT(VARCHAR(20), GETDATE(), 120)", "CREATE TABLE [target_schema].[target_table] (a INTEGER) WITH (DISTRIBUTION=REPLICATE, HEAP)",
      ],
    ),
  ]
  for case in cases {
    let (sql_, expected_sqls) = case
    let exprs = parse_one(sql_, read="tsql").expressions()
    // zip(): stops at the shorter sequence
    for i in 0..<@cmp.minimum(exprs.length(), expected_sqls.length()) {
      t.eq(sql(exprs[i], dialect="tsql"), expected_sqls[i])
    }
  }
  t.done()
}

///|
test "TestTSQL.test_collation_parse" {
  let t = t(dialect="tsql")
  let alter = t.is_a(
    Some(
      t.validate_identity("ALTER TABLE a ALTER COLUMN b CHAR(10) COLLATE abc"),
    ),
    Alter,
  )
  t.is_a(alter.list("actions")[0].arg("collate").unwrap().this(), Var) |> ignore
  t.done()
}
