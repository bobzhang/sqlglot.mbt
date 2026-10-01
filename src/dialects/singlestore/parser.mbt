// Port of sqlglot/parsers/singlestore.py

///|
/// Python `cast_to_time6(expression, time_type=TIME)`.
pub fn cast_to_time6(
  expression : @core.Expr?,
  time_type? : @core.DType = TIME,
) -> @core.Expr {
  @core.mk(Cast, [
    ("this", expression),
    (
      "to",
      @core.datatype_build(time_type, kwargs=[
        ("expressions", [@core.mk1(DataTypeParam, @core.literal_number("6"))]),
      ]),
    ),
  ])
}

///|
fn time_to_str_cast_int(
  args : Array[@core.Expr],
  format : String,
) -> @core.Expr {
  @core.cast_(
    @core.mk(TimeToStr, [
      ("this", cast_to_time6(@mysql.seq_get(args, 0))),
      ("format", @mysql.mysql_format_time(Some(@core.literal_string(format)))),
    ]),
    INT,
  )
}

///|
fn json_path_op(kind : @core.Kind, json_type? : String) -> @core.ColumnOpFn {
  (p, this, path) => {
    let path_name = match path {
      Some(x) => x.name()
      None => ""
    }
    let args : Array[@core.Expr] = [
      this.unwrap(),
      @core.literal_string(path_name),
    ]
    Some(@core.build_json_extract_path(kind, json_type?)(args, p))
  }
}

///|
fn json_array_contains(json_type : String) -> @core.FuncBuilder {
  (args, _) => {
    @core.mk(JSONArrayContains, [
      ("this", @mysql.seq_get(args, 1)),
      ("expression", @mysql.seq_get(args, 0)),
      ("json_type", json_type),
    ])
  }
}

