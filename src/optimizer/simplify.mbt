// Port of sqlglot/optimizer/simplify.py: the Simplifier.

///|
/// Rewrite the AST to simplify expressions.
pub fn simplify(
  expression : @core.Expr,
  constant_propagation? : Bool = false,
  coalesce_simplification? : Bool = false,
  dialect? : @core.Dialect,
) -> @core.Expr raise @core.SqlglotError {
  Simplifier::new(dialect?).simplify(
    expression,
    constant_propagation~,
    coalesce_simplification~,
  )
}

///|
pub struct Simplifier {
  dialect : @core.Dialect
  annotate_new_expressions : Bool
  annotator : TypeAnnotator
}

///|
pub fn Simplifier::new(
  dialect? : @core.Dialect,
  annotate_new_expressions? : Bool = true,
) -> Simplifier {
  let dialect = get_dialect(dialect)
  let schema = MappingSchema::new(dialect~) catch {
    _ => abort("unreachable: empty schema")
  }
  {
    dialect,
    annotate_new_expressions,
    annotator: TypeAnnotator::new(schema, overwrite_types=false),
  }
}

///|
/// The `annotate_types_on_change` decorator.
fn Simplifier::on_change(
  self : Simplifier,
  expression : @core.Expr,
  new_expression : @core.Expr?,
) -> @core.Expr? raise @core.SqlglotError {
  match new_expression {
    None => None
    Some(ne) => {
      if self.annotate_new_expressions && expression != ne {
        self.annotator.clear()
        let ne = self.annotator.annotate(ne, annotate_scope=false)
        ne.set_type(expression.get_type())
        return Some(ne)
      }
      Some(ne)
    }
  }
}

///|
fn Simplifier::changed(
  self : Simplifier,
  expression : @core.Expr,
  new_expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  self.on_change(expression, Some(new_expression)).unwrap()
}

///|
let complement_comparisons : Map[@core.Kind, @core.Kind] = Map::from_array([
  (LT, GTE),
  (GT, LTE),
  (LTE, GT),
  (GTE, LT),
  (EQ, NEQ),
  (NEQ, EQ),
])

///|
let inverse_comparisons : Map[@core.Kind, @core.Kind] = Map::from_array([
  (LT, GT),
  (GT, LT),
  (LTE, GTE),
  (GTE, LTE),
])

///|
let inverse_date_ops : Map[@core.Kind, @core.Kind] = Map::from_array([
  (DateAdd, Sub),
  (DateSub, Add),
  (DatetimeAdd, Sub),
  (DatetimeSub, Add),
])

///|
let inverse_ops : Map[@core.Kind, @core.Kind] = Map::from_array([
  (DateAdd, Sub),
  (DateSub, Add),
  (DatetimeAdd, Sub),
  (DatetimeSub, Add),
  (Add, Sub),
  (Sub, Add),
])

///|
fn is_comparison(e : @core.Expr) -> Bool {
  e.kind.is_any([LT, LTE, GT, GTE, EQ, NEQ, Is])
}

///|
pub fn Simplifier::simplify(
  self : Simplifier,
  expression : @core.Expr,
  constant_propagation? : Bool = false,
  coalesce_simplification? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  let mut expression = expression
  let wheres = []
  let joins = []
  for node in expression.walk(prune=n => n.kind.is_a(Condition) || is_final(n)) {
    if is_final(node) {
      continue
    }
    match node.arg("group") {
      Some(group) if node.kind.owner_selects() is Some(_) => {
        let groups = group.expressions()
        group.get_meta()[final_key] = Bool(true)
        for s in node.selects() {
          for n in s.walk() {
            if groups.contains(n) {
              s.get_meta()[final_key] = Bool(true)
              break
            }
          }
        }
        match node.arg("having") {
          Some(having) =>
            for n in having.walk() {
              if groups.contains(n) {
                having.get_meta()[final_key] = Bool(true)
                break
              }
            }
          None => ()
        }
      }
      _ => ()
    }
    if node.kind.is_a(Condition) {
      let mut current = node
      for ;; {
        let start_hash = current.hash()
        current = self.simplify_one(
          current, constant_propagation, coalesce_simplification,
        )
        if current.hash() == start_hash {
          break
        }
      }
      if physical_equal(node, expression) {
        expression = current
      }
    } else if node.kind.is_a(Where) {
      wheres.push(node)
    } else if node.kind.is_a(Join) {
      match node.arg("match_condition") {
        Some(m) => m.get_meta()[final_key] = Bool(true)
        None => ()
      }
      joins.push(node)
    }
  }
  for where_ in wheres {
    if always_true(where_.this()) && !parent_is(where_, [Filter]) {
      where_.pop() |> ignore
    }
  }
  for join in joins {
    let kind = @core.py_upper(join.text("kind"))
    if always_true(join.arg("on")) &&
      !join.has("using") &&
      !join.has("method") &&
      join.text("side") == "" &&
      (kind == "" || kind == "INNER") {
      join.arg("on").unwrap().pop() |> ignore
      join.set("side", @core.null_arg)
      join.set("kind", "CROSS")
    }
  }
  expression
}

