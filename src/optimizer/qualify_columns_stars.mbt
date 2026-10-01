// Star expansion of qualify_columns (port of `_expand_stars` and helpers).

///|
/// [BigQuery] Expand/Flatten foo.bar.* where bar is a struct column.
fn expand_struct_stars_no_parens(expression : @core.Expr) -> Array[@core.Expr] {
  let dot_column = match expression.find([Column]) {
    Some(c) if c.kind.is_a(Column) && c.is_type([STRUCT]) => c.copy()
    _ => return []
  }
  let mut starting_struct = @core.mk(ColumnDef, [
    ("this", dot_column.this()),
    ("kind", dot_column.get_type()),
  ])
  let all_parts = expression.parts()
  let dot_parts = if all_parts.length() >= 2 {
    all_parts[1:all_parts.length() - 1].to_owned()
  } else {
    []
  }
  for i in 1..<dot_parts.length() {
    let part = dot_parts[i]
    let mut found = false
    for field in starting_struct.arg("kind").unwrap().expressions() {
      match field.this() {
        Some(t) if t.kind == Identifier => ()
        _ => return []
      }
      if field.name() == part.name() &&
        type_is(field.arg("kind"), [STRUCT]) {
        starting_struct = field
        found = true
        break
      }
    }
    if !found {
      return []
    }
  }
  let taken_names : @set.Set[String] = @set.Set([])
  let new_selections = []
  for field in starting_struct.arg("kind").unwrap().expressions() {
    let name = field.name()
    let ok = match field.this() {
      Some(t) => t.kind == Identifier
      None => false
    }
    if taken_names.contains(name) || !ok {
      return []
    }
    taken_names.add(name)
    let this = field.this_().copy()
    let parts = (dot_parts + [this]).map(p => p.copy())
    let root = parts[0]
    let rest = parts[1:].to_owned()
    let new_column = @core.column_from_parts(
      root,
      table=dot_column.arg("table").map(t => t.copy()),
      fields=rest,
    )
    new_selections.push(@core.alias_expr(new_column, Some(this.copy()), copy=false))
  }
  new_selections
}

///|
/// [RisingWave] Expand/Flatten (<exp>.bar).*, where bar is a struct column.
fn expand_struct_stars_with_parens(expression : @core.Expr) -> Array[@core.Expr] {
  match expression.this() {
    Some(t) if t.kind.is_a(Paren) => ()
    _ => return []
  }
  let dot_column = match expression.find([Column]) {
    Some(c) if c.kind.is_a(Column) && c.is_type([STRUCT]) => c
    _ => return []
  }
  let mut parent = dot_column.parent
  let mut starting_struct = dot_column.get_type().unwrap()
  while parent is Some(p) {
    if p.kind.is_a(Paren) {
      parent = p.parent
      continue
    }
    if !p.kind.is_a(Dot) {
      return []
    }
    let rhs = p.expression_()
    if rhs.kind.is_a(Star) {
      break
    }
    if rhs.kind != Identifier {
      return []
    }
    let mut matched = false
    for struct_field_def in starting_struct.expressions() {
      if struct_field_def.name() == rhs.name() {
        matched = true
        starting_struct = struct_field_def.arg("kind").unwrap()
        break
      }
    }
    if !matched {
      return []
    }
    parent = p.parent
  }
  let new_selections = []
  let outer_paren = expression.this_()
  for struct_field_def in starting_struct.expressions() {
    let new_identifier = struct_field_def.this_().copy()
    let new_dot = @core.dot_build([outer_paren.copy(), new_identifier])
    new_selections.push(
      @core.alias_expr(new_dot, Some(new_identifier.copy()), copy=false),
    )
  }
  new_selections
}

