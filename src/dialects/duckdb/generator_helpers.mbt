// Port of the module-level helpers of sqlglot/generators/duckdb.py.

///|
/// Whitespace control characters that DuckDB must process with `CHR({val})` calls
let ws_control_chars_to_duck : Map[Char, Int] = {
  '\u000b': 11,
  '\u001c': 28,
  '\u001d': 29,
  '\u001e': 30,
  '\u001f': 31,
}

///|
/// Characters that must be escaped when building regex expressions in INITCAP
let regex_escape_replacements : Array[(Char, String)] = [
  ('\\', "\\\\"),
  ('-', "\\-"),
  ('^', "\\^"),
  ('[', "\\["),
  (']', "\\]"),
]

///|
let randstr_char_pool : String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

///|
let randstr_seed : Int = 123456

///|
let snowflake_collation_defaults : Array[String] = ["cs", "as", "ps"]

///|
let snowflake_collation_unsupported : Array[String] = [
  "ci", "ai", "upper", "lower", "utf8", "bin", "pi", "fl", "fu", "trim", "ltrim",
  "rtrim",
]

///|
/// Window functions that support IGNORE/RESPECT NULLS in DuckDB
let ignore_respect_nulls_window_functions : Array[@core.Kind] = [
  FirstValue,
  Lag,
  LastValue,
  Lead,
  NthValue,
]

///|
let seq_base : Template = Template::new("(ROW_NUMBER() OVER (ORDER BY 1) - 1)")

///|
let seq_unsigned : Template = Template::new(":base % :max_val")

///|
let seq_signed : Template = Template::new(
  "(CASE WHEN :base % :max_val >= :half THEN :base % :max_val - :max_val ELSE :base % :max_val END)",
)

///|
/// Regex `:\d{2}.*?[+\-]\d{2}(?::\d{2})?` search (TIMEZONE_PATTERN).
fn has_timezone(ts : String) -> Bool {
  let chars = ts.to_array()
  let n = chars.length()
  // `\d` is any Unicode decimal digit; `.` doesn't match a newline.
  let digit = (i : Int) => i < n && @core.is_decimal(chars[i])
  for i in 0..<n {
    if chars[i] == ':' && digit(i + 1) && digit(i + 2) {
      for j in (i + 3)..<n {
        if (chars[j] == '+' || chars[j] == '-') && digit(j + 1) && digit(j + 2) {
          return true
        }
        if chars[j] == '\n' {
          break
        }
      }
    }
  }
  false
}

///|
fn apply_base64_alphabet_replacements(
  result : @core.Expr,
  alphabet : @core.Expr?,
  reverse? : Bool = false,
) -> @core.Expr {
  let mut result = result
  match alphabet {
    Some(a) if a.kind == Literal && a.is_string() => {
      let defaults = "+/=".to_array()
      let news = a.text("this").to_array()
      for i in 0..<@cmp.minimum(defaults.length(), news.length()) {
        let default_char = defaults[i]
        let new_char = news[i]
        if new_char != default_char {
          let (find, replace) = if reverse {
            (new_char, default_char)
          } else {
            (default_char, new_char)
          }
          result = @core.mk(Replace, [
            ("this", result),
            ("expression", str_lit(find.to_string())),
            ("replacement", str_lit(replace.to_string())),
          ])
        }
      }
    }
    _ => ()
  }
  result
}

///|
/// Transpile Snowflake BASE64_DECODE_STRING/BINARY to DuckDB.
fn base64_decode_sql(
  g : @core.Generator,
  e : @core.Expr,
  to_string : Bool,
) -> String raise @core.SqlglotError {
  let mut input_expr = this_of(e)
  let alphabet = e.arg("alphabet")
  input_expr = apply_base64_alphabet_replacements(
    input_expr,
    alphabet,
    reverse=true,
  )
  input_expr = @core.mk1(FromBase64, input_expr)
  if to_string {
    input_expr = @core.mk1(Decode, input_expr)
  }
  g.sql(Some(input_expr))
}

///|
/// DuckDB's LAST_DAY only supports finding the last day of a month.
fn last_day_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let date_expr = this_of(e)
  let unit_expr = e.arg("unit")
  match @core.week_unit_to_dow(unit_expr) {
    Some(week_start) if week_start != 0 => {
      // The week's last day precedes its start day; DuckDB DAYOFWEEK: Sunday=0, ..., Saturday=6
      let last_dow = week_start - 1
      let dow = func("EXTRACT", [parse("DAYOFWEEK"), date_expr])
      let days_to_last_expr = @core.mk(Mod, [
        (
          "this",
          @core.mk1(
            Paren,
            @core.mk(Sub, [("this", num(last_dow + 7)), ("expression", dow)]),
          ),
        ),
        ("expression", num(7)),
      ])
      let interval_expr = interval(days_to_last_expr, "DAY")
      let add_expr = @core.mk(Add, [
        ("this", date_expr),
        ("expression", interval_expr),
      ])
      return g.sql(Some(cast(add_expr, DATE)))
    }
    _ => ()
  }
  let unit = @core.py_upper(e.text("unit"))
  if unit == "" || unit == "MONTH" {
    // Default behavior - use DuckDB's native LAST_DAY
    return g.func("LAST_DAY", [date_expr])
  }
  if unit == "YEAR" {
    // Last day of year: December 31st of the same year
    let year_expr = func("EXTRACT", [parse("YEAR"), date_expr])
    let make_date_expr = func("MAKE_DATE", [year_expr, num(12), num(31)])
    return g.sql(Some(make_date_expr))
  }
  if unit == "QUARTER" {
    let year_expr = func("EXTRACT", [parse("YEAR"), date_expr])
    let quarter_expr = func("EXTRACT", [parse("QUARTER"), date_expr])
    let last_month_expr = @core.mk(Mul, [
      ("this", quarter_expr),
      ("expression", num(3)),
    ])
    let first_day_last_month_expr = func("MAKE_DATE", [
      year_expr,
      last_month_expr,
      num(1),
    ])
    let last_day_expr = func("LAST_DAY", [first_day_last_month_expr])
    return g.sql(Some(last_day_expr))
  }
  g.unsupported(
    "Unsupported date part '\{e.text("unit")}' in LAST_DAY function",
  )
  g.function_fallback_sql(e)
}

