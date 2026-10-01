// Generator methods for functions.

///|
/// Python `dialects.dialect.map_date_part`.
pub fn gen_map_date_part(part : Expr?, dialect : Dialect) -> Expr? {
  match part {
    Some(p) => {
      if p.kind.is_a(Column) && p.column_parts().length() != 1 {
        return part
      }
      match dialect.cfg.date_part_mapping.get(py_upper(p.name())) {
        Some(mapped) if mapped != "" =>
          Some(
            if p.is_string() {
              literal_string(mapped)
            } else {
              var_(mapped)
            },
          )
        _ => part
      }
    }
    None => None
  }
}

///|
/// Python `dialects.dialect.unit_to_str`.
pub fn gen_unit_to_str(expression : Expr, default? : String = "DAY") -> Expr? {
  match expression.arg("unit") {
    None => if default != "" { Some(literal_string(default)) } else { None }
    Some(unit) =>
      if unit.kind.is_a(WeekStart) {
        Some(literal_string("WEEK"))
      } else if unit.kind.is_a(Placeholder) ||
        !(unit.kind == Var || unit.kind == Literal) {
        Some(unit)
      } else {
        Some(literal_string(unit.name()))
      }
  }
}

///|
pub fn Generator::function_fallback_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let args : Array[&SqlArg] = []
  for kv in expression.kind.arg_types() {
    match expression.args.get(kv.0) {
      Some(List(l)) =>
        for v in l {
          args.push(v)
        }
      Some(v) => args.push(v)
      None => ()
    }
  }
  let name = if self.dialect.cfg.preserve_original_names {
    match expression.meta_get("name") {
      Some(Str(n)) if n != "" => n
      _ => expression.kind.sql_name()
    }
  } else {
    expression.kind.sql_name()
  }
  self.func(name, args)
}

///|
pub fn Generator::anonymous_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let is_qualified = match expression.parent {
    Some(p) =>
      p.kind.is_a(Dot) &&
      (match p.expression() {
        Some(pe) => physical_equal(pe, expression)
        None => false
      })
    None => false
  }
  self.func(
    self.sql_key(expression, "this"),
    g_fargs(expression.expressions()),
    normalize=!is_qualified,
  )
}

///|
pub fn Generator::ceil_floor(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let to_clause = self.sql_key(expression, "to")
  if to_clause != "" {
    return expression.kind.sql_name() +
      "(" +
      self.sql_key(expression, "this") +
      " TO " +
      to_clause +
      ")"
  }
  self.function_fallback_sql(expression)
}

///|
pub fn Generator::extract_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = if self.cfg.normalize_extract_date_parts {
    gen_map_date_part(expression.this(), self.dialect)
  } else {
    expression.this()
  }
  let this_sql = if self.cfg.extract_allows_quotes {
    self.sql(this)
  } else {
    match this {
      Some(t) if t.kind.is_a(WeekStart) => self.weekstart_name(t)
      Some(t) => t.name()
      None => ""
    }
  }
  let expression_sql = self.sql_key(expression, "expression")
  "EXTRACT(" + this_sql + " FROM " + expression_sql + ")"
}

///|
pub fn Generator::trim_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let trim_type = self.sql_key(expression, "position")
  let func_name = if trim_type == "LEADING" {
    "LTRIM"
  } else if trim_type == "TRAILING" {
    "RTRIM"
  } else {
    "TRIM"
  }
  self.func(func_name, [expression.get("this"), expression.get("expression")])
}

///|
pub fn Generator::convert_concat_args(
  self : Generator,
  expression : Expr,
) -> Array[Expr] raise SqlglotError {
  let mut args = expression.expressions()
  let is_concat_ws = expression.kind.is_a(ConcatWs)
  if is_concat_ws {
    args = if args.is_empty() { [] } else { args[1:].to_owned() }
  }
  if self.dialect.cfg.strict_string_concat && expression.has("safe") {
    args = args.map(e => exp_cast(e, DType::TEXT))
  }
  let concat_coalesce = if is_concat_ws {
    self.dialect.cfg.concat_ws_coalesce
  } else {
    self.dialect.cfg.concat_coalesce
  }
  if !concat_coalesce && expression.has("coalesce") {
    let wrapped = []
    for e in args {
      let mut e = e
      if e.get_type() is None {
        e = gen_annotate_types(e, self.dialect)
      }
      if e.is_string() || e.is_type([DType::ARRAY]) {
        wrapped.push(e)
      } else {
        wrapped.push(
          mk(Coalesce, [
            ("this", e.copy()),
            ("expressions", [literal_string("")]),
          ]),
        )
      }
    }
    args = wrapped
  }
  args
}

///|
pub fn Generator::concat_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.dialect.cfg.concat_coalesce && !expression.has("coalesce") {
    return self.concat_to_dpipe_sql(expression)
  }
  let expressions = self.convert_concat_args(expression)
  if !self.cfg.supports_single_arg_concat && expressions.length() == 1 {
    return self.sql(Some(expressions[0]))
  }
  self.func("CONCAT", g_fargs(expressions))
}

///|
/// Python `dialects.dialect.concat_to_dpipe_sql`.
pub fn Generator::concat_to_dpipe_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let args = self.convert_concat_args(expression)
  if args.is_empty() {
    raise ValueError("reduce() of empty iterable with no initial value")
  }
  let mut acc = args[0]
  for i in 1..<args.length() {
    acc = mk2(DPipe, acc, args[i])
  }
  self.sql(Some(acc))
}

///|
pub fn Generator::concatws_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.dialect.cfg.concat_ws_coalesce && !expression.has("coalesce") {
    let all_args = expression.expressions()
    expression.set("coalesce", true)
    let conds = all_args.map(arg => exp_is(arg, null_()))
    let case_ = case_when(exp_case(), exp_or(conds), null_())
    return self.sql(Some(case_else(case_, expression)))
  }
  let args : Array[&SqlArg] = [expression.expressions().get(0)]
  for a in self.convert_concat_args(expression) {
    args.push(a)
  }
  self.func("CONCAT_WS", args)
}

///|
pub fn Generator::matchagainst_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions : Array[&SqlArg] = []
  if g_str_truthy(self.cfg.match_against_table_prefix) {
    for expr in expression.expressions() {
      if expr.kind.is_a(Table) {
        expressions.push("TABLE " + self.sql(Some(expr)))
      } else {
        expressions.push(expr)
      }
    }
  } else {
    for expr in expression.expressions() {
      expressions.push(expr)
    }
  }
  let modifier = match expression.get("modifier") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  self.func("MATCH", expressions) +
  " AGAINST(" +
  self.sql_key(expression, "this") +
  modifier +
  ")"
}

///|
pub fn Generator::jsonkeyvalue_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  self.cfg.json_key_value_pair_sep +
  " " +
  self.sql_key(expression, "expression")
}

///|
pub fn Generator::jsonpath_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut path = lstrip_chars(
    self.expressions(expression~, sep="", flat=true),
    ".",
  )
  if self.cfg.quote_json_path {
    path = self.escape_str(path)
    path = self.dialect.cfg.quote_start + path + self.dialect.cfg.quote_end
  }
  path
}

