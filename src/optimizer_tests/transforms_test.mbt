// Tests for the optimizer-dependent transforms (port of the relevant cases of
// tests/test_transforms.py and tests/dialects/test_spark.py). Expected values were
// produced by the Python implementation. Join-mark cases parsed as Oracle are generated
// with the base dialect because the Oracle generator port lacks its Subquery override.

///|
fn explode_sql(
  sql : String,
  index_offset~ : Int,
  unnest_map? : Bool = false,
  annotate? : Bool = false,
) -> String raise @core.SqlglotError {
  let spark = @sqlglot.dialect("spark")
  let e = @core.parse_one(sql, dialect=spark)
  let e = if annotate {
    let schema = @optimizer.MappingSchema::new(
      schema=@optimizer.schema_from_json_string(
        "{\"tbl\": {\"cells\": \"MAP<INT, STRING>\", \"arr\": \"ARRAY<INT>\"}}",
      ),
      dialect=spark,
    )
    @optimizer.annotate_types(e, schema~, dialect=spark)
  } else {
    e
  }
  let transform = @optimizer.explode_projection_to_unnest(
    index_offset~,
    unnest_map~,
  )
  @optimizer.sql_of(transform(e))
}

///|
/// Python `parse_one(sql, dialect).transform(eliminate_join_marks).sql(dialect)`.
fn join_marks_sql(
  sql : String,
  dialect : String,
) -> String raise @core.SqlglotError {
  let e = @sqlglot.parse_one(sql, read=dialect)
  let error : Ref[@core.SqlglotError?] = Ref(None)
  let result = e.transform(node => {
    if error.val is Some(_) {
      return Some(node)
    }
    Some(
      @optimizer.eliminate_join_marks(node) catch {
        err => {
          error.val = Some(err)
          node
        }
      },
    )
  })
  match error.val {
    Some(err) => raise err
    None =>
      @sqlglot.generate(
        result,
        dialect=if dialect == "oracle" { "" } else { dialect },
      )
  }
}

///|
fn join_marks_or_error(sql : String, dialect : String) -> String {
  join_marks_sql(sql, dialect) catch {
    err => err.to_string()
  }
}

///|
test "transforms explode_projection_to_unnest index_offset=0" {
  inspect(
    explode_sql("SELECT EXPLODE(x) FROM tbl", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(x)) - 1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(col) FROM _u", index_offset=0),
    content="SELECT CASE WHEN _u_2.pos = _u_3.pos_2 THEN _u_3.col_2 END AS col_2 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(col)) - 1)) AS _u_2(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_3(col_2, pos_2) WHERE _u_2.pos = _u_3.pos_2 OR (_u_2.pos > (ARRAY_LENGTH(col) - 1) AND _u_3.pos_2 = (ARRAY_LENGTH(col) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(col) AS exploded FROM schema.tbl",
      index_offset=0,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.exploded END AS exploded FROM schema.tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(col)) - 1)) AS _u(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_2(exploded, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(col) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(col) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(ARRAY(1, 2))", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(ARRAY(1, 2))) - 1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(1, 2)) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(1, 2)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(1, 2)) - 1))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(ARRAY(2, 3)) AS x", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.x END AS x, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2 FROM UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))) - 1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(x, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(x) AS (a, b)", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.a THEN _u_2.b END AS b, CASE WHEN _u.pos = _u_2.a THEN _u_2.a END AS a FROM UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(x)) - 1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(b, a) WHERE _u.pos = _u_2.a OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.a = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE(ARRAY(2, 3)), EXPLODE(ARRAY(4, 5, 6)) FROM tbl",
      index_offset=0,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2, CASE WHEN _u.pos = _u_3.pos_3 THEN _u_3.col_2 END AS col_2 FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(ARRAY(2, 3)), ARRAY_LENGTH(ARRAY(4, 5, 6))) - 1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(col, pos_2) CROSS JOIN UNNEST(ARRAY(4, 5, 6)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE (_u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))) AND (_u.pos = _u_3.pos_3 OR (_u.pos > (ARRAY_LENGTH(ARRAY(4, 5, 6)) - 1) AND _u_3.pos_3 = (ARRAY_LENGTH(ARRAY(4, 5, 6)) - 1)))",
  )
  inspect(
    explode_sql(
      "SELECT col, pos, POSEXPLODE(ARRAY(2, 3)) FROM _u",
      index_offset=0,
    ),
    content="SELECT col, pos, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.col_2 END AS col_2, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.pos_3 END AS pos_3 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))) - 1)) AS _u_2(pos_2) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE _u_2.pos_2 = _u_3.pos_3 OR (_u_2.pos_2 > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_3.pos_3 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE_OUTER(x) FROM tbl", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)) - 1)) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE_OUTER(x) AS (p, v) FROM tbl WHERE y > 1",
      index_offset=0,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.p THEN _u_2.v END AS v, CASE WHEN _u.pos = _u_2.p THEN _u_2.p END AS p FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)) - 1)) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(v, p) WHERE y > 1 AND (_u.pos = _u_2.p OR (_u.pos > (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1) AND _u_2.p = (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1)))",
  )
  inspect(
    explode_sql(
      "SELECT a, EXPLODE(x) + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id",
      index_offset=0,
    ),
    content="SELECT a, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.e END + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(x)) - 1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(e, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(tbl.x) FROM tbl", index_offset=0),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(0, GREATEST(ARRAY_LENGTH(tbl.x)) - 1)) AS _u(pos) CROSS JOIN UNNEST(tbl.x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(tbl.x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(tbl.x) - 1))",
  )
  inspect(explode_sql("SELECT 1 AS a", index_offset=0), content="SELECT 1 AS a")
}

