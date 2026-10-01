// Extra helpers of dialect_unit_tests_a (prefixed `a_` to avoid clashes).

///|
/// A `MappingSchema` from a JSON mapping (Python dict) in `dialect`.
fn a_schema(
  json : String,
  dialect? : String = "",
) -> @optimizer.MappingSchema raise {
  @optimizer.MappingSchema::new(
    schema=@optimizer.schema_from_json_string(json),
    dialect=@sqlglot.dialect(dialect),
  )
}

///|
/// `qualify(expression, dialect=dialect, schema=<json mapping>)`.
fn a_qualify(
  e : @core.Expr,
  dialect? : String = "",
  schema? : String,
) -> @core.Expr raise {
  let schema = match schema {
    Some(json) => Some(a_schema(json, dialect~))
    None => None
  }
  @optimizer.qualify(e, dialect=@sqlglot.dialect(dialect), schema?)
}

///|
/// `annotate_types(expression, schema=<json mapping>, dialect=dialect)`.
fn a_annotate(
  e : @core.Expr,
  dialect? : String = "",
  schema? : String,
) -> @core.Expr raise {
  let schema = match schema {
    Some(json) => Some(a_schema(json, dialect~))
    None => None
  }
  @optimizer.annotate_types(e, dialect=@sqlglot.dialect(dialect), schema?)
}

///|
/// `Validator.assert_duckdb_sql(expression, includes=..., excludes=..., chr_chars=...)`.
#callsite(autofill(loc))
fn T::a_assert_duckdb_sql(
  self : T,
  expression : @core.Expr,
  includes? : Array[String] = [],
  excludes? : Array[String] = [],
  chr_chars? : Array[Char] = [],
  loc~ : SourceLoc,
) -> String raise {
  // duckdb's WS_CONTROL_CHARS_TO_DUCK
  let codes : Map[Char, Int] = {
    '\u{0b}': 11,
    '\u{1c}': 28,
    '\u{1d}': 29,
    '\u{1e}': 30,
    '\u{1f}': 31,
  }
  let duckdb_sql = sql(expression, dialect="duckdb")
  for fragment in includes {
    self.contains(duckdb_sql, fragment, loc~)
  }
  for fragment in excludes {
    self.not_contains(duckdb_sql, fragment, loc~)
  }
  for char in chr_chars {
    match codes.get(char) {
      Some(code) => self.contains(duckdb_sql, "CHR(\{code})", loc~)
      None => self.fail("missing DuckDB code for \{char}", loc)
    }
  }
  duckdb_sql
}
