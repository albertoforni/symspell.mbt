///|
/// The amount of detail returned by a lookup.
pub(all) enum Verbosity {
  Top
  Closest
  All
} derive(Eq, Debug)

///|
/// A suggested term, its Unicode character edit distance, and its frequency.
pub(all) struct Suggestion {
  term : String
  distance : Int32
  count : Int64
} derive(Eq, Debug)

///|
/// Configuration, dictionary parsing, and snapshot errors.
pub(all) suberror SymSpellError {
  InvalidEditDistance(Int32)
  InvalidPrefixLength(Int32)
  InvalidCountThreshold(Int64)
  InvalidColumns(Int32, Int32)
  InvalidDictionaryLine(Int32, String)
  InvalidCorpusSize(Int64)
  InvalidFrequencyCount(Int64)
  InvalidBigramTerm(String)
  InvalidSegmentationWordLength(Int32)
  InvalidSnapshot(Int32, String)
  UnsupportedSnapshotVersion(UInt32)
} derive(Eq, Debug)

///|
/// Frequencies share the signed 64-bit range used by upstream SymSpell.
let max_frequency : Int64 = 9223372036854775807L

///|
// Cached term_hash is used by the native/Wasm slots; JS uses runtime string hashes.
#warnings("-unused_field")
struct Word {
  term : String
  chars : Array[Char]
  term_hash : Int32
  mut seen : Int32
  signature : UInt32
  mut count : Int64
  mut exact : Suggestion
}

///|
/// A missing bit needs at least one insertion/replacement (or deletion in the
/// opposite direction). Collisions only weaken this lower bound, so the mask
/// remains safe for every Unicode character, including supplementary ones.
fn character_signature(chars : Array[Char]) -> UInt32 {
  let mut signature = 0U
  for character in chars {
    signature = signature | (1U << (character.to_int() & 31))
  }
  signature
}

///|
/// A mutable SymSpell dictionary. All indexing and distances use Unicode
/// characters, never UTF-8 bytes or UTF-16 offsets. Matching is case-sensitive;
/// normalize both dictionary terms and queries before using this API if needed.
pub struct SymSpell {
  priv words : WordTable
  priv pending : Map[String, Int64]
  priv deletes : StringTable[Array[Word]]
  priv bigrams : Map[String, Int64]
  priv mut bigram_count_min : Int64
  priv corpus_size : Int64
  priv max_dictionary_edit_distance : Int32
  priv prefix_length : Int32
  priv count_threshold : Int64
  priv mut lookup_id : Int32
  priv mut max_word_length : Int32
}

///|
/// Create a dictionary. `prefix_length` must exceed the maximum edit distance.
/// The default settings match upstream SymSpell: distance 2, prefix 7, count 1.
/// `corpus_size` must be positive and is used for phrase probability estimates;
/// its default is the corpus frequency total used by upstream SymSpell.
pub fn SymSpell::new(
  max_dictionary_edit_distance~ : Int32 = 2,
  prefix_length~ : Int32 = 7,
  count_threshold~ : Int64 = 1L,
  corpus_size~ : Int64 = 1024908267229L,
) -> SymSpell raise SymSpellError {
  if max_dictionary_edit_distance < 0 {
    raise InvalidEditDistance(max_dictionary_edit_distance)
  }
  if prefix_length <= max_dictionary_edit_distance {
    raise InvalidPrefixLength(prefix_length)
  }
  if count_threshold < 0L {
    raise InvalidCountThreshold(count_threshold)
  }
  if corpus_size <= 0L {
    raise InvalidCorpusSize(corpus_size)
  }
  {
    words: WordTable::new(),
    pending: Map([]),
    deletes: StringTable::new(),
    bigrams: Map([]),
    bigram_count_min: max_frequency,
    corpus_size,
    max_dictionary_edit_distance,
    prefix_length,
    count_threshold,
    lookup_id: 0,
    max_word_length: 0,
  }
}

///|
/// Number of terms whose frequency has reached the configured threshold.
pub fn SymSpell::word_count(self : SymSpell) -> Int32 {
  self.words.length()
}

