// Generator methods for queries: SELECT, set operations, CTEs, joins, modifiers.

///|
/// The `@unsupported_args(...)` decorator check.
pub fn Generator::unsupported_args(
  self : Generator,
  expression : Expr,
  args : Array[String],
) -> Unit raise SqlglotError {
  for arg_name in args {
    if expression.has(arg_name) {
      self.unsupported(
        "Argument '\{arg_name}' is not supported for expression '\{expression.kind.name()}' when targeting \{self.dialect_class_name()}.",
      )
    }
  }
}

///|
pub fn Generator::prepend_ctes(
  self : Generator,
  expression : Expr,
  sql : String,
) -> String raise SqlglotError {
  let with_ = self.sql_key(expression, "with_")
  if with_ != "" {
    with_ + self.sep() + sql
  } else {
    sql
  }
}

///|
pub fn Generator::with_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let udfs = g_pfx("WITH ", self.expressions(expression~, key="udfs", flat=true))
  let sql = self.expressions(expression~, flat=true)
  let recursive = g_when(
    self.cfg.cte_recursive_keyword_required && expression.has("recursive"),
    "RECURSIVE ",
  )
  let search = g_pfx(" ", self.sql_key(expression, "search"))
  let sql = if sql != "" { "WITH " + recursive + sql + search } else { "" }
  if udfs != "" && sql != "" {
    udfs + " " + sql
  } else {
    udfs + sql
  }
}

///|
pub fn Generator::cte_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.arg("alias") {
    Some(alias_) => alias_.add_comments(Some(expression.pop_comments()))
    None => ()
  }
  let alias_sql = self.sql_key(expression, "alias")
  let materialized = match expression.get("materialized") {
    Some(Bool(false)) => "NOT MATERIALIZED "
    Some(v) if v.truthy() => "MATERIALIZED "
    _ => ""
  }
  let key_expressions = g_around(
    " USING KEY (",
    self.expressions(expression~, key="key_expressions", flat=true),
    ")",
  )
  alias_sql + key_expressions + " AS " + materialized + self.wrap(expression)
}

///|
pub fn Generator::tablealias_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut alias_ = self.sql_key(expression, "this")
  let mut columns = g_around(
    "(",
    self.expressions(expression~, key="columns", flat=true),
    ")",
  )
  if columns != "" &&
    !self.cfg.supports_table_alias_columns &&
    !(self.cfg.supports_named_cte_columns &&
    (match expression.parent {
      Some(p) => p.kind.is_a(CTE)
      None => false
    })) {
    columns = ""
    self.unsupported("Named columns are not supported in table alias.")
  }
  if alias_ == "" && !self.dialect.cfg.unnest_column_only {
    alias_ = (self.next_name)()
  }
  alias_ + columns
}

// ---------------------------------------------------------------------------
// Set operations

///|
pub fn Generator::set_operation(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let op_type = expression.kind
  let op_name = py_upper(op_type.key())
  let mut distinct : Bool? = match expression.get("distinct") {
    Some(Bool(b)) => Some(b)
    Some(v) => Some(v.truthy())
    None => None
  }
  if distinct == Some(false) &&
    (op_type == Except || op_type == Intersect) &&
    !self.cfg.except_intersect_support_all_clause {
    self.unsupported("\{op_name} ALL is not supported")
  }
  let default_distinct = match
    self.dialect.cfg.set_op_distinct_by_default.get(op_type) {
    Some(d) => d
    None => None
  }
  if distinct is None {
    distinct = default_distinct
    if distinct is None {
      self.unsupported("\{op_name} requires DISTINCT or ALL to be specified")
    }
  }
  let distinct_or_all = if distinct == default_distinct {
    ""
  } else if distinct == Some(true) {
    " DISTINCT"
  } else {
    " ALL"
  }
  let parts = []
  let side = py_upper(expression.text("side"))
  if side != "" {
    parts.push(side)
  }
  let kind = py_upper(expression.text("kind"))
  if kind != "" {
    parts.push(kind)
  }
  let side_kind = g_pfx("", parts.join(" "))
  let side_kind = if side_kind != "" { side_kind + " " } else { "" }
  let by_name = g_when(expression.has("by_name"), " BY NAME")
  let on = g_around(
    " ON (",
    self.expressions(expression~, key="on", flat=true),
    ")",
  )
  side_kind + op_name + distinct_or_all + by_name + on
}

///|
/// Virtual `set_operations`.
pub fn Generator::set_operations(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.set_operations {
    Some(f) => f(self, expression)
    None => self.set_operations_base(expression)
  }
}

///|
pub fn Generator::set_operations_base(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !self.cfg.set_op_modifiers {
    if expression.has("limit") ||
      expression.has("order") ||
      expression.has("offset") {
      let sub = exp_subquery_of(expression, alias_="_l_0", copy=false)
      let select = self.move_ctes_to_top_level(
        exp_select_from([mk0(Star)], sub),
      )
      for arg in ["limit", "order", "offset"] {
        match expression.arg(arg) {
          Some(value) => select.set(arg, value.pop())
          None => ()
        }
      }
      return self.sql(Some(select))
    }
  }
  let sqls : Array[String] = []
  let stack : Array[BinItem] = [BNode(Some(expression))]
  while stack.pop() is Some(item) {
    match item {
      BNode(Some(node)) if node.kind.is_a(SetOperation) => {
        stack.push(BNode(node.arg("expression")))
        stack.push(
          BStr(
            self.maybe_comment(
              self.set_operation(node),
              comments?=node.comments,
              separated=true,
            ),
          ),
        )
        stack.push(BNode(node.arg("this")))
      }
      BNode(Some(node)) => {
        let mut node = node
        if !self.cfg.set_op_limits &&
          node.kind.is_a(Select) &&
          node.has("limit") {
          node = exp_subquery_of(node, copy=false)
          if !self.cfg.set_op_parenthesized_operands {
            node = exp_select_from([mk0(Star)], node)
          }
        }
        sqls.push(self.sql(Some(node)))
      }
      BNode(None) => sqls.push("")
      BStr(s) => sqls.push(s)
    }
  }
  let this = sqls.join(self.sep())
  let this = self.query_modifiers(expression, [this])
  self.prepend_ctes(expression, this)
}

// ---------------------------------------------------------------------------
// Limit / fetch / offset

///|
pub fn Generator::fetch_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let direction = match expression.get("direction") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let count = g_pfx(" ", self.sql_key(expression, "count"))
  let limit_options = self.sql_key(expression, "limit_options")
  let limit_options = if limit_options != "" {
    limit_options
  } else {
    " ROWS ONLY"
  }
  self.seg("FETCH") + direction + count + limit_options
}

///|
pub fn Generator::limitoptions_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let percent = g_when(expression.has("percent"), " PERCENT")
  let rows = g_when(expression.has("rows"), " ROWS")
  let mut with_ties = g_when(expression.has("with_ties"), " WITH TIES")
  if with_ties == "" && rows != "" {
    with_ties = " ONLY"
  }
  percent + rows + with_ties
}

///|
pub fn Generator::filter_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let where_ = py_strip(self.sql_key(expression, "expression"))
  this + " FILTER(" + where_ + ")"
}

///|
pub fn Generator::hint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !self.cfg.query_hints {
    self.unsupported("Hints are not supported")
    return ""
  }
  " /*+ " +
  py_strip(self.expressions(expression~, sep=self.cfg.query_hint_sep)) +
  " */"
}

///|
pub fn Generator::simplify_unless_literal(
  self : Generator,
  expression : Expr,
) -> Expr raise SqlglotError {
  if !expression.kind.is_a(Literal) {
    return gen_simplify(expression, self.dialect)
  }
  expression
}

