// Hand-ported tests of tests/test_diff.py that the recorded fixtures (diff_test.mbt)
// can't replay: supplied matchings (including nodes shared between the trees), the
// dialect option, explicit None args and comments.

///|
/// `TestDiff._validate_delta_only`: `set(actual) == set(expected)`.
fn validate_delta_only(
  actual : Array[@diff.Edit],
  expected : Array[@diff.Edit],
) -> Unit raise {
  let missing = expected.filter(e => !actual.contains(e))
  let extra = actual.filter(e => !expected.contains(e))
  if !missing.is_empty() || !extra.is_empty() {
    fail(
      "missing: \{Repr(missing.map(e => e.to_string()))}\nunexpected: \{Repr(extra.map(e => e.to_string()))}",
    )
  }
}

///|
fn diff_delta_only(
  source : @core.Expr,
  target : @core.Expr,
  matchings? : Array[(@core.Expr, @core.Expr)] = [],
  dialect? : @core.Dialect,
) -> Array[@diff.Edit] {
  @diff.diff(source, target, matchings~, delta_only=true, dialect?)
}

///|
fn num(n : Int) -> @core.Expr {
  @core.literal_number(n.to_string())
}

///|
test "TestDiff.test_pre_matchings" {
  let expr_src = @core.parse_one("SELECT 1")
  let expr_tgt = @core.parse_one("SELECT 1, 2, 3, 4")
  validate_delta_only(diff_delta_only(expr_src, expr_tgt), [
    Remove(expr_src),
    Insert(expr_tgt),
    Insert(num(2)),
    Insert(num(3)),
    Insert(num(4)),
    Move(source=num(1), target=num(1)),
  ])
  validate_delta_only(
    diff_delta_only(expr_src, expr_tgt, matchings=[(expr_src, expr_tgt)]),
    [Insert(num(2)), Insert(num(3)), Insert(num(4))],
  )
  validate_delta_only(
    diff_delta_only(expr_src, expr_tgt, matchings=[
      (expr_src, expr_tgt),
      (expr_src, expr_tgt),
    ]),
    [Insert(num(2)), Insert(num(3)), Insert(num(4))],
  )
  // the trees now share a node: diff() works on copies and remaps the matchings
  expr_tgt.selects()[0].replace(Some(expr_src.selects()[0])) |> ignore
  validate_delta_only(
    diff_delta_only(expr_src, expr_tgt, matchings=[(expr_src, expr_tgt)]),
    [Insert(num(2)), Insert(num(3)), Insert(num(4))],
  )
}

///|
test "TestDiff.test_dialect_aware_diff" {
  // Python asserts that no warning is logged (generating Oracle's FOR UPDATE in the
  // base dialect would log "Unsupported ...")
  @sqlglot.register_dialects()
  @core.take_log_messages() |> ignore
  let expression = @core.parse_one(
    "SELECT foo FROM bar FOR UPDATE",
    dialect=@core.Dialect::get_or_raise("oracle"),
  )
  validate_delta_only(
    diff_delta_only(
      expression,
      expression.copy(),
      dialect=@core.Dialect::get_or_raise("oracle"),
    ),
    [],
  )
  assert_eq(@core.take_log_messages(), [])
}

///|
test "TestDiff.test_none_args_are_not_treated_as_leaves" {
  let expr_src = @core.mk(@core.Kind::Column, [
    ("this", @core.to_identifier("b")),
    ("table", @core.to_identifier("a")),
    ("db", @core.null_arg),
    ("catalog", @core.null_arg),
  ])
  let expr_tgt = @core.mk(@core.Kind::Column, [
    ("this", @core.to_identifier("b")),
    ("table", @core.to_identifier("a")),
  ])
  // set(expr.args): the explicit None args are keys (Expr::arg_keys)
  let keys = (e : @core.Expr) => {
    let ks = e.arg_keys()
    ks.sort_by((a, b) => py_cmp(a, b))
    ks
  }
  assert_eq(keys(expr_src), ["catalog", "db", "table", "this"])
  assert_eq(keys(expr_tgt), ["table", "this"])
  validate_delta_only(diff_delta_only(expr_src, expr_tgt), [])
}

///|
test "TestDiff.test_comments_do_not_affect_diff" {
  let expr_src = @core.parse_one("select a from tbl")
  let expr_tgt = @core.parse_one("select a from tbl -- this is comment")
  assert_eq(
    expr_tgt.arg("from_").unwrap().this_().comments,
    Some([" this is comment"]),
  )
  validate_delta_only(diff_delta_only(expr_src, expr_tgt), [])
}
