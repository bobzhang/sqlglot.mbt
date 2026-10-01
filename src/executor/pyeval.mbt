// A small Python expression compiler and evaluator. The Python executor generates
// Python source code for SQL expressions and runs it with `eval`; this file implements
// the subset of Python expressions that the generator emits.

///|
/// A compiled Python expression (the result of `compile(source, ..., "eval")`).
pub enum Code {
  Const(Value)
  Name(String)
  Attr(Code, String)
  Subscript(Code, Code)
  Call(Code, Array[Code])
  Lambda(Array[String], Code)
  IfExp(Code, Code, Code)
  BoolOp(Bool, Array[Code]) // true: `and`, false: `or`
  Not(Code)
  Unary(String, Code)
  Binary(String, Code, Code)
  Compare(Code, Array[(String, Code)])
  ListDisplay(Array[Code])
  TupleDisplay(Array[Code])
  DictDisplay(Array[(Code, Code)])
}

///|
priv enum Tok {
  TName(String)
  TNum(Value)
  TStr(String)
  TOp(String)
  TEnd
} derive(Eq)

///|
fn syntax_error(msg : String) -> PyException {
  PyException("SyntaxError", msg)
}

///|
fn is_name_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c.to_int() >= 128
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
let three_char_ops : Array[String] = ["**=", "//=", ">>=", "<<=", "..."]

///|
let two_char_ops : Array[String] = [
  "==", "!=", "<=", ">=", "//", "**", "<<", ">>", "->", ":=", "+=", "-=", "*=", "/=",
  "%=", "&=", "|=", "^=", "@=",
]

///|
fn tokenize(src : String) -> Array[Tok] raise PyException {
  let chars = src.to_array()
  let n = chars.length()
  let toks = []
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0c}' {
      i += 1
      continue
    }
    if c == '\\' && i + 1 < n && chars[i + 1] == '\n' {
      i += 2
      continue
    }
    if c == '#' {
      while i < n && chars[i] != '\n' {
        i += 1
      }
      continue
    }
    // string literal, possibly prefixed
    let mut j = i
    let mut raw = false
    while j < n && j - i < 2 && "rRbBuUfF".contains_char(chars[j]) {
      if chars[j] == 'r' || chars[j] == 'R' {
        raw = true
      }
      j += 1
    }
    if j < n && (chars[j] == '\'' || chars[j] == '"') {
      let prefix = String::from_array(chars[i:j].to_owned())
      if @core.py_lower(prefix).contains("b") ||
        @core.py_lower(prefix).contains("f") {
        raise syntax_error("unsupported string prefix \{prefix}")
      }
      let (s, next) = read_string(chars, j, raw)
      toks.push(TStr(s))
      i = next
      continue
    }
    if is_name_start(c) {
      let mut j = i + 1
      while j < n && (is_name_start(chars[j]) || is_digit(chars[j])) {
        j += 1
      }
      toks.push(TName(String::from_array(chars[i:j].to_owned())))
      i = j
      continue
    }
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(chars[i + 1])) {
      let (v, next) = read_number(chars, i)
      toks.push(TNum(v))
      i = next
      continue
    }
    let rest3 = if i + 3 <= n {
      String::from_array(chars[i:i + 3].to_owned())
    } else {
      ""
    }
    let rest2 = if i + 2 <= n {
      String::from_array(chars[i:i + 2].to_owned())
    } else {
      ""
    }
    if three_char_ops.contains(rest3) {
      toks.push(TOp(rest3))
      i += 3
    } else if two_char_ops.contains(rest2) {
      toks.push(TOp(rest2))
      i += 2
    } else if "()[]{},:.+-*/%&|^~<>=@;".contains_char(c) {
      toks.push(TOp(c.to_string()))
      i += 1
    } else {
      raise syntax_error("invalid character '\{c}'")
    }
  }
  toks.push(TEnd)
  toks
}

