// Port of sqlglot/planner.py.

///|
pub(all) enum StepKind {
  Scan
  Join
  Aggregate
  Sort
  SetOperation
} derive(Eq, Debug)

///|
/// The join information of a Join step.
pub struct JoinInfo {
  side : String
  join_key : Array[@core.Expr]
  source_key : Array[@core.Expr]
  condition : @core.Expr
}

///|
/// A step of an execution plan.
pub struct Step {
  uid : Int
  kind : StepKind
  mut name : String?
  dependencies : Array[Step]
  dependents : Array[Step]
  mut projections : Array[@core.Expr]
  /// `None` means no limit (Python `math.inf`)
  mut limit : Int64?
  mut offset : Int64
  mut condition : @core.Expr?
  // Scan
  mut source : @core.Expr?
  // Join
  mut source_name : String?
  joins : Array[(String, JoinInfo)]
  // Aggregate
  mut aggregations : Array[@core.Expr]
  mut operands : Array[@core.Expr]
  mut group : Array[(String, @core.Expr)]
  mut agg_source : String?
  // Sort
  mut key : Array[@core.Expr]
  // SetOperation
  op : @core.Kind?
  left : String
  right : String
  distinct : Bool
}

///|
let step_counter : Ref[Int] = Ref(0)

///|
fn Step::new(
  kind : StepKind,
  op? : @core.Kind,
  left? : String = "",
  right? : String = "",
  distinct? : Bool = false,
) -> Step {
  step_counter.val += 1
  {
    uid: step_counter.val,
    kind,
    name: None,
    dependencies: [],
    dependents: [],
    projections: [],
    limit: None,
    offset: 0L,
    condition: None,
    source: None,
    source_name: None,
    joins: [],
    aggregations: [],
    operands: [],
    group: [],
    agg_source: None,
    key: [],
    op,
    left,
    right,
    distinct,
  }
}

///|
pub fn Step::add_dependency(self : Step, dependency : Step) -> Unit {
  if !self.dependencies.iter().any(d => physical_equal(d, dependency)) {
    self.dependencies.push(dependency)
  }
  if !dependency.dependents.iter().any(d => physical_equal(d, self)) {
    dependency.dependents.push(self)
  }
}

///|
pub fn Step::type_name(self : Step) -> String {
  match self.kind {
    Scan => "Scan"
    Join => "Join"
    Aggregate => "Aggregate"
    Sort => "Sort"
    SetOperation =>
      match self.op {
        Some(k) => k.name()
        None => "SetOperation"
      }
  }
}

///|
/// `Step.id`: e.g. `Scan: x (12)`.
pub fn Step::id(self : Step) -> String {
  let name = match self.name {
    Some(n) if n != "" => " " + n
    _ => ""
  }
  "\{self.type_name()}:\{name} (\{self.uid})"
}

///|
fn sql(e : @core.Expr) -> String {
  @core.expr_to_sql(e) catch {
    _ => e.kind.name()
  }
}

///|
fn Step::context_lines(self : Step, indent : String) -> Array[String] {
  match self.kind {
    Scan => {
      let src = match self.source {
        Some(s) => sql(s)
        None => "-static-"
      }
      ["\{indent}Source: \{src}"]
    }
    Join => {
      let src = match self.source_name {
        Some(s) if s != "" => s
        _ => self.name.unwrap_or("")
      }
      let lines = ["\{indent}Source: \{src}"]
      for kv in self.joins {
        let (name, join) = kv
        let side = if join.side == "" { "INNER" } else { join.side }
        lines.push("\{indent}\{name}: \{side}")
        let join_key = join.join_key.map(sql).join(", ")
        if join_key != "" {
          lines.push("\{indent}Key: \{join_key}")
        }
        lines.push("\{indent}On: \{sql(join.condition)}")
      }
      lines
    }
    Aggregate => {
      let lines = ["\{indent}Aggregations:"]
      for e in self.aggregations {
        lines.push("\{indent}  - \{sql(e)}")
      }
      if !self.group.is_empty() {
        lines.push("\{indent}Group:")
        for kv in self.group {
          lines.push("\{indent}  - \{sql(kv.1)}")
        }
      }
      match self.condition {
        Some(c) => {
          lines.push("\{indent}Having:")
          lines.push("\{indent}  - \{sql(c)}")
        }
        None => ()
      }
      if !self.operands.is_empty() {
        lines.push("\{indent}Operands:")
        for e in self.operands {
          lines.push("\{indent}  - \{sql(e)}")
        }
      }
      lines
    }
    Sort => {
      let lines = ["\{indent}Key:"]
      for e in self.key {
        lines.push("\{indent}  - \{sql(e)}")
      }
      lines
    }
    SetOperation =>
      if self.distinct {
        ["\{indent}Distinct: True"]
      } else {
        []
      }
  }
}

