# hongbozhang/sqlglot

The facade package of the MoonBit port of [sqlglot](https://github.com/tobymao/sqlglot):
a SQL parser, transpiler, optimizer and engine. Importing only this package is enough
for the common workflows below: it registers all built-in dialects and re-exports the
principal types (`Expr`, `Kind`, `Dialect`, `ErrorLevel`, `SqlglotError`, `DType`,
`Generator`, `IntoPy`, `MappingSchema`, `SchemaNode`, `Table`, `TableData`, ...).

```
import {
  "hongbozhang/sqlglot",
}
```

Every example in this file is compiled and run by `moon test`.

## Transpiling

`transpile` parses SQL in one dialect (`read`) and generates it in another (`write`):

```mbt check
///|
test "transpile between dialects" {
  inspect(
    @sqlglot.transpile(
      "SELECT EPOCH_MS(1618088028295)",
      read="duckdb",
      write="hive",
    )[0],
    content="SELECT FROM_UNIXTIME(1618088028295 / POW(10, 3))",
  )
  inspect(
    @sqlglot.transpile(
      "SELECT STRFTIME(x, '%y-%-m-%S')",
      read="duckdb",
      write="hive",
    )[0],
    content="SELECT DATE_FORMAT(x, 'yy-M-ss')",
  )
}
```

Generator options are labelled arguments; `identify` and `normalize_functions` take the
`Identify` and `NormalizeFunctions` enums:

```mbt check
///|
test "generator options" {
  inspect(
    @sqlglot.transpile("SELECT a FROM t WHERE b = 1", write="spark", identify=Always)[0],
    content="SELECT `a` FROM `t` WHERE `b` = 1",
  )
  inspect(
    @sqlglot.transpile(
      "SELECT cardinality(x) FROM t",
      read="presto",
      write="presto",
      normalize_functions=Lower,
    )[0],
    content="SELECT cardinality(x) FROM t",
  )
  inspect(
    @sqlglot.transpile(
      "WITH baz AS (SELECT a, c FROM foo WHERE a = 1) SELECT f.a, b.b, baz.c, CAST(\"b\".\"a\" AS REAL) d FROM foo f JOIN bar b ON f.a = b.a LEFT JOIN baz ON f.a = baz.a",
      write="spark",
      identify=Always,
      pretty=true,
    )[0],
    content=(
      #|WITH `baz` AS (
      #|  SELECT
      #|    `a`,
      #|    `c`
      #|  FROM `foo`
      #|  WHERE
      #|    `a` = 1
      #|)
      #|SELECT
      #|  `f`.`a`,
      #|  `b`.`b`,
      #|  `baz`.`c`,
      #|  CAST(`b`.`a` AS FLOAT) AS `d`
      #|FROM `foo` AS `f`
      #|JOIN `bar` AS `b`
      #|  ON `f`.`a` = `b`.`a`
      #|LEFT JOIN `baz`
      #|  ON `f`.`a` = `baz`.`a`
    ),
  )
}
```

## Parsing and errors

`parse_one` returns the syntax tree (`Expr`) of a statement; `generate` turns it back into
SQL. Errors are `SqlglotError`s:

```mbt check
///|
test "parse, inspect and generate" {
  let ast : @sqlglot.Expr = @sqlglot.parse_one(
    "SELECT a, b + 1 AS c FROM t WHERE a > 1",
  )
  inspect(
    ast.find_all([Column]).map(c => c.name()).collect().join(", "),
    content="a, b, a",
  )
  inspect(
    @sqlglot.generate(ast, dialect="spark"),
    content="SELECT a, b + 1 AS c FROM t WHERE a > 1",
  )
}

///|
test "parse errors" {
  try @sqlglot.parse_one("SELECT foo FROM (SELECT baz FROM t") catch {
    @sqlglot.SqlglotError::ParseError(_, errors) => {
      let e = errors[0]
      inspect("\{e.description} at \{e.line}:\{e.col}", content="Expecting ) at 1:34")
    }
    _ => fail("expected a parse error")
  } noraise {
    _ => fail("expected a parse error")
  }
}
```

## Building queries

Builders take SQL strings or expressions; mixed arguments are passed as
`Array[&@sqlglot.IntoPy]`. Like Python, builder methods return a modified copy (pass
`copy=false` to modify in place), so several queries can be derived from one base:

```mbt check
///|
test "build queries" {
  let columns : Array[&@sqlglot.IntoPy] = [@sqlglot.column("a"), "b + 1 AS c"]
  let base = @sqlglot.select(columns).from_("t")
  let q1 = base.where_(["a > 1"])
  let conditions : Array[&@sqlglot.IntoPy] = [
    @sqlglot.condition("a < 0"),
    "c IS NOT NULL",
  ]
  let q2 = base
    .where_([@sqlglot.and_(conditions)])
    .order_by(["c"])
    .limit_(10)
  inspect(@sqlglot.generate(base), content="SELECT a, b + 1 AS c FROM t")
  inspect(@sqlglot.generate(q1), content="SELECT a, b + 1 AS c FROM t WHERE a > 1")
  inspect(
    @sqlglot.generate(q2),
    content="SELECT a, b + 1 AS c FROM t WHERE a < 0 AND NOT c IS NULL ORDER BY c LIMIT 10",
  )
  let x = @sqlglot.column("x").eq_(1).or_(["y = 2"])
  inspect(
    @sqlglot.generate(
      @sqlglot.select(["x"]).from_("tbl").where_([x]),
      dialect="duckdb",
    ),
    content="SELECT x FROM tbl WHERE x = 1 OR y = 2",
  )
}
```

## Optimizing

`optimize` qualifies, normalizes and simplifies a query given a schema:

```mbt check
///|
test "optimize" {
  let schema : Map[String, @sqlglot.SchemaNode] = {
    "x": Dict({
      "A": Type("INT"),
      "B": Type("INT"),
      "C": Type("INT"),
      "D": Type("INT"),
      "Z": Type("STRING"),
    }),
  }
  let optimized = @sqlglot.optimize(
    "SELECT A OR (B OR (C AND D)) FROM x WHERE Z = date '2021-01-01' + INTERVAL '1' month OR 1 = 0",
    schema~,
  )
  inspect(
    @sqlglot.generate(optimized, pretty=true),
    content=(
      #|SELECT
      #|  (
      #|    "x"."a" <> 0 OR "x"."b" <> 0 OR "x"."c" <> 0
      #|  )
      #|  AND (
      #|    "x"."a" <> 0 OR "x"."b" <> 0 OR "x"."d" <> 0
      #|  ) AS "_col_0"
      #|FROM "x" AS "x"
      #|WHERE
      #|  CAST("x"."z" AS DATE) = CAST('2021-02-01' AS DATE)
    ),
  )
}
```

## Executing

`execute` runs a query against in-memory tables (Python value semantics):

```mbt check
///|
test "execute" {
  let tables : Map[String, @sqlglot.TableData] = {
    "sushi": Records([[("id", Int(1)), ("price", Float(1.0))], [("id", Int(2)), ("price", Float(2.0))]]),
    "order_items": Records([
      [("sushi_id", Int(1)), ("order_id", Int(1))],
      [("sushi_id", Int(1)), ("order_id", Int(1))],
      [("sushi_id", Int(2)), ("order_id", Int(1))],
      [("sushi_id", Int(2)), ("order_id", Int(2))],
    ]),
    "orders": Records([
      [("id", Int(1)), ("user_id", Int(1))],
      [("id", Int(2)), ("user_id", Int(2))],
    ]),
  }
  let result : @sqlglot.Table = @sqlglot.execute(
    (
      #|SELECT o.user_id, SUM(s.price) AS price
      #|FROM orders o
      #|JOIN order_items i ON o.id = i.order_id
      #|JOIN sushi s ON i.sushi_id = s.id
      #|GROUP BY o.user_id
      #|ORDER BY o.user_id
    ),
    tables~,
  )
  inspect(result.columns.join(", "), content="user_id, price")
  inspect(
    result,
    content=(
      #|user_id price
      #|      1   4.0
      #|      2   2.0
    ),
  )
}
```
