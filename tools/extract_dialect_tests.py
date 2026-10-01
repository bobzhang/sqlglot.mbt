"""Run the Python sqlglot dialect test-suite with an instrumented Validator and record
every (read dialect, write dialect, input sql, output sql, options) case as JSON lines.

Besides the Validator helpers (validate_identity / validate_all / validate_transpile),
calls to `parse_one` / `parse` / `transpile` / `Expr.sql` made directly by the test
methods that *raise* a sqlglot error are recorded as `kind="error_call"` cases (the
exception class and message), so that the MoonBit port can check it raises the same
error with the same message.

The run fails (exit status 1) if any Python test fails or errors: the instrumentation
must not change the outcome of the suite, and a failing Python test means the recorded
expectations can't be trusted.

A per-test-method manifest (validator cases, error cases, direct assertions) is written
to the path given with `--manifest`; tools/gen_dialect_fixtures.py combines it with the
hand-ported tests in src/dialect_unit_tests into docs/dialect-test-manifest.md.

Usage: python3 tools/extract_dialect_tests.py [--manifest manifest.json] > cases.jsonl
Then: python3 tools/gen_dialect_fixtures.py cases.jsonl manifest.json
"""

import collections
import json
import logging
import os
import sys
import unittest
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SG = os.path.join(ROOT, ".repos", "sqlglot")
sys.path.insert(0, SG)
os.chdir(SG)
warnings.filterwarnings("ignore")
# test_dialect.test_lazy_load spawns `python`: make it the interpreter running this script.
os.environ["PATH"] = os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")

# Keep log output quiet without disabling logging: `assertLogs` must still see records.
logging.getLogger().addHandler(logging.NullHandler())
logging.getLogger().setLevel(logging.CRITICAL)

import sqlglot  # noqa: E402
from sqlglot import ErrorLevel, UnsupportedError, exp, parse_one  # noqa: E402
from sqlglot.dialects.dialect import Dialect  # noqa: E402
from sqlglot.errors import SqlglotError  # noqa: E402
from sqlglot.serde import dump  # noqa: E402
from tests.dialects import test_dialect  # noqa: E402

OUT = []
# Per test id: counters for the manifest.
STATS = collections.defaultdict(collections.Counter)
CURRENT = [None]
# > 0 while running inside a Validator helper (its own assertions are not "direct").
VALIDATOR_DEPTH = [0]
# > 0 while running inside a recorded API call (nested calls are not recorded).
CALL_DEPTH = [0]


def name(d):
    if d is None:
        return ""
    if isinstance(d, str):
        return d
    if isinstance(d, type):
        return d.__name__.lower()
    if isinstance(d, Dialect):
        return type(d).__name__.lower()
    raise TypeError(d)


def record(**kw):
    STATS[kw["test"]][kw["kind"]] += 1
    if "error" in kw:
        STATS[kw["test"]]["errors"] += 1
    OUT.append(kw)


V = test_dialect.Validator
orig_identity = V.validate_identity
orig_all = V.validate_all
orig_transpile = V.validate_transpile


def in_validator(f):
    def wrapper(*args, **kwargs):
        VALIDATOR_DEPTH[0] += 1
        try:
            return f(*args, **kwargs)
        finally:
            VALIDATOR_DEPTH[0] -= 1

    return wrapper


class quiet:
    """Silences logging while the recorder re-runs a case, so that the extra parse/generate
    calls don't add records to the test's own `assertLogs` captures."""

    def __enter__(self):
        logging.disable(logging.CRITICAL)

    def __exit__(self, *exc):
        logging.disable(logging.NOTSET)


def error_fields(ex):
    return {"error": type(ex).__name__, "message": str(ex)}


@in_validator
def validate_identity(self, sql, write_sql=None, pretty=False, check_command_warning=False, identify=False):
    with quiet():
        record_identity(self, sql, pretty, check_command_warning, identify)
    return orig_identity(self, sql, write_sql, pretty, check_command_warning, identify)


