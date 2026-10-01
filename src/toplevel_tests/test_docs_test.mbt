// Port of tests/test_docs.py: the doctest examples of the sqlglot modules.
//
// Examples of Python-only helpers (helper.dict_depth/flatten/is_iterable/
// split_num_words, schema.nested_set, subclassing `Expr`, the skipped diff example)
// have no MoonBit counterpart and are not ported. Private generator helpers are
// exercised through `transpile`, and `optimize_joins._is_reorderable` (private)
// through `optimize_joins`.

///|
fn doc_sql(e : @core.Expr, dialect? : String = "") -> String raise {
  @sqlglot.generate(e, dialect~)
}

///|
fn doc_ident(name : String) -> @core.Expr raise {
  @sqlglot.to_identifier(name).unwrap()
}

///|
fn doc_schema(mapping : Json) -> @optimizer.MappingSchema raise {
  match @optimizer.SchemaNode::from_json(mapping) {
    Dict(m) => @optimizer.MappingSchema::new(schema=m)
    _ => fail("expected a mapping")
  }
}

///|
test "doctest dialects.dialect.Dialect.get_or_raise" {
  ignore(@core.Dialect::get_or_raise("duckdb"))
  let d = @core.Dialect::get_or_raise(
    "mysql, normalization_strategy = case_sensitive",
  )
  assert_true(d.normalization_strategy is CaseSensitive)
}

///|
test "doctest expressions.builders" {
  assert_eq(
    doc_sql(@sqlglot.array([@core.PyInt(1), @core.PyStr("x")])),
    "ARRAY(1, x)",
  )
  assert_eq(doc_sql(@sqlglot.cast("x + 1", "int")), "CAST(x + 1 AS INT)")
  let names = @core.column_table_names(
    @sqlglot.parse_one("a.b AND c.d AND c.e"),
  )
  names.sort()
  assert_eq(names, ["a", "c"])
  assert_eq(
    doc_sql(@sqlglot.delete("my_table", where_="id > 1")),
    "DELETE FROM my_table WHERE id > 1",
  )
  assert_eq(
    doc_sql(
      @sqlglot.expand(@sqlglot.parse_one("select * from x AS z"), {
        "x": () => @sqlglot.parse_one("select * from y"),
      }),
    ),
    "SELECT * FROM (SELECT * FROM y) AS z /* source: x */",
  )
  assert_eq(
    doc_sql(
      @sqlglot.expand(@sqlglot.parse_one("select * from x AS z"), {
        "x": () => @sqlglot.parse_one("select * from y"),
        "y": () => @sqlglot.parse_one("select * from z"),
      }),
    ),
    "SELECT * FROM (SELECT * FROM (SELECT * FROM z) AS y /* source: y */) AS z /* source: x */",
  )
  assert_eq(
    doc_sql(@sqlglot.from_("tbl").select_(["col1", "col2"])),
    "SELECT col1, col2 FROM tbl",
  )
  assert_eq(doc_sql(@sqlglot.func("abs", args=[5])), "ABS(5)")
  assert_eq(
    doc_sql(
      @sqlglot.func("cast", kwargs={
        "this": 5,
        "to": @sqlglot.datatype_build("DOUBLE"),
      }),
    ),
    "CAST(5 AS DOUBLE)",
  )
  assert_eq(
    doc_sql(@sqlglot.insert("VALUES (1, 2, 3)", "tbl")),
    "INSERT INTO tbl VALUES (1, 2, 3)",
  )
  assert_eq(
    doc_sql(
      @sqlglot.merge(
        [
          "WHEN MATCHED THEN UPDATE SET col1 = source_table.col1", "WHEN NOT MATCHED THEN INSERT (col1) VALUES (source_table.col1)",
        ],
        into="my_table",
        using_="source_table",
        on="my_table.id = source_table.id",
      ),
    ),
    "MERGE INTO my_table USING source_table ON my_table.id = source_table.id WHEN MATCHED THEN UPDATE SET col1 = source_table.col1 WHEN NOT MATCHED THEN INSERT (col1) VALUES (source_table.col1)",
  )
  assert_eq(
    @sqlglot.normalize_table_name("`A-B`.c", dialect="bigquery"),
    "A-B.c",
  )
  assert_eq(
    doc_sql(
      @sqlglot.replace_placeholders(
        @sqlglot.parse_one("select * from :tbl where ? = ?"),
        args=[doc_ident("str_col"), "b"],
        kwargs={ "tbl": doc_ident("foo") },
      ),
    ),
    "SELECT * FROM foo WHERE str_col = 'b'",
  )
  assert_eq(
    doc_sql(
      @sqlglot.replace_tables(@sqlglot.parse_one("select * from a.b"), {
        "a.b": "c",
      }),
    ),
    "SELECT * FROM c /* a.b */",
  )
  assert_eq(
    doc_sql(@sqlglot.select(["col1", "col2"]).from_("tbl")),
    "SELECT col1, col2 FROM tbl",
  )
  assert_eq(
    doc_sql(@sqlglot.subquery("select x from tbl", alias_="bar").select_(["x"])),
    "SELECT x FROM (SELECT x FROM tbl) AS bar",
  )
  assert_eq(
    @sqlglot.table_name(
      @sqlglot.parse_one("select * from a.b.c").find([Table]).unwrap(),
    ),
    "a.b.c",
  )
  assert_eq(
    doc_sql(@sqlglot.tuple_([@core.PyInt(1), @core.PyStr("x")])),
    "(1, x)",
  )
  assert_eq(
    doc_sql(
      @sqlglot.update(
        "my_table",
        properties={ "x": 1, "y": "2", "z": @core.PyNone },
        from_="baz_cte",
        where_="baz_cte.id > 1 and my_table.id = baz_cte.id",
        with_={ "baz_cte": "SELECT id FROM foo" },
      ),
    ),
    "WITH baz_cte AS (SELECT id FROM foo) UPDATE my_table SET x = 1, y = '2', z = NULL FROM baz_cte WHERE baz_cte.id > 1 AND my_table.id = baz_cte.id",
  )
  assert_eq(
    doc_sql(
      @sqlglot.values([@core.PyTuple([@core.PyInt(1), @core.PyStr("2")])]),
    ),
    "VALUES (1, '2')",
  )
  assert_eq(@sqlglot.var_("x").to_s(), "Var(this=x)")
  assert_eq(
    @sqlglot.var_(@sqlglot.column("x", table="y")).to_s(),
    "Var(this=x)",
  )
}

