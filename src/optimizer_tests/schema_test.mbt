// Port of tests/test_schema.py.

///|
fn schema_of(
  json : String,
  dialect? : String,
  normalize? : Bool = true,
) -> @optimizer.MappingSchema raise @core.SqlglotError {
  let dialect = match dialect {
    Some(d) => Some(@core.Dialect::get_or_raise(d))
    None => None
  }
  @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(json),
    dialect?,
    normalize~,
  )
}

///|
fn assert_column_names(
  schema : @optimizer.MappingSchema,
  cases : Array[(String, Array[String])],
) -> Unit raise {
  for case_ in cases {
    let (table, expected) = case_
    let got = schema.column_names(@core.to_table(table))
    if got != expected {
      fail("\{table}: expected \{Repr(expected)}, got \{Repr(got)}")
    }
  }
}

///|
fn assert_column_names_raises(
  schema : @optimizer.MappingSchema,
  tables : Array[String],
) -> Unit raise {
  for table in tables {
    try schema.column_names(@core.to_table(table)) catch {
      @core.SchemaError(_) => ()
      err => fail("\{table}: expected SchemaError, got \{err}")
    } noraise {
      _ => fail("\{table}: expected SchemaError")
    }
  }
}

///|
fn assert_column_names_empty(
  schema : @optimizer.MappingSchema,
  tables : Array[String],
) -> Unit raise {
  assert_column_names(schema, tables.map(t => (t, [])))
}

///|
test "schema: test_schema" {
  let schema = @optimizer.ensure_schema(
    mapping=@optimizer.schema_from_json_string(
      "{\"x\": {\"a\": \"uint64\"}, \"y\": {\"b\": \"uint64\", \"c\": \"uint64\"}}",
    ),
  )
  assert_column_names(schema, [
    ("x", ["a"]),
    ("y", ["b", "c"]),
    ("z.x", ["a"]),
    ("z.x.y", ["b", "c"]),
  ])
  assert_column_names_empty(schema, ["z", "z.z", "z.z.z"])
}

///|
test "schema: test_schema_db" {
  let schema = @optimizer.ensure_schema(
    mapping=@optimizer.schema_from_json_string(
      "{\"d1\": {\"x\": {\"a\": \"uint64\"}, \"y\": {\"b\": \"uint64\"}}, \"d2\": {\"x\": {\"c\": \"uint64\"}}}",
    ),
  )
  assert_column_names(schema, [
    ("d1.x", ["a"]),
    ("d2.x", ["c"]),
    ("y", ["b"]),
    ("d1.y", ["b"]),
    ("z.d1.y", ["b"]),
  ])
  assert_column_names_raises(schema, ["x"])
  assert_column_names_empty(schema, ["z.x", "z.y"])
}

///|
test "schema: test_schema_catalog" {
  let schema = @optimizer.ensure_schema(
    mapping=@optimizer.schema_from_json_string(
      (
        #|{
        #|  "c1": {
        #|    "d1": {
        #|      "x": {"a": "uint64"},
        #|      "y": {"b": "uint64"},
        #|      "z": {"c": "uint64"}
        #|    }
        #|  },
        #|  "c2": {
        #|    "d1": {
        #|      "y": {"d": "uint64"},
        #|      "z": {"e": "uint64"}
        #|    },
        #|    "d2": {
        #|      "z": {"f": "uint64"}
        #|    }
        #|  }
        #|}
      ),
    ),
  )
  assert_column_names(schema, [
    ("x", ["a"]),
    ("d1.x", ["a"]),
    ("c1.d1.x", ["a"]),
    ("c1.d1.y", ["b"]),
    ("c1.d1.z", ["c"]),
    ("c2.d1.y", ["d"]),
    ("c2.d1.z", ["e"]),
    ("d2.z", ["f"]),
    ("c2.d2.z", ["f"]),
  ])
  assert_column_names_raises(schema, ["y", "z", "d1.y", "d1.z"])
  assert_column_names_empty(schema, ["q", "d2.x", "a.b.c"])
}

///|
test "schema: test_schema_add_table_with_and_without_mapping" {
  let schema = @optimizer.MappingSchema::new()
  let test_ = @core.to_table("test")
  schema.add_table(test_)
  debug_inspect(schema.column_names(test_), content="[]")
  schema.add_table(test_, column_mapping={ "x": Type("string") })
  debug_inspect(schema.column_names(test_), content=(
    #|["x"]
  ))
  schema.add_table(test_, column_mapping={ "x": Type("string"), "y": Type("int") })
  debug_inspect(schema.column_names(test_), content=(
    #|["x", "y"]
  ))
  schema.add_table(test_)
  debug_inspect(schema.column_names(test_), content=(
    #|["x", "y"]
  ))
}

