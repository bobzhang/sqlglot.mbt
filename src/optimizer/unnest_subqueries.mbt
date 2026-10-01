// Port of sqlglot/optimizer/unnest_subqueries.py.

///|
/// `Select.join(expression, on=..., join_type=..., join_alias=..., copy=False)`, mirroring
/// Python's copies (the joined query is copied into a Subquery, which is copied again
/// when aliased).
fn select_join(
  parent_select : @core.Expr,
  expression : @core.Expr,
  on : Array[@core.Expr],
  join_type : String,
  join_alias : String,
) -> Unit {
  let join = if expression.kind.is_a(Join) {
    expression
  } else {
    @core.mk1(Join, expression)
  }
  match join.this() {
    Some(t) if t.kind.is_a(Select) =>
      t.replace(Some(@core.mk1(Subquery, t.copy()))) |> ignore
    _ => ()
  }
  match join_type {
    "LEFT" | "RIGHT" | "FULL" => join.set("side", join_type)
    "CROSS" | "INNER" | "OUTER" | "SEMI" | "ANTI" => join.set("kind", join_type)
    _ => ()
  }
  if !on.is_empty() {
    join.set("on", @core.and_(on))
  }
  if join_alias != "" {
    let aliased = join.this_().copy()
    aliased.set("alias", @core.mk1(TableAlias, @core.to_identifier(join_alias)))
    join.set("this", aliased)
  }
  let joins = parent_select.list("joins")
  joins.push(join)
  parent_select.set("joins", joins)
}

///|
/// Python `_replace(expression, condition)` with an expression.
fn replace_with_condition(
  expression : @core.Expr,
  condition : @core.Expr,
) -> @core.Expr {
  expression.replace(Some(condition.copy())).unwrap()
}

///|
/// Python `_replace(expression, condition)` with a SQL string.
fn replace_with_sql(
  expression : @core.Expr,
  sql : String,
) -> @core.Expr raise @core.SqlglotError {
  expression.replace(Some(@core.parse_one(sql))).unwrap()
}

///|
/// Rewrite the AST to convert some predicates with subqueries into joins.
pub fn unnest_subqueries(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  let next_alias_name = @core.name_sequence("_u_")
  for scope in traverse_scope(expression) {
    let select = scope.expression
    // (checked before the upward `parent_select` walk, which only the scopes that get
    // rewritten need)
    let rewritten = if !scope.external_columns().is_empty() {
      scope.scope_type != SetOperationScope
    } else {
      scope.scope_type == SubqueryScope
    }
    if !rewritten {
      continue
    }
    let parent = match select.parent_select() {
      Some(p) => p
      None => continue
    }
    if !scope.external_columns().is_empty() {
      if scope.scope_type != SetOperationScope {
        decorrelate(select, parent, scope.external_columns(), next_alias_name)
      }
    } else if scope.scope_type == SubqueryScope {
      unnest(select, parent, next_alias_name)
    }
  }
  expression
}

///|
fn is_negated(expression : @core.Expr) -> Bool {
  let mut parent = expression.parent
  while parent is Some(p) && p.kind.is_a(Paren) {
    parent = p.parent
  }
  match parent {
    Some(p) => p.kind.is_a(Not)
    None => false
  }
}

///|
fn same_select(a : @core.Expr?, b : @core.Expr) -> Bool {
  match a {
    Some(x) => physical_equal(x, b)
    None => false
  }
}

