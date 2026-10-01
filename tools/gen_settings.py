"""Generate dialect configuration data (non-callable class attributes) from Python sqlglot.

Emits:
  src/core/gen_config.mbt            -- DialectConfig / ParserConfig / GeneratorConfig structs + base values
  src/dialects/<name>/gen_config.mbt -- per dialect diffs against the parent dialect

Usage: python3 tools/gen_settings.py
"""

import enum
import os
import re
import sys
import types
import warnings

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, ".repos", "sqlglot"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
warnings.filterwarnings("ignore")

import sqlglot  # noqa: E402,F401
from sqlglot import exp, generator, parser, tokens  # noqa: E402
from sqlglot.dialects import DIALECTS  # noqa: E402
from sqlglot.dialects.dialect import Dialect  # noqa: E402
from sqlglot.tokenizer_core import TokenType  # noqa: E402

from gen_meta import kind_name, mbt_str, mbt_char  # noqa: E402

CORE = os.path.join(ROOT, "src", "core")

# Attributes that are hand-ported (callables) or derived at runtime.
SKIP = {
    "dialect": {
        "EXPRESSION_METADATA", "TIME_TRIE", "FORMAT_TRIE", "INVERSE_TIME_TRIE", "INVERSE_FORMAT_TRIE",
        "tokenizer_class", "jsonpath_tokenizer_class", "parser_class", "generator_class",
        "COERCES_TO", "SUPPORTED_SETTINGS",
    },
    "parser": {"SHOW_TRIE", "SET_TRIE"},
    "generator": {"SAFE_JSON_PATH_KEY_RE", "UNICODE_SUBSTITUTE", "TYPE_PARAM_SETTINGS"},
}


def snake(name):
    n = name.lower()
    if n in ("type", "match", "fn", "let", "if", "else", "for", "while", "loop", "break", "continue",
             "true", "false", "test", "struct", "enum", "trait", "impl", "with", "as", "in", "pub",
             "priv", "mut", "return", "raise", "try", "catch", "guard", "is", "use", "using", "const",
             "extern", "typealias", "async", "derive", "where", "init"):
        n = n + "_"
    return n


def is_callable_value(v):
    return isinstance(v, (types.FunctionType, types.MethodType, types.BuiltinFunctionType, staticmethod, classmethod, property))


def elem_kind(x):
    if isinstance(x, bool):
        return "bool"
    if isinstance(x, TokenType):
        return "tt"
    if isinstance(x, exp.DType):
        return "dtype"
    if isinstance(x, type) and issubclass(x, exp.Expr):
        return "kind"
    if isinstance(x, int):
        return "int"
    if isinstance(x, str):
        return "str"
    if x is None:
        return "none"
    if isinstance(x, (tuple, list)):
        return "seq"
    if isinstance(x, enum.Enum):
        return "enum:" + type(x).__name__
    if is_callable_value(x) or callable(x):
        return "fn"
    return "other:" + type(x).__name__


def infer(values):
    """Infer a type descriptor from all observed values of an attribute."""
    kinds = set()
    for v in values:
        if v is None:
            kinds.add("none")
        elif isinstance(v, bool):
            kinds.add("bool")
        elif isinstance(v, int) and not isinstance(v, enum.Enum):
            kinds.add("int")
        elif isinstance(v, str) and not isinstance(v, enum.Enum):
            kinds.add("str")
        elif isinstance(v, enum.Enum):
            kinds.add("enum:" + type(v).__name__)
        elif isinstance(v, (set, frozenset)):
            els = {elem_kind(x) for x in v}
            kinds.add(("set", frozenset(els)))
        elif isinstance(v, (list, tuple)):
            els = {elem_kind(x) for x in v}
            kinds.add(("seq", frozenset(els)))
        elif isinstance(v, dict):
            ks = {elem_kind(x) for x in v.keys()}
            vs = {elem_kind(x) for x in v.values()}
            kinds.add(("dict", frozenset(ks), frozenset(vs)))
        elif isinstance(v, re.Pattern):
            kinds.add("pattern")
        elif callable(v):
            kinds.add("fn")
        else:
            kinds.add("other:" + type(v).__name__)
    return kinds


