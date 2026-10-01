// Port of sqlglot/generators/duckdb.py: TRANSFORMS and generator configuration.

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  let fns = d.gen_fns
  fns.type_param_settings[BIGDECIMAL] = ([38, 5], [Some(38), Some(38)])
  fns.type_param_settings[DECFLOAT] = ([38, 5], [Some(38), Some(38)])
  // AFTER_HAVING_MODIFIER_TRANSFORMS = generator.AFTER_HAVING_MODIFIER_TRANSFORMS
  fns.after_having_modifier_transforms = fns.after_having_modifier_transforms.filter(kv => {
      kv.0 == "windows" || kv.0 == "qualify"
    },
  )
  configure_transforms(d)
  configure_methods(d)
}

///|
fn configure_transforms(d : @core.Dialect) -> Unit {
  let t = d.gen_fns.transforms
  t[AnyValue] = anyvalue_sql
  t[ApproxDistinct] = @core.approx_count_distinct_sql
  t[Boolnot] = boolnot_sql
  t[Booland] = booland_sql
  t[Boolor] = boolor_sql
  t[Array] = @core.preprocess(
    [e => @core.inherit_struct_field_names(e)],
    generator=@core.inline_array_unless_query,
  )
  t[ArrayAppend] = @core.array_append_sql("LIST_APPEND")
  t[ArrayCompact] = @core.array_compact_sql
  t[ArrayConstructCompact] = (g, e) => {
    g.sql(
      Some(
        @core.mk1(
          ArrayCompact,
          @core.mk(Array, [("expressions", e.expressions())]),
        ),
      ),
    )
  }
  t[ArrayConcat] = @core.array_concat_sql("LIST_CONCAT")
  t[ArrayContains] = array_contains_sql
  t[ArrayOverlaps] = array_overlaps_sql
  t[ArrayFilter] = @core.rename_func("LIST_FILTER")
  t[ArrayInsert] = array_insert_sql
  t[ArrayPosition] = (g, e) => {
    if e.has("zero_based") {
      g.sql(
        Some(
          @core.mk(Sub, [
            (
              "this",
              @core.mk(ArrayPosition, [
                ("this", e.this()),
                ("expression", e.expression()),
              ]),
            ),
            ("expression", num(1)),
          ]),
        ),
      )
    } else {
      g.func("ARRAY_POSITION", [e.this(), e.expression()])
    }
  }
  t[ArrayRemoveAt] = array_remove_at_sql
  t[ArrayRemove] = @core.remove_from_array_using_filter
  t[ArraySort] = array_sort_sql
  t[ArrayPrepend] = @core.array_append_sql("LIST_PREPEND", swap_params=true)
  t[ArraySum] = @core.rename_func("LIST_SUM")
  t[ArrayMax] = @core.rename_func("LIST_MAX")
  t[ArrayMin] = @core.rename_func("LIST_MIN")
  t[Base64DecodeBinary] = (g, e) => base64_decode_sql(g, e, false)
  t[Base64DecodeString] = (g, e) => base64_decode_sql(g, e, true)
  t[BitwiseAnd] = (g, e) => bitwise_op(g, e, "&")
  t[BitwiseAndAgg] = bitwise_agg_sql
  t[BitwiseCount] = @core.rename_func("BIT_COUNT")
  t[BitwiseLeftShift] = bitshift_sql
  t[BitwiseOr] = (g, e) => bitwise_op(g, e, "|")
  t[BitwiseOrAgg] = bitwise_agg_sql
  t[BitwiseRightShift] = bitshift_sql
  t[BitwiseXorAgg] = bitwise_agg_sql
  t[CommentColumnConstraint] = @core.no_comment_column_constraint_sql
  t[Corr] = corr_sql
  t[CosineDistance] = @core.rename_func("LIST_COSINE_DISTANCE")
  t[CurrentTime] = (_, _) => "CURRENT_TIME"
  t[CurrentSchemas] = (g, e) => {
    g.func("current_schemas", [
      match e.this() {
        Some(t) => t
        None => @core.true_()
      },
    ])
  }
  t[CurrentTimestamp] = (g, e) => {
    if e.has("sysdate") {
      g.sql(
        Some(
          @core.mk(AtTimeZone, [
            ("this", @core.var_("CURRENT_TIMESTAMP")),
            ("zone", str_lit("UTC")),
          ]),
        ),
      )
    } else {
      "CURRENT_TIMESTAMP"
    }
  }
  t[CurrentVersion] = @core.rename_func("version")
  t[Localtime] = (g, e) => {
    g.unsupported_args(e, ["this"])
    "LOCALTIME"
  }
  t[DayOfMonth] = @core.rename_func("DAYOFMONTH")
  t[DayOfWeek] = @core.rename_func("DAYOFWEEK")
  t[DayOfWeekIso] = @core.rename_func("ISODOW")
  t[DayOfYear] = @core.rename_func("DAYOFYEAR")
  t[Dayname] = (g, e) => {
    if e.has("abbreviated") {
      g.func("STRFTIME", [e.this_(), str_lit("%a")])
    } else {
      g.func("DAYNAME", [e.this()])
    }
  }
  t[Monthname] = (g, e) => {
    if e.has("abbreviated") {
      g.func("STRFTIME", [e.this_(), str_lit("%b")])
    } else {
      g.func("MONTHNAME", [e.this()])
    }
  }
  t[Date] = date_sql
  t[DateAdd] = duck_date_delta_to_binary_interval_op()
  t[DateFromParts] = date_from_parts_sql
  t[DateSub] = duck_date_delta_to_binary_interval_op()
  t[DateDiff] = date_diff_sql
  t[DateStrToDate] = @core.datestrtodate_sql
  t[Datetime] = @core.no_datetime_sql
  t[DatetimeDiff] = date_diff_sql
  t[DatetimeSub] = duck_date_delta_to_binary_interval_op()
  t[DatetimeAdd] = duck_date_delta_to_binary_interval_op()
  t[DateToDi] = (g, e) => {
    "CAST(STRFTIME(\{g.sql_key(e, "this")}, \{g.dialect.cfg.dateint_format}) AS INT)"
  }
  t[Decode] = (g, e) => @core.encode_decode_sql(g, e, "DECODE", replace=false)
  t[HexDecodeString] = (g, e) => {
    g.sql(Some(@core.mk1(Decode, @core.mk1(Unhex, e.this()))))
  }
  t[DiToDate] = (g, e) => {
    "CAST(STRPTIME(CAST(\{g.sql_key(e, "this")} AS TEXT), \{g.dialect.cfg.dateint_format}) AS DATE)"
  }
  t[Encode] = (g, e) => @core.encode_decode_sql(g, e, "ENCODE", replace=false)
  t[EqualNull] = (g, e) => {
    g.sql(
      Some(
        @core.mk(NullSafeEQ, [
          ("this", e.this()),
          ("expression", e.expression()),
        ]),
      ),
    )
  }
  t[EuclideanDistance] = @core.rename_func("LIST_DISTANCE")
  t[GenerateDateArray] = generate_datetime_array_sql
  t[GenerateSeries] = @core.generate_series_sql(
    "GENERATE_SERIES",
    exclusive_func_name="RANGE",
  )
  t[GenerateTimestampArray] = generate_datetime_array_sql
  t[Getbit] = @core.getbit_sql
  t[GroupConcat] = (g, e) => @core.groupconcat_sql(g, e, within_group=false)
  t[Explode] = @core.rename_func("UNNEST")
  t[IcebergProperty] = (_, _) => ""
  t[IntDiv] = (g, e) => g.binary(e, "//")
  t[IsInf] = @core.rename_func("ISINF")
  t[IsNan] = @core.rename_func("ISNAN")
  t[IsNullValue] = (g, e) => {
    g.sql(Some(eq(func("JSON_TYPE", [e.this_()]), str_lit("NULL"))))
  }
  t[IsArray] = (g, e) => {
    g.sql(Some(eq(func("JSON_TYPE", [e.this_()]), str_lit("ARRAY"))))
  }
  t[Ceil] = ceil_floor
  t[Floor] = ceil_floor
  t[JSONBExists] = @core.rename_func("JSON_EXISTS")
  t[JSONExtract] = arrow_json_extract_sql
  t[JSONExtractArray] = json_extract_value_array_sql
  t[JSONFormat] = json_format_sql
  t[JSONValueArray] = json_extract_value_array_sql
  t[Lateral] = explode_to_unnest_sql
  t[LogicalOr] = (g, e) => g.func("BOOL_OR", [cast_to_boolean(e.this())])
  t[LogicalAnd] = (g, e) => g.func("BOOL_AND", [cast_to_boolean(e.this())])
  t[Select] = @core.preprocess([
    connect_by_to_recursive_cte, seq_to_range_in_generator,
  ])
  t[Seq1] = (g, e) => seq_sql(g, e, 1)
  t[Seq2] = (g, e) => seq_sql(g, e, 2)
  t[Seq4] = (g, e) => seq_sql(g, e, 4)
  t[Seq8] = (g, e) => seq_sql(g, e, 8)
  t[BoolxorAgg] = boolxor_agg_sql
  t[MakeInterval] = (g, e) => @core.no_make_interval_sql(g, e, sep=" ")
  t[Initcap] = initcap_sql
  t[MD5Digest] = (g, e) => g.func("UNHEX", [g.func("MD5", [e.this()])])
  t[SHA] = (g, e) => sha_sql(g, e, "SHA1")
  t[SHA1Digest] = (g, e) => sha_sql(g, e, "SHA1", binary=true)
  t[SHA2] = (g, e) => sha_sql(g, e, "SHA256")
  t[SHA2Digest] = (g, e) => sha_sql(g, e, "SHA256", binary=true)
  t[MonthsBetween] = @core.months_between_sql
  t[NextDay] = day_navigation_sql
  t[PercentileCont] = @core.rename_func("QUANTILE_CONT")
  t[PercentileDisc] = @core.rename_func("QUANTILE_DISC")
  // DuckDB doesn't allow qualified columns inside of PIVOT expressions.
  t[Pivot] = @core.preprocess([e => @core.unqualify_columns(e)])
  t[PreviousDay] = day_navigation_sql
  t[RegexpILike] = (g, e) => {
    g.func("REGEXP_MATCHES", [e.this(), e.expression(), Some(str_lit("i"))])
  }
  t[RegexpSplit] = @core.rename_func("STR_SPLIT_REGEX")
  t[RegrValx] = regr_val_sql
  t[RegrValy] = regr_val_sql
  t[Return] = (g, e) => g.sql_key(e, "this")
  t[ReturnsProperty] = (_, e) => {
    match e.this() {
      Some(t) if t.kind == Schema => "TABLE"
      _ => ""
    }
  }
  t[StrToUnix] = (g, e) => {
    g.func("EPOCH", [g.func("STRPTIME", [e.this(), g.format_time(e)])])
  }
  t[Struct] = struct_sql
  t[Transform] = @core.rename_func("LIST_TRANSFORM")
  t[TimeAdd] = duck_date_delta_to_binary_interval_op()
  t[TimeSub] = duck_date_delta_to_binary_interval_op()
  t[Time] = @core.no_time_sql
  t[TimeDiff] = timediff_sql
  t[Timestamp] = @core.no_timestamp_sql
  t[TimestampAdd] = duck_date_delta_to_binary_interval_op()
  t[TimestampDiff] = (g, e) => {
    let unit = match e.arg("unit") {
      Some(u) => @core.expr_to_sql(u)
      None => "None"
    }
    g.func("DATE_DIFF", [str_lit(unit), e.expression_(), e.this_()])
  }
  t[TimestampSub] = duck_date_delta_to_binary_interval_op()
  t[TimeStrToDate] = (g, e) => g.sql(Some(cast(e.this_(), DATE)))
  t[TimeStrToTime] = (g, e) => @core.timestrtotime_sql(g, e)
  t[TimeStrToUnix] = (g, e) => g.func("EPOCH", [cast(e.this_(), TIMESTAMP)])
  t[TimeToStr] = (g, e) => g.func("STRFTIME", [e.this(), g.format_time(e)])
  t[ToBoolean] = to_boolean_sql
  t[ToVariant] = (g, e) => g.sql(Some(cast_to(e.this_(), duck_type("VARIANT"))))
  t[TimeToUnix] = @core.rename_func("EPOCH")
  t[TsOrDiToDi] = (g, e) => {
    "CAST(SUBSTR(REPLACE(CAST(\{g.sql_key(e, "this")} AS TEXT), '-', ''), 1, 8) AS INT)"
  }
  t[TsOrDsAdd] = duck_date_delta_to_binary_interval_op()
  t[TsOrDsDiff] = (g, e) => {
    let unit = match e.get("unit") {
      Some(Node(u)) => @core.expr_to_sql(u)
      Some(Str(s)) if s != "" => s
      _ => "DAY"
    }
    g.func("DATE_DIFF", [
      "'\{unit}'",
      cast(e.expression_(), TIMESTAMP),
      cast(e.this_(), TIMESTAMP),
    ])
  }
  t[UnixMicros] = (g, e) => {
    g.func("EPOCH_US", [implicit_datetime_cast(e.this())])
  }
  t[UnixMillis] = (g, e) => {
    g.func("EPOCH_MS", [implicit_datetime_cast(e.this())])
  }
  t[UnixSeconds] = (g, e) => {
    g.sql(
      Some(
        cast(parse(g.func("EPOCH", [implicit_datetime_cast(e.this())])), BIGINT),
      ),
    )
  }
  t[UnixToStr] = (g, e) => {
    g.func("STRFTIME", [
      Some(g.func("TO_TIMESTAMP", [e.this()])),
      g.format_time(e),
    ])
  }
  t[UnixToTime] = unix_to_time_sql
  t[UnixToTimeStr] = (g, e) => {
    "CAST(TO_TIMESTAMP(\{g.sql_key(e, "this")}) AS TEXT)"
  }
  t[VariancePop] = @core.rename_func("VAR_POP")
  t[WeekOfYear] = @core.rename_func("WEEKOFYEAR")
  t[YearOfWeek] = (g, e) => {
    g.sql(
      Some(
        @core.mk(Extract, [
          ("this", @core.var_("ISOYEAR")),
          ("expression", e.this()),
        ]),
      ),
    )
  }
  t[YearOfWeekIso] = (g, e) => {
    g.sql(
      Some(
        @core.mk(Extract, [
          ("this", @core.var_("ISOYEAR")),
          ("expression", e.this()),
        ]),
      ),
    )
  }
  t[Xor] = xor_sql
  t[JSONObjectAgg] = @core.rename_func("JSON_GROUP_OBJECT")
  t[JSONBObjectAgg] = @core.rename_func("JSON_GROUP_OBJECT")
  t[DateBin] = @core.rename_func("TIME_BUCKET")
  t[LastDay] = last_day_sql
}
