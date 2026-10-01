// Port of tests/test_transpile.py

///|
test "TestTranspile.test_weird_chars" {
  let t = t()
  t.eqf(() => @sqlglot.transpile("0Êß")[0], "0 AS Êß")
  t.eqf(
    () => @sqlglot.transpile("SELECT　* FROM t WHERE c = 1")[0],
    "SELECT * FROM t WHERE c = 1",
  )
  t.done()
}

///|
test "TestTranspile.test_alias" {
  let t = t()
  t.eqf(
    () => @sqlglot.transpile("SELECT SUM(y) KEEP")[0],
    "SELECT SUM(y) AS KEEP",
  )
  t.eqf(
    () => @sqlglot.transpile("SELECT 1 overwrite")[0],
    "SELECT 1 AS overwrite",
  )
  t.eqf(() => @sqlglot.transpile("SELECT 1 is")[0], "SELECT 1 AS is")
  t.eqf(
    () => @sqlglot.transpile("SELECT 1 current_time")[0],
    "SELECT 1 AS current_time",
  )
  t.eqf(
    () => @sqlglot.transpile("SELECT 1 current_timestamp")[0],
    "SELECT 1 AS current_timestamp",
  )
  t.eqf(
    () => @sqlglot.transpile("SELECT 1 current_date")[0],
    "SELECT 1 AS current_date",
  )
  t.eqf(
    () => @sqlglot.transpile("SELECT 1 current_datetime")[0],
    "SELECT 1 AS current_datetime",
  )
  t.eqf(() => @sqlglot.transpile("SELECT 1 row")[0], "SELECT 1 AS row")
  t.eqf(
    () => {
      @sqlglot.transpile(
        "SELECT 1 FROM a.b.table1 t UNPIVOT((c3) FOR c4 IN (a, b))",
      )[0]
    },
    "SELECT 1 FROM a.b.table1 AS t UNPIVOT((c3) FOR c4 IN (a, b))",
  )
  for key in ["union", "from", "join"] {
    t.validate("SELECT x AS \{key}", "SELECT x AS \{key}")
    t.validate("SELECT x \"\{key}\"", "SELECT x AS \"\{key}\"")
    t.raises_parse(() => ignore(@sqlglot.transpile("SELECT x \{key}")))
    |> ignore
  }
  t.done()
}

///|
test "TestTranspile.test_unary" {
  let t = t()
  t.validate("+++1", "1")
  t.validate("+-1", "-1")
  t.validate("+- - -1", "- - -1")
  t.done()
}

///|
test "TestTranspile.test_paren" {
  let t = t()
  t.raises_parse(() => {
    ignore(@sqlglot.transpile("1 + (2 + 3"))
    // (unreachable in Python too: the first call raises)
    ignore(@sqlglot.transpile("select f("))
  })
  |> ignore
  t.done()
}

///|
test "TestTranspile.test_some" {
  let t = t()
  t.validate(
    "SELECT * FROM x WHERE a = SOME (SELECT 1)", "SELECT * FROM x WHERE a = ANY(SELECT 1)",
  )
  t.done()
}

///|
test "TestTranspile.test_leading_comma" {
  let t = t()
  t.validate(
    "SELECT a, b, c FROM (SELECT a, b, c FROM t)",
    (
      #|SELECT
      #|    a
      #|    , b
      #|    , c
      #|FROM (
      #|    SELECT
      #|        a
      #|        , b
      #|        , c
      #|    FROM t
      #|)
    ),
    leading_comma=true,
    pretty=true,
    pad=4,
    indent=4,
  )
  t.validate(
    "SELECT FOO, BAR, BAZ",
    (
      #|SELECT
      #|  FOO
      #|  , BAR
      #|  , BAZ
    ),
    leading_comma=true,
    pretty=true,
  )
  t.validate(
    (
      #|SELECT FOO, /*x*/
      #|BAR, /*y*/
      #|BAZ
    ),
    (
      #|SELECT
      #|  FOO /* x */
      #|  , BAR /* y */
      #|  , BAZ
    ),
    leading_comma=true,
    pretty=true,
  )
  t.validate("SELECT FOO, BAR, BAZ", "SELECT FOO, BAR, BAZ", leading_comma=true)
  t.done()
}

///|
test "TestTranspile.test_space" {
  let t = t()
  t.validate("SELECT MIN(3)>MIN(2)", "SELECT MIN(3) > MIN(2)")
  t.validate("SELECT MIN(3)>=MIN(2)", "SELECT MIN(3) >= MIN(2)")
  t.validate("SELECT 1>0", "SELECT 1 > 0")
  t.validate("SELECT 3>=3", "SELECT 3 >= 3")
  t.validate("SELECT a\r\nFROM b", "SELECT a FROM b")
  t.done()
}

