// Compact argument storage for AST nodes (Python's `Expression.args` dict).

///|
/// The arguments of an expression node: an insertion-ordered map from argument
/// name to value, like the Python `args` dict.
///
/// Nodes have few arguments (rarely more than a handful are set), so this stores
/// keys and values in two small parallel arrays and looks keys up linearly. That
/// takes far less memory per node than a hash map, which matters for large queries:
/// every AST node owns one of these.
pub struct Args {
  priv mut keys : FixedArray[String]
  priv mut vals : FixedArray[Value]
  priv mut len : Int
}

///|
let empty_keys : FixedArray[String] = []

///|
let empty_vals : FixedArray[Value] = []

///|
/// Creates an empty argument map with room for `capacity` arguments.
pub fn Args::new(capacity? : Int = 0) -> Args {
  if capacity <= 0 {
    { keys: empty_keys, vals: empty_vals, len: 0 }
  } else {
    {
      keys: FixedArray::make(capacity, ""),
      vals: FixedArray::make(capacity, Bool(false)),
      len: 0,
    }
  }
}

///|
pub fn Args::from_array(pairs : ArrayView[(String, Value)]) -> Args {
  let a = Args::new(capacity=pairs.length())
  for kv in pairs {
    a.set(kv.0, kv.1)
  }
  a
}

///|
pub fn Args::from_iter(pairs : Iter[(String, Value)]) -> Args {
  let a = Args::new()
  for kv in pairs {
    a.set(kv.0, kv.1)
  }
  a
}

///|
pub fn Args::from_map(m : Map[String, Value]) -> Args {
  let a = Args::new(capacity=m.length())
  for k, v in m {
    a.set(k, v)
  }
  a
}

///|
fn Args::find(self : Args, key : String) -> Int {
  for i in 0..<self.len {
    if self.keys[i] == key {
      return i
    }
  }
  -1
}

///|
pub fn Args::length(self : Args) -> Int {
  self.len
}

///|
pub fn Args::is_empty(self : Args) -> Bool {
  self.len == 0
}

///|
pub fn Args::contains(self : Args, key : String) -> Bool {
  self.find(key) >= 0
}

///|
pub fn Args::get(self : Args, key : String) -> Value? {
  let i = self.find(key)
  if i < 0 {
    None
  } else {
    Some(self.vals[i])
  }
}

///|
/// `args[key]`; aborts when the key is absent (like `Map`).
#alias("_[_]")
pub fn Args::at(self : Args, key : String) -> Value {
  let i = self.find(key)
  if i < 0 {
    abort("Args: missing key \{key}")
  }
  self.vals[i]
}

///|
/// Sets `key` (appending it if new, keeping its position otherwise).
#alias("_[_]=_")
pub fn Args::set(self : Args, key : String, value : Value) -> Unit {
  let i = self.find(key)
  if i >= 0 {
    self.vals[i] = value
    return
  }
  if self.len == self.keys.length() {
    let cap = if self.len < 2 { 2 } else { self.len * 2 }
    let keys = FixedArray::make(cap, "")
    let vals = FixedArray::make(cap, Bool(false))
    for j in 0..<self.len {
      keys[j] = self.keys[j]
      vals[j] = self.vals[j]
    }
    self.keys = keys
    self.vals = vals
  }
  self.keys[self.len] = key
  self.vals[self.len] = value
  self.len += 1
}

///|
/// Removes `key`, keeping the order of the remaining arguments.
pub fn Args::remove(self : Args, key : String) -> Unit {
  let i = self.find(key)
  if i < 0 {
    return
  }
  for j in i..<(self.len - 1) {
    self.keys[j] = self.keys[j + 1]
    self.vals[j] = self.vals[j + 1]
  }
  self.len -= 1
  // drop the reference held by the vacated slot
  self.keys[self.len] = ""
  self.vals[self.len] = Bool(false)
}

///|
pub fn Args::copy(self : Args) -> Args {
  let a = Args::new(capacity=self.len)
  for i in 0..<self.len {
    a.keys[i] = self.keys[i]
    a.vals[i] = self.vals[i]
  }
  a.len = self.len
  a
}

///|
pub fn Args::keys(self : Args) -> Iter[String] {
  let n = self.len
  let keys = self.keys
  (0).until(n).map(i => keys[i])
}

///|
pub fn Args::values(self : Args) -> Iter[Value] {
  let n = self.len
  let vals = self.vals
  (0).until(n).map(i => vals[i])
}

///|
pub fn Args::iter(self : Args) -> Iter[(String, Value)] {
  let n = self.len
  let keys = self.keys
  let vals = self.vals
  (0).until(n).map(i => (keys[i], vals[i]))
}

///|
/// Enables `for key, value in args { ... }`.
pub fn Args::iter2(self : Args) -> Iter2[String, Value] {
  self.iter()
}

///|
pub fn Args::to_array(self : Args) -> Array[(String, Value)] {
  Array::makei(self.len, i => (self.keys[i], self.vals[i]))
}

///|
/// Removes all arguments.
pub fn Args::clear(self : Args) -> Unit {
  self.keys = empty_keys
  self.vals = empty_vals
  self.len = 0
}
