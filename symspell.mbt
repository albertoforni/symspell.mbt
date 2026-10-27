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
struct Word {
  term : String
  chars : Array[Char]
  term_hash : Int32
  signature : UInt32
  mut count : Int64
}

///|
/// Candidate de-duplication uses the immutable term and its cached hash, not
/// the frequency (which may change between lookups).
impl Eq for Word with fn equal(self, other) {
  self.term == other.term
}

///|
impl Hash for Word with fn hash_combine(self, hasher) {
  hasher.combine(self.term)
}

///|
impl Hash for Word with fn hash(self) {
  self.term_hash
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
// Native and Wasm have an intrinsic population count. Keep JavaScript's hot
// lookup path free of the software bit-count screen and its extra work.
#cfg(target="js")
fn use_character_filter() -> Bool {
  false
}

///|
#cfg(not(target="js"))
fn use_character_filter() -> Bool {
  true
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
  priv max_dictionary_edit_distance : Int32
  priv prefix_length : Int32
  priv count_threshold : Int64
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
  let word = {
    term,
    chars,
    term_hash: term.hash(),
    signature: character_signature(chars),
    count,
  }
  self.words[term] = word
  self.max_word_length = Int32::max(self.max_word_length, chars.length())
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
pub fn SymSpell::lookup(
  self : SymSpell,
  term : String,
  verbosity~ : Verbosity = Closest,
  max_edit_distance? : Int32,
  include_unknown~ : Bool = false,
) -> Array[Suggestion] raise SymSpellError {
  let limit = self.resolve_edit_distance(max_edit_distance)
  let suggestions : Array[Suggestion] = []
  let exact = self.words.get(term)
  if exact is Some(word) {
    suggestions.push({ term, distance: 0, count: word.count, })
    if verbosity != All {
      return suggestions
    }
  }
  let query = term.to_array()
  if limit > 0 && query.length() - limit <= self.max_word_length {
    let signature = if use_character_filter() {
      character_signature(query)
    } else {
      0U
    }
    let considered : @set.Set[Word] = @set.Set([])
    if exact is Some(word) {
      considered.add(word)
    }
    let workspace = OsaWorkspace::new()
    let mut cutoff = limit
    let prefix = String::from_array(
      query[:Int32::min(query.length(), self.prefix_length)],
    )
    let variants = [prefix]
    let seen = @set.Set([prefix])
    let mut start = 0
    for depth = 0; depth <= cutoff; depth = depth + 1 {
      let end = variants.length()
      for i = start; i < end; i = i + 1 {
        if self.deletes.get(variants[i]) is Some(bucket) {
          for word in bucket {
            if (query.length() - word.chars.length()).abs() > cutoff {
              continue
            }
            // The index only constrains prefixes. Reject incompatible suffix
            // character sets before hashing or scoring a full-length word.
            if use_character_filter() &&
              (
                query.length() > self.prefix_length ||
                word.chars.length() > self.prefix_length
              ) &&
              (
                (signature & word.signature.lnot()).popcnt() > cutoff ||
                (word.signature & signature.lnot()).popcnt() > cutoff
              ) {
              continue
            }
            if !considered.add_and_check(word) {
              continue
            }
            if osa_distance_with_workspace(query, word.chars, cutoff, workspace)
              is Some(distance) {
              if verbosity != All && distance < cutoff {
                suggestions.clear()
                cutoff = distance
              }
              let suggestion = { term: word.term, distance, count: word.count, }
              if verbosity == Top && !suggestions.is_empty() {
                if compare_suggestions(suggestion, suggestions[0]) < 0 {
                  suggestions[0] = suggestion
                }
              } else {
                suggestions.push(suggestion)
              }
            }
          }
        }
      }
      // Every edit <= cutoff has an intersection at a query deletion depth
      // <= cutoff. Avoid constructing deeper layers after a closer match.
      if depth >= cutoff {
        break
      }
      append_deletion_layer(variants, seen, start, end)
      start = end
      if start == variants.length() {
        break
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
/// Generate unique deletion variants of a Unicode prefix in breadth-first
/// order. Include the unchanged prefix so insertions and deletions can meet.
fn deletion_variants(
  chars : Array[Char],
  prefix_length : Int32,
  max_distance : Int32,
) -> Array[String] {
  let prefix = String::from_array(
    chars[:Int32::min(chars.length(), prefix_length)],
  )
  let variants = [prefix]
  let seen = @set.Set([prefix])
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
  seen : @set.Set[String],
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
        let builder = StringBuilder(size_hint=candidate.length())
        builder.write_view(candidate[:offset])
        builder.write_view(candidate[next:])
        let deleted = builder.to_string()
        if seen.add_and_check(deleted) {
          variants.push(deleted)
        }
      }
      previous = Some(character)
      offset = next
    }
  }
}
