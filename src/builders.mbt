// Python-style expression builders (port of sqlglot/expressions/builders.py and the
// module-level builders of sqlglot/expressions/core.py and query.py). Arguments are host
// values (`@core.IntoPy`): expressions are used as-is, SQL strings are parsed in `dialect`.

///|
fn dialect_opt(name : String?) -> @core.Dialect raise @core.SqlglotError {
  @core.Dialect::get_or_raise(name.unwrap_or(""))
}

///|
/// `exp.maybe_parse(sql_or_expression, into=..., dialect=..., prefix=..., copy=...)`
pub fn[T : @core.IntoPy] maybe_parse(
  sql_or_expression : T,
  into? : Array[@core.Kind],
  dialect? : String,
  prefix? : String,
  copy? : Bool = false,
) -> @core.Expr raise @core.SqlglotError {
  @core.maybe_parse(
    sql_or_expression,
    into?=into.map(i => i[:]),
    dialect=dialect_opt(dialect),
    prefix?,
    copy~,
  )
}

///|
/// `exp.select(*expressions)`
pub fn[T : @core.IntoPy] select(
  expressions : Array[T],
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.select_(expressions, dialect=dialect_opt(dialect), copy~)
}

///|
/// `exp.from_(expression)`
pub fn[T : @core.IntoPy] from_(
  expression : T,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.mk0(Select).from_(expression, dialect=dialect_opt(dialect), copy~)
}

///|
/// `exp.condition(expression)`
pub fn[T : @core.IntoPy] condition(
  expression : T,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.condition(expression, dialect=dialect_opt(dialect), copy~)
}

///|
/// `exp.and_(*expressions)`
pub fn[T : @core.IntoPy] and_(
  expressions : Array[T],
  dialect? : String,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.combine_py(
    @core.py_list(expressions),
    And,
    dialect=dialect_opt(dialect),
    copy~,
    wrap~,
  )
}

///|
/// `exp.or_(*expressions)`
pub fn[T : @core.IntoPy] or_(
  expressions : Array[T],
  dialect? : String,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.combine_py(
    @core.py_list(expressions),
    Or,
    dialect=dialect_opt(dialect),
    copy~,
    wrap~,
  )
}

///|
/// `exp.xor(*expressions)`
pub fn[T : @core.IntoPy] xor(
  expressions : Array[T],
  dialect? : String,
  copy? : Bool = true,
  wrap? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.combine_py(
    @core.py_list(expressions),
    Xor,
    dialect=dialect_opt(dialect),
    copy~,
    wrap~,
  )
}

///|
/// `exp.not_(expression)`
pub fn[T : @core.IntoPy] not_(
  expression : T,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.not_(
    @core.condition(expression, dialect=dialect_opt(dialect), copy~),
    copy=false,
  )
}

///|
/// `exp.paren(expression)`
pub fn[T : @core.IntoPy] paren(
  expression : T,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  @core.mk1(Paren, @core.maybe_parse(expression, copy~))
}

///|
/// Python `to_identifier(name, quoted, copy)` for a host value: strings become identifiers
/// (quoted when they aren't safe identifiers, unless `quoted` is given), identifiers are
/// copied, `None` stays `None`.
pub fn[T : @core.IntoPy] to_identifier(
  name : T,
  quoted? : Bool,
  copy? : Bool = true,
) -> @core.Expr? raise @core.SqlglotError {
  match name.into_py() {
    PyNone => None
    PyExpr(e) if e.kind == Identifier => Some(@core.maybe_copy(e, copy))
    PyStr(s) => Some(@core.to_identifier(s, quoted?))
    other =>
      raise @core.ValueError(
        "Name needs to be a string or an Identifier, got: \{other.py_repr()}",
      )
  }
}

///|
/// `exp.alias_(expression, alias, table=..., quoted=...)`. `table` creates a table alias;
/// `table_columns` adds its column names (Python `table=[...]`).
pub fn[T : @core.IntoPy, A : @core.IntoPy] alias_(
  expression : T,
  alias_name : A,
  table? : Bool = false,
  table_columns? : Array[String] = [],
  quoted? : Bool,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let exp = @core.maybe_parse(expression, dialect=dialect_opt(dialect), copy~)
  let alias_id = to_identifier(alias_name, quoted?)
  if table || !table_columns.is_empty() {
    let table_alias = @core.mk(TableAlias, [("this", alias_id)])
    exp.set("alias", table_alias)
    for column in table_columns {
      table_alias.append("columns", @core.to_identifier(column, quoted?))
    }
    return exp
  }
  @core.alias_expr(exp, alias_id, copy=false)
}