///|
/// Number of distinct deletion keys in the index.
pub fn SymSpell::entry_count(self : SymSpell) -> Int32 {
  self.deletes.length()
}

///|
/// Number of terms still below the configured frequency threshold.
pub fn SymSpell::pending_word_count(self : SymSpell) -> Int32 {
  self.pending.length()
}

///|
/// Frequency of an indexed term. Below-threshold terms return `None`.
pub fn SymSpell::frequency(self : SymSpell, term : String) -> Int64? {
  self.words.get(term).map(word => word.count)
}

///|
/// Add a term or increase its frequency. Returns true only when a new term
/// enters the index. Repeated entries accumulate counts, saturating at Int64's
/// maximum. Nonpositive counts are ignored unless the threshold is zero.
pub fn SymSpell::create_dictionary_entry(
  self : SymSpell,
  term : String,
  count : Int64,
) -> Bool {
  let mut count = count
  if count <= 0L {
    if self.count_threshold > 0L {
      return false
    }
    count = 0L
  }
  if self.words.get(term) is Some(word) {
    word.count = add_frequency(word.count, count)
    word.exact = { term: word.term, distance: 0, count: word.count, }
    return false
  }
  let pending = if self.pending.is_empty() {
    None
  } else {
    self.pending.get(term)
  }
  if pending is Some(previous) {
    count = add_frequency(previous, count)
  }
  if count < self.count_threshold {
    self.pending[term] = count
    return false
  }
  if pending is Some(_) {
    self.pending.remove(term)
  }
  let chars = term.to_array()
  let word = {
    term,
    chars,
    term_hash: word_table_hash(term),
    seen: 0,
    signature: character_signature(chars),
    count,
    exact: { term, distance: 0, count, },
  }
  self.words[term] = word
  self.max_word_length = Int32::max(self.max_word_length, chars.length())
  for
    key in deletion_variants(
      chars,
      self.prefix_length,
      self.max_dictionary_edit_distance,
      deduplicate=false,
      source=term,
    ) {
    let bucket = self.deletes.get_or_init(key, () => [])
    if bucket.is_empty() || !physical_equal(bucket[bucket.length() - 1], word) {
      bucket.push(word)
    }
  }
  true
}

///|
/// Remove an indexed or below-threshold term. Returns false if it is absent.
/// The deletion buckets are cleaned so removal and re-insertion cannot leave
/// stale suggestions or retain empty buckets.
pub fn SymSpell::delete_dictionary_entry(
  self : SymSpell,
  term : String,
) -> Bool {
  match self.words.get(term) {
    None =>
      if self.pending.contains(term) {
        self.pending.remove(term)
        true
      } else {
        false
      }
    Some(word) => {
      self.words.remove(term)
      for
        key in deletion_variants(
          word.chars,
          self.prefix_length,
          self.max_dictionary_edit_distance,
        ) {
        if self.deletes.get(key) is Some(bucket) {
          let remaining = bucket.filter(entry => entry.term != term)
          if remaining.is_empty() {
            self.deletes.remove(key)
          } else {
            self.deletes[key] = remaining
          }
        }
      }
      if word.chars.length() == self.max_word_length {
        self.max_word_length = 0
        for entry in self.words.values() {
          self.max_word_length = Int32::max(
            self.max_word_length,
            entry.chars.length(),
          )
        }
      }
      true
    }
  }
}

///|
/// Find spelling suggestions. Rank by distance ascending, frequency descending,
/// and finally term ascending for deterministic ties. Distances use restricted
/// Damerau-Levenshtein (optimal string alignment), including adjacent swaps.
/// `max_edit_distance` defaults to the dictionary's configured maximum.
/// With `include_unknown`, an unmatched query is returned with count zero and
/// distance `max_edit_distance + 1`.
#inline
#cfg(target="js")
pub fn SymSpell::lookup(
  self : SymSpell,
  term : String,
  verbosity~ : Verbosity = Closest,
  max_edit_distance? : Int32,
  include_unknown~ : Bool = false,
) -> Array[Suggestion] raise SymSpellError {
  // The constructor already validated the default. Only explicit overrides
  // need another range check on this hot path.
  let limit = match max_edit_distance {
    None => self.max_dictionary_edit_distance
    Some(_) => self.resolve_edit_distance(max_edit_distance)
  }
  let exact = self.words.get(term)
  if exact is Some(word) && verbosity != All {
    return [word.exact]
  }
  self.lookup_candidates(term, verbosity, limit, include_unknown, exact)
}

