// Port of sqlglot/diff.py: the Change Distiller tree diff.

///|
/// An edit of the edit script.
pub(all) enum Edit {
  /// A new node has been inserted
  Insert(@core.Expr)
  /// An existing node has been removed
  Remove(@core.Expr)
  /// An existing node's position within the tree has changed
  Move(source~ : @core.Expr, target~ : @core.Expr)
  /// An existing node has been updated
  Update(source~ : @core.Expr, target~ : @core.Expr)
  /// An existing node hasn't been changed
  Keep(source~ : @core.Expr, target~ : @core.Expr)
}

///|
/// Structural equality of edits (Python dataclass equality).
pub impl Eq for Edit with fn equal(self, other) {
  match (self, other) {
    (Insert(a), Insert(b)) => a == b
    (Remove(a), Remove(b)) => a == b
    (Move(source=s1, target=t1), Move(source=s2, target=t2)) => s1 == s2 && t1 == t2
    (Update(source=s1, target=t1), Update(source=s2, target=t2)) =>
      s1 == s2 && t1 == t2
    (Keep(source=s1, target=t1), Keep(source=s2, target=t2)) => s1 == s2 && t1 == t2
    _ => false
  }
}

///|
fn edit_sql(e : @core.Expr) -> String {
  @core.expr_to_sql(e) catch {
    _ => e.kind.name()
  }
}

///|
/// A readable representation, e.g. `Update(table_one -> table_two)`.
pub fn Edit::to_string(self : Edit) -> String {
  match self {
    Insert(e) => "Insert(\{e.kind.name()}: \{edit_sql(e)})"
    Remove(e) => "Remove(\{e.kind.name()}: \{edit_sql(e)})"
    Move(source~, target~) =>
      "Move(\{source.kind.name()}: \{edit_sql(source)} -> \{edit_sql(target)})"
    Update(source~, target~) =>
      "Update(\{source.kind.name()}: \{edit_sql(source)} -> \{edit_sql(target)})"
    Keep(source~, target~) =>
      "Keep(\{source.kind.name()}: \{edit_sql(source)} -> \{edit_sql(target)})"
  }
}

///|
/// Returns the list of changes between the source and the target expressions.
pub fn diff(
  source : @core.Expr,
  target : @core.Expr,
  matchings? : Array[(@core.Expr, @core.Expr)] = [],
  delta_only? : Bool = false,
  f? : Double = 0.6,
  t? : Double = 0.6,
  dialect? : @core.Dialect,
) -> Array[Edit] {
  let source_nodes = source.walk().collect()
  let target_nodes = target.walk().collect()
  let source_ids : @set.Set[Int] = @set.new()
  for n in source_nodes {
    source_ids.add(n.uid)
  }
  let target_ids : @set.Set[Int] = @set.new()
  for n in target_nodes {
    target_ids.add(n.uid)
  }
  let copy = source_nodes.length() != source_ids.length() ||
    target_nodes.length() != target_ids.length() ||
    source_ids.iter().any(i => target_ids.contains(i))
  let source_copy = if copy { source.copy() } else { source }
  let target_copy = if copy { target.copy() } else { target }
  let mut matchings = matchings
  if copy && !matchings.is_empty() {
    let source_mapping = node_mappings(source_nodes, source_copy.walk().collect())
    let target_mapping = node_mappings(target_nodes, target_copy.walk().collect())
    matchings = matchings.map(m => (source_mapping[m.0.uid], target_mapping[m.1.uid]))
  }
  ChangeDistiller::new(f~, t~, dialect?).diff(
    source_copy,
    target_copy,
    matchings~,
    delta_only~,
  )
}

///|
fn node_mappings(
  old_nodes : Array[@core.Expr],
  new_nodes : Array[@core.Expr],
) -> Map[Int, @core.Expr] {
  let m : Map[Int, @core.Expr] = Map([])
  let n = @core.min_int(old_nodes.length(), new_nodes.length())
  for i in 0..<n {
    m[old_nodes[old_nodes.length() - 1 - i].uid] = new_nodes[new_nodes.length() - 1 -
      i]
  }
  m
}

///|
fn is_updatable(e : @core.Expr) -> Bool {
  e.kind.is_any([Alias, Boolean, Column, DataType, Lambda, Literal, Table, Window])
}

///|
fn is_ignored_leaf(e : @core.Expr) -> Bool {
  e.kind == Identifier
}

