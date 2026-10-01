// Module-level helpers of sqlglot/dialects/dialect.py (from `rename_func` to the end of
// the file) shared by dialect generators. Builders used by dialect parsers live in
// dialect_helpers_parse.mbt; date/time/unit helpers in dialect_helpers_time.mbt.
//
// Conventions:
//   * Python `def f(self: Generator, expression)` -> `pub fn f(g : Generator, e : Expr)`
//     (directly usable as a `GenFn` when there are no extra parameters).
//   * Python higher-order helpers returning generator callables return `GenFn`.
//   * Python keyword arguments become optional labeled arguments.

///|
/// Python `flatten(expression.args.values())` as `func` arguments.
fn flatten_arg_values(e : Expr) -> Array[&SqlArg] {
  let out : Array[&SqlArg] = []
  fn go(v : Value) {
    match v {
      List(l) =>
        for x in l {
          go(x)
        }
      v => out.push(v)
    }
  }
  for _, v in e.args {
    go(v)
  }
  out
}

///|
/// Converts expressions to `func` arguments.
fn expr_sql_args(xs : Array[Expr]) -> Array[&SqlArg] {
  xs.map(x => (x : &SqlArg))
}

///|
/// Python `rename_func(name)`: renders the expression as `name(<all args>)`.
pub fn rename_func(name : String) -> GenFn {
  (g, e) => g.func(name, flatten_arg_values(e))
}

///|
/// Python `bracket_to_element_at_sql`.
pub fn bracket_to_element_at_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let offset = match e.get("offset") {
    Some(Int(i)) => i
    _ => 0
  }
  let index = gen_apply_index_offset(
    e.this_(),
    e.expressions(),
    1 - offset,
    g.dialect,
  ).get(0)
  g.func("ELEMENT_AT", [e.this(), index])
}

///|
/// Python `approx_count_distinct_sql`.
pub fn approx_count_distinct_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  g.unsupported_args(e, ["accuracy"])
  g.func("APPROX_COUNT_DISTINCT", [e.this()])
}

///|
/// Python `if_sql(name, false_value)`.
pub fn if_sql(name? : String = "IF", false_value? : Expr) -> GenFn {
  (g, e) => {
    let false_ : &SqlArg = match e.get("false") {
      Some(v) if v.truthy() => (v : &SqlArg)
      _ => (false_value : &SqlArg)
    }
    g.func(name, [e.this(), e.get("true"), false_])
  }
}

///|
/// Python `if_sql(name, false_value)` with a string `false_value` (raw SQL).
pub fn if_sql_str(name? : String = "IF", false_value : String) -> GenFn {
  (g, e) => {
    let false_ : &SqlArg = match e.get("false") {
      Some(v) if v.truthy() => (v : &SqlArg)
      _ => (false_value : &SqlArg)
    }
    g.func(name, [e.this(), e.get("true"), false_])
  }
}

///|
/// Python `arrow_json_extract_sql(self, expression, op=None)`.
pub fn arrow_json_extract_sql(
  g : Generator,
  e : Expr,
  op? : String,
) -> String raise SqlglotError {
  match e.this() {
    Some(this) if g.cfg.json_type_required_for_extraction &&
      this.kind == Literal &&
      this.is_string() =>
      this.replace(Some(exp_cast(this, DType::JSON))) |> ignore
    _ => ()
  }
  match e.expression() {
    Some(ex) if ex.kind.is_any([Binary, Predicate, Not]) =>
      e.set("expression", exp_paren(ex, copy=false))
    _ => ()
  }
  let op = match op {
    Some(o) if o != "" => o
    _ => if e.kind.is_a(JSONExtract) { "->" } else { "->>" }
  }
  g.binary(e, op)
}

///|
/// Python `inline_array_sql`.
pub fn inline_array_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  "[" +
  g.expressions(
    expression=e,
    dynamic=true,
    new_line=true,
    skip_first=true,
    skip_last=true,
  ) +
  "]"
}

///|
/// Python `inline_array_unless_query`.
pub fn inline_array_unless_query(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  match e.expressions().get(0) {
    Some(elem) if elem.find([Query]) is Some(_) => g.func("ARRAY", [elem])
    _ => inline_array_sql(g, e)
  }
}

///|
/// Python `no_ilike_sql`.
pub fn no_ilike_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.call_method(
    Like,
    mk(Like, [
      ("this", mk1(Lower, e.this())),
      ("expression", mk1(Lower, e.expression())),
      ("negate", e.get("negate")),
    ]),
  )
}

///|
/// Python `no_paren_current_date_sql`.
pub fn no_paren_current_date_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let zone = g.sql_key(e, "this")
  if zone != "" {
    "CURRENT_DATE AT TIME ZONE " + zone
  } else {
    "CURRENT_DATE"
  }
}

///|
/// Python `no_recursive_cte_sql`.
pub fn no_recursive_cte_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  if e.has("recursive") {
    g.unsupported("Recursive CTEs are unsupported")
    e.set("recursive", false)
  }
  g.call_method(With, e)
}