///|
pub fn Generator::json_path_part(
  self : Generator,
  expression : Value?,
) -> String raise SqlglotError {
  match expression {
    Some(Node(e)) if e.kind.is_a(JSONPathPart) =>
      match self.fns.transforms.get(e.kind) {
        Some(transform) => transform(self, e)
        None => {
          self.unsupported("Unsupported JSONPathPart type \{e.kind.name()}")
          ""
        }
      }
    Some(Int(i)) => i.to_string()
    Some(Bool(b)) => if b { "True" } else { "False" }
    Some(Str(s)) =>
      if self.quote_json_path_key_using_brackets &&
        self.cfg.json_path_single_quote_escape {
        "'" + s.replace_all(old="'", new="\\'") + "'"
      } else {
        "\"" + s.replace_all(old="\"", new="\\\"") + "\""
      }
    Some(other) => py_str_value(Some(other))
    None => ""
  }
}

///|
/// Python `_jsonpathkey_sql`.
pub fn Generator::jsonpathkey_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.get("this")
  match this {
    Some(Node(w)) if w.kind.is_a(JSONPathWildcard) => {
      let s = self.json_path_part(this)
      return g_pfx(".", s)
    }
    _ => ()
  }
  let quoted = expression.has("quoted")
  match this {
    Some(Str(s)) if !(quoted && self.cfg.json_path_key_quoted_forces_brackets) => {
      let safe = match self.fns.hooks.safe_json_path_key_re {
        Some(f) => f(s)
        None => is_safe_identifier(s)
      }
      if safe {
        return "." + s
      }
    }
    _ => ()
  }
  let this = self.json_path_part(this)
  if self.quote_json_path_key_using_brackets &&
    self.cfg.json_path_bracketed_key_supported {
    "[" + this + "]"
  } else {
    "." + this
  }
}

///|
/// Python `_jsonpathsubscript_sql`.
pub fn Generator::jsonpathsubscript_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.json_path_part(expression.get("this"))
  g_around("[", this, "]")
}

///|
pub fn Generator::formatjson_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") + " FORMAT JSON"
}

///|
pub fn Generator::formatphrase_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let fmt = self.sql_key(expression, "format")
  this + " (FORMAT " + fmt + ")"
}

///|
/// Python `_jsonobject_sql(expression, name)`.
pub fn Generator::jsonobject_sql(
  self : Generator,
  expression : Expr,
  name? : String = "",
) -> String raise SqlglotError {
  let null_handling = match expression.get("null_handling") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let unique_keys = match expression.get("unique_keys") {
    Some(v) =>
      " " + (if v.truthy() { "WITH" } else { "WITHOUT" }) + " UNIQUE KEYS"
    None => ""
  }
  let return_type = g_pfx(" RETURNING ", self.sql_key(expression, "return_type"))
  let encoding = g_pfx(" ENCODING ", self.sql_key(expression, "encoding"))
  let name = if name == "" {
    if expression.kind.is_a(JSONObject) {
      "JSON_OBJECT"
    } else {
      "JSON_OBJECTAGG"
    }
  } else {
    name
  }
  self.func(
    name,
    g_fargs(expression.expressions()),
    suffix=null_handling + unique_keys + return_type + encoding + ")",
  )
}

///|
pub fn Generator::jsonarray_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let null_handling = match expression.get("null_handling") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let return_type = g_pfx(" RETURNING ", self.sql_key(expression, "return_type"))
  let strict = g_when(expression.has("strict"), " STRICT")
  self.func(
    "JSON_ARRAY",
    g_fargs(expression.expressions()),
    suffix=null_handling + return_type + strict + ")",
  )
}

///|
pub fn Generator::jsonarrayagg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let order = self.sql_key(expression, "order")
  let null_handling = match expression.get("null_handling") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let return_type = g_pfx(" RETURNING ", self.sql_key(expression, "return_type"))
  let strict = g_when(expression.has("strict"), " STRICT")
  self.func(
    "JSON_ARRAYAGG",
    [this],
    suffix=order + null_handling + return_type + strict + ")",
  )
}

///|
pub fn Generator::jsoncolumndef_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let path = g_pfx(" PATH ", self.sql_key(expression, "path"))
  let nested_schema = self.sql_key(expression, "nested_schema")
  if nested_schema != "" {
    return "NESTED" + path + " " + nested_schema
  }
  let this = self.sql_key(expression, "this")
  let kind = g_pfx(" ", self.sql_key(expression, "kind"))
  let format_json = g_when(expression.has("format_json"), " FORMAT JSON")
  let ordinality = g_when(expression.has("ordinality"), " FOR ORDINALITY")
  this + kind + format_json + path + ordinality
}

///|
pub fn Generator::jsonschema_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("COLUMNS", g_fargs(expression.expressions()))
}

///|
pub fn Generator::jsontable_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let path = g_pfx(", ", self.sql_key(expression, "path"))
  let error_handling = match expression.get("error_handling") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let empty_handling = match expression.get("empty_handling") {
    Some(v) if v.truthy() => " " + py_str_value(Some(v))
    _ => ""
  }
  let schema = self.sql_key(expression, "schema")
  self.func(
    "JSON_TABLE",
    [this],
    suffix=path + error_handling + empty_handling + " " + schema + ")",
  )
}

///|
pub fn Generator::openjsoncolumndef_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = self.sql_key(expression, "kind")
  let path = g_pfx(" ", self.sql_key(expression, "path"))
  let as_json = g_when(expression.has("as_json"), " AS JSON")
  this + " " + kind + path + as_json
}

///|
pub fn Generator::openjson_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let path = g_pfx(", ", self.sql_key(expression, "path"))
  let expressions = self.expressions(expression~)
  let with_ = if expressions != "" {
    " WITH (" +
    self.seg(self.indent(expressions), sep="") +
    self.seg(")", sep="")
  } else {
    ""
  }
  "OPENJSON(" + this + path + ")" + with_
}

///|
pub fn Generator::return_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "RETURN " + self.sql_key(expression, "this")
}

///|
pub fn Generator::strtotime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("STR_TO_TIME", [expression.get("this"), expression.get("format")])
}

///|
pub fn Generator::strtodate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("STR_TO_DATE", [expression.get("this"), expression.get("format")])
}

///|
pub fn Generator::parsedatetime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("PARSE_DATETIME", [
    expression.get("this"),
    expression.get("format"),
    expression.get("zone"),
  ])
}

///|
pub fn Generator::currentdate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let zone = self.sql_key(expression, "this")
  if zone != "" {
    "CURRENT_DATE(" + zone + ")"
  } else {
    "CURRENT_DATE"
  }
}

///|
pub fn Generator::fromiso8601date_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(Some(exp_cast(expression.this_(), DType::DATE)))
}

///|
pub fn Generator::fromiso8601timestamp_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(Some(exp_cast(expression.this_(), DType::TIMESTAMPTZ)))
}

///|
pub fn Generator::fromiso8601timestampnanos_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(Some(exp_cast(expression.this_(), DType::TIMESTAMPTZ)))
}

///|
pub fn Generator::tochar_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.unsupported_args(expression, ["format"])
  self.sql(Some(exp_cast(expression.this_(), DType::TEXT)))
}

///|
pub fn Generator::tonumber_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.unsupported_args(expression, ["default"])
  if !self.cfg.supports_to_number {
    self.unsupported("Unsupported TO_NUMBER function")
    return self.tonumber_cast_sql(expression)
  }
  let fmt = match expression.get("format") {
    Some(v) if v.truthy() => v
    _ => {
      self.unsupported("Conversion format is required for TO_NUMBER")
      return self.tonumber_cast_sql(expression)
    }
  }
  self.func("TO_NUMBER", [expression.get("this"), Some(fmt)])
}

