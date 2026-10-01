// Generator flag variants (see tools/gen_generator_variants.py): synthetic dialects that
// only change Generator/Dialect data attributes, compared with Python.

///|
fn make_flagsa() -> @core.Dialect {
  @core.Dialect::subclass(@core.base_dialect(), "flagsa", d => {
    let g = d.gen_cfg
    g.limit_fetch = "FETCH"
    g.null_ordering_supported = None
    g.set_op_modifiers = false
    g.ensure_bools = true
    g.is_bool_allowed = false
    g.tz_to_with_time_zone = true
    g.single_string_interval = true
    g.interval_allows_plural_form = false
    g.extract_allows_quotes = false
    g.values_as_table = false
    g.wrap_derived_values = false
    g.unnest_with_ordinality = false
    g.multi_arg_distinct = false
    g.supports_table_alias_columns = false
    g.tablesample_requires_parens = false
    g.tablesample_size_is_rows = false
    g.tablesample_with_method = false
    g.query_hints = false
    g.join_hints = false
    g.table_hints = false
    g.locking_reads_supported = true
    g.nvl2_supported = false
    g.supports_decode_case = false
    g.star_exclude_requires_derived_table = false
    g.supports_like_quantifiers = false
    g.supports_median = false
    g.supports_to_number = false
    g.try_supported = false
    g.supports_single_arg_concat = false
    g.last_day_supports_date_part = false
    g.can_implement_array_any = true
    g.array_size_dim_required = Some(true)
    g.parse_json_name = None
    g.collate_is_func = true
    g.cte_recursive_keyword_required = false
    g.semi_anti_join_with_side = false
    g.computed_column_with_type = false
    g.supports_table_copy = false
    g.supports_create_table_like = false
    g.alter_table_include_column_keyword = false
    g.rename_table_with_db = false
    g.supports_exploding_projections = false
    g.pad_fill_pattern_is_required = true
    g.supports_window_exclude = true
    g.supports_between_flags = true
    g.returning_end = false
    g.except_intersect_support_all_clause = false
    g.supports_select_into = true
    g.supports_uescape = false
    g.quote_json_path = false
    g.json_path_single_quote_escape = true
    g.json_path_bracketed_key_supported = false
    g.update_statement_supports_from = false
    g.matched_by_source = false
    g.duplicate_key_update_with_set = false
    g.index_on = "FOR"
    g.normalize_extract_date_parts = true
    g.supports_convert_timezone = true
    g.supports_unix_seconds = true
    g.supports_grouping_sets_as_suffix = true
    g.supports_modify_column = true
    g.supports_change_column = true
    g.supports_alter_column_nullability = true
    g.supports_alter_column_if_exists = true
    g.alter_set_wrapped = true
    g.alter_set_type = "TYPE"
    g.hex_func = "TO_HEX"
    g.star_except = "EXCLUDE"
    g.tablesample_keywords = "USING SAMPLE"
    g.tablesample_seed_keyword = "REPEATABLE"
    g.parameter_token = "$"
    g.named_placeholder_token = "@"
    g.query_hint_sep = " "
    g.groupings_sep = ""
    g.json_key_value_pair_sep = ","
    g.insert_overwrite = " OVERWRITE INTO"
    g.declare_default_assignment = "DEFAULT"
    g.inout_separator = ""
    g.array_size_name = "CARDINALITY"
    g.mod_operator = "MOD"
    g.select_kinds = []
    g.supports_unlogged_tables = true
    g.pivot_alias_with_as = false
    g.unpivot_aliases_are_identifiers = false
    g.set_assignment_requires_variable_keyword = true
    g.supports_named_cte_columns = false
    g.copy_params_are_wrapped = false
    g.copy_params_eq_required = true
    g.copy_has_into_keyword = false
    g.supports_drop_alter_iceberg_property = false
    g.ignore_nulls_in_func = true
    g.data_type_specifiers_allowed = true
    g.historical_data_post_alias = true
    g.like_property_inside_schema = true
    g.supports_merge_where = true
    g.auto_refresh_bare_intervals = true
    g.directed_joins = true
    let c = d.cfg
    c.null_ordering = "nulls_are_large"
    c.concat_coalesce = true
    c.concat_ws_coalesce = true
    c.typed_division = true
    c.log_base_first = None
    c.strict_string_concat = true
    c.unnest_column_only = true
    c.alias_post_tablesample = true
    c.alias_post_version = true
    c.index_offset = 1
    c.hex_lowercase = true
    c.tablesample_size_is_percent = true
    c.alter_table_add_required_for_each_column = false
    c.alter_table_supports_cascade = true
    c.on_condition_empty_before_error = false
    c.uuid_is_string_type = true
    c.initcap_supports_custom_delimiters = false
    c.week_offset = -1
    c.projection_aliases_shadow_source_names = true
    c.identifiers_can_start_with_digit = true
    c.hex_string_is_integer_type = true
    c.byte_string_is_bytes_type = true
  })
}