def merge_containers(kinds):
    """Merge container descriptors across dialects."""
    sets = [k for k in kinds if isinstance(k, tuple) and k[0] == "set"]
    seqs = [k for k in kinds if isinstance(k, tuple) and k[0] == "seq"]
    dicts = [k for k in kinds if isinstance(k, tuple) and k[0] == "dict"]
    scalars = {k for k in kinds if not isinstance(k, tuple)}
    return sets, seqs, dicts, scalars


def resolve_type(name, kinds):
    """Return (mbt_type, encoder) or None if the attribute should be skipped."""
    sets, seqs, dicts, scalars = merge_containers(kinds)
    if "fn" in scalars or "pattern" in scalars:
        return None
    if sets or seqs:
        els = set()
        for k in sets + seqs:
            els |= set(k[1])
        els.discard("none") if False else None
        if dicts:
            return None
        if els <= {"tt"}:
            if sets:
                return ("TokenSet", enc_tokenset) if not seqs else ("TokenSet", enc_tokenset)
            return ("Array[TokenType]", enc_tt_array)
        if els <= {"str"}:
            if sets and not seqs:
                return ("@set.Set[String]", enc_str_set)
            return ("Array[String]", enc_str_array)
        if els <= {"kind"}:
            return ("Array[Kind]", enc_kind_array)
        if els <= {"dtype"}:
            return ("Array[DType]", enc_dtype_array)
        if els == set():
            # always empty; guess from name
            if name.endswith("TOKENS"):
                return ("TokenSet", enc_tokenset)
            return ("@set.Set[String]", enc_str_set) if sets else ("Array[String]", enc_str_array)
        if els <= {"str", "seq"}:
            return ("Array[Array[String]]", enc_str_seq_seq)
        return None
    if dicts:
        ks = set()
        vs = set()
        for d in dicts:
            ks |= set(d[1])
            vs |= set(d[2])
        if "fn" in vs:
            return None
        key_t = None
        if ks <= {"tt"}:
            key_t = ("TokenType", enc_tt)
        elif ks <= {"str"}:
            key_t = ("String", mbt_str)
        elif ks <= {"kind"}:
            key_t = ("Kind", enc_kind)
        elif ks <= {"dtype"}:
            key_t = ("DType", enc_dtype)
        elif ks <= {"seq"}:
            key_t = ("Array[String]", enc_str_seq)
        elif not ks:
            key_t = ("String", mbt_str)
        val_t = None
        if not vs:
            val_t = ("String", mbt_str)
        elif vs <= {"kind"}:
            val_t = ("Kind", enc_kind)
        elif vs <= {"tt"}:
            val_t = ("TokenType", enc_tt)
        elif vs <= {"str"}:
            val_t = ("String", mbt_str)
        elif vs <= {"bool"}:
            val_t = ("Bool", enc_bool)
        elif vs <= {"bool", "none"}:
            val_t = ("Bool?", enc_opt_bool)
        elif vs <= {"seq"}:
            val_t = ("Array[Array[String]]", enc_options)
        elif vs <= {"str", "seq"}:
            val_t = ("Array[String]", enc_str_or_seq)
        elif vs <= {"enum:PropertiesLocation"}:
            val_t = ("PropertiesLocation", enc_enum)
        elif vs <= {"int", "seq"} or vs <= {"seq", "int"}:
            return None
        if key_t is None or val_t is None:
            return None
        if key_t[0] == "Array[String]":
            return (f"Array[({key_t[0]}, {val_t[0]})]", lambda v, kt=key_t, vt=val_t: enc_pairs(v, kt[1], vt[1]))
        return (f"Map[{key_t[0]}, {val_t[0]}]", lambda v, kt=key_t, vt=val_t: enc_map(v, kt[1], vt[1]))
    s = set(scalars)
    if s <= {"bool"}:
        return ("Bool", enc_bool)
    if s <= {"bool", "none"}:
        return ("Bool?", enc_opt_bool)
    if s <= {"int"}:
        return ("Int", str)
    if s <= {"int", "none"}:
        return ("Int?", lambda v: "None" if v is None else f"Some({v})")
    if s <= {"str"}:
        return ("String", mbt_str)
    if s <= {"str", "none"}:
        return ("String?", lambda v: "None" if v is None else f"Some({mbt_str(v)})")
    if s <= {"str", "bool"}:
        return ("StrOrBool", enc_str_or_bool)
    if s == {"enum:DType"}:
        return ("DType", enc_dtype)
    if s == {"enum:NormalizationStrategy"}:
        return ("NormalizationStrategy", enc_enum)
    if s <= {"none"}:
        return ("String?", lambda v: "None")
    return None