///|
/// Python `_tonumber_cast_sql`.
pub fn Generator::tonumber_cast_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("safe") {
    return self.sql(
      Some(
        mk(TryCast, [
          ("this", expression.get("this")),
          ("to", Some(Node(datatype_of(DType::DOUBLE)))),
        ]),
      ),
    )
  }
  self.sql(Some(exp_cast(expression.this_(), DType::DOUBLE)))
}

///|
pub fn Generator::distinct_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.expressions(expression~, flat=true)
  let exprs = expression.expressions()
  if !self.cfg.multi_arg_distinct && exprs.length() > 1 {
    let mut case_ = exp_case()
    for arg in exprs {
      case_ = case_when(case_, exp_is(arg, null_()), null_())
    }
    this = self.sql(Some(case_else(case_, maybe_parse_str("(" + this + ")"))))
  }
  let this = g_pfx(" ", this)
  let on = g_pfx(" ON ", self.sql_key(expression, "on"))
  "DISTINCT" + this + on
}

///|
pub fn Generator::ignorenulls_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.embed_ignore_nulls(expression, "IGNORE NULLS")
}

///|
pub fn Generator::respectnulls_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.embed_ignore_nulls(expression, "RESPECT NULLS")
}

///|
pub fn Generator::havingmax_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = self.sql_key(expression, "this")
  let expression_sql = self.sql_key(expression, "expression")
  let kind = if expression.has("max") { "MAX" } else { "MIN" }
  this_sql + " HAVING " + kind + " " + expression_sql
}

///|
/// Python `_embed_ignore_nulls`.
pub fn Generator::embed_ignore_nulls(
  self : Generator,
  expression : Expr,
  text : String,
) -> String raise SqlglotError {
  let this = expression.this()
  match this {
    Some(t) if t.kind.is_any(
        self.cfg.respect_ignore_nulls_unsupported_expressions,
      ) => {
      self.unsupported(
        "RESPECT/IGNORE NULLS is not supported for \{t.kind.key()} in \{self.dialect_class_name()}",
      )
      return self.sql(this)
    }
    _ => ()
  }
  if self.cfg.ignore_nulls_in_func && !expression.meta_bool("inline") {
    if self.cfg.ignore_nulls_before_order {
      let found = gen_find_all_in_scope(expression, [HavingMax, Order, Limit])
      let priority = fn(x : Expr) -> Int {
        if x.kind.is_a(HavingMax) {
          0
        } else if x.kind.is_a(Order) {
          1
        } else {
          2
        }
      }
      let mut best : Expr? = None
      for x in found {
        match best {
          None => best = Some(x)
          Some(b) => if priority(x) < priority(b) { best = Some(x) }
        }
      }
      match best {
        Some(m) => {
          let mod_this = m.this_()
          let new_this = mk1(expression.kind, mod_this.copy())
          new_this.get_meta()["inline"] = Bool(true)
          mod_this.replace(Some(new_this)) |> ignore
          return self.sql(expression.this())
        }
        None => ()
      }
    }
    match expression.find([AggFunc]) {
      Some(agg_func) => {
        let s = self.sql(Some(agg_func), comment=false)
        let agg_func_sql = substr(s, 0, py_len(s) - 1) + " " + text + ")"
        return self.maybe_comment(agg_func_sql, comments?=agg_func.comments)
      }
      None => ()
    }
  }
  self.sql_key(expression, "this") + " " + text
}

///|
pub fn Generator::try_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !self.cfg.try_supported {
    self.unsupported("Unsupported TRY function")
    return self.sql_key(expression, "this")
  }
  self.func("TRY", [expression.get("this")])
}

///|
pub fn Generator::log_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = expression.get("this")
  let mut expr = expression.get("expression")
  match self.dialect.cfg.log_base_first {
    Some(false) => {
      let tmp = this
      this = expr
      expr = tmp
    }
    None if expr is Some(_) => {
      let name = match this {
        Some(Node(t)) => t.name()
        _ => ""
      }
      if name == "2" || name == "10" {
        return self.func("LOG" + name, [expr])
      }
      let this_sql = match this {
        Some(v) => self.sql_value(v)
        None => ""
      }
      self.unsupported("Unsupported logarithm with base \{this_sql}")
    }
    _ => ()
  }
  self.func("LOG", [this, expr])
}

///|
pub fn Generator::nvl2_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.nvl2_supported {
    return self.function_fallback_sql(expression)
  }
  let case_ = case_when(
    mk0(Case),
    exp_not(exp_is(expression.this_(), null_()), copy=false),
    match expression.arg("true") {
      Some(t) => t
      None => null_()
    },
    copy=false,
  )
  match expression.arg("false") {
    Some(else_cond) => case_else(case_, else_cond, copy=false) |> ignore
    None => ()
  }
  self.sql(Some(case_))
}

///|
pub fn Generator::nthvalue_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.get("from_first") is Some(Bool(false)) {
    self.unsupported("NTH_VALUE FROM LAST is not supported")
  }
  self.function_fallback_sql(expression)
}

///|
pub fn Generator::comprehension_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = self.sql_key(expression, "expression")
  let position = g_pfx(", ", self.sql_key(expression, "position"))
  let iterator = self.sql_key(expression, "iterator")
  let condition = g_pfx(" IF ", self.sql_key(expression, "condition"))
  this + " FOR " + expr + position + " IN " + iterator + condition
}

///|
pub fn Generator::columnprefix_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  "(" +
  self.sql_key(expression, "expression") +
  ")"
}

///|
pub fn Generator::opclass_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " " +
  self.sql_key(expression, "expression")
}

///|
/// Python `_ml_sql(expression, name)`.
pub fn Generator::ml_sql(
  self : Generator,
  expression : Expr,
  name : String,
) -> String raise SqlglotError {
  let model = "MODEL " + self.sql_key(expression, "this")
  let expr_sql : String? = match expression.expression() {
    Some(expr) => {
      let s = self.sql_key(expression, "expression")
      Some(if expr.kind.is_a(Table) { "TABLE " + s } else { s })
    }
    None => None
  }
  let parameters = self.sql_key(expression, "params_struct")
  let parameters : String? = if parameters != "" {
    Some(parameters)
  } else {
    None
  }
  self.func(name, [model, expr_sql, parameters])
}

///|
pub fn Generator::predict_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "PREDICT")
}

///|
pub fn Generator::generateembedding_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let name = if expression.has("is_text") {
    "GENERATE_TEXT_EMBEDDING"
  } else {
    "GENERATE_EMBEDDING"
  }
  self.ml_sql(expression, name)
}

///|
pub fn Generator::generatetext_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "GENERATE_TEXT")
}

///|
pub fn Generator::generatetable_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "GENERATE_TABLE")
}

///|
pub fn Generator::generatebool_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "GENERATE_BOOL")
}

///|
pub fn Generator::generateint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "GENERATE_INT")
}

///|
pub fn Generator::generatedouble_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "GENERATE_DOUBLE")
}

///|
pub fn Generator::mltranslate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "TRANSLATE")
}

///|
pub fn Generator::mlforecast_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.ml_sql(expression, "FORECAST")
}

