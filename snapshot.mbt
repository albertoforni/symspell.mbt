///|
let snapshot_magic : Bytes = b"MBSSIDX\x00"

///|
let snapshot_version : UInt = 1U

///|
/// Export settings, word counts, pending terms, bigrams, and the complete
/// deletion index as a versioned binary snapshot. Identical dictionary states
/// produce identical bytes regardless of insertion order. Strings use UTF-8;
/// frequencies remain exact signed 64-bit integers. File I/O belongs to callers.
pub fn SymSpell::to_snapshot(self : SymSpell) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytes(snapshot_magic[:])
  buffer.write_uint_le(snapshot_version)
  buffer.write_int_le(self.max_dictionary_edit_distance)
  buffer.write_int_le(self.prefix_length)
  buffer.write_int64_le(self.count_threshold)
  buffer.write_int64_le(self.corpus_size)
  let words = self.words.values().to_array()
  words.sort_by((left, right) => left.term.lexical_compare(right.term))
  let word_ids : Map[String, Int] = Map([])
  buffer.write_int_le(words.length())
  for i = 0; i < words.length(); i = i + 1 {
    let word = words[i]
    word_ids[word.term] = i
    write_snapshot_string(buffer, word.term)
    buffer.write_int64_le(word.count)
  }
  write_snapshot_frequencies(buffer, self.pending)
  write_snapshot_frequencies(buffer, self.bigrams)
  let keys = sorted_snapshot_keys(self.deletes)
  buffer.write_int_le(keys.length())
  for key in keys {
    write_snapshot_string(buffer, key)
    let ids = self.deletes[key].map(word => word_ids[word.term])
    ids.sort()
    buffer.write_int_le(ids.length())
    for id in ids {
      buffer.write_int_le(id)
    }
  }
  let checksum = snapshot_crc32(buffer.to_bytes()[:])
  buffer.write_uint_le(checksum)
  buffer.to_bytes()
}

