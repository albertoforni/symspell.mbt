///|
fn[T] expect_symspell_error(
  action : () -> T raise @symspell.SymSpellError,
  expected : @symspell.SymSpellError,
) -> Unit raise {
  try action() catch {
    error => assert_eq(error, expected)
  } noraise {
    _ => fail("expected a SymSpellError")
  }
}

///|
test "the documented upstream members example" {
  let dictionary = @symspell.SymSpell::new()
  assert_true(dictionary.create_dictionary_entry("members", 226656153L))
  assert_eq(dictionary.lookup("memebers"), [
    { term: "members", distance: 1, count: 226656153L, },
  ])
}

///|
test "distance wins over frequency, and verbosity controls the result set" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("cat 10\nbat 50\ncut 20\ndog 1000")
  assert_eq(dictionary.lookup("cat", verbosity=Top), [
    { term: "cat", distance: 0, count: 10L, },
  ])
  assert_eq(dictionary.lookup("hat"), [
    { term: "bat", distance: 1, count: 50L, },
    { term: "cat", distance: 1, count: 10L, },
  ])
  assert_eq(dictionary.lookup("hat", verbosity=Top), [
    { term: "bat", distance: 1, count: 50L, },
  ])
  assert_eq(dictionary.lookup("cat", verbosity=All), [
    { term: "cat", distance: 0, count: 10L, },
    { term: "bat", distance: 1, count: 50L, },
    { term: "cut", distance: 1, count: 20L, },
  ])
  assert_eq(dictionary.lookup("cat", max_edit_distance=0), [
    { term: "cat", distance: 0, count: 10L, },
  ])
  assert_eq(dictionary.lookup("hat", max_edit_distance=0), [])
}

///|
test "equal scores have deterministic term order" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("cat 50\nbat 50")
  assert_eq(dictionary.lookup("hat"), [
    { term: "bat", distance: 1, count: 50L, },
    { term: "cat", distance: 1, count: 50L, },
  ])
  assert_eq(dictionary.lookup("hat", verbosity=Top)[0].term, "bat")
  let different_lengths = @symspell.SymSpell::new()
  let _ = different_lengths.load_dictionary("ba 24\nabb 24")
  assert_eq(different_lengths.lookup("ab"), [
    { term: "abb", distance: 1, count: 24L, },
    { term: "ba", distance: 1, count: 24L, },
  ])
}

///|
test "adjacent transpositions use optimal string alignment" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary_entry("bank", 10L)
  assert_eq(dictionary.lookup("bnak", max_edit_distance=1), [
    { term: "bank", distance: 1, count: 10L, },
  ])
  assert_eq(dictionary.lookup("xban", max_edit_distance=1), [])
  assert_eq(dictionary.lookup("baxn", max_edit_distance=1), [])
  let restricted = @symspell.SymSpell::new(
    max_dictionary_edit_distance=3,
    prefix_length=4,
  )
  let _ = restricted.create_dictionary_entry("CA", 1L)
  assert_eq(restricted.lookup("ABC", max_edit_distance=2), [])
  assert_eq(restricted.lookup("ABC")[0].distance, 3)
}

///|
test "Unicode is measured in characters including supplementary code points" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=1,
    prefix_length=2,
  )
  let _ = dictionary.load_dictionary(
    "café 10\n東京 9\nАБИ 8\na😀 7\n𐐀 6",
  )
  for
    entry in [
      ("cafe", "café"),
      ("東亰", "東京"),
      ("АБ", "АБИ"),
      ("😀a", "a😀"),
      ("", "𐐀"),
    ] {
    let (query, expected) = entry
    assert_eq(dictionary.lookup(query, verbosity=Top)[0].term, expected)
    assert_eq(dictionary.lookup(query, verbosity=Top)[0].distance, 1)
  }
  let emoji = @symspell.SymSpell::new(
    max_dictionary_edit_distance=1,
    prefix_length=2,
  )
  let _ = emoji.create_dictionary_entry("😀", 1L)
  assert_eq(emoji.lookup("")[0].distance, 1)
  assert_eq(emoji.lookup("😃")[0].distance, 1)
}