///|
/// Python `no_tablesample_sql`.
pub fn no_tablesample_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.unsupported("TABLESAMPLE unsupported")
  g.sql(e.this())
}

///|
/// Python `no_pivot_sql`.
pub fn no_pivot_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  ignore(e)
  g.unsupported("PIVOT unsupported")
  ""
}

///|
/// Python `no_trycast_sql`.
pub fn no_trycast_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.cast_sql_v(e)
}

///|
/// Python `no_comment_column_constraint_sql`.
pub fn no_comment_column_constraint_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  ignore(e)
  g.unsupported("CommentColumnConstraint unsupported")
  ""
}

///|
/// Python `no_map_from_entries_sql`.
pub fn no_map_from_entries_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  ignore(e)
  g.unsupported("MAP_FROM_ENTRIES unsupported")
  ""
}

///|
/// Python `property_sql` (dialect helper): `'name'=value`.
pub fn property_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.property_name(e, string_key=true) + "=" + g.sql_key(e, "value")
}

///|
/// Python `strposition_sql`.
pub fn strposition_sql(
  g : Generator,
  e : Expr,
  func_name? : String = "STRPOS",
  supports_position? : Bool = false,
  supports_occurrence? : Bool = false,
  use_ansi_position? : Bool = true,
) -> String raise SqlglotError {
  let mut string = e.this()
  let substr = e.arg("substr")
  let mut position = e.arg("position")
  let occurrence = e.arg("occurrence")
  let zero = literal_int(0)
  let one = literal_int(1)
  if supports_occurrence &&
    occurrence is Some(_) &&
    supports_position &&
    position is None {
    position = Some(one)
  }
  let transpile_position = position is Some(_) && !supports_position
  if transpile_position {
    string = Some(mk(Substring, [("this", string), ("start", position)]))
  }
  let func = if func_name == "POSITION" && use_ansi_position {
    mk(Anonymous, [
      ("this", func_name),
      ("expressions", [mk(In, [("this", substr), ("field", string)])]),
    ])
  } else {
    let args : Array[Expr?] = if func_name == "LOCATE" ||
      func_name == "CHARINDEX" {
      [substr, string]
    } else {
      [string, substr]
    }
    if supports_position {
      args.push(position)
    }
    if occurrence is Some(_) {
      if supports_occurrence {
        args.push(occurrence)
      } else {
        g.unsupported("\{func_name} does not support the occurrence parameter.")
      }
    }
    let exprs : Array[Value] = []
    for a in args {
      match a {
        Some(x) => exprs.push(Node(x))
        None => ()
      }
    }
    mk(Anonymous, [("this", func_name), ("expressions", exprs)])
  }
  if transpile_position {
    let position = position.unwrap()
    let func_with_offset = mk(Sub, [
      ("this", exp_add(func, position)),
      ("expression", one),
    ])
    let func_wrapped = mk(If, [
      ("this", exp_eq(func, zero)),
      ("true", zero),
      ("false", func_with_offset),
    ])
    return g.sql(Some(func_wrapped))
  }
  g.sql(Some(func))
}

///|
/// Python `struct_extract_sql`.
pub fn struct_extract_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let name = match e.expression() {
    Some(x) => x.name()
    None => ""
  }
  g.sql_key(e, "this") + "." + g.sql(Some(to_identifier(name)))
}

///|
/// Python `array_append_sql(name, swap_params)`: transpiles ARRAY_APPEND/ARRAY_PREPEND
/// between dialects with different NULL propagation semantics.
pub fn array_append_sql(name : String, swap_params? : Bool = false) -> GenFn {
  (g, e) => {
    let this = e.this()
    let element = e.expression()
    let args : Array[&SqlArg] = if swap_params {
      [element, this]
    } else {
      [this, element]
    }
    let func_sql = g.func(name, args)
    let source_null_propagation = e.has("null_propagation")
    let target_null_propagation = g.dialect.cfg.array_funcs_propagates_nulls
    if source_null_propagation == target_null_propagation {
      return func_sql
    }
    if source_null_propagation {
      return g.sql(
        Some(
          mk(If, [
            ("this", mk(Is, [("this", this), ("expression", null_())])),
            ("true", null_()),
            ("false", func_sql),
          ]),
        ),
      )
    }
    let this = mk(Coalesce, [
      (
        "expressions",
        [this, Some(mk(Kind::Array, [("expressions", ([] : Array[Expr]))]))],
      ),
    ])
    let args : Array[&SqlArg] = if swap_params {
      [element, this]
    } else {
      [this, element]
    }
    g.func(name, args)
  }
}

///|
/// Python `generate_series_sql(func_name, exclusive_func_name)`.
pub fn generate_series_sql(
  func_name : String,
  exclusive_func_name? : String,
) -> GenFn {
  (g, e) => {
    let start = e.arg("start")
    let end = e.arg("end")
    let step = e.arg("step")
    if e.has("is_end_exclusive") {
      match exclusive_func_name {
        Some(n) if n != "" => return g.func(n, [start, end, step])
        _ => ()
      }
      let adjusted_end = mk(Sub, [("this", end), ("expression", literal_int(1))])
      return g.func(func_name, [start, Some(adjusted_end), step])
    }
    g.func(func_name, [start, end, step])
  }
}