///|
pub fn Generator::limit_sql(
  self : Generator,
  expression : Expr,
  top? : Bool = false,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let args = []
  for k in ["offset", "expression"] {
    match expression.arg(k) {
      Some(e) =>
        args.push(
          if self.cfg.limit_only_literals {
            self.simplify_unless_literal(e)
          } else {
            e
          },
        )
      None => ()
    }
  }
  let parts = []
  for e in args {
    parts.push(self.sql(Some(e)))
  }
  let mut args_sql = parts.join(", ")
  if top && args.iter().any(e => !e.is_number()) {
    args_sql = "(" + args_sql + ")"
  }
  let expressions = g_pfx(" BY ", self.expressions(expression~, flat=true))
  let limit_options = self.sql_key(expression, "limit_options")
  this +
  self.seg(if top { "TOP" } else { "LIMIT" }) +
  " " +
  args_sql +
  limit_options +
  expressions
}

///|
pub fn Generator::offset_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let value = match expression.arg("expression") {
    Some(v) =>
      Some(
        if self.cfg.limit_only_literals {
          self.simplify_unless_literal(v)
        } else {
          v
        },
      )
    None => None
  }
  let expressions = g_pfx(" BY ", self.expressions(expression~, flat=true))
  this + self.seg("OFFSET") + " " + self.sql(value) + expressions
}

// ---------------------------------------------------------------------------
// Tables

///|
/// Virtual `table_parts`.
pub fn Generator::table_parts(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.table_parts {
    Some(f) => f(self, expression)
    None => self.table_parts_base(expression)
  }
}

///|
pub fn Generator::table_parts_base(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let parts = []
  for k in ["catalog", "db", "this"] {
    match expression.get(k) {
      Some(v) => parts.push(self.sql_value(v))
      None => ()
    }
  }
  parts.join(".")
}

///|
/// Virtual `table_sql(expression, sep)`.
pub fn Generator::table_sql_v(
  self : Generator,
  expression : Expr,
  sep? : String = " AS ",
) -> String raise SqlglotError {
  match self.fns.hooks.table_sql {
    Some(f) => f(self, expression, sep)
    None => self.table_sql(expression, sep~)
  }
}

///|
pub fn Generator::table_sql(
  self : Generator,
  expression : Expr,
  sep? : String = " AS ",
) -> String raise SqlglotError {
  let mut table = self.table_parts(expression)
  let only = g_when(expression.has("only"), "ONLY ")
  let partition = g_pfx(" ", self.sql_key(expression, "partition"))
  let version = g_pfx(" ", self.sql_key(expression, "version"))
  let mut alias_ = g_pfx(sep, self.sql_key(expression, "alias"))
  let sample = self.sql_key(expression, "sample")
  let mut post_alias = ""
  let mut pre_alias = ""
  if self.dialect.cfg.alias_post_tablesample {
    pre_alias = sample
  } else {
    post_alias = sample
  }
  if self.dialect.cfg.alias_post_version {
    pre_alias = pre_alias + version
  } else {
    post_alias = post_alias + version
  }
  let hints = self.expressions(expression~, key="hints", sep=" ")
  let hints = if hints != "" && self.cfg.table_hints { " " + hints } else { "" }
  let pivots = self.expressions(expression~, key="pivots", sep="", flat=true)
  let joins = self.indent(
    self.expressions(expression~, key="joins", sep="", flat=true),
    skip_first=true,
  )
  let laterals = self.expressions(expression~, key="laterals", sep="")
  let mut file_format = self.sql_key(expression, "format")
  let pattern = self.sql_key(expression, "pattern")
  if file_format != "" {
    let pattern = g_pfx(", PATTERN => ", pattern)
    file_format = " (FILE_FORMAT => " + file_format + pattern + ")"
  } else if pattern != "" {
    file_format = " (PATTERN => " + pattern + ")"
  }
  let mut ordinality = ""
  if expression.has("ordinality") {
    ordinality = " WITH ORDINALITY" + alias_
    alias_ = ""
  }
  let when_ = self.sql_key(expression, "when")
  if when_ != "" {
    if self.cfg.historical_data_post_alias {
      alias_ = alias_ + " " + when_
    } else {
      table = table + " " + when_
    }
  }
  let changes = g_pfx(" ", self.sql_key(expression, "changes"))
  let rows_from = self.expressions(expression~, key="rows_from")
  if rows_from != "" {
    table = "ROWS FROM " + self.wrap_str(rows_from)
  }
  let indexed = match expression.get("indexed") {
    Some(v) =>
      if v.truthy() {
        " INDEXED BY " + self.sql_value(v)
      } else {
        " NOT INDEXED"
      }
    None => ""
  }
  only +
  table +
  changes +
  partition +
  file_format +
  pre_alias +
  alias_ +
  indexed +
  hints +
  pivots +
  post_alias +
  joins +
  laterals +
  ordinality
}

///|
pub fn Generator::tablefromrows_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let table = self.func("TABLE", [expression.get("this")])
  let alias_ = g_pfx(" AS ", self.sql_key(expression, "alias"))
  let sample = self.sql_key(expression, "sample")
  let pivots = self.expressions(expression~, key="pivots", sep="", flat=true)
  let joins = self.indent(
    self.expressions(expression~, key="joins", sep="", flat=true),
    skip_first=true,
  )
  table + alias_ + pivots + sample + joins
}

///|
/// Virtual `tablesample_sql(expression, tablesample_keyword)`.
pub fn Generator::tablesample_sql_v(
  self : Generator,
  expression : Expr,
  tablesample_keyword? : String,
) -> String raise SqlglotError {
  match self.fns.hooks.tablesample_sql {
    Some(f) => f(self, expression, tablesample_keyword)
    None => self.tablesample_sql(expression, tablesample_keyword?)
  }
}

///|
pub fn Generator::tablesample_sql(
  self : Generator,
  expression : Expr,
  tablesample_keyword? : String,
) -> String raise SqlglotError {
  let method_ = self.sql_key(expression, "method")
  let method_ = if method_ != "" && self.cfg.tablesample_with_method {
    method_ + " "
  } else {
    ""
  }
  let numerator = self.sql_key(expression, "bucket_numerator")
  let denominator = self.sql_key(expression, "bucket_denominator")
  let field = g_pfx(" ON ", self.sql_key(expression, "bucket_field"))
  let bucket = if numerator != "" {
    "BUCKET " + numerator + " OUT OF " + denominator + field
  } else {
    ""
  }
  let seed = g_around(
    " " + self.cfg.tablesample_seed_keyword + " (",
    self.sql_key(expression, "seed"),
    ")",
  )
  let mut size = self.sql_key(expression, "size")
  if size != "" && self.cfg.tablesample_size_is_rows {
    size = size + " ROWS"
  }
  let mut percent = self.sql_key(expression, "percent")
  if percent != "" && !self.dialect.cfg.tablesample_size_is_percent {
    percent = percent + " PERCENT"
  }
  let mut expr = bucket + percent + size
  if self.cfg.tablesample_requires_parens {
    expr = "(" + expr + ")"
  }
  let keyword = match tablesample_keyword {
    Some(k) if k != "" => k
    _ => self.cfg.tablesample_keywords
  }
  " " + keyword + " " + method_ + expr + seed
}

///|
fn g_value_bool_or(v : Value?, default : Bool) -> Bool {
  match v {
    Some(Bool(b)) => b
    Some(x) => x.truthy()
    None => default
  }
}