///|
test "doctest expressions.core" {
  assert_eq(doc_sql(@sqlglot.condition("x=1").and_(["y=1"])), "x = 1 AND y = 1")
  assert_eq(
    doc_sql(
      @sqlglot.parse_one("SELECT x from y").assert_is(Select).select_(["z"]),
    ),
    "SELECT x, z FROM y",
  )
  assert_eq(doc_sql(@sqlglot.condition("x=1").not_()), "NOT x = 1")
  assert_eq(doc_sql(@sqlglot.condition("x=1").or_(["y=1"])), "x = 1 OR y = 1")
  assert_eq(@sqlglot.parse_one("SELECT a").expressions()[0].output_name(), "a")
  assert_eq(
    @sqlglot.parse_one("SELECT b AS c").expressions()[0].output_name(),
    "c",
  )
  assert_eq(
    @sqlglot.parse_one("SELECT 1 + 2").expressions()[0].output_name(),
    "",
  )
  let tree = @sqlglot.parse_one("SELECT x FROM tbl")
  let replaced = tree
    .find([Column])
    .unwrap()
    .replace(Some(@sqlglot.column("y")))
  assert_eq(
    replaced.unwrap().to_s(),
    "Column(\n  this=Identifier(this=y, quoted=False))",
  )
  assert_eq(doc_sql(tree), "SELECT y FROM tbl")
  assert_eq(doc_sql(@sqlglot.alias_("foo", "bar")), "foo AS bar")
  assert_eq(
    doc_sql(
      @sqlglot.alias_("(select 1, 2)", "bar", table=true, table_columns=[
        "a", "b",
      ]),
    ),
    "(SELECT 1, 2) AS bar(a, b)",
  )
  assert_eq(
    doc_sql(
      @sqlglot.and_([
        @core.PyStr("x=1"),
        @core.PyExpr(@sqlglot.and_(["y=1", "z=1"])),
      ]),
    ),
    "x = 1 AND (y = 1 AND z = 1)",
  )
  assert_eq(doc_sql(@sqlglot.condition("x=1")), "x = 1")
  let where_ = @sqlglot.condition("x=1").and_(["y=1"])
  assert_eq(doc_sql(where_), "x = 1 AND y = 1")
  assert_eq(
    @sqlglot.maybe_parse("1").to_s(),
    "Literal(this=1, is_string=False)",
  )
  assert_eq(
    @sqlglot.maybe_parse(doc_ident("x")).to_s(),
    "Identifier(this=x, quoted=False)",
  )
  assert_eq(
    doc_sql(@sqlglot.not_("this_suit='black'")),
    "NOT this_suit = 'black'",
  )
  assert_eq(
    doc_sql(
      @sqlglot.or_([
        @core.PyStr("x=1"),
        @core.PyExpr(@sqlglot.or_(["y=1", "z=1"])),
      ]),
    ),
    "x = 1 OR (y = 1 OR z = 1)",
  )
  assert_eq(doc_sql(@sqlglot.paren("5 + 3")), "(5 + 3)")
  assert_eq(
    doc_sql(
      @sqlglot.xor([
        @core.PyStr("x=1"),
        @core.PyExpr(@sqlglot.xor(["y=1", "z=1"])),
      ]),
    ),
    "x = 1 XOR (y = 1 XOR z = 1)",
  )
}