///|
fn is_nanosecond_unit(unit : @core.Expr?) -> Bool {
  match unit {
    Some(u) if u.kind == Var || u.kind == Literal =>
      @core.py_upper(u.name()) == "NANOSECOND"
    _ => false
  }
}

///|
/// Generate NANOSECOND diff using EPOCH_NS since DATE_DIFF doesn't support it.
fn handle_nanosecond_diff(
  g : @core.Generator,
  end_time : @core.Expr,
  start_time : @core.Expr,
) -> String raise @core.SqlglotError {
  let end_ns = cast(end_time, TIMESTAMP_NS)
  let start_ns = cast(start_time, TIMESTAMP_NS)
  g.sql(
    Some(
      @core.mk(Sub, [
        ("this", func("EPOCH_NS", [end_ns])),
        ("expression", func("EPOCH_NS", [start_ns])),
      ]),
    ),
  )
}

///|
/// Transpile TO_BOOLEAN and TRY_TO_BOOLEAN functions from Snowflake to DuckDB equivalent.
fn to_boolean_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = this_of(e)
  let is_safe = e.has("safe")
  let base_case_expr = case_()
    |> when(
      eq(@core.mk1(Upper, cast(arg, VARCHAR)), str_lit("ON")),
      @core.true_(),
    )
    |> when(
      eq(@core.mk1(Upper, cast(arg, VARCHAR)), str_lit("OFF")),
      @core.false_(),
    )
  let case_expr = if is_safe {
    else_(base_case_expr, func("TRY_CAST", [arg, @core.datatype_of(BOOLEAN)]))
  } else {
    let cast_to_real = func("TRY_CAST", [arg, @core.datatype_of(FLOAT)])
    let nan_inf_check = @core.mk(Or, [
      ("this", func("ISNAN", [cast_to_real])),
      ("expression", func("ISINF", [cast_to_real])),
    ])
    else_(
      when(
        base_case_expr,
        nan_inf_check,
        func("ERROR", [
          str_lit(
            "TO_BOOLEAN: Non-numeric values NaN and INF are not supported",
          ),
        ]),
      ),
      cast(arg, BOOLEAN),
    )
  }
  g.sql(Some(case_expr))
}

///|
/// BigQuery -> DuckDB conversion for the DATE function
fn date_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut this = this_of(e)
  let zone = g.sql_key(e, "zone")
  if zone != "" {
    this = cast(this, TIMESTAMP)
    let at_utc = @core.mk(AtTimeZone, [("this", this), ("zone", str_lit("UTC"))])
    this = @core.mk(AtTimeZone, [("this", at_utc), ("zone", zone)])
  }
  g.sql(Some(cast(this, DATE)))
}

///|
/// BigQuery -> DuckDB conversion for the TIME_DIFF function
fn timediff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = e.arg("unit")
  if is_nanosecond_unit(unit) {
    return handle_nanosecond_diff(g, expr_of(e), this_of(e))
  }
  let this = cast(this_of(e), TIME)
  let expr = cast(expr_of(e), TIME)
  // Although the 2 dialects share similar signatures, BQ seems to inverse
  // the sign of the result so the start/end time operands are flipped
  g.func("DATE_DIFF", [@core.unit_to_str(e), expr, this])
}

///|
/// DuckDB override of `date_delta_to_binary_interval_op` handling NANOSECOND units and
/// float/decimal interval values.
fn duck_date_delta_to_binary_interval_op(cast? : Bool = true) -> @core.GenFn {
  let base_impl = @core.date_delta_to_binary_interval_op(cast~)
  (g, e) => {
    let unit = e.arg("unit")
    let mut interval_value = e.expression()
    // Handle NANOSECOND unit (DuckDB doesn't support INTERVAL ... NANOSECOND)
    if is_nanosecond_unit(unit) {
      match interval_value {
        Some(iv) if iv.kind == Interval => interval_value = iv.this()
        _ => ()
      }
      let timestamp_ns = @core.exp_cast(this_of(e), TIMESTAMP_NS)
      return g.sql(
        Some(
          func("MAKE_TIMESTAMP_NS", [
            @core.mk(Add, [
              ("this", func("EPOCH_NS", [timestamp_ns])),
              ("expression", interval_value),
            ]),
          ]),
        ),
      )
    }
    match interval_value {
      None => return base_impl(g, e)
      Some(iv) if iv.kind == Interval => return base_impl(g, e)
      Some(iv) =>
        if is_real(iv) {
          e.set(
            "expression",
            @core.exp_cast_to(func("ROUND", [iv]), base_type("INT")),
          )
        }
    }
    base_impl(g, e)
  }
}

///|
/// Transpile ARRAY_INSERT to DuckDB using LIST_CONCAT and slicing.
fn array_insert_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let position = e.arg("position")
  let element = expr_of(e)
  let element_array = @core.mk(Array, [("expressions", [element])])
  let index_offset = match e.get("offset") {
    Some(Int(i)) => i.to_int()
    Some(Node(n)) => to_int(n)
    _ => 0
  }
  guard position is Some(position) && position.is_int() else {
    g.unsupported("ARRAY_INSERT can only be transpiled with a literal position")
    return g.func("ARRAY_INSERT", [Some(this), position, Some(element)])
  }
  let mut pos_value = to_int(position)
  if pos_value > 0 {
    pos_value = pos_value - index_offset
  } else if pos_value < 0 {
    pos_value = pos_value + index_offset
  }
  let concat_exprs : Array[&@core.SqlArg] = if pos_value == 0 {
    [element_array, this]
  } else if pos_value > 0 {
    let slice_start = @core.mk(Bracket, [
      ("this", this),
      (
        "expressions",
        [@core.mk(Slice, [("this", num(1)), ("expression", num(pos_value))])],
      ),
    ])
    let slice_end = @core.mk(Bracket, [
      ("this", this),
      ("expressions", [@core.mk1(Slice, num(pos_value + 1))]),
    ])
    [slice_start, element_array, slice_end]
  } else {
    let arr_len = @core.mk1(Length, this)
    let slice_end_pos = add(arr_len, num(pos_value))
    let slice_start_pos = add(slice_end_pos, num(1))
    let slice_start = @core.mk(Bracket, [
      ("this", this),
      (
        "expressions",
        [@core.mk(Slice, [("this", num(1)), ("expression", slice_end_pos)])],
      ),
    ])
    let slice_end = @core.mk(Bracket, [
      ("this", this),
      ("expressions", [@core.mk1(Slice, slice_start_pos)]),
    ])
    [slice_start, element_array, slice_end]
  }
  g.sql(
    Some(
      if_(
        @core.mk(Is, [("this", this), ("expression", @core.null_())]),
        @core.null_(),
        g.func("LIST_CONCAT", concat_exprs),
      ),
    ),
  )
}

