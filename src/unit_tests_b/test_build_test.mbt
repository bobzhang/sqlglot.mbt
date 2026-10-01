// Port of tests/test_build.py
//
// Python operators map to `Expr` methods: `x + 1` -> `x.add(1)`, `1 + x` ->
// `x.binop(Add, 1, reverse=true)` (Python's `__radd__`), `x // 1` -> `x.floordiv(1)`,
// `x ** 1` -> `x.pow(1)`, `x & 1` -> `x.land(1)`, `x | 1` -> `x.lor(1)`, `-x` -> `x.neg()`,
// `~x` -> `x.invert()`, `x[1]` -> `x.getitem([1])`; Python's reflected comparisons
// (`1 < x` evaluates `x > 1`) are written directly as `x.gt(1)`.

///|

///|
test "TestBuild.test_build" {
  let x = @sqlglot.condition("x")
  let x_plus_one = x.add(1)
  // Make sure we're not mutating x by changing its parent to be x_plus_one
  assert_true(x.parent is None)
  assert_false(physical_equal(x_plus_one.this_(), x))
  let mysql = @sqlglot.dialect("mysql")
  let postgres = @sqlglot.dialect("postgres")
  let cases : Array[(() -> @core.Expr raise, String, String)] = [
    (() => x.add(1), "x + 1", ""),
    (() => x.binop(Add, 1, reverse=true), "1 + x", ""),
    (() => x.sub(1), "x - 1", ""),
    (() => x.binop(Sub, 1, reverse=true), "1 - x", ""),
    (() => x.mul(1), "x * 1", ""),
    (() => x.binop(Mul, 1, reverse=true), "1 * x", ""),
    (() => x.truediv(1), "x / 1", ""),
    (() => x.binop(Div, 1, reverse=true), "1 / x", ""),
    (() => x.floordiv(1), "CAST(x / 1 AS INT)", ""),
    (() => x.binop(IntDiv, 1, reverse=true), "CAST(1 / x AS INT)", ""),
    (() => x.mod(1), "x % 1", ""),
    (() => x.binop(Mod, 1, reverse=true), "1 % x", ""),
    (() => x.pow(1), "POWER(x, 1)", ""),
    (() => x.binop(Pow, 1, reverse=true), "POWER(1, x)", ""),
    (() => x.land(1), "x AND 1", ""),
    (() => x.binop(And, 1, reverse=true), "1 AND x", ""),
    (() => x.lor(1), "x OR 1", ""),
    (() => x.binop(Or, 1, reverse=true), "1 OR x", ""),
    (() => x.lt(1), "x < 1", ""),
    (() => x.gt(1), "x > 1", ""),
    (() => x.le(1), "x <= 1", ""),
    (() => x.ge(1), "x >= 1", ""),
    (() => x.gt(1), "x > 1", ""),
    (() => x.lt(1), "x < 1", ""),
    (() => x.ge(1), "x >= 1", ""),
    (() => x.le(1), "x <= 1", ""),
    (() => x.eq_(1), "x = 1", ""),
    (() => x.neq(1), "x <> 1", ""),
    (() => x.is__(@core.null_()), "x IS NULL", ""),
    (() => x.as_("y"), "x AS y", ""),
    (() => x.isin(expressions=[1, "2"]), "x IN (1, '2')", ""),
    (() => x.isin(query="select 1"), "x IN (SELECT 1)", ""),
    (() => x.isin(unnest=["x"]), "x IN (SELECT UNNEST(x))", ""),
    (() => x.isin(unnest=["x"]), "x IN UNNEST(x)", "bigquery"),
    (() => x.isin(unnest=["x", "y"]), "x IN (SELECT UNNEST(x, y))", ""),
    (() => x.between(1, 2), "x BETWEEN 1 AND 2", ""),
    (() => x.binop(Add, 1, reverse=true).add(2).add(3), "1 + x + 2 + 3", ""),
    (() => x.mul(2).binop(Add, 1, reverse=true).add(3), "1 + (x * 2) + 3", ""),
    (() => x.mul(1).mul(2).add(3), "(x * 1 * 2) + 3", ""),
    (
      () => x.mul(2).truediv(3).binop(Add, 1, reverse=true),
      "1 + ((x * 2) / 3)",
      "",
    ),
    (() => x.land("y"), "x AND 'y'", ""),
    (() => x.lor("y"), "x OR 'y'", ""),
    (() => x.neg(), "-x", ""),
    (() => x.invert(), "NOT x", ""),
    (() => x.getitem([1]), "x[1]", ""),
    (() => x.getitem([1, 2]), "x[1, 2]", ""),
    (() => x.getitem(["y"]).add(1), "x['y'] + 1", ""),
    (() => x.like("y"), "x LIKE 'y'", ""),
    (() => x.ilike("y"), "x ILIKE 'y'", ""),
    (() => x.rlike("y"), "REGEXP_LIKE(x, 'y')", ""),
    (
      () => @sqlglot.case().when_("x = 1", "x").else_("bar"),
      "CASE WHEN x = 1 THEN x ELSE bar END",
      "",
    ),
    (
      () => @sqlglot.case(expression="x").when_("1", "x").else_("bar"),
      "CASE x WHEN 1 THEN x ELSE bar END",
      "",
    ),
    (() => @sqlglot.func("COALESCE", args=["x", 1]), "COALESCE(x, 1)", ""),
    (() => @sqlglot.column("x").desc(), "x DESC", ""),
    (
      () => @sqlglot.column("x").desc(nulls_first=true),
      "x DESC NULLS FIRST",
      "",
    ),
    (() => @sqlglot.select(["x"]), "SELECT x", ""),
    (() => @sqlglot.select(["x"]), "SELECT x", ""),
    (() => @sqlglot.select(["x", "y"]), "SELECT x, y", ""),
    (() => @sqlglot.select(["x"]).from_("tbl"), "SELECT x FROM tbl", ""),
    (() => @sqlglot.select(["x", "y"]).from_("tbl"), "SELECT x, y FROM tbl", ""),
    (
      () => @sqlglot.select(["x"]).select_(["y"]).from_("tbl"),
      "SELECT x, y FROM tbl",
      "",
    ),
    (() => @sqlglot.select(["comment", "begin"]), "SELECT comment, begin", ""),
    (
      () => @sqlglot.select(["x"]).select_(["y"], append=false).from_("tbl"),
      "SELECT y FROM tbl",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").from_("tbl2"),
      "SELECT x FROM tbl2",
      "",
    ),
    (() => @sqlglot.select(["SUM(x) AS y"]), "SELECT SUM(x) AS y", ""),
    (
      () => @sqlglot.select(["x"]).from_("tbl").where_(["x > 0"]),
      "SELECT x FROM tbl WHERE x > 0",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").where_(["x < 4 OR x > 5"]),
      "SELECT x FROM tbl WHERE x < 4 OR x > 5",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_("tbl").where_(["x > 0"]).where_(["x < 9"])
      },
      "SELECT x FROM tbl WHERE x > 0 AND x < 9",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").where_(["x > 0", "x < 9"]),
      "SELECT x FROM tbl WHERE x > 0 AND x < 9",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .where_([@core.PyNone])
        .where_(([false, ""] : Array[&@core.IntoPy]))
      },
      "SELECT x FROM tbl WHERE FALSE",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .where_(["x > 0"])
        .where_(["x < 9"], append=false)
      },
      "SELECT x FROM tbl WHERE x < 9",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_("tbl").where_(["x > 0"]).lock(copy=false)
      },
      "SELECT x FROM tbl WHERE x > 0 FOR UPDATE",
      "mysql",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_("tbl").where_(["x > 0"]).lock(update=false)
      },
      "SELECT x FROM tbl WHERE x > 0 FOR SHARE",
      "postgres",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").hint(["repartition(100)"]),
      "SELECT /*+ REPARTITION(100) */ x FROM tbl",
      "spark",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .hint(["coalesce(3)", "broadcast(x)"])
      },
      "SELECT /*+ COALESCE(3), BROADCAST(x) */ x FROM tbl",
      "spark",
    ),
    (
      () => @sqlglot.select(["x", "y"]).from_("tbl").group_by(["x"]),
      "SELECT x, y FROM tbl GROUP BY x",
      "",
    ),
    (
      () => @sqlglot.select(["x", "y"]).from_("tbl").group_by(["x, y"]),
      "SELECT x, y FROM tbl GROUP BY x, y",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z", "a"])
        .from_("tbl")
        .group_by(["x, y", "z"])
        .group_by(["a"])
      },
      "SELECT x, y, z, a FROM tbl GROUP BY x, y, z, a",
      "",
    ),
    (
      () => @sqlglot.select([1]).from_("tbl").group_by(["x with cube"]),
      "SELECT 1 FROM tbl GROUP BY x WITH CUBE",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).distinct_(ons=["a", "b"]).from_("tbl"),
      "SELECT DISTINCT ON (a, b) x FROM tbl",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).distinct_(distinct=true).from_("tbl"),
      "SELECT DISTINCT x FROM tbl",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).distinct_(distinct=false).from_("tbl"),
      "SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .lateral(["OUTER explode(y) tbl2 AS z"])
        .from_("tbl")
      },
      "SELECT x FROM tbl LATERAL VIEW OUTER EXPLODE(y) tbl2 AS z",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").join_("tbl2 ON tbl.y = tbl2.y"),
      "SELECT x FROM tbl JOIN tbl2 ON tbl.y = tbl2.y",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_("tbl").join_("tbl2", on=["tbl.y = tbl2.y"])
      },
      "SELECT x FROM tbl JOIN tbl2 ON tbl.y = tbl2.y",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_("tbl2", on=["tbl.y = tbl2.y", "a = b"])
      },
      "SELECT x FROM tbl JOIN tbl2 ON tbl.y = tbl2.y AND a = b",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_("tbl2", join_type="left outer")
      },
      "SELECT x FROM tbl LEFT OUTER JOIN tbl2",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(@core.mk(Table, [("this", "tbl2")]), join_type="left outer")
      },
      "SELECT x FROM tbl LEFT OUTER JOIN tbl2",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(
          @core.mk(Table, [("this", "tbl2")]),
          join_type="left outer",
          join_alias="foo",
        )
      },
      "SELECT x FROM tbl LEFT OUTER JOIN tbl2 AS foo",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(@sqlglot.select(["y"]).from_("tbl2"), join_type="left outer")
      },
      "SELECT x FROM tbl LEFT OUTER JOIN (SELECT y FROM tbl2)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(
          @sqlglot.select(["y"]).from_("tbl2").subquery(alias="aliased"),
          join_type="left outer",
        )
      },
      "SELECT x FROM tbl LEFT OUTER JOIN (SELECT y FROM tbl2) AS aliased",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(
          @sqlglot.select(["y"]).from_("tbl2"),
          join_type="left outer",
          join_alias="aliased",
        )
      },
      "SELECT x FROM tbl LEFT OUTER JOIN (SELECT y FROM tbl2) AS aliased",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(@sqlglot.maybe_parse("left join x", into=[Join]), on=["a=b"])
      },
      "SELECT x FROM tbl LEFT JOIN x ON a = b",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").join_("left join x", on=["a=b"]),
      "SELECT x FROM tbl LEFT JOIN x ON a = b",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_("select b from tbl2", on=["a=b"], join_type="left")
      },
      "SELECT x FROM tbl LEFT JOIN (SELECT b FROM tbl2) ON a = b",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .join_(
          "select b from tbl2",
          on=["a=b"],
          join_type="left",
          join_alias="aliased",
        )
      },
      "SELECT x FROM tbl LEFT JOIN (SELECT b FROM tbl2) AS aliased ON a = b",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z"])
        .from_("merged_df")
        .join_("vte_diagnosis_df", using_=["patient_id", "encounter_id"])
      },
      "SELECT x, y, z FROM merged_df JOIN vte_diagnosis_df USING (patient_id, encounter_id)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z"])
        .from_("merged_df")
        .join_("vte_diagnosis_df", using_=[
          @core.to_identifier("patient_id"),
          @core.to_identifier("encounter_id"),
        ])
      },
      "SELECT x, y, z FROM merged_df JOIN vte_diagnosis_df USING (patient_id, encounter_id)",
      "",
    ),
    (
      () => @sqlglot.maybe_parse("JOIN x", into=[Join]).on(["y = 1", "z = 1"]),
      "JOIN x ON y = 1 AND z = 1",
      "",
    ),
    (
      () => @sqlglot.maybe_parse("JOIN x", into=[Join]).on(["y = 1"]),
      "JOIN x ON y = 1",
      "",
    ),
    (
      () => @sqlglot.maybe_parse("JOIN x", into=[Join]).using_(["bar", "bob"]),
      "JOIN x USING (bar, bob)",
      "",
    ),
    (
      () => @sqlglot.maybe_parse("JOIN x", into=[Join]).using_(["bar"]),
      "JOIN x USING (bar)",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("foo").join_("bla", using_=["bob"]),
      "SELECT x FROM foo JOIN bla USING (bob)",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("foo").join_("bla", using_=["bob"]),
      "SELECT x FROM foo JOIN bla USING (bob)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x", "COUNT(y)"])
        .from_("tbl")
        .group_by(["x"])
        .having_(["COUNT(y) > 0"])
      },
      "SELECT x, COUNT(y) FROM tbl GROUP BY x HAVING COUNT(y) > 0",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").order_by(["y"]),
      "SELECT x FROM tbl ORDER BY y",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("select * from x union select * from y").order_by([
          "y",
        ])
      },
      "SELECT * FROM x UNION SELECT * FROM y ORDER BY y",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").cluster_by(["y"]),
      "SELECT x FROM tbl CLUSTER BY y",
      "hive",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").sort_by(["y"]),
      "SELECT x FROM tbl SORT BY y",
      "hive",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").order_by(["x, y DESC"]),
      "SELECT x FROM tbl ORDER BY x, y DESC",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").cluster_by(["x, y"]),
      "SELECT x FROM tbl CLUSTER BY x, y",
      "hive",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").sort_by(["x, y DESC"]),
      "SELECT x FROM tbl SORT BY x, y DESC",
      "hive",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z", "a"])
        .from_("tbl")
        .order_by(["x, y", "z"])
        .order_by(["a"])
      },
      "SELECT x, y, z, a FROM tbl ORDER BY x, y, z, a",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z", "a"])
        .from_("tbl")
        .cluster_by(["x, y", "z"])
        .cluster_by(["a"])
      },
      "SELECT x, y, z, a FROM tbl CLUSTER BY x, y, z, a",
      "hive",
    ),
    (
      () => {
        @sqlglot.select(["x", "y", "z", "a"])
        .from_("tbl")
        .sort_by(["x, y", "z"])
        .sort_by(["a"])
      },
      "SELECT x, y, z, a FROM tbl SORT BY x, y, z, a",
      "hive",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").limit_(10),
      "SELECT x FROM tbl LIMIT 10",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").offset_(10),
      "SELECT x FROM tbl OFFSET 10",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_("tbl").with_("tbl", "SELECT x FROM tbl2")
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", "SELECT x FROM tbl2", materialized=true)
      },
      "WITH tbl AS MATERIALIZED (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", "SELECT x FROM tbl2", materialized=false)
      },
      "WITH tbl AS NOT MATERIALIZED (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", "SELECT x FROM tbl2", recursive=true)
      },
      "WITH RECURSIVE tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_(
          "tbl",
          @sqlglot.select(["x"]).from_("tbl2"),
          recursive=true,
          materialized=true,
        )
      },
      "WITH RECURSIVE tbl AS MATERIALIZED (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_(
          "tbl",
          @sqlglot.select(["x"]).from_("tbl2"),
          recursive=true,
          materialized=false,
        )
      },
      "WITH RECURSIVE tbl AS NOT MATERIALIZED (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl (x, y)", @sqlglot.select(["x", "y"]).from_("tbl2"))
      },
      "WITH tbl(x, y) AS (SELECT x, y FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .with_("tbl2", @sqlglot.select(["x"]).from_("tbl3"))
      },
      "WITH tbl AS (SELECT x FROM tbl2), tbl2 AS (SELECT x FROM tbl3) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .from_("tbl")
        .with_("tbl", @sqlglot.select(["x", "y"]).from_("tbl2"))
        .select_(["y"])
      },
      "WITH tbl AS (SELECT x, y FROM tbl2) SELECT x, y FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .group_by(["x"])
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl GROUP BY x",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .order_by(["x"])
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl ORDER BY x",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .limit_(10)
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl LIMIT 10",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .offset_(10)
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl OFFSET 10",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .join_("tbl3")
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl, tbl3",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .distinct_()
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT DISTINCT x FROM tbl",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .where_(["x > 10"])
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl WHERE x > 10",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("tbl", @sqlglot.select(["x"]).from_("tbl2"))
        .from_("tbl")
        .having_(["x > 20"])
      },
      "WITH tbl AS (SELECT x FROM tbl2) SELECT x FROM tbl HAVING x > 20",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").subquery(),
      "(SELECT x FROM tbl)",
      "",
    ),
    (
      () => @sqlglot.select(["x"]).from_("tbl").subquery(alias="y"),
      "(SELECT x FROM tbl) AS y",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"]).from_(
          @sqlglot.select(["x"]).from_("tbl").subquery(),
        )
      },
      "SELECT x FROM (SELECT x FROM tbl)",
      "",
    ),
    (() => @sqlglot.from_("tbl").select_(["x"]), "SELECT x FROM tbl", ""),
    (
      () => {
        @sqlglot.parse_one("SELECT a FROM tbl").assert_is(Select).select_(["b"])
      },
      "SELECT a, b FROM tbl",
      "",
    ),
    (
      () => @sqlglot.parse_one("SELECT * FROM y").assert_is(Select).ctas("x"),
      "CREATE TABLE x AS SELECT * FROM y",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("SELECT * FROM y")
        .assert_is(Select)
        .ctas("foo.x", properties={
          "format": @core.PyStr("parquet"),
          "y": @core.PyStr("2"),
        })
      },
      "CREATE TABLE foo.x STORED AS PARQUET TBLPROPERTIES ('y'='2') AS SELECT * FROM y",
      "hive",
    ),
    (() => @sqlglot.and_(["x=1", "y=1"]), "x = 1 AND y = 1", ""),
    (
      () => @sqlglot.condition("x").and_(["y['a']"]).and_(["1"]),
      "(x AND y['a']) AND 1",
      "",
    ),
    (() => @sqlglot.condition("x=1").and_(["y=1"]), "x = 1 AND y = 1", ""),
    (
      () => @sqlglot.and_(["x=1", "y=1", "z=1"]),
      "x = 1 AND y = 1 AND z = 1",
      "",
    ),
    (
      () => @sqlglot.condition("x=1").and_(["y=1", "z=1"]),
      "x = 1 AND y = 1 AND z = 1",
      "",
    ),
    (
      () => {
        @sqlglot.and_(
          (["x=1", @sqlglot.and_(["y=1", "z=1"])] : Array[&@core.IntoPy]),
        )
      },
      "x = 1 AND (y = 1 AND z = 1)",
      "",
    ),
    (
      () => @sqlglot.condition("x=1").and_(["y=1"]).and_(["z=1"]),
      "(x = 1 AND y = 1) AND z = 1",
      "",
    ),
    (
      () => {
        @sqlglot.or_(
          ([@sqlglot.and_(["x=1", "y=1"]), "z=1"] : Array[&@core.IntoPy]),
        )
      },
      "(x = 1 AND y = 1) OR z = 1",
      "",
    ),
    (
      () => @sqlglot.condition("x=1").and_(["y=1"]).or_(["z=1"]),
      "(x = 1 AND y = 1) OR z = 1",
      "",
    ),
    (
      () => {
        @sqlglot.or_(
          (["z=1", @sqlglot.and_(["x=1", "y=1"])] : Array[&@core.IntoPy]),
        )
      },
      "z = 1 OR (x = 1 AND y = 1)",
      "",
    ),
    (
      () => {
        @sqlglot.or_(
          (["z=1 OR a=1", @sqlglot.and_(["x=1", "y=1"])] : Array[&@core.IntoPy]),
        )
      },
      "(z = 1 OR a = 1) OR (x = 1 AND y = 1)",
      "",
    ),
    (() => @sqlglot.not_("x=1"), "NOT x = 1", ""),
    (() => @sqlglot.condition("x=1").not_(), "NOT x = 1", ""),
    (
      () => @sqlglot.condition("x=1").and_(["y=1"]).not_(),
      "NOT (x = 1 AND y = 1)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["*"])
        .from_("x")
        .where_([@sqlglot.condition("y=1").and_(["z=1"])])
      },
      "SELECT * FROM x WHERE y = 1 AND z = 1",
      "",
    ),
    (
      () => {
        @sqlglot.subquery("select x from tbl", alias="foo")
        .select_(["x"])
        .where_(["x > 0"])
      },
      "SELECT x FROM (SELECT x FROM tbl) AS foo WHERE x > 0",
      "",
    ),
    (
      () => {
        @sqlglot.subquery(
          "select x from tbl UNION select x from bar",
          alias="unioned",
        ).select_(["x"])
      },
      "SELECT x FROM (SELECT x FROM tbl UNION SELECT x FROM bar) AS unioned",
      "",
    ),
    (() => @sqlglot.parse_one("(SELECT 1)").select_(["2"]), "(SELECT 1, 2)", ""),
    (() => @sqlglot.parse_one("(SELECT 1)").limit_(1), "(SELECT 1) LIMIT 1", ""),
    (
      () => @sqlglot.parse_one("WITH t AS (SELECT 1) (SELECT 1)").limit_(1),
      "WITH t AS (SELECT 1) SELECT 1 LIMIT 1",
      "",
    ),
    (
      () => @sqlglot.parse_one("(SELECT 1 LIMIT 2)").limit_(1),
      "(SELECT 1 LIMIT 2) LIMIT 1",
      "",
    ),
    (
      () => @sqlglot.parse_one("SELECT 1 UNION SELECT 2").limit_(5).offset_(2),
      "SELECT 1 UNION SELECT 2 LIMIT 5 OFFSET 2",
      "",
    ),
    (() => @sqlglot.parse_one("(SELECT 1)").subquery(), "((SELECT 1))", ""),
    (
      () => @sqlglot.parse_one("(SELECT 1)").subquery(alias="alias"),
      "((SELECT 1)) AS alias",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("(select * from foo)").with_("foo", "select 1 as c")
      },
      "WITH foo AS (SELECT 1 AS c) (SELECT * FROM foo)",
      "",
    ),
    (
      () => {
        @sqlglot.update("tbl", properties={
          "x": @core.PyNone,
          "y": @core.PyDict([(@core.PyStr("x"), @core.PyInt(1))]),
        })
      },
      "UPDATE tbl SET x = NULL, y = MAP(ARRAY('x'), ARRAY(1))",
      "",
    ),
    (
      () => @sqlglot.update("tbl", properties={ "x": 1 }, where_="y > 0"),
      "UPDATE tbl SET x = 1 WHERE y > 0",
      "",
    ),
    (
      () => {
        @sqlglot.update(
          "tbl",
          properties={ "x": 1 },
          where_=@sqlglot.condition("y > 0"),
        )
      },
      "UPDATE tbl SET x = 1 WHERE y > 0",
      "",
    ),
    (
      () => @sqlglot.update("tbl", properties={ "x": 1 }, from_="tbl2"),
      "UPDATE tbl SET x = 1 FROM tbl2",
      "",
    ),
    (
      () => {
        @sqlglot.update(
          "tbl",
          properties={ "x": 1 },
          from_="tbl2 cross join tbl3",
        )
      },
      "UPDATE tbl SET x = 1 FROM tbl2 CROSS JOIN tbl3",
      "",
    ),
    (
      () => {
        @sqlglot.update(
          "my_table",
          properties={ "x": 1 },
          from_="baz",
          where_="my_table.id = baz.id",
          with_={ "baz": "SELECT id FROM foo UNION SELECT id FROM bar" },
        )
      },
      "WITH baz AS (SELECT id FROM foo UNION SELECT id FROM bar) UPDATE my_table SET x = 1 FROM baz WHERE my_table.id = baz.id",
      "",
    ),
    (
      () => @sqlglot.update("my_table").set_(["x = 1"]),
      "UPDATE my_table SET x = 1",
      "",
    ),
    (
      () => @sqlglot.update("my_table").set_(["x = 1"]).where_(["y = 2"]),
      "UPDATE my_table SET x = 1 WHERE y = 2",
      "",
    ),
    (
      () => @sqlglot.update("my_table").set_(["a = 1"]).set_(["b = 2"]),
      "UPDATE my_table SET a = 1, b = 2",
      "",
    ),
    (
      () => {
        @sqlglot.update("my_table")
        .set_(["x = 1"])
        .where_(["my_table.id = baz.id"])
        .from_("baz")
        .with_("baz", "SELECT id FROM foo")
      },
      "WITH baz AS (SELECT id FROM foo) UPDATE my_table SET x = 1 FROM baz WHERE my_table.id = baz.id",
      "",
    ),
    (
      () => @sqlglot.union(["SELECT * FROM foo", "SELECT * FROM bla"]),
      "SELECT * FROM foo UNION SELECT * FROM bla",
      "",
    ),
    (
      () => @sqlglot.parse_one("SELECT * FROM foo").union_("SELECT * FROM bla"),
      "SELECT * FROM foo UNION SELECT * FROM bla",
      "",
    ),
    (
      () => @sqlglot.intersect(["SELECT * FROM foo", "SELECT * FROM bla"]),
      "SELECT * FROM foo INTERSECT SELECT * FROM bla",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("SELECT * FROM foo").intersect_("SELECT * FROM bla")
      },
      "SELECT * FROM foo INTERSECT SELECT * FROM bla",
      "",
    ),
    (
      () => @sqlglot.except_(["SELECT * FROM foo", "SELECT * FROM bla"]),
      "SELECT * FROM foo EXCEPT SELECT * FROM bla",
      "",
    ),
    (
      () => @sqlglot.parse_one("SELECT * FROM foo").except_("SELECT * FROM bla"),
      "SELECT * FROM foo EXCEPT SELECT * FROM bla",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("(SELECT * FROM foo)").union_("SELECT * FROM bla")
      },
      "(SELECT * FROM foo) UNION SELECT * FROM bla",
      "",
    ),
    (
      () => {
        @sqlglot.parse_one("(SELECT * FROM foo)").union_(
          "SELECT * FROM bla",
          distinct=false,
        )
      },
      "(SELECT * FROM foo) UNION ALL SELECT * FROM bla",
      "",
    ),
    (
      () => {
        @sqlglot.alias_(@sqlglot.parse_one("LAG(x) OVER (PARTITION BY y)"), "a")
      },
      "LAG(x) OVER (PARTITION BY y) AS a",
      "",
    ),
    (
      () => @sqlglot.alias_(@sqlglot.parse_one("LAG(x) OVER (ORDER BY z)"), "a"),
      "LAG(x) OVER (ORDER BY z) AS a",
      "",
    ),
    (
      () => {
        @sqlglot.alias_(
          @sqlglot.parse_one("LAG(x) OVER (PARTITION BY y ORDER BY z)"),
          "a",
        )
      },
      "LAG(x) OVER (PARTITION BY y ORDER BY z) AS a",
      "",
    ),
    (
      () => @sqlglot.alias_(@sqlglot.parse_one("LAG(x) OVER ()"), "a"),
      "LAG(x) OVER () AS a",
      "",
    ),
    (
      () => @sqlglot.values([@core.PyTuple([@core.PyStr("1"), @core.PyInt(2)])]),
      "VALUES ('1', 2)",
      "",
    ),
    (
      () => {
        @sqlglot.values(
          [@core.PyTuple([@core.PyStr("1"), @core.PyInt(2)])],
          alias="alias",
        )
      },
      "(VALUES ('1', 2)) AS alias",
      "",
    ),
    (
      () => {
        @sqlglot.values([
          @core.PyTuple([@core.PyStr("1"), @core.PyInt(2)]),
          @core.PyTuple([@core.PyStr("2"), @core.PyInt(3)]),
        ])
      },
      "VALUES ('1', 2), ('2', 3)",
      "",
    ),
    (
      () => {
        @sqlglot.values(
          [
            @core.PyTuple([@core.PyStr("1"), @core.PyInt(2), @core.PyNone]),
            @core.PyTuple([@core.PyStr("2"), @core.PyInt(3), @core.PyNone]),
          ],
          alias="alias",
          columns=["col1", "col2", "col3"],
        )
      },
      "(VALUES ('1', 2, NULL), ('2', 3, NULL)) AS alias(col1, col2, col3)",
      "",
    ),
    (
      () => @sqlglot.delete("y", where_="x > 1"),
      "DELETE FROM y WHERE x > 1",
      "",
    ),
    (
      () => @sqlglot.delete("y", where_=@sqlglot.and_(["x > 1"])),
      "DELETE FROM y WHERE x > 1",
      "",
    ),
    (
      () => {
        @sqlglot.select(["AVG(a) OVER b"])
        .from_("table")
        .window(["b AS (PARTITION BY c ORDER BY d)"])
      },
      "SELECT AVG(a) OVER b FROM table WINDOW b AS (PARTITION BY c ORDER BY d)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["AVG(a) OVER b", "MIN(c) OVER d"])
        .from_("table")
        .window(["b AS (PARTITION BY e ORDER BY f)"])
        .window(["d AS (PARTITION BY g ORDER BY h)"])
      },
      "SELECT AVG(a) OVER b, MIN(c) OVER d FROM table WINDOW b AS (PARTITION BY e ORDER BY f), d AS (PARTITION BY g ORDER BY h)",
      "",
    ),
    (
      () => {
        @sqlglot.select(["*"])
        .from_("table")
        .qualify(["row_number() OVER (PARTITION BY a ORDER BY b) = 1"])
      },
      "SELECT * FROM table QUALIFY ROW_NUMBER() OVER (PARTITION BY a ORDER BY b) = 1",
      "",
    ),
    (
      () => @sqlglot.delete("tbl1", where_="x = 1").delete("tbl2"),
      "DELETE FROM tbl2 WHERE x = 1",
      "",
    ),
    (
      () => @sqlglot.delete("tbl").where_(["x = 1"]),
      "DELETE FROM tbl WHERE x = 1",
      "",
    ),
    (() => @sqlglot.delete(@sqlglot.table_("tbl")), "DELETE FROM tbl", ""),
    (
      () => @sqlglot.delete("tbl", where_="x = 1").where_(["y = 2"]),
      "DELETE FROM tbl WHERE x = 1 AND y = 2",
      "",
    ),
    (
      () => {
        @sqlglot.delete("tbl", where_="x = 1").where_([
          @sqlglot.condition("y = 2").or_(["z = 3"]),
        ])
      },
      "DELETE FROM tbl WHERE x = 1 AND (y = 2 OR z = 3)",
      "",
    ),
    (
      () => {
        @sqlglot.delete("tbl")
        .where_(["x = 1"])
        .returning("*", dialect=postgres)
      },
      "DELETE FROM tbl WHERE x = 1 RETURNING *",
      "postgres",
    ),
    (
      () => {
        @sqlglot.delete(
          "tbl",
          where_="x = 1",
          returning="*",
          dialect="postgres",
        )
      },
      "DELETE FROM tbl WHERE x = 1 RETURNING *",
      "postgres",
    ),
    (
      () => @sqlglot.insert("SELECT * FROM tbl2", "tbl"),
      "INSERT INTO tbl SELECT * FROM tbl2",
      "",
    ),
    (
      () => @sqlglot.insert("SELECT * FROM tbl2", "tbl", returning="*"),
      "INSERT INTO tbl SELECT * FROM tbl2 RETURNING *",
      "",
    ),
    (
      () => @sqlglot.insert("SELECT * FROM tbl2", "tbl", overwrite=true),
      "INSERT OVERWRITE TABLE tbl SELECT * FROM tbl2",
      "",
    ),
    (
      () => {
        @sqlglot.insert("VALUES (1, 2), (3, 4)", "tbl", columns=["cola", "colb"])
      },
      "INSERT INTO tbl (cola, colb) VALUES (1, 2), (3, 4)",
      "",
    ),
    (
      () => @sqlglot.insert("VALUES (1), (2)", "tbl", columns=["col a"]),
      "INSERT INTO tbl (\"col a\") VALUES (1), (2)",
      "",
    ),
    (
      () => {
        @sqlglot.insert("SELECT * FROM cte", "t").with_(
          "cte", "SELECT x FROM tbl",
        )
      },
      "WITH cte AS (SELECT x FROM tbl) INSERT INTO t SELECT * FROM cte",
      "",
    ),
    (
      () => {
        @sqlglot.insert("SELECT * FROM cte", "t").with_(
          "cte",
          "SELECT x FROM tbl",
          materialized=true,
        )
      },
      "WITH cte AS MATERIALIZED (SELECT x FROM tbl) INSERT INTO t SELECT * FROM cte",
      "",
    ),
    (
      () => {
        @sqlglot.insert("SELECT * FROM cte", "t").with_(
          "cte",
          "SELECT x FROM tbl",
          materialized=false,
        )
      },
      "WITH cte AS NOT MATERIALIZED (SELECT x FROM tbl) INSERT INTO t SELECT * FROM cte",
      "",
    ),
    (
      () => {
        @core.convert(
          @core.PyTuple([
            @core.PyExpr(@sqlglot.column("x")),
            @core.PyExpr(@sqlglot.column("y")),
          ]),
        ).isin(expressions=[
          @core.PyTuple([@core.PyInt(1), @core.PyInt(2)]),
          @core.PyTuple([@core.PyInt(3), @core.PyInt(4)]),
        ])
      },
      "(x, y) IN ((1, 2), (3, 4))",
      "postgres",
    ),
    (() => @sqlglot.cast("CAST(x AS INT)", "int"), "CAST(x AS INT)", ""),
    (
      () => @sqlglot.cast("CAST(x AS TEXT)", "int"),
      "CAST(CAST(x AS TEXT) AS INT)",
      "",
    ),
    (
      () => @sqlglot.rename_column("table1", "c1", "c2", exists=true),
      "ALTER TABLE table1 RENAME COLUMN IF EXISTS c1 TO c2",
      "",
    ),
    (
      () => @sqlglot.rename_column("table1", "c1", "c2", exists=false),
      "ALTER TABLE table1 RENAME COLUMN c1 TO c2",
      "",
    ),
    (
      () => @sqlglot.rename_column("table1", "c1", "c2"),
      "ALTER TABLE table1 RENAME COLUMN c1 TO c2",
      "",
    ),
    (
      () => {
        @sqlglot.merge(
          [
            "WHEN MATCHED THEN UPDATE SET col1 = source.col1", "WHEN NOT MATCHED THEN INSERT (col1) VALUES (source.col1)",
          ],
          into="target_table",
          using_="source_table",
          on="target_table.id = source_table.id",
        )
      },
      "MERGE INTO target_table USING source_table ON target_table.id = source_table.id WHEN MATCHED THEN UPDATE SET col1 = source.col1 WHEN NOT MATCHED THEN INSERT (col1) VALUES (source.col1)",
      "",
    ),
    (
      () => {
        @sqlglot.merge(
          [
            "WHEN MATCHED AND source.is_deleted = 1 THEN DELETE", "WHEN MATCHED THEN UPDATE SET val = source.val",
            "WHEN NOT MATCHED THEN INSERT (id, val) VALUES (source.id, source.val)",
          ],
          into="target_table",
          using_="source_table",
          on="target_table.id = source_table.id",
        )
      },
      "MERGE INTO target_table USING source_table ON target_table.id = source_table.id WHEN MATCHED AND source.is_deleted = 1 THEN DELETE WHEN MATCHED THEN UPDATE SET val = source.val WHEN NOT MATCHED THEN INSERT (id, val) VALUES (source.id, source.val)",
      "",
    ),
    (
      () => {
        @sqlglot.merge(
          ["WHEN MATCHED THEN UPDATE SET target.name = source.name"],
          into=@sqlglot.table_("target_table").as_("target"),
          using_=@sqlglot.table_("source_table").as_("source"),
          on="target.id = source.id",
        )
      },
      "MERGE INTO target_table AS target USING source_table AS source ON target.id = source.id WHEN MATCHED THEN UPDATE SET target.name = source.name",
      "",
    ),
    (
      () => {
        @sqlglot.merge(
          ["WHEN MATCHED THEN UPDATE SET target.name = source.name"],
          into=@sqlglot.table_("target_table").as_("target"),
          using_=@sqlglot.table_("source_table").as_("source"),
          on="target.id = source.id",
          returning="target.*",
        )
      },
      "MERGE INTO target_table AS target USING source_table AS source ON target.id = source.id WHEN MATCHED THEN UPDATE SET target.name = source.name RETURNING target.*",
      "",
    ),
    (
      () => {
        @sqlglot.merge(
          [
            @core.mk(When, [
              ("matched", true),
              (
                "then",
                @core.mk(Update, [
                  (
                    "expressions",
                    [
                      @sqlglot.column("name", table="target").eq_(
                        @sqlglot.column("name", table="source"),
                      ),
                    ],
                  ),
                ]),
              ),
            ]),
          ],
          into=@sqlglot.table_("target_table").as_("target"),
          using_=@sqlglot.table_("source_table").as_("source"),
          on="target.id = source.id",
          returning="target.*",
        )
      },
      "MERGE INTO target_table AS target USING source_table AS source ON target.id = source.id WHEN MATCHED THEN UPDATE SET target.name = source.name RETURNING target.*",
      "",
    ),
    (
      () => @sqlglot.union(["SELECT 1", "SELECT 2", "SELECT 3", "SELECT 4"]),
      "SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4",
      "",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_(
          "var1",
          @sqlglot.select(["x"]).from_("tbl2").subquery(),
          scalar=true,
        )
        .from_("tbl")
        .where_(["x > var1"])
      },
      "WITH (SELECT x FROM tbl2) AS var1 SELECT x FROM tbl WHERE x > var1",
      "clickhouse",
    ),
    (
      () => {
        @sqlglot.select(["x"])
        .with_("var1", @sqlglot.select(["x"]).from_("tbl2"), scalar=true)
        .from_("tbl")
        .where_(["x > var1"])
      },
      "WITH (SELECT x FROM tbl2) AS var1 SELECT x FROM tbl WHERE x > var1",
      "clickhouse",
    ),
  ]
  ignore(mysql)
  let failures = []
  for case in cases {
    let (build, sql, dialect) = case
    let actual = @sqlglot.generate(build(), dialect~) catch {
      e => "ERROR: \{e}"
    }
    if actual != sql {
      failures.push("expected: \{sql}\n  actual: \{actual}")
    }
  }
  assert_eq(failures.length(), 0, msg=failures.join("\n"))
}