///|
test "doctest expressions.dml" {
  let postgres = @sqlglot.dialect("postgres")
  assert_eq(
    doc_sql(@core.mk0(Delete).delete("tbl").returning("*", dialect=postgres)),
    "DELETE FROM tbl RETURNING *",
  )
  assert_eq(doc_sql(@core.mk0(Delete).delete("tbl")), "DELETE FROM tbl")
  assert_eq(
    doc_sql(@core.mk0(Delete).delete("tbl").where_(["x = 'a' OR x < 'b'"])),
    "DELETE FROM tbl WHERE x = 'a' OR x < 'b'",
  )
  assert_eq(
    doc_sql(
      @sqlglot.parse_one("INSERT INTO t SELECT x FROM cte").with_(
        "cte", "SELECT * FROM tbl",
      ),
    ),
    "WITH cte AS (SELECT * FROM tbl) INSERT INTO t SELECT x FROM cte",
  )
  assert_eq(
    doc_sql(@core.mk0(Update).table("my_table").set_(["x = 1"]).from_("baz")),
    "UPDATE my_table SET x = 1 FROM baz",
  )
  assert_eq(
    doc_sql(@core.mk0(Update).table("my_table").set_(["x = 1"])),
    "UPDATE my_table SET x = 1",
  )
  assert_eq(
    doc_sql(
      @core.mk0(Update)
      .table("tbl")
      .set_(["x = 1"])
      .where_(["x = 'a' OR x < 'b'"]),
    ),
    "UPDATE tbl SET x = 1 WHERE x = 'a' OR x < 'b'",
  )
  assert_eq(
    doc_sql(
      @core.mk0(Update)
      .table("my_table")
      .set_(["x = 1"])
      .from_("baz")
      .with_("baz", "SELECT id FROM foo"),
    ),
    "WITH baz AS (SELECT id FROM foo) UPDATE my_table SET x = 1 FROM baz",
  )
}