///|
/// Transpile ARRAY_REMOVE_AT to DuckDB using LIST_CONCAT and slicing.
fn array_remove_at_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let position = e.arg("position")
  guard position is Some(position) && position.is_int() else {
    g.unsupported(
      "ARRAY_REMOVE_AT can only be transpiled with a literal position",
    )
    return g.func("ARRAY_REMOVE_AT", [Some(this), position])
  }
  let pos_value = to_int(position)
  let result_expr : @core.Value = if pos_value == 0 {
    Node(
      @core.mk(Bracket, [
        ("this", this),
        ("expressions", [@core.mk1(Slice, num(2))]),
      ]),
    )
  } else if pos_value > 0 {
    let left_slice = @core.mk(Bracket, [
      ("this", this),
      (
        "expressions",
        [@core.mk(Slice, [("this", num(1)), ("expression", num(pos_value))])],
      ),
    ])
    let right_slice = @core.mk(Bracket, [
      ("this", this),
      ("expressions", [@core.mk1(Slice, num(pos_value + 2))]),
    ])
    Str(g.func("LIST_CONCAT", [left_slice, right_slice]))
  } else if pos_value == -1 {
    let arr_len = @core.mk1(Length, this)
    let slice_end = add(arr_len, num(-1))
    Node(
      @core.mk(Bracket, [
        ("this", this),
        (
          "expressions",
          [@core.mk(Slice, [("this", num(1)), ("expression", slice_end)])],
        ),
      ]),
    )
  } else {
    let arr_len = @core.mk1(Length, this)
    let slice_end_pos = add(arr_len, num(pos_value))
    let slice_start_pos = add(slice_end_pos, num(2))
    let left_slice = @core.mk(Bracket, [
      ("this", this),
      (
        "expressions",
        [@core.mk(Slice, [("this", num(1)), ("expression", slice_end_pos)])],
      ),
    ])
    let right_slice = @core.mk(Bracket, [
      ("this", this),
      ("expressions", [@core.mk1(Slice, slice_start_pos)]),
    ])
    Str(g.func("LIST_CONCAT", [left_slice, right_slice]))
  }
  g.sql(
    Some(
      if_(
        @core.mk(Is, [("this", this), ("expression", @core.null_())]),
        @core.null_(),
        result_expr,
      ),
    ),
  )
}

///|
fn array_sort_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if e.has("expression") {
    g.unsupported("DuckDB's ARRAY_SORT does not support a comparator.")
  }
  g.func("ARRAY_SORT", [e.this()])
}

///|
fn array_contains_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this = this_of(e)
  let expr = expr_of(e)
  let func_sql = g.func("ARRAY_CONTAINS", [this, expr])
  if e.has("check_null") {
    let check_null_in_array = @core.mk(Nullif, [
      (
        "this",
        @core.mk(NEQ, [
          ("this", @core.mk1(ArraySize, this)),
          ("expression", func("LIST_COUNT", [this])),
        ]),
      ),
      ("expression", @core.false_()),
    ])
    return g.sql(
      Some(if_(is_(expr, @core.null_()), check_null_in_array, func_sql)),
    )
  }
  func_sql
}

///|
/// Translates Snowflake's NULL-safe ARRAYS_OVERLAP to DuckDB.
fn array_overlaps_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  if !e.has("null_safe") {
    return g.binary(e, "&&")
  }
  let arr1 = this_of(e)
  let arr2 = expr_of(e)
  let check_nulls = @core.exp_and(
    [
      @core.mk(NEQ, [
        ("this", @core.mk1(ArraySize, arr1.copy())),
        ("expression", func("LIST_COUNT", [arr1.copy()])),
      ]),
      @core.mk(NEQ, [
        ("this", @core.mk1(ArraySize, arr2.copy())),
        ("expression", func("LIST_COUNT", [arr2.copy()])),
      ]),
    ],
    copy=false,
  )
  let overlap = @core.mk(ArrayOverlaps, [
    ("this", arr1.copy()),
    ("expression", arr2.copy()),
  ])
  g.sql(
    Some(
      @core.exp_or(
        [
          @core.exp_paren(overlap, copy=false),
          @core.exp_paren(check_nulls, copy=false),
        ],
        copy=false,
        wrap=false,
      ),
    ),
  )
}

///|
fn struct_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let ancestor_cast = match e.find_ancestor([Cast, Select]) {
    Some(a) if a.kind == Select => None
    a => a
  }
  // Empty struct cast works with MAP() since DuckDB can't parse {}
  if e.expressions().is_empty() {
    match ancestor_cast {
      Some(c) if c.kind.is_a(Cast) &&
        (match c.arg("to") {
          Some(to) => to.is_type([MAP])
          None => false
        }) => return "MAP()"
      _ => ()
    }
  }
  let args : Array[String] = []
  // BigQuery allows inline construction such as "STRUCT<a STRING, b INTEGER>('str', 1)" which is
  // canonicalized to "ROW('str', 1) AS STRUCT(a TEXT, b INT)" in DuckDB
  let is_bq_inline_struct = e.find([PropertyEQ]) is None &&
    (match ancestor_cast {
      Some(c) =>
        c.find_all([DataType]).any(casted_type => casted_type.is_type([STRUCT]))
      None => false
    })
  for i, expr in e.expressions() {
    let is_property_eq = expr.kind == PropertyEQ
    let this = expr.this()
    let value = if is_property_eq { expr.expression() } else { Some(expr) }
    if is_bq_inline_struct {
      args.push(g.sql(value))
    } else {
      let key = match this {
        Some(t) if t.kind == Identifier => g.sql(Some(str_lit(expr.name())))
        _ =>
          if is_property_eq {
            g.sql(this)
          } else {
            g.sql(Some(str_lit("_\{i}")))
          }
      }
      args.push("\{key}: \{g.sql(value)}")
    }
  }
  let csv_args = args.join(", ")
  if is_bq_inline_struct {
    "ROW(\{csv_args})"
  } else {
    "{\{csv_args}}"
  }
}

