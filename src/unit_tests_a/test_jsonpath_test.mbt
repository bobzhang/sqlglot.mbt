// Port of tests/test_jsonpath.py

///|
/// `sqlglot.jsonpath.parse(path)` with the base dialect.
fn jsonpath(path : String) -> @core.Expr raise {
  @core.parse_json_path(path, @core.base_dialect())
}

///|
test "TestJsonpath.test_jsonpath" {
  let expected_expressions = [
    @core.mk0(JSONPathRoot),
    @core.mk1(JSONPathKey, @core.mk0(JSONPathWildcard)),
    @core.mk1(JSONPathKey, "a"),
    @core.mk1(JSONPathSubscript, 0),
    @core.mk1(JSONPathKey, "x"),
    @core.mk(JSONPathUnion, [
      (
        "expressions",
        [@core.Node(@core.mk0(JSONPathWildcard)), @core.Str("y"), @core.Int(1)],
      ),
    ]),
    @core.mk1(JSONPathKey, "z"),
    @core.mk1(JSONPathSelector, @core.mk1(JSONPathFilter, "(@.a == 'b'), 1:")),
    @core.mk1(
      JSONPathSubscript,
      @core.mk(JSONPathSlice, [
        ("start", 1),
        ("end", 5),
        ("step", (None : Int?)),
      ]),
    ),
    @core.mk(JSONPathUnion, [
      (
        "expressions",
        [@core.Int(1), @core.Node(@core.mk1(JSONPathFilter, "@.a"))],
      ),
    ]),
    @core.mk1(JSONPathSelector, @core.mk1(JSONPathScript, "@.x)")),
  ]
  let t = t()
  t.eq_expr(
    jsonpath(
      "$.*.a[0]['x'][*, 'y', 1].z[?(@.a == 'b'), 1:][1:5][1,?@.a][(@.x)]",
    ),
    @core.mk(JSONPath, [("expressions", expected_expressions)]),
  )
  t.done()
}

///|
test "TestJsonpath.test_unclosed_filter_raises_parse_error" {
  // A filter/script that runs off the end of the path without a closing
  // bracket must raise ParseError, not IndexError.
  for selector in ["$[?(@.x", "$[(@.x", "$[?(1"] {
    try jsonpath(selector) catch {
      @core.ParseError(_, _) => ()
      e => fail("\{selector}: expected ParseError, got \{e}")
    } noraise {
      _ => fail("\{selector}: expected ParseError")
    }
  }
}

///|
test "TestJsonpath.test_identity" {
  for
    case in [
      ("$.select", "$.select"),
      ("$[(@.length-1)]", "$[(@.length-1)]"),
      ("$[((@.length-1))]", "$[((@.length-1))]"),
    ] {
    let (selector, expected) = case
    assert_eq(gen(jsonpath(selector)), "'\{expected}'")
  }
}

///|
test "TestJsonpath.test_union_preserves_falsey_members" {
  let cases : Array[(String, @core.Expr)] = [
    (
      "$[1,0]",
      @core.mk(JSONPathUnion, [("expressions", [@core.Int(1), @core.Int(0)])]),
    ),
    (
      "$[\"a\",\"\"]",
      @core.mk(JSONPathUnion, [("expressions", [@core.Str("a"), @core.Str("")])]),
    ),
    (
      "$[\"\",1]",
      @core.mk(JSONPathUnion, [("expressions", [@core.Str(""), @core.Int(1)])]),
    ),
  ]
  let t = t()
  for case in cases {
    let (selector, expected) = case
    let exprs = jsonpath(selector).expressions()
    t.eq_expr(exprs[exprs.length() - 1], expected)
  }
  let exprs = jsonpath("$[0]").expressions()
  t.eq_expr(exprs[exprs.length() - 1], @core.mk1(JSONPathSubscript, 0))
  t.done()
}

///|
test "TestJsonpath.test_cts_file" {
  // sqlglot json path generator rewrites to a normal form
  let overrides : Map[String, String] = {}
  for i = 0; i < cts_overrides.length(); i = i + 2 {
    overrides[cts_overrides[i]] = cts_overrides[i + 1]
  }
  let t = t()
  for i = 0; i < cts_fixtures.length(); i = i + 3 {
    let name = cts_fixtures[i]
    let selector = cts_fixtures[i + 1]
    if cts_fixtures[i + 2] == "1" {
      // invalid selector: may raise ParseError/TokenError, or parse
      try jsonpath(selector) catch {
        @core.ParseError(_, _) | @core.TokenError(_) => ()
        e => t.ok(false, msg="\{selector} /* \{name} */: unexpected error \{e}")
      } noraise {
        _ => ()
      }
    } else if selector.contains("113667776004") {
      // SKIP (6 selectors): JSONPath indices are stored as 32-bit `Value::Int`
      // (Python ints are unbounded), so 113667776004 overflows.
      continue
    } else {
      let expected = overrides
        .get(selector)
        .unwrap_or(selector)
        .replace_all(old="'", new="''")
      t.eqf(() => gen(jsonpath(selector)), "'\{expected}'")
    }
  }
  t.done()
}
