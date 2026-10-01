// Port of tests/test_generator.py

///|
test "TestGenerator.test_fallback_function_sql" {
  // SKIP: defines a Python subclass of Expression/Func at runtime and registers it in
  // SnowflakeParser.FUNCTIONS; expression kinds are a closed enum in the port.
  ()
}

///|
test "TestGenerator.test_fallback_function_var_args_sql" {
  // SKIP: the SpecialUdf part (runtime Func subclass, see above).
  let t = t()
  t.eqf(
    () => gen(
      @core.mk(DateTrunc, [
        ("this", @core.column_of("event_date")),
        ("unit", @core.var_("MONTH")),
      ]),
    ),
    "DATE_TRUNC('MONTH', event_date)",
  )
  t.done()
}

///|
test "TestGenerator.test_identify" {
  let t = t()
  t.eqf(() => @sqlglot.generate(@sqlglot.parse_one("x"), identify=true), "\"x\"")
  t.eqf(() => @sqlglot.generate(@sqlglot.parse_one("x"), identify=false), "x")
  t.eqf(() => @sqlglot.generate(@sqlglot.parse_one("X"), identify=true), "\"X\"")
  t.eqf(
    () => @sqlglot.generate(@sqlglot.parse_one("\"x\""), identify=false),
    "\"x\"",
  )
  t.eqf(
    () => @sqlglot.generate(@sqlglot.parse_one("x"), identify_mode="safe"),
    "\"x\"",
  )
  t.eqf(
    () => @sqlglot.generate(@sqlglot.parse_one("X"), identify_mode="safe"),
    "X",
  )
  t.eqf(
    () => @sqlglot.generate(@sqlglot.parse_one("x as 1"), identify_mode="safe"),
    "\"x\" AS \"1\"",
  )
  t.eqf(
    () => @sqlglot.generate(@sqlglot.parse_one("X as 1"), identify_mode="safe"),
    "X AS \"1\"",
  )
  t.done()
}

///|
test "TestGenerator.test_generate_nested_binary" {
  let sql = "SELECT 'foo'" + " || 'foo'".repeat(1000)
  assert_eq(@sqlglot.generate(@sqlglot.parse_one(sql), copy=false), sql)
}

///|
test "TestGenerator.test_overlap_operator" {
  let t = t()
  for op in ["&<", "&>"] {
    let input_sql = "SELECT '[1,10]'::int4range \{op} '[5,15]'::int4range"
    let expected_sql = "SELECT CAST('[1,10]' AS INT4RANGE) \{op} CAST('[5,15]' AS INT4RANGE)"
    match t.run(() => @sqlglot.parse_one(input_sql, read="postgres")) {
      Some(ast) => {
        t.eqf(() => gen(ast), expected_sql)
        t.eqf(() => @sqlglot.generate(ast, dialect="postgres"), expected_sql)
      }
      None => ()
    }
  }
  t.done()
}

///|
#callsite(autofill(loc))
fn T::assert_pretty_nested(
  self : T,
  type_str : String,
  single_line : String,
  pretty : String,
  max_text_width? : Int = 10,
  leading_comma? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  match self.run(() => @core.datatype_from_str(type_str), loc~) {
    Some(datatype) => {
      self.eqf(() => gen(datatype), single_line, loc~)
      self.eqf(
        () => @sqlglot.generate(
          datatype,
          pretty=true,
          max_text_width~,
          leading_comma~,
        ),
        pretty,
        loc~,
      )
    }
    None => ()
  }
}

///|
test "TestGenerator.test_pretty_nested_types" {
  let t = t()
  // STRUCT
  let type_str = "STRUCT<a INT, b TEXT>"
  t.assert_pretty_nested(type_str, type_str, "STRUCT<\n  a INT,\n  b TEXT\n>")

  // STRUCT - type def shorter than max text width so stays one line
  t.assert_pretty_nested(
    type_str,
    type_str,
    "STRUCT<a INT, b TEXT>",
    max_text_width=50,
  )

  // STRUCT, leading_comma = True
  t.assert_pretty_nested(
    type_str,
    type_str,
    "STRUCT<\n  a INT\n  , b TEXT\n>",
    leading_comma=true,
  )

  // ARRAY
  let type_str = "ARRAY<DECIMAL(38, 9)>"
  t.assert_pretty_nested(type_str, type_str, "ARRAY<\n  DECIMAL(38, 9)\n>")

  // ARRAY nested STRUCT
  let type_str = "ARRAY<STRUCT<a INT, b TEXT>>"
  t.assert_pretty_nested(
    type_str,
    type_str,
    "ARRAY<\n  STRUCT<\n    a INT,\n    b TEXT\n  >\n>",
  )

  // RANGE
  let type_str = "RANGE<DECIMAL(38, 9)>"
  t.assert_pretty_nested(type_str, type_str, "RANGE<\n  DECIMAL(38, 9)\n>")

  // LIST
  let type_str = "LIST<INT, INT, TEXT>"
  t.assert_pretty_nested(type_str, type_str, "LIST<\n  INT,\n  INT,\n  TEXT\n>")

  // MAP
  let type_str = "MAP<INT, DECIMAL(38, 9)>"
  t.assert_pretty_nested(type_str, type_str, "MAP<\n  INT,\n  DECIMAL(38, 9)\n>")
  t.done()
}
