///|
test "plain text builds word frequencies and reports every occurrence" {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.create_dictionary(
    "abc abc-def abc_def abc'def abc qwe qwe1 1qwe q1we 1234 1234",
  )
  assert_eq(report, { parsed_tokens: 13, added_words: 8, })
  let expected = @symspell.SymSpell::new()
  let _ = expected.load_dictionary(
    "abc 4\ndef 2\nabc'def 1\nqwe 1\nqwe1 1\n1qwe 1\nq1we 1\n1234 2",
  )
  assert_eq(dictionary.to_snapshot(), expected.to_snapshot())
  assert_eq(dictionary.lookup("abx", verbosity=Top)[0].term, "abc")
}

///|
test "corpus building preserves spelling casing and normalization" {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.create_dictionary(
    "Hello hello HELLO CAFÉ café é e\u{0301}",
  )
  assert_eq(report, { parsed_tokens: 7, added_words: 7, })
  for word in ["Hello", "hello", "HELLO", "CAFÉ", "café", "é", "e"] {
    assert_eq(dictionary.frequency(word), Some(1L))
  }
  assert_eq(dictionary.frequency("e\u{0301}"), None)
  assert_eq(dictionary.frequency("Café"), None)
  let _ = dictionary.create_dictionary("hello")
  assert_eq(dictionary.frequency("hello"), Some(2L))
  assert_eq(dictionary.frequency("Hello"), Some(1L))
}

///|
test "corpus tokens include Unicode letters and numbers across planes" {
  let dictionary = @symspell.SymSpell::new()
  let words = [
    "café", "東京", "мир", "العربية", "𐐀", "𠀀", "٣٤", "²½Ⅻ",
    "Ａ１",
  ]
  let report = dictionary.create_dictionary(words.join("\u{2003}"))
  assert_eq(report, { parsed_tokens: 9, added_words: 9, })
  for word in words {
    assert_eq(dictionary.frequency(word), Some(1L))
  }
  assert_eq(dictionary.lookup("東亰", verbosity=Top)[0].term, "東京")
}

///|
test "corpus token categories are pinned to Unicode 16" {
  let dictionary = @symspell.SymSpell::new()
  // U+1C89/U+1C8A are Cyrillic letters introduced in Unicode 16.0;
  // U+2EBF0 is the start of CJK Extension I, introduced in Unicode 15.1.
  let report = dictionary.create_dictionary("\u{1C89}\u{1C8A} \u{2EBF0}")
  assert_eq(report, { parsed_tokens: 2, added_words: 2, })
  assert_eq(dictionary.frequency("\u{1C89}\u{1C8A}"), Some(1L))
  assert_eq(dictionary.frequency("\u{2EBF0}"), Some(1L))
}

///|
test "apostrophes are retained inside at edges and on their own" {
  let dictionary = @symspell.SymSpell::new()
  let words = [
    "don't", "rock’n’roll", "'quoted'", "dogs’", "'", "’’", "l’amour",
  ]
  let report = dictionary.create_dictionary(words.join(" "))
  assert_eq(report, { parsed_tokens: 7, added_words: 7, })
  for word in words {
    assert_eq(dictionary.frequency(word), Some(1L))
  }
  // Opening curly quotes are separators; closing curly quotes are apostrophes.
  let _ = dictionary.create_dictionary("‘quoted’")
  assert_eq(dictionary.frequency("quoted’"), Some(1L))
}

///|
test "punctuation controls marks and emoji separate corpus tokens" {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.create_dictionary(
    "\u{FEFF}one,two.three!four?five-six_seven/eight\\nine\r\nten\t" +
    "eleven\u{00A0}twelve😀thirteen\u{0301}fourteen\u{200D}fifteen\u{0000}sixteen",
  )
  assert_eq(report, { parsed_tokens: 16, added_words: 16, })
  for
    word in [
      "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
      "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    ] {
    assert_eq(dictionary.frequency(word), Some(1L))
  }
}

///|
test "empty and separator-only corpora leave even zero-threshold dictionaries unchanged" {
  let dictionary = @symspell.SymSpell::new(count_threshold=0L)
  let _ = dictionary.load_dictionary("existing 5")
  let before = dictionary.to_snapshot()
  for
    text in [
      "", " \t\r\n", ".,_-!?😀👩‍💻\u{0301}\u{FEFF}\u{E000}\u{0378}",
    ] {
    assert_eq(dictionary.create_dictionary(text), {
      parsed_tokens: 0,
      added_words: 0,
    })
    assert_eq(dictionary.to_snapshot(), before)
  }
  assert_eq(dictionary.frequency(""), None)
}

