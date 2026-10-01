///|
/// A character trie, mirroring `sqlglot.trie`.
pub struct Trie {
  children : Map[Char, Trie]
  mut terminal : Bool
}

///|
pub(all) enum TrieResult {
  Failed
  Prefix
  Exists
} derive(Eq, Debug)

///|
pub fn Trie::new() -> Trie {
  { children: Map([]), terminal: false }
}

///|
/// Creates a new trie out of a collection of keywords.
pub fn new_trie(keywords : Iter[String]) -> Trie {
  let trie = Trie::new()
  for key in keywords {
    trie.add(key)
  }
  trie
}

///|
pub fn Trie::add(self : Trie, key : String) -> Unit {
  let mut current = self
  for c in key {
    current = match current.children.get(c) {
      Some(t) => t
      None => {
        let t = Trie::new()
        current.children[c] = t
        t
      }
    }
  }
  current.terminal = true
}

///|
pub fn Trie::get(self : Trie, c : Char) -> Trie? {
  self.children.get(c)
}

///|
/// Checks whether a key is in a trie.
pub fn in_trie(trie : Trie, key : ArrayView[String]) -> (TrieResult, Trie) {
  if key.is_empty() {
    return (Failed, trie)
  }
  let mut current = trie
  for part in key {
    for c in part {
      match current.children.get(c) {
        Some(t) => current = t
        None => return (Failed, current)
      }
    }
  }
  if current.terminal {
    (Exists, current)
  } else {
    (Prefix, current)
  }
}

///|
/// Checks whether a key (sequence of chars) is in a trie.
pub fn in_trie_chars(trie : Trie, key : ArrayView[Char]) -> (TrieResult, Trie) {
  if key.is_empty() {
    return (Failed, trie)
  }
  let mut current = trie
  for c in key {
    match current.children.get(c) {
      Some(t) => current = t
      None => return (Failed, current)
    }
  }
  if current.terminal {
    (Exists, current)
  } else {
    (Prefix, current)
  }
}
