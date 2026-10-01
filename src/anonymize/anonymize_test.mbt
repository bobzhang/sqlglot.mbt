// Port of tests/test_anonymize.py.

///|
fn token_triples(
  tokens : Array[@core.Token],
) -> Array[(String, String, Array[String])] {
  tokens.map(t => (t.token_type.name(), t.text, t.comments))
}

///|
/// `expected`: (TokenType name, text) for the full anonymized token stream; the
/// comments of every token are expected to be empty unless given in `comments`
/// as (token index, comments).
fn assert_anonymized(
  sql : String,
  expected : Array[(String, String)],
  dialect? : String = "",
  comments? : (Int, Array[String]),
) -> Unit raise {
  // Make sure the facade (which registers the dialects) is linked in.
  ignore(@sqlglot.dialect(dialect))
  let got = token_triples(@anonymize.anonymize(sql, dialect~))
  let want = expected.mapi((i, e) => {
    let c = match comments {
      Some((j, c)) if i == j => c
      _ => []
    }
    (e.0, e.1, c)
  })
  assert_eq(got, want)
}

///|
fn assert_rendered(
  sql : String,
  expected : String,
  dialect? : String = "",
) -> Unit raise {
  ignore(@sqlglot.dialect(dialect))
  let rendered = @anonymize.render(
    sql,
    @anonymize.anonymize(sql, dialect~),
    dialect~,
  )
  assert_eq(rendered, expected)
  assert_eq(rendered.to_array().length(), sql.to_array().length())
}

///|
test "identifiers rewritten" {
  assert_anonymized("SELECT foo FROM bar", [
    ("SELECT", "SELECT"),
    ("VAR", "aaa"), // foo
    ("FROM", "FROM"),
    ("VAR", "aab"), // bar
  ])
}

///|
test "consistent within call" {
  assert_anonymized("SELECT a, a, b FROM t", [
    ("SELECT", "SELECT"),
    ("VAR", "a"), // a
    ("COMMA", ","),
    ("VAR", "a"), // a, same alias as above
    ("COMMA", ","),
    ("VAR", "b"), // b
    ("FROM", "FROM"),
    ("VAR", "c"), // t
  ])
}

///|
test "quoted identifier shares alias" {
  assert_anonymized("SELECT foo, \"foo\"", [
    ("SELECT", "SELECT"),
    ("VAR", "aaa"),
    ("COMMA", ","),
    ("IDENTIFIER", "aaa"),
  ])
}

///|
test "strings rewritten" {
  assert_anonymized("SELECT 'hello', 'world' FROM t", [
    ("SELECT", "SELECT"),
    ("STRING", "aaaaa"), // hello
    ("COMMA", ","),
    ("STRING", "aaaab"), // world
    ("FROM", "FROM"),
    ("VAR", "c"), // t
  ])
}

///|
test "whitespace" {
  assert_anonymized(
    "SELECT 'line1\nline2', 'spam  eggs', 'a\tb', \"my table\" FROM t",
    [
      ("SELECT", "SELECT"),
      ("STRING", "aaaaa\naaaaa"), // line1 + newline + line2 (line break kept)
      ("COMMA", ","),
      ("STRING", "aaaa  aaab"), // spam  eggs (spaces kept)
      ("COMMA", ","),
      ("STRING", "a\tc"), // a\tb (tab kept)
      ("COMMA", ","),
      ("IDENTIFIER", "aa aaaad"), // "my table" (space kept)
      ("FROM", "FROM"),
      ("VAR", "e"), // t
    ],
  )
}

///|
test "reserved keywords not rewritten" {
  // keyword tokens (e.g. window, out) aren't sensitive; they stay verbatim
  assert_anonymized("SELECT * FROM window, OUT, apple", [
    ("SELECT", "SELECT"),
    ("STAR", "*"),
    ("FROM", "FROM"),
    ("WINDOW", "window"),
    ("COMMA", ","),
    ("OUT", "OUT"),
    ("COMMA", ","),
    ("VAR", "aaaaa"), // apple
  ])
}

