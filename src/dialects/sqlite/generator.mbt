// Port of sqlglot/generators/sqlite.py

///|
fn remove_node(list : Array[@core.Value], node : @core.Expr) -> Unit {
  for i, v in list {
    if v is Node(e) && physical_equal(e, node) {
      list.remove(i) |> ignore
      return
    }
  }
}

///|
/// Move primary key to a column and place auto_increment after it.
fn transform_create(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == Create &&
    expression.this() is Some(schema) &&
    schema.kind == Schema else {
    return expression
  }
  let defs : Map[String, @core.Expr] = Map([])
  let mut primary_key : @core.Expr? = None
  for e in schema.expressions() {
    if e.kind == ColumnDef {
      defs[e.name()] = e
    } else if e.kind == PrimaryKey {
      primary_key = Some(e)
    }
  }
  if primary_key is Some(pk) && pk.expressions().length() == 1 {
    match defs.get(pk.expressions()[0].name()) {
      Some(column) =>
        column.append(
          "constraints",
          @core.mk(ColumnConstraint, [
            ("kind", @core.mk0(PrimaryKeyColumnConstraint)),
          ]),
        )
      None => ()
    }
    remove_node(schema.raw_list("expressions"), pk)
  }
  for _, column in defs {
    let mut primary_key_index = -1
    let mut auto_increment : @core.Expr? = None
    let mut auto_increment_index = -1
    for i, constraint in column.list("constraints") {
      match constraint.arg("kind") {
        Some(k) if k.kind == PrimaryKeyColumnConstraint => primary_key_index = i
        Some(k) if k.kind == AutoIncrementColumnConstraint => {
          auto_increment = Some(constraint)
          auto_increment_index = i
        }
        _ => ()
      }
    }
    if auto_increment is Some(ai) &&
      0 <= auto_increment_index &&
      auto_increment_index < primary_key_index {
      let constraints = column.raw_list("constraints")
      remove_node(constraints, ai)
      constraints.insert(primary_key_index, Node(ai))
    }
  }
  expression
}

///|
fn generated_to_auto_increment(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == ColumnDef else { return expression }
  // Only rewrite true identity columns. Expression-bearing forms are computed
  // columns (GENERATED ALWAYS AS (expr)) and must keep their expression.
  match expression.find([GeneratedAsIdentityColumnConstraint]) {
    Some(generated) if generated.expression() is None => {
      generated.parent.unwrap().pop() |> ignore
      match expression.find([NotNullColumnConstraint]) {
        Some(not_null) => not_null.parent.unwrap().pop() |> ignore
        None => ()
      }
      expression.append(
        "constraints",
        @core.mk(ColumnConstraint, [
          ("kind", @core.mk0(AutoIncrementColumnConstraint)),
        ]),
      )
    }
    _ => ()
  }
  expression
}