///|
fn configure_parser(d : @core.Dialect) -> Unit {
  let fns = d.parser_fns
  let f = fns.functions
  f["TO_DATE"] = @core.build_formatted_time(TsOrDsToDate)
  f["TO_TIMESTAMP"] = @core.build_formatted_time(StrToTime)
  f["TO_CHAR"] = @core.build_formatted_time(ToChar)
  f["STR_TO_DATE"] = @core.build_formatted_time(
    StrToDate,
    dialect_override="mysql",
  )
  f["DATE_FORMAT"] = @core.build_formatted_time(
    TimeToStr,
    dialect_override="mysql",
  )
  // The first argument of following functions is converted to TIME(6)
  // This is needed because exp.TimeToStr is converted to DATE_FORMAT
  // which interprets the first argument as DATETIME and fails to parse
  // string literals like '12:05:47' without a date part.
  f["TIME_FORMAT"] = (args, _) => {
    @core.mk(TimeToStr, [
      ("this", cast_to_time6(@mysql.seq_get(args, 0))),
      ("format", @mysql.mysql_format_time(@mysql.seq_get(args, 1))),
    ])
  }
  f["HOUR"] = (args, _) => time_to_str_cast_int(args, "%k")
  f["MICROSECOND"] = (args, _) => time_to_str_cast_int(args, "%f")
  f["SECOND"] = (args, _) => time_to_str_cast_int(args, "%s")
  f["MINUTE"] = (args, _) => time_to_str_cast_int(args, "%i")
  f["MONTHNAME"] = (args, _) => {
    @core.mk(TimeToStr, [
      ("this", @mysql.seq_get(args, 0)),
      ("format", @mysql.mysql_format_time(Some(@core.literal_string("%M")))),
    ])
  }
  f["WEEKDAY"] = (args, _) => {
    @core.mk(Mod, [
      (
        "this",
        @core.paren(
          @core.add_(
            @core.mk1(DayOfWeek, @mysql.seq_get(args, 0)),
            @core.literal_number("5"),
          ),
          copy=false,
        ),
      ),
      ("expression", @core.literal_number("7")),
    ])
  }
  f["UNIX_TIMESTAMP"] = @core.from_arg_list_builder(StrToUnix)
  f["FROM_UNIXTIME"] = @core.build_formatted_time(
    UnixToTime,
    dialect_override="mysql",
  )
  f["TIME_BUCKET"] = (args, _) => {
    @core.mk(DateBin, [
      ("this", @mysql.seq_get(args, 0)),
      ("expression", @mysql.seq_get(args, 1)),
      ("origin", @mysql.seq_get(args, 2)),
    ])
  }
  f["BSON_EXTRACT_BSON"] = @core.build_json_extract_path(JSONBExtract)
  f["BSON_EXTRACT_STRING"] = @core.build_json_extract_path(
    JSONBExtractScalar,
    json_type="STRING",
  )
  f["BSON_EXTRACT_DOUBLE"] = @core.build_json_extract_path(
    JSONBExtractScalar,
    json_type="DOUBLE",
  )
  f["BSON_EXTRACT_BIGINT"] = @core.build_json_extract_path(
    JSONBExtractScalar,
    json_type="BIGINT",
  )
  f["JSON_EXTRACT_JSON"] = @core.build_json_extract_path(JSONExtract)
  f["JSON_EXTRACT_STRING"] = @core.build_json_extract_path(
    JSONExtractScalar,
    json_type="STRING",
  )
  f["JSON_EXTRACT_DOUBLE"] = @core.build_json_extract_path(
    JSONExtractScalar,
    json_type="DOUBLE",
  )
  f["JSON_EXTRACT_BIGINT"] = @core.build_json_extract_path(
    JSONExtractScalar,
    json_type="BIGINT",
  )
  f["JSON_ARRAY_CONTAINS_STRING"] = json_array_contains("STRING")
  f["JSON_ARRAY_CONTAINS_DOUBLE"] = json_array_contains("DOUBLE")
  f["JSON_ARRAY_CONTAINS_JSON"] = json_array_contains("JSON")
  f["JSON_KEYS"] = (args, _) => {
    @core.mk(JSONKeys, [
      ("this", @mysql.seq_get(args, 0)),
      ("expressions", args[1:].to_owned()),
    ])
  }
  f["JSON_PRETTY"] = @core.from_arg_list_builder(JSONFormat)
  f["JSON_BUILD_ARRAY"] = (args, _) => {
    @core.mk(JSONArray, [("expressions", args)])
  }
  f["JSON_BUILD_OBJECT"] = (args, _) => {
    @core.mk(JSONObject, [("expressions", args)])
  }
  f["DATE"] = @core.from_arg_list_builder(Date)
  f["DAYNAME"] = (args, _) => {
    @core.mk(TimeToStr, [
      ("this", @mysql.seq_get(args, 0)),
      ("format", @mysql.mysql_format_time(Some(@core.literal_string("%W")))),
    ])
  }
  f["TIMESTAMPDIFF"] = (args, _) => {
    @core.mk(TimestampDiff, [
      ("this", @mysql.seq_get(args, 2)),
      ("expression", @mysql.seq_get(args, 1)),
      ("unit", @mysql.seq_get(args, 0)),
    ])
  }
  f["APPROX_COUNT_DISTINCT"] = @core.from_arg_list_builder(Hll)
  f["APPROX_PERCENTILE"] = (args, _) => {
    @core.mk(ApproxQuantile, [
      ("this", @mysql.seq_get(args, 0)),
      ("quantile", @mysql.seq_get(args, 1)),
      ("error_tolerance", @mysql.seq_get(args, 2)),
    ])
  }
  f["VARIANCE"] = @core.from_arg_list_builder(VariancePop)
  f["INSTR"] = @core.from_arg_list_builder(Contains)
  f["REGEXP_MATCH"] = (args, _) => {
    @core.mk(RegexpExtractAll, [
      ("this", @mysql.seq_get(args, 0)),
      ("expression", @mysql.seq_get(args, 1)),
      ("parameters", @mysql.seq_get(args, 2)),
    ])
  }
  f["REGEXP_SUBSTR"] = (args, _) => {
    @core.mk(RegexpExtract, [
      ("this", @mysql.seq_get(args, 0)),
      ("expression", @mysql.seq_get(args, 1)),
      ("position", @mysql.seq_get(args, 2)),
      ("occurrence", @mysql.seq_get(args, 3)),
      ("parameters", @mysql.seq_get(args, 4)),
    ])
  }
  f["REDUCE"] = (args, _) => {
    @core.mk(Reduce, [
      ("initial", @mysql.seq_get(args, 0)),
      ("this", @mysql.seq_get(args, 1)),
      ("merge", @mysql.seq_get(args, 2)),
    ])
  }
  fns.function_parsers["JSON_AGG"] = p => {
    let this = p.parse_term()
    let order = p.parse_order()
    Some(@core.mk(JSONArrayAgg, [("this", this), ("order", order)]))
  }
  let co = fns.column_operators
  co[COLON_GT] = Some((p, this, to) => {
    Some(p.expression(@core.mk(Cast, [("this", this), ("to", to)])))
  })
  co[NCOLON_GT] = Some((p, this, to) => {
    Some(p.expression(@core.mk(TryCast, [("this", this), ("to", to)])))
  })
  co[DCOLON] = Some(json_path_op(JSONExtract))
  co[DCOLONDOLLAR] = Some(json_path_op(JSONExtractScalar, json_type="STRING"))
  co[DCOLONPERCENT] = Some(json_path_op(JSONExtractScalar, json_type="DOUBLE"))
  co[DCOLONQMARK] = Some((p, this, path) => {
    let path_name = match path {
      Some(x) => x.name()
      None => ""
    }
    Some(
      p.expression(
        @core.mk(JSONExists, [
          ("this", this),
          ("path", path_name),
          ("from_dcolonqmark", true),
        ]),
      ),
    )
  })
  for
    tt in [@core.TokenType::ARROW, DARROW, HASH_ARROW, DHASH_ARROW, PLACEHOLDER] {
    co.remove(tt)
  }
  let sp = fns.show_parsers
  sp["AGGREGATES"] = @mysql.show_parser("AGGREGATES")
  sp["CDC EXTRACTOR POOL"] = @mysql.show_parser("CDC EXTRACTOR POOL")
  sp["CREATE AGGREGATE"] = @mysql.show_parser("CREATE AGGREGATE", target="")
  sp["CREATE PIPELINE"] = @mysql.show_parser("CREATE PIPELINE", target="")
  sp["CREATE PROJECTION"] = @mysql.show_parser("CREATE PROJECTION", target="")
  sp["DATABASE STATUS"] = @mysql.show_parser("DATABASE STATUS")
  sp["DISTRIBUTED_PLANCACHE STATUS"] = @mysql.show_parser(
    "DISTRIBUTED_PLANCACHE STATUS",
  )
  sp["FULLTEXT SERVICE METRICS LOCAL"] = @mysql.show_parser(
    "FULLTEXT SERVICE METRICS LOCAL",
  )
  sp["FULLTEXT SERVICE METRICS FOR NODE"] = @mysql.show_parser(
    "FULLTEXT SERVICE METRICS FOR NODE",
    target="",
  )
  sp["FULLTEXT SERVICE STATUS"] = @mysql.show_parser("FULLTEXT SERVICE STATUS")
  sp["FUNCTIONS"] = @mysql.show_parser("FUNCTIONS")
  sp["GROUPS"] = @mysql.show_parser("GROUPS")
  sp["GROUPS FOR ROLE"] = @mysql.show_parser("GROUPS FOR ROLE", target="")
  sp["GROUPS FOR USER"] = @mysql.show_parser("GROUPS FOR USER", target="")
  sp["INDEXES"] = @mysql.show_parser("INDEX", target="FROM")
  sp["KEYS"] = @mysql.show_parser("INDEX", target="FROM")
  sp["LINKS"] = @mysql.show_parser("LINKS", target="ON")
  sp["LOAD ERRORS"] = @mysql.show_parser("LOAD ERRORS")
  sp["LOAD WARNINGS"] = @mysql.show_parser("LOAD WARNINGS")
  sp["PARTITIONS"] = @mysql.show_parser("PARTITIONS", target="ON")
  sp["PIPELINES"] = @mysql.show_parser("PIPELINES")
  sp["PLAN"] = @mysql.show_parser("PLAN", target="")
  sp["PLANCACHE"] = @mysql.show_parser("PLANCACHE")
  sp["PROCEDURES"] = @mysql.show_parser("PROCEDURES")
  sp["PROJECTIONS"] = @mysql.show_parser("PROJECTIONS", target="ON TABLE")
  sp["REPLICATION STATUS"] = @mysql.show_parser("REPLICATION STATUS")
  sp["REPRODUCTION"] = @mysql.show_parser("REPRODUCTION")
  sp["RESOURCE POOLS"] = @mysql.show_parser("RESOURCE POOLS")
  sp["ROLES"] = @mysql.show_parser("ROLES")
  sp["ROLES FOR USER"] = @mysql.show_parser("ROLES FOR USER", target="")
  sp["ROLES FOR GROUP"] = @mysql.show_parser("ROLES FOR GROUP", target="")
  sp["STATUS EXTENDED"] = @mysql.show_parser("STATUS EXTENDED")
  sp["USERS"] = @mysql.show_parser("USERS")
  sp["USERS FOR ROLE"] = @mysql.show_parser("USERS FOR ROLE", target="")
  sp["USERS FOR GROUP"] = @mysql.show_parser("USERS FOR GROUP", target="")
  fns.alter_parsers["CHANGE"] = p => {
    Some(
      Node(
        p.expression(
          @core.mk(RenameColumn, [
            ("this", p.parse_column()),
            ("to", p.parse_column()),
          ]),
        ),
      ),
    )
  }
  fns.hooks.parse_vector_expressions = Some((p, expressions) => {
    let mut type_name = @core.py_upper(expressions[1].name())
    // VECTOR_TYPE_ALIASES is the inverse of INVERSE_VECTOR_TYPE_ALIASES
    for k, v in p.dialect.cfg.inverse_vector_type_aliases {
      if v == type_name {
        type_name = k
        break
      }
    }
    [@core.datatype_from_str(type_name, dialect=p.dialect), expressions[0]]
  })
}
