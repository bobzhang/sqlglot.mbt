// Port of sqlglot/executor/python.py: executes a plan by generating Python code for its
// expressions (see python_dialect.mbt) and evaluating it (see pyeval.mbt).

///|
/// Raised when the execution of a plan fails (Python `sqlglot.errors.ExecuteError`);
/// `cause` is the underlying error (Python `__cause__`).
pub(all) suberror ExecuteError {
  ExecuteError(String, cause~ : Error?)
}

///|
/// Python `str(error)`.
pub fn error_message(e : Error) -> String {
  match e {
    PyException(_, m) => m
    ExecuteError(m, ..) => m
    @core.SqlglotError::ParseError(m, _) => m
    @core.SqlglotError::TokenError(m)
    | @core.SqlglotError::UnsupportedError(m)
    | @core.SqlglotError::OptimizeError(m)
    | @core.SqlglotError::SchemaError(m)
    | @core.SqlglotError::ExecuteError(m)
    | @core.SqlglotError::ValueError(m) => m
    _ => e.to_string()
  }
}

///|
priv struct SubqueryPlan {
  plan : @planner.Plan
  cache : Map[String, Table]
}

///|
/// Executes plans with Python semantics (Python `PythonExecutor`).
pub struct PythonExecutor {
  priv generator : @core.Generator
  env : Map[String, Value]
  tables : Tables
  priv subquery_plans : Array[(String, SubqueryPlan)]
  priv plan_names_by_sql : Map[String, String]
  priv mut ctes : @core.Expr?
  priv mut outer_scope : Map[String?, Reader]?
}

///|
/// Creates an executor. `env` adds or overrides functions available to the generated
/// code.
pub fn PythonExecutor::new(
  env? : Map[String, Value] = {},
  tables? : Tables,
) -> PythonExecutor raise @core.SqlglotError {
  let all_env : Map[String, Value] = Map([])
  for k, v in default_env {
    all_env[k] = v
  }
  for k, v in env {
    all_env[k] = v
  }
  let tables = match tables {
    Some(t) => t
    None => Tables::new({})
  }
  let self = {
    generator: @core.Generator::new(
      python_dialect(),
      identify="always",
      comments=false,
    ),
    env: all_env,
    tables,
    subquery_plans: [],
    plan_names_by_sql: {},
    ctes: None,
    outer_scope: None,
  }
  all_env["SUBQUERY_COMPARISON"] = pyfunc("SUBQUERY_COMPARISON", 5, -1, args => {
    self.subquery_comparison(args)
  })
  all_env["SUBQUERY_EXISTS"] = pyfunc("SUBQUERY_EXISTS", 2, -1, args => {
    self.subquery_exists(args)
  })
  all_env["SUBQUERY_SCALAR"] = pyfunc("SUBQUERY_SCALAR", 2, -1, args => {
    self.subquery_scalar(args)
  })
  self
}

///|
/// The number of distinct subquery plans and the size of each one's result cache.
pub fn PythonExecutor::subquery_cache_sizes(
  self : PythonExecutor,
) -> Array[Int] {
  self.subquery_plans.map(kv => kv.1.cache.length())
}

///|
/// Executes a plan; `outer_scope` are the readers of an enclosing query.
pub fn PythonExecutor::execute(
  self : PythonExecutor,
  plan : @planner.Plan,
  outer_scope? : Map[String?, Reader],
) -> Table raise {
  let ctes = self.ctes
  let scope = self.outer_scope
  self.ctes = plan.ctes
  self.outer_scope = outer_scope
  defer {
    self.ctes = ctes
    self.outer_scope = scope
  }
  self.execute_plan(plan)
}

///|
fn contains_step(steps : Array[@planner.Step], step : @planner.Step) -> Bool {
  steps.iter().any(s => physical_equal(s, step))
}