///|
test "corpora merge counts and promote pending words exactly once" {
  let dictionary = @symspell.SymSpell::new(count_threshold=3L)
  let _ = dictionary.load_dictionary("existing 5\nrare 1")
  assert_eq(dictionary.create_dictionary("existing rare new new"), {
    parsed_tokens: 4,
    added_words: 0,
  })
  assert_eq(dictionary.frequency("existing"), Some(6L))
  assert_eq(dictionary.pending_word_count(), 2)
  assert_eq(dictionary.create_dictionary("rare new new new"), {
    parsed_tokens: 4,
    added_words: 2,
  })
  assert_eq(dictionary.pending_word_count(), 0)
  assert_eq(dictionary.frequency("rare"), Some(3L))
  assert_eq(dictionary.frequency("new"), Some(5L))
  let index_size = dictionary.entry_count()
  assert_eq(dictionary.create_dictionary("new rare existing"), {
    parsed_tokens: 3,
    added_words: 0,
  })
  assert_eq(dictionary.entry_count(), index_size)
  assert_eq(dictionary.lookup("raer", verbosity=Top)[0].count, 4L)
}

///|
test "corpus frequency additions saturate and can cross the maximum threshold" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary_entry("large", 9223372036854775806L)
  assert_eq(dictionary.create_dictionary("large large large"), {
    parsed_tokens: 3,
    added_words: 0,
  })
  assert_eq(dictionary.frequency("large"), Some(9223372036854775807L))
  let pending = @symspell.SymSpell::new(count_threshold=9223372036854775807L)
  let _ = pending.create_dictionary_entry("large", 9223372036854775806L)
  assert_eq(pending.create_dictionary("large large"), {
    parsed_tokens: 2,
    added_words: 1,
  })
  assert_eq(pending.frequency("large"), Some(9223372036854775807L))
}

///|
test "each corpus call completes its final token and supports whole-line ingestion" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.create_dictionary("hello")
  let _ = dictionary.create_dictionary("world")
  let _ = dictionary.create_dictionary("hello world\n")
  assert_eq(dictionary.frequency("hello"), Some(2L))
  assert_eq(dictionary.frequency("world"), Some(2L))
  assert_eq(dictionary.frequency("helloworld"), None)
  let combined = @symspell.SymSpell::new()
  let _ = combined.create_dictionary("hello\nworld\nhello world\n")
  assert_eq(dictionary.to_snapshot(), combined.to_snapshot())
}

///|
test "corpus ingestion preserves bigrams scoring configuration and pending snapshot words" {
  let dictionary = @symspell.SymSpell::new(count_threshold=2L, corpus_size=6L)
  let _ = dictionary.set_bigram_count("hello world", 2L)
  let _ = dictionary.create_dictionary("hello world hello world rare")
  let expected = @symspell.SymSpell::new(count_threshold=2L, corpus_size=6L)
  let _ = expected.load_dictionary("hello 2\nworld 2\nrare 1")
  let _ = expected.set_bigram_count("hello world", 2L)
  assert_eq(dictionary.to_snapshot(), expected.to_snapshot())
  assert_eq(dictionary.bigram_count(), 1)
  let restored = @symspell.SymSpell::from_snapshot(dictionary.to_snapshot())
  assert_eq(restored.create_dictionary("rare"), {
    parsed_tokens: 1,
    added_words: 1,
  })
  assert_eq(restored.frequency("rare"), Some(2L))
  assert_eq(dictionary.frequency("rare"), None)
  assert_eq(restored.lookup_compound("helloworld")[0].term, "hello world")
  assert_eq(
    restored.word_segmentation("helloworld").corrected_string,
    "hello world",
  )
}

///|
test "corpus frequencies are deterministic across order and survive removal" {
  let forward = @symspell.SymSpell::new()
  let _ = forward.create_dictionary("cat bat cat cut")
  let backward = @symspell.SymSpell::new()
  let _ = backward.create_dictionary("cut cat bat cat")
  assert_eq(forward.to_snapshot(), backward.to_snapshot())
  assert_true(forward.delete_dictionary_entry("cat"))
  assert_eq(forward.create_dictionary("cat cat"), {
    parsed_tokens: 2,
    added_words: 1,
  })
  assert_eq(forward.to_snapshot(), backward.to_snapshot())
  assert_eq(forward.lookup("hat", verbosity=Top)[0].term, "cat")
}
