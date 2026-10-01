"""Generate MoonBit executor fixtures from the Python executor (sqlglot/executor).

    python tools/gen_executor_fixtures.py [--max-rows N]

Writes:

* src/executor_tests/fixture_executor_cases_test.mbt: every `execute(...)` call made by the
  self-contained tests of tests/test_executor.py (recorded by running them with a patched
  `execute`), with the Python executor's result (`repr` of the columns and rows) or error.
* src/executor_tests/fixture_tpcds_test.mbt: the TPC-DS queries of
  tests/fixtures/optimizer/tpc-ds/tpc-ds.sql marked `# execute: true` (as in
  test_execute_tpcds), executed by the Python executor over the TPC-DS sample data
  (tests/fixtures/optimizer/tpc-ds/*.csv.gz). Python's test compares these against DuckDB;
  DuckDB isn't available in MoonBit, so the Python executor's own results are recorded.
  To keep the fixture small, only the columns the queries reference are kept and each table
  is cut to its first `--max-rows` rows; the results are computed on that same data.

The TPC-H queries of tests/fixtures/optimizer/tpc-h/tpc-h.sql have no `# execute: true`
meta, so test_execute_tpch executes none of them and they are not recorded.

Results whose row order depends on Python's (randomized) string hashing are detected by
running the recording under two hash seeds; those are compared as multisets.
"""

import argparse
import ast
import csv
import gzip
import json
import os
import subprocess
import sys
import types
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
if not os.path.isdir(SG):
    SG = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(ROOT))), ".repos", "sqlglot")
sys.path.insert(0, SG)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import dateutil.relativedelta  # noqa: F401
except ImportError:
    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyshim"))
warnings.filterwarnings("ignore")

import logging  # noqa: E402

logging.getLogger("sqlglot").setLevel(logging.CRITICAL)

OUT = os.path.join(ROOT, "src", "executor_tests")


def stub_modules():
    """tests/test_executor.py imports numpy and pandas (only used by the DuckDB tests)."""
    if "numpy" not in sys.modules:
        try:
            import numpy  # noqa: F401
        except ImportError:
            np = types.ModuleType("numpy")
            np.bool_ = bool
            np.nan = float("nan")
            sys.modules["numpy"] = np
    try:
        import pandas  # noqa: F401
    except ImportError:
        pd = types.ModuleType("pandas")
        pd.DataFrame = object
        testing = types.ModuleType("pandas.testing")
        testing.assert_frame_equal = lambda *a, **k: None
        pd.testing = testing
        sys.modules["pandas"] = pd
        sys.modules["pandas.testing"] = testing
    try:
        import duckdb  # noqa: F401
    except ImportError:
        sys.modules["duckdb"] = types.ModuleType("duckdb")


SKIPPED_TESTS = {
    # DuckDB comparisons (TPC-H / TPC-DS are recorded separately)
    "test_optimized_tpch",
    "test_execute_tpch",
    "test_execute_tpcds",
}


def literal(value):
    """A Python literal of plain data (dicts, lists, tuples, scalars) or None."""
    if value is None or isinstance(value, (bool, int, float, str)):
        if type(value) not in (bool, int, float, str, type(None)):
            raise TypeError(type(value))
        return repr(value)
    if isinstance(value, dict):
        return "{" + ", ".join(f"{literal(k)}: {literal(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(literal(v) for v in value) + "]"
    if isinstance(value, tuple):
        if len(value) == 1:
            return "(" + literal(value[0]) + ",)"
        return "(" + ", ".join(literal(v) for v in value) + ")"
    raise TypeError(type(value))


def record_unit_cases():
    stub_modules()
    import tests.test_executor as te

    real_execute = te.execute
    cases = []

    def recording_execute(sql, schema=None, dialect=None, tables=None):
        try:
            result = real_execute(sql, schema=schema, dialect=dialect, tables=tables)
        except Exception as e:
            outcome = ("error", type(e).__name__, type(e.__cause__).__name__ if e.__cause__ else "")
            record(sql, schema, dialect, tables, outcome)
            raise
        record(sql, schema, dialect, tables, ("ok", repr(result.columns), repr(result.rows)))
        return result

    def record(sql, schema, dialect, tables, outcome):
        if not isinstance(sql, str):
            return
        try:
            tables_lit = literal(tables or {})
            schema_lit = literal(schema or {})
        except TypeError:
            return
        if dialect is not None and not isinstance(dialect, str):
            return
        cases.append((sql, schema_lit, tables_lit, dialect or "", outcome))

    te.execute = recording_execute
    names = sorted(n for n in dir(te.TestExecutor) if n.startswith("test_"))
    for name in names:
        if name in SKIPPED_TESTS:
            continue
        test = te.TestExecutor(name)
        try:
            getattr(test, name)()
        except Exception as e:  # a failing Python test still records its calls
            print(f"warning: {name} failed: {e!r}", file=sys.stderr)
    te.execute = real_execute
    return cases