///|
pub fn Generator::table_prefixed_sql(
  self : Generator,
  expression : Expr,
  key : String,
) -> String raise SqlglotError {
  let s = self.sql_key(expression, key)
  match expression.arg(key) {
    Some(t) if t.kind.is_a(Table) => "TABLE " + s
    _ => s
  }
}

///|
pub fn Generator::aiforecast_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = self.table_prefixed_sql(expression, "this")
  let args : Array[&SqlArg] = [this_sql]
  for
    k in [
      "data_col", "timestamp_col", "model", "id_cols", "horizon", "forecast_end_timestamp",
      "confidence_level", "output_historical_time_series", "context_window",
    ] {
    args.push(expression.get(k))
  }
  self.func("FORECAST", args)
}

///|
pub fn Generator::featuresattime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = self.table_prefixed_sql(expression, "this")
  self.func("FEATURES_AT_TIME", [
    this_sql,
    expression.get("time"),
    expression.get("num_rows"),
    expression.get("ignore_feature_nulls"),
  ])
}

///|
pub fn Generator::vectorsearch_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = self.table_prefixed_sql(expression, "this")
  let query_table = self.table_prefixed_sql(expression, "query_table")
  self.func("VECTOR_SEARCH", [
    this_sql,
    expression.get("column_to_search"),
    query_table,
    expression.get("query_column_to_search"),
    expression.get("top_k"),
    expression.get("distance_type"),
    expression.get("options"),
  ])
}

///|
pub fn Generator::forin_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expression_sql = self.sql_key(expression, "expression")
  "FOR " + this + " DO " + expression_sql
}

///|
pub fn Generator::refresh_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = match expression.this() {
    Some(t) if t.kind.is_a(Literal) => ""
    _ => expression.text("kind") + " "
  }
  "REFRESH " + kind + this
}

///|
pub fn Generator::toarray_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut arg = expression.this_()
  if arg.get_type() is None {
    arg = gen_annotate_types(arg, self.dialect)
  }
  if arg.is_type([DType::ARRAY]) {
    return self.sql(Some(arg))
  }
  let cond_for_null = exp_is(arg, null_())
  self.sql(
    Some(
      mk(If, [
        ("this", cond_for_null.copy()),
        ("true", null_()),
        ("false", mk(Kind::Array, [("expressions", [arg])]).copy()),
      ]),
    ),
  )
}

///|
pub fn Generator::tsordstotime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.this_()
  let time_format = self.format_time(expression)
  if g_str_truthy(time_format) {
    return self.sql(
      Some(
        exp_cast(
          mk(StrToTime, [("this", this), ("format", expression.arg("format"))]),
          DType::TIME,
        ),
      ),
    )
  }
  if this.kind.is_a(TsOrDsToTime) || this.is_type([DType::TIME]) {
    return self.sql(Some(this))
  }
  self.sql(Some(exp_cast(this, DType::TIME)))
}

///|
pub fn Generator::tsordstotimestamp_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.this_()
  if this.kind.is_a(TsOrDsToTimestamp) || this.is_type([DType::TIMESTAMP]) {
    return self.sql(Some(this))
  }
  self.sql(Some(exp_cast(this, DType::TIMESTAMP, dialect=self.dialect)))
}

///|
pub fn Generator::tsordstodatetime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.this_()
  if this.kind.is_a(TsOrDsToDatetime) || this.is_type([DType::DATETIME]) {
    return self.sql(Some(this))
  }
  self.sql(Some(exp_cast(this, DType::DATETIME, dialect=self.dialect)))
}

///|
pub fn Generator::tsordstodate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.this_()
  let time_format = self.format_time(expression)
  let safe = expression.get("safe")
  match time_format {
    Some(tf) if tf != "" &&
      tf != self.dialect.cfg.time_format &&
      tf != self.dialect.cfg.date_format =>
      return self.sql(
        Some(
          exp_cast(
            mk(StrToTime, [
              ("this", this),
              ("format", expression.arg("format")),
              ("safe", safe),
            ]),
            DType::DATE,
          ),
        ),
      )
    _ => ()
  }
  if this.kind.is_a(TsOrDsToDate) || this.is_type([DType::DATE]) {
    return self.sql(Some(this))
  }
  match safe {
    Some(v) if v.truthy() =>
      return self.sql(
        Some(mk(TryCast, [("this", this), ("to", datatype_of(DType::DATE))])),
      )
    _ => ()
  }
  self.sql(Some(exp_cast(this, DType::DATE)))
}

///|
pub fn Generator::unixdate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(
    Some(
      mk(DateDiff, [
        ("this", expression.this_().copy()),
        ("expression", exp_cast(literal_string("1970-01-01"), DType::DATE)),
        ("unit", mk1(Column, to_identifier("day"))),
      ]),
    ),
  )
}

///|
pub fn Generator::lastday_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.last_day_supports_date_part {
    return self.function_fallback_sql(expression)
  }
  match expression.arg("unit") {
    Some(unit) if py_upper(unit.name()) != "MONTH" =>
      self.unsupported("Date parts are not supported in LAST_DAY.")
    _ => ()
  }
  self.func("LAST_DAY", [expression.get("this")])
}

///|
pub fn Generator::dateadd_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("DATE_ADD", [
    expression.arg("this"),
    expression.arg("expression"),
    gen_unit_to_str(expression),
  ])
}

///|
/// Virtual `arrayinsert_sql(expression, index_offset)`.
pub fn Generator::arrayinsert_sql_v(
  self : Generator,
  expression : Expr,
  index_offset? : Int = 0,
) -> String raise SqlglotError {
  match self.fns.hooks.arrayinsert_sql {
    Some(f) => f(self, expression, index_offset)
    None => self.arrayinsert_sql(expression, index_offset~)
  }
}

///|
pub fn Generator::arrayinsert_sql(
  self : Generator,
  expression : Expr,
  index_offset? : Int = 0,
) -> String raise SqlglotError {
  let this = expression.this_()
  let mut position = expression.arg("position")
  let stored_offset = match expression.get("offset") {
    Some(Int(i)) => i.to_int()
    Some(Bool(b)) => if b { 1 } else { 0 }
    Some(Node(n)) =>
      match n.to_py_int() {
        Some(v) => v.to_int()
        None => 0
      }
    _ => 0
  }
  let offset = index_offset - stored_offset
  if offset != 0 {
    match position {
      Some(p) if p.is_int() => {
        let value = p.to_py_int().unwrap()
        if value >= 0L {
          position = Some(
            literal_number((value + offset.to_int64()).to_string()),
          )
        } else if offset < 0 && value == -1L {
          position = Some(mk1(ArraySize, this.copy()))
        } else {
          position = Some(
            literal_number((value - offset.to_int64()).to_string()),
          )
        }
      }
      _ =>
        self.unsupported(
          "ARRAY_INSERT position can only be converted if it's a literal",
        )
    }
  }
  self.func("ARRAY_INSERT", [Some(this), position, expression.arg("expression")])
}

///|
pub fn Generator::arrayany_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.can_implement_array_any {
    let filtered = mk2(
      ArrayFilter,
      expression.get("this"),
      expression.get("expression"),
    )
    let filtered_not_empty = exp_neq(mk1(ArraySize, filtered), literal_int(0))
    let original_is_empty = exp_eq(
      mk1(ArraySize, expression.get("this")),
      literal_int(0),
    )
    return self.sql(
      Some(exp_paren(exp_or([original_is_empty, filtered_not_empty]))),
    )
  }
  if self.dialect.name != "" {
    self.unsupported("ARRAY_ANY is unsupported")
  }
  self.function_fallback_sql(expression)
}