///|
fn offset_to_limit(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  if expression.kind == Select &&
    expression.has("offset") &&
    !expression.has("limit") {
    expression.limit_(@core.literal_number("-1"), copy=false) |> ignore
  }
  expression
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
  cfg.type_mapping.remove(BLOB)
  for t in [@core.DType::BOOLEAN, TINYINT, SMALLINT, INT, BIGINT] {
    cfg.type_mapping[t] = "INTEGER"
  }
  for t in [@core.DType::FLOAT, DOUBLE, DECIMAL] {
    cfg.type_mapping[t] = "REAL"
  }
  for t in [@core.DType::CHAR, NCHAR, VARCHAR, NVARCHAR] {
    cfg.type_mapping[t] = "TEXT"
  }
  for t in [@core.DType::BINARY, VARBINARY] {
    cfg.type_mapping[t] = "BLOB"
  }
  let t = d.gen_fns.transforms
  t[AnyValue] = @core.any_value_to_max_sql
  t[Chr] = @core.rename_func("CHAR")
  t[CountIf] = @core.count_if_to_sum
  t[Create] = @core.preprocess([transform_create])
  t[CurrentDate] = (_, _) => "CURRENT_DATE"
  t[CurrentTime] = (_, _) => "CURRENT_TIME"
  t[CurrentTimestamp] = (_, _) => "CURRENT_TIMESTAMP"
  t[CurrentVersion] = (_, _) => "SQLITE_VERSION()"
  t[ColumnDef] = @core.preprocess([generated_to_auto_increment])
  t[DateStrToDate] = (g, e) => g.sql_key(e, "this")
  t[If] = @core.rename_func("IIF")
  t[ILike] = @core.no_ilike_sql
  t[JSONArrayAgg] = (g, e) => {
    g.unsupported_args(e, ["order", "null_handling", "return_type", "strict"])
    @core.rename_func("JSON_GROUP_ARRAY")(g, e)
  }
  t[JSONObjectAgg] = (g, e) => g.jsonobject_sql(e, name="JSON_GROUP_OBJECT")
  t[Levenshtein] = (g, e) => {
    g.unsupported_args(e, ["ins_cost", "del_cost", "sub_cost", "max_dist"])
    @core.rename_func("EDITDIST3")(g, e)
  }
  t[LogicalOr] = @core.rename_func("MAX")
  t[LogicalAnd] = @core.rename_func("MIN")
  t[Pivot] = @core.no_pivot_sql
  t[Rand] = @core.rename_func("RANDOM")
  t[RegexpLike] = (g, e) => g.binary(e, "REGEXP")
  t[Select] = @core.preprocess([
    offset_to_limit, @core.eliminate_distinct_on, @core.eliminate_qualify, @core.eliminate_semi_and_anti_joins,
  ])
  t[StrPosition] = (g, e) => @core.strposition_sql(g, e, func_name="INSTR")
  t[TableSample] = @core.no_tablesample_sql
  t[TimeStrToTime] = (g, e) => g.sql_key(e, "this")
  t[TimeToStr] = (g, e) => g.func("STRFTIME", [e.arg("format"), e.this()])
  t[TryCast] = @core.no_trycast_sql
  t[TsOrDsToTimestamp] = (g, e) => g.sql_key(e, "this")
  let m = d.gen_fns.methods
  m[AutoIncrementColumnConstraint] = autoincrementcolumnconstraint_sql
  m[Insert] = insert_sql
  m[BitwiseAndAgg] = (g, e) => {
    g.unsupported("BITWISE_AND aggregation is not supported in SQLite")
    g.function_fallback_sql(e)
  }
  m[BitwiseOrAgg] = (g, e) => {
    g.unsupported("BITWISE_OR aggregation is not supported in SQLite")
    g.function_fallback_sql(e)
  }
  m[BitwiseXorAgg] = (g, e) => {
    g.unsupported("BITWISE_XOR aggregation is not supported in SQLite")
    g.function_fallback_sql(e)
  }
  m[JSONExtract] = (g, e) => {
    if !e.expressions().is_empty() {
      g.function_fallback_sql(e)
    } else {
      @core.arrow_json_extract_sql(g, e)
    }
  }
  m[JSONExtractScalar] = (g, e) => {
    if e.has("json_subtype") {
      // json_extract() keeps the JSON subtype on object/array results;
      // ->> strips it, observable when the result feeds another JSON function
      g.func("JSON_EXTRACT", [e.this(), e.expression()])
    } else {
      @core.arrow_json_extract_sql(g, e)
    }
  }
  m[DateAdd] = dateadd_sql
  d.gen_fns.hooks.cast_sql = Some((g, e, _safe_prefix) => {
    if e.is_type([DATE]) {
      g.func("DATE", [e.this()])
    } else {
      g.cast_sql(e)
    }
  })
  m[ComputedColumnConstraint] = computedcolumnconstraint_sql
  // Note: SQLite's TRUNC always returns REAL (e.g., trunc(10.99) -> 10.0), not INTEGER.
  m[Trunc] = (g, e) => {
    g.unsupported_args(e, ["decimals"])
    g.func("TRUNC", [e.this()])
  }
  m[GenerateSeries] = generateseries_sql
  m[DateDiff] = datediff_sql
  m[GroupConcat] = groupconcat_sql
  m[Greatest] = greatest_least_sql
  m[Least] = greatest_least_sql
  m[Transaction] = (g, e) => {
    let this = g.sql_key(e, "this")
    let this = if this.is_empty() { "" } else { " " + this }
    "BEGIN\{this} TRANSACTION"
  }
  m[IsAscii] = (g, e) => {
    "(NOT \{g.sql(e.this())} GLOB CAST(x'2a5b5e012d7f5d2a' AS TEXT))"
  }
  m[CurrentSchema] = (g, e) => {
    g.unsupported_args(e, ["this"])
    "'main'"
  }
  m[IgnoreNulls] = (g, e) => {
    g.unsupported("SQLite does not support IGNORE NULLS.")
    g.sql(e.this())
  }
  m[RespectNulls] = (g, e) => g.sql(e.this())
  m[WindowSpec] = (g, e) => {
    if @core.py_upper(e.text("kind")) == "RANGE" &&
      @core.py_upper(e.text("start")) == "CURRENT ROW" &&
      !e.has("end") {
      "RANGE CURRENT ROW"
    } else {
      g.windowspec_sql(e)
    }
  }
}

///|
fn autoincrementcolumnconstraint_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match e.find_ancestor([ColumnDef]) {
    Some(column) if column.find([PrimaryKeyColumnConstraint]) is Some(_) =>
      g.autoincrementcolumnconstraint_sql(e)
    _ => {
      g.unsupported("SQLite AUTOINCREMENT requires an INTEGER PRIMARY KEY")
      ""
    }
  }
}

///|
fn insert_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("ignore") {
    e.set("ignore", false)
    e.set("alternative", "IGNORE")
  }
  g.insert_sql(e)
}

