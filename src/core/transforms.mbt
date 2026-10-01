// Port of sqlglot/transforms.py (except move_ctes_to_top_level / ensure_bools, which
// live in transforms_gen.mbt, and the optimizer-dependent transforms, which live in
// the optimizer package).

///|
/// A `preprocess` step. Every public transform has this signature (even those that cannot
/// currently raise, which carry `#warnings("-unused_error_type")`) so that it can be
/// passed to `preprocess` directly, as in Python.
pub type Transform = (Expr) -> Expr raise SqlglotError

///|
/// Creates a generator function by chaining a sequence of transformations and converting the
/// resulting expression to SQL (Python `transforms.preprocess`).
pub fn preprocess(transforms : Array[Transform], generator? : GenFn) -> GenFn {
  fn(self : Generator, expression : Expr) raise SqlglotError {
    let expression_type = expression.kind
    let mut expression = expression
    try {
      for t in transforms {
        expression = t(expression)
      }
    } catch {
      UnsupportedError(msg) => self.unsupported(msg)
      e => raise e
    }
    match generator {
      Some(g) => return g(self, expression)
      None => ()
    }
    let kind = expression.kind
    match self.fns.methods.get(kind) {
      Some(f) => return f(self, expression)
      None => ()
    }
    match self.base_dispatch(kind, expression) {
      Some(s) => return s
      None => ()
    }
    match self.fns.transforms.get(kind) {
      Some(handler) => {
        if expression_type == kind {
          if kind.is_a(Func) {
            return self.function_fallback_sql(expression)
          }
          raise ValueError(
            "Expr type \{kind.name()} requires a _sql method in order to be transformed.",
          )
        }
        handler(self, expression)
      }
      None => raise ValueError("Unsupported expression type \{kind.name()}.")
    }
  }
}

///|
pub fn unnest_generate_date_array_using_recursive_cte(
  expression : Expr,
) -> Expr raise SqlglotError {
  if expression.kind == Select {
    let mut count = 0
    let recursive_ctes = []
    for unnest in expression.find_all([Unnest]).collect() {
      let parent_ok = match unnest.parent {
        Some(p) => p.kind.is_any([From, Join])
        None => false
      }
      let exprs = unnest.expressions()
      if !parent_ok || exprs.length() != 1 || exprs[0].kind != GenerateDateArray {
        continue
      }
      let generate_date_array = exprs[0]
      let start = generate_date_array.arg("start")
      let end = generate_date_array.arg("end")
      let step = generate_date_array.arg("step")
      let (start, end, step) = match (start, end, step) {
        (Some(s), Some(e), Some(st)) if st.kind == Interval => (s, e, st)
        _ => continue
      }
      let alias_ = unnest.arg("alias")
      // Python: `alias.columns[0]` is an Identifier (keeping its quoting) that is reused
      // as-is below; the "date_value" fallback is a plain string.
      let column_ident = match alias_ {
        Some(a) if a.kind == TableAlias => a.list("columns").get(0)
        _ => None
      }
      // `maybe_parse(column_name)`: the identifier itself, or the parsed column
      let column_expr = () => match column_ident {
        Some(c) => c.copy()
        None => column_of("date_value")
      }
      let start = cast_(start, DType::DATE)
      let date_add = func_("date_add", [
        column_expr(),
        literal_number(step.name()),
        step.arg("unit").unwrap_or(var_("DAY")),
      ])
      let cast_date_add = cast_(date_add, DType::DATE)
      let cte_name = "_generated_dates" +
        (if count > 0 { "_\{count}" } else { "" })
      let base_query = select_([
        match column_ident {
          Some(c) => mk(Alias, [("this", start), ("alias", c.copy())])
          None => start.as_("date_value")
        },
      ])
      let recursive_query = select_([cast_date_add])
        .from_(table_of(cte_name))
        .where_([
          mk(LTE, [
            ("this", cast_date_add.copy()),
            ("expression", cast_(end, DType::DATE)),
          ]),
        ])
      let cte_query = base_query.union_(recursive_query, distinct=false)
      let generate_dates_query = select_([column_expr()]).from_(
        table_of(cte_name),
      )
      unnest.replace(
        Some(generate_dates_query.subquery(alias_=cte_name, copy=false)),
      )
      |> ignore
      let cte = alias_table(mk1(CTE, cte_query), cte_name)
      cte
      .arg("alias")
      .unwrap()
      .append("columns", match column_ident {
        Some(c) => c.copy()
        None => to_identifier("date_value")
      })
      recursive_ctes.push(cte)
      count += 1
    }
    if !recursive_ctes.is_empty() {
      let with_expression = match expression.arg("with_") {
        Some(w) => w
        None => mk0(With)
      }
      with_expression.set("recursive", true)
      with_expression.set(
        "expressions",
        recursive_ctes + with_expression.expressions(),
      )
      expression.set("with_", with_expression)
    }
  }
  expression
}

