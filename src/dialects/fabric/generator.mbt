// Port of sqlglot/generators/fabric.py

///|
/// Cap the precision of to a maximum of `max_precision` digits.
/// If no precision is specified, default to `max_precision`.
fn cap_data_type_precision(
  expression : @core.Expr,
  max_precision? : Int64 = 6L,
) -> @core.Expr {
  let precision_param = expression.find([DataTypeParam])
  let target_precision = match precision_param {
    Some(pp) if pp.this() is Some(t) && t.is_int() => {
      let current_precision = t.to_py_int().unwrap_or(max_precision)
      if current_precision < max_precision {
        current_precision
      } else {
        max_precision
      }
    }
    _ => max_precision
  }
  @core.mk(DataType, [
    ("this", expression.get("this")),
    (
      "expressions",
      [
        @core.mk1(
          DataTypeParam,
          @core.literal_number(target_precision.to_string()),
        ),
      ],
    ),
  ])
}

///|
/// Transform function to add VARCHAR(MAX) or CHAR(MAX) for cross-dialect conversion.
fn add_default_precision_to_varchar(expression : @core.Expr) -> @core.Expr {
  match expression.this() {
    Some(schema) if expression.kind == Create &&
      expression.text("kind") == "TABLE" &&
      schema.kind == Schema =>
      for column in schema.expressions() {
        if column.kind != ColumnDef {
          continue
        }
        match column.arg("kind") {
          Some(column_type) if column_type.kind.is_a(DataType) &&
            (
              column_type.datatype_this() == Some(VARCHAR) ||
              column_type.datatype_this() == Some(CHAR)
            ) &&
            column_type.expressions().is_empty() =>
            // For transpilation, VARCHAR/CHAR without precision becomes VARCHAR(MAX)/CHAR(MAX)
            column_type.set("expressions", [@core.var_("MAX")])
          _ => ()
        }
      }
    _ => ()
  }
  expression
}

///|
/// `str(expression)`: SQL in the default dialect.
fn default_sql(e : @core.Expr?) -> String raise @core.SqlglotError {
  match e {
    Some(x) => @core.Generator::new(@core.base_dialect()).generate(x)
    None => ""
  }
}

