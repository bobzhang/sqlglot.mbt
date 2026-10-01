"""Generate MoonBit optimizer fixtures by running each optimizer rule in Python.

Mirrors tests/test_optimizer.py: every rule is driven with the same schema, kwargs,
dialect and pretty settings, and the Python output is recorded as the expected
result (errors are recorded as "ERROR: <ExceptionType>: <message>").

Run with the scratchpad venv python (needs pytz):
    python tools/gen_optimizer_fixtures.py
"""

import json
import os
import sys
import warnings
from functools import partial

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
sys.path.insert(0, SG)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import dateutil.relativedelta  # noqa: F401
except ImportError:
    # Fall back to a minimal relativedelta so that date simplifications are exercised
    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyshim"))
warnings.filterwarnings("ignore")

import logging  # noqa: E402

logging.getLogger("sqlglot").setLevel(logging.CRITICAL)

from gen_meta import mbt_str  # noqa: E402

import sqlglot  # noqa: E402
from sqlglot import exp, optimizer, parse_one  # noqa: E402
from sqlglot.optimizer.annotate_types import annotate_types  # noqa: E402
from sqlglot.optimizer.canonicalize_internal_names import canonicalize_internal_names  # noqa: E402
from sqlglot.optimizer.qualify import qualify  # noqa: E402
from sqlglot.optimizer.scope import build_scope  # noqa: E402
from sqlglot.schema import MappingSchema  # noqa: E402
from tests.helpers import (  # noqa: E402
    TPCDS_SCHEMA,
    TPCH_SCHEMA,
    load_sql_fixture_pairs,
    load_sql_fixtures,
    string_to_bool,
)

OUT = os.path.join(ROOT, "src", "optimizer_tests")

sqlglot.schema = MappingSchema()

# ---------------------------------------------------------------------------
# Wrappers copied from tests/test_optimizer.py


def qualify_then_canonicalize(expression, **qualify_kwargs):
    return canonicalize_internal_names(qualify(expression, **qualify_kwargs))


def qualify_columns(expression, validate_qualify_columns=True, **kwargs):
    return optimizer.qualify.qualify(
        expression,
        infer_schema=True,
        validate_qualify_columns=validate_qualify_columns,
        identify=False,
        **kwargs,
    )


def pushdown_projections(expression, **kwargs):
    expression = optimizer.qualify_tables.qualify_tables(expression)
    expression = optimizer.qualify_columns.qualify_columns(expression, infer_schema=True, **kwargs)
    return optimizer.pushdown_projections.pushdown_projections(expression)


def normalize(expression, **kwargs):
    schema = kwargs.get("schema")
    expression = optimizer.normalize.normalize(expression, dnf=False)
    expression = annotate_types(expression, schema=schema)
    return optimizer.simplify.simplify(expression)


def simplify(expression, **kwargs):
    dialect = kwargs.get("dialect")
    schema = kwargs.get("schema")
    expression = annotate_types(expression, schema=schema, dialect=dialect)
    return optimizer.simplify.simplify(
        expression, constant_propagation=True, coalesce_simplification=True, dialect=dialect
    )


def pushdown_ctes(expression, **kwargs):
    optimizer.qualify_columns.pushdown_cte_alias_columns(build_scope(expression))
    return expression


def annotate_functions(expression, **kwargs):
    annotated = annotate_types(expression, dialect=kwargs.get("dialect"), schema=kwargs.get("schema"))
    return annotated.expressions[0]


TEST_SCHEMA = {
    "x": {"a": "INT", "b": "INT"},
    "nn": {
        "a": exp.DataType.build("INT", nullable=False),
        "b": exp.DataType.build("INT", nullable=False),
    },
    "y": {"b": "INT", "c": "INT"},
    "z": {"b": "INT", "c": "INT"},
    "w": {"d": "TEXT", "e": "TEXT"},
    "temporal": {"d": "DATE", "t": "DATETIME"},
    "structs": {
        "one": "STRUCT<a_1 INT, b_1 VARCHAR>",
        "nested_0": "STRUCT<a_1 INT, nested_1 STRUCT<a_2 INT, nested_2 STRUCT<a_3 INT>>>",
        "quoted": 'STRUCT<"foo bar" INT>',
    },
    "t_bool": {"a": "BOOLEAN", "b": "BOOLEAN"},
    "comparisons": {"a": "INT", "b": "INT", "c": "BOOLEAN"},
    "unpivotable": {"id": "INT", "jan": "INT", "feb": "INT", "north": "INT", "south": "INT"},
    "pivotable": {"id": "INT", "cat": "TEXT", "val": "INT", "kind": "TEXT", "amt": "INT"},
}

