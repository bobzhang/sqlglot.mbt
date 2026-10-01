// Port of sqlglot/executor/table.py.

///|
/// A row of a table (a Python tuple).
pub type Row = Array[Value]

///|
/// A simple columnar data structure: column names and rows of values.
pub struct Table {
  mut columns : Array[String]
  mut column_range : (Int, Int)?
  mut reader : RowReader
  mut rows : Array[Row]
  range_reader : RangeReader
}

///|
/// Reads the columns of the current row.
pub struct RowReader {
  columns : Map[String, Int]
  mut row : Row
}

///|
/// Reads the values of a column over a range of rows.
pub struct RangeReader {
  mut table : Table?
  mut start : Int
  mut stop : Int
}

///|
fn range_contains(r : (Int, Int)?, i : Int) -> Bool {
  match r {
    // an empty range is falsy in Python: all columns are visible
    None => true
    Some((start, stop)) => start >= stop || (i >= start && i < stop)
  }
}

///|
pub fn RowReader::new(
  columns? : Array[String],
  column_range? : (Int, Int),
) -> RowReader {
  let m : Map[String, Int] = Map([])
  match columns {
    Some(cols) =>
      for i, c in cols {
        if range_contains(column_range, i) {
          m[c] = i
        }
      }
    None => ()
  }
  { columns: m, row: [], }
}

///|
pub fn RowReader::get(
  self : RowReader,
  column : String,
) -> Value raise PyException {
  match self.columns.get(column) {
    Some(i) =>
      match self.row.get(i) {
        Some(v) => v
        None => raise PyException("IndexError", "tuple index out of range")
      }
    None => raise PyException("KeyError", @core.py_repr_str(column))
  }
}

///|
pub fn RangeReader::length(self : RangeReader) -> Int {
  if self.stop > self.start {
    self.stop - self.start
  } else {
    0
  }
}

///|
pub fn RangeReader::get(
  self : RangeReader,
  column : String,
) -> Value raise PyException {
  let out = []
  match self.table {
    Some(t) =>
      for i in self.start..<self.stop {
        out.push(t.get_row(i).get(column))
      }
    None => ()
  }
  Iter(out)
}

///|
pub fn Reader::get(self : Reader, column : String) -> Value raise PyException {
  match self {
    Row(r) => r.get(column)
    Range(r) => r.get(column)
  }
}

///|
/// Creates a table. `rows` is shared (not copied), as in Python, unless empty.
pub fn Table::new(
  columns? : Array[String] = [],
  rows? : Array[Row] = [],
  column_range? : (Int, Int),
) -> Table {
  let columns = columns.copy()
  if !rows.is_empty() && rows[0].length() != columns.length() {
    abort("AssertionError: row width does not match the columns")
  }
  let range_reader = { table: None, start: 0, stop: 0, }
  let t = {
    columns,
    column_range,
    reader: RowReader::new(columns~, column_range?),
    rows: if rows.is_empty() {
      []
    } else {
      rows
    },
    range_reader,
  }
  range_reader.table = Some(t)
  t
}

///|
pub fn Table::add_columns(self : Table, columns : Array[String]) -> Unit {
  self.columns = self.columns + columns
  match self.column_range {
    Some((start, stop)) =>
      if stop > start {
        self.column_range = Some((start, stop + columns.length()))
      }
    None => ()
  }
  self.reader = RowReader::new(
    columns=self.columns,
    column_range?=self.column_range,
  )
}

///|
pub fn Table::append(self : Table, row : Row) -> Unit raise PyException {
  if row.length() != self.columns.length() {
    raise PyException("AssertionError", "row width does not match the columns")
  }
  self.rows.push(row)
}

///|
pub fn Table::pop(self : Table) -> Unit {
  self.rows.pop() |> ignore
}