///|
fn Simplifier::simplify_one(
  self : Simplifier,
  expression : @core.Expr,
  constant_propagation : Bool,
  coalesce_simplification : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let pre_stack = [expression]
  let post_stack : Array[(@core.Expr, @core.Expr?)] = []
  let mut node = expression
  while pre_stack.pop() is Some(original) {
    node = original
    if !is_simplifiable(node) {
      if node.kind.is_a(Query) {
        self.simplify(node, constant_propagation~, coalesce_simplification~)
        |> ignore
      }
      continue
    }
    let parent = node.parent
    let root = physical_equal(node, expression)
    node = self.rewrite_between(node)
    node = self.uniq_sort(node, root)
    node = self.absorb_and_eliminate(node, root)
    node = self.simplify_concat(node)
    node = self.simplify_conditionals(node)
    if constant_propagation {
      node = propagate_constants(node, root)
    }
    if !physical_equal(node, original) {
      original.replace(Some(node)) |> ignore
    }
    for n in node.iter_expressions(reverse=true) {
      if !is_final(n) {
        pre_stack.push(n)
      }
    }
    post_stack.push((node, parent))
  }
  while post_stack.pop() is Some((original, parent)) {
    let root = physical_equal(original, expression)
    for k, v in original.args.copy() {
      original.set(k, v)
    }
    node = self.simplify_not(original)
    node = flatten_connector(node)
    node = self.simplify_connectors(node, root)
    node = self.remove_complements(node, root)
    if coalesce_simplification {
      node = self.simplify_coalesce(node)
    }
    node.set_parent_ref(parent)
    node = self.simplify_literals(node, root)
    node = self.simplify_equality(node)
    node = simplify_parens(node, self.dialect)
    node = self.simplify_datetrunc(node)
    node = self.sort_comparison(node)
    node = self.simplify_startswith(node)
    if !physical_equal(node, original) {
      original.replace(Some(node)) |> ignore
    }
  }
  node
}

///|
/// Rewrite x between y and z to x >= y AND x <= z.
pub fn Simplifier::rewrite_between(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if !expression.kind.is_a(Between) {
    return expression
  }
  let negate = parent_is(expression, [Not])
  let mut result = @core.and_(
    [
      @core.mk2(GTE, expression.this_().copy(), expression.arg("low")),
      @core.mk2(LTE, expression.this_().copy(), expression.arg("high")),
    ],
    copy=false,
  )
  if negate {
    result = @core.paren(result, copy=false)
  }
  self.changed(expression, result)
}

///|
/// Demorgan's Law.
pub fn Simplifier::simplify_not(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  self.changed(expression, self.simplify_not_impl(expression))
}

///|
fn null_and_true(parent : @core.Expr?) -> @core.Expr {
  parenthesize_nested_connector(
    @core.and_([@core.null_(), @core.true_()], copy=false),
    parent,
  )
}

