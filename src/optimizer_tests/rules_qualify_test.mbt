// Fixture drivers for the qualify-family rules.

///|
fn run_qualify_columns(
  e : @core.Expr,
  c : Case,
  default_schema : String,
) -> @core.Expr raise {
  @optimizer.qualify(
    e,
    infer_schema=true,
    validate_qualify_columns=c.meta_bool("validate_qualify_columns").unwrap_or(
      true,
    ),
    identify=false,
    schema=c.schema(default_schema),
    dialect?=c.dialect,
    canonicalize_table_aliases=c.meta_bool("canonicalize_table_aliases").unwrap_or(
      false,
    ),
  )
}

///|
test "optimizer qualify_columns" {
  run_fixtures("qualify_columns", qualify_columns_fixtures, pretty=false, (
    e,
    c,
  ) => run_qualify_columns(e, c, test_schema_json))
  run_fixtures("qualify_columns_ddl", qualify_columns_ddl_fixtures, pretty=false, (
    e,
    c,
  ) => run_qualify_columns(e, c, test_schema_json))
}

///|
test "optimizer qualify_columns__with_invisible" {
  run_fixtures(
    "qualify_columns__with_invisible",
    qualify_columns__with_invisible_fixtures,
    pretty=false,
    (e, c) => {
      let visible : Map[String, @optimizer.SchemaNode] = {}
      match @json.parse(invisible_json) {
        Object(m) =>
          for k, v in m {
            visible[k] = @optimizer.SchemaNode::from_json(v)
          }
        _ => ()
      }
      let schema = @optimizer.MappingSchema::new(
        schema=@optimizer.schema_from_json_string(test_schema_json),
        visible~,
        dialect?=c.dialect,
      )
      @optimizer.qualify(
        e,
        infer_schema=true,
        validate_qualify_columns=true,
        identify=false,
        schema~,
        dialect?=c.dialect,
      )
    },
  )
}

///|
test "optimizer qualify_columns__invalid" {
  run_fixtures(
    "qualify_columns__invalid",
    qualify_columns__invalid_fixtures,
    pretty=false,
    (e, c) => {
      let schema = c.schema(test_schema_json)
      let e = @optimizer.qualify_columns(e, schema)
      @optimizer.validate_qualify_columns(e)
    },
    output=(_, _) => "OK",
    check_parents=false,
  )
}

///|
test "optimizer normalize_identifiers" {
  run_fixtures(
    "normalize_identifiers",
    normalize_identifiers_fixtures,
    pretty=false,
    (e, c) => @optimizer.normalize_identifiers(e, dialect?=c.dialect),
  )
}

///|
test "optimizer quote_identifiers" {
  run_fixtures("quote_identifiers", quote_identifiers_fixtures, pretty=false, (
    e,
    c,
  ) => @optimizer.quote_identifiers(e, dialect?=c.dialect))
}

///|
test "optimizer pushdown_cte_alias_columns" {
  run_fixtures(
    "pushdown_cte_alias_columns",
    pushdown_cte_alias_columns_fixtures,
    pretty=false,
    (e, _) => {
      match @optimizer.build_scope(e) {
        Some(s) => @optimizer.pushdown_cte_alias_columns(s)
        None => ()
      }
      e
    },
  )
}

///|
test "optimizer isolate_table_selects" {
  run_fixtures(
    "isolate_table_selects",
    isolate_table_selects_fixtures,
    pretty=false,
    (e, c) => @optimizer.isolate_table_selects(
      e,
      schema=c.schema(test_schema_json),
      dialect?=c.dialect,
    ),
  )
}