///|
fn empty_array() -> Expr {
  mk(Kind::Array, [("expressions", ([] : Array[Expr]))])
}

///|
/// Builds an ARRAY_CONCAT call from a list of arguments, handling variadic vs binary
/// nesting (Python `array_concat_sql._build_func_call`).
fn array_concat_build_func_call(
  g : Generator,
  func_name : String,
  args : Array[Expr],
) -> String raise SqlglotError {
  if g.cfg.array_concat_is_var_len {
    g.func(func_name, expr_sql_args(args))
  } else if args.length() == 1 {
    g.func(func_name, [args[0], empty_array()])
  } else {
    let n = args.length()
    let mut result = g.func(func_name, [args[n - 2], args[n - 1]])
    for i = n - 3; i >= 0; i = i - 1 {
      result = func_name + "(" + g.sql(Some(args[i])) + ", " + result + ")"
    }
    result
  }
}

///|
/// Python `array_concat_sql(name)`: transpiles ARRAY_CONCAT/ARRAY_CAT between dialects
/// with different NULL propagation semantics.
pub fn array_concat_sql(name : String) -> GenFn {
  (g, e) => {
    let this = e.this_()
    let exprs = e.expressions()
    let all_args = [this] + exprs
    let source_null_propagation = e.has("null_propagation")
    let target_null_propagation = g.dialect.cfg.array_funcs_propagates_nulls
    if source_null_propagation == target_null_propagation ||
      this.kind.is_a(Kind::Array) ||
      exprs.is_empty() {
      return array_concat_build_func_call(g, name, all_args)
    }
    if source_null_propagation {
      let null_checks = all_args.map(arg => {
        mk(Is, [("this", arg.copy()), ("expression", null_())])
      })
      let mut combined_check = null_checks[0]
      for i in 1..<null_checks.length() {
        combined_check = mk(Or, [
          ("this", combined_check),
          ("expression", null_checks[i]),
        ])
      }
      let func_sql = array_concat_build_func_call(g, name, all_args)
      return g.sql(
        Some(
          mk(If, [
            ("this", combined_check),
            ("true", null_()),
            ("false", func_sql),
          ]),
        ),
      )
    }
    let wrapped_args = all_args.map(arg => {
      mk(Coalesce, [("expressions", [arg.copy(), empty_array()])])
    })
    array_concat_build_func_call(g, name, wrapped_args)
  }
}

///|
/// Python `var_map_sql(self, expression, map_func_name="MAP")`.
pub fn var_map_sql(
  g : Generator,
  e : Expr,
  map_func_name? : String = "MAP",
) -> String raise SqlglotError {
  let keys = e.arg("keys")
  let values = e.arg("values")
  match (keys, values) {
    (Some(k), Some(v)) if k.kind.is_a(Kind::Array) && v.kind.is_a(Kind::Array) => {
      let args : Array[&SqlArg] = []
      let ks = k.expressions()
      let vs = v.expressions()
      for i in 0..<min_int(ks.length(), vs.length()) {
        args.push(g.sql(Some(ks[i])))
        args.push(g.sql(Some(vs[i])))
      }
      g.func(map_func_name, args)
    }
    _ => {
      g.unsupported("Cannot convert array columns into map.")
      g.func(map_func_name, [e.get("keys"), e.get("values")])
    }
  }
}

///|
/// Python `months_between_sql`: transpiles MONTHS_BETWEEN to dialects without native
/// support (`DATEDIFF('month', d2, d1) + (DAY(d1) - DAY(d2)) / 31.0`, with a last day of
/// month check).
pub fn months_between_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let date1_cast = exp_cast(e.this_(), DType::DATE, copy=false)
  let date2_cast = exp_cast(e.expression_(), DType::DATE, copy=false)
  let whole_months = mk(DateDiff, [
    ("this", date1_cast),
    ("expression", date2_cast),
    ("unit", var_("month")),
  ])
  let day1 = mk1(Day, date1_cast.copy())
  let day2 = mk1(Day, date2_cast.copy())
  let day_of_last_day1 = mk1(Day, mk1(LastDay, date1_cast.copy()))
  let day_of_last_day2 = mk1(Day, mk1(LastDay, date2_cast.copy()))
  let last_day1 = mk2(EQ, day1.copy(), day_of_last_day1)
  let last_day2 = mk2(EQ, day2.copy(), day_of_last_day2)
  let both_last_day = mk2(And, last_day1, last_day2)
  let fractional = mk2(
    Div,
    mk1(Paren, mk2(Sub, day1.copy(), day2.copy())),
    literal_number("31.0"),
  )
  let fractional_with_check = mk(If, [
    ("this", both_last_day),
    ("true", literal_number("0")),
    ("false", fractional),
  ])
  g.sql(Some(mk2(Add, whole_months, fractional_with_check)))
}

