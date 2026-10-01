"""Generate differential Unicode fixtures from Python into src/robust_tests.

    python tools/gen_unicode_fixtures.py

Writes src/robust_tests/fixture_unicode_test.mbt with:

* `uc_block_hashes`: for every 4096-code-point block, an FNV-1a hash of each code point's
  `str.upper/lower/casefold()`, `unicodedata.decimal` and character classes (`isalpha`,
  `isdecimal`, `isdigit`, `isnumeric`, `isspace`, `islower`, `isupper`, `isprintable`,
  `isidentifier`, identifier-continue, `isalnum`, and `re`'s `\\w`, `\\d`, `\\s`). The
  MoonBit runner recomputes the hashes with the port's helpers, so every code point is
  checked against Python.
* `uc_ignorecase`: for a set of cased characters, which other characters of the set match
  them under `re.IGNORECASE` (the executor's ILIKE and the optimizer's star ILIKE).
* `uc_strings`: a corpus of strings (special casing, Final_Sigma contexts, astral characters,
  Unicode digits and spaces) with Python's string-level results.
* `uc_sql`: SQL with Unicode identifiers/literals per dialect: tokens (with code point
  positions), round trip, `normalize_identifiers`, `case_sensitive`, `to_identifier`.
* `uc_exec`: executor queries (ILIKE, UPPER/LOWER, LENGTH, LEFT/RIGHT/SUBSTRING/REVERSE,
  STRPOSITION, ORDER BY / MIN / MAX on strings) over a table of Unicode strings.
"""

import os
import random
import re
import sys
import unicodedata
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
from sqlglot.dialects.dialect import Dialect  # noqa: E402
from sqlglot.executor import execute  # noqa: E402
from sqlglot.optimizer.normalize_identifiers import normalize_identifiers  # noqa: E402

try:
    from re._compiler import _EXTRA_CASES as EXTRA_CASES
except ImportError:  # Python < 3.11
    from sre_compile import _ignorecase_fixes as EXTRA_CASES  # type: ignore

OUT = os.path.join(ROOT, "src", "robust_tests", "fixture_unicode_test.mbt")

BLOCK = 0x1000
RE_W = re.compile(r"\w")
RE_D = re.compile(r"\d")
RE_S = re.compile(r"\s")


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


def fnv(h, v):
    return ((h ^ v) * 16777619) & 0xFFFFFFFF


def signed32(h):
    return h - (1 << 32) if h >= 1 << 31 else h


def cp_signature(c):
    ch = chr(c)
    flags = 0
    for bit, v in enumerate(
        [
            ch.isalpha(),
            ch.isdecimal(),
            ch.isdigit(),
            ch.isnumeric(),
            ch.isspace(),
            ch.islower(),
            ch.isupper(),
            ch.isprintable(),
            ch.isidentifier(),
            ("a" + ch).isidentifier(),
            ch.isalnum(),
            bool(RE_W.fullmatch(ch)),
            bool(RE_D.fullmatch(ch)),
            bool(RE_S.fullmatch(ch)),
        ]
    ):
        if v:
            flags |= 1 << bit
    sig = [c, flags, unicodedata.decimal(ch, -1) & 0xFFFFFFFF]
    for m in (ch.upper(), ch.lower(), ch.casefold()):
        sig.append(len(m))
        sig.extend(ord(x) for x in m)
    return sig


def block_hashes():
    out = []
    for b in range(0, 0x110000, BLOCK):
        h = 2166136261
        for c in range(b, b + BLOCK):
            if 0xD800 <= c < 0xE000:
                continue
            for v in cp_signature(c):
                h = fnv(h, v)
        out.append(signed32(h))
    return out


def ignorecase_set():
    import _sre

    pool = set()
    spans = [
        (0x0000, 0x0600),
        (0x10A0, 0x1100),
        (0x13A0, 0x1400),
        (0x1C80, 0x1CC0),
        (0x1E00, 0x2200),
        (0x2C00, 0x2D40),
        (0xA640, 0xA800),
        (0xAB70, 0xABC0),
        (0xFB00, 0xFB20),
        (0xFF20, 0xFF60),
        (0x10400, 0x10460),
        (0x1E900, 0x1E950),
    ]
    for a, b in spans:
        for c in range(a, b):
            if _sre.unicode_iscased(c):
                pool.add(c)
    for k, vs in EXTRA_CASES.items():
        pool.add(k)
        pool.update(vs)
    for c in list(pool):
        for m in (chr(c).upper(), chr(c).lower(), chr(c).casefold()):
            pool.update(ord(x) for x in m)
    # A few uncased characters.
    pool.update([ord(x) for x in "0_%.-ʹ·ˆ́ͅ"] + [0x1F600, 0x4E2D])
    return sorted(pool)