///|
fn hex_val(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn read_string(
  chars : Array[Char],
  start : Int,
  raw : Bool,
) -> (String, Int) raise PyException {
  let n = chars.length()
  let q = chars[start]
  let triple = start + 2 < n && chars[start + 1] == q && chars[start + 2] == q
  let mut i = if triple { start + 3 } else { start + 1 }
  let sb = StringBuilder()
  for ;; {
    if i >= n {
      raise syntax_error("unterminated string literal")
    }
    let c = chars[i]
    if c == q {
      if !triple {
        return (sb.to_string(), i + 1)
      }
      if i + 2 < n && chars[i + 1] == q && chars[i + 2] == q {
        return (sb.to_string(), i + 3)
      }
      sb.write_char(c)
      i += 1
      continue
    }
    if c == '\n' && !triple {
      raise syntax_error("unterminated string literal")
    }
    if c != '\\' {
      sb.write_char(c)
      i += 1
      continue
    }
    if i + 1 >= n {
      raise syntax_error("unterminated string literal")
    }
    let e = chars[i + 1]
    if raw {
      sb.write_char('\\')
      sb.write_char(e)
      i += 2
      continue
    }
    i += 2
    match e {
      '\n' => ()
      '\\' => sb.write_char('\\')
      '\'' => sb.write_char('\'')
      '"' => sb.write_char('"')
      'a' => sb.write_char('\u{07}')
      'b' => sb.write_char('\u{08}')
      'f' => sb.write_char('\u{0c}')
      'n' => sb.write_char('\n')
      'r' => sb.write_char('\r')
      't' => sb.write_char('\t')
      'v' => sb.write_char('\u{0b}')
      'x' | 'u' | 'U' => {
        let len = match e {
          'x' => 2
          'u' => 4
          _ => 8
        }
        let mut v = 0
        for k in 0..<len {
          match chars.get(i + k).bind(hex_val) {
            Some(h) => v = v * 16 + h
            None => raise syntax_error("truncated \\\{e} escape")
          }
        }
        i += len
        sb.write_char(Int::unsafe_to_char(v))
      }
      '0'..='7' => {
        let mut v = e.to_int() - '0'.to_int()
        let mut k = 0
        while k < 2 && i < n && chars[i] >= '0' && chars[i] <= '7' {
          v = v * 8 + (chars[i].to_int() - '0'.to_int())
          i += 1
          k += 1
        }
        sb.write_char(Int::unsafe_to_char(v))
      }
      _ => {
        // unknown escapes are kept verbatim
        sb.write_char('\\')
        sb.write_char(e)
      }
    }
  }
}

///|
fn read_number(
  chars : Array[Char],
  start : Int,
) -> (Value, Int) raise PyException {
  let n = chars.length()
  let mut i = start
  if chars[i] == '0' && i + 1 < n && "xXoObB".contains_char(chars[i + 1]) {
    let base = match chars[i + 1] {
      'x' | 'X' => 16
      'o' | 'O' => 8
      _ => 2
    }
    i += 2
    let mut v = 0L
    let mut any = false
    while i < n {
      let c = chars[i]
      if c == '_' {
        i += 1
        continue
      }
      match hex_val(c) {
        Some(h) if h < base => {
          v = checked_add(checked_mul(v, base.to_int64()), h.to_int64()) catch {
            _ => raise int64_overflow("an integer literal")
          }
          any = true
          i += 1
        }
        _ => break
      }
    }
    if !any {
      raise syntax_error("invalid number literal")
    }
    return (Int(v), i)
  }
  let sb = StringBuilder()
  let mut is_float = false
  let mut int_digits = 0
  let mut leading_zero_nonzero = false
  while i < n && (is_digit(chars[i]) || chars[i] == '_') {
    if chars[i] != '_' {
      if int_digits == 0 && chars[i] == '0' {
        leading_zero_nonzero = true
      } else if leading_zero_nonzero && chars[i] != '0' {
        leading_zero_nonzero = true
      }
      sb.write_char(chars[i])
      int_digits += 1
    }
    i += 1
  }
  let int_text = sb.to_string()
  if i < n && chars[i] == '.' {
    is_float = true
    sb.write_char('.')
    i += 1
    while i < n && (is_digit(chars[i]) || chars[i] == '_') {
      if chars[i] != '_' {
        sb.write_char(chars[i])
      }
      i += 1
    }
  }
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    let save = i
    let mut j = i + 1
    if j < n && (chars[j] == '+' || chars[j] == '-') {
      j += 1
    }
    if j < n && is_digit(chars[j]) {
      is_float = true
      sb.write_char('e')
      for k in (i + 1)..<j {
        sb.write_char(chars[k])
      }
      i = j
      while i < n && is_digit(chars[i]) {
        sb.write_char(chars[i])
        i += 1
      }
    } else {
      i = save
    }
  }
  if i < n && (chars[i] == 'j' || chars[i] == 'J') {
    raise syntax_error("complex literals are not supported")
  }
  if i < n && is_name_start(chars[i]) {
    raise syntax_error("invalid decimal literal")
  }
  let text = sb.to_string()
  if is_float {
    let d = @string.parse_double(
      if text.has_prefix(".") {
        "0" + text
      } else {
        text
      },
    ) catch {
      _ => raise syntax_error("invalid float literal")
    }
    return (Float(d), i)
  }
  // ints: leading zeros are only allowed for zero itself
  if int_text.length() > 1 &&
    int_text.has_prefix("0") &&
    int_text.iter().any(c => c != '0') {
    raise syntax_error(
      "leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers",
    )
  }
  match @core.parse_int_str(int_text) {
    Some(v) => (Int(v), i)
    None if @core.is_int_str(int_text) =>
      raise int64_overflow("the literal \{int_text}")
    None => raise syntax_error("invalid integer literal")
  }
}

