// Port of sqlglot/parsers/teradata.py

///|
let charset_translators : Array[String] = [
  "GRAPHIC_TO_KANJISJIS", "GRAPHIC_TO_LATIN", "GRAPHIC_TO_UNICODE", "GRAPHIC_TO_UNICODE_PadSpace",
  "KANJI1_KanjiEBCDIC_TO_UNICODE", "KANJI1_KanjiEUC_TO_UNICODE", "KANJI1_KANJISJIS_TO_UNICODE",
  "KANJI1_SBC_TO_UNICODE", "KANJISJIS_TO_GRAPHIC", "KANJISJIS_TO_LATIN", "KANJISJIS_TO_UNICODE",
  "LATIN_TO_GRAPHIC", "LATIN_TO_KANJISJIS", "LATIN_TO_UNICODE", "LOCALE_TO_UNICODE",
  "UNICODE_TO_GRAPHIC", "UNICODE_TO_GRAPHIC_PadGraphic", "UNICODE_TO_GRAPHIC_VarGraphic",
  "UNICODE_TO_KANJI1_KanjiEBCDIC", "UNICODE_TO_KANJI1_KanjiEUC", "UNICODE_TO_KANJI1_KANJISJIS",
  "UNICODE_TO_KANJI1_SBC", "UNICODE_TO_KANJISJIS", "UNICODE_TO_LATIN", "UNICODE_TO_LOCALE",
  "UNICODE_TO_UNICODE_FoldSpace", "UNICODE_TO_UNICODE_Fullwidth", "UNICODE_TO_UNICODE_Halfwidth",
  "UNICODE_TO_UNICODE_NFC", "UNICODE_TO_UNICODE_NFD", "UNICODE_TO_UNICODE_NFKC",
  "UNICODE_TO_UNICODE_NFKD",
]

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.statement_parsers[DATABASE] = p => {
    Some(p.expression(@core.mk1(Use, p.parse_table(schema=false))))
  }
  fns.statement_parsers[REPLACE] = p => p.parse_create()
  fns.statement_parsers[LOCK] = parse_locking_statement
  fns.set_parsers["QUERY_BAND"] = parse_query_band
  // https://docs.teradata.com/r/SQL-Functions-Operators-Exprs-and-Predicates/June-2017/Data-Type-Conversions/TRYCAST
  match fns.function_parsers.get("TRY_CAST") {
    Some(f) => fns.function_parsers["TRYCAST"] = f
    None => ()
  }
  fns.function_parsers["RANGE_N"] = parse_rangen
  fns.function_parsers["TRANSLATE"] = parse_translate
  fns.functions["CARDINALITY"] = @core.from_arg_list_builder(ArraySize)
  fns.functions["RANDOM"] = (args, _) => {
    @core.mk(Rand, [("lower", args.get(0)), ("upper", args.get(1))])
  }
  let h = fns.hooks
  h.parse_update = Some(parse_update)
  let parent_parse_index_params = h.parse_index_params
  h.parse_index_params = Some(p => {
    let this = match parent_parse_index_params {
      Some(f) => f(p)
      None => p.parse_index_params_base()
    }
    match this {
      Some(t) if t.has("on") => {
        t.set("on", (None : @core.Expr?))
        p.retreat(p.index - 2)
      }
      _ => ()
    }
    this
  })
  let parent_parse_function = h.parse_function
  h.parse_function = Some((p, functions, anonymous, optional_parens, any_token) => {
    // Teradata uses a `(FORMAT <format_string>)` clause after column references to
    // override the output format. When we see this pattern we do not
    // parse it as a function call.
    if p.next.ok() &&
      p.next.token_type == L_PAREN &&
      p.index + 2 < p.tokens.length() &&
      p.tokens[p.index + 2].token_type == FORMAT {
      return None
    }
    match parent_parse_function {
      Some(f) => f(p, functions, anonymous, optional_parens, any_token)
      None =>
        p.parse_function_base(
          functions?,
          anonymous~,
          optional_parens~,
          any_token~,
        )
    }
  })
  let parent_parse_column_ops = h.parse_column_ops
  h.parse_column_ops = Some((p, this) => {
    let mut this = match parent_parse_column_ops {
      Some(f) => f(p, this)
      None => p.parse_column_ops_base(this)
    }
    if p.match_pair(L_PAREN, FORMAT) {
      // `(FORMAT <format_string>)` after a column specifies a Teradata format override.
      let fmt_string = p.parse_string()
      p.match_r_paren()
      this = Some(
        p.expression(
          @core.mk(FormatPhrase, [("this", this), ("format", fmt_string)]),
        ),
      )
    }
    this
  })
}

