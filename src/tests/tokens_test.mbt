///|
test "tokenizer matches python on identity fixtures" {
  let settings = @core.base_tokenizer_settings_raw().finalize()
  let mut failures = 0
  let mut i = 0
  while i < token_fixtures.length() {
    let sql = token_fixtures[i]
    let expected = token_fixtures[i + 1]
    i += 2
    let tokens = @core.Tokenizer::new(settings).tokenize(sql) catch {
      e => {
        failures += 1
        println("ERR \{sql}: \{e}")
        continue
      }
    }
    let digest = tokens
      .map(t => {
        let c = if t.comments.is_empty() {
          ""
        } else {
          "#\{t.comments.length()}"
        }
        "\{t.token_type.name()}:\{t.text}@\{t.line},\{t.col},\{t.start},\{t.end}\{c}"
      })
      .join(" ")
    if digest != expected {
      failures += 1
      if failures < 10 {
        println("MISMATCH \{sql}\n  got: \{digest}\n  exp: \{expected}")
      }
    }
  }
  inspect(failures, content="0")
}
