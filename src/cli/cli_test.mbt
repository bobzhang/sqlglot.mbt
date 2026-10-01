// Tests of the `python -m sqlglot` command line port. Expected outputs were
// produced by running sqlglot/__main__.py.

///|
fn run(argv : Array[String], stdin? : String = "") -> @cli.CliResult {
  @cli.run(argv, () => stdin)
}

///|
fn stdout_of(argv : Array[String], stdin? : String = "") -> String raise {
  let r = run(argv, stdin~)
  assert_eq(r.stderr, "")
  assert_eq(r.exit_code, 0)
  r.stdout
}

///|
test "transpile" {
  assert_eq(stdout_of(["SELECT 1"]), "SELECT\n  1\n")
  assert_eq(
    stdout_of(["select a, b from t where x = 1", "--no-pretty"]),
    "SELECT \"a\", \"b\" FROM \"t\" WHERE \"x\" = 1\n",
  )
  assert_eq(
    stdout_of(["select a, b from t where x = 1"]),
    "SELECT\n  \"a\",\n  \"b\"\nFROM \"t\"\nWHERE\n  \"x\" = 1\n",
  )
  assert_eq(
    stdout_of([
      "SELECT IFNULL(a, b) FROM t", "--read", "mysql", "--write", "duckdb", "--no-pretty",
    ]),
    "SELECT COALESCE(\"a\", \"b\") FROM \"t\"\n",
  )
  assert_eq(
    stdout_of(["SELECT `a` FROM t", "--read=mysql", "--write=postgres"]),
    "SELECT\n  \"a\"\nFROM \"t\"\n",
  )
  assert_eq(
    stdout_of(["SELECT a FROM t", "--identify", "true", "--no-pretty"]),
    "SELECT \"a\" FROM \"t\"\n",
  )
  assert_eq(
    stdout_of(["SELECT A FROM t", "--identify", "false", "--no-pretty"]),
    "SELECT A FROM t\n",
  )
  assert_eq(
    stdout_of(["SELECT 1; SELECT 2", "--no-pretty"]),
    "SELECT 1\nSELECT 2\n",
  )
}

///|
test "stdin" {
  assert_eq(
    stdout_of(
      ["-", "--no-pretty", "--write", "spark"],
      stdin="SELECT CAST(x AS TEXT) FROM y",
    ),
    "SELECT CAST(`x` AS STRING) FROM `y`\n",
  )
}

///|
test "parse and tokenize" {
  let parsed =
    #|Select(
    #|  expressions=[
    #|    Column(
    #|      this=Identifier(this=a, quoted=False))],
    #|  from_=From(
    #|    this=Table(
    #|      this=Identifier(this=t, quoted=False))))
    #|
  assert_eq(stdout_of(["SELECT a FROM t", "--parse"]), parsed)
  let tokens =
    #|<Token token_type: TokenType.SELECT, text: SELECT, line: 1, col: 6, start: 0, end: 5, comments: []>
    #|<Token token_type: TokenType.NUMBER, text: 1, line: 1, col: 8, start: 7, end: 7, comments: [' c ']>
    #|
  assert_eq(stdout_of(["SELECT 1 /* c */", "--tokenize"]), tokens)
  // argparse accepts unambiguous prefixes of long options
  assert_eq(
    stdout_of(["SELECT 1", "--pars"]),
    "Select(\n  expressions=[\n    Literal(this=1, is_string=False)])\n",
  )
}

///|
test "error levels" {
  assert_eq(
    stdout_of(["SELECT 1 +", "--error-level", "ignore", "--no-pretty"]),
    "SELECT 1 +\n",
  )
  let r = run(["SELECT 1 +"])
  assert_eq(r.exit_code, 1)
  assert_eq(r.stdout, "")
  assert_true(
    r.stderr.has_prefix(
      "sqlglot.errors.ParseError: Required keyword: 'expression' missing for <class 'sqlglot.expressions.core.Add'>. Line 1, Col: 10.",
    ),
  )
  let r = run(["SELECT 1", "--error-level", "foo"])
  assert_eq(r.exit_code, 1)
  assert_eq(r.stderr, "KeyError: 'FOO'\n")
}

///|
test "argument errors" {
  let r = run([])
  assert_eq(r.exit_code, 2)
  assert_true(
    r.stderr.has_suffix(
      "sqlglot: error: the following arguments are required: sql\n",
    ),
  )
  let r = run(["SELECT 1", "--bogus"])
  assert_eq(r.exit_code, 2)
  assert_true(
    r.stderr.has_suffix("sqlglot: error: unrecognized arguments: --bogus\n"),
  )
  let r = run(["SELECT 1", "--read"])
  assert_eq(r.exit_code, 2)
  assert_true(
    r.stderr.has_suffix(
      "sqlglot: error: argument --read: expected one argument\n",
    ),
  )
}

///|
test "help and version" {
  let r = run(["--version"])
  assert_eq(r, { stdout: "\{@cli.version}\n", stderr: "", exit_code: 0, })
  let r = run(["-h"])
  assert_eq(r.exit_code, 0)
  assert_true(r.stdout.has_prefix("usage: sqlglot [-h]"))
}
