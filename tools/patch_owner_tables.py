"""Recomputes the `kind_owner_*` tables of src/core/gen_kinds.mbt in place (Python MRO
attribute lookup), without regenerating the rest of the file.

    python tools/patch_owner_tables.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, ".repos", "sqlglot"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_meta  # noqa: E402
from sqlglot import exp  # noqa: E402


def main():
    classes = gen_meta.all_classes()
    idx = {c: i for i, c in enumerate(classes)}
    path = os.path.join(ROOT, "src", "core", "gen_kinds.mbt")
    s = open(path).read()
    changed = 0
    for prop in gen_meta.POLY_PROPS:
        vals = []
        for c in classes:
            owner = -1
            for a in c.__mro__:
                if prop in a.__dict__:
                    if a not in (exp.Expr, exp.Expression):
                        owner = idx.get(a, -1)
                    break
            vals.append(owner)
        m = re.search(
            r"let kind_owner_" + prop + r" : FixedArray\[Int\] = \[\n(.*?)\n\]", s, re.S
        )
        old = [int(x) for x in re.findall(r"-?\d+", m.group(1))]
        assert len(old) == len(vals), prop
        if old != vals:
            changed += sum(1 for a, b in zip(old, vals) if a != b)
            lines = [
                "  " + ", ".join(map(str, vals[i : i + 20])) + ","
                for i in range(0, len(vals), 20)
            ]
            s = s[: m.start(1)] + "\n".join(lines) + s[m.end(1) :]
    with open(path, "w") as f:
        f.write(s)
    print("changed entries:", changed)


if __name__ == "__main__":
    main()