///|
fn json_format_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let sql = g.func("TO_JSON", [e.this(), e.arg("options")])
  "CAST(\{sql} AS TEXT)"
}

///|
/// Build a SEQ expression with the given base, byte width, and signedness.
fn build_seq_expression(
  base : @core.Expr,
  byte_width : Int,
  signed : Bool,
) -> @core.Expr raise @core.SqlglotError {
  let bits = byte_width * 8
  let max_val = numstr(pow2(bits))
  if signed {
    let half = numstr(pow2(bits - 1))
    return tmpl(seq_signed.get(), [
      ("base", base),
      ("max_val", max_val),
      ("half", half),
    ])
  }
  tmpl(seq_unsigned.get(), [("base", base), ("max_val", max_val)])
}

///|
fn pow2(bits : Int) -> String {
  if bits >= 64 {
    // 2 ** 64 does not fit in a UInt64
    return "18446744073709551616"
  }
  (1UL << bits).to_string()
}

///|
fn seq_byte_width(kind : @core.Kind) -> Int? {
  match kind {
    Seq1 => Some(1)
    Seq2 => Some(2)
    Seq4 => Some(4)
    Seq8 => Some(8)
    _ => None
  }
}

///|
/// Transform SEQ functions to `range` column references when inside a GENERATOR context.
fn seq_to_range_in_generator(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == Select else { return expression }
  match expression.arg("from_") {
    Some(from_) if (match from_.this() {
        Some(t) =>
          t.kind == TableFromRows &&
          (match t.this() {
            Some(gen) => gen.kind == Generator
            None => false
          })
        None => false
      }) => ()
    _ => return expression
  }
  // Pre-compute the replacements, since `transform` callbacks can't raise
  let replacements : Map[Int, @core.Expr] = Map([])
  let nodes : Array[@core.Expr] = []
  for node in expression.dfs() {
    match seq_byte_width(node.kind) {
      Some(width) => {
        replacements[nodes.length()] = build_seq_expression(
          @core.column_of("range"),
          width,
          node.name() == "1",
        )
        nodes.push(node)
      }
      None => ()
    }
  }
  expression.transform(
    node => {
      for i, n in nodes {
        if physical_equal(n, node) {
          return replacements.get(i)
        }
      }
      Some(node)
    },
    copy=false,
  )
}

///|
/// Rewrites START WITH ... CONNECT BY PRIOR into WITH RECURSIVE
fn connect_by_to_recursive_cte(
  expression : @core.Expr,
) -> @core.Expr raise @core.SqlglotError {
  guard expression.kind == Select && expression.has("connect") else {
    return expression
  }
  let connect = req(expression, "connect")
  let connect_pred = req(connect, "connect")
  let priors = connect_pred.find_all([Prior]).collect()
  if priors.is_empty() {
    return expression
  }
  let from_ = expression.arg("from_")
  guard from_ is Some(from_) && !expression.has("joins") else {
    return expression
  }
  let source_table = this_of(from_)
  let base_select_exprs = expression.expressions()
  let base_where = expression.arg("where")
  let base_with = expression.arg("with_")
  // LEVEL is a Snowflake pseudo-column: it's always computed as a depth counter in the CTE.
  let has_level = base_select_exprs
    .iter()
    .any(e => {
      e
      .find_all([Column])
      .any(col => col.kind.is_a(Column) && @core.py_upper(col.name()) == "LEVEL")
    })
  let has_star = expression.is_star()
  let root_col_names : Array[String] = []
  let anchor_root_cols : Array[@core.Expr] = []
  let inner_root_cols : Array[@core.Expr] = []
  let roots = []
  for e in base_select_exprs {
    for root in e.find_all([ConnectByRoot]) {
      roots.push(root)
    }
  }
  for i, root in roots {
    let name = "_connect_by_root_\{i}"
    root_col_names.push(name)
    anchor_root_cols.push(@core.alias_(this_of(root), name))
    inner_root_cols.push(
      @core.alias_(@core.column_of(name, table="_parent_row"), name),
    )
    root.replace(Some(@core.column_of(name))) |> ignore
  }

  // Build the join condition from the full CONNECT BY predicate:
  // PRIOR(col) → _parent_row.col, unqualified cols → _child_row.col.
  fn qualify_connect_pred(node : @core.Expr) -> @core.Expr {
    for col in @core.gen_find_all_in_scope(node, [Column]) {
      let is_prior = match col.parent {
        Some(p) => p.kind == Prior
        None => false
      }
      col.set(
        "table",
        @core.to_identifier(if is_prior { "_parent_row" } else { "_child_row" }),
      )
    }
    for prior in @core.gen_find_all_in_scope(node, [Prior]) {
      prior.replace(prior.this()) |> ignore
    }
    node
  }

  // Avoid colliding with any CTE names already on the query.
  let taken : Array[String] = match base_with {
    Some(w) => w.expressions().map(cte => cte.alias())
    None => []
  }
  let cte_name = @core.find_new_name(n => taken.contains(n), "_rootcte")
  // Anchor: project all source columns + seed LEVEL at 1 + bind each root column to its own value.
  let mut anchor = @core.select_(
    [@core.mk0(Star), @core.alias_(num(1), "level"), ..anchor_root_cols].map(x => {
      x.copy()
    }),
  ).from_(source_table.copy())
  match connect.arg("start") {
    Some(start) => anchor = anchor.where_([start])
    None => ()
  }
  // Recursive arm: carry all child columns + increment level + forward each root value.
  let inner_query = @core.select_(
      [
        @core.mk(Column, [
          ("this", @core.mk0(Star)),
          ("table", @core.to_identifier("_child_row")),
        ]),
        @core.alias_(
          add(@core.column_of("level", table="_parent_row"), num(1)),
          "level",
        ),
        ..inner_root_cols,
      ].map(x => x.copy()),
    )
    .from_(@core.alias_table(source_table, "_child_row"))
    .join_(@core.alias_table(@core.to_table(cte_name), "_parent_row"), on=[
      qualify_connect_pred(connect_pred),
    ])
  // Outer SELECT re-projects from the CTE.
  let outer_select_exprs = if has_star {
    let except_cols = if has_level { [] } else { [@core.column_of("level")] }
    for name in root_col_names {
      except_cols.push(@core.column_of(name))
    }
    let star = if except_cols.is_empty() {
      @core.mk0(Star)
    } else {
      @core.mk(Star, [("except_", except_cols)])
    }
    [star, ..base_select_exprs.filter(e => !e.is_star())]
  } else {
    base_select_exprs
  }
  let mut outer_query = @core.select_(outer_select_exprs.map(x => x.copy())).from_(
    @core.to_table(cte_name),
  )
  match base_where {
    Some(w) => outer_query = outer_query.where_([this_of(w)])
    None => ()
  }
  match base_with {
    Some(w) => outer_query.set("with_", w)
    None => ()
  }
  outer_query = outer_query.with_(
    cte_name,
    @core.exp_union(anchor, inner_query, distinct=false),
    recursive=true,
    copy=false,
  )
  for arg, val in expression.args {
    if val.truthy() &&
      !["connect", "where", "from_", "with_", "expressions"].contains(arg) {
      outer_query.set(arg, val)
    }
  }
  for col in @core.gen_find_all_in_scope(outer_query, [Column]) {
    col.set("table", (None : @core.Expr?))
  }
  outer_query
}

