///|
fn snapshot_test_terms() -> Array[String] {
  let terms = [""]
  let mut level = [""]
  for _length = 0; _length < 4; _length = _length + 1 {
    let next : Array[String] = []
    for prefix in level {
      for character in ["a", "b", "😀"] {
        next.push(prefix + character)
      }
    }
    terms.append(next)
    level = next
  }
  terms
}

///|
test "snapshot empty dictionaries preserve every configuration" {
  for distance in [0, 1, 2, 4] {
    for threshold in [0L, 3L, 9223372036854775807L] {
      let original = @symspell.SymSpell::new(
        max_dictionary_edit_distance=distance,
        prefix_length=distance + 1,
        count_threshold=threshold,
        corpus_size=12345L,
      )
      let restored = @symspell.SymSpell::from_snapshot(original.to_snapshot())
      assert_eq(restored.word_count(), 0)
      assert_eq(restored.pending_word_count(), 0)
      assert_eq(restored.entry_count(), 0)
      assert_eq(restored.bigram_count(), 0)
      assert_eq(restored.lookup_compound("")[0].count, 12345L)
      assert_eq(
        restored.lookup("x", include_unknown=true)[0].distance,
        distance + 1,
      )
      expect_symspell_error(
        () => restored.lookup("x", max_edit_distance=distance + 1),
        @symspell.SymSpellError::InvalidEditDistance(distance + 1),
      )
      assert_eq(restored.to_snapshot(), original.to_snapshot())
      assert_eq(restored.create_dictionary_entry("zero", 0L), threshold == 0L)
    }
  }
}

///|
test "snapshot lookup results survive varied prefixes edit limits and thresholds" {
  let terms = snapshot_test_terms()
  for distance in [0, 1, 2, 3, 4] {
    for prefix in [distance + 1, 7] {
      for threshold in [0L, 3L] {
        let original = @symspell.SymSpell::new(
          max_dictionary_edit_distance=distance,
          prefix_length=prefix,
          count_threshold=threshold,
        )
        for i = 0; i < terms.length(); i = i + 1 {
          let _ = original.create_dictionary_entry(terms[i], (i % 7).to_int64())
        }
        let restored = @symspell.SymSpell::from_snapshot(original.to_snapshot())
        assert_eq(restored.word_count(), original.word_count())
        assert_eq(restored.pending_word_count(), original.pending_word_count())
        assert_eq(restored.entry_count(), original.entry_count())
        for term in terms {
          assert_eq(restored.frequency(term), original.frequency(term))
          for limit = 0; limit <= distance; limit = limit + 1 {
            let modes : Array[@symspell.Verbosity] = [Top, Closest, All]
            for verbosity in modes {
              assert_eq(
                restored.lookup(term, verbosity~, max_edit_distance=limit),
                original.lookup(term, verbosity~, max_edit_distance=limit),
              )
            }
          }
        }
        assert_eq(restored.to_snapshot(), original.to_snapshot())
      }
    }
  }
}

///|
test "snapshot exact Int64 counts and arbitrary Unicode terms round trip" {
  let original = @symspell.SymSpell::new(count_threshold=0L)
  let terms = [
    "", "café", "e\u{0301}", "É", "東京", "АБИ", "a😀", "𐐀", "👩‍💻",
    "\u{FEFF}bom", "line\nfeed", "tab\tword", "null\u{0000}word", "quote\"slash\\word",
    "has spaces",
  ]
  for i = 0; i < terms.length(); i = i + 1 {
    let count = if i == 0 { 0L } else { 9223372036854775807L - i.to_int64() }
    assert_true(original.create_dictionary_entry(terms[i], count))
  }
  let _ = original.set_bigram_count("東京 😀", 9223372036854775807L)
  let restored = @symspell.SymSpell::from_snapshot(original.to_snapshot())
  for term in terms {
    assert_eq(restored.lookup(term), original.lookup(term))
    assert_eq(restored.frequency(term), original.frequency(term))
  }
  for query in ["cafe", "東亰", "АБ", "😀a", "É", "e\u{0301}"] {
    assert_eq(
      restored.lookup(query, verbosity=All),
      original.lookup(query, verbosity=All),
    )
  }
  assert_eq(
    restored.bigram_frequency("東京 😀"),
    Some(9223372036854775807L),
  )
  assert_eq(restored.to_snapshot(), original.to_snapshot())
}

///|
test "snapshot bytes do not depend on insertion order or mutation history" {
  let left = @symspell.SymSpell::new(count_threshold=3L)
  let right = @symspell.SymSpell::new(count_threshold=3L)
  let entries = [
    ("cat", 3L),
    ("bat", 5L),
    ("abb", 24L),
    ("ba", 24L),
    ("😀", 2L),
  ]
  for entry in entries {
    let (term, count) = entry
    let _ = left.create_dictionary_entry(term, count)
  }
  for entry in entries.rev() {
    let (term, count) = entry
    let _ = right.create_dictionary_entry(term, 1L)
    let _ = right.create_dictionary_entry(term, count - 1L)
  }
  let _ = left.set_bigram_count("cat bat", 7L)
  let _ = left.set_bigram_count("ba abb", 10L)
  let _ = right.set_bigram_count("ba abb", 100L)
  let _ = right.set_bigram_count("cat\tbat", 7L)
  let _ = right.set_bigram_count("ba abb", 10L)
  let _ = right.create_dictionary_entry("discarded", 99L)
  assert_true(right.delete_dictionary_entry("discarded"))
  assert_eq(left.to_snapshot(), right.to_snapshot())
  assert_eq(left.lookup("hat"), right.lookup("hat"))
}