///|
/// The Change Distiller algorithm (Fluri & Pinzger), based on Chawathe et al.
pub struct ChangeDistiller {
  f : Double
  t : Double
  dialect : @core.Dialect
  priv mut source_index : Map[Int, @core.Expr]
  priv mut target_index : Map[Int, @core.Expr]
  priv mut unmatched_source : @set.Set[Int]
  priv mut unmatched_target : @set.Set[Int]
  priv bigram_cache : Map[Int, Map[String, Int]]
  priv mut roots : (@core.Expr, @core.Expr)?
}

///|
pub fn ChangeDistiller::new(
  f? : Double = 0.6,
  t? : Double = 0.6,
  dialect? : @core.Dialect,
) -> ChangeDistiller {
  {
    f,
    t,
    dialect: match dialect {
      Some(d) => d
      None => @core.base_dialect()
    },
    source_index: {},
    target_index: {},
    unmatched_source: @set.new(),
    unmatched_target: @set.new(),
    bigram_cache: {},
    roots: None,
  }
}

///|
pub fn ChangeDistiller::diff(
  self : ChangeDistiller,
  source : @core.Expr,
  target : @core.Expr,
  matchings? : Array[(@core.Expr, @core.Expr)] = [],
  delta_only? : Bool = false,
) -> Array[Edit] {
  let pre_matched : Map[Int, Int] = Map([])
  for m in matchings {
    pre_matched[m.0.uid] = m.1.uid
  }
  let pre_matched_targets : @set.Set[Int] = @set.new()
  for _, v in pre_matched {
    pre_matched_targets.add(v)
  }
  self.source_index = {}
  for n in source.bfs() {
    if !is_ignored_leaf(n) {
      self.source_index[n.uid] = n
    }
  }
  self.target_index = {}
  for n in target.bfs() {
    if !is_ignored_leaf(n) {
      self.target_index[n.uid] = n
    }
  }
  self.unmatched_source = @set.new()
  for k, _ in self.source_index {
    if !pre_matched.contains(k) {
      self.unmatched_source.add(k)
    }
  }
  self.unmatched_target = @set.new()
  for k, _ in self.target_index {
    if !pre_matched_targets.contains(k) {
      self.unmatched_target.add(k)
    }
  }
  self.bigram_cache.clear()
  self.roots = Some((source, target))
  let matching_set = self.compute_matching_set()
  for k, v in pre_matched {
    if !matching_set.iter().any(p => p.0 == k && p.1 == v) {
      matching_set.push((k, v))
    }
  }
  // dict(matching_set), ordered by the source's BFS order
  let matchings_map : Map[Int, Int] = Map([])
  for k, _ in self.source_index {
    for p in matching_set {
      if p.0 == k {
        matchings_map[k] = p.1
      }
    }
  }
  for p in matching_set {
    if !matchings_map.contains(p.0) {
      matchings_map[p.0] = p.1
    }
  }
  self.generate_edit_script(matchings_map, delta_only)
}

///|
fn non_expression_leaves(e : @core.Expr) -> Array[(String, @core.Value)] {
  let out = []
  for k, v in e.args {
    match v {
      Node(_) => continue
      List(l) =>
        match l.get(0) {
          Some(Node(_)) => continue
          _ => out.push((k, v))
        }
      _ => out.push((k, v))
    }
  }
  out
}

///|
fn value_eq(a : @core.Value, b : @core.Value) -> Bool {
  match (a, b) {
    (Node(x), Node(y)) => x == y
    (List(x), List(y)) =>
      x.length() == y.length() &&
      x.iter().zip(y.iter()).all(p => value_eq(p.0, p.1))
    (Str(x), Str(y)) => x == y
    (Bool(x), Bool(y)) => x == y
    (Int(x), Int(y)) => x == y
    (DT(x), DT(y)) => x == y
    (Bool(true), Int(1)) | (Int(1), Bool(true)) => true
    (Bool(false), Int(0)) | (Int(0), Bool(false)) => true
    _ => false
  }
}

///|
fn leaves_eq(
  a : Array[(String, @core.Value)],
  b : Array[(String, @core.Value)],
) -> Bool {
  a.length() == b.length() &&
  a
  .iter()
  .all(kv => b.iter().any(kw => kw.0 == kv.0 && value_eq(kv.1, kw.1)))
}