///|
/// Transpile Snowflake SEQ1/SEQ2/SEQ4/SEQ8 to DuckDB.
fn seq_sql(
  g : @core.Generator,
  e : @core.Expr,
  byte_width : Int,
) -> String raise @core.SqlglotError {
  match e.find_ancestor([Where, Having, AggFunc, Order, Select]) {
    Some(ancestor) if (!ancestor.kind.is_a(Order) && ancestor.kind != Select) ||
      (
        ancestor.kind.is_a(Order) &&
        (match ancestor.parent {
          Some(p) => p.kind == Window
          None => false
        })
      ) =>
      g.unsupported(
        "SEQ in restricted context is not supported - use CTE or subquery",
      )
    _ => ()
  }
  let result = build_seq_expression(
    seq_base.get().copy(),
    byte_width,
    e.name() == "1",
  )
  g.sql(Some(result))
}

///|
fn unix_to_time_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let scale = e.arg("scale")
  let mut timestamp = this_of(e)
  let is_ntz = match e.arg("target_type") {
    Some(t) => t.is_type([TIMESTAMP, TIMESTAMPNTZ]) && t.kind == DataType
    None => false
  }
  let scale_is = (n : Int) => {
    match scale {
      Some(s) => s.is_int() && to_int(s) == n
      None => false
    }
  }
  if scale_is(3) {
    // EPOCH_MS already returns TIMESTAMP (naive, UTC)
    return g.func("EPOCH_MS", [timestamp])
  }
  if scale_is(6) {
    // MAKE_TIMESTAMP already returns TIMESTAMP (naive, UTC)
    return g.func("MAKE_TIMESTAMP", [timestamp])
  }
  // Other scales: divide and use TO_TIMESTAMP
  match scale {
    Some(s) if !scale_is(0) =>
      timestamp = @core.mk(Div, [
        ("this", timestamp),
        ("expression", func("POW", [num(10), s])),
      ])
    _ => ()
  }
  let mut to_timestamp = @core.mk(Anonymous, [
    ("this", "TO_TIMESTAMP"),
    ("expressions", [timestamp]),
  ])
  if is_ntz {
    to_timestamp = @core.mk(AtTimeZone, [
      ("this", to_timestamp),
      ("zone", str_lit("UTC")),
    ])
  }
  g.sql(Some(to_timestamp))
}

///|
fn arrow_json_extract_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let mut arrow_sql = @core.arrow_json_extract_sql(g, e)
  match e.parent {
    Some(p) if !e.same_parent() && p.kind.is_any([Binary, Bracket, In, Not]) =>
      arrow_sql = g.wrap_str(arrow_sql)
    _ => ()
  }
  arrow_sql
}

///|
fn implicit_datetime_cast(
  arg : @core.Expr?,
  type_? : @core.DType = DATE,
) -> @core.Expr? {
  match arg {
    Some(a) if a.kind == Literal && a.is_string() => {
      let ts = a.name()
      let mut t = type_
      if t == DATE && ts.contains(":") {
        t = if has_timezone(ts) { TIMESTAMPTZ } else { TIMESTAMP }
      }
      Some(cast(a, t))
    }
    _ => arg
  }
}

///|
fn week_trunc_start_dow(unit : @core.Expr?) -> Int? {
  // DuckDB's weeks are ISO 8601, so ISOWEEK maps to its plain WEEK unit
  match unit {
    Some(u) if u.kind == Literal && @core.py_upper(u.name()) == "ISOWEEK" =>
      Some(1)
    _ => @core.week_unit_to_dow(unit)
  }
}

///|
/// Build DATE_TRUNC expression for week boundaries with custom start day.
fn build_week_trunc_expression(
  date_expr : @core.Expr,
  start_dow : Int,
  preserve_start_day? : Bool = false,
  cast_to_date? : Bool = true,
) -> @core.Expr {
  let shift_days = if start_dow == 7 { 1 } else { 1 - start_dow }
  let truncated = @core.mk(DateTrunc, [
    ("unit", @core.var_("WEEK")),
    ("this", date_expr.copy()),
  ])
  if shift_days == 0 {
    return truncated
  }
  let shift = interval(str_lit(shift_days.to_string()), "DAY")
  let shifted_date = @core.mk(DateAdd, [
    ("this", date_expr),
    ("expression", shift),
  ])
  truncated.set("this", shifted_date)
  if preserve_start_day {
    let iv = interval(str_lit((-shift_days).to_string()), "DAY")
    let shifted_back = @core.mk(DateAdd, [
      ("this", truncated),
      ("expression", iv),
    ])
    if cast_to_date {
      return @core.exp_cast(shifted_back, DATE, copy=false)
    }
    return shifted_back
  }
  truncated
}

///|
fn date_diff_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let unit = e.arg("unit")
  if is_nanosecond_unit(unit) {
    return handle_nanosecond_diff(g, this_of(e), expr_of(e))
  }
  let mut this = implicit_datetime_cast(e.this())
  let mut expr = implicit_datetime_cast(e.expression())
  let date_part_boundary = e.has("date_part_boundary")
  match (@core.week_unit_to_dow(unit), this, expr) {
    (Some(week_start), Some(t), Some(x)) if date_part_boundary &&
      week_start != 0 => {
      e.set("unit", str_lit("WEEK"))
      this = Some(build_week_trunc_expression(t, week_start))
      expr = Some(build_week_trunc_expression(x, week_start))
    }
    _ => ()
  }
  g.func("DATE_DIFF", [@core.unit_to_str(e), expr, this])
}