///|
fn assert_type(t : @core.Expr, expected : @core.DType) -> Unit raise {
  if t.datatype_this() != Some(expected) {
    fail("unexpected type: \{@optimizer.sql_of(t)}")
  }
}

///|
test "schema: test_schema_get_column_type" {
  let schema = schema_of("{\"A\": {\"b\": \"varchar\"}}")
  assert_type(schema.get_column_type_str(@core.to_table("a"), "B"), VARCHAR)
  assert_type(
    schema.get_column_type(@core.to_table("a"), @core.column_of("b")),
    VARCHAR,
  )
  let schema = schema_of("{\"a\": {\"b\": {\"c\": \"varchar\"}}}")
  assert_type(
    schema.get_column_type(@core.to_table("a.b"), @core.column_of("c")),
    VARCHAR,
  )
  assert_type(schema.get_column_type_str(@core.to_table("a.b"), "c"), VARCHAR)
  let schema = schema_of("{\"a\": {\"b\": {\"c\": {\"d\": \"varchar\"}}}}")
  assert_type(
    schema.get_column_type(@core.to_table("a.b.c"), @core.column_of("d")),
    VARCHAR,
  )
  assert_type(schema.get_column_type_str(@core.to_table("a.b.c"), "d"), VARCHAR)
  let int_type = @core.parse_one("INT", into=[DataType])
  let schema = @optimizer.MappingSchema::new(schema={
    "foo": Dict({ "bar": DataType(int_type) }),
  })
  assert_type(schema.get_column_type_str(@core.to_table("foo"), "bar"), INT)
}

///|
fn table_in(sql : String, dialect : String) -> @core.Expr raise {
  @core.parse_one(sql, dialect=@core.Dialect::get_or_raise(dialect), into=[
    Table,
  ])
}

///|
test "schema: test_schema_normalization" {
  let schema = schema_of(
    "{\"x\": {\"`y`\": {\"Z\": {\"a\": \"INT\", \"`B`\": \"VARCHAR\"}, \"w\": {\"C\": \"INT\"}}}}",
    dialect="clickhouse",
  )
  let table_z = @core.to_table("x.y.Z")
  let table_w = @core.to_table("x.y.w")
  debug_inspect(schema.column_names(table_z), content=(
    #|["a", "B"]
  ))
  debug_inspect(schema.column_names(table_w), content=(
    #|["C"]
  ))
  let schema = schema_of("{\"x\": {\"`y`\": \"INT\"}}", dialect="clickhouse")
  debug_inspect(schema.column_names(@core.to_table("x")), content=(
    #|["y"]
  ))

  // add_table normalizes both the table and the column names to be added / updated
  let schema = @optimizer.MappingSchema::new()
  schema.add_table_str("Foo", column_types={
    "SomeColumn": Type("INT"),
    "\"SomeColumn\"": Type("DOUBLE"),
  })
  debug_inspect(
    schema.column_names(@core.to_table("fOO")),
    content=(
      #|["somecolumn", "SomeColumn"]
    ),
  )

  // names are normalized to uppercase for Snowflake
  let schema = schema_of(
    "{\"x\": {\"foo\": \"int\", \"\\\"bLa\\\"\": \"int\"}}",
    dialect="snowflake",
  )
  debug_inspect(schema.column_names(@core.to_table("x")), content=(
    #|["FOO", "bLa"]
  ))

  // switching off the normalization logic
  let schema = schema_of(
    "{\"x\": {\"foo\": \"int\"}}",
    normalize=false,
    dialect="snowflake",
  )
  debug_inspect(schema.column_names(@core.to_table("x")), content=(
    #|["foo"]
  ))

  // the correct dialect is used when calling schema methods
  let schema = schema_of("{\"[Fo]\": {\"x\": \"int\"}}", dialect="tsql")
  let clickhouse = @core.Dialect::get_or_raise("clickhouse")
  assert_eq(
    schema.column_names(table_in("[Fo]", "tsql")),
    schema.column_names(table_in("`fo`", "clickhouse"), dialect=clickhouse),
  )
  debug_inspect(schema.column_names(table_in("[Fo]", "tsql")), content=(
    #|["x"]
  ))

  // BigQuery: all column identifiers are lowercased, even quoted ones; tables aren't
  let schema = schema_of("{\"Foo\": {\"`BaR`\": \"int\"}}", dialect="bigquery")
  debug_inspect(
    schema.column_names(table_in("Foo", "bigquery")),
    content=(
      #|["bar"]
    ),
  )
  // Python: [] (BigQuery table names are case-sensitive); needs the ported BigQuery
  // normalize_identifier, i.e. it fails until the dialect port is merged
  debug_inspect(schema.column_names(table_in("foo", "bigquery")), content="[]")

  // the schema's normalization setting can be overridden
  let schema = schema_of(
    "{\"X\": {\"y\": \"int\"}}",
    normalize=false,
    dialect="snowflake",
  )
  debug_inspect(
    schema.column_names(table_in("x", "snowflake"), normalize=true),
    content=(
      #|["y"]
    ),
  )

  // identifiers in nested data types are normalized
  let schema = schema_of(
    "{\"t\": {\"col\": \"STRUCT<FooBar INT>\"}}",
    dialect="bigquery",
  )
  let col_type = schema.get_column_type_str(table_in("t", "bigquery"), "col")
  inspect(col_type.expressions()[0].name(), content="foobar")
  let schema = schema_of(
    "{\"t\": {\"col\": \"STRUCT<FooBar INT>\"}}",
    dialect="snowflake",
  )
  let col_type = schema.get_column_type_str(table_in("T", "snowflake"), "COL")
  inspect(col_type.expressions()[0].name(), content="FOOBAR")
  let schema = schema_of(
    "{\"t\": {\"col\": \"STRUCT<FooBar INT>\"}}",
    dialect="clickhouse",
  )
  let col_type = schema.get_column_type_str(table_in("t", "clickhouse"), "col")
  inspect(col_type.expressions()[0].name(), content="FooBar")
  let schema = schema_of(
    "{\"t\": {\"col\": \"STRUCT<Outer STRUCT<Inner INT>>\"}}",
    dialect="bigquery",
  )
  let col_type = schema.get_column_type_str(table_in("t", "bigquery"), "col")
  inspect(col_type.expressions()[0].name(), content="outer")
  inspect(
    col_type.expressions()[0].arg("kind").unwrap().expressions()[0].name(),
    content="inner",
  )
  let schema = schema_of(
    "{\"t\": {\"col\": \"ARRAY<STRUCT<FooBar INT>>\"}}",
    dialect="bigquery",
  )
  let col_type = schema.get_column_type_str(table_in("t", "bigquery"), "col")
  let struct_type = col_type.expressions()[0]
  inspect(struct_type.expressions()[0].name(), content="foobar")
}