///|
/// Python `_pivot_in_value_aliases`.
pub fn Generator::pivot_in_value_aliases(
  self : Generator,
  expression : Expr,
) -> Array[Expr]? raise SqlglotError {
  let columns = expression.list("columns")
  let fields = expression.list("fields")
  if columns.is_empty() || fields.length() != 1 {
    return None
  }
  let pcfg = self.dialect.parser_cfg
  let tgt_identify_pivot_strings = pcfg.identify_pivot_strings
  let tgt_prefixed_pivot_columns = pcfg.prefixed_pivot_columns
  let tgt_pivot_column_naming = pcfg.pivot_column_naming
  let src_identify_pivot_strings = g_value_bool_or(
    expression.get("identify_pivot_strings"),
    tgt_identify_pivot_strings,
  )
  let src_prefixed_pivot_columns = g_value_bool_or(
    expression.get("prefixed_pivot_columns"),
    tgt_prefixed_pivot_columns,
  )
  let src_pivot_column_naming = match expression.get("pivot_column_naming") {
    Some(Str(s)) => s
    Some(v) => py_str_value(Some(v))
    None => tgt_pivot_column_naming
  }
  if src_identify_pivot_strings == tgt_identify_pivot_strings &&
    src_prefixed_pivot_columns == tgt_prefixed_pivot_columns &&
    src_pivot_column_naming == tgt_pivot_column_naming {
    return None
  }
  let in_exprs = fields[0].expressions()
  if in_exprs.is_empty() {
    return None
  }
  let step = columns.length() / in_exprs.length()
  let first_base = if src_identify_pivot_strings {
    expr_to_sql(in_exprs[0])
  } else {
    in_exprs[0].alias_or_name()
  }
  let first_stored = columns[0].name()
  if !first_stored.has_prefix(first_base) {
    return None
  }
  let suffix = g_str_from(first_stored, py_len(first_base))
  let target_has_suffix = (
      expression.expressions().length() > 1 ||
      tgt_pivot_column_naming != "agg_name_if_multiple"
    ) &&
    expression.expressions().iter().any(a => a.alias() != "")
  let source_has_suffix = suffix != ""
  let new_exprs = []
  let mut modified = false
  for val_idx, e in in_exprs {
    if e.kind.is_a(PivotAlias) {
      new_exprs.push(e)
      continue
    }
    let i = val_idx * step
    let stored_full = columns[i].name()
    let stored_value = if suffix != "" {
      substr(stored_full, 0, py_len(stored_full) - py_len(suffix))
    } else {
      stored_full
    }
    let target_value = if tgt_identify_pivot_strings {
      expr_to_sql(e)
    } else {
      e.alias_or_name()
    }
    if source_has_suffix && !target_has_suffix {
      new_exprs.push(
        mk(PivotAlias, [
          ("this", e),
          ("alias", to_identifier(stored_full, quoted=true)),
        ]),
      )
      modified = true
    } else if stored_value != target_value {
      new_exprs.push(
        mk(PivotAlias, [
          ("this", e),
          ("alias", to_identifier(stored_value, quoted=true)),
        ]),
      )
      modified = true
    } else {
      new_exprs.push(e)
    }
  }
  if modified {
    Some(new_exprs)
  } else {
    None
  }
}

///|
pub fn Generator::pivot_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, flat=true)
  let unpivot = expression.has("unpivot")
  let direction = if unpivot { "UNPIVOT" } else { "PIVOT" }
  let group = self.sql_key(expression, "group")
  if expression.has("this") {
    let this = self.sql_key(expression, "this")
    let sql = if expressions == "" {
      "UNPIVOT " + this
    } else {
      let on = self.seg("ON") + " " + expressions
      let into = self.sql_key(expression, "into")
      let into = if into != "" { self.seg("INTO") + " " + into } else { "" }
      let using_ = self.expressions(expression~, key="using", flat=true)
      let using_ = if using_ != "" {
        self.seg("USING") + " " + using_
      } else {
        ""
      }
      direction + " " + this + on + into + using_ + group
    }
    return self.prepend_ctes(expression, sql)
  }
  if !unpivot {
    match self.pivot_in_value_aliases(expression) {
      Some(new_field_exprs) =>
        expression.list("fields")[0].set("expressions", new_field_exprs)
      None => ()
    }
  }
  let mut alias_ = self.sql_key(expression, "alias")
  if alias_ != "" {
    alias_ = if self.cfg.pivot_alias_with_as {
      " AS " + alias_
    } else {
      " " + alias_
    }
  }
  let fields = self.expressions(
    expression~,
    key="fields",
    sep=" ",
    dynamic=true,
    new_line=true,
    skip_first=true,
    skip_last=true,
  )
  let nulls = match expression.get("include_nulls") {
    Some(v) => if v.truthy() { " INCLUDE NULLS " } else { " EXCLUDE NULLS " }
    None => ""
  }
  let default_on_null = g_around(
    " DEFAULT ON NULL (",
    self.sql_key(expression, "default_on_null"),
    ")",
  )
  let sql = self.seg(direction) +
    nulls +
    "(" +
    expressions +
    " FOR " +
    fields +
    default_on_null +
    group +
    ")" +
    alias_
  self.prepend_ctes(expression, sql)
}

///|
pub fn Generator::version_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = "FOR " + expression.name()
  let kind = expression.text("kind")
  let expr = self.sql_key(expression, "expression")
  this + " " + kind + " " + expr
}

///|
pub fn Generator::tuple_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "(" +
  self.expressions(
    expression~,
    dynamic=true,
    new_line=true,
    skip_first=true,
    skip_last=true,
  ) +
  ")"
}

// ---------------------------------------------------------------------------
// DML

///|
/// Python `_update_from_joins_sql`: returns (join_sql, from_sql).
pub fn Generator::update_from_joins_sql(
  self : Generator,
  expression : Expr,
) -> (String, String) raise SqlglotError {
  let from_expr = match expression.arg("from_") {
    Some(f) if !self.cfg.update_statement_supports_from => f
    _ => return ("", self.sql_key(expression, "from_"))
  }
  match expression.this() {
    Some(target_table) if target_table.kind.is_a(Table) => {
      let target_name = to_identifier(target_table.alias_or_name())
      for eq in expression.expressions() {
        match eq.this() {
          Some(col) if col.kind.is_a(Column) && col.text("table") == "" =>
            col.set("table", target_name)
          _ => ()
        }
      }
    }
    _ => ()
  }
  let table = from_expr.this_()
  let nested_joins = table.list("joins")
  if !nested_joins.is_empty() {
    table.set("joins", null_arg)
  }
  let mut join_sql = self.sql(
    Some(mk(Join, [("this", table), ("on", true_())])),
  )
  for nested in nested_joins {
    if !nested.has("on") && !nested.has("using") {
      nested.set("on", true_())
    }
    join_sql = join_sql + self.sql(Some(nested))
  }
  (join_sql, "")
}

///|
pub fn Generator::update_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let hint = self.sql_key(expression, "hint")
  let this = self.sql_key(expression, "this")
  let (join_sql, from_sql) = self.update_from_joins_sql(expression)
  let set_sql = self.expressions(expression~, flat=true)
  let where_sql = self.sql_key(expression, "where")
  let returning = self.sql_key(expression, "returning")
  let order = self.sql_key(expression, "order")
  let limit = self.sql_key(expression, "limit")
  let expression_sql = if self.cfg.returning_end {
    from_sql + where_sql + returning
  } else {
    returning + from_sql + where_sql
  }
  let options = g_around(
    " OPTION(",
    self.expressions(expression~, key="options"),
    ")",
  )
  let sql = "UPDATE" +
    hint +
    " " +
    this +
    join_sql +
    " SET " +
    set_sql +
    expression_sql +
    order +
    limit +
    options
  self.prepend_ctes(expression, sql)
}

///|
/// Virtual `values_sql(expression, values_as_table)`.
pub fn Generator::values_sql_v(
  self : Generator,
  expression : Expr,
  values_as_table? : Bool = true,
) -> String raise SqlglotError {
  match self.fns.hooks.values_sql {
    Some(f) => f(self, expression, values_as_table)
    None => self.values_sql(expression, values_as_table~)
  }
}

