// Port of the optimizer-dependent transforms of sqlglot/transforms.py:
// `explode_projection_to_unnest` (needs `Scope`) and `eliminate_join_marks` (needs
// `traverse_scope` and `normalize`). The other transforms live in core's transforms.mbt.

///|
/// Python `exp.func(name, *args)` (copies the arguments and validates the result).
fn transforms_func(
  name : String,
  args : Array[@core.Expr],
) -> @core.Expr raise @core.SqlglotError {
  let converted = args.map(a => a.copy())
  let function = @core.func_(name, converted)
  for error_message in function.error_messages(nargs=converted.length()) {
    raise @core.ValueError(error_message)
  }
  function
}

///|
/// Python `exp.column(col, table=table)` where both parts are strings or identifiers.
fn transforms_column(
  col : @core.Value,
  table : @core.Value,
) -> @core.Expr raise @core.SqlglotError {
  @core.mk(Column, [
    ("this", @core.to_identifier_value(col)),
    ("table", @core.to_identifier_value(table)),
  ])
}

///|
/// Python `exp.alias_(expression, alias, table=[...columns])`.
fn transforms_alias_table(
  expression : @core.Expr,
  alias_name : String,
  columns : Array[@core.Value],
) -> @core.Expr raise @core.SqlglotError {
  let e = expression.copy()
  let table_alias = @core.mk1(TableAlias, @core.to_identifier(alias_name))
  e.set("alias", table_alias)
  for column in columns {
    table_alias.append("columns", @core.to_identifier_value(column))
  }
  e
}

///|
/// Python `expressions.index(value)` (structural equality) for an expression list.
fn transforms_index_of(
  expressions : Array[@core.Expr],
  value : @core.Expr,
) -> Int raise @core.SqlglotError {
  match expressions.search(value) {
    Some(i) => i
    None => raise @core.ValueError("\{value.kind.name()} is not in list")
  }
}

