// Hand-ported assertions of tests/test_lineage.py that the recorded graph dumps of
// lineage_test.mbt can't express: node identity/sharing, callbacks, `copy=`, prebuilt
// scopes, mutation of the inputs and DAG traversal.

///|
fn schema_of(j : Json) -> @optimizer.MappingSchema raise {
  guard @optimizer.SchemaNode::from_json(j) is Dict(m) else {
    fail("schema must be an object")
  }
  @optimizer.MappingSchema::new(schema=m)
}

///|
fn gen_sql(e : @core.Expr) -> String raise {
  @sqlglot.generate(e)
}

///|
fn names(nodes : Array[@lineage.Node]) -> Array[String] {
  nodes.map(n => n.name)
}

///|
test "TestLineage.test_lineage (sources and node sources)" {
  let node = @lineage.lineage(
    "a",
    @sqlglot.parse_one("SELECT a FROM z"),
    schema=schema_of({ "x": { "a": "int" } }),
    sources={
      "y": @sqlglot.parse_one("SELECT * FROM x"),
      "z": @sqlglot.parse_one("SELECT a FROM y"),
    },
  )
  assert_eq(
    gen_sql(node.source),
    "SELECT z.a AS a FROM (SELECT y.a AS a FROM (SELECT x.a AS a FROM x AS x) AS y /* source: y */) AS z /* source: z */",
  )
  assert_eq(node.source_name, "")
  let downstream = node.downstream[0]
  assert_eq(
    gen_sql(downstream.source),
    "SELECT y.a AS a FROM (SELECT x.a AS a FROM x AS x) AS y /* source: y */",
  )
  assert_eq(downstream.source_name, "z")
  let downstream = downstream.downstream[0]
  assert_eq(gen_sql(downstream.source), "SELECT x.a AS a FROM x AS x")
  assert_eq(downstream.source_name, "y")
  let html = node.to_html()
  assert_true(html.length() > 1000)

  // the sql is not modified
  let sql = "SELECT a FROM x"
  let ast = @sqlglot.parse_one(sql)
  @lineage.lineage("a", ast) |> ignore
  assert_eq(gen_sql(ast), sql)

  // the sources are not modified
  let ast = @sqlglot.parse_one(sql)
  let source_sql = "SELECT a FROM y"
  let source = @sqlglot.parse_one(source_sql)
  @lineage.lineage("a", ast, sources={ "x": source }) |> ignore
  assert_eq(gen_sql(source), source_sql)
}

///|
test "TestLineage.test_lineage_no_self_loops_with_multi_aliased_union_cte" {
  let query =
    #|WITH three_way AS (
    #|    SELECT a FROM t1
    #|    UNION ALL
    #|    SELECT a FROM t2
    #|    UNION ALL
    #|    SELECT a FROM t3
    #|),
    #|attached AS (
    #|    SELECT COALESCE(r1.a, r2.a) AS a
    #|    FROM three_way AS r1
    #|    LEFT JOIN three_way AS r2 ON r1.a = r2.a
    #|)
    #|SELECT a FROM attached
  let node = @lineage.lineage("a", @sqlglot.parse_one(query))
  let visited : Map[Int, Bool] = Map([])
  let stack = [(node, [node.id])]
  while stack.pop() is Some((current, path)) {
    if visited.contains(current.id) {
      continue
    }
    visited[current.id] = true
    for child in current.downstream {
      assert_true(
        !path.contains(child.id),
        msg="cycle detected at node '\{child.name}'",
      )
      stack.push((child, path + [child.id]))
    }
  }
}

///|
test "TestLineage.test_copy_flag" {
  let schema : Json = { "x": { "a": "int" } }
  let query = @sqlglot.parse_one("SELECT a FROM z")
  let sources = {
    "y": @sqlglot.parse_one("SELECT * FROM x"),
    "z": @sqlglot.parse_one("SELECT * FROM y"),
  }
  @lineage.lineage("a", query, schema=schema_of(schema), sources~, copy=false)
  |> ignore
  assert_eq(gen_sql(sources["y"]), "SELECT * FROM x")
  assert_eq(gen_sql(sources["z"]), "SELECT * FROM y")
  assert_eq(
    gen_sql(query),
    "SELECT z.a AS a FROM (SELECT y.a AS a FROM (SELECT x.a AS a FROM x AS x) AS y /* source: y */) AS z /* source: z */",
  )
  let query = @sqlglot.parse_one("SELECT a FROM z")
  let sources = {
    "y": @sqlglot.parse_one("SELECT * FROM x"),
    "z": @sqlglot.parse_one("SELECT * FROM y"),
  }
  @lineage.lineage("a", query, schema=schema_of(schema), sources~, copy=true)
  |> ignore
  assert_eq(gen_sql(sources["y"]), "SELECT * FROM x")
  assert_eq(gen_sql(sources["z"]), "SELECT * FROM y")
  assert_eq(gen_sql(query), "SELECT a FROM z")
  let query = @sqlglot.parse_one("SELECT a FROM x")
  @lineage.lineage("a", query, schema=schema_of(schema), copy=false) |> ignore
  assert_eq(gen_sql(query), "SELECT x.a AS a FROM x AS x")
  let query = @sqlglot.parse_one("SELECT a FROM x")
  @lineage.lineage("a", query, schema=schema_of(schema), copy=true) |> ignore
  assert_eq(gen_sql(query), "SELECT a FROM x")
}