///|
test "snapshot restores shared word references and keeps dictionaries independent" {
  let original = @symspell.SymSpell::new()
  let _ = original.load_dictionary("cat 3\nbat 5\ncut 4\nlongest 10")
  let snapshot = original.to_snapshot()
  let first = @symspell.SymSpell::from_snapshot(snapshot)
  let second = @symspell.SymSpell::from_snapshot(snapshot)
  assert_false(first.create_dictionary_entry("cat", 10L))
  assert_eq(first.lookup("hat", verbosity=Top)[0].term, "cat")
  assert_eq(first.lookup("hat", verbosity=Top)[0].count, 13L)
  assert_eq(first.frequency("cat"), Some(13L))
  assert_eq(original.lookup("hat", verbosity=Top)[0].term, "bat")
  assert_eq(second.lookup("hat", verbosity=Top)[0].term, "bat")
  assert_eq(original.frequency("cat"), Some(3L))
  assert_true(first.delete_dictionary_entry("cat"))
  assert_eq(first.lookup("hat", verbosity=Top)[0].term, "bat")
  assert_true(first.create_dictionary_entry("cat", 99L))
  assert_eq(first.lookup("hat", verbosity=All), [
    { term: "cat", distance: 1, count: 99L },
    { term: "bat", distance: 1, count: 5L },
    { term: "cut", distance: 2, count: 4L },
  ])
  assert_true(first.delete_dictionary_entry("longest"))
  assert_eq(first.word_segmentation("catbat").corrected_string, "cat bat")
  let fresh = @symspell.SymSpell::from_snapshot(first.to_snapshot())
  assert_eq(
    fresh.lookup("hat", verbosity=All),
    first.lookup("hat", verbosity=All),
  )
  assert_eq(original.to_snapshot(), snapshot)
  assert_eq(second.to_snapshot(), snapshot)
}

///|
test "snapshot pending terms retain counts for promotion and removal" {
  let original = @symspell.SymSpell::new(count_threshold=10L)
  let _ = original.create_dictionary_entry("😀", 9L)
  let _ = original.create_dictionary_entry("café", 2L)
  let _ = original.create_dictionary_entry("café", 3L)
  let _ = original.create_dictionary_entry("remove", 1L)
  let restored = @symspell.SymSpell::from_snapshot(original.to_snapshot())
  assert_eq(restored.pending_word_count(), 3)
  assert_eq(restored.lookup("😀"), [])
  assert_true(restored.create_dictionary_entry("😀", 1L))
  assert_eq(restored.frequency("😀"), Some(10L))
  assert_false(restored.create_dictionary_entry("café", 4L))
  assert_true(restored.create_dictionary_entry("café", 1L))
  assert_eq(restored.frequency("café"), Some(10L))
  assert_true(restored.delete_dictionary_entry("remove"))
  assert_eq(restored.pending_word_count(), 0)
  assert_eq(original.pending_word_count(), 3)
}

///|
test "snapshot compound and segmentation scores preserve corpus and bigram state" {
  let original = @symspell.SymSpell::new(corpus_size=10000L)
  let _ = original.load_dictionary(
    "where 2\nis 2\nwhereas 2\nhello 100\nworld 90\nsteam 10\nmachine 5",
  )
  let _ = original.load_bigram_dictionary(
    "where is 10\nhello world 50\nunused pair 1",
  )
  let restored = @symspell.SymSpell::from_snapshot(original.to_snapshot())
  for
    phrase in [
      "whereiz", "helloworld", "ste am machie", "helo world", "東京 😀", "",
    ] {
    assert_eq(
      restored.lookup_compound(phrase),
      original.lookup_compound(phrase),
    )
    assert_eq(
      restored.word_segmentation(phrase),
      original.word_segmentation(phrase),
    )
  }
  assert_eq(restored.bigram_count(), 3)
  assert_false(restored.set_bigram_count("unused pair", 100L))
  assert_false(original.set_bigram_count("unused pair", 100L))
  assert_eq(
    restored.lookup_compound("steamachine"),
    original.lookup_compound("steamachine"),
  )
  assert_true(restored.delete_bigram_entry("hello world"))
  assert_true(original.delete_bigram_entry("hello world"))
  assert_eq(
    restored.lookup_compound("helloworld"),
    original.lookup_compound("helloworld"),
  )
  assert_eq(restored.to_snapshot(), original.to_snapshot())
}

///|
test "snapshot rejects truncation bit flips and unsupported versions" {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("hello 100\nworld 90\n😀 1")
  let snapshot = dictionary.to_snapshot()
  for length = 0; length < snapshot.length(); length = length + 1 {
    try @symspell.SymSpell::from_snapshot(snapshot[:length].to_owned()) catch {
      @symspell.SymSpellError::InvalidSnapshot(_, _) => ()
      _ => fail("truncation should raise InvalidSnapshot")
    } noraise {
      _ => fail("truncated snapshot was accepted")
    }
  }
  for offset = 12; offset < snapshot.length(); offset = offset + 1 {
    let corrupt = Bytes::makei(snapshot.length(), i => {
      if i == offset {
        snapshot[i] ^ b'\x01'
      } else {
        snapshot[i]
      }
    })
    expect_symspell_error(
      () => @symspell.SymSpell::from_snapshot(corrupt),
      @symspell.SymSpellError::InvalidSnapshot(
        snapshot.length() - 4,
        "checksum mismatch",
      ),
    )
  }
  let unsupported = Bytes::makei(snapshot.length(), i => {
    if i == 8 {
      b'\x02'
    } else {
      snapshot[i]
    }
  })
  expect_symspell_error(
    () => @symspell.SymSpell::from_snapshot(unsupported),
    @symspell.SymSpellError::UnsupportedSnapshotVersion(2U),
  )
}
