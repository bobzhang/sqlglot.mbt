// Port of tests/test_tokens.py

///|
/// Python `Tokenizer()` (the base dialect's tokenizer).
fn base_tokenizer() -> @core.Tokenizer {
  @core.Tokenizer::new(@core.base_dialect().tokenizer)
}

///|
fn tokenize(sql : String) -> Array[@core.Token] raise {
  base_tokenizer().tokenize(sql)
}

///|
/// `[(token.token_type, token.text) for token in tokens]`
fn types_and_texts(tokens : Array[@core.Token]) -> Array[(String, String)] {
  tokens.map(t => (t.token_type.name(), t.text))
}

///|
test "TestTokens.test_space_keywords" {
  for
    case in [
      ("group bys", 2),
      (" group bys", 2),
      (" group bys ", 2),
      ("group by)", 2),
      ("group bys)", 3),
      ("group \r", 1),
    ] {
    let (string, length) = case
    let tokens = tokenize(string)
    assert_true(tokens[0].text.to_upper().contains("GROUP"))
    assert_eq(tokens.length(), length)
  }
}

///|
test "TestTokens.test_comment_attachment" {
  let tokenizer = base_tokenizer()
  let sql_comment : Array[(String, Array[String])] = [
    ("/*comment*/ foo", ["comment"]),
    ("/*comment*/ foo --test", ["comment", "test"]),
    ("--comment\nfoo --test", ["comment", "test"]),
    ("foo --comment", ["comment"]),
    ("foo", []),
    ("foo /*comment 1*/ /*comment 2*/", ["comment 1", "comment 2"]),
    ("foo\n-- comment", [" comment"]),
    ("1 /*/2 */", ["/2 "]),
    ("1\n/*comment*/;", ["comment"]),
  ]
  for case in sql_comment {
    let (sql, comment) = case
    assert_eq(tokenizer.tokenize(sql)[0].comments, comment)
  }
}

///|
test "TestTokens.test_token_line_col" {
  let tokens = tokenize(
    (
      #|SELECT /*
      #|line break
      #|*/
      #|'x
      #| y',
      #|x
    ),
  )
  assert_eq(tokens[0].line, 1)
  assert_eq(tokens[0].col, 6)
  assert_eq(tokens[1].line, 5)
  assert_eq(tokens[1].col, 3)
  assert_eq(tokens[2].line, 5)
  assert_eq(tokens[2].col, 4)
  assert_eq(tokens[3].line, 6)
  assert_eq(tokens[3].col, 1)
  let tokens = tokenize("SELECT .")
  assert_eq(tokens[1].line, 1)
  assert_eq(tokens[1].col, 8)
  assert_eq(tokenize("'''abc'")[0].start, 0)
  assert_eq(tokenize("'''abc'")[0].end, 6)
  assert_eq(tokenize("'abc'")[0].start, 0)
  let tokens = tokenize("SELECT\r\n  1,\r\n  2")
  assert_eq(tokens[0].line, 1)
  assert_eq(tokens[0].col, 6)
  assert_eq(tokens[1].line, 2)
  assert_eq(tokens[1].col, 3)
  assert_eq(tokens[2].line, 2)
  assert_eq(tokens[2].col, 4)
  assert_eq(tokens[3].line, 3)
  assert_eq(tokens[3].col, 3)
  let tokens = tokenize("  SELECT\n    100")
  assert_eq(tokens[0].line, 1)
  assert_eq(tokens[0].col, 8)
  assert_eq(tokens[1].line, 2)
  assert_eq(tokens[1].col, 7)
}

///|
test "TestTokens.test_crlf" {
  let tokens = types_and_texts(tokenize("SELECT a\r\nFROM b"))
  assert_eq(tokens, [
    ("SELECT", "SELECT"),
    ("VAR", "a"),
    ("FROM", "FROM"),
    ("VAR", "b"),
  ])
  for simple_query in ["SELECT 1\r\n", "\r\nSELECT 1"] {
    let tokens = types_and_texts(tokenize(simple_query))
    assert_eq(tokens, [("SELECT", "SELECT"), ("NUMBER", "1")])
  }
}

