///|
/// The Python class name of this kind, e.g. `Select`.
pub fn Kind::name(self : Kind) -> String {
  kind_names[self.id()]
}

///|
/// The lowercase key of this kind, e.g. `select`.
pub fn Kind::key(self : Kind) -> String {
  kind_names[self.id()].to_lower()
}

///|
pub impl Show for Kind with fn output(self, logger) {
  logger.write_string(self.name())
}

///|
/// Whether `self` is `base` or a subclass of `base` (Python `issubclass`).
pub fn Kind::is_a(self : Kind, base : Kind) -> Bool {
  if self == base {
    return true
  }
  let b = base.id()
  for a in kind_ancestors[self.id()] {
    if a == b {
      return true
    }
  }
  false
}

///|
/// Whether `self` is a subclass of any of the given kinds.
pub fn Kind::is_any(self : Kind, bases : ArrayView[Kind]) -> Bool {
  for b in bases {
    if self.is_a(b) {
      return true
    }
  }
  false
}

///|
pub fn Kind::arg_types(self : Kind) -> FixedArray[(String, Bool)] {
  kind_arg_types[self.id()]
}

///|
pub fn Kind::has_arg(self : Kind, key : String) -> Bool {
  for kv in kind_arg_types[self.id()] {
    if kv.0 == key {
      return true
    }
  }
  false
}

///|
pub fn Kind::is_var_len_args(self : Kind) -> Bool {
  kind_var_len[self.id()]
}

///|
pub fn Kind::var_len_arg_key(self : Kind) -> String {
  kind_var_len_arg_key[self.id()]
}

///|
pub fn Kind::is_subquery(self : Kind) -> Bool {
  kind_is_subquery[self.id()]
}

///|
pub fn Kind::is_cast(self : Kind) -> Bool {
  kind_is_cast[self.id()]
}

///|
pub fn Kind::is_data_type(self : Kind) -> Bool {
  kind_is_data_type[self.id()]
}

///|
pub fn Kind::is_primitive(self : Kind) -> Bool {
  kind_is_primitive[self.id()]
}

///|
pub fn Kind::hash_raw_args(self : Kind) -> Bool {
  kind_hash_raw_args[self.id()]
}

///|
/// Whether this kind is an abstract trait (e.g. `Func`, `Binary`) rather than a concrete node.
pub fn Kind::is_trait(self : Kind) -> Bool {
  kind_is_trait[self.id()]
}

///|
/// SQL names of a function kind (first is the canonical one).
pub fn Kind::sql_names(self : Kind) -> FixedArray[String] {
  kind_sql_names[self.id()]
}

///|
pub fn Kind::sql_name(self : Kind) -> String {
  let names = kind_sql_names[self.id()]
  if names.length() > 0 {
    names[0]
  } else {
    camel_to_snake_case(self.name())
  }
}

///|
let kind_by_key : Map[String, Kind] = {
  let m : Map[_, _] = Map([], capacity=all_kinds.length())
  for k in all_kinds {
    m[k.key()] = k
  }
  m
}

///|
/// Looks up a kind by its lowercase key, e.g. `"select"`.
pub fn kind_from_key(key : String) -> Kind? {
  kind_by_key.get(key.to_lower())
}

///|
/// Looks up a kind by its class name, e.g. `"Select"`.
pub fn kind_from_name(name : String) -> Kind? {
  kind_by_key.get(name.to_lower())
}

///|
/// Returns all concrete kinds that are subclasses of `base`.
pub fn subclasses_of(base : Kind) -> Array[Kind] {
  let out = []
  for k in all_kinds {
    if !k.is_trait() && k.is_a(base) {
      out.push(k)
    }
  }
  out
}

///|
pub fn TokenType::name(self : TokenType) -> String {
  token_type_names[self.id()]
}

///|
pub impl Show for TokenType with fn output(self, logger) {
  logger.write_string("TokenType.")
  logger.write_string(self.name())
}

///|
let token_type_by_name : Map[String, TokenType] = {
  let m : Map[_, _] = Map([], capacity=all_token_types.length())
  for t in all_token_types {
    m[t.name()] = t
  }
  m
}

///|
pub fn token_type_from_name(name : String) -> TokenType? {
  token_type_by_name.get(name)
}

///|
pub fn DType::name(self : DType) -> String {
  dtype_names[self.id()]
}

///|
/// The SQL value of a data type, e.g. `DOUBLE PRECISION` style names are kept as in Python.
pub fn DType::value(self : DType) -> String {
  dtype_values[self.id()]
}

///|
pub impl Show for DType with fn output(self, logger) {
  logger.write_string("DType.")
  logger.write_string(self.name())
}

///|
let dtype_by_name : Map[String, DType] = {
  let m : Map[_, _] = Map([], capacity=all_dtypes.length())
  for t in all_dtypes {
    m[t.name()] = t
  }
  m
}

///|
let dtype_by_value : Map[String, DType] = {
  let m : Map[_, _] = Map([], capacity=all_dtypes.length())
  for t in all_dtypes {
    m[t.value()] = t
  }
  m
}

///|
pub fn dtype_from_name(name : String) -> DType? {
  dtype_by_name.get(name)
}

///|
pub fn dtype_from_value(value : String) -> DType? {
  dtype_by_value.get(value)
}
