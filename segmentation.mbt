///|
/// Segmentation before and after spelling correction, the accumulated edit
/// penalty, and the sum of base-10 word log probabilities.
pub(all) struct Composition {
  segmented_string : String
  corrected_string : String
  distance_sum : Int32
  log_prob_sum : Double
} derive(Eq, Debug)

///|
priv struct SegmentationPath {
  previous : SegmentationPath?
  segmented : String
  corrected : String
  separator : Bool
}

///|
priv struct SegmentationState {
  end_position : Int32
  path : SegmentationPath?
  distance : Int32
  probability : Double
  separator_present : Bool
}

///|
/// Insert missing word boundaries and optionally correct spelling. Boundary
/// whitespace is trimmed and whitespace runs become a single separator. Case
/// folding, compatibility normalization, and hyphen removal are not
/// implicit. Normalize dictionary terms and input in the application if desired.
/// The default window is the longest dictionary word, or the input length when
/// the dictionary is empty. Unknown words remain unchanged with a length-based
/// penalty and probability prior. A window must be positive when supplied.
pub fn SymSpell::word_segmentation(
  self : SymSpell,
  phrase : String,
  max_edit_distance? : Int32,
  max_segmentation_word_length? : Int32,
) -> Composition raise SymSpellError {
  let limit = self.resolve_edit_distance(max_edit_distance)
  if max_segmentation_word_length is Some(length) && length <= 0 {
    raise InvalidSegmentationWordLength(length)
  }
  let chars = normalize_whitespace(phrase).to_array()
  if chars.is_empty() {
    return {
      segmented_string: "",
      corrected_string: "",
      distance_sum: 0,
      log_prob_sum: 0.0,
    }
  }
  let default_window = if self.max_word_length > 0 {
    self.max_word_length
  } else {
    chars.length()
  }
  let window = max_segmentation_word_length.unwrap_or(default_window)
  // With no dictionary and no existing boundaries, one unknown word is best
  // whenever its prior is at most one. Avoid quadratic candidate work for long
  // unknown input; compute its probability directly in log space.
  if self.words.is_empty() &&
    self.corpus_size >= 10L &&
    window >= chars.length() &&
    !chars.iter().any(Char::is_whitespace) {
    let text = String::from_array(chars[:])
    return {
      segmented_string: text,
      corrected_string: text,
      distance_sum: chars.length(),
      log_prob_sum: self.unknown_log_probability(chars.length()),
    }
  }
  let bounded_window = Int32::min(window, chars.length())
  // A normalized span of W non-space characters contains at most W spaces.
  // Bound the circular buffer without overflowing for very large windows.
  let size = bounded_window +
    Int32::min(bounded_window, chars.length() - bounded_window)
  let states : Array[SegmentationState?] = Array::make(size, None)
  let mut index = -1
  for start = 0; start < chars.length(); start = start + 1 {
    let previous = if start == 0 {
      SegmentationState::{
        end_position: 0,
        path: None,
        distance: 0,
        probability: 0.0,
        separator_present: false,
      }
    } else {
      states[index].unwrap()
    }
    // An existing separator advances the prefix without introducing an empty
    // word or charging for a space that was already present in the input.
    if chars[start].is_whitespace() {
      let destination = (index + 1) % size
      let end_position = start + 1
      let replace = match states[destination] {
        None => true
        Some(current) =>
          current.end_position != end_position ||
          previous.distance < current.distance ||
          (
            previous.distance == current.distance &&
            previous.probability > current.probability
          )
      }
      if replace {
        states[destination] = Some({
          end_position,
          path: previous.path,
          distance: previous.distance,
          probability: previous.probability,
          separator_present: true,
        })
      }
    }
    let maximum = Int32::min(chars.length() - start, size)
    let mut non_spaces = 0
    for length = 1; length <= maximum; length = length + 1 {
      if !chars[start + length - 1].is_whitespace() {
        non_spaces = non_spaces + 1
      }
      if non_spaces > window {
        break
      }
      let leading_space = chars[start].is_whitespace()
      let separator_cost = if leading_space || previous.separator_present {
        0
      } else {
        1
      }
      let builder = StringBuilder()
      let mut removed_spaces = 0
      let offset = if leading_space { start + 1 } else { start }
      for position = offset; position < start + length; position = position + 1 {
        if chars[position].is_whitespace() {
          removed_spaces = removed_spaces + 1
        } else {
          builder.write_char(chars[position])
        }
      }
      let part = builder.to_string()
      if part.is_empty() {
        continue
      }
      let results = self.lookup(part, verbosity=Top, max_edit_distance=limit)
      let (correction, penalty, probability) = match results.get(0) {
        Some(suggestion) =>
          (
            suggestion.term,
            removed_spaces + suggestion.distance,
            self.word_log_probability(suggestion.count),
          )
        None => {
          let length = part.char_length()
          (part, removed_spaces + length, self.unknown_log_probability(length))
        }
      }
      let destination = (index + length) % size
      let end_position = start + length
      let existing = match states[destination] {
        Some(current) if current.end_position == end_position => Some(current)
        _ => None
      }
      let distance = previous.distance + separator_cost + penalty
      let log_probability = previous.probability + probability
      let replace = match existing {
        None => true
        Some(current) =>
          distance < current.distance ||
          (
            (
              current.distance == previous.distance + penalty ||
              current.distance == distance
            ) &&
            log_probability > current.probability
          )
      }
      if replace {
        let add_separator = start > 0 && !attaches_to_previous(correction)
        let added_distance = if add_separator {
          separator_cost + penalty
        } else {
          penalty
        }
        states[destination] = Some({
          end_position,
          path: Some({
            previous: previous.path,
            segmented: part,
            corrected: correction,
            separator: add_separator,
          }),
          distance: previous.distance + added_distance,
          probability: log_probability,
          separator_present: false,
        })
      }
    }
    index = (index + 1) % size
  }
  let result = states[index].unwrap()
  // Keep backpointers during search and materialize strings only once. This
  // avoids repeatedly copying an ever-growing prefix for each candidate.
  let pieces : Array[SegmentationPath] = []
  let mut path = result.path
  while path is Some(piece) {
    pieces.push(piece)
    path = piece.previous
  }
  let segmented = StringBuilder()
  let corrected = StringBuilder()
  for i = pieces.length() - 1; i >= 0; i = i - 1 {
    let piece = pieces[i]
    if piece.separator {
      segmented.write_char(' ')
      corrected.write_char(' ')
    }
    segmented.write_string(piece.segmented)
    corrected.write_string(piece.corrected)
  }
  {
    segmented_string: segmented.to_string(),
    corrected_string: corrected.to_string(),
    distance_sum: result.distance,
    log_prob_sum: result.probability,
  }
}

///|
fn attaches_to_previous(term : String) -> Bool {
  let chars = term.to_array()
  (chars.length() == 1 && chars[0].is_ascii_punctuation()) ||
  (chars.length() == 2 && chars[0] == '\'')
}

///|
fn normalize_whitespace(text : String) -> String {
  let builder = StringBuilder()
  let mut separator = false
  for character in text {
    if character.is_whitespace() {
      separator = !builder.is_empty()
    } else {
      if separator {
        builder.write_char(' ')
      }
      builder.write_char(character)
      separator = false
    }
  }
  builder.to_string()
}