///|
/// `exp.case(expression)`
pub fn case(
  expression? : &@core.IntoPy,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let this = match expression {
    Some(e) =>
      Some(@core.maybe_parse(e.into_py(), dialect=dialect_opt(dialect), copy~))
    None => None
  }
  @core.mk(Case, [("this", this), ("ifs", ([] : Array[@core.Expr]))])
}

///|
/// `exp.DataType.build(dtype, dialect=..., udt=...)`: `dtype` may be a type string, a
/// `DataType` expression or a `DType` (as `@core.datatype_of(dtype)`).
pub fn[T : @core.IntoPy] datatype_build(
  dtype : T,
  dialect? : String,
  udt? : Bool = false,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  match dtype.into_py() {
    PyStr(s) => @core.datatype_from_str(s, dialect=dialect_opt(dialect), udt~)
    PyExpr(e) if e.kind.is_any([Identifier, Dot]) && udt =>
      @core.mk(DataType, [("this", @core.DType::USERDEFINED), ("kind", e)])
    PyExpr(e) if e.kind.is_a(DataType) => @core.maybe_copy(e, copy)
    other =>
      raise @core.ValueError(
        "Invalid data type: \{other.py_repr()}. Expected str or DType",
      )
  }
}

///|
/// `DataType.is_type(*dtypes, check_nullable=...)` for a `DataType` expression, with the
/// types given as type strings or `DataType` expressions.
pub fn[T : @core.IntoPy] datatype_is_type(
  dt : @core.Expr,
  dtypes : Array[T],
  check_nullable? : Bool = false,
) -> Bool raise @core.SqlglotError {
  let self_is_nullable = dt.bool_arg("nullable")
  for dtype in dtypes {
    let other_type = datatype_build(dtype, copy=false, udt=true)
    let other_is_nullable = other_type.bool_arg("nullable")
    let matches = if !other_type.expressions().is_empty() ||
      (check_nullable && (self_is_nullable || other_is_nullable)) ||
      dt.datatype_this() == Some(@core.DType::USERDEFINED) ||
      other_type.datatype_this() == Some(@core.DType::USERDEFINED) {
      dt == other_type
    } else {
      match (dt.get("this"), other_type.get("this")) {
        (Some(DT(a)), Some(DT(b))) => a == b
        (None, None) => true
        (Some(Node(a)), Some(Node(b))) => a == b
        (Some(Str(a)), Some(Str(b))) => a == b
        _ => false
      }
    }
    if matches {
      return true
    }
  }
  false
}

///|
/// `Expr.is_type(*dtypes)`: whether the type of `expression` (a DataType, the target type
/// of a cast, or its annotated type) matches one of `dtypes`.
pub fn[T : @core.IntoPy] is_type(
  expression : @core.Expr,
  dtypes : Array[T],
  check_nullable? : Bool = false,
) -> Bool raise @core.SqlglotError {
  match expression.get_type() {
    Some(t) => datatype_is_type(t, dtypes, check_nullable~)
    None => false
  }
}

///|
/// `exp.cast(expression, to)`
pub fn[T : @core.IntoPy, D : @core.IntoPy] cast(
  expression : T,
  to : D,
  copy? : Bool = true,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let expr = @core.maybe_parse(expression, copy~, dialect=d)
  let data_type = datatype_build(to, copy~, dialect?)
  // dont re-cast if the expression is already a cast to the correct type
  if expr.kind.is_a(Cast) {
    let type_mapping = d.gen_cfg.type_mapping
    let existing_cast_type = match expr.arg("to") {
      Some(to) => to.datatype_this()
      None => None
    }
    let new_cast_type = data_type.datatype_this()
    let types_are_equivalent = match (existing_cast_type, new_cast_type) {
      (Some(a), Some(b)) =>
        type_mapping.get(a).unwrap_or(a.value()) ==
        type_mapping.get(b).unwrap_or(b.value())
      _ => false
    }
    if expr.is_type_expr(data_type) || types_are_equivalent {
      return expr
    }
  }
  let e = @core.mk(Cast, [("this", expr), ("to", data_type)])
  e.set_type(Some(data_type))
  e
}