///|
fn ChangeDistiller::generate_edit_script(
  self : ChangeDistiller,
  matchings : Map[Int, Int],
  delta_only : Bool,
) -> Array[Edit] {
  let edit_script = []
  for k, n in self.source_index {
    if self.unmatched_source.contains(k) {
      edit_script.push(Remove(n))
    }
  }
  for k, n in self.target_index {
    if self.unmatched_target.contains(k) {
      edit_script.push(Insert(n))
    }
  }
  for kept_source_id, kept_target_id in matchings {
    let source_node = self.source_index[kept_source_id]
    let target_node = self.target_index[kept_target_id]
    let identical_nodes = source_node == target_node
    if !is_updatable(source_node) || identical_nodes {
      if identical_nodes {
        let moved = match (source_node.parent, target_node.parent) {
          (Some(_), None) | (None, Some(_)) => true
          (Some(sp), Some(tp)) => matchings.get(sp.uid) != Some(tp.uid)
          (None, None) => false
        }
        if moved {
          edit_script.push(Move(source=source_node, target=target_node))
        }
      } else {
        for m in self.generate_move_edits(source_node, target_node, matchings) {
          edit_script.push(m)
        }
      }
      if !leaves_eq(
          non_expression_leaves(source_node),
          non_expression_leaves(target_node),
        ) {
        edit_script.push(Update(source=source_node, target=target_node))
      } else if !delta_only {
        edit_script.push(Keep(source=source_node, target=target_node))
      }
    } else {
      edit_script.push(Update(source=source_node, target=target_node))
    }
  }
  edit_script
}

///|
fn ChangeDistiller::generate_move_edits(
  self : ChangeDistiller,
  source : @core.Expr,
  target : @core.Expr,
  matchings : Map[Int, Int],
) -> Array[Edit] {
  let source_args = source
    .iter_expressions()
    .filter(a => !is_ignored_leaf(a))
    .map(a => a.uid)
  let target_args = target
    .iter_expressions()
    .filter(a => !is_ignored_leaf(a))
    .map(a => a.uid)
  let args_lcs = lcs(source_args, target_args, (l, r) => matchings.get(l) ==
    Some(r))
  let move_edits = []
  for a in source_args {
    if !args_lcs.contains(a) && !self.unmatched_source.contains(a) {
      move_edits.push(
        Move(
          source=self.source_index[a],
          target=self.target_index[matchings[a]],
        ),
      )
    }
  }
  move_edits
}

///|
fn ChangeDistiller::compute_matching_set(
  self : ChangeDistiller,
) -> Array[(Int, Int)] {
  let leaves_matching_set = self.compute_leaf_matching_set()
  let matching_set = leaves_matching_set.copy()
  let ordered_source = self.source_index
    .keys()
    .filter(k => self.unmatched_source.contains(k))
    .collect()
  let ordered_target = self.target_index
    .keys()
    .filter(k => self.unmatched_target.contains(k))
    .collect()
  for source_node_id in ordered_source {
    for ti, target_node_id in ordered_target {
      let source_node = self.source_index[source_node_id]
      let target_node = self.target_index[target_node_id]
      if is_same_type(source_node, target_node) {
        let source_leaf_ids : @set.Set[Int] = @set.new()
        for l in expression_leaves(source_node) {
          source_leaf_ids.add(l.uid)
        }
        let target_leaf_ids : @set.Set[Int] = @set.new()
        for l in expression_leaves(target_node) {
          target_leaf_ids.add(l.uid)
        }
        let max_leaves_num = @core.max_int(
          source_leaf_ids.length(),
          target_leaf_ids.length(),
        )
        let leaf_similarity_score = if max_leaves_num > 0 {
          let mut common = 0
          for p in leaves_matching_set {
            if source_leaf_ids.contains(p.0) && target_leaf_ids.contains(p.1) {
              common += 1
            }
          }
          common.to_double() / max_leaves_num.to_double()
        } else {
          0.0
        }
        let adjusted_t = if @core.min_int(
            source_leaf_ids.length(),
            target_leaf_ids.length(),
          ) >
          4 {
          self.t
        } else {
          0.4
        }
        if leaf_similarity_score >= 0.8 ||
          (leaf_similarity_score >= adjusted_t &&
          self.dice_coefficient(source_node, target_node) >= self.f) {
          matching_set.push((source_node_id, target_node_id))
          self.unmatched_source.remove(source_node_id)
          self.unmatched_target.remove(target_node_id)
          ordered_target.remove(ti) |> ignore
          break
        }
      }
    }
  }
  matching_set
}

