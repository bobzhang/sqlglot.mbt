"""Generate differential numeric-boundary fixtures from Python into src/robust_tests.

    python tools/gen_numeric_fixtures.py

Writes src/robust_tests/fixture_numeric_test.mbt with:

* `num_sql`: huge / boundary literals (around +-2^63, 2^64, 10^30, float limits, hex, `_`
  separators) in many syntactic positions (projections, negation, casts, LIMIT, array
  subscripts, JSON paths, intervals, DECIMAL precision, ...), per dialect: the round trip
  `parse_one(sql, read=d).sql(d)` and `simplify(...)`.
* `num_simplify`: constant folding of arithmetic, shifts and comparisons on boundary
  operands (Python ints are unbounded; the port folds with BigInt).
* `num_exec`: the executor on a table of boundary Int64 values and on literals. Python
  results that contain integers outside Int64 are marked `overflow`: the port's executor
  uses 64-bit integers and must raise an error for them instead of wrapping.
* `num_serde`: Python `Expr.dump()` payloads of trees holding integer arguments (JSON path
  subscripts/slices); payloads with integers outside Int64 are marked `overflow` (the port
  stores AST integers as Int64 and must refuse them on load).
* `num_to_py`: `Literal.to_py()` / `is_int` for numeric literals (`overflow` beyond Int64).
"""

import json
import os
import sys
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
if not os.path.isdir(SG):
    SG = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(ROOT))), ".repos", "sqlglot")
sys.path.insert(0, SG)
try:
    import dateutil.relativedelta  # noqa: F401
except ImportError:
    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyshim"))
warnings.filterwarnings("ignore")

import logging  # noqa: E402

logging.getLogger("sqlglot").setLevel(logging.CRITICAL)

import sqlglot  # noqa: E402
from sqlglot import exp  # noqa: E402
from sqlglot.executor import execute  # noqa: E402
from sqlglot.optimizer.simplify import simplify  # noqa: E402

OUT = os.path.join(ROOT, "src", "robust_tests", "fixture_numeric_test.mbt")

I64_MIN = -(2**63)
I64_MAX = 2**63 - 1


