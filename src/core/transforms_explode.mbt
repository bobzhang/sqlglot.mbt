// Port of `transforms.explode_projection_to_unnest` (sqlglot/transforms.py).

///|
/// Python `Expr._binop(klass, other)`: copies both operands and wraps binary operands in
/// parentheses unless one of them is already of kind `kind`.
fn explode_binop(kind : Kind, this : Expr, other : Expr) -> Expr {
  let mut this = this.copy()
  let mut other = other.copy()
  if !this.kind.is_a(kind) && !other.kind.is_a(kind) {
    this = wrap_binary(this)
    other = wrap_binary(other)
  }
  mk(kind, [("this", this), ("expression", other)])
}

///|
/// Python `exp.column(col, table=table)` where both may be identifiers or names.
fn explode_column(col : Value, table : Value) -> Expr {
  mk(Column, [("this", explode_ident(col)), ("table", explode_ident(table))])
}

///|
/// Python `exp.to_identifier(name)` for an identifier (copied) or a string.
fn explode_ident(v : Value) -> Expr {
  match v {
    Node(e) => e.copy()
    Str(s) => to_identifier(s)
    _ => to_identifier("")
  }
}

///|
/// Python `exp.alias_(expression, alias, table=[columns...])` for a node with an
/// `alias` arg.
fn explode_alias_table(e : Expr, name : String, columns : Array[Value]) -> Expr {
  let table_alias = mk1(TableAlias, to_identifier(name))
  e.set("alias", table_alias)
  for c in columns {
    table_alias.append("columns", explode_ident(c))
  }
  e
}

///|
/// Python `bool(value)` for an alias that is either an identifier or a string.
fn explode_value_truthy(v : Value) -> Bool {
  match v {
    Node(_) => true
    Str(s) => s != ""
    _ => false
  }
}

///|
/// Names of the sources of a Select's scope (Python `Scope(expression).references`).
fn explode_source_names(expression : Expr) -> Array[String] {
  let tables = []
  let others = []
  let nodes = []
  gen_walk_in_scope(expression, nodes)
  for node in nodes {
    if physical_equal(node, expression) {
      continue
    }
    let parent_is = fn(kinds : Array[Kind]) {
      match node.parent {
        Some(p) => p.kind.is_any(kinds)
        None => false
      }
    }
    if node.kind.is_a(Table) && !parent_is([JoinHint]) {
      tables.push(node.alias_or_name())
    } else if node.kind == Lateral ||
      (node.kind.is_a(UDTF) && parent_is([From, Join])) {
      others.push(node)
    } else if node.kind.is_a(Subquery) &&
      (
        node.alias() != "" ||
        (match node.this() {
          Some(t) => t.kind.is_any([Select, SetOperation])
          None => false
        })
      ) &&
      parent_is([From, Join]) {
      others.push(node)
    }
  }
  for o in others {
    let mut alias_name = o.alias()
    if alias_name == "" {
      match o.arg("alias") {
        Some(a) if a.kind.is_a(TableAlias) && a.list("columns").length() == 1 =>
          alias_name = a.list("columns")[0].name()
        _ => ()
      }
    }
    tables.push(alias_name)
  }
  tables
}

