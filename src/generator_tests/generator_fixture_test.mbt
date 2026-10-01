///|
/// Runs the generator on ASTs dumped from Python and compares with Python's output.
fn run_generator_fixtures(mode : String, verbose : Bool) -> (Int, Int) {
  let d = @core.base_dialect()
  let mut total = 0
  let mut failed = 0
  let mut i = 0
  while i + 4 < generator_fixtures.length() {
    let ast = generator_fixtures[i + 1]
    let expected = match mode {
      "pretty" => generator_fixtures[i + 3]
      "identify" => generator_fixtures[i + 4]
      _ => generator_fixtures[i + 2]
    }
    let e = parse_canonical(ast)
    let g = match mode {
      "pretty" => @core.Generator::new(d, pretty=true)
      "identify" => @core.Generator::new(d, identify="always")
      _ => @core.Generator::new(d)
    }
    total += 1
    let got = g.generate(e) catch { err => "<error: \{err}>" }
    if got != expected {
      failed += 1
      if verbose {
        println("--- [\{mode}] \{generator_fixtures[i]}")
        println("  expected: \{expected}")
        println("  got:      \{got}")
      }
    }
    i += 5
  }
  (total, failed)
}

///|
test "generator fixtures: default" {
  let (total, failed) = run_generator_fixtures("default", true)
  println("default: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator fixtures: pretty" {
  let (total, failed) = run_generator_fixtures("pretty", true)
  println("pretty: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator fixtures: identify" {
  let (total, failed) = run_generator_fixtures("identify", true)
  println("identify: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
fn run_dialect_fixtures(mode : String, verbose : Bool) -> (Int, Int) {
  let d = @core.base_dialect()
  let mut total = 0
  let mut failed = 0
  let mut i = 0
  while i + 4 < generator_dialect_fixtures.length() {
    let ast = generator_dialect_fixtures[i + 1]
    let expected = match mode {
      "pretty" => generator_dialect_fixtures[i + 3]
      "identify" => generator_dialect_fixtures[i + 4]
      _ => generator_dialect_fixtures[i + 2]
    }
    let e = parse_canonical(ast)
    let g = match mode {
      "pretty" => @core.Generator::new(d, pretty=true)
      "identify" => @core.Generator::new(d, identify="always")
      _ => @core.Generator::new(d)
    }
    total += 1
    let got = g.generate(e) catch { err => "<error: \{err}>" }
    if got != expected {
      failed += 1
      if verbose {
        println("--- [\{mode}] \{generator_dialect_fixtures[i]}")
        println("  expected: \{expected}")
        println("  got:      \{got}")
      }
    }
    i += 5
  }
  (total, failed)
}

///|
test "generator dialect fixtures: default" {
  let (total, failed) = run_dialect_fixtures("default", true)
  println("dialect default: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator dialect fixtures: pretty" {
  let (total, failed) = run_dialect_fixtures("pretty", true)
  println("dialect pretty: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator dialect fixtures: identify" {
  let (total, failed) = run_dialect_fixtures("identify", true)
  println("dialect identify: \{total - failed}/\{total}")
  inspect(failed, content="0")
}