///|
fn make_flagsb() -> @core.Dialect {
  @core.Dialect::subclass(@core.base_dialect(), "flagsb", d => {
    let g = d.gen_cfg
    g.limit_is_top = true
    g.limit_fetch = "LIMIT"
    g.null_ordering_supported = Some(false)
    g.set_op_parenthesized_operands = false
    g.supports_unlogged_tables = true
    g.with_properties_prefix = "TBLPROPERTIES"
    g.ignore_nulls_in_func = true
    g.ignore_nulls_before_order = false
    g.supports_table_alias_columns = false
    g.supports_named_cte_columns = true
    g.array_size_dim_required = Some(false)
    g.supports_single_arg_concat = false
    g.expressions_without_nested_ctes = [
      @core.Select,
      @core.Insert,
      @core.Union,
    ]
    g.unsupported_types = [@core.DType::TEXT, @core.DType::JSON]
    g.type_mapping = g.type_mapping.copy()
    g.type_mapping[@core.DType::TEXT] = "STRING"
    g.type_mapping[@core.DType::INT] = "INTEGER"
    g.type_mapping[@core.DType::VARCHAR] = "STRING"
    g.token_mapping = g.token_mapping.copy()
    g.token_mapping[@core.TokenType::AUTO_INCREMENT] = "AUTOINCREMENT"
    g.reserved_keywords = g.reserved_keywords.copy()
    for k in ["x", "y", "a", "b", "c", "t"] {
      g.reserved_keywords.add(k)
    }
    g.window_funcs_with_null_ordering = [
      @core.FirstValue,
      @core.LastValue,
      @core.Rank,
    ]
    g.respect_ignore_nulls_unsupported_expressions = [@core.Max]
    g.time_part_singulars = Map::from_array([("DAYS", "DAY"), ("HOURS", "HOUR")])
    g.interval_allows_plural_form = false
    g.expression_precedes_properties_creatables = g.expression_precedes_properties_creatables.copy()
    g.expression_precedes_properties_creatables.add("TABLE")
    g.match_against_table_prefix = Some("TABLE")
    let c = d.cfg
    c.null_ordering = "nulls_are_last"
    c.log_base_first = Some(false)
    c.safe_division = true
    c.typed_division = false
    c.initcap_supports_custom_delimiters = false
  })
}

///|
fn run_variant(
  name : String,
  d : @core.Dialect,
  diffs : Array[String],
) -> (Int, Int) {
  let expected : Map[Int, (String, String)] = Map([])
  let mut i = 0
  while i + 2 < diffs.length() {
    let idx = @string.parse_int(diffs[i]) catch { _ => -1 }
    expected[idx] = (diffs[i + 1], diffs[i + 2])
    i += 3
  }
  let mut failed = 0
  for idx, ast in variant_asts {
    let (exp_sql, exp_msgs) = match expected.get(idx) {
      Some(x) => x
      None => (variant_base[2 * idx], variant_base[2 * idx + 1])
    }
    let e = parse_canonical(ast)
    let g = @core.Generator::new(d, unsupported_level=Ignore)
    let (got_sql, got_msgs) = try g.generate(e) catch {
      err => ("<error>", err.to_string())
    } noraise {
      s => (s, g.unsupported_messages.join("\n"))
    }
    if got_sql != exp_sql || (exp_sql != "<error>" && got_msgs != exp_msgs) {
      failed += 1
      println("--- [\{name}] #\{idx} \{ast}")
      if got_sql != exp_sql {
        println("  expected: \{exp_sql}")
        println("  got:      \{got_sql}")
      }
      if got_msgs != exp_msgs {
        println("  expected msgs: \{exp_msgs}")
        println("  got msgs:      \{got_msgs}")
      }
    }
  }
  (variant_asts.length(), failed)
}

///|
test "generator variants: base with messages" {
  let (total, failed) = run_variant("base", @core.base_dialect(), [])
  println("variant base: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator variants: flagsa" {
  let (total, failed) = run_variant("flagsa", make_flagsa(), variant_flagsa)
  println("variant flagsa: \{total - failed}/\{total}")
  inspect(failed, content="0")
}

///|
test "generator variants: flagsb" {
  let (total, failed) = run_variant("flagsb", make_flagsb(), variant_flagsb)
  println("variant flagsb: \{total - failed}/\{total}")
  inspect(failed, content="0")
}
