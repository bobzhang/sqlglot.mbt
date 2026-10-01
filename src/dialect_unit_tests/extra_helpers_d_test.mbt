// Extra helpers of the dialect_unit_tests_d package (names prefixed with `d_`).

///|
/// `MappingSchema` built from a JSON schema mapping (Python dict schema).
fn d_schema(json : String, dialect? : String) -> @optimizer.MappingSchema raise {
  let dialect = match dialect {
    Some(d) => Some(@sqlglot.dialect(d))
    None => None
  }
  @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(json),
    dialect?,
  )
}

///|
/// The values of Python's `Dialects` enum, in definition order.
let d_python_dialects : Array[String] = [
  "", "athena", "bigquery", "clickhouse", "databricks", "dax", "doris", "dremio",
  "drill", "druid", "duckdb", "dune", "fabric", "hive", "materialize", "mysql", "oracle",
  "postgres", "presto", "prql", "redshift", "risingwave", "snowflake", "solr", "spark",
  "spark2", "sqlite", "starrocks", "tableau", "teradata", "trino", "tsql", "exasol",
]

///|
/// `expression.meta` restricted to its integer entries (positions), as a map.
fn d_meta(e : @core.Expr) -> Map[String, Int64] {
  let m : Map[String, Int64] = Map([])
  for k, v in e.get_meta() {
    if v is Int(i) {
      m[k] = i
    }
  }
  m
}

///|
/// The keys of `expression.meta`, sorted (Python `set(expression.meta)`).
fn d_meta_keys(e : @core.Expr) -> Array[String] {
  let keys = e.get_meta().keys().collect()
  keys.sort()
  keys
}

///|
/// Python `s[start:end]` for ASCII strings.
fn d_slice(s : String, start : Int64, end : Int64) -> String {
  s.unsafe_substring(start=start.to_int(), end=end.to_int())
}

///|
/// Python `s.count(sub)` (non-overlapping occurrences).
fn d_count(s : String, sub : String) -> Int {
  let mut n = 0
  let mut rest = s
  while rest.find(sub) is Some(i) {
    n += 1
    rest = rest.unsafe_substring(start=i + sub.length(), end=rest.length())
  }
  n
}

///|
/// `annotate_types(expr, dialect="bigquery")`.
fn d_bq_annotate(e : @core.Expr) -> @core.Expr raise {
  @optimizer.annotate_types(e, dialect=@sqlglot.dialect("bigquery"))
}

///|
/// `self.parse_one(sql, into=exp.Table)` with the BigQuery dialect.
fn d_bq_table(sql : String) -> @core.Expr raise {
  @sqlglot.parse_one(sql, read="bigquery", into=Table)
}

///|
/// `zip(statements, expected)`: checks `actual.sql(dialect="bigquery") == expected`.
fn T::d_bq_check_statements(
  self : T,
  statements : Array[@core.Expr?],
  expected : Array[String],
) -> Unit raise {
  let n = if statements.length() < expected.length() {
    statements.length()
  } else {
    expected.length()
  }
  for i in 0..<n {
    let actual = match statements[i] {
      Some(e) => sql(e, dialect="bigquery")
      None => "None"
    }
    self.eq(actual, expected[i])
  }
}
