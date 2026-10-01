// An indexed version of Python's `_flat_simplify` pairwise scan.
//
// Python pops the first operand `a` and tries `simplifier(expression, a, b)` for every
// remaining `b` in queue order, combining `a` with the first `b` that yields a new
// expression. That is O(n^2) simplifier calls even when nothing combines (e.g. a
// 10,000-way AND of unrelated comparisons). The simplifiers only combine specific operand
// shapes, so operands are filed in buckets and `a` is only tried against the operands of the
// buckets it may combine with, still in queue order: the first `b` that combines is the
// same one Python finds, and the result is identical.

///|
/// Which operands may combine with which. `keys(x)` are the buckets `x` is filed under;
/// `partners(a)` are the buckets holding every operand that may combine with `a` (`None`:
/// any operand may).
priv struct FlatIndex {
  keys : (@core.Expr) -> Array[Int]
  partners : (@core.Expr) -> Array[Int]?
}

///|
/// Operands below this count use the plain scan.
let flat_index_min_size : Int = 8

///|
let special_bucket : Int = -1

///|
/// The comparison class of a connector operand (0..5), or -1.
fn comparison_class(e : @core.Expr) -> Int {
  match e.kind {
    LT => 0
    LTE => 1
    GT => 2
    GTE => 3
    EQ => 4
    NEQ => 5
    _ => -1
  }
}

///|
/// The comparison classes `_simplify_comparison` may combine with class `c` (see the
/// permutation checks there): both LT/LTE, both GT/GTE, and under AND also LT with GT/GTE,
/// GT with LT/LTE and EQ with LT/LTE/GT/GTE/NEQ. EQ with EQ, NEQ with NEQ and IS never
/// combine.
fn comparison_partners(c : Int, or_ : Bool) -> Array[Int] {
  if or_ {
    match c {
      0 | 1 => [0, 1]
      2 | 3 => [2, 3]
      _ => []
    }
  } else {
    match c {
      0 => [0, 1, 2, 3, 4]
      1 => [0, 1, 2, 4]
      2 => [2, 3, 0, 1, 4]
      3 => [2, 3, 0, 4]
      4 => [0, 1, 2, 3, 5]
      5 => [4]
      _ => []
    }
  }
}

///|
fn operand_bucket(operand : @core.Expr, class : Int) -> Int {
  // non-negative so it can't be `special_bucket`
  (operand.hash() * 8 + class) & 0x7fffffff
}

///|
/// Operands that `_simplify_connectors` treats specially (TRUE, FALSE, numbers, NULL).
fn is_connector_special(e : @core.Expr) -> Bool {
  e.kind.is_any([Boolean, Literal, Null])
}

///|
/// The index for `_simplify_connectors`: a special operand may combine with anything; two
/// other operands only combine in `_simplify_comparison`, which needs two comparisons of
/// compatible classes sharing an operand.
fn connector_flat_index(or_ : Bool) -> FlatIndex {
  {
    keys: x => {
      if is_connector_special(x) {
        return [special_bucket]
      }
      let c = comparison_class(x)
      match (c, x.this(), x.expression()) {
        (0..=5, Some(l), Some(r)) =>
          [operand_bucket(l, c), operand_bucket(r, c)]
        _ => []
      }
    },
    partners: a => {
      if is_connector_special(a) {
        return None
      }
      let out = [special_bucket]
      let c = comparison_class(a)
      match (c, a.this(), a.expression()) {
        (0..=5, Some(l), Some(r)) =>
          for p in comparison_partners(c, or_) {
            out.push(operand_bucket(l, p))
            out.push(operand_bucket(r, p))
          }
        _ => ()
      }
      Some(out)
    },
  }
}

///|
/// The operand class `_simplify_binary` acts on: 0 number, 1 string, 2 interval, 3 date
/// literal, -1 none.
fn binary_operand_class(x : @core.Expr) -> Int {
  if x.is_number() {
    0
  } else if x.is_string() {
    1
  } else if x.kind.is_a(Interval) {
    2
  } else if is_date_literal(x) {
    3
  } else {
    -1
  }
}

