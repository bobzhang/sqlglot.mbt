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
| Tokenizer, parser, generator (base dialect) | Complete. Identical ASTs and SQL to Python on all base fixtures (5,501 ASTs and 5,962 round trips) |
| Dialects (34) | Complete. 15,752 of 15,775 cases extracted from `tests/dialects` match Python; the rest need the optimizer |
| Expression API, builders, transforms | Ported; unit-test port in progress |
| Optimizer, schema, lineage | In progress |
| Executor, planner, diff, serde | Not yet ported |

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

## Development

```
moon check
moon test -p hongbozhang/sqlglot/tests            # base parser/generator conformance
moon test -p hongbozhang/sqlglot/generator_tests  # generator conformance
moon test -p hongbozhang/sqlglot/dialect_tests    # per-dialect conformance (prints DIALECT <module>: ...)
moon test -p hongbozhang/sqlglot/dialect_tests -F "*dialect snowflake*"
```

Regenerate fixtures and configuration with the scripts in `tools/`. Each script's docstring
describes its inputs. They need a Python environment with sqlglot's test dependencies, such as
`pytz` for the BigQuery tests.