///|
/// Find spelling suggestions. Rank by distance ascending, frequency descending,
/// and finally term ascending for deterministic ties. Distances use restricted
/// Damerau-Levenshtein (optimal string alignment), including adjacent swaps.
/// `max_edit_distance` defaults to the dictionary's configured maximum.
/// With `include_unknown`, an unmatched query is returned with count zero and
/// distance `max_edit_distance + 1`.
#inline
#cfg(not(target="js"))
pub fn SymSpell::lookup(
  self : SymSpell,
  term : String,
  verbosity~ : Verbosity = Closest,
  max_edit_distance? : Int32,
  include_unknown~ : Bool = false,
) -> Array[Suggestion] raise SymSpellError {
  // The constructor already validated the default. Only explicit overrides
  // need another range check on this hot path.
  let limit = match max_edit_distance {
    None => self.max_dictionary_edit_distance
    Some(_) => self.resolve_edit_distance(max_edit_distance)
  }
  let hash = word_table_hash(term)
  let mask = self.words.entries.length() - 1
  let mut slot = hash & mask
  while self.words.entries.unsafe_get(slot) is Some(entry) {
    if entry.term_hash == hash && entry.term == term {
      if verbosity != All {
        return [entry.exact]
      }
      return self.lookup_candidates(
        term,
        verbosity,
        limit,
        include_unknown,
        Some(entry),
      )
    }
    slot = (slot + 1) & mask
  }
  self.lookup_candidates(term, verbosity, limit, include_unknown, None)
}

///|
fn SymSpell::lookup_candidates(
  self : SymSpell,
  term : String,
  verbosity : Verbosity,
  limit : Int32,
  include_unknown : Bool,
  exact : Word?,
) -> Array[Suggestion] {
  let suggestions : Array[Suggestion] = []
  if exact is Some(word) {
    suggestions.push(word.exact)
  }
  let query = term.to_array()
  if limit > 0 && query.length() - limit <= self.max_word_length {
    if self.lookup_id == 2147483647 {
      for word in self.words.values() {
        word.seen = 0
      }
      self.lookup_id = 0
    }
    self.lookup_id = self.lookup_id + 1
    let lookup_id = self.lookup_id
    if exact is Some(word) {
      word.seen = lookup_id
    }
    let search = LookupSearch::{
      query,
      signature: character_signature(query),
      lookup_id,
      verbosity,
      cutoff: limit,
      suggestions,
      workspace: OsaWorkspace::new(),
    }
    if limit <= 2 {
      let prefix_length = Int32::min(query.length(), self.prefix_length)
      // Enumerate deletion positions directly. Hashes can collide: scan every
      // matching entry and verify full words, so collisions only add candidates.
      // Repeated characters may revisit a bucket but never rescore a word.
      for depth = 0; depth <= search.cutoff; depth = depth + 1 {
        for first = 0
            first < (if depth == 0 { 1 } else { prefix_length })
            first = first + 1 {
          for second = (if depth == 2 { first + 1 } else { 0 })
              second < (if depth == 2 { prefix_length } else { 1 })
              second = second + 1 {
            let hash = deletion_hash(
              query,
              prefix_length,
              if depth > 0 {
                first
              } else {
                -1
              },
              if depth == 2 {
                second
              } else {
                -1
              },
            )
            self.deletes.each_hash(hash, bucket => {
              search.consider(bucket, self.prefix_length)
            })
          }
        }
      }
    } else {
      let prefix = String::from_array(
        query[:Int32::min(query.length(), self.prefix_length)],
      )
      let variants = [prefix]
      let seen : StringTable[Bool] = StringTable::new()
      seen[prefix] = true
      let mut start = 0
      for depth = 0; depth <= search.cutoff; depth = depth + 1 {
        let end = variants.length()
        for i = start; i < end; i = i + 1 {
          if self.deletes.get(variants[i]) is Some(bucket) {
            search.consider(bucket, self.prefix_length)
          }
        }
        // Every edit <= search.cutoff has an intersection at a query deletion depth
        // <= search.cutoff. Avoid constructing deeper layers after a closer match.
        if depth >= search.cutoff {
          break
        }
        append_deletion_layer(variants, seen, start, end)
        start = end
        if start == variants.length() {
          break
        }
      }
    }
  }
  if verbosity != Top {
    suggestions.sort_by(compare_suggestions)
  }
  if suggestions.is_empty() && include_unknown {
    suggestions.push({ term, distance: limit + 1, count: 0L, })
  }
  suggestions
}

