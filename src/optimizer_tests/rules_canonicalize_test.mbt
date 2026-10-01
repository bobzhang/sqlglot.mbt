// Fixture drivers for canonicalize.

///|
test "optimizer canonicalize_internal_names" {
  run_fixtures(
    "canonicalize_internal_names",
    canonicalize_internal_names_fixtures,
    pretty=false,
    (e, c) => {
      let e = @optimizer.qualify(
        e,
        schema=c.schema(canon_names_schema_json),
        catalog="c",
        db="db",
        dialect?=c.dialect,
        validate_qualify_columns=c.meta_bool("validate_qualify_columns").unwrap_or(
          true,
        ),
        canonicalize_table_aliases=c.meta_bool("canonicalize_table_aliases").unwrap_or(
          false,
        ),
      )
      @optimizer.canonicalize_internal_names(e)
    },
  )
}

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