///|
/// Python `time_format(dialect)`: returns the time format of an expression unless it's
/// equivalent to the default time format of `dialect` (the base dialect if omitted).
pub fn time_format(
  dialect? : String,
) -> (Generator, Expr) -> String? raise SqlglotError {
  (g, e) => {
    let time_format = g.format_time(e)
    let d = match dialect {
      Some(name) => Dialect::get_or_raise(name)
      None => base_dialect()
    }
    match time_format {
      Some(tf) if tf != d.cfg.time_format => Some(tf)
      _ => None
    }
  }
}

///|
/// Python `left_to_substring_sql`.
pub fn left_to_substring_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  g.sql(
    Some(
      mk(Substring, [
        ("this", e.this()),
        ("start", Some(literal_int(1))),
        ("length", e.expression()),
      ]),
    ),
  )
}

///|
/// Python `right_to_substring_sql`.
pub fn right_to_substring_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let length = mk1(Length, e.this())
  let start = exp_binop(
    Sub,
    length,
    exp_paren(exp_binop(Sub, e.expression_(), literal_int(1))),
  )
  g.sql(Some(mk(Substring, [("this", e.this()), ("start", Some(start))])))
}

///|
/// Python `encode_decode_sql(self, expression, name, replace=True)`. Used for dialects
/// whose functions don't support a charset and assume utf-8.
pub fn encode_decode_sql(
  g : Generator,
  e : Expr,
  name : String,
  replace? : Bool = true,
) -> String raise SqlglotError {
  match e.arg("charset") {
    Some(charset) => {
      let n = py_lower(charset.name())
      if n != "utf-8" && n != "utf8" {
        g.unsupported(
          "Expected utf-8 character set, got \{expr_to_sql(charset)}.",
        )
      }
    }
    None => ()
  }
  let rep : Value? = if replace { e.get("replace") } else { None }
  g.func(name, [e.get("this"), rep])
}

///|
/// Python `min_or_least`.
pub fn min_or_least(g : Generator, e : Expr) -> String raise SqlglotError {
  let name = if e.expressions().is_empty() { "MIN" } else { "LEAST" }
  rename_func(name)(g, e)
}

///|
/// Python `max_or_greatest`.
pub fn max_or_greatest(g : Generator, e : Expr) -> String raise SqlglotError {
  let name = if e.expressions().is_empty() { "MAX" } else { "GREATEST" }
  rename_func(name)(g, e)
}

///|
/// Python `count_if_to_sum`.
pub fn count_if_to_sum(g : Generator, e : Expr) -> String raise SqlglotError {
  let mut cond = e.this_()
  if cond.kind.is_a(Distinct) {
    cond = cond.expressions()[0]
    g.unsupported("DISTINCT is not supported when converting COUNT_IF to SUM")
  }
  g.func("sum", [func_("if", [cond, literal_int(1), literal_int(0)])])
}

///|
/// Python `trim_sql(self, expression, default_trim_type="")` (dialect helper).
pub fn trim_sql(
  g : Generator,
  e : Expr,
  default_trim_type? : String = "",
) -> String raise SqlglotError {
  let remove_chars = g.sql_key(e, "expression")
  if remove_chars == "" {
    return g.call_method(Trim, e)
  }
  let target = g.sql_key(e, "this")
  let trim_type = match g.sql_key(e, "position") {
    "" => default_trim_type
    t => t
  }
  let collation = g.sql_key(e, "collation")
  let trim_type = if trim_type != "" { trim_type + " " } else { "" }
  let remove_chars = if remove_chars != "" { remove_chars + " " } else { "" }
  let from_part = if trim_type != "" || remove_chars != "" {
    "FROM "
  } else {
    ""
  }
  let collation = if collation != "" { " COLLATE " + collation } else { "" }
  "TRIM(" + trim_type + remove_chars + from_part + target + collation + ")"
}

///|
/// Python `concat_ws_to_dpipe_sql`.
pub fn concat_ws_to_dpipe_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let exprs = e.expressions()
  if exprs.is_empty() {
    raise ValueError("not enough values to unpack (expected at least 1, got 0)")
  }
  let delim = exprs[0]
  if exprs.length() < 2 {
    raise ValueError("reduce() of empty iterable with no initial value")
  }
  let mut acc = exprs[1]
  for i in 2..<exprs.length() {
    acc = mk2(DPipe, acc, mk2(DPipe, delim, exprs[i]))
  }
  g.sql(Some(acc))
}

///|
/// Python `regexp_extract_sql`.
pub fn regexp_extract_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.unsupported_args(e, ["position", "occurrence", "parameters"])
  let mut group = e.arg("group")
  match group {
    Some(gr) if gr.name() ==
      g.dialect.cfg.regexp_extract_default_group.to_string() => group = None
    _ => ()
  }
  g.func(e.kind.sql_name(), [e.this(), e.expression(), group])
}