///|
test "TestTranspile.test_comments" {
  let t = t()
  t.validate(
    "select /* asfd /* asdf */ asdf */ 1", "/* asfd / * asdf * / asdf */ SELECT 1",
  )
  t.validate("SELECT c /* foo */ AS alias", "SELECT c AS alias /* foo */")
  t.validate(
    "SELECT c AS /* foo */ (a, b, c) FROM t", "SELECT c AS (a, b, c) /* foo */ FROM t",
  )
  t.validate(
    (
      #|SELECT * FROM t1
      #|/*x*/
      #|UNION ALL SELECT * FROM t2
    ),
    "SELECT * FROM t1 /* x */ UNION ALL SELECT * FROM t2",
  )
  t.validate(
    "/* comment */ SELECT * FROM a UNION SELECT * FROM b", "/* comment */ SELECT * FROM a UNION SELECT * FROM b",
  )
  t.validate(
    (
      #|SELECT * FROM t1
      #|/*x*/
      #|INTERSECT ALL SELECT * FROM t2
    ),
    "SELECT * FROM t1 /* x */ INTERSECT ALL SELECT * FROM t2",
  )
  t.validate(
    (
      #|SELECT
      #|  foo
      #|/* comments */
      #|;
    ),
    "SELECT foo /* comments */",
  )
  t.validate(
    "SELECT * FROM a INNER /* comments */ JOIN b", "SELECT * FROM a /* comments */ INNER JOIN b",
  )
  t.validate(
    "SELECT * FROM a LEFT /* comment 1 */ OUTER /* comment 2 */ JOIN b", "SELECT * FROM a /* comment 1 */ /* comment 2 */ LEFT OUTER JOIN b",
  )
  t.validate(
    "SELECT CASE /* test */ WHEN a THEN b ELSE c END", "SELECT CASE WHEN a THEN b ELSE c END /* test */",
  )
  t.validate("SELECT 1 /*/2 */", "SELECT 1 /* /2 */")
  t.validate("SELECT */*comment*/", "SELECT * /* comment */")
  t.validate(
    "SELECT * FROM table /*comment 1*/ /*comment 2*/", "SELECT * FROM table /* comment 1 */ /* comment 2 */",
  )
  t.validate("SELECT 1 FROM foo -- comment", "SELECT 1 FROM foo /* comment */")
  t.validate(
    (
      #|SELECT * FROM
      #|/* comment */
      #|db.schema1.tbl PIVOT (SUM(a) FOR b IN ('x', 'y'))
    ),
    "SELECT * FROM db.schema1.tbl PIVOT(SUM(a) FOR b IN ('x', 'y')) /* comment */",
  )
  t.validate(
    (
      #|SELECT --+5
      #|x FROM foo
    ),
    "/* +5 */ SELECT x FROM foo",
  )
  t.validate(
    (
      #|SELECT --!5
      #|x FROM foo
    ),
    "/* !5 */ SELECT x FROM foo",
  )
  t.validate(
    "SELECT 1 /* inline */ FROM foo -- comment", "SELECT 1 /* inline */ FROM foo /* comment */",
  )
  t.validate(
    "SELECT FUN(x) /*x*/, [1,2,3] /*y*/", "SELECT FUN(x) /* x */, ARRAY(1, 2, 3) /* y */",
  )
  t.validate(
    (
      #|
      #|            SELECT 1 -- comment
      #|            FROM foo -- comment
      #|            
    ),
    "SELECT 1 /* comment */ FROM foo /* comment */",
  )
  t.validate(
    (
      #|
      #|            SELECT 1 /* big comment
      #|             like this */
      #|            FROM foo -- comment
      #|            
    ),
    (
      #|SELECT 1 /* big comment
      #|             like this */ FROM foo /* comment */
    ),
  )
  t.validate("select x from foo --       x", "SELECT x FROM foo /*       x */")
  t.validate(
    (
      #|select x, --
      #|            from foo
    ),
    "SELECT x FROM foo",
  )
  t.validate(
    (
      #|
      #|-- comment 1
      #|-- comment 2
      #|-- comment 3
      #|SELECT * FROM foo
      #|            
    ),
    "/* comment 1 */ /* comment 2 */ /* comment 3 */ SELECT * FROM foo",
  )
  t.validate(
    (
      #|
      #|-- comment 1
      #|-- comment 2
      #|-- comment 3
      #|SELECT * FROM foo
    ),
    (
      #|/* comment 1 */
      #|/* comment 2 */
      #|/* comment 3 */
      #|SELECT
      #|  *
      #|FROM foo
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|SELECT * FROM tbl /*line1
      #|line2
      #|line3*/ /*another comment*/ where 1=1 -- comment at the end
    ),
    (
      #|SELECT * FROM tbl /* line1
      #|line2
      #|line3 */ /* another comment */ WHERE 1 = 1 /* comment at the end */
    ),
  )
  t.validate(
    (
      #|
      #|SELECT * FROM tbl /*line1
      #|line2
      #|line3*/ /*another comment*/ where 1=1 -- comment at the end
    ),
    (
      #|SELECT
      #|  *
      #|FROM tbl /* line1
      #|line2
      #|line3 */ /* another comment */
      #|WHERE
      #|  1 = 1 /* comment at the end */
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            /* multi
      #|               line
      #|               comment
      #|            */
      #|            SELECT
      #|              tbl.cola /* comment 1 */ + tbl.colb /* comment 2 */,
      #|              CAST(x AS CHAR), # comment 3
      #|              y               -- comment 4
      #|            FROM
      #|              bar /* comment 5 */,
      #|              tbl #          comment 6
      #|            
    ),
    (
      #|/* multi
      #|               line
      #|               comment
      #|            */
      #|SELECT
      #|  tbl.cola /* comment 1 */ + tbl.colb /* comment 2 */,
      #|  CAST(x AS CHAR), /* comment 3 */
      #|  y /* comment 4 */
      #|FROM bar /* comment 5 */, tbl /*          comment 6 */
    ),
    read="mysql",
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            SELECT a FROM b
      #|            WHERE foo
      #|            -- comment 1
      #|            AND bar
      #|            -- comment 2
      #|            AND bla
      #|            -- comment 3
      #|            LIMIT 10
      #|            ;
      #|            
    ),
    "SELECT a FROM b WHERE foo AND /* comment 1 */ bar AND /* comment 2 */ bla LIMIT 10 /* comment 3 */",
  )
  t.validate(
    (
      #|
      #|            SELECT a FROM b WHERE foo
      #|            -- comment 1
      #|            
    ),
    "SELECT a FROM b WHERE foo /* comment 1 */",
  )
  t.validate(
    (
      #|
      #|            select a
      #|            -- from
      #|            from b
      #|            -- where
      #|            where foo
      #|            -- comment 1
      #|            and bar
      #|            -- comment 2
      #|            and bla
      #|            
    ),
    (
      #|SELECT
      #|  a
      #|/* from */
      #|FROM b
      #|/* where */
      #|WHERE
      #|  foo AND /* comment 1 */ bar AND /* comment 2 */ bla
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            -- test
      #|            WITH v AS (
      #|              SELECT
      #|                1 AS literal
      #|            )
      #|            SELECT
      #|              *
      #|            FROM v
      #|            
    ),
    (
      #|/* test */
      #|WITH v AS (
      #|  SELECT
      #|    1 AS literal
      #|)
      #|SELECT
      #|  *
      #|FROM v
    ),
    pretty=true,
  )
  t.validate("(/* 1 */ 1 ) /* 2 */", "(1) /* 1 */ /* 2 */")
  t.validate(
    "select * from t where not a in (23) /*test*/ and b in (14)", "SELECT * FROM t WHERE NOT a IN (23) /* test */ AND b IN (14)",
  )
  t.validate(
    "select * from t where a in (23) /*test*/ and b in (14)", "SELECT * FROM t WHERE a IN (23) /* test */ AND b IN (14)",
  )
  t.validate(
    "select * from t where ((condition = 1)/*test*/)", "SELECT * FROM t WHERE ((condition = 1) /* test */)",
  )
  t.validate(
    "SELECT 1 // hi this is a comment",
    "SELECT 1 /* hi this is a comment */",
    read="snowflake",
  )
  t.validate(
    (
      #|-- comment
      #|DROP TABLE IF EXISTS foo
    ),
    "/* comment */ DROP TABLE IF EXISTS foo",
  )
  t.validate(
    (
      #|
      #|            -- comment1
      #|            -- comment2
      #|
      #|            -- comment3
      #|            DROP TABLE IF EXISTS db.tba
      #|            
    ),
    (
      #|/* comment1 */
      #|/* comment2 */
      #|/* comment3 */
      #|DROP TABLE IF EXISTS db.tba
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            -- comment4
      #|            CREATE TABLE db.tba AS
      #|            SELECT a, b, c
      #|            FROM tb_01
      #|            WHERE
      #|            -- comment5
      #|              a = 1 AND b = 2 --comment6
      #|              -- and c = 1
      #|            -- comment7
      #|            ;
      #|            
    ),
    (
      #|/* comment4 */
      #|CREATE TABLE db.tba AS
      #|SELECT
      #|  a,
      #|  b,
      #|  c
      #|FROM tb_01
      #|WHERE
      #|  a /* comment5 */ = 1 AND b = 2 /* comment6 */ /* and c = 1 */ /* comment7 */
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            SELECT
      #|               -- This is testing comments
      #|                col,
      #|            -- 2nd testing comments
      #|            CASE WHEN a THEN b ELSE c END as d
      #|            FROM t
      #|            
    ),
    (
      #|SELECT
      #|  col, /* This is testing comments */
      #|  CASE WHEN a THEN b ELSE c END AS d /* 2nd testing comments */
      #|FROM t
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            SELECT * FROM a
      #|            -- comments
      #|            INNER JOIN b
      #|            
    ),
    (
      #|SELECT
      #|  *
      #|FROM a
      #|/* comments */
      #|INNER JOIN b
    ),
    pretty=true,
  )
  t.validate(
    "SELECT * FROM a LEFT /* comment 1 */ OUTER /* comment 2 */ JOIN b",
    (
      #|SELECT
      #|  *
      #|FROM a
      #|/* comment 1 */
      #|/* comment 2 */
      #|LEFT OUTER JOIN b
    ),
    pretty=true,
  )
  t.validate(
    (
      #|SELECT
      #|  a /* sqlglot.meta case_sensitive */ -- noqa
      #|FROM tbl
    ),
    (
      #|SELECT
      #|  a /* sqlglot.meta case_sensitive */ /* noqa */
      #|FROM tbl
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|SELECT
      #|  'hotel1' AS hotel,
      #|  *
      #|FROM dw_1_dw_1_1.exactonline_1.transactionlines
      #|/*
      #|    UNION ALL
      #|    SELECT
      #|      'Thon Partner Hotel Jølster' AS hotel,
      #|      name,
      #|      date,
      #|      CAST(identifier AS VARCHAR) AS identifier,
      #|      value
      #|    FROM d2o_889_oupjr_1348.public.accountvalues_forecast
      #|*/
      #|UNION ALL
      #|SELECT
      #|  'hotel2' AS hotel,
      #|  *
      #|FROM dw_1_dw_1_1.exactonline_2.transactionlines
    ),
    (
      #|SELECT
      #|  'hotel1' AS hotel,
      #|  *
      #|FROM dw_1_dw_1_1.exactonline_1.transactionlines
      #|/*
      #|    UNION ALL
      #|    SELECT
      #|      'Thon Partner Hotel Jølster' AS hotel,
      #|      name,
      #|      date,
      #|      CAST(identifier AS VARCHAR) AS identifier,
      #|      value
      #|    FROM d2o_889_oupjr_1348.public.accountvalues_forecast
      #|*/
      #|UNION ALL
      #|SELECT
      #|  'hotel2' AS hotel,
      #|  *
      #|FROM dw_1_dw_1_1.exactonline_2.transactionlines
    ),
    pretty=true,
  )
  t.validate(
    "/* The result of  some calculations\n */\nwith\n    base as (\n        select\n            sum(sb.hep_amount) as hep_amount,\n            -- I AM REMOVED\n            sum(sb.hep_budget)\n            /* Budget defined in sharepoint */\n            as blub\n            , 1 as bla\n        from gold.data_budget sb\n        group by all\n    )\nselect\n    *\nfrom base\n",
    (
      #|/* The result of  some calculations
      #| */
      #|WITH base AS (
      #|  SELECT
      #|    SUM(sb.hep_amount) AS hep_amount,
      #|    SUM(sb.hep_budget) /* I AM REMOVED */ AS blub, /* Budget defined in sharepoint */
      #|    1 AS bla
      #|  FROM gold.data_budget AS sb
      #|  GROUP BY ALL
      #|)
      #|SELECT
      #|  *
      #|FROM base
    ),
    pretty=true,
  )
  t.validate(
    (
      #|-- comment
      #|SOME_FUNC(arg IGNORE NULLS)
      #|  OVER (PARTITION BY foo ORDER BY bla) AS col
    ),
    "SOME_FUNC(arg IGNORE NULLS) OVER (PARTITION BY foo ORDER BY bla) AS col /* comment */",
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            SELECT *
      #|            FROM x
      #|            INNER JOIN y
      #|            -- inner join z
      #|            LEFT JOIN z using (id)
      #|            using (id)
      #|            
    ),
    (
      #|SELECT
      #|  *
      #|FROM x
      #|INNER JOIN y
      #|  /* inner join z */
      #|  LEFT JOIN z
      #|    USING (id)
      #|  USING (id)
    ),
    pretty=true,
  )
  t.validate(
    (
      #|with x as (
      #|  SELECT *
      #|  /*
      #|NOTE: LEFT JOIN because blah blah blah
      #|  */
      #|  FROM a
      #|)
      #|select * from x
    ),
    (
      #|WITH x AS (
      #|  SELECT
      #|    *
      #|  /*
      #|NOTE: LEFT JOIN because blah blah blah
      #|  */
      #|  FROM a
      #|)
      #|SELECT
      #|  *
      #|FROM x
    ),
    pretty=true,
  )
  t.validate(
    (
      #|SELECT X FROM  catalog.db.table WHERE Y
      #|        --
      #|        AND Z
    ),
    "SELECT X FROM catalog.db.table WHERE Y AND Z",
  )
  t.validate(
    "with a as /* comment */ ( select * from b) select * from a", "WITH a /* comment */ AS (SELECT * FROM b) SELECT * FROM a",
  )
  t.validate(
    (
      #|
      #|  -- comment at the top
      #|WITH
      #|-- comment for tbl1
      #|tbl1 AS (SELECT 1)
      #|-- comment for tbl2
      #|, tbl2 AS (SELECT 2)
      #|-- comment for tbl3
      #|, tbl3 AS (SELECT 3)
      #|-- comment for final select
      #|SELECT * FROM tbl1
    ),
    (
      #|/* comment at the top */
      #|WITH tbl1 /* comment for tbl1 */ AS (
      #|  SELECT
      #|    1
      #|), tbl2 /* comment for tbl2 */ AS (
      #|  SELECT
      #|    2
      #|), tbl3 /* comment for tbl3 */ AS (
      #|  SELECT
      #|    3
      #|)
      #|/* comment for final select */
      #|SELECT
      #|  *
      #|FROM tbl1
    ),
    pretty=true,
  )
  t.validate(
    (
      #|
      #|            WITH x /* a */ AS (
      #|              SELECT 2 AS n /* b */
      #|              FROM (/* c */ SELECT /* c2 */ a /* d */ FROM t) AS x
      #|            )
      #|            SELECT * FROM x /* e */
      #|            WHERE n >= (/* f */ SELECT MAX(x) FROM t)
      #|            ORDER BY n /* g */
      #|            -- h
      #|            
    ),
    (
      #|WITH x /* a */ AS (
      #|  SELECT
      #|    2 AS n /* b */
      #|  FROM (
      #|    /* c */
      #|    /* c2 */
      #|    SELECT
      #|      a /* d */
      #|    FROM t
      #|  ) AS x
      #|)
      #|SELECT
      #|  *
      #|FROM x /* e */
      #|WHERE
      #|  n >= (
      #|    SELECT
      #|      MAX(x)
      #|    FROM t
      #|  ) /* f */
      #|ORDER BY
      #|  n /* g */ /* h */
    ),
    pretty=true,
  )
  t.validate(
    "SELECT a /* foo */ /* bar */ FROM tbl",
    (
      #|SELECT
      #|  a /* foo */ /* bar */
      #|FROM tbl
    ),
    pretty=true,
  )
  t.validate(
    "SELECT x FROM t WHERE x = 1 /* a */ /* b */ /* c */",
    (
      #|SELECT
      #|  x
      #|FROM t
      #|WHERE
      #|  x = 1 /* a */ /* b */ /* c */
    ),
    pretty=true,
  )
  t.validate(
    (
      #|SELECT
      #|  *
      #|FROM x
      #|WHERE
      #|  a = 1 AND /*
      #|  hello
      #|  world
      #|*/ 1 = 0
    ),
    (
      #|SELECT
      #|  *
      #|FROM x
      #|WHERE
      #|  a = 1 AND /*
      #|  hello
      #|  world
      #|*/ 1 = 0
    ),
    pretty=true,
  )
  t.validate(
    (
      #|SELECT
      #|  *
      #|FROM x
      #|WHERE
      #|  a = 1
      #|  AND /*
      #|  line1
      #|
      #|  line3
      #|*/ b = 2
    ),
    (
      #|SELECT
      #|  *
      #|FROM x
      #|WHERE
      #|  a = 1
      #|  AND /*
      #|  line1
      #|
      #|  line3
      #|*/ b = 2
    ),
    pretty=true,
  )
  t.done()
}