///|
test "tokenize error tail blanked" {
  let tokens = @anonymize.anonymize("SELECT foo, 'secret tail")
  assert_eq(tokens.map(t => (t.token_type.name(), t.text)), [
    ("SELECT", "SELECT"),
    ("VAR", "aaa"), // foo
    ("COMMA", ","),
    ("UNKNOWN", "'s.........."), // 'secret tail, delimiter kept
  ])
}

///|
test "comments redacted" {
  assert_anonymized(
    "SELECT a -- secret comment\nFROM t",
    [("SELECT", "SELECT"), ("VAR", "a"), ("FROM", "FROM"), ("VAR", "b")],
    comments=(1, [" ...... ......."]),
  )
}

///|
test "tpcds query reserialized" {
  let sql =
    #|WITH inv
    #|     AS (SELECT w_warehouse_name,
    #|                w_warehouse_sk,
    #|                i_item_sk,
    #|                d_moy,
    #|                stdev,
    #|                mean,
    #|                CASE mean
    #|                  WHEN 0 THEN NULL
    #|                  ELSE stdev / mean
    #|                END cov
    #|         FROM  (SELECT w_warehouse_name,
    #|                       w_warehouse_sk,
    #|                       i_item_sk,
    #|                       d_moy,
    #|                       Stddev_samp(inv_quantity_on_hand) stdev,
    #|                       Avg(inv_quantity_on_hand)         mean
    #|                FROM   inventory,
    #|                       item,
    #|                       warehouse,
    #|                       date_dim
    #|                WHERE  inv_item_sk = i_item_sk
    #|                       AND inv_warehouse_sk = w_warehouse_sk
    #|                       AND inv_date_sk = d_date_sk
    #|                       AND d_year = 2002
    #|                GROUP  BY w_warehouse_name,
    #|                          w_warehouse_sk,
    #|                          i_item_sk,
    #|                          d_moy) foo
    #|         WHERE  CASE mean
    #|                  WHEN 0 THEN 0
    #|                  ELSE stdev / mean
    #|                END > 1)
    #|SELECT inv1.w_warehouse_sk,
    #|       inv1.i_item_sk,
    #|       inv1.d_moy,
    #|       inv1.mean,
    #|       inv1.cov,
    #|       inv2.w_warehouse_sk,
    #|       inv2.i_item_sk,
    #|       inv2.d_moy,
    #|       inv2.mean,
    #|       inv2.cov
    #|FROM   inv inv1,
    #|       inv inv2
    #|WHERE  inv1.i_item_sk = inv2.i_item_sk
    #|       AND inv1.w_warehouse_sk = inv2.w_warehouse_sk
    #|       AND inv1.d_moy = 1
    #|       AND inv2.d_moy = 1 + 1
    #|ORDER  BY inv1.w_warehouse_sk,
    #|          inv1.i_item_sk,
    #|          inv1.d_moy,
    #|          inv1.mean,
    #|          inv1.cov,
    #|          inv2.d_moy,
    #|          inv2.mean,
    #|          inv2.cov;
  let expected =
    #|WITH aaa
    #|     AS (SELECT aaaaaaaaaaaaaaab,
    #|                aaaaaaaaaaaaac,
    #|                aaaaaaaad,
    #|                aaaae,
    #|                aaaaf,
    #|                aaag,
    #|                CASE aaag
    #|                  WHEN 8 THEN NULL
    #|                  ELSE aaaaf / aaag
    #|                END aai
    #|         FROM  (SELECT aaaaaaaaaaaaaaab,
    #|                       aaaaaaaaaaaaac,
    #|                       aaaaaaaad,
    #|                       aaaae,
    #|                       Stddev_samp(aaaaaaaaaaaaaaaaaaaj) aaaaf,
    #|                       Avg(aaaaaaaaaaaaaaaaaaaj)         aaag
    #|                FROM   aaaaaaaak,
    #|                       aaal,
    #|                       aaaaaaaam,
    #|                       aaaaaaan
    #|                WHERE  aaaaaaaaaao = aaaaaaaad
    #|                       AND aaaaaaaaaaaaaaap = aaaaaaaaaaaaac
    #|                       AND aaaaaaaaaaq = aaaaaaaar
    #|                       AND aaaaas = 1019
    #|                GROUP  BY aaaaaaaaaaaaaaab,
    #|                          aaaaaaaaaaaaac,
    #|                          aaaaaaaad,
    #|                          aaaae) aau
    #|         WHERE  CASE aaag
    #|                  WHEN 8 THEN 8
    #|                  ELSE aaaaf / aaag
    #|                END > 4)
    #|SELECT aaaw.aaaaaaaaaaaaac,
    #|       aaaw.aaaaaaaad,
    #|       aaaw.aaaae,
    #|       aaaw.aaag,
    #|       aaaw.aai,
    #|       aaax.aaaaaaaaaaaaac,
    #|       aaax.aaaaaaaad,
    #|       aaax.aaaae,
    #|       aaax.aaag,
    #|       aaax.aai
    #|FROM   aaa aaaw,
    #|       aaa aaax
    #|WHERE  aaaw.aaaaaaaad = aaax.aaaaaaaad
    #|       AND aaaw.aaaaaaaaaaaaac = aaax.aaaaaaaaaaaaac
    #|       AND aaaw.aaaae = 4
    #|       AND aaax.aaaae = 4 + 4
    #|ORDER  BY aaaw.aaaaaaaaaaaaac,
    #|          aaaw.aaaaaaaad,
    #|          aaaw.aaaae,
    #|          aaaw.aaag,
    #|          aaaw.aai,
    #|          aaax.aaaae,
    #|          aaax.aaag,
    #|          aaax.aai;
  assert_rendered(sql, expected)
}

