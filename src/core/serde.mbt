// Port of sqlglot/serde.py: dump/load of expression trees to/from a flat,
// JSON-compatible list of payloads.
//
// Each payload is an object with the keys
//   "i": index of the parent payload, "k": the parent's arg key,
//   "a": true if the node is an element of a list argument,
//   "c": the expression class name (or "DataType.Type" for a DType value),
//   "t": the dumped `type` of the node, "o": comments, "m": meta,
//   "v": a leaf value (string, bool, int, list of leaves or DType value).

///|
let serde_index : String = "i"

///|
let serde_arg_key : String = "k"

///|
let serde_is_array : String = "a"

///|
let serde_class : String = "c"

///|
let serde_type : String = "t"

///|
let serde_comments : String = "o"

///|
let serde_meta : String = "m"

///|
let serde_value : String = "v"

///|
let serde_data_type : String = "DataType.Type"

///|
priv struct SerdeStackVal {
  node : Value
  index : Int?
  arg_key : String?
  is_array : Bool
}

///|
/// Converts a non-node leaf value to JSON (Python's `json.dumps` of the raw arg).
fn serde_leaf_to_json(v : Value) -> Json {
  match v {
    Str(s) => Json::string(s)
    Bool(b) => Json::boolean(b)
    Int(i) => Json::number(i.to_double())
    DT(d) => Json::string(d.value())
    List(l) => Json::array(l.map(serde_leaf_to_json))
    // Not JSON-serializable in Python; dumped as a nested payload list.
    Node(e) => e.dump()
  }
}

///|
/// Converts a JSON leaf value back to an argument value.
fn serde_leaf_from_json(j : Json) -> Value raise SqlglotError {
  match j {
    String(s) => Str(s)
    True => Bool(true)
    False => Bool(false)
    Number(n, ..) => Int(n.to_int())
    Array(items) =>
      // A list of payload objects is a nested dump (see `serde_leaf_to_json`).
      if !items.is_empty() && items.iter().all(x => x is Object(_)) {
        match Expr::load(j) {
          Some(e) => Node(e)
          None => List([])
        }
      } else {
        List(items.map(serde_leaf_from_json))
      }
    Null | Object(_) =>
      raise ValueError("Cannot load JSON value \{j.stringify()} as an argument")
  }
}

///|
/// Dumps this expression into a JSON-serializable list of payloads
/// (Python `Expr.dump`).
pub fn Expr::dump(self : Expr) -> Json {
  let mut i = 0
  let payloads : Array[Json] = []
  let stack : Array[SerdeStackVal] = [
    { node: Node(self), index: None, arg_key: None, is_array: false, },
  ]
  while stack.pop() is Some({ node, index, arg_key, is_array, }) {
    let payload : Map[String, Json] = Map([])
    if index is Some(idx) {
      payload[serde_index] = Json::number(idx.to_double())
    }
    if arg_key is Some(k) {
      payload[serde_arg_key] = Json::string(k)
    }
    if is_array {
      payload[serde_is_array] = Json::boolean(true)
    }
    payloads.push(Json::object(payload))
    match node {
      Node(e) => {
        // Python `__qualname__`, prefixed with the defining module unless it is
        // `sqlglot.expressions` itself.
        let module_name = e.kind.module_name()
        payload[serde_class] = Json::string(
          if module_name == "sqlglot.expressions" {
            e.kind.name()
          } else {
            "\{module_name}.\{e.kind.name()}"
          },
        )
        match e.get_type() {
          Some(t) if !physical_equal(t, e) => payload[serde_type] = t.dump()
          _ => ()
        }
        match e.comments {
          Some(c) if !c.is_empty() =>
            payload[serde_comments] = Json::array(c.map(Json::string))
          _ => ()
        }
        match e.meta {
          Some(m) => {
            let obj : Map[String, Json] = Map([])
            for k, v in m {
              obj[k] = serde_leaf_to_json(v)
            }
            payload[serde_meta] = Json::object(obj)
          }
          None => ()
        }
        let entries = e.args.to_array()
        entries.rev_in_place()
        for kv in entries {
          let (k, vs) = kv
          match vs {
            List(l) =>
              for j = l.length() - 1; j >= 0; j = j - 1 {
                stack.push({
                  node: l[j],
                  index: Some(i),
                  arg_key: Some(k),
                  is_array: true,
                })
              }
            _ =>
              stack.push({
                node: vs,
                index: Some(i),
                arg_key: Some(k),
                is_array: false,
              })
          }
        }
      }
      DT(d) => {
        payload[serde_class] = Json::string(serde_data_type)
        payload[serde_value] = Json::string(d.value())
      }
      other => payload[serde_value] = serde_leaf_to_json(other)
    }
    i += 1
  }
  Json::array(payloads)
}