///|
pub fn Generator::values_sql(
  self : Generator,
  expression : Expr,
  values_as_table? : Bool = true,
) -> String raise SqlglotError {
  let values_as_table = values_as_table && self.cfg.values_as_table
  if values_as_table || expression.find_ancestor([From, Join]) is None {
    let args = self.expressions(expression~)
    let alias_ = self.sql_key(expression, "alias")
    let mut values = "VALUES" + self.seg("") + args
    if self.cfg.wrap_derived_values &&
      (
        alias_ != "" ||
        (match expression.parent {
          Some(p) => p.kind.is_any([From, Table])
          None => false
        })
      ) {
      values = "(" + values + ")"
    }
    values = self.query_modifiers(expression, [values])
    return if alias_ != "" { values + " AS " + alias_ } else { values }
  }
  let alias_node = expression.arg("alias")
  let column_names = match alias_node {
    Some(a) => a.raw_list("columns")
    None => []
  }
  let selects = []
  for i, tup in expression.expressions() {
    let mut row = tup.expressions()
    if i == 0 && !column_names.is_empty() {
      let aliased = []
      let n = if row.length() < column_names.length() {
        row.length()
      } else {
        column_names.length()
      }
      for j in 0..<n {
        aliased.push(exp_alias(row[j], column_names[j]))
      }
      row = aliased
    }
    selects.push(mk(Select, [("expressions", row)]))
  }
  if self.pretty {
    let mut query = selects[0]
    for i in 1..<selects.length() {
      query = exp_union(query, selects[i], distinct=false)
    }
    let alias_this = match alias_node {
      Some(a) => a.this()
      None => None
    }
    return self.call_method(
      Subquery,
      exp_subquery_with_alias_expr(query, alias_this, copy=false),
    )
  }
  let alias_ = match alias_node {
    Some(a) => " AS " + self.sql_key(a, "this")
    None => ""
  }
  let parts = []
  for select in selects {
    parts.push(self.sql(Some(select)))
  }
  "(" + parts.join(" UNION ALL ") + ")" + alias_
}

///|
pub fn Generator::into_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.unsupported_args(expression, ["expressions"])
  let temporary = g_when(expression.has("temporary"), " TEMPORARY")
  let unlogged = g_when(expression.has("unlogged"), " UNLOGGED")
  self.seg("INTO") +
  (if temporary != "" { temporary } else { unlogged }) +
  " " +
  self.sql_key(expression, "this")
}

///|
pub fn Generator::from_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.seg("FROM") + " " + self.sql_key(expression, "this")
}

///|
pub fn Generator::groupingsets_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let grouping_sets = self.expressions(expression~, indent=false)
  "GROUPING SETS " + self.wrap_str(grouping_sets)
}

///|
pub fn Generator::rollup_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, indent=false)
  if expressions != "" {
    "ROLLUP " + self.wrap_str(expressions)
  } else {
    "WITH ROLLUP"
  }
}

///|
pub fn Generator::rollupindex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let columns = self.expressions(expression~, flat=true)
  let from_sql = g_pfx(" FROM ", self.sql_key(expression, "from_index"))
  let properties_sql = match expression.arg("properties") {
    Some(p) => " " + self.properties(p, prefix="PROPERTIES")
    None => ""
  }
  this + "(" + columns + ")" + from_sql + properties_sql
}

///|
pub fn Generator::rollupproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "ROLLUP (" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::cube_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, indent=false)
  if expressions != "" {
    "CUBE " + self.wrap_str(expressions)
  } else {
    "WITH CUBE"
  }
}

///|
pub fn Generator::group_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let modifier = match expression.get("all") {
    Some(Bool(true)) => " ALL"
    Some(Bool(false)) => " DISTINCT"
    _ => ""
  }
  let mut group_by = self.op_expressions("GROUP BY" + modifier, expression)
  let grouping_sets = self.expressions(expression~, key="grouping_sets")
  let cube = self.expressions(expression~, key="cube")
  let rollup = self.expressions(expression~, key="rollup")
  let groupings = csv(
    [
      if grouping_sets != "" {
        self.seg(grouping_sets)
      } else {
        ""
      },
      if cube != "" {
        self.seg(cube)
      } else {
        ""
      },
      if rollup != "" {
        self.seg(rollup)
      } else {
        ""
      },
      if expression.has("totals") {
        self.seg("WITH TOTALS")
      } else {
        ""
      },
    ],
    sep=self.cfg.groupings_sep,
  )
  let stripped = py_strip(groupings)
  if !expression.expressions().is_empty() &&
    groupings != "" &&
    stripped != "WITH CUBE" &&
    stripped != "WITH ROLLUP" {
    let mut add_separator = true
    if grouping_sets != "" {
      if self.cfg.supports_grouping_sets_as_suffix {
        add_separator = false
      } else {
        self.unsupported(
          "GROUPING SETS without a comma after GROUP BY expressions is not supported",
        )
      }
    }
    if add_separator {
      group_by = group_by + self.cfg.groupings_sep
    }
  }
  group_by + groupings
}

///|
pub fn Generator::having_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.indent(self.sql_key(expression, "this"))
  self.seg("HAVING") + self.sep() + this
}

///|
pub fn Generator::connect_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let start = self.sql_key(expression, "start")
  let start = if start != "" { self.seg("START WITH " + start) } else { "" }
  let nocycle = g_when(expression.has("nocycle"), " NOCYCLE")
  let connect = self.sql_key(expression, "connect")
  let connect = self.seg("CONNECT BY" + nocycle + " " + connect)
  start + connect
}

///|
pub fn Generator::prior_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "PRIOR " + self.sql_key(expression, "this")
}

///|
pub fn Generator::join_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = py_upper(expression.text("kind"))
  let side = if !self.cfg.semi_anti_join_with_side &&
    (kind == "SEMI" || kind == "ANTI") {
    ""
  } else {
    py_upper(expression.text("side"))
  }
  let ops = [
    py_upper(expression.text("method")),
    g_when(expression.has("global_"), "GLOBAL"),
    side,
    kind,
    if self.cfg.join_hints {
      py_upper(expression.text("hint"))
    } else {
      ""
    },
    g_when(expression.has("directed") && self.cfg.directed_joins, "DIRECTED"),
  ]
  let mut op_sql = csv(ops, sep=" ")
  let match_cond = g_around(
    " MATCH_CONDITION (",
    self.sql_key(expression, "match_condition"),
    ")",
  )
  let mut on_sql = self.sql_key(expression, "on")
  let using_ = expression.raw_list("using")
  if on_sql == "" && !using_.is_empty() {
    let parts = []
    for column in using_ {
      parts.push(self.sql_value(column))
    }
    on_sql = csv(parts)
  }
  let this = expression.this()
  let mut this_sql = self.sql(this)
  let exprs = self.expressions(expression~)
  if exprs != "" {
    this_sql = this_sql + "," + self.seg(exprs)
  }
  if on_sql != "" {
    on_sql = self.indent(on_sql, skip_first=true)
    let space = if self.pretty { self.seg(" ".repeat(self.pad)) } else { " " }
    if !using_.is_empty() {
      on_sql = space + "USING (" + on_sql + ")"
    } else {
      on_sql = space + "ON " + on_sql
    }
  } else if op_sql == "" {
    match this {
      Some(t) if t.kind.is_a(Lateral) && t.get("cross_apply") is Some(_) =>
        return " " + this_sql
      _ => ()
    }
    return ", " + this_sql
  }
  if op_sql != "STRAIGHT_JOIN" {
    op_sql = if op_sql != "" { op_sql + " JOIN" } else { "JOIN" }
  }
  let pivots = self.expressions(expression~, key="pivots", sep="", flat=true)
  self.seg(op_sql) + " " + this_sql + match_cond + on_sql + pivots
}

///|
/// Virtual `lateral_op`.
pub fn Generator::lateral_op(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.lateral_op {
    Some(f) => f(self, expression)
    None => self.lateral_op_base(expression)
  }
}

///|
pub fn Generator::lateral_op_base(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  let op = match expression.get("cross_apply") {
    Some(Bool(true)) => "INNER JOIN "
    Some(Bool(false)) => "LEFT JOIN "
    _ => ""
  }
  op + "LATERAL"
}