///|
fn generate_datetime_array_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let is_generate_date_array = e.kind == GenerateDateArray
  let t : @core.DType = if is_generate_date_array { DATE } else { TIMESTAMP }
  let start = implicit_datetime_cast(e.arg("start"), type_=t)
  let end = implicit_datetime_cast(e.arg("end"), type_=t)
  let mut gen_series = @core.mk(GenerateSeries, [
    ("start", start),
    ("end", end),
    ("step", e.arg("step")),
  ])
  if is_generate_date_array {
    gen_series = cast_to(gen_series, base_type("ARRAY<DATE>"))
  }
  g.sql(Some(gen_series))
}

///|
fn json_extract_value_array_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let json_extract = @core.mk(JSONExtract, [
    ("this", e.this()),
    ("expression", e.expression()),
  ])
  let data_type = if e.kind == JSONValueArray {
    "ARRAY<STRING>"
  } else {
    "ARRAY<JSON>"
  }
  g.sql(Some(cast_to(json_extract, base_type(data_type))))
}

///|
fn cast_to_varchar(arg : @core.Expr?) -> @core.Expr? {
  match arg {
    Some(a) if has_type(a) && !a.is_type([..@core.dtype_text_types, UNKNOWN]) =>
      Some(cast(a, VARCHAR))
    _ => arg
  }
}

///|
fn cast_to_boolean(arg : @core.Expr?) -> @core.Expr? {
  match arg {
    Some(a) if !a.is_type([BOOLEAN]) => Some(cast(a, BOOLEAN))
    _ => arg
  }
}

///|
fn is_binary(arg : @core.Expr?) -> Bool {
  match arg {
    Some(a) => a.is_type([BINARY, VARBINARY, BLOB])
    None => false
  }
}

///|
fn gen_with_cast_to_blob(
  g : @core.Generator,
  e : @core.Expr,
  result_sql : String,
) -> String raise @core.SqlglotError {
  if is_binary(Some(e)) {
    let blob = duck_type("BLOB")
    return g.sql(Some(@core.mk(Cast, [("this", result_sql), ("to", blob)])))
  }
  result_sql
}

///|
fn cast_to_bit(arg : @core.Expr) -> @core.Expr {
  if !is_binary(Some(arg)) {
    return arg
  }
  let arg = if arg.kind == HexString {
    @core.mk1(Unhex, str_lit(arg.text("this")))
  } else {
    arg
  }
  cast(arg, BIT)
}

///|
fn prepare_binary_bitwise_args(e : @core.Expr) -> Unit {
  if is_binary(e.this()) {
    e.set("this", cast_to_bit(e.this_()))
  }
  if is_binary(e.expression()) {
    e.set("expression", cast_to_bit(e.expression_()))
  }
}

///|
/// Transpile Snowflake's NEXT_DAY / PREVIOUS_DAY to DuckDB using date arithmetic.
fn day_navigation_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let date_expr = this_of(e)
  let day_name_expr = expr_of(e)
  let isodow_call = func("ISODOW", [date_expr])
  let target_dow = if day_name_expr.kind == Literal {
    let day_name_str = @core.py_upper(day_name_expr.name())
    let mut matching : Int? = None
    for day, dow in @core.week_start_day_to_dow {
      if day.has_prefix(day_name_str) {
        matching = Some(dow)
        break
      }
    }
    match matching {
      Some(dow) => num(dow)
      None => return g.function_fallback_sql(e)
    }
  } else {
    let upper_day_name = @core.mk1(Upper, day_name_expr)
    let ifs = []
    for day, dow_num in @core.week_start_day_to_dow {
      ifs.push(
        @core.mk(If, [
          (
            "this",
            func("STARTS_WITH", [
              upper_day_name.copy(),
              str_lit(@core.substr(day, 0, 2)),
            ]),
          ),
          ("true", num(dow_num)),
        ]),
      )
    }
    @core.mk(Case, [("ifs", ifs)])
  }
  let date_with_offset = if e.kind == NextDay {
    let days_offset = add(
      mod_(
        @core.exp_paren(add(sub(target_dow, isodow_call), num(6)), copy=false),
        num(7),
      ),
      num(1),
    )
    add(date_expr, interval(days_offset, "DAY"))
  } else {
    let days_offset = add(
      mod_(
        @core.exp_paren(add(sub(isodow_call, target_dow), num(6)), copy=false),
        num(7),
      ),
      num(1),
    )
    sub(date_expr, interval(days_offset, "DAY"))
  }
  g.sql(Some(cast(date_with_offset, DATE)))
}

///|
fn anyvalue_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  // Transform ANY_VALUE(expr HAVING MAX/MIN having_expr) to ARG_MAX_NULL/ARG_MIN_NULL
  match e.this() {
    Some(having) if having.kind == HavingMax => {
      let func_name = if having.has("max") {
        "ARG_MAX_NULL"
      } else {
        "ARG_MIN_NULL"
      }
      g.func(func_name, [having.this(), having.expression()])
    }
    _ => g.function_fallback_sql(e)
  }
}

///|
fn bitwise_agg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let func_name = match e.kind {
    BitwiseOrAgg => "BIT_OR"
    BitwiseAndAgg => "BIT_AND"
    _ => "BIT_XOR"
  }
  let mut arg = this_of(e)
  if !has_type(arg) {
    arg = @core.gen_annotate_types(arg, g.dialect)
  }
  if arg.is_type([..@core.dtype_real_types, ..@core.dtype_text_types]) {
    if arg.is_type(@core.dtype_float_types) {
      arg = func("ROUND", [arg])
    }
    arg = cast(arg, INT)
  }
  g.func(func_name, [arg])
}

