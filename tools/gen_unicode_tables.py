"""Generate src/core/gen_unicode.mbt: Python's Unicode character database as MoonBit tables.

    python tools/gen_unicode_tables.py

The tables are derived from the running CPython (`str.upper/lower/casefold`, `str.isalpha`
and friends, `_sre.unicode_tolower`, `re._compiler._EXTRA_CASES`), so the MoonBit helpers in
src/core/unicode.mbt reproduce exactly the behaviour of the Python version that generates the
test fixtures (the version and its Unicode database version are recorded in the output).

Tables:

* character classes as sorted, flattened `[start0, end0, start1, end1, ...]` ranges;
* case mappings as runs `[start, end, delta, stride]` of single code point mappings
  (`stride` 2 covers the alternating upper/lower pairs of e.g. Latin Extended-A), plus a
  sorted list of code points whose mapping expands to several code points (e.g. `ß` ->
  `SS`, `İ` -> `i̇`);
* `cased` and `case_ignorable` for the Final_Sigma rule of `str.lower()`, recovered from
  the behaviour of `str.lower()` itself;
* the `re` module's extra case-insensitive equivalences (e.g. `s`/`ſ`, `σ`/`ς`).
"""

import os
import re
import sys
import unicodedata

import _sre

try:
    from re._compiler import _EXTRA_CASES as EXTRA_CASES
except ImportError:  # Python < 3.11
    from sre_compile import _ignorecase_fixes as EXTRA_CASES  # type: ignore

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "core", "gen_unicode.mbt")

MAX = 0x110000


def code_points():
    for c in range(MAX):
        if 0xD800 <= c < 0xE000:
            continue
        yield c


def ranges(pred):
    out = []
    start = None
    prev = None
    for c in code_points():
        if pred(c):
            if start is None or c != prev + 1:
                if start is not None:
                    out.append((start, prev))
                start = c
            prev = c
        elif start is not None:
            out.append((start, prev))
            start = None
    if start is not None:
        out.append((start, prev))
    return out


def case_map(fn):
    """Returns (runs, multi) for a str -> str per-code-point mapping."""
    single = {}
    multi = {}
    for c in code_points():
        m = fn(chr(c))
        if m == chr(c):
            continue
        if len(m) == 1:
            single[c] = ord(m) - c
        else:
            multi[c] = m
    mapped = set(single) | set(multi)
    runs = []
    cps = sorted(single)
    i = 0
    while i < len(cps):
        s = cps[i]
        d = single[s]
        stride = 1
        e = s
        j = i + 1
        if j < len(cps) and single[cps[j]] == d:
            if cps[j] == s + 1:
                stride = 1
            elif cps[j] == s + 2 and (s + 1) not in mapped:
                stride = 2
        while j < len(cps) and cps[j] == e + stride and single[cps[j]] == d:
            if stride == 2 and (e + 1) in mapped:
                break
            e = cps[j]
            j += 1
        runs.append((s, e, d, stride))
        i = j
    return runs, multi


def final_sigma_props():
    """`case_ignorable` and `cased` as used by CPython's handle_capital_sigma, recovered from
    the behaviour of `str.lower()` (see the docstring of py_lower in unicode.mbt)."""

    def b(x):
        return ("AΣ" + x).lower()[1] == "ς"

    def c(x):
        return ("AΣ" + x + "B").lower()[1] == "ς"

    def a(x):
        return (x + "Σ").lower()[-1] == "ς"

    ignorable = set()
    cased = set()
    for cp in code_points():
        if cp == 0x3A3:
            cased.add(cp)
            continue
        x = chr(cp)
        ign = b(x) and not c(x)
        if ign:
            ignorable.add(cp)
        elif a(x):
            cased.add(cp)
    # Cross-check against the documented definition of `cased` (Lowercase, Uppercase, Lt) for
    # the characters that aren't case-ignorable.
    for cp in code_points():
        if cp in ignorable:
            continue
        ch = chr(cp)
        expected = ch.islower() or ch.isupper() or unicodedata.category(ch) == "Lt"
        assert (cp in cased) == expected, hex(cp)
    return ignorable, cased


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


def int_array(name, values, doc):
    lines = [f"///|\n/// {doc}\nlet {name} : FixedArray[Int] = ["]
    for i in range(0, len(values), 12):
        lines.append("  " + ", ".join(str(v) for v in values[i : i + 12]) + ",")
    lines.append("]\n")
    return "\n".join(lines)