///|
/// Unnests GENERATE_SERIES or SEQUENCE table references.
#warnings("-unused_error_type")
pub fn unnest_generate_series(expression : Expr) -> Expr raise SqlglotError {
  match expression.this() {
    Some(this) if expression.kind == Table && this.kind.is_a(GenerateSeries) => {
      let unnest = mk(Unnest, [("expressions", [this])])
      let alias_ = expression.alias_()
      if !alias_.is_empty() {
        return alias_table(unnest, "_u", columns=[alias_], copy=false)
      }
      unnest
    }
    _ => expression
  }
}

///|
/// Convert SELECT DISTINCT ON statements to a subquery with a window function.
pub fn eliminate_distinct_on(expression : Expr) -> Expr raise SqlglotError {
  let on_tuple = match expression.arg("distinct") {
    Some(d) =>
      match d.arg("on") {
        Some(on) if on.kind == Tuple => true
        _ => false
      }
    None => false
  }
  if expression.kind == Select && on_tuple {
    let named = expression.named_selects()
    let row_number_window_alias = find_new_name(
      n => named.contains(n),
      "_row_number",
    )
    let distinct_cols = expression
      .arg("distinct")
      .unwrap()
      .pop()
      .arg("on")
      .unwrap()
      .expressions()
    let window = mk(Window, [
      ("this", mk0(RowNumber)),
      ("partition_by", distinct_cols),
    ])
    match expression.arg("order") {
      Some(order) => window.set("order", order.pop())
      None =>
        window.set(
          "order",
          mk(Order, [("expressions", distinct_cols.map(c => c.copy()))]),
        )
    }
    expression.select_([alias_(window, row_number_window_alias)], copy=false)
    |> ignore
    let mut new_selects = []
    let taken_names = [row_number_window_alias]
    let selects = expression.selects()
    for i in 0..<(selects.length() - 1) {
      let mut select = selects[i]
      if select.is_star() {
        new_selects = [mk0(Star)]
        break
      }
      if !select.kind.is_a(Alias) {
        let base = if select.output_name().is_empty() {
          "_col"
        } else {
          select.output_name()
        }
        let new_alias = find_new_name(n => taken_names.contains(n), base)
        let quoted : Bool? = if select.kind.is_a(Column) {
          match select.this() {
            Some(t) =>
              match t.args.get("quoted") {
                Some(Bool(b)) => Some(b)
                _ => None
              }
            None => None
          }
        } else {
          None
        }
        select = select.replace(Some(alias_(select, new_alias, quoted?))).unwrap()
      }
      taken_names.push(select.output_name())
      new_selects.push(select.arg("alias").unwrap())
    }
    return select_(new_selects, copy=false)
      .from_(expression.subquery(alias_="_t", copy=false), copy=false)
      .where_(
        [column_of(row_number_window_alias).eq_(literal_int(1))],
        copy=false,
      )
  }
  expression
}