///|
#inline
fn SymSpell::resolve_edit_distance(
  self : SymSpell,
  requested : Int32?,
) -> Int32 raise SymSpellError {
  let limit = requested.unwrap_or(self.max_dictionary_edit_distance)
  if limit < 0 || limit > self.max_dictionary_edit_distance {
    raise InvalidEditDistance(limit)
  }
  limit
}

///|
fn compare_suggestions(left : Suggestion, right : Suggestion) -> Int32 {
  let distance = left.distance.compare(right.distance)
  if distance != 0 {
    return distance
  }
  let frequency = right.count.compare(left.count)
  if frequency != 0 {
    return frequency
  }
  left.term.lexical_compare(right.term)
}

///|
fn add_frequency(left : Int64, right : Int64) -> Int64 {
  if right > max_frequency - left {
    max_frequency
  } else {
    left + right
  }
}

///|
/// Generate deletion variants of a Unicode prefix, including the unchanged
/// prefix. Index insertion can deduplicate against each bucket's final word
/// instead of allocating a separate set for every dictionary entry.
fn deletion_variants(
  chars : Array[Char],
  prefix_length : Int32,
  max_distance : Int32,
  deduplicate~ : Bool = true,
  source? : String,
) -> Array[String] {
  let length = Int32::min(chars.length(), prefix_length)
  let prefix = match source {
    Some(text) => {
      let mut end = 0
      for i = 0; i < length; i = i + 1 {
        end = end + (if chars[i].to_int() > 0xFFFF { 2 } else { 1 })
      }
      text.unsafe_substring(start=0, end~)
    }
    None => String::from_array(chars[:length])
  }
  let variants = [prefix]
  if max_distance <= 2 {
    let length = Int32::min(chars.length(), prefix_length)
    let offsets = [0]
    for i = 0; i < length; i = i + 1 {
      offsets.push(
        offsets[i] + (if chars[i].to_int() > 0xFFFF { 2 } else { 1 }),
      )
    }
    if max_distance > 0 {
      for i = 0; i < length; i = i + 1 {
        if i > 0 && chars[i] == chars[i - 1] {
          continue
        }
        let candidate = prefix.unsafe_substring(start=0, end=offsets[i]) +
          prefix.unsafe_substring(start=offsets[i + 1], end=prefix.length())
        variants.push(candidate)
        if max_distance == 2 {
          let width = offsets[i + 1] - offsets[i]
          for j = i + 1; j < length; j = j + 1 {
            if j > i + 1 && chars[j] == chars[j - 1] {
              continue
            }
            let deleted = candidate.unsafe_substring(
                start=0,
                end=offsets[j] - width,
              ) +
              candidate.unsafe_substring(
                start=offsets[j + 1] - width,
                end=candidate.length(),
              )
            if !deduplicate || !variants.contains(deleted) {
              variants.push(deleted)
            }
          }
        }
      }
    }
    return variants
  }
  let seen : StringTable[Bool] = StringTable::new()
  seen[prefix] = true
  let mut start = 0
  for _depth = 0; _depth < max_distance; _depth = _depth + 1 {
    let end = variants.length()
    append_deletion_layer(variants, seen, start, end)
    start = end
    if start == variants.length() {
      break
    }
  }
  variants
}

