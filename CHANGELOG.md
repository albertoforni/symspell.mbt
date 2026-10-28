# Changelog

## 0.4.2 — 2026-10-28

- Outperform `node-symspell@0.1.0` on all nine shared benchmark operations at both recorded dictionary sizes: 1.05–3.88× on JavaScript and 1.43–7.63× on native. See the [benchmark methodology and results](benchmarks/README.md).
- Probe one- and two-edit deletion hashes without allocating query deletion strings.
- Replace candidate hash sets with dictionary epochs and specialize two-edit OSA scoring.
- Use compact native/Wasm slot tables and JavaScript's built-in Map for index slots.
- Reuse immutable exact suggestions while keeping returned arrays independent.
- Recycle uniquely owned single-result buffers on ARC targets; preserve escaped arrays, views, and iterators.
- Slice corpus and dictionary tokens, parse common decimal counts without per-digit BigInt work, and extend segmentation spans incrementally.
- Preserve Unicode distances, full Int64 frequencies, public signatures, and snapshot bytes; add collision, epoch, aliasing, numeric-boundary, and exhaustive OSA lookup regressions.

## 0.4.1 — 2026-10-27

- Build without warnings on MoonBit 0.10.17 (moon 0.1.20261023).
- Keep `equal` as a method; deprecate the `not_equal` and `to_repr` methods.
- Replace deprecated `StringBuilder::new()` and `hash_combine` calls.
- Apply the current formatter; the interface now spells `Int` as `Int32`.
- Point the installation docs at the published Mooncakes package.

## 0.4.0 — 2026-10-26

- Add reproducible release-mode benchmarks against a locked JavaScript SymSpell port.
- Measure build, corpus ingestion, lookup modes, phrase APIs, snapshots, and peak RSS.
- Generate query deletion layers lazily as the best edit-distance cutoff tightens.
- Trim common distance affixes, reuse candidate buffers, and handle one-edit matches directly.
- Cache immutable word hashes and keep only the best candidate in Top lookup mode.
- Screen incompatible word character sets before distance scoring on native and Wasm.
- Preserve the public API and snapshot format, with independent distance regressions.
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