///|
test "transforms explode_projection_to_unnest index_offset=1" {
  inspect(
    explode_sql("SELECT EXPLODE(x) FROM tbl", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(x)))) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(x) AND _u_2.pos_2 = ARRAY_LENGTH(x))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(col) FROM _u", index_offset=1),
    content="SELECT CASE WHEN _u_2.pos = _u_3.pos_2 THEN _u_3.col_2 END AS col_2 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(col)))) AS _u_2(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_3(col_2, pos_2) WHERE _u_2.pos = _u_3.pos_2 OR (_u_2.pos > ARRAY_LENGTH(col) AND _u_3.pos_2 = ARRAY_LENGTH(col))",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(col) AS exploded FROM schema.tbl",
      index_offset=1,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.exploded END AS exploded FROM schema.tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(col)))) AS _u(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_2(exploded, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(col) AND _u_2.pos_2 = ARRAY_LENGTH(col))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(ARRAY(1, 2))", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(ARRAY(1, 2))))) AS _u(pos) CROSS JOIN UNNEST(ARRAY(1, 2)) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(ARRAY(1, 2)) AND _u_2.pos_2 = ARRAY_LENGTH(ARRAY(1, 2)))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(ARRAY(2, 3)) AS x", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.x END AS x, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2 FROM UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))))) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(x, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(ARRAY(2, 3)) AND _u_2.pos_2 = ARRAY_LENGTH(ARRAY(2, 3)))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(x) AS (a, b)", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.a THEN _u_2.b END AS b, CASE WHEN _u.pos = _u_2.a THEN _u_2.a END AS a FROM UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(x)))) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(b, a) WHERE _u.pos = _u_2.a OR (_u.pos > ARRAY_LENGTH(x) AND _u_2.a = ARRAY_LENGTH(x))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE(ARRAY(2, 3)), EXPLODE(ARRAY(4, 5, 6)) FROM tbl",
      index_offset=1,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2, CASE WHEN _u.pos = _u_3.pos_3 THEN _u_3.col_2 END AS col_2 FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(ARRAY(2, 3)), ARRAY_LENGTH(ARRAY(4, 5, 6))))) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(col, pos_2) CROSS JOIN UNNEST(ARRAY(4, 5, 6)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE (_u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(ARRAY(2, 3)) AND _u_2.pos_2 = ARRAY_LENGTH(ARRAY(2, 3)))) AND (_u.pos = _u_3.pos_3 OR (_u.pos > ARRAY_LENGTH(ARRAY(4, 5, 6)) AND _u_3.pos_3 = ARRAY_LENGTH(ARRAY(4, 5, 6))))",
  )
  inspect(
    explode_sql(
      "SELECT col, pos, POSEXPLODE(ARRAY(2, 3)) FROM _u",
      index_offset=1,
    ),
    content="SELECT col, pos, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.col_2 END AS col_2, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.pos_3 END AS pos_3 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))))) AS _u_2(pos_2) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE _u_2.pos_2 = _u_3.pos_3 OR (_u_2.pos_2 > ARRAY_LENGTH(ARRAY(2, 3)) AND _u_3.pos_3 = ARRAY_LENGTH(ARRAY(2, 3)))",
  )
  inspect(
    explode_sql("SELECT EXPLODE_OUTER(x) FROM tbl", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)))) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) AND _u_2.pos_2 = ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE_OUTER(x) AS (p, v) FROM tbl WHERE y > 1",
      index_offset=1,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.p THEN _u_2.v END AS v, CASE WHEN _u.pos = _u_2.p THEN _u_2.p END AS p FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)))) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(v, p) WHERE y > 1 AND (_u.pos = _u_2.p OR (_u.pos > ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) AND _u_2.p = ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)))",
  )
  inspect(
    explode_sql(
      "SELECT a, EXPLODE(x) + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id",
      index_offset=1,
    ),
    content="SELECT a, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.e END + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(x)))) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(e, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(x) AND _u_2.pos_2 = ARRAY_LENGTH(x))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(tbl.x) FROM tbl", index_offset=1),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(tbl.x)))) AS _u(pos) CROSS JOIN UNNEST(tbl.x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(tbl.x) AND _u_2.pos_2 = ARRAY_LENGTH(tbl.x))",
  )
  inspect(explode_sql("SELECT 1 AS a", index_offset=1), content="SELECT 1 AS a")
}