///|
pub fn Generator::lateral_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  if expression.has("view") {
    let alias_ = expression.arg("alias")
    let columns = match alias_ {
      Some(a) => self.expressions(expression=a, key="columns", flat=true)
      None => ""
    }
    let alias_name = match alias_ {
      Some(a) => a.name()
      None => ""
    }
    let table = g_pfx(" ", alias_name)
    let columns = g_pfx(" AS ", columns)
    let op_sql = self.seg(
      "LATERAL VIEW" + g_when(expression.has("outer"), " OUTER"),
    )
    return op_sql + self.sep() + this + table + columns
  }
  let mut table_alias = expression.arg("alias")
  let this_expr = expression.this()
  let offset = match this_expr {
    Some(t) => t.arg("offset")
    None => None
  }
  match (table_alias, this_expr, offset) {
    (Some(ta), Some(t), Some(off)) if self.cfg.unnest_with_ordinality &&
      t.kind.is_a(Unnest) &&
      off.kind.is_a(Identifier) => {
      let ta = ta.copy()
      ta.append("columns", off.copy())
      table_alias = Some(ta)
    }
    _ => ()
  }
  let mut alias_ = g_pfx(" AS ", self.sql(table_alias))
  let mut ordinality = ""
  if expression.has("ordinality") {
    ordinality = " WITH ORDINALITY" + alias_
    alias_ = ""
  }
  self.lateral_op(expression) + " " + this + alias_ + ordinality
}

///|
pub fn Generator::setitem_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut kind = self.sql_key(expression, "kind")
  if !self.cfg.set_assignment_requires_variable_keyword && kind == "VARIABLE" {
    kind = ""
  } else {
    kind = g_pfx("", kind)
    if kind != "" {
      kind = kind + " "
    }
  }
  let this = self.sql_key(expression, "this")
  let expressions = self.expressions(expression~)
  let collate = g_pfx(" COLLATE ", self.sql_key(expression, "collate"))
  let global_ = g_when(expression.has("global_"), "GLOBAL ")
  global_ + kind + this + expressions + collate
}

///|
pub fn Generator::set_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = " " + self.expressions(expression~, flat=true)
  let tag = g_when(expression.has("tag"), " TAG")
  (if expression.has("unset") { "UNSET" } else { "SET" }) + tag + expressions
}

///|
pub fn Generator::queryband_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let update = g_when(expression.has("update"), " UPDATE")
  let scope = g_pfx(" FOR ", self.sql_key(expression, "scope"))
  "QUERY_BAND = " + this + update + scope
}

///|
pub fn Generator::pragma_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "PRAGMA " + self.sql_key(expression, "this")
}

///|
pub fn Generator::lock_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !self.cfg.locking_reads_supported {
    self.unsupported("Locking reads using 'FOR UPDATE/SHARE' are not supported")
    return ""
  }
  let update = expression.has("update")
  let key = expression.has("key")
  let lock_type = if update {
    if key {
      "FOR NO KEY UPDATE"
    } else {
      "FOR UPDATE"
    }
  } else if key {
    "FOR KEY SHARE"
  } else {
    "FOR SHARE"
  }
  let expressions = g_pfx(" OF ", self.expressions(expression~, flat=true))
  let wait = match expression.get("wait") {
    Some(Node(w)) if w.kind.is_a(Literal) => " WAIT " + self.sql(Some(w))
    Some(v) => if v.truthy() { " NOWAIT" } else { " SKIP LOCKED" }
    None => ""
  }
  lock_type + expressions + wait
}

///|
pub fn Generator::order_sql(
  self : Generator,
  expression : Expr,
  flat? : Bool = false,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let this = if this != "" { this + " " } else { this }
  let siblings = g_when(expression.has("siblings"), "SIBLINGS ")
  self.op_expressions(
    this + "ORDER " + siblings + "BY",
    expression,
    flat=this != "" || flat,
  )
}

///|
pub fn Generator::withfill_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let from_sql = g_pfx(" FROM ", self.sql_key(expression, "from_"))
  let to_sql = g_pfx(" TO ", self.sql_key(expression, "to"))
  let step_sql = g_pfx(" STEP ", self.sql_key(expression, "step"))
  let interpolated_values = []
  for e in expression.list("interpolate") {
    interpolated_values.push(
      if e.kind.is_a(Alias) {
        self.sql_key(e, "alias") + " AS " + self.sql_key(e, "this")
      } else {
        self.sql_key(e, "this")
      },
    )
  }
  let interpolate = if interpolated_values.is_empty() {
    ""
  } else {
    " INTERPOLATE (" + interpolated_values.join(", ") + ")"
  }
  "WITH FILL" + from_sql + to_sql + step_sql + interpolate
}

///|
pub fn Generator::cluster_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.op_expressions("CLUSTER BY", expression)
}

///|
pub fn Generator::clusterproperty_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("this") {
    self.unsupported(
      "Unsupported CLUSTER BY " + self.sql_key(expression, "this"),
    )
    return ""
  }
  "CLUSTER BY (" + self.expressions(expression~, flat=true) + ")"
}

///|
pub fn Generator::distribute_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.op_expressions("DISTRIBUTE BY", expression)
}

///|
pub fn Generator::sort_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.op_expressions("SORT BY", expression)
}

///|
/// Python `_resolve_ordered_for_null_ordering_simulation`.
pub fn Generator::resolve_ordered_for_null_ordering_simulation(
  self : Generator,
  expression : Expr,
) -> Expr? {
  ignore(self)
  let this = match expression.this() {
    Some(t) if t.kind.is_a(Column) && t.text("table") == "" => t
    _ => return None
  }
  let ancestor = match expression.find_ancestor([Select, Window]) {
    Some(a) if a.kind.is_a(Select) => a
    _ => return None
  }
  let column_name = this.name()
  let matched = []
  for p in ancestor.expressions() {
    if p.output_name() == column_name {
      matched.push(if p.kind.is_a(Alias) { p.this_() } else { p })
    }
  }
  let m = if matched.length() == 1 { Some(matched[0]) } else { None }
  match m {
    Some(x) if x.kind.is_a(Column) &&
      x.text("table") == "" &&
      x.name() == column_name => None
    _ => m
  }
}

