// Deserializer for the canonical AST dump format of tools/gen_fixtures.py
// (`Kind(key=value,...)`), used to build generator inputs without the parser.

///|
priv struct CanonParser {
  s : Array[Char]
  mut pos : Int
}

///|
fn CanonParser::peek(self : CanonParser) -> Char {
  if self.pos < self.s.length() {
    self.s[self.pos]
  } else {
    '\u{0}'
  }
}

///|
fn CanonParser::expect(self : CanonParser, c : Char) -> Unit {
  if self.peek() != c {
    abort(
      "canonical parse error at \{self.pos}: expected \{c}, got \{self.peek()}",
    )
  }
  self.pos += 1
}

///|
fn CanonParser::ident(self : CanonParser) -> String {
  let sb = StringBuilder()
  while self.pos < self.s.length() {
    let c = self.s[self.pos]
    if c.is_ascii_alphabetic() || (c >= '0' && c <= '9') || c == '_' {
      sb.write_char(c)
      self.pos += 1
    } else {
      break
    }
  }
  sb.to_string()
}

///|
fn hex_val(c : Char) -> Int {
  match c {
    '0'..='9' => c.to_int() - '0'.to_int()
    'a'..='f' => c.to_int() - 'a'.to_int() + 10
    'A'..='F' => c.to_int() - 'A'.to_int() + 10
    _ => 0
  }
}

///|
fn CanonParser::json_string(self : CanonParser) -> String {
  self.expect('"')
  let sb = StringBuilder()
  while self.peek() != '"' {
    let c = self.s[self.pos]
    self.pos += 1
    if c == '\\' {
      let e = self.s[self.pos]
      self.pos += 1
      match e {
        'n' => sb.write_char('\n')
        't' => sb.write_char('\t')
        'r' => sb.write_char('\r')
        'b' => sb.write_char('\u{8}')
        'f' => sb.write_char('\u{c}')
        'u' => {
          let mut code = 0
          for _ in 0..<4 {
            code = code * 16 + hex_val(self.s[self.pos])
            self.pos += 1
          }
          // surrogate pair
          if code >= 0xD800 && code < 0xDC00 && self.peek() == '\\' {
            self.pos += 2
            let mut low = 0
            for _ in 0..<4 {
              low = low * 16 + hex_val(self.s[self.pos])
              self.pos += 1
            }
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          }
          sb.write_char(Int::unsafe_to_char(code))
        }
        other => sb.write_char(other)
      }
    } else {
      sb.write_char(c)
    }
  }
  self.expect('"')
  sb.to_string()
}

///|
fn CanonParser::value(self : CanonParser) -> @core.Value {
  let c = self.peek()
  if c == '"' {
    return Str(self.json_string())
  }
  if c == '[' {
    self.pos += 1
    let items = []
    while self.peek() != ']' {
      items.push(self.value())
      if self.peek() == ',' {
        self.pos += 1
      }
    }
    self.pos += 1
    return List(items)
  }
  if c == '-' || (c >= '0' && c <= '9') {
    let mut neg = false
    if c == '-' {
      neg = true
      self.pos += 1
    }
    let mut n = 0L
    while self.peek() >= '0' && self.peek() <= '9' {
      n = n * 10 + (self.peek().to_int() - '0'.to_int()).to_int64()
      self.pos += 1
    }
    return Int(if neg { -n } else { n })
  }
  let start = self.pos
  let name = self.ident()
  if name == "true" {
    return Bool(true)
  }
  if name == "false" {
    return Bool(false)
  }
  if name == "DType" && self.peek() == '.' {
    self.pos += 1
    let dt = self.ident()
    match @core.dtype_from_name(dt) {
      Some(d) => return DT(d)
      None => abort("unknown DType \{dt}")
    }
  }
  self.pos = start
  Node(self.node())
}

///|
fn CanonParser::node(self : CanonParser) -> @core.Expr {
  let name = self.ident()
  self.expect('(')
  let args : Map[String, @core.Value] = Map([])
  let mut comments : Array[String]? = None
  let mut type_ : @core.Expr? = None
  while self.peek() != ')' {
    if self.peek() == '#' {
      self.pos += 1
      let key = self.ident()
      self.expect('=')
      if key == "t" {
        type_ = Some(self.node())
        if self.peek() == ',' {
          self.pos += 1
        }
        continue
      }
      guard key == "c" else { abort("unknown meta key \{key}") }
      self.expect('[')
      let cs = []
      while self.peek() != ']' {
        cs.push(self.json_string())
        if self.peek() == ',' {
          self.pos += 1
        }
        while self.peek() == ' ' {
          self.pos += 1
        }
      }
      self.pos += 1
      comments = Some(cs)
    } else {
      let key = self.ident()
      self.expect('=')
      args[key] = self.value()
    }
    if self.peek() == ',' {
      self.pos += 1
    }
  }
  self.expect(')')
  let kind = match @core.kind_from_name(name) {
    Some(k) => k
    None => abort("unknown kind \{name}")
  }
  if kind == @core.DateTrunc {
    // the stored unit is already normalized (e.g. Oracle keeps abbreviations)
    args["unabbreviate"] = Bool(false)
  }
  let e = @core.Expr::new(kind, args)
  match comments {
    Some(cs) => e.add_comments(Some(cs))
    None => ()
  }
  match type_ {
    Some(t) => e.set_type(Some(t))
    None => ()
  }
  e
}

///|
fn parse_canonical(s : String) -> @core.Expr {
  let p : CanonParser = { s: s.to_array(), pos: 0, }
  p.node()
}
