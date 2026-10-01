// Generator methods for literals, identifiers, data types and operators.

///|
pub let annotate_types_hook : Ref[((Expr, Dialect) -> Expr raise SqlglotError)?] = Ref(
  None,
)

///|
pub let simplify_hook : Ref[((Expr, Dialect) -> Expr raise SqlglotError)?] = Ref(
  None,
)

///|
/// Annotates types using `annotate_types_hook`, or a minimal fallback that only
/// types integer literals.
pub fn gen_annotate_types(
  expression : Expr,
  dialect : Dialect,
) -> Expr raise SqlglotError {
  match annotate_types_hook.val {
    Some(f) => f(expression, dialect)
    None => {
      // Minimal fallback until the optimizer's annotate_types is available.
      if expression.get_type() is None {
        let dtype = if expression.is_int() {
          Some(DType::INT)
        } else if expression.kind == Literal && expression.is_number() {
          Some(DType::DOUBLE)
        } else if expression.kind == Neg &&
          expression.this() is Some(operand) &&
          operand.kind == Literal &&
          operand.is_number() {
          // Unary minus keeps the type of its numeric literal operand
          gen_annotate_types(operand, dialect) |> ignore
          match operand.get_type() {
            Some(t) => t.datatype_this()
            None => None
          }
        } else if expression.kind == Timestamp {
          Some(
            if expression.has("with_tz") {
              DType::TIMESTAMPTZ
            } else {
              DType::TIMESTAMP
            },
          )
        } else if expression.is_string() {
          Some(DType::VARCHAR)
        } else if expression.kind == Kind::Array {
          Some(DType::ARRAY)
        } else if expression.kind == Boolean {
          Some(DType::BOOLEAN)
        } else {
          None
        }
        match dtype {
          Some(d) => expression.set_type(Some(datatype_of(d)))
          None => ()
        }
      }
      expression
    }
  }
}

///|
fn gen_simplify(
  expression : Expr,
  dialect : Dialect,
) -> Expr raise SqlglotError {
  match simplify_hook.val {
    Some(f) => f(expression, dialect)
    None => {
      // Minimal constant folding for `int + int`
      if expression.kind == Add {
        match (expression.arg("this"), expression.arg("expression")) {
          (Some(a), Some(b)) =>
            match (a.to_py_int(), b.to_py_int()) {
              (Some(x), Some(y)) if a.is_int() && b.is_int() =>
                return literal_number((x + y).to_string())
              _ => ()
            }
          _ => ()
        }
      }
      expression
    }
  }
}

///|
/// Python `expressions.apply_index_offset`.
pub fn gen_apply_index_offset(
  this : Expr,
  expressions : Array[Expr],
  offset : Int,
  dialect : Dialect,
) -> Array[Expr] raise SqlglotError {
  if offset == 0 || expressions.length() != 1 {
    return expressions
  }
  let mut expression = expressions[0]
  if this.get_type() is None {
    gen_annotate_types(this, dialect) |> ignore
  }
  let this_type = match this.get_type() {
    Some(t) => t.datatype_this()
    None => Some(DType::UNKNOWN)
  }
  if !(this_type == Some(DType::UNKNOWN) || this_type == Some(DType::ARRAY)) {
    return expressions
  }
  if expression.get_type() is None {
    gen_annotate_types(expression, dialect) |> ignore
  }
  let et = match expression.get_type() {
    Some(t) => t.datatype_this()
    None => None
  }
  match et {
    Some(d) if dtype_integer_types.contains(d) => {
      g_log_info("Applying array index offset (\{offset})")
      expression = gen_simplify(
        exp_add(expression, literal_int(offset)),
        dialect,
      )
      [expression]
    }
    _ => expressions
  }
}

///|
fn g_log_info(msg : String) -> Unit {
  ignore(msg)
}

// ---------------------------------------------------------------------------
// Literals and strings

///|
pub fn Generator::bitstring_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  if g_str_truthy(self.dialect.cfg.bit_start) {
    return g_opt_str(self.dialect.cfg.bit_start) +
      this +
      g_opt_str(self.dialect.cfg.bit_end)
  }
  int_str_from_base(this, 2)
}

///|
/// Virtual `hexstring_sql(expression, binary_function_repr)`.
pub fn Generator::hexstring_sql_v(
  self : Generator,
  expression : Expr,
  binary_function_repr? : String,
) -> String raise SqlglotError {
  match self.fns.hooks.hexstring_sql {
    Some(f) => f(self, expression, binary_function_repr)
    None => self.hexstring_sql(expression, binary_function_repr?)
  }
}

