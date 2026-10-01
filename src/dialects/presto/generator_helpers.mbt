// Module-level helper functions of sqlglot/generators/presto.py

///|
fn sha2_digest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let length = e.text("length")
  let length = if length == "" { "256" } else { length }
  if length != "256" && length != "512" {
    g.unsupported("SHA\{length} is not supported in Presto")
  }
  let mut this = e.this_()
  if this.is_type(@core.dtype_text_types) {
    // the native digest takes VARBINARY, so a text-typed argument needs encoding
    this = @core.mk(Encode, [
      ("this", this),
      ("charset", @core.literal_string("utf-8")),
    ])
  }
  g.func("SHA\{length}", [this])
}

///|
fn initcap_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.expression() {
    Some(delimiters) if !(delimiters.is_string() &&
      delimiters.text("this") == g.dialect.cfg.initcap_default_delimiter_chars) =>
      g.unsupported("INITCAP does not support custom delimiters")
    _ => ()
  }
  let regex = "(\\w)(\\w*)"
  "REGEXP_REPLACE(\{g.sql_key(e, "this")}, '\{regex}', x -> UPPER(x[1]) || LOWER(x[2]))"
}

///|
fn no_sort_array(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let comparator : String? = match e.arg("asc") {
    Some(asc) if asc.kind == Boolean && !asc.bool_arg("this") =>
      Some("(a, b) -> CASE WHEN a < b THEN 1 WHEN a > b THEN -1 ELSE 0 END")
    _ => None
  }
  g.func("ARRAY_SORT", [e.this(), comparator])
}

///|
fn schema_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.parent {
    Some(parent) if parent.kind == PartitionedByProperty => {
      // Any columns in the ARRAY[] string literals should not be quoted
      for ident in e.find_all([Identifier]).collect() {
        match (ident.parent, ident.arg_key) {
          (Some(p), Some(k)) =>
            match ident.index {
              Some(i) => p.set_at(k, ident.name(), i)
              None => p.set(k, ident.name())
            }
          _ => ()
        }
      }
      let partition_exprs = e
        .raw_list("expressions")
        .map(v => {
          match v {
            Node(c) if c.kind.is_a(Func) || c.kind.is_a(Property) =>
              g.sql(Some(c))
            Node(c) => g.sql_key(c, "this")
            v => g.sql_value(v)
          }
        })
      return g.sql(
        Some(
          @core.mk(Array, [
            ("expressions", partition_exprs.map(c => @core.literal_string(c))),
          ]),
        ),
      )
    }
    Some(parent) =>
      for schema in parent.find_all([Schema]).collect() {
        if physical_equal(schema, e) {
          continue
        }
        let column_defs = schema.find_all([ColumnDef]).collect()
        if schema.parent is Some(sp) && sp.kind.is_a(Property) {
          match e.args.get("expressions") {
            Some(List(l)) =>
              for cd in column_defs {
                l.push(Node(cd))
              }
            _ => ()
          }
        }
      }
    None => ()
  }
  g.schema_sql(e)
}

///|
fn quantile_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.unsupported("Presto does not support exact quantiles")
  g.func("APPROX_PERCENTILE", [e.this(), e.arg("quantile")])
}

///|
fn str_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.func("DATE_PARSE", [e.this(), g.format_time(e)])
}

///|
fn ts_or_ds_to_date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let time_format = g.format_time(e)
  match time_format {
    Some(tf) if tf != "" &&
      tf != g.dialect.cfg.time_format &&
      tf != g.dialect.cfg.date_format =>
      return g.sql(
        Some(@core.exp_cast(@core.mk1(Var, str_to_time_sql(g, e)), DATE)),
      )
    _ => ()
  }
  g.sql(Some(@core.exp_cast(@core.exp_cast(e.this_(), TIMESTAMP), DATE)))
}

///|
fn ts_or_ds_add_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let e = @core.ts_or_ds_add_cast(e)
  let unit = @core.unit_to_str(e)
  g.func("DATE_ADD", [unit, e.expression(), e.this()])
}

///|
fn ts_or_ds_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = @core.exp_cast(e.this_(), TIMESTAMP)
  let expr = @core.exp_cast(e.expression_(), TIMESTAMP)
  let unit = @core.unit_to_str(e)
  g.func("DATE_DIFF", [unit, expr, this])
}

///|
/// Trino doesn't support FIRST / LAST as functions, but they're valid in the context
/// of MATCH_RECOGNIZE, so we need to preserve them in that case. In all other cases
/// they're converted into an ARBITRARY call.
fn first_last_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.find_ancestor([MatchRecognize, Select]) {
    Some(a) if a.kind.is_a(MatchRecognize) => g.function_fallback_sql(e)
    _ => @core.rename_func("ARBITRARY")(g, e)
  }
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let timestamp = g.sql_key(e, "this")
  match scale {
    None => return @core.rename_func("FROM_UNIXTIME")(g, e)
    Some(s) if s == @core.literal_number("0") =>
      return @core.rename_func("FROM_UNIXTIME")(g, e)
    _ => ()
  }
  "FROM_UNIXTIME(CAST(\{timestamp} AS DOUBLE) / POW(10, \{g.sql(scale)}))"
}