///|
test "TestTranspile.test_comment_single_line_with_block_close" {
  let t = t()
  t.validate(
    (
      #|-- aa */ SELECT * FROM secret_table --
      #|SELECT 1
    ),
    "/* aa * / SELECT * FROM secret_table -- */ SELECT 1",
  )
  t.validate(
    (
      #|-- comment */ DROP TABLE users --
      #|SELECT 1
    ),
    "/* comment * / DROP TABLE users -- */ SELECT 1",
  )
  t.validate("SELECT c /* c1 /* c2 */ c3 */", "SELECT c /* c1 / * c2 * / c3 */")
  t.validate(
    "SELECT c /* c1 /* c2 /* c3 */ */ */", "SELECT c /* c1 / * c2 / * c3 * / * / */",
  )
  t.done()
}

///|
test "TestTranspile.test_types" {
  let t = t()
  t.validate("INT 1", "CAST(1 AS INT)")
  t.validate("VARCHAR 'x' y", "CAST('x' AS VARCHAR) AS y")
  t.validate("STRING 'x' y", "CAST('x' AS TEXT) AS y")
  t.validate("x::INT", "CAST(x AS INT)")
  t.validate("x::INTEGER", "CAST(x AS INT)")
  t.validate("x::INT y", "CAST(x AS INT) AS y")
  t.validate("x::INT AS y", "CAST(x AS INT) AS y")
  t.validate("x::INT::BOOLEAN", "CAST(CAST(x AS INT) AS BOOLEAN)")
  t.validate("interval::int", "CAST(interval AS INT)")
  t.validate("x::user_defined_type", "CAST(x AS user_defined_type)")
  t.validate("CAST(x::INT AS BOOLEAN)", "CAST(CAST(x AS INT) AS BOOLEAN)")
  t.validate("CAST(x AS INT)::BOOLEAN", "CAST(CAST(x AS INT) AS BOOLEAN)")
  t.raises_parse(() => ignore(@sqlglot.transpile("x::z", read="clickhouse")))
  |> ignore
  t.done()
}