///|
/// Convert SELECT statements that contain the QUALIFY clause into subqueries.
pub fn eliminate_qualify(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Select && expression.has("qualify") {
    let taken = expression.named_selects()
    for select in expression.selects() {
      if select.alias_or_name().is_empty() {
        let new_alias = find_new_name(n => taken.contains(n), "_c")
        select.replace(Some(alias_(select, new_alias))) |> ignore
        taken.push(new_alias)
      }
    }
    fn select_alias_or_name(select : Expr) -> Expr raise SqlglotError {
      let alias_or_name = select.alias_or_name()
      let identifier = match select.arg("alias") {
        Some(a) => Some(a)
        None => select.this()
      }
      match identifier {
        Some(i) if i.kind == Identifier => {
          let quoted = match i.args.get("quoted") {
            Some(Bool(b)) => Some(b)
            _ => None
          }
          match quoted {
            Some(q) => column_of(alias_or_name, quoted=q)
            None => column_of(alias_or_name)
          }
        }
        _ => column_of_parsed(alias_or_name)
      }
    }

    let outer_selects = select_(expression.selects().map(select_alias_or_name))
    let mut qualify_filters = expression
      .arg("qualify")
      .unwrap()
      .pop()
      .this()
      .unwrap()
    let expression_by_alias : Map[String, Expr] = Map([])
    for select in expression.selects() {
      if select.kind.is_a(Alias) {
        expression_by_alias[select.alias_()] = select.this().unwrap()
      }
    }
    let select_candidates = if expression.is_star() {
      [Window]
    } else {
      [Window, Column]
    }
    for
      select_candidate in qualify_filters.find_all(select_candidates).collect() {
      if select_candidate.kind.is_a(Window) {
        if !expression_by_alias.is_empty() {
          for column in select_candidate.find_all([Column]).collect() {
            match expression_by_alias.get(column.name()) {
              Some(expr) => column.replace(Some(expr)) |> ignore
              None => ()
            }
          }
        }
        let named = expression.named_selects()
        let new_alias = find_new_name(n => named.contains(n), "_w")
        expression.select_([alias_(select_candidate, new_alias)], copy=false)
        |> ignore
        let column = column_of(new_alias)
        match select_candidate.parent {
          Some(p) if p.kind == Qualify => qualify_filters = column
          _ => select_candidate.replace(Some(column)) |> ignore
        }
      } else if !expression.named_selects().contains(select_candidate.name()) &&
        select_candidate.find_ancestor([Window]) is None {
        expression.select_([select_candidate.copy()], copy=false) |> ignore
      }
    }
    return outer_selects
      .from_(expression.subquery(alias_="_t", copy=false), copy=false)
      .where_([qualify_filters], copy=false)
  }
  expression
}

///|
/// Python passes the plain name string to `exp.select`, which parses it (so that
/// e.g. `*` becomes a Star rather than a quoted column).
fn column_of_parsed(name : String) -> Expr raise SqlglotError {
  maybe_parse_str(name)
}

///|
/// Removes the precision of parameterized types in expressions.
#warnings("-unused_error_type")
pub fn remove_precision_parameterized_types(
  expression : Expr,
) -> Expr raise SqlglotError {
  for node in expression.find_all([DataType]).collect() {
    node.set(
      "expressions",
      node.expressions().filter(e => e.kind != DataTypeParam),
    )
  }
  expression
}

///|
/// Remove references to unnest table aliases, added by the optimizer's qualify_columns step.
#warnings("-unused_error_type")
pub fn unqualify_unnest(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Select {
    let unnest_aliases = []
    for unnest in find_all_in_scope(expression, [Unnest]) {
      match unnest.parent {
        Some(p) if p.kind.is_any([From, Join]) =>
          unnest_aliases.push(unnest.alias_())
        _ => ()
      }
    }
    if !unnest_aliases.is_empty() {
      for column in expression.find_all([Column]).collect() {
        let parts = column.parts()
        if parts.is_empty() {
          continue
        }
        let leftmost_part = parts[0]
        if leftmost_part.arg_key != Some("this") &&
          unnest_aliases.contains(leftmost_part.text("this")) {
          leftmost_part.pop() |> ignore
        }
      }
    }
  }
  expression
}