///|
/// A readable representation of the step and its dependencies.
pub fn Step::to_s(self : Step, level? : Int = 0) -> String {
  let indent = "  ".repeat(level)
  let nested = indent + "    "
  let context = self.context_lines(nested + "  ")
  let lines = ["\{indent}- \{self.id()}"]
  if !context.is_empty() {
    lines.push("\{nested}Context:")
    for c in context {
      lines.push(c)
    }
  }
  lines.push("\{nested}Projections:")
  for e in self.projections {
    lines.push("\{nested}  - \{sql(e)}")
  }
  if self.kind != Aggregate {
    match self.condition {
      Some(c) => lines.push("\{nested}Condition: \{sql(c)}")
      None => ()
    }
  } else {
    match self.condition {
      Some(c) => lines.push("\{nested}Condition: \{sql(c)}")
      None => ()
    }
  }
  match self.limit {
    Some(l) => lines.push("\{nested}Limit: \{l}")
    None => ()
  }
  if self.offset != 0L {
    lines.push("\{nested}Offset: \{self.offset}")
  }
  if !self.dependencies.is_empty() {
    lines.push("\{nested}Dependencies:")
    for d in self.dependencies {
      lines.push("  " + d.to_s(level=level + 1))
    }
  }
  lines.join("\n")
}

///|
/// An execution plan: a DAG of steps.
pub struct Plan {
  expression : @core.Expr
  ctes : @core.Expr?
  root : Step
}

///|
pub fn Plan::new(expression : @core.Expr) -> Plan raise @core.SqlglotError {
  let expression = expression.copy()
  let ctes = expression.arg("with_").map(w => w.copy())
  { expression, ctes, root: step_from_expression(expression, {}) }
}

///|
/// The plan's DAG: each step and its dependencies.
pub fn Plan::dag(self : Plan) -> Array[(Step, Array[Step])] {
  let dag : Array[(Step, Array[Step])] = []
  let nodes = [self.root]
  while nodes.pop() is Some(node) {
    if dag.iter().any(e => physical_equal(e.0, node)) {
      continue
    }
    dag.push((node, node.dependencies.copy()))
    for dep in node.dependencies {
      nodes.push(dep)
    }
  }
  dag
}

///|
/// Steps without dependencies.
pub fn Plan::leaves(self : Plan) -> Array[Step] {
  self.dag().filter(e => e.1.is_empty()).map(e => e.0)
}

///|
pub fn Plan::to_string(self : Plan) -> String {
  "Plan\n----\n\{self.root.to_s()}"
}

///|
fn assoc_find(m : Array[(@core.Expr, String)], k : @core.Expr) -> String? {
  for kv in m {
    if kv.0 == k {
      return Some(kv.1)
    }
  }
  None
}