///|
/// The index for `_simplify_binary` on an arithmetic chain: only number/number,
/// string/string, date/interval, interval/date and date/date pairs combine. Comparisons
/// (whose operands go through `_simplify_integer_cast`), IS, the null-safe operators and
/// operands of an IF (where any NULL combines) keep the plain scan.
fn binary_flat_index(expression : @core.Expr) -> FlatIndex? {
  if is_comparison(expression) ||
    expression.kind.is_any([Is, NullSafeEQ, NullSafeNEQ, PropertyEQ]) ||
    parent_is(expression, [If]) {
    return None
  }
  Some({
    keys: x => {
      let c = binary_operand_class(x)
      if c < 0 {
        []
      } else {
        [c]
      }
    },
    partners: a => {
      Some(
        match binary_operand_class(a) {
          0 => [0]
          1 => [1]
          2 => [3]
          3 => [2, 3]
          _ => []
        },
      )
    },
  })
}

///|
/// `_flat_simplify`'s scan over `items` (the flattened operands), trying only the
/// candidates `index` allows. Returns the remaining operands.
fn flat_simplify_indexed(
  expression : @core.Expr,
  items : Array[@core.Expr],
  simplifier : (@core.Expr, @core.Expr, @core.Expr) -> @core.Expr? raise @core.SqlglotError,
  index : FlatIndex,
) -> Array[@core.Expr] raise @core.SqlglotError {
  let n = items.length()
  // The queue is always: an optional result prepended by the last combination (popped
  // next), followed by the not yet consumed original operands in order.
  let alive = Array::make(n, true)
  let next = Array::makei(n, i => i + 1)
  let prev = Array::makei(n, i => i - 1)
  let mut head = 0
  let remove = (i : Int) => {
    alive[i] = false
    if prev[i] >= 0 {
      next[prev[i]] = next[i]
    } else {
      head = next[i]
    }
    if next[i] < n {
      prev[next[i]] = prev[i]
    }
  }
  let buckets : Map[Int, Array[Int]] = Map([])
  for i, item in items {
    for k in (index.keys)(item) {
      match buckets.get(k) {
        Some(b) => if b.last() != Some(i) { b.push(i) }
        None => buckets[k] = [i]
      }
    }
  }
  // per bucket: the first position that may still be alive
  let starts : Map[Int, Int] = Map([])
  let operands = []
  let mut pending : @core.Expr? = None
  for ;; {
    let a = match pending {
      Some(r) => {
        pending = None
        r
      }
      None => {
        if head >= n {
          break
        }
        let i = head
        remove(i)
        items[i]
      }
    }
    let mut found : (Int, @core.Expr)? = None
    match (index.partners)(a) {
      None => {
        let mut j = head
        while j < n {
          match simplifier(expression, a, items[j]) {
            Some(r) if !physical_equal(r, expression) => {
              found = Some((j, r))
              break
            }
            _ => ()
          }
          j = next[j]
        }
      }
      Some(keys) => {
        // k-way merge of the partner buckets in queue order
        let lists : Array[Array[Int]] = []
        let pos : Array[Int] = []
        for k in keys {
          match buckets.get(k) {
            Some(b) => {
              let mut s = starts.get(k).unwrap_or(0)
              while s < b.length() && !alive[b[s]] {
                s += 1
              }
              starts[k] = s
              if s < b.length() && !lists.iter().any(l => physical_equal(l, b)) {
                lists.push(b)
                pos.push(s)
              }
            }
            None => ()
          }
        }
        let mut last = -1
        for ;; {
          let mut best = -1
          for li, l in lists {
            while pos[li] < l.length() && !alive[l[pos[li]]] {
              pos[li] += 1
            }
            if pos[li] < l.length() &&
              (best < 0 || l[pos[li]] < lists[best][pos[best]]) {
              best = li
            }
          }
          if best < 0 {
            break
          }
          let j = lists[best][pos[best]]
          pos[best] += 1
          if j == last {
            continue
          }
          last = j
          match simplifier(expression, a, items[j]) {
            Some(r) if !physical_equal(r, expression) => {
              found = Some((j, r))
              break
            }
            _ => ()
          }
        }
      }
    }
    match found {
      Some((j, r)) => {
        remove(j)
        pending = Some(r)
      }
      None => operands.push(a)
    }
  }
  operands
}
