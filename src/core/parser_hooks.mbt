// Typed hooks for Parser methods that some dialect overrides (emulates subclassing).
// A dialect override that calls `super()` must call the next implementation in the
// Python MRO: the parent dialect's implementation function, or `Parser::<name>_base`.

///|
pub(all) struct ParserHooks {
  mut negate_range : ((Parser, Expr?) -> Expr? raise SqlglotError)?
  mut parse_alias : ((Parser, Expr?, Bool) -> Expr? raise SqlglotError)?
  mut parse_alter_drop_action : ParseFn?
  mut parse_alter_table_alter : ParseFn?
  mut parse_alter_table_rename : ParseFn?
  mut parse_alter_table_set : ParseFn?
  mut parse_assignment : ParseFn?
  mut parse_bracket : ParseFn1?
  mut parse_bracket_key_value : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_charset_name : ParseFn?
  mut parse_check_constraint : ParseFn?
  mut parse_cluster_property : ParseFn?
  mut parse_column : ParseFn?
  mut parse_column_constraint : ParseFn?
  mut parse_column_def : ((Parser, Expr?, Bool) -> Expr? raise SqlglotError)?
  mut parse_column_ops : ParseFn1?
  mut parse_commit_or_rollback : ParseFn?
  mut parse_connect_with_prior : ParseFn?
  mut parse_constraint : ParseFn?
  mut parse_convert : ((Parser, Bool, Bool?) -> Expr? raise SqlglotError)?
  mut parse_create : ParseFn?
  mut parse_cte : ParseFn?
  mut parse_dcolon : ParseFn?
  mut parse_definer : ParseFn?
  mut parse_describe : ParseFn?
  mut parse_drop_column : ParseFn?
  mut parse_equality : ParseFn?
  mut parse_expression : ParseFn?
  mut parse_extract : ParseFn?
  mut parse_factor_operand : ParseFn?
  mut parse_file_location : ParseFn?
  mut parse_foreign_key : ParseFn?
  mut parse_from : ((Parser, Bool, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_function : ((Parser, Map[String, FuncBuilder]?, Bool, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_function_call : ((
    Parser,
    Map[String, FuncBuilder]?,
    Bool,
    Bool,
    Bool,
  ) -> Expr? raise SqlglotError)?
  mut parse_function_parameter : ParseFn?
  mut parse_function_properties : ParseFn?
  mut parse_generated_as_identity : ParseFn?
  mut parse_group_concat : ParseFn?
  mut parse_hint_function_call : ParseFn?
  mut parse_id_var : ((Parser, Bool, TokenSet?) -> Expr? raise SqlglotError)?
  mut parse_if : ParseFn?
  mut parse_index_params : ParseFn?
  mut parse_insert_table : ParseFn?
  mut parse_into_clause : ParseFn?
  mut parse_join : ((Parser, Bool, Bool, TokenSet?) -> Expr? raise SqlglotError)?
  mut parse_join_parts : ((Parser) -> (Token?, Token?, Token?) raise SqlglotError)?
  mut parse_json_object : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_lambda : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_lambda_arg : ParseFn?
  mut parse_lateral : ParseFn?
  mut parse_on_property : ParseFn?
  mut parse_ordered : ((Parser, (() -> Expr? raise SqlglotError)?) -> Expr? raise SqlglotError)?
  mut parse_parameter : ParseFn?
  mut parse_partition : ParseFn?
  mut parse_partition_and_order : ((Parser) -> (Array[Expr], Expr?) raise SqlglotError)?
  mut parse_partitioned_by : ParseFn?
  mut parse_pivot_aggregation : ParseFn?
  mut parse_position : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_primary : ParseFn?
  mut parse_primary_key : ((Parser, Bool, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_primary_key_part : ParseFn?
  mut parse_projections : ((Parser) -> (Array[Expr], Array[Expr]?) raise SqlglotError)?
  mut parse_property_before : ((Parser) -> Value? raise SqlglotError)?
  mut parse_range : ParseFn1?
  mut parse_returns : ParseFn?
  mut parse_set : ((Parser, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_statement : ParseFn?
  mut parse_struct_types : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_substring : ParseFn?
  mut parse_table : ((Parser, TableArgs) -> Expr? raise SqlglotError)?
  mut parse_table_hints : ((Parser) -> Array[Expr]? raise SqlglotError)?
  mut parse_table_part : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_table_parts : ((Parser, Bool, Bool, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_table_sample : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_transaction : ParseFn?
  mut parse_type : ((Parser, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_types : ((Parser, Bool, Bool, Bool, Bool) -> Expr? raise SqlglotError)?
  mut parse_unique : ParseFn?
  mut parse_unique_key : ParseFn?
  mut parse_unnest : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_update : ParseFn?
  mut parse_use : ParseFn?
  mut parse_user_defined_function : ((Parser, TokenType?) -> Expr? raise SqlglotError)?
  mut parse_user_defined_function_expression : ParseFn?
  mut parse_user_defined_type : ((Parser, Expr) -> Expr? raise SqlglotError)?
  mut parse_value : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut parse_vector_expressions : ((Parser, Array[Expr]) -> Array[Expr] raise SqlglotError)?
  mut parse_window : ((Parser, Expr?, Bool) -> Expr? raise SqlglotError)?
  mut parse_with_property : ((Parser) -> Value? raise SqlglotError)?
  mut parse_wrapped_id_vars : ((Parser, Bool) -> Array[Expr] raise SqlglotError)?
  mut parse_wrapped_select : ((Parser, Bool) -> Expr? raise SqlglotError)?
  mut pivot_column_names : ((Parser, Array[Expr]) -> Array[String] raise SqlglotError)?
  mut to_prop_eq : ((Parser, Expr, Int) -> Expr raise SqlglotError)?
  mut build_cast : ((Parser, Bool, Array[(String, Value?)]) -> Expr raise SqlglotError)?
  mut parse : ((Parser, Array[Token], String) -> Array[Expr?] raise SqlglotError)?
  mut parse_into : ((Parser, Array[Kind], Array[Token], String) -> Array[Expr?] raise SqlglotError)?
}

///|
pub fn ParserHooks::new() -> ParserHooks {
  {
    negate_range: None,
    parse_alias: None,
    parse_alter_drop_action: None,
    parse_alter_table_alter: None,
    parse_alter_table_rename: None,
    parse_alter_table_set: None,
    parse_assignment: None,
    parse_bracket: None,
    parse_bracket_key_value: None,
    parse_charset_name: None,
    parse_check_constraint: None,
    parse_cluster_property: None,
    parse_column: None,
    parse_column_constraint: None,
    parse_column_def: None,
    parse_column_ops: None,
    parse_commit_or_rollback: None,
    parse_connect_with_prior: None,
    parse_constraint: None,
    parse_convert: None,
    parse_create: None,
    parse_cte: None,
    parse_dcolon: None,
    parse_definer: None,
    parse_describe: None,
    parse_drop_column: None,
    parse_equality: None,
    parse_expression: None,
    parse_extract: None,
    parse_factor_operand: None,
    parse_file_location: None,
    parse_foreign_key: None,
    parse_from: None,
    parse_function: None,
    parse_function_call: None,
    parse_function_parameter: None,
    parse_function_properties: None,
    parse_generated_as_identity: None,
    parse_group_concat: None,
    parse_hint_function_call: None,
    parse_id_var: None,
    parse_if: None,
    parse_index_params: None,
    parse_insert_table: None,
    parse_into_clause: None,
    parse_join: None,
    parse_join_parts: None,
    parse_json_object: None,
    parse_lambda: None,
    parse_lambda_arg: None,
    parse_lateral: None,
    parse_on_property: None,
    parse_ordered: None,
    parse_parameter: None,
    parse_partition: None,
    parse_partition_and_order: None,
    parse_partitioned_by: None,
    parse_pivot_aggregation: None,
    parse_position: None,
    parse_primary: None,
    parse_primary_key: None,
    parse_primary_key_part: None,
    parse_projections: None,
    parse_property_before: None,
    parse_range: None,
    parse_returns: None,
    parse_set: None,
    parse_statement: None,
    parse_struct_types: None,
    parse_substring: None,
    parse_table: None,
    parse_table_hints: None,
    parse_table_part: None,
    parse_table_parts: None,
    parse_table_sample: None,
    parse_transaction: None,
    parse_type: None,
    parse_types: None,
    parse_unique: None,
    parse_unique_key: None,
    parse_unnest: None,
    parse_update: None,
    parse_use: None,
    parse_user_defined_function: None,
    parse_user_defined_function_expression: None,
    parse_user_defined_type: None,
    parse_value: None,
    parse_vector_expressions: None,
    parse_window: None,
    parse_with_property: None,
    parse_wrapped_id_vars: None,
    parse_wrapped_select: None,
    pivot_column_names: None,
    to_prop_eq: None,
    build_cast: None,
    parse: None,
    parse_into: None,
  }
}

///|
pub fn ParserHooks::copy(self : ParserHooks) -> ParserHooks {
  { ..self, }
}

///|
/// Keyword arguments of `_parse_table`.
pub(all) struct TableArgs {
  schema : Bool
  joins : Bool
  alias_tokens : TokenSet?
  parse_bracket : Bool
  is_db_reference : Bool
  parse_partition : Bool
  consume_pipe : Bool
}
