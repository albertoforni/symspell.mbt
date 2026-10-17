# Changelog

## Unreleased

- Add plain-text corpus building with occurrence and newly indexed word reports.
- Preserve explicit casing and normalization while using symspellpy-style tokens.
- Pin Unicode letter/number token boundaries to a generated Unicode 16.0.0 table.
- Reuse frequency saturation, threshold promotion, and dictionary persistence.
- Add 416 incremental corpus builds against offline upstream tokenization fixtures.
- Verify Unicode classification totals over every scalar and corpus/phrase integration.

## 0.3.0 — 2026-10-14

- Add deterministic binary dictionary snapshots and independent restoration.
- Preserve settings, exact Int64 counts, pending words, bigrams, and deletion buckets.
- Restore the complete index without regenerating deletion strings.
- Validate format versions, CRC32, table ordering, frequencies, and index completeness.
- Define a portable format with UTF-8 terms and little-endian integers.
- Add 25 independent Python byte fixtures, round trips, and malformed-input regressions.

## 0.2.0 — 2026-10-14

- Add compound correction with word splitting, merging, and bigram scoring.
- Add transactional bigram loading, frequency replacement, and removal.
- Add word segmentation with optional spelling correction and log probabilities.
- Keep casing and Unicode normalization explicit; normalize phrase whitespace.
- Preserve existing segmentation boundaries for sparse dictionaries.
- Add configurable corpus size and safe probability-to-frequency conversion.
- Bound segmentation windows and avoid copying accumulated text during search.
- Add 4,728 compound and 3,504 segmentation reference cases plus edge regressions.

## 0.1.0 — 2026-10-14

- Add a pure MoonBit SymSpell dictionary and Unicode deletion index.
- Support Top, Closest, and All lookup with frequency ranking and stable ties.
- Verify candidates with cutoff-aware optimal string alignment distance.
- Add text dictionary loading, strict transactional parsing, and load reports.
- Support incremental frequency updates, thresholds, saturation, and removal.
- Add offline symspellpy conformance fixtures, Unicode regressions, and a demo.
- Preserve upstream MIT licensing and document the single-word release scope.