///|
test "doctest expressions.query" {
  assert_eq(
    doc_sql(@sqlglot.parse_one("JOIN x", into=Join).on(["y = 1"])),
    "JOIN x ON y = 1",
  )
  assert_eq(
    doc_sql(@sqlglot.parse_one("JOIN x", into=Join).using_(["foo", "bla"])),
    "JOIN x USING (foo, bla)",
  )
  let piv = @sqlglot.parse_one(
      "SELECT * FROM t UNPIVOT(val FOR name IN (a, b))",
    )
    .find([Pivot])
    .unwrap()
  assert_eq(
    @optimizer.pivot_output_columns(piv, ["a", "b", "c"]).map(c => c.0),
    ["c", "name", "val"],
  )
  assert_eq(
    doc_sql(
      @sqlglot.parse_one("SELECT * FROM foo").except_("SELECT * FROM bla"),
    ),
    "SELECT * FROM foo EXCEPT SELECT * FROM bla",
  )
  assert_eq(
    doc_sql(
      @sqlglot.parse_one("SELECT * FROM foo").intersect_("SELECT * FROM bla"),
    ),
    "SELECT * FROM foo INTERSECT SELECT * FROM bla",
  )
  let select = () => @core.mk0(Select)
  assert_eq(
    doc_sql(select().select_(["1"]).union_(select().select_(["1"])).limit_(1)),
    "SELECT 1 UNION SELECT 1 LIMIT 1",
  )
  assert_eq(
    doc_sql(select().from_("tbl").select_(["x"]).offset_(10)),
    "SELECT x FROM tbl OFFSET 10",
  )
  assert_eq(
    doc_sql(select().from_("tbl").select_(["x"]).order_by(["x DESC"])),
    "SELECT x FROM tbl ORDER BY x DESC",
  )
  let subquery = select().select_(["x"]).from_("tbl").subquery()
  assert_eq(
    doc_sql(select().select_(["x"]).from_(subquery)),
    "SELECT x FROM (SELECT x FROM tbl)",
  )
  assert_eq(
    doc_sql(@sqlglot.parse_one("SELECT * FROM foo").union_("SELECT * FROM bla")),
    "SELECT * FROM foo UNION SELECT * FROM bla",
  )
  assert_eq(
    doc_sql(select().select_(["x"]).from_("tbl").where_(["x = 'a' OR x < 'b'"])),
    "SELECT x FROM tbl WHERE x = 'a' OR x < 'b'",
  )
  assert_eq(
    doc_sql(
      select().with_("tbl2", "SELECT * FROM tbl").select_(["x"]).from_("tbl2"),
    ),
    "WITH tbl2 AS (SELECT * FROM tbl) SELECT x FROM tbl2",
  )
  assert_eq(
    doc_sql(
      select().from_("tbl").select_(["x"]).cluster_by(["x"]),
      dialect="hive",
    ),
    "SELECT x FROM tbl CLUSTER BY x",
  )
  assert_eq(
    doc_sql(select().select_(["*"]).from_("tbl").ctas("x")),
    "CREATE TABLE x AS SELECT * FROM tbl",
  )
  assert_eq(
    doc_sql(select().from_("tbl").select_(["x"]).distinct_()),
    "SELECT DISTINCT x FROM tbl",
  )
  assert_eq(doc_sql(select().from_("tbl").select_(["x"])), "SELECT x FROM tbl")
  assert_eq(
    doc_sql(select().from_("tbl").select_(["x", "COUNT(1)"]).group_by(["x"])),
    "SELECT x, COUNT(1) FROM tbl GROUP BY x",
  )
  assert_eq(
    doc_sql(
      select()
      .select_(["x", "COUNT(y)"])
      .from_("tbl")
      .group_by(["x"])
      .having_(["COUNT(y) > 3"]),
    ),
    "SELECT x, COUNT(y) FROM tbl GROUP BY x HAVING COUNT(y) > 3",
  )
  assert_eq(
    doc_sql(
      select().select_(["x"]).from_("tbl").hint(["BROADCAST(y)"]),
      dialect="spark",
    ),
    "SELECT /*+ BROADCAST(y) */ x FROM tbl",
  )
  assert_eq(
    doc_sql(
      select().select_(["*"]).from_("tbl").join_("tbl2", on=["tbl1.y = tbl2.y"]),
    ),
    "SELECT * FROM tbl JOIN tbl2 ON tbl1.y = tbl2.y",
  )
  assert_eq(
    doc_sql(
      select().select_(["1"]).from_("a").join_("b", using_=["x", "y", "z"]),
    ),
    "SELECT 1 FROM a JOIN b USING (x, y, z)",
  )
  assert_eq(
    doc_sql(
      select()
      .select_(["*"])
      .from_("tbl")
      .join_("tbl2", on=["tbl1.y = tbl2.y"], join_type="left outer"),
    ),
    "SELECT * FROM tbl LEFT OUTER JOIN tbl2 ON tbl1.y = tbl2.y",
  )
  assert_eq(
    doc_sql(
      select()
      .select_(["x"])
      .lateral(["OUTER explode(y) tbl2 AS z"])
      .from_("tbl"),
    ),
    "SELECT x FROM tbl LATERAL VIEW OUTER EXPLODE(y) tbl2 AS z",
  )
  assert_eq(
    doc_sql(
      select().select_(["x"]).from_("tbl").where_(["x = 'a'"]).lock(),
      dialect="mysql",
    ),
    "SELECT x FROM tbl WHERE x = 'a' FOR UPDATE",
  )
  assert_eq(
    doc_sql(
      select()
      .select_(["x"])
      .from_("tbl")
      .where_(["x = 'a'"])
      .lock(update=false),
      dialect="mysql",
    ),
    "SELECT x FROM tbl WHERE x = 'a' FOR SHARE",
  )
  assert_eq(
    doc_sql(
      select().from_("tbl").select_(["x"]).sort_by(["x DESC"]),
      dialect="hive",
    ),
    "SELECT x FROM tbl SORT BY x DESC",
  )
  assert_eq(
    doc_sql(@sqlglot.except_(["SELECT * FROM foo", "SELECT * FROM bla"])),
    "SELECT * FROM foo EXCEPT SELECT * FROM bla",
  )
  assert_eq(
    doc_sql(@sqlglot.intersect(["SELECT * FROM foo", "SELECT * FROM bla"])),
    "SELECT * FROM foo INTERSECT SELECT * FROM bla",
  )
  assert_eq(
    doc_sql(@sqlglot.union(["SELECT * FROM foo", "SELECT * FROM bla"])),
    "SELECT * FROM foo UNION SELECT * FROM bla",
  )
}

