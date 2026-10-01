// Port of sqlglot/parsers/drill.py

///|
fn build_ilike(args : Array[@core.Expr]) -> @core.Expr {
  let get = (i : Int) => if i < args.length() { Some(args[i]) } else { None }
  let ilike = @core.mk(ILike, [("this", get(0)), ("expression", get(1))])
  match get(2) {
    Some(escape) => @core.mk(Escape, [("this", ilike), ("expression", escape)])
    None => ilike
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let f = d.parser_fns.functions
  f["ILIKE"] = (args, _) => build_ilike(args)
  f["REPEATED_COUNT"] = @core.from_arg_list_builder(ArraySize)
  f["TO_TIMESTAMP"] = @core.from_arg_list_builder(TimeStrToTime)
  f["TO_CHAR"] = @core.build_formatted_time(TimeToStr)
  f["LEVENSHTEIN_DISTANCE"] = @core.from_arg_list_builder(Levenshtein)
}
