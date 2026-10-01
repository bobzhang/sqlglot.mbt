// Direct assertions of tests/dialects/test_trino.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestTrino.test_concat_ws_typed" {
  let t = t(dialect="trino")
  let spark = @core.Dialect::get_or_raise("spark")
  for case in [
    (
      "ARRAY<STRING>",
      "STRING",
      "CONCAT_WS(t.sep, CONCAT(COALESCE(CAST(t.a AS ARRAY(VARCHAR)), ARRAY[]), " +
      "ARRAY[CAST(t.b AS VARCHAR)]))",
    ),
    (
      "ARRAY<STRING>",
      "ARRAY<STRING>",
      "CONCAT_WS(t.sep, CONCAT(COALESCE(CAST(t.a AS ARRAY(VARCHAR)), ARRAY[]), " +
      "COALESCE(CAST(t.b AS ARRAY(VARCHAR)), ARRAY[])))",
    ),
    (
      "ARRAY<INT>",
      "INT",
      "CONCAT_WS(t.sep, CONCAT(COALESCE(CAST(t.a AS ARRAY(VARCHAR)), ARRAY[]), " +
      "ARRAY[CAST(t.b AS VARCHAR)]))",
    ),
  ] {
    let (a_type, b_type, expected) = case
    let schema = @optimizer.MappingSchema::new(
      schema=@optimizer.schema_from_json_string(
        "{\"t\": {\"sep\": \"STRING\", \"a\": \"\{a_type}\", \"b\": \"\{b_type}\"}}",
      ),
      dialect=spark,
    )
    let expression = @optimizer.annotate_types(
      parse_one("SELECT CONCAT_WS(t.sep, t.a, t.b) FROM t", read="spark"),
      schema~,
      dialect=spark,
    )
    t.eqf(
      () => sql(expression, dialect="trino", unsupported_level=Raise),
      "SELECT \{expected} FROM t",
    )
  }
  t.done()
}

///|
test "TestTrino.test_concat_ws_unknown_types" {
  let t = t(dialect="trino")
  for sql_ in [
    "SELECT CONCAT_WS('-', t.a, t.b) FROM t", "SELECT CONCAT_WS('-', ARRAY('a'), t.b) FROM t",
  ] {
    for annotated in [false, true] {
      let mut expression = parse_one(sql_, read="spark")
      if annotated {
        expression = @optimizer.annotate_types(
          expression,
          dialect=@core.Dialect::get_or_raise("spark"),
        )
      }
      let logs = t.assert_logs(() => ignore(sql(expression, dialect="trino")))
      t.contains(
        logs.get(0).unwrap_or(""),
        "CONCAT_WS with unknown argument types",
      )
      t.raises(
        () => ignore(sql(expression, dialect="trino", unsupported_level=Raise)),
        "UnsupportedError",
        contains="unknown argument types",
      )
      |> ignore
    }
  }
  t.done()
}

///|
test "TestTrino.test_inline_udf" {
  let t = t(dialect="trino")
  t.ok(
    t.validate_identity("SELECT NOT deterministic FROM t").selects()[0].kind.is_a(
      Not,
    ),
  )
  t.done()
}

///|
test "TestTrino.test_inline_udf_begin_end" {
  let t = t(dialect="trino")
  // A Block built without begin=True must not get a synthesized BEGIN
  t.eq(
    sql(
      @core.mk(Block, [
        (
          "expressions",
          [parse_one("SELECT 1"), parse_one("SELECT 2"), @core.mk0(EndStatement)],
        ),
      ]),
      dialect="trino",
    ),
    "SELECT 1; SELECT 2; END",
  )
  t.done()
}

///|
test "TestTrino.test_inline_udf_loop_repeat" {
  let t = t(dialect="trino")
  let loop_ast = t.validate_identity(
    "WITH FUNCTION to_one_hundred(start_value BIGINT, step BIGINT) RETURNS BIGINT " +
    "BEGIN DECLARE count BIGINT DEFAULT 0; DECLARE current BIGINT DEFAULT 0; " +
    "SET current = start_value; " +
    "abc: LOOP IF current >= 100 THEN LEAVE abc; END IF; " +
    "SET count = count + 1; SET current = current + step; END LOOP; " +
    "RETURN count; END " +
    "SELECT TO_ONE_HUNDRED(0, 10)",
  )
  let repeat_ast = t.validate_identity(
    "WITH FUNCTION iter_count() RETURNS BIGINT " +
    "BEGIN DECLARE a BIGINT DEFAULT 0; DECLARE b BIGINT DEFAULT 0; " +
    "top: REPEAT SET a = a + 1; IF a <= 3 THEN ITERATE top; END IF; SET b = b + 1; " +
    "UNTIL a >= 10 END REPEAT; " +
    "RETURN b; END " +
    "SELECT ITER_COUNT()",
  )
  // The base generator warns on these Trino-specific routine statements
  let nodes = [
    ..loop_ast.find_all([LoopBlock, Leave]).to_array(),
    ..repeat_ast.find_all([RepeatBlock, Iterate]).to_array(),
  ]
  for node in nodes {
    let cm = t.assert_logs(level="WARNING", () => t.eq(sql(node), ""))
    t.contains(cm.get(0).unwrap_or(""), "Unsupported")
  }
  t.done()
}