///|
/// `exp.column(col, table, db, catalog, fields=..., quoted=...)`
pub fn[T : @core.IntoPy] column(
  col : T,
  table? : &@core.IntoPy,
  db? : &@core.IntoPy,
  catalog? : &@core.IntoPy,
  fields? : Array[&@core.IntoPy] = [],
  quoted? : Bool,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let col = match col.into_py() {
    PyExpr(e) if e.kind == Star => Some(e)
    other => to_identifier(other, quoted?, copy~)
  }
  let ident = fn(x : &@core.IntoPy?) raise @core.SqlglotError {
    match x {
      Some(v) => to_identifier(v.into_py(), quoted?, copy~)
      None => None
    }
  }
  let this = @core.mk(Column, [
    ("this", col),
    ("table", ident(table)),
    ("db", ident(db)),
    ("catalog", ident(catalog)),
  ])
  if fields.is_empty() {
    return this
  }
  let parts = [this]
  for f in fields {
    match to_identifier(f.into_py(), quoted?, copy~) {
      Some(i) => parts.push(i)
      None => ()
    }
  }
  @core.dot_build(parts)
}

///|
/// `exp.func(name, *args, **kwargs)`: an instance of the function `name`, or an anonymous
/// function if `name` doesn't correspond to a known function.
pub fn func(
  name : String,
  args? : Array[&@core.IntoPy] = [],
  kwargs? : Map[String, &@core.IntoPy] = Map([]),
  copy? : Bool = true,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  if !args.is_empty() && !kwargs.is_empty() {
    raise @core.ValueError(
      "Can't use both args and kwargs to instantiate a function.",
    )
  }
  let d = dialect_opt(dialect)
  let converted = []
  for arg in args {
    converted.push(@core.maybe_parse(arg.into_py(), dialect=d, copy~))
  }
  let parsed_kwargs : Map[String, @core.Expr] = Map([])
  for k, v in kwargs {
    parsed_kwargs[k] = @core.maybe_parse(v.into_py(), dialect=d, copy~)
  }
  let upper = @core.py_upper(name)
  let function = match d.parser_fns.functions.get(upper) {
    Some(constructor_) =>
      if !converted.is_empty() {
        constructor_(converted, d.parser())
      } else {
        let mut kind : @core.Kind? = None
        for kv in @core.function_by_name {
          if kv.0 == upper {
            kind = Some(kv.1)
            break
          }
        }
        match kind {
          Some(k) => {
            let f = @core.mk0(k)
            for key, v in parsed_kwargs {
              f.set(key, v)
            }
            f
          }
          None =>
            raise @core.ValueError(
              "Unable to convert '\{name}' into a Func. Either manually construct the Func expression of interest or parse the function call.",
            )
        }
      }
    None => {
      let f = @core.mk(Anonymous, [("this", name)])
      if parsed_kwargs.is_empty() {
        f.set("expressions", converted)
      } else {
        for key, v in parsed_kwargs {
          f.set(key, v)
        }
      }
      f
    }
  }
  for error_message in function.error_messages(nargs=converted.length()) {
    raise @core.ValueError(error_message)
  }
  function
}

///|
fn set_operation_builder(
  expressions : Array[@core.PyObj],
  kind : @core.Kind,
  name : String,
  distinct : Bool,
  dialect : String?,
  copy : Bool,
) -> @core.Expr raise @core.SqlglotError {
  if expressions.length() < 2 {
    raise @core.ValueError(
      "At least two expressions are required by `\{name}`.",
    )
  }
  @core.apply_set_operation(
    expressions,
    kind,
    distinct~,
    dialect=dialect_opt(dialect),
    copy~,
  )
}

///|
/// `exp.union(*expressions, distinct=...)`
pub fn[T : @core.IntoPy] union(
  expressions : Array[T],
  distinct? : Bool = true,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  set_operation_builder(
    @core.py_list(expressions),
    Union,
    "union",
    distinct,
    dialect,
    copy,
  )
}

///|
/// `exp.intersect(*expressions, distinct=...)`
pub fn[T : @core.IntoPy] intersect(
  expressions : Array[T],
  distinct? : Bool = true,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  set_operation_builder(
    @core.py_list(expressions),
    Intersect,
    "intersect",
    distinct,
    dialect,
    copy,
  )
}

///|
/// `exp.except_(*expressions, distinct=...)`
pub fn[T : @core.IntoPy] except_(
  expressions : Array[T],
  distinct? : Bool = true,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  set_operation_builder(
    @core.py_list(expressions),
    Except,
    "except_",
    distinct,
    dialect,
    copy,
  )
}

