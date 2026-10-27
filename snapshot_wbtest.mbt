///|
fn expect_invalid_snapshot(data : Bytes, reason : String) -> Unit raise {
  try SymSpell::from_snapshot(data) catch {
    InvalidSnapshot(_, actual) => assert_eq(actual, reason)
    _ => fail("unexpected snapshot error")
  } noraise {
    _ => fail("invalid snapshot was accepted")
  }
}

///|
fn checked_test_snapshot(payload : Bytes) -> Bytes {
  let buffer = @buffer.from_bytes(payload[:])
  buffer.write_uint_le(snapshot_crc32(payload[:]))
  buffer.to_bytes()
}

///|
fn raw_test_snapshot(
  words : Array[(String, Int64)],
  deletes : Array[(String, Array[Int32])],
  pending~ : Array[(String, Int64)] = [],
  bigrams~ : Array[(String, Int64)] = [],
  distance~ : Int32 = 1,
  prefix~ : Int32 = 2,
  threshold~ : Int64 = 1L,
  corpus~ : Int64 = 10000L,
) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytes(snapshot_magic[:])
  buffer.write_uint_le(1U)
  buffer.write_int_le(distance)
  buffer.write_int_le(prefix)
  buffer.write_int64_le(threshold)
  buffer.write_int64_le(corpus)
  for table in [words, pending, bigrams] {
    buffer.write_int_le(table.length())
    for entry in table {
      let (term, count) = entry
      write_snapshot_string(buffer, term)
      buffer.write_int64_le(count)
    }
  }
  buffer.write_int_le(deletes.length())
  for entry in deletes {
    let (key, ids) = entry
    write_snapshot_string(buffer, key)
    buffer.write_int_le(ids.length())
    for id in ids {
      buffer.write_int_le(id)
    }
  }
  checked_test_snapshot(buffer.to_bytes())
}

///|
fn replace_test_uint(data : Bytes, offset : Int32, value : UInt32) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytes(data[:offset])
  buffer.write_uint_le(value)
  buffer.write_bytes(data[offset + 4:data.length() - 4])
  checked_test_snapshot(buffer.to_bytes())
}

///|
test "snapshot checksum matches standard CRC32 vectors" {
  assert_eq(snapshot_crc32(b""[:]), 0U)
  assert_eq(snapshot_crc32(b"123456789"[:]), 0xCBF43926U)
  let bytes = Bytes::makei(256, Int32::to_byte)
  assert_eq(snapshot_crc32(bytes[:]), 0x29058C73U)
}

///|
test "snapshot subsequence counts match exhaustive deletion sets" {
  let terms = [""]
  let mut level = [""]
  for _length = 0; _length < 5; _length = _length + 1 {
    let next : Array[String] = []
    for prefix in level {
      for character in ["a", "b", "😀"] {
        next.push(prefix + character)
      }
    }
    terms.append(next)
    level = next
  }
  for term in terms {
    let chars = term.to_array()
    for distance = 0; distance <= 5; distance = distance + 1 {
      for prefix in [distance + 1, 7] {
        let variants = deletion_variants(chars, prefix, distance)
        assert_true(
          snapshot_variant_count_matches(
            chars,
            prefix,
            distance,
            variants.length(),
          ),
        )
        assert_false(
          snapshot_variant_count_matches(
            chars,
            prefix,
            distance,
            variants.length() - 1,
          ),
        )
        assert_false(
          snapshot_variant_count_matches(
            chars,
            prefix,
            distance,
            variants.length() + 1,
          ),
        )
        for key in variants {
          assert_true(
            valid_snapshot_deletion(key.to_array(), chars, prefix, distance),
          )
        }
      }
    }
  }
  assert_false(
    snapshot_variant_count_matches("abc".to_array(), 2147483647, 2147483646, 1),
  )
  assert_true(
    snapshot_variant_count_matches(
      "aaaaa".to_array(),
      2147483647,
      2147483646,
      6,
    ),
  )
  assert_false(valid_snapshot_deletion("ba".to_array(), "ab".to_array(), 2, 1))
  assert_false(valid_snapshot_deletion("".to_array(), "ab".to_array(), 2, 1))
}

///|
test "snapshot validates configuration and frequency invariants" {
  expect_invalid_snapshot(
    raw_test_snapshot([], [], prefix=1),
    "prefix length must exceed maximum edit distance",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], corpus=0L),
    "corpus size must be positive",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], threshold=-1L),
    "frequency must be nonnegative",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], corpus=-1L),
    "frequency must be nonnegative",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", -1L)], []),
    "frequency must be nonnegative",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 0L)], []),
    "indexed frequency is below threshold",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], pending=[("a", 0L)], threshold=2L),
    "invalid pending term or frequency",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], pending=[("a", 2L)], threshold=2L),
    "invalid pending term or frequency",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 2L)], [], pending=[("a", 1L)], threshold=2L),
    "invalid pending term or frequency",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], bigrams=[("single", 1L)]),
    "bigram must be a canonical pair of words",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], bigrams=[("a\tb", 1L)]),
    "bigram must be a canonical pair of words",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], bigrams=[("a b", -1L)]),
    "frequency must be nonnegative",
  )
}