///|
fn PythonExecutor::execute_plan(
  self : PythonExecutor,
  plan : @planner.Plan,
) -> Table raise {
  let finished : Array[@planner.Step] = []
  let queue = plan.leaves()
  let contexts : Map[Int, Context] = Map([])
  while queue.pop() is Some(node) {
    try {
      let tables : Array[(String?, Table)] = []
      for dep in node.dependencies {
        for kv in contexts[dep.uid].tables {
          tables.push(kv)
        }
      }
      let context = self.context(tables)
      let result = match node.kind {
        Scan => self.scan(node, context)
        Aggregate => self.aggregate(node, context)
        Join => self.join(node, context)
        Sort => self.sort(node, context)
        SetOperation => self.set_operation(node, context)
      }
      contexts[node.uid] = result
      if node.offset != 0L {
        let table = result.get_table(node.name)
        table.rows = slice_rows(table.rows, clamp_int(node.offset), None)
      }
      finished.push(node)
      for dep in node.dependents {
        if dep.dependencies.iter().all(d => contexts.contains(d.uid)) &&
          !contains_step(queue, dep) &&
          !contains_step(finished, dep) {
          queue.push(dep)
        }
      }
      for dep in node.dependencies {
        if dep.dependents.iter().all(d => contains_step(finished, d)) {
          contexts.remove(dep.uid)
        }
      }
    } catch {
      e =>
        raise ExecuteError(
          "Step '\{node.id()}' failed: \{error_message(e)}",
          cause=Some(e),
        )
    }
  }
  let root = plan.root
  contexts[root.uid].get_table(root.name)
}

///|
fn slice_rows(rows : Array[Row], start : Int, end : Int?) -> Array[Row] {
  let n = rows.length()
  let s = if start > n { n } else { start }
  let e = match end {
    Some(e) => if e > n { n } else if e < s { s } else { e }
    None => n
  }
  rows[s:e].to_owned()
}

///|
/// Converts a SQL expression into Python code and compiles it.
pub fn PythonExecutor::generate(
  self : PythonExecutor,
  expression : @core.Expr?,
) -> Code? raise {
  guard expression is Some(expression) else { return None }
  let expression = self.replace_subqueries(expression)
  let sql = self.generator.generate(expression)
  Some(compile_python(sql))
}

///|
fn PythonExecutor::generate_tuple(
  self : PythonExecutor,
  expressions : Array[@core.Expr],
) -> Array[Code] raise {
  expressions.map(e => self.generate(Some(e)).unwrap())
}

///|
let subquery_nodes : Array[@core.Kind] = [Subquery, Exists, All, Any]

///|
fn PythonExecutor::replace_subqueries(
  self : PythonExecutor,
  expression : @core.Expr,
) -> @core.Expr raise {
  if expression.find(subquery_nodes) is None {
    return expression
  }
  let mut expression = expression.copy()
  for ;; {
    guard expression.find(subquery_nodes) is Some(subquery) else {
      return expression
    }
    let (target, replacement) = self.compile_subquery(subquery)
    if physical_equal(target, expression) {
      expression = replacement
    } else {
      target.replace(Some(replacement)) |> ignore
    }
  }
}

///|
fn PythonExecutor::compile_subquery(
  self : PythonExecutor,
  subquery : @core.Expr,
) -> (@core.Expr, @core.Expr) raise {
  let query = subquery.this_().unnest()
  let outer_columns = match @optimizer.build_scope(query) {
    Some(scope) => scope.external_columns()
    None => []
  }
  let plan = self.register_subquery(query)
  let parent = subquery.parent
  let scope_var = @core.var_("scope")
  if subquery.kind.is_a(Exists) {
    return (
      subquery,
      @core.func_("SUBQUERY_EXISTS", [plan, scope_var] + outer_columns),
    )
  }
  let selects = query.selects()
  if selects.length() != 1 {
    raise ExecuteError(
      "Subquery used as an expression returned \{selects.length()} columns",
      cause=None,
    )
  }
  if subquery.kind.is_a(All) || subquery.kind.is_a(Any) {
    return self.compile_quantified(
      parent,
      @core.py_upper(subquery.kind.key()),
      plan,
      outer_columns,
    )
  }
  match parent {
    Some(p) if p.kind.is_a(In) &&
      (match p.arg("query") {
        Some(q) => physical_equal(q, subquery)
        None => false
      }) =>
      return self.compile_quantified(
        parent,
        "ANY",
        plan,
        outer_columns,
        op="EQ",
      )
    _ => ()
  }
  (subquery, @core.func_("SUBQUERY_SCALAR", [plan, scope_var] + outer_columns))
}

