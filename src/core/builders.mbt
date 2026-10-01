// Expression builders (port of parts of sqlglot/expressions/core.py and builders.py).

///|
/// `exp.column(name)` for a simple (possibly quoted) column name.
pub fn column_of(name : String, table? : String, quoted? : Bool) -> Expr {
  let col = mk1(Column, to_identifier(name, quoted?))
  match table {
    Some(t) => col.set("table", to_identifier(t, quoted?))
    None => ()
  }
  col
}

///|
/// `exp.column(col, table, db, catalog, fields=...)` with identifier expressions.
pub fn column_from_parts(
  col : Expr,
  table? : Expr?,
  db? : Expr?,
  catalog? : Expr?,
  fields? : Array[Expr] = [],
) -> Expr {
  let c = mk(Column, [
    ("this", col),
    (
      "table",
      match table {
        Some(t) => t
        None => None
      },
    ),
    (
      "db",
      match db {
        Some(t) => t
        None => None
      },
    ),
    (
      "catalog",
      match catalog {
        Some(t) => t
        None => None
      },
    ),
  ])
  if fields.is_empty() {
    c
  } else {
    let mut this = c
    for f in fields {
      this = mk(Dot, [("this", this), ("expression", f)])
    }
    this
  }
}

///|
/// Copies an identifier expression (Python `to_identifier(identifier)`).
pub fn to_identifier_expr(e : Expr) -> Expr {
  e.copy()
}

///|
/// `Dot.build(expressions)`
pub fn dot_build(expressions : Array[Expr]) -> Expr {
  let mut this = expressions[0]
  for i in 1..<expressions.length() {
    this = mk(Dot, [("this", this), ("expression", expressions[i])])
  }
  this
}

///|
/// `Column.to_dot()`: converts the column into a dot expression.
pub fn Expr::to_dot(self : Expr, include_dots? : Bool = true) -> Expr {
  let parts = self.parts()
  let mut parent = self.parent
  if include_dots {
    while parent is Some(p) && p.kind == Dot {
      match p.expression() {
        Some(e) => parts.push(e)
        None => ()
      }
      parent = p.parent
    }
  }
  if parts.length() > 1 {
    dot_build(parts.map(p => p.copy()))
  } else if parts.length() == 1 {
    parts[0]
  } else {
    self
  }
}

///|
/// `Table.to_column()`
pub fn Expr::to_column(self : Expr, copy? : Bool = true) -> Expr {
  let parts = self.parts()
  let last_part = parts[parts.length() - 1]
  let mut col = if last_part.kind == Identifier {
    let first4 = parts[0:min_int(4, parts.length())].to_array()
    first4.rev_in_place()
    let fields = parts[min_int(4, parts.length()):].to_array()
    let m = fn(e : Expr) { if copy { e.copy() } else { e } }
    column_from_parts(
      m(first4[0]),
      table=first4.get(1).map(m),
      db=first4.get(2).map(m),
      catalog=first4.get(3).map(m),
      fields=fields.map(m),
    )
  } else {
    last_part
  }
  match self.arg("alias") {
    Some(alias) => col = alias_expr(col, alias.this(), copy~)
    None => ()
  }
  col
}

///|
/// `exp.alias_(expression, alias)` with an identifier alias expression.
pub fn alias_expr(e : Expr, alias : Expr?, copy? : Bool = true) -> Expr {
  let e = maybe_copy(e, copy)
  let alias = match alias {
    Some(a) => Some(if copy { a.copy() } else { a })
    None => None
  }
  if e.kind.has_arg("alias") && e.kind != Window {
    e.set("alias", alias)
    return e
  }
  mk(Alias, [("this", e), ("alias", alias)])
}

///|
/// `exp.alias_(expression, name)` with a string alias.
pub fn alias_(
  e : Expr,
  name : String,
  quoted? : Bool,
  copy? : Bool = true,
) -> Expr {
  alias_expr(e, Some(to_identifier(name, quoted?)), copy~)
}

///|
/// `exp.alias_(expression, name, table=True)`
pub fn alias_table(
  e : Expr,
  name : String,
  columns? : Array[String] = [],
) -> Expr {
  let table_alias = mk1(TableAlias, to_identifier(name))
  e.set("alias", table_alias)
  for c in columns {
    table_alias.append("columns", to_identifier(c))
  }
  e
}

///|
/// `Query.subquery(alias, copy)`
pub fn Expr::subquery(
  self : Expr,
  alias? : String,
  copy? : Bool = true,
) -> Expr {
  let instance = maybe_copy(self, copy)
  let alias = match alias {
    Some(a) if !a.is_empty() => Some(mk1(TableAlias, to_identifier(a)))
    _ => None
  }
  mk(Subquery, [("this", instance), ("alias", alias)])
}