OPTIMIZER_SCHEMA = {
    "x": {"a": "INT", "b": "INT"},
    "y": {"b": "INT", "c": "INT"},
    "z": {"a": "INT", "c": "INT"},
    "u": {"f": "INT", "g": "INT", "h": "TEXT"},
}

CANON_NAMES_SCHEMA = {**TEST_SCHEMA, "jtbl": {"j": "JSON"}, "pvt": {"c": "TEXT", "v": "INT"}}

ANNOTATE_FUNCS_SCHEMA = {
    "tbl": {
        "bin_col": "BINARY",
        "str_col": "STRING",
        "bignum_col": "BIGNUMERIC",
        "date_col": "DATE",
        "decfloat_col": "DECFLOAT",
        "float_col": "FLOAT",
        "timestamp_col": "TIMESTAMP",
        "double_col": "DOUBLE",
        "bigint_col": "BIGINT",
        "smallint_col": "SMALLINT",
        "bit_col": "BIT",
        "obj_col": "OBJECT",
        "int_col": "INT",
        "bool_col": "BOOLEAN",
        "bytes_col": "BYTES",
        "interval_col": "INTERVAL",
        "array_col": "ARRAY<STRING>",
    }
}

INVISIBLE = {"x": ["a"], "y": ["b"], "z": ["b"]}


def schema_json(schema):
    def enc(v):
        if isinstance(v, dict):
            return {k: enc(x) for k, x in v.items()}
        if isinstance(v, exp.DataType):
            # only non-nullable DataTypes are used in the test schemas
            return {"__nonnull__": v.sql()}
        return v

    return json.dumps(enc(schema))


def merge_optimize(expression, **kwargs):
    return optimizer.optimize(
        expression,
        rules=[
            optimizer.qualify_tables.qualify_tables,
            optimizer.qualify_columns.qualify_columns,
            optimizer.merge_subqueries.merge_subqueries,
        ],
        **kwargs,
    )


def canonicalize_optimize(expression, **kwargs):
    return optimizer.optimize(
        expression,
        rules=[
            optimizer.qualify.qualify,
            optimizer.qualify_columns.quote_identifiers,
            annotate_types,
            optimizer.canonicalize.canonicalize,
        ],
        **kwargs,
    )


# (rule name, fixture file, function, pretty, kwargs)
RULES = [
    ("optimizer", "optimizer", optimizer.optimize, True, {"infer_schema": True, "schema": OPTIMIZER_SCHEMA}),
    ("isolate_table_selects", "isolate_table_selects", optimizer.isolate_table_selects.isolate_table_selects, False, {"schema": TEST_SCHEMA}),
    ("qualify_tables", "qualify_tables", optimizer.qualify_tables.qualify_tables, False, {"db": "db", "catalog": "c"}),
    ("normalize", "normalize", normalize, False, {"schema": TEST_SCHEMA}),
    ("qualify_columns", "qualify_columns", qualify_columns, False, {"schema": TEST_SCHEMA}),
    ("qualify_columns_ddl", "qualify_columns_ddl", qualify_columns, False, {"schema": TEST_SCHEMA}),
    ("qualify_columns__with_invisible", "qualify_columns__with_invisible", qualify_columns, False, {"schema": "INVISIBLE"}),
    ("pushdown_cte_alias_columns", "pushdown_cte_alias_columns", pushdown_ctes, False, {}),
    ("normalize_identifiers", "normalize_identifiers", optimizer.normalize_identifiers.normalize_identifiers, False, {}),
    ("quote_identifiers", "quote_identifiers", optimizer.qualify_columns.quote_identifiers, False, {}),
    ("pushdown_projections", "pushdown_projections", pushdown_projections, False, {"schema": TEST_SCHEMA}),
    ("simplify", "simplify", simplify, False, {"schema": TEST_SCHEMA}),
    ("unnest_subqueries", "unnest_subqueries", optimizer.unnest_subqueries.unnest_subqueries, False, {}),
    ("pushdown_predicates", "pushdown_predicates", optimizer.pushdown_predicates.pushdown_predicates, False, {}),
    ("optimize_joins", "optimize_joins", optimizer.optimize_joins.optimize_joins, False, {}),
    ("eliminate_joins", "eliminate_joins", optimizer.eliminate_joins.eliminate_joins, True, {}),
    ("eliminate_ctes", "eliminate_ctes", optimizer.eliminate_ctes.eliminate_ctes, True, {}),
    ("merge_subqueries", "merge_subqueries", merge_optimize, False, {"schema": TEST_SCHEMA}),
    ("eliminate_subqueries", "eliminate_subqueries", optimizer.eliminate_subqueries.eliminate_subqueries, False, {}),
    ("canonicalize_internal_names", "canonicalize_internal_names", qualify_then_canonicalize, False, {"schema": CANON_NAMES_SCHEMA, "catalog": "c", "db": "db"}),
    ("canonicalize", "canonicalize", canonicalize_optimize, False, {"schema": TEST_SCHEMA}),
    ("tpch", "tpc-h/tpc-h", optimizer.optimize, True, {"schema": TPCH_SCHEMA}),
    ("tpcds", "tpc-ds/tpc-ds", optimizer.optimize, True, {"schema": TPCDS_SCHEMA}),
]