///|
/// Convert explode/posexplode projections into unnests.
pub fn explode_projection_to_unnest(
  index_offset? : Int = 0,
  unnest_map? : Bool = false,
) -> @core.Transform {
  fn(expression : @core.Expr) raise @core.SqlglotError {
    if expression.kind == Select {
      let taken_select_names : @set.Set[String] = @set.Set::new()
      for name in expression.named_selects() {
        taken_select_names.add(name)
      }
      let taken_source_names : @set.Set[String] = @set.Set::new()
      for reference in Scope::new(expression).references() {
        taken_source_names.add(reference.0)
      }
      fn new_name(names : @set.Set[String], name : String) -> String {
        let name = @core.find_new_name(n => names.contains(n), name)
        names.add(name)
        name
      }

      let arrays : Array[@core.Expr] = []
      let series_alias = new_name(taken_select_names, "pos")
      let series = transforms_alias_table(
        @core.mk(Unnest, [
          (
            "expressions",
            [
              @core.mk(GenerateSeries, [
                ("start", @core.literal_int(index_offset)),
              ]),
            ],
          ),
        ]),
        new_name(taken_source_names, "_u"),
        [Str(series_alias)],
      )

      // we use a snapshot here because expression.selects is mutated inside the loop
      for select in expression.selects() {
        let mut explode = match select.find([Explode]) {
          Some(e) => e
          None => continue
        }
        if unnest_map &&
          explode.kind == Explode &&
          explode.this_().is_type([MAP]) &&
          (physical_equal(select, explode) || select.kind.is_a(Aliases)) {
          let (map_key_alias, map_value_alias) : (@core.Value, @core.Value) = if select.kind.is_a(
              Aliases,
            ) {
            match select.expressions() {
              [k, v] => (Node(k), Node(v))
              aliases =>
                raise @core.ValueError(
                  if aliases.length() < 2 {
                    "not enough values to unpack (expected 2, got \{aliases.length()})"
                  } else {
                    "too many values to unpack (expected 2)"
                  },
                )
            }
          } else {
            let k = new_name(taken_select_names, "key")
            let v = new_name(taken_select_names, "value")
            (Str(k), Str(v))
          }
          let map_unnest_source = new_name(taken_source_names, "_u")
          let map_key_select = select
            .replace(
              Some(
                @core.exp_alias(
                  transforms_column(map_key_alias, Str(map_unnest_source)),
                  map_key_alias,
                ),
              ),
            )
            .unwrap()
          let expressions = expression.expressions()
          expressions.insert(
            transforms_index_of(expressions, map_key_select) + 1,
            @core.exp_alias(
              transforms_column(map_value_alias, Str(map_unnest_source)),
              map_value_alias,
            ),
          )
          expression.set("expressions", expressions)
          let unnest = transforms_alias_table(
            @core.mk(Unnest, [("expressions", [explode.this_().copy()])]),
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
        let mut pos_alias : @core.Value = Str("")
        let mut explode_alias : @core.Value = Str("")
        let aliased = if select.kind.is_a(Alias) {
          explode_alias = select.get("alias").unwrap_or(Str(""))
          select
        } else if select.kind.is_a(Aliases) {
          let aliases = select.expressions()
          pos_alias = Node(aliases[0])
          explode_alias = Node(aliases[1])
          select
          .replace(Some(@core.alias_(select.this_(), "", copy=false)))
          .unwrap()
        } else {
          let aliased = select.replace(Some(@core.alias_(select, ""))).unwrap()
          explode = aliased.find([Explode]).unwrap()
          aliased
        }
        let is_posexplode = explode.kind.is_a(Posexplode)
        let mut explode_arg = explode.this_()
        if explode.kind.is_a(ExplodeOuter) {
          let bracket = @core.mk(Bracket, [
            ("this", explode_arg.copy()),
            ("expressions", [@core.literal_int(0)]),
          ])
          bracket.set("safe", true)
          bracket.set("offset", true)
          explode_arg = transforms_func("IF", [
            @core.exp_eq(
              transforms_func("ARRAY_SIZE", [
                transforms_func("COALESCE", [explode_arg, @core.mk0(Array)]),
              ]),
              @core.literal_int(0),
            ),
            @core.array_([bracket]),
            explode_arg,
          ])
        }

        // This ensures that we won't use [POS]EXPLODE's argument as a new selection
        if explode_arg.kind.is_a(Column) {
          taken_select_names.add(explode_arg.output_name())
        }
        let unnest_source_alias = new_name(taken_source_names, "_u")
        if !explode_alias.truthy() {
          explode_alias = Str(new_name(taken_select_names, "col"))
          if is_posexplode {
            pos_alias = Str(new_name(taken_select_names, "pos"))
          }
        }
        if !pos_alias.truthy() {
          pos_alias = Str(new_name(taken_select_names, "pos"))
        }
        aliased.set("alias", @core.to_identifier_value(explode_alias))
        let series_table_alias : @core.Value = Node(
          series.arg("alias").unwrap().this_(),
        )
        let column = @core.mk(If, [
          (
            "this",
            @core.exp_eq(
              transforms_column(Str(series_alias), series_table_alias),
              transforms_column(pos_alias, Str(unnest_source_alias)),
            ),
          ),
          ("true", transforms_column(explode_alias, Str(unnest_source_alias))),
        ])
        explode.replace(Some(column)) |> ignore
        if is_posexplode {
          let expressions = expression.expressions()
          expressions.insert(
            transforms_index_of(expressions, aliased) + 1,
            @core.exp_alias(
              @core.mk(If, [
                (
                  "this",
                  @core.exp_eq(
                    transforms_column(Str(series_alias), series_table_alias),
                    transforms_column(pos_alias, Str(unnest_source_alias)),
                  ),
                ),
                ("true", transforms_column(pos_alias, Str(unnest_source_alias))),
              ]),
              pos_alias,
            ),
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
        let mut size = @core.mk1(ArraySize, explode_arg.copy())
        arrays.push(size)

        // trino doesn't support left join unnest with on conditions
        // if it did, this would be much simpler
        expression.join_(
          transforms_alias_table(
            @core.mk(Unnest, [
              ("expressions", [explode_arg.copy()]),
              ("offset", @core.to_identifier_value(pos_alias)),
            ]),
            unnest_source_alias,
            [explode_alias],
          ),
          kind="CROSS",
        )
        |> ignore
        if index_offset != 1 {
          size = @core.exp_binop(Sub, size, @core.literal_int(1))
        }
        expression.where_([
          @core.exp_or([
            @core.exp_eq(
              transforms_column(Str(series_alias), series_table_alias),
              transforms_column(pos_alias, Str(unnest_source_alias)),
            ),
            @core.exp_and([
              @core.exp_binop(
                GT,
                transforms_column(Str(series_alias), series_table_alias),
                size,
              ),
              @core.exp_eq(
                transforms_column(pos_alias, Str(unnest_source_alias)),
                size,
              ),
            ]),
          ]),
        ])
        |> ignore
      }
      if !arrays.is_empty() {
        let mut end = @core.mk(Greatest, [
          ("this", arrays[0]),
          ("expressions", arrays[1:].to_array()),
        ])
        if index_offset != 1 {
          end = @core.exp_binop(Sub, end, @core.literal_int(1 - index_offset))
        }
        series.expressions()[0].set("end", end)
      }
    }
    expression
  }
}

///|
/// Python `assert condition, message` (raised as a `ValueError` carrying the
/// `AssertionError` message, since `SqlglotError` has no assertion variant).
fn transforms_assert(
  condition : Bool,
  message : String,
) -> Unit raise @core.SqlglotError {
  if !condition {
    raise @core.ValueError("AssertionError: \{message}")
  }
}

///|
/// Remove Oracle-style `(+)` join marks by converting them into explicit LEFT JOINs.
///
/// See https://docs.oracle.com/cd/B19306_01/server.102/b14200/queries006.htm#sthref3178
///
/// 1. You cannot specify the (+) operator in a query block that also contains FROM clause
///    join syntax.
/// 2. The (+) operator can appear only in the WHERE clause or, in the context of
///    left-correlation (that is, when specifying the TABLE clause) in the FROM clause, and can
///    be applied only to a column of a table or view.
///
/// The (+) operator does not produce an outer join if you specify one table in the outer query
/// and the other table in an inner query. A WHERE condition containing the (+) operator cannot
/// be combined with another condition using the OR logical operator, cannot use the IN
/// comparison condition and cannot compare a marked column with a subquery.
pub fn eliminate_join_marks(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  // we go in reverse to check the main query for left correlation
  let scopes = traverse_scope(expression)
  for i = scopes.length() - 1; i >= 0; i = i - 1 {
    let scope = scopes[i]
    let query = scope.expression
    let where_ = match query.arg("where") {
      Some(w) => w
      None => continue
    }
    let joins = query.list("joins")
    if !where_.find_all([Column]).any(c => c.has("join_mark")) {
      continue
    }

    // knockout: we do not support left correlation (see point 2)
    transforms_assert(
      !scope.is_correlated_subquery(),
      "Correlated queries are not supported",
    )

    // make sure we have AND of ORs to have clear join terms
    let where_ = normalize(where_.this_())
    transforms_assert(normalized(where_), "Cannot normalize JOIN predicates")
    // {name: list of join AND conditions}, in insertion order
    let joins_ons : Map[String, Array[@core.Expr]] = {}
    let conds = if where_.kind.is_a(And) {
      where_.flatten().collect()
    } else {
      [where_]
    }
    for cond in conds {
      let join_cols = cond
        .find_all([Column])
        .filter(col => col.has("join_mark"))
        .collect()
      let left_join_table : Array[String] = []
      for col in join_cols {
        let table = col.table_name()
        if !left_join_table.contains(table) {
          left_join_table.push(table)
        }
      }
      if left_join_table.is_empty() {
        continue
      }
      transforms_assert(
        !(left_join_table.length() > 1),
        "Cannot combine JOIN predicates from different tables",
      )
      for col in join_cols {
        col.set("join_mark", false)
      }
      match joins_ons.get(left_join_table[0]) {
        Some(l) => l.push(cond)
        None => joins_ons[left_join_table[0]] = [cond]
      }
    }
    let old_joins : Map[String, @core.Expr] = {}
    for join in joins {
      old_joins[join.alias_or_name()] = join
    }
    let new_joins : Map[String, @core.Expr] = {}
    let query_from = match query.arg("from_") {
      Some(f) => f
      None => raise @core.ValueError("KeyError: 'from_'")
    }
    for table, predicates in joins_ons {
      let join_what = old_joins.get(table).unwrap_or(query_from).this_().copy()
      new_joins[join_what.alias_or_name()] = @core.mk(Join, [
        ("this", join_what),
        ("on", @core.exp_and(predicates)),
        ("kind", "LEFT"),
      ])
      for p in predicates {
        while p.parent is Some(pp) && pp.kind == Paren {
          pp.replace(Some(p)) |> ignore
        }
        let parent = p.parent
        p.pop() |> ignore
        match parent {
          Some(parent) if parent.kind.is_a(Binary) =>
            match parent.arg("this") {
              None => parent.replace(parent.arg("expression")) |> ignore
              Some(left) => parent.replace(Some(left)) |> ignore
            }
          Some(parent) if parent.kind.is_a(Where) => parent.pop() |> ignore
          _ => ()
        }
      }
    }
    if new_joins.contains(query_from.alias_or_name()) {
      // Python takes the first element of the set difference `old_joins.keys() -
      // new_joins.keys()`, whose order is unspecified; we use insertion order.
      let only_old_joins = old_joins
        .keys()
        .filter(k => !new_joins.contains(k))
        .collect()
      transforms_assert(
        only_old_joins.length() >= 1,
        "Cannot determine which table to use in the new FROM clause",
      )
      let new_from_name = only_old_joins[0]
      query.set("from_", @core.mk1(From, old_joins[new_from_name].this()))
    }
    if !new_joins.is_empty() {
      // preserve any other joins
      for n, j in old_joins {
        if !new_joins.contains(n) && n != query.arg("from_").unwrap().name() {
          if j.text("kind").is_empty() {
            j.set("kind", "CROSS")
          }
          new_joins[n] = j
        }
      }
      query.set("joins", new_joins.values().collect())
    }
  }
  expression
}