///|
fn expect_schema_error(f : () -> Unit raise, expected : String) -> Unit raise {
  try f() catch {
    @core.SchemaError(msg) => assert_eq(msg, expected)
    err => fail("expected SchemaError, got \{err}")
  } noraise {
    _ => fail("expected SchemaError")
  }
}

///|
test "schema: test_same_number_of_qualifiers" {
  let schema = schema_of("{\"x\": {\"y\": {\"c1\": \"int\"}}}")
  expect_schema_error(
    () => schema.add_table_str("z", column_types={ "c2": Type("int") }),
    "Table z must match the schema's nesting level: 2.",
  )
  let schema = @optimizer.MappingSchema::new()
  schema.add_table_str("x.y", column_types={ "c1": Type("int") })
  expect_schema_error(
    () => schema.add_table_str("z", column_types={ "c2": Type("int") }),
    "Table z must match the schema's nesting level: 2.",
  )
  expect_schema_error(
    () => schema_of("{\"x\": {\"y\": {\"c1\": \"int\"}}, \"z\": {\"c2\": \"int\"}}")
    |> ignore,
    "Table z must match the schema's nesting level: 2.",
  )
  expect_schema_error(
    () => schema_of(
      "{\"catalog\": {\"db\": {\"tbl\": {\"col\": \"a\"}}}, \"tbl2\": {\"col\": \"b\"}}",
    )
    |> ignore,
    "Table tbl2 must match the schema's nesting level: 3.",
  )
  expect_schema_error(
    () => schema_of(
      "{\"tbl2\": {\"col\": \"b\"}, \"catalog\": {\"db\": {\"tbl\": {\"col\": \"a\"}}}}",
    )
    |> ignore,
    "Table catalog.db.tbl must match the schema's nesting level: 1.",
  )
}

///|
test "schema: test_has_column" {
  let schema = schema_of("{\"x\": {\"c\": \"int\"}}")
  assert_true(schema.has_column(@core.to_table("x"), @core.column_of("c")))
  assert_false(schema.has_column(@core.to_table("x"), @core.column_of("k")))
}

///|
test "schema: test_find" {
  let schema = schema_of("{\"x\": {\"c\": \"int\"}}")
  let found = schema.find(@core.to_table("x")).unwrap()
  debug_inspect(found.keys().collect(), content=(
    #|["c"]
  ))
  guard found.get("c") is Some(Type("int")) else { fail("expected 'int'") }
  let found = schema.find_column_types(@core.to_table("x")).unwrap()
  guard found.get("c") is Some(Some(dt)) else { fail("expected a type") }
  assert_true(dt.equal(@core.datatype_from_str("int")))
}