///|
fn literal_sql_with_ws_chr(
  g : @core.Generator,
  literal : String,
) -> String raise @core.SqlglotError {
  // DuckDB does not support \uXXXX escapes, so we must use CHR() instead of replacing them directly
  if !literal.iter().any(ch => ws_control_chars_to_duck.contains(ch)) {
    return g.sql(Some(str_lit(literal)))
  }
  let sql_segments : Array[String] = []
  let buf = StringBuilder()
  for ch in literal {
    match ws_control_chars_to_duck.get(ch) {
      Some(code) => {
        if buf.to_string() != "" {
          sql_segments.push(g.sql(Some(str_lit(buf.to_string()))))
          buf.reset()
        }
        sql_segments.push(g.func("CHR", [numstr(code.to_string())]))
      }
      None => buf.write_char(ch)
    }
  }
  if buf.to_string() != "" {
    sql_segments.push(g.sql(Some(str_lit(buf.to_string()))))
  }
  let sql = sql_segments.join(" || ")
  if sql_segments.length() == 1 {
    sql
  } else {
    "(\{sql})"
  }
}

///|
/// Escapes regex metacharacters \ - ^ [ ] for use in character classes regex expressions.
fn escape_regex_metachars(
  g : @core.Generator,
  delimiters : @core.Expr?,
  delimiters_sql : String,
) -> String raise @core.SqlglotError {
  guard delimiters is Some(delimiters) else { return delimiters_sql }
  if delimiters.is_string() {
    let literal_value = delimiters.text("this")
    let escaped = StringBuilder()
    for ch in literal_value {
      let mut replaced = false
      for r in regex_escape_replacements {
        if r.0 == ch {
          escaped.write_string(r.1)
          replaced = true
          break
        }
      }
      if !replaced {
        escaped.write_char(ch)
      }
    }
    return literal_sql_with_ws_chr(g, escaped.to_string())
  }
  let mut escaped_sql = delimiters_sql
  for r in regex_escape_replacements {
    escaped_sql = g.func("REPLACE", [
      escaped_sql,
      g.sql(Some(str_lit(r.0.to_string()))),
      g.sql(Some(str_lit(r.1))),
    ])
  }
  escaped_sql
}

///|
fn build_capitalization_sql(
  g : @core.Generator,
  value_to_split : String,
  delimiters_sql : String,
) -> String raise @core.SqlglotError {
  // empty string delimiter --> treat value as one word, no need to split
  if delimiters_sql == "''" {
    return "UPPER(LEFT(\{value_to_split}, 1)) || LOWER(SUBSTRING(\{value_to_split}, 2))"
  }
  let delim_regex_sql = "CONCAT('[', \{delimiters_sql}, ']')"
  let split_regex_sql = "CONCAT('([', \{delimiters_sql}, ']+|[^', \{delimiters_sql}, ']+)')"
  let when_sql = "REGEXP_MATCHES(LEFT(\{value_to_split}, 1), \{delim_regex_sql})"
  let then_sql = g.func("LIST_TRANSFORM", [
    g.func("REGEXP_EXTRACT_ALL", [value_to_split, split_regex_sql]),
    "(seg, idx) -> CASE WHEN idx % 2 = 0 THEN UPPER(LEFT(seg, 1)) || LOWER(SUBSTRING(seg, 2)) ELSE seg END",
  ])
  let else_sql = g.func("LIST_TRANSFORM", [
    g.func("REGEXP_EXTRACT_ALL", [value_to_split, split_regex_sql]),
    "(seg, idx) -> CASE WHEN idx % 2 = 1 THEN UPPER(LEFT(seg, 1)) || LOWER(SUBSTRING(seg, 2)) ELSE seg END",
  ])
  let case_expr = else_(
    when(case_(), parse(when_sql), parse(then_sql)),
    parse(else_sql),
  )
  g.func("ARRAY_TO_STRING", [case_expr, "''"])
}

///|
fn initcap_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let this_sql = g.sql_key(e, "this")
  let delimiters = match e.arg("expression") {
    Some(d) => d
    // fallback for manually created exp.Initcap w/o delimiters arg
    None => str_lit(g.dialect.cfg.initcap_default_delimiter_chars)
  }
  let delimiters_sql = g.sql(Some(delimiters))
  let escaped_delimiters_sql = escape_regex_metachars(
    g,
    Some(delimiters),
    delimiters_sql,
  )
  build_capitalization_sql(g, this_sql, escaped_delimiters_sql)
}

///|
fn boolxor_agg_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  g.sql(
    Some(
      @core.mk(EQ, [
        ("this", @core.mk1(CountIf, cast_to_boolean(e.this()))),
        ("expression", num(1)),
      ]),
    ),
  )
}

///|
/// Transform bitshift expressions for DuckDB by injecting BIT/INT128 casts.
fn bitshift_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let operator = if e.kind == BitwiseLeftShift { "<<" } else { ">>" }
  let mut result_is_blob = false
  let this = this_of(e)
  if is_binary(Some(this)) {
    result_is_blob = true
    e.set("this", cast(this, BIT))
  } else if e.has("requires_int128") {
    this.replace(Some(cast(this, INT128))) |> ignore
  }
  let mut result_sql = g.binary(e, operator)
  // Wrap in parentheses if parent is a bitwise operator to "fix" DuckDB precedence issue
  match e.parent {
    Some(p) if p.kind.is_a(Binary) =>
      result_sql = g.sql(Some(@core.mk1(Paren, result_sql)))
    _ => ()
  }
  if result_is_blob {
    result_sql = g.sql(
      Some(@core.mk(Cast, [("this", result_sql), ("to", duck_type("BLOB"))])),
    )
  }
  result_sql
}

///|
/// Handle scale parameter transformation for rounding functions.
fn scale_rounding_sql(
  g : @core.Generator,
  e : @core.Expr,
  rounding_func : @core.Kind,
) -> String? raise @core.SqlglotError {
  guard e.arg("decimals") is Some(decimals) && e.arg("to") is None else {
    return None
  }
  let mut this = this_of(e)
  if this.kind.is_a(Binary) {
    this = @core.mk1(Paren, this)
  }
  let n_int = if !(decimals.is_int() || is_integer(decimals)) {
    cast(decimals, INT)
  } else {
    decimals
  }
  let pow_ = @core.mk(Pow, [("this", numstr("10")), ("expression", n_int)])
  let rounded = @core.mk1(
    rounding_func,
    @core.mk(Mul, [("this", this), ("expression", pow_)]),
  )
  let result = @core.mk(Div, [("this", rounded), ("expression", pow_.copy())])
  Some(
    round_sql(
      g,
      @core.mk(Round, [
        ("this", result),
        ("decimals", decimals),
        ("casts_non_integer_decimals", true),
      ]),
    ),
  )
}

///|
fn ceil_floor(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  match scale_rounding_sql(g, e, e.kind) {
    Some(s) => s
    None => g.ceil_floor(e)
  }
}

