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
#deprecated
pub extend PropertiesLocation with Eq::{not_equal, equal}

///|
#deprecated
pub extend PropertiesLocation with Hash::{hash, hash_combine}

///|
#deprecated
pub extend PropertiesLocation with Debug::{to_repr}

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
#deprecated
pub extend NormalizationStrategy with Eq::{not_equal, equal}

///|
#deprecated
pub extend NormalizationStrategy with Hash::{hash, hash_combine}

///|
#deprecated
pub extend NormalizationStrategy with Debug::{to_repr}

///|
/// A Python attribute whose value is either a string or a boolean.
pub(all) enum StrOrBool {
  S(String)
  B(Bool)
} derive(Eq, Debug)

///|
#deprecated
pub extend StrOrBool with Eq::{not_equal, equal}

///|
#deprecated
pub extend StrOrBool with Debug::{to_repr}
