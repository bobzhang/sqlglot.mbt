// Direct assertions of tests/dialects/test_mysql.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestMySQL.test_show_simple" {
  let t = t(dialect="mysql")
  for
    case in [
      ("BINARY LOGS", "BINARY LOGS"),
      ("MASTER LOGS", "BINARY LOGS"),
      ("STORAGE ENGINES", "ENGINES"),
      ("ENGINES", "ENGINES"),
      ("EVENTS", "EVENTS"),
      ("MASTER STATUS", "MASTER STATUS"),
      ("PLUGINS", "PLUGINS"),
      ("PRIVILEGES", "PRIVILEGES"),
      ("PROFILES", "PROFILES"),
      ("REPLICAS", "REPLICAS"),
      ("SLAVE HOSTS", "REPLICAS"),
    ] {
    let (key, write_key) = case
    let show = t.validate_identity("SHOW \{key}", write_sql="SHOW \{write_key}")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), write_key)
  }
  t.done()
}

///|
test "TestMySQL.test_show_events" {
  let t = t(dialect="mysql")
  for key in ["BINLOG", "RELAYLOG"] {
    let show = t.validate_identity("SHOW \{key} EVENTS")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), "\{key} EVENTS")
    let show = t.validate_identity(
      "SHOW \{key} EVENTS IN 'log' FROM 1 LIMIT 2, 3",
    )
    t.eq(show.text("log"), "log")
    t.eq(show.text("position"), "1")
    t.eq(show.text("limit"), "3")
    t.eq(show.text("offset"), "2")
    let show = t.validate_identity("SHOW \{key} EVENTS LIMIT 1")
    t.eq(show.text("limit"), "1")
    t.ok(show.get("offset") is None)
  }
  t.done()
}

///|
test "TestMySQL.test_show_like_or_where" {
  let t = t(dialect="mysql")
  for
    case in [
      ("CHARSET", "CHARACTER SET"),
      ("CHARACTER SET", "CHARACTER SET"),
      ("COLLATION", "COLLATION"),
      ("DATABASES", "DATABASES"),
      ("SCHEMAS", "DATABASES"),
      ("FUNCTION STATUS", "FUNCTION STATUS"),
      ("PROCEDURE STATUS", "PROCEDURE STATUS"),
      ("GLOBAL STATUS", "GLOBAL STATUS"),
      ("SESSION STATUS", "STATUS"),
      ("STATUS", "STATUS"),
      ("GLOBAL VARIABLES", "GLOBAL VARIABLES"),
      ("SESSION VARIABLES", "VARIABLES"),
      ("VARIABLES", "VARIABLES"),
    ] {
    let (key, write_key) = case
    // write_key.strip("GLOBAL").strip()
    let expected_name = @core.py_strip(@core.strip_chars(write_key, "GLOBAL"))
    let show = t.validate_identity("SHOW \{key}", write_sql="SHOW \{write_key}")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), expected_name)
    let show = t.validate_identity(
      "SHOW \{key} LIKE '%foo%'",
      write_sql="SHOW \{write_key} LIKE '%foo%'",
    )
    t.ok(show.kind.is_a(Show))
    t.ok(c_arg_is(show, "like", Literal))
    t.eq(show.text("like"), "%foo%")
    let show = t.validate_identity(
      "SHOW \{key} WHERE Column_name LIKE '%foo%'",
      write_sql="SHOW \{write_key} WHERE Column_name LIKE '%foo%'",
    )
    t.ok(show.kind.is_a(Show))
    t.ok(c_arg_is(show, "where", Where))
    t.eq(c_arg_sql(show, "where"), "WHERE Column_name LIKE '%foo%'")
  }
  t.done()
}

