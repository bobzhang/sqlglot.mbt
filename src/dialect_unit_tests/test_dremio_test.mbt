// Direct assertions of tests/dialects/test_dremio.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestDremio.test_type_mappings" {
  let t = t(dialect="dremio")
  for sql in ["CAST(x AS TIMESTAMPTZ)", "CAST(x AS TIMESTAMPLTZ)"] {
    t.raises(
      () => {
        ignore(
          @sqlglot.transpile(
            sql,
            read="oracle",
            write="dremio",
            unsupported_level=Immediate,
          ),
        )
      },
      "UnsupportedError",
    )
    |> ignore
  }
  t.done()
}

///|
test "TestDremio.test_typed_division" {
  let t = t(dialect="dremio")
  let div_result_type = (sql : String, dialect : String) => {
    let tree = parse_one(sql, read=dialect)
    @optimizer.annotate_types(tree, dialect=@sqlglot.dialect(dialect)) |> ignore
    tree.find([Div]).unwrap().get_type().unwrap().datatype_this()
  }
  t.eq(div_result_type("SELECT 5 / 2", "dremio"), Some(@core.DType::BIGINT))
  t.eq(div_result_type("SELECT 5 / 2", "oracle"), Some(@core.DType::DOUBLE))
  t.done()
}

///|
test "TestDremio.test_user_defined_types_unsupported" {
  let t = t(dialect="dremio")
  t.raises(() => ignore(t.parse_one("CAST(x AS MY_CUSTOM_TYPE)")), "ParseError")
  |> ignore
  t.done()
}

///|
test "TestDremio.test_time_travel" {
  let t = t(dialect="dremio")
  t.raises(
    () => {
      ignore(
        @sqlglot.transpile(
          "SELECT * FROM t FOR VERSION BETWEEN '1' AND '2'",
          write="dremio",
          unsupported_level=Immediate,
        ),
      )
    },
    "UnsupportedError",
  )
  |> ignore
  t.done()
}

///|
test "TestDremio.test_to_char_special" {
  let t = t(dialect="dremio")
  // numeric formats have is_numeric=True
  for
    sql in [
      "TO_CHAR(5555, '#')", "TO_CHAR(3.14, '#.#')", "TO_CHAR(columnname, '#.##')",
    ] {
    let to_char = t.validate_identity(sql).assert_is(ToChar)
    t.ok(to_char.get("is_numeric") is Some(Bool(true)), msg=sql)
  }
  // non-numeric formats or columns have is_numeric=None or False
  for
    sql in [
      "TO_CHAR(5555)", "TO_CHAR(3.14, columnname)", "TO_CHAR(123, 'abcd')", "TO_CHAR(3.14, UPPER('abcd'))",
    ] {
    let to_char = t.validate_identity(sql).assert_is(ToChar)
    t.ok(!to_char.bool_arg("is_numeric"), msg=sql)
  }
  t.done()
}

///|
test "TestDremio.test_regexp_split" {
  let t = t(dialect="dremio")
  let ast = t.validate_identity(
    "SELECT REGEXP_SPLIT(tags, ',', 'ALL', 1000) AS t",
  )
  let regexp_split = ast.find([RegexpSplit]).unwrap()
  t.eq(regexp_split.text("mode"), "ALL")
  t.eq(regexp_split.text("limit"), "1000")
  // constructed in arg_types order (this, expression, limit, mode)
  let reordered = @core.mk(RegexpSplit, [
    ("this", @core.column_of("tags")),
    ("expression", @core.literal_string(",")),
    ("limit", @core.literal_number("1000")),
    ("mode", @core.literal_string("ALL")),
  ])
  t.eq(sql(reordered, dialect="dremio"), "REGEXP_SPLIT(tags, ',', 'ALL', 1000)")
  t.done()
}