///|
pub fn Generator::ordered_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let desc_v = expression.get("desc")
  let desc = match desc_v {
    Some(v) => v.truthy()
    None => false
  }
  let asc = !desc
  let nulls_first = expression.has("nulls_first")
  let nulls_last = !nulls_first
  let null_ordering = self.dialect.cfg.null_ordering
  let nulls_are_large = null_ordering == "nulls_are_large"
  let nulls_are_small = null_ordering == "nulls_are_small"
  let nulls_are_last = null_ordering == "nulls_are_last"
  let mut this = self.sql_key(expression, "this")
  let sort_order = if desc {
    " DESC"
  } else if desc_v is Some(Bool(false)) {
    " ASC"
  } else {
    ""
  }
  let mut nulls_sort_change = ""
  if nulls_first &&
    ((asc && nulls_are_large) || (desc && nulls_are_small) || nulls_are_last) {
    nulls_sort_change = " NULLS FIRST"
  } else if nulls_last &&
    ((asc && nulls_are_small) || (desc && nulls_are_large)) &&
    !nulls_are_last {
    nulls_sort_change = " NULLS LAST"
  }
  let null_ordering_supported = self.cfg.null_ordering_supported
  if nulls_sort_change != "" && null_ordering_supported != Some(true) {
    let window = expression.find_ancestor([Window, Select])
    let (window_this, spec) = match window {
      Some(w) if w.kind.is_a(Window) => {
        let mut wt = w.this()
        match wt {
          Some(x) if x.kind.is_any([IgnoreNulls, RespectNulls]) => wt = x.this()
          _ => ()
        }
        (wt, w.arg("spec"))
      }
      _ => (None, None)
    }
    let supports = match window_this {
      Some(wt) =>
        wt.kind.is_any(self.cfg.window_funcs_with_null_ordering) &&
        (match spec {
          None => true
          Some(s) => py_upper(s.text("kind")) == "ROWS"
        })
      None => false
    }
    if !supports {
      if window_this is Some(wt) && spec is Some(_) {
        self.unsupported(
          "'\{py_strip(nulls_sort_change)}' translation not supported in window function \{wt.kind.sql_name()}",
        )
        nulls_sort_change = ""
      } else if null_ordering_supported == Some(false) &&
        (
          (asc && nulls_sort_change == " NULLS LAST") ||
          (desc && nulls_sort_change == " NULLS FIRST")
        ) {
        let mut ancestor = expression.find_ancestor([AggFunc, Window, Select])
        match ancestor {
          Some(a) if a.kind.is_a(Window) => ancestor = a.this()
          _ => ()
        }
        match ancestor {
          Some(a) if a.kind.is_a(AggFunc) => {
            self.unsupported(
              "'\{py_strip(nulls_sort_change)}' translation not supported for aggregate function \{a.kind.sql_name()} with \{sort_order} sort order",
            )
            nulls_sort_change = ""
          }
          _ => ()
        }
      } else if null_ordering_supported is None {
        let this_expr = expression.this_()
        if this_expr.is_int() {
          self.unsupported(
            "'\{py_strip(nulls_sort_change)}' translation not supported with positional ordering",
          )
        } else if !this_expr.kind.is_a(Rand) {
          let resolved = self.resolve_ordered_for_null_ordering_simulation(
            expression,
          )
          let target = match resolved {
            Some(r) => self.sql(Some(r))
            None => this
          }
          let null_sort_order = if nulls_sort_change == " NULLS FIRST" {
            " DESC"
          } else {
            ""
          }
          this = "CASE WHEN \{target} IS NULL THEN 1 ELSE 0 END\{null_sort_order}, \{target}"
        }
        nulls_sort_change = ""
      }
    }
  }
  let with_fill = g_pfx(" ", self.sql_key(expression, "with_fill"))
  this + sort_order + nulls_sort_change + with_fill
}

///|
pub fn Generator::matchrecognizemeasure_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let window_frame = self.sql_key(expression, "window_frame")
  let window_frame = if window_frame != "" { window_frame + " " } else { "" }
  window_frame + self.sql_key(expression, "this")
}

///|
pub fn Generator::matchrecognize_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let partition = self.partition_by_sql(expression)
  let order = self.sql_key(expression, "order")
  let measures = self.expressions(expression~, key="measures")
  let measures = if measures != "" {
    self.seg("MEASURES" + self.seg(measures))
  } else {
    ""
  }
  let rows = self.sql_key(expression, "rows")
  let rows = if rows != "" { self.seg(rows) } else { "" }
  let after = self.sql_key(expression, "after")
  let after = if after != "" { self.seg(after) } else { "" }
  let pattern = self.sql_key(expression, "pattern")
  let pattern = if pattern != "" {
    self.seg("PATTERN (" + pattern + ")")
  } else {
    ""
  }
  let definition_sqls = []
  for definition in expression.list("define") {
    definition_sqls.push(
      self.sql_key(definition, "alias") +
      " AS " +
      self.sql_key(definition, "this"),
    )
  }
  let definitions = self.expressions(sqls=g_strs(definition_sqls))
  let define_ = if definitions != "" {
    self.seg("DEFINE" + self.seg(definitions))
  } else {
    ""
  }
  let body = partition + order + measures + rows + after + pattern + define_
  let alias_ = g_pfx(" ", self.sql_key(expression, "alias"))
  self.seg("MATCH_RECOGNIZE") + " " + self.wrap_str(body) + alias_
}

///|
pub fn Generator::query_modifiers(
  self : Generator,
  expression : Expr,
  sqls : Array[String],
) -> String raise SqlglotError {
  let mut limit = expression.arg("limit")
  match limit {
    Some(l) if self.cfg.limit_fetch == "LIMIT" && l.kind.is_a(Fetch) => {
      let count = match l.arg("count") {
        Some(c) => c.copy()
        None => literal_int(1)
      }
      limit = Some(mk(Limit, [("expression", count)]))
    }
    Some(l) if self.cfg.limit_fetch == "FETCH" && l.kind.is_a(Limit) =>
      limit = Some(
        mk(Fetch, [
          ("direction", ("FIRST" : &IntoValue)),
          (
            "count",
            match l.arg("expression") {
              Some(e) => Some(e.copy())
              None => None
            },
          ),
        ]),
      )
    _ => ()
  }
  let parts = sqls.copy()
  for join in expression.list("joins") {
    parts.push(self.sql(Some(join)))
  }
  parts.push(self.sql_key(expression, "match"))
  for lateral in expression.list("laterals") {
    parts.push(self.sql(Some(lateral)))
  }
  parts.push(self.sql_key(expression, "prewhere"))
  parts.push(self.sql_key(expression, "where"))
  parts.push(self.sql_key(expression, "connect"))
  parts.push(self.sql_key(expression, "group"))
  parts.push(self.sql_key(expression, "having"))
  for gen in self.fns.after_having_modifier_transforms {
    parts.push((gen.1)(self, expression))
  }
  parts.push(self.sql_key(expression, "order"))
  let is_fetch = match limit {
    Some(l) => l.kind.is_a(Fetch)
    None => false
  }
  for s in self.offset_limit_modifiers(expression, is_fetch, limit) {
    parts.push(s)
  }
  for s in self.after_limit_modifiers(expression) {
    parts.push(s)
  }
  parts.push(self.sql_key(expression, "for_"))
  parts.push(self.options_modifier(expression))
  csv(parts, sep="")
}

///|
/// Virtual `options_modifier`.
pub fn Generator::options_modifier(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.options_modifier {
    Some(f) => f(self, expression)
    None => self.options_modifier_base(expression)
  }
}

///|
pub fn Generator::options_modifier_base(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  g_pfx(" ", self.expressions(expression~, key="options"))
}

///|
pub fn Generator::forclause_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = py_str_value(expression.get("kind"))
  if kind == "BROWSE" {
    return self.sep() + "FOR BROWSE"
  }
  let options = self.expressions(expression~, key="expressions")
  if options == "" {
    return ""
  }
  self.sep() + "FOR " + kind + self.seg(options)
}

///|
pub fn Generator::queryoption_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported("Unsupported query option.")
  ""
}

///|
/// Virtual `offset_limit_modifiers`.
pub fn Generator::offset_limit_modifiers(
  self : Generator,
  expression : Expr,
  fetch : Bool,
  limit : Expr?,
) -> Array[String] raise SqlglotError {
  match self.fns.hooks.offset_limit_modifiers {
    Some(f) => f(self, expression, fetch, limit)
    None => self.offset_limit_modifiers_base(expression, fetch, limit)
  }
}

///|
pub fn Generator::offset_limit_modifiers_base(
  self : Generator,
  expression : Expr,
  fetch : Bool,
  limit : Expr?,
) -> Array[String] raise SqlglotError {
  if fetch {
    [self.sql_key(expression, "offset"), self.sql(limit)]
  } else {
    [self.sql(limit), self.sql_key(expression, "offset")]
  }
}

///|
/// Virtual `after_limit_modifiers`.
pub fn Generator::after_limit_modifiers(
  self : Generator,
  expression : Expr,
) -> Array[String] raise SqlglotError {
  match self.fns.hooks.after_limit_modifiers {
    Some(f) => f(self, expression)
    None => self.after_limit_modifiers_base(expression)
  }
}

///|
pub fn Generator::after_limit_modifiers_base(
  self : Generator,
  expression : Expr,
) -> Array[String] raise SqlglotError {
  let locks = g_pfx(" ", self.expressions(expression~, key="locks", sep=" "))
  [locks, self.sql_key(expression, "sample")]
}