///|
test "transforms explode_projection_to_unnest index_offset=2" {
  inspect(
    explode_sql("SELECT EXPLODE(x) FROM tbl", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(x)) - -1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(col) FROM _u", index_offset=2),
    content="SELECT CASE WHEN _u_2.pos = _u_3.pos_2 THEN _u_3.col_2 END AS col_2 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(col)) - -1)) AS _u_2(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_3(col_2, pos_2) WHERE _u_2.pos = _u_3.pos_2 OR (_u_2.pos > (ARRAY_LENGTH(col) - 1) AND _u_3.pos_2 = (ARRAY_LENGTH(col) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(col) AS exploded FROM schema.tbl",
      index_offset=2,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.exploded END AS exploded FROM schema.tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(col)) - -1)) AS _u(pos) CROSS JOIN UNNEST(col) WITH ORDINALITY AS _u_2(exploded, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(col) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(col) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(ARRAY(1, 2))", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(ARRAY(1, 2))) - -1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(1, 2)) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(1, 2)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(1, 2)) - 1))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(ARRAY(2, 3)) AS x", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.x END AS x, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2 FROM UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))) - -1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(x, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))",
  )
  inspect(
    explode_sql("SELECT POSEXPLODE(x) AS (a, b)", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.a THEN _u_2.b END AS b, CASE WHEN _u.pos = _u_2.a THEN _u_2.a END AS a FROM UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(x)) - -1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(b, a) WHERE _u.pos = _u_2.a OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.a = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE(ARRAY(2, 3)), EXPLODE(ARRAY(4, 5, 6)) FROM tbl",
      index_offset=2,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.pos_2 END AS pos_2, CASE WHEN _u.pos = _u_3.pos_3 THEN _u_3.col_2 END AS col_2 FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(ARRAY(2, 3)), ARRAY_LENGTH(ARRAY(4, 5, 6))) - -1)) AS _u(pos) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_2(col, pos_2) CROSS JOIN UNNEST(ARRAY(4, 5, 6)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE (_u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))) AND (_u.pos = _u_3.pos_3 OR (_u.pos > (ARRAY_LENGTH(ARRAY(4, 5, 6)) - 1) AND _u_3.pos_3 = (ARRAY_LENGTH(ARRAY(4, 5, 6)) - 1)))",
  )
  inspect(
    explode_sql(
      "SELECT col, pos, POSEXPLODE(ARRAY(2, 3)) FROM _u",
      index_offset=2,
    ),
    content="SELECT col, pos, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.col_2 END AS col_2, CASE WHEN _u_2.pos_2 = _u_3.pos_3 THEN _u_3.pos_3 END AS pos_3 FROM _u CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(ARRAY(2, 3))) - -1)) AS _u_2(pos_2) CROSS JOIN UNNEST(ARRAY(2, 3)) WITH ORDINALITY AS _u_3(col_2, pos_3) WHERE _u_2.pos_2 = _u_3.pos_3 OR (_u_2.pos_2 > (ARRAY_LENGTH(ARRAY(2, 3)) - 1) AND _u_3.pos_3 = (ARRAY_LENGTH(ARRAY(2, 3)) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE_OUTER(x) FROM tbl", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)) - -1)) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1))",
  )
  inspect(
    explode_sql(
      "SELECT POSEXPLODE_OUTER(x) AS (p, v) FROM tbl WHERE y > 1",
      index_offset=2,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.p THEN _u_2.v END AS v, CASE WHEN _u.pos = _u_2.p THEN _u_2.p END AS p FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END)) - -1)) AS _u(pos) CROSS JOIN UNNEST(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) WITH ORDINALITY AS _u_2(v, p) WHERE y > 1 AND (_u.pos = _u_2.p OR (_u.pos > (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1) AND _u_2.p = (ARRAY_LENGTH(CASE WHEN ARRAY_LENGTH(COALESCE(x, ARRAY())) = 0 THEN ARRAY(x[-1]) ELSE x END) - 1)))",
  )
  inspect(
    explode_sql(
      "SELECT a, EXPLODE(x) + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id",
      index_offset=2,
    ),
    content="SELECT a, CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.e END + 1 AS e FROM tbl JOIN t2 ON tbl.id = t2.id CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(x)) - -1)) AS _u(pos) CROSS JOIN UNNEST(x) WITH ORDINALITY AS _u_2(e, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(x) - 1))",
  )
  inspect(
    explode_sql("SELECT EXPLODE(tbl.x) FROM tbl", index_offset=2),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(2, GREATEST(ARRAY_LENGTH(tbl.x)) - -1)) AS _u(pos) CROSS JOIN UNNEST(tbl.x) WITH ORDINALITY AS _u_2(col, pos_2) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > (ARRAY_LENGTH(tbl.x) - 1) AND _u_2.pos_2 = (ARRAY_LENGTH(tbl.x) - 1))",
  )
  inspect(explode_sql("SELECT 1 AS a", index_offset=2), content="SELECT 1 AS a")
}