///|
/// `exp.update(table, properties, where=..., from_=..., with_=...)`
pub fn[T : @core.IntoPy] update(
  table : T,
  properties? : Map[String, &@core.IntoPy] = Map([]),
  where_? : &@core.IntoPy,
  from_? : &@core.IntoPy,
  with_? : Map[String, &@core.IntoPy] = Map([]),
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let update_expr = @core.mk1(
    Update,
    @core.maybe_parse(table, into=[Table], dialect=d, copy~),
  )
  if !properties.is_empty() {
    let exprs = []
    for k, v in properties {
      exprs.push(
        @core.mk(EQ, [
          ("this", @core.maybe_parse(k, dialect=d, copy~)),
          ("expression", @core.convert(v.into_py())),
        ]),
      )
    }
    update_expr.set("expressions", exprs)
  }
  match from_ {
    Some(f) if f.into_py().truthy() =>
      update_expr.set(
        "from_",
        @core.maybe_parse(
          f.into_py(),
          into=[From],
          dialect=d,
          prefix="FROM",
          copy~,
        ),
      )
    _ => ()
  }
  match where_ {
    Some(w) => {
      let w = match w.into_py() {
        PyExpr(e) if e.kind.is_a(Condition) => @core.PyExpr(@core.mk1(Where, e))
        other => other
      }
      if w.truthy() {
        update_expr.set(
          "where",
          @core.maybe_parse(w, into=[Where], dialect=d, prefix="WHERE", copy~),
        )
      }
    }
    None => ()
  }
  if !with_.is_empty() {
    let cte_list = []
    for cte_name, qry in with_ {
      let cte = @core.mk1(
        CTE,
        @core.maybe_parse(qry.into_py(), dialect=d, copy~),
      )
      cte_list.push(alias_(cte, cte_name, table=true))
    }
    update_expr.set("with_", @core.mk(With, [("expressions", cte_list)]))
  }
  update_expr
}

///|
/// `exp.delete(table, where=..., returning=...)`
pub fn[T : @core.IntoPy] delete(
  table : T,
  where_? : &@core.IntoPy,
  returning? : &@core.IntoPy,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let mut delete_expr = @core.mk0(Delete).delete(table, dialect=d, copy=false)
  match where_ {
    Some(w) if w.into_py().truthy() =>
      delete_expr = delete_expr.where_([w.into_py()], dialect=d, copy=false)
    _ => ()
  }
  match returning {
    Some(r) if r.into_py().truthy() =>
      delete_expr = delete_expr.returning(r.into_py(), dialect=d, copy=false)
    _ => ()
  }
  delete_expr
}

///|
/// `exp.insert(expression, into, columns=..., overwrite=..., returning=...)`
pub fn[T : @core.IntoPy, I : @core.IntoPy] insert(
  expression : T,
  into : I,
  columns? : Array[String] = [],
  overwrite? : Bool,
  returning? : &@core.IntoPy,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let expr = @core.maybe_parse(expression, dialect=d, copy~)
  let mut this = @core.maybe_parse(into, into=[Table], dialect=d, copy~)
  if !columns.is_empty() {
    this = @core.mk(Schema, [
      ("this", this),
      ("expressions", columns.map(c => @core.to_identifier(c))),
    ])
  }
  let mut insert = @core.mk(Insert, [
    ("this", this),
    ("expression", expr),
    ("overwrite", overwrite),
  ])
  match returning {
    Some(r) if r.into_py().truthy() =>
      insert = insert.returning(r.into_py(), dialect=d, copy=false)
    _ => ()
  }
  insert
}

