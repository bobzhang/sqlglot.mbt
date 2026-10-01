// Port of sqlglot/schema.py.

///|
/// A node of a nested schema mapping (Python's nested dicts of the schema).
pub(all) enum SchemaNode {
  /// A nested mapping: `{name: node}`.
  Dict(Map[String, SchemaNode])
  /// A column type given as a string, e.g. `"INT"`.
  Type(String)
  /// A column type given as a `DataType` expression.
  DataType(@core.Expr)
  /// Python `None`, e.g. a column mapping built from a list of names.
  Null
  /// A set of column names (used for the `visible` mapping).
  Names(Array[String])
}

///|
/// Builds a schema mapping from JSON: objects become `Dict`s, strings become `Type`s,
/// `null` becomes `Null` and arrays of strings become `Names`.
/// `{"__nonnull__": "INT"}` builds a non-nullable `DataType`.
pub fn SchemaNode::from_json(json : Json) -> SchemaNode raise @core.SqlglotError {
  match json {
    Object(m) => {
      if m.length() == 1 {
        match m.get("__nonnull__") {
          Some(String(t)) => {
            let dt = @core.datatype_from_str(t)
            dt.set("nullable", false)
            return DataType(dt)
          }
          _ => ()
        }
      }
      let out : Map[String, SchemaNode] = Map([])
      for k, v in m {
        out[k] = SchemaNode::from_json(v)
      }
      Dict(out)
    }
    String(s) => Type(s)
    Null => Null
    Array(a) =>
      Names(
        a.map(x => match x {
          String(s) => s
          _ => ""
        }),
      )
    _ => Null
  }
}

///|
/// Parses a JSON string into a schema mapping (see `SchemaNode::from_json`).
pub fn schema_from_json_string(
  s : String,
) -> Map[String, SchemaNode] raise @core.SqlglotError {
  let json = @json.parse(s) catch {
    _ => raise @core.SchemaError("Invalid JSON schema")
  }
  match SchemaNode::from_json(json) {
    Dict(m) => m
    _ => raise @core.SchemaError("Invalid JSON schema")
  }
}

///|
/// Python `dict_depth`.
fn dict_depth(d : SchemaNode) -> Int {
  match d {
    Dict(m) =>
      match m.values().next() {
        Some(v) => 1 + dict_depth(v)
        None => 1
      }
    _ => 0
  }
}

///|
fn map_depth(m : Map[String, SchemaNode]) -> Int {
  dict_depth(Dict(m))
}

///|
/// Python `flatten_schema`.
fn flatten_schema(
  schema : Map[String, SchemaNode],
  depth? : Int,
  keys? : Array[String] = [],
) -> Array[Array[String]] {
  let tables = []
  let depth = match depth {
    Some(d) => d
    None => map_depth(schema) - 1
  }
  for k, v in schema {
    match v {
      Dict(sub) if depth != 1 => {
        if depth >= 2 {
          for t in flatten_schema(sub, depth=depth - 1, keys=keys + [k]) {
            tables.push(t)
          }
        }
      }
      _ => tables.push(keys + [k])
    }
  }
  tables
}

///|
/// Python `nested_get`: `path` is a list of (name, key) pairs.
fn nested_get(
  d : Map[String, SchemaNode],
  path : Array[(String, String)],
  raise_on_missing? : Bool = true,
) -> SchemaNode? raise @core.SqlglotError {
  let mut result : SchemaNode = Dict(d)
  for p in path {
    let (name, key) = p
    let next = match result {
      Dict(m) => m.get(key)
      _ => None
    }
    match next {
      Some(Null) | None => {
        if raise_on_missing {
          let name = if name == "this" { "table" } else { name }
          raise @core.ValueError("Unknown \{name}: \{key}")
        }
        return None
      }
      Some(v) => result = v
    }
  }
  Some(result)
}