///|
/// Append one breadth-first layer. UTF-16 offsets advance by whole Unicode
/// characters, so the slices cannot split a supplementary character. Copy two
/// views instead of allocating a character array and rebuilding every character
/// for every deletion. Consecutive equal characters yield the same deletion.
fn append_deletion_layer(
  variants : Array[String],
  seen : StringTable[Bool],
  start : Int32,
  end : Int32,
) -> Unit {
  for i = start; i < end; i = i + 1 {
    let candidate = variants[i]
    let mut offset = 0
    let mut previous : Char? = None
    for character in candidate {
      let next = offset + (if character.to_int() > 0xFFFF { 2 } else { 1 })
      if previous != Some(character) {
        let deleted = candidate.unsafe_substring(start=0, end=offset) +
          candidate.unsafe_substring(start=next, end=candidate.length())
        if seen.insert(deleted, true) {
          variants.push(deleted)
        }
      }
      previous = Some(character)
      offset = next
    }
  }
}

///|
/// Match the table hash without allocating a deletion string. Prefix positions
/// are Unicode code points; supplementary characters contribute both UTF-16
/// units to exactly the same hash as their stored string.
fn deletion_hash(
  chars : Array[Char],
  length : Int32,
  first : Int32,
  second : Int32,
) -> Int32 {
  let mut hash = 0U
  for i = 0; i < length; i = i + 1 {
    if i == first || i == second {
      continue
    }
    let code = chars[i].to_int()
    if code > 0xFFFF {
      hash = hash * 31U +
        ((code - 0x10000) >> 10).reinterpret_as_uint() +
        0xD800U
      hash = hash * 31U +
        ((code - 0x10000) & 1023).reinterpret_as_uint() +
        0xDC00U
    } else {
      hash = hash * 31U + code.reinterpret_as_uint()
    }
  }
  hash = (hash ^ (hash >> 16)) * 0x85ebca6bU
  let result = (hash ^ (hash >> 13)).reinterpret_as_int()
  if result == 0 {
    1
  } else {
    result
  }
}

///|
/// Candidate markers and distance buffers belong to this synchronous search.
/// No user code runs while its dictionary epoch is active.
priv struct LookupSearch {
  query : Array[Char]
  signature : UInt32
  lookup_id : Int32
  verbosity : Verbosity
  mut cutoff : Int32
  suggestions : Array[Suggestion]
  workspace : OsaWorkspace
}

///|
fn LookupSearch::consider(
  self : LookupSearch,
  bucket : Array[Word],
  prefix_length : Int32,
) -> Unit {
  for word in bucket {
    if word.seen == self.lookup_id {
      continue
    }
    word.seen = self.lookup_id
    if (self.query.length() - word.chars.length()).abs() > self.cutoff {
      continue
    }
    // The deletion index constrains prefixes; screen suffix character sets
    // before scoring. The screen is a lower bound even for Unicode collisions.
    if (
        self.query.length() > prefix_length ||
        word.chars.length() > prefix_length
      ) &&
      (
        (self.signature & word.signature.lnot()).popcnt() > self.cutoff ||
        (word.signature & self.signature.lnot()).popcnt() > self.cutoff
      ) {
      continue
    }
    if osa_distance_with_workspace(
        self.query,
        word.chars,
        self.cutoff,
        self.workspace,
      )
      is Some(distance) {
      if self.verbosity != All && distance < self.cutoff {
        self.suggestions.clear()
        self.cutoff = distance
      }
      if self.verbosity == Top && !self.suggestions.is_empty() {
        let best = self.suggestions[0]
        if word.count > best.count ||
          (word.count == best.count && word.term.lexical_compare(best.term) < 0) {
          self.suggestions[0] = {
            term: word.term,
            distance,
            count: word.count,
          }
        }
      } else {
        self.suggestions.push({ term: word.term, distance, count: word.count, })
      }
    }
  }
}