///|
test "TestTranspile.test_not_range" {
  let t = t()
  t.validate("a NOT LIKE b", "a NOT LIKE b")
  t.validate("a NOT BETWEEN b AND c", "NOT a BETWEEN b AND c")
  t.validate("a NOT IN (1, 2)", "NOT a IN (1, 2)")
  t.validate("a IS NOT NULL", "NOT a IS NULL")
  t.validate("a LIKE TEXT 'y'", "a LIKE CAST('y' AS TEXT)")
  t.done()
}

///|
test "TestTranspile.test_extract" {
  let t = t()
  t.validate(
    "EXTRACT(day FROM '2020-01-01'::TIMESTAMP)", "EXTRACT(DAY FROM CAST('2020-01-01' AS TIMESTAMP))",
  )
  t.validate(
    "EXTRACT(timezone FROM '2020-01-01'::TIMESTAMP)", "EXTRACT(TIMEZONE FROM CAST('2020-01-01' AS TIMESTAMP))",
  )
  t.validate(
    "EXTRACT(year FROM '2020-01-01'::TIMESTAMP WITH TIME ZONE)", "EXTRACT(YEAR FROM CAST('2020-01-01' AS TIMESTAMPTZ))",
  )
  t.validate(
    "extract(month from '2021-01-31'::timestamp without time zone)", "EXTRACT(MONTH FROM CAST('2021-01-31' AS TIMESTAMP))",
  )
  t.validate(
    "extract(week from current_date + 2)", "EXTRACT(WEEK FROM CURRENT_DATE + 2)",
  )
  t.validate(
    "EXTRACT(minute FROM datetime1 - datetime2)", "EXTRACT(MINUTE FROM datetime1 - datetime2)",
  )
  t.done()
}