///|
test "transforms explode_projection_to_unnest unnest_map" {
  inspect(
    explode_sql(
      "SELECT EXPLODE(tbl.cells) AS (cell_id, cell_name) FROM tbl",
      index_offset=1,
      unnest_map=true,
      annotate=true,
    ),
    content="SELECT _u_2.cell_id AS cell_id, _u_2.cell_name AS cell_name FROM tbl CROSS JOIN UNNEST(tbl.cells) AS _u_2(cell_id, cell_name)",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(tbl.cells) FROM tbl",
      index_offset=1,
      unnest_map=true,
      annotate=true,
    ),
    content="SELECT _u_2.key AS key, _u_2.value AS value FROM tbl CROSS JOIN UNNEST(tbl.cells) AS _u_2(key, value)",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(tbl.cells) AS (k, v), EXPLODE(tbl.arr) FROM tbl",
      index_offset=1,
      unnest_map=true,
      annotate=true,
    ),
    content="SELECT _u_2.k AS k, _u_2.v AS v, CASE WHEN _u.pos = _u_3.pos_2 THEN _u_3.col END AS col FROM tbl CROSS JOIN UNNEST(tbl.cells) AS _u_2(k, v) CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(tbl.arr)))) AS _u(pos) CROSS JOIN UNNEST(tbl.arr) WITH ORDINALITY AS _u_3(col, pos_2) WHERE _u.pos = _u_3.pos_2 OR (_u.pos > ARRAY_LENGTH(tbl.arr) AND _u_3.pos_2 = ARRAY_LENGTH(tbl.arr))",
  )
  inspect(
    explode_sql(
      "SELECT key, EXPLODE(tbl.cells) FROM tbl WHERE tbl.arr IS NOT NULL",
      index_offset=1,
      unnest_map=true,
      annotate=true,
    ),
    content="SELECT key, _u_2.key_2 AS key_2, _u_2.value AS value FROM tbl CROSS JOIN UNNEST(tbl.cells) AS _u_2(key_2, value) WHERE NOT tbl.arr IS NULL",
  )
  inspect(
    explode_sql(
      "SELECT EXPLODE(tbl.arr), EXPLODE(tbl.cells) FROM tbl",
      index_offset=1,
      unnest_map=true,
      annotate=true,
    ),
    content="SELECT CASE WHEN _u.pos = _u_2.pos_2 THEN _u_2.col END AS col, _u_3.key AS key, _u_3.value AS value FROM tbl CROSS JOIN UNNEST(GENERATE_SERIES(1, GREATEST(ARRAY_LENGTH(tbl.arr)))) AS _u(pos) CROSS JOIN UNNEST(tbl.arr) WITH ORDINALITY AS _u_2(col, pos_2) CROSS JOIN UNNEST(tbl.cells) AS _u_3(key, value) WHERE _u.pos = _u_2.pos_2 OR (_u.pos > ARRAY_LENGTH(tbl.arr) AND _u_2.pos_2 = ARRAY_LENGTH(tbl.arr))",
  )
}

