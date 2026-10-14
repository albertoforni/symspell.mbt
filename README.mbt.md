# SymSpell for MoonBit

A pure MoonBit implementation of SymSpell spelling correction and segmentation.
It uses a precomputed deletion index to find candidates, then verifies them
with cutoff-aware optimal string alignment distance and ranks them by frequency.

The library depends only on `moonbitlang/core` and runs on native, JavaScript,
WebAssembly, and WebAssembly GC. There are no C bindings or runtime dictionary
downloads. The module name is `albertoforni/symspell`; version 0.3.0 is currently
a local project and has not been published to Mooncakes.

## Run the example

From this directory:

```sh
moon run cmd/main --target native
```

The example corrects `memebers` to `members`, `cafe` to `café`, `東亰` to `東京`,
and `😃` to `😀` using a small, embedded dictionary. It also demonstrates compound
correction and segmentation, including `whereiz` → `where is`,
`ste am machie` → `steam machine`, and `helloworld` → `hello world`, then
restores a dictionary from a binary snapshot. It runs with
`--target js`, `--target wasm`, or `--target wasm-gc`.

## Basic usage

Import the library from a consuming package:

```moonbit nocheck
import {
  "albertoforni/symspell",
}
```

```mbt check
///|
test {
  let dictionary = @symspell.SymSpell::new()
  let report = dictionary.load_dictionary(
    "members 226656153\nmember 100000\nremember 90000\n",
  )
  assert_eq(report.added_words, 3)
  let suggestions = dictionary.lookup("memebers")
  assert_eq(suggestions[0].term, "members")
  assert_eq(suggestions[0].distance, 1)
  assert_eq(suggestions[0].count, 226656153L)
}
```

`new()` and `lookup()` raise typed `SymSpellError` values for invalid settings;
`load_dictionary()` also raises parsing errors. A MoonBit `test` block can
propagate these errors. In a `main` block, use `try ... catch` to handle them;
the bundled demo uses `try!` because its dictionary and settings are fixed.

## Lookup modes

`lookup()` defaults to `Closest`. Pass `verbosity=Top` for one best result,
`verbosity=Closest` for every result at the smallest edit distance, or
`verbosity=All` for every result within the requested limit. Suggestions are
ordered by increasing edit distance, decreasing frequency, and finally
lexicographic term order using MoonBit's UTF-16 lexical comparison. Exact score
ties therefore have stable results across targets and dictionary insertion order.

```mbt check
///|
test {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("cat 10\nbat 50\ncut 20")
  assert_eq(dictionary.lookup("hat", verbosity=Top)[0].term, "bat")
  assert_eq(dictionary.lookup("hat", verbosity=Closest).length(), 2)
  assert_eq(dictionary.lookup("cat", verbosity=All).length(), 3)
  assert_eq(dictionary.lookup("hat", max_edit_distance=0), [])
  let fallback = dictionary.lookup("unknown", include_unknown=true)
  assert_eq(fallback[0].term, "unknown")
  assert_eq(fallback[0].count, 0L)
  assert_eq(fallback[0].distance, 3)
}
```

The default maximum edit distance is 2. A lookup limit can be smaller than the
dictionary's configured maximum, but cannot exceed it. The unknown fallback is
returned only when there are no suggestions; its distance is the lookup limit
plus one and its frequency is zero.

## Compound correction

`lookup_compound()` corrects individual words and repairs accidentally missing
or inserted spaces. It splits the input on Unicode whitespace, checks possible
word merges, and uses observed bigram frequencies or a word-frequency estimate
to choose split candidates. It returns an array containing one suggestion.

```mbt check
///|
test {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("where 2\nis 2\nwhereas 2\n")
  let _ = dictionary.load_bigram_dictionary("where is 10")
  let correction = dictionary.lookup_compound("whereiz")[0]
  assert_eq(correction.term, "where is")
  assert_eq(correction.distance, 2)
  assert_eq(correction.count, 10L)
}
```

The edit limit applies to the individual word lookups. The final phrase can have
a larger distance because it can contain multiple corrections and space changes.
Its `distance` is the OSA distance between the original input and final output;
its `count` is an estimated aggregate frequency, which can round down to zero.
An unknown word stays unchanged if no suitable correction is found.

`corpus_size` in `new()` controls probability estimates. Its default is
`1024908267229`, matching upstream SymSpell. Pass a positive corpus total
consistent with your own frequency data when using a custom dictionary. Phrase
frequency estimates saturate at Int64's maximum instead of overflowing.

## Word segmentation

`word_segmentation()` inserts missing word boundaries and optionally corrects
spelling. The result contains the segmented input, the corrected output, an
accumulated edit penalty, and the sum of base-10 word log probabilities.

```mbt check
///|
test {
  let dictionary = @symspell.SymSpell::new()
  let _ = dictionary.load_dictionary("hello 100\nworld 90")
  let joined = dictionary.word_segmentation("helloworld")
  assert_eq(joined.corrected_string, "hello world")
  assert_eq(joined.distance_sum, 1)
  let corrected = dictionary.word_segmentation("helo world")
  assert_eq(corrected.segmented_string, "helo world")
  assert_eq(corrected.corrected_string, "hello world")
  assert_eq(corrected.distance_sum, 1)
}
```