///|
fn ChangeDistiller::compute_leaf_matching_set(
  self : ChangeDistiller,
) -> Array[(Int, Int)] {
  let candidates : Array[(Double, Int, Int, @core.Expr, @core.Expr)] = []
  let (source_root, target_root) = self.roots.unwrap()
  let source_leaves = expression_leaves(source_root)
  let target_leaves = expression_leaves(target_root)
  for source_leaf in source_leaves {
    for target_leaf in target_leaves {
      if is_same_type(source_leaf, target_leaf) {
        let similarity_score = self.dice_coefficient(source_leaf, target_leaf)
        if similarity_score >= self.f {
          candidates.push((
            similarity_score,
            parent_similarity_score(Some(source_leaf), Some(target_leaf)),
            candidates.length(),
            source_leaf,
            target_leaf,
          ))
        }
      }
    }
  }
  // heap order: highest score, then highest parent similarity, then insertion order
  candidates.sort_by((a, b) => {
    let c = b.0.compare(a.0)
    if c != 0 {
      return c
    }
    let c = b.1.compare(a.1)
    if c != 0 {
      return c
    }
    a.2.compare(b.2)
  })
  let matching_set = []
  for c in candidates {
    let (_, _, _, source_leaf, target_leaf) = c
    if self.unmatched_source.contains(source_leaf.uid) &&
      self.unmatched_target.contains(target_leaf.uid) {
      matching_set.push((source_leaf.uid, target_leaf.uid))
      self.unmatched_source.remove(source_leaf.uid)
      self.unmatched_target.remove(target_leaf.uid)
    }
  }
  matching_set
}

///|
fn ChangeDistiller::dice_coefficient(
  self : ChangeDistiller,
  source : @core.Expr,
  target : @core.Expr,
) -> Double {
  let source_histo = self.bigram_histo(source)
  let target_histo = self.bigram_histo(target)
  let mut total_grams = 0
  for _, v in source_histo {
    total_grams += v
  }
  for _, v in target_histo {
    total_grams += v
  }
  if total_grams == 0 {
    return if source == target { 1.0 } else { 0.0 }
  }
  let mut overlap_len = 0
  for g, v in source_histo {
    match target_histo.get(g) {
      Some(w) => overlap_len += @core.min_int(v, w)
      None => ()
    }
  }
  2.0 * overlap_len.to_double() / total_grams.to_double()
}

///|
fn ChangeDistiller::bigram_histo(
  self : ChangeDistiller,
  expression : @core.Expr,
) -> Map[String, Int] {
  match self.bigram_cache.get(expression.uid) {
    Some(h) => return h
    None => ()
  }
  let s = @core.Generator::new(self.dialect, comments=false).generate(expression) catch {
    _ => ""
  }
  let chars = s.to_array()
  let histo : Map[String, Int] = Map([])
  for i in 0..<(chars.length() - 1) {
    let g = String::from_array([chars[i], chars[i + 1]])
    histo[g] = histo.get_or_default(g, 0) + 1
  }
  self.bigram_cache[expression.uid] = histo
  histo
}

///|
fn expression_leaves(expression : @core.Expr) -> Array[@core.Expr] {
  let out = []
  fn go(e : @core.Expr) -> Unit {
    let mut has_child_exprs = false
    for node in e.iter_expressions() {
      if !is_ignored_leaf(node) {
        has_child_exprs = true
        go(node)
      }
    }
    if !has_child_exprs {
      out.push(e)
    }
  }

  go(expression)
  out
}

///|
fn is_same_type(source : @core.Expr, target : @core.Expr) -> Bool {
  if source.kind != target.kind {
    return false
  }
  if source.kind.is_a(Join) {
    return match (source.get("side"), target.get("side")) {
      (None, None) => true
      (Some(a), Some(b)) => value_eq(a, b)
      _ => false
    }
  }
  if source.kind.is_a(Anonymous) {
    return match (source.get("this"), target.get("this")) {
      (None, None) => true
      (Some(a), Some(b)) => value_eq(a, b)
      _ => false
    }
  }
  true
}

///|
fn parent_similarity_score(source : @core.Expr?, target : @core.Expr?) -> Int {
  match (source, target) {
    (Some(s), Some(t)) if s.kind == t.kind =>
      1 + parent_similarity_score(s.parent, t.parent)
    _ => 0
  }
}

///|
/// Calculates the longest common subsequence.
fn lcs(
  seq_a : Array[Int],
  seq_b : Array[Int],
  equal : (Int, Int) -> Bool,
) -> Array[Int] {
  let len_a = seq_a.length()
  let len_b = seq_b.length()
  let table : Array[Array[Array[Int]]] = Array::makei(len_a + 1, _ => Array::makei(
    len_b + 1,
    _ => [],
  ))
  for i in 0..=len_a {
    for j in 0..=len_b {
      if i == 0 || j == 0 {
        table[i][j] = []
      } else if equal(seq_a[i - 1], seq_b[j - 1]) {
        table[i][j] = table[i - 1][j - 1] + [seq_a[i - 1]]
      } else {
        table[i][j] = if table[i - 1][j].length() > table[i][j - 1].length() {
          table[i - 1][j]
        } else {
          table[i][j - 1]
        }
      }
    }
  }
  table[len_a][len_b]
}
