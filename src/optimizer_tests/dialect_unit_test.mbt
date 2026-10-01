// Ports of the dialect-specific (mostly BigQuery) unit tests of tests/test_optimizer.py.

///|
test "annotate_types: table as struct (bigquery)" {
  let schema = "{\"d\": {\"s\": {\"t\": {\"c1\": \"int64\", \"c2\": \"struct<f1 int64, f2 string>\"}}}}"
  let annotate = fn(query : String) raise {
    qualify_and_annotate(query, dialect="bigquery", schema~)
  }
  let annotated = annotate("SELECT t FROM d.s.t")
  assert_true(annotated.selects()[0].this_().kind == TableColumn)
  assert_eq(
    gen_sql(annotated, dialect="bigquery"),
    "SELECT `t` AS `t` FROM `d`.`s`.`t` AS `t`",
  )
  let struct_type = @core.datatype_from_str(
    "STRUCT<c1 BIGINT, c2 STRUCT<f1 BIGINT, f2 TEXT>>",
  )
  assert_true(annotated.selects()[0].is_type_expr(struct_type))
  let annotated = annotate("SELECT subq FROM (SELECT * from d.s.t) subq")
  assert_true(annotated.selects()[0].is_type_expr(struct_type))
  let annotated = annotate("WITH t AS (SELECT 1 AS c) SELECT t FROM t")
  assert_true(
    annotated.selects()[0].is_type_expr(@core.datatype_from_str("STRUCT<c INT>")),
  )
  let annotated = annotate("WITH t AS (SELECT FOO() AS c) SELECT t FROM t")
  assert_true(annotated.selects()[0].is_type([UNKNOWN]))
  for query in ["SELECT 'foo'", "(SELECT 'foo')"] {
    let annotated = annotate("SELECT ARRAY(\{query})")
    assert_true(
      annotated.selects()[0].is_type_expr(
        @core.datatype_from_str("ARRAY<VARCHAR>"),
      ),
    )
  }
}

///|
test "qualify: GROUP BY conflict (bigquery)" {
  let schema = "{\"custom_fields\": {\"id\": \"int\", \"col\": \"struct<fld string>\"}}"
  let qual = qualify_expr(
    "SELECT id, ARRAY_AGG(col) AS custom_fields FROM custom_fields AS custom_fields GROUP BY id HAVING id >= 1",
    dialect="bigquery",
    schema~,
  )
  assert_eq(
    gen_sql(qual, dialect="bigquery"),
    "SELECT `custom_fields`.`id` AS `id`, ARRAY_AGG(`custom_fields`.`col`) AS `custom_fields` FROM `custom_fields` AS `custom_fields` GROUP BY `id` HAVING `id` >= 1",
  )
  // The shadowed references stay qualified in the AST and only render bare in dialects
  // where projection aliases shadow source names
  let group_col = qual.arg("group").unwrap().find([Column]).unwrap()
  assert_eq(group_col.table_name(), "custom_fields")
  assert_true(group_col.bool_arg("shadow"))
  assert_eq(
    gen_sql(qual, dialect="duckdb"),
    "SELECT \"custom_fields\".\"id\" AS \"id\", ARRAY_AGG(\"custom_fields\".\"col\") AS \"custom_fields\" FROM \"custom_fields\" AS \"custom_fields\" GROUP BY \"custom_fields\".\"id\" HAVING \"custom_fields\".\"id\" >= 1",
  )
  // A clause ref matching a projection alias takes the alias-expansion path
  let qual = qualify_expr(
    "SELECT custom_fields.id AS id, ARRAY_AGG(custom_fields.col) AS custom_fields FROM custom_fields AS custom_fields GROUP BY id HAVING id >= 1",
    dialect="bigquery",
    schema~,
  )
  assert_eq(
    gen_sql(qual, dialect="bigquery"),
    "SELECT `custom_fields`.`id` AS `id`, ARRAY_AGG(`custom_fields`.`col`) AS `custom_fields` FROM `custom_fields` AS `custom_fields` GROUP BY `id` HAVING `id` >= 1",
  )
}