///|
test "functions anonymized" {
  assert_anonymized(
    "SELECT SUM(x), my_udf(...), CURRENT_DATE, CASE WHEN 1 THEN 2 ELSE 3 END",
    [
      ("SELECT", "SELECT"),
      ("VAR", "SUM"), // known function — kept
      ("L_PAREN", "("),
      ("VAR", "a"), // x
      ("R_PAREN", ")"),
      ("COMMA", ","),
      ("VAR", "aaaaab"), // my_udf (unknown) — masked
      ("L_PAREN", "("),
      ("DOT", "."),
      ("DOT", "."),
      ("DOT", "."),
      ("R_PAREN", ")"),
      ("COMMA", ","),
      ("CURRENT_DATE", "CURRENT_DATE"), // no-paren function — kept
      ("COMMA", ","),
      ("CASE", "CASE"), // keyword — kept
      ("WHEN", "WHEN"),
      ("NUMBER", "3"), // 1
      ("THEN", "THEN"),
      ("NUMBER", "4"), // 2
      ("ELSE", "ELSE"),
      ("NUMBER", "5"), // 3
      ("END", "END"),
    ],
  )

  // JSON_OBJECT is registered in FUNCTION_PARSERS rather than FUNCTIONS
  assert_anonymized("SELECT JSON_OBJECT('k', v)", [
    ("SELECT", "SELECT"),
    ("VAR", "JSON_OBJECT"), // known function — kept
    ("L_PAREN", "("),
    ("STRING", "a"), // 'k'
    ("COMMA", ","),
    ("VAR", "b"), // v
    ("R_PAREN", ")"),
  ])
}

///|
test "string family forms anonymized" {
  assert_anonymized(
    "SELECT N'nat', $$her$$, x'4141'",
    [
      ("SELECT", "SELECT"),
      ("NATIONAL_STRING", "aaa"),
      ("COMMA", ","),
      ("RAW_STRING", "aab"),
      ("COMMA", ","),
      ("HEX_STRING", "aaac"),
    ],
    dialect="snowflake",
  )
}

///|
test "empty input" {
  assert_eq(@anonymize.anonymize("").length(), 0)
  assert_eq(@anonymize.anonymize("   ").length(), 0)
}

///|
test "identifiers with spaces stay distinct" {
  assert_anonymized("SELECT \"a b\", \"a c\"", [
    ("SELECT", "SELECT"),
    ("IDENTIFIER", "a a"),
    ("COMMA", ","),
    ("IDENTIFIER", "a b"),
  ])
}

///|
test "number and string same text stay distinct" {
  assert_anonymized("SELECT 123, '123'", [
    ("SELECT", "SELECT"),
    ("NUMBER", "100"),
    ("COMMA", ","),
    ("STRING", "aab"),
  ])
}