///|
priv struct PyParser {
  toks : Array[Tok]
  mut pos : Int
}

///|
fn PyParser::peek(self : PyParser) -> Tok {
  self.toks[self.pos]
}

///|
fn PyParser::peek_at(self : PyParser, k : Int) -> Tok {
  if self.pos + k < self.toks.length() {
    self.toks[self.pos + k]
  } else {
    TEnd
  }
}

///|
fn PyParser::advance(self : PyParser) -> Tok {
  let t = self.toks[self.pos]
  if self.pos < self.toks.length() - 1 {
    self.pos += 1
  }
  t
}

///|
fn PyParser::is_op(self : PyParser, op : String) -> Bool {
  self.peek() == TOp(op)
}

///|
fn PyParser::is_kw(self : PyParser, kw : String) -> Bool {
  self.peek() == TName(kw)
}

///|
fn PyParser::expect_op(self : PyParser, op : String) -> Unit raise PyException {
  if !self.is_op(op) {
    raise syntax_error("expected '\{op}'")
  }
  self.advance() |> ignore
}

///|
let keywords : Array[String] = [
  "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
  "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
  "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
  "return", "try", "while", "with", "yield",
]

///|
/// `test: or_test ['if' or_test 'else' test] | lambdef`
fn PyParser::parse_test(self : PyParser) -> Code raise PyException {
  if self.is_kw("lambda") {
    self.advance() |> ignore
    let params = []
    while !self.is_op(":") {
      match self.advance() {
        TName(n) if !keywords.contains(n) => params.push(n)
        _ => raise syntax_error("invalid syntax")
      }
      if self.is_op(",") {
        self.advance() |> ignore
      } else if !self.is_op(":") {
        raise syntax_error("invalid syntax")
      }
    }
    self.expect_op(":")
    let body = self.parse_test()
    return Lambda(params, body)
  }
  let body = self.or_test()
  if self.is_kw("if") {
    self.advance() |> ignore
    let cond = self.or_test()
    if !self.is_kw("else") {
      raise syntax_error("expected 'else' after 'if' expression")
    }
    self.advance() |> ignore
    let else_branch = self.parse_test()
    return IfExp(cond, body, else_branch)
  }
  body
}

///|
fn PyParser::or_test(self : PyParser) -> Code raise PyException {
  let first = self.and_test()
  if !self.is_kw("or") {
    return first
  }
  let items = [first]
  while self.is_kw("or") {
    self.advance() |> ignore
    items.push(self.and_test())
  }
  BoolOp(false, items)
}