///|
/// Restore an independent mutable dictionary, including its precomputed index.
/// Verify the format version, checksum, configuration, frequencies, canonical
/// table ordering, and every index membership. A counting algorithm checks index
/// completeness without regenerating deletion strings. Invalid data raises
/// `InvalidSnapshot(byte_offset, reason)`; an unknown format version raises
/// `UnsupportedSnapshotVersion(version)`. No existing dictionary is changed.
pub fn SymSpell::from_snapshot(data : Bytes) -> SymSpell raise SymSpellError {
  if data.length() < 56 {
    raise InvalidSnapshot(0, "snapshot is too short")
  }
  let end = data.length() - 4
  let reader = SnapshotReader::{ data: data[:end], offset: 0 }
  if !reader.take(8).equal_to_bytes(snapshot_magic) {
    raise InvalidSnapshot(0, "invalid snapshot magic")
  }
  let version = reader.read_uint()
  if version != snapshot_version {
    raise UnsupportedSnapshotVersion(version)
  }
  let checksum_reader = SnapshotReader::{ data: data[end:], offset: 0 }
  if checksum_reader.read_uint() != snapshot_crc32(data[:end]) {
    raise InvalidSnapshot(end, "checksum mismatch")
  }
  let max_dictionary_edit_distance = reader.read_size()
  let prefix_length = reader.read_size()
  if prefix_length <= max_dictionary_edit_distance {
    raise InvalidSnapshot(16, "prefix length must exceed maximum edit distance")
  }
  let count_threshold = reader.read_frequency()
  let corpus_size = reader.read_frequency()
  if corpus_size == 0L {
    raise InvalidSnapshot(28, "corpus size must be positive")
  }
  let dictionary = SymSpell::new(
    max_dictionary_edit_distance~,
    prefix_length~,
    count_threshold~,
    corpus_size~,
  )
  let word_count = reader.read_count(12)
  let words : Array[Word] = []
  let mut previous : String? = None
  for _i = 0; _i < word_count; _i = _i + 1 {
    let offset = reader.offset
    let term = reader.read_ordered_string(previous)
    previous = Some(term)
    let count = reader.read_frequency()
    if count < count_threshold {
      raise InvalidSnapshot(offset, "indexed frequency is below threshold")
    }
    let chars = term.to_array()
    let word = Word::{
      term,
      chars,
      term_hash: term.hash(),
      signature: character_signature(chars),
      count,
    }
    words.push(word)
    dictionary.words[term] = word
    dictionary.max_word_length = Int::max(
      dictionary.max_word_length,
      chars.length(),
    )
  }
  let pending_count = reader.read_count(12)
  previous = None
  for _i = 0; _i < pending_count; _i = _i + 1 {
    let offset = reader.offset
    let term = reader.read_ordered_string(previous)
    previous = Some(term)
    let count = reader.read_frequency()
    if count == 0L ||
      count >= count_threshold ||
      dictionary.words.contains(term) {
      raise InvalidSnapshot(offset, "invalid pending term or frequency")
    }
    dictionary.pending[term] = count
  }
  let bigram_count = reader.read_count(12)
  previous = None
  for _i = 0; _i < bigram_count; _i = _i + 1 {
    let offset = reader.offset
    let term = reader.read_ordered_string(previous)
    previous = Some(term)
    if canonical_bigram(term) != Some(term) {
      raise InvalidSnapshot(offset, "bigram must be a canonical pair of words")
    }
    let count = reader.read_frequency()
    let _ = dictionary.store_bigram(term, count)
  }
  let bucket_count = reader.read_count(12)
  let memberships = Array::make(words.length(), 0)
  previous = None
  for _i = 0; _i < bucket_count; _i = _i + 1 {
    let offset = reader.offset
    let key = reader.read_ordered_string(previous)
    previous = Some(key)
    let chars = key.to_array()
    let count = reader.read_count(4)
    if count == 0 {
      raise InvalidSnapshot(offset, "deletion bucket is empty")
    }
    let bucket : Array[Word] = []
    let mut previous_id = -1
    for _j = 0; _j < count; _j = _j + 1 {
      let id_offset = reader.offset
      let id = reader.read_size()
      if id >= words.length() || id <= previous_id {
        raise InvalidSnapshot(id_offset, "invalid or duplicate word reference")
      }
      previous_id = id
      let word = words[id]
      if !valid_snapshot_deletion(
          chars,
          word.chars,
          prefix_length,
          max_dictionary_edit_distance,
        ) {
        raise InvalidSnapshot(
          offset, "key is not a deletion of its word prefix",
        )
      }
      bucket.push(word)
      memberships[id] = memberships[id] + 1
    }
    dictionary.deletes[key] = bucket
  }
  if reader.offset != end {
    raise InvalidSnapshot(reader.offset, "unexpected trailing data")
  }
  for i = 0; i < words.length(); i = i + 1 {
    if !snapshot_variant_count_matches(
        words[i].chars,
        prefix_length,
        max_dictionary_edit_distance,
        memberships[i],
      ) {
      raise InvalidSnapshot(end, "incomplete deletion index")
    }
  }
  dictionary
}

///|
fn[K] sorted_snapshot_keys(entries : Map[String, K]) -> Array[String] {
  let keys = entries.keys().to_array()
  keys.sort_by(String::lexical_compare)
  keys
}

///|
fn write_snapshot_string(buffer : @buffer.Buffer, term : String) -> Unit {
  let encoded = @utf8.encode(term[:])
  buffer.write_int_le(encoded.length())
  buffer.write_bytes(encoded[:])
}

///|
fn write_snapshot_frequencies(
  buffer : @buffer.Buffer,
  entries : Map[String, Int64],
) -> Unit {
  let keys = sorted_snapshot_keys(entries)
  buffer.write_int_le(keys.length())
  for key in keys {
    write_snapshot_string(buffer, key)
    buffer.write_int64_le(entries[key])
  }
}

///|
priv struct SnapshotReader {
  data : BytesView
  mut offset : Int
}

///|
fn SnapshotReader::take(
  self : SnapshotReader,
  length : Int,
) -> BytesView raise SymSpellError {
  if length < 0 || length > self.data.length() - self.offset {
    raise InvalidSnapshot(self.offset, "truncated snapshot")
  }
  let start = self.offset
  self.offset = self.offset + length
  self.data[start:self.offset]
}

///|
fn SnapshotReader::read_uint(self : SnapshotReader) -> UInt raise SymSpellError {
  match self.take(4) {
    [u32le(value)] => value
    _ => raise InvalidSnapshot(self.offset, "truncated integer")
  }
}

///|
fn SnapshotReader::read_size(self : SnapshotReader) -> Int raise SymSpellError {
  let offset = self.offset
  let value = self.read_uint()
  if value > 2147483647U {
    raise InvalidSnapshot(offset, "size exceeds the supported integer range")
  }
  value.reinterpret_as_int()
}

