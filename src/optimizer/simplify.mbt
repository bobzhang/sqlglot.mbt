// Port of sqlglot/optimizer/simplify.py.

///|
/// Removes redundant parentheses around `expression` when they're not needed.
pub fn simplify_parens(
  expression : @core.Expr,
  dialect : @core.Dialect,
) -> @core.Expr {
  if !expression.kind.is_a(Paren) {
    return expression
  }
  let this = match expression.this() {
    Some(t) => t
    None => return expression
  }
  let parent = expression.parent
  let parent_kind_is = fn(kinds : Array[@core.Kind]) {
    match parent {
      Some(p) => p.kind.is_any(kinds)
      None => false
    }
  }
  let parent_is_predicate = parent_kind_is([Predicate])
  if this.kind.is_a(Select) {
    return expression
  }
  if parent_kind_is([SubqueryPredicate, Bracket]) {
    return expression
  }
  if dialect.cfg.requires_parenthesized_struct_access && parent_kind_is([Dot]) {
    match parent.unwrap().expression() {
      Some(r) if r.kind == Identifier || r.kind.is_a(Star) => return expression
      _ => ()
    }
  }
  if this.kind.is_any([Predicate, Not]) {
    if parent_is_predicate ||
      parent_kind_is([Neg, BitwiseNot]) ||
      (parent_kind_is([Binary]) && !parent_kind_is([Connector])) {
      return expression
    }
    return this
  }
  if !parent_kind_is([Condition, Binary]) ||
    parent_kind_is([Paren]) ||
    !this.kind.is_a(Binary) ||
    (this.kind.is_a(Add) && parent_kind_is([Add])) ||
    (this.kind.is_a(Mul) && parent_kind_is([Mul])) ||
    (this.kind.is_a(Mul) && parent_kind_is([Add, Sub])) {
    return this
  }
  expression
}