///|
test "TestTranspile.test_if" {
  let t = t()
  t.validate(
    "SELECT IF(a > 1, 1, 0) FROM foo", "SELECT CASE WHEN a > 1 THEN 1 ELSE 0 END FROM foo",
  )
  t.validate("SELECT IF a > 1 THEN b END", "SELECT CASE WHEN a > 1 THEN b END")
  t.validate(
    "SELECT IF a > 1 THEN b ELSE c END", "SELECT CASE WHEN a > 1 THEN b ELSE c END",
  )
  t.validate(
    "SELECT IF(a > 1, 1) FROM foo", "SELECT CASE WHEN a > 1 THEN 1 END FROM foo",
  )
  t.done()
}

///|
test "TestTranspile.test_with" {
  let t = t()
  t.validate(
    "WITH a AS (SELECT 1) WITH b AS (SELECT 2) SELECT *", "WITH a AS (SELECT 1), b AS (SELECT 2) SELECT *",
  )
  t.validate(
    "WITH a AS (SELECT 1), WITH b AS (SELECT 2) SELECT *", "WITH a AS (SELECT 1), b AS (SELECT 2) SELECT *",
  )
  t.validate(
    "WITH A(filter) AS (VALUES 1, 2, 3) SELECT * FROM A WHERE filter >= 2",
    "WITH A(filter) AS (SELECT * FROM (VALUES (1), (2), (3)) AS _values) SELECT * FROM A WHERE filter >= 2",
    read="presto",
  )
  t.validate(
    "SELECT 1 UNION ALL VALUES (2)", "SELECT 1 UNION ALL SELECT * FROM (VALUES (2)) AS _values",
  )
  t.validate(
    "VALUES (1) AS v(a) UNION ALL SELECT 2", "SELECT * FROM (VALUES (1)) AS v(a) UNION ALL SELECT 2",
  )
  t.validate(
    "VALUES (1) UNION SELECT * FROM x", "SELECT * FROM (VALUES (1)) AS _values UNION SELECT * FROM x",
  )
  t.validate(
    "WITH RECURSIVE T(n) AS (VALUES (1) UNION ALL SELECT n + 1 FROM t WHERE n < 100) SELECT SUM(n) FROM t",
    "WITH RECURSIVE T(n) AS (SELECT * FROM (VALUES (1)) AS _values UNION ALL SELECT n + 1 FROM t WHERE n < 100) SELECT SUM(n) FROM t",
  )
  t.validate(
    "SELECT BOOL_OR(a > 10) FROM (VALUES 1, 2, 15) AS T(a)",
    "SELECT BOOL_OR(a > 10) FROM (VALUES (1), (2), (15)) AS T(a)",
    read="presto",
  )
  t.done()
}

///|
test "TestTranspile.test_alter" {
  let t = t()
  t.validate(
    "ALTER TABLE integers ADD k INTEGER", "ALTER TABLE integers ADD COLUMN k INT",
  )
  t.validate(
    "ALTER TABLE integers ALTER i TYPE VARCHAR", "ALTER TABLE integers ALTER COLUMN i SET DATA TYPE VARCHAR",
  )
  t.validate(
    "ALTER TABLE integers ALTER i TYPE VARCHAR COLLATE foo USING bar", "ALTER TABLE integers ALTER COLUMN i SET DATA TYPE VARCHAR COLLATE foo USING bar",
  )
  t.done()
}

