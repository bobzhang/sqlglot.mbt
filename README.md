# sqlglot.mbt

A MoonBit port of [sqlglot](https://github.com/tobymao/sqlglot), the SQL parser,
transpiler and optimizer. The port aims to match the Python library's behaviour exactly.
Its test suites are generated from the Python implementation and test-suite.

```moonbit
let sql = @sqlglot.transpile(
  "SELECT EPOCH_MS(1618088028295)",
  read="duckdb",
  write="hive",
)[0]
// SELECT FROM_UNIXTIME(1618088028295 / POW(10, 3))

let ast = @sqlglot.parse_one("SELECT a FROM t WHERE b > 1", read="postgres")
let out = @sqlglot.generate(ast, dialect="snowflake", pretty=true)
```

## Status

| Component | Status |
|---|---|
| Tokenizer, parser, generator (base dialect) | Complete: identical ASTs and SQL to Python on all base fixtures (5,501 ASTs, 5,962 round trips) |
| Dialects (34) | Complete: all 15,775 cases extracted from `tests/dialects` match Python |
| Optimizer (qualify, annotate_types, simplify, all rules), schema | Complete: all optimizer fixtures, TPC-H and TPC-DS match Python |
| Lineage, diff, planner | Complete: lineage 80/80, diff 24/24, planner 27/27 recorded Python results |
| Expression API, builders, transforms | Complete: unit tests ported from test_expressions, test_build, test_transforms, test_parser, test_transpile, test_errors, test_tokens, test_jsonpath and others |
| Executor | Complete: generates Python code like sqlglot and evaluates it with a built-in interpreter; test_executor (445 recorded cases) and 57 TPC-DS queries match Python |
| Serde, anonymize, CLI | Complete (`src/core/serde.mbt`, `src/anonymize`, `src/cli`, native binary in `src/cmd/sqlglot`) |

Known differences from Python: integers are 64-bit (Python's are unbounded), and the things that need
Python runtime features, such as defining new expression classes at runtime, aren't supported.

## Layout

- `src/core`: the AST (`Expr`, with a generated `Kind` enum for every Python expression class),
  tokenizer, parser, generator, transforms, builders, and the dialect infrastructure and shared
  dialect helpers (the module-level functions in `dialects/dialect.py`).
- `src/dialects/<name>`: one package per dialect.
  - `gen_config.mbt` (generated) holds the dialect's data class attributes, stored as diffs from
    the parent dialect.
  - `tokenizer.mbt`, `parser.mbt` and `generator.mbt` hold the hand-ported callables and
    method overrides.
  - `dialect.mbt` (generated) derives the dialect from its parent and registers it.
- `src/optimizer`: schema, scope, the optimizer rules, `optimize`, and per-dialect type annotators
  (`sqlglot/typing`). It installs the real `annotate_types` and `simplify` into core's hooks.
- `src/lineage`, `src/diff`, `src/planner`, `src/executor`, `src/anonymize`: ports of the
  corresponding Python modules. `src/cli` and `src/cmd/sqlglot` provide the command-line tool.
- `src/` (package `hongbozhang/sqlglot`): the facade (`transpile`, `parse_one`, `parse`,
  `generate`, `dialect`). It imports and registers all dialects.
- `src/tests`, `src/generator_tests`, `src/dialect_tests`: conformance suites generated
  from Python.
- `tools/`: generators for metadata, configuration and fixtures. They run against the Python
  checkout in `.repos/sqlglot`.

### How Python features map to MoonBit

- **Expression subclasses** become a single dynamic `Expr { kind, args }`.
  - Python `isinstance(e, exp.Foo)` becomes `e.kind.is_a(Foo)`, which follows the generated MRO
    tables.
  - Python `type(e) is exp.Foo` becomes `e.kind == Foo`.
- **Dialect subclassing:** `Dialect::subclass(parent, name, configure)` copies the parent's
  configuration and its function tables (FUNCTIONS, *_PARSERS, TRANSFORMS, method overrides), then
  applies the child's changes.
- **Overridden methods** go through typed hook tables, `ParserHooks` and `GeneratorHooks`.
- **`super()`:** a child dialect captures its parent's implementation when it is configured.
  See `docs/review-02-dialects.md`.
- **Unicode:** `str.upper/lower/casefold` (full mappings, `ß` -> `SS`, Final_Sigma) and the
  `str.is*` / `re` (`\w`, `\d`, `\s`, `re.IGNORECASE`) character classes use tables generated
  from Python's Unicode database (`tools/gen_unicode_tables.py` -> `src/core/gen_unicode.mbt`,
  helpers in `src/core/unicode.mbt`). Strings are indexed by code point, as in Python.
- **Integers:** SQL number literals stay text, and constant folding uses big integers (as do
  `relativedelta` date shifts), so they behave like Python at any size. Integers that are
  *stored* as host values are Int64: AST arguments (`Value::Int`, e.g. JSON path subscripts and
  serde payloads), `PyInt` (`Expr.to_py()`) and the executor's ints. Where Python would hold an
  integer outside Int64 there, the port raises an error whose message mentions "Int64 range"
  (`@core.int64_range_error`; an `OverflowError` in the executor) instead of wrapping.
  `src/robust_tests` checks both against Python (`tools/gen_unicode_fixtures.py`,
  `tools/gen_numeric_fixtures.py`).

## Development

```
moon check
moon test -p hongbozhang/sqlglot/tests            # base parser/generator conformance
moon test -p hongbozhang/sqlglot/generator_tests  # generator conformance
moon test -p hongbozhang/sqlglot/dialect_tests    # per-dialect conformance (prints DIALECT <module>: ...)
moon test -p hongbozhang/sqlglot/dialect_tests -F "*dialect snowflake*"
moon test                                         # everything (537 tests)
```

Regenerate fixtures and configuration with the scripts in `tools/`. Each script's docstring
describes its inputs. They need a Python environment with sqlglot's test dependencies, such as
`pytz` for the BigQuery tests.
