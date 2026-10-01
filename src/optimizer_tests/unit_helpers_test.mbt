// Shared helpers for the ports of the non-fixture unit tests of tests/test_optimizer.py.

///|
fn dialect_of(name : String?) -> @core.Dialect? raise @core.SqlglotError {
  match name {
    Some("") | None => None
    Some(n) => Some(@core.Dialect::get_or_raise(n))
  }
}

///|
/// `parse_one(sql, read=read)`.
fn parse_sql(sql : String, read? : String) -> @core.Expr raise @core.SqlglotError {
  @core.parse_one(sql, dialect?=dialect_of(read))
}

///|
/// `expression.sql(dialect=dialect, pretty=pretty)`.
fn gen_sql(
  e : @core.Expr,
  dialect? : String,
  pretty? : Bool = false,
) -> String raise @core.SqlglotError {
  @optimizer.sql_of(e, dialect?=dialect_of(dialect), pretty~)
}

///|
/// `MappingSchema(json.loads(json), dialect=dialect)`.
fn mapping_schema(
  json : String,
  dialect? : String,
) -> @optimizer.MappingSchema raise @core.SqlglotError {
  @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(json),
    dialect?=dialect_of(dialect),
  )
}

///|
/// `qualify(parse_one(sql, read=dialect), schema=schema, dialect=dialect, ...)`, as SQL.
fn qualify_sql(
  sql : String,
  dialect? : String,
  schema? : String,
  db? : String,
  catalog? : String,
  quote_identifiers? : Bool,
  identify? : Bool,
  expand_alias_refs? : Bool,
  expand_stars? : Bool,
  infer_schema? : Bool,
  validate_qualify_columns? : Bool,
  allow_partial_qualification? : Bool,
  out_dialect? : String,
) -> String raise @core.SqlglotError {
  let e = qualify_expr(
    sql,
    dialect?,
    schema?,
    db?,
    catalog?,
    quote_identifiers?,
    identify?,
    expand_alias_refs?,
    expand_stars?,
    infer_schema?,
    validate_qualify_columns?,
    allow_partial_qualification?,
  )
  let out = match out_dialect {
    Some(d) => Some(d)
    None => dialect
  }
  gen_sql(e, dialect?=out)
}

///|
fn qualify_expr(
  sql : String,
  dialect? : String,
  schema? : String,
  db? : String,
  catalog? : String,
  quote_identifiers? : Bool,
  identify? : Bool,
  expand_alias_refs? : Bool,
  expand_stars? : Bool,
  infer_schema? : Bool,
  validate_qualify_columns? : Bool,
  allow_partial_qualification? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let schema = match schema {
    Some(s) => Some(mapping_schema(s, dialect?))
    None => None
  }
  @optimizer.qualify(
    parse_sql(sql, read?=dialect),
    dialect?=dialect_of(dialect),
    schema?,
    db?,
    catalog?,
    quote_identifiers?,
    identify?,
    expand_alias_refs?,
    expand_stars?,
    infer_schema?,
    validate_qualify_columns?,
    allow_partial_qualification?,
  )
}

///|
/// Asserts that `f` raises an error whose message contains `expected`.
fn assert_raises_with(
  f : () -> Unit raise @core.SqlglotError,
  expected : String,
) -> Unit raise {
  try f() catch {
    err => {
      let msg = err.message()
      if !msg.contains(expected) {
        fail("expected error containing '\{expected}', got '\{msg}'")
      }
    }
  } noraise {
    _ => fail("expected an error containing '\{expected}'")
  }
}
