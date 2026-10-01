// Port of sqlglot/generators/starrocks.py

///|
/// StarRocks doesn't support BETWEEN in DELETE statements, so we convert
/// BETWEEN expressions to explicit comparisons.
///
/// https://docs.starrocks.io/docs/sql-reference/sql-statements/table_bucket_part_index/DELETE/#parameters
fn eliminate_between_in_delete(expression : @core.Expr) -> @core.Expr {
  match expression.arg("where") {
    Some(where_) =>
      for between in where_.find_all([Between]) {
        between.replace(
          Some(
            @core.and_(
              [
                @core.mk(GTE, [
                  ("this", between.this_().copy()),
                  ("expression", between.arg("low")),
                ]),
                @core.mk(LTE, [
                  ("this", between.this_().copy()),
                  ("expression", between.arg("high")),
                ]),
              ],
              copy=false,
              wrap=true,
            ),
          ),
        )
        |> ignore
      }
    None => ()
  }
  expression
}

///|
/// https://docs.starrocks.io/docs/sql-reference/sql-functions/spatial-functions/st_distance_sphere/
pub fn st_distance_sphere(
  g : @core.Generator,
  e : @core.Expr,
) -> String raise @core.SqlglotError {
  let point1 = e.this()
  let point2 = e.expression()
  let point1_x = g.func("ST_X", [point1])
  let point1_y = g.func("ST_Y", [point1])
  let point2_x = g.func("ST_X", [point2])
  let point2_y = g.func("ST_Y", [point2])
  g.func("ST_Distance_Sphere", [point1_x, point1_y, point2_x, point2_y])
}