///|
/// Transpile Snowflake's REGR_VALX/REGR_VALY to DuckDB equivalent.
fn regr_val_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let y = this_of(e)
  let x = expr_of(e)
  let (check_for_null, return_value, return_value_attr) = if e.kind == RegrValx {
    (y, x, "expression")
  } else {
    (x, y, "this")
  }
  let unknown = (t : @core.Expr?) => {
    match t {
      None => true
      Some(t) => t.datatype_this() == Some(UNKNOWN)
    }
  }
  let mut result_type = return_value.get_type()
  if unknown(result_type) {
    let annotated = @core.gen_annotate_types(e.copy(), g.dialect) catch {
      _ => e
    }
    match annotated.arg(return_value_attr) {
      Some(a) if !physical_equal(annotated, e) => result_type = a.get_type()
      _ => ()
    }
  }
  if unknown(result_type) {
    result_type = Some(@core.datatype_of(DOUBLE))
  }
  let typed_null = @core.mk(Cast, [("this", @core.null_()), ("to", result_type)])
  g.sql(
    Some(
      if_(
        @core.mk(Is, [
          ("this", check_for_null.copy()),
          ("expression", @core.null_()),
        ]),
        typed_null,
        return_value.copy(),
      ),
    ),
  )
}

///|
fn maybe_corr_null_to_false(e : @core.Expr) -> @core.Expr? {
  let mut corr = e
  while corr.kind == Window || corr.kind == Filter {
    corr = corr.this_()
  }
  if corr.kind != Corr || !corr.has("null_on_zero_variance") {
    return None
  }
  corr.set("null_on_zero_variance", false)
  Some(e)
}

///|
/// Snowflake's DATE_FROM_PARTS allows out-of-range values for the month and day input.
fn date_from_parts_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let year_expr = e.arg("year")
  let month_expr = e.arg("month")
  let day_expr = e.arg("day")
  if e.has("allow_overflow") {
    let mut base_date = func("MAKE_DATE", [year_expr.unwrap(), num(1), num(1)])
    match month_expr {
      Some(m) => base_date = add(base_date, interval(sub(m, num(1)), "MONTH"))
      None => ()
    }
    match day_expr {
      Some(d) => base_date = add(base_date, interval(sub(d, num(1)), "DAY"))
      None => ()
    }
    return g.sql(Some(cast(base_date, DATE)))
  }
  g.func("MAKE_DATE", [year_expr, month_expr, day_expr])
}

///|
fn round_arg(
  arg : @core.Expr,
  round_input : Bool,
) -> @core.Expr raise @core.SqlglotError {
  if round_input {
    return func("ROUND", [arg, num(0)])
  }
  arg
}

///|
fn boolnot_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let arg = round_arg(this_of(e), e.has("round_input"))
  g.sql(Some(@core.exp_not(@core.exp_paren(arg))))
}

///|
fn booland_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let round_input = e.has("round_input")
  let left = round_arg(this_of(e), round_input)
  let right = round_arg(expr_of(e), round_input)
  g.sql(
    Some(
      @core.exp_paren(
        @core.exp_and(
          [@core.exp_paren(left), @core.exp_paren(right)],
          wrap=false,
        ),
      ),
    ),
  )
}

///|
fn boolor_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let round_input = e.has("round_input")
  let left = round_arg(this_of(e), round_input)
  let right = round_arg(expr_of(e), round_input)
  g.sql(
    Some(
      @core.exp_paren(
        @core.exp_or(
          [@core.exp_paren(left), @core.exp_paren(right)],
          wrap=false,
        ),
      ),
    ),
  )
}

///|
fn xor_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let round_input = e.has("round_input")
  let left = round_arg(this_of(e), round_input)
  let right = round_arg(expr_of(e), round_input)
  g.sql(
    Some(
      @core.exp_or(
        [
          @core.exp_paren(
            @core.exp_and(
              [left.copy(), @core.exp_paren(not_(right))],
              wrap=false,
            ),
          ),
          @core.exp_paren(
            @core.exp_and(
              [@core.exp_paren(not_(left)), right.copy()],
              wrap=false,
            ),
          ),
        ],
        wrap=false,
      ),
    ),
  )
}

///|
/// Handle LATERAL VIEW EXPLODE/INLINE conversion to UNNEST for DuckDB.
fn explode_to_unnest_sql(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let explode = e.this()
  match explode {
    Some(ex) if ex.kind == Inline => {
      let unnest_expr = @core.mk(Unnest, [
        (
          "expressions",
          [
            this_of(ex),
            @core.mk(Kwarg, [
              ("this", @core.var_("max_depth")),
              ("expression", num(2)),
            ]),
          ],
        ),
      ])
      let select_expr = @core.mk(Select, [("expressions", [unnest_expr])]).subquery()
      let alias_expr = e.arg("alias")
      match alias_expr {
        Some(a) if !a.has("this") => {
          let index = match e.index {
            Some(i) => i
            None => 0
          }
          a.set("this", @core.to_identifier("_u_\{index}"))
        }
        _ => ()
      }
      let transformed_lateral_expr = @core.mk(Lateral, [
        ("this", select_expr),
        ("alias", alias_expr),
      ])
      let cross_join_lateral_expr = @core.mk(Join, [
        ("this", transformed_lateral_expr),
        ("kind", "CROSS"),
      ])
      g.sql(Some(cross_join_lateral_expr))
    }
    _ => @core.explode_to_unnest_sql(g, e)
  }
}

///|
fn sha_sql(
  g : @core.Generator,
  e : @core.Expr,
  hash_func : String,
  binary? : Bool = false,
) -> String raise @core.SqlglotError {
  let mut arg = this_of(e)
  if hash_func == "SHA256" {
    let length = match e.text("length") {
      "" => "256"
      l => l
    }
    if length != "256" {
      g.unsupported("DuckDB only supports SHA256 hashing algorithm.")
    }
  }
  let needs_cast = match arg.get_type() {
    Some(t) => t.datatype_this() != Some(UNKNOWN)
    None => false
  }
  if needs_cast && !is_text(arg) && !is_binary(Some(arg)) {
    arg = cast(arg, VARCHAR)
  }
  let result = g.func(hash_func, [arg])
  if binary {
    g.func("UNHEX", [result])
  } else {
    result
  }
}
