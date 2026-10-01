// Direct assertions of tests/dialects/test_singlestore.py (the Validator checks are
// replayed from fixtures by src/dialect_tests).

///|
test "TestSingleStore.test_singlestore" {
  let t = t(dialect="singlestore")
  let ast = parse_one(
    "SELECT id AS my_id FROM data WHERE my_id = 1 GROUP BY my_id HAVING my_id = 1",
    read="singlestore",
  )
  let ast = a_qualify(
    ast,
    dialect="singlestore",
    schema="{\"data\": {\"id\": \"INT\", \"my_id\": \"INT\"}}",
  )
  t.eq(
    sql(ast, dialect="singlestore"),
    "SELECT `data`.`id` AS `my_id` FROM `data` AS `data` WHERE `data`.`my_id` = 1 GROUP BY `data`.`my_id` HAVING `data`.`id` = 1",
  )
  t.done()
}

///|
test "TestSingleStore.test_json" {
  let t = t(dialect="singlestore")
  t.validate_identity("JSON_BUILD_ARRAY(id, name)").assert_is(JSONArray) |> ignore
  t.validate_identity("JSON_BUILD_OBJECT('name', name)").assert_is(JSONObject)
  |> ignore
  t.done()
}

///|
test "TestSingleStore.test_match_against" {
  let t = t(dialect="singlestore")
  for sql_ in [
    "SELECT MATCH(name) AGAINST('search term') FROM products", "SELECT MATCH(name, name) AGAINST('book') FROM products",
    "SELECT MATCH(TABLE products2) AGAINST('search term') FROM products2",
  ] {
    t.run(() => t.validate_identity(sql_).expressions()[0].assert_is(MatchAgainst))
    |> ignore
  }
  t.done()
}
