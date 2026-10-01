// Black-box tests of the base Generator built from hand-constructed ASTs.
// (Large conformance suites live in src/generator_tests.)

///|
fn col(name : String) -> @core.Expr {
  @core.mk1(@core.Column, @core.to_identifier(name))
}

///|
fn gen(
  e : @core.Expr,
  pretty? : Bool = false,
) -> String raise @core.SqlglotError {
  @core.Generator::new(@core.base_dialect(), pretty~).generate(e)
}

///|
test "generator: simple select" {
  let select = @core.mk(@core.Select, [
    (
      "expressions",
      [col("a"), @core.mk2(@core.Add, col("b"), @core.literal_int(1))],
    ),
    (
      "from_",
      @core.mk1(@core.From, @core.mk1(@core.Table, @core.to_identifier("t"))),
    ),
    (
      "where",
      @core.mk1(
        @core.Where,
        @core.mk2(@core.EQ, col("a"), @core.literal_string("x'y")),
      ),
    ),
  ])
  inspect(gen(select), content="SELECT a, b + 1 FROM t WHERE a = 'x''y'")
  inspect(
    gen(select, pretty=true),
    content=(
      #|SELECT
      #|  a,
      #|  b + 1
      #|FROM t
      #|WHERE
      #|  a = 'x''y'
    ),
  )
}

///|
test "generator: functions, casts and identifiers" {
  let e = @core.mk(@core.Cast, [
    (
      "this",
      @core.mk1(
        @core.Upper,
        @core.mk1(@core.Column, @core.to_identifier("a\"b", quoted=true)),
      ),
    ),
    ("to", @core.datatype_of(@core.DType::NVARCHAR)),
  ])
  inspect(gen(e), content="CAST(UPPER(\"a\"\"b\") AS VARCHAR)")
  let anon = @core.mk(@core.Anonymous, [
    ("this", ("my_func" : &@core.IntoValue)),
    ("expressions", [@core.literal_int(1), @core.null_()]),
  ])
  inspect(gen(anon), content="MY_FUNC(1, NULL)")
  inspect(
    @core.Generator::new(@core.base_dialect(), identify="always").generate(
      col("a"),
    ),
    content="\"a\"",
  )
}

///|
test "generator: dialect overrides via transforms, methods and hooks" {
  let d = @core.Dialect::subclass(@core.base_dialect(), "custom", d => {
    // TRANSFORMS entry
    d.gen_fns.transforms[@core.Upper] = (g, e) => {
      g.func("UCASE", [e.get("this")])
    }
    // `<key>_sql` method override, also used by virtual calls (pseudocolumn_sql)
    d.gen_fns.methods[@core.Column] = (g, e) => "[" + g.column_sql(e) + "]"
    // `_sql` method with extra parameters
    d.gen_fns.hooks.cast_sql = Some((g, e, prefix) => {
      let p = match prefix {
        Some(p) => p
        None => ""
      }
      "<" + p + ">" + g.cast_sql(e)
    })
  })
  let g = @core.Generator::new(d)
  inspect(g.generate(@core.mk1(@core.Upper, col("x"))), content="UCASE([x])")
  inspect(
    g.generate(@core.mk1(@core.Pseudocolumn, @core.to_identifier("rownum"))),
    content="[rownum]",
  )
  let try_cast = @core.mk(@core.TryCast, [
    ("this", col("x")),
    ("to", @core.datatype_of(@core.DType::INT)),
  ])
  inspect(g.generate(try_cast), content="<TRY_>CAST([x] AS INT)")
}

///|
test "generator: unsupported messages" {
  let d = @core.base_dialect()
  let lock = @core.mk(@core.Lock, [("update", true)])
  let select = @core.mk(@core.Select, [
    ("expressions", [col("a")]),
    ("locks", [lock]),
  ])
  let g = @core.Generator::new(d, unsupported_level=Ignore)
  inspect(g.generate(select), content="SELECT a")
  inspect(
    g.unsupported_messages.join("|"),
    content="Locking reads using 'FOR UPDATE/SHARE' are not supported",
  )
  let g = @core.Generator::new(d, unsupported_level=Raise)
  try g.generate(select) catch {
    err =>
      inspect(
        err,
        content="UnsupportedError: Locking reads using 'FOR UPDATE/SHARE' are not supported",
      )
  } noraise {
    _ => fail("expected to fail")
  }
}