def enc_bool(v):
    return "true" if v else "false"


def enc_opt_bool(v):
    return "None" if v is None else f"Some({enc_bool(v)})"


def enc_tt(v):
    return f"TokenType::{v.name}"


def enc_dtype(v):
    return f"DType::{v.name}"


def enc_kind(v):
    return f"Kind::{kind_name(v.__name__)}"


def enc_enum(v):
    return f"{type(v).__name__}::{''.join(p.capitalize() for p in v.name.lower().split('_'))}"


def enc_tokenset(v):
    return "TokenSet::new([" + ", ".join(sorted(enc_tt(x) for x in v)) + "])"


def enc_tt_array(v):
    return "[" + ", ".join(enc_tt(x) for x in v) + "]"


def enc_str_set(v):
    items = sorted(v) if isinstance(v, (set, frozenset)) else list(v)
    return "@set.Set::from_array([" + ", ".join(mbt_str(x) for x in items) + "])"


def enc_str_array(v):
    items = sorted(v) if isinstance(v, (set, frozenset)) else list(v)
    return "[" + ", ".join(mbt_str(x) for x in items) + "]"


def enc_kind_array(v):
    items = sorted(v, key=lambda c: c.__name__) if isinstance(v, (set, frozenset)) else list(v)
    return "[" + ", ".join(enc_kind(x) for x in items) + "]"


def enc_dtype_array(v):
    items = sorted(v, key=lambda c: c.name) if isinstance(v, (set, frozenset)) else list(v)
    return "[" + ", ".join(enc_dtype(x) for x in items) + "]"


def enc_str_seq(v):
    return "[" + ", ".join(mbt_str(x) for x in v) + "]"


def enc_str_seq_seq(v):
    out = []
    for x in v:
        if isinstance(x, str):
            out.append(f"[{mbt_str(x)}]")
        else:
            out.append(enc_str_seq(x))
    return "[" + ", ".join(out) + "]"


def enc_options(v):
    # OPTIONS_TYPE value: sequence of (str | sequence of str)
    return enc_str_seq_seq(v)


def enc_str_or_seq(v):
    if isinstance(v, str):
        return f"[{mbt_str(v)}]"
    return enc_str_seq(v)


def enc_str_or_bool(v):
    if isinstance(v, bool):
        return f"StrOrBool::B({enc_bool(v)})"
    return f"StrOrBool::S({mbt_str(v)})"


def enc_map(v, kenc, venc):
    if not v:
        return "Map([])"
    items = ", ".join(f"({kenc(k)}, {venc(x)})" for k, x in v.items())
    return "Map::from_array([" + items + "])"


def enc_pairs(v, kenc, venc):
    return "[" + ", ".join(f"({kenc(k)}, {venc(x)})" for k, x in v.items()) + "]"


def dialect_classes():
    out = {"": Dialect}
    for n in DIALECTS:
        d = Dialect.get_or_raise(n.lower())
        out[n.lower()] = type(d)
    return out


def class_for(D, cat):
    return {
        "dialect": D,
        "parser": D.parser_class,
        "generator": D.generator_class,
        "tokenizer": D.tokenizer_class,
    }[cat]


BASES = {"dialect": Dialect, "parser": parser.Parser, "generator": generator.Generator}


def data_attrs(cat, all_classes):
    base = BASES[cat]
    names = []
    for a in dir(base):
        if a.startswith("_") or a in SKIP[cat]:
            continue
        if not a.isupper():
            continue
        v = getattr(base, a)
        if is_callable_value(v) or (callable(v) and not isinstance(v, (dict, set, frozenset, list, tuple, type))):
            continue
        if isinstance(v, type):
            continue
        names.append(a)
    result = []
    for a in names:
        vals = [getattr(class_for(D, cat), a) for D in all_classes.values()]
        t = resolve_type(a, infer(vals))
        if t is None:
            continue
        result.append((a, t))
    return result


def parent_dialect_name(D, classes):
    for b in D.__mro__[1:]:
        for n, C in classes.items():
            if C is b:
                return n
    return ""


def values_equal(a, b):
    try:
        return a == b and type(a) is type(b)
    except Exception:
        return False