///|
test "normalization and casing are explicit application policies" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary_entry("é", 1L)
  assert_eq(dictionary.lookup("e\u{0301}")[0].distance, 2)
  assert_eq(dictionary.lookup("É")[0].distance, 1)
  let _ = dictionary.create_dictionary_entry("👩‍💻", 2L)
  assert_eq(dictionary.lookup("", verbosity=All), [
    { term: "é", distance: 1, count: 1L, },
  ])
}

///|
test "short strings, empty terms, and candidates without a common character" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=4,
    prefix_length=5,
  )
  let _ = dictionary.load_dictionary("bank 10\nbink 9")
  assert_eq(dictionary.lookup("knab", verbosity=All), [
    { term: "bank", distance: 3, count: 10L, },
    { term: "bink", distance: 4, count: 9L, },
  ])
  assert_eq(dictionary.lookup("", verbosity=All), [
    { term: "bank", distance: 4, count: 10L, },
    { term: "bink", distance: 4, count: 9L, },
  ])
  assert_true(dictionary.create_dictionary_entry("", 3L))
  assert_eq(dictionary.lookup(""), [{ term: "", distance: 0, count: 3L, }])
  assert_eq(dictionary.lookup("x", max_edit_distance=1), [
    { term: "", distance: 1, count: 3L, },
  ])
}

///|
test "full words are verified even when their prefixes collide" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=1,
    prefix_length=2,
  )
  let _ = dictionary.load_dictionary("abcdefgh 10\nabcxyzgh 100")
  assert_eq(dictionary.lookup("abcdefgi"), [
    { term: "abcdefgh", distance: 1, count: 10L, },
  ])
  assert_eq(dictionary.lookup("abcdefghij"), [])
}

///|
test "duplicates accumulate and threshold promotion indexes a term only once" {
  let dictionary = @symspell.SymSpell::new(count_threshold=10L)
  assert_false(dictionary.create_dictionary_entry("pipe", 4L))
  assert_eq(dictionary.frequency("pipe"), None)
  assert_eq(dictionary.pending_word_count(), 1)
  assert_eq(dictionary.lookup("pip"), [])
  assert_false(dictionary.create_dictionary_entry("pipe", 4L))
  assert_true(dictionary.create_dictionary_entry("pipe", 4L))
  assert_eq(dictionary.frequency("pipe"), Some(12L))
  assert_eq(dictionary.pending_word_count(), 0)
  let index_size = dictionary.entry_count()
  assert_false(dictionary.create_dictionary_entry("pipe", 4L))
  assert_eq(dictionary.entry_count(), index_size)
  assert_eq(dictionary.lookup("pip"), [
    { term: "pipe", distance: 1, count: 16L, },
  ])
}

///|
test "frequencies saturate without overflowing" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary_entry("large", 9223372036854775806L)
  let _ = dictionary.create_dictionary_entry("large", 10L)
  assert_eq(dictionary.frequency("large"), Some(9223372036854775807L))
  let pending = @symspell.SymSpell::new(count_threshold=9223372036854775807L)
  let _ = pending.create_dictionary_entry("large", 9223372036854775806L)
  assert_true(pending.create_dictionary_entry("large", 10L))
  assert_eq(pending.frequency("large"), Some(9223372036854775807L))
}

///|
test "nonpositive counts respect a zero threshold" {
  let dictionary = @symspell.SymSpell::new()
  assert_false(dictionary.create_dictionary_entry("pipe", 0L))
  assert_false(dictionary.create_dictionary_entry("pipe", -1L))
  let zero = @symspell.SymSpell::new(count_threshold=0L)
  assert_true(zero.create_dictionary_entry("pipe", -1L))
  assert_false(zero.create_dictionary_entry("pipe", 0L))
  assert_eq(zero.frequency("pipe"), Some(0L))
}