META_KEYS = ("schema", "leave_tables_isolated", "validate_qualify_columns", "canonicalize_table_aliases")


def run_case(func, sql, read, pretty, **kwargs):
    try:
        optimized = func(parse_one(sql, read=read), **kwargs)
        return optimized.sql(pretty=pretty, dialect=read)
    except Exception as e:  # noqa: BLE001
        return f"ERROR: {type(e).__name__}: {e}"


def write_fixtures(name, records, consts=()):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"fixture_{name}_test.mbt")
    with open(path, "w") as f:
        f.write("// Code generated by tools/gen_optimizer_fixtures.py. DO NOT EDIT.\n\n")
        for cname, value in consts:
            f.write("///|\n")
            f.write(f"let {cname} : String = {mbt_str(value)}\n\n")
        f.write("///|\n")
        f.write(f"let {name}_fixtures : Array[String] = [\n")
        for rec in records:
            f.write("  " + ", ".join(mbt_str(x) for x in rec) + ",\n")
        f.write("]\n")


def gen_rule(name, file, func, pretty, kwargs):
    records = []
    for i, (meta, sql, _expected) in enumerate(load_sql_fixture_pairs(f"optimizer/{file}.sql"), start=1):
        title = meta.get("title") or f"{i}, {sql}"
        dialect = meta.get("dialect")
        func_kwargs = dict(kwargs)
        if func_kwargs.get("schema") == "INVISIBLE":
            func_kwargs["schema"] = MappingSchema(TEST_SCHEMA, {k: set(v) for k, v in INVISIBLE.items()})
        if schema := meta.get("schema"):
            func_kwargs["schema"] = json.loads(schema)
        for key, kw in (
            ("leave_tables_isolated", "leave_tables_isolated"),
            ("validate_qualify_columns", "validate_qualify_columns"),
            ("canonicalize_table_aliases", "canonicalize_table_aliases"),
        ):
            if meta.get(key) is not None:
                func_kwargs[kw] = string_to_bool(meta[key])
        if dialect:
            func_kwargs["dialect"] = dialect
        actual = run_case(func, sql, dialect, pretty, **func_kwargs)
        if os.environ.get("CHECK") and actual != _expected:
            print(f"  [{name}] python output differs from fixture: {title!r}: {actual!r} != {_expected!r}")
        meta_out = {k: meta[k] for k in META_KEYS if k in meta}
        records.append((title, dialect or "", json.dumps(meta_out), sql, actual))
    write_fixtures(name, records)
    return len(records)


def gen_annotate_types():
    records = []
    for i, (meta, sql, _expected) in enumerate(load_sql_fixture_pairs("optimizer/annotate_types.sql"), start=1):
        title = meta.get("title") or f"{i}, {sql}"
        dialect = meta.get("dialect")
        try:
            result = annotate_types(parse_one(sql, read=dialect), dialect=dialect)
            actual = result.type.sql(dialect)
        except Exception as e:  # noqa: BLE001
            actual = f"ERROR: {type(e).__name__}: {e}"
        records.append((title, dialect or "", "{}", sql, actual))
    write_fixtures("annotate_types", records)
    return len(records)


