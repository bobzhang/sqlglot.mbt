///|
test "get_or_raise settings" {
  let d = @sqlglot.dialect("postgres, normalization_strategy = uppercase")
  debug_inspect(d.normalization_strategy, content="Uppercase")
  // a fresh instance is returned every time
  debug_inspect(@sqlglot.dialect("postgres").normalization_strategy, content="Lowercase")
  debug_inspect(@sqlglot.dialect("duckdb, version=1.2").version, content="(1, 2, 0)")
  let err = try @sqlglot.dialect("duckdb, foo = bar") catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  inspect(err, content=(
    #|ValueError: Unknown setting 'foo'.
  ))
  let err = try @sqlglot.dialect("mysqll") catch {
    e => e.to_string()
  } noraise {
    _ => "no error"
  }
  inspect(err, content=(
    #|ValueError: Unknown dialect 'mysqll'. Did you mean mysql?
  ))
}

///|
test "presto supported settings" {
  let d = @sqlglot.dialect("presto, variant_extract_is_json_extract=false")
  debug_inspect(d.settings.get("variant_extract_is_json_extract"), content=(
    #|Some("false")
  ))
  inspect(
    @sqlglot.transpile("SELECT x:a FROM t", read="snowflake", write="presto, variant_extract_is_json_extract=false")[0],
    content=(
      #|SELECT x.a FROM t
    ),
  )
}
