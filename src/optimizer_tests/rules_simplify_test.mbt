// Fixture drivers for simplify and normalize.

///|
test "optimizer simplify" {
  run_fixtures("simplify", simplify_fixtures, pretty=false, (e, c) => {
    let schema = c.schema(test_schema_json)
    let e = @optimizer.annotate_types(e, schema~, dialect?=c.dialect)
    @optimizer.simplify(
      e,
      constant_propagation=true,
      coalesce_simplification=true,
      dialect?=c.dialect,
    )
  })
}

///|
test "optimizer normalize" {
  run_fixtures("normalize", normalize_fixtures, pretty=false, (e, c) => {
    let schema = c.schema(test_schema_json)
    let e = @optimizer.normalize(e, dnf=false)
    let e = @optimizer.annotate_types(e, schema~)
    @optimizer.simplify(e)
  })
}
