///|
/// A set of token types (Python `set[TokenType]`), stored as a bitmap.
pub struct TokenSet {
  bits : FixedArray[Bool]
}

///|
pub fn TokenSet::new(types : ArrayView[TokenType]) -> TokenSet {
  let bits = FixedArray::make(all_token_types.length(), false)
  for t in types {
    bits[t.id()] = true
  }
  { bits, }
}

///|
pub fn TokenSet::empty() -> TokenSet {
  TokenSet::new([])
}

///|
pub fn TokenSet::contains(self : TokenSet, t : TokenType) -> Bool {
  self.bits[t.id()]
}

///|
pub fn TokenSet::copy(self : TokenSet) -> TokenSet {
  { bits: self.bits.copy() }
}

///|
/// Returns a new set: `self | other`.
pub fn TokenSet::union(self : TokenSet, other : ArrayView[TokenType]) -> TokenSet {
  let s = self.copy()
  for t in other {
    s.bits[t.id()] = true
  }
  s
}

///|
/// Returns a new set: `self | other`.
pub fn TokenSet::union_set(self : TokenSet, other : TokenSet) -> TokenSet {
  let s = self.copy()
  for i in 0..<s.bits.length() {
    if other.bits[i] {
      s.bits[i] = true
    }
  }
  s
}

///|
/// Returns a new set: `self - other`.
pub fn TokenSet::minus(self : TokenSet, other : ArrayView[TokenType]) -> TokenSet {
  let s = self.copy()
  for t in other {
    s.bits[t.id()] = false
  }
  s
}

///|
/// Returns a new set: `self - other`.
pub fn TokenSet::minus_set(self : TokenSet, other : TokenSet) -> TokenSet {
  let s = self.copy()
  for i in 0..<s.bits.length() {
    if other.bits[i] {
      s.bits[i] = false
    }
  }
  s
}

///|
/// Adds `t` in place.
pub fn TokenSet::add(self : TokenSet, t : TokenType) -> Unit {
  self.bits[t.id()] = true
}

///|
/// Removes `t` in place.
pub fn TokenSet::remove(self : TokenSet, t : TokenType) -> Unit {
  self.bits[t.id()] = false
}

///|
pub fn TokenSet::to_array(self : TokenSet) -> Array[TokenType] {
  let out = []
  for i, b in self.bits {
    if b {
      out.push(all_token_types[i])
    }
  }
  out
}

///|
/// A trie keyed by words (Python `new_trie(key.split(" ") for key in ...)`).
pub struct WordTrie {
  children : Map[String, WordTrie]
  mut terminal : Bool
}

///|
pub fn WordTrie::new() -> WordTrie {
  { children: Map([]), terminal: false }
}

///|
pub fn WordTrie::from_keys(keys : Iter[String]) -> WordTrie {
  let t = WordTrie::new()
  for k in keys {
    let mut cur = t
    for w in py_split(k, " ") {
      cur = match cur.children.get(w) {
        Some(c) => c
        None => {
          let c = WordTrie::new()
          cur.children[w] = c
          c
        }
      }
    }
    cur.terminal = true
  }
  t
}

///|
/// Checks whether a single word continues from `self`.
pub fn WordTrie::lookup(self : WordTrie, key : ArrayView[String]) -> (TrieResult, WordTrie) {
  if key.is_empty() {
    return (Failed, self)
  }
  let mut cur = self
  for w in key {
    match cur.children.get(w) {
      Some(c) => cur = c
      None => return (Failed, cur)
    }
  }
  if cur.terminal {
    (Exists, cur)
  } else {
    (Prefix, cur)
  }
}