///|
test "TestLineage.test_lineage_shared_cte_performance" {
  let n_levels = 12
  let ctes = ["cte_0 AS (SELECT a FROM base_table)"]
  for k in 1..<n_levels {
    let prev = "cte_\{k - 1}"
    ctes.push(
      "cte_\{k} AS (SELECT t1.a + t2.a AS a FROM \{prev} t1 JOIN \{prev} t2 ON t1.a = t2.a)",
    )
  }
  let sql = "WITH " +
    ctes.join(",\n     ") +
    "\nSELECT a FROM cte_\{n_levels - 1}"
  let node = @lineage.lineage(
    "a",
    @sqlglot.parse_one(sql),
    schema=schema_of({ "base_table": { "a": "int" } }),
  )
  let all_nodes = node.walk()
  assert_true(
    all_nodes.length() < 200,
    msg="got \{all_nodes.length()} nodes -- DAG walk may be broken",
  )
  // walk() yields each node exactly once (identity = the node's id; ids are unique
  // per created node, and physically distinct nodes never share one)
  let ids : Map[Int, @lineage.Node] = Map([])
  for n in all_nodes {
    assert_true(!ids.contains(n.id))
    ids[n.id] = n
  }
  let leaves = all_nodes.filter(n => n.downstream.is_empty())
  assert_true(leaves.length() > 0)
  for n in leaves {
    assert_true(gen_sql(n.source).contains("base_table"))
  }
}

///|
test "TestLineage.test_lineage_cte_self_join_distinct_aliases" {
  let node = @lineage.lineage(
    "combined",
    @sqlglot.parse_one(
      "WITH shared AS (SELECT a FROM x) SELECT s1.a + s2.a AS combined FROM shared s1, shared s2",
    ),
    schema=schema_of({ "x": { "a": "int" } }),
  )
  let downstream_names = names(node.downstream)
  downstream_names.sort()
  assert_eq(downstream_names, ["s1.a", "s2.a"])
}

///|
test "TestLineage.test_lineage_all_columns" {
  let schema : Json = { "x": { "a": "int", "b": "int" } }
  let result = @lineage.lineage_all(
    @sqlglot.parse_one("SELECT a, b + 1 AS bp FROM x"),
    schema=schema_of(schema),
  )
  assert_eq(result.keys().collect(), ["a", "bp"])
  let single = @lineage.lineage(
    "a",
    @sqlglot.parse_one("SELECT a, b + 1 AS bp FROM x"),
    schema=schema_of(schema),
  )
  assert_eq(result["a"].name, single.name)
  assert_eq(names(result["a"].downstream), names(single.downstream))
}

///|
test "TestLineage.test_lineage_on_node_hook" {
  let nodes_visited = []
  let result = @lineage.lineage_all(
    @sqlglot.parse_one("WITH t AS (SELECT a + 1 AS v FROM x) SELECT v FROM t"),
    schema=schema_of({ "x": { "a": "int" } }),
    on_node=node => {
      nodes_visited.push(node.name)
      node.payload["seen"] = true
    },
  )
  assert_true(nodes_visited.length() >= 3)
  assert_eq(result["v"].payload.get("seen"), Some(true))
  assert_true(
    result["v"].walk().iter().all(n => n.payload.get("seen") is Some(True)),
  )
}

///|
test "TestLineage.test_lineage_all_columns_shares_nodes_across_outputs" {
  let result = @lineage.lineage_all(
    @sqlglot.parse_one(
      "WITH t AS (SELECT a, b FROM x) SELECT a, a + b AS ab FROM t",
    ),
    schema=schema_of({ "x": { "a": "int", "b": "int" } }),
  )
  assert_eq(result.keys().collect(), ["a", "ab"])
  let a_via_a = result["a"].downstream[0]
  guard result["ab"].downstream.search_by(d => d.name == "t.a") is Some(i) else {
    fail("no t.a below ab")
  }
  let a_via_ab = result["ab"].downstream[i]
  // assertIs: the very same node object
  assert_true(physical_equal(a_via_a, a_via_ab))
  assert_true(physical_equal(a_via_a.downstream[0], a_via_ab.downstream[0]))
}

