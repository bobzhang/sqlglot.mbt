// Port of `transforms.explode_projection_to_unnest` (sqlglot/transforms.py), which the
// BigQuery generator uses for its Select preprocessing.

///|
/// Source names of a Select's scope (`{name for name, _ in Scope(expression).references}`).
fn scope_reference_names(select : @core.Expr) -> Array[String] {
  let names = []
  let sources : Array[@core.Expr] = []
  match select.arg("from_") {
    Some(f) =>
      match f.this() {
        Some(s) => sources.push(s)
        None => ()
      }
    None => ()
  }
  for j in select.list("joins") {
    match j.this() {
      Some(s) => sources.push(s)
      None => ()
    }
  }
  for source in sources {
    if source.kind == Table {
      names.push(source.alias_or_name())
    } else {
      let mut alias_name = source.alias()
      if alias_name == "" {
        match source.arg("alias") {
          Some(a) if a.kind == TableAlias && a.list("columns").length() == 1 =>
            alias_name = a.list("columns")[0].name()
          _ => ()
        }
      }
      names.push(alias_name)
    }
  }
  names
}

///|
fn new_name(names : @set.Set[String], name : String) -> String {
  let name = @core.find_new_name(n => names.contains(n), name)
  names.add(name)
  name
}

///|
fn col(name : Name, table : @core.Expr) -> @core.Expr {
  @core.mk(Column, [("this", name.ident()), ("table", table.copy())])
}

///|
/// A name that is either a plain string or an existing identifier (Python passes both
/// to `exp.to_identifier`, which keeps identifiers - and their quoting - as they are).
priv enum Name {
  S(String)
  I(@core.Expr)
}

///|
fn Name::ident(self : Name) -> @core.Expr {
  match self {
    S(s) => @core.to_identifier(s)
    I(e) => e.copy()
  }
}

///|
fn Name::is_empty(self : Name) -> Bool {
  match self {
    S(s) => s == ""
    I(_) => false
  }
}

///|
fn Name::text(self : Name) -> String {
  match self {
    S(s) => s
    I(e) => e.name()
  }
}

///|
/// Convert explode/posexplode projections into unnests.
fn explode_projection_to_unnest(index_offset : Int) -> @core.Transform {
  fn(expression) raise @core.SqlglotError {
    if expression.kind != Select {
      return expression
    }
    let taken_select_names = @set.Set::from_array(expression.named_selects())
    let taken_source_names = @set.Set::from_array(
      scope_reference_names(expression),
    )
    let arrays : Array[@core.Expr] = []
    let series_alias = new_name(taken_select_names, "pos")
    let series = @core.alias_table(
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
      columns=[series_alias],
    )
    // we use a copy here because expression.selects is mutated inside the loop
    for select in expression.selects().copy() {
      guard select.find([Explode]) is Some(found) else { continue }
      let mut explode = found
      let mut pos_alias = S("")
      let mut explode_alias = S("")
      let mut alias_node = select
      if select.kind == Alias {
        explode_alias = match select.arg("alias") {
          Some(a) => I(a)
          None => S("")
        }
      } else if select.kind == Aliases {
        let aliases = select.expressions()
        pos_alias = I(aliases[0])
        explode_alias = I(aliases[1])
        alias_node = select
          .replace(
            Some(
              @core.mk(Alias, [
                ("this", select.this()),
                ("alias", Some(@core.to_identifier(""))),
              ]),
            ),
          )
          .unwrap()
      } else {
        alias_node = select
          .replace(
            Some(
              @core.mk(Alias, [
                ("this", select.copy()),
                ("alias", @core.to_identifier("")),
              ]),
            ),
          )
          .unwrap()
        explode = alias_node.find([Explode]).unwrap()
      }
      let is_posexplode = explode.kind.is_a(Posexplode)
      let mut explode_arg = explode.this().unwrap()
      if explode.kind.is_a(ExplodeOuter) {
        let bracket = @core.mk(Bracket, [
          ("this", explode_arg.copy()),
          ("expressions", [@core.literal_int(0)]),
        ])
        bracket.set("safe", true)
        bracket.set("offset", true)
        explode_arg = @core.func_("IF", [
          @core.func_("ARRAY_SIZE", [
            @core.func_("COALESCE", [explode_arg, @core.mk0(Array)]),
          ])
          |> @core.exp_eq(@core.literal_int(0)),
          @core.array_([bracket]),
          explode_arg,
        ])
      }
      // This ensures that we won't use [POS]EXPLODE's argument as a new selection
      if explode_arg.kind == Column {
        taken_select_names.add(explode_arg.output_name())
      }
      let unnest_source_alias = new_name(taken_source_names, "_u")
      if explode_alias.is_empty() {
        explode_alias = S(new_name(taken_select_names, "col"))
        if is_posexplode {
          pos_alias = S(new_name(taken_select_names, "pos"))
        }
      }
      if pos_alias.is_empty() {
        pos_alias = S(new_name(taken_select_names, "pos"))
      }
      alias_node.set("alias", explode_alias.ident())
      let series_table_alias = series.arg("alias").unwrap().this().unwrap()
      let unnest_ident = @core.to_identifier(unnest_source_alias)
      let column = @core.mk(If, [
        (
          "this",
          @core.exp_eq(
            col(S(series_alias), series_table_alias),
            col(pos_alias, unnest_ident),
          ),
        ),
        ("true", col(explode_alias, unnest_ident)),
      ])
      explode.replace(Some(column)) |> ignore
      if is_posexplode {
        let expressions = expression.expressions()
        let mut idx = expressions.length()
        for i, x in expressions {
          if physical_equal(x, alias_node) {
            idx = i + 1
            break
          }
        }
        expressions.insert(
          idx,
          @core.alias_(
            @core.mk(If, [
              (
                "this",
                @core.exp_eq(
                  col(S(series_alias), series_table_alias),
                  col(pos_alias, unnest_ident),
                ),
              ),
              ("true", col(pos_alias, unnest_ident)),
            ]),
            pos_alias.text(),
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
        @core.alias_table(
          @core.mk(Unnest, [
            ("expressions", [explode_arg.copy()]),
            ("offset", pos_alias.ident()),
          ]),
          unnest_source_alias,
          columns=[explode_alias.text()],
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
            col(S(series_alias), series_table_alias),
            col(pos_alias, unnest_ident),
          ),
          @core.exp_and([
            @core.exp_binop(GT, col(S(series_alias), series_table_alias), size),
            @core.exp_eq(col(pos_alias, unnest_ident), size),
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
}