///|
fn Simplifier::simplify_not_impl(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr {
  if !expression.kind.is_a(Not) {
    return expression
  }
  let this = expression.this_()
  if is_null(Some(this)) {
    return null_and_true(expression.parent)
  }
  match complement_comparisons.get(this.kind) {
    Some(complement) => {
      let mut right = this.expression_()
      match right.kind {
        All => right = @core.mk1(Any, right.this())
        Any => right = @core.mk1(All, right.this())
        _ => ()
      }
      return @core.paren(@core.mk2(complement, this.this(), right), copy=false)
    }
    None => ()
  }
  if this.kind.is_a(Paren) {
    let condition = this.unnest()
    if condition.kind.is_a(And) {
      return @core.paren(
        @core.or_(
          [
            @core.not_(condition.this_(), copy=false),
            @core.not_(condition.expression_(), copy=false),
          ],
          copy=false,
        ),
        copy=false,
      )
    }
    if condition.kind.is_a(Or) {
      return @core.paren(
        @core.and_(
          [
            @core.not_(condition.this_(), copy=false),
            @core.not_(condition.expression_(), copy=false),
          ],
          copy=false,
        ),
        copy=false,
      )
    }
    if is_null(Some(condition)) {
      return null_and_true(expression.parent)
    }
  }
  if always_true(Some(this)) {
    return @core.false_()
  }
  if is_false(Some(this)) {
    return @core.true_()
  }
  if this.kind.is_a(Not) && self.dialect.cfg.safe_to_eliminate_double_negation {
    let inner = this.this_()
    if inner.is_type([BOOLEAN]) {
      return inner
    }
  }
  expression
}

///|
pub fn Simplifier::simplify_connectors(
  self : Simplifier,
  expression : @core.Expr,
  root : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let mut expression = expression
  let original = expression
  if expression.kind.is_a(Connector) {
    let mut original_parent = expression.parent
    expression = self.flat_simplify(
      expression,
      (e, l, r) => self.simplify_connectors_pair(e, l, r),
      root,
      index=connector_flat_index(expression.kind.is_a(Or)),
    )
    if !expression.kind.is_any([Connector, Boolean]) &&
      !expression.is_type([BOOLEAN]) {
      for ;; {
        match original_parent {
          Some(p) if p.kind.is_a(Connector) => break
          Some(p) if p.kind.is_a(Paren) => original_parent = p.parent
          _ => {
            expression = @core.and_([expression, @core.true_()], copy=false)
            break
          }
        }
      }
    }
  }
  self.changed(original, expression)
}

///|
fn Simplifier::simplify_connectors_pair(
  self : Simplifier,
  expression : @core.Expr,
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  let l = Some(left)
  let r = Some(right)
  if expression.kind.is_a(And) {
    if is_false(l) || is_false(r) {
      return Some(@core.false_())
    }
    if is_zero(l) || is_zero(r) {
      return Some(@core.false_())
    }
    if (is_null(l) && is_null(r)) ||
      (is_null(l) && always_true(r)) ||
      (always_true(l) && is_null(r)) {
      return Some(@core.null_())
    }
    if always_true(l) && always_true(r) {
      return Some(@core.true_())
    }
    if always_true(l) {
      return Some(right)
    }
    if always_true(r) {
      return Some(left)
    }
    return self.simplify_comparison(expression, left, right, false)
  } else if expression.kind.is_a(Or) {
    if always_true(l) || always_true(r) {
      return Some(@core.true_())
    }
    if (is_null(l) && is_null(r)) ||
      (is_null(l) && always_false(r)) ||
      (always_false(l) && is_null(r)) {
      return Some(@core.null_())
    }
    if is_false(l) {
      return Some(right)
    }
    if is_false(r) {
      return Some(left)
    }
    return self.simplify_comparison(expression, left, right, true)
  }
  None
}

///|
/// A comparable value extracted from comparison operands.
priv enum CmpVal {
  CNum(PyNum)
  CStr(String)
  CDate(PyDT)
}

///|
fn cmpval_cmp(a : CmpVal, b : CmpVal) -> Int raise @core.SqlglotError {
  match (a, b) {
    (CNum(x), CNum(y)) => pynum_cmp(x, y)
    (CStr(x), CStr(y)) => py_str_cmp(x, y)
    (CDate(x), CDate(y)) => pydt_cmp(x, y)
    _ => raise @core.ValueError("TypeError: incomparable values")
  }
}

///|
fn cmpval_eq(a : CmpVal, b : CmpVal) -> Bool {
  match (a, b) {
    (CNum(x), CNum(y)) => pynum_cmp(x, y) == 0
    (CStr(x), CStr(y)) => x == y
    (CDate(x), CDate(y)) => pydt_eq(x, y)
    _ => false
  }
}

///|
/// A Python set of expressions (structural equality), insertion ordered, with hashed
/// lookups.
priv struct ExprSet {
  items : Array[@core.Expr]
  index : Map[Int, Array[Int]]
}

///|
fn ExprSet::new() -> ExprSet {
  { items: [], index: {}, }
}

///|
fn ExprSet::find(self : ExprSet, x : @core.Expr, h : Int) -> Int {
  match self.index.get(h) {
    Some(bucket) =>
      for i in bucket {
        if self.items[i] == x {
          return i
        }
      }
    None => ()
  }
  -1
}

///|
fn ExprSet::contains(self : ExprSet, x : @core.Expr) -> Bool {
  self.find(x, x.hash()) >= 0
}

///|
/// Adds `x` unless an equal expression is present; returns its position.
fn ExprSet::add(self : ExprSet, x : @core.Expr) -> Int {
  let h = x.hash()
  let i = self.find(x, h)
  if i >= 0 {
    return i
  }
  let i = self.items.length()
  self.items.push(x)
  match self.index.get(h) {
    Some(bucket) => bucket.push(i)
    None => self.index[h] = [i]
  }
  i
}

///|
fn ExprSet::of(xs : Array[@core.Expr]) -> ExprSet {
  let s = ExprSet::new()
  for x in xs {
    s.add(x) |> ignore
  }
  s
}

///|
/// Python set of structurally-equal expressions (insertion ordered).
fn expr_set(xs : Array[@core.Expr]) -> Array[@core.Expr] {
  if xs.length() <= 4 {
    let out = []
    for x in xs {
      if !out.contains(x) {
        out.push(x)
      }
    }
    return out
  }
  ExprSet::of(xs).items
}

///|
fn Simplifier::simplify_comparison(
  self : Simplifier,
  expression : @core.Expr,
  left : @core.Expr,
  right : @core.Expr,
  or_ : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  self.on_change(
    expression,
    self.simplify_comparison_impl(expression, left, right, or_),
  )
}

///|
fn Simplifier::simplify_comparison_impl(
  self : Simplifier,
  expression : @core.Expr,
  left : @core.Expr,
  right : @core.Expr,
  or_ : Bool,
) -> @core.Expr? raise @core.SqlglotError {
  ignore(self)
  if !(is_comparison(left) && is_comparison(right)) {
    return None
  }
  if (left.kind.is_a(Is) && left.has("negate")) ||
    (right.kind.is_a(Is) && right.has("negate")) {
    return None
  }
  let (ll, lr) = match (left.this(), left.expression()) {
    (Some(a), Some(b)) => (a, b)
    _ => return None
  }
  let (rl, rr) = match (right.this(), right.expression()) {
    (Some(a), Some(b)) => (a, b)
    _ => return None
  }
  let largs = expr_set([ll, lr])
  let rargs = expr_set([rl, rr])
  let matching = largs.filter(x => rargs.contains(x))
  let columns = matching.filter(m => !is_constant_expr(m) &&
    m.find([Rand, Randn]) is None)
  if matching.is_empty() || columns.is_empty() {
    return None
  }
  let l_rest = largs.filter(x => !columns.contains(x))
  let r_rest = rargs.filter(x => !columns.contains(x))
  if l_rest.is_empty() || r_rest.is_empty() {
    // StopIteration: Python returns the expression unchanged
    return Some(expression)
  }
  let l = l_rest[0]
  let r = r_rest[0]
  let (lv, rv) = if l.is_number() && r.is_number() {
    match (expr_to_pynum(l), expr_to_pynum(r)) {
      (Some(a), Some(b)) => (CNum(a), CNum(b))
      _ => return None
    }
  } else if l.is_string() && r.is_string() {
    (CStr(l.name()), CStr(r.name()))
  } else {
    let ld = match extract_date(l) {
      Some(d) => d
      None => return None
    }
    let rd = match extract_date(r) {
      Some(d) => d
      None => return None
    }
    (CDate(ld.to_datetime()), CDate(rd.to_datetime()))
  }
  let false_ = if left.meta_get("nonnull") is Some(Bool(true)) &&
    right.meta_get("nonnull") is Some(Bool(true)) {
    Some(@core.false_())
  } else {
    None
  }
  let lt_lte : Array[@core.Kind] = [LT, LTE]
  let gt_gte : Array[@core.Kind] = [GT, GTE]
  for perm in [((left, lv), (right, rv)), ((right, rv), (left, lv))] {
    let ((a, av), (b, bv)) = perm
    if a.kind.is_any(lt_lte) && b.kind.is_any(lt_lte) {
      let c = cmpval_cmp(av, bv)
      return Some(if (if or_ { c > 0 } else { c <= 0 }) { left } else { right })
    }
    if a.kind.is_any(gt_gte) && b.kind.is_any(gt_gte) {
      let c = cmpval_cmp(av, bv)
      return Some(if (if or_ { c < 0 } else { c >= 0 }) { left } else { right })
    }
    if !or_ {
      if a.kind.is_a(LT) && b.kind.is_any(gt_gte) {
        if cmpval_cmp(av, bv) <= 0 {
          return false_
        }
      } else if a.kind.is_a(GT) && b.kind.is_any(lt_lte) {
        if cmpval_cmp(av, bv) >= 0 {
          return false_
        }
      } else if a.kind.is_a(EQ) {
        if b.kind.is_a(LT) {
          return if cmpval_cmp(av, bv) >= 0 { false_ } else { Some(a) }
        }
        if b.kind.is_a(LTE) {
          return if cmpval_cmp(av, bv) > 0 { false_ } else { Some(a) }
        }
        if b.kind.is_a(GT) {
          return if cmpval_cmp(av, bv) <= 0 { false_ } else { Some(a) }
        }
        if b.kind.is_a(GTE) {
          return if cmpval_cmp(av, bv) < 0 { false_ } else { Some(a) }
        }
        if b.kind.is_a(NEQ) {
          return if cmpval_eq(av, bv) { false_ } else { Some(a) }
        }
      }
    }
  }
  None
}

///|
/// Removing complements: A AND NOT A -> FALSE (only for non-NULL A).
pub fn Simplifier::remove_complements(
  self : Simplifier,
  expression : @core.Expr,
  root : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let mut result = expression
  if expression.kind.is_any([And, Or]) && (root || !expression.same_parent()) {
    let op_set = ExprSet::of(expression.flatten().collect())
    for op in op_set.items {
      if op.kind.is_a(Not) && op_set.contains(op.this_()) {
        if expression.meta_get("nonnull") is Some(Bool(true)) {
          result = if expression.kind.is_a(And) {
            @core.false_()
          } else {
            @core.true_()
          }
          break
        }
      }
    }
  }
  self.changed(expression, result)
}

///|
/// Uniq and sort a connector: C AND A AND B AND B -> A AND B AND C.
pub fn Simplifier::uniq_sort(
  self : Simplifier,
  expression : @core.Expr,
  root : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let original = expression
  let mut expression = expression
  if expression.kind.is_a(Connector) && (root || !expression.same_parent()) {
    let flattened = expression.flatten().collect()
    let is_xor = expression.kind.is_a(Xor)
    let combine = fn(xs : Array[@core.Expr]) -> @core.Expr {
      if is_xor {
        @core.combine_conditions(xs, Xor, copy=false)
      } else if original.kind.is_a(And) {
        @core.and_(xs, copy=false)
      } else {
        @core.or_(xs, copy=false)
      }
    }
    let arr : Array[(String, @core.Expr)] = []
    let mut deduped_len = 0
    if is_xor {
      for e in flattened {
        arr.push((gen(e), e))
      }
    } else {
      // dict {gen(e): e}: first position, last value
      let positions : Map[String, Int] = Map([])
      for e in flattened {
        let key = gen(e)
        match positions.get(key) {
          Some(i) => arr[i] = (key, e)
          None => {
            positions[key] = arr.length()
            arr.push((key, e))
          }
        }
      }
      deduped_len = arr.length()
    }
    let mut needs_sort = false
    for i in 1..<arr.length() {
      if py_str_cmp(arr[i].0, arr[i - 1].0) < 0 {
        needs_sort = true
        break
      }
    }
    if needs_sort {
      let sorted = arr.copy()
      sorted.sort_by((a, b) => py_str_cmp(a.0, b.0))
      expression = combine(sorted.map(kv => kv.1))
    } else if !is_xor && deduped_len < flattened.length() {
      let unique_operand = flattened[0]
      if deduped_len == 1 {
        expression = @core.and_([unique_operand, @core.true_()], copy=false)
      } else {
        expression = combine(arr.map(kv => kv.1))
      }
    }
  }
  self.changed(original, expression)
}

///|
fn frozen_pair_eq(
  a1 : @core.Expr,
  b1 : @core.Expr,
  a2 : @core.Expr,
  b2 : @core.Expr,
) -> Bool {
  let s1 = expr_set([a1, b1])
  let s2 = expr_set([a2, b2])
  s1.length() == s2.length() && s1.iter().all(x => s2.contains(x))
}

///|
fn is_proper_subset(a : Array[@core.Expr], b : Array[@core.Expr]) -> Bool {
  a.length() < b.length() && a.iter().all(x => b.contains(x))
}

///|
/// Absorption and elimination.
pub fn Simplifier::absorb_and_eliminate(
  self : Simplifier,
  expression : @core.Expr,
  root : Bool,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind.is_any([And, Or]) && (root || !expression.same_parent()) {
    let kind : @core.Kind = if expression.kind.is_a(And) { Or } else { And }
    let ops = expression.flatten().collect()
    let op_set = ExprSet::of(ops)
    // defaultdict(list) keyed by expression (hashed lookups)
    let subop_keys = ExprSet::new()
    let subop_vals : Array[Array[Array[@core.Expr]]] = []
    fn subops_add(k : @core.Expr, s : Array[@core.Expr]) {
      let i = subop_keys.add(k)
      if i == subop_vals.length() {
        subop_vals.push([])
      }
      subop_vals[i].push(s)
    }

    fn subops_get(k : @core.Expr) -> Array[Array[@core.Expr]] {
      let i = subop_keys.find(k, k.hash())
      if i >= 0 {
        subop_vals[i]
      } else {
        []
      }
    }

    // defaultdict(list) keyed by frozenset({a, b}), bucketed by an order-independent hash
    let pairs : Map[
      Int,
      Array[(@core.Expr, @core.Expr, Array[(@core.Expr, @core.Expr)])],
    ] = Map([])
    fn pair_hash(a : @core.Expr, b : @core.Expr) -> Int {
      let ha = a.hash()
      let hb = b.hash()
      if ha < hb {
        ha * 31 + hb
      } else {
        hb * 31 + ha
      }
    }

    fn pairs_add(a : @core.Expr, b : @core.Expr, v : (@core.Expr, @core.Expr)) {
      let h = pair_hash(a, b)
      let bucket = match pairs.get(h) {
        Some(bucket) => bucket
        None => {
          let bucket = []
          pairs[h] = bucket
          bucket
        }
      }
      for entry in bucket {
        if frozen_pair_eq(entry.0, entry.1, a, b) {
          entry.2.push(v)
          return
        }
      }
      bucket.push((a, b, [v]))
    }

    fn pairs_get(
      a : @core.Expr,
      b : @core.Expr,
    ) -> Array[(@core.Expr, @core.Expr)] {
      match pairs.get(pair_hash(a, b)) {
        Some(bucket) =>
          for entry in bucket {
            if frozen_pair_eq(entry.0, entry.1, a, b) {
              return entry.2
            }
          }
        None => ()
      }
      []
    }

    for op in ops {
      if !op.kind.is_a(kind) {
        subops_add(op, [op])
        continue
      }
      let subset = expr_set(op.flatten().collect())
      for i in subset {
        subops_add(i, subset)
      }
      let operands = op.unnest_operands()
      let a = operands[0]
      let b = operands[1]
      if a.kind.is_a(Not) && a.this_().meta_get("nonnull") is Some(Bool(true)) {
        pairs_add(a.this_(), b, (op, b))
      }
      if b.kind.is_a(Not) && b.this_().meta_get("nonnull") is Some(Bool(true)) {
        pairs_add(a, b.this_(), (op, a))
      }
    }
    for op in ops {
      if !op.kind.is_a(kind) {
        continue
      }
      let operands = op.unnest_operands()
      let a = operands[0]
      let b = operands[1]
      if a.kind.is_a(Not) &&
        op_set.contains(a.this_()) &&
        a.this_().meta_get("nonnull") is Some(Bool(true)) {
        a.replace(Some(if kind == And { @core.true_() } else { @core.false_() }))
        |> ignore
        continue
      }
      if b.kind.is_a(Not) &&
        op_set.contains(b.this_()) &&
        b.this_().meta_get("nonnull") is Some(Bool(true)) {
        b.replace(Some(if kind == And { @core.true_() } else { @core.false_() }))
        |> ignore
        continue
      }
      let superset = expr_set(op.flatten().collect())
      if superset
        .iter()
        .any(i => subops_get(i).iter().any(s => is_proper_subset(s, superset))) {
        op.replace(Some(if kind == And { @core.false_() } else { @core.true_() }))
        |> ignore
        continue
      }
      for entry in pairs_get(a, b) {
        let (other, complement) = entry
        op.replace(Some(complement)) |> ignore
        other.replace(Some(complement)) |> ignore
      }
    }
  }
  self.changed(expression, expression)
}

///|
/// Use the subtraction and addition properties of equality to simplify expressions.
pub fn Simplifier::simplify_equality(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let result = self.simplify_equality_impl(expression) catch {
    UnsupportedUnit => expression
  }
  self.changed(expression, result)
}

///|
fn Simplifier::simplify_equality_impl(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise UnsupportedUnit {
  ignore(self)
  if !is_comparison(expression) {
    return expression
  }
  let (l, r) = match (expression.this(), expression.expression()) {
    (Some(l), Some(r)) => (l, r)
    _ => return expression
  }
  let inverse = match inverse_ops.get(l.kind) {
    Some(k) => k
    None => return expression
  }
  let (a_predicate, b_predicate) : ((@core.Expr) -> Bool, (@core.Expr) -> Bool) = if r.is_number() {
    (is_number_expr, is_number_expr)
  } else if is_date_literal(r) {
    (is_date_literal, is_interval_expr)
  } else {
    return expression
  }
  let (a0, b0) = if inverse_date_ops.contains(l.kind) {
    (l.this_(), interval_of(l))
  } else {
    match (l.this(), l.expression()) {
      (Some(x), Some(y)) => (x, y)
      _ => return expression
    }
  }
  let mut a = a0
  let mut b = b0
  if !a_predicate(a) && b_predicate(b) {
    ()
  } else if !a_predicate(b) && b_predicate(a) {
    if l.kind.is_a(Sub) {
      let k = inverse_comparisons.get(expression.kind).unwrap_or(expression.kind)
      return @core.mk2(k, b, @core.mk2(Sub, a, r))
    }
    let tmp = a
    a = b
    b = tmp
  } else {
    return expression
  }
  if b.kind.is_a(Interval) {
    let exact = is_exact_interval_move(l, r, b) catch { _ => false }
    if !exact {
      return expression
    }
  }
  @core.mk2(expression.kind, a, @core.mk2(inverse, r, b))
}

///|
/// `IntervalOp.interval()`: builds an Interval from the expression and unit.
fn interval_of(e : @core.Expr) -> @core.Expr {
  @core.mk(Interval, [
    ("this", e.expression().map(x => x.copy())),
    ("unit", e.arg("unit").map(x => x.copy())),
  ])
}

///|
pub fn Simplifier::simplify_literals(
  self : Simplifier,
  expression : @core.Expr,
  root : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let result = if expression.kind.is_a(Binary) && !expression.kind.is_a(Connector) {
    self.flat_simplify(
      expression,
      (e, a, b) => self.simplify_binary(e, a, b),
      root,
      index?=binary_flat_index(expression),
    )
  } else if expression.kind.is_a(Neg) &&
    (match expression.this() {
      Some(t) => t.kind.is_a(Neg)
      None => false
    }) {
    expression.this_().this_()
  } else if inverse_date_ops.contains(expression.kind) {
    match self.simplify_binary(expression, expression.this_(), interval_of(expression)) {
      Some(r) => r
      None => expression
    }
  } else {
    expression
  }
  self.changed(expression, result)
}

///|
fn Simplifier::simplify_integer_cast(
  self : Simplifier,
  expr : @core.Expr,
) -> @core.Expr {
  let this = if expr.kind.is_a(Cast) &&
    (match expr.this() {
      Some(t) => t.kind.is_a(Cast)
      None => false
    }) {
    self.simplify_integer_cast(expr.this_())
  } else {
    match expr.this() {
      Some(t) => t
      None => return expr
    }
  }
  if expr.kind.is_a(Cast) && this.is_int() {
    match expr_to_pynum(this) {
      Some(PInt(num)) => {
        let to_this = match expr.arg("to") {
          Some(t) => t.datatype_this()
          None => None
        }
        let signed = match to_this {
          Some(d) => @core.dtype_signed_integer_types.contains(d)
          None => false
        }
        let unsigned = match to_this {
          Some(d) => @core.dtype_unsigned_integer_types.contains(d)
          None => false
        }
        if (num >= big(-128) && num <= big(127) && signed) ||
          (num >= big(0) && num <= big(255) && unsigned) {
          return this
        }
      }
      _ => ()
    }
  }
  expr
}

///|
fn Simplifier::simplify_binary(
  self : Simplifier,
  expression : @core.Expr,
  a : @core.Expr,
  b : @core.Expr,
) -> @core.Expr? raise @core.SqlglotError {
  let mut a = a
  let mut b = b
  if is_comparison(expression) {
    a = self.simplify_integer_cast(a)
    b = self.simplify_integer_cast(b)
  }
  if expression.kind.is_a(Is) {
    let (c, not0) = if b.kind.is_a(Not) {
      (b.this_(), true)
    } else {
      (b, false)
    }
    let mut not_ = not0
    if expression.has("negate") {
      not_ = !not_
    }
    if is_null(Some(c)) {
      if a.kind.is_a(Literal) {
        return Some(if not_ { @core.true_() } else { @core.false_() })
      }
      if is_null(Some(a)) {
        return Some(if not_ { @core.false_() } else { @core.true_() })
      }
    }
  } else if expression.kind.is_any([NullSafeEQ, NullSafeNEQ, PropertyEQ]) {
    return None
  } else if (is_null(Some(a)) || is_null(Some(b))) && parent_is(expression, [If]) {
    return Some(@core.null_())
  }
  if a.is_number() && b.is_number() {
    let num_a = match expr_to_pynum(a) {
      Some(n) => n
      None => return None
    }
    let num_b = match expr_to_pynum(b) {
      Some(n) => n
      None => return None
    }
    if expression.kind.is_a(Add) {
      return Some(literal_from_pynum(pynum_add(num_a, num_b)))
    }
    if expression.kind.is_a(Mul) {
      return Some(literal_from_pynum(pynum_mul(num_a, num_b)))
    }
    let same_parent = match (a.parent, b.parent) {
      (Some(x), Some(y)) => physical_equal(x, y)
      (None, None) => true
      _ => false
    }
    if expression.kind.is_a(Sub) {
      return if same_parent {
        Some(literal_from_pynum(pynum_sub(num_a, num_b)))
      } else {
        None
      }
    }
    if expression.kind.is_a(Div) {
      if (num_a.is_int() && num_b.is_int()) || !same_parent {
        return None
      }
      return Some(literal_from_pynum(pynum_div(num_a, num_b)))
    }
    let boolean = eval_boolean_cmp(
      expression,
      () => pynum_cmp(num_a, num_b),
      () => pynum_cmp(num_a, num_b) == 0,
    )
    if boolean is Some(_) {
      return boolean
    }
  } else if a.is_string() && b.is_string() {
    let sa = a.text("this")
    let sb = b.text("this")
    let boolean = eval_boolean_cmp(expression, () => py_str_cmp(sa, sb), () => sa == sb)
    if boolean is Some(_) {
      return boolean
    }
  } else if is_date_literal(a) && b.kind.is_a(Interval) {
    match (extract_date(a), extract_interval(b)) {
      (Some(date), Some(delta)) => {
        if expression.kind.is_any([Add, DateAdd, DatetimeAdd]) {
          return Some(date_literal(add_reldelta(date, delta), extract_type([a])))
        }
        if expression.kind.is_any([Sub, DateSub, DatetimeSub]) {
          return Some(date_literal(add_reldelta(date, delta.neg()), extract_type([a])))
        }
      }
      _ => ()
    }
  } else if a.kind.is_a(Interval) && is_date_literal(b) {
    match (extract_interval(a), extract_date(b)) {
      (Some(delta), Some(date)) =>
        if expression.kind.is_a(Add) {
          return Some(date_literal(add_reldelta(date, delta), extract_type([b])))
        }
      _ => ()
    }
  } else if is_date_literal(a) && is_date_literal(b) {
    if expression.kind.is_a(Predicate) {
      let da = extract_date(a).unwrap()
      let db = extract_date(b).unwrap()
      let boolean = eval_boolean_cmp(
        expression,
        () => pydt_cmp(da, db),
        () => pydt_eq(da, db),
      )
      if boolean is Some(_) {
        return boolean
      }
    }
  }
  None
}

///|
pub fn Simplifier::simplify_coalesce(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  self.changed(expression, self.simplify_coalesce_impl(expression))
}

///|
fn Simplifier::simplify_coalesce_impl(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr {
  if expression.kind.is_a(Coalesce) &&
    (expression.expressions().is_empty() ||
    is_nonnull_constant(expression.this_())) &&
    !parent_is(expression, [Hint]) {
    return expression.this_()
  }
  if self.dialect.cfg.coalesce_comparison_non_standard {
    return expression
  }
  if !is_comparison(expression) {
    return expression
  }
  let left = expression.this_()
  let right = expression.expression_()
  let (coalesce, other) = if left.kind.is_a(Coalesce) {
    (left, right)
  } else if right.kind.is_a(Coalesce) {
    (right, left)
  } else {
    return expression
  }
  if !is_constant_expr(other) {
    return expression
  }
  let exprs = coalesce.expressions()
  let mut arg_index = -1
  for i, arg in exprs {
    if is_nonnull_constant(arg) {
      arg_index = i
      break
    }
  }
  if arg_index < 0 {
    return expression
  }
  let arg = exprs[arg_index]
  coalesce.set("expressions", exprs[0:arg_index].to_array())
  let this = if !coalesce.expressions().is_empty() {
    coalesce
  } else {
    coalesce.this_()
  }
  let substituted = expression.copy()
  substituted.set(
    if physical_equal(coalesce, left) { "this" } else { "expression" },
    arg.copy(),
  )
  @core.paren(
    @core.or_(
      [
        @core.and_(
          [
            @core.not_(binop(Is, this, @core.null_()), copy=false),
            expression.copy(),
          ],
          copy=false,
        ),
        @core.and_([binop(Is, this, @core.null_()), substituted], copy=false),
      ],
      copy=false,
    ),
    copy=false,
  )
}

///|
/// Reduces all groups that contain string literals by concatenating them.
pub fn Simplifier::simplify_concat(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  self.changed(expression, simplify_concat_impl(expression))
}

///|
fn simplify_concat_impl(expression : @core.Expr) -> @core.Expr {
  if !expression.kind.is_any([Concat, DPipe]) {
    return expression
  }
  let is_ws = expression.kind.is_a(ConcatWs)
  if is_ws && !expression.expressions()[0].is_string() {
    return expression
  }
  let (sep_expr, expressions, sep) = if is_ws {
    let all = expression.expressions()
    (Some(all[0]), all[1:].to_array(), all[0].name())
  } else {
    (None, expression.expressions(), "")
  }
  let safe = expression.get("safe")
  let coalesce = expression.get("coalesce")
  let items = if expressions.is_empty() {
    expression.flatten(unnest=false).collect()
  } else {
    expressions
  }
  let new_args : Array[@core.Expr] = []
  let mut i = 0
  while i < items.length() {
    if items[i].is_string() {
      let group = []
      while i < items.length() && items[i].is_string() {
        group.push(items[i].name())
        i += 1
      }
      new_args.push(@core.literal_string(group.join(sep)))
    } else {
      new_args.push(items[i])
      i += 1
    }
  }
  if new_args.length() == 1 && new_args[0].is_string() {
    return new_args[0]
  }
  if is_ws {
    let args = [sep_expr.unwrap()] + new_args
    let e = @core.mk(ConcatWs, [("expressions", args)])
    match safe {
      Some(v) => e.set("safe", v)
      None => ()
    }
    match coalesce {
      Some(v) => e.set("coalesce", v)
      None => ()
    }
    return e
  }
  if expression.kind.is_a(DPipe) {
    let mut acc = new_args[0]
    for j in 1..<new_args.length() {
      acc = @core.mk(DPipe, [("this", acc), ("expression", new_args[j])])
      match safe {
        Some(v) => acc.set("safe", v)
        None => ()
      }
    }
    return acc
  }
  let e = @core.mk(Concat, [("expressions", new_args)])
  match safe {
    Some(v) => e.set("safe", v)
    None => ()
  }
  match coalesce {
    Some(v) => e.set("coalesce", v)
    None => ()
  }
  e
}

///|
/// Simplifies expressions like IF, CASE if their condition is statically known.
pub fn Simplifier::simplify_conditionals(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  self.changed(expression, simplify_conditionals_impl(expression))
}

///|
fn simplify_conditionals_impl(expression : @core.Expr) -> @core.Expr {
  if expression.kind.is_a(Case) {
    let this = expression.this()
    for case in expression.list("ifs") {
      let mut cond = case.this_()
      match this {
        Some(t) => {
          let popped = t.pop()
          cond = cond.replace(Some(binop(EQ, popped, cond))).unwrap()
        }
        None => ()
      }
      if always_true(Some(cond)) {
        return @core.paren(case.arg("true").unwrap(), copy=false)
      }
      if always_false(Some(cond)) {
        case.pop() |> ignore
        if expression.list("ifs").is_empty() {
          return @core.paren(
            match expression.arg("default") {
              Some(d) => d
              None => @core.null_()
            },
            copy=false,
          )
        }
      }
    }
  } else if expression.kind.is_a(If) && !parent_is(expression, [Case]) {
    if always_true(expression.this()) {
      return @core.paren(expression.arg("true").unwrap(), copy=false)
    }
    if always_false(expression.this()) {
      return @core.paren(
        match expression.arg("false") {
          Some(d) => d
          None => @core.null_()
        },
        copy=false,
      )
    }
  }
  expression
}

///|
/// Reduces a prefix check to TRUE or FALSE if both arguments are statically known.
pub fn Simplifier::simplify_startswith(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let result = if expression.kind.is_a(StartsWith) &&
    expression.this_().is_string() &&
    expression.expression_().is_string() {
    boolean_literal(expression.name().has_prefix(expression.expression_().name()))
  } else {
    expression
  }
  self.changed(expression, result)
}

///|
fn is_datetrunc_predicate(left : @core.Expr, right : @core.Expr) -> Bool {
  left.kind.is_any([DateTrunc, TimestampTrunc]) && is_date_literal(right)
}

///|
/// Simplify expressions like `DATE_TRUNC('year', x) >= CAST('2021-01-01' AS DATE)`.
pub fn Simplifier::simplify_datetrunc(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let result = self.simplify_datetrunc_impl(expression) catch {
    UnsupportedUnit => expression
  }
  self.changed(expression, result)
}

///|
fn Simplifier::simplify_datetrunc_impl(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise UnsupportedUnit {
  let comparison = expression.kind
  let dialect = self.dialect
  if expression.kind.is_any([DateTrunc, TimestampTrunc]) {
    let this = expression.this_()
    let trunc_type = if expression.is_type(@core.dtype_temporal_types) {
      expression.get_type()
    } else {
      extract_type([this])
    }
    let date = extract_date(this)
    match (date, expression.arg("unit")) {
      (Some(d), Some(unit)) =>
        return date_literal(
          floor_or_raise(d, trunc_unit(unit, dialect), dialect),
          trunc_type,
        )
      _ => ()
    }
  } else if !(comparison == In || comparison.is_any([LT, GT, LTE, GTE, EQ, NEQ])) {
    return expression
  }
  if expression.kind.is_a(Binary) {
    let (l, r) = match (expression.this(), expression.expression()) {
      (Some(l), Some(r)) => (l, r)
      _ => return expression
    }
    if !is_datetrunc_predicate(l, r) {
      return expression
    }
    let trunc_arg = l.this_()
    let unit = trunc_unit(l.arg("unit").unwrap(), dialect)
    let date = match extract_date(r) {
      Some(d) => d
      None => return expression
    }
    let target_type = extract_type([r])
    let floor = floor_or_raise(date, unit, dialect)
    let iv = interval_or_raise(unit)
    let add = fn(d : PyDT) raise UnsupportedUnit {
      add_reldelta(d, iv) catch {
        _ => raise UnsupportedUnit
      }
    }
    let simplified : @core.Expr? = match comparison {
      LT =>
        Some(
          lt_(
            trunc_arg,
            date_literal(
              if pydt_eq(date, floor) {
                date
              } else {
                add(floor)
              },
              target_type,
            ),
          ),
        )
      GT => Some(ge_(trunc_arg, date_literal(add(floor), target_type)))
      LTE => Some(lt_(trunc_arg, date_literal(add(floor), target_type)))
      GTE =>
        Some(ge_(trunc_arg, date_literal(date_ceil(date, unit, dialect), target_type)))
      EQ =>
        datetrunc_range(date, unit, dialect).map(dr => datetrunc_eq_expression(
          trunc_arg, dr, target_type,
        ))
      NEQ =>
        datetrunc_range(date, unit, dialect).map(dr => {
          @core.or_(
            [
              lt_(trunc_arg, date_literal(dr.0, target_type)),
              ge_(trunc_arg, date_literal(dr.1, target_type)),
            ],
            copy=false,
          )
        })
      _ => None
    }
    return match simplified {
      Some(s) => parenthesize_nested_connector(s, expression.parent)
      None => expression
    }
  }
  if expression.kind.is_a(In) {
    let l = expression.this_()
    let rs = expression.expressions()
    if !rs.is_empty() && rs.iter().all(r => is_datetrunc_predicate(l, r)) {
      let unit = trunc_unit(l.arg("unit").unwrap(), dialect)
      let ranges = []
      for r in rs {
        let date = match extract_date(r) {
          Some(d) => d
          None => return expression
        }
        match datetrunc_range(date, unit, dialect) {
          Some(dr) => ranges.push(dr)
          None => ()
        }
      }
      if ranges.is_empty() {
        return expression
      }
      let merged = merge_ranges(ranges) catch { _ => raise UnsupportedUnit }
      let target_type = extract_type(rs)
      let simplified = @core.or_(
        merged.map(dr => datetrunc_eq_expression(l, dr, target_type)),
        copy=false,
      )
      return parenthesize_nested_connector(simplified, expression.parent)
    }
  }
  expression
}

///|
pub fn Simplifier::sort_comparison(
  self : Simplifier,
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let mut result = expression
  if complement_comparisons.contains(expression.kind) {
    let l = expression.this_()
    let r = expression.expression_()
    let l_column = l.kind.is_a(Column)
    let r_column = r.kind.is_a(Column)
    let l_const = is_constant_expr(l)
    let r_const = is_constant_expr(r)
    if (l_column && !r_column) ||
      (r_const && !l_const) ||
      r.kind.is_a(SubqueryPredicate) {
      ()
    } else if (r_column && !l_column) || (l_const && !r_const) ||
      py_str_cmp(gen(l), gen(r)) > 0 {
      let k = inverse_comparisons.get(expression.kind).unwrap_or(expression.kind)
      result = @core.mk2(k, r, l)
    }
  }
  self.changed(expression, result)
}

///|
fn Simplifier::flat_simplify(
  self : Simplifier,
  expression : @core.Expr,
  simplifier : (@core.Expr, @core.Expr, @core.Expr) -> @core.Expr? raise @core.SqlglotError,
  root : Bool,
  index? : FlatIndex,
) -> @core.Expr raise @core.SqlglotError {
  ignore(self)
  if root || !expression.same_parent() {
    let mut operands = []
    let queue = expression.flatten(unnest=false).collect()
    let size = queue.length()
    if expression.kind.is_a(Connector) &&
      !queue
      .iter()
      .any(op => op.kind.is_any([Boolean, Literal, Null]) || is_comparison(op)) {
      return expression
    }
    if index is Some(ix) && size >= flat_index_min_size {
      operands = flat_simplify_indexed(expression, queue, simplifier, ix)
      queue.clear()
    }
    while queue.length() > 0 {
      let a = queue.remove(0)
      let mut combined = false
      for j in 0..<queue.length() {
        let b = queue[j]
        let result = simplifier(expression, a, b)
        match result {
          Some(res) if !physical_equal(res, expression) => {
            queue.remove(j) |> ignore
            queue.insert(0, res)
            combined = true
            break
          }
          _ => ()
        }
      }
      if !combined {
        operands.push(a)
      }
    }
    if operands.length() < size {
      let mut acc = operands[0]
      for i in 1..<operands.length() {
        acc = @core.mk2(expression.kind, acc, operands[i])
      }
      return acc
    }
  }
  expression
}

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