Set `max_edit_distance=0` for segmentation without spelling correction.
`max_segmentation_word_length` limits the number of non-whitespace Unicode
characters in each input candidate. It defaults to the longest indexed term,
or the input length when there are no indexed words. A supplied limit must be
positive. The search uses a bounded circular buffer and linked paths; the
completed strings are materialized once after the best path is selected.

Boundary whitespace is trimmed and whitespace runs become a single space before
the search. Existing word boundaries do not introduce empty words or duplicate
spaces. Unknown candidates receive a length-based penalty and a prior computed
in log space. Empty input has a zero penalty and log probability. A known word
with zero frequency has negative-infinite log probability. `distance_sum` is
the accumulated segmentation penalty after whitespace normalization, including
unknown-word penalties; it is not the final phrase's OSA distance.

## Dictionary loading and updates

`load_dictionary(text)` accepts Unicode whitespace-separated word/frequency
pairs. It supports CRLF and a leading BOM. For another delimiter, pass a single
character such as `separator='$'`; `term_index` and `count_index` select
zero-based columns. Delimited terms can contain spaces. Quoted CSV fields are
not parsed. The library consumes an already-decoded `String`; the caller owns
file reading or fetching, so the same library API works on every target.

Loading merges into the current dictionary. Duplicate terms accumulate counts;
the report distinguishes parsed entries, newly indexed words, and skipped
malformed lines. Blank lines are ignored. Counts in dictionary text must be
nonnegative signed 64-bit integers.

By default, parsing is strict and transactional: an invalid line raises
`InvalidDictionaryLine(line_number, line)` before any counts or index entries
change. `strict=false` skips malformed lines and records their number in the
report. Line numbers are one-based.

For incremental updates, use `create_dictionary_entry(term, count)` and
`delete_dictionary_entry(term)`. Addition returns true when a new word enters
the index; an update to an existing word returns false. Counts saturate at
`9223372036854775807` on addition. Nonpositive additions are ignored unless the
frequency threshold is zero, in which case they register a zero-frequency term.

Set `count_threshold` in `new()` to hold rare words outside the suggestion index
until their accumulated frequency reaches the threshold. `word_count()`,
`pending_word_count()`, `entry_count()`, and `frequency(term)` expose dictionary
statistics without exposing mutable internal collections. Removal also supports
below-threshold terms and cleans all associated deletion buckets.

## Bigram dictionaries

`load_bigram_dictionary(text)` reads `first second count` rows. An explicit
delimiter instead reads a pair in the term column, for example
`first second$42`. The default count column is 2 for whitespace-separated input
and 1 for a custom delimiter. Override `term_index` and `count_index` for other
column layouts. Parsing is strict and transactional by default; `strict=false`
skips malformed rows. A `BigramLoadReport` gives parsed entries, new pairs, and
skipped lines.

Use `set_bigram_count("first second", count)` for an incremental update,
`bigram_frequency(pair)` to read it, and `delete_bigram_entry(pair)` to remove
it. A pair must contain exactly two whitespace-separated terms; its whitespace
is canonicalized but its spelling and case are retained. Bigram counts are
nonnegative. Unlike word-frequency additions, repeated bigram entries replace
their count. Replacement and removal refresh the minimum-frequency cap used
for unobserved pairs. `bigram_count()` returns the number of stored pairs.

## Dictionary persistence

`to_snapshot()` returns a `Bytes` value containing the dictionary settings,
indexed and below-threshold word frequencies, bigram frequencies, and the
precomputed deletion index. `SymSpell::from_snapshot(bytes)` restores a new,
independent mutable dictionary. It loads the saved buckets directly; deletion
strings are not generated again. Word, compound, and segmentation results are
preserved, including frequency thresholds and corpus scoring.

```mbt check
///|
test {
  let dictionary = @symspell.SymSpell::new(count_threshold=3L)
  let _ = dictionary.load_dictionary("hello 100\nworld 90\nrare 2")
  let _ = dictionary.set_bigram_count("hello world", 50L)
  let bytes = dictionary.to_snapshot()
  // Save or transport these bytes using the application's I/O facilities.
  let restored = @symspell.SymSpell::from_snapshot(bytes)
  assert_eq(restored.lookup("helo"), dictionary.lookup("helo"))
  assert_eq(
    restored.word_segmentation("helloworld").corrected_string,
    "hello world",
  )
  assert_eq(restored.bigram_frequency("hello world"), Some(50L))
  assert_true(restored.create_dictionary_entry("rare", 1L))
  assert_eq(restored.frequency("rare"), Some(3L))
  assert_eq(dictionary.frequency("rare"), None)
}
```

The format is deterministic across supported targets and insertion order, uses
UTF-8 strings without character normalization, and stores frequencies exactly
as signed 64-bit integers. The caller owns file access, storage, compression,
or network transport. Both methods work on every library target.

