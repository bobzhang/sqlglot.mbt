"""Generate generator fixtures for dialect variants that only change Generator/Dialect flags.

For every AST of src/generator_tests/*_data_test.mbt (identity, pretty and dialect cases), the
SQL is re-parsed in Python and generated with synthetic dialects whose Generator class only
changes data attributes. Only cases whose output differs from the base output, or that emit
unsupported messages, are recorded.

Usage: python3 tools/gen_generator_variants.py <cases.jsonl from extract_dialect_tests.py>
"""

import json
import os
import sys
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
sys.path.insert(0, SG)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
warnings.filterwarnings("ignore")

import logging  # noqa: E402

logging.getLogger("sqlglot").setLevel(logging.CRITICAL)

from gen_meta import mbt_str  # noqa: E402

OUT = os.path.join(ROOT, "src", "generator_tests")

VARIANTS = {
    "flagsa": (
        {
            "LIMIT_FETCH": "FETCH",
            "NULL_ORDERING_SUPPORTED": None,
            "SET_OP_MODIFIERS": False,
            "ENSURE_BOOLS": True,
            "IS_BOOL_ALLOWED": False,
            "TZ_TO_WITH_TIME_ZONE": True,
            "SINGLE_STRING_INTERVAL": True,
            "INTERVAL_ALLOWS_PLURAL_FORM": False,
            "EXTRACT_ALLOWS_QUOTES": False,
            "VALUES_AS_TABLE": False,
            "WRAP_DERIVED_VALUES": False,
            "UNNEST_WITH_ORDINALITY": False,
            "MULTI_ARG_DISTINCT": False,
            "SUPPORTS_TABLE_ALIAS_COLUMNS": False,
            "TABLESAMPLE_REQUIRES_PARENS": False,
            "TABLESAMPLE_SIZE_IS_ROWS": False,
            "TABLESAMPLE_WITH_METHOD": False,
            "QUERY_HINTS": False,
            "JOIN_HINTS": False,
            "TABLE_HINTS": False,
            "LOCKING_READS_SUPPORTED": True,
            "NVL2_SUPPORTED": False,
            "SUPPORTS_DECODE_CASE": False,
            "STAR_EXCLUDE_REQUIRES_DERIVED_TABLE": False,
            "SUPPORTS_LIKE_QUANTIFIERS": False,
            "SUPPORTS_MEDIAN": False,
            "SUPPORTS_TO_NUMBER": False,
            "TRY_SUPPORTED": False,
            "SUPPORTS_SINGLE_ARG_CONCAT": False,
            "LAST_DAY_SUPPORTS_DATE_PART": False,
            "CAN_IMPLEMENT_ARRAY_ANY": True,
            "ARRAY_SIZE_DIM_REQUIRED": True,
            "PARSE_JSON_NAME": None,
            "COLLATE_IS_FUNC": True,
            "CTE_RECURSIVE_KEYWORD_REQUIRED": False,
            "SEMI_ANTI_JOIN_WITH_SIDE": False,
            "COMPUTED_COLUMN_WITH_TYPE": False,
            "SUPPORTS_TABLE_COPY": False,
            "SUPPORTS_CREATE_TABLE_LIKE": False,
            "ALTER_TABLE_INCLUDE_COLUMN_KEYWORD": False,
            "RENAME_TABLE_WITH_DB": False,
            "SUPPORTS_EXPLODING_PROJECTIONS": False,
            "PAD_FILL_PATTERN_IS_REQUIRED": True,
            "SUPPORTS_WINDOW_EXCLUDE": True,
            "SUPPORTS_BETWEEN_FLAGS": True,
            "RETURNING_END": False,
            "EXCEPT_INTERSECT_SUPPORT_ALL_CLAUSE": False,
            "SUPPORTS_SELECT_INTO": True,
            "SUPPORTS_UESCAPE": False,
            "QUOTE_JSON_PATH": False,
            "JSON_PATH_SINGLE_QUOTE_ESCAPE": True,
            "JSON_PATH_BRACKETED_KEY_SUPPORTED": False,
            "UPDATE_STATEMENT_SUPPORTS_FROM": False,
            "MATCHED_BY_SOURCE": False,
            "DUPLICATE_KEY_UPDATE_WITH_SET": False,
            "INDEX_ON": "FOR",
            "NORMALIZE_EXTRACT_DATE_PARTS": True,
            "SUPPORTS_CONVERT_TIMEZONE": True,
            "SUPPORTS_UNIX_SECONDS": True,
            "SUPPORTS_GROUPING_SETS_AS_SUFFIX": True,
            "SUPPORTS_MODIFY_COLUMN": True,
            "SUPPORTS_CHANGE_COLUMN": True,
            "SUPPORTS_ALTER_COLUMN_NULLABILITY": True,
            "SUPPORTS_ALTER_COLUMN_IF_EXISTS": True,
            "ALTER_SET_WRAPPED": True,
            "ALTER_SET_TYPE": "TYPE",
            "HEX_FUNC": "TO_HEX",
            "STAR_EXCEPT": "EXCLUDE",
            "TABLESAMPLE_KEYWORDS": "USING SAMPLE",
            "TABLESAMPLE_SEED_KEYWORD": "REPEATABLE",
            "PARAMETER_TOKEN": "$",
            "NAMED_PLACEHOLDER_TOKEN": "@",
            "QUERY_HINT_SEP": " ",
            "GROUPINGS_SEP": "",
            "JSON_KEY_VALUE_PAIR_SEP": ",",
            "INSERT_OVERWRITE": " OVERWRITE INTO",
            "DECLARE_DEFAULT_ASSIGNMENT": "DEFAULT",
            "INOUT_SEPARATOR": "",
            "ARRAY_SIZE_NAME": "CARDINALITY",
            "MOD_OPERATOR": "MOD",
            "SELECT_KINDS": (),
            "SUPPORTS_UNLOGGED_TABLES": True,
            "PIVOT_ALIAS_WITH_AS": False,
            "UNPIVOT_ALIASES_ARE_IDENTIFIERS": False,
            "SET_ASSIGNMENT_REQUIRES_VARIABLE_KEYWORD": True,
            "SUPPORTS_NAMED_CTE_COLUMNS": False,
            "COPY_PARAMS_ARE_WRAPPED": False,
            "COPY_PARAMS_EQ_REQUIRED": True,
            "COPY_HAS_INTO_KEYWORD": False,
            "SUPPORTS_DROP_ALTER_ICEBERG_PROPERTY": False,
            "IGNORE_NULLS_IN_FUNC": True,
            "DATA_TYPE_SPECIFIERS_ALLOWED": True,
            "HISTORICAL_DATA_POST_ALIAS": True,
            "LIKE_PROPERTY_INSIDE_SCHEMA": True,
            "SUPPORTS_MERGE_WHERE": True,
            "AUTO_REFRESH_BARE_INTERVALS": True,
            "DIRECTED_JOINS": True,
        },
        {
            "NULL_ORDERING": "nulls_are_large",
            "CONCAT_COALESCE": True,
            "CONCAT_WS_COALESCE": True,
            "TYPED_DIVISION": True,
            "LOG_BASE_FIRST": None,
            "STRICT_STRING_CONCAT": True,
            "UNNEST_COLUMN_ONLY": True,
            "ALIAS_POST_TABLESAMPLE": True,
            "ALIAS_POST_VERSION": True,
            "INDEX_OFFSET": 1,
            "HEX_LOWERCASE": True,
            "TABLESAMPLE_SIZE_IS_PERCENT": True,
            "SUPPORTS_COLUMN_JOIN_MARKS": True,
            "ALTER_TABLE_ADD_REQUIRED_FOR_EACH_COLUMN": False,
            "ALTER_TABLE_SUPPORTS_CASCADE": True,
            "ON_CONDITION_EMPTY_BEFORE_ERROR": False,
            "UUID_IS_STRING_TYPE": True,
            "INITCAP_SUPPORTS_CUSTOM_DELIMITERS": False,
            "WEEK_OFFSET": -1,
            "PROJECTION_ALIASES_SHADOW_SOURCE_NAMES": True,
            "IDENTIFIERS_CAN_START_WITH_DIGIT": True,
            "HEX_STRING_IS_INTEGER_TYPE": True,
            "BYTE_STRING_IS_BYTES_TYPE": True,
        },
    ),
    "flagsb": (
        {
            "LIMIT_IS_TOP": True,
            "LIMIT_FETCH": "LIMIT",
            "NULL_ORDERING_SUPPORTED": False,
            "SET_OP_PARENTHESIZED_OPERANDS": False,
            "SUPPORTS_UNLOGGED_TABLES": True,
            "WITH_PROPERTIES_PREFIX": "TBLPROPERTIES",
            "IGNORE_NULLS_IN_FUNC": True,
            "IGNORE_NULLS_BEFORE_ORDER": False,
            "SUPPORTS_TABLE_ALIAS_COLUMNS": False,
            "SUPPORTS_NAMED_CTE_COLUMNS": True,
            "ARRAY_SIZE_DIM_REQUIRED": False,
            "SUPPORTS_SINGLE_ARG_CONCAT": False,
            "EXPRESSIONS_WITHOUT_NESTED_CTES": {"Select", "Insert", "Union"},
            "UNSUPPORTED_TYPES": {"TEXT", "JSON"},
            "TYPE_MAPPING": {"TEXT": "STRING", "INT": "INTEGER", "VARCHAR": "STRING"},
            "TOKEN_MAPPING": {"AUTO_INCREMENT": "AUTOINCREMENT"},
            "RESERVED_KEYWORDS": {"x", "y", "a", "b", "c", "t"},
            "WINDOW_FUNCS_WITH_NULL_ORDERING": ("FirstValue", "LastValue", "Rank"),
            "RESPECT_IGNORE_NULLS_UNSUPPORTED_EXPRESSIONS": ("Max",),
            "TIME_PART_SINGULARS": {"DAYS": "DAY", "HOURS": "HOUR"},
            "INTERVAL_ALLOWS_PLURAL_FORM": False,
            "EXPRESSION_PRECEDES_PROPERTIES_CREATABLES": {"TABLE"},
            "MATCH_AGAINST_TABLE_PREFIX": "TABLE",
        },
        {
            "NULL_ORDERING": "nulls_are_last",
            "LOG_BASE_FIRST": False,
            "SAFE_DIVISION": True,
            "TYPED_DIVISION": False,
        },
    ),
}


