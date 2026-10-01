// Port of the scope-dependent Select transforms used by the Snowflake generator
// (`explode_projection_to_unnest` comes from the optimizer package):
// `_transform_generate_date_array` and `_qualify_unnested_columns`, built on the
// optimizer's `build_scope`.

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
          match @optimizer.build_scope(select) {
            Some(scope) =>
              for column in scope.columns() {
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
            None => ()
          }
          let lateral = @core.mk1(Lateral, unnest_parent.this_().pop())
          unnest_parent.replace(Some(@core.mk1(Join, lateral))) |> ignore
        }
        _ => ()
      }
    _ => {
      // `date_add.as_(sequence_value_name)`: an alias column Identifier is reused
      // as-is (keeping its quoting); the "value" fallback is a plain string
      let projection = if sequence_value_name.kind == Identifier {
        @core.mk(Alias, [
          ("this", date_add.copy()),
          ("alias", sequence_value_name.copy()),
        ])
      } else {
        @core.alias_(date_add, sequence_value_str)
      }
      let sub = @core.select_([projection]).from_(unnest.copy())
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
  guard @optimizer.build_scope(expression) is Some(scope) else {
    return expression
  }
  let unnests = scope.find_all([Unnest]).collect()
  if unnests.is_empty() {
    return expression
  }
  let taken_source_names = scope.sources.keys().collect()
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
        scope.replace(unnest, aliased_unnest)
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
  for column in scope.columns() {
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