Restoration checks the magic, format version, CRC32, configuration, frequencies,
table ordering, word references, and deletion-index membership and completeness.
Truncated, corrupt, or inconsistent data raises
`InvalidSnapshot(byte_offset, reason)`. An unknown version raises
`UnsupportedSnapshotVersion(version)`. Offsets are zero-based positions in the
snapshot bytes, independent of the Unicode character offsets used for lookup.
CRC32 detects accidental corruption; it is not an authenticity signature.

Binary format version 1 is specified in [docs/snapshot-format.md](docs/snapshot-format.md).
It is independent of the package release version and is not compatible with
upstream Python pickle or C# serialization formats. Restoration allocates a
dictionary and validates the stored index; it is not a zero-copy file mapping.

## Unicode and distance semantics

The index, prefix length, and edit distance operate on MoonBit `Char` values:
Unicode code points, including supplementary characters such as emoji. They
never slice UTF-8 bytes or UTF-16 surrogate pairs. A grapheme containing multiple
code points, such as `👩‍💻`, consequently counts as multiple characters.

Matching is case-sensitive and does not perform character normalization or case
folding implicitly. Phrase APIs normalize only whitespace. Normalize
dictionary terms and queries consistently in the application when canonical
equivalence or case-insensitive lookup is required. For example, `é` and
`e` plus a combining acute accent have distance 2 without normalization.

Distance is restricted Damerau-Levenshtein, also called optimal string alignment
(OSA). Insertions, deletions, replacements, and adjacent transpositions cost one.
This is the default used by `symspellpy`; it differs from unrestricted
Damerau-Levenshtein in cases that edit the same substring more than once.

The default prefix length is 7 and must exceed the configured maximum distance.
Longer prefixes and larger edit limits increase index size. This implementation
is intended for small spelling-error limits, usually 1 or 2. The candidate
verifier uses three reusable rows and a cutoff band; it does not scan the full
dictionary during lookup. Lookup settings affect candidate work, so benchmark
your own dictionary before making performance claims.

## Compatibility and release scope

Version 0.3.0 implements word and bigram dictionary management, single-word
lookup, compound correction, word segmentation, and serialized-index persistence.
Corpus tokenization, regex ignore rules, automatic number/acronym exemptions,
and case transfer are not implemented.

Behavior follows [SymSpell](https://github.com/wolfgarbe/SymSpell) and
[symspellpy 6.10.0](https://github.com/mammothb/symspellpy). Deliberate differences
are deterministic lexical tie-breaking, Unicode whitespace parsing, strict
transactional loading by default, removal of below-threshold terms, and explicit
character normalization/casing. Compound correction uses whitespace tokenization,
corresponding to upstream's `split_by_space=True` on already-normalized text.
Segmentation counts non-whitespace characters in its word window, normalizes
whitespace runs, and avoids empty fragments. This fixes duplicated existing
spaces in sparse dictionaries and defines behavior for empty input/dictionaries.
Each suggested term appears once. The reference sometimes emits duplicate
one-character candidates; fixture generation keeps the best-distance candidate
and checks every result against an independent exhaustive OSA calculation.

## Validation

```sh
moon fmt --check
moon check --deny-warn --target all
moon test --deny-warn --target all
moon build --deny-warn --target all
moon info --target all
```

The checked-in fixtures contain 6,540 query/cutoff cases tested in all three
lookup modes, plus 73,205 distance/cutoff checks over an exhaustive alphabet
containing an emoji. They cover edit limits 0 through 4, short and long prefixes,
two frequency thresholds, repeated characters, empty strings, non-Latin words,
and supplementary Unicode characters. Hand-written tests cover dictionary
mutation, saturated counts, parsing errors, and Unicode normalization policy.
The phrase fixtures add 4,728 compound and 3,504 segmentation cases, covering
two synthetic dictionaries, two corpus totals, edit limits 0 through 2, and
optional bigram scoring. Upstream single-word ties are canonicalized to the
port's lexical policy. Segmentation reference cases have no whitespace, casing,
or NFKC changes; separate regressions verify the intentional whitespace fixes
and normalization policy. Log probabilities are checked within `1e-9`.
Persistence has 25 independent byte fixtures encoded using Python's
`struct`, `itertools`, and `zlib`, plus round-trip, post-restore mutation,
Unicode, truncation, corruption, and checksum-valid mutation tests. The same
expected bytes are tested on every target. Index completeness counts are
checked against exhaustive deletion sets with repeated and supplementary
Unicode characters.
Normal test runs need neither Python nor network access.

To regenerate fixtures:

```sh
python -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/generate_fixtures.py
.venv/bin/python scripts/generate_phrase_fixtures.py
.venv/bin/python scripts/generate_snapshot_fixtures.py
moon fmt
```

The snapshot fixture generator uses only Python's standard library and can also
be run directly with `python scripts/generate_snapshot_fixtures.py`.

## License

MIT. Upstream notices are preserved in [LICENSE](LICENSE) and [NOTICE](NOTICE).
No upstream frequency dictionaries are bundled; supply a dictionary suited to
your application and follow its license terms.