///|
test "TestTokens.test_command" {
  let tokens = tokenize("SHOW;")
  assert_eq(tokens[0].token_type.name(), "SHOW")
  assert_eq(tokens[1].token_type.name(), "SEMICOLON")
  let tokens = tokenize("EXECUTE")
  assert_eq(tokens[0].token_type.name(), "EXECUTE")
  assert_eq(tokens.length(), 1)
  let tokens = tokenize("FETCH;SHOW;")
  assert_eq(tokens[0].token_type.name(), "FETCH")
  assert_eq(tokens[1].token_type.name(), "SEMICOLON")
  assert_eq(tokens[2].token_type.name(), "SHOW")
  assert_eq(tokens[3].token_type.name(), "SEMICOLON")
}

///|
test "TestTokens.test_error_msg" {
  let sql = "select /*"
  try tokenize(sql) catch {
    @core.TokenError(msg) =>
      // assertRaisesRegex(TokenError, "Error tokenizing 'select /'")
      assert_true(msg.contains("Error tokenizing 'select /'"))
    // SKIP: `sql[e.start:e.end] == "select /"` -- the port's TokenError carries
    // only the message (no structured start/end offsets).
    e => fail("expected TokenError, got \{e}")
  } noraise {
    _ => fail("expected TokenError")
  }
}

///|
test "TestTokens.test_jinja" {
  // Check that {#, #} are treated as token delimiters, even though BigQuery overrides COMMENTS
  let bigquery = @sqlglot.dialect("bigquery")
  let tokens = bigquery.tokenize(
    (
      #|
      #|            SELECT
      #|               {{ x }},
      #|               {{- x -}},
      #|               {# it's a comment #}
      #|               {% for x in y -%}
      #|               a {{+ b }}
      #|               {% endfor %};
      #|
    ),
  )
  assert_eq(types_and_texts(tokens), [
    ("SELECT", "SELECT"),
    ("L_BRACE", "{"),
    ("L_BRACE", "{"),
    ("VAR", "x"),
    ("R_BRACE", "}"),
    ("R_BRACE", "}"),
    ("COMMA", ","),
    ("BLOCK_START", "{{-"),
    ("VAR", "x"),
    ("BLOCK_END", "-}}"),
    ("COMMA", ","),
    ("BLOCK_START", "{%"),
    ("FOR", "for"),
    ("VAR", "x"),
    ("IN", "in"),
    ("VAR", "y"),
    ("BLOCK_END", "-%}"),
    ("VAR", "a"),
    ("BLOCK_START", "{{+"),
    ("VAR", "b"),
    ("R_BRACE", "}"),
    ("R_BRACE", "}"),
    ("BLOCK_START", "{%"),
    ("VAR", "endfor"),
    ("BLOCK_END", "%}"),
    ("SEMICOLON", ";"),
  ])
  let tokens = bigquery.tokenize("'{{ var('x') }}'")
  assert_eq(types_and_texts(tokens), [
    ("STRING", "{{ var("),
    ("VAR", "x"),
    ("STRING", ") }}"),
  ])
}

///|
test "TestTokens.test_partial_token_list" {
  let tokenizer = base_tokenizer()
  // This is expected to fail due to the unbalanced string quotes
  try tokenizer.tokenize("foo 'bar") catch {
    @core.TokenError(msg) =>
      assert_true(msg.contains("Error tokenizing 'foo 'ba'"), msg~)
    e => fail("expected TokenError, got \{e}")
  } noraise {
    _ => ()
  }
  let partial_tokens = tokenizer.tokens
  assert_eq(partial_tokens.length(), 1)
  assert_eq(partial_tokens[0].token_type.name(), "VAR")
  assert_eq(partial_tokens[0].text, "foo")
}

///|
test "TestTokens.test_unicode_identifiers" {
  let tokens = tokenize("SELECT café FROM t")
  let v = tokens.iter().find_first(t => t.token_type.name() == "VAR").unwrap()
  assert_eq(v.text, "café")
}

///|
test "TestTokens.test_token_repr" {
  // Ensures both the Python and the Rust tokenizer produce a human-friendly representation
  assert_eq(
    tokenize("foo").to_string(),
    "[<Token token_type: TokenType.VAR, text: foo, line: 1, col: 3, start: 0, end: 2, comments: []>]",
  )
}
