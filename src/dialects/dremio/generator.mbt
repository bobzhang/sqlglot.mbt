// Port of sqlglot/generators/dremio.py

///|
fn date_delta_sql(name : String) -> @core.GenFn {
  (g, e) => {
    let unit = @core.py_upper(e.text("unit"))
    // Fallback to default behavior if unit is missing or 'DAY'
    if unit == "" || unit == "DAY" {
      return g.func(name, [e.this(), e.expression()])
    }
    let this_sql = g.sql_key(e, "this")
    let expr_sql = g.sql_key(e, "expression")
    let interval_sql = "CAST(\{expr_sql} AS INTERVAL \{unit})"
    "\{name}(\{this_sql}, \{interval_sql})"
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
  let t = d.gen_fns.transforms
  t[BitwiseAndAgg] = @core.rename_func("BIT_AND")
  t[BitwiseOrAgg] = @core.rename_func("BIT_OR")
  t[ToChar] = @core.rename_func("TO_CHAR")
  t[TimeToStr] = (g, e) => g.func("TO_CHAR", [e.this(), g.format_time(e)])
  t[TryCast] = @core.no_trycast_sql
  t[DateAdd] = date_delta_sql("DATE_ADD")
  t[DateSub] = date_delta_sql("DATE_SUB")
  t[GenerateSeries] = @core.rename_func("ARRAY_GENERATE_RANGE")
  t[RegexpSplit] = (g, e) => {
    g.func("REGEXP_SPLIT", [
      e.this(),
      e.expression(),
      e.arg("mode"),
      e.arg("limit"),
    ])
  }
  let m = d.gen_fns.methods
  let parent_version = m.get(Version)
  m[Version] = (g, e) => {
    if e.text("kind") == "AS OF" {
      let this = if e.name() == "VERSION" { "SNAPSHOT" } else { e.name() }
      return "AT \{this} \{g.sql_key(e, "expression")}"
    }
    g.unsupported("Range time travel is not supported in Dremio")
    match parent_version {
      Some(f) => f(g, e)
      None => g.version_sql(e)
    }
  }
  let parent_datatype = m.get(DataType)
  m[DataType] = (g, e) => {
    // Reject time-zone-aware TIMESTAMPs, which Dremio does not accept
    if e.is_type([TIMESTAMPTZ, TIMESTAMPLTZ]) {
      g.unsupported("Dremio does not support time-zone-aware TIMESTAMP")
    }
    match parent_datatype {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
  let hooks = d.gen_fns.hooks
  let parent_cast = hooks.cast_sql
  hooks.cast_sql = Some((g, e, safe_prefix) => {
    // Match: CAST(CURRENT_TIMESTAMP AT TIME ZONE 'UTC' AS DATE)
    if e.is_type([DATE]) {
      match e.this() {
        Some(atz) if atz.kind == AtTimeZone &&
          atz.this() is Some(ct) &&
          ct.kind == CurrentTimestamp &&
          atz.arg("zone") is Some(zone) &&
          zone.kind == Literal &&
          @core.py_upper(atz.text("zone")) == "UTC" => return "CURRENT_DATE_UTC"
        _ => ()
      }
    }
    match parent_cast {
      Some(f) => f(g, e, safe_prefix)
      None => g.cast_sql(e, safe_prefix?)
    }
  })
}