def str_array(name, values, doc):
    lines = [f"///|\n/// {doc}\nlet {name} : FixedArray[String] = ["]
    for i in range(0, len(values), 8):
        lines.append("  " + ", ".join(mbt_str(v) for v in values[i : i + 8]) + ",")
    lines.append("]\n")
    return "\n".join(lines)


def flat_ranges(rs):
    return [v for r in rs for v in r]


def main():
    parts = [
        "// Code generated by tools/gen_unicode_tables.py; DO NOT EDIT.\n"
        f"// Python {sys.version.split()[0]}, Unicode {unicodedata.unidata_version}.\n",
        "///|\n"
        f'pub let unicode_version : String = "{unicodedata.unidata_version}"\n',
    ]

    classes = [
        ("uc_alpha", lambda c: chr(c).isalpha(), "`str.isalpha()`"),
        ("uc_decimal", lambda c: chr(c).isdecimal(), "`str.isdecimal()` (also `re`'s `\\d`)"),
        ("uc_digit", lambda c: chr(c).isdigit(), "`str.isdigit()`"),
        ("uc_numeric", lambda c: chr(c).isnumeric(), "`str.isnumeric()`"),
        ("uc_space", lambda c: chr(c).isspace(), "`str.isspace()` (also `re`'s `\\s`)"),
        ("uc_lower", lambda c: chr(c).islower(), "`str.islower()` of one character"),
        ("uc_upper", lambda c: chr(c).isupper(), "`str.isupper()` of one character"),
        ("uc_printable", lambda c: chr(c).isprintable(), "`str.isprintable()`"),
        ("uc_id_start", lambda c: chr(c).isidentifier(), "`str.isidentifier()` of one character"),
        (
            "uc_id_continue",
            lambda c: ("a" + chr(c)).isidentifier(),
            "characters that may continue a Python identifier",
        ),
        ("uc_sre_cased", lambda c: _sre.unicode_iscased(c), "`_sre.unicode_iscased`"),
    ]
    for name, pred, doc in classes:
        parts.append(int_array(name, flat_ranges(ranges(pred)), f"Ranges for {doc}."))

    # Decimal digits come in contiguous runs of ten starting at zero.
    for s, e in ranges(lambda c: chr(c).isdecimal()):
        for c in range(s, e + 1):
            assert unicodedata.decimal(chr(c)) == (c - s) % 10, hex(c)

    ignorable, cased = final_sigma_props()
    parts.append(
        int_array(
            "uc_case_ignorable",
            flat_ranges(ranges(lambda c: c in ignorable)),
            "Ranges for `Case_Ignorable` (Final_Sigma rule of `str.lower()`).",
        )
    )
    parts.append(
        int_array(
            "uc_cased",
            flat_ranges(ranges(lambda c: c in cased)),
            "Ranges for `Cased` (Final_Sigma rule of `str.lower()`).",
        )
    )

    for name, fn, doc in [
        ("upper", str.upper, "`str.upper()`"),
        ("lower", str.lower, "`str.lower()` (without the Final_Sigma rule)"),
        ("fold", str.casefold, "`str.casefold()`"),
    ]:
        runs, multi = case_map(fn)
        parts.append(
            int_array(
                f"uc_{name}_runs",
                [v for r in runs for v in r],
                f"Single code point mappings of {doc} as `[start, end, delta, stride]` runs.",
            )
        )
        keys = sorted(multi)
        parts.append(
            int_array(f"uc_{name}_multi_cps", keys, f"Code points whose {doc} expands.")
        )
        parts.append(
            str_array(
                f"uc_{name}_multi_strs",
                [multi[k] for k in keys],
                f"The expansions of `uc_{name}_multi_cps`.",
            )
        )

    # `_sre.unicode_tolower` is the first code point of the full lowercase mapping.
    for c in code_points():
        assert _sre.unicode_tolower(c) == ord(chr(c).lower()[0]), hex(c)

    keys = sorted(EXTRA_CASES)
    flat = []
    for k in keys:
        flat.extend([k, len(EXTRA_CASES[k])] + list(EXTRA_CASES[k]))
    parts.append(
        int_array(
            "uc_sre_extra_cases",
            flat,
            "`re`'s extra case-insensitive equivalences as `[lower, n, alt_1 .. alt_n]` groups.",
        )
    )

    with open(OUT, "w") as f:
        f.write("\n".join(parts))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