///|
/// `exp.merge(*when_exprs, into=..., using=..., on=..., returning=...)`
pub fn[I : @core.IntoPy, U : @core.IntoPy, O : @core.IntoPy] merge(
  when_exprs : Array[&@core.IntoPy],
  into~ : I,
  using_~ : U,
  on~ : O,
  returning? : &@core.IntoPy,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let expressions = []
  for when_expr in when_exprs {
    let expression = @core.maybe_parse(when_expr.into_py(), dialect=d, copy~, into=[
      Whens,
    ])
    if expression.kind == When {
      expressions.push(expression)
    } else {
      expressions.append(expression.expressions())
    }
  }
  let mut merge = @core.mk(Merge, [
    ("this", @core.maybe_parse(into, dialect=d, copy~)),
    ("using", @core.maybe_parse(using_, dialect=d, copy~)),
    ("on", @core.maybe_parse(on, dialect=d, copy~)),
    ("whens", @core.mk(Whens, [("expressions", expressions)])),
  ])
  match returning {
    Some(r) if r.into_py().truthy() =>
      merge = merge.returning(r.into_py(), dialect=d, copy=false)
    _ => ()
  }
  match merge.arg("using") {
    Some(using_clause) if using_clause.kind == Alias =>
      using_clause.replace(
        Some(
          alias_(using_clause.this_(), using_clause.arg("alias"), table=true),
        ),
      )
      |> ignore
    _ => ()
  }
  merge
}

///|
/// `exp.parse_identifier(name, dialect)`
pub fn parse_identifier(
  name : String,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  @core.parse_identifier(name, dialect=dialect_opt(dialect))
}

///|
/// `exp.to_interval(interval)`: builds an interval expression from a string like '1 day'.
pub fn[T : @core.IntoPy] to_interval(
  interval : T,
) -> @core.Expr raise @core.SqlglotError {
  let text = match interval.into_py() {
    PyExpr(e) if e.kind == Literal => {
      if !e.is_string() {
        raise @core.ValueError("Invalid interval string.")
      }
      e.text("this")
    }
    other => other.py_str()
  }
  let parsed = @core.maybe_parse("INTERVAL \{text}")
  if parsed.kind != Interval {
    raise @core.ValueError("Expected an Interval, got \{parsed.kind}")
  }
  parsed
}

///|
/// Python `split_num_words(value, sep, min_num_words)` (filling from the start).
fn split_num_words(
  value : String,
  sep : String,
  min_num_words : Int,
) -> Array[String?] {
  let words : Array[String?] = @core.py_split(value, sep).map(w => Some(w))
  let out : Array[String?] = []
  for _ in 0..<(min_num_words - words.length()) {
    out.push(None)
  }
  out + words
}

///|
/// `exp.to_table(sql_path, dialect=..., **kwargs)`: a table expression from a
/// `[catalog].[schema].[table]` sql path, or a copy of the given table.
pub fn[T : @core.IntoPy] to_table(
  sql_path : T,
  dialect? : String,
  copy? : Bool = true,
  kwargs? : Map[String, @core.Value] = Map([]),
) -> @core.Expr raise @core.SqlglotError {
  let path = sql_path.into_py()
  let table = match path {
    PyExpr(e) if e.kind == Table => return @core.maybe_copy(e, copy)
    _ =>
      @core.maybe_parse(path, into=[Table], dialect=dialect_opt(dialect)) catch {
        @core.ParseError(_, _) as err => {
          let parts = split_num_words(path.py_str(), ".", 3)
          match parts[2] {
            Some(this) if !this.is_empty() =>
              table_(this, db?=parts[1], catalog?=parts[0])
            _ => raise err
          }
        }
        err => raise err
      }
  }
  for k, v in kwargs {
    table.set(k, v)
  }
  table
}

///|
/// `exp.to_column(sql_path, quoted=..., dialect=..., **kwargs)`
pub fn[T : @core.IntoPy] to_column(
  sql_path : T,
  quoted? : Bool,
  dialect? : String,
  copy? : Bool = true,
  kwargs? : Map[String, @core.Value] = Map([]),
) -> @core.Expr raise @core.SqlglotError {
  let path = sql_path.into_py()
  match path {
    PyExpr(e) if e.kind.is_a(Column) => return @core.maybe_copy(e, copy)
    _ => ()
  }
  let col = @core.maybe_parse(path, into=[Column], dialect=dialect_opt(dialect)) catch {
    @core.ParseError(_, _) => {
      let parts = @core.py_split(path.py_str(), ".")
      parts.rev_in_place()
      let c = column(
        parts[0],
        table?=parts.get(1).map(x => (x : &@core.IntoPy)),
        db?=parts.get(2).map(x => (x : &@core.IntoPy)),
        catalog?=parts.get(3).map(x => (x : &@core.IntoPy)),
        quoted?,
      )
      for k, v in kwargs {
        c.set(k, v)
      }
      return c
    }
    err => raise err
  }
  for k, v in kwargs {
    col.set(k, v)
  }
  if quoted == Some(true) {
    for i in col.find_all([Identifier]) {
      i.set("quoted", true)
    }
  }
  col
}