def gen_annotate_functions():
    records = []
    for i, (meta, sql, _expected) in enumerate(
        load_sql_fixture_pairs("optimizer/annotate_functions.sql"), start=1
    ):
        title = meta.get("title") or f"{i}, {sql}"
        dialects = (meta.get("dialect") or "").split(", ")
        full_sql = f"SELECT {sql} FROM tbl"
        for dialect in dialects:
            try:
                result = annotate_functions(
                    parse_one(full_sql, read=dialect), schema=ANNOTATE_FUNCS_SCHEMA, dialect=dialect
                )
                actual = result.type.sql(dialect)
            except Exception as e:  # noqa: BLE001
                actual = f"ERROR: {type(e).__name__}: {e}"
            records.append((title, dialect, "{}", full_sql, actual))
    write_fixtures("annotate_functions", records)
    return len(records)


def gen_invalid():
    records = []
    for sql in load_sql_fixtures("optimizer/qualify_columns__invalid.sql"):
        try:
            expression = optimizer.qualify_columns.qualify_columns(parse_one(sql), schema=TEST_SCHEMA)
            optimizer.qualify_columns.validate_qualify_columns(expression)
            actual = "OK"
        except Exception as e:  # noqa: BLE001
            actual = f"ERROR: {type(e).__name__}: {e}"
        records.append((sql, "", "{}", sql, actual))
    write_fixtures("qualify_columns__invalid", records)
    return len(records)


def gen_identity_stress():
    """Runs optimize / qualify / annotate_types on every statement of identity.sql."""
    from sqlglot import parse_one as p1

    records = []
    with open(os.path.join(SG, "tests", "fixtures", "identity.sql"), encoding="utf-8") as f:
        lines = [line.strip() for line in f if line.strip() and not line.startswith("--")]
    for _, sql, _ in load_sql_fixture_pairs("pretty.sql"):
        lines.append(sql)
    for sql in lines:
        try:
            expression = p1(sql)
        except Exception:  # noqa: BLE001
            continue
        for mode in ("optimize", "qualify", "annotate"):
            try:
                e = expression.copy()
                if mode == "optimize":
                    out = optimizer.optimize(e).sql()
                elif mode == "qualify":
                    out = qualify(e, validate_qualify_columns=False).sql()
                else:
                    annotated = annotate_types(e)
                    out = annotated.type.sql() if annotated.type else "None"
            except Exception as ex:  # noqa: BLE001
                out = f"ERROR: {type(ex).__name__}: {ex}"
            records.append((mode, "", "{}", sql, out))
    write_fixtures("identity_stress", records)
    return len(records)


def gen_schemas():
    consts = [
        ("test_schema_json", schema_json(TEST_SCHEMA)),
        ("optimizer_schema_json", schema_json(OPTIMIZER_SCHEMA)),
        ("canon_names_schema_json", schema_json(CANON_NAMES_SCHEMA)),
        ("annotate_funcs_schema_json", schema_json(ANNOTATE_FUNCS_SCHEMA)),
        ("tpch_schema_json", schema_json(TPCH_SCHEMA)),
        ("tpcds_schema_json", schema_json(TPCDS_SCHEMA)),
        ("invisible_json", json.dumps(INVISIBLE)),
    ]
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "fixture_schemas_test.mbt")
    with open(path, "w") as f:
        f.write("// Code generated by tools/gen_optimizer_fixtures.py. DO NOT EDIT.\n\n")
        for cname, value in consts:
            f.write("///|\n")
            f.write(f"let {cname} : String = {mbt_str(value)}\n\n")


if __name__ == "__main__":
    only = set(sys.argv[1:])
    gen_schemas()
    for spec in RULES:
        if only and spec[0] not in only:
            continue
        print(spec[0], gen_rule(*spec))
    if not only or "annotate_types" in only:
        print("annotate_types", gen_annotate_types())
    if not only or "annotate_functions" in only:
        print("annotate_functions", gen_annotate_functions())
    if not only or "invalid" in only:
        print("qualify_columns__invalid", gen_invalid())
    if not only or "identity_stress" in only:
        print("identity_stress", gen_identity_stress())