///|
pub fn Generator::struct_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let new_exprs = []
  for e in expression.expressions() {
    if e.kind.is_a(PropertyEQ) {
      let alias_ : Value = match e.this() {
        Some(t) if t.is_string() => Str(e.name())
        _ =>
          match e.get("this") {
            Some(v) => v
            None => Str("")
          }
      }
      new_exprs.push(exp_alias(e.expression_(), alias_))
    } else {
      new_exprs.push(e)
    }
  }
  expression.set("expressions", new_exprs)
  self.function_fallback_sql(expression)
}

///|
pub fn Generator::partitionrange_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let low = self.sql_key(expression, "this")
  let high = self.sql_key(expression, "expression")
  low + " TO " + high
}

///|
pub fn Generator::convert_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut to = match expression.this() {
    Some(t) => t
    None => return ""
  }
  let value = match expression.expression() {
    Some(v) => v
    None => return ""
  }
  let style = expression.arg("style")
  let safe = expression.get("safe")
  let strict = expression.has("strict")
  let to_this = to.datatype_this()
  let is_param_text = match to_this {
    Some(d) => self.cfg.parameterizable_text_types.contains(d)
    None => false
  }
  if to.expressions().is_empty() && is_param_text {
    to = datatype_build(to_this.unwrap(), kwargs=[
      ("expressions", [literal_int(30)]),
      ("nested", false),
    ])
  }
  let to_this = to.datatype_this()
  let cast_kind = if strict { Kind::Cast } else { Kind::TryCast }
  let mut transformed : Expr? = None
  match style {
    Some(st) if st.kind.is_a(Literal) && st.is_int() => {
      let style_value = st.name()
      let converted_style = match tsql_convert_format_mapping.get(style_value) {
        Some(s) => s
        None => {
          self.unsupported("Unsupported T-SQL 'style' value: \{style_value}")
          "None"
        }
      }
      let fmt = literal_string(converted_style)
      if to_this == Some(DType::DATE) {
        transformed = Some(mk(StrToDate, [("this", value), ("format", fmt)]))
      } else if to_this == Some(DType::DATETIME) ||
        to_this == Some(DType::DATETIME2) {
        transformed = Some(mk(StrToTime, [("this", value), ("format", fmt)]))
      } else if is_param_text {
        transformed = Some(
          mk(cast_kind, [
            ("this", mk(TimeToStr, [("this", value), ("format", fmt)])),
            ("to", to),
            ("safe", safe),
          ]),
        )
      } else if to_this == Some(DType::TEXT) {
        transformed = Some(mk(TimeToStr, [("this", value), ("format", fmt)]))
      }
    }
    _ => ()
  }
  let transformed = match transformed {
    Some(t) => t
    None => mk(cast_kind, [("this", value), ("to", to), ("safe", safe)])
  }
  self.sql(Some(transformed))
}

///|
pub fn Generator::querytransform_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let transform = self.func("TRANSFORM", g_fargs(expression.expressions()))
  let row_format_before = g_pfx(
    " ",
    self.sql_key(expression, "row_format_before"),
  )
  let record_writer = g_pfx(
    " RECORDWRITER ",
    self.sql_key(expression, "record_writer"),
  )
  let using_ = " USING " + self.sql_key(expression, "command_script")
  let schema = g_pfx(" AS ", self.sql_key(expression, "schema"))
  let row_format_after = g_pfx(" ", self.sql_key(expression, "row_format_after"))
  let record_reader = g_pfx(
    " RECORDREADER ",
    self.sql_key(expression, "record_reader"),
  )
  transform +
  row_format_before +
  record_writer +
  using_ +
  schema +
  row_format_after +
  record_reader
}

///|
pub fn Generator::anyvalue_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  let having = self.sql_key(expression, "having")
  if having != "" {
    this = this +
      " HAVING " +
      (if expression.has("max") { "MAX" } else { "MIN" }) +
      " " +
      having
  }
  self.func("ANY_VALUE", [this])
}

///|
pub fn Generator::gapfill_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = "TABLE " + self.sql_key(expression, "this")
  let args : Array[&SqlArg] = [this]
  for k, v in expression.args {
    if k != "this" {
      args.push(v)
    }
  }
  self.func("GAP_FILL", args)
}

///|
/// Virtual `scope_resolution`.
pub fn Generator::scope_resolution(
  self : Generator,
  rhs : String,
  scope_name : String,
) -> String raise SqlglotError {
  match self.fns.hooks.scope_resolution {
    Some(f) => f(self, rhs, scope_name)
    None => self.scope_resolution_base(rhs, scope_name)
  }
}

///|
pub fn Generator::scope_resolution_base(
  self : Generator,
  rhs : String,
  scope_name : String,
) -> String raise SqlglotError {
  let scope : String? = if scope_name != "" { Some(scope_name) } else { None }
  self.func("SCOPE_RESOLUTION", [scope, Some(rhs)])
}

///|
pub fn Generator::scoperesolution_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = match expression.expression() {
    Some(e) if e.kind.is_a(Func) =>
      self.sql_key(e, "this") +
      "(" +
      self.format_args(g_fargs(e.expressions())) +
      ")"
    _ => self.sql_key(expression, "expression")
  }
  self.scope_resolution(expr, this)
}

///|
pub fn Generator::parsejson_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match self.cfg.parse_json_name {
    None => self.sql(expression.this())
    Some(name) =>
      self.func(name, [expression.get("this"), expression.get("expression")])
  }
}

///|
pub fn Generator::rand_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let lower = self.sql_key(expression, "lower")
  let upper = self.sql_key(expression, "upper")
  if lower != "" && upper != "" {
    return "(" +
      upper +
      " - " +
      lower +
      ") * " +
      self.func("RAND", [expression.get("this")]) +
      " + " +
      lower
  }
  self.func("RAND", [expression.get("this")])
}

///|
pub fn Generator::changes_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let information = "INFORMATION => " + self.sql_key(expression, "information")
  let at_before = g_pfx(self.seg(""), self.sql_key(expression, "at_before"))
  let end = g_pfx(self.seg(""), self.sql_key(expression, "end"))
  "CHANGES (" + information + ")" + at_before + end
}

///|
pub fn Generator::pad_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let prefix = if expression.has("is_left") { "L" } else { "R" }
  let fill_pattern = self.sql_key(expression, "fill_pattern")
  let fill_pattern : String? = if fill_pattern != "" {
    Some(fill_pattern)
  } else if self.cfg.pad_fill_pattern_is_required {
    Some("' '")
  } else {
    None
  }
  self.func(prefix + "PAD", [
    expression.get("this"),
    expression.get("expression"),
    fill_pattern.map(s => Str(s)),
  ])
}

///|
pub fn Generator::summarize_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let table = g_when(expression.has("table"), " TABLE")
  "SUMMARIZE" + table + " " + self.sql(expression.this())
}

