// Copy semantics of the fluent builders: like Python, builder methods default to
// `copy=true`, so deriving several queries from one base never mutates the base, and
// `copy=false` modifies the instance in place.

///|
/// Checks that every child of `e` points back to `e` with the right `arg_key`/`index`.
fn check_tree_integrity(e : @core.Expr) -> Unit raise {
  for key, value in e.args {
    match value {
      Node(child) => {
        guard child.parent is Some(p) && physical_equal(p, e) else {
          fail("\{key}: child has a wrong parent")
        }
        assert_eq(child.arg_key, Some(key))
        assert_eq(child.index, None)
        check_tree_integrity(child)
      }
      List(items) =>
        for i, item in items {
          guard item is Node(child) else { continue }
          guard child.parent is Some(p) && physical_equal(p, e) else {
            fail("\{key}[\{i}]: child has a wrong parent")
          }
          assert_eq(child.arg_key, Some(key))
          assert_eq(child.index, Some(i))
          check_tree_integrity(child)
        }
      _ => ()
    }
  }
}

///|
fn node_uids(e : @core.Expr) -> @set.Set[Int] {
  let out = @set.Set::new()
  for n in e.walk() {
    out.add(n.uid)
  }
  out
}

///|
test "builders: deriving queries from one base leaves the base untouched" {
  let base = @sqlglot.select(["a", "b"]).from_("t")
  let base_sql = @sqlglot.generate(base)
  let base_uids = node_uids(base)
  let derived : Array[(@core.Expr, String)] = [
    (base.where_(["x = 1"]), "SELECT a, b FROM t WHERE x = 1"),
    (base.where_(["y = 2"]).limit_(5), "SELECT a, b FROM t WHERE y = 2 LIMIT 5"),
    (base.select_(["c"]), "SELECT a, b, c FROM t"),
    (base.select_(["c"], append=false), "SELECT c FROM t"),
    (
      base.join_("u", on=["t.id = u.id"], join_type="left"),
      "SELECT a, b FROM t LEFT JOIN u ON t.id = u.id",
    ),
    (
      base.group_by(["a"]).having_(["COUNT(*) > 1"]),
      "SELECT a, b FROM t GROUP BY a HAVING COUNT(*) > 1",
    ),
    (
      base.order_by(["b DESC"]).offset_(3),
      "SELECT a, b FROM t ORDER BY b DESC OFFSET 3",
    ),
    (base.with_("cte", "SELECT 1"), "WITH cte AS (SELECT 1) SELECT a, b FROM t"),
    (base.distinct_(), "SELECT DISTINCT a, b FROM t"),
    (
      base.qualify(["ROW_NUMBER() OVER (PARTITION BY a) = 1"]),
      "SELECT a, b FROM t QUALIFY ROW_NUMBER() OVER (PARTITION BY a) = 1",
    ),
    (base.sort_by(["a"]), "SELECT a, b FROM t SORT BY a"),
    (base.cluster_by(["a"]), "SELECT a, b FROM t CLUSTER BY a"),
    (base.hint(["BROADCAST(t)"]), "SELECT /*+ BROADCAST(t) */ a, b FROM t"),
    (
      base.lateral(["explode(b) tf AS c"]),
      "SELECT a, b FROM t LATERAL VIEW EXPLODE(b) tf AS c",
    ),
    (
      base.window(["w AS (PARTITION BY a)"]),
      "SELECT a, b FROM t WINDOW w AS (PARTITION BY a)",
    ),
    (
      base.union_("SELECT c, d FROM u"),
      "SELECT a, b FROM t UNION SELECT c, d FROM u",
    ),
    (
      base.intersect_("SELECT c, d FROM u"),
      "SELECT a, b FROM t INTERSECT SELECT c, d FROM u",
    ),
    (
      base.except_("SELECT c, d FROM u"),
      "SELECT a, b FROM t EXCEPT SELECT c, d FROM u",
    ),
    (base.ctas("t2"), "CREATE TABLE t2 AS SELECT a, b FROM t"),
    (base.subquery(alias="s"), "(SELECT a, b FROM t) AS s"),
  ]
  let locked = base.lock()
  assert_eq(
    @sqlglot.generate(locked, dialect="mysql"),
    "SELECT a, b FROM t FOR UPDATE",
  )
  for item in derived {
    let (query, expected) = item
    assert_eq(@sqlglot.generate(query), expected)
    check_tree_integrity(query)
    // No node is shared with the base query.
    for n in query.walk() {
      assert_false(base_uids.contains(n.uid))
    }
  }
  assert_eq(@sqlglot.generate(base), base_sql)
  assert_true(base.arg("where") is None)
  assert_true(base.arg("joins") is None)
  check_tree_integrity(base)
}

///|
test "builders: copy=false modifies the instance in place" {
  let s = @sqlglot.select(["a"]).from_("t")
  let cond = @sqlglot.condition("x = 1")
  let q = s.where_([cond], copy=false)
  assert_true(physical_equal(q, s))
  assert_eq(@sqlglot.generate(s), "SELECT a FROM t WHERE x = 1")
  // the condition is used as-is when not copying
  assert_true(physical_equal(s.arg("where").unwrap().this_(), cond))
  check_tree_integrity(s)
  // with the default (copy=true) the condition is copied too
  let cond2 = @sqlglot.condition("y = 2")
  let q2 = s.where_([cond2])
  assert_false(physical_equal(q2, s))
  assert_true(cond2.parent is None)
  assert_eq(@sqlglot.generate(q2), "SELECT a FROM t WHERE x = 1 AND y = 2")
  assert_eq(@sqlglot.generate(s), "SELECT a FROM t WHERE x = 1")
  check_tree_integrity(q2)
  // chained in-place building
  let r = @sqlglot.select(["a"], copy=false)
  r.from_("t", copy=false).group_by(["a"], copy=false).limit_(1, copy=false)
  |> ignore
  assert_eq(@sqlglot.generate(r), "SELECT a FROM t GROUP BY a LIMIT 1")
}

///|
test "builders: connectors, not_ and cast copy their operands by default" {
  let c = @sqlglot.condition("x = 1")
  let a = @sqlglot.and_(([c, "y = 2"] : Array[&@core.IntoPy]))
  assert_true(c.parent is None)
  assert_eq(@sqlglot.generate(a), "x = 1 AND y = 2")
  let a2 = @sqlglot.and_(([c, "y = 2"] : Array[&@core.IntoPy]), copy=false)
  assert_true(c.parent is Some(p) && physical_equal(p, a2))
  let d = @sqlglot.condition("z = 3")
  let n = @sqlglot.not_(d)
  assert_true(d.parent is None)
  assert_eq(@sqlglot.generate(n), "NOT z = 3")
  // core helpers taking expressions follow the same contract
  let e1 = @sqlglot.condition("p = 1")
  let e2 = @sqlglot.condition("q = 2")
  let o = @core.or_([e1, e2])
  assert_true(e1.parent is None && e2.parent is None)
  check_tree_integrity(o)
  let o2 = @core.or_([e1, e2], copy=false)
  assert_true(e1.parent is Some(p) && physical_equal(p, o2))
  let col = @sqlglot.column("col")
  let cast = @core.cast_(col, INT)
  assert_true(col.parent is None)
  assert_eq(@sqlglot.generate(cast), "CAST(col AS INT)")
  let cast2 = @core.cast_(col, INT, copy=false)
  assert_true(col.parent is Some(p) && physical_equal(p, cast2))
  let neg = @core.not_(e2)
  assert_true(physical_equal(e2.parent.unwrap(), o2))
  check_tree_integrity(neg)
}
