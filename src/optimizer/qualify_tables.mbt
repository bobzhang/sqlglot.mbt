// Port of sqlglot/optimizer/qualify_tables.py and normalize_identifiers.py.

///|
/// Normalize identifiers by converting them to either lower or upper case, ensuring
/// the semantics are preserved in each case (e.g. by respecting case-sensitivity).
pub fn normalize_identifiers(
  expression : @core.Expr,
  dialect? : @core.Dialect,
  store_original_column_identifiers? : Bool = false,
) -> @core.Expr {
  @core.normalize_identifiers(
    expression,
    get_dialect(dialect),
    store_original_column_identifiers~,
  )
}

///|
/// `normalize_identifiers("name", dialect)`: parses `name` as an identifier first.
pub fn normalize_identifier_str(
  name : String,
  dialect? : @core.Dialect,
) -> @core.Expr {
  let d = get_dialect(dialect)
  normalize_identifiers(@core.parse_identifier(name, dialect=d), dialect=d)
}

///|
/// Rewrite the AST to have fully qualified tables. Join constructs such as
/// `(t1 JOIN t2) AS t` will be expanded into `(SELECT * FROM t1 AS t1, t2 AS t2) AS t`.
pub fn qualify_tables(
  expression : @core.Expr,
  db? : String,
  catalog? : String,
  on_qualify? : (@core.Expr) -> Unit,
  dialect? : @core.Dialect,
  canonicalize_table_aliases? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  let dialect = get_dialect(dialect)
  let next_alias_name = @core.name_sequence("_")
  let db_ident = match db {
    Some(d) if d != "" => {
      let i = @core.parse_identifier(d, dialect~)
      i.get_meta()["is_table"] = Bool(true)
      Some(normalize_identifiers(i, dialect~))
    }
    _ => None
  }
  let catalog_ident = match catalog {
    Some(c) if c != "" => {
      let i = @core.parse_identifier(c, dialect~)
      i.get_meta()["is_table"] = Bool(true)
      Some(normalize_identifiers(i, dialect~))
    }
    _ => None
  }
  fn qualify_one(table : @core.Expr) {
    match table.this() {
      Some(t) if t.kind == Identifier => {
        match db_ident {
          Some(d) if !table.has("db") => table.set("db", d.copy())
          _ => ()
        }
        match catalog_ident {
          Some(c) if !table.has("catalog") && table.has("db") =>
            table.set("catalog", c.copy())
          _ => ()
        }
      }
      _ => ()
    }
  }

  if (db_ident is Some(_) || catalog_ident is Some(_)) &&
    !expression.kind.is_a(Query) {
    let cte_names : @set.Set[String] = @set.new()
    match expression.arg("with_") {
      Some(w) => for cte in w.expressions() { cte_names.add(cte.alias_or_name()) }
      None => ()
    }
    for node in expression.walk(prune=n => n.kind.is_a(Query)) {
      if node.kind.is_a(Table) && !cte_names.contains(node.name()) {
        qualify_one(node)
      }
    }
  }
  fn set_alias(
    expression : @core.Expr,
    canonical_aliases : Map[String, String],
    target_alias : String?,
    scope : Scope?,
    normalize : Bool,
    columns : Array[@core.Expr]?,
  ) -> Unit {
    let alias = match expression.arg("alias") {
      Some(a) => a
      None => @core.mk0(TableAlias)
    }
    let new_alias_name = if canonicalize_table_aliases {
      let n = next_alias_name()
      let key = if alias.name() != "" {
        alias.name()
      } else {
        match target_alias {
          Some(t) => t
          None => ""
        }
      }
      canonical_aliases[key] = n
      n
    } else if alias.name() == "" {
      match target_alias {
        Some(t) if t != "" =>
          if normalize {
            normalize_identifier_str(t, dialect~).name()
          } else {
            t
          }
        _ => next_alias_name()
      }
    } else {
      return
    }
    alias.set("this", @core.to_identifier(new_alias_name))
    match columns {
      Some(cols) if !cols.is_empty() => alias.set("columns", cols)
      _ => ()
    }
    expression.set("alias", alias)
    match scope {
      Some(s) => s.rename_source(None, new_alias_name)
      None => ()
    }
  }

  for scope in traverse_scope(expression) {
    let parent = scope.parent
    let local_columns = scope.local_columns()
    let canonical_aliases : Map[String, String] = {}
    let queries = scope.subqueries().copy()
    if scope.is_root() && scope.expression.kind.is_a(Subquery) {
      queries.push(scope.expression.unnest())
    } else if scope.is_subquery() {
      queries.push(scope.expression)
    }
    for query in queries {
      match query.parent {
        Some(subquery) if subquery.kind.is_a(Subquery) => {
          let unwrapped = subquery.unwrap_subquery()
          if parent_is(unwrapped, [From, Join]) {
            continue
          }
          if parent_is(unwrapped, [Create]) && !physical_equal(unwrapped, subquery) {
            unwrapped.set("this", subquery)
          } else {
            unwrapped.replace(Some(subquery)) |> ignore
          }
        }
        _ => ()
      }
    }
    for derived_table in scope.derived_tables() {
      let unnested = derived_table.unnest()
      if unnested.kind.is_a(Table) {
        let joins = unnested.get("joins")
        unnested.set("joins", @core.null_arg)
        let sel = @core.select_([@core.mk0(Star)]).from_(unnested.copy())
        derived_table.this_().replace(Some(sel)) |> ignore
        match joins {
          Some(j) => derived_table.this_().set("joins", j)
          None => derived_table.this_().set("joins", @core.null_arg)
        }
      }
      set_alias(derived_table, canonical_aliases, None, Some(scope), false, None)
      match derived_table.list("pivots").last() {
        Some(pivot) => set_alias(pivot, canonical_aliases, None, None, false, None)
        None => ()
      }
    }
    let table_aliases : Map[String, @core.Expr] = {}
    for name, source in scope.sources.copy() {
      match parent {
        Some(p) =>
          match p.sources.get(name) {
            Some(ps) if ps.is_same(source) => continue
            _ => ()
          }
        None => ()
      }
      match source {
        TableSource(source) => {
          let is_real_table_source = name != ""
          let mut name = name
          let pivot = source.list("pivots").last()
          if pivot is Some(_) {
            name = source.name()
          }
          let table_this = source.this()
          let table_alias = source.arg("alias")
          let mut function_columns : Array[@core.Expr]? = None
          match table_this {
            Some(tt) if tt.kind.is_a(Func) => {
              let defaults = dialect.cfg.default_functions_column_names.get(
                tt.kind,
              )
              match table_alias {
                None =>
                  function_columns = Some(
                    match defaults {
                      Some(d) => [@core.to_identifier(d)]
                      None => []
                    },
                  )
                Some(ta) => {
                  let cols = ta.list("columns")
                  if !cols.is_empty() {
                    function_columns = Some(cols.map(c => c.copy()))
                  } else if defaults is Some(_) {
                    function_columns = Some([
                      @core.to_identifier(source.alias_or_name()),
                    ])
                    source.set("alias", @core.null_arg)
                    name = ""
                  }
                }
              }
            }
            _ => ()
          }
          let target = if name != "" { name } else { source.name() }
          set_alias(
            source,
            canonical_aliases,
            Some(target),
            None,
            true,
            function_columns,
          )
          let source_fqn = source.parts().map(p => p.name()).join(".")
          let had_explicit_alias = match table_alias {
            Some(ta) => ta.name() != ""
            None => false
          }
          if !had_explicit_alias || !table_aliases.contains(source_fqn) {
            match source.arg("alias") {
              Some(a) =>
                match a.this() {
                  Some(t) => table_aliases[source_fqn] = t.copy()
                  None => ()
                }
              None => ()
            }
          }
          match pivot {
            Some(pivot) => {
              let target_alias = if pivot.has("unpivot") {
                Some(source.alias())
              } else {
                None
              }
              set_alias(pivot, canonical_aliases, target_alias, None, true, None)
              match scope.sources.get(source.alias_or_name()) {
                Some(ScopeSource(_)) => continue
                _ => ()
              }
            }
            None => ()
          }
          if is_real_table_source {
            qualify_one(source)
            match on_qualify {
              Some(f) => f(source)
              None => ()
            }
          }
        }
        ScopeSource(s) if s.is_udtf() => {
          let udtf = s.expression
          set_alias(udtf, canonical_aliases, None, None, false, None)
          let table_alias = udtf.arg("alias").unwrap()
          if udtf.kind.is_a(Values) && table_alias.list("columns").is_empty() {
            let column_aliases = dialect
              .generate_values_aliases(udtf)
              .map(i => normalize_identifiers(i, dialect~))
            table_alias.set("columns", column_aliases)
          } else if udtf.kind.is_a(TableFromRows) &&
            table_alias.list("columns").is_empty() {
            match udtf.this() {
              Some(t) =>
                match dialect.cfg.default_functions_column_names.get(t.kind) {
                  Some(d) =>
                    table_alias.set("columns", [
                      normalize_identifiers(@core.to_identifier(d), dialect~),
                    ])
                  None => ()
                }
              None => ()
            }
          }
        }
        _ => ()
      }
    }
    for table in scope.tables() {
      if table.alias() == "" && parent_is(table, [From, Join]) {
        set_alias(
          table,
          canonical_aliases,
          Some(table.name()),
          None,
          false,
          None,
        )
      }
    }
    for column in local_columns {
      let column_table = column.table_name()
      if column.db() != "" {
        let parts = column.parts()
        let key = parts[0:parts.length() - 1]
          .to_array()
          .map(p => p.name())
          .join(".")
        match table_aliases.get(key) {
          Some(table_alias) => {
            for p in ["table", "db", "catalog"] {
              column.set(p, @core.null_arg)
            }
            column.set("table", table_alias.copy())
          }
          None => ()
        }
      } else if !canonical_aliases.is_empty() && column_table != "" {
        match canonical_aliases.get(column_table) {
          Some(canonical_table) if canonical_table != "" &&
            canonical_table != column_table =>
            column.set("table", @core.to_identifier(canonical_table))
          _ => ()
        }
      }
    }
  }
  expression
}
