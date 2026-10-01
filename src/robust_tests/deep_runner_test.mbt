// Deep chains of NOT / unary minus / ~ / parentheses (generated iteratively by the port)
// against Python's recursive generator; fixtures from tools/gen_deep_fixtures.py.

///|
fn build_chain(spec : String) -> @core.Expr {
  let links : Array[(@core.Kind, Bool)] = []
  let mut comment = false
  for ch in spec {
    if ch == 'c' {
      comment = true
      continue
    }
    let kind : @core.Kind = match ch {
      '-' => Neg
      'N' => Not
      '~' => BitwiseNot
      _ => Paren
    }
    links.push((kind, comment))
    comment = false
  }
  let mut e = @core.column_of("x")
  for i = links.length() - 1; i >= 0; i = i - 1 {
    let (kind, has_comment) = links[i]
    e = @core.mk1(kind, e)
    if has_comment {
      e.add_comments(Some(["c\{i}"]))
    }
  }
  e
}

///|
test "deep: unary and parenthesis chains generate like Python" {
  let r = Report::new("deep chains")
  for row in deep_chains {
    let (spec, pretty, expected) = row
    let e = build_chain(spec)
    r.expect(
      "\{spec} pretty=\{pretty}",
      attempt(() => @sqlglot.generate(e, pretty~)),
      expected,
    )
  }
  r.finish()
}

///|
test "deep: very deep chains don't exhaust the stack" {
  // 20,000 links: generated, copied, compared and hashed without recursion
  let spec = "-N~(".repeat(5000)
  let e = build_chain(spec)
  let sql = @sqlglot.generate(e)
  inspect(sql.length() > 20000, content="true")
  let copy = e.copy()
  inspect(copy == e, content="true")
  inspect(copy.hash() == e.hash(), content="true")
  inspect(e.walk().count(), content="20002")
  inspect(e.find_all([Column]).count(), content="1")
  let loaded = @core.Expr::load(@json.parse(e.dump().stringify())).unwrap()
  inspect(loaded == e, content="true")
  let transformed = e.transform(n => Some(n))
  inspect(transformed == e, content="true")
}

///|
test "deep: simplify and optimize very deep chains" {
  let e = build_chain("-N~(".repeat(5000))
  let select = @core.mk(Select, [
    ("expressions", [e]),
    ("from_", @core.mk1(From, @core.mk1(Table, @core.to_identifier("t")))),
  ])
  inspect(
    @sqlglot.generate(@optimizer.simplify(select.copy())).length() > 0,
    content="true",
  )
  inspect(
    @sqlglot.generate(@optimizer.optimize(select.copy())).length() > 0,
    content="true",
  )
}