///|
fn parse_locking_statement(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  // Reuse exp.LockingProperty parsing for the lock kind, type etc
  let locking_property = p.parse_locking()
  let wrapped_query = p.parse_select()
  if wrapped_query is None {
    p.raise_error("Expected SELECT statement after LOCKING clause")
  }
  Some(
    p.expression(
      @core.mk(LockingStatement, [
        ("this", locking_property),
        ("expression", wrapped_query),
      ]),
    ),
  )
}

///|
fn parse_translate(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_assignment()
  p.match_(USING) |> ignore
  p.match_texts(charset_translators) |> ignore
  let expression = @core.py_upper(p.prev.text)
  let with_error = p.match_text_seq(["WITH", "ERROR"])
  Some(
    p.expression(
      @core.mk(TranslateCharacters, [
        ("this", this),
        ("expression", expression),
        ("with_error", with_error),
      ]),
    ),
  )
}

///|
/// FROM before SET in Teradata UPDATE syntax
fn parse_update(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_table(alias_tokens=p.cfg.update_alias_tokens)
  let from_ = p.parse_from(joins=true)
  let expressions = if p.match_(SET) {
    Some(p.parse_csv(() => p.parse_update_assignment()))
  } else {
    None
  }
  let where_ = p.parse_where()
  Some(
    p.expression(
      @core.mk(Update, [
        ("this", this),
        ("from_", from_),
        ("expressions", expressions),
        ("where", where_),
      ]),
    ),
  )
}

///|
fn parse_rangen(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  let this = p.parse_id_var()
  p.match_(BETWEEN) |> ignore
  let expressions = p.parse_csv(() => p.parse_assignment())
  let each = if p.match_text_seq(["EACH"]) {
    p.parse_assignment()
  } else {
    None
  }
  Some(
    p.expression(
      @core.mk(RangeN, [
        ("this", this),
        ("expressions", expressions),
        ("each", each),
      ]),
    ),
  )
}

///|
fn parse_query_band(p : @core.Parser) -> @core.Expr? raise @core.SqlglotError {
  // Parse: SET QUERY_BAND = 'key=value;key2=value2;' FOR SESSION|TRANSACTION
  // Also supports: SET QUERY_BAND = 'key=value;' UPDATE FOR SESSION|TRANSACTION
  // Also supports: SET QUERY_BAND = NONE FOR SESSION|TRANSACTION
  p.match_(EQ) |> ignore
  // Handle both string literals and NONE keyword
  let query_band_string = if p.match_text_seq(["NONE"]) {
    Some(@core.var_("NONE"))
  } else {
    p.parse_string()
  }
  let update = p.match_text_seq(["UPDATE"])
  p.match_text_seq(["FOR"]) |> ignore
  // Handle scope - can be SESSION, TRANSACTION, VOLATILE, or SESSION VOLATILE
  let scope : String? = if p.match_text_seq(["SESSION", "VOLATILE"]) {
    Some("SESSION VOLATILE")
  } else if p.match_texts(["SESSION", "TRANSACTION"]) {
    Some(@core.py_upper(p.prev.text))
  } else {
    None
  }
  Some(
    p.expression(
      @core.mk(QueryBand, [
        ("this", query_band_string),
        ("scope", scope),
        ("update", update),
      ]),
    ),
  )
}
