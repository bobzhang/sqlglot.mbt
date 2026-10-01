///|
/// Where a property is placed in a `CREATE` statement.
pub(all) enum PropertiesLocation {
  PostCreate
  PostName
  PostSchema
  PostWith
  PostAlias
  PostExpression
  PostIndex
  Unsupported
} derive(Eq, Hash, Debug)

///|
/// How a dialect normalizes identifiers.
pub(all) enum NormalizationStrategy {
  Lowercase
  Uppercase
  CaseSensitive
  CaseInsensitive
  CaseInsensitiveUppercase
} derive(Eq, Hash, Debug)

///|
/// A Python attribute whose value is either a string or a boolean.
pub(all) enum StrOrBool {
  S(String)
  B(Bool)
} derive(Eq, Debug)