///|
pub fn Generator::select_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let into = expression.arg("into")
  if !self.cfg.supports_select_into {
    match into {
      Some(i) => i.pop() |> ignore
      None => ()
    }
  }
  let hint = self.sql_key(expression, "hint")
  let distinct = g_pfx(" ", self.sql_key(expression, "distinct"))
  let mut kind = self.sql_key(expression, "kind")
  let top = match expression.arg("limit") {
    Some(limit) if limit.kind.is_a(Limit) && self.cfg.limit_is_top => {
      let top = self.limit_sql(limit, top=true)
      limit.pop() |> ignore
      top
    }
    _ => ""
  }
  let mut expressions = self.expressions(expression~)
  if kind != "" {
    if self.cfg.select_kinds.contains(kind) {
      kind = " AS " + kind
    } else {
      if kind == "STRUCT" {
        let items = []
        for e in expression.expressions() {
          items.push(
            if e.kind.is_a(Alias) {
              mk(PropertyEQ, [
                ("this", e.get("alias")),
                ("expression", e.get("this")),
              ])
            } else {
              e
            },
          )
        }
        expressions = self.expressions(sqls=[
          Str(self.sql(Some(mk(Struct, [("expressions", items)])))),
        ])
      }
      kind = ""
    }
  }
  let operation_modifiers = g_pfx(
    self.sep(),
    self.expressions(expression~, key="operation_modifiers", sep=" "),
  )
  let exclude = expression.raw_list("exclude")
  if !self.cfg.star_exclude_requires_derived_table && !exclude.is_empty() {
    let exclude_sql = self.expressions(sqls=exclude, flat=true)
    expressions = expressions + self.seg("EXCLUDE") + " (" + exclude_sql + ")"
  }
  let top_distinct = if self.cfg.limit_is_top {
    distinct + hint + top
  } else {
    top + hint + distinct
  }
  let expressions = g_pfx(self.sep(), expressions)
  let mut sql = self.query_modifiers(expression, [
    "SELECT" + top_distinct + operation_modifiers + kind + expressions,
    self.sql_key(expression, "into"),
    self.sql_key(expression, "from_"),
  ])
  if expression.has("with_") {
    sql = self.maybe_comment(sql, expression~)
    expression.pop_comments() |> ignore
  }
  sql = self.prepend_ctes(expression, sql)
  if self.cfg.star_exclude_requires_derived_table && !exclude.is_empty() {
    expression.set("exclude", null_arg)
    let subquery = exp_subquery_of(expression, copy=false)
    let star = mk(Star, [("except_", exclude)])
    sql = self.sql(Some(exp_select_from([star], subquery)))
  }
  if !self.cfg.supports_select_into {
    match into {
      Some(into) => {
        let table_kind = if into.has("temporary") {
          " TEMPORARY"
        } else if self.cfg.supports_unlogged_tables && into.has("unlogged") {
          " UNLOGGED"
        } else {
          ""
        }
        sql = "CREATE" +
          table_kind +
          " TABLE " +
          self.sql(into.this()) +
          " AS " +
          sql
      }
      None => ()
    }
  }
  sql
}

///|
pub fn Generator::schema_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let sql = self.schema_columns_sql(expression)
  if this != "" && sql != "" {
    this + " " + sql
  } else if this != "" {
    this
  } else {
    sql
  }
}

///|
pub fn Generator::schema_columns_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !expression.expressions().is_empty() {
    return "(" +
      self.sep(sep="") +
      self.expressions(expression~) +
      self.seg(")", sep="")
  }
  ""
}

///|
pub fn Generator::star_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let except_ = self.expressions(expression~, key="except_", flat=true)
  let except_ = if except_ != "" {
    self.seg(self.cfg.star_except) + " (" + except_ + ")"
  } else {
    ""
  }
  let replace = self.expressions(expression~, key="replace", flat=true)
  let replace = if replace != "" {
    self.seg("REPLACE") + " (" + replace + ")"
  } else {
    ""
  }
  let rename = self.expressions(expression~, key="rename", flat=true)
  let rename = if rename != "" {
    self.seg("RENAME") + " (" + rename + ")"
  } else {
    ""
  }
  let ilike = self.sql_key(expression, "ilike")
  let ilike = if ilike != "" { self.seg("ILIKE") + " " + ilike } else { "" }
  "*" + ilike + except_ + replace + rename
}

///|
pub fn Generator::subquery_sql(
  self : Generator,
  expression : Expr,
  sep? : String = " AS ",
) -> String raise SqlglotError {
  let mut alias_ = g_pfx(sep, self.sql_key(expression, "alias"))
  let sample = self.sql_key(expression, "sample")
  if self.dialect.cfg.alias_post_tablesample && sample != "" {
    alias_ = sample + alias_
    expression.set("sample", null_arg)
  }
  let pivots = self.expressions(expression~, key="pivots", sep="", flat=true)
  let sql = self.query_modifiers(expression, [
    self.wrap(expression),
    alias_,
    pivots,
  ])
  self.prepend_ctes(expression, sql)
}

///|
pub fn Generator::qualify_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.indent(self.sql_key(expression, "this"))
  self.seg("QUALIFY") + self.sep() + this
}

///|
pub fn Generator::unnest_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let args = self.expressions(expression~, flat=true)
  let alias_ = expression.arg("alias")
  let offset = expression.get("offset")
  if self.cfg.unnest_with_ordinality {
    match (alias_, offset) {
      (Some(a), Some(Node(off))) => {
        a.append("columns", off)
        expression.set("offset", null_arg)
      }
      _ => ()
    }
  }
  let alias_sql = match alias_ {
    Some(a) if self.dialect.cfg.unnest_column_only => {
      let columns = a.raw_list("columns")
      if columns.is_empty() {
        ""
      } else {
        self.sql_value(columns[0])
      }
    }
    _ => self.sql(alias_)
  }
  let alias_sql = g_pfx(" AS ", alias_sql)
  let offset_truthy = match offset {
    Some(v) => v.truthy()
    None => false
  }
  let suffix = if self.cfg.unnest_with_ordinality {
    if offset_truthy {
      " WITH ORDINALITY" + alias_sql
    } else {
      alias_sql
    }
  } else {
    match offset {
      Some(Node(off)) => alias_sql + " WITH OFFSET AS " + self.sql(Some(off))
      _ => if offset_truthy { alias_sql + " WITH OFFSET" } else { alias_sql }
    }
  }
  "UNNEST(" + args + ")" + suffix
}

///|
pub fn Generator::prewhere_sql(self : Generator, expression : Expr) -> String {
  ignore((self, expression))
  ""
}

///|
pub fn Generator::where_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.indent(self.sql_key(expression, "this"))
  self.seg("WHERE") + self.sep() + this
}

///|
pub fn Generator::window_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  let partition = self.partition_by_sql(expression)
  let order = match expression.arg("order") {
    Some(o) => self.order_sql(o, flat=true)
    None => ""
  }
  let spec = self.sql_key(expression, "spec")
  let alias_ = self.sql_key(expression, "alias")
  let over = self.sql_key(expression, "over")
  let over = if over != "" { over } else { "OVER" }
  this = this +
    " " +
    (if expression.arg_key == Some("windows") { "AS" } else { over })
  let first = match expression.get("first") {
    None => ""
    Some(v) => if v.truthy() { "FIRST" } else { "LAST" }
  }
  if partition == "" && order == "" && spec == "" && alias_ != "" {
    return this + " " + alias_
  }
  let args : Array[&SqlArg] = []
  for arg in [alias_, first, partition, order, spec] {
    if arg != "" {
      args.push(arg)
    }
  }
  let args = self.format_args(args, sep=" ")
  this + " (" + args + ")"
}

///|
pub fn Generator::partition_by_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  g_pfx(
    "PARTITION BY ",
    self.expressions(expression~, key="partition_by", flat=true),
  )
}