///|
fn PythonExecutor::compile_quantified(
  _self : PythonExecutor,
  comparison : @core.Expr?,
  quantifier : String,
  plan : @core.Expr,
  outer_columns : Array[@core.Expr],
  op? : String,
) -> (@core.Expr, @core.Expr) raise {
  guard comparison is Some(comparison) &&
    (comparison.kind.is_a(Binary) || comparison.kind.is_a(In)) else {
    raise ExecuteError(
      "Unsupported \{quantifier} subquery: expected a comparison",
      cause=None,
    )
  }
  let op = match op {
    Some(o) => o
    None => @core.py_upper(comparison.kind.key())
  }
  let args = [
    comparison.this_(),
    plan,
    @core.var_("scope"),
    @core.literal_string(op),
    @core.literal_string(quantifier),
  ]
  (comparison, @core.func_("SUBQUERY_COMPARISON", args + outer_columns))
}

///|
fn PythonExecutor::register_subquery(
  self : PythonExecutor,
  query : @core.Expr,
) -> @core.Expr raise {
  match self.ctes {
    Some(ctes) if !query.has("with_") => query.set("with_", ctes)
    _ => ()
  }
  let sql = @core.expr_to_sql(query)
  let name = match self.plan_names_by_sql.get(sql) {
    Some(n) => n
    None => {
      let n = "_sq_\{self.subquery_plans.length()}"
      self.plan_names_by_sql[sql] = n
      self.subquery_plans.push(
        (n, { plan: @planner.Plan::new(query), cache: {}, }),
      )
      n
    }
  }
  @core.literal_string(name)
}

///|
fn PythonExecutor::subquery_table(
  self : PythonExecutor,
  plan_name : Value,
  scope : Value,
  args : Array[Value],
) -> Table raise {
  let name = match plan_name {
    Str(s) => s
    v => raise PyException("KeyError", v.repr())
  }
  let mut entry : SubqueryPlan? = None
  for kv in self.subquery_plans {
    if kv.0 == name {
      entry = Some(kv.1)
    }
  }
  guard entry is Some(entry) else {
    raise PyException("KeyError", @core.py_repr_str(name))
  }
  // an unhashable correlated value can't be memoized
  let key = hash_key(Tuple(args)) catch { _ => "" }
  if key != "" {
    match entry.cache.get(key) {
      Some(t) => return t
      None => ()
    }
  }
  let outer = match scope {
    Readers(m) => Some(m)
    _ => None
  }
  let table = self.execute(entry.plan, outer_scope?=outer)
  if key != "" {
    entry.cache[key] = table
  }
  table
}

///|
fn PythonExecutor::subquery_exists(
  self : PythonExecutor,
  args : Array[Value],
) -> Value raise {
  let table = self.subquery_table(args[0], args[1], args[2:].to_owned())
  Bool(!table.rows.is_empty())
}

///|
fn PythonExecutor::subquery_scalar(
  self : PythonExecutor,
  args : Array[Value],
) -> Value raise {
  let rows = self.subquery_table(args[0], args[1], args[2:].to_owned()).rows
  if rows.length() > 1 {
    raise ExecuteError(
      "More than one row returned by a subquery used as an expression",
      cause=None,
    )
  }
  if rows.is_empty() {
    Null
  } else {
    rows[0][0]
  }
}

///|
fn PythonExecutor::subquery_comparison(
  self : PythonExecutor,
  args : Array[Value],
) -> Value raise {
  let value = args[0]
  let op = match args[3] {
    Str(s) => s
    v => v.py_str()
  }
  let compare = match self.env.get(op) {
    Some(f) => f
    None => raise PyException("KeyError", @core.py_repr_str(op))
  }
  let is_any = args[4] is Str("ANY")
  let mut saw_null = false
  for row in self.subquery_table(args[1], args[2], args[5:].to_owned()).rows {
    let result = call_value(compare, [value, row[0]])
    if result is Null {
      saw_null = true
    } else if result.truthy() == is_any {
      return Bool(is_any)
    }
  }
  if saw_null {
    Null
  } else {
    Bool(!is_any)
  }
}

