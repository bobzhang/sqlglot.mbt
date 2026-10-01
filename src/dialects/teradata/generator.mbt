// Port of sqlglot/generators/teradata.py

///|
fn date_add_sql(kind : String) -> @core.GenFn {
  (g, e) => {
    let this = g.sql_key(e, "this")
    let unit = e.arg("unit")
    let mut value = g.simplify_unless_literal(e.expression().unwrap())
    if !value.kind.is_a(Literal) {
      g.unsupported("Cannot add non literal")
    }
    let op = if value.kind == Neg {
      value = @core.literal_string(
        match value.this() {
          Some(t) => t.name()
          None => ""
        },
      )
      if kind == "+" {
        "-"
      } else {
        "+"
      }
    } else {
      value.set("is_string", true)
      kind
    }
    "\{this} \{op} \{g.sql(Some(@core.mk(Interval, [("this", value), ("unit", unit)])))}"
  }
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  // (the module-level table: only WINDOW and QUALIFY)
  d.gen_fns.after_having_modifier_transforms = d.gen_fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
  let cfg = d.gen_cfg
  cfg.type_mapping[GEOMETRY] = "ST_GEOMETRY"
  cfg.type_mapping[DOUBLE] = "DOUBLE PRECISION"
  cfg.type_mapping[TIMESTAMPTZ] = "TIMESTAMP"
  let t = d.gen_fns.transforms
  t[ArgMax] = @core.rename_func("MAX_BY")
  t[ArgMin] = @core.rename_func("MIN_BY")
  t[Max] = @core.max_or_greatest
  t[Min] = @core.min_or_least
  t[Pow] = (g, e) => g.binary(e, "**")
  t[Rand] = (g, e) => g.func("RANDOM", [e.arg("lower"), e.arg("upper")])
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.eliminate_semi_and_anti_joins,
  ])
  t[StrPosition] = (g, e) => {
    @core.strposition_sql(
      g,
      e,
      func_name="INSTR",
      supports_position=true,
      supports_occurrence=true,
    )
  }
  t[StrToDate] = (g, e) => {
    let fmt = match g.format_time(e) {
      Some(f) => f
      None => "None"
    }
    "CAST(\{g.sql_key(e, "this")} AS DATE FORMAT \{fmt})"
  }
  t[ToChar] = (g, e) => g.function_fallback_sql(e)
  t[ToNumber] = @core.to_number_with_nls_param
  t[Use] = (g, e) => "DATABASE \{g.sql_key(e, "this")}"
  t[DateAdd] = date_add_sql("+")
  t[DateSub] = date_add_sql("-")
  t[Quarter] = (g, e) => {
    g.sql(
      Some(@core.mk(Extract, [("this", "QUARTER"), ("expression", e.this())])),
    )
  }
  let m = d.gen_fns.methods
  let h = d.gen_fns.hooks
  m[CurrentTimestamp] = (g, e) => {
    let (prefix, suffix) = if e.this() is Some(_) {
      ("(", ")")
    } else {
      ("", "")
    }
    g.func("CURRENT_TIMESTAMP", [e.this()], prefix~, suffix~)
  }
  h.cast_sql = Some((g, e, safe_prefix) => {
    match e.arg("to") {
      Some(to) if to.datatype_this() == Some(UNKNOWN) && e.has("format") =>
        // We don't actually want to print the unknown type in CAST(<value> AS FORMAT <format>)
        to.pop() |> ignore
      _ => ()
    }
    g.cast_sql(e, safe_prefix?)
  })
  m[TryCast] = (g, e) => g.cast_sql_v(e, safe_prefix="TRY")
  h.tablesample_sql = Some((g, e, _) => {
    "\{g.sql_key(e, "this")} SAMPLE \{g.expressions(expression=e)}"
  })
  m[PartitionedByProperty] = (g, e) => "PARTITION BY \{g.sql_key(e, "this")}"
  // FROM before SET in Teradata UPDATE syntax
  m[Update] = (g, e) => {
    let this = g.sql_key(e, "this")
    let from_sql = g.sql_key(e, "from_")
    let set_sql = g.expressions(expression=e, flat=true)
    let where_sql = g.sql_key(e, "where")
    let sql = "UPDATE \{this}\{from_sql} SET \{set_sql}\{where_sql}"
    g.prepend_ctes(e, sql)
  }
  m[RangeN] = (g, e) => {
    let this = g.sql_key(e, "this")
    let expressions_sql = g.expressions(expression=e)
    let each_sql = g.sql_key(e, "each")
    let each_sql = if each_sql != "" { " EACH \{each_sql}" } else { "" }
    "RANGE_N(\{this} BETWEEN \{expressions_sql}\{each_sql})"
  }
  m[LockingStatement] = (g, e) => {
    let locking_clause = g.sql_key(e, "this")
    let query_sql = g.sql_key(e, "expression")
    "\{locking_clause} \{query_sql}"
  }
  let parent_createable_sql = h.createable_sql
  h.createable_sql = Some((g, e, locations) => {
    let kind = @core.py_upper(g.sql_key(e, "kind"))
    match locations.get(PostName) {
      Some(post_name) if kind == "TABLE" && !post_name.is_empty() => {
        let schema = e.this().unwrap()
        let this_name = g.sql_key(schema, "this")
        let this_properties = g.properties(
          @core.mk(Properties, [("expressions", post_name)]),
          wrapped=false,
          prefix=",",
        )
        let this_schema = g.schema_columns_sql(schema)
        "\{this_name}\{this_properties}\{g.sep()}\{this_schema}"
      }
      _ =>
        match parent_createable_sql {
          Some(f) => f(g, e, locations)
          None => g.createable_sql_base(e, locations)
        }
    }
  })
  m[Extract] = (g, e) => {
    let this = g.sql_key(e, "this")
    if @core.py_upper(this) != "QUARTER" {
      return g.extract_sql(e)
    }
    let to_char = @core.func_("to_char", [
      e.expression().unwrap(),
      @core.literal_string("Q"),
    ])
    g.sql(Some(@core.exp_cast(to_char, INT)))
  }
  m[Interval] = (g, e) => {
    let unit = e.text("unit")
    let multiplier = if unit.has_prefix("WEEK") {
      7
    } else if unit.has_prefix("QUARTER") {
      90
    } else {
      0
    }
    if multiplier != 0 {
      let interval = @core.mk(Interval, [
        ("this", e.this()),
        ("unit", @core.var_("DAY")),
      ])
      return "(\{multiplier} * \{g.interval_sql(interval)})"
    }
    g.interval_sql(e)
  }
}