///|
test "transforms eliminate_join_marks oracle" {
  inspect(
    join_marks_or_error(
      "SELECT a.f1, b.f2 FROM a JOIN b ON a.id = b.id WHERE a.blabla = 'a'", "oracle",
    ),
    content="SELECT a.f1, b.f2 FROM a JOIN b ON a.id = b.id WHERE a.blabla = 'a'",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y (+) > 5", "oracle",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x AND T2.y > 5",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x (+) = T2.x and T2.y > 5", "oracle",
    ),
    content="SELECT T1.d, T2.c FROM T2 LEFT JOIN T1 ON T1.x = T2.x WHERE T2.y > 5",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y (+) IS NULL",
      "oracle",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x AND T2.y IS NULL",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y IS NULL", "oracle",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x WHERE T2.y IS NULL",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T1.Z > 4", "oracle",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x WHERE T1.Z > 4",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col(+)", "oracle",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2, table3, table4 WHERE table1.col = table2.col(+) and table2.col >= table3.col(+) and table1.col = table4.col(+)",
      "oracle",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col LEFT JOIN table3 ON table2.col >= table3.col LEFT JOIN table4 ON table1.col = table4.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2, table3 WHERE table1.col = table2.col(+) and table2.col >= table3.col(+)",
      "oracle",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col LEFT JOIN table3 ON table2.col >= table3.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col1(+) + table2.col2(+)",
      "oracle",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col1 + table2.col2",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col1(+) + 25", "oracle",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col1 + 25",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM a, b, c WHERE a.id = b.id AND b.id(+) = c.id", "oracle",
    ),
    content="SELECT * FROM a LEFT JOIN b ON b.id = c.id CROSS JOIN c WHERE a.id = b.id",
  )
  inspect(
    join_marks_or_error(
      "SELECT table1.id, table2.cloumn1, table3.id FROM table1, table2, (SELECT tableInner1.id FROM tableInner1, tableInner2 WHERE tableInner1.id = tableInner2.id(+)) AS table3 WHERE table1.id = table2.id(+) and table1.id = table3.id(+)",
      "oracle",
    ),
    content="SELECT table1.id, table2.cloumn1, table3.id FROM table1 LEFT JOIN table2 ON table1.id = table2.id LEFT JOIN (SELECT tableInner1.id FROM tableInner1 LEFT JOIN tableInner2 ON tableInner1.id = tableInner2.id) AS table3 ON table1.id = table3.id",
  )
  inspect(
    join_marks_or_error(
      "select a.id from a, b where a.id = b.id (+) AND b.d (+) = const", "oracle",
    ),
    content="SELECT a.id FROM a LEFT JOIN b ON a.id = b.id AND b.d = const",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where (1 = 1) and (t1.id = t2.id1 (+))", "oracle",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = t2.id1 WHERE (1 = 1)",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where t1.id = case when t2.id (+) = 'n/a' then null else t2.id (+) end",
      "oracle",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = CASE WHEN t2.id = 'n/a' THEN NULL ELSE t2.id END",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where t1.id = t2.id1 (+) or t1.id = t2.id2 (+)",
      "oracle",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = t2.id1 OR t1.id = t2.id2",
  )
  inspect(
    join_marks_or_error(
      "SELECT c.customer_name, (SELECT MAX(o.order_date) FROM orders o WHERE o.customer_id(+) = c.customer_id) AS latest_order_date FROM customers c",
      "oracle",
    ),
    content="ValueError: AssertionError: Correlated queries are not supported",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM t1, t2 WHERE t1.a = t2.a (+) AND t1.b (+) = t2.b", "oracle",
    ),
    content="ValueError: AssertionError: Cannot determine which table to use in the new FROM clause",
  )
}