///|
fn PyParser::and_test(self : PyParser) -> Code raise PyException {
  let first = self.not_test()
  if !self.is_kw("and") {
    return first
  }
  let items = [first]
  while self.is_kw("and") {
    self.advance() |> ignore
    items.push(self.not_test())
  }
  BoolOp(true, items)
}

///|
fn PyParser::not_test(self : PyParser) -> Code raise PyException {
  if self.is_kw("not") {
    self.advance() |> ignore
    return Not(self.not_test())
  }
  self.comparison()
}

///|
fn PyParser::comp_op(self : PyParser) -> String? {
  match self.peek() {
    TOp("<" | ">" | "==" | ">=" | "<=" | "!=" as op) => {
      self.advance() |> ignore
      Some(op)
    }
    TName("in") => {
      self.advance() |> ignore
      Some("in")
    }
    TName("not") if self.peek_at(1) == TName("in") => {
      self.advance() |> ignore
      self.advance() |> ignore
      Some("not in")
    }
    TName("is") => {
      self.advance() |> ignore
      if self.is_kw("not") {
        self.advance() |> ignore
        Some("is not")
      } else {
        Some("is")
      }
    }
    _ => None
  }
}

///|
fn PyParser::comparison(self : PyParser) -> Code raise PyException {
  let left = self.binop(0)
  let ops = []
  while self.comp_op() is Some(op) {
    ops.push((op, self.binop(0)))
  }
  if ops.is_empty() {
    left
  } else {
    Compare(left, ops)
  }
}

///|
let binop_levels : Array[Array[String]] = [
  ["|"],
  ["^"],
  ["&"],
  ["<<", ">>"],
  ["+", "-"],
  ["*", "/", "//", "%", "@"],
]

///|
fn PyParser::binop(self : PyParser, level : Int) -> Code raise PyException {
  if level >= binop_levels.length() {
    return self.factor()
  }
  let mut left = self.binop(level + 1)
  for ;; {
    match self.peek() {
      TOp(op) if binop_levels[level].contains(op) => {
        self.advance() |> ignore
        let right = self.binop(level + 1)
        left = Binary(op, left, right)
      }
      _ => break
    }
  }
  left
}

///|
fn PyParser::factor(self : PyParser) -> Code raise PyException {
  match self.peek() {
    TOp("+" | "-" | "~" as op) => {
      self.advance() |> ignore
      Unary(op, self.factor())
    }
    _ => self.power()
  }
}

///|
fn PyParser::power(self : PyParser) -> Code raise PyException {
  let base = self.primary()
  if self.is_op("**") {
    self.advance() |> ignore
    let exp = self.factor()
    return Binary("**", base, exp)
  }
  base
}

///|
fn PyParser::primary(self : PyParser) -> Code raise PyException {
  let mut node = self.atom()
  for ;; {
    if self.is_op("(") {
      self.advance() |> ignore
      let args = []
      while !self.is_op(")") {
        if self.is_op("*") || self.is_op("**") {
          raise syntax_error("starred arguments are not supported")
        }
        if self.peek() is TName(_) && self.peek_at(1) == TOp("=") {
          raise syntax_error("keyword arguments are not supported")
        }
        args.push(self.parse_test())
        if self.is_op(",") {
          self.advance() |> ignore
        } else if !self.is_op(")") {
          raise syntax_error("invalid syntax. Perhaps you forgot a comma?")
        }
      }
      self.advance() |> ignore
      node = Call(node, args)
    } else if self.is_op("[") {
      self.advance() |> ignore
      let index = self.subscript()
      self.expect_op("]")
      node = Subscript(node, index)
    } else if self.is_op(".") {
      self.advance() |> ignore
      match self.advance() {
        TName(n) => node = Attr(node, n)
        _ => raise syntax_error("invalid syntax")
      }
    } else {
      break
    }
  }
  node
}