///|
/// Python `Table.to_pylist()`: the rows as (column, value) records.
pub fn Table::to_pylist(self : Table) -> Array[Array[(String, Value)]] {
  self.rows.map(row => {
    let n = if row.length() < self.columns.length() {
      row.length()
    } else {
      self.columns.length()
    }
    Array::makei(n, i => (self.columns[i], row[i]))
  })
}

///|
pub fn Table::width(self : Table) -> Int {
  self.columns.length()
}

///|
pub fn Table::length(self : Table) -> Int {
  self.rows.length()
}

///|
/// Python `table[index]`: points the table's reader at a row and returns it.
pub fn Table::get_row(self : Table, index : Int) -> RowReader raise PyException {
  let n = self.rows.length()
  let i = if index < 0 { index + n } else { index }
  if i < 0 || i >= n {
    raise PyException("IndexError", "list index out of range")
  }
  self.reader.row = self.rows[i]
  self.reader
}

///|
/// Python `repr(table)`.
pub fn Table::to_string(self : Table) -> String {
  let columns = []
  for i, c in self.columns {
    if range_contains(self.column_range, i) {
      columns.push(c)
    }
  }
  let lines = [columns.join(" ")]
  for i in 0..<self.rows.length() {
    if i > 10 {
      break
    }
    let row = try! self.get_row(i)
    let cells = columns.map(column => {
      let width = column.char_length()
      let s = (row.get(column) catch { _ => Null }).py_str()
      let s = if s.char_length() < width {
        " ".repeat(width - s.char_length()) + s
      } else {
        s
      }
      String::from_array(s.to_array()[0:width].to_owned())
    })
    lines.push(cells.join(" "))
  }
  lines.join("\n")
}

///|
pub impl Show for Table with fn output(self, logger) {
  logger.write_string(self.to_string())
}

///|
#deprecated
pub extend Table with Show::{output}

///|
/// The input data of `execute`: rows given as records, a `Table`, or a nested mapping
/// of `{db: {table: ...}}`.
pub(all) enum TableData {
  Records(Array[Array[(String, Value)]])
  Tbl(Table)
  Nested(Map[String, TableData])
}

///|
/// A nested mapping of table names to tables (Python `Tables(AbstractMappingSchema)`).
pub struct Tables {
  mapping : Map[String, TableData]
  supported_table_args : Array[String]
}

///|
fn data_depth(d : Map[String, TableData]) -> Int {
  match d.values().next() {
    None => 1
    Some(Nested(m)) => 1 + data_depth(m)
    Some(_) => 1
  }
}

///|
let table_parts : Array[String] = ["this", "db", "catalog"]

///|
pub fn Tables::new(
  mapping : Map[String, TableData],
) -> Tables raise @core.SqlglotError {
  let args = if mapping.is_empty() {
    []
  } else {
    let depth = data_depth(mapping)
    if depth >= 1 && depth <= 3 {
      table_parts[0:depth].to_owned()
    } else {
      raise @core.SchemaError("Invalid mapping shape. Depth: \{depth}")
    }
  }
  { mapping, supported_table_args: args, }
}

///|
/// The table paths of the mapping (Python `flatten_schema(mapping, depth)`).
pub fn Tables::flatten(self : Tables) -> Array[Array[String]] {
  let out = []
  let depth = self.supported_table_args.length()
  fn go(m : Map[String, TableData], depth : Int, keys : Array[String]) -> Unit {
    for k, v in m {
      match v {
        Nested(sub) if depth > 1 => go(sub, depth - 1, keys + [k])
        _ => out.push(keys + [k])
      }
    }
  }

  go(self.mapping, depth, [])
  out
}

///|
/// Looks up a table by its path (outermost first).
pub fn Tables::get(self : Tables, keys : Array[String]) -> Table? {
  let mut m = self.mapping
  for i, k in keys {
    match m.get(k) {
      Some(Nested(sub)) if i < keys.length() - 1 => m = sub
      Some(Tbl(t)) if i == keys.length() - 1 => return Some(t)
      _ => return None
    }
  }
  None
}