///|
test "TestMySQL.test_show_columns" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW COLUMNS FROM tbl_name")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "COLUMNS")
  t.eq(show.text("target"), "tbl_name")
  t.ok(!c_truthy(show, "full"))
  let show = t.validate_identity(
    "SHOW FULL COLUMNS FROM tbl_name FROM db_name LIKE '%foo%'",
  )
  t.ok(show.kind.is_a(Show))
  t.eq(show.text("target"), "tbl_name")
  t.ok(c_truthy(show, "full"))
  t.eq(show.text("db"), "db_name")
  t.ok(c_arg_is(show, "like", Literal))
  t.eq(show.text("like"), "%foo%")
  t.done()
}

///|
test "TestMySQL.test_show_name" {
  let t = t(dialect="mysql")
  for
    key in [
      "CREATE DATABASE", "CREATE EVENT", "CREATE FUNCTION", "CREATE PROCEDURE", "CREATE TABLE",
      "CREATE TRIGGER", "CREATE VIEW", "FUNCTION CODE", "PROCEDURE CODE",
    ] {
    let show = t.validate_identity("SHOW \{key} foo")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), key)
    t.eq(show.text("target"), "foo")
  }
  t.done()
}

///|
test "TestMySQL.test_show_create_qualified" {
  let t = t(dialect="mysql")
  for
    key in [
      "CREATE TABLE", "CREATE VIEW", "CREATE FUNCTION", "CREATE PROCEDURE",
    ] {
    let show = t.validate_identity("SHOW \{key} db_name.foo")
    t.ok(show.kind.is_a(Show))
    t.eq(show.text("db"), "db_name")
    t.eq(show.text("target"), "foo")
  }
  t.done()
}

///|
test "TestMySQL.test_show_grants" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW GRANTS FOR foo")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "GRANTS")
  t.eq(show.text("target"), "foo")
  t.done()
}

///|
test "TestMySQL.test_show_engine" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW ENGINE foo STATUS")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "ENGINE")
  t.eq(show.text("target"), "foo")
  t.ok(!c_truthy(show, "mutex"))
  let show = t.validate_identity("SHOW ENGINE foo MUTEX")
  t.eq(show.name(), "ENGINE")
  t.eq(show.text("target"), "foo")
  t.ok(c_truthy(show, "mutex"))
  t.done()
}

///|
test "TestMySQL.test_show_errors" {
  let t = t(dialect="mysql")
  for key in ["ERRORS", "WARNINGS"] {
    let show = t.validate_identity("SHOW \{key}")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), key)
    let show = t.validate_identity("SHOW \{key} LIMIT 2, 3")
    t.eq(show.text("limit"), "3")
    t.eq(show.text("offset"), "2")
  }
  t.done()
}

///|
test "TestMySQL.test_show_index" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW INDEX FROM foo")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "INDEX")
  t.eq(show.text("target"), "foo")
  let show = t.validate_identity("SHOW INDEX FROM foo FROM bar")
  t.eq(show.text("db"), "bar")
  t.done()
}

///|
test "TestMySQL.test_show_db_like_or_where_sql" {
  let t = t(dialect="mysql")
  for key in ["OPEN TABLES", "TABLE STATUS", "TRIGGERS"] {
    let show = t.validate_identity("SHOW \{key}")
    t.ok(show.kind.is_a(Show))
    t.eq(show.name(), key)
    let show = t.validate_identity("SHOW \{key} FROM db_name")
    t.eq(show.name(), key)
    t.eq(show.text("db"), "db_name")
    let show = t.validate_identity("SHOW \{key} LIKE '%foo%'")
    t.eq(show.name(), key)
    t.ok(c_arg_is(show, "like", Literal))
    t.eq(show.text("like"), "%foo%")
    let show = t.validate_identity("SHOW \{key} WHERE Column_name LIKE '%foo%'")
    t.eq(show.name(), key)
    t.ok(c_arg_is(show, "where", Where))
    t.eq(c_arg_sql(show, "where"), "WHERE Column_name LIKE '%foo%'")
  }
  t.done()
}