///|
/// `Func.from_arg_list(args)`
pub fn from_arg_list(kind : Kind, args : Array[Expr]) -> Expr {
  let arg_types = kind.arg_types()
  let m : Map[String, Value] = Map([])
  if kind.is_var_len_args() {
    let var_key = kind.var_len_arg_key()
    let mut var_len_index = arg_types.length()
    for i, kv in arg_types {
      if kv.0 == var_key {
        var_len_index = i
        break
      }
    }
    for i, a in args {
      if i < var_len_index {
        m[arg_types[i].0] = Node(a)
      }
    }
    let rest = []
    for i in var_len_index..<args.length() {
      rest.push(Node(args[i]))
    }
    m[var_key] = List(rest)
  } else {
    for i, a in args {
      if i < arg_types.length() {
        m[arg_types[i].0] = Node(a)
      }
    }
  }
  Expr::new(kind, m)
}

///|
/// A builder that calls `from_arg_list`.
pub fn from_arg_list_builder(kind : Kind) -> FuncBuilder {
  fn(args, _p) { from_arg_list(kind, args) }
}

///|
/// Combines conditions with a connector (And / Or / Xor), wrapping operands that are
/// themselves connectors in parentheses (Python `_combine` with `wrap=True`).
pub fn combine_conditions(
  conditions : Array[Expr],
  connector : Kind,
  wrap? : Bool = true,
) -> Expr {
  let wrap_ = fn(e : Expr) {
    if wrap && e.kind.is_a(Connector) {
      mk1(Paren, e)
    } else {
      e
    }
  }
  let mut this = conditions[0]
  if conditions.length() > 1 {
    this = wrap_(this)
  }
  for i in 1..<conditions.length() {
    this = mk(connector, [("this", this), ("expression", wrap_(conditions[i]))])
  }
  this
}

///|
/// `exp.and_(...)` for expressions.
pub fn and_(conditions : Array[Expr], wrap? : Bool = true) -> Expr {
  combine_conditions(conditions, And, wrap~)
}

///|
/// `exp.or_(...)` for expressions.
pub fn or_(conditions : Array[Expr], wrap? : Bool = true) -> Expr {
  combine_conditions(conditions, Or, wrap~)
}

///|
/// `exp.not_(expression)`.
pub fn not_(e : Expr) -> Expr {
  mk1(Not, if e.kind.is_a(Connector) { mk1(Paren, e) } else { e })
}

///|
/// `exp.paren(expression)`.
pub fn paren(e : Expr) -> Expr {
  mk1(Paren, e)
}

///|
/// `exp.apply_index_offset`
pub fn apply_index_offset(
  this : Expr,
  expressions : Array[Expr],
  offset : Int,
  dialect : Dialect,
) -> Array[Expr] {
  // Same logic as the generator's version (falls back to the minimal type annotation
  // when the optimizer isn't available), so that parse/generate offsets round-trip.
  gen_apply_index_offset(this, expressions, offset, dialect) catch {
    _ => expressions
  }
}

///|
/// `normalize_identifiers(expression, dialect)` (sqlglot.optimizer.normalize_identifiers).
pub fn normalize_identifiers(
  expression : Expr,
  dialect : Dialect,
  store_original_column_identifiers? : Bool = false,
) -> Expr {
  let it = expression.walk(prune=n => n.meta_bool("case_sensitive"))
  while it.next() is Some(node) {
    if node.meta_bool("case_sensitive") {
      continue
    }
    if store_original_column_identifiers &&
      node.kind.is_any([Column, Dot]) &&
      !(match node.parent {
        Some(p) => p.kind == Dot
        None => false
      }) {
      if node.kind.is_a(Column) {
        node.get_meta()["dot_parts"] = List(
          node.parts().map(p => Str(p.name())),
        )
      } else if !node.is_star() {
        let mut root = node
        let dot_parts = []
        while root.kind == Dot {
          dot_parts.push(
            match root.expression() {
              Some(e) => e.name()
              None => ""
            },
          )
          match root.this() {
            Some(t) => root = t
            None => break
          }
        }
        dot_parts.rev_in_place()
        let parts = if root.kind.is_a(Column) {
          root.parts().map(p => p.name()) + dot_parts
        } else {
          dot_parts
        }
        root.get_meta()["dot_parts"] = List(parts.map(p => Str(p)))
      }
    }
    if node.kind == Identifier {
      dialect.normalize_identifier(node) |> ignore
    }
  }
  expression
}

///|
/// `exp.parse_identifier(name, dialect)`
pub fn parse_identifier(name : String, dialect? : Dialect) -> Expr {
  if is_safe_identifier(name) {
    return mk(Identifier, [("this", name), ("quoted", false)])
  }
  parse_one(name, dialect?, into=[Identifier]) catch {
    _ => to_identifier(name)
  }
}

///|
/// Python `ensure_list(x)` for an optional expression.
pub fn opt_list(e : Expr?) -> Array[Expr] {
  match e {
    Some(x) => [x]
    None => []
  }
}