///|
fn PyParser::subscript(self : PyParser) -> Code raise PyException {
  if self.is_op(":") {
    raise syntax_error("slices are not supported")
  }
  let first = self.parse_test()
  if self.is_op(":") {
    raise syntax_error("slices are not supported")
  }
  if self.is_op(",") {
    let items = [first]
    while self.is_op(",") {
      self.advance() |> ignore
      if self.is_op("]") {
        break
      }
      items.push(self.parse_test())
    }
    return TupleDisplay(items)
  }
  first
}

///|
fn PyParser::atom(self : PyParser) -> Code raise PyException {
  match self.advance() {
    TNum(v) => Const(v)
    TStr(s) => {
      let mut s = s
      // adjacent string literals are concatenated
      while self.peek() is TStr(t) {
        self.advance() |> ignore
        s = s + t
      }
      Const(Str(s))
    }
    TName("None") => Const(Null)
    TName("True") => Const(Bool(true))
    TName("False") => Const(Bool(false))
    TName(n) if keywords.contains(n) => raise syntax_error("invalid syntax")
    TName(n) => Name(n)
    TOp("(") => {
      if self.is_op(")") {
        self.advance() |> ignore
        return TupleDisplay([])
      }
      let first = self.parse_test()
      if self.is_op(")") {
        self.advance() |> ignore
        return first
      }
      let items = [first]
      while self.is_op(",") {
        self.advance() |> ignore
        if self.is_op(")") {
          break
        }
        items.push(self.parse_test())
      }
      self.expect_op(")")
      TupleDisplay(items)
    }
    TOp("[") => {
      let items = []
      while !self.is_op("]") {
        items.push(self.parse_test())
        if self.is_op(",") {
          self.advance() |> ignore
        } else if !self.is_op("]") {
          raise syntax_error("invalid syntax. Perhaps you forgot a comma?")
        }
      }
      self.advance() |> ignore
      ListDisplay(items)
    }
    TOp("{") => {
      let items = []
      while !self.is_op("}") {
        let k = self.parse_test()
        self.expect_op(":")
        let v = self.parse_test()
        items.push((k, v))
        if self.is_op(",") {
          self.advance() |> ignore
        } else if !self.is_op("}") {
          raise syntax_error("invalid syntax")
        }
      }
      self.advance() |> ignore
      DictDisplay(items)
    }
    _ => raise syntax_error("invalid syntax")
  }
}

///|
/// Python `compile(source, source, "eval")`: parses a Python expression.
pub fn compile_python(source : String) -> Code raise PyException {
  let p = { toks: tokenize(source), pos: 0, }
  let first = p.parse_test()
  let code = if p.is_op(",") {
    let items = [first]
    while p.is_op(",") {
      p.advance() |> ignore
      if p.peek() == TEnd {
        break
      }
      items.push(p.parse_test())
    }
    TupleDisplay(items)
  } else {
    first
  }
  if p.peek() != TEnd {
    raise syntax_error("invalid syntax")
  }
  code
}

///|
/// The environment of an evaluation: lambda locals chained to the globals.
priv struct Frame {
  locals : Map[String, Value]
  parent : Frame?
}

///|
/// Python `eval(code, globals)`; `scope` is the value of the `scope` global and
/// `globals` the other globals (falling back to the builtins).
pub fn eval_code(
  code : Code,
  globals : Map[String, Value],
  scope : Value,
) -> Value raise {
  eval_in(code, globals, scope, None)
}

///|
fn lookup_name(
  name : String,
  globals : Map[String, Value],
  scope : Value,
  frame : Frame?,
) -> Value raise PyException {
  let mut f = frame
  while f is Some(fr) {
    match fr.locals.get(name) {
      Some(v) => return v
      None => f = fr.parent
    }
  }
  if name == "scope" {
    return scope
  }
  match globals.get(name) {
    Some(v) => v
    None =>
      match builtins.get(name) {
        Some(v) => v
        None => raise PyException("NameError", "name '\{name}' is not defined")
      }
  }
}