///|
fn unnest(
  select : @core.Expr,
  parent_select : @core.Expr,
  next_alias_name : () -> String,
) -> Unit raise @core.SqlglotError {
  if select.selects().length() > 1 {
    return
  }
  let mut predicate = match select.find_ancestor([Condition]) {
    Some(p) => p
    None => return
  }
  if (predicate.kind.is_a(Func) &&
    (match predicate.parent {
      Some(p) => p.kind.is_any([Table, From, Join])
      None => false
    })) ||
    !same_select(predicate.parent_select(), parent_select) ||
    !parent_select.has("from_") ||
    (predicate.kind.is_a(In) && is_negated(predicate)) {
    return
  }
  let mut select = select
  if select.kind.is_a(SetOperation) {
    let inner_alias = next_alias_name()
    let projections = select
      .selects()
      .map(s => @core.alias_(
        column_with_table(s.alias_or_name(), table=inner_alias),
        s.alias_or_name(),
      ))
    select = @core.select_(projections).from_(
      @core.mk(Subquery, [
        ("this", select.copy()),
        ("alias", @core.mk1(TableAlias, @core.to_identifier(inner_alias))),
      ]),
    )
  }
  let alias = next_alias_name()
  let clause = predicate.find_ancestor([Having, Where, Join])
  if !predicate.kind.is_any([In, Any]) {
    let mut column = column_with_table(
      select.selects()[0].alias_or_name(),
      table=alias,
    )
    let clause_parent_select = match clause {
      Some(c) => c.parent_select()
      None => None
    }
    let clause_is_having = match clause {
      Some(c) => c.kind.is_a(Having)
      None => false
    }
    if (clause_is_having && same_select(clause_parent_select, parent_select)) ||
      ((clause is None || !same_select(clause_parent_select, parent_select)) &&
      (parent_select.has("group") ||
      parent_select
      .selects()
      .iter()
      .any(s => find_in_scope(s, [AggFunc]) is Some(_)))) {
      column = @core.mk1(Max, column)
    } else if !parent_is(select, [Subquery]) {
      return
    }
    let mut join_type = "CROSS"
    let mut on_clause = []
    if predicate.kind.is_a(Exists) {
      column = @core.exp_not(@core.exp_is(column, @core.null_()))
      join_type = "LEFT"
      on_clause = [@core.true_()]
    }
    replace_with_condition(select.parent.unwrap(), column) |> ignore
    select_join(parent_select, select, on_clause, join_type, alias)
    return
  }
  if find_in_scope(select, [Limit, Offset]) is Some(_) {
    return
  }
  if predicate.kind.is_a(Any) {
    predicate = match predicate.find_ancestor([EQ]) {
      Some(p) => p
      None => return
    }
    if !same_select(predicate.parent_select(), parent_select) {
      return
    }
  }
  let column = match other_operand(Some(predicate)) {
    Some(c) => c
    None => return
  }
  let value = select.selects()[0]
  let join_key = column_with_table(value.alias(), table=alias)
  let join_key_not_null = @core.exp_not(@core.exp_is(join_key, @core.null_()))
  match clause {
    Some(c) if c.kind.is_a(Join) => {
      replace_with_condition(predicate, @core.true_()) |> ignore
      parent_select.where_([join_key_not_null]) |> ignore
    }
    _ => replace_with_condition(predicate, join_key_not_null) |> ignore
  }
  match select.arg("group") {
    Some(group) => {
      let gexprs = expr_set(group.expressions())
      let value_this = value.this()
      let same = gexprs.length() == 1 && Some(gexprs[0]) == value_this
      if !same {
        let sub = select.subquery(alias="_q", copy=false)
        select = @core.select_([
            @core.alias_(column_with_table(value.alias(), table="_q"), value.alias()),
          ])
          .from_(sub)
          .group_by([column_with_table(value.alias(), table="_q")])
      }
    }
    None =>
      match value.this() {
        Some(vt) =>
          if find_in_scope(vt, [AggFunc]) is None {
            select = select.group_by([vt])
          }
        None => raise @core.OptimizeError("AttributeError: value.this is None")
      }
  }
  select_join(
    parent_select,
    select,
    [@core.exp_eq(column, join_key)],
    "LEFT",
    alias,
  )
}

///|
fn is_plain_group(group : @core.Expr) -> Bool {
  !["grouping_sets", "cube", "rollup", "totals"].iter().any(a => group.has(a)) &&
  !group
  .expressions()
  .iter()
  .any(e => e.kind.is_any([Rollup, Cube, GroupingSets]) ||
    (e.kind.is_a(Tuple) && e.expressions().is_empty()))
}

///|
fn has_aggregate_projection(select : @core.Expr) -> Bool {
  let windows = select.list("windows")
  select.selects().iter().any(p => projection_has_aggregate(p, windows))
}

///|
fn other_operand(expression : @core.Expr?) -> @core.Expr? {
  match expression {
    Some(e) if e.kind.is_a(In) => e.this()
    Some(e) if e.kind.is_any([Any, All]) => other_operand(e.parent)
    Some(e) if e.kind.is_a(Binary) =>
      match e.this() {
        Some(l) if l.kind.is_any([Subquery, Any, Exists, All]) => e.expression()
        l => l
      }
    _ => None
  }
}

///|
/// Structural-equality keyed list (Python dict keyed by expressions).
fn assoc_get(m : Array[(@core.Expr, String)], k : @core.Expr) -> String? {
  for kv in m {
    if kv.0 == k {
      return Some(kv.1)
    }
  }
  None
}

