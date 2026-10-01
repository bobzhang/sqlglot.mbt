// The expression tree node. This mirrors sqlglot's `Expression` class: every node
// has a kind (its Python class) and a dictionary of arguments.

///|
/// An argument value of an expression.
pub(all) enum Value {
  Node(Expr)
  List(Array[Value])
  Str(String)
  Bool(Bool)
  Int(Int)
  DT(DType)
}

///|
/// A node of the SQL syntax tree.
pub struct Expr {
  kind : Kind
  args : Map[String, Value]
  mut parent : Expr?
  mut arg_key : String?
  mut index : Int?
  mut comments : Array[String]?
  mut type_ : Expr?
  mut meta : Map[String, Value]?
  /// Unique identity of this node (Python `id(node)`).
  uid : Int
}

///|
let expr_uid_counter : Ref[Int] = Ref(0)

///|
fn next_expr_uid() -> Int {
  expr_uid_counter.val += 1
  expr_uid_counter.val
}

///|
/// Conversion of host values to expression argument values.
pub trait IntoValue {
  fn into_value(Self) -> Value?
}

///|
pub impl IntoValue for Expr with fn into_value(self) {
  Some(Node(self))
}

///|
pub impl IntoValue for String with fn into_value(self) {
  Some(Str(self))
}

///|
pub impl IntoValue for Bool with fn into_value(self) {
  Some(Bool(self))
}

///|
pub impl IntoValue for Int with fn into_value(self) {
  Some(Int(self))
}

///|
pub impl IntoValue for DType with fn into_value(self) {
  Some(DT(self))
}

///|
pub impl IntoValue for Value with fn into_value(self) {
  Some(self)
}

///|
pub impl[T : IntoValue] IntoValue for T? with fn into_value(self) {
  match self {
    Some(x) => x.into_value()
    None => None
  }
}

///|
pub impl[T : IntoValue] IntoValue for Array[T] with fn into_value(self) {
  let out = Array::new(capacity=self.length())
  for x in self {
    match x.into_value() {
      Some(v) => out.push(v)
      None => ()
    }
  }
  Some(List(out))
}

///|
/// The "no value" argument, i.e. Python `None`.
pub let null_arg : Value? = None

///|
/// Python truthiness of an argument value.
pub fn Value::truthy(self : Value) -> Bool {
  match self {
    Node(_) => true
    List(l) => !l.is_empty()
    Str(s) => !s.is_empty()
    Bool(b) => b
    Int(i) => i != 0
    DT(_) => true
  }
}

///|
pub fn Value::as_node(self : Value) -> Expr? {
  match self {
    Node(e) => Some(e)
    _ => None
  }
}

///|
pub fn Value::as_str(self : Value) -> String? {
  match self {
    Str(s) => Some(s)
    _ => None
  }
}

///|
/// Creates a new expression of `kind` with the given arguments. `None` arguments are skipped.
pub fn Expr::new(kind : Kind, args : Map[String, Value]) -> Expr {
  let e = {
    kind,
    args,
    parent: None,
    arg_key: None,
    index: None,
    comments: None,
    type_: None,
    meta: None,
    uid: next_expr_uid(),
  }
  if kind == DateTrunc {
    normalize_date_trunc_args(args)
  }
  for k, v in args {
    e.set_parent(k, v, None)
  }
  e.post_init()
  e
}

///|
/// Builds an expression, Python style: `mk(Column, [("this", ident), ("table", tbl)])`.
pub fn mk(kind : Kind, args : ArrayView[(String, &IntoValue)]) -> Expr {
  let m : Map[_, _] = Map([], capacity=args.length())
  for kv in args {
    match kv.1.into_value() {
      Some(v) => m[kv.0] = v
      None => ()
    }
  }
  Expr::new(kind, m)
}

///|
/// Builds an expression with no arguments.
pub fn mk0(kind : Kind) -> Expr {
  Expr::new(kind, Map([]))
}

///|
/// Builds an expression with a single `this` argument.
pub fn mk1(kind : Kind, this : &IntoValue) -> Expr {
  mk(kind, [("this", this)])
}

///|
/// Builds an expression with `this` and `expression` arguments.
pub fn mk2(kind : Kind, this : &IntoValue, expression : &IntoValue) -> Expr {
  mk(kind, [("this", this), ("expression", expression)])
}

///|
pub let unabbreviated_unit_name : Map[String, String] = {
  "D": "DAY",
  "H": "HOUR",
  "M": "MINUTE",
  "MS": "MILLISECOND",
  "NS": "NANOSECOND",
  "Q": "QUARTER",
  "S": "SECOND",
  "US": "MICROSECOND",
  "W": "WEEK",
  "Y": "YEAR",
}

///|
pub fn unabbreviate_unit(name : String) -> String? {
  unabbreviated_unit_name.get(name)
}

///|
fn is_var_like_unit(unit : Expr) -> Bool {
  match unit.kind {
    Column => unit.column_parts().length() == 1
    Literal | Var => true
    _ => false
  }
}

