// Port of sqlglot/optimizer/annotate_types.py (stub, filled in later).

///|
pub struct TypeAnnotator {
  schema : MappingSchema
}

///|
pub fn TypeAnnotator::new(schema : MappingSchema) -> TypeAnnotator {
  { schema, }
}

///|
pub fn TypeAnnotator::annotate_scope(self : TypeAnnotator, scope : Scope) -> Unit {
  ignore(self)
  ignore(scope)
}

///|
pub fn TypeAnnotator::uncache(
  self : TypeAnnotator,
  expression : @core.Expr,
  deep? : Bool = true,
) -> Unit {
  ignore(self)
  ignore(expression)
  ignore(deep)
}