///|
test "doctest generators and transforms" {
  // generators.snowflake._unqualify_pivot_columns, generators.spark2._unalias_pivot,
  // generators.starrocks._eliminate_between_in_delete are private generator
  // transforms; their examples are checked through the generators.
  assert_eq(
    doc_sql(
      @sqlglot.parse_one(
        "SELECT * FROM m_sales UNPIVOT(sales FOR month IN (m_sales.jan, feb, mar, april))",
      ),
      dialect="snowflake",
    ),
    "SELECT * FROM m_sales UNPIVOT(sales FOR month IN (jan, feb, mar, april))",
  )
  assert_eq(
    doc_sql(
      @sqlglot.parse_one(
        "SELECT piv.x FROM tbl PIVOT (SUM(a) FOR b IN ('x')) piv",
      ),
      dialect="spark",
    ),
    "SELECT piv.x FROM (SELECT * FROM tbl PIVOT(SUM(a) FOR b IN ('x'))) AS piv",
  )
  assert_eq(
    doc_sql(
      @sqlglot.parse_one("DELETE FROM t WHERE x BETWEEN 1 AND 10"),
      dialect="starrocks",
    ),
    "DELETE FROM t WHERE x >= 1 AND x <= 10",
  )
  let expr = @sqlglot.parse_one(
    "SELECT * FROM tbl PIVOT (SUM(tbl.sales) FOR tbl.quarter IN ('Q1', 'Q2'))",
  )
  assert_eq(
    doc_sql(@core.unqualify_pivot_fields(expr), dialect="spark"),
    "SELECT * FROM tbl PIVOT(SUM(tbl.sales) FOR quarter IN ('Q1', 'Q2'))",
  )
}

///|
test "doctest helper, time and trie" {
  assert_eq(@core.merge_ranges([(1, 3), (2, 6)]), [(1, 6)])
  let mapping = { "%Y": "YYYY" }
  assert_eq(
    @core.format_time("%Y", mapping, @core.new_trie(mapping.keys())),
    "YYYY",
  )
  let trie = @core.new_trie(["cat"].iter())
  let chars = (s : String) => s.to_array().map(c => c.to_string())
  assert_true(@core.in_trie(trie, chars("bob")).0 is Failed)
  assert_true(@core.in_trie(trie, chars("ca")).0 is Prefix)
  assert_true(@core.in_trie(trie, chars("cat")).0 is Exists)
  let trie = @core.new_trie(["bla", "foo", "blab"].iter())
  assert_true(@core.in_trie(trie, chars("bla")).0 is Exists)
  assert_true(@core.in_trie(trie, chars("blab")).0 is Exists)
  assert_true(@core.in_trie(trie, chars("fo")).0 is Prefix)
}

