// Python's `str` case conversions and character classes, driven by the tables generated
// from CPython's Unicode database in gen_unicode.mbt (tools/gen_unicode_tables.py).

///|
/// Whether `c` lies in one of the flattened `[start, end]` ranges of `tbl`.
fn in_ranges(tbl : FixedArray[Int], c : Int) -> Bool {
  let n = tbl.length() / 2
  // First range whose start is > c.
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) / 2
    if tbl[2 * mid] <= c {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo > 0 && c <= tbl[2 * (lo - 1) + 1]
}

///|
/// The single code point mapping of `c` in `[start, end, delta, stride]` runs, or -1.
fn run_lookup(runs : FixedArray[Int], c : Int) -> Int {
  let n = runs.length() / 4
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) / 2
    if runs[4 * mid] <= c {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo == 0 {
    return -1
  }
  let r = 4 * (lo - 1)
  if c <= runs[r + 1] && (c - runs[r]) % runs[r + 3] == 0 {
    c + runs[r + 2]
  } else {
    -1
  }
}

///|
/// Index of `c` in the sorted `cps`, or -1.
fn sorted_index(cps : FixedArray[Int], c : Int) -> Int {
  let mut lo = 0
  let mut hi = cps.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if cps[mid] < c {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo < cps.length() && cps[lo] == c {
    lo
  } else {
    -1
  }
}

///|
/// Writes the full case mapping of `c` (described by the given tables) to `sb`.
fn write_case_mapped(
  sb : StringBuilder,
  c : Char,
  runs : FixedArray[Int],
  multi_cps : FixedArray[Int],
  multi_strs : FixedArray[String],
) -> Unit {
  let i = c.to_int()
  let m = run_lookup(runs, i)
  if m >= 0 {
    sb.write_char(Int::unsafe_to_char(m))
    return
  }
  let k = sorted_index(multi_cps, i)
  if k >= 0 {
    sb.write_string(multi_strs[k])
  } else {
    sb.write_char(c)
  }
}

///|
/// The first code point of the full case mapping of `c`.
fn first_case_mapped(
  c : Char,
  runs : FixedArray[Int],
  multi_cps : FixedArray[Int],
  multi_strs : FixedArray[String],
) -> Char {
  let i = c.to_int()
  let m = run_lookup(runs, i)
  if m >= 0 {
    return Int::unsafe_to_char(m)
  }
  let k = sorted_index(multi_cps, i)
  if k >= 0 {
    multi_strs[k].get_char(0).unwrap()
  } else {
    c
  }
}

///|
fn is_ascii_string(s : String) -> Bool {
  for i in 0..<s.length() {
    if s.code_unit_at(i).to_int() >= 128 {
      return false
    }
  }
  true
}

///|
/// Python `str.upper()` (full Unicode case mapping, e.g. `ß` -> `SS`).
pub fn py_upper(s : String) -> String {
  if is_ascii_string(s) {
    return s.to_upper()
  }
  let sb = StringBuilder()
  for c in s {
    write_case_mapped(
      sb, c, uc_upper_runs, uc_upper_multi_cps, uc_upper_multi_strs,
    )
  }
  sb.to_string()
}

///|
/// Python `str.lower()` (full Unicode case mapping, e.g. `İ` -> `i̇`, including the
/// Final_Sigma rule for `Σ`).
pub fn py_lower(s : String) -> String {
  if is_ascii_string(s) {
    return s.to_lower()
  }
  if !s.contains_char('Σ') {
    let sb = StringBuilder()
    for c in s {
      write_case_mapped(
        sb, c, uc_lower_runs, uc_lower_multi_cps, uc_lower_multi_strs,
      )
    }
    return sb.to_string()
  }
  let chars = s.to_array()
  let sb = StringBuilder()
  for i, c in chars {
    if c == 'Σ' {
      sb.write_char(capital_sigma_lower(chars, i))
    } else {
      write_case_mapped(
        sb, c, uc_lower_runs, uc_lower_multi_cps, uc_lower_multi_strs,
      )
    }
  }
  sb.to_string()
}

///|
/// CPython's `handle_capital_sigma`: `Σ` lowers to `ς` when it is preceded by a cased
/// letter and not followed by one (skipping case-ignorable characters in both directions).
fn capital_sigma_lower(chars : Array[Char], i : Int) -> Char {
  let mut j = i - 1
  while j >= 0 && in_ranges(uc_case_ignorable, chars[j].to_int()) {
    j -= 1
  }
  let mut final_sigma = j >= 0 && in_ranges(uc_cased, chars[j].to_int())
  if final_sigma && i + 1 < chars.length() {
    let mut k = i + 1
    while k < chars.length() && in_ranges(uc_case_ignorable, chars[k].to_int()) {
      k += 1
    }
    final_sigma = k == chars.length() || !in_ranges(uc_cased, chars[k].to_int())
  }
  if final_sigma {
    'ς'
  } else {
    'σ'
  }
}

///|
/// Python `str.casefold()` (full Unicode case folding, e.g. `ß` -> `ss`).
pub fn py_casefold(s : String) -> String {
  if is_ascii_string(s) {
    return s.to_lower()
  }
  let sb = StringBuilder()
  for c in s {
    write_case_mapped(
      sb, c, uc_fold_runs, uc_fold_multi_cps, uc_fold_multi_strs,
    )
  }
  sb.to_string()
}

///|
/// The first code point of `str(c).upper()` (CPython's `_PyUnicode_ToUppercase`).
pub fn char_upper(c : Char) -> Char {
  if c.to_int() < 128 {
    return c.to_ascii_uppercase()
  }
  first_case_mapped(c, uc_upper_runs, uc_upper_multi_cps, uc_upper_multi_strs)
}

///|
/// The first code point of `str(c).lower()` (CPython's `_PyUnicode_ToLowercase`, which is
/// also `re`'s case-insensitive key `_sre.unicode_tolower`).
pub fn char_lower(c : Char) -> Char {
  if c.to_int() < 128 {
    return c.to_ascii_lowercase()
  }
  first_case_mapped(c, uc_lower_runs, uc_lower_multi_cps, uc_lower_multi_strs)
}

///|
/// Python `str.isspace()` for one character (also `re`'s `\s`).
pub fn is_space(c : Char) -> Bool {
  let i = c.to_int()
  if i < 128 {
    i == 32 || (i >= 9 && i <= 13) || (i >= 0x1C && i <= 0x1F)
  } else {
    in_ranges(uc_space, i)
  }
}

///|
/// Python `str.isalpha()` for one character.
pub fn is_alpha(c : Char) -> Bool {
  if c.to_int() < 128 {
    c.is_ascii_alphabetic()
  } else {
    in_ranges(uc_alpha, c.to_int())
  }
}

///|
/// Python `str.isdecimal()` for one character (also `re`'s `\d`).
pub fn is_decimal(c : Char) -> Bool {
  if c.to_int() < 128 {
    c >= '0' && c <= '9'
  } else {
    in_ranges(uc_decimal, c.to_int())
  }
}

///|
/// The value of a decimal digit (`unicodedata.decimal`), or -1.
pub fn decimal_value(c : Char) -> Int {
  let i = c.to_int()
  if i < 128 {
    return if c >= '0' && c <= '9' { i - '0'.to_int() } else { -1 }
  }
  let tbl = uc_decimal
  let n = tbl.length() / 2
  let mut lo = 0
  let mut hi = n
  while lo < hi {
    let mid = (lo + hi) / 2
    if tbl[2 * mid] <= i {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  // Decimal digits come in contiguous runs of ten starting at zero.
  if lo > 0 && i <= tbl[2 * (lo - 1) + 1] {
    (i - tbl[2 * (lo - 1)]) % 10
  } else {
    -1
  }
}

///|
/// Python `str.isdigit()` for one character (includes e.g. superscripts like `²`).
/// See `is_digit_char` for the ASCII `0-9` test.
pub fn is_py_digit(c : Char) -> Bool {
  if c.to_int() < 128 {
    c >= '0' && c <= '9'
  } else {
    in_ranges(uc_digit, c.to_int())
  }
}

///|
/// Python `str.isnumeric()` for one character.
pub fn is_numeric(c : Char) -> Bool {
  if c.to_int() < 128 {
    c >= '0' && c <= '9'
  } else {
    in_ranges(uc_numeric, c.to_int())
  }
}

///|
/// ASCII `0-9` (Python code testing membership in `"0123456789"`).
pub fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Python `str.isalnum()` for one character.
pub fn is_alnum(c : Char) -> Bool {
  if c.to_int() < 128 {
    c.is_ascii_alphabetic() || c.is_ascii_digit()
  } else {
    is_alpha(c) || is_decimal(c) || is_py_digit(c) || is_numeric(c)
  }
}

///|
/// `re`'s `\w` for one character (`str.isalnum()` or `_`).
pub fn is_word_char(c : Char) -> Bool {
  c == '_' || is_alnum(c)
}

///|
/// Python `str.islower()` for one character.
pub fn is_lower_char(c : Char) -> Bool {
  if c.to_int() < 128 {
    c.is_ascii_lowercase()
  } else {
    in_ranges(uc_lower, c.to_int())
  }
}

///|
/// Python `str.isupper()` for one character.
pub fn is_upper_char(c : Char) -> Bool {
  if c.to_int() < 128 {
    c.is_ascii_uppercase()
  } else {
    in_ranges(uc_upper, c.to_int())
  }
}

///|
/// Python `str.isprintable()` for one character.
pub fn is_printable(c : Char) -> Bool {
  let i = c.to_int()
  if i < 128 {
    i >= 32 && i < 127
  } else {
    in_ranges(uc_printable, i)
  }
}

///|
/// Python `str.isidentifier()` for a one-character string (XID_Start or `_`).
pub fn is_identifier_char(c : Char) -> Bool {
  if c.to_int() < 128 {
    c == '_' || c.is_ascii_alphabetic()
  } else {
    in_ranges(uc_id_start, c.to_int())
  }
}

///|
/// Whether `c` may continue a Python identifier (XID_Continue).
pub fn is_identifier_continue(c : Char) -> Bool {
  if c.to_int() < 128 {
    c == '_' || c.is_ascii_alphabetic() || c.is_ascii_digit()
  } else {
    in_ranges(uc_id_continue, c.to_int())
  }
}

///|
/// Python `str.isidentifier()`.
pub fn str_is_identifier(s : String) -> Bool {
  let mut first = true
  for c in s {
    if first {
      if !is_identifier_char(c) {
        return false
      }
      first = false
    } else if !is_identifier_continue(c) {
      return false
    }
  }
  !first
}

///|
/// Whether a pattern character `p` matches `c` under `re.IGNORECASE` (Unicode mode), as
/// compiled by `re`: uncased characters match exactly; cased ones compare by
/// `_sre.unicode_tolower`, also accepting `re`'s extra equivalences (e.g. `s`/`ſ`, `σ`/`ς`).
pub fn re_ignorecase_char_eq(p : Char, c : Char) -> Bool {
  if p == c {
    return true
  }
  if p.to_int() < 128 && c.to_int() < 128 {
    return p.to_ascii_lowercase() == c.to_ascii_lowercase() &&
      p.is_ascii_alphabetic()
  }
  if !in_ranges(uc_sre_cased, p.to_int()) {
    return false
  }
  let lo = char_lower(p).to_int()
  let lc = char_lower(c).to_int()
  if lo == lc {
    return true
  }
  // Extra equivalences, as `[lower, n, alt_1 .. alt_n]` groups.
  let tbl = uc_sre_extra_cases
  let mut k = 0
  while k < tbl.length() {
    let n = tbl[k + 1]
    if tbl[k] == lo {
      for m in 0..<n {
        if tbl[k + 2 + m] == lc {
          return true
        }
      }
      return false
    }
    k += 2 + n
  }
  false
}