///|
fn param_precision(data_type : @core.Expr) -> Int64? {
  match data_type.find([DataTypeParam]) {
    Some(p) =>
      match p.this() {
        Some(t) if t.is_int() => t.to_py_int()
        _ => None
      }
    None => None
  }
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let cfg = d.gen_cfg
  cfg.type_mapping[DATETIME] = "DATETIME2"
  cfg.type_mapping[DECIMAL] = "DECIMAL"
  cfg.type_mapping[IMAGE] = "VARBINARY(MAX)"
  cfg.type_mapping[INT] = "INT"
  cfg.type_mapping[JSON] = "VARCHAR(MAX)"
  cfg.type_mapping[MONEY] = "DECIMAL(19, 4)"
  cfg.type_mapping[NCHAR] = "CHAR"
  cfg.type_mapping[NVARCHAR] = "VARCHAR"
  cfg.type_mapping[ROWVERSION] = "ROWVERSION"
  cfg.type_mapping[SMALLDATETIME] = "DATETIME2"
  cfg.type_mapping[SMALLMONEY] = "DECIMAL(10, 4)"
  cfg.type_mapping[TIMESTAMP] = "DATETIME2"
  cfg.type_mapping[TIMESTAMPNTZ] = "DATETIME2"
  cfg.type_mapping[TIMESTAMPTZ] = "DATETIME2"
  cfg.type_mapping[TINYINT] = "SMALLINT"
  cfg.type_mapping[UTINYINT] = "SMALLINT"
  cfg.type_mapping[UUID] = "UNIQUEIDENTIFIER"
  cfg.type_mapping[XML] = "VARCHAR(MAX)"
  d.gen_fns.transforms[Create] = @core.preprocess([
    e => add_default_precision_to_varchar(e),
  ])
  let m = d.gen_fns.methods
  let h = d.gen_fns.hooks
  let parent_datatype_sql = m.get(DataType)
  m[DataType] = (g, e) => {
    // Check if this is a temporal type that needs precision handling. Fabric limits temporal
    // types to max 6 digits precision. When no precision is specified, we default to 6 digits.
    let e = if e.is_type(@core.dtype_temporal_types) &&
      e.datatype_this() != Some(DATE) {
      // Create a new expression with the capped precision
      cap_data_type_precision(e)
    } else {
      e
    }
    match parent_datatype_sql {
      Some(f) => f(g, e)
      None => g.datatype_sql(e)
    }
  }
  let parent_cast_sql = h.cast_sql
  let super_cast = fn(
    g : @core.Generator,
    e : @core.Expr,
    safe_prefix : String?,
  ) -> String raise @core.SqlglotError {
    match parent_cast_sql {
      Some(f) => f(g, e, safe_prefix)
      None => g.cast_sql(e, safe_prefix?)
    }
  }
  h.cast_sql = Some((g, e, safe_prefix) => {
    // Cast to DATETIMEOFFSET if inside an AT TIME ZONE expression
    // https://learn.microsoft.com/en-us/sql/t-sql/data-types/datetimeoffset-transact-sql#microsoft-fabric-support
    if e.is_type([TIMESTAMPTZ]) {
      let at_time_zone = e.find_ancestor([AtTimeZone, Select])
      // Return normal cast, if the expression is not in an AT TIME ZONE context
      guard at_time_zone is Some(atz) && atz.kind == AtTimeZone else {
        return super_cast(g, e, safe_prefix)
      }
      // Get the precision from the original TIMESTAMPTZ cast and cap it to 6
      let capped_data_type = cap_data_type_precision(e.arg("to").unwrap())
      let precision_value = param_precision(capped_data_type).unwrap_or(6L)
      // Do the cast explicitly to bypass sqlglot's default handling
      return "CAST(\{default_sql(e.this())} AS DATETIMEOFFSET(\{precision_value}))"
    }
    super_cast(g, e, safe_prefix)
  })
  let parent_attimezone_sql = m.get(AtTimeZone)
  let super_attimezone = fn(
    g : @core.Generator,
    e : @core.Expr,
  ) -> String raise @core.SqlglotError {
    match parent_attimezone_sql {
      Some(f) => f(g, e)
      None => g.attimezone_sql(e)
    }
  }
  m[AtTimeZone] = (g, e) => {
    // Wrap the AT TIME ZONE expression in a cast to DATETIME2 if it contains a TIMESTAMPTZ
    // https://learn.microsoft.com/en-us/sql/t-sql/data-types/datetimeoffset-transact-sql#microsoft-fabric-support
    match @core.gen_find_all_in_scope(e, [Cast]).get(0) {
      Some(timestamptz_cast) if timestamptz_cast.arg("to") is Some(to) &&
        to.is_type([TIMESTAMPTZ]) => {
        // Get the precision from the original TIMESTAMPTZ cast and cap it to 6
        let capped_data_type = cap_data_type_precision(to)
        let precision = match capped_data_type.find([DataTypeParam]) {
          Some(pp) =>
            match pp.this() {
              Some(t) => t.to_py_int().unwrap_or(6L).to_string()
              None => "6"
            }
          None => "6"
        }
        // Generate the AT TIME ZONE expression (which will handle the inner cast conversion)
        let at_time_zone_sql = super_attimezone(g, e)
        // Wrap it in an outer cast to DATETIME2
        "CAST(\{at_time_zone_sql} AS DATETIME2(\{precision}))"
      }
      _ => super_attimezone(g, e)
    }
  }
  m[UnixToTime] = (g, e) => {
    let scale = e.arg("scale")
    let timestamp = e.this().unwrap()
    match scale {
      None => ()
      Some(s) if s == @core.literal_number("0") => ()
      Some(s) => {
        g.unsupported(
          "UnixToTime scale \{default_sql(Some(s))} is not supported by Fabric",
        )
        return ""
      }
    }
    // Convert unix timestamp (seconds) to microseconds and round to avoid decimals
    let microseconds = @core.exp_binop(
      Mul,
      timestamp,
      @core.literal_number("1e6"),
    )
    let rounded = @core.func_("round", [microseconds, @core.literal_number("0")])
    let rounded_ms_as_bigint = @core.exp_cast(rounded, BIGINT)
    // Create the base datetime as '1970-01-01' cast to DATETIME2(6)
    let epoch_start = @core.exp_cast_to(
      @core.literal_string("1970-01-01"),
      @core.mk(DataType, [
        ("this", @core.Value::DT(DATETIME2)),
        ("expressions", [@core.mk1(DataTypeParam, @core.literal_number("6"))]),
      ]),
    )
    let dateadd = @core.mk(DateAdd, [
      ("this", epoch_start),
      ("expression", rounded_ms_as_bigint),
      ("unit", @core.literal_string("MICROSECONDS")),
    ])
    g.sql(Some(dateadd))
  }
}
