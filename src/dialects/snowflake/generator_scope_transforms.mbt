// Port of the scope-dependent Select transforms used by the Snowflake generator:
// `transforms.explode_projection_to_unnest()` (index_offset=0, unnest_map=False),
// `_transform_generate_date_array` and `_qualify_unnested_columns`.

///|
fn new_name(names : Array[String], name : String) -> String {
  let name = @core.find_new_name(n => names.contains(n), name)
  names.push(name)
  name
}

///|
/// `exp.alias_(expression, alias, table=[columns...])` (copies `expression`).
fn alias_with_table(
  expression : @core.Expr,
  alias_name : String?,
  columns : Array[@core.Expr],
) -> @core.Expr {
  let e = expression.copy()
  let table_alias = @core.mk(TableAlias, [
    ("this", alias_name.map(n => @core.to_identifier(n))),
  ])
  for c in columns {
    table_alias.append("columns", c)
  }
  e.set("alias", table_alias)
  e
}

///|
fn ident_of(v : @core.Value) -> @core.Expr {
  match v {
    Node(e) => e
    Str(s) => @core.to_identifier(s)
    _ => @core.to_identifier("")
  }
}

///|
/// `exp.column(name, table=table)` where both may be identifiers or strings.
fn column_v(name : @core.Value, table : @core.Value) -> @core.Expr {
  @core.mk(Column, [("this", ident_of(name)), ("table", ident_of(table))])
}

///|
/// `transforms.explode_projection_to_unnest(index_offset=0)`: converts
/// explode/posexplode projections into unnests.
fn explode_projection_to_unnest(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == Select else { return expression }
  let index_offset = 0
  let taken_select_names = expression.named_selects()
  let taken_source_names = scope_reference_names(expression)
  let arrays : Array[@core.Expr] = []
  let series_alias = new_name(taken_select_names, "pos")
  let series = alias_with_table(
    @core.mk(Unnest, [
      (
        "expressions",
        [@core.mk(GenerateSeries, [("start", @core.literal_int(index_offset))])],
      ),
    ]),
    Some(new_name(taken_source_names, "_u")),
    [@core.to_identifier(series_alias)],
  )
  // we use a copy here because expression.selects is mutated inside the loop
  for select in expression.selects().copy() {
    guard select.find([Explode]) is Some(found) else { continue }
    let mut explode = found
    let mut pos_alias : @core.Value = Str("")
    let mut explode_alias : @core.Value = Str("")
    let alias_node = if select.kind == Alias {
      explode_alias = select.get("alias").unwrap()
      select
    } else if select.kind == Aliases {
      let aliases = select.expressions()
      pos_alias = Node(aliases[0])
      explode_alias = Node(aliases[1])
      let a = @core.alias_(select.this_(), "", copy=false)
      select.replace(Some(a)) |> ignore
      a
    } else {
      let a = @core.alias_(select, "")
      select.replace(Some(a)) |> ignore
      explode = a.find([Explode]).unwrap()
      a
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
      explode_arg = @core.func_("IF", [
        @core.exp_eq(
          @core.func_("ARRAY_SIZE", [
            @core.func_("COALESCE", [explode_arg, @core.mk0(Array)]),
          ]),
          @core.literal_int(0),
        ),
        @core.mk(Array, [("expressions", [bracket])]),
        explode_arg,
      ])
    }
    // This ensures that we won't use [POS]EXPLODE's argument as a new selection
    if explode_arg.kind == Column {
      taken_select_names.push(explode_arg.output_name())
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
    alias_node.set("alias", ident_of(explode_alias).copy())
    let series_table_alias : @core.Value = match series.arg("alias") {
      Some(a) => Node(a.this_())
      None => Str("")
    }
    let src : @core.Value = Str(unnest_source_alias)
    let series_alias_v : @core.Value = Str(series_alias)
    let column = @core.mk(If, [
      (
        "this",
        @core.exp_eq(
          column_v(series_alias_v, series_table_alias),
          column_v(pos_alias, src),
        ),
      ),
      ("true", column_v(explode_alias, src)),
    ])
    explode.replace(Some(column)) |> ignore
    if is_posexplode {
      let expressions = expression.expressions()
      let mut idx = 0
      for i, x in expressions {
        if physical_equal(x, alias_node) {
          idx = i
          break
        }
      }
      let pos_name = match pos_alias {
        Str(s) => s
        Node(e) => e.name()
        _ => ""
      }
      let new_expressions = expressions.copy()
      new_expressions.insert(
        idx + 1,
        @core.alias_(
          @core.mk(If, [
            (
              "this",
              @core.exp_eq(
                column_v(series_alias_v, series_table_alias),
                column_v(pos_alias, src),
              ),
            ),
            ("true", column_v(pos_alias, src)),
          ]),
          pos_name,
        ),
      )
      expression.set("expressions", new_expressions)
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
      alias_with_table(
        @core.mk(Unnest, [
          ("expressions", [explode_arg.copy()]),
          ("offset", ident_of(pos_alias).copy()),
        ]),
        Some(unnest_source_alias),
        [ident_of(explode_alias).copy()],
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
          column_v(series_alias_v, series_table_alias),
          column_v(pos_alias, src),
        ),
        @core.exp_and([
          @core.exp_binop(
            GT,
            column_v(series_alias_v, series_table_alias),
            size,
          ),
          @core.exp_eq(column_v(pos_alias, src), size),
        ]),
      ]),
    ])
    |> ignore
  }
  if !arrays.is_empty() {
    let mut end = @core.mk(Greatest, [
      ("this", arrays[0]),
      ("expressions", arrays[1:].to_owned()),
    ])
    if index_offset != 1 {
      end = @core.exp_binop(Sub, end, @core.literal_int(1 - index_offset))
    }
    series.expressions()[0].set("end", end)
  }
  expression
}