SNAKE_NAMES = {"DialectConfig": "dialect_config", "ParserConfig": "parser_config", "GeneratorConfig": "generator_config"}
STRUCT_NAMES = {"dialect": "DialectConfig", "parser": "ParserConfig", "generator": "GeneratorConfig"}


def gen():
    classes = dialect_classes()
    attrs = {cat: data_attrs(cat, classes) for cat in BASES}
    L = ["// Code generated by tools/gen_settings.py. DO NOT EDIT.", ""]
    for cat, struct in STRUCT_NAMES.items():
        L.append("///|")
        L.append(f"/// Data attributes of the Python `{BASES[cat].__name__}` class.")
        L.append(f"pub(all) struct {struct} {{")
        for a, (t, _) in attrs[cat]:
            L.append(f"  mut {snake(a)} : {t}")
        L.append("}")
        L.append("")
        L.append("///|")
        L.append(f"pub fn {struct}::copy(self : {struct}) -> {struct} {{")
        L.append("  {")
        for a, (t, _) in attrs[cat]:
            f = snake(a)
            if t.startswith("Map[") or t == "TokenSet" or t.startswith("Array[") or t.startswith("@set."):
                L.append(f"    {f}: self.{f}.copy(),")
            else:
                L.append(f"    {f}: self.{f},")
        L.append("  }")
        L.append("}")
        L.append("")
        L.append("///|")
        L.append(f"pub fn base_{SNAKE_NAMES[struct]}() -> {struct} {{")
        L.append("  {")
        base = BASES[cat]
        for a, (t, enc) in attrs[cat]:
            L.append(f"    {snake(a)}: {enc(getattr(base, a))},")
        L.append("  }")
        L.append("}")
        L.append("")
    with open(os.path.join(CORE, "gen_config.mbt"), "w") as f:
        f.write("\n".join(L) + "\n")

    # Per dialect diffs
    from gen_meta import tokenizer_settings_full  # noqa: F401

    for n, D in classes.items():
        if not n:
            continue
        parent = parent_dialect_name(D, classes)
        P = classes[parent]
        out = ["// Code generated by tools/gen_settings.py. DO NOT EDIT.", ""]
        out.append(f"// Parent dialect: {parent or 'base'}")
        out.append("")
        for cat, struct in STRUCT_NAMES.items():
            out.append("///|")
            out.append(f"fn apply_{cat}_config(c : @core.{struct}) -> Unit {{")
            cnt = 0
            for a, (t, enc) in attrs[cat]:
                v = getattr(class_for(D, cat), a)
                pv = getattr(class_for(P, cat), a)
                if not values_equal(v, pv):
                    code = enc(v).replace("TokenSet::", "@core.TokenSet::").replace("Kind::", "@core.Kind::").replace("TokenType::", "@core.TokenType::").replace("DType::", "@core.DType::").replace("PropertiesLocation::", "@core.PropertiesLocation::").replace("NormalizationStrategy::", "@core.NormalizationStrategy::").replace("StrOrBool::", "@core.StrOrBool::")
                    out.append(f"  c.{snake(a)} = {code}")
                    cnt += 1
            if cnt == 0:
                out.append("  ignore(c)")
            out.append("}")
            out.append("")
        # tokenizer diffs
        T = D.tokenizer_class
        PT = P.tokenizer_class
        out.append("///|")
        out.append("fn apply_tokenizer_config(t : @core.TokenizerSettings) -> Unit {")
        tcnt = 0
        for k in [k for k in PT.SINGLE_TOKENS if k not in T.SINGLE_TOKENS]:
            out.append(f"  t.single_tokens.remove({mbt_char(k)})")
            tcnt += 1
        for k, v in T.SINGLE_TOKENS.items():
            if PT.SINGLE_TOKENS.get(k) != v:
                out.append(f"  t.single_tokens[{mbt_char(k)}] = @core.TokenType::{v.name}")
                tcnt += 1
        for k in [k for k in PT.KEYWORDS if k not in T.KEYWORDS]:
            out.append(f"  t.keywords.remove({mbt_str(k)})")
            tcnt += 1
        for k, v in T.KEYWORDS.items():
            if PT.KEYWORDS.get(k) != v:
                out.append(f"  t.keywords[{mbt_str(k)}] = @core.TokenType::{v.name}")
                tcnt += 1
        from gen_meta import quote_specs, tt_list

        for attr in ["BIT_STRINGS", "BYTE_STRINGS", "HEX_STRINGS", "RAW_STRINGS", "HEREDOC_STRINGS", "UNICODE_STRINGS", "IDENTIFIERS", "QUOTES", "COMMENTS"]:
            if getattr(T, attr) != getattr(PT, attr):
                out.append(f"  t.{attr.lower()} = {quote_specs(getattr(T, attr)).replace('Same(', '@core.QuoteSpec::Same(').replace('Pair(', '@core.QuoteSpec::Pair(')}")
                tcnt += 1
        for attr in ["STRING_ESCAPES", "ESCAPE_FOLLOW_CHARS", "IDENTIFIER_ESCAPES"]:
            if list(getattr(T, attr)) != list(getattr(PT, attr)):
                out.append(f"  t.{attr.lower()} = [{', '.join(mbt_str(x) for x in getattr(T, attr))}]")
                tcnt += 1
        if "BYTE_STRING_ESCAPES" in T.__dict__ or list(T.BYTE_STRING_ESCAPES) != list(PT.BYTE_STRING_ESCAPES):
            if list(T.BYTE_STRING_ESCAPES) != list(T.STRING_ESCAPES) or "BYTE_STRING_ESCAPES" in T.__dict__:
                out.append(f"  t.byte_string_escapes = Some([{', '.join(mbt_str(x) for x in T.BYTE_STRING_ESCAPES)}])")
                tcnt += 1
        if T.VAR_SINGLE_TOKENS != PT.VAR_SINGLE_TOKENS:
            out.append(f"  t.var_single_tokens = [{', '.join(mbt_char(x) for x in sorted(T.VAR_SINGLE_TOKENS))}]")
            tcnt += 1
        for attr in ["HEREDOC_TAG_IS_IDENTIFIER", "STRING_ESCAPES_ALLOWED_IN_RAW_STRINGS", "DROP_UNKNOWN_ESCAPES", "NESTED_COMMENTS", "NUMBERS_CAN_HAVE_DECIMALS"]:
            if getattr(T, attr) != getattr(PT, attr):
                out.append(f"  t.{attr.lower()} = {enc_bool(getattr(T, attr))}")
                tcnt += 1
        if T.HEREDOC_STRING_ALTERNATIVE != PT.HEREDOC_STRING_ALTERNATIVE:
            out.append(f"  t.heredoc_string_alternative = @core.TokenType::{T.HEREDOC_STRING_ALTERNATIVE.name}")
            tcnt += 1
        if T.HINT_START != PT.HINT_START:
            out.append(f"  t.hint_start = {mbt_str(T.HINT_START)}")
            tcnt += 1
        for attr in ["TOKENS_PRECEDING_HINT", "COMMANDS", "COMMAND_PREFIX_TOKENS"]:
            if set(getattr(T, attr)) != set(getattr(PT, attr)):
                out.append(f"  t.{attr.lower()} = {tt_list(getattr(T, attr)).replace('TokenType::', '@core.TokenType::')}")
                tcnt += 1
        if T.NUMERIC_ESCAPES != PT.NUMERIC_ESCAPES:
            items = ", ".join(
                f"{mbt_str(k)}: {{ base: {v[0]}, min_digits: {v[1]}, max_digits: {v[2]}, max_value: {v[3]} }}"
                for k, v in T.NUMERIC_ESCAPES.items()
            )
            out.append(f"  t.numeric_escapes = {{ {items} }}" if items else "  t.numeric_escapes = Map([])")
            tcnt += 1
        if T.NUMERIC_LITERALS != PT.NUMERIC_LITERALS:
            items = ", ".join(f"{mbt_str(k)}: {mbt_str(v)}" for k, v in T.NUMERIC_LITERALS.items())
            out.append(f"  t.numeric_literals = {{ {items} }}" if items else "  t.numeric_literals = Map([])")
            tcnt += 1
        if tcnt == 0:
            out.append("  ignore(t)")
        out.append("}")
        out.append("")
        ddir = os.path.join(ROOT, "src", "dialects", n)
        os.makedirs(ddir, exist_ok=True)
        with open(os.path.join(ddir, "gen_config.mbt"), "w") as f:
            f.write("\n".join(out) + "\n")
        print(n, "parent:", parent or "base")


if __name__ == "__main__":
    gen()