def make_dialect(name, gen_flags, dialect_flags):
    from sqlglot import exp
    from sqlglot.dialects.dialect import Dialect
    from sqlglot.generator import Generator

    gflags = {}
    for k, v in gen_flags.items():
        if k in ("EXPRESSIONS_WITHOUT_NESTED_CTES",):
            v = {getattr(exp, x) for x in v}
        elif k in ("WINDOW_FUNCS_WITH_NULL_ORDERING", "RESPECT_IGNORE_NULLS_UNSUPPORTED_EXPRESSIONS"):
            v = tuple(getattr(exp, x) for x in v)
        elif k == "UNSUPPORTED_TYPES":
            v = {getattr(exp.DType, x) for x in v}
        elif k == "TYPE_MAPPING":
            v = {**Generator.TYPE_MAPPING, **{getattr(exp.DType, a): b for a, b in v.items()}}
        elif k == "TOKEN_MAPPING":
            from sqlglot.tokens import TokenType

            v = {getattr(TokenType, a): b for a, b in v.items()}
        gflags[k] = v
    gen_cls = type(name.capitalize() + "Generator", (Generator,), gflags)
    attrs = dict(dialect_flags)
    attrs["generator_class"] = gen_cls
    cls = type(name.capitalize(), (Dialect,), attrs)
    return cls()