///|
test "TestMySQL.test_show_processlist" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW PROCESSLIST")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "PROCESSLIST")
  t.ok(!c_truthy(show, "full"))
  let show = t.validate_identity("SHOW FULL PROCESSLIST")
  t.eq(show.name(), "PROCESSLIST")
  t.ok(c_truthy(show, "full"))
  t.done()
}

///|
test "TestMySQL.test_show_profile" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW PROFILE")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "PROFILE")
  let show = t.validate_identity("SHOW PROFILE BLOCK IO")
  t.eq(show.list("types")[0].name(), "BLOCK IO")
  let show = t.validate_identity(
    "SHOW PROFILE BLOCK IO, PAGE FAULTS FOR QUERY 1 OFFSET 2 LIMIT 3",
  )
  t.eq(show.list("types")[0].name(), "BLOCK IO")
  t.eq(show.list("types")[1].name(), "PAGE FAULTS")
  t.eq(show.text("query"), "1")
  t.eq(show.text("offset"), "2")
  t.eq(show.text("limit"), "3")
  t.done()
}

///|
test "TestMySQL.test_show_replica_status" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW REPLICA STATUS")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "REPLICA STATUS")
  let show = t.validate_identity(
    "SHOW SLAVE STATUS",
    write_sql="SHOW REPLICA STATUS",
  )
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "REPLICA STATUS")
  let show = t.validate_identity("SHOW REPLICA STATUS FOR CHANNEL channel_name")
  t.eq(show.text("channel"), "channel_name")
  t.done()
}

///|
test "TestMySQL.test_show_tables" {
  let t = t(dialect="mysql")
  let show = t.validate_identity("SHOW TABLES")
  t.ok(show.kind.is_a(Show))
  t.eq(show.name(), "TABLES")
  let show = t.validate_identity("SHOW FULL TABLES FROM db_name LIKE '%foo%'")
  t.ok(c_truthy(show, "full"))
  t.eq(show.text("db"), "db_name")
  t.ok(c_arg_is(show, "like", Literal))
  t.eq(show.text("like"), "%foo%")
  let show = t.validate_identity(
    "SHOW TABLES IN test",
    write_sql="SHOW TABLES FROM test",
  )
  t.eq(show.name(), "TABLES")
  t.eq(show.text("db"), "test")
  let show = t.validate_identity(
    "SHOW FULL TABLES IN test",
    write_sql="SHOW FULL TABLES FROM test",
  )
  t.ok(c_truthy(show, "full"))
  t.eq(show.text("db"), "test")
  t.done()
}

///|
test "TestMySQL.test_set_variable" {
  let t = t(dialect="mysql")
  let cmd = t.parse_one("SET SESSION x = 1")
  let item = cmd.expressions()[0]
  t.eq(item.text("kind"), "SESSION")
  t.ok(item.this_().kind.is_a(EQ))
  t.eq(item.this_().this_().name(), "x")
  t.eq(item.this_().expression_().name(), "1")
  let cmd = t.parse_one("SET @@GLOBAL.x = @@GLOBAL.y")
  let item = cmd.expressions()[0]
  t.eq(item.text("kind"), "")
  t.ok(item.this_().kind.is_a(EQ))
  t.ok(item.this_().this_().kind.is_a(SessionParameter))
  t.ok(item.this_().expression_().kind.is_a(SessionParameter))
  let cmd = t.parse_one("SET NAMES 'charset_name' COLLATE 'collation_name'")
  let item = cmd.expressions()[0]
  t.eq(item.text("kind"), "NAMES")
  t.eq(item.name(), "charset_name")
  t.eq(item.text("collate"), "collation_name")
  let cmd = t.parse_one("SET CHARSET DEFAULT")
  let item = cmd.expressions()[0]
  t.eq(item.text("kind"), "CHARACTER SET")
  t.eq(item.this_().name(), "DEFAULT")
  let cmd = t.parse_one("SET x = 1, y = 2")
  t.eq(cmd.expressions().length(), 2)
  t.done()
}