///|
/// Python `PythonExecutor.context(tables)`.
pub fn PythonExecutor::context(
  self : PythonExecutor,
  tables : Array[(String?, Table)],
) -> Context {
  Context::new(tables, env=self.env, outer?=self.outer_scope)
}

///|
fn table_of_exprs(expressions : Array[@core.Expr]) -> Table {
  Table::new(columns=expressions.map(e => e.alias_or_name()))
}

///|
/// An iterator over row readers (Python generators / `TableIter`).
priv struct RowIter {
  next : () -> RowReader? raise
}

///|
fn PythonExecutor::scan(
  self : PythonExecutor,
  step : @planner.Step,
  context : Context,
) -> Context raise {
  let source : String? = match step.source {
    Some(s) => {
      let n = s.name()
      Some(if n != "" { n } else { s.alias_() })
    }
    None => None
  }
  let (context, table_iter) = match source {
    None => self.static_()
    Some(src) if context.contains(Some(src)) => {
      if step.projections.is_empty() && step.condition is None {
        return self.context([(step.name, context.get_table(Some(src)))])
      }
      let it = context.table_iter(Some(src))
      (context, { next: () => it.next(), })
    }
    Some(_) => self.scan_table(step)
  }
  self.context([(step.name, self.project_and_filter(context, step, table_iter))])
}

///|
fn PythonExecutor::project_and_filter(
  self : PythonExecutor,
  context : Context,
  step : @planner.Step,
  table_iter : RowIter,
) -> Table raise {
  let sink = if step.projections.is_empty() {
    Table::new(columns=context.columns())
  } else {
    table_of_exprs(step.projections)
  }
  let condition = self.generate(step.condition)
  let projections = self.generate_tuple(step.projections)
  while (table_iter.next)() is Some(reader) {
    match step.limit {
      Some(limit) =>
        if sink.length().to_int64() >= sat_add64(step.offset, limit) {
          break
        }
      None => ()
    }
    match condition {
      Some(c) => if !context.eval(c).truthy() { continue }
      None => ()
    }
    if !projections.is_empty() {
      sink.append(context.eval_tuple(projections))
    } else {
      sink.append(reader.row)
    }
  }
  sink
}

///|
fn PythonExecutor::static_(self : PythonExecutor) -> (Context, RowIter) {
  let mut done = false
  let reader = RowReader::new(columns=[])
  (
    self.context([]),
    {
      next: () => {
        if done {
          None
        } else {
          done = true
          Some(reader)
        }
      },
    },
  )
}

///|
fn PythonExecutor::scan_table(
  self : PythonExecutor,
  step : @planner.Step,
) -> (Context, RowIter) raise {
  let source = step.source.unwrap()
  guard self.tables.find(source) is Some(table) else {
    raise PyException(
      "AttributeError", "'NoneType' object has no attribute 'range_reader'",
    )
  }
  let context = self.context([(Some(source.alias_or_name()), table)])
  let index = Ref(-1)
  (
    context,
    {
      next: () => {
        index.val += 1
        if index.val < table.rows.length() {
          Some(table.get_row(index.val))
        } else {
          None
        }
      },
    },
  )
}

///|
/// Iterates a context like Python's `(reader for reader, _ in iter(context))`.
fn context_iter(context : Context) -> RowIter {
  let mut started = false
  let mut i = 0
  let mut n = 0
  {
    next: () => {
      if !started {
        started = true
        context.scope = Readers(context.row_readers)
        n = context.table().rows.length()
      }
      if i >= n {
        return None
      }
      let mut reader : RowReader? = None
      for kv in context.tables {
        reader = Some(kv.1.get_row(i))
      }
      i += 1
      reader
    },
  }
}