///|
/// Python `regexp_replace_sql`.
pub fn regexp_replace_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.unsupported_args(e, ["position", "occurrence", "modifiers"])
  g.func("REGEXP_REPLACE", [
    e.get("this"),
    e.get("expression"),
    e.get("replacement"),
  ])
}

///|
/// Python `pivot_column_names(aggregations, dialect)`.
pub fn pivot_column_names(
  aggregations : Array[Expr],
  dialect : Dialect,
) -> Array[String] raise SqlglotError {
  let names = []
  for agg in aggregations {
    if agg.kind.is_a(Alias) {
      names.push(agg.alias())
    } else {
      // Aggregations without aliases are used as suffixes (e.g. col_avg(foo)). Identifiers
      // are unquoted because they're quoted later by the parser's `_parse_pivot`.
      let agg_all_unquoted = agg.transform(node => {
        if node.kind.is_a(Identifier) {
          Some(mk(Identifier, [("this", node.name()), ("quoted", false)]))
        } else {
          Some(node)
        }
      })
      names.push(
        Generator::new(dialect, normalize_functions="lower").generate(
          agg_all_unquoted,
        ),
      )
    }
  }
  names
}

///|
/// Python `any_value_to_max_sql`.
pub fn any_value_to_max_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  g.func("MAX", [e.this()])
}

///|
/// Python `bool_xor_sql`.
pub fn bool_xor_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let a = g.sql_key(e, "this")
  let b = g.sql_key(e, "expression")
  "(" + a + " AND (NOT " + b + ")) OR ((NOT " + a + ") AND " + b + ")"
}

///|
/// Python `is_parse_json`.
pub fn is_parse_json(e : Expr) -> Bool {
  e.kind.is_a(ParseJSON) || (e.kind.is_a(Cast) && e.is_type([DType::JSON]))
}

///|
/// Python `generatedasidentitycolumnconstraint_sql` (dialect helper): `IDENTITY(start, increment)`.
pub fn generatedasidentitycolumnconstraint_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let start = match g.sql_key(e, "start") {
    "" => "1"
    s => s
  }
  let increment = match g.sql_key(e, "increment") {
    "" => "1"
    s => s
  }
  "IDENTITY(" + start + ", " + increment + ")"
}

///|
/// Python `arg_max_or_min_no_count(name)`.
pub fn arg_max_or_min_no_count(name : String) -> GenFn {
  (g, e) => {
    g.unsupported_args(e, ["count"])
    g.func(name, [e.this(), e.expression()])
  }
}

///|
/// Python `no_last_day_sql`.
pub fn no_last_day_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let trunc_curr_date = func_("date_trunc", [literal_string("month"), e.this_()])
  let plus_one_month = func_("date_add", [
    trunc_curr_date,
    literal_int(1),
    literal_string("month"),
  ])
  let minus_one_day = func_("date_sub", [
    plus_one_month,
    literal_int(1),
    literal_string("day"),
  ])
  g.sql(Some(exp_cast(minus_one_day, DType::DATE)))
}

///|
/// Python `merge_without_target_sql`: removes table refs from columns in WHEN clauses.
pub fn merge_without_target_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let target = e.this_()
  let alias_ = target.arg("alias")
  let normalize = fn(identifier : Expr?) -> String? {
    match identifier {
      Some(i) => Some(g.dialect.normalize_identifier(i).name())
      None => None
    }
  }
  let targets : Array[String?] = [normalize(target.this())]
  match alias_ {
    Some(a) => targets.push(normalize(a.this()))
    None => ()
  }
  let whens = match e.arg("whens") {
    Some(w) => w.expressions()
    None => []
  }
  for when in whens {
    // Only remove the target table names from certain parts of WHEN MATCHED / WHEN NOT
    // MATCHED: they are still valid in the <condition>, the right hand side of each
    // UPDATE and the VALUES part (not the column list) of the INSERT.
    match when.arg("then") {
      Some(then) => {
        if then.kind.is_a(Update) {
          for equals in find_all_in_scope(then, [EQ]) {
            match equals.this() {
              Some(lhs) if lhs.kind.is_a(Column) &&
                targets.contains(normalize(lhs.arg("table"))) =>
                lhs.replace(Some(mk1(Column, lhs.this().map(x => x.copy()))))
                |> ignore
              _ => ()
            }
          }
        }
        if then.kind.is_a(Insert) {
          match then.this() {
            Some(column_list) if column_list.kind.is_a(Tuple) =>
              for column in column_list.expressions() {
                if targets.contains(normalize(column.arg("table"))) {
                  column.replace(
                    Some(mk1(Column, column.this().map(x => x.copy()))),
                  )
                  |> ignore
                }
              }
            _ => ()
          }
        }
      }
      None => ()
    }
  }
  g.call_method(Merge, e)
}