///|
test "doctest optimizer" {
  let schema = doc_schema({ "y": { "cola": "SMALLINT" } })
  let sql = "SELECT x.cola + 2.5 AS cola FROM (SELECT y.cola AS cola FROM y AS y) AS x"
  let annotated = @optimizer.annotate_types(@sqlglot.parse_one(sql), schema~)
  assert_true(
    annotated.expressions()[0].get_type().unwrap().get("this")
    is Some(DT(DOUBLE)),
  )
  let schema = doc_schema({ "src": { "c1": "INT", "c2": "INT" } })
  assert_eq(
    doc_sql(
      @optimizer.canonicalize_internal_names(
        @optimizer.qualify(
          @sqlglot.parse_one(
            "WITH t AS (SELECT c1, c2 FROM c.db.src) SELECT * FROM t",
          ),
          schema~,
        ),
      ),
    ),
    "WITH \"_t1\" AS (SELECT \"_t0\".\"c1\" AS \"_c0\", \"_t0\".\"c2\" AS \"_c1\" FROM \"c\".\"db\".\"src\" AS \"_t0\") SELECT \"_t1\".\"_c0\" AS \"c1\", \"_t1\".\"_c1\" AS \"c2\" FROM \"_t1\" AS \"_t1\"",
  )
  assert_eq(
    doc_sql(
      @optimizer.eliminate_ctes(
        @sqlglot.parse_one("WITH y AS (SELECT a FROM x) SELECT a FROM z"),
      ),
    ),
    "SELECT a FROM z",
  )
  assert_eq(
    doc_sql(
      @optimizer.eliminate_joins(
        @sqlglot.parse_one(
          "SELECT x.a FROM x LEFT JOIN (SELECT DISTINCT y.b FROM y) AS y ON x.b = y.b",
        ),
      ),
    ),
    "SELECT x.a FROM x",
  )
  assert_eq(
    doc_sql(
      @optimizer.eliminate_subqueries(
        @sqlglot.parse_one("SELECT a FROM (SELECT * FROM x) AS y"),
      ),
    ),
    "WITH y AS (SELECT * FROM x) SELECT a FROM y AS y",
  )
  assert_eq(
    doc_sql(
      @optimizer.eliminate_subqueries(
        @sqlglot.parse_one(
          "SELECT a FROM (SELECT * FROM x) AS y CROSS JOIN (SELECT * FROM x) AS z",
        ),
      ),
    ),
    "WITH y AS (SELECT * FROM x) SELECT a FROM y AS y CROSS JOIN y AS z",
  )
  assert_eq(
    doc_sql(
      @optimizer.merge_subqueries(
        @sqlglot.parse_one("SELECT a FROM (SELECT x.a FROM x) CROSS JOIN y"),
      ),
    ),
    "SELECT x.a FROM x CROSS JOIN y",
  )
  assert_eq(
    doc_sql(
      @optimizer.merge_subqueries(
        @sqlglot.parse_one("SELECT a FROM (SELECT x.a FROM x) CROSS JOIN y"),
        leave_tables_isolated=true,
      ),
    ),
    "SELECT a FROM (SELECT x.a FROM x) CROSS JOIN y",
  )
  assert_eq(
    @optimizer.normalization_distance(
      @sqlglot.parse_one("(a AND b) OR (c AND d)"),
    ),
    4,
  )
  assert_eq(
    doc_sql(
      @optimizer.normalize(@sqlglot.parse_one("(x AND y) OR z"), dnf=false),
    ),
    "(x OR z) AND (y OR z)",
  )
  assert_true(
    @optimizer.normalized(
      @sqlglot.parse_one("(a AND b) OR c OR (d AND e)"),
      dnf=true,
    ),
  )
  assert_true(@optimizer.normalized(@sqlglot.parse_one("(a OR b) AND c")))
  assert_false(
    @optimizer.normalized(@sqlglot.parse_one("a AND (b OR c)"), dnf=true),
  )
  assert_eq(
    doc_sql(
      @optimizer.normalize_identifiers(
        @sqlglot.parse_one("SELECT Bar.A AS A FROM \"Foo\".Bar"),
      ),
    ),
    "SELECT bar.a AS a FROM \"Foo\".bar",
  )
  let snowflake = @sqlglot.dialect("snowflake")
  assert_eq(
    doc_sql(
      @optimizer.normalize_identifiers(
        @sqlglot.parse_identifier("foo", dialect="snowflake"),
        dialect=snowflake,
      ),
      dialect="snowflake",
    ),
    "FOO",
  )
  assert_eq(
    doc_sql(
      @optimizer.optimize_joins(
        @sqlglot.parse_one(
          "SELECT * FROM x CROSS JOIN y JOIN z ON x.a = z.a AND y.a = z.a",
        ),
      ),
    ),
    "SELECT * FROM x JOIN z ON x.a = z.a AND TRUE JOIN y ON y.a = z.a",
  )
  // _is_reorderable: a LEFT JOIN blocks the reordering
  assert_eq(
    doc_sql(
      @optimizer.optimize_joins(
        @sqlglot.parse_one(
          "SELECT * FROM x LEFT JOIN y ON x.id = y.id JOIN z ON y.id = z.id",
        ),
      ),
    ),
    "SELECT * FROM x LEFT JOIN y ON x.id = y.id JOIN z ON y.id = z.id",
  )
  assert_eq(
    doc_sql(
      @optimizer.pushdown_predicates(
        @sqlglot.parse_one(
          "SELECT y.a AS a FROM (SELECT x.a AS a FROM x AS x) AS y WHERE y.a = 1",
        ),
      ),
    ),
    "SELECT y.a AS a FROM (SELECT x.a AS a FROM x AS x WHERE x.a = 1) AS y WHERE TRUE",
  )
  assert_eq(
    doc_sql(
      @optimizer.pushdown_projections(
        @sqlglot.parse_one(
          "SELECT y.a AS a FROM (SELECT x.a AS a, x.b AS b FROM x) AS y",
        ),
      ),
    ),
    "SELECT y.a AS a FROM (SELECT x.a AS a FROM x) AS y",
  )
  let schema = doc_schema({ "tbl": { "col": "INT" } })
  assert_eq(
    doc_sql(
      @optimizer.qualify(@sqlglot.parse_one("SELECT col FROM tbl"), schema~),
    ),
    "SELECT \"tbl\".\"col\" AS \"col\" FROM \"tbl\" AS \"tbl\"",
  )
  let schema = doc_schema({ "tbl": { "col": "INT" } })
  assert_eq(
    doc_sql(
      @optimizer.qualify_columns(
        @sqlglot.parse_one("SELECT col FROM tbl"),
        schema,
      ),
    ),
    "SELECT tbl.col AS col FROM tbl",
  )
  assert_eq(
    doc_sql(
      @optimizer.qualify_tables(
        @sqlglot.parse_one("SELECT 1 FROM tbl"),
        db="db",
      ),
    ),
    "SELECT 1 FROM db.tbl AS tbl",
  )
  assert_eq(
    doc_sql(
      @optimizer.qualify_tables(
        @sqlglot.parse_one("SELECT 1 FROM (t1 JOIN t2) AS t"),
      ),
    ),
    "SELECT 1 FROM (SELECT * FROM t1 AS t1, t2 AS t2) AS t",
  )
  let scopes = @optimizer.traverse_scope(
    @sqlglot.parse_one("SELECT a FROM (SELECT a FROM x) AS y"),
  )
  assert_eq(doc_sql(scopes[0].expression), "SELECT a FROM x")
  assert_eq(scopes[0].sources.keys().collect(), ["x"])
  assert_eq(
    doc_sql(scopes[1].expression),
    "SELECT a FROM (SELECT a FROM x) AS y",
  )
  assert_eq(scopes[1].sources.keys().collect(), ["y"])
  assert_eq(
    doc_sql(
      @optimizer.Simplifier::new().simplify_startswith(
        @sqlglot.parse_one("STARTSWITH('foo', 'f')"),
      ),
    ),
    "TRUE",
  )
  assert_eq(
    doc_sql(@optimizer.simplify(@sqlglot.parse_one("TRUE AND TRUE"))),
    "TRUE",
  )
  assert_eq(
    doc_sql(
      @optimizer.unnest_subqueries(
        @sqlglot.parse_one(
          "SELECT * FROM x AS x WHERE (SELECT y.a AS a FROM y AS y WHERE x.a = y.a) = 1 ",
        ),
      ),
    ),
    "SELECT * FROM x AS x LEFT JOIN (SELECT y.a AS a FROM y AS y WHERE TRUE GROUP BY y.a) AS _u_0 ON x.a = _u_0.a WHERE _u_0.a = 1",
  )
}