///|
/// `DateTrunc.__init__`: normalizes the unit before parents are attached.
fn normalize_date_trunc_args(args : Map[String, Value]) -> Unit {
  let unabbreviate = match args.get("unabbreviate") {
    Some(Bool(b)) => b
    _ => true
  }
  args.remove("unabbreviate")
  match args.get("unit") {
    Some(Node(unit)) =>
      if unit.kind.is_any([Column, Literal, Var]) &&
        !(unit.kind.is_a(Column) && unit.column_parts().length() != 1) {
        let mut unit_name = py_upper(unit.name())
        if unabbreviate {
          match unabbreviated_unit_name.get(unit_name) {
            Some(n) => unit_name = n
            None => ()
          }
        }
        args["unit"] = Node(literal_string(unit_name))
      }
    _ => ()
  }
}

///|
/// Emulates the custom `__init__` of some expression classes.
fn Expr::post_init(self : Expr) -> Unit {
  if self.kind.is_a(TimeUnit) {
    match self.arg("unit") {
      Some(unit) =>
        if is_var_like_unit(unit) {
          let name = unit.name()
          let n = match unabbreviated_unit_name.get(name) {
            Some(n) => n
            None => name
          }
          let v = mk1(Var, py_upper(n))
          self.args["unit"] = Node(v)
          self.set_parent("unit", Node(v), None)
        } else if unit.kind == Week {
          match unit.this() {
            Some(t) => unit.set("this", mk1(Var, py_upper(t.name())))
            None => ()
          }
        }
      None => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Argument access

///|
pub fn Expr::get(self : Expr, key : String) -> Value? {
  self.args.get(key)
}

///|
/// Python truthiness of `self.args.get(key)`.
pub fn Expr::has(self : Expr, key : String) -> Bool {
  match self.args.get(key) {
    Some(v) => v.truthy()
    None => false
  }
}

///|
/// Returns the argument `key` if it is an expression.
pub fn Expr::arg(self : Expr, key : String) -> Expr? {
  match self.args.get(key) {
    Some(Node(e)) => Some(e)
    _ => None
  }
}

///|
/// Returns the list argument `key` (only expression elements).
pub fn Expr::list(self : Expr, key : String) -> Array[Expr] {
  match self.args.get(key) {
    Some(List(l)) => {
      let out = Array::new(capacity=l.length())
      for v in l {
        match v {
          Node(e) => out.push(e)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

///|
/// Returns the raw list argument `key`.
pub fn Expr::raw_list(self : Expr, key : String) -> Array[Value] {
  match self.args.get(key) {
    Some(List(l)) => l
    _ => []
  }
}

///|
/// Returns the string argument `key`, if it is a string.
pub fn Expr::str_arg(self : Expr, key : String) -> String? {
  match self.args.get(key) {
    Some(Str(s)) => Some(s)
    _ => None
  }
}

///|
/// Returns the boolean argument `key` (Python truthiness).
pub fn Expr::bool_arg(self : Expr, key : String) -> Bool {
  self.has(key)
}

///|
/// `self.this` when it is an expression.
pub fn Expr::this(self : Expr) -> Expr? {
  self.arg("this")
}

///|
/// `self.this` expression; panics if missing.
pub fn Expr::this_(self : Expr) -> Expr {
  match self.arg("this") {
    Some(e) => e
    None => abort("\{self.kind} has no `this` expression")
  }
}

///|
/// `self.expression` when it is an expression.
pub fn Expr::expression(self : Expr) -> Expr? {
  self.arg("expression")
}

///|
pub fn Expr::expression_(self : Expr) -> Expr {
  match self.arg("expression") {
    Some(e) => e
    None => abort("\{self.kind} has no `expression` expression")
  }
}

///|
/// `self.expressions`.
pub fn Expr::expressions(self : Expr) -> Array[Expr] {
  self.list("expressions")
}

///|
/// Returns a textual representation of the argument corresponding to `key`.
pub fn Expr::text(self : Expr, key : String) -> String {
  match self.args.get(key) {
    Some(Str(s)) => s
    Some(Node(f)) =>
      match f.kind {
        Identifier | Literal | Var =>
          match f.args.get("this") {
            Some(Str(s)) => s
            _ => ""
          }
        Star | Null => f.name()
        _ => ""
      }
    _ => ""
  }
}

///|
pub fn Expr::is_string(self : Expr) -> Bool {
  self.kind == Literal && self.has("is_string")
}

///|
pub fn Expr::is_number(self : Expr) -> Bool {
  (self.kind == Literal && !self.has("is_string")) ||
  (
    self.kind == Neg &&
    (match self.this() {
      Some(t) => t.is_number()
      None => false
    })
  )
}

///|
pub fn Expr::is_int(self : Expr) -> Bool {
  if !self.is_number() {
    return false
  }
  match self.kind {
    Literal => is_int_str(self.text("this"))
    Neg =>
      match self.this() {
        Some(t) => t.is_int()
        None => false
      }
    _ => false
  }
}

///|
pub fn Expr::is_star(self : Expr) -> Bool {
  match self.kind.owner_is_star() {
    Some(Dot) =>
      match self.expression() {
        Some(e) => e.is_star()
        None => false
      }
    Some(Select) => self.expressions().iter().any(e => e.is_star())
    Some(SetOperation) | Some(Subquery) => is_star_query(self)
    _ =>
      self.kind == Star ||
      (
        self.kind.is_a(Column) &&
        (match self.this() {
          Some(t) => t.kind == Star
          None => false
        })
      )
  }
}

///|
fn is_star_query(expression : Expr) -> Bool {
  let stack = [expression]
  while stack.pop() is Some(node) {
    if node.kind.is_a(SetOperation) {
      match node.this() {
        Some(t) => stack.push(t)
        None => ()
      }
      match node.expression() {
        Some(t) => stack.push(t)
        None => ()
      }
    } else if node.kind.is_a(Subquery) {
      match node.this() {
        Some(t) => stack.push(t)
        None => ()
      }
    } else if node.is_star() {
      return true
    }
  }
  false
}

///|
/// The alias of the expression, or an empty string if it's not aliased.
pub fn Expr::alias(self : Expr) -> String {
  match self.args.get("alias") {
    Some(Node(a)) => a.name()
    _ => self.text("alias")
  }
}

///|
pub fn Expr::alias_column_names(self : Expr) -> Array[String] {
  match self.arg("alias") {
    Some(a) => a.list("columns").map(c => c.name())
    None => []
  }
}

///|
pub fn Expr::name(self : Expr) -> String {
  match self.kind.owner_name() {
    Some(Star) => "*"
    Some(Placeholder) => {
      let t = self.text("this")
      if t.is_empty() {
        "?"
      } else {
        t
      }
    }
    Some(Null) => "NULL"
    Some(Dot) =>
      match self.expression() {
        Some(e) => e.name()
        None => ""
      }
    Some(Anonymous) =>
      match self.args.get("this") {
        Some(Str(s)) => s
        Some(Node(e)) => e.name()
        _ => ""
      }
    Some(Table) =>
      match self.this() {
        None => ""
        Some(t) =>
          if t.kind.is_a(Func) && !t.kind.is_a(DynamicIdentifier) {
            ""
          } else {
            t.name()
          }
      }
    Some(DataType) => self.text("this")
    Some(_) =>
      // DataTypeParam, Cast, Execute, From, DynamicIdentifier, Ordered: this.name
      match self.this() {
        Some(t) => t.name()
        None => ""
      }
    None => self.text("this")
  }
}

///|
pub fn Expr::alias_or_name(self : Expr) -> String {
  match self.kind.owner_alias_or_name() {
    Some(From) | Some(Join) =>
      match self.this() {
        Some(t) => t.alias_or_name()
        None => ""
      }
    _ => {
      let a = self.alias()
      if a.is_empty() {
        self.name()
      } else {
        a
      }
    }
  }
}

///|
/// Name of the output column if this expression is a selection.
pub fn Expr::output_name(self : Expr) -> String {
  match self.kind.owner_output_name() {
    None => ""
    Some(Alias) => self.alias()
    Some(Subquery) => self.alias()
    Some(Bracket) => {
      let exprs = self.expressions()
      if exprs.length() == 1 {
        exprs[0].output_name()
      } else {
        ""
      }
    }
    Some(Paren) | Some(Agg) =>
      match self.this() {
        Some(t) => t.name()
        None => ""
      }
    Some(JSONExtract) =>
      if self.expressions().is_empty() {
        match self.expression() {
          Some(e) => e.output_name()
          None => ""
        }
      } else {
        ""
      }
    Some(JSONExtractScalar) =>
      match self.expression() {
        Some(e) => e.output_name()
        None => ""
      }
    Some(JSONPath) => {
      let exprs = self.expressions()
      if exprs.is_empty() {
        ""
      } else {
        match exprs[exprs.length() - 1].args.get("this") {
          Some(Str(s)) => s
          _ => ""
        }
      }
    }
    Some(_) => self.name()
  }
}

///|
/// The parts of a column in order catalog, db, table, name.
pub fn Expr::column_parts(self : Expr) -> Array[Expr] {
  let out = []
  for part in ["catalog", "db", "table", "this"] {
    match self.args.get(part) {
      Some(Node(e)) => out.push(e)
      _ => ()
    }
  }
  out
}

///|
/// `Table.parts` / `Dot.parts` / `Column.parts`.
pub fn Expr::parts(self : Expr) -> Array[Expr] {
  match self.kind.owner_parts() {
    Some(Table) => {
      let parts = []
      for arg in ["catalog", "db", "this"] {
        match self.args.get(arg) {
          Some(Node(part)) =>
            if part.kind == Dot {
              for p in part.flatten() {
                parts.push(p)
              }
            } else {
              parts.push(part)
            }
          _ => ()
        }
      }
      parts
    }
    Some(Dot) => {
      let flat = self.flatten().collect()
      let this = flat[0]
      let parts = flat[1:].to_array()
      parts.rev_in_place()
      for arg in ["this", "table", "db", "catalog"] {
        match this.args.get(arg) {
          Some(Node(p)) => parts.push(p)
          _ => ()
        }
      }
      parts.rev_in_place()
      parts
    }
    _ => self.column_parts()
  }
}

///|
pub fn Expr::table_name(self : Expr) -> String {
  self.text("table")
}

///|
pub fn Expr::db(self : Expr) -> String {
  self.text("db")
}

///|
pub fn Expr::catalog(self : Expr) -> String {
  self.text("catalog")
}

///|
/// The `type` property: the inferred data type of this expression.
pub fn Expr::get_type(self : Expr) -> Expr? {
  if self.kind.is_data_type() {
    return Some(self)
  }
  if self.kind.is_cast() {
    match self.type_ {
      Some(t) => return Some(t)
      None => return self.arg("to")
    }
  }
  self.type_
}

///|
/// Sets the inferred data type of this expression.
pub fn Expr::set_type(self : Expr, dtype : Expr?) -> Unit {
  self.type_ = dtype
}

///|
pub fn Expr::is_leaf(self : Expr) -> Bool {
  for _, v in self.args {
    match v {
      Node(_) => return false
      List(l) => if !l.is_empty() { return false }
      _ => ()
    }
  }
  true
}

///|
pub fn Expr::get_meta(self : Expr) -> Map[String, Value] {
  match self.meta {
    Some(m) => m
    None => {
      let m : Map[_, _] = Map([])
      self.meta = Some(m)
      m
    }
  }
}

///|
pub fn Expr::meta_get(self : Expr, key : String) -> Value? {
  match self.meta {
    Some(m) => m.get(key)
    None => None
  }
}

///|
pub fn Expr::meta_bool(self : Expr, key : String) -> Bool {
  match self.meta_get(key) {
    Some(v) => v.truthy()
    None => false
  }
}

// ---------------------------------------------------------------------------
// Copying

///|
fn copy_value(v : Value) -> Value {
  match v {
    Node(e) => Node(e.copy())
    List(l) => List(l.map(copy_value))
    other => other
  }
}

///|
/// Returns a deep copy of the expression.
pub fn Expr::copy(self : Expr) -> Expr {
  let args : Map[_, _] = Map([], capacity=self.args.length())
  for k, v in self.args {
    args[k] = copy_value(v)
  }
  let e = {
    kind: self.kind,
    args,
    parent: None,
    arg_key: None,
    index: None,
    comments: match self.comments {
      Some(c) => Some(c.copy())
      None => None
    },
    type_: match self.type_ {
      Some(t) => Some(t.copy())
      None => None
    },
    meta: match self.meta {
      Some(m) => {
        let m2 : Map[_, _] = Map([])
        for k, v in m {
          m2[k] = copy_value(v)
        }
        Some(m2)
      }
      None => None
    },
    uid: next_expr_uid(),
  }
  for k, v in args {
    e.set_parent(k, v, None)
  }
  e
}

///|
pub fn maybe_copy(e : Expr, copy : Bool) -> Expr {
  if copy {
    e.copy()
  } else {
    e
  }
}

// ---------------------------------------------------------------------------
// Comments

///|
pub fn Expr::add_comments(
  self : Expr,
  comments : Array[String]?,
  prepend? : Bool = false,
) -> Unit {
  if self.comments is None {
    self.comments = Some([])
  }
  match comments {
    Some(comments) if !comments.is_empty() => {
      for comment in comments {
        let parts = py_split(comment, sqlglot_meta)
        if parts.length() > 1 {
          let meta = parts[1:].to_array().join("")
          for kv in py_split(meta, ",") {
            let kvs = py_split(kv, "=")
            let k = py_strip(kvs[0])
            let v : Value = if kvs.length() > 1 {
              let vs = py_strip(kvs[1])
              match to_bool_str(vs) {
                Some(b) => Bool(b)
                None => Str(vs)
              }
            } else {
              Bool(true)
            }
            self.get_meta()[k] = v
          }
        }
        if !prepend {
          self.comments.unwrap().push(comment)
        }
      }
      if prepend {
        self.comments = Some(comments + self.comments.unwrap())
      }
    }
    _ => ()
  }
}

///|
pub fn Expr::pop_comments(self : Expr) -> Array[String] {
  let c = match self.comments {
    Some(c) => c
    None => []
  }
  self.comments = None
  c
}

///|
pub let sqlglot_meta : String = "sqlglot.meta"

///|
pub let sqlglot_anonymous : String = "sqlglot.anonymous"

// ---------------------------------------------------------------------------
// Mutation

///|
fn Expr::set_parent(
  self : Expr,
  arg_key : String,
  value : Value,
  index : Int?,
) -> Unit {
  match value {
    Node(e) => {
      e.parent = Some(self)
      e.arg_key = Some(arg_key)
      e.index = index
    }
    List(l) =>
      for i, v in l {
        match v {
          Node(e) => {
            e.parent = Some(self)
            e.arg_key = Some(arg_key)
            e.index = Some(i)
          }
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// Appends value to arg_key if it's a list or sets it as a new list.
pub fn Expr::append(self : Expr, arg_key : String, value : &IntoValue) -> Unit {
  let value = match value.into_value() {
    Some(v) => v
    None => return
  }
  let values = match self.args.get(arg_key) {
    Some(List(l)) => l
    _ => {
      let l = []
      self.args[arg_key] = List(l)
      l
    }
  }
  match value {
    Node(e) => {
      e.parent = Some(self)
      e.arg_key = Some(arg_key)
      e.index = Some(values.length())
    }
    _ => ()
  }
  values.push(value)
}

///|
/// Sets arg_key to value. `None` removes the argument.
pub fn Expr::set(self : Expr, arg_key : String, value : &IntoValue) -> Unit {
  match value.into_value() {
    None => self.args.remove(arg_key)
    Some(v) => {
      self.args[arg_key] = v
      self.set_parent(arg_key, v, None)
    }
  }
}

///|
/// `Expr.set(arg_key, value, index, overwrite)` for list arguments.
pub fn Expr::set_at(
  self : Expr,
  arg_key : String,
  value : &IntoValue,
  index : Int,
  overwrite? : Bool = true,
) -> Unit {
  let expressions = match self.args.get(arg_key) {
    Some(List(l)) => l
    _ => return
  }
  let n = expressions.length()
  // Python: seq_get(expressions, index) is None -> return
  if index >= n || index < -n {
    return
  }
  let i = if index < 0 { n + index } else { index }
  // Python slice/insert position semantics for a (possibly negative) index
  fn pos(len : Int) -> Int {
    if index < 0 {
      let p = len + index
      if p < 0 {
        0
      } else {
        p
      }
    } else if index > len {
      len
    } else {
      index
    }
  }

  match value.into_value() {
    None => {
      expressions.remove(i) |> ignore
      for j in pos(expressions.length())..<expressions.length() {
        match expressions[j] {
          Node(e) =>
            e.index = match e.index {
              Some(x) => Some(x - 1)
              None => None
            }
          _ => ()
        }
      }
      return
    }
    Some(List(vs)) => {
      expressions.remove(i) |> ignore
      let at = pos(expressions.length())
      for j, v in vs {
        expressions.insert(at + j, v)
      }
    }
    Some(v) =>
      if overwrite {
        expressions[i] = v
      } else {
        expressions.insert(pos(n), v)
      }
  }
  self.set_parent(arg_key, List(expressions), Some(index))
}

///|
pub fn Expr::set_kwargs(
  self : Expr,
  kwargs : ArrayView[(String, &IntoValue)],
) -> Expr {
  for kv in kwargs {
    self.set(kv.0, kv.1)
  }
  self
}

///|
/// Sets the parent pointer without attaching the node to `parent`'s args
/// (Python `node.parent = parent`).
pub fn Expr::set_parent_ref(self : Expr, parent : Expr?) -> Unit {
  self.parent = parent
}

///|
/// Depth of this node in the tree.
pub fn Expr::depth(self : Expr) -> Int {
  match self.parent {
    Some(p) => p.depth() + 1
    None => 0
  }
}

///|
/// Yields all child expressions, exploding list args.
pub fn Expr::iter_expressions(
  self : Expr,
  reverse? : Bool = false,
) -> Array[Expr] {
  let out = []
  for _, vs in self.args {
    match vs {
      List(l) =>
        for v in l {
          match v {
            Node(e) => out.push(e)
            _ => ()
          }
        }
      Node(e) => out.push(e)
      _ => ()
    }
  }
  if reverse {
    out.rev_in_place()
  }
  out
}

///|
/// Iterates the tree in DFS order.
pub fn Expr::dfs(self : Expr, prune? : (Expr) -> Bool) -> Iter[Expr] {
  let stack = [self]
  let mut pending : Expr? = None
  Iter::new(fn() {
    match pending {
      Some(node) => {
        pending = None
        let pruned = match prune {
          Some(p) => p(node)
          None => false
        }
        if !pruned {
          for v in node.iter_expressions(reverse=true) {
            stack.push(v)
          }
        }
      }
      None => ()
    }
    match stack.pop() {
      Some(node) => {
        pending = Some(node)
        Some(node)
      }
      None => None
    }
  })
}

///|
/// Iterates the tree in BFS order.
pub fn Expr::bfs(self : Expr, prune? : (Expr) -> Bool) -> Iter[Expr] {
  let queue = @deque.Deque::new()
  queue.push_back(self)
  let mut pending : Expr? = None
  Iter::new(fn() {
    match pending {
      Some(node) => {
        pending = None
        let pruned = match prune {
          Some(p) => p(node)
          None => false
        }
        if !pruned {
          for v in node.iter_expressions() {
            queue.push_back(v)
          }
        }
      }
      None => ()
    }
    match queue.pop_front() {
      Some(node) => {
        pending = Some(node)
        Some(node)
      }
      None => None
    }
  })
}

///|
pub fn Expr::walk(
  self : Expr,
  bfs? : Bool = true,
  prune? : (Expr) -> Bool,
) -> Iter[Expr] {
  if bfs {
    self.bfs(prune?)
  } else {
    self.dfs(prune?)
  }
}

///|
/// Returns the first node in this tree which matches at least one of the kinds.
pub fn Expr::find(
  self : Expr,
  kinds : ArrayView[Kind],
  bfs? : Bool = true,
) -> Expr? {
  let it = self.walk(bfs~)
  while it.next() is Some(e) {
    if e.kind.is_any(kinds) {
      return Some(e)
    }
  }
  None
}

///|
/// Returns all nodes in this tree which match at least one of the kinds.
pub fn Expr::find_all(
  self : Expr,
  kinds : ArrayView[Kind],
  bfs? : Bool = true,
) -> Iter[Expr] {
  let kinds = kinds.to_array()
  self.walk(bfs~).filter(e => e.kind.is_any(kinds))
}

///|
/// Returns the nearest parent matching the kinds.
pub fn Expr::find_ancestor(self : Expr, kinds : ArrayView[Kind]) -> Expr? {
  let mut ancestor = self.parent
  while ancestor is Some(a) && !a.kind.is_any(kinds) {
    ancestor = a.parent
  }
  ancestor
}

///|
pub fn Expr::parent_select(self : Expr) -> Expr? {
  self.find_ancestor([Select])
}

///|
pub fn Expr::same_parent(self : Expr) -> Bool {
  match self.parent {
    Some(p) => p.kind == self.kind
    None => false
  }
}

///|
pub fn Expr::root(self : Expr) -> Expr {
  let mut e = self
  while e.parent is Some(p) {
    e = p
  }
  e
}

///|
/// Returns the first non-parenthesis child (or first non-subquery for subqueries).
pub fn Expr::unnest(self : Expr) -> Expr {
  match self.kind.owner_unnest() {
    Some(Subquery) => {
      let mut e = self
      while e.kind.is_a(Subquery) {
        match e.this() {
          Some(t) => e = t
          None => break
        }
      }
      e
    }
    _ => {
      let mut e = self
      while e.kind == Paren {
        match e.this() {
          Some(t) => e = t
          None => break
        }
      }
      e
    }
  }
}

///|
pub fn Expr::unalias(self : Expr) -> Expr {
  if self.kind.is_a(Alias) {
    match self.this() {
      Some(t) => t
      None => self
    }
  } else {
    self
  }
}

///|
pub fn Expr::unnest_operands(self : Expr) -> Array[Expr] {
  self.iter_expressions().map(e => e.unnest())
}

///|
/// Returns a generator which yields child nodes whose parents are the same class.
pub fn Expr::flatten(self : Expr, unnest? : Bool = true) -> Iter[Expr] {
  let kind = self.kind
  self
  .dfs(prune=n => n.parent is Some(_) && n.kind != kind)
  .filter_map(node => {
    if node.kind != kind {
      Some(
        if unnest && !node.kind.is_subquery() {
          node.unnest()
        } else {
          node
        },
      )
    } else {
      None
    }
  })
}

///|
/// Subquery.unwrap
pub fn Expr::unwrap_subquery(self : Expr) -> Expr {
  let mut e = self
  while e.same_parent() && e.is_wrapper() {
    e = e.parent.unwrap()
  }
  e
}

///|
/// Whether this Subquery acts as a simple wrapper around another expression.
pub fn Expr::is_wrapper(self : Expr) -> Bool {
  for k, _ in self.args {
    if k != "this" {
      return false
    }
  }
  true
}

///|
/// Replaces this node with `expression` in its parent. Returns the new expression.
pub fn Expr::replace(self : Expr, expression : Expr?) -> Expr? {
  let parent = match self.parent {
    Some(p) => p
    None => return expression
  }
  match expression {
    Some(e) => if physical_equal(parent, e) { return expression }
    None => ()
  }
  match self.arg_key {
    Some(key) =>
      match self.index {
        Some(i) => parent.set_at(key, expression, i)
        None => parent.set(key, expression)
      }
    None => ()
  }
  match expression {
    Some(e) if physical_equal(e, self) => ()
    _ => {
      self.parent = None
      self.arg_key = None
      self.index = None
    }
  }
  expression
}

///|
/// Replace with a list of expressions (Python `replace([...])`).
pub fn Expr::replace_with_list(self : Expr, expressions : Array[Expr]) -> Unit {
  let parent = match self.parent {
    Some(p) => p
    None => return
  }
  match (self.arg_key, self.index) {
    (Some(key), Some(i)) => parent.set_at(key, expressions, i)
    (Some(key), None) =>
      match parent.args.get(key) {
        Some(Node(value)) =>
          match value.parent {
            Some(vp) => vp.replace_with_list(expressions)
            None => ()
          }
        _ => parent.set(key, expressions)
      }
    _ => ()
  }
  self.parent = None
  self.arg_key = None
  self.index = None
}

///|
/// Removes this expression from its parent.
pub fn Expr::pop(self : Expr) -> Expr {
  self.replace(None) |> ignore
  self
}

///|
/// Recursively visits all tree nodes (DFS) and applies `fun` to each, replacing nodes.
pub fn Expr::transform(
  self : Expr,
  fun : (Expr) -> Expr? raise?,
  copy? : Bool = true,
) -> Expr raise? {
  let mut root : Expr? = None
  let mut new_node : Expr? = None
  let start = if copy { self.copy() } else { self }
  let it = start.dfs(prune=n => {
    match new_node {
      Some(nn) => !physical_equal(n, nn)
      None => true
    }
  })
  while it.next() is Some(node) {
    let parent = node.parent
    let arg_key = node.arg_key
    let index = node.index
    let nn = fun(node)
    new_node = nn
    if root is None {
      root = nn
      if nn is None {
        // keep going so that the semantics match Python's assertion
        break
      }
    } else {
      match (parent, arg_key) {
        (Some(p), Some(k)) => {
          let same = match nn {
            Some(n) => physical_equal(n, node)
            None => false
          }
          if !same {
            match index {
              Some(i) => p.set_at(k, nn, i)
              None => p.set(k, nn)
            }
          }
        }
        _ => ()
      }
    }
  }
  match root {
    Some(r) => r
    None => abort("transform produced no root")
  }
}

///|
pub fn Expr::update_positions(self : Expr, other : Expr?) -> Expr {
  match other {
    Some(o) =>
      match o.meta {
        Some(m) =>
          for k in ["line", "col", "start", "end"] {
            match m.get(k) {
              Some(v) => self.get_meta()[k] = v
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  self
}

///|
/// Updates position meta from a token.
pub fn Expr::update_positions_from_token(self : Expr, token : Token) -> Expr {
  let m = self.get_meta()
  m["line"] = Int(token.line)
  m["col"] = Int(token.col)
  m["start"] = Int(token.start)
  m["end"] = Int(token.end)
  self
}

///|
/// Checks the arguments of an expression for errors.
pub fn Expr::error_messages(self : Expr, nargs? : Int = 0) -> Array[String] {
  let errors = []
  for kv in self.kind.arg_types() {
    if kv.1 {
      let missing = match self.args.get(kv.0) {
        None => true
        Some(List(l)) => l.is_empty()
        _ => false
      }
      if missing {
        errors.push(
          "Required keyword: '\{kv.0}' missing for \{class_path(self.kind)}",
        )
      }
    }
  }
  if nargs > 0 &&
    self.kind.is_a(Func) &&
    nargs > self.kind.arg_types().length() &&
    !self.kind.is_var_len_args() {
    errors.push(
      "The number of provided arguments (\{nargs}) is greater than the maximum number of supported arguments (\{self.kind.arg_types().length()})",
    )
  }
  errors
}

///|
fn class_path(kind : Kind) -> String {
  kind.class_path()
}

///|
/// Converts a number literal to a host value: Int64 when integral.
pub fn Expr::to_py_int(self : Expr) -> Int64? {
  match self.kind {
    Literal =>
      if self.is_number() {
        parse_int_str(self.text("this"))
      } else {
        None
      }
    Neg =>
      match self.this() {
        Some(t) =>
          match t.to_py_int() {
            Some(v) => Some(-v)
            None => None
          }
        None => None
      }
    _ => None
  }
}

///|
/// Converts a number literal to a Double.
pub fn Expr::to_py_float(self : Expr) -> Double? {
  match self.kind {
    Literal =>
      if self.is_number() {
        let t = self.text("this")
        Some(@string.parse_double(t)) catch {
          // Python's Decimal handles huge exponents (e.g. 1e1000000); treat a
          // well-formed but out-of-range number as +/- infinity
          _ =>
            if is_float_str(t) {
              Some(
                if t.has_prefix("-") {
                  @double.neg_infinity
                } else {
                  @double.infinity
                },
              )
            } else {
              None
            }
        }
      } else {
        None
      }
    Neg =>
      match self.this() {
        Some(t) =>
          match t.to_py_float() {
            Some(v) => Some(-v)
            None => None
          }
        None => None
      }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Equality and hashing (structural, mirroring Python's __eq__/__hash__)

///|
fn value_eq(a : Value, b : Value, raw : Bool) -> Bool {
  match (a, b) {
    (Node(x), Node(y)) => x == y
    (List(x), List(y)) => {
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        if !value_eq(x[i], y[i], raw) {
          return false
        }
      }
      true
    }
    (Str(x), Str(y)) =>
      if raw {
        x == y
      } else {
        x == y || py_lower(x) == py_lower(y)
      }
    (Bool(x), Bool(y)) => x == y
    (Int(x), Int(y)) => x == y
    (DT(x), DT(y)) => x == y
    (Bool(true), Int(1)) | (Int(1), Bool(true)) => true
    _ => false
  }
}

///|
fn significant(v : Value, raw : Bool) -> Bool {
  if raw {
    v.truthy()
  } else {
    match v {
      Bool(false) => false
      List(l) => !l.is_empty()
      _ => true
    }
  }
}

///|
pub impl Eq for Expr with fn equal(self, other) {
  if physical_equal(self, other) {
    return true
  }
  if self.kind != other.kind {
    return false
  }
  let raw = self.kind.hash_raw_args()
  let mut n1 = 0
  for k, v in self.args {
    if !significant(v, raw) {
      continue
    }
    n1 += 1
    match other.args.get(k) {
      Some(w) => {
        if !significant(w, raw) {
          return false
        }
        if !value_eq(v, w, raw) {
          return false
        }
      }
      None => return false
    }
  }
  let mut n2 = 0
  for _, w in other.args {
    if significant(w, raw) {
      n2 += 1
    }
  }
  n1 == n2
}

///|
fn hash_value(hasher : Hasher, v : Value, raw : Bool) -> Unit {
  match v {
    Node(e) => hasher.combine_int(e.hash())
    List(l) => {
      hasher.combine_int(l.length())
      for x in l {
        hash_value(hasher, x, raw)
      }
    }
    Str(s) => hasher.combine_string(if raw { s } else { py_lower(s) })
    Bool(b) => hasher.combine_int(if b { 1 } else { 0 })
    Int(i) => hasher.combine_int(i)
    DT(d) => hasher.combine_int(d.id() + 1000)
  }
}

///|
pub impl Hash for Expr with fn hash_combine(self, hasher) {
  hasher.combine_int(self.kind.id())
  let raw = self.kind.hash_raw_args()
  let keys = []
  for k, v in self.args {
    if significant(v, raw) {
      keys.push(k)
    }
  }
  keys.sort()
  for k in keys {
    hasher.combine_string(k)
    hash_value(hasher, self.args[k], raw)
  }
}

// ---------------------------------------------------------------------------
// Selectable / Query properties

///|
/// `Selectable.selects`: the projections of a query-like expression.
pub fn Expr::selects(self : Expr) -> Array[Expr] {
  match self.kind.owner_selects() {
    Some(Select) => self.expressions()
    Some(SetOperation) => {
      let mut e = self
      while e.kind.is_a(SetOperation) {
        match e.this() {
          Some(t) => e = t.unnest()
          None => break
        }
      }
      if e.kind.owner_selects() is Some(_) {
        e.selects()
      } else {
        []
      }
    }
    Some(Table) => []
    Some(DDL) =>
      match self.expression() {
        Some(e) if e.kind.is_a(Query) => e.selects()
        _ => []
      }
    Some(UDTF) =>
      match self.arg("alias") {
        Some(a) => a.list("columns")
        None => []
      }
    Some(Unnest) => {
      let columns = match self.arg("alias") {
        Some(a) => a.list("columns")
        None => []
      }
      match self.get("offset") {
        Some(Node(o)) => columns + [o]
        Some(Bool(true)) => columns + [to_identifier("offset")]
        _ => columns
      }
    }
    Some(Lateral) => {
      let columns = match self.arg("alias") {
        Some(a) => a.list("columns")
        None => []
      }
      match self.this() {
        Some(t) if t.kind == Unnest =>
          match t.arg("offset") {
            Some(o) if o.kind == Identifier => columns + [o]
            _ => columns
          }
        _ => columns
      }
    }
    Some(DerivedTable) =>
      match self.this() {
        Some(t) if t.kind.is_a(Query) => t.selects()
        _ => []
      }
    Some(k) if k == Values || k == Query => []
    // Classes whose MRO puts `Expression` before the trait defining `selects`
    // (e.g. `Values(Expression, UDTF)`, `Subquery`, `CTE`) resolve to that trait in Python.
    None if self.kind.is_a(UDTF) =>
      match self.arg("alias") {
        Some(a) => a.list("columns")
        None => []
      }
    None if self.kind.is_a(DerivedTable) =>
      match self.this() {
        Some(t) if t.kind.is_a(Query) => t.selects()
        _ => []
      }
    None if self.kind.is_a(DDL) =>
      match self.expression() {
        Some(e) if e.kind.is_a(Query) => e.selects()
        _ => []
      }
    _ => []
  }
}

///|
/// `Selectable.named_selects`: output names of the projections.
pub fn Expr::named_selects(self : Expr) -> Array[String] {
  match self.kind.owner_named_selects() {
    Some(Select) => {
      let out = []
      for e in self.expressions() {
        if !e.alias_or_name().is_empty() {
          out.push(e.output_name())
        } else if e.kind == Aliases {
          for a in e.expressions() {
            out.push(a.name())
          }
        }
      }
      out
    }
    Some(SetOperation) => {
      let mut expr = self
      while expr.kind.is_a(SetOperation) {
        if expr.has("by_name") {
          let left = expr.this().unwrap().unnest().named_selects()
          let right = expr.expression().unwrap().unnest().named_selects()
          let out = []
          for n in left + right {
            if !out.contains(n) {
              out.push(n)
            }
          }
          return out
        }
        expr = expr.this().unwrap().unnest()
      }
      expr.selects().map(s => s.output_name())
    }
    Some(Table) => []
    Some(DDL) =>
      match self.expression() {
        Some(e) if e.kind.is_a(Query) => e.named_selects()
        _ => []
      }
    _ => self.selects().map(s => s.output_name())
  }
}

///|
/// `Query.ctes`
pub fn Expr::ctes(self : Expr) -> Array[Expr] {
  match self.arg("with_") {
    Some(w) => w.expressions()
    None => []
  }
}