///|
pub fn Generator::hexstring_sql(
  self : Generator,
  expression : Expr,
  binary_function_repr? : String,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let is_integer_type = expression.has("is_integer")
  let has_repr = g_str_truthy(binary_function_repr)
  if (is_integer_type && !self.dialect.cfg.hex_string_is_integer_type) ||
    (!g_str_truthy(self.dialect.cfg.hex_start) && !has_repr) {
    return int_str_from_base(this, 16)
  }
  if !is_integer_type {
    if has_repr {
      return self.func(g_opt_str(binary_function_repr), [literal_string(this)])
    }
    if self.dialect.cfg.hex_string_is_integer_type {
      self.unsupported("Unsupported transpilation from BINARY/BLOB hex string")
    }
  }
  g_opt_str(self.dialect.cfg.hex_start) + this + g_opt_str(self.dialect.cfg.hex_end)
}

///|
pub fn Generator::bytestring_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  if g_str_truthy(self.dialect.cfg.byte_start) {
    let byte_end = g_opt_str(self.dialect.cfg.byte_end)
    let escaped_byte_string = self.escape_str(
      this,
      escape_backslash=false,
      delimiter=byte_end,
      escaped_delimiter=self.escaped_byte_quote_end,
      is_byte_string=true,
    )
    let is_bytes = expression.has("is_bytes")
    let delimited_byte_string = g_opt_str(self.dialect.cfg.byte_start) +
      escaped_byte_string +
      byte_end
    if is_bytes && !self.dialect.cfg.byte_string_is_bytes_type {
      return self.sql(
        Some(
          exp_cast(
            maybe_parse_str(delimited_byte_string, dialect=self.dialect),
            DType::BINARY,
            dialect=self.dialect,
          ),
        ),
      )
    }
    if !is_bytes && self.dialect.cfg.byte_string_is_bytes_type {
      return self.sql(
        Some(
          exp_cast(
            maybe_parse_str(delimited_byte_string, dialect=self.dialect),
            DType::VARCHAR,
            dialect=self.dialect,
          ),
        ),
      )
    }
    return delimited_byte_string
  }
  if self.dialect.tokenizer.string_escapes.contains("\\") {
    return self.sql(Some(literal_string(this)))
  }
  self.unsupported(
    "Byte strings are not supported for \{self.dialect_class_name()}",
  )
  ""
}

///|
/// `re.sub(rf"{prefix}(\d+)", repl, text)` with a literal prefix.
fn g_sub_escaped_digits(
  text : String,
  prefix : String,
  repl : (String) -> String,
) -> String {
  let chars = text.to_array()
  let pchars = prefix.to_array()
  let n = chars.length()
  let pn = pchars.length()
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    let mut matches = i + pn <= n
    if matches {
      for j in 0..<pn {
        if chars[i + j] != pchars[j] {
          matches = false
          break
        }
      }
    }
    if matches {
      let mut k = i + pn
      while k < n && is_digit_char(chars[k]) {
        k += 1
      }
      if k > i + pn {
        sb.write_string(repl(String::from_array(chars[i + pn:k])))
        i = k
        continue
      }
    }
    sb.write_char(chars[i])
    i += 1
  }
  sb.to_string()
}

///|
pub fn Generator::unicodestring_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  let escape = expression.arg("escape")
  let unicode_start = self.dialect.cfg.unicode_start
  let has_unicode_start = g_str_truthy(unicode_start)
  let (escape_substitute, left_quote, right_quote) : (
    (String) -> String,
    String,
    String,
  ) = if has_unicode_start {
    (
      fn(g) { "\\" + g },
      g_opt_str(unicode_start),
      g_opt_str(self.dialect.cfg.unicode_end),
    )
  } else {
    (
      fn(g) { "\\u" + g },
      self.dialect.cfg.quote_start,
      self.dialect.cfg.quote_end,
    )
  }
  let (escape_prefix, escape_sql) = match escape {
    Some(esc) =>
      (
        esc.name(),
        if self.cfg.supports_uescape {
          " UESCAPE " + self.sql(Some(esc))
        } else {
          ""
        },
      )
    None => ("\\", "")
  }
  if !has_unicode_start || (escape is Some(_) && !self.cfg.supports_uescape) {
    let repl = match self.fns.hooks.unicode_substitute {
      Some(f) => f
      None => escape_substitute
    }
    this = g_sub_escaped_digits(this, escape_prefix, repl)
  }
  if has_unicode_start {
    this = self.replace_line_breaks(this)
    if right_quote != "" {
      this = this.replace_all(old=right_quote, new=right_quote + right_quote)
    }
  } else {
    this = self.escape_str(this, escape_backslash=false)
  }
  left_quote + this + right_quote + escape_sql
}