///|
/// Convert explode/posexplode projections into unnests (Python
/// `transforms.explode_projection_to_unnest(index_offset, unnest_map)`).
pub fn explode_projection_to_unnest(
  index_offset? : Int = 0,
  unnest_map? : Bool = false,
) -> Transform {
  fn(expression : Expr) raise SqlglotError {
    if !expression.kind.is_a(Select) {
      return expression
    }
    let taken_select_names : Set[String] = Set::from_array(
      expression.named_selects(),
    )
    let taken_source_names : Set[String] = Set::from_array(
      explode_source_names(expression),
    )
    fn new_name(names : Set[String], name : String) -> String {
      let name = find_new_name(n => names.contains(n), name)
      names.add(name)
      name
    }

    let arrays : Array[Expr] = []
    let series_alias = new_name(taken_select_names, "pos")
    let series = explode_alias_table(
      mk(Unnest, [
        (
          "expressions",
          [
            mk(GenerateSeries, [
              ("start", literal_number(index_offset.to_string())),
            ]),
          ],
        ),
      ]),
      new_name(taken_source_names, "_u"),
      [Str(series_alias)],
    )
    // we use a copy here because expression.selects is mutated inside the loop
    for select in expression.selects().copy() {
      guard select.find([Explode]) is Some(found) else { continue }
      let mut explode = found
      if unnest_map &&
        explode.kind == Explode &&
        explode.this_().is_type([DType::MAP]) &&
        (physical_equal(select, explode) || select.kind.is_a(Aliases)) {
        let (map_key_alias, map_value_alias) = if select.kind.is_a(Aliases) {
          let aliases = select.raw_list("expressions")
          (aliases[0], aliases[1])
        } else {
          (
            Str(new_name(taken_select_names, "key")),
            Str(new_name(taken_select_names, "value")),
          )
        }
        let map_unnest_source = new_name(taken_source_names, "_u")
        let key_col = explode_column(map_key_alias, Str(map_unnest_source))
        let map_key_select = alias_expr(
          key_col,
          Some(explode_ident(map_key_alias)),
          copy=false,
        )
        select.replace(Some(map_key_select)) |> ignore
        let expressions = expression.list("expressions")
        let mut idx = 0
        for i, x in expressions {
          if physical_equal(x, map_key_select) {
            idx = i
            break
          }
        }
        let value_col = explode_column(map_value_alias, Str(map_unnest_source))
        expressions.insert(
          idx + 1,
          alias_expr(
            value_col,
            Some(explode_ident(map_value_alias)),
            copy=false,
          ),
        )
        expression.set("expressions", expressions)
        let unnest = explode_alias_table(
          mk(Unnest, [("expressions", [explode.this_().copy()])]),
          map_unnest_source,
          [map_key_alias, map_value_alias],
        )
        if expression.has("from_") {
          expression.join_(unnest, kind="CROSS") |> ignore
        } else {
          expression.from_(unnest) |> ignore
        }
        continue
      }
      let mut pos_alias : Value = Str("")
      let mut explode_alias : Value = Str("")
      let alias = if select.kind.is_a(Alias) {
        explode_alias = select.get("alias").unwrap_or(Str(""))
        select
      } else if select.kind.is_a(Aliases) {
        let aliases = select.raw_list("expressions")
        pos_alias = aliases[0]
        explode_alias = aliases[1]
        let a = alias_expr(select.this_(), Some(to_identifier("")), copy=false)
        select.replace(Some(a)) |> ignore
        a
      } else {
        let a = alias_expr(select, Some(to_identifier("")))
        select.replace(Some(a)) |> ignore
        explode = a.find([Explode]).unwrap()
        a
      }
      let is_posexplode = explode.kind.is_a(Posexplode)
      let mut explode_arg = explode.this_()
      if explode.kind.is_a(ExplodeOuter) {
        let bracket = mk(Bracket, [
          ("this", explode_arg.copy()),
          ("expressions", [literal_number("0")]),
        ])
        bracket.set("safe", true)
        bracket.set("offset", true)
        explode_arg = func_("IF", [
          explode_binop(
            EQ,
            func_("ARRAY_SIZE", [
              func_("COALESCE", [explode_arg.copy(), mk0(Array)]),
            ]),
            literal_number("0"),
          ),
          mk(Array, [("expressions", [bracket])]),
          explode_arg.copy(),
        ])
      }
      // This ensures that we won't use [POS]EXPLODE's argument as a new selection
      if explode_arg.kind.is_a(Column) {
        taken_select_names.add(explode_arg.output_name())
      }
      let unnest_source_alias = new_name(taken_source_names, "_u")
      if !explode_value_truthy(explode_alias) {
        explode_alias = Str(new_name(taken_select_names, "col"))
        if is_posexplode {
          pos_alias = Str(new_name(taken_select_names, "pos"))
        }
      }
      if !explode_value_truthy(pos_alias) {
        pos_alias = Str(new_name(taken_select_names, "pos"))
      }
      alias.set("alias", explode_ident(explode_alias))
      let series_table_alias = series.arg("alias").unwrap().this_()
      let series_col = fn() {
        explode_column(Str(series_alias), Node(series_table_alias))
      }
      let pos_col = fn() { explode_column(pos_alias, Str(unnest_source_alias)) }
      let column = mk(If, [
        ("this", explode_binop(EQ, series_col(), pos_col())),
        ("true", explode_column(explode_alias, Str(unnest_source_alias))),
      ])
      explode.replace(Some(column)) |> ignore
      if is_posexplode {
        let expressions = expression.list("expressions")
        let mut idx = 0
        for i, x in expressions {
          if physical_equal(x, alias) {
            idx = i
            break
          }
        }
        let pos_if = mk(If, [
          ("this", explode_binop(EQ, series_col(), pos_col())),
          ("true", pos_col()),
        ])
        expressions.insert(
          idx + 1,
          alias_expr(pos_if, Some(explode_ident(pos_alias)), copy=false),
        )
        expression.set("expressions", expressions)
      }
      if arrays.is_empty() {
        if expression.has("from_") {
          expression.join_(series, kind="CROSS") |> ignore
        } else {
          expression.from_(series) |> ignore
        }
      }
      let mut size = mk1(ArraySize, explode_arg.copy())
      arrays.push(size)
      // trino doesn't support left join unnest with on conditions
      // if it did, this would be much simpler
      expression.join_(
        explode_alias_table(
          mk(Unnest, [
            ("expressions", [explode_arg.copy()]),
            ("offset", explode_ident(pos_alias)),
          ]),
          unnest_source_alias,
          [explode_alias],
        ),
        kind="CROSS",
      )
      |> ignore
      if index_offset != 1 {
        size = explode_binop(Sub, size, literal_number("1"))
      }
      expression.where_([
        or_([
          explode_binop(EQ, series_col(), pos_col()),
          and_([
            explode_binop(GT, series_col(), size),
            explode_binop(EQ, pos_col(), size),
          ]),
        ]),
      ])
      |> ignore
    }
    if !arrays.is_empty() {
      let mut end = mk(Greatest, [
        ("this", arrays[0]),
        ("expressions", arrays[1:].to_array()),
      ])
      if index_offset != 1 {
        end = explode_binop(
          Sub,
          end,
          literal_number((1 - index_offset).to_string()),
        )
      }
      series.expressions()[0].set("end", end)
    }
    expression
  }
}