///|
test "transforms eliminate_join_marks redshift" {
  inspect(
    join_marks_or_error(
      "SELECT a.f1, b.f2 FROM a JOIN b ON a.id = b.id WHERE a.blabla = 'a'", "redshift",
    ),
    content="SELECT a.f1, b.f2 FROM a JOIN b ON a.id = b.id WHERE a.blabla = 'a'",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y (+) > 5", "redshift",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x AND T2.y > 5",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x (+) = T2.x and T2.y > 5", "redshift",
    ),
    content="SELECT T1.d, T2.c FROM T2 LEFT JOIN T1 ON T1.x = T2.x WHERE T2.y > 5",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y (+) IS NULL",
      "redshift",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x AND T2.y IS NULL",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T2.y IS NULL", "redshift",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x WHERE T2.y IS NULL",
  )
  inspect(
    join_marks_or_error(
      "SELECT T1.d, T2.c FROM T1, T2 WHERE T1.x = T2.x (+) and T1.Z > 4", "redshift",
    ),
    content="SELECT T1.d, T2.c FROM T1 LEFT JOIN T2 ON T1.x = T2.x WHERE T1.Z > 4",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col(+)", "redshift",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2, table3, table4 WHERE table1.col = table2.col(+) and table2.col >= table3.col(+) and table1.col = table4.col(+)",
      "redshift",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col LEFT JOIN table3 ON table2.col >= table3.col LEFT JOIN table4 ON table1.col = table4.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2, table3 WHERE table1.col = table2.col(+) and table2.col >= table3.col(+)",
      "redshift",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col LEFT JOIN table3 ON table2.col >= table3.col",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col1(+) + table2.col2(+)",
      "redshift",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col1 + table2.col2",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM table1, table2 WHERE table1.col = table2.col1(+) + 25", "redshift",
    ),
    content="SELECT * FROM table1 LEFT JOIN table2 ON table1.col = table2.col1 + 25",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM a, b, c WHERE a.id = b.id AND b.id(+) = c.id", "redshift",
    ),
    content="SELECT * FROM a LEFT JOIN b ON b.id = c.id CROSS JOIN c WHERE a.id = b.id",
  )
  inspect(
    join_marks_or_error(
      "SELECT table1.id, table2.cloumn1, table3.id FROM table1, table2, (SELECT tableInner1.id FROM tableInner1, tableInner2 WHERE tableInner1.id = tableInner2.id(+)) AS table3 WHERE table1.id = table2.id(+) and table1.id = table3.id(+)",
      "redshift",
    ),
    content="SELECT table1.id, table2.cloumn1, table3.id FROM table1 LEFT JOIN table2 ON table1.id = table2.id LEFT JOIN (SELECT tableInner1.id FROM tableInner1 LEFT JOIN tableInner2 ON tableInner1.id = tableInner2.id) AS table3 ON table1.id = table3.id",
  )
  inspect(
    join_marks_or_error(
      "select a.id from a, b where a.id = b.id (+) AND b.d (+) = const", "redshift",
    ),
    content="SELECT a.id FROM a LEFT JOIN b ON a.id = b.id AND b.d = const",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where (1 = 1) and (t1.id = t2.id1 (+))", "redshift",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = t2.id1 WHERE (1 = 1)",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where t1.id = case when t2.id (+) = 'n/a' then null else t2.id (+) end",
      "redshift",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = CASE WHEN t2.id = 'n/a' THEN NULL ELSE t2.id END",
  )
  inspect(
    join_marks_or_error(
      "select t1.a, t2.b from t1, t2 where t1.id = t2.id1 (+) or t1.id = t2.id2 (+)",
      "redshift",
    ),
    content="SELECT t1.a, t2.b FROM t1 LEFT JOIN t2 ON t1.id = t2.id1 OR t1.id = t2.id2",
  )
  inspect(
    join_marks_or_error(
      "SELECT c.customer_name, (SELECT MAX(o.order_date) FROM orders o WHERE o.customer_id(+) = c.customer_id) AS latest_order_date FROM customers c",
      "redshift",
    ),
    content="ValueError: AssertionError: Correlated queries are not supported",
  )
  inspect(
    join_marks_or_error(
      "SELECT * FROM t1, t2 WHERE t1.a = t2.a (+) AND t1.b (+) = t2.b", "redshift",
    ),
    content="ValueError: AssertionError: Cannot determine which table to use in the new FROM clause",
  )
}

///|
test "transforms eliminate_join_marks keeps a consistent tree" {
  let sql = "select a.id from a, b where a.id = b.id (+) AND b.d (+) = const"
  for dialect in ["oracle", "redshift"] {
    let tree = @optimizer.eliminate_join_marks(
      @sqlglot.parse_one(sql, read=dialect),
    )
    for table in tree.find_all([Table]) {
      assert_true(table.parent_select() is Some(s) && s.kind == Select)
    }
    inspect(
      @sqlglot.generate(tree, dialect~),
      content="SELECT a.id FROM a LEFT JOIN b ON a.id = b.id AND b.d = const",
    )
  }
}
