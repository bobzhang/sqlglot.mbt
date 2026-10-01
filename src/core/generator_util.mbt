// Small Python-compatible helpers used by the generator.

///|
fn first_char(s : String) -> Char? {
  for c in s {
    return Some(c)
  }
  None
}

///|
fn last_char(s : String) -> Char? {
  let mut last : Char? = None
  for c in s.rev_iter() {
    last = Some(c)
    break
  }
  last
}

///|
/// Python `str.lstrip()`.
pub fn py_lstrip(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  while i < chars.length() && is_space(chars[i]) {
    i += 1
  }
  if i == 0 {
    s
  } else {
    String::from_array(chars[i:])
  }
}

///|
/// Python `str.rstrip()`.
pub fn py_rstrip(s : String) -> String {
  let chars = s.to_array()
  let mut j = chars.length()
  while j > 0 && is_space(chars[j - 1]) {
    j -= 1
  }
  if j == chars.length() {
    s
  } else {
    String::from_array(chars[:j])
  }
}

///|
/// Python `str.lstrip(chars)`.
pub fn lstrip_chars(s : String, chars : String) -> String {
  s.trim_start(chars~).to_owned()
}

///|
/// Python `str[n:]` on code points.
fn str_from(s : String, n : Int) -> String {
  substr(s, n, py_len(s))
}

///|
/// sqlglot `helper.csv`: joins the non-empty strings with `sep`.
pub fn csv(args : Array[String], sep? : String = ", ") -> String {
  let out = []
  for a in args {
    if a != "" {
      out.push(a)
    }
  }
  out.join(sep)
}

///|
/// Python `str(int(text, base))`: converts a (possibly huge) number written in
/// `base` into its decimal representation.
pub fn int_str_from_base(
  text : String,
  base : Int,
) -> String raise SqlglotError {
  let t = py_strip(text).replace_all(old="_", new="")
  let mut negative = false
  let mut body = t
  if body.has_prefix("-") {
    negative = true
    body = str_from(body, 1)
  } else if body.has_prefix("+") {
    body = str_from(body, 1)
  }
  let lower = py_lower(body)
  if (base == 16 && lower.has_prefix("0x")) ||
    (base == 2 && lower.has_prefix("0b")) ||
    (base == 8 && lower.has_prefix("0o")) {
    body = str_from(body, 2)
  }
  if body == "" {
    raise ValueError(
      "invalid literal for int() with base \{base}: \{py_repr_str(text)}",
    )
  }
  // little-endian base-10^4 digits
  let digits : Array[Int] = [0]
  for c in body {
    let d = match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='z' => c.to_int() - 'a'.to_int() + 10
      'A'..='Z' => c.to_int() - 'A'.to_int() + 10
      _ => 99
    }
    if d >= base {
      raise ValueError(
        "invalid literal for int() with base \{base}: \{py_repr_str(text)}",
      )
    }
    let mut carry = d
    for i in 0..<digits.length() {
      let v = digits[i] * base + carry
      digits[i] = v % 10000
      carry = v / 10000
    }
    while carry > 0 {
      digits.push(carry % 10000)
      carry = carry / 10000
    }
  }
  let sb = StringBuilder()
  let n = digits.length()
  let mut top = n - 1
  while top > 0 && digits[top] == 0 {
    top -= 1
  }
  if negative && !(top == 0 && digits[0] == 0) {
    sb.write_char('-')
  }
  sb.write_string(digits[top].to_string())
  let mut i = top - 1
  while i >= 0 {
    let s = digits[i].to_string()
    sb.write_string("0".repeat(4 - s.length()))
    sb.write_string(s)
    i -= 1
  }
  sb.to_string()
}

///|
/// Python `str(value)` for an argument value, as used in f-strings
/// (`str(expr)` generates SQL with the default dialect).
pub fn py_str_value(v : Value?) -> String raise SqlglotError {
  match v {
    None => "None"
    Some(Node(e)) => expr_to_sql(e)
    Some(Str(s)) => s
    Some(Bool(b)) => if b { "True" } else { "False" }
    Some(Int(i)) => i.to_string()
    Some(DT(d)) => "DType." + d.name()
    Some(List(l)) => {
      let parts = []
      for x in l {
        parts.push(
          match x {
            Str(s) => py_repr_str(s)
            other => py_str_value(Some(other))
          },
        )
      }
      "[" + parts.join(", ") + "]"
    }
  }
}

///|
/// The dialect's class name, used in some messages (Python `self.dialect.__class__.__name__`).
fn Generator::dialect_class_name(self : Generator) -> String {
  dialect_class_name(self.dialect)
}

///|
/// Python `Dialect.__class__.__name__` for a dialect.
pub fn dialect_class_name(d : Dialect) -> String {
  match d.name {
    "" => "Dialect"
    "bigquery" => "BigQuery"
    "clickhouse" => "ClickHouse"
    "databricks" => "Databricks"
    "doris" => "Doris"
    "dremio" => "Dremio"
    "drill" => "Drill"
    "druid" => "Druid"
    "duckdb" => "DuckDB"
    "dune" => "Dune"
    "exasol" => "Exasol"
    "fabric" => "Fabric"
    "hive" => "Hive"
    "materialize" => "Materialize"
    "mysql" => "MySQL"
    "oracle" => "Oracle"
    "postgres" => "Postgres"
    "presto" => "Presto"
    "prql" => "PRQL"
    "redshift" => "Redshift"
    "risingwave" => "RisingWave"
    "singlestore" => "SingleStore"
    "snowflake" => "Snowflake"
    "solr" => "Solr"
    "spark" => "Spark"
    "spark2" => "Spark2"
    "sqlite" => "SQLite"
    "starrocks" => "StarRocks"
    "tableau" => "Tableau"
    "teradata" => "Teradata"
    "trino" => "Trino"
    "tsql" => "TSQL"
    "athena" => "Athena"
    "dax" => "DAX"
    n => {
      let sb = StringBuilder()
      let mut first = true
      for c in n {
        sb.write_char(if first { char_upper(c) } else { c })
        first = false
      }
      sb.to_string()
    }
  }
}

///|
/// `f"{prefix}{s}" if s else ""`.
fn pfx(prefix : String, s : String) -> String {
  if s != "" {
    prefix + s
  } else {
    ""
  }
}

///|
/// `f"{prefix}{s}{suffix}" if s else ""`.
fn around(prefix : String, s : String, suffix : String) -> String {
  if s != "" {
    prefix + s + suffix
  } else {
    ""
  }
}

///|
/// `s if cond else ""`.
fn when(cond : Bool, s : String) -> String {
  if cond {
    s
  } else {
    ""
  }
}

///|
/// Python truthiness of an optional string (`None` and `""` are falsy).
fn str_truthy(s : String?) -> Bool {
  match s {
    Some(x) => x != ""
    None => false
  }
}

///|
fn opt_str(s : String?) -> String {
  match s {
    Some(x) => x
    None => ""
  }
}

///|
/// Converts strings to argument values (for `expressions(sqls=...)`).
fn strs(xs : Array[String]) -> Array[Value] {
  xs.map(x => Str(x))
}

///|
/// Converts expressions to argument values (for `expressions(sqls=...)`).
fn nodes(xs : Array[Expr]) -> Array[Value] {
  xs.map(x => Node(x))
}

///|
/// Converts expressions to `func` arguments.
fn fargs(xs : Array[Expr]) -> Array[&SqlArg] {
  xs.map(x => (x : &SqlArg))
}