///|
fn unnest_generate_date_array(
  unnest : @core.Expr,
) -> Unit raise @core.SqlglotError {
  let generate_date_array = unnest.expressions()[0]
  let start = generate_date_array.arg("start")
  let end = generate_date_array.arg("end")
  let step = generate_date_array.arg("step")
  guard start is Some(start) &&
    end is Some(end) &&
    step is Some(step) &&
    step.kind == Interval &&
    step.name() == "1" else {
    return
  }
  let unit = step.arg("unit")
  let mut unnest_alias = unnest.arg("alias")
  let sequence_value_name : @core.Expr = match unnest_alias {
    Some(a) => {
      let a = a.copy()
      unnest_alias = Some(a)
      match a.list("columns").get(0) {
        Some(c) => c
        None => @core.column_of("value")
      }
    }
    None => @core.column_of("value")
  }
  let sequence_value_str = sequence_value_name.name()
  // We'll add the next sequence value to the starting date and project the result
  let date_add = build_date_time_add(DateAdd)([
    unit.unwrap(),
    @core.exp_cast(sequence_value_name, INT),
    @core.exp_cast(start, DATE),
  ])
  // We use DATEDIFF to compute the number of sequence values needed
  let number_sequence = build_array_generate_range([
    @core.literal_int(0),
    @core.exp_add(
      build_date_diff([unit.unwrap(), start, end]),
      @core.literal_int(1),
    ),
  ])
  unnest.set("expressions", [number_sequence])
  match unnest.parent {
    Some(unnest_parent) if unnest_parent.kind == Join =>
      match unnest_parent.parent {
        Some(select) if select.kind == Select => {
          let replace_column_name = sequence_value_str
          for column in scope_columns(select) {
            if @core.py_lower(column.name()) ==
              @core.py_lower(replace_column_name) {
              let replacement = match column.parent {
                Some(p) if p.kind == Select =>
                  @core.alias_(date_add, replace_column_name)
                _ => date_add
              }
              column.replace(Some(replacement)) |> ignore
            }
          }
          let lateral = @core.mk1(Lateral, unnest_parent.this_().pop())
          unnest_parent.replace(Some(@core.mk1(Join, lateral))) |> ignore
        }
        _ => ()
      }
    _ => {
      let sub = @core.select_([@core.alias_(date_add, sequence_value_str)]).from_(
        unnest.copy(),
      )
      unnest.replace(
        Some(@core.exp_subquery_with_alias_expr(sub, unnest_alias, copy=false)),
      )
      |> ignore
    }
  }
}