///|
/// Case-insensitive matcher for a star ILIKE pattern (Python builds a regex from it).
fn ilike_matches(
  pattern : String,
  name : String,
  backslash_escape : Bool,
) -> Bool {
  // Tokenize the pattern: Some(c) is a literal char, None is '_' and '%' is a wildcard.
  let tokens : Array[Int] = [] // -1: any char, -2: any sequence, otherwise char code
  let chars = pattern.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' && backslash_escape && i + 1 < chars.length() {
      i += 1
      tokens.push(chars[i].to_int())
    } else if c == '%' {
      tokens.push(-2)
    } else if c == '_' {
      tokens.push(-1)
    } else {
      tokens.push(c.to_int())
    }
    i += 1
  }
  // `re.fullmatch(pattern, name, re.IGNORECASE)`: `.` (and so `.*`) doesn't match a newline.
  let s = name.to_array().map(c => c.to_int())
  let t = tokens
  let nl = '\n'.to_int()
  // DP match
  let n = s.length()
  let m = t.length()
  let dp = Array::make((n + 1) * (m + 1), false)
  dp[0] = true
  for j in 1..=m {
    if t[j - 1] == -2 {
      dp[j] = dp[j - 1]
    }
  }
  for a in 1..=n {
    for j in 1..=m {
      let tok = t[j - 1]
      let v = if tok == -2 {
        (s[a - 1] != nl && dp[(a - 1) * (m + 1) + j]) || dp[a * (m + 1) + j - 1]
      } else if (tok == -1 && s[a - 1] != nl) ||
        (
          tok >= 0 &&
          @core.re_ignorecase_char_eq(
            Int::unsafe_to_char(tok),
            Int::unsafe_to_char(s[a - 1]),
          )
        ) {
        dp[(a - 1) * (m + 1) + j - 1]
      } else {
        false
      }
      dp[a * (m + 1) + j] = v
    }
  }
  dp[n * (m + 1) + m]
}

///|
fn add_except_columns(
  expression : @core.Expr,
  tables : Array[String],
  except_columns : Map[String, Array[String]],
) -> Unit {
  let except_ = expression.list("except_")
  if except_.is_empty() {
    return
  }
  let columns = []
  let qualified_columns : Map[String, Array[String]] = Map([])
  for e in except_ {
    if e.kind.is_a(Column) && e.table_name() != "" {
      if !qualified_columns.contains(e.table_name()) {
        qualified_columns[e.table_name()] = []
      }
      let q = qualified_columns[e.table_name()]
      if !q.contains(e.name()) {
        q.push(e.name())
      }
    } else if !columns.contains(e.name()) {
      columns.push(e.name())
    }
  }
  for table in tables {
    let table_columns = match qualified_columns.get(table) {
      Some(q) if !q.is_empty() => columns + q
      _ => columns
    }
    if !table_columns.is_empty() {
      except_columns[table] = table_columns
    }
  }
}

///|
fn add_rename_columns(
  expression : @core.Expr,
  tables : Array[String],
  rename_columns : Map[String, Map[String, String]],
) -> Unit {
  let rename = expression.list("rename")
  if rename.is_empty() {
    return
  }
  let columns : Map[String, String] = Map([])
  for e in rename {
    columns[e.this_().name()] = e.alias_()
  }
  for table in tables {
    rename_columns[table] = columns
  }
}

///|
fn add_replace_columns(
  expression : @core.Expr,
  tables : Array[String],
  replace_columns : Map[String, Map[String, @core.Expr]],
) -> Unit {
  let replace = expression.list("replace")
  if replace.is_empty() {
    return
  }
  let columns : Map[String, @core.Expr] = Map([])
  for e in replace {
    columns[e.alias_()] = e
  }
  for table in tables {
    replace_columns[table] = columns
  }
}