///|
fn configure_generator(d : @core.Dialect) -> Unit {
  @mysql.register_settings(d, s => {
    s.varchar_requires_size = false
    s.cast_mapping = Map([])
    s.sql_security_view_location = PostSchema
  })
  let t = d.gen_fns.transforms
  // StarRocks uses the native TRIM(str, chars)/LTRIM/RTRIM function form, not
  // MySQL's TRIM(chars FROM str) syntax, so it falls back to the base generator.
  t.remove(DateTrunc)
  t.remove(Trim)
  t[ArgMax] = @core.rename_func("MAX_BY")
  t[ArgMin] = @core.rename_func("MIN_BY")
  t[Array] = @core.inline_array_sql
  t[ArrayAgg] = @core.rename_func("ARRAY_AGG")
  // a <@ b (ArrayContainedBy) is equivalent to ARRAY_CONTAINS_ALL(b, a)
  t[ArrayContainedBy] = (g, e) => {
    g.func("ARRAY_CONTAINS_ALL", [e.expression(), e.this()])
  }
  t[ArrayContainsAll] = @core.rename_func("ARRAY_CONTAINS_ALL")
  t[ArrayFilter] = @core.rename_func("ARRAY_FILTER")
  t[ArrayToString] = @core.rename_func("ARRAY_JOIN")
  t[ApproxDistinct] = @core.approx_count_distinct_sql
  t[CurrentVersion] = (_, _) => "CURRENT_VERSION()"
  t[DateDiff] = (g, e) => {
    g.func("DATE_DIFF", [
      @core.weekstart_unit_to_str(g, e),
      e.this(),
      e.expression(),
    ])
  }
  t[Delete] = @core.preprocess([e => eliminate_between_in_delete(e)])
  t[Flatten] = @core.rename_func("ARRAY_FLATTEN")
  t[JSONExtractScalar] = (g, e) => @core.arrow_json_extract_sql(g, e)
  t[JSONExtract] = (g, e) => @core.arrow_json_extract_sql(g, e)
  // Both MAP forms (two-array MAP([keys], [values]) and variadic MAP(k1, v1, ...))
  // generate StarRocks' variadic MAP(k1, v1, k2, v2, ...) constructor
  t[Map] = (g, e) => @core.var_map_sql(g, e, map_func_name="MAP")
  t[Property] = @core.property_sql
  t[RegexpLike] = @core.rename_func("REGEXP")
  // Inherited from MySQL, minus operations StarRocks supports natively
  // (QUALIFY, FULL OUTER JOIN, SEMI/ANTI JOIN)
  t[Select] = @core.preprocess([
    @core.eliminate_distinct_on, @core.unnest_generate_date_array_using_recursive_cte,
  ])
  t[SchemaCommentProperty] = (g, e) => g.naked_property(e)
  t[SqlSecurityProperty] = (g, e) => "SECURITY \{g.sql_key(e, "this")}"
  t[StDistance] = st_distance_sphere
  t[StrToUnix] = (g, e) => {
    g.func("UNIX_TIMESTAMP", [e.this(), g.format_time(e)])
  }
  t[TimestampTrunc] = (g, e) => {
    g.func("DATE_TRUNC", [@core.weekstart_unit_to_str(g, e), e.this()])
  }
  t[TimeStrToDate] = @core.rename_func("TO_DATE")
  t[UnixToStr] = (g, e) => g.func("FROM_UNIXTIME", [e.this(), g.format_time(e)])
  t[UnixToTime] = @core.rename_func("FROM_UNIXTIME")
  t[VarMap] = (g, e) => @core.var_map_sql(g, e, map_func_name="MAP")
  let m = d.gen_fns.methods
  let parent_ignorenulls_sql = m.get(IgnoreNulls)
  m[IgnoreNulls] = (g, e) => {
    // IGNORE NULLS follows the first argument, e.g. LAG(x IGNORE NULLS, 1, 0)
    // https://docs.starrocks.io/docs/sql-reference/sql-functions/Window_function/
    match e.this() {
      Some(func) if func.kind.is_any([FirstValue, LastValue, Lag, Lead]) =>
        g.func(func.kind.sql_name(), [
          Some(
            @core.Value::Str(
              g.ignorenulls_sql(@core.mk1(IgnoreNulls, func.this())),
            ),
          ),
          func.get("offset"),
          func.get("default"),
        ])
      _ =>
        match parent_ignorenulls_sql {
          Some(f) => f(g, e)
          None => g.ignorenulls_sql(e)
        }
    }
  }
  // RESPECT NULLS is the default behavior, and StarRocks rejects the keyword
  m[RespectNulls] = (g, e) => g.sql_key(e, "this")
  let parent_create_sql = m.get(Create)
  m[Create] = (g, e) => {
    // Starrocks' primary key is defined outside of the schema, so we need to move it there
    match e.this() {
      Some(schema) if schema.kind == Schema =>
        match schema.find([PrimaryKey]) {
          Some(primary_key) => {
            let props = match e.arg("properties") {
              Some(props) => props
              None => {
                let props = @core.mk(Properties, [
                  ("expressions", ([] : Array[@core.Expr])),
                ])
                e.set("properties", props)
                props
              }
            }
            // Verify if the first one is an engine property. Is true then insert it after the engine,
            // otherwise insert it at the beginning
            let engine_index = match props.find([EngineProperty]) {
              Some(engine) => engine.index.unwrap_or(0)
              None => -1
            }
            props.set_at(
              "expressions",
              primary_key.pop(),
              engine_index + 1,
              overwrite=false,
            )
          }
          None => ()
        }
      _ => ()
    }
    match parent_create_sql {
      Some(f) => f(g, e)
      None => g.create_sql(e)
    }
  }
  m[PartitionedByProperty] = (g, e) => {
    match e.this() {
      Some(this) if this.kind == Schema => {
        // For MVs, StarRocks needs outer parentheses.
        let create = e.find_ancestor([Create])
        let mut sql = g.expressions(expression=this, flat=true)
        let is_view = match create {
          Some(c) => c.text("kind") == "VIEW"
          None => false
        }
        if is_view ||
          this
          .expressions()
          .iter()
          .all(col => col.kind.is_any([Column, Identifier])) {
          sql = "(\{sql})"
        }
        "PARTITION BY \{sql}"
      }
      this => "PARTITION BY \{g.sql(this)}"
    }
  }
  m[ClusterProperty] = (g, e) => {
    // Generate StarRocks ORDER BY clause for clustering.
    if e.has("this") {
      g.unsupported("Unsupported CLUSTER BY \{g.sql_key(e, "this")}")
      return ""
    }
    let expressions = g.expressions(expression=e, flat=true)
    "ORDER BY (\{expressions})"
  }
  m[RefreshTriggerProperty] = (g, e) => {
    // Generate StarRocks REFRESH clause for materialized views.
    // There is a little difference of the syntax between StarRocks and Doris.
    let method_ = g.sql_key(e, "method")
    let method_ = if method_ != "" { " \{method_}" } else { "" }
    let kind = g.sql_key(e, "kind")
    let kind = if kind != "" { " \{kind}" } else { "" }
    let starts = g.sql_key(e, "starts")
    let starts = if starts != "" { " START (\{starts})" } else { "" }
    let every = g.sql_key(e, "every")
    let unit = g.sql_key(e, "unit")
    let every = if every != "" && unit != "" {
      " EVERY (INTERVAL \{every} \{unit})"
    } else {
      ""
    }
    "REFRESH\{method_}\{kind}\{starts}\{every}"
  }
}
