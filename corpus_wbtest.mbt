///|
test "Unicode corpus classification matches independent Unicode 16 totals over every scalar" {
  // Independently computed with Python 3.14's Unicode 16.0 str.isalnum(),
  // rather than the UnicodeData.txt parser used to generate our ranges.
  let mut count = 0
  let mut code_sum = 0L
  let mut square_sum = 0L
  for code = 0; code <= 0x10FFFF; code = code + 1 {
    if code is (0xD800..=0xDFFF) {
      continue
    }
    if is_corpus_alphanumeric(code.unsafe_to_char()) {
      count = count + 1
      let value = code.to_int64()
      code_sum = code_sum + value
      square_sum = square_sum + value * value
    }
  }
  assert_eq(count, 142939)
  assert_eq(code_sum, 15351581153L)
  assert_eq(square_sum, 2246322401470651L)
}

///|
test "corpus Unicode ranges are ordered disjoint non-ASCII scalar intervals" {
  let mut previous = 127
  for range in corpus_alphanumeric_ranges {
    let (first, last) = range
    assert_true(first > previous && first <= last && last <= 0x10FFFF)
    assert_true(last < 0xD800 || first > 0xDFFF)
    previous = last
  }
}