///|
/// `exp.subquery(expression, alias)`: a new `Select` from the given query as a subquery.
pub fn[T : @core.IntoPy] subquery(
  expression : T,
  alias_? : String,
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let expr = @core.maybe_parse(expression, dialect=d)
    .assert_is(Query)
    .subquery(alias_?, copy~)
  @core.mk0(Select).from_(expr, dialect=d)
}

///|
/// `exp.table_(table, db=..., catalog=..., quoted=..., alias=...)`
pub fn table_(
  table : String,
  db? : String,
  catalog? : String,
  quoted? : Bool,
  alias_? : String,
) -> @core.Expr {
  let ident = fn(s : String?) {
    match s {
      Some(s) if !s.is_empty() => Some(@core.to_identifier(s, quoted?))
      _ => None
    }
  }
  @core.mk(Table, [
    ("this", ident(Some(table))),
    ("db", ident(db)),
    ("catalog", ident(catalog)),
    (
      "alias",
      match alias_ {
        Some(a) if !a.is_empty() =>
          Some(@core.mk1(TableAlias, @core.to_identifier(a)))
        _ => None
      },
    ),
  ])
}

///|
/// `exp.values(values, alias=..., columns=...)`: builds a VALUES statement.
pub fn values(
  values : Array[@core.PyObj],
  alias_? : String,
  columns? : Array[String] = [],
) -> @core.Expr raise @core.SqlglotError {
  if !columns.is_empty() && alias_.unwrap_or("").is_empty() {
    raise @core.ValueError("Alias is required when providing columns")
  }
  let exprs = []
  for tup in values {
    exprs.push(@core.convert(tup))
  }
  let table_alias = if !columns.is_empty() {
    Some(
      @core.mk(TableAlias, [
        ("this", @core.to_identifier(alias_.unwrap())),
        ("columns", columns.map(c => @core.to_identifier(c))),
      ]),
    )
  } else {
    match alias_ {
      Some(a) if !a.is_empty() =>
        Some(@core.mk1(TableAlias, @core.to_identifier(a)))
      _ => None
    }
  }
  @core.mk(Values, [("expressions", exprs), ("alias", table_alias)])
}

///|
/// `exp.var(name)`: builds a SQL variable.
pub fn[T : @core.IntoPy] var_(name : T) -> @core.Expr raise @core.SqlglotError {
  let n = match name.into_py() {
    PyExpr(e) => e.name()
    PyNone => ""
    other => other.py_str()
  }
  if n.is_empty() {
    raise @core.ValueError("Cannot convert empty name into var.")
  }
  @core.var_(n)
}

///|
/// `exp.rename_table(old_name, new_name)`
pub fn[O : @core.IntoPy, N : @core.IntoPy] rename_table(
  old_name : O,
  new_name : N,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let old_table = to_table(old_name, dialect?)
  let new_table = to_table(new_name, dialect?)
  @core.mk(Alter, [
    ("this", old_table),
    ("kind", "TABLE"),
    ("actions", [@core.mk1(AlterRename, new_table)]),
  ])
}

///|
/// `exp.rename_column(table_name, old_column_name, new_column_name, exists=...)`
pub fn[T : @core.IntoPy, O : @core.IntoPy, N : @core.IntoPy] rename_column(
  table_name : T,
  old_column_name : O,
  new_column_name : N,
  exists? : Bool,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let table = to_table(table_name, dialect?)
  let old_column = to_column(old_column_name, dialect?)
  let new_column = to_column(new_column_name, dialect?)
  @core.mk(Alter, [
    ("this", table),
    ("kind", "TABLE"),
    (
      "actions",
      [
        @core.mk(RenameColumn, [
          ("this", old_column),
          ("to", new_column),
          ("exists", exists),
        ]),
      ],
    ),
  ])
}

///|
/// `exp.table_name(table, dialect=..., identify=...)`: the full name of a table.
pub fn[T : @core.IntoPy] table_name(
  table : T,
  dialect? : String,
  identify? : Bool = false,
) -> String raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let expr = @core.maybe_parse(table, into=[Table], dialect=d)
  let parts = []
  for part in expr.parts() {
    parts.push(
      if identify || !@core.is_safe_identifier(part.name()) {
        @core.Generator::new(d, identify="always", comments=false).generate(
          part,
          copy=false,
        )
      } else {
        part.name()
      },
    )
  }
  parts.join(".")
}