///|
test "TestMySQL.test_at_time_zone" {
  let t = t(dialect="mysql")
  let cm = t.assert_logs(() => {
    // Check AT TIME ZONE doesnt discard the column name and also raises a warning
    t.validate_identity("SELECT foo AT TIME ZONE 'UTC'", write_sql="SELECT foo")
    |> ignore
  })
  t.contains(cm.get(0).unwrap_or(""), "AT TIME ZONE is not supported")
  t.done()
}

///|
test "TestMySQL.test_explain" {
  let t = t(dialect="mysql")
  let expression = t.parse_one("EXPLAIN ANALYZE SELECT * FROM t")
  t.ok(expression.kind.is_a(Describe))
  t.eq(expression.text("style"), "ANALYZE")
  t.done()
}

///|
test "TestMySQL.test_invisible_column" {
  let t = t(dialect="mysql")
  let expr = t.parse_one("CREATE TABLE t (c INT INVISIBLE)")
  t.ok(expr.find([InvisibleColumnConstraint]) is Some(_))
  let expr = t.parse_one("ALTER TABLE t ADD COLUMN c INT INVISIBLE")
  t.ok(expr.find([InvisibleColumnConstraint]) is Some(_))
  t.done()
}

///|
test "TestMySQL.test_unique_key_index_options" {
  let t = t(dialect="mysql")
  let unique = t
    .parse_one("CREATE TABLE t (a INT, UNIQUE KEY u (a) INVISIBLE)")
    .this_()
    .expressions()[1]
  t.ok(unique.list("options")[0].get("visible") is Some(Bool(false)))
  let columns = t
    .parse_one(
      "CREATE TABLE t (a INT UNIQUE COMMENT 'c', b INT UNIQUE INVISIBLE)",
    )
    .this_()
    .expressions()
  t.ok(
    c_arg_is(columns[0].list("constraints")[1], "kind", CommentColumnConstraint),
  )
  t.ok(
    c_arg_is(
      columns[1].list("constraints")[1],
      "kind",
      InvisibleColumnConstraint,
    ),
  )
  t.done()
}

///|
test "TestMySQL.test_alter_table_auto_increment" {
  let t = t(dialect="mysql")
  let prop = t
    .parse_one("ALTER TABLE t AUTO_INCREMENT=3000000000")
    .find([AutoIncrementProperty])
  t.eq(prop.map(p => p.this_().to_py_int()), Some(Some(3000000000L)))
  t.done()
}

///|
test "TestMySQL.test_mod" {
  let t = t(dialect="mysql")
  t.is_a(Some(t.validate_identity("x % y")), Mod) |> ignore
  t.is_a(Some(t.validate_identity("x MOD y", write_sql="x % y")), Mod) |> ignore
  t.is_a(Some(t.validate_identity("MOD(x, y)", write_sql="x % y")), Mod)
  |> ignore
  t.done()
}

///|
test "TestMySQL.test_numeric_trunc" {
  let t = t(dialect="mysql")
  t.is_a(Some(t.validate_identity("TRUNCATE(3.14159, 2)")), Trunc) |> ignore
  t.is_a(Some(t.validate_identity("TRUNCATE(price, 0)")), Trunc) |> ignore
  t.is_a(
    Some(
      t.validate_identity("TRUNC(3.14159, 2)", write_sql="TRUNCATE(3.14159, 2)"),
    ),
    Trunc,
  )
  |> ignore
  t.done()
}

///|
test "TestMySQL.test_utc_time" {
  let t = t(dialect="mysql")
  t.is_a(Some(t.validate_identity("UTC_TIME()")), UtcTime) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIME(6)")), UtcTime) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIMESTAMP()")), UtcTimestamp) |> ignore
  t.is_a(Some(t.validate_identity("UTC_TIMESTAMP(6)")), UtcTimestamp) |> ignore
  t.done()
}
