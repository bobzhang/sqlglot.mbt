// Adversarial query shapes, each built at a given size `n`.

///|
/// A benchmark shape: `sql(n)` builds the query of size `n`; `ops` are the operations
/// timed on it ("parse", "generate", "pretty", "copy", "simplify", "optimize").
struct Case {
  name : String
  sizes : Array[Int]
  sql : (Int) -> String
  ops : Array[String]
}

///|
fn doubling(from : Int, to : Int) -> Array[Int] {
  let out = []
  let mut n = from
  while n <= to {
    out.push(n)
    n *= 2
  }
  out
}

///|
fn joined(n : Int, sep : String, item : (Int) -> String) -> String {
  let sb = StringBuilder()
  for i in 0..<n {
    if i > 0 {
      sb.write_string(sep)
    }
    sb.write_string(item(i))
  }
  sb.to_string()
}

///|
fn nested(n : Int, open : String, inner : String, close : String) -> String {
  let sb = StringBuilder()
  for _ in 0..<n {
    sb.write_string(open)
  }
  sb.write_string(inner)
  for _ in 0..<n {
    sb.write_string(close)
  }
  sb.to_string()
}

///|
let all_ops : Array[String] = [
  "parse", "generate", "pretty", "copy", "simplify", "optimize",
]

///|
let cases : Array[Case] = [
  {
    name: "wide_and",
    sizes: doubling(256, 8192),
    sql: n => "SELECT a FROM t WHERE " + joined(n, " AND ", i => "c\{i} = \{i}"),
    ops: all_ops,
  },
  {
    name: "wide_or_same_column",
    sizes: doubling(256, 8192),
    sql: n => "SELECT a FROM t WHERE " + joined(n, " OR ", i => "a = \{i}"),
    ops: all_ops,
  },
  {
    name: "wide_and_duplicates",
    sizes: doubling(256, 8192),
    sql: n => {
      "SELECT a FROM t WHERE " +
      joined(n, " AND ", i => "c\{i % 16} > \{i % 16}")
    },
    ops: ["parse", "simplify"],
  },
  {
    name: "wide_or_of_ands",
    sizes: doubling(128, 4096),
    sql: n => {
      "SELECT a FROM t WHERE " +
      joined(n, " OR ", i => "(x = \{i} AND y = \{i % 7})")
    },
    ops: ["parse", "generate", "simplify"],
  },
  {
    name: "long_in_list",
    sizes: doubling(512, 32768),
    sql: n => {
      "SELECT a FROM t WHERE a IN (" + joined(n, ", ", i => "\{i}") + ")"
    },
    ops: all_ops,
  },
  {
    name: "long_in_list_strings",
    sizes: doubling(512, 32768),
    sql: n => {
      "SELECT a FROM t WHERE a IN (" + joined(n, ", ", i => "'v\{i}'") + ")"
    },
    ops: ["parse", "generate", "simplify"],
  },
  {
    name: "nested_parens",
    sizes: doubling(64, 4096),
    sql: n => "SELECT " + nested(n, "(", "1", ")"),
    ops: all_ops,
  },
  {
    name: "nested_functions",
    sizes: doubling(64, 4096),
    sql: n => "SELECT " + nested(n, "ABS(", "x", ")") + " FROM t",
    ops: all_ops,
  },
  {
    name: "nested_unary",
    sizes: doubling(64, 4096),
    sql: n => "SELECT " + joined(n, "", _ => "- ") + "x FROM t",
    ops: all_ops,
  },
  {
    name: "nested_not",
    sizes: doubling(64, 4096),
    sql: n => "SELECT a FROM t WHERE " + joined(n, "", _ => "NOT ") + "x",
    ops: all_ops,
  },
  {
    name: "nested_subqueries",
    sizes: doubling(16, 1024),
    sql: n => nested(n, "SELECT a FROM (", "SELECT 1 AS a", ") AS s"),
    ops: all_ops,
  },
  {
    name: "deep_binary_left",
    sizes: doubling(256, 16384),
    sql: n => "SELECT " + joined(n, " + ", i => "c\{i}") + " FROM t",
    ops: all_ops,
  },
  {
    name: "deep_binary_right_parens",
    sizes: doubling(64, 4096),
    sql: n => "SELECT " + joined(n, "", i => "c\{i} + (") + "1" + ")".repeat(n),
    ops: all_ops,
  },
  {
    name: "many_ctes",
    sizes: doubling(32, 1024),
    sql: n => {
      "WITH " +
      joined(n, ", ", i => {
        if i == 0 {
          "c0 AS (SELECT 1 AS x)"
        } else {
          "c\{i} AS (SELECT x FROM c\{i - 1})"
        }
      }) +
      " SELECT x FROM c\{n - 1}"
    },
    ops: all_ops,
  },
  {
    name: "long_string_literal",
    sizes: doubling(4096, 1048576),
    sql: n => "SELECT '" + "ab''c".repeat(n / 5) + "' AS s",
    ops: ["parse", "generate", "copy", "simplify"],
  },
  {
    name: "long_comment",
    sizes: doubling(4096, 1048576),
    sql: n => "SELECT 1 /* " + "x".repeat(n) + " */",
    ops: ["parse", "generate"],
  },
  {
    name: "repeated_hints",
    sizes: doubling(64, 4096),
    sql: n => {
      joined(n, " UNION ALL ", i => "SELECT /*+ INDEX(t i\{i}) */ a FROM t")
    },
    ops: ["parse", "generate"],
  },
  {
    name: "many_commands",
    sizes: doubling(64, 4096),
    sql: n => joined(n, "; ", i => "SHOW TABLES LIKE 'x\{i}'"),
    ops: ["parse"],
  },
  {
    name: "huge_select_list",
    sizes: doubling(256, 16384),
    sql: n => "SELECT " + joined(n, ", ", i => "c\{i} AS a\{i}") + " FROM t",
    ops: all_ops,
  },
  {
    name: "wide_union",
    sizes: doubling(32, 2048),
    sql: n => joined(n, " UNION ALL ", i => "SELECT \{i} AS x"),
    ops: all_ops,
  },
  {
    name: "big_case",
    sizes: doubling(128, 8192),
    sql: n => {
      "SELECT CASE " +
      joined(n, " ", i => "WHEN x = \{i} THEN 'v\{i}'") +
      " ELSE NULL END FROM t"
    },
    ops: all_ops,
  },
  {
    name: "many_joins",
    sizes: doubling(16, 512),
    sql: n => {
      "SELECT t0.a FROM t0 " +
      joined(n, " ", i => "JOIN t\{i + 1} ON t\{i + 1}.a = t\{i}.a")
    },
    ops: all_ops,
  },
  {
    name: "pretty_large_query",
    sizes: doubling(32, 2048),
    sql: n => {
      joined(n, " UNION ALL ", i => {
        "SELECT a\{i}, SUM(b) AS s FROM t\{i} WHERE x = \{i} AND y IN (1, 2, 3) GROUP BY a\{i} HAVING COUNT(*) > 1"
      })
    },
    ops: ["parse", "generate", "pretty"],
  },
]
