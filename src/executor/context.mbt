// Port of sqlglot/executor/context.py.

///|
/// Execution context for sql expressions: the tables of the current scope. Column
/// references evaluate to scalars after `set_row` and to vectors after `set_range`.
pub struct Context {
  /// table name (`None` for the anonymous table) -> table, in insertion order
  tables : Array[(String?, Table)]
  mut table_ : Table?
  range_readers : Map[String?, Reader]
  row_readers : Map[String?, Reader]
  env : Map[String, Value]
  /// the value of the `scope` global
  mut scope : Value
}

///|
/// Builds a context. Entries of `tables` with the same name replace earlier ones (as in
/// a Python dict); `outer` are the readers of an enclosing query.
pub fn Context::new(
  tables : Array[(String?, Table)],
  env? : Map[String, Value] = {},
  outer? : Map[String?, Reader],
) -> Context {
  let deduped : Array[(String?, Table)] = []
  for kv in tables {
    let mut replaced = false
    for i, e in deduped {
      if e.0 == kv.0 {
        deduped[i] = (e.0, kv.1)
        replaced = true
        break
      }
    }
    if !replaced {
      deduped.push(kv)
    }
  }
  let range_readers : Map[String?, Reader] = Map([])
  let row_readers : Map[String?, Reader] = Map([])
  match outer {
    Some(o) =>
      for k, v in o {
        range_readers[k] = v
        row_readers[k] = v
      }
    None => ()
  }
  for kv in deduped {
    range_readers.remove(kv.0)
    range_readers[kv.0] = Range(kv.1.range_reader)
  }
  for kv in deduped {
    row_readers.remove(kv.0)
    row_readers[kv.0] = Row(kv.1.reader)
  }
  {
    tables: deduped,
    table_: None,
    range_readers,
    row_readers,
    env,
    scope: Readers(row_readers),
  }
}

///|
/// Python `eval(code, self.env)`.
pub fn Context::eval(self : Context, code : Code) -> Value raise {
  eval_code(code, self.env, self.scope)
}

///|
pub fn Context::eval_tuple(
  self : Context,
  codes : Array[Code],
) -> Array[Value] raise {
  codes.map(c => self.eval(c))
}

///|
pub fn Context::table(self : Context) -> Table raise PyException {
  match self.table_ {
    Some(t) => t
    None => {
      guard self.tables.get(0) is Some((_, first)) else {
        raise PyException("IndexError", "list index out of range")
      }
      for kv in self.tables {
        let other = kv.1
        if first.columns != other.columns {
          raise PyException("Exception", "Columns are different.")
        }
        if first.rows.length() != other.rows.length() {
          raise PyException("Exception", "Rows are different.")
        }
      }
      self.table_ = Some(first)
      first
    }
  }
}

///|
pub fn Context::add_columns(self : Context, columns : Array[String]) -> Unit {
  for kv in self.tables {
    kv.1.add_columns(columns)
  }
}

///|
pub fn Context::columns(self : Context) -> Array[String] raise PyException {
  if self.tables.is_empty() {
    []
  } else {
    self.table().columns
  }
}

///|
/// Python `iter(context)`: sets each row in turn and calls `f` with the reader of the
/// last table.
pub fn Context::each(
  self : Context,
  f : (RowReader) -> Unit raise,
) -> Unit raise {
  self.scope = Readers(self.row_readers)
  let n = self.table().rows.length()
  for i in 0..<n {
    let mut reader : RowReader? = None
    for kv in self.tables {
      reader = Some(kv.1.get_row(i))
    }
    f(reader.unwrap())
  }
}

///|
/// Python `context.table_iter(table)`: an iterator over the rows of a table.
pub fn Context::table_iter(
  self : Context,
  name : String?,
) -> TableIter raise PyException {
  self.scope = Readers(self.row_readers)
  for kv in self.tables {
    if kv.0 == name {
      return { table: kv.1, index: -1, }
    }
  }
  raise PyException(
    "KeyError",
    name.map(n => @core.py_repr_str(n)).unwrap_or("None"),
  )
}