///|
pub fn Generator::rawstring_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut string = expression.text("this")
  if self.dialect.tokenizer.string_escapes.contains("\\") {
    string = string.replace_all(old="\\", new="\\\\")
  }
  string = self.escape_str(string, escape_backslash=false)
  self.dialect.cfg.quote_start + string + self.dialect.cfg.quote_end
}

///|
pub fn Generator::literal_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let text = match expression.get("this") {
    Some(Str(s)) => s
    Some(v) if v.truthy() => py_str_value(Some(v))
    _ => ""
  }
  if expression.is_string() {
    return self.dialect.cfg.quote_start +
      self.escape_str(text) +
      self.dialect.cfg.quote_end
  }
  text
}

///|
pub fn Generator::escape_str(
  self : Generator,
  text : String,
  escape_backslash? : Bool = true,
  delimiter? : String,
  escaped_delimiter? : String,
  is_byte_string? : Bool = false,
) -> String {
  let supports_escape_sequences = if is_byte_string {
    self.dialect.cfg.byte_strings_support_escaped_sequences
  } else {
    self.dialect.cfg.strings_support_escaped_sequences
  }
  let mut text = text
  if supports_escape_sequences {
    let sb = StringBuilder()
    let seqs = self.dialect.cfg.escaped_sequences
    for ch in text {
      if escape_backslash || ch != '\\' {
        match seqs.get(ch.to_string()) {
          Some(s) => sb.write_string(s)
          None => sb.write_char(ch)
        }
      } else {
        sb.write_char(ch)
      }
    }
    text = sb.to_string()
  }
  let delimiter = match delimiter {
    Some(d) if d != "" => d
    _ => self.dialect.cfg.quote_end
  }
  let escaped_delimiter = match escaped_delimiter {
    Some(d) if d != "" => d
    _ => self.escaped_quote_end
  }
  let text = self.replace_line_breaks(text)
  if delimiter == "" {
    text
  } else {
    text.replace_all(old=delimiter, new=escaped_delimiter)
  }
}

///|
pub fn Generator::national_sql(
  self : Generator,
  expression : Expr,
  prefix? : String = "N",
) -> String raise SqlglotError {
  let string = self.sql(Some(literal_string(expression.name())))
  prefix + string
}

///|
pub fn Generator::identifier_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut text = expression.name()
  let lower = py_lower(text)
  let quoted = expression.has("quoted")
  if self.normalize && !quoted {
    text = lower
  }
  if self.identifier_end != "" {
    text = text.replace_all(
      old=self.identifier_end,
      new=self.escaped_identifier_end,
    )
  }
  if quoted ||
    self.dialect.can_quote(expression, identify=self.identify) ||
    self.cfg.reserved_keywords.contains(lower) ||
    (
      !self.dialect.cfg.identifiers_can_start_with_digit &&
      (match g_first_char(text) {
        Some(c) => is_digit_char(c)
        None => false
      })
    ) {
    text = self.identifier_start +
      self.replace_line_breaks(text) +
      self.identifier_end
  }
  text
}

///|
pub fn Generator::null_sql(self : Generator, expression : Expr) -> String {
  ignore((self, expression))
  "NULL"
}

///|
pub fn Generator::boolean_sql(self : Generator, expression : Expr) -> String {
  ignore(self)
  if expression.has("this") {
    "TRUE"
  } else {
    "FALSE"
  }
}

///|
pub fn Generator::var_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this")
}

///|
pub fn Generator::parameter_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  self.cfg.parameter_token + this
}

///|
pub fn Generator::sessionparameter_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let kind = g_pfx("", expression.text("kind"))
  let kind = if kind != "" { kind + "." } else { kind }
  "@@" + kind + this
}

///|
pub fn Generator::placeholder_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if expression.has("this") {
    self.cfg.named_placeholder_token + expression.name()
  } else {
    "?"
  }
}

///|
pub fn Generator::heredoc_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let tag = self.sql_key(expression, "tag")
  "$" + tag + "$" + self.sql_key(expression, "this") + "$" + tag + "$"
}

// ---------------------------------------------------------------------------
// Data types

///|
pub fn Generator::datatypeparam_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let specifier = self.sql_key(expression, "expression")
  let specifier = if specifier != "" && self.cfg.data_type_specifiers_allowed {
    " " + specifier
  } else {
    ""
  }
  this + specifier
}