///|
test "comments blanked in reserialization" {
  assert_rendered(
    "SELECT a -- secret comment\nFROM t", "SELECT a -- ...... .......\nFROM b",
  )
}

///|
test "huge numeric literal no crash" {
  let tokens = @anonymize.anonymize("SELECT " + "1".repeat(4500))
  assert_true(tokens[1].token_type is NUMBER)
  assert_eq(tokens[1].text.length(), 4500)
}

///|
test "athena known function kept" {
  assert_rendered(
    "SELECT LISTAGG(x, ',') WITHIN GROUP (ORDER BY x) FROM t",
    "SELECT LISTAGG(a, 'b') aaaaac aaaad (ORDER BY a) FROM e",
    dialect="athena",
  )
}

///|
test "known function kept when passing tokens" {
  let tokens = @anonymize.anonymize_tokens(
    @sqlglot.dialect("snowflake").tokenize("SELECT TO_VARIANT(x) FROM t"),
    dialect="snowflake",
  )
  assert_eq(tokens.map(t => (t.token_type.name(), t.text)), [
    ("SELECT", "SELECT"),
    ("VAR", "TO_VARIANT"), // dialect-specific known function — kept
    ("L_PAREN", "("),
    ("VAR", "a"), // x
    ("R_PAREN", ")"),
    ("FROM", "FROM"),
    ("VAR", "b"), // t
  ])
}

///|
test "known function comment still blanked" {
  assert_anonymized(
    "SELECT sum/* secretpassword */(x)",
    [
      ("SELECT", "SELECT"),
      ("VAR", "sum"),
      ("L_PAREN", "("),
      ("VAR", "a"), // x
      ("R_PAREN", ")"),
    ],
    comments=(1, [" .............. "]),
  )
}

///|
test "quotes preserved" {
  // the alias is fitted between the quotes of the source span, so a literal stays a
  // literal of the same kind and width instead of collapsing to a bare word
  let cases = [
    ("SELECT 'hello' AS x", "SELECT 'aaaaa' AS b", ""),
    ("SELECT 'a''b'", "SELECT 'aaaa'", ""), // the escape is content, so it's masked
    ("SELECT ''", "SELECT ''", ""),
    ("SELECT N'nat', x'4141'", "SELECT N'aaa', x'aaab'", "snowflake"),
    ("SELECT \"my table\"", "SELECT \"aa aaaaa\"", ""),
    ("SELECT `back tick`", "SELECT `aaaa aaaa`", "mysql"),
    ("SELECT [brack et]", "SELECT [aaaaa aa]", "tsql"),
    (
      "SELECT $$her$$, $tag$body$tag$", "SELECT $$aaa$$, $tag$aaab$tag$", "postgres",
    ),
  ]
  for c in cases {
    assert_rendered(c.0, c.1, dialect=c.2)
  }
}

///|
test "source spelling preserved" {
  // tokens that aren't anonymized are rendered over their own span, so the spelling
  // the tokenizer normalized away (GROUP  BY -> GROUP BY) survives
  let cases = [
    ("SELECT a FROM t GROUP  BY a", "SELECT a FROM b GROUP  BY a"),
    ("SELECT a ORDER   BY a", "SELECT a ORDER   BY a"),
    ("select * from window, OUT", "select * from window, OUT"),
  ]
  for c in cases {
    assert_rendered(c.0, c.1)
  }
}

///|
test "numbers keep their shape" {
  assert_rendered(
    "SELECT 1e, 1.e, 1e10, .5, 2002, 1e-5, 1E+2", "SELECT 1e, 2.e, 3e10, .4, 1004, 6e-1, 7E+1",
  )
}

