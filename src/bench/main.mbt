// Scaling benchmarks for adversarial query shapes (not part of `moon test`).
//
//   moon run src/bench --release [--target native] [-- <case-filter> [<op-filter>]]
//
// For every case and operation the input size doubles; the time per run and the ratio to
// the previous size are printed (about 2x per doubling is linear, about 4x quadratic).
// A size whose run exceeds the time budget stops that operation. Deep shapes may hit the
// host stack limit; run them one at a time (`-- nested_parens`) to isolate a crash.

///|
/// Stop growing an operation once one run takes longer than this (microseconds).
let budget_us : Double = 2000000.0

///|
/// Repeat fast operations until this much time has been measured (microseconds).
let min_total_us : Double = 50000.0

///|
fn time_op(f : () -> Unit raise) -> Double raise {
  let mut runs = 0
  let mut total = 0.0
  while runs == 0 || (total < min_total_us && runs < 1000) {
    let t = @timing.monotonic_clock_start()
    f()
    total += @timing.monotonic_clock_end(t)
    runs += 1
  }
  total / runs.to_double()
}

///|
fn run_op(op : String, sql : String, parsed : @core.Expr) -> Unit raise {
  match op {
    "parse" => ignore(@sqlglot.parse(if sql == "" { gen(parsed) } else { sql }))
    "generate" => ignore(@sqlglot.generate(parsed))
    "pretty" => ignore(@sqlglot.generate(parsed, pretty=true))
    "copy" => ignore(parsed.copy())
    "simplify" => ignore(@optimizer.simplify(parsed.copy()))
    "optimize" => ignore(@optimizer.optimize(parsed.copy()))
    "qualify" => ignore(@optimizer.qualify(parsed.copy()))
    _ => fail("unknown op \{op}")
  }
}

///|
let rule_names : Array[String] = [
  "qualify", "pushdown_projections", "normalize", "unnest_subqueries", "pushdown_predicates",
  "optimize_joins", "eliminate_subqueries", "merge_subqueries", "eliminate_joins",
  "eliminate_ctes", "quote_identifiers", "annotate_types", "canonicalize", "simplify",
]

///|
/// Times each default optimizer rule on `parsed` (applied in sequence, one run each).
fn time_rules(name : String, n : Int, parsed : @core.Expr) -> Unit raise {
  let mut prefix = 0.0
  for i in 0..<@optimizer.rules.length() {
    let rules = @optimizer.rules[:i + 1].to_owned()
    let t = @timing.monotonic_clock_start()
    ignore(@optimizer.optimize(parsed.copy(), rules~))
    let total = @timing.monotonic_clock_end(t)
    println(
      "\{name}\trule:\{rule_names[i]}\t\{n}\t\{fmt_ms(total - prefix)}\t-",
    )
    prefix = total
  }
}

///|
/// Times the steps of `qualify` on `parsed` (one run each).
fn time_qualify_steps(
  name : String,
  n : Int,
  parsed : @core.Expr,
) -> Unit raise {
  let schema = @optimizer.MappingSchema::new()
  let mut e = parsed.copy()
  let step = (label : String, f : () -> @core.Expr raise) => {
    let t = @timing.monotonic_clock_start()
    e = f()
    println(
      "\{name}\tqualify:\{label}\t\{n}\t\{fmt_ms(@timing.monotonic_clock_end(t))}\t-",
    )
  }
  step("traverse_scope", () => {
    ignore(@optimizer.traverse_scope(e))
    e
  })
  step("normalize_identifiers", () => @optimizer.normalize_identifiers(e))
  step("qualify_tables", () => @optimizer.qualify_tables(e))
  step("qualify_columns", () => @optimizer.qualify_columns(e, schema))
  step("quote_identifiers", () => @optimizer.quote_identifiers(e))
  step("validate", () => @optimizer.validate_qualify_columns(e))
}

///|
fn gen(e : @core.Expr) -> String raise {
  @sqlglot.generate(e)
}

///|
fn first_statement(sql : String) -> @core.Expr raise {
  match @sqlglot.parse(sql) {
    [Some(e), ..] => e
    _ => fail("no statement")
  }
}

///|
fn fmt_ms(us : Double) -> String {
  let ms = us / 1000.0
  let r = (ms * 100.0).round() / 100.0
  r.to_string()
}

///|
fn fmt_ratio(r : Double) -> String {
  ((r * 10.0).round() / 10.0).to_string()
}

///|
fn main {
  let args = @env.args()
  // `moon run` passes the program name first; filters follow
  let filters = args.filter(a => {
    !a.has_suffix(".wasm") && !a.has_suffix(".exe") && !a.contains("/")
  })
  let case_filter = filters.get(0).unwrap_or("")
  let op_filter = filters.get(1).unwrap_or("")
  // an optional third argument runs a single size
  let only_size = match filters.get(2) {
    Some(s) => @string.parse_int(s) catch { _ => 0 }
    None => 0
  }
  let flagged : Array[String] = []
  println("case\top\tn\tms/run\tratio")
  for c in cases {
    if case_filter != "" && c.name != case_filter {
      continue
    }
    for
      op in (if op_filter is ("rules" | "qualify" | "qualify_steps") {
        [op_filter]
      } else {
        c.ops
      }) {
      if op_filter != "" && op != op_filter {
        continue
      }
      let mut prev : Double? = None
      let mut last_ratio = 0.0
      for n in (if only_size > 0 { [only_size] } else { c.sizes }) {
        let sql = (c.sql)(n)
        let parsed = try {
          match c.build {
            Some(b) => b(n)
            None => first_statement(sql)
          }
        } catch {
          e => {
            println("\{c.name}\t\{op}\t\{n}\terror\t\{e}")
            break
          }
        }
        if op == "qualify_steps" {
          time_qualify_steps(c.name, n, parsed) catch {
            e => println("\{c.name}\tqualify_steps\t\{n}\terror\t\{e}")
          }
          continue
        }
        if op == "rules" {
          time_rules(c.name, n, parsed) catch {
            e => println("\{c.name}\trules\t\{n}\terror\t\{e}")
          }
          continue
        }
        let us = time_op(() => run_op(op, sql, parsed)) catch {
          e => {
            println("\{c.name}\t\{op}\t\{n}\terror\t\{e}")
            break
          }
        }
        let ratio = match prev {
          Some(p) if p > 0.0 => us / p
          _ => 0.0
        }
        println(
          "\{c.name}\t\{op}\t\{n}\t\{fmt_ms(us)}\t\{if ratio > 0.0 { fmt_ratio(ratio) } else { "-" }}",
        )
        prev = Some(us)
        last_ratio = ratio
        if us > budget_us {
          break
        }
      }
      println("\{c.name}\t\{op}\tdone")
      // Ratios are noisy for tiny timings; flag only clear growth on measurable sizes.
      if last_ratio > 3.0 && prev.unwrap_or(0.0) > 5000.0 {
        flagged.push("\{c.name}/\{op} (x\{fmt_ratio(last_ratio)} per doubling)")
      }
    }
  }
  println("")
  if flagged.is_empty() {
    println("no super-linear growth flagged")
  } else {
    println("super-linear:")
    for f in flagged {
      println("  \{f}")
    }
  }
}