def load_tpcds(max_rows):
    from sqlglot import exp, parse_one
    from sqlglot.optimizer import optimize
    from sqlglot.optimizer.scope import traverse_scope
    from tests.helpers import FIXTURES_DIR, TPCDS_SCHEMA, load_sql_fixture_pairs

    queries = []
    used = {}
    for i, (meta, sql, _) in enumerate(load_sql_fixture_pairs("optimizer/tpc-ds/tpc-ds.sql")):
        if not meta.get("execute"):
            continue
        queries.append((i + 1, sql))
        optimized = optimize(parse_one(sql), TPCDS_SCHEMA, leave_tables_isolated=True)
        for scope in traverse_scope(optimized):
            for name, source in scope.sources.items():
                if isinstance(source, exp.Table):
                    used.setdefault(source.name, set())
            for column in scope.columns:
                source = scope.sources.get(column.table)
                if isinstance(source, exp.Table):
                    used.setdefault(source.name, set()).add(column.name)

    data = {}
    for table, columns in TPCDS_SCHEMA.items():
        if table not in used:
            continue
        file_name = f"{FIXTURES_DIR}/optimizer/tpc-ds/{table}.csv.gz"
        reader = csv.reader(gzip.open(file_name, "rt", newline=""), delimiter="|")
        next(reader)
        all_columns = list(columns)
        keep = [i for i, c in enumerate(all_columns) if c in used[table]]
        rows, ctypes = [], []
        for row in reader:
            # as in TestExecutor.setUpClass: the types are inferred from the first row
            if not ctypes:
                for v in row:
                    try:
                        ctypes.append(type(ast.literal_eval(v)))
                    except (ValueError, SyntaxError):
                        ctypes.append(str)
            if len(rows) < max_rows:
                rows.append([row[i] for i in keep])
        data[table] = ([all_columns[i] for i in keep], [ctypes[i] for i in keep], rows)
    return queries, data


def typed_rows(ctypes, rows):
    return [
        tuple(None if (t is not str and v == "") else t(v) for t, v in zip(ctypes, row))
        for row in rows
    ]


def run_tpcds(queries, data):
    from sqlglot import find_tables, parse_one
    from sqlglot.executor import execute
    from sqlglot.executor.table import Table
    from tests.helpers import TPCDS_SCHEMA

    tables = {
        name: Table(columns=columns, rows=typed_rows(ctypes, rows))
        for name, (columns, ctypes, rows) in data.items()
    }
    results = []
    for number, sql in queries:
        expression = parse_one(sql)
        try:
            result = execute(
                expression,
                schema=TPCDS_SCHEMA,
                tables={t.name: tables[t.name] for t in find_tables(expression)},
            )
            outcome = ("ok", repr(result.columns), repr(result.rows))
        except Exception as e:
            outcome = ("error", type(e).__name__, type(e.__cause__).__name__ if e.__cause__ else "")
        results.append((number, sql, outcome))
    return results


def child(mode, max_rows):
    """Records the cases in this process and prints them as JSON."""
    if mode == "unit":
        print(json.dumps(record_unit_cases()))
    else:
        queries, data = load_tpcds(max_rows)
        print(json.dumps({"results": run_tpcds(queries, data)}))


def run_child(mode, max_rows, seed):
    env = dict(os.environ, PYTHONHASHSEED=str(seed))
    out = subprocess.run(
        [sys.executable, __file__, "--child", mode, "--max-rows", str(max_rows)],
        env=env,
        check=True,
        capture_output=True,
        text=True,
        cwd=SG,
    )
    return json.loads(out.stdout)


def unordered(a, b):
    """Whether two outcomes differ only by row order (then compare as multisets)."""
    return a != b and a[0] == b[0] == "ok" and a[1] == b[1]


def mbt_str(s):
    from gen_meta import mbt_str as f

    return f(s)