///|
pub fn Context::get_table(
  self : Context,
  name : String?,
) -> Table raise PyException {
  for kv in self.tables {
    if kv.0 == name {
      return kv.1
    }
  }
  raise PyException(
    "KeyError",
    name.map(n => @core.py_repr_str(n)).unwrap_or("None"),
  )
}

///|
pub fn Context::sort(self : Context, key : Array[Code]) -> Unit raise {
  let rows = self.table().rows
  let keys = rows.map(row => {
    self.set_row(row)
    Tuple(self.eval_tuple(key).map(t => Tuple([Bool(t is Null), t])))
  })
  let order = stable_sort_indices(keys)
  let sorted = order.map(i => rows[i])
  for i, r in sorted {
    rows[i] = r
  }
}

///|
pub fn Context::set_row(self : Context, row : Row) -> Unit {
  for kv in self.tables {
    kv.1.reader.row = row
  }
  self.scope = Readers(self.row_readers)
}

///|
pub fn Context::set_index(
  self : Context,
  index : Int,
) -> Unit raise PyException {
  for kv in self.tables {
    kv.1.get_row(index) |> ignore
  }
  self.scope = Readers(self.row_readers)
}

///|
pub fn Context::set_range(self : Context, start : Int, end : Int) -> Unit {
  for kv in self.tables {
    match self.range_readers.get(kv.0) {
      Some(Range(r)) => {
        r.start = start
        r.stop = end
      }
      _ => ()
    }
  }
  self.scope = Readers(self.range_readers)
}

///|
pub fn Context::contains(self : Context, name : String?) -> Bool {
  self.tables.iter().any(kv => kv.0 == name)
}

///|
/// Python `TableIter`.
pub struct TableIter {
  table : Table
  mut index : Int
}

///|
pub fn TableIter::next(self : TableIter) -> RowReader? raise PyException {
  self.index += 1
  if self.index < self.table.rows.length() {
    Some(self.table.get_row(self.index))
  } else {
    None
  }
}

///|
/// A stable sort (like Python's `list.sort`) of indices by `<` on the keys.
fn stable_sort_indices(keys : Array[Value]) -> Array[Int] raise PyException {
  let idx = Array::makei(keys.length(), i => i)
  merge_sort(idx, keys)
  idx
}

///|
fn merge_sort(idx : Array[Int], keys : Array[Value]) -> Unit raise PyException {
  let n = idx.length()
  if n < 2 {
    return
  }
  let buf = Array::make(n, 0)
  let mut width = 1
  // insertion sort runs of 8 first
  let run = 8
  let mut s = 0
  while s < n {
    let e = @cmp.minimum(s + run, n)
    for i in (s + 1)..<e {
      let x = idx[i]
      let mut j = i - 1
      while j >= s && py_lt(keys[x], keys[idx[j]]) {
        idx[j + 1] = idx[j]
        j -= 1
      }
      idx[j + 1] = x
    }
    s = e
  }
  width = run
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = @cmp.minimum(lo + width, n)
      let hi = @cmp.minimum(lo + 2 * width, n)
      if mid < hi {
        let mut i = lo
        let mut j = mid
        let mut k = lo
        while i < mid && j < hi {
          // take from the right only if strictly smaller (stability)
          if py_lt(keys[idx[j]], keys[idx[i]]) {
            buf[k] = idx[j]
            j += 1
          } else {
            buf[k] = idx[i]
            i += 1
          }
          k += 1
        }
        while i < mid {
          buf[k] = idx[i]
          i += 1
          k += 1
        }
        while j < hi {
          buf[k] = idx[j]
          j += 1
          k += 1
        }
        for t in lo..<hi {
          idx[t] = buf[t]
        }
      }
      lo += 2 * width
    }
    width *= 2
  }
}