///|
fn PythonExecutor::join(
  self : PythonExecutor,
  step : @planner.Step,
  context : Context,
) -> Context raise {
  let source = step.source_name
  let source_table = context.get_table(source)
  let mut source_context = self.context([(source, source_table)])
  let column_ranges : Array[(String?, (Int, Int))] = [
    (source, (0, source_table.columns.length())),
  ]
  for entry in step.joins {
    let (name, join) = entry
    let name = Some(name)
    let table = context.get_table(name)
    let mut start = 0
    for r in column_ranges {
      if r.1.1 > start {
        start = r.1.1
      }
    }
    set_range_entry(
      column_ranges,
      name,
      (start, table.columns.length() + start),
    )
    let join_context = self.context([(name, table)])
    let condition = self.generate(Some(join.condition))
    let condition_context = match condition {
      Some(_) => {
        let combined = source_context.columns() + join_context.columns()
        Some(
          self.context(
            column_ranges.map(r => {
              (r.0, Table::new(columns=combined, column_range=r.1))
            }),
          ),
        )
      }
      None => None
    }
    let table = if !join.source_key.is_empty() {
      self.hash_join(
        join, source_context, join_context, condition, condition_context,
      )
    } else {
      self.nested_loop_join(
        join, source_context, join_context, condition, condition_context,
      )
    }
    source_context = self.context(
      column_ranges.map(r => {
        (
          r.0,
          Table::new(columns=table.columns, rows=table.rows, column_range=r.1),
        )
      }),
    )
  }
  if step.condition is None && step.projections.is_empty() {
    return source_context
  }
  let sink = self.project_and_filter(
    source_context,
    step,
    context_iter(source_context),
  )
  if !step.projections.is_empty() {
    self.context([(step.name, sink)])
  } else {
    self.context(
      source_context.tables.map(kv => {
        (
          kv.0,
          Table::new(
            columns=kv.1.columns,
            rows=sink.rows,
            column_range?=kv.1.column_range,
          ),
        )
      }),
    )
  }
}

///|
fn set_range_entry(
  ranges : Array[(String?, (Int, Int))],
  name : String?,
  r : (Int, Int),
) -> Unit {
  for i, e in ranges {
    if e.0 == name {
      ranges[i] = (name, r)
      return
    }
  }
  ranges.push((name, r))
}

///|
fn join_matches(
  row : Row,
  condition : Code?,
  condition_context : Context?,
) -> Bool raise {
  guard condition is Some(c) else { return true }
  let ctx = condition_context.unwrap()
  ctx.set_row(row)
  ctx.eval(c) is Bool(true)
}

///|
fn PythonExecutor::nested_loop_join(
  _self : PythonExecutor,
  join : @planner.JoinInfo,
  source_context : Context,
  join_context : Context,
  condition : Code?,
  condition_context : Context?,
) -> Table raise {
  let table = Table::new(
    columns=source_context.columns() + join_context.columns(),
  )
  let source_rows = source_context.table().rows
  let join_rows = join_context.table().rows
  let matched_source : Map[Int, Unit] = Map([])
  let matched_join : Map[Int, Unit] = Map([])
  for source_index, source_row in source_rows {
    for join_index, join_row in join_rows {
      let row = source_row + join_row
      if join_matches(row, condition, condition_context) {
        table.append(row)
        matched_source[source_index] = ()
        matched_join[join_index] = ()
      }
    }
  }
  append_unmatched_join_rows(
    table, join, source_rows, join_rows, matched_source, matched_join,
  )
  table
}

///|
fn PythonExecutor::hash_join(
  self : PythonExecutor,
  join : @planner.JoinInfo,
  source_context : Context,
  join_context : Context,
  condition : Code?,
  condition_context : Context?,
) -> Table raise {
  let source_key = self.generate_tuple(join.source_key)
  let join_key = self.generate_tuple(join.join_key)
  let groups : Map[String, Int] = Map([])
  let results : Array[(Array[(Int, Row)], Array[(Int, Row)])] = []
  fn group_of(key : Array[Value]) -> Int raise {
    let k = hash_key(Tuple(key))
    match groups.get(k) {
      Some(g) => g
      None => {
        let g = results.length()
        groups[k] = g
        results.push(([], []))
        g
      }
    }
  }

  let mut index = 0
  source_context.each(reader => {
    let key = source_context.eval_tuple(source_key)
    if key.iter().all(v => !(v is Null)) {
      results[group_of(key)].0.push((index, reader.row))
    }
    index += 1
  })
  index = 0
  join_context.each(reader => {
    let key = join_context.eval_tuple(join_key)
    if key.iter().all(v => !(v is Null)) {
      results[group_of(key)].1.push((index, reader.row))
    }
    index += 1
  })
  let table = Table::new(
    columns=source_context.columns() + join_context.columns(),
  )
  let matched_source : Map[Int, Unit] = Map([])
  let matched_join : Map[Int, Unit] = Map([])
  for group in results {
    let (source_group, join_group) = group
    for s in source_group {
      for j in join_group {
        let row = s.1 + j.1
        if join_matches(row, condition, condition_context) {
          table.append(row)
          matched_source[s.0] = ()
          matched_join[j.0] = ()
        }
      }
    }
  }
  append_unmatched_join_rows(
    table,
    join,
    source_context.table().rows,
    join_context.table().rows,
    matched_source,
    matched_join,
  )
  table
}

