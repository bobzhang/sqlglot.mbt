// Port of tests/test_helper.py

///|
test "TestHelper.test_tsort" {
  assert_eq(@core.tsort({ "a": [] }), ["a"])
  assert_eq(@core.tsort({ "a": ["b"] }), ["b", "a"])
  assert_eq(@core.tsort({ "a": ["c"], "b": [], "c": [] }), ["b", "c", "a"])
  assert_eq(
    @core.tsort({ "a": ["b", "c"], "b": ["c"], "c": [], "d": ["a"] }),
    ["c", "b", "a", "d"],
  )
  try @core.tsort({ "a": ["b", "c"], "b": ["a"], "c": [] }) catch {
    @core.ValueError(_) => ()
    e => fail("unexpected error \{e}")
  } noraise {
    _ => fail("expected ValueError")
  }
}

///|
test "TestHelper.test_name_sequence" {
  let s1 = @core.name_sequence("a")
  let s2 = @core.name_sequence("b")
  assert_eq(s1(), "a0")
  assert_eq(s1(), "a1")
  assert_eq(s2(), "b0")
  assert_eq(s1(), "a2")
  assert_eq(s2(), "b1")
  assert_eq(s2(), "b2")
}

///|
test "TestHelper.test_merge_ranges" {
  let empty : Array[(Int, Int)] = []
  assert_eq(empty, @core.merge_ranges(empty))
  assert_eq([(0, 1)], @core.merge_ranges([(0, 1)]))
  assert_eq([(0, 1), (2, 3)], @core.merge_ranges([(0, 1), (2, 3)]))
  assert_eq([(0, 3)], @core.merge_ranges([(0, 1), (1, 3)]))
  assert_eq([(0, 1), (2, 4)], @core.merge_ranges([(2, 3), (0, 1), (3, 4)]))
}