///|
pub fn Generator::datatype_param_bound_limiter(
  self : Generator,
  expression : Expr,
  type_value : DType,
  defaults : Array[Int],
  bounds : Array[Int?],
) -> Expr raise SqlglotError {
  let params = expression.raw_list("expressions")
  if params.is_empty() {
    if !defaults.is_empty() {
      expression.set(
        "expressions",
        defaults.map(d => mk1(DataTypeParam, literal_int(d))),
      )
    }
    return expression
  }
  if bounds.is_empty() {
    return expression
  }
  for i in 0..<params.length() {
    let bound = if i < bounds.length() { bounds[i] } else { None }
    guard bound is Some(bound) else { continue }
    guard params[i] is Node(param) else { continue }
    let param_value = if param.kind.is_a(DataTypeParam) {
      match param.this() {
        Some(t) => t
        None => continue
      }
    } else {
      param
    }
    let value = if param_value.kind.is_a(Literal) && param_value.is_number() {
      param_value.to_py_float()
    } else {
      None
    }
    match value {
      Some(v) if v > bound.to_double() => {
        self.unsupported(
          "\{type_value.value()} parameter \{param_value.name()} exceeds \{self.dialect_class_name()}'s maximum of \{bound}; capping",
        )
        params[i] = Node(mk1(DataTypeParam, literal_int(bound)))
      }
      _ => ()
    }
  }
  expression
}

///|
pub fn Generator::datatype_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut expression = expression
  let mut nested = ""
  let mut values = ""
  let expr_nested = expression.has("nested")
  let type_value = expression.datatype_this()
  if !expr_nested {
    match type_value {
      Some(tv) =>
        match self.fns.type_param_settings.get(tv) {
          Some((defaults, bounds)) =>
            expression = self.datatype_param_bound_limiter(
              expression, tv, defaults, bounds,
            )
          None => ()
        }
      None => ()
    }
  }
  let interior = if expr_nested && self.pretty {
    self.expressions(
      expression~,
      dynamic=true,
      new_line=true,
      skip_first=true,
      skip_last=true,
    )
  } else {
    self.expressions(expression~, flat=true)
  }
  match type_value {
    Some(tv) if self.cfg.unsupported_types.contains(tv) =>
      self.unsupported(
        "Data type \{tv.value()} is not supported when targeting \{self.dialect_class_name()}",
      )
    _ => ()
  }
  let mut type_sql = ""
  if type_value == Some(DType::USERDEFINED) && expression.has("kind") {
    type_sql = self.sql_key(expression, "kind")
  } else if type_value == Some(DType::CHARACTER_SET) {
    return "CHAR CHARACTER SET " + self.sql_key(expression, "kind")
  } else {
    type_sql = match type_value {
      Some(tv) =>
        match self.cfg.type_mapping.get(tv) {
          Some(m) => m
          None => tv.value()
        }
      None => py_str_value(expression.get("this"))
    }
  }
  if interior != "" {
    if expr_nested {
      nested = self.cfg.struct_delimiter[0] +
        interior +
        self.cfg.struct_delimiter[1]
      if expression.get("values") is Some(_) {
        let (d0, d1) = if type_value == Some(DType::ARRAY) {
          ("[", "]")
        } else {
          ("(", ")")
        }
        values = d0 +
          self.expressions(expression~, key="values", flat=true) +
          d1
      }
    } else if type_value == Some(DType::INTERVAL) {
      nested = " " + interior
    } else {
      nested = "(" + interior + ")"
    }
  }
  type_sql = type_sql + nested + values
  if self.cfg.tz_to_with_time_zone &&
    (
      type_value == Some(DType::TIMETZ) ||
      type_value == Some(DType::TIMESTAMPTZ)
    ) {
    type_sql = type_sql + " WITH TIME ZONE"
  }
  let collate = self.sql_key(expression, "collate")
  if collate != "" {
    type_sql = type_sql + " COLLATE " + collate
  }
  type_sql
}

///|
pub fn Generator::pseudotype_sql(self : Generator, expression : Expr) -> String {
  ignore(self)
  expression.name()
}

///|
pub fn Generator::objectidentifier_sql(
  self : Generator,
  expression : Expr,
) -> String {
  ignore(self)
  expression.name()
}

// ---------------------------------------------------------------------------
// Operators