///|
fn dateadd_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut modifier = e.expression().unwrap()
  let mut unit = e.arg("unit")
  // An INTERVAL amount carries its own unit, e.g. DATE_ADD(d, INTERVAL 1 DAY);
  // unwrap it so the unit is not left inside the quoted modifier string.
  if modifier.kind == Interval {
    if unit is None {
      unit = modifier.arg("unit")
    }
    modifier = modifier.this().unwrap()
  }
  modifier = modifier.unnest()
  if unit is Some(u) &&
    !modifier.kind.is_a(Literal) &&
    !(modifier.kind == Neg && modifier.this().unwrap().is_number()) {
    return g.func("DATE", [
      e.this(),
      @core.mk(DPipe, [
        ("this", @core.paren(modifier)),
        ("expression", @core.literal_string(" " + u.name())),
      ]),
    ])
  }
  let modifier_sql = if modifier.is_string() {
    modifier.name()
  } else {
    g.sql(Some(modifier))
  }
  let modifier_sql = match unit {
    Some(u) => "'\{modifier_sql} \{u.name()}'"
    None => "'\{modifier_sql}'"
  }
  g.func("DATE", [e.this(), modifier_sql])
}

///|
/// https://www.sqlite.org/gencol.html
fn computedcolumnconstraint_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("data_type") {
    g.unsupported("SQLite generated columns do not support a data type")
  }
  let this = e.this()
  let this_sql = match this {
    Some(t) if t.kind == Paren => g.sql(this)
    _ => "(\{g.sql(this)})"
  }
  let storage = if e.has("persisted") { " STORED" } else { "" }
  let not_null = if e.has("not_null") { " NOT NULL" } else { "" }
  "AS \{this_sql}\{storage}\{not_null}"
}

///|
fn generateseries_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let alias_ = match e.parent {
    Some(p) => p.arg("alias")
    None => None
  }
  match alias_ {
    Some(a) if a.kind == TableAlias && !a.list("columns").is_empty() => {
      let column_alias = a.list("columns")[0]
      a.set("columns", (None : @core.Expr?))
      g.sql(
        Some(
          @core.select_([
            @core.alias_(@core.column_of("value"), column_alias.name()),
          ])
          .from_(e)
          .subquery(),
        ),
      )
    }
    _ => g.function_fallback_sql(e)
  }
}

///|
fn datediff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = match e.arg("unit") {
    Some(u) => @core.py_upper(u.name())
    None => "DAY"
  }
  let mut sql = "(JULIANDAY(\{g.sql_key(e, "this")}) - JULIANDAY(\{g.sql_key(e, "expression")}))"
  match unit {
    "MONTH" => sql = "\{sql} / 30.0"
    "YEAR" => sql = "\{sql} / 365.0"
    "HOUR" => sql = "\{sql} * 24.0"
    "MINUTE" => sql = "\{sql} * 1440.0"
    "SECOND" => sql = "\{sql} * 86400.0"
    "MILLISECOND" => sql = "\{sql} * 86400000.0"
    "MICROSECOND" => sql = "\{sql} * 86400000000.0"
    "NANOSECOND" => sql = "\{sql} * 86400000000000.0"
    _ => g.unsupported("DATEDIFF unsupported for '\{unit}'.")
  }
  "CAST(\{sql} AS INTEGER)"
}

///|
fn groupconcat_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let node = match e.parent {
    Some(p) if p.kind == Filter => p
    _ => e
  }
  let window = node.parent
  match (e.this(), window) {
    (Some(order), Some(w)) if order.kind.is_a(Order) &&
      w.kind == Window &&
      w.this() is Some(wt) &&
      physical_equal(wt, node) => {
      g.unsupported(
        "SQLite GROUP_CONCAT window functions do not support argument ORDER BY",
      )
      e.set("this", order.this())
    }
    _ => ()
  }
  @core.groupconcat_sql(
    g,
    e,
    func_name="GROUP_CONCAT",
    sep="",
    within_group=false,
  )
}

///|
fn greatest_least_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.expressions().is_empty() {
    return g.sql_key(e, "this")
  }
  let name = if e.kind == Greatest { "MAX" } else { "MIN" }
  if !e.has("ignore_nulls") {
    return @core.rename_func(name)(g, e)
  }
  // SQLite's multi-argument MAX/MIN return NULL if any argument is NULL.
  // GREATEST(a, b, c) -> MAX(COALESCE(a, b, c), COALESCE(b, c, a), COALESCE(c, a, b)).
  let args = [e.this().unwrap(), ..e.expressions()]
  let coalesces : Array[&@core.SqlArg] = []
  for i in 0..<args.length() {
    let rotated = [..args[i:], ..args[:i]]
    coalesces.push(
      @core.mk(Coalesce, [
        ("this", rotated[0]),
        ("expressions", rotated[1:].to_owned()),
      ]),
    )
  }
  g.func(name, coalesces)
}