///|
/// Python `AbstractMappingSchema.find(table)`: the table matching an `exp.Table`.
pub fn Tables::find(
  self : Tables,
  table : @core.Expr,
  raise_on_missing? : Bool = true,
) -> Table? raise @core.SqlglotError {
  let all_parts = table.parts().map(p => p.name())
  all_parts.rev_in_place()
  let n = @cmp.minimum(self.supported_table_args.length(), all_parts.length())
  let parts = all_parts[0:n].to_owned()
  // trie lookup of the reversed paths
  let paths = self
    .flatten()
    .map(p => {
      let r = p.copy()
      r.rev_in_place()
      r
    })
  let exact = paths.filter(p => p == parts)
  let resolved = if !exact.is_empty() {
    parts
  } else {
    let prefixed = paths.filter(p => {
      p.length() > parts.length() && p[0:parts.length()].to_owned() == parts
    })
    if prefixed.is_empty() {
      return None
    }
    if prefixed.length() == 1 {
      prefixed[0]
    } else {
      if raise_on_missing {
        let joined = parts.join(".")
        let message = prefixed
          .map(p => p[parts.length():].to_owned().join("."))
          .join(", ")
        raise @core.SchemaError("Ambiguous mapping for \{joined}: \{message}.")
      }
      return None
    }
  }
  // nested_get with (arg name, key) pairs
  let keys = resolved.copy()
  keys.rev_in_place()
  let mut m = self.mapping
  let args = self.supported_table_args
  let path = []
  for i in 0..<@cmp.minimum(args.length(), resolved.length()) {
    path.push((args[i], resolved[resolved.length() - 1 - i]))
  }
  // Python zips the table args with the reversed parts: (this, outermost) ...
  ignore(keys)
  for i, pair in path {
    let (name, key) = pair
    match m.get(key) {
      Some(Nested(sub)) if i < path.length() - 1 => m = sub
      Some(Tbl(t)) if i == path.length() - 1 => return Some(t)
      _ =>
        if raise_on_missing {
          let name = if name == "this" { "table" } else { name }
          raise @core.ValueError("Unknown \{name}: \{key}")
        } else {
          return None
        }
    }
  }
  None
}

///|
/// Python `ensure_tables(d, dialect)`: normalizes table and column names and converts
/// records to `Table`s.
pub fn ensure_tables(
  d : Map[String, TableData]?,
  dialect? : @core.Dialect,
) -> Tables raise @core.SqlglotError {
  Tables::new(ensure_tables_map(d.unwrap_or({}), dialect))
}

///|
fn ensure_tables_map(
  d : Map[String, TableData],
  dialect : @core.Dialect?,
) -> Map[String, TableData] {
  if d.is_empty() {
    return {}
  }
  let depth = data_depth(d)
  let result : Map[String, TableData] = Map([])
  if depth > 1 {
    for k, v in d {
      let name = @optimizer.normalize_name(k, dialect?, is_table=true).name()
      let sub = match v {
        Nested(m) => m
        _ => {}
      }
      result[name] = Nested(ensure_tables_map(sub, dialect))
    }
    return result
  }
  for k, v in d {
    let table_name = @optimizer.normalize_name(k, dialect?).name()
    match v {
      Tbl(t) => result[table_name] = Tbl(t)
      Records(records) => {
        let normalized = records.map(row => {
          row.map(cv => (@optimizer.normalize_name(cv.0, dialect?).name(), cv.1))
        })
        let column_names = []
        if !normalized.is_empty() {
          for cv in normalized[0] {
            if !column_names.contains(cv.0) {
              column_names.push(cv.0)
            }
          }
        }
        let rows = normalized.map(row => {
          column_names.map(name => {
            let mut found = Null
            for cv in row {
              if cv.0 == name {
                found = cv.1
              }
            }
            found
          })
        })
        result[table_name] = Tbl(Table::new(columns=column_names, rows~))
      }
      Nested(_) => result[table_name] = v
    }
  }
  result
}