///|
pub fn Generator::between_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let low = self.sql_key(expression, "low")
  let high = self.sql_key(expression, "high")
  let symmetric = expression.get("symmetric")
  let is_symmetric = match symmetric {
    Some(v) => v.truthy()
    None => false
  }
  if is_symmetric && !self.cfg.supports_between_flags {
    return "(\{this} BETWEEN \{low} AND \{high} OR \{this} BETWEEN \{high} AND \{low})"
  }
  let flag = if is_symmetric {
    " SYMMETRIC"
  } else if symmetric is Some(Bool(false)) && self.cfg.supports_between_flags {
    " ASYMMETRIC"
  } else {
    ""
  }
  "\{this} BETWEEN\{flag} \{low} AND \{high}"
}

///|
pub fn Generator::bracket_offset_expressions(
  self : Generator,
  expression : Expr,
  index_offset? : Int,
) -> Array[Expr] raise SqlglotError {
  if expression.has("json_access") {
    return expression.expressions()
  }
  let base = match index_offset {
    Some(i) if i != 0 => i
    _ => self.dialect.cfg.index_offset
  }
  let offset = match expression.get("offset") {
    Some(Int(i)) => i
    Some(Bool(b)) => if b { 1 } else { 0 }
    Some(Node(n)) =>
      match n.to_py_int() {
        Some(v) => v.to_int()
        None => 0
      }
    _ => 0
  }
  gen_apply_index_offset(
    expression.this_(),
    expression.expressions(),
    base - offset,
    self.dialect,
  )
}

///|
pub fn Generator::bracket_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let expressions = self.bracket_offset_expressions(expression)
  let parts = []
  for e in expressions {
    parts.push(self.sql(Some(e)))
  }
  self.sql_key(expression, "this") + "[" + parts.join(", ") + "]"
}

///|
pub fn Generator::all_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  match expression.this() {
    Some(t) if t.kind.is_any([Tuple, Paren]) => ()
    _ => this = self.wrap_str(this)
  }
  "ALL " + this
}

///|
pub fn Generator::any_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let mut this = self.sql_key(expression, "this")
  match expression.this() {
    Some(t) if t.kind.is_any([Select, SetOperation, Paren]) => {
      if t.kind.is_any([Select, SetOperation]) {
        this = self.wrap_str(this)
      }
      "ANY" + this
    }
    _ => "ANY " + this
  }
}

///|
pub fn Generator::exists_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "EXISTS" + self.wrap(expression)
}

///|
pub fn Generator::case_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let statements = [if this != "" { "CASE " + this } else { "CASE" }]
  for e in expression.list("ifs") {
    statements.push("WHEN " + self.sql_key(e, "this"))
    statements.push("THEN " + self.sql_key(e, "true"))
  }
  let default = self.sql_key(expression, "default")
  if default != "" {
    statements.push("ELSE " + default)
  }
  statements.push("END")
  if self.pretty && self.too_wide(statements) {
    return self.indent(statements.join("\n"), skip_first=true, skip_last=true)
  }
  statements.join(" ")
}

///|
pub fn Generator::if_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.call_method(
    Case,
    mk(Case, [("ifs", [expression]), ("default", expression.get("false"))]),
  )
}

///|
pub fn Generator::alias_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let alias_ = g_pfx(" AS ", self.sql_key(expression, "alias"))
  self.sql_key(expression, "this") + alias_
}

///|
pub fn Generator::pivotalias_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let alias_ = expression.arg("alias")
  let pivot = match expression.parent {
    Some(p) => p.parent
    None => None
  }
  match (pivot, alias_) {
    (Some(pv), Some(alias_)) if pv.kind.is_a(Pivot) && pv.has("unpivot") => {
      let identifier_alias = alias_.kind.is_a(Identifier)
      let literal_alias = alias_.kind.is_a(Literal)
      if identifier_alias && !self.cfg.unpivot_aliases_are_identifiers {
        alias_.replace(Some(literal_string(alias_.output_name()))) |> ignore
      } else if !identifier_alias &&
        literal_alias &&
        self.cfg.unpivot_aliases_are_identifiers {
        alias_.replace(Some(to_identifier(alias_.output_name()))) |> ignore
      }
    }
    _ => ()
  }
  self.call_method(Alias, expression)
}

///|
pub fn Generator::aliases_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " AS (" +
  self.expressions(expression~, flat=true) +
  ")"
}

///|
pub fn Generator::atindex_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " AT " +
  self.sql_key(expression, "expression")
}

///|
pub fn Generator::attimezone_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " AT TIME ZONE " +
  self.sql_key(expression, "zone")
}