///|
test "snapshot rejects noncanonical tables and duplicate references" {
  let order_error = "table terms must be unique and lexically ordered"
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L), ("a", 2L)], []),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("b", 1L), ("a", 2L)], []),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], pending=[("b", 1L), ("a", 1L)], threshold=2L),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([], [], bigrams=[("a b", 1L), ("a b", 2L)]),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("a", [0]), ("", [0])]),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("", [0]), ("", [0])]),
    order_error,
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("", [0, 0])]),
    "invalid or duplicate word reference",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L), ("b", 1L)], [("", [1, 0])]),
    "invalid or duplicate word reference",
  )
}

///|
test "snapshot rejects inconsistent index memberships and missing deletion keys" {
  expect_invalid_snapshot(
    raw_test_snapshot([("aaaa", 1L)], [("aaaa", [])]),
    "deletion bucket is empty",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("", [1])]),
    "invalid or duplicate word reference",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("b", [0])]),
    "key is not a deletion of its word prefix",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("ab", 1L)], [("", [0])]),
    "key is not a deletion of its word prefix",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("ab", 1L)], [("ba", [0])]),
    "key is not a deletion of its word prefix",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("abcdef", 1L)], [("abc", [0])]),
    "key is not a deletion of its word prefix",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], []),
    "incomplete deletion index",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("a", 1L)], [("a", [0])]),
    "incomplete deletion index",
  )
  expect_invalid_snapshot(
    raw_test_snapshot([("aa", 1L)], [("a", [0])]),
    "incomplete deletion index",
  )
  let restored = SymSpell::from_snapshot(
    raw_test_snapshot([("aa", 1L)], [("a", [0]), ("aa", [0])]),
  )
  assert_eq(restored.lookup("a")[0].term, "aa")
}

///|
test "snapshot rejects impossible sizes malformed UTF8 and trailing bytes" {
  let empty = raw_test_snapshot([], [])
  expect_invalid_snapshot(
    replace_test_uint(empty, 12, 0xFFFFFFFFU),
    "size exceeds the supported integer range",
  )
  expect_invalid_snapshot(
    replace_test_uint(empty, 36, 0x7FFFFFFFU),
    "entry count exceeds remaining data",
  )
  let one = raw_test_snapshot([("a", 1L)], [("", [0]), ("a", [0])])
  expect_invalid_snapshot(
    replace_test_uint(one, 40, 0x7FFFFFFFU),
    "truncated snapshot",
  )
  let malformed = one.to_array()
  malformed[44] = b'\xFF'
  expect_invalid_snapshot(
    checked_test_snapshot(Bytes::from_array(malformed[:malformed.length() - 4])),
    "invalid UTF-8 string",
  )
  let trailing = @buffer.from_bytes(empty[:empty.length() - 4])
  trailing.write_byte(b'\x00')
  expect_invalid_snapshot(
    checked_test_snapshot(trailing.to_bytes()),
    "unexpected trailing data",
  )
  let bad_magic = empty.to_array()
  bad_magic[0] = b'\x00'
  expect_invalid_snapshot(
    Bytes::from_array(bad_magic[:]),
    "invalid snapshot magic",
  )
}

///|
test "snapshot checks checksum-valid mutations without traps or noncanonical results" {
  let dictionary = SymSpell::new(count_threshold=3L, corpus_size=10000L)
  let _ = dictionary.load_dictionary(
    "hello 100\nworld 90\na 3\nab 7\n😀 8\nrare 1",
  )
  let _ = dictionary.set_bigram_count("hello world", 50L)
  let snapshot = dictionary.to_snapshot()
  let mut state = 20261014U
  for _i = 0; _i < 2048; _i = _i + 1 {
    let payload = snapshot[:snapshot.length() - 4].to_array()
    state = state * 1664525U + 1013904223U
    let edits = 1 + ((state >> 16) & 3U).reinterpret_as_int()
    for _j = 0; _j < edits; _j = _j + 1 {
      state = state * 1664525U + 1013904223U
      let offset = 8 +
        (state % (payload.length() - 8).reinterpret_as_uint()).reinterpret_as_int()
      state = state * 1664525U + 1013904223U
      payload[offset] = (state >> 24).to_byte()
    }
    let mutant = checked_test_snapshot(Bytes::from_array(payload[:]))
    try SymSpell::from_snapshot(mutant) catch {
      InvalidSnapshot(_, _) | UnsupportedSnapshotVersion(_) => ()
      _ => fail("malformed snapshots should raise snapshot errors")
    } noraise {
      restored => assert_eq(restored.to_snapshot(), mutant)
    }
  }
}
