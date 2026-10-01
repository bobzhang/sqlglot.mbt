# sqlglot command line

A native executable mirroring Python's `python -m sqlglot` (`sqlglot/__main__.py`).
The argument handling and execution live in the target-independent package
`hongbozhang/sqlglot/cli` (tested on every backend); this package only connects it
to `argv`, stdin, stdout/stderr and the exit code through libc, so it builds for the
native backend only.

## Build and run

```sh
moon build --target native --release src/cmd/sqlglot
./_build/native/release/build/cmd/sqlglot/sqlglot.exe "SELECT IFNULL(a, b) FROM t" --read mysql --write duckdb

# or, without a separate build step
moon run --target native src/cmd/sqlglot -- "SELECT 1" --no-pretty
```

## Usage

```
usage: sqlglot [-h] [--read READ] [--write WRITE] [--identify IDENTIFY] [--no-pretty]
               [--parse] [--tokenize] [--error-level ERROR_LEVEL] [--version] sql

positional arguments:
  sql                   SQL statement(s) to transpile, or - to parse stdin.

options:
  -h, --help            show this help message and exit
  --read READ           Dialect to read default is generic
  --write WRITE         Dialect to write default is generic
  --identify IDENTIFY   Whether to quote identifiers (safe, true, false)
  --no-pretty           Compress sql
  --parse               Parse and return the expression tree
  --tokenize            Tokenize and return the tokens list
  --error-level ERROR_LEVEL
                        IGNORE, WARN, RAISE, IMMEDIATE (default)
  --version             Display the SQLGlot version
```

As in Python, output is pretty-printed by default and identifiers are quoted in
`safe` mode; every statement (or expression tree / token) is printed on its own.

```sh
$ echo "SELECT CAST(x AS TEXT) FROM y" | sqlglot.exe - --no-pretty --write spark
SELECT CAST(`x` AS STRING) FROM `y`

$ sqlglot.exe "SELECT a FROM t" --parse
Select(
  expressions=[
    Column(
      this=Identifier(this=a, quoted=False))],
  from_=From(
    this=Table(
      this=Identifier(this=t, quoted=False))))
```

Behaviour follows argparse: `--opt value` and `--opt=value` forms, unambiguous
prefixes of long options (`--pars`), usage errors on stderr with exit code 2.
SQL errors print `sqlglot.errors.<Error>: <message>` on stderr and exit with code 1
(Python prints a traceback ending in the same line). `--version` prints the version
of this port.
