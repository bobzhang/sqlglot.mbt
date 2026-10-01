// Port of tests/test_time.py

///|
test "TestTime.test_format_time" {
  assert_eq(@core.format_time_opt("", {}), None)
  assert_eq(@core.format_time_opt(" ", {}), Some(" "))
  let mapping = { "a": "b", "aa": "c" }
  assert_eq(@core.format_time_opt("a", mapping), Some("b"))
  assert_eq(@core.format_time_opt("aa", mapping), Some("c"))
  assert_eq(@core.format_time_opt("aaada", mapping), Some("cbdb"))
  assert_eq(@core.format_time_opt("da", mapping), Some("db"))
}

///|
/// Python `\w` for the characters that can appear in time formats.
fn is_word_char(c : Char) -> Bool {
  c == '_' || @core.is_alnum(c)
}

///|
/// `CANONICAL_TIME_FORMAT = re.compile(r"%(?:[mdHIMS]strict|[-:].|.)")` (sqlglot/generators/hive.py):
/// returns `(CANONICAL_TIME_FORMAT.split(fmt), CANONICAL_TIME_FORMAT.findall(fmt))`.
fn canonical_split(fmt : String) -> (Array[String], Array[String]) {
  let chars = fmt.to_array()
  let n = chars.length()
  let parts = []
  let atoms = []
  let part = StringBuilder()
  let mut i = 0
  while i < n {
    if chars[i] == '%' && i + 1 < n && chars[i + 1] != '\n' {
      let c = chars[i + 1]
      let len = if "mdHIMS".contains_char(c) &&
        i + 8 <= n &&
        String::from_array(chars[i + 2:i + 8]) == "strict" {
        8
      } else if (c == '-' || c == ':') && i + 2 < n && chars[i + 2] != '\n' {
        3
      } else {
        2
      }
      parts.push(part.to_string())
      part.reset()
      atoms.push(String::from_array(chars[i:i + len]))
      i += len
    } else {
      part.write_char(chars[i])
      i += 1
    }
  }
  parts.push(part.to_string())
  (parts, atoms)
}

///|
/// `KNOWN_CANONICAL_ATOM = re.compile(r"%(?:[mdHIMS]strict|[-:].|[\w%])")`, fullmatch.
fn known_canonical_atom(atom : String) -> Bool {
  let chars = atom.to_array()
  match chars {
    ['%', c, .. rest] if "mdHIMS".contains_char(c) &&
      String::from_array(rest) == "strict" => true
    ['%', '-' | ':', c] => c != '\n'
    ['%', c] => is_word_char(c) || c == '%'
    _ => false
  }
}

///|
/// `re.search(r"%[mdHIMS](?!strict)\w", value)` is not None.
fn has_lax_followed_by_word(value : String) -> Bool {
  let chars = value.to_array()
  let n = chars.length()
  for i in 0..<(n - 2) {
    if chars[i] == '%' && "mdHIMS".contains_char(chars[i + 1]) {
      let rest = String::from_array(chars[i + 2:])
      if !rest.has_prefix("strict") && is_word_char(chars[i + 2]) {
        return true
      }
    }
  }
  false
}

///|
test "TestTime.test_canonical_time_format_vocabulary" {
  let lax = ["%m", "%d", "%H", "%I", "%M", "%S"]
  let names = @core.dialect_names()
  names.sort()
  for name in names {
    let d = @sqlglot.dialect(name)
    let values = []
    for _, v in d.cfg.time_mapping {
      values.push(v)
    }
    for _, v in d.cfg.format_mapping {
      values.push(v)
    }
    for value in values {
      let (parts, atoms) = canonical_split(value)
      for part in parts {
        assert_false(
          part.contains("%"),
          msg="\{name}: unconsumed '%' in \{value}",
        )
      }
      for atom in atoms {
        assert_true(
          known_canonical_atom(atom),
          msg="\{name}: unexpected canonical atom \{atom} in \{value}",
        )
      }
      assert_false(
        has_lax_followed_by_word(value),
        msg="\{name}: a lax specifier directly followed by a word character in \{value}",
      )
    }
    if d.cfg.time_mapping.get("MM") == Some("%mstrict") {
      for key, _ in d.cfg.inverse_time_mapping {
        let (_, atoms) = canonical_split(key)
        if atoms.length() > 1 {
          assert_false(
            atoms.iter().any(a => lax.contains(a)),
            msg="\{name}: composite inverse key \{key} contains a lax specifier",
          )
        }
      }
    }
  }
}

///|
test "TestTime.test_subsecond_precision" {
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.123456+00:00"))
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.000123+00:00"))
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.000001+00:00"))
  assert_eq(3, @core.subsecond_precision("2023-01-01 12:13:14.123+00:00"))
  assert_eq(0, @core.subsecond_precision("2023-01-01 12:13:14+00:00"))
  assert_eq(0, @core.subsecond_precision("2023-01-01 12:13:14"))
  assert_eq(0, @core.subsecond_precision("garbage"))
}

///|
test "TestTime.test_subsecond_precision_python311" {
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.123456789+00:00"))
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.12345+00:00"))
  assert_eq(6, @core.subsecond_precision("2023-01-01 12:13:14.1234+00:00"))
  assert_eq(3, @core.subsecond_precision("2023-01-01 12:13:14.12+00:00"))
  assert_eq(3, @core.subsecond_precision("2023-01-01 12:13:14.1+00:00"))
}
