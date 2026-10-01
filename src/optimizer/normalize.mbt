// Port of sqlglot/optimizer/normalize.py.

///|
/// Rewrite the AST into conjunctive normal form (or disjunctive normal form if `dnf`).
pub fn normalize(
  expression : @core.Expr,
  dnf? : Bool = false,
  max_distance? : Int = 128,
) -> @core.Expr raise @core.SqlglotError {
  let simplifier = Simplifier::new(annotate_new_expressions=false)
  let mut expression = expression
  let nodes = expression.walk(prune=e => e.kind.is_a(Connector)).collect()
  for node in nodes {
    if !node.kind.is_a(Connector) {
      continue
    }
    if normalized(node, dnf~) {
      continue
    }
    let root = physical_equal(node, expression)
    let original = node.copy()
    node.transform(
      e => Some(simplifier.rewrite_between(e) catch { _ => e }),
      copy=false,
    )
    |> ignore
    let distance = normalization_distance(node, dnf~, max=max_distance)
    if distance > max_distance {
      return expression
    }
    let result = while_changing(node, e => distributive_law(
      e, dnf, max_distance, simplifier,
    )) catch {
      @core.OptimizeError(_) => {
        node.replace(Some(original)) |> ignore
        if root {
          return original
        }
        return expression
      }
      e => raise e
    }
    let node = node.replace(Some(result)).unwrap()
    if root {
      expression = node
    }
  }
  expression
}

///|
/// Applies `func` until the expression's hash stops changing.
fn while_changing(
  expression : @core.Expr,
  func : (@core.Expr) -> @core.Expr raise @core.SqlglotError,
) -> @core.Expr raise @core.SqlglotError {
  let mut expression = expression
  for ;; {
    let start_hash = expression.hash()
    expression = func(expression)
    if expression.hash() == start_hash {
      break
    }
  }
  expression
}

///|
/// Checks whether a given expression is in a normal form of interest.
pub fn normalized(expression : @core.Expr, dnf? : Bool = false) -> Bool {
  let (ancestor, root) : (@core.Kind, @core.Kind) = if dnf {
    (And, Or)
  } else {
    (Or, And)
  }
  !find_all_in_scope(expression, [root]).any(connector => connector.find_ancestor([
      ancestor,
    ])
    is Some(_))
}

///|
/// The difference in the number of predicates between a given expression and its
/// normalized form.
pub fn normalization_distance(
  expression : @core.Expr,
  dnf? : Bool = false,
  max? : Int = 2147483647,
) -> Int {
  let total = Ref(-(expression.find_all([Connector]).count() + 1))
  predicate_lengths(expression, dnf, max, 0, length => {
    total.val += length
    total.val <= max
  })
  |> ignore
  total.val
}

///|
/// Emits the predicate lengths when expanded to normalized form; `emit` returns false
/// to stop early. Returns false if stopped.
fn predicate_lengths(
  expression : @core.Expr,
  dnf : Bool,
  max : Int,
  depth : Int,
  emit : (Int) -> Bool,
) -> Bool {
  if depth > max {
    return emit(depth)
  }
  let expression = expression.unnest()
  if !expression.kind.is_a(Connector) {
    return emit(1)
  }
  let depth = depth + 1
  let left = expression.this_()
  let right = expression.expression_()
  let distributes = if dnf {
    expression.kind.is_a(And)
  } else {
    expression.kind.is_a(Or)
  }
  if distributes {
    predicate_lengths(left, dnf, max, depth, a => predicate_lengths(
      right,
      dnf,
      max,
      depth,
      b => emit(a + b),
    ))
  } else {
    predicate_lengths(left, dnf, max, depth, emit) &&
    predicate_lengths(right, dnf, max, depth, emit)
  }
}

///|
/// Python `exp.replace_children(expression, fun)`.
fn replace_children(
  expression : @core.Expr,
  fun : (@core.Expr) -> @core.Expr raise @core.SqlglotError,
) -> Unit raise @core.SqlglotError {
  for k, v in expression.args.copy() {
    match v {
      List(l) => {
        let new_nodes : Array[@core.Value] = []
        for cn in l {
          match cn {
            Node(e) => new_nodes.push(Node(fun(e)))
            other => new_nodes.push(other)
          }
        }
        expression.set(k, @core.Value::List(new_nodes))
      }
      Node(e) => expression.set(k, fun(e))
      _ => ()
    }
  }
}

///|
/// x OR (y AND z) -> (x OR y) AND (x OR z)
fn distributive_law(
  expression : @core.Expr,
  dnf : Bool,
  max_distance : Int,
  simplifier : Simplifier,
) -> @core.Expr raise @core.SqlglotError {
  if normalized(expression, dnf~) {
    return expression
  }
  let distance = normalization_distance(expression, dnf~, max=max_distance)
  if distance > max_distance {
    raise @core.OptimizeError(
      "Normalization distance \{distance} exceeds max \{max_distance}",
    )
  }
  replace_children(expression, e => distributive_law(
    e, dnf, max_distance, simplifier,
  ))
  let (to_exp, from_exp) : (@core.Kind, @core.Kind) = if dnf {
    (Or, And)
  } else {
    (And, Or)
  }
  if expression.kind.is_a(from_exp) {
    let operands = expression.unnest_operands()
    let a = operands[0]
    let b = operands[1]
    if a.kind.is_a(to_exp) && b.kind.is_a(to_exp) {
      if a.find_all([Connector]).count() > b.find_all([Connector]).count() {
        return distribute(a, b, from_exp, to_exp, simplifier)
      }
      return distribute(b, a, from_exp, to_exp, simplifier)
    }
    if a.kind.is_a(to_exp) {
      return distribute(b, a, from_exp, to_exp, simplifier)
    }
    if b.kind.is_a(to_exp) {
      return distribute(a, b, from_exp, to_exp, simplifier)
    }
  }
  expression
}

///|
fn combine2(kind : @core.Kind, a : @core.Expr, b : @core.Expr, copy : Bool) -> @core.Expr {
  let a = if copy { a.copy() } else { a }
  let b = if copy { b.copy() } else { b }
  @core.combine_conditions([a, b], kind)
}

///|
fn distribute(
  a : @core.Expr,
  b : @core.Expr,
  from_kind : @core.Kind,
  to_kind : @core.Kind,
  simplifier : Simplifier,
) -> @core.Expr raise @core.SqlglotError {
  if a.kind.is_a(Connector) && a.kind.is_a(b.kind) {
    replace_children(a, c => combine2(
      to_kind,
      simplifier.uniq_sort(
        flatten_connector(combine2(from_kind, c, b.this_(), true)),
        true,
      ),
      simplifier.uniq_sort(
        flatten_connector(combine2(from_kind, c, b.expression_(), true)),
        true,
      ),
      false,
    ))
    return a
  }
  combine2(
    to_kind,
    simplifier.uniq_sort(
      flatten_connector(combine2(from_kind, a, b.this_(), true)),
      true,
    ),
    simplifier.uniq_sort(
      flatten_connector(combine2(from_kind, a, b.expression_(), true)),
      true,
    ),
    false,
  )
}