def escape_field(v):
    return v.replace("\\", "\\\\").replace("|", "\\|").replace("\n", "\\n").replace("\r", "\\r")


def write_unit(cases_a, cases_b):
    path = os.path.join(OUT, "fixture_executor_cases_test.mbt")
    with open(path, "w") as f:
        f.write("// Code generated by tools/gen_executor_fixtures.py. DO NOT EDIT.\n\n")
        f.write("///|\n/// (sql, schema, tables, dialect, kind, columns-or-error, rows-or-cause, ordered)\n")
        f.write("let executor_cases : Array[(String, String, String, String, String, String, String, Bool)] = [\n")
        for a, b in zip(cases_a, cases_b):
            sql, schema, tables, dialect, outcome = a
            ordered = not unordered(outcome, b[4])
            kind, x, y = outcome
            f.write(
                f"  ({mbt_str(sql)}, {mbt_str(schema)}, {mbt_str(tables)}, {mbt_str(dialect)}, "
                f"{mbt_str(kind)}, {mbt_str(x)}, {mbt_str(y)}, {'true' if ordered else 'false'}),\n"
            )
        f.write("]\n")
    return path


def write_tpcds(data, results_a, results_b, max_rows):
    path = os.path.join(OUT, "fixture_tpcds_test.mbt")
    type_codes = {int: "i", float: "f", str: "s", bool: "b"}
    with open(path, "w") as f:
        f.write("// Code generated by tools/gen_executor_fixtures.py. DO NOT EDIT.\n")
        f.write(f"// TPC-DS sample data: referenced columns, first {max_rows} rows per table.\n\n")
        f.write("///|\n/// (table, columns, column type codes, rows: one per line, fields separated by `|`)\n")
        f.write("let tpcds_tables : Array[(String, Array[String], String, String)] = [\n")
        for name, (columns, ctypes, rows) in sorted(data.items()):
            codes = "".join(type_codes[t] for t in ctypes)
            f.write(f"  (\n    {mbt_str(name)},\n    [{', '.join(mbt_str(c) for c in columns)}],\n")
            f.write(f"    {mbt_str(codes)},\n")
            if rows:
                f.write("    (\n")
                for row in rows:
                    f.write("      #|" + "|".join(escape_field(v) for v in row) + "\n")
                f.write("    ),\n  ),\n")
            else:
                f.write('    "",\n  ),\n')
        f.write("]\n\n")
        from tests.helpers import TPCDS_SCHEMA

        f.write(f"///|\nlet tpcds_schema_json : String = {mbt_str(json.dumps(TPCDS_SCHEMA))}\n\n")
        f.write("///|\n/// (query number, sql, kind, columns-or-error, rows-or-cause, ordered)\n")
        f.write("let tpcds_cases : Array[(Int, String, String, String, String, Bool)] = [\n")
        for a, b in zip(results_a, results_b):
            number, sql, outcome = a
            ordered = not unordered(tuple(outcome), tuple(b[2]))
            kind, x, y = outcome
            f.write(
                f"  ({number}, {mbt_str(sql)}, {mbt_str(kind)}, {mbt_str(x)}, {mbt_str(y)}, "
                f"{'true' if ordered else 'false'}),\n"
            )
        f.write("]\n")
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--child")
    parser.add_argument("--max-rows", type=int, default=1000)
    args = parser.parse_args()
    if args.child:
        os.chdir(SG)
        child(args.child, args.max_rows)
        return

    unit_a = run_child("unit", args.max_rows, 1)
    unit_b = run_child("unit", args.max_rows, 2)
    assert len(unit_a) == len(unit_b)
    print(write_unit(unit_a, unit_b), len(unit_a), "cases")

    os.chdir(SG)
    queries, data = load_tpcds(args.max_rows)
    tpcds_a = run_child("tpcds", args.max_rows, 1)["results"]
    tpcds_b = run_child("tpcds", args.max_rows, 2)["results"]
    print(write_tpcds(data, tpcds_a, tpcds_b, args.max_rows), len(tpcds_a), "queries")
    nonempty = sum(1 for _, _, o in tpcds_a if o[0] == "ok" and o[2] != "[]")
    errors = sum(1 for _, _, o in tpcds_a if o[0] == "error")
    print(f"  non-empty results: {nonempty}, errors: {errors}")


if __name__ == "__main__":
    main()