///|
test "TestTranspile.test_time" {
  let t = t()
  t.validate("INTERVAL '1 day'", "INTERVAL '1' DAY")
  t.validate("INTERVAL '1 days' * 5", "INTERVAL '1' DAYS * 5")
  t.validate("5 * INTERVAL '1 day'", "5 * INTERVAL '1' DAY")
  t.validate("INTERVAL 1 day", "INTERVAL '1' DAY")
  t.validate("INTERVAL 2 months", "INTERVAL '2' MONTHS")
  t.validate("TIMESTAMP '2020-01-01'", "CAST('2020-01-01' AS TIMESTAMP)")
  t.validate(
    "TIMESTAMP WITH TIME ZONE '2020-01-01'", "CAST('2020-01-01' AS TIMESTAMPTZ)",
  )
  t.validate(
    "TIMESTAMP(9) WITH TIME ZONE '2020-01-01'", "CAST('2020-01-01' AS TIMESTAMPTZ(9))",
  )
  t.validate(
    "TIMESTAMP WITHOUT TIME ZONE '2020-01-01'", "CAST('2020-01-01' AS TIMESTAMP)",
  )
  t.validate("'2020-01-01'::TIMESTAMP", "CAST('2020-01-01' AS TIMESTAMP)")
  t.validate(
    "'2020-01-01'::TIMESTAMP WITHOUT TIME ZONE", "CAST('2020-01-01' AS TIMESTAMP)",
  )
  t.validate(
    "'2020-01-01'::TIMESTAMP WITH TIME ZONE", "CAST('2020-01-01' AS TIMESTAMPTZ)",
  )
  t.validate(
    "timestamp with time zone '2025-11-20 00:00:00+00' AT TIME ZONE 'Africa/Cairo'",
    "CAST('2025-11-20 00:00:00+00' AS TIMESTAMPTZ) AT TIME ZONE 'Africa/Cairo'",
  )
  t.validate("DATE '2020-01-01'", "CAST('2020-01-01' AS DATE)")
  t.validate("'2020-01-01'::DATE", "CAST('2020-01-01' AS DATE)")
  t.validate("STR_TO_TIME('x', 'y')", "STRPTIME('x', 'y')", write="duckdb")
  t.validate(
    "STR_TO_UNIX('x', 'y')",
    "EPOCH(STRPTIME('x', 'y'))",
    write="duckdb",
  )
  t.validate("TIME_TO_STR(x, 'y')", "STRFTIME(x, 'y')", write="duckdb")
  t.validate("TIME_TO_UNIX(x)", "EPOCH(x)", write="duckdb")
  t.validate(
    "UNIX_TO_STR(123, 'y')",
    "STRFTIME(TO_TIMESTAMP(123), 'y')",
    write="duckdb",
  )
  t.validate("UNIX_TO_TIME(123)", "TO_TIMESTAMP(123)", write="duckdb")
  t.validate(
    "STR_TO_TIME(x, 'y')",
    "CAST(FROM_UNIXTIME(UNIX_TIMESTAMP(x, 'y')) AS TIMESTAMP)",
    write="hive",
  )
  t.validate(
    "STR_TO_TIME(x, 'yyyy-MM-dd HH:mm:ss')",
    "CAST(x AS TIMESTAMP)",
    write="hive",
  )
  t.validate(
    "STR_TO_TIME(x, 'yyyy-MM-dd')",
    "CAST(x AS TIMESTAMP)",
    write="hive",
  )
  t.validate("STR_TO_UNIX('x', 'y')", "UNIX_TIMESTAMP('x', 'y')", write="hive")
  t.validate("TIME_TO_STR(x, 'y')", "DATE_FORMAT(x, 'y')", write="hive")
  t.validate("TIME_STR_TO_TIME(x)", "TIME_STR_TO_TIME(x)")
  t.validate(
    "TIME_STR_TO_TIME(x, 'America/Los_Angeles')", "TIME_STR_TO_TIME(x, 'America/Los_Angeles')",
  )
  t.validate("TIME_STR_TO_UNIX(x)", "TIME_STR_TO_UNIX(x)")
  t.validate("TIME_TO_TIME_STR(x)", "CAST(x AS TEXT)")
  t.validate("TIME_TO_STR(x, 'y')", "TIME_TO_STR(x, 'y')")
  t.validate("TIME_TO_UNIX(x)", "TIME_TO_UNIX(x)")
  t.validate("UNIX_TO_STR(x, 'y')", "UNIX_TO_STR(x, 'y')")
  t.validate("UNIX_TO_TIME(x)", "UNIX_TO_TIME(x)")
  t.validate("UNIX_TO_TIME_STR(x)", "UNIX_TO_TIME_STR(x)")
  t.validate("TIME_STR_TO_DATE(x)", "TIME_STR_TO_DATE(x)")
  t.validate("TIME_STR_TO_DATE(x)", "TO_DATE(x)", write="hive")
  t.validate(
    "UNIX_TO_STR(x, 'yyyy-MM-dd HH:mm:ss')",
    "FROM_UNIXTIME(x)",
    write="hive",
  )
  t.validate(
    "STR_TO_UNIX(x, 'yyyy-MM-dd HH:mm:ss')",
    "UNIX_TIMESTAMP(x)",
    write="hive",
  )
  t.validate("IF(x > 1, x + 1)", "IF(x > 1, x + 1)", write="presto")
  t.validate("IF(x > 1, 1 + 1)", "IF(x > 1, 1 + 1)", write="hive")
  t.validate("IF(x > 1, 1, 0)", "IF(x > 1, 1, 0)", write="hive")
  t.validate("TIME_TO_UNIX(x)", "UNIX_TIMESTAMP(x)", write="hive")
  t.validate("UNIX_TO_STR(123, 'y')", "FROM_UNIXTIME(123, 'y')", write="hive")
  t.validate("UNIX_TO_TIME(123)", "FROM_UNIXTIME(123)", write="hive")
  t.validate("STR_TO_TIME('x', 'y')", "DATE_PARSE('x', 'y')", write="presto")
  t.validate(
    "STR_TO_UNIX('x', 'y')",
    "TO_UNIXTIME(COALESCE(TRY(DATE_PARSE(CAST('x' AS VARCHAR), 'y')), PARSE_DATETIME(DATE_FORMAT(CAST('x' AS TIMESTAMP), 'y'), 'y')))",
    write="presto",
  )
  t.validate("TIME_TO_STR(x, 'y')", "DATE_FORMAT(x, 'y')", write="presto")
  t.validate("TIME_TO_UNIX(x)", "TO_UNIXTIME(x)", write="presto")
  t.validate(
    "UNIX_TO_STR(123, 'y')",
    "DATE_FORMAT(FROM_UNIXTIME(123), 'y')",
    write="presto",
  )
  t.validate("UNIX_TO_TIME(123)", "FROM_UNIXTIME(123)", write="presto")
  t.validate("STR_TO_TIME('x', 'y')", "TO_TIMESTAMP('x', 'y')", write="spark")
  t.validate("STR_TO_UNIX('x', 'y')", "UNIX_TIMESTAMP('x', 'y')", write="spark")
  t.validate("TIME_TO_STR(x, 'y')", "DATE_FORMAT(x, 'y')", write="spark")
  t.validate("TIME_TO_UNIX(x)", "UNIX_TIMESTAMP(x)", write="spark")
  t.validate("UNIX_TO_STR(123, 'y')", "FROM_UNIXTIME(123, 'y')", write="spark")
  t.validate(
    "UNIX_TO_TIME(123)",
    "CAST(FROM_UNIXTIME(123) AS TIMESTAMP)",
    write="spark",
  )
  t.validate(
    "CREATE TEMPORARY TABLE test AS SELECT 1",
    "CREATE TEMPORARY VIEW test AS SELECT 1",
    write="spark2",
  )
  t.done()
}

