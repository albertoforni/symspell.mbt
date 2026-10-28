///|
test "string table retains colliding keys through growth and cluster removal" {
  assert_eq(string_table_hash("Aa"), string_table_hash("BB"))
  let table : StringTable[Int32] = StringTable::new()
  let reference : Map[String, Int32] = Map([])
  let keys = ["Aa", "BB", "", "😀", "a😀b", "東京"]
  for i = 0; i < 1024; i = i + 1 {
    keys.push("key-\{i}")
  }
  for i, key in keys {
    table[key] = i
    reference[key] = i
  }
  for i, key in keys {
    if i % 3 == 0 {
      table.remove(key)
      reference.remove(key)
    }
  }
  for key in keys {
    assert_eq(table.get(key), reference.get(key))
  }
  for i, key in keys {
    assert_eq(
      table.get_or_init(key, () => i + 2000),
      reference.get_or_init(key, () => i + 2000),
    )
  }
  for i, key in keys {
    assert_false(table.insert(key, i + 3000))
    assert_eq(table.get(key), Some(i + 3000))
  }
  assert_eq(table.length(), keys.length())
  let actual = table.keys().to_array()
  actual.sort()
  keys.sort()
  assert_eq(actual, keys)
}

///|
test "allocation-free deletion hashes match Unicode deletion strings" {
  for
    term in [
      "", "aa", "ababa", "AaBB", "😀a𐐀😀", "東京é", "👩‍💻",
    ] {
    let chars = term.to_array()
    for length = 0; length <= chars.length(); length = length + 1 {
      for first = -1; first < length; first = first + 1 {
        for second = first; second < length; second = second + 1 {
          let kept : Array[Char] = []
          for i = 0; i < length; i = i + 1 {
            if i != first && i != second {
              kept.push(chars[i])
            }
          }
          assert_eq(
            deletion_hash(chars, length, first, second),
            string_table_hash(String::from_array(kept[:])),
          )
        }
      }
    }
  }
}

///|
test "optimized and general index paths agree with exhaustive OSA lookup" {
  let dictionary = SymSpell::new(
    max_dictionary_edit_distance=3,
    prefix_length=4,
  )
  let terms = [""]
  let mut start = 0
  for _length = 0; _length < 4; _length = _length + 1 {
    let end = terms.length()
    for i = start; i < end; i = i + 1 {
      for character in ["a", "b", "😀"] {
        terms.push(terms[i] + character)
      }
    }
    start = end
  }
  let words = terms[:40].to_owned()
  for word in ["Aa", "BB", "Aaabcdef", "BBabcdef", "ababa😀", "baaba😀"] {
    words.push(word)
  }
  for i, word in words {
    ignore(dictionary.create_dictionary_entry(word, i.to_int64() + 1L))
  }
  for query in terms {
    let all : Array[Suggestion] = []
    for i, word in words {
      all.push({
        term: word,
        distance: reference_osa(query.to_array(), word.to_array()),
        count: i.to_int64() + 1L,
      })
    }
    all.sort_by(compare_suggestions)
    for limit in [0, 1, 2, 3] {
      let expected = all.filter(item => item.distance <= limit)
      assert_eq(
        dictionary.lookup(query, verbosity=All, max_edit_distance=limit),
        expected,
      )
      assert_eq(
        dictionary.lookup(query, verbosity=Top, max_edit_distance=limit),
        expected[:Int32::min(expected.length(), 1)].to_owned(),
      )
      let closest = if expected.get(0) is Some(first) {
        expected.filter(item => item.distance == first.distance)
      } else {
        []
      }
      assert_eq(dictionary.lookup(query, max_edit_distance=limit), closest)
    }
  }
}

///|
test "lookup epochs wrap safely and exact results remain independent" {
  let dictionary = SymSpell::new()
  ignore(dictionary.create_dictionary_entry("cat", 10L))
  ignore(dictionary.create_dictionary_entry("bat", 20L))
  let before = dictionary.lookup("hat", verbosity=All)
  dictionary.lookup_id = 2147483647
  assert_eq(dictionary.lookup("hat", verbosity=All), before)
  let exact = dictionary.lookup("cat")
  ignore(dictionary.create_dictionary_entry("cat", 5L))
  assert_eq(exact[0].count, 10L)
  exact.clear()
  assert_eq(dictionary.lookup("cat"), [
    { term: "cat", distance: 0, count: 15L, },
  ])
  ignore(dictionary.delete_dictionary_entry("cat"))
  ignore(dictionary.create_dictionary_entry("cat", 30L))
  assert_eq(dictionary.lookup("hat", verbosity=Top)[0].term, "cat")
}

///|
test "fast frequency parsing preserves exact counts and core numeric syntax" {
  let samples = [
    "", "0", "000000000000000", "2147483647", "2147483648", "23135851162", "999999999999999",
    "1000000000000000", "9007199254740991", "9007199254740992", "9007199254740993",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-1", "-0",
    "+10", "0x10", "0o17", "0b10", "1_234", "1__2", "12x", "1.0", "NaN", "１２",
    " 10", "10 ",
  ]
  for i = 0; i < 100; i = i + 1 {
    samples.push((i.to_int64() * 9999999999999L).to_string())
  }
  for text in samples {
    let expected = try @string.parse_int64(text[:]) catch {
      _ => None
    } noraise {
      value => Some(value)
    }
    assert_eq(parse_frequency_count(text), expected)
  }
}

///|
test "word hash collisions preserve exact lookup, updates, removal, and restore" {
  let first = "AaxxcYde"
  let second = "BBxxcYde"
  assert_eq(word_table_hash(first), word_table_hash(second))
  let dictionary = SymSpell::new()
  ignore(dictionary.create_dictionary_entry(first, 10L))
  ignore(dictionary.create_dictionary_entry(second, 20L))
  assert_eq(dictionary.lookup(first)[0].term, first)
  assert_eq(dictionary.lookup(second)[0].term, second)
  ignore(dictionary.create_dictionary_entry(second, 5L))
  assert_eq(dictionary.lookup(second)[0].count, 25L)
  ignore(dictionary.delete_dictionary_entry(first))
  assert_eq(dictionary.lookup(second)[0].count, 25L)
  assert_eq(dictionary.lookup(first, max_edit_distance=0), [])
  let restored = SymSpell::from_snapshot(dictionary.to_snapshot())
  assert_eq(restored.lookup(second)[0].count, 25L)
  ignore(restored.create_dictionary_entry(first, 30L))
  assert_eq(restored.lookup(first)[0].count, 30L)
}
