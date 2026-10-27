///|
/// Correct a phrase, including accidentally joined or separated words. The
/// limit applies to each word lookup, not to the final phrase distance. Return
/// one suggestion with the final OSA distance and estimated phrase frequency.
/// Tokens are separated by Unicode whitespace. Spelling and case stay exact;
/// normalize dictionary terms and input consistently in the calling application.
pub fn SymSpell::lookup_compound(
  self : SymSpell,
  phrase : String,
  max_edit_distance? : Int32,
) -> Array[Suggestion] raise SymSpellError {
  let limit = self.resolve_edit_distance(max_edit_distance)
  let terms = split_whitespace(phrase)
  let parts : Array[Suggestion] = []
  let mut last_was_combination = false
  for i = 0; i < terms.length(); i = i + 1 {
    let term = terms[i]
    let chars = term.to_array()
    let suggestions = self.lookup(term, verbosity=Top, max_edit_distance=limit)
    let original = suggestions.get(0)
    if i > 0 && !last_was_combination {
      let combined = self.lookup(
        terms[i - 1] + term,
        verbosity=Top,
        max_edit_distance=limit,
      )
      if combined.get(0) is Some(merged) {
        let previous = parts[parts.length() - 1]
        let current = original.unwrap_or({
          term,
          distance: limit + 1,
          count: unknown_frequency(chars.length()),
        })
        let separate_distance = previous.distance + current.distance
        let merged_distance = merged.distance + 1
        let separate_count = previous.count.to_double() /
          self.corpus_size.to_double() *
          current.count.to_double()
        if merged_distance < separate_distance ||
          (
            merged_distance == separate_distance &&
            merged.count.to_double() > separate_count
          ) {
          parts[parts.length() - 1] = {
            term: merged.term,
            distance: merged_distance,
            count: merged.count,
          }
          last_was_combination = true
          continue
        }
      }
    }
    last_was_combination = false
    if original is Some(best) && (best.distance == 0 || chars.length() == 1) {
      parts.push(best)
      continue
    }
    let mut best_split = original
    for split = 1; split < chars.length(); split = split + 1 {
      let left = self.lookup(
        String::from_array(chars[:split]),
        verbosity=Top,
        max_edit_distance=limit,
      )
      let right = self.lookup(
        String::from_array(chars[split:]),
        verbosity=Top,
        max_edit_distance=limit,
      )
      guard left.get(0) is Some(first) else { continue }
      guard right.get(0) is Some(second) else { continue }
      let correction = first.term + " " + second.term
      let distance = osa_distance(chars, correction.to_array(), limit).unwrap_or(
        limit + 1,
      )
      if best_split is Some(best) {
        if distance > best.distance {
          continue
        }
        if distance < best.distance {
          best_split = None
        }
      }
      let count = match self.bigrams.get(correction) {
        Some(frequency) => {
          let mut count = frequency
          let concatenated = first.term + second.term
          match original {
            Some(single) =>
              if concatenated == term {
                count = Int64::max(count, add_frequency(single.count, 2L))
              } else if single.term == first.term || single.term == second.term {
                count = Int64::max(count, add_frequency(single.count, 1L))
              }
            None =>
              if concatenated == term {
                count = Int64::max(
                  count,
                  add_frequency(Int64::max(first.count, second.count), 2L),
                )
              }
          }
          count
        }
        None => self.estimated_bigram_count(first.count, second.count)
      }
      if best_split is None || (best_split is Some(best) && count > best.count) {
        best_split = Some({ term: correction, distance, count, })
      }
    }
    parts.push(
      best_split.unwrap_or({
        term,
        distance: limit + 1,
        count: unknown_frequency(chars.length()),
      }),
    )
  }
  let builder = StringBuilder()
  let mut count = self.corpus_size.to_double()
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      builder.write_char(' ')
    }
    builder.write_string(parts[i].term)
    count = count * (parts[i].count.to_double() / self.corpus_size.to_double())
  }
  let correction = builder.to_string()
  let original = phrase.to_array()
  let corrected = correction.to_array()
  let distance = osa_distance(
    original,
    corrected,
    Int32::max(original.length(), corrected.length()),
  ).unwrap()
  [{ term: correction, distance, count: probability_count(count), }]
}