///|
test "removal cleans all buckets and allows re-insertion" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("stea 1\nsteama 2\nsteem 3")
  assert_true(dictionary.delete_dictionary_entry("steama"))
  assert_eq(dictionary.lookup("steama", verbosity=Top)[0].term, "steem")
  assert_true(dictionary.delete_dictionary_entry("stea"))
  assert_true(dictionary.delete_dictionary_entry("steem"))
  assert_eq(dictionary.word_count(), 0)
  assert_eq(dictionary.entry_count(), 0)
  assert_eq(dictionary.lookup("steama"), [])
  assert_false(dictionary.delete_dictionary_entry("steem"))
  let _ = dictionary.create_dictionary_entry("steem", 10L)
  assert_eq(dictionary.lookup("steama"), [
    { term: "steem", distance: 2, count: 10L, },
  ])
  let pending = @symspell.SymSpell::new(count_threshold=2L)
  let _ = pending.create_dictionary_entry("pending", 1L)
  assert_true(pending.delete_dictionary_entry("pending"))
  assert_eq(pending.pending_word_count(), 0)
}

///|
test "dictionary loading supports whitespace, BOM, CRLF, columns, and duplicates" {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.load_dictionary(
    "\u{FEFF}café\t10\r\n東京\u{2003}9\r\n\ncafé 5\n",
  )
  assert_eq(report, { parsed_entries: 3, added_words: 2, skipped_lines: 0, })
  assert_eq(dictionary.frequency("café"), Some(15L))
  let custom = dictionary.load_dictionary(
    "20$ice cream\n30$ice cream",
    separator='$',
    term_index=1,
    count_index=0,
  )
  assert_eq(custom, { parsed_entries: 2, added_words: 1, skipped_lines: 0, })
  assert_eq(dictionary.frequency("ice cream"), Some(50L))
}

///|
test "strict dictionary parsing is transactional" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary_entry("existing", 10L)
  expect_symspell_error(
    () => dictionary.load_dictionary("new 5\nbroken nope"),
    @symspell.InvalidDictionaryLine(2, "broken nope"),
  )
  assert_eq(dictionary.word_count(), 1)
  assert_eq(dictionary.frequency("new"), None)
  let report = dictionary.load_dictionary(
    "new 5\nbroken nope\nmissing\nnegative -1\noverflow 9223372036854775808\n\n",
    strict=false,
  )
  assert_eq(report, { parsed_entries: 1, added_words: 1, skipped_lines: 4, })
  assert_eq(dictionary.frequency("new"), Some(5L))
}

///|
test "unknown fallback and exact-only dictionaries" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=0,
    prefix_length=1,
  )
  let _ = dictionary.create_dictionary_entry("known", 5L)
  assert_eq(dictionary.lookup("known"), [
    { term: "known", distance: 0, count: 5L, },
  ])
  assert_eq(dictionary.lookup("unknown"), [])
  assert_eq(dictionary.lookup("unknown", include_unknown=true), [
    { term: "unknown", distance: 1, count: 0L, },
  ])
  let empty = @symspell.SymSpell::new()
  assert_eq(empty.lookup("verylongword", include_unknown=true), [
    { term: "verylongword", distance: 3, count: 0L, },
  ])
}

///|
test "invalid configuration and lookup limits return typed errors" {
  expect_symspell_error(
    () => @symspell.SymSpell::new(max_dictionary_edit_distance=-1),
    @symspell.InvalidEditDistance(-1),
  )
  expect_symspell_error(
    () => @symspell.SymSpell::new(prefix_length=0),
    @symspell.InvalidPrefixLength(0),
  )
  expect_symspell_error(
    () => @symspell.SymSpell::new(prefix_length=2),
    @symspell.InvalidPrefixLength(2),
  )
  expect_symspell_error(
    () => @symspell.SymSpell::new(count_threshold=-1L),
    @symspell.InvalidCountThreshold(-1L),
  )
  let dictionary = @symspell.SymSpell::new()
  expect_symspell_error(
    () => dictionary.lookup("word", max_edit_distance=-1),
    @symspell.InvalidEditDistance(-1),
  )
  expect_symspell_error(
    () => dictionary.lookup("word", max_edit_distance=3),
    @symspell.InvalidEditDistance(3),
  )
  expect_symspell_error(
    () => dictionary.load_dictionary("", term_index=-1),
    @symspell.InvalidColumns(-1, 1),
  )
  expect_symspell_error(
    () => dictionary.load_dictionary("", count_index=-1),
    @symspell.InvalidColumns(0, -1),
  )
  expect_symspell_error(
    () => dictionary.load_dictionary("word 1", term_index=2147483647),
    @symspell.InvalidDictionaryLine(1, "word 1"),
  )
}
