"""Run the Python sqlglot dialect test-suite with an instrumented Validator and record
every (read dialect, write dialect, input sql, output sql, options) case as JSON lines.

Usage: python3 tools/extract_dialect_tests.py > /tmp/cases.jsonl
Then: python3 tools/gen_dialect_fixtures.py
"""

import json
import os
import sys
import unittest
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
sys.path.insert(0, SG)
os.chdir(SG)
warnings.filterwarnings("ignore")

import logging  # noqa: E402

logging.disable(logging.CRITICAL)

from sqlglot import ErrorLevel, UnsupportedError, parse_one  # noqa: E402
from tests.dialects import test_dialect  # noqa: E402

OUT = []


def name(d):
    if d is None:
        return ""
    if isinstance(d, str):
        return d
    return type(d).__name__.lower() if not isinstance(d, type) else d.__name__.lower()


def record(**kw):
    OUT.append(kw)


V = test_dialect.Validator
orig_identity = V.validate_identity
orig_all = V.validate_all
orig_transpile = V.validate_transpile


def validate_identity(self, sql, write_sql=None, pretty=False, check_command_warning=False, identify=False):
    try:
        e = parse_one(sql, read=self.dialect)
        out = e.sql(dialect=self.dialect, pretty=pretty, identify=identify)
        record(test=self.id(), kind="identity", read=name(self.dialect), write=name(self.dialect),
               sql=sql, out=out, pretty=pretty, identify=identify, command=check_command_warning)
    except Exception as ex:  # noqa: BLE001
        record(test=self.id(), kind="identity", read=name(self.dialect), write=name(self.dialect),
               sql=sql, error=type(ex).__name__, pretty=pretty, identify=identify)
    try:
        return orig_identity(self, sql, write_sql, pretty, check_command_warning, identify)
    except Exception:  # noqa: BLE001
        return parse_one(sql, read=self.dialect)


def validate_transpile(self, sql, write_sql, write_dialect=None):
    try:
        e = parse_one(sql, read=self.dialect)
        record(test=self.id(), kind="transpile", read=name(self.dialect), write=name(write_dialect),
               sql=sql, out=e.sql(dialect=write_dialect))
    except Exception as ex:  # noqa: BLE001
        record(test=self.id(), kind="transpile", read=name(self.dialect), write=name(write_dialect),
               sql=sql, error=type(ex).__name__)
    try:
        return orig_transpile(self, sql, write_sql, write_dialect)
    except Exception:  # noqa: BLE001
        return parse_one(sql, read=self.dialect)


def validate_all(self, sql, read=None, write=None, pretty=False, identify=False):
    for read_dialect, read_sql in (read or {}).items():
        try:
            out = parse_one(read_sql, read_dialect).sql(
                self.dialect, unsupported_level=ErrorLevel.IGNORE, pretty=pretty, identify=identify
            )
            record(test=self.id(), kind="all_read", read=name(read_dialect), write=name(self.dialect),
                   sql=read_sql, out=out, pretty=pretty, identify=identify)
        except Exception as ex:  # noqa: BLE001
            record(test=self.id(), kind="all_read", read=name(read_dialect), write=name(self.dialect),
                   sql=read_sql, error=type(ex).__name__, pretty=pretty, identify=identify)
    try:
        expression = parse_one(sql, read=self.dialect)
    except Exception:  # noqa: BLE001
        expression = None
    for write_dialect, write_sql in (write or {}).items():
        if expression is None:
            continue
        if write_sql is UnsupportedError:
            record(test=self.id(), kind="all_write", read=name(self.dialect), write=name(write_dialect),
                   sql=sql, unsupported=True)
            continue
        try:
            out = expression.sql(write_dialect, unsupported_level=ErrorLevel.IGNORE, pretty=pretty,
                                  identify=identify)
            record(test=self.id(), kind="all_write", read=name(self.dialect), write=name(write_dialect),
                   sql=sql, out=out, pretty=pretty, identify=identify)
        except Exception as ex:  # noqa: BLE001
            record(test=self.id(), kind="all_write", read=name(self.dialect), write=name(write_dialect),
                   sql=sql, error=type(ex).__name__, pretty=pretty, identify=identify)
    try:
        return orig_all(self, sql, read, write, pretty, identify)
    except Exception:  # noqa: BLE001
        return None


V.validate_identity = validate_identity
V.validate_all = validate_all
V.validate_transpile = validate_transpile

loader = unittest.TestLoader()
suite = loader.discover("tests/dialects", pattern="test_*.py", top_level_dir=".")
runner = unittest.TextTestRunner(stream=open(os.devnull, "w"), verbosity=0)
result = runner.run(suite)
sys.stderr.write(f"ran={result.testsRun} failures={len(result.failures)} errors={len(result.errors)} cases={len(OUT)}\n")
for t, tb in result.errors[:5]:
    sys.stderr.write(str(t) + "\n" + tb[-600:] + "\n")
for c in OUT:
    print(json.dumps(c, ensure_ascii=False))