///|
pub fn Generator::fromtimezone_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  " AT TIME ZONE " +
  self.sql_key(expression, "zone") +
  " AT TIME ZONE 'UTC'"
}

///|
pub fn Generator::paren_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let sql = self.seg(self.indent(self.sql_key(expression, "this")), sep="")
  "(" + sql + self.seg(")", sep="")
}

///|
pub fn Generator::neg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this_sql = self.sql_key(expression, "this")
  let sep = if this_sql.has_prefix("-") { " " } else { "" }
  "-" + sep + this_sql
}

///|
pub fn Generator::not_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "NOT " + self.sql_key(expression, "this")
}

///|
pub fn Generator::add_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "+")
}

///|
pub fn Generator::and_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.connector_sql(expression, "AND")
}

///|
pub fn Generator::or_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.connector_sql(expression, "OR")
}

///|
pub fn Generator::xor_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.connector_sql(expression, "XOR")
}

///|
pub fn Generator::bitwiseand_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "&")
}

///|
pub fn Generator::bitwiseleftshift_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<<")
}

///|
pub fn Generator::bitwisenot_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  "~" + self.sql_key(expression, "this")
}

///|
pub fn Generator::bitwiseor_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "|")
}

///|
pub fn Generator::bitwiserightshift_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, ">>")
}

///|
pub fn Generator::bitwisexor_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "^")
}

///|
/// Virtual `cast_sql(expression, safe_prefix)`.
pub fn Generator::cast_sql_v(
  self : Generator,
  expression : Expr,
  safe_prefix? : String,
) -> String raise SqlglotError {
  match self.fns.hooks.cast_sql {
    Some(f) => f(self, expression, safe_prefix)
    None =>
      match self.fns.methods.get(Cast) {
        Some(f) if safe_prefix is None => f(self, expression)
        _ => self.cast_sql(expression, safe_prefix?)
      }
  }
}

///|
pub fn Generator::cast_sql(
  self : Generator,
  expression : Expr,
  safe_prefix? : String,
) -> String raise SqlglotError {
  let format_sql = g_pfx(" FORMAT ", self.sql_key(expression, "format"))
  let to_sql = g_pfx(" ", self.sql_key(expression, "to"))
  let action = g_pfx(" ", self.sql_key(expression, "action"))
  let default = g_around(
    " DEFAULT ",
    self.sql_key(expression, "default"),
    " ON CONVERSION ERROR",
  )
  g_opt_str(safe_prefix) +
  "CAST(" +
  self.sql_key(expression, "this") +
  " AS" +
  to_sql +
  default +
  format_sql +
  action +
  ")"
}

///|
pub fn Generator::trycast_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.cast_sql_v(expression, safe_prefix="TRY_")
}

///|
pub fn Generator::jsoncast_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.cast_sql_v(expression)
}

///|
pub fn Generator::collate_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.cfg.collate_is_func {
    return self.function_fallback_sql(expression)
  }
  self.binary(expression, "COLLATE")
}

///|
pub fn Generator::intdiv_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql(
    Some(
      mk(Cast, [
        ("this", mk2(Div, expression.get("this"), expression.get("expression"))),
        ("to", datatype_of(DType::INT)),
      ]),
    ),
  )
}

///|
pub fn Generator::dpipe_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  if self.dialect.cfg.strict_string_concat && expression.has("safe") {
    let args : Array[&SqlArg] = []
    for e in expression.flatten() {
      args.push(exp_cast(e, DType::TEXT))
    }
    return self.func("CONCAT", args)
  }
  self.binary(expression, "||")
}

///|
pub fn Generator::div_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let l = expression.this_()
  let r = expression.expression_()
  if !self.dialect.cfg.safe_division && expression.has("safe") {
    r.replace(Some(mk2(Nullif, r.copy(), literal_int(0)))) |> ignore
  }
  if self.dialect.cfg.typed_division && !expression.has("typed") {
    if !l.is_type(dtype_real_types) && !r.is_type(dtype_real_types) {
      l.replace(Some(exp_cast(l.copy(), DType::DOUBLE))) |> ignore
    }
  } else if !self.dialect.cfg.typed_division && expression.has("typed") {
    if l.is_type(dtype_integer_types) && r.is_type(dtype_integer_types) {
      return self.sql(Some(exp_cast(exp_div(l, r), DType::BIGINT)))
    }
  }
  self.binary(expression, "/")
}

///|
pub fn Generator::safedivide_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let n = exp_wrap(expression.this_(), Binary)
  let d = exp_wrap(expression.expression_(), Binary)
  self.sql(
    Some(
      mk(If, [
        ("this", exp_neq(d, literal_int(0))),
        ("true", exp_div(n, d)),
        ("false", mk0(Null)),
      ]),
    ),
  )
}

