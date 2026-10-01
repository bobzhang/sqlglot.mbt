// Direct assertions of tests/dialects/test_athena.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestAthena.test_func_builder" {
  let t = t(dialect="athena")
  let args : Array[&@core.IntoPy] = [
    @core.literal_string("-"),
    @sqlglot.column("a"),
    @sqlglot.column("b"),
  ]
  t.eq(
    sql(@sqlglot.func("CONCAT_WS", args~, dialect="athena"), dialect="athena"),
    "CONCAT_WS('-', a, b)",
  )
  t.eq(
    sql(@sqlglot.func("CONCAT", args~, dialect="athena"), dialect="athena"),
    "CONCAT('-', a, b)",
  )
  t.ok(
    @sqlglot.func("DATE_FORMAT", args=["a", "'%Y'"], dialect="athena").kind.is_a(
      TimeToStr,
    ),
  )
  t.eq(
    sql(
      @sqlglot.cast(t.parse_one("CAST(x AS VARCHAR)"), "TEXT", dialect="athena"),
      dialect="athena",
    ),
    "CAST(x AS VARCHAR)",
  )
  t.done()
}

///|
test "TestAthena.test_max_nodes" {
  let t = t(dialect="athena")
  for
    sql in [
      "SELECT a + b + c FROM t", "ALTER TABLE t ADD COLUMNS (a INT, b INT)",
    ] {
    t.raises(() => ignore(t.parse_one(sql, max_nodes=3)), "ParseError")
    |> ignore
  }
  t.done()
}

///|
test "TestAthena.test_qualify" {
  let t = t(dialect="athena")
  let d = @core.Dialect::get_or_raise("athena")
  let schema = @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(
      "{\"MyTable\": {\"MyCol\": \"INT\"}}",
    ),
    dialect=d,
  )
  let expression = @optimizer.qualify(
    t.parse_one("SELECT \"MyCol\" FROM \"MyTable\""),
    schema~,
    dialect=d,
  )
  t.eq(
    sql(expression, dialect="athena"),
    "SELECT \"mytable\".\"mycol\" AS \"mycol\" FROM \"mytable\" AS \"mytable\"",
  )
  t.done()
}

///|
test "TestAthena.test_create_table" {
  let t = t(dialect="athena")
  let table_schema = @core.mk(Schema, [
    ("this", @sqlglot.to_table("foo.bar")),
    (
      "expressions",
      [
        @core.mk(ColumnDef, [
          ("this", @core.to_identifier("a")),
          ("kind", @sqlglot.datatype_build("int")),
        ]),
        @core.mk(ColumnDef, [
          ("this", @core.to_identifier("b")),
          ("kind", @sqlglot.datatype_build("varchar")),
        ]),
      ],
    ),
  ])
  // Hive tables - CREATE EXTERNAL TABLE
  let ct_hive = @core.mk(Create, [
    ("this", table_schema),
    ("kind", "TABLE"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk0(ExternalProperty),
            @core.mk(FileFormatProperty, [
              ("this", @core.literal_string("parquet")),
            ]),
            @core.mk(LocationProperty, [
              ("this", @core.literal_string("s3://foo")),
            ]),
            @core.mk(PartitionedByProperty, [
              (
                "this",
                @core.mk(Schema, [
                  ("expressions", [@sqlglot.to_column("partition_col")]),
                ]),
              ),
            ]),
          ],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(ct_hive, dialect=t.dialect, identify=true),
    "CREATE EXTERNAL TABLE `foo`.`bar` (`a` INT, `b` STRING) STORED AS PARQUET LOCATION 's3://foo' PARTITIONED BY (`partition_col`)",
  )
  // Iceberg tables - CREATE TABLE... TBLPROPERTIES ('table_type'='iceberg')
  let ct_iceberg = @core.mk(Create, [
    ("this", table_schema),
    ("kind", "TABLE"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(FileFormatProperty, [
              ("this", @core.literal_string("parquet")),
            ]),
            @core.mk(LocationProperty, [
              ("this", @core.literal_string("s3://foo")),
            ]),
            @core.mk(PartitionedByProperty, [
              (
                "this",
                @core.mk(Schema, [
                  (
                    "expressions",
                    [
                      @sqlglot.to_column("partition_col"),
                      @core.mk(PartitionedByBucket, [
                        ("this", @sqlglot.to_column("a")),
                        ("expression", @core.literal_int(4)),
                      ]),
                    ],
                  ),
                ]),
              ),
            ]),
            @core.mk(Property, [
              ("this", @core.var_("table_type")),
              ("value", @core.literal_string("iceberg")),
            ]),
          ],
        ),
      ]),
    ),
  ])
  t.eq(
    sql(ct_iceberg, dialect=t.dialect, identify=true),
    "CREATE TABLE `foo`.`bar` (`a` INT, `b` STRING) STORED AS PARQUET LOCATION 's3://foo' PARTITIONED BY (`partition_col`, BUCKET(4, `a`)) TBLPROPERTIES ('table_type'='iceberg')",
  )
  t.done()
}

