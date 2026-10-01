// Port of tests/test_errors.py

///|
const U : String = "\u{1b}[4m"

///|
const R : String = "\u{1b}[0m"

///|
test "TestErrors.test_highlight_sql_single_character" {
  let sql = "SELECT a FROM t"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 7),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "a")
  assert_eq(end_ctx, " FROM t")
  assert_eq(formatted, "SELECT \{U}a\{R} FROM t")
}

///|
test "TestErrors.test_highlight_sql_multi_character" {
  let sql = "SELECT foo FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 9),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "foo")
  assert_eq(end_ctx, " FROM table")
  assert_eq(formatted, "SELECT \{U}foo\{R} FROM table")
}

///|
test "TestErrors.test_highlight_sql_multiple_highlights" {
  let sql = "SELECT a, b, c FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 7),
    (10, 10),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "a, b")
  assert_eq(end_ctx, ", c FROM table")
  assert_eq(formatted, "SELECT \{U}a\{R}, \{U}b\{R}, c FROM table")
}

///|
test "TestErrors.test_highlight_sql_at_end" {
  let sql = "SELECT a FROM t"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (14, 14),
  ])
  assert_eq(start_ctx, "SELECT a FROM ")
  assert_eq(highlight, "t")
  assert_eq(end_ctx, "")
  assert_eq(formatted, "SELECT a FROM \{U}t\{R}")
}

///|
test "TestErrors.test_highlight_sql_entire_string" {
  let sql = "SELECT a"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (0, 7),
  ])
  assert_eq(start_ctx, "")
  assert_eq(highlight, "SELECT a")
  assert_eq(end_ctx, "")
  assert_eq(formatted, "\{U}SELECT a\{R}")
}

///|
test "TestErrors.test_highlight_sql_adjacent_highlights" {
  let sql = "SELECT ab FROM t"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 7),
    (8, 8),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "ab")
  assert_eq(end_ctx, " FROM t")
  assert_eq(formatted, "SELECT \{U}a\{R}\{U}b\{R} FROM t")
}

///|
test "TestErrors.test_highlight_sql_small_context_length" {
  let sql = "SELECT a, b, c FROM table WHERE x = 1"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(
    sql,
    [(7, 7), (10, 10)],
    context_length=5,
  )
  assert_eq(start_ctx, "LECT ")
  assert_eq(highlight, "a, b")
  assert_eq(end_ctx, ", c F")
  assert_eq(formatted, "LECT \{U}a\{R}, \{U}b\{R}, c F")
}

///|
test "TestErrors.test_highlight_sql_empty_positions" {
  let sql = "SELECT a FROM t"
  try @core.highlight_sql(sql, []) catch {
    @core.ValueError(_) => ()
    e => fail("expected ValueError, got \{e}")
  } noraise {
    _ => fail("expected ValueError")
  }
}

///|
test "TestErrors.test_highlight_sql_partial_overlap" {
  let sql = "SELECT foo FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 9),
    (8, 10),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "foo ")
  assert_eq(end_ctx, "FROM table")
  assert_eq(formatted, "SELECT \{U}foo\{R}\{U} \{R}FROM table")
}

///|
test "TestErrors.test_highlight_sql_full_overlap" {
  let sql = "SELECT foobar FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 12),
    (9, 11),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "foobar")
  assert_eq(end_ctx, " FROM table")
  assert_eq(formatted, "SELECT \{U}foobar\{R} FROM table")
}

///|
test "TestErrors.test_highlight_sql_identical_positions" {
  let sql = "SELECT a FROM t"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (7, 7),
    (7, 7),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "a")
  assert_eq(end_ctx, " FROM t")
  assert_eq(formatted, "SELECT \{U}a\{R} FROM t")
}

///|
test "TestErrors.test_highlight_sql_reversed_positions" {
  let sql = "SELECT a, b FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(sql, [
    (10, 10),
    (7, 7),
  ])
  assert_eq(start_ctx, "SELECT ")
  assert_eq(highlight, "a, b")
  assert_eq(end_ctx, " FROM table")
  assert_eq(formatted, "SELECT \{U}a\{R}, \{U}b\{R} FROM table")
}

///|
test "TestErrors.test_highlight_sql_zero_context_length" {
  let sql = "SELECT a, b FROM table"
  let (formatted, start_ctx, highlight, end_ctx) = @core.highlight_sql(
    sql,
    [(7, 7)],
    context_length=0,
  )
  assert_eq(start_ctx, "")
  assert_eq(end_ctx, "")
  assert_eq(highlight, "a")
  assert_eq(formatted, "\{U}a\{R}")
}