///|
/// Convert cross join unnest into lateral view explode.
pub fn unnest_to_explode(unnest_using_arrays_zip? : Bool = true) -> Transform {
  fn(expression : Expr) raise SqlglotError {
    fn unnest_zip_exprs(
      u : Expr,
      unnest_exprs : Array[Expr],
      has_multi_expr : Bool,
    ) -> Array[Expr] raise SqlglotError {
      if has_multi_expr {
        if !unnest_using_arrays_zip {
          raise UnsupportedError(
            "Cannot transpile UNNEST with multiple input arrays",
          )
        }
        let zip_exprs = [
          mk(Anonymous, [("this", "ARRAYS_ZIP"), ("expressions", unnest_exprs)]),
        ]
        u.set("expressions", zip_exprs)
        return zip_exprs
      }
      unnest_exprs
    }

    fn udtf_type(u : Expr, has_multi_expr : Bool) -> Kind {
      if u.has("offset") {
        Posexplode
      } else if has_multi_expr {
        Inline
      } else {
        Explode
      }
    }

    if expression.kind == Select {
      match expression.arg("from_") {
        Some(from_) =>
          match from_.this() {
            Some(unnest) if unnest.kind == Unnest => {
              let alias_ = unnest.arg("alias")
              let exprs = unnest.expressions()
              let has_multi_expr = exprs.length() > 1
              let this = unnest_zip_exprs(unnest, exprs, has_multi_expr)[0]
              let columns = match alias_ {
                Some(a) => a.list("columns")
                None => []
              }
              match unnest.get("offset") {
                Some(Node(o)) if o.kind == Identifier => columns.insert(0, o)
                Some(v) if v.truthy() => columns.insert(0, to_identifier("pos"))
                _ => ()
              }
              let table_alias = match alias_ {
                Some(a) =>
                  Some(
                    mk(TableAlias, [("this", a.this()), ("columns", columns)]),
                  )
                None => None
              }
              unnest.replace(
                Some(
                  mk(Table, [
                    ("this", mk1(udtf_type(unnest, has_multi_expr), this)),
                    ("alias", table_alias),
                  ]),
                ),
              )
              |> ignore
            }
            _ => ()
          }
        None => ()
      }
      let joins = expression.list("joins")
      for join in joins {
        let join_expr = match join.this() {
          Some(j) => j
          None => continue
        }
        let is_lateral = join_expr.kind == Lateral
        let unnest = if is_lateral {
          match join_expr.this() {
            Some(u) => u
            None => continue
          }
        } else {
          join_expr
        }
        if unnest.kind == Unnest {
          let alias_ = if is_lateral {
            join_expr.arg("alias")
          } else {
            unnest.arg("alias")
          }
          let alias_ = match alias_ {
            Some(a) => a
            None =>
              raise UnsupportedError(
                "CROSS JOIN UNNEST to LATERAL VIEW EXPLODE transformation requires an alias",
              )
          }
          let exprs = unnest.expressions()
          let has_multi_expr = exprs.length() > 1
          let exprs = unnest_zip_exprs(unnest, exprs, has_multi_expr)
          join.pop() |> ignore
          let alias_cols = alias_.list("columns")
          if !has_multi_expr &&
            alias_cols.length() != 1 &&
            alias_cols.length() != 2 {
            raise UnsupportedError(
              "CROSS JOIN UNNEST to LATERAL VIEW EXPLODE transformation requires explicit column aliases",
            )
          }
          match unnest.get("offset") {
            Some(Node(o)) if o.kind == Identifier => alias_cols.insert(0, o)
            Some(v) if v.truthy() => alias_cols.insert(0, to_identifier("pos"))
            _ => ()
          }
          let n = min_int(exprs.length(), alias_cols.length())
          for i in 0..<n {
            expression.append(
              "laterals",
              mk(Lateral, [
                ("this", mk1(udtf_type(unnest, has_multi_expr), exprs[i])),
                ("view", true),
                (
                  "alias",
                  mk(TableAlias, [
                    ("this", alias_.this()),
                    ("columns", alias_cols),
                  ]),
                ),
              ]),
            )
          }
        }
      }
    }
    expression
  }
}

///|
/// Transforms percentiles by adding a WITHIN GROUP clause to them.
#warnings("-unused_error_type")
pub fn add_within_group_for_percentiles(
  expression : Expr,
) -> Expr raise SqlglotError {
  if expression.kind.is_any([PercentileCont, PercentileDisc]) &&
    !(match expression.parent {
      Some(p) => p.kind == WithinGroup
      None => false
    }) &&
    expression.expression() is Some(_) {
    let column = expression.this().unwrap().pop()
    expression.set("this", expression.expression().unwrap().pop())
    let order = mk(Order, [("expressions", [mk1(Ordered, column)])])
    return mk(WithinGroup, [("this", expression), ("expression", order)])
  }
  expression
}