///|
fn append_unmatched_join_rows(
  table : Table,
  join : @planner.JoinInfo,
  source_rows : Array[Row],
  join_rows : Array[Row],
  matched_source : Map[Int, Unit],
  matched_join : Map[Int, Unit],
) -> Unit raise {
  let side = join.side
  if side == "LEFT" || side == "FULL" {
    let width = if source_rows.is_empty() {
      0
    } else {
      table.columns.length() - source_rows[0].length()
    }
    let join_nulls = Array::make(if width > 0 { width } else { 0 }, Null)
    for index, row in source_rows {
      if !matched_source.contains(index) {
        table.append(row + join_nulls)
      }
    }
  }
  if side == "RIGHT" || side == "FULL" {
    let source_width = table.columns.length() -
      (if join_rows.is_empty() { 0 } else { join_rows[0].length() })
    let source_nulls = Array::make(
      if source_width > 0 {
        source_width
      } else {
        0
      },
      Null,
    )
    for index, row in join_rows {
      if !matched_join.contains(index) {
        table.append(source_nulls + row)
      }
    }
  }
}

///|
fn PythonExecutor::aggregate(
  self : PythonExecutor,
  step : @planner.Step,
  context : Context,
) -> Context raise {
  let group_by = self.generate_tuple(step.group.map(kv => kv.1))
  let aggregations = self.generate_tuple(step.aggregations)
  let operands = self.generate_tuple(step.operands)
  let mut context = context
  if !operands.is_empty() {
    let operand_table = Table::new(
      columns=table_of_exprs(step.operands).columns,
    )
    let ctx = context
    ctx.each(_ => operand_table.append(ctx.eval_tuple(operands)))
    let rows = context.table().rows
    let n = @cmp.minimum(rows.length(), operand_table.rows.length())
    for i in 0..<n {
      rows[i] = rows[i] + operand_table.rows[i]
    }
    let width = context.columns().length()
    context.add_columns(operand_table.columns)
    let operand_table = Table::new(
      columns=context.columns(),
      rows=context.table().rows,
      column_range=(width, width + operand_table.columns.length()),
    )
    context = self.context([(None, operand_table)] + context.tables)
  }
  context.sort(group_by)
  let mut group : Array[Value]? = None
  let mut start = 0
  let mut end = 1
  let length = context.table().rows.length()
  let table = Table::new(
    columns=step.group.map(kv => kv.0) +
      step.aggregations.map(e => e.alias_or_name()),
  )
  let ctx = context
  fn add_row(group : Array[Value]) -> Unit raise {
    table.append(group + ctx.eval_tuple(aggregations))
  }

  if length > 0 {
    for i in 0..<length {
      ctx.set_index(i)
      let key = ctx.eval_tuple(group_by)
      let g = match group {
        None => key
        Some(g) => g
      }
      group = Some(g)
      end += 1
      if !seq_eq(key, g) {
        ctx.set_range(start, end - 2)
        add_row(g)
        group = Some(key)
        start = end - 2
      }
      if step.condition is None {
        match step.limit {
          Some(limit) =>
            if table.rows.length().to_int64() >= sat_add64(step.offset, limit) {
              break
            }
          None => ()
        }
      }
      if i == length - 1 {
        ctx.set_range(start, end - 1)
        add_row(group.unwrap())
      }
    }
  } else if (match step.limit {
      Some(l) => l > 0L
      None => true
    }) &&
    group_by.is_empty() {
    ctx.set_range(0, 0)
    table.append(ctx.eval_tuple(aggregations))
  }
  let tables : Array[(String?, Table)] = [(step.name, table)]
  for kv in ctx.tables {
    tables.push((kv.0, table))
  }
  let context = self.context(tables)
  if !step.projections.is_empty() || step.condition is Some(_) {
    let it = context.table_iter(step.name)
    return self.context([
      (
        step.name,
        self.project_and_filter(context, step, { next: () => it.next(), }),
      ),
    ])
  }
  context
}