///|
pub fn Generator::overlaps_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "OVERLAPS")
}

///|
pub fn Generator::distance_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<->")
}

///|
pub fn Generator::distancend_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<<->>")
}

///|
pub fn Generator::dot_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.sql_key(expression, "this") +
  "." +
  self.sql_key(expression, "expression")
}

///|
pub fn Generator::eq_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "=")
}

///|
pub fn Generator::propertyeq_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, ":=")
}

///|
pub fn Generator::escape_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  match expression.this() {
    Some(this) if this.kind.is_any([Like, ILike]) &&
      (match this.expression() {
        Some(x) => x.kind.is_any([All, Any])
        None => false
      }) &&
      !self.cfg.supports_like_quantifiers =>
      self.like_sql_inner(this, escape=expression)
    _ => self.binary(expression, "ESCAPE")
  }
}

///|
pub fn Generator::glob_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "GLOB")
}

///|
pub fn Generator::gt_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, ">")
}

///|
pub fn Generator::gte_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, ">=")
}

///|
pub fn Generator::is_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let negate = expression.has("negate")
  match expression.expression() {
    Some(b) if !self.cfg.is_bool_allowed && b.kind.is_a(Boolean) => {
      let positive = b.has("this") != negate
      let this = expression.this_()
      return self.sql(Some(if positive { this } else { exp_not(this) }))
    }
    _ => ()
  }
  self.binary(expression, if negate { "IS NOT" } else { "IS" })
}

///|
/// Python `_like_sql(expression, escape)`.
pub fn Generator::like_sql_inner(
  self : Generator,
  expression : Expr,
  escape? : Expr,
) -> String raise SqlglotError {
  let this = expression.get("this")
  let rhs = expression.expression()
  let (exp_class, op0) = if expression.kind.is_a(Like) {
    (Kind::Like, "LIKE")
  } else {
    (Kind::ILike, "ILIKE")
  }
  let mut op = op0
  if expression.has("negate") {
    op = "NOT " + op
  }
  match rhs {
    Some(rhs) if rhs.kind.is_any([All, Any]) &&
      !self.cfg.supports_like_quantifiers => {
      let inner = rhs.this_().unnest()
      let exprs = if inner.kind.is_a(Tuple) {
        inner.expressions()
      } else {
        [inner]
      }
      let negate = expression.get("negate")
      let make_like = fn(expr : Expr) -> Expr {
        let like = mk(exp_class, [
          ("this", this),
          ("expression", expr),
          ("negate", negate),
        ])
        match escape {
          Some(esc) =>
            mk(Escape, [
              ("this", like),
              ("expression", esc.expression_().copy()),
            ])
          None => like
        }
      }
      let mut like_expr = make_like(exprs[0])
      for i in 1..<exprs.length() {
        let next = make_like(exprs[i])
        like_expr = if rhs.kind.is_a(Any) {
          exp_or([like_expr, next], copy=false)
        } else {
          exp_and([like_expr, next], copy=false)
        }
      }
      let parent = match escape {
        Some(esc) => esc.parent
        None => expression.parent
      }
      match parent {
        Some(p) if !(p.kind.is_a(like_expr.kind) || p.kind.is_a(Paren)) &&
          p.kind.is_a(Condition) => like_expr = exp_paren(like_expr, copy=false)
        _ => ()
      }
      return self.sql(Some(like_expr))
    }
    _ => ()
  }
  self.binary(expression, op)
}

///|
pub fn Generator::like_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.like_sql_inner(expression)
}

///|
pub fn Generator::ilike_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.like_sql_inner(expression)
}

///|
pub fn Generator::match_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "MATCH")
}

///|
pub fn Generator::similarto_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "SIMILAR TO")
}

///|
pub fn Generator::lt_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<")
}

///|
pub fn Generator::lte_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<=")
}

///|
pub fn Generator::mod_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let this = self.sql_key(expression, "this")
  let expr = self.sql_key(expression, "expression")
  let sql = this +
    " " +
    self.maybe_comment(self.cfg.mod_operator, comments?=expression.comments) +
    " " +
    expr
  match expression.parent {
    Some(p) if p.kind.is_any(self.cfg.mod_paren_parent_types) &&
      (match p.expression() {
        Some(pe) => physical_equal(pe, expression)
        None => false
      }) => "(" + sql + ")"
    _ => sql
  }
}

///|
pub fn Generator::mul_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "*")
}