///|
/// Python `json_extract_segments(name, quoted_index, op)`.
pub fn json_extract_segments(
  name : String,
  quoted_index? : Bool = true,
  op? : String,
) -> GenFn {
  (g, e) => {
    let path = e.expression()
    match path {
      Some(p) if p.kind.is_a(JSONPath) => {
        let segments : Array[String] = []
        for segment in p.expressions() {
          let mut path = g.sql(Some(segment))
          if path != "" {
            if segment.kind.is_a(JSONPathPart) &&
              (quoted_index || !segment.kind.is_a(JSONPathSubscript)) {
              path = g.escape_str(path)
              path = g.dialect.cfg.quote_start + path + g.dialect.cfg.quote_end
            }
            segments.push(path)
          }
        }
        match op {
          Some(o) if o != "" =>
            ([g.sql(e.this())] + segments).join(" " + o + " ")
          _ => {
            let args : Array[&SqlArg] = [e.this()]
            for s in segments {
              args.push(s)
            }
            g.func(name, args)
          }
        }
      }
      _ => rename_func(name)(g, e)
    }
  }
}

///|
/// Python `json_path_key_only_name`.
pub fn json_path_key_only_name(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  match e.this() {
    Some(t) if t.kind.is_a(JSONPathWildcard) =>
      g.unsupported("Unsupported wildcard in JSONPathKey expression")
    _ => ()
  }
  e.name()
}

///|
/// Python `filter_array_using_unnest`.
pub fn filter_array_using_unnest(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let cond0 = e.expression_()
  // `alias_` is either an expression (the lambda's parameter) or the string "_u".
  let (alias_, cond) : (Expr?, Expr) = if cond0.kind.is_a(Lambda) &&
    cond0.expressions().length() == 1 {
    (Some(cond0.expressions()[0]), cond0.this_())
  } else if cond0.kind.is_a(Predicate) {
    (None, cond0)
  } else if e.kind.is_a(ArrayRemove) {
    (None, mk(NEQ, [("this", "_u"), ("expression", e.expression())]))
  } else {
    g.unsupported("Unsupported filter condition")
    return ""
  }
  let unnest = mk(Unnest, [("expressions", [e.this_()])])
  // exp.alias_(unnest, None, table=[alias_])
  let table_alias_column = match alias_ {
    Some(a) => if a.kind == Identifier { a.copy() } else { a }
    None => to_identifier("_u")
  }
  let aliased = unnest.copy()
  aliased.set("alias", mk(TableAlias, [("columns", [table_alias_column])]))
  let projection = match alias_ {
    Some(a) => a
    None => column_of("_u")
  }
  let filtered = mk(Select, [
    ("expressions", [projection]),
    ("from_", mk1(From, aliased)),
    ("where", mk1(Where, cond.copy())),
  ])
  g.sql(Some(mk(Kind::Array, [("expressions", [filtered])])))
}

///|
/// Python `array_compact_sql`.
pub fn array_compact_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let lambda_id = to_identifier("_u")
  let cond = exp_not(mk(Is, [("this", lambda_id), ("expression", null_())]))
  g.sql(
    Some(
      mk(ArrayFilter, [
        ("this", e.this()),
        (
          "expression",
          Some(mk(Lambda, [("this", cond), ("expressions", [lambda_id])])),
        ),
      ]),
    ),
  )
}

///|
/// Python `remove_from_array_using_filter`.
pub fn remove_from_array_using_filter(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let lambda_id = to_identifier("_u")
  let cond = mk(NEQ, [("this", Some(lambda_id)), ("expression", e.expression())])
  let filter_sql = g.sql(
    Some(
      mk(ArrayFilter, [
        ("this", e.this()),
        (
          "expression",
          Some(mk(Lambda, [("this", cond), ("expressions", [lambda_id])])),
        ),
      ]),
    ),
  )
  let source_null_propagation = e.has("null_propagation")
  let target_null_propagation = g.dialect.cfg.array_funcs_propagates_nulls
  if source_null_propagation && !target_null_propagation {
    let removal_value = e.expression_()
    // Skip the wrapper if the removal value is a non-NULL literal or an array literal
    if (removal_value.kind.is_a(Literal) && !removal_value.kind.is_a(Null)) ||
      removal_value.kind.is_a(Kind::Array) {
      return filter_sql
    }
    return g.sql(
      Some(
        mk(If, [
          ("this", mk(Is, [("this", removal_value), ("expression", null_())])),
          ("true", null_()),
          ("false", filter_sql),
        ]),
      ),
    )
  }
  filter_sql
}

///|
/// Python `to_number_with_nls_param`.
pub fn to_number_with_nls_param(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  g.func("TO_NUMBER", [e.get("this"), e.get("format"), e.get("nlsparam")])
}

///|
fn sha_name(e : Expr) -> String {
  match e.text("length") {
    "" => "SHA256"
    l => "SHA" + l
  }
}

///|
/// Python `sha256_sql`.
pub fn sha256_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.func(sha_name(e), [e.this()])
}

///|
/// Python `sha2_digest_sql`.
pub fn sha2_digest_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.func(sha_name(e), [e.this()])
}