def ignorecase_table(pool):
    rows = []
    chars = [chr(c) for c in pool]
    for p in pool:
        rx = re.compile(re.escape(chr(p)), re.IGNORECASE)
        matches = [ord(c) for c in chars if ord(c) != p and rx.fullmatch(c)]
        rows.append((p, matches))
    return rows


POOLS = [
    "abcxyzABCXYZ",
    "ßẞŉǰΐΰﬀﬁﬂﬃﬄﬅﬆﬓ",
    "İıIiĲĳſ",
    "ΣσςΑαΒβΩωΆά",
    "ǅǄǆǈǋ",
    "ДдЖжЯяЀѐ",
    "ԱաՖֆև",
    "ႠⴀᏸᏰ",
    "𐐀𐐨𐓀𐓘𞤀𞤢",
    "😀🎉🇩🇪𝔄𝕒",
    "́ͅ‍­'.·",
    "0123456789١٢٣٤۵߀०௧²³¹½Ⅻ㊀𝟘𝟙",
    " \t 　  \u0085",
    "_-$#@",
    "中文日本語한국어",
]


def gen_strings():
    rnd = random.Random(1234)
    out = [
        "",
        "Σ",
        "ΑΣ",
        "ΑΣ Σ",
        "ΑΣΑ",
        "ΑΣ'",
        "Α'Σ",
        "ΆΣ",
        "ΑΣ́",
        "ΑΣ́Β",
        ".Σ.",
        "ΌΣΟΣ",
        "ΣΑΣ ΣΑΣ.",
        "𐐀Σ",
        "ǅΣ",
        "straße",
        "STRASSE",
        "İstanbul",
        "ﬁnance",
        "ǅungla",
        "Ǆ",
        "ǈ",
        "ŉ",
        "ﬓ",
        "Ꭰᏸ",
        "𐐀𐐨",
        "x😀y",
        "١٢٣",
        " ١٢ ",
        "²",
        "½",
        "1_000",
        "１２３",
        "　123　",
        "á",
        "_a1",
        "1a",
        "été",
        "­",
        "a‍b",
        "line sep",
        "nbsp x",
        "tab\tx",
        "\x7f\x80\x9f",
        "\U000e0001",
        "﻿",
        "'\"",
        "'",
    ]
    letters = "".join(POOLS)
    for _ in range(150):
        n = rnd.randint(1, 8)
        out.append("".join(rnd.choice(letters) for _ in range(n)))
    seen = set()
    uniq = []
    for s in out:
        if s not in seen:
            seen.add(s)
            uniq.append(s)
    return uniq


def py_int(s):
    try:
        return str(int(s))
    except ValueError:
        return "error"


def string_rows(strings):
    rows = []
    for s in strings:
        rows.append(
            (
                s,
                s.upper(),
                s.lower(),
                s.casefold(),
                repr(s),
                "".join(
                    "1" if f else "0"
                    for f in (s.isidentifier(), s.isdigit(), s.isalnum(), s.isspace())
                ),
                len(s),
                py_int(s),
            )
        )
    return rows


IDENTS = [
    "straße",
    "STRASSE",
    "İd",
    "ıd",
    "Σίσυφος",
    "ΟΔΟΣ",
    "Ǆx",
    "ǅx",
    "ﬁeld",
    "été",
    "ÉTÉ",
    "𐐀col",
    "col𐐨",
    "Ꮳol",
    "ᏸol",
    "x😀",
    "中文",
    "a١",
    "café́",
    "_ü",
    "Ωmega",
]

DIALECTS = ["", "postgres", "snowflake", "bigquery", "duckdb", "mysql", "tsql", "oracle", "clickhouse", "presto"]


def tokens_digest(sql, dialect):
    try:
        tokens = Dialect.get_or_raise(dialect).tokenize(sql)
    except Exception as e:
        return "error:" + type(e).__name__
    return " ".join(f"{t.token_type.name}:{t.text}@{t.line},{t.col},{t.start},{t.end}" for t in tokens)


def attempt(fn):
    try:
        return fn()
    except Exception as e:
        return "error:" + type(e).__name__


def sql_rows():
    rows = []
    for d in DIALECTS:
        dialect = Dialect.get_or_raise(d)
        for name in IDENTS:
            quoted = exp.to_identifier(name).sql(dialect=d)
            for sql in (
                f"SELECT {name} FROM t",
                f"SELECT {quoted}, '{name}' AS x FROM {quoted}",
                f"SELECT * FROM t WHERE c = '{name}' -- {name}\n",
            ):
                rows.append(
                    (
                        d,
                        name,
                        sql,
                        tokens_digest(sql, d),
                        attempt(lambda: sqlglot.parse_one(sql, read=d).sql(d)),
                        attempt(
                            lambda: normalize_identifiers(
                                sqlglot.parse_one(sql, read=d), dialect=d
                            ).sql(d)
                        ),
                        "1" if dialect.case_sensitive(name) else "0",
                        attempt(lambda: exp.to_identifier(name).sql(d, identify="safe")),
                        quoted,
                    )
                )
    return rows