///|
pub fn Generator::neq_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "<>")
}

///|
pub fn Generator::nullsafeeq_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "IS NOT DISTINCT FROM")
}

///|
pub fn Generator::nullsafeneq_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "IS DISTINCT FROM")
}

///|
pub fn Generator::sub_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "-")
}

///|
pub fn Generator::kwarg_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  self.binary(expression, "=>")
}

///|
pub fn Generator::in_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let is_global = g_when(expression.has("is_global"), " GLOBAL")
  let in_sql = match
    (expression.arg("query"), expression.arg("unnest"), expression.arg("field")) {
    (Some(query), _, _) => self.sql(Some(query))
    (None, Some(unnest), _) => self.in_unnest_op(unnest)
    (None, None, Some(field)) => self.sql(Some(field))
    _ =>
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
  self.sql_key(expression, "this") + is_global + " IN " + in_sql
}

///|
/// Virtual `in_unnest_op`.
pub fn Generator::in_unnest_op(
  self : Generator,
  unnest : Expr,
) -> String raise SqlglotError {
  match self.fns.hooks.in_unnest_op {
    Some(f) => f(self, unnest)
    None => self.in_unnest_op_base(unnest)
  }
}

///|
pub fn Generator::in_unnest_op_base(
  self : Generator,
  unnest : Expr,
) -> String raise SqlglotError {
  "(SELECT " + self.sql(Some(unnest)) + ")"
}

///|
pub fn Generator::interval_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let include_keyword = !self.cfg.auto_refresh_bare_intervals ||
    !(match expression.find_ancestor([AutoRefreshProperty, Select]) {
      Some(a) => a.kind.is_a(AutoRefreshProperty)
      None => false
    })
  let mut interval_keyword = if include_keyword { "INTERVAL" } else { "" }
  let unit_expression = expression.arg("unit")
  let mut unit = match unit_expression {
    Some(u) => self.sql(Some(u))
    None => ""
  }
  if !self.cfg.interval_allows_plural_form {
    unit = match self.cfg.time_part_singulars.get(unit) {
      Some(s) => s
      None => unit
    }
  }
  let unit = g_pfx(" ", unit)
  if self.cfg.single_string_interval {
    let this = match expression.this() {
      Some(t) => t.name()
      None => ""
    }
    if this != "" {
      interval_keyword = g_pfx("", interval_keyword)
      if interval_keyword != "" {
        interval_keyword = interval_keyword + " "
      }
      match unit_expression {
        Some(u) if u.kind.is_a(IntervalSpan) =>
          return interval_keyword + "'" + this + "'" + unit
        _ => ()
      }
      return interval_keyword + "'" + this + unit + "'"
    }
    return interval_keyword + unit
  }
  let mut this = self.sql_key(expression, "this")
  if this != "" {
    let this_expr = expression.this()
    if !include_keyword &&
      (match this_expr {
        Some(t) => t.is_string()
        None => false
      }) {
      this = this_expr.unwrap().name()
    }
    let unwrapped = match this_expr {
      Some(t) => t.kind.is_any(self.cfg.unwrapped_interval_values)
      None => false
    }
    if !unwrapped {
      this = "(" + this + ")"
    }
    if include_keyword {
      this = " " + this
    }
  }
  interval_keyword + this + unit
}

///|
pub fn Generator::slice_sql(
  self : Generator,
  expression : Expr,
) -> String raise SqlglotError {
  let step = self.sql_key(expression, "step")
  let end = self.sql(expression.expression())
  let begin = self.sql(expression.this())
  let sql = if step != "" { end + ":" + step } else { end }
  if sql != "" {
    begin + ":" + sql
  } else {
    begin + ":"
  }
}

///|
pub fn Generator::lambda_sql_v(
  self : Generator,
  expression : Expr,
  arrow_sep? : String = "->",
  wrap? : Bool = true,
) -> String raise SqlglotError {
  match self.fns.hooks.lambda_sql {
    Some(f) => f(self, expression, arrow_sep, wrap)
    None => self.lambda_sql(expression, arrow_sep~, wrap~)
  }
}

///|
pub fn Generator::lambda_sql(
  self : Generator,
  expression : Expr,
  arrow_sep? : String = "->",
  wrap? : Bool = true,
) -> String raise SqlglotError {
  let mut args = self.expressions(expression~, flat=true)
  if wrap && py_split(args, ",").length() > 1 {
    args = "(" + args + ")"
  }
  args + " " + arrow_sep + " " + self.sql_key(expression, "this")
}
