// Port of sqlglot/time.py

///|
/// Converts a time string given a mapping (Python `format_time`). Returns
/// `None` for an empty string.
pub fn format_time_opt(
  string : String,
  mapping : Map[String, String],
  trie? : Trie,
) -> String? {
  if string.is_empty() {
    return None
  }
  let s = string.to_array()
  let size = s.length()
  let trie = match trie {
    Some(t) if !t.children.is_empty() || t.terminal => t
    _ => trie_of_keys(mapping)
  }
  let mut start = 0
  let mut end = 1
  let mut current = trie
  let chunks : Array[String] = []
  let mut sym : String? = None
  while end <= size {
    let mut chars = String::from_array(s[start:end])
    let (result, next) = in_trie_chars(current, [s[end - 1]])
    current = next
    if result == Failed {
      match sym {
        Some(sy) => {
          end -= 1
          chars = sy
          sym = None
        }
        None => {
          chars = s[start].to_string()
          end = start + 1
        }
      }
      start += py_len(chars)
      chunks.push(chars)
      current = trie
    } else if result == Exists {
      sym = Some(chars)
    }
    end += 1
    if result != Failed && end > size {
      chunks.push(chars)
    }
  }
  let sb = StringBuilder()
  for c in chunks {
    sb.write_string(
      match mapping.get(c) {
        Some(m) => m
        None => c
      },
    )
  }
  Some(sb.to_string())
}

///|
/// `format_time` returning Python's `str(None)` for empty input, which is what
/// `exp.Literal.string(format_time(...))` produces.
pub fn format_time(string : String, mapping : Map[String, String], trie : Trie) -> String {
  match format_time_opt(string, mapping, trie~) {
    Some(s) => s
    None => "None"
  }
}
