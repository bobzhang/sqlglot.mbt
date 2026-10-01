// Port of sqlglot/optimizer/canonicalize_internal_names.py.

///|
fn canon_ident(ident : @core.Expr, name : String) -> Unit {
  ident.set("this", name)
  ident.set("quoted", true)
}

///|
fn expr_key(e : @core.Expr) -> Int {
  e.uid * 2
}

///|
/// Rewrite a query to a canonical structural form, renaming internal names
/// (table aliases, CTE/subquery names, internal column aliases) to `_tN` / `_cN`.
pub fn canonicalize_internal_names(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if !expression.kind.is_a(Query) {
    return expression
  }
  let output_scope_exprs : @set.Set[Int] = @set.new()
  let stack = [expression]
  while stack.pop() is Some(node) {
    if node.kind.is_a(SetOperation) {
      stack.push(node.this_().unnest())
      if node.has("by_name") {
        stack.push(node.expression_().unnest())
      }
    } else {
      output_scope_exprs.add(node.uid)
    }
  }
  let next_table = @core.name_sequence("_t")
  let next_column = @core.name_sequence("_c")
  let scope_table : Map[Int, String] = Map([])
  let scope_outputs : Map[Int, Map[String, String]] = Map([])
  let table_columns : Map[Int, Map[String, String]] = Map([])
  let udtf_columns : Map[Int, Map[String, String]] = Map([])
  for scope in traverse_scope(expression) {
    let scope_expr = scope.expression
    let is_output_scope = output_scope_exprs.contains(scope_expr.uid)
    let columns_by_source : Map[String, Array[@core.Expr]] = Map([])
    fn add_col(k : String, c : @core.Expr) {
      if !columns_by_source.contains(k) {
        columns_by_source[k] = []
      }
      columns_by_source[k].push(c)
    }

    for col in scope.columns() {
      add_col(col.table_name(), col)
    }
    for table_col in scope.table_columns() {
      add_col(table_col.name(), table_col)
    }
    for star in scope.stars() {
      if star.kind.is_a(Column) && star.table_name() != "" {
        add_col(star.table_name(), star)
      }
    }
    let table_map : Map[String, (String, String)] = Map([])
    let ref_canon_taken : @set.Set[String] = @set.new()
    for source_name, source in scope.sources {
      let source_cols = columns_by_source.get(source_name).unwrap_or([])
      let mut alias_holder : @core.Expr? = None
      let is_base_source = source is TableSource(_)
      let mut canon_t = ""
      let mut child_output : Map[String, String] = Map([])
      let mut name_map : Map[String, String] = Map([])
      match source {
        TableSource(t) => {
          canon_t = scope_table.get(expr_key(t)).unwrap_or("")
          if canon_t == "" {
            canon_t = next_table()
            scope_table[expr_key(t)] = canon_t
          }
          if !table_columns.contains(expr_key(t)) {
            table_columns[expr_key(t)] = {}
          }
          name_map = table_columns[expr_key(t)]
        }
        ScopeSource(s) => {
          let src_expr = s.expression
          child_output = scope_outputs.get(src_expr.uid).unwrap_or({})
          match src_expr.parent {
            Some(p) if p.kind.is_any([CTE, Subquery]) => alias_holder = Some(p)
            Some(p) if p.kind.is_a(SetOperation) &&
              (match p.parent {
                Some(cte) =>
                  cte.kind.is_a(CTE) &&
                  (match cte.parent {
                    Some(w) => w.kind.is_a(With) && w.has("recursive")
                    None => false
                  })
                None => false
              }) => alias_holder = p.parent
            _ => if s.is_udtf() { alias_holder = Some(src_expr) }
          }
          let is_udtf_source = match alias_holder {
            Some(h) => physical_equal(h, src_expr)
            None => false
          }
          let table_key = match alias_holder {
            Some(h) => expr_key(h)
            None => s.key()
          }
          canon_t = scope_table.get(table_key).unwrap_or("")
          if canon_t == "" {
            canon_t = next_table()
            scope_table[table_key] = canon_t
          } else if !is_udtf_source {
            alias_holder = None
          }
          name_map = if is_udtf_source {
            if !udtf_columns.contains(src_expr.uid) {
              udtf_columns[src_expr.uid] = {}
            }
            udtf_columns[src_expr.uid]
          } else {
            {}
          }
        }
      }
      let ref_alias = if ref_canon_taken.contains(canon_t) {
        next_table()
      } else {
        ref_canon_taken.add(canon_t)
        canon_t
      }
      table_map[source_name] = (canon_t, ref_alias)
      let struct_field_names = []
      match source.expression() {
        Some(src) if src.kind.is_a(Unnest) =>
          match src.expressions().get(0) {
            Some(first) =>
              match first.get_type() {
                Some(t) =>
                  match t.expressions().get(0) {
                    Some(element_type) if element_type.is_type([STRUCT]) =>
                      for cd in element_type.expressions() {
                        struct_field_names.push(cd.name())
                      }
                    _ => ()
                  }
                None => ()
              }
            None => ()
          }
        _ => ()
      }
      for src_col in source_cols {
        if src_col.kind.is_a(TableColumn) {
          canon_ident(src_col.this_(), ref_alias)
          continue
        }
        let old_name = src_col.name()
        let preserve_col = is_base_source || struct_field_names.contains(old_name)
        let canon_col = match name_map.get(old_name) {
          Some(c) => c
          None => {
            let c = if preserve_col {
              old_name
            } else {
              match child_output.get(old_name) {
                Some(c) if c != "" => c
                _ => next_column()
              }
            }
            name_map[old_name] = c
            c
          }
        }
        if !preserve_col {
          canon_ident(src_col.this_(), canon_col)
        }
        match src_col.arg("table") {
          Some(table_id) => canon_ident(table_id, ref_alias)
          None => ()
        }
      }
      match alias_holder {
        Some(holder) => {
          match holder.arg("alias") {
            Some(alias_) => {
              match alias_.this() {
                Some(t) if t.kind == Identifier => canon_ident(t, canon_t)
                _ => ()
              }
              let cols = alias_.list("columns")
              if !cols.is_empty() {
                alias_.set(
                  "columns",
                  cols.map(c => @core.to_identifier(
                    name_map.get(c.name()).unwrap_or(c.name()),
                    quoted=c.has("quoted"),
                  )),
                )
              }
            }
            None => ()
          }
          let unnest = if holder.kind.is_a(Lateral) {
            holder.this()
          } else {
            Some(holder)
          }
          match unnest {
            Some(u) if u.kind.is_a(Unnest) =>
              match u.arg("offset") {
                Some(offset_id) if offset_id.kind == Identifier &&
                  name_map.contains(offset_id.name()) =>
                  canon_ident(offset_id, name_map[offset_id.name()])
                _ => ()
              }
            _ => ()
          }
        }
        None => ()
      }
    }
    for pivot in scope.pivots() {
      let pivot_alias = match pivot.arg("alias") {
        Some(a) => a
        None => continue
      }
      let pivot_this = match pivot_alias.this() {
        Some(t) if t.kind == Identifier => t
        _ => continue
      }
      let pivot_cols = match columns_by_source.get(pivot_this.name()) {
        Some(c) if !c.is_empty() => c
        _ => continue
      }
      let canon_t = next_table()
      canon_ident(pivot_this, canon_t)
      for pivot_col in pivot_cols {
        match pivot_col.arg("table") {
          Some(table_id) => canon_ident(table_id, canon_t)
          None => ()
        }
      }
    }
    for table in scope.tables() {
      let (source_canon, ref_alias) = match table_map.get(table.alias_or_name()) {
        Some(e) => e
        None => continue
      }
      match table.this() {
        Some(t) if t.kind == Identifier && !table.has("db") =>
          canon_ident(t, source_canon)
        _ => ()
      }
      match table.arg("alias") {
        Some(alias_) => {
          match alias_.this() {
            Some(t) if t.kind == Identifier => canon_ident(t, ref_alias)
            _ => ()
          }
          let cols = alias_.list("columns")
          if !cols.is_empty() {
            let tc = table_columns.get(expr_key(table)).unwrap_or({})
            alias_.set(
              "columns",
              cols.map(c => @core.to_identifier(
                tc.get(c.name()).unwrap_or(c.name()),
                quoted=c.has("quoted"),
              )),
            )
          }
        }
        None => ()
      }
    }
    let mut output_map : Map[String, String] = Map([])
    if scope_expr.kind.is_a(Select) {
      for sel in scope_expr.selects() {
        if sel.kind.is_any([Alias, Subquery]) && sel.alias_() != "" {
          let old_alias = sel.alias_()
          let new_name = if is_output_scope {
            old_alias
          } else {
            let n = next_column()
            sel.set("alias", @core.to_identifier(n, quoted=true))
            n
          }
          output_map[old_alias] = new_name
        }
      }
    } else if scope_expr.kind.is_a(SetOperation) &&
      !scope.set_operation_scopes.is_empty() {
      output_map = scope_outputs
        .get(scope.set_operation_scopes[0].expression.uid)
        .unwrap_or({})
        .copy()
      if scope_expr.has("by_name") {
        let right_out = scope_outputs
          .get(scope.set_operation_scopes[1].expression.uid)
          .unwrap_or({})
        for k, v in right_out {
          if !output_map.contains(k) {
            output_map[k] = v
          }
        }
      }
    } else if scope.is_udtf() && !scope.subquery_scopes.is_empty() {
      output_map = scope_outputs
        .get(scope.subquery_scopes[0].expression.uid)
        .unwrap_or({})
        .copy()
    }
    scope_outputs[scope_expr.uid] = output_map
    for col in find_all_in_scope(scope_expr, [Column]).collect() {
      if col.table_name() == "" && output_map.contains(col.name()) {
        canon_ident(col.this_(), output_map[col.name()])
      }
    }
    if scope_expr.kind.is_a(SetOperation) && scope_expr.has("by_name") {
      let left_scope = scope.set_operation_scopes[0]
      let right_scope = scope.set_operation_scopes[1]
      let left_out = scope_outputs.get(left_scope.expression.uid).unwrap_or({})
      let right_out = scope_outputs.get(right_scope.expression.uid).unwrap_or({})
      let rename : Map[String, String] = Map([])
      for orig_name, left_canon in left_out {
        match right_out.get(orig_name) {
          Some(right_canon) if right_canon != "" && right_canon != left_canon =>
            rename[right_canon] = left_canon
          _ => ()
        }
      }
      if !rename.is_empty() {
        let rename_stack = [right_scope.expression]
        while rename_stack.pop() is Some(node) {
          if node.kind.is_a(SetOperation) {
            rename_stack.push(node.this_())
            rename_stack.push(node.expression_())
            continue
          }
          if !node.kind.is_a(Select) {
            continue
          }
          for sel in node.selects() {
            if sel.kind.is_a(Alias) {
              match sel.arg("alias") {
                Some(aid) if aid.kind == Identifier && rename.contains(aid.name()) =>
                  canon_ident(aid, rename[aid.name()])
                _ => ()
              }
            }
          }
          for col in find_all_in_scope(node, [Column]).collect() {
            if col.table_name() == "" && rename.contains(col.name()) {
              canon_ident(col.this_(), rename[col.name()])
            }
          }
        }
        let new_right : Map[String, String] = Map([])
        for k, v in right_out {
          new_right[k] = rename.get(v).unwrap_or(v)
        }
        scope_outputs[right_scope.expression.uid] = new_right
      }
    }
  }
  expression
}