///|
/// Builds a DAG of Steps from a SQL expression (tables and subqueries must be aliased).
pub fn step_from_expression(
  expression : @core.Expr,
  ctes : Map[String, Step],
) -> Step raise @core.SqlglotError {
  let mut ctes = ctes
  let expression = expression.unnest()
  match expression.arg("with_") {
    Some(with_) => {
      ctes = ctes.copy()
      for cte in with_.expressions() {
        let step = step_from_expression(cte.this_(), ctes)
        step.name = Some(cte.alias_())
        ctes[cte.alias_()] = step
      }
    }
    None => ()
  }
  let mut step = match expression.arg("from_") {
    Some(from_) if expression.kind.is_a(Select) =>
      scan_from_expression(from_.this_(), ctes)
    _ =>
      if expression.kind.is_a(SetOperation) {
        set_operation_from_expression(expression, ctes)
      } else {
        Step::new(Scan)
      }
  }
  match expression.get("joins") {
    Some(List(_)) => {
      let join = join_from_joins(expression.list("joins"), ctes)
      join.name = step.name
      join.source_name = step.name
      join.add_dependency(step)
      step = join
    }
    _ => ()
  }
  let mut projections : Array[@core.Expr] = []
  let operands : Array[(@core.Expr, String)] = []
  let aggregations : Array[@core.Expr] = []
  let next_operand_name = @core.name_sequence("_a_")
  fn extract_agg_operands(expression : @core.Expr) -> Bool {
    let agg_funcs = @optimizer.find_all_in_scope(expression, [AggFunc]).collect()
    if !agg_funcs.is_empty() && !aggregations.contains(expression) {
      aggregations.push(expression)
    }
    for agg in agg_funcs {
      for operand in agg.unnest_operands() {
        let targets = if operand.kind.is_a(Distinct) {
          operand.expressions()
        } else {
          [operand]
        }
        for target in targets {
          if target.kind.is_a(Column) {
            continue
          }
          let name = match assoc_find(operands, target) {
            Some(n) => n
            None => {
              let n = next_operand_name()
              operands.push((target, n))
              n
            }
          }
          target.replace(
            Some(@core.mk1(Column, @core.to_identifier(name, quoted=true))),
          )
          |> ignore
        }
      }
    }
    !agg_funcs.is_empty()
  }

  fn set_ops_and_aggs(step : Step) {
    step.operands = operands.map(kv => @core.alias_(kv.0, kv.1))
    step.aggregations = aggregations.copy()
  }

  fn column_of(name : String, table : String?, quoted : Bool) -> @core.Expr {
    let q = if quoted { Some(true) } else { None }
    @core.mk(Column, [
      ("this", @core.to_identifier(name, quoted?=q)),
      ("table", table.map(t => @core.to_identifier(t, quoted?=q))),
    ])
  }

  for e in expression.expressions() {
    if @optimizer.find_in_scope(e, [AggFunc]) is Some(_) {
      projections.push(column_of(e.alias_or_name(), step.name, true))
      extract_agg_operands(e) |> ignore
    } else {
      projections.push(e)
    }
  }
  match expression.arg("where") {
    Some(w) => step.condition = w.this()
    None => ()
  }
  let group = expression.arg("group")
  let mut aggregate : Step? = None
  if group is Some(_) || !aggregations.is_empty() {
    let agg = Step::new(Aggregate)
    agg.agg_source = step.name
    agg.name = step.name
    match expression.arg("having") {
      Some(having) =>
        if extract_agg_operands(
            @core.alias_(having.this_(), "_h", quoted=true),
          ) {
          agg.condition = Some(column_of("_h", step.name, true))
        } else {
          agg.condition = having.this()
        }
      None => ()
    }
    set_ops_and_aggs(agg)
    let group_exprs = match group {
      Some(g) => g.expressions()
      None => []
    }
    agg.group = group_exprs.mapi((i, e) => ("_g\{i}", e))
    let intermediate_exprs : Array[(@core.Expr, String)] = []
    let intermediate_names : Map[String, String] = Map([])
    for kv in agg.group {
      let (k, v) = kv
      intermediate_exprs.push((v, k))
      if v.kind.is_a(Column) {
        intermediate_names[v.name()] = k
      }
    }
    let lookup = fn(node : @core.Expr) -> String? {
      // the latest assignment wins, as in a Python dict
      let mut found : String? = None
      for kv in intermediate_exprs {
        if kv.0 == node {
          found = Some(kv.1)
        }
      }
      found
    }
    for projection in projections {
      let it = projection.walk()
      while it.next() is Some(node) {
        match lookup(node) {
          Some(name) if name != "" =>
            node.replace(Some(column_of(name, step.name, false))) |> ignore
          _ => ()
        }
      }
    }
    match agg.condition {
      Some(c) => {
        let it = c.walk()
        while it.next() is Some(node) {
          let name = match lookup(node) {
            Some(n) if n != "" => Some(n)
            _ => intermediate_names.get(node.name())
          }
          match name {
            Some(n) if n != "" =>
              node.replace(Some(column_of(n, step.name, false))) |> ignore
            _ => ()
          }
        }
      }
      None => ()
    }
    agg.add_dependency(step)
    step = agg
    aggregate = Some(agg)
  }
  let mut distinct : Step? = None
  if expression.kind.is_a(Select) && expression.has("distinct") {
    let d = Step::new(Aggregate)
    d.agg_source = step.name
    d.name = step.name
    let source_exprs = if projections.is_empty() {
      expression.expressions()
    } else {
      projections
    }
    let g : Array[(String, @core.Expr)] = []
    for e in source_exprs {
      let name = e.alias_or_name()
      let mut replaced = false
      for i, kv in g {
        if kv.0 == name {
          g[i] = (name, e.unalias())
          replaced = true
        }
      }
      if !replaced {
        g.push((name, e.unalias()))
      }
    }
    d.group = g
    projections = g.map(kv => column_of(kv.0, step.name, true))
    d.add_dependency(step)
    step = d
    distinct = Some(d)
  }
  match expression.arg("order") {
    Some(order) => {
      match aggregate {
        Some(agg) => {
          for i, ordered in order.expressions() {
            if extract_agg_operands(
                @core.alias_(ordered.this_(), "_o_\{i}", quoted=true),
              ) {
              ordered
              .this_()
              .replace(Some(column_of("_o_\{i}", agg.name, true)))
              |> ignore
            }
          }
          set_ops_and_aggs(agg)
        }
        None => ()
      }
      match distinct {
        Some(d) =>
          for i, ordered in order.expressions() {
            let mut key = ordered.this_()
            let mut group_name : String? = None
            for kv in d.group {
              if kv.1 == key {
                group_name = Some(kv.0)
                break
              }
            }
            match group_name {
              Some(gn) if gn != "" => {
                key.replace(Some(column_of(gn, step.name, true))) |> ignore
                continue
              }
              _ => ()
            }
            if key.kind.is_a(Column) &&
              key.table_name() == "" &&
              d.group.iter().any(kv => kv.0 == key.name()) {
              continue
            }
            key = key.copy()
            let to_replace = key
              .walk()
              .filter(n => n.kind.is_a(Column) &&
                n.table_name() == "" &&
                d.group.iter().any(kv => kv.0 == n.name()))
              .collect()
            for node in to_replace {
              for kv in d.group {
                if kv.0 == node.name() {
                  node.replace(Some(kv.1.copy())) |> ignore
                  break
                }
              }
            }
            if !key.kind.is_a(Column) {
              d.operands = d.operands + [@core.alias_(key, "_a_\{i}")]
              key = @core.mk1(Column, @core.to_identifier("_a_\{i}", quoted=true))
            }
            d.aggregations.push(
              @core.alias_(@core.mk1(First, key), "_o_\{i}", quoted=true),
            )
            ordered
            .this_()
            .replace(Some(column_of("_o_\{i}", step.name, true)))
            |> ignore
          }
        None => ()
      }
      let sort = Step::new(Sort)
      sort.name = step.name
      sort.key = order.expressions()
      sort.add_dependency(step)
      step = sort
    }
    None => ()
  }
  step.projections = projections
  match expression.arg("limit") {
    Some(limit) =>
      step.limit = match @core.parse_int_checked(limit.text("expression")) {
        Some(v) => Some(v)
        None => raise @core.ValueError("invalid literal for int()")
      }
    None => ()
  }
  match expression.arg("offset") {
    Some(offset) =>
      step.offset = match @core.parse_int_checked(offset.text("expression")) {
        Some(v) => v
        None => raise @core.ValueError("invalid literal for int()")
      }
    None => ()
  }
  step
}