///|
test "TestTranspile.test_index_offset" {
  let t = t()
  @core.take_log_messages() |> ignore
  t.validate("x[0]", "x[1]", write="presto", identity=false)
  t.validate("x[1]", "x[0]", read="presto", identity=false)
  t.validate("x[x - 1]", "x[x - 1]", write="presto", identity=false)
  // SKIP: needs the optimizer (annotate_types + simplify) to type/fold the index:
  // self.validate("x[array_size(y) - 1]", "x[(CARDINALITY(y) - 1) + 1]", write="presto", identity=False)
  // self.validate("x[3 - 1]", "x[3]", write="presto", identity=False)
  t.validate("MAP(a, b)[0]", "MAP(a, b)[0]", write="presto", identity=false)
  // SKIP: the expected log lists 4 "Applying array index offset" entries, 2 of which
  // come from the skipped (optimizer-dependent) cases above; check the first two.
  t.eq(logged("INFO").map(m => "INFO:sqlglot:" + m), [
    "INFO:sqlglot:Applying array index offset (1)", "INFO:sqlglot:Applying array index offset (-1)",
  ])
  t.done()
}

///|
test "TestTranspile.test_identify_lambda" {
  let t = t()
  t.validate("x(y -> y)", "X(\"y\" -> \"y\")", identify=true)
  t.done()
}

///|
test "TestTranspile.test_identity" {
  let t = t()
  t.eqf(() => @sqlglot.transpile("")[0], "")
  for sql in identity_fixtures {
    t.eqf(() => @sqlglot.transpile(sql)[0], sql.trim().to_string())
  }
  t.done()
}

///|
test "TestTranspile.test_command_identity" {
  let t = t()
  for
    sql in [
      "ALTER AGGREGATE bla(foo) OWNER TO CURRENT_USER", "ALTER DOMAIN foo VALIDATE CONSTRAINT bla",
      "ALTER ROLE CURRENT_USER WITH REPLICATION", "ALTER RULE foo ON bla RENAME TO baz",
      "ALTER SEQUENCE IF EXISTS baz RESTART WITH boo", "ALTER TABLE integers DROP PRIMARY KEY",
      "ALTER TABLE table1 MODIFY COLUMN name1 SET TAG foo='bar'", "ALTER TABLE table1 RENAME COLUMN c1 AS c2",
      "ALTER TABLE table1 RENAME COLUMN c1 TO c2, c2 TO c3", "ALTER TABLE table1 RENAME COLUMN c1 c2",
      "ALTER TYPE electronic_mail RENAME TO email", "ALTER schema doo", "CALL catalog.system.iceberg_procedure_name(named_arg_1 => 'arg_1', named_arg_2 => 'arg_2')",
      "COMMENT ON ACCESS METHOD gin IS 'GIN index access method'", "CREATE OR REPLACE STAGE",
      "EXECUTE statement", "EXPLAIN SELECT * FROM x", "LOAD foo", "OPTIMIZE TABLE y",
      "PREPARE statement", "SET -v", "SET @user OFF", "SHOW TABLES", "VACUUM FREEZE my_table",
    ] {
    @core.take_log_messages() |> ignore
    t.eqf(() => @sqlglot.transpile(sql)[0], sql)
    let output = logged("WARNING")
    let prefix = if sql.length() > 100 {
      sql.unsafe_substring(start=0, end=100)
    } else {
      sql
    }
    t.ok(
      output.length() > 0 &&
      output[0].contains("'\{prefix}' contains unsupported syntax"),
      msg="\{sql}: missing unsupported syntax warning in \{output}",
    )
  }
  t.done()
}

///|
test "TestTranspile.test_normalize_name" {
  let t = t()
  t.eqf(
    () => {
      @sqlglot.transpile(
        "cardinality(x)",
        read="presto",
        write="presto",
        normalize_functions="lower",
      )[0]
    },
    "cardinality(x)",
  )
  t.done()
}

///|
test "TestTranspile.test_partial" {
  let t = t()
  for sql in partial_fixtures {
    t.eqf(
      () => @sqlglot.transpile(sql, error_level=@core.Ignore)[0],
      sql.trim().to_string(),
    )
  }
  t.done()
}

///|
test "TestTranspile.test_pretty" {
  let t = t()
  for i = 0; i < pretty_fixtures.length(); i = i + 2 {
    let sql = pretty_fixtures[i]
    let pretty = pretty_fixtures[i + 1]
    t.eqf(() => @sqlglot.transpile(sql, pretty=true)[0], pretty)
    match t.run(() => (@sqlglot.parse_one(sql), @sqlglot.parse_one(pretty))) {
      Some((a, b)) => t.eq_expr(a, b)
      None => ()
    }
  }
  t.done()
}

///|
test "TestTranspile.test_pretty_line_breaks" {
  let t = t()
  t.eqf(
    () => {
      @sqlglot.transpile(
        (
          #|SELECT '1
          #|2'
        ),
        pretty=true,
      )[0]
    },
    (
      #|SELECT
      #|  '1
      #|2'
    ),
  )
  t.eqf(
    () => {
      @sqlglot.transpile(
        (
          #|SELECT '1
          #|2'
        ),
        pretty=true,
        unsupported_level=@core.Ignore,
      )[0]
    },
    (
      #|SELECT
      #|  '1
      #|2'
    ),
  )
  t.eqf(
    () => {
      @sqlglot.transpile(
        (
          #|SELECT "1
          #|2"
        ),
        pretty=true,
      )[0]
    },
    (
      #|SELECT
      #|  "1
      #|2"
    ),
  )
  t.eqf(
    () => {
      @sqlglot.transpile(
        (
          #|SELECT "Product
          #|(Foo, Bar)" AS x FROM t
        ),
        pretty=true,
      )[0]
    },
    (
      #|SELECT
      #|  "Product
      #|(Foo, Bar)" AS x
      #|FROM t
    ),
  )
  t.done()
}

