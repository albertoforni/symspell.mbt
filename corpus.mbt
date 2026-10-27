///|
/// A summary of building a word dictionary from plain text. `parsed_tokens`
/// counts every occurrence, including repetitions and below-threshold words.
/// `added_words` counts terms newly admitted to the suggestion index.
pub(all) struct CorpusReport {
  parsed_tokens : Int32
  added_words : Int32
} derive(Eq, Debug)

///|
/// Count words in plain text, merging them into this dictionary. Each token
/// adds one occurrence using the existing frequency and threshold rules.
/// Tokens are maximal runs of Unicode 16.0 letters, numbers, and straight or
/// curly apostrophes (U+0027 and U+2019). All other characters are separators,
/// including underscores, hyphens, combining marks, and emoji. Apostrophes
/// are retained even at token edges or on their own, as in symspellpy.
/// Casing and normalization stay exact; normalize text and queries in the
/// application if needed. This method builds only unigrams and leaves the
/// configured `corpus_size` unchanged. Each call ends its final token, so
/// incremental input should be split at token boundaries, e.g. whole lines.
pub fn SymSpell::create_dictionary(
  self : SymSpell,
  text : String,
) -> CorpusReport {
  let builder = StringBuilder()
  let mut parsed_tokens = 0
  let mut added_words = 0
  for character in text {
    if is_corpus_alphanumeric(character) || character is ('\'' | '’') {
      builder.write_char(character)
    } else if !builder.is_empty() {
      parsed_tokens = parsed_tokens + 1
      if self.create_dictionary_entry(builder.to_string(), 1L) {
        added_words = added_words + 1
      }
      builder.reset()
    }
  }
  if !builder.is_empty() {
    parsed_tokens = parsed_tokens + 1
    if self.create_dictionary_entry(builder.to_string(), 1L) {
      added_words = added_words + 1
    }
  }
  { parsed_tokens, added_words, }
}

///|
fn is_corpus_alphanumeric(character : Char) -> Bool {
  if character.is_ascii() {
    return character.is_ascii_alphabetic() || character.is_ascii_digit()
  }
  let code = character.to_int()
  let mut low = 0
  let mut high = corpus_alphanumeric_ranges.length()
  while low < high {
    let middle = low + (high - low) / 2
    let (first, last) = corpus_alphanumeric_ranges[middle]
    if code < first {
      high = middle
    } else if code > last {
      low = middle + 1
    } else {
      return true
    }
  }
  false
}
