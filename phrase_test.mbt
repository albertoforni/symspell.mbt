///|
test "compound correction splits joined words with bigram scoring" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("where 2\nis 2\nwhereas 2")
  assert_true(dictionary.set_bigram_count("where is", 10L))
  assert_eq(dictionary.lookup_compound("whereiz"), [
    { term: "where is", distance: 2, count: 10L, },
  ])
  assert_eq(dictionary.lookup_compound("whereis")[0].term, "where is")
  assert_eq(
    dictionary.lookup_compound("whereis", max_edit_distance=0)[0].distance,
    1,
  )
}

///|
test "compound correction merges separated words and corrects independent typos" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("steam 1\nmachine 1")
  assert_eq(dictionary.lookup_compound("ste am machie"), [
    { term: "steam machine", distance: 2, count: 0L, },
  ])
  assert_eq(
    dictionary.lookup_compound("qwer erty ytui a")[0].term,
    "qwer erty ytui a",
  )
  let corpus = @symspell.SymSpell::new(corpus_size=100L)
  let _ = corpus.load_dictionary("hello 50\nworld 20")
  assert_eq(corpus.lookup_compound("hello world"), [
    { term: "hello world", distance: 0, count: 10L, },
  ])
}

///|
test "compound correction uses Unicode characters and explicit casing" {
  let dictionary = @symspell.SymSpell::new(corpus_size=100L)
  let _ = dictionary.load_dictionary("東京 20\n😀 10\nCafé 20\nhello 10")
  assert_eq(
    dictionary.lookup_compound("東亰\u{2003}😀")[0].term,
    "東京 😀",
  )
  assert_eq(
    dictionary.lookup_compound("Café", max_edit_distance=0)[0].term,
    "Café",
  )
  assert_eq(
    dictionary.lookup_compound("café", max_edit_distance=0)[0].term,
    "café",
  )
  assert_eq(
    dictionary.lookup_compound("hello", max_edit_distance=0)[0].distance,
    0,
  )
}

///|
test "empty and unknown compound input have a defined result" {
  let dictionary = @symspell.SymSpell::new(corpus_size=100L)
  assert_eq(dictionary.lookup_compound(""), [
    { term: "", distance: 0, count: 100L, },
  ])
  assert_eq(dictionary.lookup_compound("hello world"), [
    { term: "hello world", distance: 0, count: 0L, },
  ])
  assert_eq(
    dictionary.lookup_compound("\t hello  world \n")[0].term,
    "hello world",
  )
}

///|
test "segmentation reconstructs the documented pangram" {
  let dictionary = @symspell.SymSpell::new(max_dictionary_edit_distance=0)
  let _ = dictionary.load_dictionary(
    "the 1000\nquick 990\nbrown 980\nfox 970\njumps 960\nover 950\nlazy 940\ndog 930",
  )
  let result = dictionary.word_segmentation(
    "thequickbrownfoxjumpsoverthelazydog",
  )
  assert_eq(
    result.segmented_string,
    "the quick brown fox jumps over the lazy dog",
  )
  assert_eq(result.corrected_string, result.segmented_string)
  assert_eq(result.distance_sum, 8)
  assert_true((result.log_prob_sum - -81.22092632166166).abs() < 0.000000001)
}

///|
test "segmentation corrects spelling and preserves existing word boundaries" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("hello 100\nworld 90")
  let joined = dictionary.word_segmentation("helloworld")
  assert_eq(joined.corrected_string, "hello world")
  assert_eq(joined.distance_sum, 1)
  let existing = dictionary.word_segmentation("hello world")
  assert_eq(existing.corrected_string, "hello world")
  assert_eq(existing.segmented_string, "hello world")
  assert_eq(existing.distance_sum, 0)
  let corrected = dictionary.word_segmentation("helo world")
  assert_eq(corrected.segmented_string, "helo world")
  assert_eq(corrected.corrected_string, "hello world")
  assert_eq(corrected.distance_sum, 1)
  let spaced = dictionary.word_segmentation(" \t hello\u{2003}\u{2003}world \n")
  assert_eq(spaced, existing)
}

///|
test "segmentation removes an accidental internal space" {
  let dictionary = @symspell.SymSpell::new(max_dictionary_edit_distance=0)
  let _ = dictionary.create_dictionary_entry("hello", 100L)
  let result = dictionary.word_segmentation("hel lo")
  assert_eq(result.corrected_string, "hello")
  assert_eq(result.distance_sum, 1)
}

///|
test "segmentation counts Unicode characters and keeps normalization explicit" {
  let dictionary = @symspell.SymSpell::new(max_dictionary_edit_distance=0)
  let _ = dictionary.load_dictionary("東京 100\n😀 90\ncafé 80\nCafé 70")
  let result = dictionary.word_segmentation("東京😀café")
  assert_eq(result.corrected_string, "東京 😀 café")
  assert_eq(result.distance_sum, 2)
  assert_eq(dictionary.word_segmentation("Café").corrected_string, "Café")
  assert_eq(dictionary.word_segmentation("ﬁ").corrected_string, "ﬁ")
  assert_eq(
    dictionary.word_segmentation("hello-world", max_segmentation_word_length=20).corrected_string,
    "hello-world",
  )
}