///|
/// Transforms percentiles by getting rid of their corresponding WITHIN GROUP clause.
#warnings("-unused_error_type")
pub fn remove_within_group_for_percentiles(
  expression : Expr,
) -> Expr raise SqlglotError {
  if expression.kind == WithinGroup {
    match (expression.this(), expression.expression()) {
      (Some(t), Some(e)) if t.kind.is_any([PercentileCont, PercentileDisc]) &&
        e.kind.is_a(Order) => {
        let quantile = t.this()
        let input_value = expression.find([Ordered]).unwrap().this()
        return expression
          .replace(
            Some(
              mk(ApproxQuantile, [("this", input_value), ("quantile", quantile)]),
            ),
          )
          .unwrap()
      }
      _ => ()
    }
  }
  expression
}

///|
/// Uses projection output names in recursive CTE definitions to define the CTEs' columns.
#warnings("-unused_error_type")
pub fn add_recursive_cte_column_names(
  expression : Expr,
) -> Expr raise SqlglotError {
  if expression.kind == With && expression.has("recursive") {
    let next_name = name_sequence("_c_")
    for cte in expression.expressions() {
      let alias_ = cte.arg("alias").unwrap()
      if alias_.list("columns").is_empty() {
        let mut query = cte.this().unwrap()
        if query.kind.is_a(SetOperation) {
          query = query.this().unwrap()
        }
        alias_.set(
          "columns",
          query
          .selects()
          .map(s => {
            to_identifier(
              if s.alias_or_name().is_empty() {
                next_name()
              } else {
                s.alias_or_name()
              },
            )
          }),
        )
      }
    }
  }
  expression
}

///|
/// Replace 'epoch' in casts by the equivalent date literal.
#warnings("-unused_error_type")
pub fn epoch_cast_to_ts(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind.is_any([Cast, TryCast]) &&
    py_lower(expression.name()) == "epoch" {
    match expression.arg("to") {
      Some(to) =>
        match to.args.get("this") {
          Some(DT(d)) if dtype_temporal_types.contains(d) =>
            match expression.this() {
              Some(t) =>
                t.replace(Some(literal_string("1970-01-01 00:00:00"))) |> ignore
              None => ()
            }
          _ => ()
        }
      None => ()
    }
  }
  expression
}

///|
/// Convert SEMI and ANTI joins into equivalent forms that use EXIST instead.
pub fn eliminate_semi_and_anti_joins(
  expression : Expr,
) -> Expr raise SqlglotError {
  if expression.kind == Select {
    for join in expression.list("joins") {
      let kind = py_upper(join.text("kind"))
      match join.arg("on") {
        Some(on) if kind == "SEMI" || kind == "ANTI" => {
          let subquery = select_([literal_int(1)])
            .from_(join.this().unwrap())
            .where_([on])
          let mut exists = mk1(Exists, subquery)
          if kind == "ANTI" {
            exists = not_(exists, copy=false)
          }
          join.pop() |> ignore
          expression.where_([exists], copy=false) |> ignore
        }
        _ => ()
      }
    }
  }
  expression
}

///|
/// Converts a query with a FULL OUTER join to a union of identical queries that use LEFT/RIGHT
/// OUTER joins instead.
pub fn eliminate_full_outer_join(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Select {
    let full_outer_joins = []
    for index, join in expression.list("joins") {
      if py_upper(join.text("side")) == "FULL" {
        full_outer_joins.push((index, join))
      }
    }
    if full_outer_joins.length() == 1 {
      let mut expression_copy = expression.copy()
      let (index, full_outer_join) = full_outer_joins[0]
      let from_ = expression.arg("from_").unwrap()
      let tables = (from_.alias_or_name(), full_outer_join.alias_or_name())
      let join_conditions = match full_outer_join.arg("on") {
        Some(on) => on
        None =>
          and_(
            full_outer_join
            .list("using")
            .map(col => {
              column_of(col.name(), table=tables.0).eq_(
                column_of(col.name(), table=tables.1),
              )
            }),
          )
      }
      full_outer_join.set("side", "left")
      let anti_join_clause = select_([literal_int(1)])
        .from_(from_.copy())
        .where_([join_conditions])
      expression_copy.list("joins")[index].set("side", "right")
      expression_copy = expression_copy.where_([
        not_(mk1(Exists, anti_join_clause)),
      ])
      let union = set_operation(
        Union,
        expression,
        expression_copy,
        distinct=false,
      )
      for arg in ["with_", "order", "limit", "offset"] {
        match expression.arg(arg) {
          Some(value) => {
            expression.set(arg, null_arg)
            expression_copy.set(arg, null_arg)
            union.set(arg, value)
          }
          None => ()
        }
      }
      return union
    }
  }
  expression
}