///|
test "qualify: UNNEST alias shadowing (bigquery)" {
  assert_eq(
    qualify_sql(
      "SELECT timeline_date FROM UNNEST(GENERATE_DATE_ARRAY('2020-01-01', '2020-01-03')) AS timeline_date LEFT JOIN production_tier ON production_tier.timeline_date = timeline_date",
      dialect="bigquery",
      schema="{\"production_tier\": {\"timeline_date\": \"DATE\", \"id\": \"INT\"}}",
    ),
    "SELECT `timeline_date` AS `timeline_date` FROM UNNEST(GENERATE_DATE_ARRAY('2020-01-01', '2020-01-03', INTERVAL '1' DAY)) AS `timeline_date` LEFT JOIN `production_tier` AS `production_tier` ON `production_tier`.`timeline_date` = `timeline_date`",
  )
}

///|
fn optimize_in(
  sql : String,
  dialect : String,
  schema : String,
) -> String raise @core.SqlglotError {
  let d = dialect_of(Some(dialect))
  gen_sql(
    @optimizer.optimize(
      parse_sql(sql, read=dialect),
      schema=mapping_schema(schema, dialect~),
      dialect?=d,
    ),
    dialect~,
  )
}

///|
test "optimize: case sensitive JSON dot access" {
  let schema = "{\"t\": {\"col\": \"JSON\", \"struct_col\": \"STRUCT<STRUCT<STRUCT<VARCHAR>>>\"}}"
  // DuckDB
  assert_eq(
    optimize_in("SELECT col.A.a, col.a.A FROM t", "duckdb", schema),
    "SELECT \"t\".\"col\".\"A\".\"a\" AS \"a\", \"t\".\"col\".\"a\".\"A\" AS \"a\" FROM \"t\" AS \"t\"",
  )
  // Clickhouse
  assert_eq(
    optimize_in("SELECT col.A.a, col.a.A FROM t", "clickhouse", schema),
    "SELECT \"t\".\"col\".\"A\".\"a\" AS \"a\", \"t\".\"col\".\"a\".\"A\" AS \"A\" FROM \"t\" AS \"t\"",
  )
  // Databricks
  assert_eq(
    optimize_in("SELECT col:A.a, col:a.A FROM t", "databricks", schema),
    "SELECT `t`.`col`:A.a AS `a`, `t`.`col`:a.A AS `a` FROM `t` AS `t`",
  )
  // BigQuery: STRUCT field accesses are still normalized
  assert_eq(
    optimize_in(
      "SELECT struct_col.FlD1.flD2.FLD3 AS col FROM t", "bigquery", schema,
    ),
    "SELECT `t`.`struct_col`.`fld1`.`fld2`.`fld3` AS `col` FROM `t` AS `t`",
  )
  for dot_access in ["col.fOo.BaR.BaZ", "t.col.fOo.BaR.BaZ"] {
    let normalized = "`t`.`col`.`fOo`.`BaR`.`BaZ`"
    assert_eq(
      optimize_in(
        "SELECT JSON_VALUE(\{dot_access}, '$') AS col FROM t", "bigquery", schema,
      ),
      "SELECT JSON_VALUE(\{normalized}, '$') AS `col` FROM `t` AS `t`",
    )
    assert_eq(
      optimize_in("SELECT \{dot_access} AS col FROM t", "bigquery", schema),
      "SELECT \{normalized} AS `col` FROM `t` AS `t`",
    )
  }
  // Snowflake
  assert_eq(
    optimize_in("SELECT col:A.a, col:a.A FROM t", "snowflake", schema),
    "SELECT GET_PATH(\"T\".\"COL\", 'A.a') AS \"A\", GET_PATH(\"T\".\"COL\", 'a.A') AS \"A\" FROM \"T\" AS \"T\"",
  )
}

///|
test "optimize: JSON_VALUE over an UNNEST (bigquery)" {
  let bigquery = dialect_of(Some("bigquery"))
  let optimized = @optimizer.optimize(
    parse_sql(
      "SELECT JSON_VALUE(item.id) FROM UNNEST(JSON_QUERY_ARRAY(PARSE_JSON('[{\"id\": 1}]'))) AS item",
      read="bigquery",
    ),
    dialect?=bigquery,
  )
  for i in optimized.find_all([Identifier]) {
    assert_false(i.this() is Some(_))
  }
  assert_eq(
    gen_sql(optimized, dialect="bigquery"),
    "SELECT JSON_VALUE(`item`.`id`, '$') AS `_col_0` FROM UNNEST(JSON_QUERY_ARRAY(PARSE_JSON('[{\"id\": 1}]'), '$')) AS `item`",
  )
}