def record_identity(self, sql, pretty, check_command_warning, identify):
    try:
        e = parse_one(sql, read=self.dialect)
        out = e.sql(dialect=self.dialect, pretty=pretty, identify=identify)
        record(test=self.id(), kind="identity", read=name(self.dialect), write=name(self.dialect),
               sql=sql, out=out, pretty=pretty, identify=identify, command=check_command_warning)
    except Exception as ex:  # noqa: BLE001
        record(test=self.id(), kind="identity", read=name(self.dialect), write=name(self.dialect),
               sql=sql, pretty=pretty, identify=identify, **error_fields(ex))


@in_validator
def validate_transpile(self, sql, write_sql, write_dialect=None):
    with quiet():
        record_transpile(self, sql, write_dialect)
    return orig_transpile(self, sql, write_sql, write_dialect)


def record_transpile(self, sql, write_dialect):
    try:
        e = parse_one(sql, read=self.dialect)
        record(test=self.id(), kind="transpile", read=name(self.dialect), write=name(write_dialect),
               sql=sql, out=e.sql(dialect=write_dialect))
    except Exception as ex:  # noqa: BLE001
        record(test=self.id(), kind="transpile", read=name(self.dialect), write=name(write_dialect),
               sql=sql, **error_fields(ex))


@in_validator
def validate_all(self, sql, read=None, write=None, pretty=False, identify=False):
    with quiet():
        record_all(self, sql, read, write, pretty, identify)
    return orig_all(self, sql, read, write, pretty, identify)


def record_all(self, sql, read, write, pretty, identify):
    for read_dialect, read_sql in (read or {}).items():
        try:
            out = parse_one(read_sql, read_dialect).sql(
                self.dialect, unsupported_level=ErrorLevel.IGNORE, pretty=pretty, identify=identify
            )
            record(test=self.id(), kind="all_read", read=name(read_dialect), write=name(self.dialect),
                   sql=read_sql, out=out, pretty=pretty, identify=identify)
        except Exception as ex:  # noqa: BLE001
            record(test=self.id(), kind="all_read", read=name(read_dialect), write=name(self.dialect),
                   sql=read_sql, pretty=pretty, identify=identify, **error_fields(ex))
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
                   sql=sql, pretty=pretty, identify=identify, **error_fields(ex))


V.validate_identity = validate_identity
V.validate_all = validate_all
V.validate_transpile = validate_transpile
V.assert_duckdb_sql = V.assert_duckdb_sql  # a plain helper: its assertions count as direct

# --- Track the running test and count its direct assertions -------------------------

orig_run = unittest.TestCase.run


def run(self, result=None):
    CURRENT[0] = self.id()
    STATS[self.id()]["ran"] = 1
    try:
        return orig_run(self, result)
    finally:
        CURRENT[0] = None


unittest.TestCase.run = run


def counting(meth):
    def wrapper(self, *args, **kwargs):
        if VALIDATOR_DEPTH[0] == 0 and CURRENT[0] is not None:
            STATS[CURRENT[0]]["direct_asserts"] += 1
        return meth(self, *args, **kwargs)

    return wrapper


for attr in list(vars(unittest.TestCase)):
    if attr.startswith("assert") and callable(getattr(unittest.TestCase, attr)):
        setattr(unittest.TestCase, attr, counting(getattr(unittest.TestCase, attr)))

# --- Record failing API calls made directly by the tests ----------------------------

SIMPLE = (str, bool, int, float, type(None))


def option_value(v):
    if isinstance(v, ErrorLevel):
        return v.name
    if isinstance(v, SIMPLE):
        return v
    if isinstance(v, (Dialect, type)):
        return name(v)
    raise TypeError(v)