///|
pub fn Generator::explodinggenerateseries_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let generate_series = Expr::new(
    GenerateSeries,
    Args::from_iter(expression.args.iter()),
  )
  let mut parent = expression.parent
  match parent {
    Some(p) if p.kind.is_any([Alias, TableAlias]) => parent = p.parent
    _ => ()
  }
  let parent_is = fn(kinds : Array[Kind]) {
    match parent {
      Some(p) => p.kind.is_any(kinds)
      None => false
    }
  }
  if self.cfg.supports_exploding_projections && !parent_is([Table, Unnest]) {
    return self.sql(Some(mk(Unnest, [("expressions", [generate_series])])))
  }
  if parent_is([Select]) {
    self.unsupported("GenerateSeries projection unnesting is not supported.")
  }
  self.sql(Some(generate_series))
}

///|
pub fn Generator::converttimezone_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.supports_convert_timezone {
    return self.function_fallback_sql(expression)
  }
  let source_tz = expression.arg("source_tz")
  let target_tz = expression.arg("target_tz")
  let mut timestamp = expression.arg("timestamp")
  match (source_tz, timestamp) {
    (Some(stz), Some(ts)) =>
      timestamp = Some(
        mk(AtTimeZone, [
          ("this", exp_cast(ts, DType::TIMESTAMPNTZ)),
          ("zone", stz),
        ]),
      )
    _ => ()
  }
  let expr = mk(AtTimeZone, [("this", timestamp), ("zone", target_tz)])
  self.sql(Some(expr))
}

///|
pub fn Generator::json_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = g_pfx(" ", self.sql_key(expression, "this"))
  let with_sql = match expression.get("with_") {
    None => ""
    Some(v) => if !v.truthy() { " WITHOUT" } else { " WITH" }
  }
  let unique_sql = g_when(expression.has("unique"), " UNIQUE KEYS")
  "JSON" + this + with_sql + unique_sql
}

///|
pub fn Generator::jsonvalue_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let path = self.sql_key(expression, "path")
  let returning = g_pfx(" RETURNING ", self.sql_key(expression, "returning"))
  let on_condition = g_pfx(" ", self.sql_key(expression, "on_condition"))
  self.func("JSON_VALUE", [
    expression.get("this"),
    Some(Str(path + returning + on_condition)),
  ])
}

///|
pub fn Generator::skipjsoncolumn_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let regexp = g_when(expression.has("regexp"), " REGEXP")
  "SKIP" + regexp + " " + self.sql(expression.expression())
}

///|
pub fn Generator::conditionalinsert_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let else_ = g_when(expression.has("else_"), "ELSE ")
  let condition = self.sql_key(expression, "expression")
  let condition = if condition != "" {
    "WHEN " + condition + " THEN "
  } else {
    else_
  }
  let insert = py_strip(g_str_from(self.sql_key(expression, "this"), 6))
  condition + insert
}

///|
pub fn Generator::multitableinserts_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let kind = self.sql_key(expression, "kind")
  let expressions = self.seg(self.expressions(expression~, sep=" "))
  "INSERT " + kind + expressions + self.seg(self.sql_key(expression, "source"))
}

///|
pub fn Generator::oncondition_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut empty = match expression.get("empty") {
    Some(Node(e)) => "DEFAULT " + expr_to_sql(e) + " ON EMPTY"
    _ => self.sql_key(expression, "empty")
  }
  let mut error = match expression.get("error") {
    Some(Node(e)) => "DEFAULT " + expr_to_sql(e) + " ON ERROR"
    _ => self.sql_key(expression, "error")
  }
  if error != "" && empty != "" {
    error = if self.dialect.cfg.on_condition_empty_before_error {
      empty + " " + error
    } else {
      error + " " + empty
    }
    empty = ""
  }
  let null = self.sql_key(expression, "null")
  empty + error + null
}

///|
pub fn Generator::jsonextractquote_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let scalar = g_when(expression.has("scalar"), " ON SCALAR STRING")
  self.sql_key(expression, "option") + " QUOTES" + scalar
}

///|
pub fn Generator::jsonexists_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let path = self.sql_key(expression, "path")
  let passing = g_pfx(" PASSING ", self.expressions(expression~, key="passing"))
  let on_condition = g_pfx(" ", self.sql_key(expression, "on_condition"))
  let path = path + passing + on_condition
  self.func("JSON_EXISTS", [this, path])
}

///|
/// Python `_add_arrayagg_null_filter`.
pub fn Generator::add_arrayagg_null_filter(
  self : Generator,
  array_agg_sql : String,
  array_agg_expr : Expr,
  column_expr : Expr?,
) -> String raise SqlglotError {
  if !(self.dialect.cfg.array_agg_includes_nulls == Some(true) &&
    array_agg_expr.has("nulls_excluded")) {
    return array_agg_sql
  }
  let mut array_agg_sql = array_agg_sql
  match array_agg_expr.parent {
    Some(parent) if parent.kind.is_a(Filter) => {
      let parent_cond = parent.expression_().this_()
      match column_expr {
        Some(c) =>
          parent_cond.replace(
            Some(exp_and([parent_cond, exp_not(exp_is(c, null_()))])),
          )
          |> ignore
        None => ()
      }
    }
    _ =>
      match column_expr {
        Some(c) if c.find([Column]) is Some(_) => {
          let this_sql = if c.kind.is_a(Distinct) {
            self.expressions(expression=c)
          } else {
            self.sql(Some(c))
          }
          array_agg_sql = array_agg_sql +
            " FILTER(WHERE " +
            this_sql +
            " IS NOT NULL)"
        }
        _ => ()
      }
  }
  array_agg_sql
}

///|
pub fn Generator::arrayagg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let array_agg = self.function_fallback_sql(expression)
  let mut column_expr = expression.this()
  match column_expr {
    Some(c) if c.kind.is_a(Order) => column_expr = c.this()
    _ => ()
  }
  self.add_arrayagg_null_filter(array_agg, expression, column_expr)
}

///|
pub fn Generator::apply_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = self.sql_key(expression, "expression")
  this + " APPLY(" + expr + ")"
}

///|
pub fn Generator::columns_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let func = self.function_fallback_sql(expression)
  if expression.has("unpack") {
    "*" + func
  } else {
    func
  }
}

///|
pub fn Generator::overlay_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = self.sql_key(expression, "expression")
  let from_sql = self.sql_key(expression, "from_")
  let for_sql = g_pfx(" FOR ", self.sql_key(expression, "for_"))
  "OVERLAY(" + this + " PLACING " + expr + " FROM " + from_sql + for_sql + ")"
}

///|
pub fn Generator::todouble_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.unsupported_args(expression, ["format"])
  let cast_kind = if expression.has("safe") {
    Kind::TryCast
  } else {
    Kind::Cast
  }
  self.sql(
    Some(
      mk(cast_kind, [
        ("this", expression.get("this")),
        ("to", Some(Node(DType::DOUBLE.into_expr()))),
      ]),
    ),
  )
}

///|
pub fn Generator::string_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = expression.this_()
  match expression.arg("zone") {
    Some(zone) =>
      this = mk(ConvertTimezone, [
        ("source_tz", literal_string("UTC")),
        ("target_tz", zone),
        ("timestamp", this),
      ])
    None => ()
  }
  self.sql(Some(exp_cast(this, DType::VARCHAR)))
}

///|
pub fn Generator::median_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if !self.cfg.supports_median {
    return self.sql(
      Some(
        mk(PercentileCont, [
          ("this", expression.get("this")),
          ("expression", Some(Node(literal_number("0.5")))),
        ]),
      ),
    )
  }
  self.function_fallback_sql(expression)
}