def mbt_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif o < 0x20 or o >= 0x7F:
            out.append("\\u{%x}" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def attempt(fn):
    try:
        return fn()
    except Exception as e:
        return "error:" + type(e).__name__


def has_big_int(v):
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        return not (I64_MIN <= v <= I64_MAX)
    if isinstance(v, (list, tuple)):
        return any(has_big_int(x) for x in v)
    if isinstance(v, dict):
        return any(has_big_int(k) or has_big_int(x) for k, x in v.items())
    return False


LITERALS = [
    "0",
    "1",
    "9223372036854775807",
    "9223372036854775808",
    "18446744073709551615",
    "18446744073709551616",
    "123456789012345678901234567890",
    "99999999999999999999999999999999999999",
    "1e308",
    "1e309",
    "1.7976931348623157e308",
    "4.9e-324",
    "1e-400",
    "0.1",
    "1.5",
    "1_000",
    "0x7FFFFFFFFFFFFFFF",
    "0xFFFFFFFFFFFFFFFFFFFF",
    "1E+2",
    "00012",
]

TEMPLATES = [
    "SELECT {x}",
    "SELECT -{x}",
    "SELECT - -{x}",
    "SELECT CAST({x} AS BIGINT)",
    "SELECT a FROM t LIMIT {x}",
    "SELECT a FROM t LIMIT 1 OFFSET {x}",
    "SELECT a[{x}] FROM t",
    "SELECT JSON_EXTRACT(a, '$[{x}]') FROM t",
    "SELECT a -> '$[{x}]' FROM t",
    "SELECT a + INTERVAL '{x}' DAY FROM t",
    "SELECT CAST(a AS DECIMAL({x}, 2)) FROM t",
    "SELECT ROUND(a, {x}) FROM t",
    "SELECT SUBSTRING(a, {x}, 2) FROM t",
    "SELECT a FROM t WHERE a = {x}",
    "SELECT a FROM t WHERE a BETWEEN {x} AND {x}",
]

DIALECTS = ["", "postgres", "duckdb", "bigquery", "snowflake", "spark", "presto", "tsql", "mysql", "clickhouse", "hive", "sqlite", "oracle"]


def sql_rows():
    rows = []
    for d in DIALECTS:
        for tpl in TEMPLATES:
            for x in LITERALS:
                sql = tpl.format(x=x)
                rows.append(
                    (
                        d,
                        sql,
                        attempt(lambda: sqlglot.parse_one(sql, read=d).sql(d)),
                        attempt(
                            lambda: simplify(sqlglot.parse_one(sql, read=d), dialect=d).sql(d)
                        ),
                    )
                )
    return rows


OPERANDS = [
    "0",
    "1",
    "-1",
    "2",
    "63",
    "64",
    "9223372036854775807",
    "-9223372036854775807",
    "9223372036854775808",
    "-9223372036854775808",
    "18446744073709551616",
    "123456789012345678901234567890",
    "0.5",
    "1e308",
    "2.5",
]
OPERATORS = ["+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^", "=", "<", ">=", "<>"]


def simplify_rows():
    rows = []
    for a in OPERANDS:
        for op in OPERATORS:
            for b in OPERANDS:
                sql = f"SELECT {a} {op} {b}"
                rows.append(
                    (sql, attempt(lambda: simplify(sqlglot.parse_one(sql)).sql()))
                )
    for a in OPERANDS:
        for sql in (
            f"SELECT -({a})",
            f"SELECT ABS({a})",
            f"SELECT ({a} + 1) - 1",
            f"SELECT {a} * 1 + 0",
            f"SELECT DATE '2020-01-01' + INTERVAL '{a}' DAY",
            f"SELECT CAST('2020-01-01' AS DATE) - INTERVAL {a} YEAR",
            f"SELECT x FROM t WHERE x + {a} > {a}",
        ):
            rows.append((sql, attempt(lambda: simplify(sqlglot.parse_one(sql)).sql())))
    # Date arithmetic near Python's date/timedelta/C int limits.
    for n in ["10000", "8000", "-3000", "2147483647", "2147483648", "3000000", "999999999", "1000000000", "4000000", "-2914000", "-737790", "-737789"]:
        for unit in ["DAY", "YEAR", "MONTH", "QUARTER", "WEEK", "HOUR", "MINUTE", "SECOND", "MILLISECOND"]:
            for sql in (
                f"SELECT DATE '2020-01-01' + INTERVAL '{n}' {unit}",
                f"SELECT CAST('9999-12-31 23:00:00' AS TIMESTAMP) - INTERVAL '{n}' {unit}",
            ):
                rows.append((sql, attempt(lambda: simplify(sqlglot.parse_one(sql)).sql())))
    return rows


TABLE_VALUES = [0, 1, -1, 2, 3037000499, 3037000500, 4294967296, I64_MAX, I64_MIN, I64_MAX - 1, I64_MIN + 1]


def exec_rows():
    tables = {"t": [{"i": i, "a": v} for i, v in enumerate(TABLE_VALUES)]}
    exprs = [
        "a + 1",
        "a - 1",
        "a * 2",
        "a * a",
        "-a",
        "ABS(a)",
        "a / 2",
        "a / 3",
        "a % 7",
        "a % -7",
        "a // 2",
        "a << 1",
        "a << 62",
        "a << 64",
        "a >> 1",
        "a >> 63",
        "a >> 64",
        "a & 255",
        "a | 1",
        "a ^ -1",
        "POWER(a, 2)",
        "POWER(2, 62)",
        "POWER(2, 63)",
        "POWER(2, 64)",
        "a + 0.5",
        "CAST(a AS DOUBLE)",
        "CAST(a AS TEXT)",
        "CAST(CAST(a AS TEXT) AS BIGINT)",
        "a = 9223372036854775807",
        "a < 9223372036854775808",
        "a + 9223372036854775808",
        "a - 9223372036854775808",
        "CAST(1e19 AS BIGINT)",
        "CAST('9223372036854775808' AS BIGINT)",
        "CAST('99999999999999999999' AS BIGINT)",
        "9223372036854775807 + 1",
        "-9223372036854775808 - 1",
        "18446744073709551616",
        "18446744073709551616 - 18446744073709551615",
    ]
    rows = []
    for e in exprs:
        sql = f"SELECT i, {e} AS v FROM t ORDER BY i"
        try:
            r = execute(sql, tables=tables)
            kind = "overflow" if has_big_int(r.rows) else "ok"
            rows.append((sql, kind, repr(r.columns), repr(r.rows)))
        except Exception as ex:
            rows.append((sql, "error", type(ex).__name__, ""))
    queries = [f"SELECT {agg} AS v FROM t" for agg in ["SUM(a)", "SUM(a) - SUM(a)", "MAX(a)", "MIN(a)", "COUNT(a)", "AVG(a)"]]
    for limit in ["2", "3000000000", "9223372036854775807"]:
        for offset in ["", " OFFSET 1", " OFFSET 3000000000", " OFFSET 9223372036854775807"]:
            queries.append(f"SELECT i FROM t ORDER BY i LIMIT {limit}{offset}")
            queries.append(f"SELECT i FROM t LIMIT {limit}{offset}")
            queries.append(f"SELECT COUNT(*) AS c FROM t GROUP BY a > 0 LIMIT {limit}{offset}")
    for sql in queries:
        try:
            r = execute(sql, tables=tables)
            kind = "overflow" if has_big_int(r.rows) else "ok"
            rows.append((sql, kind, repr(r.columns), repr(r.rows)))
        except Exception as ex:
            rows.append((sql, "error", type(ex).__name__, ""))
    return TABLE_VALUES, rows


def serde_rows():
    rows = []
    for x in [
        "0",
        "9223372036854775807",
        "-9223372036854775808",
        "9223372036854775808",
        "-9223372036854775809",
        "123456789012345678901234567890",
    ]:
        for sql in (
            f"SELECT JSON_EXTRACT(a, '$[{x}]')",
            f"SELECT JSON_EXTRACT(a, '$.b[{x}:{x}]')",
        ):
            e = attempt(lambda: sqlglot.parse_one(sql))
            if isinstance(e, str):
                rows.append((sql, "error", e, ""))
                continue
            payload = json.dumps(e.dump(), separators=(",", ":"))
            ints = []

            def collect(v):
                if isinstance(v, bool):
                    return
                if isinstance(v, int):
                    ints.append(v)
                elif isinstance(v, list):
                    for y in v:
                        collect(y)
                elif isinstance(v, dict):
                    for y in v.values():
                        collect(y)

            collect(e.dump())
            kind = "overflow" if any(has_big_int(v) for v in ints) else "ok"
            rows.append((sql, kind, payload, e.sql()))
    return rows


def to_py_rows():
    rows = []
    for x in LITERALS + ["-9223372036854775808", "-9223372036854775809"]:
        e = sqlglot.parse_one(x)
        try:
            v = e.to_py()
            kind = "overflow" if has_big_int(v) else "ok"
            val = repr(v)
        except Exception as ex:
            kind, val = "error", type(ex).__name__
        rows.append((x, kind, val, "1" if e.is_int else "0"))
    return rows


def main():
    parts = ["// Code generated by tools/gen_numeric_fixtures.py. DO NOT EDIT.\n"]

    parts.append(
        "///|\n/// (dialect, sql, round trip, simplify)\nlet num_sql : Array[(String, String, String, String)] = ["
    )
    for row in sql_rows():
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    parts.append("///|\n/// (sql, simplify(sql))\nlet num_simplify : Array[(String, String)] = [")
    for row in simplify_rows():
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    values, rows = exec_rows()
    parts.append("///|\nlet num_exec_values : Array[Int64] = [")
    parts.append("  " + ", ".join(f"{v}L" if v != I64_MIN else "-9223372036854775807L - 1L" for v in values) + ",")
    parts.append("]\n")
    parts.append(
        "///|\n/// (sql, ok|overflow|error, columns-or-error, rows)\n"
        "let num_exec : Array[(String, String, String, String)] = ["
    )
    for row in rows:
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    parts.append(
        "///|\n/// (sql, ok|overflow|error, Python dump payload, sql)\n"
        "let num_serde : Array[(String, String, String, String)] = ["
    )
    for row in serde_rows():
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    parts.append(
        "///|\n/// (literal, ok|overflow|error, repr(to_py()), is_int)\n"
        "let num_to_py : Array[(String, String, String, String)] = ["
    )
    for row in to_py_rows():
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    with open(OUT, "w") as f:
        f.write("\n".join(parts))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