///|
fn decorrelate(
  select : @core.Expr,
  parent_select : @core.Expr,
  external_columns : Array[@core.Expr],
  next_alias_name : () -> String,
) -> Unit raise @core.SqlglotError {
  let where_ = match select.arg("where") {
    Some(w) => w
    None => return
  }
  if where_.find([Or]) is Some(_) || select.find([Limit, Offset, Fetch]) is Some(_) {
    return
  }
  let mut parent_predicate = select.find_ancestor([Predicate])
  match parent_predicate {
    Some(pp) if !same_select(pp.parent_select(), parent_select) => return
    _ => ()
  }
  match parent_predicate {
    Some(pp) if pp.kind.is_a(Exists) => {
      if select.has("having") || select.has("qualify") {
        return
      }
      match select.arg("group") {
        Some(group) if !(group.has("all") &&
          select
          .selects()
          .iter()
          .all(p => find_in_scope(p, [AggFunc]) is Some(_))) =>
          if !is_plain_group(group) {
            return
          }
        _ =>
          if has_aggregate_projection(select) {
            replace_with_condition(pp, @core.true_()) |> ignore
            return
          }
      }
    }
    _ => ()
  }
  let table_alias = next_alias_name()
  let keys : Array[(@core.Expr, @core.Expr, @core.Expr)] = []
  let mut eq_count = 0
  let external_ids : @set.Set[Int] = @set.new()
  for column in external_columns {
    match column.find_ancestor([Where]) {
      Some(w) if physical_equal(w, where_) => ()
      _ => return
    }
    let predicate = column.find_ancestor([Predicate])
    let mut ancestor = match predicate {
      Some(p) => p.parent
      None => None
    }
    while ancestor is Some(a) && a.kind.is_any([And, Paren]) {
      ancestor = a.parent
    }
    match ancestor {
      Some(a) if physical_equal(a, where_) => ()
      _ => return
    }
    let predicate = predicate.unwrap()
    if !predicate.kind.is_a(Binary) {
      return
    }
    let left = predicate.this_()
    let key = if left.walk().any(n => physical_equal(n, column)) {
      predicate.expression_()
    } else {
      left
    }
    keys.push((key, column, predicate))
    external_ids.add(column.uid)
    if predicate.kind.is_a(EQ) {
      eq_count += 1
    }
  }
  let is_exists = match parent_predicate {
    Some(pp) => pp.kind.is_a(Exists)
    None => false
  }
  if eq_count == 0 || (keys.length() > eq_count && !is_exists) {
    return
  }
  let is_subquery_projection = parent_select
    .selects()
    .iter()
    .any(s => {
      let node = s.unalias()
      node.kind.is_a(Subquery) && same_select(select.parent, node)
    })
  let value = select.selects()[0]
  let value_this = value.this()
  let group_by_has_value = fn(gb : Array[@core.Expr]) {
    match value_this {
      Some(v) => gb.contains(v)
      None => false
    }
  }
  let key_aliases : Array[(@core.Expr, String)] = []
  let group_by : Array[@core.Expr] = []
  for k in keys {
    let (key, _, predicate) = k
    let other = if physical_equal(key, predicate.this_()) {
      predicate.expression_()
    } else {
      predicate.this_()
    }
    if key.find_all([Column]).any(c => external_ids.contains(c.uid)) ||
      other.find_all([Column]).any(c => !external_ids.contains(c.uid)) {
      return
    }
    if Some(key) == value_this && predicate.kind.is_a(EQ) {
      let mut found = false
      for i, kv in key_aliases {
        if kv.0 == key {
          key_aliases[i] = (kv.0, value.alias())
          found = true
          break
        }
      }
      if !found {
        key_aliases.push((key, value.alias()))
      }
      group_by.push(key)
    } else {
      if assoc_get(key_aliases, key) is None {
        key_aliases.push((key, next_alias_name()))
      }
      if predicate.kind.is_a(EQ) && !group_by.contains(key) {
        group_by.push(key)
      }
    }
  }
  if parent_predicate is None && !is_subquery_projection {
    return
  }
  match parent_predicate {
    Some(pp) if pp.kind.is_a(In) && is_negated(pp) => return
    _ => ()
  }
  if !value.kind.is_a(Subquery) &&
    find_in_scope(value, [AggFunc]) is None &&
    !group_by_has_value(group_by) {
    let agg = @core.mk1(if is_subquery_projection { Max } else { ArrayAgg }, value_this)
    select.select_(
      [@core.alias_(agg, value.alias(), quoted=false, copy=true)],
      append=false,
    )
    |> ignore
  }
  if is_exists {
    select.set("expressions", @core.Value::List([]))
    select.set("group", @core.null_arg)
    select.set("distinct", @core.null_arg)
    select.set("order", @core.null_arg)
  }
  for key in group_by {
    if is_exists || Some(key) != value_this {
      select.select_([@core.alias_(key, assoc_get(key_aliases, key).unwrap())])
      |> ignore
    }
  }
  let array_keys = key_aliases.filter(kv => !group_by.contains(kv.0)).map(kv => kv.0)
  let use_struct = array_keys.length() > 1
  let mut array_alias = ""
  if !array_keys.is_empty() {
    array_alias = if use_struct {
      next_alias_name()
    } else {
      assoc_get(key_aliases, array_keys[0]).unwrap()
    }
    let array_item = if use_struct {
      @core.mk(Struct, [
        (
          "expressions",
          array_keys.map(key => @core.mk2(
            PropertyEQ,
            @core.to_identifier(assoc_get(key_aliases, key).unwrap()),
            key.copy(),
          )),
        ),
      ])
    } else {
      array_keys[0].copy()
    }
    select.select_([
      @core.alias_(@core.mk1(ArrayAgg, array_item), array_alias, quoted=false),
    ])
    |> ignore
  }
  let mut alias = column_with_table(value.alias(), table=table_alias)
  let other = other_operand(parent_predicate)
  let op_type = match parent_predicate {
    Some(pp) =>
      match pp.parent {
        Some(p) => Some(p.kind)
        None => None
      }
    None => None
  }
  match parent_predicate {
    Some(pp) if pp.kind.is_a(Exists) => {
      let mut first_alias = ""
      for key in group_by {
        first_alias = assoc_get(key_aliases, key).unwrap()
        break
      }
      alias = column_with_table(first_alias, table=table_alias)
      parent_predicate = Some(
        replace_with_sql(pp, "NOT \{expr_sql(alias)} IS NULL"),
      )
    }
    Some(pp) if pp.kind.is_a(All) => {
      let predicate = @core.mk2(
        op_type.unwrap(),
        other,
        column_with_table("_x"),
      )
      parent_predicate = Some(
        replace_with_sql(
          pp.parent.unwrap(),
          "ARRAY_ALL(\{expr_sql(alias)}, _x -> \{expr_sql(predicate)})",
        ),
      )
    }
    Some(pp) if pp.kind.is_a(Any) =>
      if group_by_has_value(group_by) {
        let predicate = @core.mk2(op_type.unwrap(), other, alias)
        parent_predicate = Some(replace_with_condition(pp.parent.unwrap(), predicate))
      } else {
        let predicate = @core.mk2(
          op_type.unwrap(),
          other,
          column_with_table("_x"),
        )
        parent_predicate = Some(
          replace_with_sql(
            pp,
            "ARRAY_ANY(\{expr_sql(alias)}, _x -> \{expr_sql(predicate)})",
          ),
        )
      }
    Some(pp) if pp.kind.is_a(In) =>
      if group_by_has_value(group_by) {
        parent_predicate = Some(
          replace_with_sql(
            pp,
            "\{expr_sql(other.unwrap())} = \{expr_sql(alias)}",
          ),
        )
      } else {
        parent_predicate = Some(
          replace_with_sql(
            pp,
            "ARRAY_ANY(\{expr_sql(alias)}, _x -> _x = \{expr_sql(pp.this_())})",
          ),
        )
      }
    _ => {
      let mut replacement = alias
      if is_subquery_projection {
        match select.parent {
          Some(p) if p.alias() != "" =>
            replacement = @core.alias_(replacement, p.alias())
          _ => ()
        }
      }
      if find_in_scope(value, [Count]) is Some(_) {
        let removed = value
          .this_()
          .transform(node => if node.kind.is_a(Count) {
            Some(@core.literal_int(0))
          } else if node.kind.is_a(AggFunc) {
            Some(@core.null_())
          } else {
            Some(node)
          })
        replacement = @core.mk(Coalesce, [
          ("this", replacement),
          ("expressions", [removed]),
        ])
      }
      select.parent.unwrap().replace(Some(replacement)) |> ignore
    }
  }
  let array_predicates = []
  for k in keys {
    let (key, _, predicate) = k
    predicate.replace(Some(@core.true_())) |> ignore
    if group_by.contains(key) {
      key.replace(
        Some(column_with_table(assoc_get(key_aliases, key).unwrap(), table=table_alias)),
      )
      |> ignore
    } else {
      key.replace(
        Some(
          if use_struct {
            column_with_table(assoc_get(key_aliases, key).unwrap(), table="_x")
          } else {
            @core.to_identifier("_x")
          },
        ),
      )
      |> ignore
      array_predicates.push(predicate)
    }
  }
  if !array_predicates.is_empty() {
    let right = @core.mk2(
      ArrayAny,
      column_with_table(array_alias, table=table_alias),
      @core.mk(Lambda, [
        ("this", @core.and_(array_predicates)),
        ("expressions", [@core.to_identifier("_x")]),
      ]),
    )
    let pp = parent_predicate.unwrap()
    parent_predicate = Some(
      replace_with_condition(
        pp,
        @core.paren(@core.and_([pp.copy(), right])),
      ),
    )
  }
  let grouped = select.group_by(group_by)
  select_join(
    parent_select,
    grouped,
    keys.filter(k => group_by.contains(k.0)).map(k => k.2),
    "LEFT",
    table_alias,
  )
}
