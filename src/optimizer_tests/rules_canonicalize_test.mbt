// Fixture drivers for canonicalize.

///|
test "optimizer canonicalize" {
  run_fixtures("canonicalize", canonicalize_fixtures, pretty=false, (e, c) => {
    let schema = c.schema(test_schema_json)
    let e = @optimizer.qualify(
      e.copy(),
      schema~,
      dialect?=c.dialect,
      isolate_tables=true,
      quote_identifiers=false,
    )
    let e = @optimizer.quote_identifiers(e, dialect?=c.dialect)
    let e = @optimizer.annotate_types(e, schema~, dialect?=c.dialect)
    @optimizer.canonicalize(e, dialect?=c.dialect)
  })
}