///|
test "TestTranspile.test_sql_security" {
  let t = t()
  let sqlglot_sql = "CREATE VIEW v SQL SECURITY INVOKER AS SELECT 1"
  for
    case in [
      ("clickhouse", "CREATE VIEW v SQL SECURITY INVOKER AS SELECT 1"),
      ("trino", "CREATE VIEW v SECURITY INVOKER AS SELECT 1"),
      ("presto", "CREATE VIEW v SECURITY INVOKER AS SELECT 1"),
      ("starrocks", "CREATE VIEW v SECURITY INVOKER AS SELECT 1"),
      ("mysql", "CREATE SQL SECURITY INVOKER VIEW v AS SELECT 1"),
    ] {
    let (dialect, sql) = case
    t.validate(sql, sqlglot_sql, read=dialect, identity=false)
    t.validate(sql, sql, write=dialect, identity=false)
  }
  t.done()
}

///|
test "TestTranspile.test_error_level" {
  let t = t()
  let invalid = "x + 1. ("
  let expected_messages = [
    "Required keyword: 'expressions' missing for <class 'sqlglot.expressions.core.Aliases'>. Line 1, Col: 8.\n  x + 1. \u{1b}[4m(\u{1b}[0m",
    "Expecting ). Line 1, Col: 8.\n  x + 1. \u{1b}[4m(\u{1b}[0m",
  ]
  let expected_errors = [
    info(
      "Required keyword: 'expressions' missing for <class 'sqlglot.expressions.core.Aliases'>",
      1, 8, "x + 1. ", "(", "",
    ),
    info("Expecting )", 1, 8, "x + 1. ", "(", ""),
  ].map(info_repr)
  @core.take_log_messages() |> ignore
  t.run(() => ignore(@sqlglot.transpile(invalid, error_level=@core.Warn)))
  |> ignore
  let output = logged("ERROR").join("\n")
  for error in expected_messages {
    t.ok(output.contains(error), msg="Expected '\{error}' not in \{output}")
  }
  let e = t.raises_parse(() => {
    ignore(@sqlglot.transpile(invalid, error_level=@core.Immediate))
  })
  t.eq(msg_of(e), expected_messages[0])
  t.eq(errors_of(e).get(0).unwrap_or(""), expected_errors[0])
  let e = t.raises_parse(() => {
    ignore(@sqlglot.transpile(invalid, error_level=@core.Raise))
  })
  t.eq(msg_of(e), expected_messages.join("\n\n"))
  t.eq(errors_of(e), expected_errors)
  let more_than_max_errors = "(((("
  let expected_messages = "Required keyword: 'this' missing for <class 'sqlglot.expressions.core.Paren'>. Line 1, Col: 4.\n  (((\u{1b}[4m(\u{1b}[0m\n\n" +
    "Expecting ). Line 1, Col: 4.\n  (((\u{1b}[4m(\u{1b}[0m\n\n" +
    "Expecting ). Line 1, Col: 4.\n  (((\u{1b}[4m(\u{1b}[0m\n\n" +
    "... and 2 more"
  let expected_errors = [
    info(
      "Required keyword: 'this' missing for <class 'sqlglot.expressions.core.Paren'>",
      1, 4, "(((", "(", "",
    ),
    info("Expecting )", 1, 4, "(((", "(", ""),
  ].map(info_repr)
  // Also expect three trailing structured errors that match the first
  let expected_errors = expected_errors +
    [expected_errors[1], expected_errors[1], expected_errors[1]]
  let e = t.raises_parse(() => {
    ignore(@sqlglot.transpile(more_than_max_errors, error_level=@core.Raise))
  })
  t.eq(msg_of(e), expected_messages)
  t.eq(errors_of(e), expected_errors)
  t.done()
}

///|
test "TestTranspile.test_unsupported_level" {
  let t = t()
  fn unsupported(level : @core.ErrorLevel) -> Unit raise {
    @sqlglot.transpile(
      "SELECT MAP(a, b), MAP(a, b), MAP(a, b), MAP(a, b)",
      read="presto",
      write="hive",
      unsupported_level=level,
    )
    |> ignore
  }

  let error = "Cannot convert array columns into map."
  @core.take_log_messages() |> ignore
  t.run(() => unsupported(@core.Warn)) |> ignore
  let output = logged("WARNING").join("\n")
  let expected = [error, error, error, error].join("\n")
  t.ok(output.contains(expected), msg="Expected '\{expected}' not in \{output}")
  fn count(s : String, sub : String) -> Int {
    s.split(sub).count() - 1
  }

  match t.raises(() => unsupported(@core.Raise)) {
    Some(@core.UnsupportedError(m)) => t.eq(count(m, error), 3)
    e => t.ok(false, msg="expected UnsupportedError, got \{e}")
  }
  match t.raises(() => unsupported(@core.Immediate)) {
    Some(@core.UnsupportedError(m)) => t.eq(count(m, error), 1)
    e => t.ok(false, msg="expected UnsupportedError, got \{e}")
  }
  t.done()
}

///|
test "TestTranspile.test_recursion" {
  let sql = "1 AND 2 OR 3 AND ".repeat(1000) + "4"
  assert_eq(gen(@sqlglot.parse_one(sql)).length(), 17001)
}

///|
/// Python's error dict: `{"description": ..., "line": ..., ...}`.
fn info(
  description : String,
  line : Int,
  col : Int,
  start_context : String,
  highlight : String,
  end_context : String,
  into_expression? : String,
) -> @core.ParseErrorInfo {
  {
    description,
    line,
    col,
    start_context,
    highlight,
    end_context,
    into_expression,
  }
}

///|
fn info_repr(i : @core.ParseErrorInfo) -> String {
  let into = match i.into_expression {
    Some(k) => k
    None => "None"
  }
  "{description: \{i.description.escape()}, line: \{i.line}, col: \{i.col}, start_context: \{i.start_context.escape()}, highlight: \{i.highlight.escape()}, end_context: \{i.end_context.escape()}, into_expression: \{into}}"
}

///|
/// `ctx.exception.errors` of a ParseError.
fn errors_of(e : @core.SqlglotError?) -> Array[String] {
  match e {
    Some(@core.ParseError(_, infos)) => infos.map(info_repr)
    _ => []
  }
}
