///|
test "get_or_raise settings" {
  let d = @sqlglot.dialect("postgres, normalization_strategy = uppercase")
  debug_inspect(d.normalization_strategy, content="Uppercase")
  // a fresh instance is returned every time
  debug_inspect(@sqlglot.dialect("postgres").normalization_strategy, content="Lowercase")
  inspect(@sqlglot.dialect("duckdb, version=1.2").version, content="(1, 2, 0)")
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
