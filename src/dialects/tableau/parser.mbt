// Port of sqlglot/parsers/tableau.py

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let f = d.parser_fns.functions
  f["COUNTD"] = (args, _) => {
    @core.mk1(Count, @core.mk(Distinct, [("expressions", args)]))
  }
  f["FIND"] = @core.from_arg_list_builder(StrPosition)
  f["FINDNTH"] = (args, _) => {
    @core.mk(StrPosition, [
      ("this", args.get(0)),
      ("substr", args.get(1)),
      ("occurrence", args.get(2)),
    ])
  }
}