///|
/// Python `sequence_sql` (for GenerateSeries / GenerateDateArray).
pub fn sequence_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let mut start = e.arg("start")
  let mut end = e.arg("end")
  let step = e.arg("step")
  let target_type = match start {
    Some(s) if s.kind.is_a(Cast) => s.arg("to")
    _ =>
      match end {
        Some(en) if en.kind.is_a(Cast) => en.arg("to")
        _ => None
      }
  }
  match (start, end) {
    (Some(s), Some(en)) => {
      match target_type {
        Some(tt) if tt.is_type([DType::DATE, DType::TIMESTAMP]) => {
          let start_is_target = s.kind.is_a(Cast) &&
            (match s.arg("to") {
              Some(to) => physical_equal(to, tt)
              None => false
            })
          if start_is_target {
            end = Some(exp_cast_to(en, tt))
          } else {
            start = Some(exp_cast_to(s, tt))
          }
        }
        _ => ()
      }
      if e.has("is_end_exclusive") {
        let start = start.unwrap()
        let step_value = match step {
          Some(st) => st
          None => literal_int(1)
        }
        let end = exp_paren(mk2(Sub, end.unwrap(), step_value), copy=false)
        let seq_args : Array[Expr] = [start, end]
        match step {
          Some(st) => seq_args.push(st)
          None => ()
        }
        let sequence_call = mk(Anonymous, [
          ("this", "SEQUENCE"),
          ("expressions", seq_args),
        ])
        let zero = literal_int(0)
        let should_return_empty = exp_or([
          mk2(EQ, step_value.copy(), zero.copy()),
          exp_and([
            mk2(GT, step_value.copy(), zero.copy()),
            mk2(GT, start.copy(), end.copy()),
          ]),
          exp_and([
            mk2(LT, step_value.copy(), zero.copy()),
            mk2(LT, start.copy(), end.copy()),
          ]),
        ])
        let empty_array_or_sequence = mk(If, [
          ("this", should_return_empty),
          ("true", empty_array()),
          ("false", sequence_call),
        ])
        return g.sql(Some(g.simplify_unless_literal(empty_array_or_sequence)))
      }
    }
    _ => ()
  }
  g.func("SEQUENCE", [start, end, step])
}

///|
/// Python `explode_to_unnest_sql` (for Lateral).
pub fn explode_to_unnest_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let this = e.this_()
  let alias_ = e.arg("alias")
  let mut cross_join_expr : Expr? = None
  match alias_ {
    Some(a) if this.kind.is_a(Posexplode) => {
      // Spark's `FROM x LATERAL VIEW POSEXPLODE(y) t AS pos, col` has the following
      // semantics:
      // - The first column is the position and the rest (1 for array, 2 for maps) are
      //   the exploded values
      // - The position is 0-based whereas WITH ORDINALITY is 1-based
      // So we subtract 1 from the ORDINALITY position and rearrange the columns:
      // `FROM x CROSS JOIN LATERAL (SELECT pos - 1 AS pos, col FROM UNNEST(y) WITH
      // ORDINALITY AS t(col, pos))`
      let columns = a.list("columns")
      let pos = columns[0]
      let cols = columns[1:].to_owned()
      let projections = [
          exp_alias(exp_binop(Sub, pos, literal_int(1)), Node(pos)),
        ] +
        cols
      let unnest = mk(Unnest, [
        ("expressions", [this.this_()]),
        ("offset", true),
        (
          "alias",
          mk(TableAlias, [("this", a.this()), ("columns", cols + [pos])]),
        ),
      ])
      let lateral_subquery = exp_select_from(projections, unnest)
      cross_join_expr = Some(mk1(Lateral, exp_subquery_of(lateral_subquery)))
    }
    _ =>
      if this.kind.is_a(Explode) {
        cross_join_expr = Some(
          mk(Unnest, [("expressions", [this.this_()]), ("alias", alias_)]),
        )
      }
  }
  match cross_join_expr {
    Some(c) => g.sql(Some(mk(Join, [("this", c), ("kind", "cross")])))
    None => g.call_method(Lateral, e)
  }
}

///|
/// Python `timestampdiff_sql`.
pub fn timestampdiff_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.func("TIMESTAMPDIFF", [e.get("unit"), e.get("expression"), e.get("this")])
}

///|
/// Python `no_make_interval_sql(self, expression, sep=", ")`.
pub fn no_make_interval_sql(
  g : Generator,
  e : Expr,
  sep? : String = ", ",
) -> String raise SqlglotError {
  let args : Array[&SqlArg] = []
  for unit, value in e.args {
    let value = match value {
      Node(v) if v.kind.is_a(Kwarg) =>
        match v.get("expression") {
          Some(x) => x
          None => Str("None")
        }
      v => v
    }
    let value_str = match value {
      Node(v) => expr_to_sql(v)
      Str(s) => s
      Int(i) => i.to_string()
      Bool(b) => if b { "True" } else { "False" }
      List(_) | DT(_) => g.sql_value(value)
    }
    args.push(value_str + " " + unit)
  }
  "INTERVAL '" + g.format_args(args, sep~) + "'"
}

