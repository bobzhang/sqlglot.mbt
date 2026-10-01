// Canonical AST dumps used to compare against the Python implementation.

///|
/// Python `json.dumps(s, ensure_ascii=False)`.
pub fn json_quote(s : String) -> String {
  let sb = StringBuilder()
  sb.write_char('"')
  for c in s {
    match c {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      '\u{08}' => sb.write_string("\\b")
      '\u{0c}' => sb.write_string("\\f")
      _ =>
        if c.to_int() < 0x20 {
          let h = c.to_int()
          let hex = "0123456789abcdef"
          sb.write_string("\\u00")
          sb.write_char(hex.get_char(h / 16).unwrap())
          sb.write_char(hex.get_char(h % 16).unwrap())
        } else {
          sb.write_char(c)
        }
    }
  }
  sb.write_char('"')
  sb.to_string()
}

///|
fn canonical_value(v : Value) -> String {
  match v {
    Node(e) => e.canonical()
    List(l) => "[" + l.map(canonical_value).join(",") + "]"
    Bool(b) => if b { "true" } else { "false" }
    DT(d) => "DType." + d.name()
    Int(i) => i.to_string()
    Str(s) => json_quote(s)
  }
}

///|
/// Canonical dump: `Kind(k=v,...)` with keys in arg_types order.
pub fn Expr::canonical(self : Expr) -> String {
  let order = self.kind.arg_types()
  let keys = []
  for kv in order {
    if self.args.contains(kv.0) {
      keys.push(kv.0)
    }
  }
  let extra = []
  for k, _ in self.args {
    if !self.kind.has_arg(k) {
      extra.push(k)
    }
  }
  extra.sort()
  let parts = []
  for k in keys + extra {
    let v = self.args[k]
    match v {
      List(l) if l.is_empty() => continue
      _ => ()
    }
    parts.push(k + "=" + canonical_value(v))
  }
  match self.comments {
    Some(c) if !c.is_empty() =>
      parts.push("#c=[" + c.map(json_quote).join(", ") + "]")
    _ => ()
  }
  self.kind.name() + "(" + parts.join(",") + ")"
}