def record_error_call(fn, ex, sql=None, tree=None, dialect=None, opts=None):
    if CURRENT[0] is None:
        return
    try:
        options = {k: option_value(v) for k, v in (opts or {}).items()}
        d = name(dialect) if dialect is not None else ""
    except TypeError:
        STATS[CURRENT[0]]["unrecorded_errors"] += 1
        return
    case = dict(test=CURRENT[0], kind="error_call", fn=fn, dialect=d, opts=options,
                **error_fields(ex))
    if sql is not None:
        case["sql"] = sql
    if tree is not None:
        case["tree"] = tree
    record(**case)


def recording_api(fn_name, orig):
    def wrapper(sql, *args, **kwargs):
        if CALL_DEPTH[0] > 0 or VALIDATOR_DEPTH[0] > 0:
            return orig(sql, *args, **kwargs)
        CALL_DEPTH[0] += 1
        try:
            return orig(sql, *args, **kwargs)
        except SqlglotError as ex:
            if not isinstance(sql, str):
                STATS[CURRENT[0]]["unrecorded_errors"] += 1
                raise
            opts = dict(kwargs)
            positional = {"parse_one": ["read", "dialect", "into"], "parse": ["read", "dialect"],
                          "transpile": ["read", "write", "identity", "error_level"]}[fn_name]
            for k, v in zip(positional, args):
                opts[k] = v
            dialect = opts.pop("read", None) or opts.pop("dialect", None)
            opts.pop("dialect", None)
            if "into" in opts:
                into = opts.pop("into")
                if into is not None:
                    STATS[CURRENT[0]]["unrecorded_errors"] += 1
                    raise
            record_error_call(fn_name, ex, sql=sql, dialect=dialect, opts=opts)
            raise
        finally:
            CALL_DEPTH[0] -= 1

    wrapper.__wrapped__ = orig
    return wrapper


def recording_sql(orig):
    def sql(self, dialect=None, copy=True, **opts):
        if CALL_DEPTH[0] > 0 or VALIDATOR_DEPTH[0] > 0:
            return orig(self, dialect, copy, **opts)
        tree = dump(self)
        CALL_DEPTH[0] += 1
        try:
            return orig(self, dialect, copy, **opts)
        except SqlglotError as ex:
            record_error_call("sql", ex, tree=tree, dialect=dialect, opts=opts)
            raise
        finally:
            CALL_DEPTH[0] -= 1

    return sql


for cls in (exp.Expr, exp.Expression):
    if "sql" in vars(cls):
        cls.sql = recording_sql(vars(cls)["sql"])

API = {"parse_one": sqlglot.parse_one, "parse": sqlglot.parse, "transpile": sqlglot.transpile}

loader = unittest.TestLoader()
suite = loader.discover("tests/dialects", pattern="test_*.py", top_level_dir=".")

for mod_name, mod in list(sys.modules.items()):
    if mod_name.startswith("tests.dialects.test_"):
        for fn_name, orig in API.items():
            if getattr(mod, fn_name, None) is orig:
                setattr(mod, fn_name, recording_api(fn_name, orig))

manifest_path = None
if "--manifest" in sys.argv:
    manifest_path = sys.argv[sys.argv.index("--manifest") + 1]

runner = unittest.TextTestRunner(stream=open(os.devnull, "w"), verbosity=0)
result = runner.run(suite)
sys.stderr.write(
    f"ran={result.testsRun} failures={len(result.failures)} errors={len(result.errors)} "
    f"skipped={len(result.skipped)} cases={len(OUT)}\n"
)
for c in OUT:
    print(json.dumps(c, ensure_ascii=False))

if manifest_path:
    with open(manifest_path, "w") as f:
        json.dump({k: dict(v) for k, v in sorted(STATS.items())}, f, indent=1, sort_keys=True)

bad = result.failures + result.errors
if bad or result.unexpectedSuccesses:
    for t, tb in bad:
        sys.stderr.write(f"FAILED {t}\n{tb}\n")
    sys.stderr.write("extract_dialect_tests: the Python test-suite did not pass under instrumentation\n")
    sys.exit(1)