EXEC_STRINGS = [
    "straße",
    "STRASSE",
    "İstanbul",
    "istanbul",
    "ΟΔΟΣ",
    "οδος",
    "οδός",
    "ǅungla",
    "ﬁnance",
    "x😀y",
    "😀",
    "�",
    "￿",
    "𐐀𐐨",
    "Ꭰᏸ",
    "ſtop",
    "KELVIN",
    "K",
    "été",
    "abc",
    "",
    "a\nb",
]

EXEC_PATTERNS = ["%ss%", "STRA%", "%Σ", "%ς", "i%", "İ%", "_😀_", "%😀%", "ſ%", "S%", "k%", "%𐐨%", "%𐑐%", "ﬁ%", "FI%", "_", "%\n%", "a_b", "ᏸ%", "ꮰ%"]


def exec_rows():
    tables = {"t": [{"i": i, "s": s} for i, s in enumerate(EXEC_STRINGS)]}
    queries = [
        "SELECT i, UPPER(s) AS u, LOWER(s) AS l, LENGTH(s) AS n FROM t",
        "SELECT i, REVERSE(s) AS r, LEFT(s, 2) AS a, RIGHT(s, 2) AS b FROM t",
        "SELECT i, SUBSTRING(s, 2, 2) AS a, SUBSTRING(s, 2) AS b FROM t",
        "SELECT i, STRPOS(s, '😀') AS p, STRPOS(s, 'y') AS q FROM t",
        "SELECT s FROM t ORDER BY s",
        "SELECT MIN(s) AS lo, MAX(s) AS hi FROM t",
        "SELECT i FROM t WHERE s < '￿' ORDER BY i",
        "SELECT i FROM t WHERE s > '�' ORDER BY i",
    ]
    for p in EXEC_PATTERNS:
        queries.append(f"SELECT i FROM t WHERE s ILIKE '{p}' ORDER BY i")
        queries.append(f"SELECT i FROM t WHERE s LIKE '{p}' ORDER BY i")
    rows = []
    for q in queries:
        try:
            r = execute(q, tables=tables)
            rows.append((q, "ok", repr(r.columns), repr(r.rows)))
        except Exception as e:
            rows.append((q, "error", type(e).__name__, ""))
    return EXEC_STRINGS, rows


def main():
    parts = ["// Code generated by tools/gen_unicode_fixtures.py. DO NOT EDIT.\n"]
    parts.append(
        f"///|\nlet uc_python_unicode_version : String = {mbt_str(unicodedata.unidata_version)}\n"
    )
    hashes = block_hashes()
    parts.append("///|\n/// FNV-1a hash per 4096-code-point block.\nlet uc_block_hashes : Array[Int] = [")
    for i in range(0, len(hashes), 8):
        parts.append("  " + ", ".join(str(h) for h in hashes[i : i + 8]) + ",")
    parts.append("]\n")

    pool = ignorecase_set()
    parts.append(
        "///|\n/// (pattern char, other chars of the pool it matches under re.IGNORECASE)\n"
        "let uc_ignorecase : Array[(Int, Array[Int])] = ["
    )
    for p, ms in ignorecase_table(pool):
        parts.append(f"  ({p}, [{', '.join(str(m) for m in ms)}]),")
    parts.append("]\n")

    parts.append(
        "///|\n/// (s, upper, lower, casefold, repr, isidentifier/isdigit/isalnum/isspace, len, int(s))\n"
        "let uc_strings : Array[(String, String, String, String, String, String, Int, String)] = ["
    )
    for row in string_rows(gen_strings()):
        s, u, l, f, r, flags, n, i = row
        parts.append(
            f"  ({mbt_str(s)}, {mbt_str(u)}, {mbt_str(l)}, {mbt_str(f)}, {mbt_str(r)}, {mbt_str(flags)}, {n}, {mbt_str(i)}),"
        )
    parts.append("]\n")

    parts.append(
        "///|\n/// (dialect, name, sql, tokens, round trip, normalize_identifiers, case_sensitive(name),\n"
        "/// to_identifier(name).sql(identify=safe), to_identifier(name).sql())\n"
        "let uc_sql : Array[(String, String, String, String, String, String, String, String, String)] = ["
    )
    for row in sql_rows():
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    strings, rows = exec_rows()
    parts.append("///|\nlet uc_exec_strings : Array[String] = [")
    for s in strings:
        parts.append(f"  {mbt_str(s)},")
    parts.append("]\n")
    parts.append(
        "///|\n/// (sql, kind, columns-or-error, rows)\nlet uc_exec : Array[(String, String, String, String)] = ["
    )
    for row in rows:
        parts.append("  (" + ", ".join(mbt_str(x) for x in row) + "),")
    parts.append("]\n")

    with open(OUT, "w") as f:
        f.write("\n".join(parts))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