///|
test "TestLineage.test_lineage_all_columns_set_operation" {
  let result = @lineage.lineage_all(
    @sqlglot.parse_one(
      (
        #|WITH u AS (SELECT a, b FROM x UNION ALL SELECT a, b FROM y)
        #|SELECT a, b FROM u
      ),
    ),
    schema=schema_of({
      "x": { "a": "int", "b": "int" },
      "y": { "a": "int", "b": "int" },
    }),
  )
  assert_eq(result.keys().collect(), ["a", "b"])
  for col in ["a", "b"] {
    let branches = result[col].downstream
    assert_eq(branches.length(), 2)
    let sources = []
    for branch in branches {
      for leaf in branch.walk() {
        let s = gen_sql(leaf.expression)
        if s.has_suffix("AS x") || s.has_suffix("AS y") {
          sources.push(s)
        }
      }
    }
    sources.sort()
    assert_eq(sources, ["x AS x", "y AS y"])
  }
}

///|
test "TestLineage.test_lineage_all_columns_with_prebuilt_scope" {
  let sql = "SELECT a, b + 1 AS bp FROM x"
  let schema : Json = { "x": { "a": "int", "b": "int" } }
  let qualified = @optimizer.qualify(
    @sqlglot.parse_one(sql),
    schema=schema_of(schema),
    validate_qualify_columns=false,
    identify=false,
  )
  guard @optimizer.build_scope(qualified) is Some(scope) else {
    fail("no scope")
  }
  let from_scope = @lineage.lineage_all(qualified, scope~)
  let from_sql = @lineage.lineage_all(
    @sqlglot.parse_one(sql),
    schema=schema_of(schema),
  )
  assert_eq(from_scope.keys().collect(), from_sql.keys().collect())
  for name, node in from_scope {
    assert_eq(node.name, from_sql[name].name)
    assert_eq(names(node.downstream), names(from_sql[name].downstream))
  }
}

///|
test "TestLineage.test_lineage_on_node_orders_children_before_parents" {
  let order : Array[Int] = []
  let result = @lineage.lineage_all(
    @sqlglot.parse_one("WITH t AS (SELECT a + 1 AS v FROM x) SELECT v FROM t"),
    schema=schema_of({ "x": { "a": "int" } }),
    on_node=node => order.push(node.id),
  )
  let position : Map[Int, Int] = Map([])
  for i, id in order {
    position[id] = i
  }
  for node in result["v"].walk() {
    for child in node.downstream {
      assert_true(
        position[child.id] < position[node.id],
        msg="\{child.name} fired after parent \{node.name}",
      )
    }
  }
}

///|
test "TestLineage.test_lineage_on_node_fires_once_per_node" {
  let counts : Map[Int, Int] = Map([])
  let result = @lineage.lineage_all(
    @sqlglot.parse_one(
      "WITH t AS (SELECT a, b FROM x) SELECT a, a + b AS ab FROM t",
    ),
    schema=schema_of({ "x": { "a": "int", "b": "int" } }),
    on_node=node => counts[node.id] = counts.get(node.id).unwrap_or(0) + 1,
  )
  let seen : Map[Int, Bool] = Map([])
  for _, top in result {
    for node in top.walk() {
      seen[node.id] = true
    }
  }
  assert_true(!seen.is_empty())
  for id, _ in seen {
    assert_eq(counts.get(id).unwrap_or(0), 1)
  }
}

///|
test "TestLineage.test_table_udtfs (qualify kwargs)" {
  let sql =
    #|WITH t AS (
    #|  SELECT p.user_id, gs.n AS to_deposit_days
    #|  FROM tbl1 AS p
    #|  CROSS JOIN (
    #|    SELECT generate_series AS n FROM TABLE(generate_series(0, 8000))
    #|  ) AS gs
    #|),
    #|t2 AS (
    #|  SELECT t.* FROM t
    #|)
    #|SELECT user_id, to_deposit_days FROM t2
  let dialect = @sqlglot.dialect("starrocks")
  let node = @lineage.lineage(
    "to_deposit_days",
    @sqlglot.parse_one(sql, read="starrocks"),
    schema=schema_of({ "tbl1": { "user_id": "BIGINT" } }),
    dialect~,
    expand_stars=true,
    validate_qualify_columns=true,
  )
  let node = node.downstream[0].downstream[0].downstream[0].downstream[0]
  assert_eq(node.name, "_0.generate_series")
  assert_eq(
    @sqlglot.generate(node.source, dialect="starrocks"),
    "TABLE(GENERATE_SERIES(0, 8000)) AS _0(generate_series)",
  )
}