///|
fn to_int(
  g : @core.Generator,
  e : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if e.get_type() is None {
    @core.gen_annotate_types(e, g.dialect) |> ignore
  }
  // A missing type means the type is unknown (annotate_types types every node)
  match e.get_type() {
    Some(t) if t.is_type(@core.dtype_integer_types) => e
    _ => @core.exp_cast(e, BIGINT)
  }
}

///|
fn date_delta_sql(
  name : String,
  negate_interval? : Bool = false,
) -> @core.GenFn {
  (g, e) => {
    let interval = to_int(g, e.expression_())
    let interval = if negate_interval {
      @core.mul_(interval.copy(), @core.literal_number("-1"))
    } else {
      interval
    }
    g.func(name, [@core.unit_to_str(e), interval, e.this()])
  }
}

///|
fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Presto/Trino only expose date_diff(unit, ts1, ts2); it returns ts2 - ts1, so the
  // operands are emitted as (expression, this) to preserve `this - expression` semantics.
  let mut this = e.this_()
  let mut expr = e.expression_()
  let mut unit = @core.unit_to_str(e)
  // DATE_DIFF counts complete units between its operands, whereas dialects that set
  // date_part_boundary count unit boundary crossings, so the operands are truncated
  // down to the unit to make the two coincide
  if unit is Some(_) && e.has("date_part_boundary") {
    let raw_unit = e.arg("unit")
    let dow = @core.week_unit_to_dow(raw_unit)
    if dow is Some(dow) {
      unit = Some(@core.literal_string("WEEK"))
      // DATE_TRUNC('WEEK', ...) is Monday-based; shifting both operands by the same
      // delta realigns it to the requested week start without changing the diff
      let shift_days = if dow == 7 { 1 } else { 1 - dow }
      if shift_days != 0 {
        let delta = @core.mk(Interval, [
          ("this", @core.literal_string(shift_days.to_string())),
          ("unit", @core.var_("DAY")),
        ])
        this = @core.mk(Add, [("this", this), ("expression", delta)])
        expr = @core.mk(Add, [("this", expr), ("expression", delta.copy())])
      }
    }
    let is_week_start = match raw_unit {
      Some(r) => r.kind.is_a(WeekStart)
      None => false
    }
    if !is_week_start || dow is Some(_) {
      this = @core.mk(DateTrunc, [
        ("unit", unit.unwrap().copy()),
        ("this", this),
      ])
      expr = @core.mk(DateTrunc, [
        ("unit", unit.unwrap().copy()),
        ("this", expr),
      ])
    }
  }
  g.func("DATE_DIFF", [unit, expr, this])
}

///|
fn explode_to_unnest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.this() {
    Some(explode) if explode.kind.is_a(Explode) => {
      let exploded_type = explode.this_().get_type()
      // This attempts a best-effort transpilation of LATERAL VIEW EXPLODE on a struct array
      match (e.arg("alias"), exploded_type) {
        (Some(alias), Some(et)) if alias.kind.is_a(TableAlias) &&
          et.kind.is_a(DataType) &&
          et.is_type([ARRAY]) &&
          !et.expressions().is_empty() &&
          et.expressions()[0].is_type([STRUCT]) =>
          // When unnesting a ROW in Presto, it produces N columns, so we need to fix the alias
          alias.set(
            "columns",
            et.expressions()[0].expressions().map(c => c.this_().copy()),
          )
        _ => ()
      }
    }
    Some(explode) if explode.kind.is_a(Inline) =>
      explode.replace(Some(@core.mk1(Explode, explode.this_().copy())))
      |> ignore
    _ => ()
  }
  @core.explode_to_unnest_sql(g, e)
}

///|
/// Amends LATERAL VIEW EXPLODE column references (only when types were inferred).
pub fn amend_exploded_column_table(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  // We check for expression.type because the columns can be amended only if types were inferred
  if expression.kind.is_a(Select) && expression.get_type() is Some(_) {
    for lateral in expression.list("laterals") {
      let alias = lateral.arg("alias")
      guard lateral.this() is Some(lt) && lt.kind.is_a(Explode) else {
        continue
      }
      guard alias is Some(alias) &&
        alias.kind.is_a(TableAlias) &&
        alias.list("columns").length() == 1 else {
        continue
      }
      let new_table = alias.this_()
      let old_table = @core.py_lower(alias.list("columns")[0].name())
      // When transpiling a LATERAL VIEW EXPLODE Spark query, the exploded fields may be qualified
      // with the struct column, resulting in invalid Presto references that need to be amended
      for column in @core.find_all_in_scope(expression, [Column]) {
        if @core.py_lower(column.db()) == old_table {
          column.set("table", column.arg("db").unwrap().pop())
        } else if @core.py_lower(column.table_name()) == old_table {
          column.set("table", new_table.copy())
        } else if @core.py_lower(column.name()) == old_table &&
          column.parent is Some(cp) &&
          cp.kind.is_a(Dot) {
          cp.replace(
            Some(
              @core.mk(Column, [
                ("this", cp.expression_()),
                ("table", new_table.copy()),
              ]),
            ),
          )
          |> ignore
        }
      }
    }
  }
  expression
}