///|
test "TestAthena.test_ctas" {
  let t = t(dialect="athena")
  let ctas_hive = @core.mk(Create, [
    ("this", @sqlglot.to_table("foo.bar")),
    ("kind", "TABLE"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(FileFormatProperty, [
              ("this", @core.literal_string("parquet")),
            ]),
            @core.mk(LocationProperty, [
              ("this", @core.literal_string("s3://foo")),
            ]),
            @core.mk(PartitionedByProperty, [
              (
                "this",
                @core.mk(Schema, [
                  (
                    "expressions",
                    [@sqlglot.to_column("partition_col", quoted=true)],
                  ),
                ]),
              ),
            ]),
          ],
        ),
      ]),
    ),
    ("expression", @sqlglot.select(["1"])),
  ])
  // Even if identify=True, column names in the partitioned_by ARRAY[] stay unquoted
  t.eq(
    sql(ctas_hive, dialect=t.dialect, identify=true),
    "CREATE TABLE \"foo\".\"bar\" WITH (format='parquet', external_location='s3://foo', partitioned_by=ARRAY['partition_col']) AS SELECT 1",
  )
  t.eq(
    sql(ctas_hive, dialect=t.dialect, identify=false),
    "CREATE TABLE foo.bar WITH (format='parquet', external_location='s3://foo', partitioned_by=ARRAY['partition_col']) AS SELECT 1",
  )
  let ctas_iceberg = @core.mk(Create, [
    ("this", @sqlglot.to_table("foo.bar")),
    ("kind", "TABLE"),
    (
      "properties",
      @core.mk(Properties, [
        (
          "expressions",
          [
            @core.mk(Property, [
              ("this", @core.var_("table_type")),
              ("value", @core.literal_string("iceberg")),
            ]),
            @core.mk(LocationProperty, [
              ("this", @core.literal_string("s3://foo")),
            ]),
            @core.mk(PartitionedByProperty, [
              (
                "this",
                @core.mk(Schema, [
                  (
                    "expressions",
                    [
                      @sqlglot.to_column("partition_col"),
                      @core.mk(PartitionedByBucket, [
                        ("this", @sqlglot.to_column("a", quoted=true)),
                        ("expression", @core.literal_int(4)),
                      ]),
                    ],
                  ),
                ]),
              ),
            ]),
          ],
        ),
      ]),
    ),
    ("expression", @sqlglot.select(["1"])),
  ])
  t.eq(
    sql(ctas_iceberg, dialect=t.dialect, identify=true),
    "CREATE TABLE \"foo\".\"bar\" WITH (table_type='iceberg', location='s3://foo', partitioning=ARRAY['partition_col', 'BUCKET(a, 4)']) AS SELECT 1",
  )
  t.eq(
    sql(ctas_iceberg, dialect=t.dialect, identify=false),
    "CREATE TABLE foo.bar WITH (table_type='iceberg', location='s3://foo', partitioning=ARRAY['partition_col', 'BUCKET(a, 4)']) AS SELECT 1",
  )
  t.done()
}

///|
test "TestAthena.test_parse_partitioned_by_returns_iceberg_transforms" {
  let t = t(dialect="athena")
  let parsed = @sqlglot.parse_one(
    "(a, bucket(4, b), truncate(3, c), month(d))",
    read=t.dialect,
    into=PartitionedByProperty,
  )
  t.ok(parsed.kind.is_a(PartitionedByProperty))
  t.ok(parsed.this_().kind.is_a(Schema))
  t.ok(
    parsed
    .this_()
    .expressions()
    .iter()
    .any(n => n.kind.is_a(PartitionedByBucket)),
  )
  t.ok(
    parsed
    .this_()
    .expressions()
    .iter()
    .any(n => n.kind.is_a(PartitionByTruncate)),
  )
  t.done()
}