///|
fn scan_from_expression(
  expression : @core.Expr,
  ctes : Map[String, Step],
) -> Step raise @core.SqlglotError {
  let alias_ = expression.alias_or_name()
  if expression.kind.is_a(Subquery) {
    let step = step_from_expression(expression.this_(), ctes)
    step.name = Some(alias_)
    return step
  }
  let step = Step::new(Scan)
  step.name = Some(alias_)
  step.source = Some(expression)
  match ctes.get(expression.name()) {
    Some(cte) => step.add_dependency(cte)
    None => ()
  }
  step
}

///|
fn join_from_joins(
  joins : Array[@core.Expr],
  ctes : Map[String, Step],
) -> Step raise @core.SqlglotError {
  let step = Step::new(Join)
  for join in joins {
    let (source_key, join_key, condition) = @optimizer.join_condition(join)
    let name = join.alias_or_name()
    let info : JoinInfo = {
      side: @core.py_upper(join.text("side")),
      join_key,
      source_key,
      condition,
    }
    let mut replaced = false
    for i, kv in step.joins {
      if kv.0 == name {
        step.joins[i] = (name, info)
        replaced = true
      }
    }
    if !replaced {
      step.joins.push((name, info))
    }
    step.add_dependency(scan_from_expression(join.this_(), ctes))
  }
  step
}

///|
fn set_operation_from_expression(
  expression : @core.Expr,
  ctes : Map[String, Step],
) -> Step raise @core.SqlglotError {
  let left = step_from_expression(expression.this_(), ctes)
  if left.name.unwrap_or("") == "" {
    left.name = Some("left")
  }
  let right = step_from_expression(expression.expression_(), ctes)
  if right.name.unwrap_or("") == "" {
    right.name = Some("right")
  }
  let step = Step::new(
    SetOperation,
    op=expression.kind,
    left=left.name.unwrap(),
    right=right.name.unwrap(),
    distinct=expression.has("distinct"),
  )
  step.add_dependency(left)
  step.add_dependency(right)
  step
}
