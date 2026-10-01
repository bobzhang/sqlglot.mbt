// Emulation of CPython's `set` iteration order (Objects/setobject.c). The order only
// depends on the hashes, which are deterministic for numbers, None and tuples of them;
// for other values (e.g. strings, whose hash is randomized per process) insertion order
// is used instead.

///|
/// CPython 64-bit `tuplehash` (xxHash based).
fn tuple_hash(items : Array[Value]) -> Int64? {
  let prime1 = 11400714785074694791UL
  let prime2 = 14029467366897019727UL
  let prime5 = 2870177450012600261UL
  let mut acc = prime5
  for item in items {
    guard cpython_hash(item) is Some(h) else { return None }
    let lane = h.reinterpret_as_uint64()
    acc = acc + lane * prime2
    acc = (acc << 31) | (acc >> 33)
    acc = acc * prime1
  }
  acc = acc + (items.length().to_uint64() ^ (prime5 ^ 3527539UL))
  if acc == 0xffffffffffffffffUL {
    return Some(1546275796L)
  }
  Some(acc.reinterpret_as_int64())
}

///|
/// CPython's `hash()` for values whose hash is not randomized.
fn cpython_hash(v : Value) -> Int64? {
  match v {
    Null => Some(4238894112L)
    Bool(b) => Some(if b { 1L } else { 0L })
    Int(i) => {
      let m = hash_modulus.reinterpret_as_int64()
      let r = if i >= 0L { i % m } else { -(-i % m) }
      Some(if r == -1L { -2L } else { r })
    }
    Float(d) =>
      if d == d.floor() && d.abs() < 9.2e18 {
        cpython_hash(Int(d.to_int64()))
      } else {
        Some(hash_double(d))
      }
    Tuple(items) => tuple_hash(items)
    _ => None
  }
}

///|
/// A simulated CPython set table: slots hold indices into `keys` (-1: empty).
priv struct SetSim {
  keys : Array[Value]
  key_ids : Array[String]
  hashes : Array[Int64]
  mut table : Array[Int]
  mut mask : Int
  mut fill : Int
}

///|
fn SetSim::new() -> SetSim {
  {
    keys: [],
    key_ids: [],
    hashes: [],
    table: Array::make(8, -1),
    mask: 7,
    fill: 0,
  }
}

///|
let linear_probes : Int = 9

///|
fn SetSim::insert_clean(
  self : SetSim,
  table : Array[Int],
  mask : Int,
  idx : Int,
) -> Unit {
  let hash = self.hashes[idx].reinterpret_as_uint64()
  let mut perturb = hash
  let mut i = (hash & mask.to_uint64()).to_int()
  for ;; {
    if table[i] == -1 {
      table[i] = idx
      return
    }
    if i + linear_probes <= mask {
      for j in 1..<=linear_probes {
        if table[i + j] == -1 {
          table[i + j] = idx
          return
        }
      }
    }
    perturb = perturb >> 5
    i = ((i.to_uint64() * 5UL + 1UL + perturb) & mask.to_uint64()).to_int()
  }
}

///|
fn SetSim::resize(self : SetSim, minused : Int) -> Unit {
  let mut newsize = 8
  while newsize <= minused {
    newsize = newsize << 1
  }
  let old = self.table
  self.mask = newsize - 1
  self.table = Array::make(newsize, -1)
  for slot in old {
    if slot != -1 {
      self.insert_clean(self.table, self.mask, slot)
    }
  }
  self.fill = self.keys.length()
}

///|
/// `set_add_entry`: probes like `insert_clean` but stops at an equal key.
fn SetSim::add(self : SetSim, key : Value, id : String, hash : Int64) -> Unit {
  let h = hash.reinterpret_as_uint64()
  let mask = self.mask
  let mut perturb = h
  let mut i = (h & mask.to_uint64()).to_int()
  for ;; {
    let probes = if i + linear_probes <= mask { linear_probes } else { 0 }
    for j in 0..<=probes {
      let slot = self.table[i + j]
      if slot == -1 {
        let idx = self.keys.length()
        self.keys.push(key)
        self.key_ids.push(id)
        self.hashes.push(hash)
        self.table[i + j] = idx
        self.fill += 1
        if self.fill * 5 >= mask * 3 {
          let used = self.keys.length()
          self.resize(if used > 50000 { used * 2 } else { used * 4 })
        }
        return
      }
      if self.hashes[slot] == hash && self.key_ids[slot] == id {
        return
      }
    }
    perturb = perturb >> 5
    i = ((i.to_uint64() * 5UL + 1UL + perturb) & mask.to_uint64()).to_int()
  }
}

///|
fn SetSim::items(self : SetSim) -> Array[Value] {
  self.table.filter(s => s != -1).map(s => self.keys[s])
}

///|
/// Builds a simulated set from values (Python `set(iterable)`), or `None` when a hash
/// is not deterministic.
fn SetSim::from_values(values : Array[Value]) -> SetSim? raise PyException {
  let s = SetSim::new()
  for v in values {
    let id = hash_key(v)
    guard cpython_hash(v) is Some(h) else { return None }
    s.add(v, id, h)
  }
  Some(s)
}

///|
/// `set_merge(so, other)` where `so` is a fresh copy target or an existing set.
fn SetSim::merge(self : SetSim, other : SetSim) -> Unit {
  let used = other.keys.length()
  if used == 0 {
    return
  }
  if (self.fill + used) * 5 >= self.mask * 3 {
    self.resize((self.keys.length() + used) * 2)
  }
  if self.fill == 0 && self.mask == other.mask {
    // copy the table as is
    for i, slot in other.table {
      if slot != -1 {
        let idx = self.keys.length()
        self.keys.push(other.keys[slot])
        self.key_ids.push(other.key_ids[slot])
        self.hashes.push(other.hashes[slot])
        self.table[i] = idx
      }
    }
    self.fill = used
    return
  }
  if self.fill == 0 {
    for slot in other.table {
      if slot != -1 {
        let idx = self.keys.length()
        self.keys.push(other.keys[slot])
        self.key_ids.push(other.key_ids[slot])
        self.hashes.push(other.hashes[slot])
        self.insert_clean(self.table, self.mask, idx)
      }
    }
    self.fill = used
    return
  }
  for slot in other.table {
    if slot != -1 {
      self.add(other.keys[slot], other.key_ids[slot], other.hashes[slot])
    }
  }
}

///|
/// Distinct values, first occurrence wins.
fn dedupe(values : Array[Value]) -> Array[Value] raise PyException {
  let seen : Map[String, Unit] = {}
  let unique = []
  for v in values {
    let k = hash_key(v)
    if !seen.contains(k) {
      seen[k] = ()
      unique.push(v)
    }
  }
  unique
}

///|
/// Python `set(values)` in CPython's iteration order (insertion order when the hashes
/// are not deterministic).
pub fn py_set(values : Array[Value]) -> Array[Value] raise PyException {
  match SetSim::from_values(values) {
    Some(s) => s.items()
    None => dedupe(values)
  }
}

///|
/// Python `list(set(a).union(set(b)))`.
pub fn py_set_union(
  a : Array[Value],
  b : Array[Value],
) -> Array[Value] raise PyException {
  match (SetSim::from_values(a), SetSim::from_values(b)) {
    (Some(sa), Some(sb)) => {
      // set_copy(sa) is a merge into an empty set, then the union merges sb
      let result = SetSim::new()
      result.merge(sa)
      result.merge(sb)
      result.items()
    }
    _ => dedupe(a + b)
  }
}
