// Ports of the sqlglot/transforms.py (and related) functions used by the base Generator.

///|
/// Some dialects only allow CTEs to be defined at the top-level. This moves all
/// nested CTEs to the top level (Python `transforms.move_ctes_to_top_level`).
pub fn move_ctes_to_top_level(expression : Expr) -> Expr {
  let mut top_level_with = expression.arg("with_")
  let it = expression.find_all([With])
  while it.next() is Some(inner_with) {
    match inner_with.parent {
      Some(p) if physical_equal(p, expression) => continue
      _ => ()
    }
    match top_level_with {
      None => {
        let w = inner_with.pop()
        top_level_with = Some(w)
        expression.set("with_", w)
      }
      Some(tlw) => {
        if inner_with.has("recursive") {
          tlw.set("recursive", true)
        }
        let parent_cte = inner_with.find_ancestor([CTE])
        inner_with.pop() |> ignore
        let existing = tlw.expressions()
        match parent_cte {
          Some(pc) => {
            let mut i = 0
            while i < existing.length() && !(existing[i] == pc) {
              i += 1
            }
            if i >= existing.length() {
              abort("ValueError: CTE is not in list")
            }
            let new_exprs = existing[:i].to_owned() +
              inner_with.expressions() +
              existing[i:].to_owned()
            tlw.set("expressions", new_exprs)
          }
          None => tlw.set("expressions", existing + inner_with.expressions())
        }
      }
    }
  }
  expression
}

///|
/// Python `optimizer.canonicalize.ensure_bools`.
fn canonicalize_ensure_bools(
  expression : Expr,
  replace_func : (Expr) -> Unit,
) -> Expr {
  if expression.kind.is_a(Connector) {
    match expression.arg("this") {
      Some(l) => replace_func(l)
      None => ()
    }
    match expression.arg("expression") {
      Some(r) => replace_func(r)
      None => ()
    }
  } else if expression.kind.is_a(Not) {
    match expression.this() {
      Some(t) => replace_func(t)
      None => ()
    }
  } else if expression.kind.is_a(If) &&
    !(match expression.parent {
      Some(p) => p.kind.is_a(Case) && p.has("this")
      None => false
    }) {
    match expression.this() {
      Some(t) => replace_func(t)
      None => ()
    }
  } else if expression.kind.is_any([Where, Having]) {
    match expression.this() {
      Some(t) => replace_func(t)
      None => ()
    }
  }
  expression
}

///|
/// Converts numeric values used in conditions into explicit boolean expressions
/// (Python `transforms.ensure_bools`).
pub fn ensure_bools(expression : Expr) -> Expr {
  let numeric : Array[DType] = [DType::UNKNOWN]
  for d in dtype_numeric_types {
    numeric.push(d)
  }
  fn ensure_bool(node : Expr) -> Unit {
    if node.is_number() ||
      (!node.kind.is_a(SubqueryPredicate) && node.is_type(numeric)) ||
      (node.kind.is_a(Column) && node.type_ is None) {
      node.replace(Some(exp_neq(node, literal_int(0)))) |> ignore
    }
  }

  let it = expression.walk()
  while it.next() is Some(node) {
    canonicalize_ensure_bools(node, ensure_bool) |> ignore
  }
  expression
}

///|
/// Python `optimizer.scope.walk_in_scope`: visits all nodes in the syntax tree,
/// stopping at nodes that start child scopes.
pub fn gen_walk_in_scope(expression : Expr, out : Array[Expr]) -> Unit {
  let stack : Array[Expr] = [expression]
  while stack.pop() is Some(node) {
    out.push(node)
    if !physical_equal(node, expression) && node.kind.is_any([CTE, Query]) {
      let parent_kind_is = fn(kinds : Array[Kind]) {
        match node.parent {
          Some(p) => p.kind.is_any(kinds)
          None => false
        }
      }
      let is_derived_table = node.kind.is_a(Subquery) &&
        (
          node.alias() != "" ||
          (match node.this() {
            Some(t) => t.kind.is_any([Select, SetOperation])
            None => false
          })
        )
      if node.kind.is_a(CTE) ||
        (parent_kind_is([From, Join]) && is_derived_table) ||
        parent_kind_is([UDTF]) ||
        node.kind.is_any([Select, SetOperation]) {
        if node.kind.is_any([Subquery, UDTF]) {
          for key in ["joins", "laterals", "pivots"] {
            for arg in node.list(key) {
              gen_walk_in_scope(arg, out)
            }
          }
        }
        continue
      }
    }
    let values = []
    for _, v in node.args {
      values.push(v)
    }
    for i = values.length() - 1; i >= 0; i = i - 1 {
      match values[i] {
        List(l) =>
          for j = l.length() - 1; j >= 0; j = j - 1 {
            match l[j] {
              Node(e) => stack.push(e)
              _ => ()
            }
          }
        Node(e) => stack.push(e)
        _ => ()
      }
    }
  }
}

///|
/// Python `optimizer.scope.find_all_in_scope`.
pub fn gen_find_all_in_scope(
  expression : Expr,
  kinds : ArrayView[Kind],
) -> Array[Expr] {
  let all = []
  gen_walk_in_scope(expression, all)
  all.filter(n => n.kind.is_any(kinds))
}
