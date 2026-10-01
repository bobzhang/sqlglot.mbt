// Port of sqlglot/executor/__init__.py.

///|
/// Converts a runtime value to a host value for `exp.convert`.
fn to_pyobj(v : Value) -> @core.PyObj raise {
  match v {
    Null => PyNone
    Bool(b) => PyBool(b)
    Int(i) => PyInt(i)
    Float(d) => PyFloat(d)
    Str(s) => PyStr(s)
    List(l) | Iter(l) | Set(l) => PyList(l.map(to_pyobj))
    Tuple(l) => PyTuple(l.map(to_pyobj))
    Dict(d) => PyDict(d.map(kv => (to_pyobj(kv.0), to_pyobj(kv.1))))
    Date(d) => PyDate(year=d.year, month=d.month, day=d.day)
    Time(t) =>
      PyTime(
        hour=t.hour,
        minute=t.minute,
        second=t.second,
        microsecond=t.microsecond,
      )
    DateTime(dt) =>
      PyDateTime(
        year=dt.date.year,
        month=dt.date.month,
        day=dt.date.day,
        hour=dt.time.hour,
        minute=dt.time.minute,
        second=dt.time.second,
        microsecond=dt.time.microsecond,
        tz=dt.tz.map(off => {
          (if off == 0 { "UTC" } else { "UTC\{off}" }, off / 60)
        }),
      )
    _ =>
      raise @core.ValueError(
        "Cannot convert \{v.repr()} of type \{v.type_name()}",
      )
  }
}

///|
fn nested_set(
  d : Map[String, @optimizer.SchemaNode],
  keys : Array[String],
  value : @optimizer.SchemaNode,
) -> Unit {
  if keys.is_empty() {
    return
  }
  if keys.length() == 1 {
    d[keys[0]] = value
    return
  }
  let sub = match d.get(keys[0]) {
    Some(Dict(m)) => m
    _ => {
      let m : Map[String, @optimizer.SchemaNode] = {}
      d[keys[0]] = Dict(m)
      m
    }
  }
  nested_set(sub, keys[1:].to_array(), value)
}

///|
/// Run a sql query against data.
///
/// - `sql`: a SQL statement (a string or an expression).
/// - `schema`: the database schema, in one of the forms `{table: {col: type}}`,
///   `{db: {table: {col: type}}}` or `{catalog: {db: {table: {col: type}}}}`. When it is
///   omitted or empty, it is inferred from the first row of each table.
/// - `dialect`: the SQL dialect to apply during parsing (eg. "spark", "hive", "presto").
/// - `tables`: the tables to register.
///
/// Returns a simple columnar data structure.
pub fn[T : @core.IntoPy] execute(
  sql : T,
  schema? : Map[String, @optimizer.SchemaNode] = {},
  dialect? : String = "",
  tables? : Map[String, TableData] = {},
) -> Table raise {
  let d = @sqlglot.dialect(dialect)
  let tables_ = ensure_tables(Some(tables), dialect=d)
  let schema = if schema.is_empty() {
    let inferred : Map[String, @optimizer.SchemaNode] = {}
    for keys in tables_.flatten() {
      let table = tables_.get(keys).unwrap()
      for column in table.columns {
        let value = table.get_row(0).get(column)
        let annotated = @optimizer.annotate_types(
          @core.convert(to_pyobj(value)),
          dialect=d,
        )
        let column_type : @optimizer.SchemaNode = match annotated.type_ {
          Some(t) => DataType(t)
          None => Type(value.type_name())
        }
        nested_set(inferred, keys + [column], column_type)
      }
    }
    inferred
  } else {
    schema
  }
  let schema = @optimizer.MappingSchema::new(schema~, dialect=d)
  let table_args = tables_.supported_table_args
  if !table_args.is_empty() && table_args != schema.supported_table_args() {
    raise ExecuteError(
      "Tables must support the same table args as schema",
      cause=None,
    )
  }
  let expression = @core.maybe_parse(sql, dialect=d, copy=true)
  let expression = @optimizer.optimize(
    expression,
    schema~,
    dialect=d,
    leave_tables_isolated=true,
  )
  let plan = @planner.Plan::new(expression)
  PythonExecutor::new(tables=tables_).execute(plan)
}