///|
test "segmentation handles empty dictionaries, empty input, and zero frequencies" {
  let dictionary = @symspell.SymSpell::new()
  assert_eq(dictionary.word_segmentation("\t\n"), {
    segmented_string: "",
    corrected_string: "",
    distance_sum: 0,
    log_prob_sum: 0.0,
  })
  let unknown = dictionary.word_segmentation("hello")
  assert_eq(unknown.corrected_string, "hello")
  assert_eq(unknown.distance_sum, 5)
  assert_true((unknown.log_prob_sum - -16.0106849963).abs() < 0.000000001)
  let zero = @symspell.SymSpell::new(count_threshold=0L)
  let _ = zero.create_dictionary_entry("zero", 0L)
  let result = zero.word_segmentation("zero")
  assert_eq(result.corrected_string, "zero")
  assert_eq(result.distance_sum, 0)
  assert_true(result.log_prob_sum < -1.0e300)
  assert_false(result.log_prob_sum.is_nan())
}

///|
test "bigram loading is transactional and supports delimited pairs" {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.load_bigram_dictionary(
    "\u{FEFF}where is 10\r\nhello world 20\nwhere is 30\n",
  )
  assert_eq(report, { parsed_entries: 3, added_bigrams: 2, skipped_lines: 0, })
  assert_eq(dictionary.bigram_frequency("where\u{2003}is"), Some(30L))
  assert_eq(dictionary.bigram_count(), 2)
  assert_true(
    try dictionary.load_bigram_dictionary("a b 10\nbad row nope") catch {
      @symspell.InvalidDictionaryLine(2, "bad row nope") => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_eq(dictionary.bigram_frequency("a b"), None)
  let custom = dictionary.load_bigram_dictionary(
    "40$ice cream\n50$hello world",
    separator='$',
    term_index=1,
    count_index=0,
  )
  assert_eq(custom, { parsed_entries: 2, added_bigrams: 1, skipped_lines: 0, })
  assert_eq(dictionary.bigram_frequency("hello world"), Some(50L))
  let skipped = dictionary.load_bigram_dictionary(
    "bad\none$4\nx y$-1\na b c$8",
    separator='$',
    strict=false,
  )
  assert_eq(skipped, { parsed_entries: 0, added_bigrams: 0, skipped_lines: 4, })
  assert_true(dictionary.delete_bigram_entry("ice cream"))
  assert_false(dictionary.delete_bigram_entry("ice cream"))
  assert_false(dictionary.delete_bigram_entry("one"))
}

///|
test "phrase options reject invalid limits and scoring parameters" {
  assert_true(
    try @symspell.SymSpell::new(corpus_size=0L) catch {
      @symspell.InvalidCorpusSize(0L) => true
      _ => false
    } noraise {
      _ => false
    },
  )
  let dictionary = @symspell.SymSpell::new()
  assert_true(
    try dictionary.lookup_compound("", max_edit_distance=3) catch {
      @symspell.InvalidEditDistance(3) => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try dictionary.word_segmentation("", max_segmentation_word_length=0) catch {
      @symspell.InvalidSegmentationWordLength(0) => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try dictionary.set_bigram_count("a b", -1L) catch {
      @symspell.InvalidFrequencyCount(-1L) => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try dictionary.set_bigram_count("word", 1L) catch {
      @symspell.InvalidBigramTerm("word") => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "bigram replacement and removal refresh the fallback frequency cap" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=0,
    corpus_size=100L,
  )
  let _ = dictionary.load_dictionary("hello 50\nworld 50")
  let _ = dictionary.set_bigram_count("unused pair", 1L)
  assert_eq(dictionary.lookup_compound("helloworld")[0].count, 1L)
  assert_false(dictionary.set_bigram_count("unused pair", 100L))
  assert_eq(dictionary.lookup_compound("helloworld")[0].count, 25L)
  let _ = dictionary.set_bigram_count("zero pair", 0L)
  assert_eq(dictionary.lookup_compound("helloworld")[0].count, 0L)
  assert_true(dictionary.delete_bigram_entry("zero pair"))
  assert_eq(dictionary.lookup_compound("helloworld")[0].count, 25L)
  assert_true(dictionary.delete_bigram_entry("unused pair"))
  assert_eq(dictionary.lookup_compound("helloworld")[0].count, 25L)
}

///|
test "phrase probabilities saturate and zero frequencies stay zero" {
  let dictionary = @symspell.SymSpell::new(
    max_dictionary_edit_distance=0,
    count_threshold=0L,
    corpus_size=1L,
  )
  let _ = dictionary.create_dictionary_entry("high", 9223372036854775807L)
  let _ = dictionary.create_dictionary_entry("zero", 0L)
  assert_eq(
    dictionary.lookup_compound("high high")[0].count,
    9223372036854775807L,
  )
  let phrase = "high ".repeat(20)
  assert_eq(dictionary.lookup_compound(phrase)[0].count, 9223372036854775807L)
  assert_eq(dictionary.lookup_compound(phrase + "zero")[0].count, 0L)
  let _ = dictionary.set_bigram_count("high high", 9223372036854775807L)
  assert_eq(
    dictionary.lookup_compound("highhigh")[0].count,
    9223372036854775807L,
  )
}

///|
test "long unknown segmentation and huge windows remain bounded and finite" {
  let dictionary = @symspell.SymSpell::new()
  let unknown = "x".repeat(1000)
  let result = dictionary.word_segmentation(unknown)
  assert_eq(result.corrected_string, unknown)
  assert_eq(result.distance_sum, 1000)
  assert_true(result.log_prob_sum < -1000.0 && result.log_prob_sum > -1100.0)
  let _ = dictionary.load_dictionary("hello 100\nworld 90")
  let bounded = dictionary.word_segmentation(
    "helloworld",
    max_segmentation_word_length=2147483647,
  )
  assert_eq(bounded.corrected_string, "hello world")
  assert_eq(bounded.distance_sum, 1)
}