///|
pub fn Generator::windowspec_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let start = csv(
    [self.sql_key(expression, "start"), self.sql_key(expression, "start_side")],
    sep=" ",
  )
  let end = csv(
    [self.sql_key(expression, "end"), self.sql_key(expression, "end_side")],
    sep=" ",
  )
  let end = if end != "" { end } else { "CURRENT ROW" }
  let mut window_spec = kind + " BETWEEN " + start + " AND " + end
  let exclude = self.sql_key(expression, "exclude")
  if exclude != "" {
    if self.cfg.supports_window_exclude {
      window_spec = window_spec + " EXCLUDE " + exclude
    } else {
      self.unsupported("EXCLUDE clause is not supported in the WINDOW clause")
    }
  }
  window_spec
}

///|
pub fn Generator::withingroup_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expression_sql = g_str_from(self.sql_key(expression, "expression"), 1)
  this + " WITHIN GROUP (" + expression_sql + ")"
}

///|
pub fn Generator::delete_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let hint = self.sql_key(expression, "hint")
  let this = g_pfx(" FROM ", self.sql_key(expression, "this"))
  let using_ = g_pfx(" USING ", self.expressions(expression~, key="using"))
  let cluster = g_pfx(" ", self.sql_key(expression, "cluster"))
  let where_ = self.sql_key(expression, "where")
  let returning = self.sql_key(expression, "returning")
  let order = self.sql_key(expression, "order")
  let limit = self.sql_key(expression, "limit")
  let tables = g_pfx(" ", self.expressions(expression~, key="tables"))
  let expression_sql = if self.cfg.returning_end {
    this + using_ + cluster + where_ + returning + order + limit
  } else {
    returning + this + using_ + cluster + where_ + order + limit
  }
  self.prepend_ctes(expression, "DELETE" + hint + tables + expression_sql)
}

///|
pub fn Generator::insert_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let hint = self.sql_key(expression, "hint")
  let overwrite = expression.has("overwrite")
  let mut this = match expression.this() {
    Some(t) if t.kind.is_a(Directory) =>
      if overwrite {
        " OVERWRITE"
      } else {
        " INTO"
      }
    _ => if overwrite { self.cfg.insert_overwrite } else { " INTO" }
  }
  let stored = g_pfx(" ", self.sql_key(expression, "stored"))
  let alternative = match expression.get("alternative") {
    Some(v) if v.truthy() => " OR " + py_str_value(Some(v))
    _ => ""
  }
  let ignore_ = g_when(expression.has("ignore"), " IGNORE")
  if expression.has("is_function") {
    this = this + " FUNCTION"
  }
  this = this + " " + self.sql_key(expression, "this")
  let exists = g_when(expression.has("exists"), " IF EXISTS")
  let where_ = g_pfx(
    self.sep() + "REPLACE WHERE ",
    self.sql_key(expression, "where"),
  )
  let using_ = g_around(
    self.sep() + "REPLACE USING (",
    self.expressions(expression~, key="using", flat=true),
    ")",
  )
  let mut expression_sql = self.sep() + self.sql_key(expression, "expression")
  let on_conflict = g_pfx(" ", self.sql_key(expression, "conflict"))
  let by_name = g_when(expression.has("by_name"), " BY NAME")
  let default_values = g_when(expression.has("default"), "DEFAULT VALUES")
  let returning = self.sql_key(expression, "returning")
  if self.cfg.returning_end {
    expression_sql = expression_sql + on_conflict + default_values + returning
  } else {
    expression_sql = returning + expression_sql + on_conflict
  }
  let partition_by = g_pfx(" ", self.sql_key(expression, "partition"))
  let settings = g_pfx(" ", self.sql_key(expression, "settings"))
  let source = g_pfx("TABLE ", self.sql_key(expression, "source"))
  let sql = "INSERT" +
    hint +
    alternative +
    ignore_ +
    this +
    stored +
    by_name +
    exists +
    partition_by +
    settings +
    where_ +
    using_ +
    expression_sql +
    source
  self.prepend_ctes(expression, sql)
}

///|
pub fn Generator::onconflict_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let conflict = if expression.has("duplicate") {
    "ON DUPLICATE KEY"
  } else {
    "ON CONFLICT"
  }
  let constraint = g_pfx(
    " ON CONSTRAINT ",
    self.sql_key(expression, "constraint"),
  )
  let conflict_keys = g_around(
    "(",
    self.expressions(expression~, key="conflict_keys", flat=true),
    ")",
  )
  let index_predicate = self.sql_key(expression, "index_predicate")
  let conflict_keys = conflict_keys + index_predicate + " "
  let action = self.sql_key(expression, "action")
  let mut expressions = self.expressions(expression~, flat=true)
  if expressions != "" {
    let set_keyword = g_when(self.cfg.duplicate_key_update_with_set, "SET ")
    expressions = " " + set_keyword + expressions
  }
  let where_ = self.sql_key(expression, "where")
  conflict + constraint + conflict_keys + action + expressions + where_
}

///|
pub fn Generator::returning_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.seg("RETURNING") + " " + self.expressions(expression~, flat=true)
}

///|
pub fn Generator::when_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let matched = if expression.has("matched") {
    "MATCHED"
  } else {
    "NOT MATCHED"
  }
  let source = g_when(
    self.cfg.matched_by_source && expression.has("source"),
    " BY SOURCE",
  )
  let condition = g_pfx(" AND ", self.sql_key(expression, "condition"))
  let then_expression = expression.arg("then")
  let mut then = match then_expression {
    Some(t) if t.kind.is_a(Insert) => {
      let this = self.sql_key(t, "this")
      let this = if this != "" { "INSERT " + this } else { "INSERT" }
      let then = self.sql_key(t, "expression")
      if then != "" {
        this + " VALUES " + then
      } else {
        this
      }
    }
    Some(t) if t.kind.is_a(Update) =>
      match t.get("expressions") {
        Some(Node(star)) if star.kind.is_a(Star) =>
          "UPDATE " + self.sql_key(t, "expressions")
        _ => {
          let expressions_sql = self.expressions(expression=t)
          if expressions_sql != "" {
            "UPDATE SET" + self.sep() + expressions_sql
          } else {
            "UPDATE"
          }
        }
      }
    _ => self.sql(then_expression)
  }
  match then_expression {
    Some(t) if t.kind.is_any([Insert, Update]) => {
      let mut where_ = self.sql_key(t, "where")
      if where_ != "" && !self.cfg.supports_merge_where {
        let kind = if t.kind.is_a(Insert) { "INSERT" } else { "UPDATE" }
        self.unsupported("WHERE clause in MERGE \{kind} is not supported")
        where_ = ""
      }
      then = then + where_
    }
    _ => ()
  }
  "WHEN " + matched + source + condition + " THEN " + then
}

///|
pub fn Generator::whens_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.expressions(expression~, sep=" ", indent=false)
}

///|
pub fn Generator::merge_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let table = expression.this_()
  let mut table_alias = ""
  let hints = table.list("hints")
  if !hints.is_empty() &&
    table.alias() != "" &&
    hints[0].kind.is_a(WithTableHint) {
    match table.arg("alias") {
      Some(a) => table_alias = " AS " + self.sql(Some(a.pop()))
      None => ()
    }
  }
  let this = self.sql(Some(table))
  let using_ = "USING " + self.sql_key(expression, "using")
  let mut whens = self.sql_key(expression, "whens")
  let mut on = g_pfx("ON ", self.sql_key(expression, "on"))
  if on == "" {
    on = g_around("USING (", self.expressions(expression~, key="using_cond"), ")")
  }
  let returning = self.sql_key(expression, "returning")
  if returning != "" {
    whens = whens + returning
  }
  let sep = self.sep()
  self.prepend_ctes(
    expression,
    "MERGE INTO " + this + table_alias + sep + using_ + sep + on + sep + whens,
  )
}
