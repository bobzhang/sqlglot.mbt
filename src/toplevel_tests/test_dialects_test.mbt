// Ports of tests/test_dialect_imports.py and tests/test_dialect_entry_points.py,
// adapted to the MoonBit dialect registry (`@core.register_dialect`, populated by
// the `bobzhang/sqlglot` facade), plus registry/settings checks.
//
// Not ported (Python packaging specific): tests/test_typing.py (checks for
// redundant entries between Python `sqlglot.typing` modules; the port generates
// that metadata), tests/test_integration_loader.py (loads an external test
// checkout), the import-lock/deadlock and `importlib` caching mechanics of
// test_dialect_imports.py and the `importlib.metadata.entry_points` plumbing of
// test_dialect_entry_points.py. tests/test_docs.py is ported in test_docs_test.mbt.

///|
/// `[d.lower() for d in sqlglot.dialects.DIALECTS]` with each dialect's direct
/// base class (`""` for `Dialect`).
let python_dialects : Array[(String, String)] = [
  ("athena", "trino"),
  ("bigquery", ""),
  ("clickhouse", ""),
  ("databricks", "spark"),
  ("dax", ""),
  ("doris", "mysql"),
  ("dremio", ""),
  ("drill", ""),
  ("druid", ""),
  ("duckdb", ""),
  ("dune", "trino"),
  ("exasol", ""),
  ("fabric", "tsql"),
  ("hive", ""),
  ("materialize", "postgres"),
  ("mysql", ""),
  ("oracle", ""),
  ("postgres", ""),
  ("presto", ""),
  ("prql", ""),
  ("redshift", "postgres"),
  ("risingwave", "postgres"),
  ("singlestore", "mysql"),
  ("snowflake", ""),
  ("solr", ""),
  ("spark", "spark2"),
  ("spark2", "hive"),
  ("sqlite", ""),
  ("starrocks", "mysql"),
  ("tableau", ""),
  ("teradata", ""),
  ("trino", "presto"),
  ("tsql", ""),
]

///|
test "every dialect is registered and resolvable" {
  assert_eq(@sqlglot.dialect_names, python_dialects.map(d => d.0))
  for entry in python_dialects {
    let (name, parent) = entry
    let d = @core.Dialect::get_or_raise(name)
    assert_eq(d.name, name)
    let parent_name = match d.parent {
      Some(p) => p.name
      None => ""
    }
    assert_eq((name, parent_name), (name, parent))
    // a settings suffix resolves to the same dialect
    assert_eq(
      @core.Dialect::get_or_raise("\{name}, normalization_strategy = lowercase").name,
      name,
    )
  }
  assert_eq(@core.Dialect::get_or_raise("").name, "")
}

///|
test "dialect import no deadlock" {
  // Athena is built from Trino and Hive while being built itself.
  let athena = @sqlglot.dialect("athena")
  assert_eq(athena.name, "athena")
  // Trino-routed and Hive-routed statements both work
  assert_eq(
    @sqlglot.transpile("SELECT 1 AS x", read="athena", write="athena"),
    ["SELECT 1 AS x"],
  )
  assert_eq(
    @sqlglot.transpile(
      "CREATE EXTERNAL TABLE t (a INT) LOCATION 's3://b/p'",
      read="athena",
    ),
    ["CREATE EXTERNAL TABLE t (a INT) LOCATION 's3://b/p'"],
  )
}

///|
test "dialect attribute access is cached" {
  match (@core.get_dialect("snowflake"), @core.get_dialect("snowflake")) {
    (Some(first), Some(second)) => assert_true(physical_equal(first, second))
    _ => fail("snowflake is not registered")
  }
}

///|
test "entry point plugin discovery" {
  // A dialect registered by another package (Python: an entry point plugin) is
  // found by name.
  @core.register_dialect("fakedb", () => {
    @core.Dialect::subclass(@core.base_dialect(), "fakedb", _ => ())
  })
  match @core.get_dialect("fakedb") {
    Some(d) => assert_eq(d.name, "fakedb")
    None => fail("fakedb was not found")
  }
  assert_eq(@core.Dialect::get_or_raise("fakedb").name, "fakedb")
}

///|
test "entry point plugin not found" {
  assert_true(@core.get_dialect("nonexistent") is None)
}

///|
test "dialect settings" {
  let d = @core.Dialect::get_or_raise("bigquery, version = 1.2.3")
  assert_eq(d.version, (1, 2, 3))
  let d = @core.Dialect::get_or_raise(
    "duckdb, normalization_strategy = lowercase, version=1.1",
  )
  assert_true(d.normalization_strategy is Lowercase)
  assert_eq(d.version, (1, 1, 0))
  let cases = [
    ("myqsl", "Unknown dialect 'myqsl'. Did you mean mysql?"),
    ("duckdb, foo = bar", "Unknown setting 'foo'."),
    (
      "mysql, normalization_strategy = invalid", "'INVALID' is not a valid NormalizationStrategy",
    ),
    ("mysql, x", "Unknown setting 'x'."),
  ]
  for c in cases {
    try @core.Dialect::get_or_raise(c.0) catch {
      e => assert_eq(e.message(), c.1)
    } noraise {
      _ => fail("expected \{c.0} to fail")
    }
  }
}