///|
/// Expand stars to lists of column selections.
fn expand_stars_impl(
  scope : Scope,
  resolver : Resolver,
  using_column_tables : ColumnTables,
  pseudocolumns : @set.Set[String],
  annotator : TypeAnnotator,
) -> Unit raise @core.SqlglotError {
  let new_selections : Array[@core.Expr] = []
  let except_columns : Map[String, Array[String]] = Map([])
  let replace_columns : Map[String, Map[String, @core.Expr]] = Map([])
  let rename_columns : Map[String, Map[String, String]] = Map([])
  let mut ilike_pattern : String? = None
  let coalesced_columns : @set.Set[String] = @set.Set([])
  let dialect = resolver.dialect
  let annotated_ahead = dialect.cfg.supports_struct_star_expansion &&
    scope.stars().iter().any(c => c.kind.is_a(Dot))
  if annotated_ahead {
    annotator.annotate_scope(scope)
  }
  let scope_expression = scope.expression
  if !scope_expression.kind.is_a(Selectable) {
    return
  }
  for expression in scope_expression.selects() {
    let tables : Array[String] = []
    if expression.kind.is_a(Star) {
      match expression.arg("ilike") {
        Some(ilike) if !ilike.is_string() => {
          new_selections.push(expression)
          continue
        }
        _ => ()
      }
      for name, _ in scope.selected_sources() {
        tables.push(name)
      }
      add_except_columns(expression, tables, except_columns)
      add_replace_columns(expression, tables, replace_columns)
      add_rename_columns(expression, tables, rename_columns)
      ilike_pattern = expression.arg("ilike").map(i => i.name())
    } else if expression.is_star() {
      if expression.kind.is_a(Column) {
        let star = expression.this_()
        match star.arg("ilike") {
          Some(ilike) if !ilike.is_string() => {
            new_selections.push(expression)
            continue
          }
          _ => ()
        }
        tables.push(expression.table_name())
        add_except_columns(star, tables, except_columns)
        add_replace_columns(star, tables, replace_columns)
        add_rename_columns(star, tables, rename_columns)
        ilike_pattern = star.arg("ilike").map(i => i.name())
      } else if expression.kind.is_a(Dot) {
        let struct_fields = if dialect.cfg.requires_parenthesized_struct_access {
          expand_struct_stars_with_parens(expression)
        } else if dialect.cfg.supports_struct_star_expansion {
          expand_struct_stars_no_parens(expression)
        } else {
          []
        }
        if !struct_fields.is_empty() {
          if annotated_ahead {
            annotator.uncache(expression)
          }
          let star = expression.expression_()
          let excluded : @set.Set[String] = @set.Set([])
          for e in star.list("except_") {
            excluded.add(e.name())
          }
          let replaced : Map[String, @core.Expr] = Map([])
          for e in star.list("replace") {
            replaced[e.alias_()] = e
          }
          for f in struct_fields {
            if !excluded.contains(f.alias_()) {
              new_selections.push(
                match replaced.get(f.alias_()) {
                  Some(r) => r
                  None => f
                },
              )
            }
          }
          continue
        }
      }
    }
    if tables.is_empty() {
      new_selections.push(expression)
      continue
    }
    for table in tables {
      let mut source = scope.sources.get(table)
      let mut source_resolver = resolver
      let mut pivots : Array[@core.Expr]? = None
      let mut source_table = table
      if source is None {
        let chain = scope.pivots()
        let parent = if !chain.is_empty() &&
          (match (chain[0].parent, chain[chain.length() - 1].parent) {
            (Some(a), Some(b)) => physical_equal(a, b)
            _ => false
          }) &&
          chain[chain.length() - 1].alias_() == table {
          chain[chain.length() - 1].parent
        } else {
          None
        }
        match parent {
          Some(p) => {
            pivots = Some(chain)
            source_table = p.alias_or_name()
            source = scope.sources.get(source_table)
          }
          None => ()
        }
        if source is None {
          let mut found = false
          for r in [resolver] + resolver.outer_resolvers() {
            source_resolver = r
            source = r.scope.sources.get(table)
            if source is Some(_) || r.has_unknown_sources() {
              found = true
              break
            }
          }
          if !found {
            raise @core.OptimizeError("Unknown table: \{table}")
          }
        }
        if source is None {
          new_selections.push(expression)
          break
        }
      }
      let source = source.unwrap()
      let mut columns = source_resolver.get_source_columns(
        source_table,
        only_visible=true,
      )
      if columns.is_empty() {
        columns = scope.outer_columns
      }
      if !pseudocolumns.is_empty() && dialect.cfg.excludes_pseudocolumns_from_star {
        columns = columns.filter(name => !pseudocolumns.contains(
          @core.py_upper(name),
        ))
      }
      if columns.is_empty() ||
        columns.contains("*") ||
        dedup_strings(columns).length() != columns.length() {
        return
      }
      let columns_to_exclude = match except_columns.get(table) {
        Some(c) => c
        None => []
      }
      let renamed_columns = match rename_columns.get(table) {
        Some(c) => c
        None => {}
      }
      let replaced_columns = match replace_columns.get(table) {
        Some(c) => c
        None => {}
      }
      let quoted_columns : @set.Set[String] = @set.Set([])
      match source {
        ScopeSource(s) if s.expression.kind.is_a(Query) =>
          for sel in selects_of(s.expression) {
            if is_output_identifier_quoted(sel) {
              quoted_columns.add(sel.output_name())
            }
          }
        _ => ()
      }
      if pivots is None {
        let selected_node = match scope.selected_sources().get(table) {
          Some((n, _)) => Some(n)
          None =>
            match source {
              TableSource(t) => Some(t)
              _ => None
            }
        }
        pivots = match selected_node {
          Some(n) => Some(n.list("pivots"))
          None => None
        }
      }
      match pivots {
        Some(pv) if !pv.is_empty() => {
          let mut pivot_columns = columns
          for pivot in pv {
            let out = pivot_output_columns(pivot, pivot_columns).map(kv => kv.0)
            pivot_columns = if out.is_empty() {
              pivot.alias_column_names()
            } else {
              out
            }
          }
          if !pivot_columns.is_empty() {
            let last_alias = pv[pv.length() - 1].alias_()
            for name in pivot_columns {
              if !columns_to_exclude.contains(name) {
                new_selections.push(
                  @core.alias_(
                    column_with_table(name, table=last_alias),
                    name,
                    copy=false,
                  ),
                )
              }
            }
            continue
          }
        }
        _ => ()
      }
      for name in columns {
        if columns_to_exclude.contains(name) || coalesced_columns.contains(name) {
          continue
        }
        match ilike_pattern {
          Some(p) if p != "" =>
            if !ilike_matches(p, name, dialect.cfg.star_ilike_backslash_escape) {
              continue
            }
          _ => ()
        }
        if using_column_tables.has(name, table) {
          coalesced_columns.add(name)
          let using_tables = using_column_tables.map[name]
          let coalesce_args = using_tables.map(t => column_with_table(name, table=t))
          new_selections.push(
            @core.alias_(@core.func_("coalesce", coalesce_args), name, copy=false),
          )
        } else {
          let alias_ = match renamed_columns.get(name) {
            Some(a) => a
            None => name
          }
          let quoted = quoted_columns.contains(name) ||
            (source is TableSource(_) && dialect.case_sensitive(name))
          let selection_expr = match replaced_columns.get(name) {
            Some(r) => r
            None => column_with_table(name, table~, quoted~)
          }
          new_selections.push(
            if alias_ != name {
              @core.alias_(selection_expr, alias_, copy=false)
            } else {
              selection_expr
            },
          )
        }
      }
    }
    if annotated_ahead {
      annotator.uncache(expression)
    }
  }
  if !new_selections.is_empty() && scope_expression.kind.is_a(Select) {
    if annotated_ahead {
      annotator.uncache(scope_expression, deep=false)
    }
    scope_expression.set("expressions", new_selections)
    scope.clear_cache()
  }
}