///|
/// `exp.normalize_table_name(table, dialect=...)`: a case normalized table name without
/// quotes.
pub fn[T : @core.IntoPy] normalize_table_name(
  table : T,
  dialect? : String,
  copy? : Bool = true,
) -> String raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  @core.normalize_identifiers(to_table(table, dialect?, copy~), d)
  .parts()
  .map(p => p.name())
  .join(".")
}

///|
/// `exp.replace_tables(expression, mapping, dialect=...)`: replaces all tables in
/// `expression` according to `mapping`.
pub fn replace_tables(
  expression : @core.Expr,
  mapping : Map[String, String],
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let normalized : Map[String, String] = Map([])
  for k, v in mapping {
    normalized[normalize_table_name(k, dialect?)] = v
  }
  expression.transform(
    node => {
      if node.kind == Table && !(node.meta_get("replace") is Some(Bool(false))) {
        let original = normalize_table_name(node, dialect?)
        match normalized.get(original) {
          Some(new_name) if !new_name.is_empty() => {
            let kwargs : Map[String, @core.Value] = Map([])
            for k, v in node.args {
              if k != "this" && k != "db" && k != "catalog" {
                kwargs[k] = v
              }
            }
            let table = to_table(new_name, kwargs~, dialect?)
            table.add_comments(Some([original]))
            return Some(table)
          }
          _ => ()
        }
      }
      Some(node)
    },
    copy~,
  )
}

///|
/// `exp.replace_placeholders(expression, *args, **kwargs)`: replaces unnamed placeholders
/// with `args` (in order) and named placeholders with `kwargs`.
pub fn replace_placeholders(
  expression : @core.Expr,
  args? : Array[&@core.IntoPy] = [],
  kwargs? : Map[String, &@core.IntoPy] = Map([]),
) -> @core.Expr raise @core.SqlglotError {
  let mut next_arg = 0
  expression.transform(node => {
    if node.kind == Placeholder {
      let name = node.text("this")
      if !name.is_empty() {
        match kwargs.get(name) {
          Some(v) =>
            match v.into_py() {
              PyNone => ()
              obj => return Some(@core.convert(obj))
            }
          None => ()
        }
      } else if next_arg < args.length() {
        let v = args[next_arg]
        next_arg += 1
        return Some(@core.convert(v.into_py()))
      }
    }
    Some(node)
  })
}

///|
/// `exp.expand(expression, sources, dialect=...)`: expands all referenced sources into
/// subqueries. Each source is given as a function providing the query on demand.
pub fn expand(
  expression : @core.Expr,
  sources : Map[String, () -> @core.Expr raise @core.SqlglotError],
  dialect? : String,
  copy? : Bool = true,
) -> @core.Expr raise @core.SqlglotError {
  let normalized : Map[String, () -> @core.Expr raise @core.SqlglotError] = Map([],
  )
  for k, v in sources {
    normalized[normalize_table_name(k, dialect?)] = v
  }
  fn expand_node(node : @core.Expr) -> @core.Expr? raise @core.SqlglotError {
    if node.kind == Table {
      let name = normalize_table_name(node, dialect?)
      match normalized.get(name) {
        Some(source) => {
          let parsed_source = source()
          let alias_ = node.alias_()
          let subquery = parsed_source.subquery(
            alias_=if alias_.is_empty() { name } else { alias_ },
          )
          subquery.add_comments(Some(["source: \{name}"]))
          return Some(subquery.transform(expand_node, copy=false))
        }
        None => ()
      }
    }
    Some(node)
  }

  expression.transform(expand_node, copy~)
}

///|
/// `exp.array(*expressions)`
pub fn[T : @core.IntoPy] array(
  expressions : Array[T],
  copy? : Bool = true,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let exprs = []
  for e in expressions {
    exprs.push(@core.maybe_parse(e, copy~, dialect=d))
  }
  @core.mk(Array, [("expressions", exprs)])
}

///|
/// `exp.tuple_(*expressions)`
pub fn[T : @core.IntoPy] tuple_(
  expressions : Array[T],
  copy? : Bool = true,
  dialect? : String,
) -> @core.Expr raise @core.SqlglotError {
  let d = dialect_opt(dialect)
  let exprs = []
  for e in expressions {
    exprs.push(@core.maybe_parse(e, copy~, dialect=d))
  }
  @core.mk(Tuple, [("expressions", exprs)])
}