///|
test "hints anonymized" {
  // a hint's text is the whole /*+ ... */ comment, whether the tokenizer emits it as a
  // HINT token (only in hint position) or leaves it in the gap as a plain comment
  let cases = [
    (
      "SELECT /*+ INDEX(customers ssn_idx) */ a FROM t", "SELECT /*+ ............... ........ */ a FROM b",
      "",
    ),
    (
      "SELECT /*+ BROADCAST(`y`) */ x FROM y", "SELECT /*+ .............. */ a FROM b",
      "spark",
    ),
    (
      "INSERT /*+ APPEND */ INTO t VALUES (1)", "INSERT /*+ ...... */ INTO a VALUES (2)",
      "oracle",
    ),
    ("SELECT a /*+ INDEX(secret) */ b", "SELECT a /*+ ............. */ b", ""),
    (
      "SELECT /*+ INDEX(customers)\n           MORE(ssn) */ a FROM t", "SELECT /*+ ................\n           ......... */ a FROM b",
      "",
    ),
  ]
  for c in cases {
    assert_rendered(c.0, c.1, dialect=c.2)
  }
}

///|
test "hint does not desync following comments" {
  // a hint's body is recorded in Token.comments but its marker isn't left in a gap, so
  // pairing gap markers with recorded bodies drifts and copies the source through
  assert_rendered(
    "SELECT /*+ x */ a -- password is hunter2\nFROM t", "SELECT /*+ . */ a -- ........ .. .......\nFROM b",
  )
}

///|
test "comments without tokens" {
  // nothing for the tokenizer to attach the comment to
  let cases = [
    ("-- top secret", "-- ... ......"),
    ("/* COMMENT */", "/* ....... */"),
    ("/*", "/*"),
  ]
  for c in cases {
    assert_rendered(c.0, c.1)
  }
}

///|
test "tokenize error keeps delimiter" {
  // the two leading characters survive so the delimiter the tokenizer choked on is
  // still identifiable - an unterminated string reads differently to a comment
  let cases = [
    ("SELECT a, 'unterminated string", "SELECT a, 'u..................", ""),
    (
      "SELECT a, /* unterminated comment", "SELECT a, /*.....................", "",
    ),
    ("SELECT a, \"unterminated ident", "SELECT a, \"u.................", ""),
    (
      "SELECT a, $$unterminated heredoc", "SELECT a, $$....................", "postgres",
    ),
    (
      "SELECT a, `unterminated backtick", "SELECT a, `u....................", "mysql",
    ),
    ("'unterminated secret", "'u..................", ""), // nothing tokenized at all
    ("SELECT a, '", "SELECT a, '", ""), // remainder shorter than the delimiter
  ]
  for c in cases {
    assert_rendered(c.0, c.1, dialect=c.2)
  }
}

///|
test "comment bodies fully blanked" {
  // markers inside a comment body are body, not structure, so they're blanked too
  let cases = [
    ("SELECT a /* x /* nested */ y */ b", "SELECT a /* . .. ...... .. . */ b"),
    (
      "SELECT a -- /* not a real block\nFROM t", "SELECT a -- .. ... . .... .....\nFROM b",
    ),
  ]
  for c in cases {
    assert_rendered(c.0, c.1)
  }
}

///|
test "render without dialect still redacts" {
  // an unrecognized marker costs readability, never redaction
  let sql = "SELECT a # secret"
  ignore(@sqlglot.dialect("mysql"))
  assert_eq(
    @anonymize.render(
      sql,
      @anonymize.anonymize(sql, dialect="mysql"),
      dialect="mysql",
    ),
    "SELECT a # ......",
  )
  assert_eq(
    @anonymize.render(sql, @anonymize.anonymize(sql, dialect="mysql")),
    "SELECT a . ......",
  )
}

///|
test "render" {
  let cases = [
    ("", "", ""),
    (" \t\n", " \t\n", ""),
    ("-- leading secret\nSELECT foo", "-- ....... ......\nSELECT aaa", ""),
    (
      "SELECT /* hidden value */ foo -- trailing secret", "SELECT /* ...... ..... */ aaa -- ........ ......",
      "",
    ),
    (
      "SELECT foo /* first */ /* second */ FROM bar", "SELECT aaa /* ..... */ /* ...... */ FROM aab",
      "",
    ),
    ("SELECT foo, 'secret tail", "SELECT aaa, 's..........", ""),
    ("SELECT foo // secret", "SELECT aaa // ......", "snowflake"),
    ("SELECT foo # secret", "SELECT aaa # ......", "mysql"),
  ]
  for c in cases {
    assert_rendered(c.0, c.1, dialect=c.2)
  }
}
