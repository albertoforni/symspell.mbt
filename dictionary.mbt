///|
/// A summary of loading a dictionary. Blank lines are ignored; `skipped_lines`
/// counts malformed nonblank lines skipped when `strict=false`.
pub(all) struct LoadReport {
  parsed_entries : Int32
  added_words : Int32
  skipped_lines : Int32
} derive(Eq, Debug)

///|
/// Load word/frequency pairs from text, merging them into this dictionary.
/// The default separator is Unicode whitespace; an explicit character supports
/// CSV-like dictionaries with spaces inside terms. Column indices are zero-based.
/// Counts must be nonnegative signed 64-bit integers. A leading BOM and CRLF
/// line endings are accepted. In strict mode, malformed lines raise an error
/// with a one-based line number and leave the dictionary unchanged.
pub fn SymSpell::load_dictionary(
  self : SymSpell,
  text : String,
  term_index~ : Int32 = 0,
  count_index~ : Int32 = 1,
  separator? : Char,
  strict~ : Bool = true,
) -> LoadReport raise SymSpellError {
  let parsed = parse_frequency_rows(
    text,
    term_index,
    count_index,
    separator,
    strict,
    bigram=false,
  )
  let mut added_words = 0
  for entry in parsed.entries {
    let (term, count) = entry
    if self.create_dictionary_entry(term, count) {
      added_words = added_words + 1
    }
  }
  {
    parsed_entries: parsed.entries.length(),
    added_words,
    skipped_lines: parsed.skipped_lines,
  }
}

///|
priv struct ParsedFrequencyRows {
  entries : Array[(String, Int64)]
  skipped_lines : Int32
}

///|
fn parse_frequency_rows(
  text : String,
  term_index : Int32,
  count_index : Int32,
  separator : Char?,
  strict : Bool,
  bigram~ : Bool,
) -> ParsedFrequencyRows raise SymSpellError {
  if term_index < 0 || count_index < 0 {
    raise InvalidColumns(term_index, count_index)
  }
  // Stage entries before mutation so a strict parse error is transactional.
  let entries : Array[(String, Int64)] = []
  let mut skipped_lines = 0
  let mut line_number = 0
  for raw_line in text.split("\n") {
    line_number = line_number + 1
    let line = if line_number == 1 {
      raw_line.trim_start(chars="\u{FEFF}").trim().to_owned()
    } else {
      raw_line.trim().to_owned()
    }
    if line.is_empty() {
      continue
    }
    let fields = match separator {
      Some(character) =>
        line.split(character.to_string()).map(StringView::to_owned).to_array()
      None => split_whitespace(line)
    }
    let parsed = if Int32::max(term_index, count_index) < fields.length() {
      let count = try @string.parse_int64(fields[count_index][:]) catch {
        _ => None
      } noraise {
        count => Some(count)
      }
      let term = if bigram && separator is None {
        if term_index < fields.length() - 1 {
          Some(fields[term_index] + " " + fields[term_index + 1])
        } else {
          None
        }
      } else {
        Some(fields[term_index])
      }
      let term = if bigram { term.bind(canonical_bigram) } else { term }
      match (term, count) {
        (Some(key), Some(value)) if value >= 0L => Some((key, value))
        _ => None
      }
    } else {
      None
    }
    match parsed {
      Some(entry) => entries.push(entry)
      None => {
        if strict {
          raise InvalidDictionaryLine(line_number, line)
        }
        skipped_lines = skipped_lines + 1
      }
    }
  }
  { entries, skipped_lines, }
}

///|
fn split_whitespace(text : String) -> Array[String] {
  let fields : Array[String] = []
  let builder = StringBuilder()
  for character in text {
    if character.is_whitespace() {
      if !builder.is_empty() {
        fields.push(builder.to_string())
        builder.reset()
      }
    } else {
      builder.write_char(character)
    }
  }
  if !builder.is_empty() {
    fields.push(builder.to_string())
  }
  fields
}