///|
pub fn Generator::overflowtruncatebehavior_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let filler = g_pfx(" ", self.sql_key(expression, "this"))
  let with_count = if expression.has("with_count") {
    "WITH COUNT"
  } else {
    "WITHOUT COUNT"
  }
  "TRUNCATE" + filler + " " + with_count
}

///|
pub fn Generator::unixseconds_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.supports_unix_seconds {
    return self.function_fallback_sql(expression)
  }
  let start_ts = exp_cast(
    literal_string("1970-01-01 00:00:00+00"),
    DType::TIMESTAMPTZ,
  )
  self.sql(
    Some(
      mk(TimestampDiff, [
        ("this", expression.get("this")),
        ("expression", Some(Node(start_ts))),
        ("unit", Some(Node(var_("SECONDS")))),
      ]),
    ),
  )
}

///|
pub fn Generator::arraysize_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut dim = expression.expression()
  match dim {
    Some(d) if self.cfg.array_size_dim_required is None => {
      if !(d.is_int() && d.name() == "1") {
        self.unsupported("Cannot transpile dimension argument for ARRAY_LENGTH")
      }
      dim = None
    }
    _ => ()
  }
  if self.cfg.array_size_dim_required == Some(true) && dim is None {
    dim = Some(literal_int(1))
  }
  self.func(self.cfg.array_size_name, [expression.arg("this"), dim])
}

///|
pub fn Generator::xmlelement_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let prefix = if expression.has("evalname") { "EVALNAME" } else { "NAME" }
  let name = prefix + " " + self.sql_key(expression, "this")
  let args : Array[&SqlArg] = [name]
  for e in expression.expressions() {
    args.push(e)
  }
  self.func("XMLELEMENT", args)
}

///|
pub fn Generator::xmlkeyvalueoption_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = g_around("(", self.sql_key(expression, "expression"), ")")
  this + expr
}

///|
pub fn Generator::xmltable_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let namespaces = g_around(
    "XMLNAMESPACES(",
    self.expressions(expression~, key="namespaces"),
    "), ",
  )
  let passing = self.expressions(expression~, key="passing")
  let passing = if passing != "" {
    self.sep() + "PASSING" + self.seg(passing)
  } else {
    ""
  }
  let columns = self.expressions(expression~, key="columns")
  let columns = if columns != "" {
    self.sep() + "COLUMNS" + self.seg(columns)
  } else {
    ""
  }
  let by_ref = if expression.has("by_ref") {
    self.sep() + "RETURNING SEQUENCE BY REF"
  } else {
    ""
  }
  "XMLTABLE(" +
  self.sep(sep="") +
  self.indent(namespaces + this + passing + by_ref + columns) +
  self.seg(")", sep="")
}

///|
pub fn Generator::xmlnamespace_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  match expression.this() {
    Some(t) if t.kind.is_a(Alias) => this
    _ => "DEFAULT " + this
  }
}

///|
pub fn Generator::parameterizedagg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let params = self.expressions(expression~, key="params", flat=true)
  self.func(expression.name(), g_fargs(expression.expressions())) +
  "(" +
  params +
  ")"
}

///|
pub fn Generator::anonymousaggfunc_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func(expression.name(), g_fargs(expression.expressions()))
}

///|
pub fn Generator::combinedaggfunc_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.call_method(AnonymousAggFunc, expression)
}

///|
pub fn Generator::combinedparameterizedagg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.call_method(ParameterizedAgg, expression)
}

///|
pub fn Generator::translatecharacters_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = self.sql_key(expression, "expression")
  let with_error = g_when(expression.has("with_error"), " WITH ERROR")
  "TRANSLATE(" + this + " USING " + expr + with_error + ")"
}

///|
pub fn Generator::decodecase_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.supports_decode_case {
    return self.func("DECODE", g_fargs(expression.expressions()))
  }
  let all = expression.expressions()
  let decode_expr = all[0]
  let expressions = all[1:].to_owned()
  let ifs = []
  let mut i = 0
  while i + 1 < expressions.length() {
    let mut search = expressions[i]
    let result = expressions[i + 1]
    if search.kind.is_a(Literal) {
      ifs.push(
        mk(If, [("this", exp_eq(decode_expr, search)), ("true", result)]),
      )
    } else if search.kind.is_a(Null) {
      ifs.push(
        mk(If, [("this", exp_is(decode_expr, mk0(Null))), ("true", result)]),
      )
    } else {
      if search.kind.is_a(Binary) {
        search = exp_paren(search)
      }
      let cond = exp_or(
        [
          exp_eq(decode_expr, search),
          exp_and(
            [exp_is(decode_expr, mk0(Null)), exp_is(search, mk0(Null))],
            copy=false,
          ),
        ],
        copy=false,
      )
      ifs.push(mk(If, [("this", cond), ("true", result)]))
    }
    i += 2
  }
  let default : Expr? = if expressions.length() % 2 == 1 {
    Some(expressions[expressions.length() - 1])
  } else {
    None
  }
  self.sql(Some(mk(Case, [("ifs", ifs), ("default", default)])))
}

///|
pub fn Generator::semanticview_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.seg(self.sql_key(expression, "this"), sep="")
  let dimensions = self.expressions(
    expression~,
    key="dimensions",
    dynamic=true,
    skip_first=true,
    skip_last=true,
  )
  let dimensions = if dimensions != "" {
    self.seg("DIMENSIONS " + dimensions)
  } else {
    ""
  }
  let metrics = self.expressions(
    expression~,
    key="metrics",
    dynamic=true,
    skip_first=true,
    skip_last=true,
  )
  let metrics = if metrics != "" { self.seg("METRICS " + metrics) } else { "" }
  let facts = self.expressions(
    expression~,
    key="facts",
    dynamic=true,
    skip_first=true,
    skip_last=true,
  )
  let facts = if facts != "" { self.seg("FACTS " + facts) } else { "" }
  let where_ = self.sql_key(expression, "where")
  let where_ = if where_ != "" { self.seg("WHERE " + where_) } else { "" }
  let body = self.indent(
    this + metrics + dimensions + facts + where_,
    skip_first=true,
  )
  "SEMANTIC_VIEW(" + body + self.seg(")", sep="")
}

///|
pub fn Generator::getextract_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = expression.this_()
  let expr = expression.expression()
  if this.get_type() is None || expression.get_type() is None {
    this = gen_annotate_types(this, self.dialect)
  }
  if this.is_type([DType::ARRAY, DType::MAP]) {
    return self.sql(
      Some(
        mk(Bracket, [
          ("this", Some(this)),
          (
            "expressions",
            match expr {
              Some(x) => [x]
              None => []
            },
          ),
        ]),
      ),
    )
  }
  self.sql(
    Some(
      mk(JSONExtract, [
        ("this", Some(this)),
        ("expression", self.dialect.to_json_path(expr)),
      ]),
    ),
  )
}

///|
pub fn Generator::datefromunixdate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(
    Some(
      mk(DateAdd, [
        ("this", exp_cast(literal_string("1970-01-01"), DType::DATE)),
        ("expression", expression.this_()),
        ("unit", var_("DAY")),
      ]),
    ),
  )
}

///|
pub fn Generator::space_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(
    Some(
      mk(Repeat, [
        ("this", Some(Node(literal_string(" ")))),
        ("times", expression.get("this")),
      ]),
    ),
  )
}