///|
fn SnapshotReader::read_count(
  self : SnapshotReader,
  minimum_size : Int,
) -> Int raise SymSpellError {
  let offset = self.offset
  let count = self.read_size()
  if count > (self.data.length() - self.offset) / minimum_size {
    raise InvalidSnapshot(offset, "entry count exceeds remaining data")
  }
  count
}

///|
fn SnapshotReader::read_frequency(
  self : SnapshotReader,
) -> Int64 raise SymSpellError {
  let offset = self.offset
  let value = match self.take(8) {
    [i64le(value)] => value
    _ => raise InvalidSnapshot(offset, "truncated frequency")
  }
  if value < 0L {
    raise InvalidSnapshot(offset, "frequency must be nonnegative")
  }
  value
}

///|
fn SnapshotReader::read_ordered_string(
  self : SnapshotReader,
  previous : String?,
) -> String raise SymSpellError {
  let offset = self.offset
  let length = self.read_size()
  let encoded = self.take(length)
  let term = @utf8.decode(encoded, ignore_bom=false) catch {
    _ => raise InvalidSnapshot(offset, "invalid UTF-8 string")
  }
  if previous is Some(old) && old.lexical_compare(term) >= 0 {
    raise InvalidSnapshot(
      offset, "table terms must be unique and lexically ordered",
    )
  }
  term
}

///|
/// A key is valid exactly when it is a subsequence of the configured prefix,
/// shorter by at most the dictionary edit limit.
fn valid_snapshot_deletion(
  key : Array[Char],
  word : Array[Char],
  prefix_length : Int,
  max_distance : Int,
) -> Bool {
  let length = Int::min(word.length(), prefix_length)
  if key.length() > length || length - key.length() > max_distance {
    return false
  }
  let mut matched = 0
  for i = 0; i < length && matched < key.length(); i = i + 1 {
    if word[i] == key[matched] {
      matched = matched + 1
    }
  }
  matched == key.length()
}

///|
/// Count distinct subsequences by number of deleted characters. Appending the
/// current character extends every previous subsequence; skipping it adds one
/// deletion. Subtract the same subsequences appended at its previous occurrence
/// to avoid counting repeated characters twice. Together with unique valid
/// bucket references, the total proves that every deletion key is present.
/// Reject totals above the observed count early, bounding allocations and
/// arithmetic even for an excessive edit limit in a malformed snapshot.
fn snapshot_variant_count_matches(
  chars : Array[Char],
  prefix_length : Int,
  max_distance : Int,
  observed : Int,
) -> Bool {
  let length = Int::min(chars.length(), prefix_length)
  let distance = Int::min(max_distance, length)
  if observed <= distance {
    return false
  }
  if distance == 0 {
    return observed == 1
  }
  let mut counts = Array::make(distance + 1, 0L)
  counts[0] = 1L
  let history : Map[Char, (Int, Array[Int64])] = Map([])
  let mut total = 1L
  for i = 0; i < length; i = i + 1 {
    let character = chars[i]
    let previous = history.get(character)
    let current = Array::make(distance + 1, 0L)
    total = 0L
    for deleted = 0; deleted <= Int::min(distance, i + 1); deleted = deleted + 1 {
      let mut count = counts[deleted]
      if deleted > 0 {
        count = count + counts[deleted - 1]
      }
      if deleted < i + 1 && previous is Some((position, old)) {
        let duplicate = deleted - (i - position)
        if duplicate >= 0 {
          count = count - old[duplicate]
        }
      }
      current[deleted] = count
      total = total + count
      if total > observed.to_int64() {
        return false
      }
    }
    history[character] = (i, counts)
    counts = current
  }
  total == observed.to_int64()
}

///|
let snapshot_crc_table : FixedArray[UInt] = FixedArray::makei(256, index => {
  let mut value = index.reinterpret_as_uint()
  for _i = 0; _i < 8; _i = _i + 1 {
    value = if (value & 1U) == 1U {
      (value >> 1) ^ 0xEDB88320U
    } else {
      value >> 1
    }
  }
  value
})

///|
/// CRC-32/ISO-HDLC (the checksum used by gzip), with initial/final inversion.
fn snapshot_crc32(data : BytesView) -> UInt {
  let mut checksum = 0xFFFFFFFFU
  for byte in data {
    let index = ((checksum ^ byte.to_uint()) & 0xFFU).reinterpret_as_int()
    checksum = snapshot_crc_table[index] ^ (checksum >> 8)
  }
  checksum ^ 0xFFFFFFFFU
}