///|
fn transform_generate_date_array(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == Select {
    for
      generate_date_array in expression.find_all([GenerateDateArray]).collect() {
      let parent = generate_date_array.parent
      // If GENERATE_DATE_ARRAY is used directly as an array (e.g passed into ARRAY_LENGTH), the transformed Snowflake
      // query is the following (it'll be unnested properly on the next iteration due to copy):
      // SELECT ref(GENERATE_DATE_ARRAY(...)) -> SELECT ref((SELECT ARRAY_AGG(*) FROM UNNEST(GENERATE_DATE_ARRAY(...))))
      if !opt_kind_is(parent, [Unnest]) {
        let unnest = @core.mk(Unnest, [
          ("expressions", [generate_date_array.copy()]),
        ])
        generate_date_array.replace(
          Some(
            @core.select_([@core.mk1(ArrayAgg, @core.mk0(Star))])
            .from_(unnest)
            .subquery(),
          ),
        )
        |> ignore
      }
      match parent {
        Some(p) if p.kind == Unnest &&
          opt_kind_is(p.parent, [From, Join]) &&
          p.expressions().length() == 1 => unnest_generate_date_array(p)
        _ => ()
      }
    }
  }
  expression
}

///|
fn qualify_unnested_columns(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == Select else { return expression }
  let scope = build_mini_scope(expression)
  let unnests = @core.gen_find_all_in_scope(expression, [Unnest])
  if unnests.is_empty() {
    return expression
  }
  let taken_source_names = scope.sources.copy()
  let column_source : Map[String, @core.Expr] = Map([])
  let unnest_to_identifier : Array[(@core.Expr, @core.Expr)] = []
  let mut unnest_identifier : @core.Expr? = None
  let orig_expression = expression.copy()
  for unnest in unnests {
    if !opt_kind_is(unnest.parent, [From, Join]) {
      continue
    }
    // Try to infer column names produced by an unnest operator. This is only possible
    // when we can peek into the (statically known) contents of the unnested value.
    let unnest_columns : Array[String] = []
    for unnest_expr in unnest.expressions() {
      if unnest_expr.kind != Array {
        continue
      }
      for array_expr in unnest_expr.expressions() {
        if !(array_expr.kind == Struct &&
          !array_expr.expressions().is_empty() &&
          array_expr.expressions().iter().all(e => e.kind == PropertyEQ)) {
          continue
        }
        for struct_expr in array_expr.expressions() {
          let n = @core.py_lower(struct_expr.this_().name())
          if !unnest_columns.contains(n) {
            unnest_columns.push(n)
          }
        }
        break
      }
      if !unnest_columns.is_empty() {
        break
      }
    }
    match unnest.arg("alias") {
      None => {
        let alias_name = new_name(taken_source_names, "value")
        // Produce a `TableAlias` AST similar to what is produced for BigQuery. This
        // will be corrected later, when we generate SQL for the `Unnest` AST node.
        let aliased_unnest = alias_with_table(unnest, None, [
          @core.to_identifier(alias_name),
        ])
        unnest.replace(Some(aliased_unnest)) |> ignore
        unnest_identifier = aliased_unnest
          .arg("alias")
          .unwrap()
          .list("columns")
          .get(0)
      }
      Some(unnest_alias) =>
        unnest_identifier = match unnest_alias.this() {
          Some(t) => Some(t)
          None => unnest_alias.list("columns").get(0)
        }
    }
    guard unnest_identifier is Some(ui) && ui.kind == Identifier else {
      return orig_expression
    }
    unnest_to_identifier.push((unnest, ui))
    for c in unnest_columns {
      column_source[@core.py_lower(c)] = ui
    }
  }
  for column in scope_columns(expression) {
    if column.text("table") != "" {
      continue
    }
    let mut table = column_source.get(@core.py_lower(column.name()))
    if unnest_identifier is Some(ui) &&
      table is None &&
      scope.sources.length() == 1 &&
      @core.py_lower(column.name()) != @core.py_lower(ui.name()) {
      let unnest_ancestor = column.find_ancestor([Unnest, Select])
      match unnest_ancestor {
        Some(ua) if ua.kind == Unnest => {
          let mut ancestor_identifier : @core.Expr? = None
          for kv in unnest_to_identifier {
            if kv.0 == ua {
              ancestor_identifier = Some(kv.1)
              break
            }
          }
          if ancestor_identifier is Some(ai) &&
            @core.py_lower(ai.name()) == @core.py_lower(ui.name()) {
            continue
          }
        }
        _ => ()
      }
      table = Some(ui)
    }
    column.set("table", table.map(t => t.copy()))
  }
  expression
}