///|
pub fn Generator::modelattribute_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported("The model!attribute syntax is not supported")
  ""
}

///|
pub fn Generator::directorystage_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.func("DIRECTORY", [expression.get("this")])
}

///|
pub fn Generator::uuid_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let is_string = expression.has("is_string")
  let uuid_func_sql = self.func("UUID", [])
  if is_string && !self.dialect.cfg.uuid_is_string_type {
    return self.sql(
      Some(
        exp_cast(
          maybe_parse_str(uuid_func_sql, dialect=self.dialect),
          DType::VARCHAR,
          dialect=self.dialect,
        ),
      ),
    )
  }
  uuid_func_sql
}

///|
pub fn Generator::initcap_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut delimiters = expression.expression()
  match delimiters {
    Some(d) =>
      if d.is_string() &&
        d.text("this") == self.dialect.cfg.initcap_default_delimiter_chars {
        delimiters = None
      } else if !self.dialect.cfg.initcap_supports_custom_delimiters {
        self.unsupported("INITCAP does not support custom delimiters")
        delimiters = None
      }
    None => ()
  }
  self.func("INITCAP", [expression.arg("this"), delimiters])
}

///|
pub fn Generator::localtime_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.get("this") {
    Some(v) if v.truthy() => self.func("LOCALTIME", [v])
    _ => "LOCALTIME"
  }
}

///|
pub fn Generator::localtimestamp_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.get("this") {
    Some(v) if v.truthy() => self.func("LOCALTIMESTAMP", [v])
    _ => "LOCALTIMESTAMP"
  }
}

///|
pub fn Generator::weekstart_name(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = match expression.this() {
    Some(t) => py_upper(t.name())
    None => ""
  }
  let dow_from_week_start_day = gen_week_start_day_to_dow.get(this)
  let dow_from_week_offset = gen_week_offset_to_dow(self.dialect.cfg.week_offset)
  if dow_from_week_start_day != Some(dow_from_week_offset) {
    self.unsupported(
      "WEEK(\{this}) is not supported; falling back to the default week start day",
    )
  }
  "WEEK"
}

///|
pub fn Generator::weekstart_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let name = self.weekstart_name(expression)
  match expression.parent {
    Some(p) if p.kind.is_a(DateTrunc) => self.sql(Some(literal_string(name)))
    _ => name
  }
}

///|
/// Virtual `chr_sql(expression, name)`.
pub fn Generator::chr_sql_v(
  self : Generator,
  expression : Expr,
  name? : String = "CHR",
) -> String raise SqlglotError {
  match self.fns.hooks.chr_sql {
    Some(f) => f(self, expression, name)
    None => self.chr_sql(expression, name~)
  }
}

///|
pub fn Generator::chr_sql(
  self : Generator,
  expression : Expr,
  name? : String = "CHR",
) -> String raise SqlglotError {
  let this = self.expressions(expression~)
  let charset = self.sql_key(expression, "charset")
  let using_ = g_pfx(" USING ", charset)
  self.func(name, [this + using_])
}

///|
pub fn Generator::block_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.expressions(expression~, sep="; ", flat=true)
  let begin = g_when(expression.has("begin"), "BEGIN ")
  if expressions != "" {
    begin + expressions
  } else {
    ""
  }
}

///|
pub fn Generator::unsupported_stmt(
  self : Generator,
  message : String,
) -> String raise SqlglotError {
  self.unsupported(message)
  ""
}

///|
pub fn Generator::functionspecification_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Inline UDFs syntax")
}

///|
pub fn Generator::storedprocedure_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Stored Procedure syntax")
}

///|
pub fn Generator::ifblock_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported If block syntax")
}

///|
pub fn Generator::casestatement_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Case statement syntax")
}

///|
pub fn Generator::whileblock_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported While block syntax")
}

///|
pub fn Generator::loopblock_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Loop block syntax")
}

///|
pub fn Generator::repeatblock_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Repeat block syntax")
}

///|
pub fn Generator::leave_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Leave syntax")
}

///|
pub fn Generator::iterate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Iterate syntax")
}

///|
pub fn Generator::execute_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Execute syntax")
}

///|
pub fn Generator::executesql_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  ignore(expression)
  self.unsupported_stmt("Unsupported Execute syntax")
}

///|
pub fn Generator::userdefinedfunction_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expressions = self.no_identify(() => self.expressions(expression~))
  let expressions = if expression.has("wrapped") {
    self.wrap_str(expressions)
  } else {
    " " + expressions
  }
  if py_strip(expressions) != "" {
    this + expressions
  } else {
    this
  }
}

///|
pub fn Generator::macrooverloads_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.expressions(expression~, flat=true)
}

///|
pub fn Generator::macrooverload_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let params = self.no_identify(() => self.expressions(expression~, flat=true))
  let body = self.sql_key(expression, "this")
  let prefix = g_when(expression.has("is_table"), "TABLE ")
  "(" + params + ") AS " + prefix + body
}

///|
pub fn Generator::joinhint_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expressions = self.expressions(expression~, flat=true)
  this + "(" + expressions + ")"
}

///|
pub fn Generator::tag_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  py_str_value(expression.get("prefix")) +
  self.sql(expression.this()) +
  py_str_value(expression.get("postfix"))
}

///|
pub fn Generator::nextvaluefor_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let order = match expression.arg("order") {
    Some(o) => " OVER (" + self.order_sql(o, flat=true) + ")"
    None => ""
  }
  "NEXT VALUE FOR " + self.sql_key(expression, "this") + order
}

///|
pub fn Generator::hex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut text = self.func(self.cfg.hex_func, [self.sql_key(expression, "this")])
  if self.dialect.cfg.hex_lowercase {
    text = self.func("LOWER", [text])
  }
  text
}

///|
pub fn Generator::lowerhex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut text = self.func(self.cfg.hex_func, [self.sql_key(expression, "this")])
  if !self.dialect.cfg.hex_lowercase {
    text = self.func("LOWER", [text])
  }
  text
}

///|
pub fn Generator::dynamicidentifier_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = expression.this()
  match this {
    Some(t) if t.is_string() => {
      let resolved = self.dialect.generate_sql(maybe_parse_str(t.name()))
      if expression.has_key("expressions") {
        self.unsupported(
          "Transpiling dynamically-invoked IDENTIFIER() functions is unsupported",
        )
      }
      return resolved
    }
    _ => ()
  }
  self.unsupported("IDENTIFIER() with non-literal arguments is not supported")
  self.func("IDENTIFIER", [this])
}

///|
/// Python `Dialect.generate(expression)` / `expression.sql(dialect)` with default options.
pub fn Dialect::generate_sql(
  self : Dialect,
  expression : Expr,
) -> String raise SqlglotError {
  Generator::new(self).generate(expression)
}

///|
pub fn Generator::booland_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "((" +
  self.sql_key(expression, "this") +
  ") AND (" +
  self.sql_key(expression, "expression") +
  "))"
}

///|
pub fn Generator::boolor_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "((" +
  self.sql_key(expression, "this") +
  ") OR (" +
  self.sql_key(expression, "expression") +
  "))"
}

///|
pub fn Generator::semicolon_sql(self : Generator, expression : Expr) -> String {
  ignore((self, expression))
  ""
}
