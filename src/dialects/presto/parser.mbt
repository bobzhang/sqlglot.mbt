// Port of sqlglot/parsers/presto.py

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn build_approx_percentile(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 4 {
    return @core.mk(ApproxQuantile, [
      ("this", seq_get(args, 0)),
      ("weight", seq_get(args, 1)),
      ("quantile", seq_get(args, 2)),
      ("accuracy", seq_get(args, 3)),
    ])
  }
  if args.length() == 3 {
    return @core.mk(ApproxQuantile, [
      ("this", seq_get(args, 0)),
      ("quantile", seq_get(args, 1)),
      ("accuracy", seq_get(args, 2)),
    ])
  }
  @core.from_arg_list(ApproxQuantile, args)
}

///|
fn build_from_unixtime(args : Array[@core.Expr]) -> @core.Expr {
  if args.length() == 3 {
    return @core.mk(UnixToTime, [
      ("this", seq_get(args, 0)),
      ("hours", seq_get(args, 1)),
      ("minutes", seq_get(args, 2)),
    ])
  }
  if args.length() == 2 {
    return @core.mk(UnixToTime, [
      ("this", seq_get(args, 0)),
      ("zone", seq_get(args, 1)),
    ])
  }
  @core.from_arg_list(UnixToTime, args)
}

///|
fn build_to_char(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  match seq_get(args, 1) {
    // We uppercase this to match Teradata's format mapping keys
    Some(fmt) if fmt.kind.is_a(Literal) =>
      fmt.set("this", @core.py_upper(fmt.text("this")))
    _ => ()
  }
  // We use "teradata" on purpose here, because the time formats are different in Presto.
  // See https://prestodb.io/docs/current/functions/teradata.html?highlight=to_char#to_char
  @core.build_formatted_time(TimeToStr, dialect_override="teradata")(args, p)
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f["ARBITRARY"] = @core.from_arg_list_builder(AnyValue)
  f["APPROX_DISTINCT"] = @core.from_arg_list_builder(ApproxDistinct)
  f["APPROX_PERCENTILE"] = (args, _) => build_approx_percentile(args)
  f["BITWISE_AND"] = @core.binary_from_function(BitwiseAnd)
  f["BITWISE_NOT"] = (args, _) => @core.mk1(BitwiseNot, seq_get(args, 0))
  f["BITWISE_OR"] = @core.binary_from_function(BitwiseOr)
  f["BITWISE_XOR"] = @core.binary_from_function(BitwiseXor)
  f["CARDINALITY"] = @core.from_arg_list_builder(ArraySize)
  f["CONTAINS"] = @core.from_arg_list_builder(ArrayContains)
  f["DATE_ADD"] = (args, _) => {
    @core.mk(DateAdd, [
      ("this", seq_get(args, 2)),
      ("expression", seq_get(args, 1)),
      ("unit", seq_get(args, 0)),
    ])
  }
  f["DATE_DIFF"] = (args, _) => {
    @core.mk(DateDiff, [
      ("this", seq_get(args, 2)),
      ("expression", seq_get(args, 1)),
      ("unit", seq_get(args, 0)),
    ])
  }
  f["DATE_FORMAT"] = @core.build_formatted_time(TimeToStr)
  f["DATE_PARSE"] = @core.build_formatted_time(StrToTime)
  f["DATE_TRUNC"] = (args, _) => @core.date_trunc_to_time(args)
  f["DAY_OF_WEEK"] = @core.from_arg_list_builder(DayOfWeekIso)
  f["DOW"] = @core.from_arg_list_builder(DayOfWeekIso)
  f["DOY"] = @core.from_arg_list_builder(DayOfYear)
  f["ELEMENT_AT"] = (args, _) => {
    @core.mk(Bracket, [
      ("this", seq_get(args, 0)),
      ("expressions", [seq_get(args, 1)].filter_map(x => x)),
      ("offset", 1),
      ("safe", true),
    ])
  }
  f["FROM_HEX"] = @core.from_arg_list_builder(Unhex)
  f["FROM_UNIXTIME"] = (args, _) => build_from_unixtime(args)
  f["FROM_UTF8"] = (args, _) => {
    @core.mk(Decode, [
      ("this", seq_get(args, 0)),
      ("replace", seq_get(args, 1)),
      ("charset", Some(@core.literal_string("utf-8"))),
    ])
  }
  f["JSON_FORMAT"] = (args, _) => {
    @core.mk(JSONFormat, [
      ("this", seq_get(args, 0)),
      ("options", seq_get(args, 1)),
      ("is_json", true),
    ])
  }
  f["LEVENSHTEIN_DISTANCE"] = @core.from_arg_list_builder(Levenshtein)
  f["NOW"] = @core.from_arg_list_builder(CurrentTimestamp)
  f["REGEXP_EXTRACT"] = @core.build_regexp_extract(RegexpExtract)
  f["REGEXP_EXTRACT_ALL"] = @core.build_regexp_extract(RegexpExtractAll)
  f["REGEXP_REPLACE"] = (args, _) => {
    @core.mk(RegexpReplace, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      (
        "replacement",
        Some(
          match seq_get(args, 2) {
            Some(r) => r
            None => @core.literal_string("")
          },
        ),
      ),
    ])
  }
  f["REPLACE"] = (args, _) => {
    @core.build_replace_with_optional_replacement(args)
  }
  f["ROW"] = @core.from_arg_list_builder(Struct)
  f["SEQUENCE"] = @core.from_arg_list_builder(GenerateSeries)
  f["SET_AGG"] = @core.from_arg_list_builder(ArrayUniqueAgg)
  f["SPLIT_TO_MAP"] = @core.from_arg_list_builder(StrToMap)
  f["STRPOS"] = (args, _) => {
    @core.mk(StrPosition, [
      ("this", seq_get(args, 0)),
      ("substr", seq_get(args, 1)),
      ("occurrence", seq_get(args, 2)),
    ])
  }
  f["SLICE"] = @core.from_arg_list_builder(ArraySlice)
  f["TO_CHAR"] = build_to_char
  f["TO_UNIXTIME"] = @core.from_arg_list_builder(TimeToUnix)
  f["TO_UTF8"] = (args, _) => {
    @core.mk(Encode, [
      ("this", seq_get(args, 0)),
      ("charset", Some(@core.literal_string("utf-8"))),
    ])
  }
  f["MD5"] = @core.from_arg_list_builder(MD5Digest)
  f["SHA256"] = (args, _) => {
    @core.mk(SHA2Digest, [
      ("this", seq_get(args, 0)),
      ("length", Some(@core.literal_number("256"))),
    ])
  }
  f["SHA512"] = (args, _) => {
    @core.mk(SHA2Digest, [
      ("this", seq_get(args, 0)),
      ("length", Some(@core.literal_number("512"))),
    ])
  }
  f["WEEK"] = @core.from_arg_list_builder(WeekOfYear)
  fns.function_parsers.remove("TRIM")
}