///|
/// Python `length_or_char_length_sql`.
pub fn length_or_char_length_sql(
  g : Generator,
  e : Expr,
) -> String raise SqlglotError {
  let length_func = if e.has("binary") { "LENGTH" } else { "CHAR_LENGTH" }
  g.func(length_func, [e.this()])
}

///|
/// Python `groupconcat_sql(self, expression, func_name="LISTAGG", sep=",",
/// within_group=True, on_overflow=False)`. Pass `sep=""` for Python `sep=None`.
pub fn groupconcat_sql(
  g : Generator,
  e : Expr,
  func_name? : String = "LISTAGG",
  sep? : String = ",",
  within_group? : Bool = true,
  on_overflow? : Bool = false,
) -> String raise SqlglotError {
  let mut this = e.this_()
  let separator = match e.arg("separator") {
    Some(s) => g.sql(Some(s))
    None => if sep != "" { g.sql(Some(literal_string(sep))) } else { "" }
  }
  let on_overflow_sql = g.sql_key(e, "on_overflow")
  let on_overflow_sql = if on_overflow && on_overflow_sql != "" {
    " ON OVERFLOW " + on_overflow_sql
  } else {
    ""
  }
  let mut limit : Expr? = None
  if this.kind.is_a(Limit) && this.this() is Some(inner) {
    limit = Some(this)
    this = inner.pop()
  }
  let order = this.find([Order])
  match order {
    Some(o) =>
      match o.this() {
        Some(ot) => this = ot.pop()
        None => ()
      }
    None => ()
  }
  let second : String? = if separator != "" || on_overflow_sql != "" {
    Some(separator + on_overflow_sql)
  } else {
    None
  }
  let args = g.format_args([this, second])
  // The arguments are already rendered, so they are wrapped in a `Var` (whose SQL is
  // its text) to be used as the function's argument.
  let listagg_func = mk(Anonymous, [
    ("this", func_name),
    ("expressions", [var_(args)]),
  ])
  let mut listagg = listagg_func
  let mut modifiers = g.sql(limit)
  match order {
    Some(o) =>
      if within_group {
        listagg = mk(WithinGroup, [("this", listagg_func), ("expression", o)])
      } else {
        modifiers = g.sql(Some(o)) + modifiers
      }
    None => ()
  }
  if modifiers != "" {
    // Like Python, this sets `expressions` on the outermost node (a no-op for WithinGroup).
    listagg.set("expressions", [var_(args + modifiers)])
  }
  g.sql(Some(listagg))
}

///|
/// Python `regexp_replace_global_modifier`.
pub fn regexp_replace_global_modifier(e : Expr) -> Expr? {
  let mut modifiers = e.arg("modifiers")
  let single_replace = e.has("single_replace")
  let occurrence = e.arg("occurrence")
  let occurrence_is_zero = match occurrence {
    None => true
    Some(o) => o.is_int() && o.to_py_int() == Some(0L)
  }
  if !single_replace && occurrence_is_zero {
    match modifiers {
      None => modifiers = Some(literal_string("g"))
      Some(m) if m.is_string() =>
        modifiers = Some(literal_string(m.name() + "g"))
      _ => ()
    }
  }
  modifiers
}

///|
/// Python `nth_value_from_sql`.
pub fn nth_value_from_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let this = g.func("NTH_VALUE", [e.get("this"), e.get("offset")])
  match e.get("from_first") {
    None => this
    Some(v) => this + " FROM " + (if v.truthy() { "FIRST" } else { "LAST" })
  }
}

///|
/// Python `getbit_sql`: GET_BIT, transpiled to `(value >> position) & 1` when the zero
/// index is the least-significant bit and the input is an integer.
pub fn getbit_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  let value = e.this()
  let position = e.expression()
  if !e.has("zero_is_msb") &&
    e.is_type(dtype_signed_integer_types + dtype_unsigned_integer_types) {
    let shifted = mk(BitwiseRightShift, [
      ("this", value),
      ("expression", position),
    ])
    let masked = mk(BitwiseAnd, [
      ("this", Some(shifted)),
      ("expression", Some(literal_int(1))),
    ])
    return g.sql(Some(masked))
  }
  g.func("GET_BIT", [value, position])
}

///|
/// Python `jarowinkler_similarity(func)`.
pub fn jarowinkler_similarity(func : String) -> GenFn {
  (g, e) => {
    let mut this = e.this()
    let mut expr = e.expression()
    if e.has("case_insensitive") {
      this = Some(mk1(Upper, this))
      expr = Some(mk1(Upper, expr))
    }
    g.func(func, [this, expr])
  }
}

///|
/// Python `concat_to_dpipe_sql` (same as `Generator::concat_to_dpipe_sql`).
pub fn concat_to_dpipe_sql(g : Generator, e : Expr) -> String raise SqlglotError {
  g.concat_to_dpipe_sql(e)
}