def asts(cases_path):
    import sqlglot
    from sqlglot.helper import seq_get  # noqa: F401

    sys.path.insert(0, os.path.join(SG, "tests"))
    from helpers import load_sql_fixture_pairs

    from gen_generator_fixtures import canonical_typed

    out = []
    seen = set()

    def add(sql, read=None):
        try:
            e = sqlglot.parse_one(sql, read=read)
        except Exception:
            return
        if e is None:
            return
        key = canonical_typed(e)
        if key in seen:
            return
        seen.add(key)
        out.append((sql, read, key))

    for line in open(os.path.join(SG, "tests/fixtures/identity.sql")):
        line = line.rstrip("\n")
        if line.strip():
            add(line)
    for _, src, _ in load_sql_fixture_pairs("pretty.sql"):
        add(src)
    s2 = set()
    for line in open(cases_path):
        c = json.loads(line)
        if "error" in c or c.get("kind") not in ("identity", "all", "transpile"):
            continue
        read = c.get("read") or ""
        sql = c.get("sql")
        if not isinstance(sql, str) or (read, sql) in s2:
            continue
        s2.add((read, sql))
        add(sql, read or None)
    return out


def main():
    import sqlglot
    from sqlglot import ErrorLevel

    cases = asts(sys.argv[1])
    lines = []
    for i, (sql, read, ast) in enumerate(cases):
        lines.append(("ast", ast))
    with open(os.path.join(OUT, "generator_variant_data_test.mbt"), "w") as f:
        f.write("// Code generated by tools/gen_generator_variants.py. DO NOT EDIT.\n\n")
        f.write("///|\n")
        f.write("let variant_asts : Array[String] = [\n")
        for _, _, ast in cases:
            f.write(f"  {mbt_str(ast)},\n")
        f.write("]\n\n")
        f.write("///|\n")
        f.write("/// Base outputs with unsupported_level=IGNORE: sql, then messages joined by '\\n'.\n")
        f.write("let variant_base : Array[String] = [\n")
        base = sqlglot.Dialect.get_or_raise(None)
        base_out = []
        for sql, read, _ in cases:
            e = sqlglot.parse_one(sql, read=read)
            g = base.generator(unsupported_level=ErrorLevel.IGNORE)
            try:
                s = g.generate(e)
                m = "\n".join(g.unsupported_messages)
            except Exception as ex:  # noqa: BLE001
                s, m = "<error>", type(ex).__name__
            base_out.append((s, m))
            f.write(f"  {mbt_str(s)}, {mbt_str(m)},\n")
        f.write("]\n\n")
        for vname, (gflags, dflags) in VARIANTS.items():
            d = make_dialect(vname, gflags, dflags)
            f.write("///|\n")
            f.write(f"/// Variant {vname}: (index, sql, messages) for outputs differing from base.\n")
            f.write(f"let variant_{vname} : Array[String] = [\n")
            n = 0
            for i, (sql, read, _) in enumerate(cases):
                e = sqlglot.parse_one(sql, read=read)
                g = d.generator(unsupported_level=ErrorLevel.IGNORE)
                try:
                    s = g.generate(e)
                    m = "\n".join(g.unsupported_messages)
                except Exception as ex:  # noqa: BLE001
                    s, m = "<error>", type(ex).__name__
                if (s, m) != base_out[i]:
                    f.write(f"  {mbt_str(str(i))}, {mbt_str(s)}, {mbt_str(m)},\n")
                    n += 1
            f.write("]\n\n")
            print(vname, n, "differing cases")
    print(len(cases), "asts")


if __name__ == "__main__":
    main()
