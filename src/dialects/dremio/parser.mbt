// Port of sqlglot/parsers/dremio.py

///|
fn seq_get(args : Array[@core.Expr], i : Int) -> @core.Expr? {
  if i >= 0 && i < args.length() {
    Some(args[i])
  } else {
    None
  }
}

///|
fn to_char_is_numeric_handler(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  let expression = @core.build_timetostr_or_tochar(args, p.dialect)
  match seq_get(args, 1) {
    Some(fmt) if expression.kind == ToChar &&
      fmt.is_string() &&
      fmt.name().contains("#") =>
      // Only mark as numeric if format is a literal containing #
      expression.set("is_numeric", true)
    _ => ()
  }
  expression
}

///|
fn build_date_delta_with_cast_interval(kind : @core.Kind) -> @core.FuncBuilder {
  let fallback_builder = @core.build_date_delta(kind)
  (args, p) => {
    if args.length() == 2 {
      let date_arg = args[0]
      let interval_arg = args[1]
      if interval_arg.kind == Cast {
        match interval_arg.arg("to") {
          Some(to) if to.kind == DataType &&
            to.arg("this") is Some(iv) &&
            iv.kind == Interval =>
            return @core.mk(kind, [
              ("this", Some(date_arg)),
              ("expression", interval_arg.this()),
              ("unit", iv.arg("unit")),
            ])
          _ => ()
        }
      }
      return @core.mk(kind, [("this", date_arg), ("expression", interval_arg)])
    }
    fallback_builder(args, p)
  }
}

///|
fn pad_int(v : Int64, width : Int) -> String {
  let neg = v < 0L
  let s = (if neg { -v } else { v }).to_string()
  let padded = if s.length() < width {
    "0".repeat(width - s.length()) + s
  } else {
    s
  }
  if neg {
    "-" + padded
  } else {
    padded
  }
}

///|
fn datetype_handler(
  args : Array[@core.Expr],
  p : @core.Parser,
) -> @core.Expr raise @core.SqlglotError {
  guard args.length() == 3 else {
    raise @core.ParseError(
      "DATETYPE expects 3 arguments, got \{args.length()}",
      [],
    )
  }
  let year = args[0]
  let month = args[1]
  let day = args[2]
  if [year, month, day].iter().all(a => a.kind == Literal && a.is_int()) {
    let y = @core.parse_int_str(year.text("this")).unwrap()
    let m = @core.parse_int_str(month.text("this")).unwrap()
    let d = @core.parse_int_str(day.text("this")).unwrap()
    let date_str = "\{pad_int(y, 4)}-\{pad_int(m, 2)}-\{pad_int(d, 2)}"
    return @core.mk1(Date, @core.literal_string(date_str))
  }
  @core.mk(Cast, [
    (
      "this",
      @core.mk(Concat, [
        (
          "expressions",
          [
            year,
            @core.literal_string("-"),
            month,
            @core.literal_string("-"),
            day,
          ],
        ),
        ("coalesce", p.dialect.cfg.concat_coalesce),
      ]),
    ),
    ("to", @core.datatype_of(DATE)),
  ])
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  fns.no_paren_function_parsers["CURRENT_DATE_UTC"] = parse_current_date_utc
  let f = fns.functions
  f["ARRAY_GENERATE_RANGE"] = @core.from_arg_list_builder(GenerateSeries)
  f["BIT_AND"] = @core.from_arg_list_builder(BitwiseAndAgg)
  f["BIT_OR"] = @core.from_arg_list_builder(BitwiseOrAgg)
  f["DATE_ADD"] = build_date_delta_with_cast_interval(DateAdd)
  f["DATE_FORMAT"] = @core.build_formatted_time(TimeToStr)
  f["DATE_SUB"] = build_date_delta_with_cast_interval(DateSub)
  f["REGEXP_MATCHES"] = @core.from_arg_list_builder(RegexpLike)
  f["REGEXP_SPLIT"] = (args, _) => {
    @core.mk(RegexpSplit, [
      ("this", seq_get(args, 0)),
      ("expression", seq_get(args, 1)),
      ("mode", seq_get(args, 2)),
      ("limit", seq_get(args, 3)),
    ])
  }
  f["REPEATSTR"] = @core.from_arg_list_builder(Repeat)
  f["TO_CHAR"] = to_char_is_numeric_handler
  f["TO_DATE"] = @core.build_formatted_time(TsOrDsToDate)
  f["DATE_PART"] = @core.from_arg_list_builder(Extract)
  f["DATETYPE"] = datetype_handler
}

///|
fn parse_current_date_utc(
  p : @core.Parser,
) -> @core.Expr? raise @core.SqlglotError {
  if p.match_(L_PAREN) {
    p.match_r_paren()
  }
  Some(
    @core.mk(Cast, [
      (
        "this",
        @core.mk(AtTimeZone, [
          ("this", @core.mk0(CurrentTimestamp)),
          ("zone", @core.literal_string("UTC")),
        ]),
      ),
      ("to", @core.datatype_of(DATE)),
    ]),
  )
}