///|
/// Loads a payload list produced by `Expr::dump` back into an expression
/// (Python `Expr.load`). Returns `None` for an empty or null payload list.
pub fn Expr::load(payloads : Json) -> Expr? raise SqlglotError {
  let items = match payloads {
    Array(items) => items
    Null => return None
    _ => raise ValueError("Expected a list of payloads")
  }
  if items.is_empty() {
    return None
  }
  let root = match serde_load_node(serde_payload(items[0])) {
    Node(e) => e
    _ => raise ValueError("The root payload must be an expression")
  }
  let nodes : Array[Value] = [Node(root)]
  for p in items[1:] {
    let payload = serde_payload(p)
    let node = if payload.contains(serde_class) {
      serde_load_node(payload)
    } else {
      match payload.get(serde_value) {
        Some(v) => serde_leaf_from_json(v)
        None => raise ValueError("Payload without a class or a value")
      }
    }
    nodes.push(node)
    let parent_index = match payload.get(serde_index) {
      Some(Number(n, ..)) => n.to_int()
      _ => raise ValueError("Payload without a parent index")
    }
    let parent = match nodes.get(parent_index) {
      Some(Node(e)) => e
      _ => raise ValueError("Invalid parent index \{parent_index}")
    }
    let arg_key = match payload.get(serde_arg_key) {
      Some(String(k)) => k
      _ => raise ValueError("Payload without an arg key")
    }
    let is_array = match payload.get(serde_is_array) {
      Some(True) => true
      _ => false
    }
    if is_array {
      parent.append(arg_key, node)
    } else {
      parent.set(arg_key, node)
    }
  }
  Some(root)
}

///|
fn serde_payload(j : Json) -> Map[String, Json] raise SqlglotError {
  match j {
    Object(m) => m
    _ => raise ValueError("Payloads must be objects, got \{j.stringify()}")
  }
}

///|
fn serde_load_node(payload : Map[String, Json]) -> Value raise SqlglotError {
  let class_name = match payload.get(serde_class) {
    Some(String(c)) => c
    _ => raise ValueError("Payload without a class")
  }
  if class_name == serde_data_type {
    let v = match payload.get(serde_value) {
      Some(String(v)) => v
      _ => raise ValueError("DataType.Type payload without a value")
    }
    return match dtype_from_value(v) {
      Some(d) => DT(d)
      None => raise ValueError("Unknown DataType.Type value \{v}")
    }
  }
  // Python resolves dotted names through their module; only the expression
  // classes of sqlglot exist here, so the last component is looked up.
  let name = match class_name.rev_find(".") {
    Some(pos) => class_name.view(start_offset=pos + 1).to_owned()
    None => class_name
  }
  let kind = match kind_from_name(name) {
    Some(k) => k
    None => raise ValueError("Unknown expression class \{class_name}")
  }
  let expression = mk0(kind)
  expression.type_ = match payload.get(serde_type) {
    Some(t) => Expr::load(t)
    None => None
  }
  expression.comments = match payload.get(serde_comments) {
    Some(Array(c)) =>
      Some(
        c.map(x => {
          match x {
            String(s) => s
            _ => x.stringify()
          }
        }),
      )
    _ => None
  }
  expression.meta = match payload.get(serde_meta) {
    Some(Object(m)) => {
      let meta : Map[String, Value] = Map([])
      for k, v in m {
        meta[k] = serde_leaf_from_json(v)
      }
      Some(meta)
    }
    _ => None
  }
  Node(expression)
}
