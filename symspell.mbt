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
  distance : Int
  count : Int64
} derive(Eq, Debug)

///|
/// Configuration, dictionary parsing, and snapshot errors.
pub(all) suberror SymSpellError {
  InvalidEditDistance(Int)
  InvalidPrefixLength(Int)
  InvalidCountThreshold(Int64)
  InvalidColumns(Int, Int)
  InvalidDictionaryLine(Int, String)
  InvalidCorpusSize(Int64)
  InvalidFrequencyCount(Int64)
  InvalidBigramTerm(String)
  InvalidSegmentationWordLength(Int)
  InvalidSnapshot(Int, String)
  UnsupportedSnapshotVersion(UInt)
} derive(Eq, Debug)

///|
/// Frequencies share the signed 64-bit range used by upstream SymSpell.
let max_frequency : Int64 = 9223372036854775807L

///|
struct Word {
  term : String
  chars : Array[Char]
  mut count : Int64
}

///|
/// A mutable SymSpell dictionary. All indexing and distances use Unicode
/// characters, never UTF-8 bytes or UTF-16 offsets. Matching is case-sensitive;
/// normalize both dictionary terms and queries before using this API if needed.
pub struct SymSpell {
  priv words : Map[String, Word]
  priv pending : Map[String, Int64]
  priv deletes : Map[String, Array[Word]]
  priv bigrams : Map[String, Int64]
  priv mut bigram_count_min : Int64
  priv corpus_size : Int64
  priv max_dictionary_edit_distance : Int
  priv prefix_length : Int
  priv count_threshold : Int64
  priv mut max_word_length : Int
}

///|
/// Create a dictionary. `prefix_length` must exceed the maximum edit distance.
/// The default settings match upstream SymSpell: distance 2, prefix 7, count 1.
/// `corpus_size` must be positive and is used for phrase probability estimates;
/// its default is the corpus frequency total used by upstream SymSpell.
pub fn SymSpell::new(
  max_dictionary_edit_distance? : Int = 2,
  prefix_length? : Int = 7,
  count_threshold? : Int64 = 1L,
  corpus_size? : Int64 = 1024908267229L,
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
    words: Map([]),
    pending: Map([]),
    deletes: Map([]),
    bigrams: Map([]),
    bigram_count_min: max_frequency,
    corpus_size,
    max_dictionary_edit_distance,
    prefix_length,
    count_threshold,
    max_word_length: 0,
  }
}

///|
/// Number of terms whose frequency has reached the configured threshold.
pub fn SymSpell::word_count(self : SymSpell) -> Int {
  self.words.length()
}

///|
/// Number of distinct deletion keys in the index.
pub fn SymSpell::entry_count(self : SymSpell) -> Int {
  self.deletes.length()
}

///|
/// Number of terms still below the configured frequency threshold.
pub fn SymSpell::pending_word_count(self : SymSpell) -> Int {
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
    return false
  }
  if self.pending.get(term) is Some(previous) {
    count = add_frequency(previous, count)
  }
  if count < self.count_threshold {
    self.pending[term] = count
    return false
  }
  self.pending.remove(term)
  let chars = term.to_array()
  let word = { term, chars, count }
  self.words[term] = word
  self.max_word_length = Int::max(self.max_word_length, chars.length())
  for
    key in deletion_variants(
      chars,
      self.prefix_length,
      self.max_dictionary_edit_distance,
    ) {
    self.deletes.get_or_init(key, () => []).push(word)
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
          self.max_word_length = Int::max(
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
pub fn SymSpell::lookup(
  self : SymSpell,
  term : String,
  verbosity? : Verbosity = Closest,
  max_edit_distance? : Int,
  include_unknown? : Bool = false,
) -> Array[Suggestion] raise SymSpellError {
  let limit = self.resolve_edit_distance(max_edit_distance)
  let query = term.to_array()
  let suggestions : Array[Suggestion] = []
  if self.words.get(term) is Some(word) {
    suggestions.push({ term, distance: 0, count: word.count })
    if verbosity != All {
      return suggestions
    }
  }
  if limit > 0 && query.length() - limit <= self.max_word_length {
    let considered = @set.Set([term])
    let mut cutoff = limit
    for key in deletion_variants(query, self.prefix_length, limit) {
      if self.deletes.get(key) is Some(bucket) {
        for word in bucket {
          if considered.contains(word.term) {
            continue
          }
          considered.add(word.term)
          if osa_distance(query, word.chars, cutoff) is Some(distance) {
            if verbosity != All && distance < cutoff {
              suggestions.clear()
              cutoff = distance
            }
            suggestions.push({ term: word.term, distance, count: word.count })
          }
        }
      }
    }
  }
  suggestions.sort_by(compare_suggestions)
  if verbosity == Top {
    suggestions.truncate(1)
  }
  if suggestions.is_empty() && include_unknown {
    suggestions.push({ term, distance: limit + 1, count: 0L })
  }
  suggestions
}

///|
fn SymSpell::resolve_edit_distance(
  self : SymSpell,
  requested : Int?,
) -> Int raise SymSpellError {
  let limit = requested.unwrap_or(self.max_dictionary_edit_distance)
  if limit < 0 || limit > self.max_dictionary_edit_distance {
    raise InvalidEditDistance(limit)
  }
  limit
}

///|
fn compare_suggestions(left : Suggestion, right : Suggestion) -> Int {
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
/// Generate unique deletion variants of a Unicode prefix in breadth-first
/// order. Include the unchanged prefix so insertions and deletions can meet.
fn deletion_variants(
  chars : Array[Char],
  prefix_length : Int,
  max_distance : Int,
) -> Array[String] {
  let prefix = String::from_array(
    chars[:Int::min(chars.length(), prefix_length)],
  )
  let variants = [prefix]
  let seen = @set.Set([prefix])
  let mut start = 0
  for _depth = 0; _depth < max_distance; _depth = _depth + 1 {
    let end = variants.length()
    for i = start; i < end; i = i + 1 {
      let candidate = variants[i].to_array()
      for j = 0; j < candidate.length(); j = j + 1 {
        let builder = StringBuilder::new()
        for k = 0; k < candidate.length(); k = k + 1 {
          if k != j {
            builder.write_char(candidate[k])
          }
        }
        let deleted = builder.to_string()
        if !seen.contains(deleted) {
          seen.add(deleted)
          variants.push(deleted)
        }
      }
    }
    start = end
    if start == variants.length() {
      break
    }
  }
  variants
}