///|
fn eval_in(
  code : Code,
  globals : Map[String, Value],
  scope : Value,
  frame : Frame?,
) -> Value raise {
  fn ev(c : Code) -> Value raise {
    eval_in(c, globals, scope, frame)
  }

  match code {
    Const(v) => v
    Name(n) => lookup_name(n, globals, scope, frame)
    Attr(obj, name) => getattr(ev(obj), name)
    Subscript(obj, index) => py_getitem(ev(obj), ev(index))
    Call(f, args) => {
      let fv = ev(f)
      let argv = args.map(a => ev(a))
      call_value(fv, argv)
    }
    Lambda(params, body) =>
      Func({
        name: "<lambda>",
        call: args => {
          if args.length() != params.length() {
            raise type_error(
              "<lambda>() takes \{params.length()} positional arguments but \{args.length()} were given",
            )
          }
          let locals : Map[String, Value] = Map([])
          for i, p in params {
            locals[p] = args[i]
          }
          eval_in(body, globals, scope, Some({ locals, parent: frame, }))
        },
      })
    IfExp(cond, body, else_branch) =>
      if ev(cond).truthy() {
        ev(body)
      } else {
        ev(else_branch)
      }
    BoolOp(is_and, items) => {
      let mut v = Null
      for i, item in items {
        v = ev(item)
        if i < items.length() - 1 && v.truthy() != is_and {
          return v
        }
      }
      v
    }
    Not(x) => Bool(!ev(x).truthy())
    Unary(op, x) => {
      let v = ev(x)
      match op {
        "-" => py_neg(v)
        "+" => py_pos(v)
        _ => py_invert(v)
      }
    }
    Binary(op, a, b) => {
      let x = ev(a)
      let y = ev(b)
      match op {
        "+" => py_add(x, y)
        "-" => py_sub(x, y)
        "*" => py_mul(x, y)
        "/" => py_truediv(x, y)
        "//" => py_floordiv(x, y)
        "%" => py_mod(x, y)
        "**" => py_pow(x, y)
        "&" | "|" | "^" | "<<" | ">>" => py_bitop(op, x, y)
        _ => raise unsupported(op, x, y)
      }
    }
    Compare(first, ops) => {
      let mut left = ev(first)
      let mut result = Bool(true)
      for pair in ops {
        let (op, rc) = pair
        let right = ev(rc)
        let ok = match op {
          "==" => py_eq(left, right)
          "!=" => !py_eq(left, right)
          "<" => py_lt(left, right)
          ">" => py_gt(left, right)
          "<=" => py_le(left, right)
          ">=" => py_ge(left, right)
          "is" => py_is(left, right)
          "is not" => !py_is(left, right)
          "in" => py_contains(right, left)
          _ => !py_contains(right, left)
        }
        result = Bool(ok)
        if !ok {
          return result
        }
        left = right
      }
      result
    }
    ListDisplay(items) => List(items.map(i => ev(i)))
    TupleDisplay(items) => Tuple(items.map(i => ev(i)))
    DictDisplay(items) => {
      let out : Array[(Value, Value)] = []
      for kv in items {
        dict_set(out, ev(kv.0), ev(kv.1))
      }
      Dict(out)
    }
  }
}

///|
/// Python `a is b` for the singletons and immutable values the generated code compares.
fn py_is(a : Value, b : Value) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (Bool(x), Bool(y)) => x == y
    (Int(x), Int(y)) => x == y && x >= -5L && x <= 256L
    (Str(x), Str(y)) => physical_equal(x, y)
    (List(x), List(y)) | (Tuple(x), Tuple(y)) => physical_equal(x, y)
    (DTypeV(x), DTypeV(y)) => x == y
    (Module(x), Module(y)) => x == y
    (Func(x), Func(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Python `item in container`.
fn py_contains(container : Value, item : Value) -> Bool raise PyException {
  match container {
    Str(s) =>
      match item {
        Str(t) => s.contains(t)
        _ =>
          raise type_error(
            "'in <string>' requires string as left operand, not \{item.type_name()}",
          )
      }
    _ => py_iter(container).iter().any(v => py_eq(v, item))
  }
}