///|
fn PythonExecutor::sort(
  self : PythonExecutor,
  step : @planner.Step,
  context : Context,
) -> Context raise {
  let projections = self.generate_tuple(step.projections)
  let projection_columns = step.projections.map(p => p.alias_or_name())
  let context_columns = context.columns()
  let all_columns = context_columns + projection_columns
  let sink = Table::new(columns=all_columns)
  context.each(reader => {
    sink.append(reader.row + context.eval_tuple(projections))
  })
  let tables : Array[(String?, Table)] = [(None, sink)]
  for kv in context.tables {
    tables.push((kv.0, sink))
  }
  let sort_ctx = self.context(tables)
  sort_ctx.sort(self.generate_tuple(step.key))
  match step.limit {
    Some(limit) =>
      sort_ctx.table().rows = slice_rows(
        sort_ctx.table().rows,
        0,
        Some(clamp_int(sat_add64(step.offset, limit))),
      )
    None => ()
  }
  let mut rows = sort_ctx.table().rows
  if !projection_columns.is_empty() {
    rows = rows.map(row => {
      slice_values(row, context_columns.length(), all_columns.length())
    })
  }
  let output = Table::new(
    columns=if projection_columns.is_empty() {
      context_columns
    } else {
      projection_columns
    },
    rows~,
  )
  self.context([(step.name, output)])
}

///|
fn slice_values(row : Row, start : Int, end : Int) -> Row {
  let n = row.length()
  let s = @cmp.minimum(start, n)
  let e = @cmp.maximum(s, @cmp.minimum(end, n))
  row[s:e].to_owned()
}

///|
fn PythonExecutor::set_operation(
  self : PythonExecutor,
  step : @planner.Step,
  context : Context,
) -> Context raise {
  let left = context.get_table(Some(step.left))
  let right = context.get_table(Some(step.right))
  let sink = Table::new(columns=left.columns)
  let op = step.op.unwrap()
  if op.is_a(Intersect) || op.is_a(Except) {
    let right_counts : Map[String, Int] = Map([])
    for row in right.rows {
      let k = hash_key(Tuple(row))
      right_counts[k] = right_counts.get(k).unwrap_or(0) + 1
    }
    let seen : Map[String, Unit] = Map([])
    for row in left.rows {
      let k = hash_key(Tuple(row))
      let count = right_counts.get(k).unwrap_or(0)
      if op.is_a(Intersect) {
        if count != 0 && (!step.distinct || !seen.contains(k)) {
          sink.append(row)
          seen[k] = ()
          if !step.distinct {
            right_counts[k] = count - 1
          }
        }
      } else if count != 0 && !step.distinct {
        right_counts[k] = count - 1
      } else if count == 0 && (!step.distinct || !seen.contains(k)) {
        sink.append(row)
        seen[k] = ()
      }
    }
  } else if op.is_a(Union) && step.distinct {
    sink.rows = py_set_union(
      left.rows.map(r => Tuple(r)),
      right.rows.map(r => Tuple(r)),
    ).map(t => {
      match t {
        Tuple(r) => r
        _ => []
      }
    })
  } else {
    sink.rows = left.rows + right.rows
  }
  match step.limit {
    Some(limit) =>
      sink.rows = slice_rows(
        sink.rows,
        0,
        Some(clamp_int(sat_add64(step.offset, limit))),
      )
    None => ()
  }
  self.context([(step.name, sink)])
}