///|
/// Python `nested_set`.
fn nested_set(
  d : Map[String, SchemaNode],
  keys : ArrayView[String],
  value : SchemaNode,
) -> Unit {
  if keys.is_empty() {
    return
  }
  let mut subd = d
  for i in 0..<(keys.length() - 1) {
    let key = keys[i]
    subd = match subd.get(key) {
      Some(Dict(m)) => m
      Some(_) => return
      None => {
        let m : Map[String, SchemaNode] = Map([])
        subd[key] = Dict(m)
        m
      }
    }
  }
  subd[keys[keys.length() - 1]] = value
}

///|
/// A trie keyed by name parts (Python `new_trie` over tuples of strings).
priv struct PartTrie {
  children : Map[String, PartTrie]
  mut terminal : Bool
}

///|
fn PartTrie::new() -> PartTrie {
  { children: {}, terminal: false }
}

///|
fn PartTrie::add(self : PartTrie, key : ArrayView[String]) -> Unit {
  let mut current = self
  for part in key {
    current = match current.children.get(part) {
      Some(t) => t
      None => {
        let t = PartTrie::new()
        current.children[part] = t
        t
      }
    }
  }
  current.terminal = true
}

///|
fn PartTrie::lookup(
  self : PartTrie,
  key : ArrayView[String],
) -> (@core.TrieResult, PartTrie) {
  if key.is_empty() {
    return (Failed, self)
  }
  let mut current = self
  for part in key {
    match current.children.get(part) {
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

///|
/// All keys stored below this trie node (Python `flatten_schema(trie)`).
fn PartTrie::flatten(self : PartTrie) -> Array[Array[String]] {
  let out = []
  fn go(t : PartTrie, prefix : Array[String]) -> Unit {
    if t.terminal && !prefix.is_empty() {
      out.push(prefix)
    }
    for k, v in t.children {
      go(v, prefix + [k])
    }
  }

  go(self, [])
  out
}

///|
fn trie_from_mapping(m : Map[String, SchemaNode], depth : Int) -> PartTrie {
  let trie = PartTrie::new()
  for t in flatten_schema(m, depth~) {
    let r = t.copy()
    r.rev_in_place()
    trie.add(r)
  }
  trie
}

///|
let table_parts_names : Array[String] = ["this", "db", "catalog"]

///|
/// Schema based on a nested mapping (Python `MappingSchema`).
pub struct MappingSchema {
  mut mapping : Map[String, SchemaNode]
  priv mut mapping_trie : PartTrie
  mut udf_mapping : Map[String, SchemaNode]
  priv mut udf_trie : PartTrie
  visible : Map[String, SchemaNode]
  normalize : Bool
  dialect : @core.Dialect
  priv mut depth_ : Int
  priv mut supported_table_args_ : Array[String]
  priv type_mapping_cache : Map[String, @core.Expr]
  /// Python `_find_cache`: `find` results by (table, ensure_data_types).
  priv find_cache : Map[(@core.Expr, Bool), FindResult]
}

///|
/// A cached `MappingSchema.find` result: the raw column mapping, or the column types.
priv enum FindResult {
  Raw(Map[String, SchemaNode]?)
  Types(Map[String, @core.Expr?]?)
}

///|
/// The number of entries of the `find` cache (Python `len(schema._find_cache)`).
pub fn MappingSchema::find_cache_size(self : MappingSchema) -> Int {
  self.find_cache.length()
}

///|
/// Creates a mapping schema.
///
/// `schema` is a mapping in one of the forms `{table: {col: type}}`,
/// `{db: {table: {col: type}}}` or `{catalog: {db: {table: {col: type}}}}`.
pub fn MappingSchema::new(
  schema? : Map[String, SchemaNode] = {},
  visible? : Map[String, SchemaNode] = {},
  dialect? : @core.Dialect,
  normalize? : Bool = true,
  udf_mapping? : Map[String, SchemaNode] = {},
) -> MappingSchema raise @core.SqlglotError {
  let dialect = match dialect {
    Some(d) => d
    None => @core.base_dialect()
  }
  let s : MappingSchema = {
    mapping: {},
    mapping_trie: PartTrie::new(),
    udf_mapping: {},
    udf_trie: PartTrie::new(),
    visible,
    normalize,
    dialect,
    depth_: 0,
    supported_table_args_: [],
    type_mapping_cache: {},
    find_cache: {},
  }
  let mapping = if normalize { s.normalize_mapping(schema) } else { schema }
  let udfs = if normalize { s.normalize_udfs(udf_mapping) } else { udf_mapping }
  s.mapping = mapping
  s.mapping_trie = trie_from_mapping(mapping, s.depth())
  s.udf_mapping = udfs
  s.udf_trie = trie_from_mapping(udfs, s.udf_depth())
  s
}

///|
/// Python `ensure_schema`: builds a `MappingSchema` from an optional mapping.
pub fn ensure_schema(
  schema? : MappingSchema,
  mapping? : Map[String, SchemaNode],
  dialect? : @core.Dialect,
) -> MappingSchema raise @core.SqlglotError {
  match schema {
    Some(s) => s
    None =>
      match mapping {
        Some(m) => MappingSchema::new(schema=m, dialect?)
        None => MappingSchema::new(dialect?)
      }
  }
}

///|
/// Returns a copy of this schema, optionally with a new mapping.
pub fn MappingSchema::copy(
  self : MappingSchema,
  schema? : Map[String, SchemaNode],
) -> MappingSchema raise @core.SqlglotError {
  MappingSchema::new(
    schema=match schema {
      Some(s) => s
      None => self.mapping.copy()
    },
    visible=self.visible.copy(),
    dialect=self.dialect,
    normalize=self.normalize,
    udf_mapping=self.udf_mapping.copy(),
  )
}

///|
/// Whether the schema is empty.
pub fn MappingSchema::empty(self : MappingSchema) -> Bool {
  self.mapping.is_empty()
}

///|
pub fn MappingSchema::depth(self : MappingSchema) -> Int {
  if !self.empty() && self.depth_ == 0 {
    self.depth_ = map_depth(self.mapping) - 1
  }
  self.depth_
}

///|
fn MappingSchema::udf_depth(self : MappingSchema) -> Int {
  map_depth(self.udf_mapping)
}

///|
/// Table arguments this schema supports, e.g. `["this", "db", "catalog"]`.
pub fn MappingSchema::supported_table_args(
  self : MappingSchema,
) -> Array[String] raise @core.SqlglotError {
  if self.supported_table_args_.is_empty() && !self.mapping.is_empty() {
    let depth = self.depth()
    if depth == 0 {
      self.supported_table_args_ = []
    } else if depth >= 1 && depth <= 3 {
      self.supported_table_args_ = table_parts_names[0:depth].to_owned()
    } else {
      raise @core.SchemaError("Invalid mapping shape. Depth: \{depth}")
    }
  }
  self.supported_table_args_
}

///|
fn table_parts(table : @core.Expr) -> Array[String] {
  let parts = table.parts().map(p => p.name())
  parts.rev_in_place()
  parts
}

///|
fn MappingSchema::udf_parts(self : MappingSchema, udf : @core.Expr) -> Array[String] {
  let parts = match udf.parent {
    Some(p) if p.kind == Dot => p.flatten().map(x => x.name()).collect()
    _ => [udf.name()]
  }
  parts.rev_in_place()
  let n = @core.min_int(self.udf_depth(), parts.length())
  parts[0:n].to_owned()
}

///|
fn find_in_part_trie(
  parts : Array[String],
  trie : PartTrie,
  raise_on_missing : Bool,
) -> Array[String]? raise @core.SqlglotError {
  let (value, sub) = trie.lookup(parts)
  match value {
    Failed => None
    Prefix => {
      let possibilities = sub.flatten()
      if possibilities.length() == 1 {
        Some(parts + possibilities[0])
      } else {
        if raise_on_missing {
          let joined = parts.join(".")
          let message = possibilities.map(p => p.join(".")).join(", ")
          raise @core.SchemaError("Ambiguous mapping for \{joined}: \{message}.")
        }
        None
      }
    }
    Exists => Some(parts)
  }
}

///|
fn MappingSchema::nested_get_parts(
  self : MappingSchema,
  parts : Array[String],
  d? : Map[String, SchemaNode],
  raise_on_missing? : Bool = true,
) -> SchemaNode? raise @core.SqlglotError {
  let d = match d {
    Some(d) if !d.is_empty() => d
    _ => self.mapping
  }
  let args = self.supported_table_args()
  let rev = parts.copy()
  rev.rev_in_place()
  let path = []
  for i in 0..<@core.min_int(args.length(), rev.length()) {
    path.push((args[i], rev[i]))
  }
  nested_get(d, path, raise_on_missing~)
}

///|
/// Returns the column mapping of a given table.
pub fn MappingSchema::find(
  self : MappingSchema,
  table : @core.Expr,
  raise_on_missing? : Bool = true,
) -> Map[String, SchemaNode]? raise @core.SqlglotError {
  // like Python, a cached None is looked up again
  if self.find_cache.get((table, false)) is Some(Raw(Some(_) as cached)) {
    return cached
  }
  let schema = self.find_uncached(table, raise_on_missing~)
  self.find_cache[(table, false)] = Raw(schema)
  schema
}

///|
/// `AbstractMappingSchema.find`: the column mapping of a table, without the cache.
fn MappingSchema::find_uncached(
  self : MappingSchema,
  table : @core.Expr,
  raise_on_missing? : Bool = true,
) -> Map[String, SchemaNode]? raise @core.SqlglotError {
  let n = self.supported_table_args().length()
  let all_parts = table_parts(table)
  let parts = all_parts[0:@core.min_int(n, all_parts.length())].to_owned()
  match find_in_part_trie(parts, self.mapping_trie, raise_on_missing) {
    None => None
    Some(resolved) =>
      match self.nested_get_parts(resolved, raise_on_missing~) {
        Some(Dict(m)) => Some(m)
        _ => None
      }
  }
}

///|
/// `find(table, raise_on_missing=False, ensure_data_types=True)`: the column types of a
/// table (string types are converted to `DataType`s).
pub fn MappingSchema::find_column_types(
  self : MappingSchema,
  table : @core.Expr,
) -> Map[String, @core.Expr?]? raise @core.SqlglotError {
  if self.find_cache.get((table, true)) is Some(Types(Some(_) as cached)) {
    return cached
  }
  let schema = self.find_column_types_uncached(table)
  self.find_cache[(table, true)] = Types(schema)
  schema
}

///|
fn MappingSchema::find_column_types_uncached(
  self : MappingSchema,
  table : @core.Expr,
) -> Map[String, @core.Expr?]? raise @core.SqlglotError {
  match self.find_uncached(table, raise_on_missing=false) {
    Some(cols) => {
      let out : Map[String, @core.Expr?] = Map([])
      for col, dtype in cols {
        out[col] = match dtype {
          Type(s) => Some(self.to_data_type(s))
          DataType(dt) => Some(dt)
          _ => None
        }
      }
      Some(out)
    }
    None => None
  }
}

///|
/// Register or update a table.
pub fn MappingSchema::add_table(
  self : MappingSchema,
  table : @core.Expr,
  column_mapping? : Map[String, SchemaNode] = {},
  dialect? : @core.Dialect,
  normalize? : Bool,
  match_depth? : Bool = true,
) -> Unit raise @core.SqlglotError {
  let normalized_table = self.normalize_table(table, dialect?, normalize?)
  if match_depth &&
    !self.empty() &&
    normalized_table.parts().length() != self.depth() {
    let gen = @core.Generator::new(self.dialect)
    raise @core.SchemaError(
      "Table \{gen.generate(normalized_table)} must match the schema's nesting level: \{self.depth()}.",
    )
  }
  let normalized_column_mapping : Map[String, SchemaNode] = Map([])
  for key, value in column_mapping {
    normalized_column_mapping[self.normalize_name(key, dialect?, normalize?)] = value
  }
  let schema = self.find(normalized_table, raise_on_missing=false)
  match schema {
    Some(s) if !s.is_empty() && normalized_column_mapping.is_empty() => return
    _ => ()
  }
  let parts = table_parts(normalized_table)
  let rev = parts.copy()
  rev.rev_in_place()
  nested_set(self.mapping, rev, Dict(normalized_column_mapping))
  self.mapping_trie.add(parts)
  self.find_cache.remove((normalized_table, true))
  self.find_cache.remove((normalized_table, false))
}

///|
/// Adds a table given by name (parsed with the schema's dialect), with a list of columns.
pub fn MappingSchema::add_table_str(
  self : MappingSchema,
  table : String,
  columns? : Array[String] = [],
  column_types? : Map[String, SchemaNode] = {},
  dialect? : @core.Dialect,
  normalize? : Bool,
  match_depth? : Bool = true,
) -> Unit raise @core.SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => self.dialect
  }
  let t = @core.parse_one(table, dialect=d, into=[Table])
  let mapping = column_types.copy()
  for c in columns {
    mapping[c] = Null
  }
  self.add_table(t, column_mapping=mapping, dialect?, normalize?, match_depth~)
}

///|
/// Get the column names for a table.
pub fn MappingSchema::column_names(
  self : MappingSchema,
  table : @core.Expr,
  only_visible? : Bool = false,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> Array[String] raise @core.SqlglotError {
  let normalized_table = self.normalize_table(table, dialect?, normalize?)
  let schema = match self.find(normalized_table) {
    Some(s) => s
    None => return []
  }
  if !only_visible || self.visible.is_empty() {
    return schema.keys().collect()
  }
  let visible = match
    self.nested_get_parts(
      table_parts(normalized_table),
      d=self.visible,
      raise_on_missing=true,
    ) {
    Some(Names(names)) => names
    _ => []
  }
  schema.keys().filter(c => visible.contains(c)).collect()
}

///|
/// Get the `DataType` of a column in the schema.
pub fn MappingSchema::get_column_type(
  self : MappingSchema,
  table : @core.Expr,
  column : @core.Expr,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let normalized_table = self.normalize_table(table, dialect?, normalize?)
  let normalized_column_name = match column.this() {
    Some(ident) => self.normalize_ident_name(ident, dialect?, normalize?)
    None => self.normalize_name(column.name(), dialect?, normalize?)
  }
  match self.find(normalized_table, raise_on_missing=false) {
    Some(table_schema) if !table_schema.is_empty() =>
      match table_schema.get(normalized_column_name) {
        Some(DataType(dt)) => return dt
        Some(Type(s)) => return self.to_data_type(s, dialect?)
        _ => ()
      }
    _ => ()
  }
  @core.datatype_of(UNKNOWN)
}

///|
/// Get the `DataType` of a column given by name.
pub fn MappingSchema::get_column_type_str(
  self : MappingSchema,
  table : @core.Expr,
  column : String,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let normalized_table = self.normalize_table(table, dialect?, normalize?)
  let normalized_column_name = self.normalize_name(column, dialect?, normalize?)
  match self.find(normalized_table, raise_on_missing=false) {
    Some(table_schema) if !table_schema.is_empty() =>
      match table_schema.get(normalized_column_name) {
        Some(DataType(dt)) => return dt
        Some(Type(s)) => return self.to_data_type(s, dialect?)
        _ => ()
      }
    _ => ()
  }
  @core.datatype_of(UNKNOWN)
}

///|
/// Returns whether `column` appears in `table`'s schema.
pub fn MappingSchema::has_column(
  self : MappingSchema,
  table : @core.Expr,
  column : @core.Expr,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> Bool raise @core.SqlglotError {
  let normalized_table = self.normalize_table(table, dialect?, normalize?)
  let normalized_column_name = match column.this() {
    Some(ident) => self.normalize_ident_name(ident, dialect?, normalize?)
    None => self.normalize_name(column.name(), dialect?, normalize?)
  }
  match self.find(normalized_table, raise_on_missing=false) {
    Some(table_schema) if !table_schema.is_empty() =>
      table_schema.contains(normalized_column_name)
    _ => false
  }
}

///|
/// Get the return type of a UDF, or UNKNOWN if not found.
pub fn MappingSchema::get_udf_type(
  self : MappingSchema,
  udf : @core.Expr,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let normalize = match normalize {
    Some(n) => n
    None => self.normalize
  }
  let mut parts = self.udf_parts(udf)
  if normalize {
    parts = parts.map(p => self.normalize_name(p, dialect?, is_table=true))
  }
  match find_in_part_trie(parts, self.udf_trie, false) {
    None => @core.datatype_of(UNKNOWN)
    Some(resolved) => {
      let rev = resolved.copy()
      rev.rev_in_place()
      let path = []
      for i in 0..<resolved.length() {
        path.push((resolved[i], rev[i]))
      }
      match nested_get(self.udf_mapping, path, raise_on_missing=false) {
        Some(DataType(dt)) => dt
        Some(Type(s)) => self.to_data_type(s, dialect?)
        _ => @core.datatype_of(UNKNOWN)
      }
    }
  }
}

///|
/// Get the return type of a UDF given as a string, e.g. `"db.my_func(x)"`, or UNKNOWN if
/// not found.
pub fn MappingSchema::get_udf_type_str(
  self : MappingSchema,
  udf : String,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let d = match dialect {
    Some(d) => d
    None => self.dialect
  }
  let parsed = @core.maybe_parse_str(udf, dialect=d)
  let udf_expr = if parsed.kind == Anonymous {
    parsed
  } else {
    match parsed.expression() {
      Some(e) if parsed.kind == Dot && e.kind == Anonymous => e
      _ => raise @core.SchemaError("Unable to parse UDF from: \{@core.py_repr_str(udf)}")
    }
  }
  self.get_udf_type(udf_expr, dialect?, normalize?)
}

///|
fn MappingSchema::normalize_mapping(
  self : MappingSchema,
  schema : Map[String, SchemaNode],
) -> Map[String, SchemaNode] raise @core.SqlglotError {
  let normalized_mapping : Map[String, SchemaNode] = Map([])
  let flattened_schema = flatten_schema(schema)
  for keys in flattened_schema {
    let columns = nested_get(schema, keys.map(k => (k, k)))
    let nesting = flattened_schema[0].length()
    let columns = match columns {
      Some(Dict(c)) => c
      _ => {
        let t = keys[0:keys.length() - 1].to_owned().join(".")
        raise @core.SchemaError(
          "Table \{t} must match the schema's nesting level: \{nesting}.",
        )
      }
    }
    if columns.is_empty() {
      let t = keys[0:keys.length() - 1].to_owned().join(".")
      raise @core.SchemaError("Table \{t} must have at least one column")
    }
    match columns.values().next() {
      Some(Dict(_)) => {
        let t = (keys + flatten_schema(columns)[0]).join(".")
        raise @core.SchemaError(
          "Table \{t} must match the schema's nesting level: \{nesting}.",
        )
      }
      _ => ()
    }
    let normalized_keys = keys.map(k => self.normalize_name(k, is_table=true))
    for column_name, column_type in columns {
      nested_set(
        normalized_mapping,
        normalized_keys + [self.normalize_name(column_name)],
        column_type,
      )
    }
  }
  normalized_mapping
}

///|
fn MappingSchema::normalize_udfs(
  self : MappingSchema,
  udfs : Map[String, SchemaNode],
) -> Map[String, SchemaNode] raise @core.SqlglotError {
  let normalized_mapping : Map[String, SchemaNode] = Map([])
  for keys in flatten_schema(udfs, depth=map_depth(udfs)) {
    match nested_get(udfs, keys.map(k => (k, k))) {
      Some(udf_type) => {
        let normalized_keys = keys.map(k => self.normalize_name(k, is_table=true))
        nested_set(normalized_mapping, normalized_keys, udf_type)
      }
      None => ()
    }
  }
  normalized_mapping
}

///|
/// Normalizes a table (parsing it if it's a string).
pub fn MappingSchema::normalize_table(
  self : MappingSchema,
  table : @core.Expr,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> @core.Expr {
  let dialect = match dialect {
    Some(d) => d
    None => self.dialect
  }
  let normalize = match normalize {
    Some(n) => n
    None => self.normalize
  }
  if !normalize {
    return table
  }
  let normalized_table = table.copy()
  for part in normalized_table.parts() {
    if part.kind == Identifier {
      part
      .replace(Some(normalize_name_ident(part, dialect, is_table=true)))
      .unwrap()
      |> ignore
    }
  }
  normalized_table
}

///|
fn MappingSchema::normalize_name(
  self : MappingSchema,
  name : String,
  dialect? : @core.Dialect,
  is_table? : Bool = false,
  normalize? : Bool,
) -> String {
  let normalize = match normalize {
    Some(n) => n
    None => self.normalize
  }
  let dialect = match dialect {
    Some(d) => d
    None => self.dialect
  }
  normalize_name(name, dialect~, is_table~, normalize~).name()
}

///|
fn MappingSchema::normalize_ident_name(
  self : MappingSchema,
  ident : @core.Expr,
  dialect? : @core.Dialect,
  normalize? : Bool,
) -> String {
  let normalize = match normalize {
    Some(n) => n
    None => self.normalize
  }
  let dialect = match dialect {
    Some(d) => d
    None => self.dialect
  }
  if !normalize {
    return ident.name()
  }
  normalize_name_ident(ident, dialect, is_table=false).name()
}

///|
/// Converts a type string into a `DataType` expression.
fn MappingSchema::to_data_type(
  self : MappingSchema,
  schema_type : String,
  dialect? : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  match self.type_mapping_cache.get(schema_type) {
    Some(t) => return t
    None => ()
  }
  let dialect = match dialect {
    Some(d) => d
    None => self.dialect
  }
  let udt = dialect.cfg.supports_user_defined_types
  let expression = @core.datatype_from_str(schema_type, dialect~, udt~) catch {
    _ =>
      raise @core.SchemaError(
        "Failed to build type '\{schema_type}' in dialect \{dialect.name}.",
      )
  }
  let expression = expression.transform(
    n => Some(dialect.normalize_identifier(n)),
    copy=false,
  )
  self.type_mapping_cache[schema_type] = expression
  expression
}

///|
/// Python `normalize_name` for a string identifier.
pub fn normalize_name(
  identifier : String,
  dialect? : @core.Dialect,
  is_table? : Bool = false,
  normalize? : Bool = true,
) -> @core.Expr {
  let dialect = match dialect {
    Some(d) => d
    None => @core.base_dialect()
  }
  let ident = @core.parse_identifier(identifier, dialect~)
  if !normalize {
    return ident
  }
  ident.get_meta()["is_table"] = Bool(is_table)
  dialect.normalize_identifier(ident)
}

///|
/// Python `normalize_name` for an identifier expression (it is copied).
pub fn normalize_name_ident(
  identifier : @core.Expr,
  dialect : @core.Dialect,
  is_table? : Bool = false,
) -> @core.Expr {
  let ident = identifier.copy()
  ident.get_meta()["is_table"] = Bool(is_table)
  dialect.normalize_identifier(ident)
}
