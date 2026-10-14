///|
/// A summary of loading bigram frequencies. Blank lines are ignored.
pub(all) struct BigramLoadReport {
  parsed_entries : Int
  added_bigrams : Int
  skipped_lines : Int
} derive(Eq, Debug)

///|
/// Set the frequency of a pair of words. Unicode whitespace is canonicalized
/// to a single space; the two words retain their exact spelling and casing.
/// Returns true when the pair is new. Repeated pairs replace their frequency.
pub fn SymSpell::set_bigram_count(
  self : SymSpell,
  term : String,
  count : Int64,
) -> Bool raise SymSpellError {
  if count < 0L {
    raise InvalidFrequencyCount(count)
  }
  match canonical_bigram(term) {
    Some(key) => self.store_bigram(key, count)
    None => raise InvalidBigramTerm(term)
  }
}

///|
/// Look up the frequency of a word pair, using the same whitespace policy as
/// `set_bigram_count`. Invalid or missing pairs return None.
pub fn SymSpell::bigram_frequency(self : SymSpell, term : String) -> Int64? {
  canonical_bigram(term).bind(key => self.bigrams.get(key))
}

///|
/// Number of word pairs in the bigram dictionary.
pub fn SymSpell::bigram_count(self : SymSpell) -> Int {
  self.bigrams.length()
}

///|
/// Remove a pair of words. Invalid or missing pairs return false.
pub fn SymSpell::delete_bigram_entry(self : SymSpell, term : String) -> Bool {
  match canonical_bigram(term) {
    Some(key) if self.bigrams.contains(key) => {
      self.bigrams.remove(key)
      self.refresh_bigram_minimum()
      true
    }
    _ => false
  }
}

///|
/// Load `first second count` rows from text. For an explicit delimiter, the
/// term column contains both words, e.g. `first second$42`. Default count columns
/// are 2 for whitespace-separated input and 1 for a custom delimiter.
/// Parsing is strict and transactional by default, as for word dictionaries.
pub fn SymSpell::load_bigram_dictionary(
  self : SymSpell,
  text : String,
  term_index? : Int = 0,
  count_index? : Int,
  separator? : Char,
  strict? : Bool = true,
) -> BigramLoadReport raise SymSpellError {
  let count_index = count_index.unwrap_or(if separator is None { 2 } else { 1 })
  let parsed = parse_frequency_rows(
    text,
    term_index,
    count_index,
    separator,
    strict,
    bigram=true,
  )
  let mut added_bigrams = 0
  for entry in parsed.entries {
    let (term, count) = entry
    if self.store_bigram(term, count) {
      added_bigrams = added_bigrams + 1
    }
  }
  {
    parsed_entries: parsed.entries.length(),
    added_bigrams,
    skipped_lines: parsed.skipped_lines,
  }
}

///|
fn canonical_bigram(term : String) -> String? {
  let words = split_whitespace(term)
  if words.length() == 2 {
    Some(words[0] + " " + words[1])
  } else {
    None
  }
}

///|
fn SymSpell::store_bigram(
  self : SymSpell,
  term : String,
  count : Int64,
) -> Bool {
  let previous = self.bigrams.get(term)
  self.bigrams[term] = count
  if previous is Some(old) && old == self.bigram_count_min && count > old {
    self.refresh_bigram_minimum()
  } else {
    self.bigram_count_min = Int64::min(self.bigram_count_min, count)
  }
  previous is None
}

///|
fn SymSpell::refresh_bigram_minimum(self : SymSpell) -> Unit {
  self.bigram_count_min = max_frequency
  for count in self.bigrams.values() {
    self.bigram_count_min = Int64::min(self.bigram_count_min, count)
  }
}