///|
#warnings("-unused_error_type")
pub fn unqualify_columns(expression : Expr) -> Expr raise SqlglotError {
  for column in expression.find_all([Column]).collect() {
    let parts = column.parts()
    for i in 0..<(parts.length() - 1) {
      parts[i].pop() |> ignore
    }
  }
  expression
}

///|
pub fn unqualify_pivot_fields(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Pivot {
    let fields = []
    for f in expression.list("fields") {
      fields.push(unqualify_columns(f))
    }
    expression.set("fields", fields)
  }
  expression
}

///|
#warnings("-unused_error_type")
pub fn remove_unique_constraints(expression : Expr) -> Expr raise SqlglotError {
  for constraint in expression.find_all([UniqueColumnConstraint]).collect() {
    match constraint.parent {
      Some(p) if p.kind.is_any([ColumnConstraint, Constraint]) =>
        p.pop() |> ignore
      _ => constraint.pop() |> ignore
    }
  }
  expression
}

///|
pub fn ctas_with_tmp_tables_to_create_tmp_view(
  tmp_storage_provider? : (Expr) -> Expr raise SqlglotError = e => e,
) -> Transform {
  fn(expression : Expr) raise SqlglotError {
    let temporary = match expression.arg("properties") {
      Some(p) =>
        p.expressions().iter().any(prop => prop.kind == TemporaryProperty)
      None => false
    }
    if py_upper(expression.text("kind")) == "TABLE" && temporary {
      match expression.expression() {
        Some(e) =>
          return mk(Create, [
            ("kind", "TEMPORARY VIEW"),
            ("this", expression.this()),
            ("expression", e),
          ])
        None => return tmp_storage_provider(expression)
      }
    }
    expression
  }
}

///|
#warnings("-unused_error_type")
pub fn move_schema_columns_to_partitioned_by(
  expression : Expr,
) -> Expr raise SqlglotError {
  let kind = py_upper(expression.text("kind"))
  let is_partitionable = kind == "TABLE" || kind == "VIEW"
  match expression.this() {
    Some(schema) if schema.kind == Schema && is_partitionable =>
      match expression.find([PartitionedByProperty]) {
        Some(prop) =>
          match prop.this() {
            Some(pt) if pt.kind != Schema => {
              let columns = pt.expressions().map(v => py_upper(v.name()))
              let schema_exprs = schema.expressions()
              let partitions = schema_exprs.filter(col => {
                columns.contains(py_upper(col.name()))
              })
              schema.set(
                "expressions",
                schema_exprs.filter(e => {
                  !partitions.iter().any(p => physical_equal(p, e) || p == e)
                }),
              )
              prop.replace(
                Some(
                  mk1(
                    PartitionedByProperty,
                    mk(Schema, [("expressions", partitions)]),
                  ),
                ),
              )
              |> ignore
              expression.set("this", schema)
            }
            _ => ()
          }
        None => ()
      }
    _ => ()
  }
  expression
}

///|
#warnings("-unused_error_type")
pub fn move_partitioned_by_to_schema_columns(
  expression : Expr,
) -> Expr raise SqlglotError {
  match expression.find([PartitionedByProperty]) {
    Some(prop) =>
      match prop.this() {
        Some(pt) if pt.kind == Schema &&
          pt.expressions().iter().all(e => e.kind == ColumnDef && e.has("kind")) => {
          let prop_this = mk(Tuple, [
            ("expressions", pt.expressions().map(e => e.this().unwrap().copy())),
          ])
          let schema = expression.this().unwrap()
          for e in pt.expressions() {
            schema.append("expressions", e)
          }
          prop.set("this", prop_this)
        }
        _ => ()
      }
    None => ()
  }
  expression
}

