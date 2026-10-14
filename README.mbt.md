# SymSpell for MoonBit

A pure MoonBit implementation of SymSpell's single-word spelling correction.
It uses a precomputed deletion index to find candidates, then verifies them
with cutoff-aware optimal string alignment distance and ranks them by frequency.

The library depends only on `moonbitlang/core` and runs on native, JavaScript,
WebAssembly, and WebAssembly GC. There are no C bindings or runtime dictionary
downloads. The module name is `albertoforni/symspell`; version 0.1.0 is currently
a local project and has not been published to Mooncakes.

## Run the example

From this directory:

```sh
moon run cmd/main --target native
```

The example corrects `memebers` to `members`, `cafe` to `café`, `東亰` to `東京`,
and `😃` to `😀` using a small, embedded dictionary. It also runs with
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

## Unicode and distance semantics

The index, prefix length, and edit distance operate on MoonBit `Char` values:
Unicode code points, including supplementary characters such as emoji. They
never slice UTF-8 bytes or UTF-16 surrogate pairs. A grapheme containing multiple
code points, such as `👩‍💻`, consequently counts as multiple characters.

Matching is case-sensitive and does not normalize text implicitly. Normalize
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

Version 0.1.0 implements dictionary management and single-word lookup. Compound
correction, bigram dictionaries, word segmentation, corpus tokenization, regex
ignore rules, case transfer, and serialized-index persistence are not implemented.

Behavior follows [SymSpell](https://github.com/wolfgarbe/SymSpell) and
[symspellpy 6.10.0](https://github.com/mammothb/symspellpy). Deliberate differences
are deterministic lexical tie-breaking, Unicode whitespace parsing, strict
transactional loading by default, and removal of below-threshold terms.
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
Normal test runs need neither Python nor network access.

To regenerate fixtures:

```sh
python -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/generate_fixtures.py
moon fmt
```

## License

MIT. Upstream notices are preserved in [LICENSE](LICENSE) and [NOTICE](NOTICE).
No upstream frequency dictionaries are bundled; supply a dictionary suited to
your application and follow its license terms.