///|
/// Converts struct arguments to aliases, e.g. STRUCT(1 AS y).
#warnings("-unused_error_type")
pub fn struct_kv_to_alias(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Struct {
    expression.set(
      "expressions",
      expression
      .expressions()
      .map(e => {
        if e.kind == PropertyEQ {
          alias_expr(e.expression().unwrap(), e.this())
        } else {
          e
        }
      }),
    )
  }
  expression
}

///|
/// Transform ANY operator to Spark's EXISTS.
#warnings("-unused_error_type")
pub fn any_to_exists(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Select {
    for any_expr in expression.find_all([Any]).collect() {
      let this = any_expr.this().unwrap()
      let parent_like = match any_expr.parent {
        Some(p) => p.kind.is_any([Like, ILike])
        None => false
      }
      if this.kind.is_a(Query) || parent_like {
        continue
      }
      match any_expr.parent {
        Some(binop) if binop.kind.is_a(Binary) => {
          let lambda_arg = to_identifier("x")
          any_expr.replace(Some(lambda_arg)) |> ignore
          let lambda_expr = mk(Lambda, [
            ("this", binop.copy()),
            ("expressions", [lambda_arg]),
          ])
          binop.replace(
            Some(
              mk(Exists, [("this", this.unnest()), ("expression", lambda_expr)]),
            ),
          )
          |> ignore
        }
        _ => ()
      }
    }
  }
  expression
}

///|
/// Eliminates the `WINDOW` query clause by inlining each named window.
#warnings("-unused_error_type")
pub fn eliminate_window_clause(expression : Expr) -> Expr raise SqlglotError {
  match expression.get("windows") {
    Some(List(_)) if expression.kind == Select => {
      let windows = expression.list("windows")
      expression.set("windows", null_arg)
      let window_expression : Map[String, Expr] = Map([])
      fn inline_inherited_window(window : Expr) -> Unit {
        match window_expression.get(py_lower(window.alias_())) {
          Some(inherited_window) => {
            window.set("alias", null_arg)
            for key in ["partition_by", "order", "spec"] {
              match inherited_window.get(key) {
                Some(Node(arg)) => window.set(key, arg.copy())
                Some(List(l)) =>
                  window.set(
                    key,
                    l.map(x => {
                      match x {
                        Node(n) => Node(n.copy())
                        other => other
                      }
                    }),
                  )
                _ => ()
              }
            }
          }
          None => ()
        }
      }

      for window in windows {
        inline_inherited_window(window)
        window_expression[py_lower(window.name())] = window
      }
      for window in find_all_in_scope(expression, [Window]) {
        inline_inherited_window(window)
      }
    }
    _ => ()
  }
  expression
}

///|
/// Inherit field names from the first struct in an array.
#warnings("-unused_error_type")
pub fn inherit_struct_field_names(expression : Expr) -> Expr raise SqlglotError {
  if expression.kind == Array && expression.has("struct_name_inheritance") {
    let exprs = expression.expressions()
    match exprs.get(0) {
      Some(first_item) if first_item.kind == Struct &&
        first_item.expressions().iter().all(f => f.kind == PropertyEQ) => {
        let field_names = first_item.expressions().map(f => f.this().unwrap())
        for i in 1..<exprs.length() {
          let struct_ = exprs[i]
          if struct_.kind != Struct ||
            struct_.expressions().length() != field_names.length() {
            continue
          }
          let new_expressions = []
          for j, expr in struct_.expressions() {
            if expr.kind != PropertyEQ {
              let property_eq = mk(PropertyEQ, [
                ("this", field_names[j].copy()),
                ("expression", expr),
              ])
              property_eq.set_type(expr.get_type())
              new_expressions.push(property_eq)
            } else {
              new_expressions.push(expr)
            }
          }
          struct_.set("expressions", new_expressions)
        }
      }
      _ => ()
    }
  }
  expression
}
