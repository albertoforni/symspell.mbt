# Performance benchmarks

Run from the module root with MoonBit, Node.js, npm, and Python 3 installed:

```sh
python scripts/benchmark.py --words 10000 --output benchmarks/.cache/10000.json
python scripts/benchmark.py --words 0 --output benchmarks/.cache/full.json
```

The script downloads a pinned upstream dictionary and checks its SHA-256 before
using it, installs the locked npm comparison dependencies with lifecycle scripts
disabled, generates the same workload for all engines, and builds MoonBit in
release mode. Subsequent runs reuse the verified dictionary and dependencies.
Normal library use and tests require none of these benchmark dependencies.
Generated MoonBit drivers, downloaded data, dependencies, and intermediate
measurements are ignored by Git. The original dictionary is not redistributed.
Successful runs remove the generated driver package.

For a short harness check:

```sh
python scripts/benchmark.py --words 1000 --queries 16 --samples 1 --warmup-ms 10 --sample-ms 20
```

`--cpu N` pins the benchmark and its children to a CPU on Linux. Choose a CPU
available on your machine. `--samples`, `--warmup-ms`, and `--sample-ms` control
independent process trials and the minimum duration of each timing window.
Avoid running other CPU-intensive work during a measurement.

## What is compared

The baseline is the unmodified npm package
[`node-symspell@0.1.0`](https://www.npmjs.com/package/node-symspell/v/0.1.0),
installed with the checked-in `package-lock.json`. Its
[upstream documentation](https://github.com/MathieuLoutre/node-symspell)
describes it as a SymSpell 6.6 port without a focus on speed optimization.
Results apply to this implementation, workload, runtime, and machine; other
JavaScript implementations can perform differently.

Both use maximum edit distance 2, prefix length 7, and count threshold 1.
The comparison uses lowercase ASCII terms from the frequency-ranked upstream
English dictionary. This gives both implementations the same character and
frequency semantics: the JavaScript port uses UTF-16 indices and `Number`
counts; this MoonBit port supports Unicode code points and full signed 64-bit
counts. Unicode correctness remains covered by the library's separate fixtures.

The dataset source is
[SymSpell at commit c239062](https://github.com/wolfgarbe/SymSpell/blob/c239062ae02961df18ab7da1671d01b4388204e0/SymSpell/frequency_dictionary_en_82_765.txt).
Its SHA-256 is
`c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b`.
[Upstream documents its Google Books Ngram and SCOWL sources and licenses](https://github.com/wolfgarbe/SymSpell/blob/c239062ae02961df18ab7da1671d01b4388204e0/README.md#frequency-dictionary).

## Workloads and validation

- **Build:** parse valid frequency text and construct a new deletion index.
- **Corpus:** tokenize 16,384 deterministic synthetic tokens sampled from common
  dictionary words, count them, and construct a new dictionary.
- **Exact Top:** query dictionary words in `Top` mode.
- **Typo Top / Closest / All:** uniformly sample dictionary words of at least four
  characters and apply deletions, insertions, replacements, and adjacent swaps
  in equal proportions. Some edits produce another existing dictionary word.
- **Miss Top:** query random `j/q/x/z` strings with lengths 5 through 12, keeping
  them within the dictionary's normal length range.
- **Compound / segmentation:** correct 32 synthetic phrases and segment 32
  concatenations of common dictionary words; no bigram dictionary is loaded.
- **Snapshot save / restore:** measure MoonBit's deterministic, validated binary
  format separately. The JavaScript baseline has no equivalent persistence API.

Before timing, the harness checks every query's results on both MoonBit targets
and against the JavaScript baseline. `Closest` and `All` compare complete result
sets including terms, edit distances, and frequencies. The harness canonicalizes
result order outside timing; the libraries' own sorting remains part of each
measured API call. `Top` permits different lexical choices only when both distance
and frequency tie. Corpus token/word totals must agree, and restored snapshots
must reproduce the original dictionary's suggestions.

Word mismatches stop the run. Phrase differences are recorded with examples,
and speedups for the affected operation are withheld. This accommodates the
port's documented phrase behavior while preventing different outputs from
being presented as a speed win.

For one- and two-edit lookups, the optimized implementation enumerates deleted
prefix positions and probes their rolling hashes without creating deletion
strings or a query-side deduplication table. Hash collisions add candidates;
full Unicode OSA verification still decides every match. Dictionary epochs
prevent repeated candidate scoring. Native and Wasm use open-addressed slots,
with words stored directly in exact-match slots; JavaScript uses the runtime's
built-in `Map`. All targets trim common affixes, screen character-signature
lower bounds, and use a specialized two-edit OSA kernel. Larger cutoffs retain
the general deletion and banded-distance paths. Exact lookups reuse immutable
suggestion records while returning independent mutable arrays. Native and linear-memory
Wasm recycle the most recent single-result backing buffer through the core
ownership-aware view conversion. Surviving arrays, views, or iterators force a
copy, and mutated result lengths use a fresh single-result array.

An independent full-matrix OSA oracle checks the optimized and general paths,
alongside the existing cross-target fixtures. Additional regressions exercise
hash collisions, cluster removal, Unicode deletion hashes, epoch wraparound,
returned-array independence, and exact frequency parsing at numeric boundaries.

## Measurement method

Each engine runs in a fresh process for each trial. The order rotates between
engines across trials. Each case warms up for at least 250 ms and runs repeated
batches for at least 500 ms by default. Longer single operations are allowed to
finish. Both JavaScript engines receive `--expose-gc` and collect garbage after
warmup, outside the timing window. Collections caused by measured work remain
part of its cost. Native code uses its normal reference counting.

Timers are monotonic. Every result contributes to a printed checksum.
Both drivers accumulate result counts, term lengths, and edit distances directly
inside their batch loops. Earlier reports called a separate checksum helper:
the JavaScript JIT inlined it, while native retained a measurable helper call
(about 6 ns per exact lookup in profiling). Reports from 28 October onward use
the same inline checksum work on both sides; their driver hashes differ from
the older reports. Keep this harness change in mind when comparing exact-match
times across dates. The report contains every sample's mean time per operation, then the median and
range across process trials. These are batch throughput measurements, rather
than individual-query tail latencies.

Compilation, process startup, file reading, query-dictionary setup, validation,
and output printing are outside measured operations. Loading and corpus
benchmarks include parsing and index construction from an already-decoded
string. The JavaScript adapters replace the package's asynchronous file I/O
with its own unmodified insertion and tokenization methods on the same string.
MoonBit's strict loader additionally stages rows before committing changes.

On Linux, kernel child-process accounting records actual process peak RSS.
On other platforms the script tries GNU `/usr/bin/time`, or records `null` when
memory measurement is unavailable. The dictionary-only process
exits after setup; the full-suite process also allocates temporary dictionaries
and snapshots. RSS includes the runtime, input, and index, and cannot be read as
the dictionary's isolated retained size. The report also records snapshot byte
size, compiler/runtime versions, CPU affinity, source hashes, workload hash,
Git state, and the npm lockfile hash.

## Recorded results

Raw reports in [`results/`](results/) preserve the machine and workload details.
Speedup is JavaScript baseline time divided by MoonBit time: values above 1
favor MoonBit. Use measurements for your own dictionary and query distribution
when making a deployment decision.

Exact reproduction of the recorded workload and timing windows:

```sh
python scripts/benchmark.py --words 10000 --queries 512 --samples 5 --cpu 0 --output benchmarks/.cache/10000.json
python scripts/benchmark.py --words 0 --queries 512 --samples 5 --cpu 0 --output benchmarks/.cache/full.json
```

### 28 October 2026 — result buffer reuse

Measured on optimization commit `c807b78`, following the initial results below.
The benchmark drivers, workload hashes, dictionary, npm lockfile, configuration,
and snapshot byte sizes match the initial optimization run. Each engine ran in
five fresh processes per dictionary size, pinned to CPU 0, with a 250 ms minimum
warmup and 500 ms minimum timing window. The toolchain remains MoonBit 0.10.17
(moon 0.1.20261023), Node.js v26.10.0, and the same Intel Core i9-12900H on Linux.
All tested word and phrase outputs agree across engines.

Both targets are faster in all nine shared operations at both dictionary sizes.
Every MoonBit process sample is faster than every baseline process sample for
the corresponding operation: all 36 observed ranges are separate. Median
speedups span 1.05–3.88× for JavaScript and 1.43–7.63× for native. Native exact
lookup now leads by 1.65× at 10,000 words and 1.43× at 82,769 words, closing the
practical tie in the initial run.

The added optimization reuses the most recent single-result backing buffer on
ARC targets through the core ownership-aware view conversion. Arrays, escaped
views, and lazy iterators retained by callers force independent storage;
mutated lengths fall back to a new single-result array. All 159 tests pass on
native, JavaScript, Wasm, and Wasm GC, including these aliasing regressions.
Public signatures and snapshot compatibility are preserved. An independent
integrity audit also verified all 3,058 installed files from the 14 locked npm
packages against their integrity-checked registry tarballs.

These results describe the tested workloads, runtime, and machine. The raw
reports retain every process sample and range; they are batch-throughput
measurements, not individual-query tail latencies.

#### 10,000 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 72.35 ms | 68.80 ms (1.05×) | 35.74 ms (2.02×) |
| Build from corpus | 26.71 ms | 24.39 ms (1.10×) | 13.49 ms (1.98×) |
| Exact Top | 26.95 ns | 13.38 ns (2.01×) | 16.36 ns (1.65×) |
| Typo Top | 3.301 µs | 1.100 µs (3.00×) | 756.23 ns (4.36×) |
| Typo Closest | 3.338 µs | 1.141 µs (2.93×) | 785.53 ns (4.25×) |
| Typo All | 15.376 µs | 6.988 µs (2.20×) | 4.824 µs (3.19×) |
| Miss Top | 4.106 µs | 1.057 µs (3.88×) | 557.94 ns (7.36×) |
| Compound correction | 63.526 µs | 30.215 µs (2.10×) | 18.777 µs (3.38×) |
| Segmentation | 664.706 µs | 288.140 µs (2.31×) | 172.526 µs (3.85×) |
| Save snapshot | — | 168.12 ms | 58.12 ms |
| Restore snapshot | — | 105.29 ms | 39.28 ms |

Ratios above 1× favor MoonBit. Snapshots have no baseline comparator.

#### 82,769 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 931.97 ms | 771.43 ms (1.21×) | 544.00 ms (1.71×) |
| Build from corpus | 28.74 ms | 24.85 ms (1.16×) | 14.96 ms (1.92×) |
| Exact Top | 29.02 ns | 18.01 ns (1.61×) | 20.24 ns (1.43×) |
| Typo Top | 4.568 µs | 2.192 µs (2.08×) | 1.251 µs (3.65×) |
| Typo Closest | 4.698 µs | 2.288 µs (2.05×) | 1.298 µs (3.62×) |
| Typo All | 33.911 µs | 29.250 µs (1.16×) | 13.886 µs (2.44×) |
| Miss Top | 4.012 µs | 1.142 µs (3.51×) | 526.10 ns (7.63×) |
| Compound correction | 102.981 µs | 75.742 µs (1.36×) | 38.720 µs (2.66×) |
| Segmentation | 1.24 ms | 925.223 µs (1.34×) | 437.864 µs (2.83×) |
| Save snapshot | — | 1.518 s | 674.89 ms |
| Restore snapshot | — | 792.17 ms | 417.07 ms |

Ratios above 1× favor MoonBit. Snapshots have no baseline comparator.

#### Peak process RSS

| Dictionary | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| 10,000 words | 128.8 MiB | 131.3 MiB | 44.6 MiB |
| 82,769 words | 359.5 MiB | 400.2 MiB | 163.4 MiB |

RSS includes input and runtime. Snapshot sizes remain 2.44 MiB and 17.89 MiB.

[10,000-word data](results/2026-10-28-owned-results-10000.json) · [Full-dictionary data](results/2026-10-28-owned-results-full.json) · [Interactive comparison](results/2026-10-28-owned-results-comparison.html)

### 28 October 2026 — initial optimization

Measured on unreleased optimization commit `0e439b6`, with MoonBit 0.10.17
(moon 0.1.20261023), Node.js v26.10.0, and the same Intel Core i9-12900H on
Linux. Both sizes use five independent processes per engine, a 250 ms minimum
warmup, a 500 ms minimum sample, and CPU affinity 0. Workload hashes, dictionary,
npm lockfile, and snapshot bytes match 27 October. All tested word and phrase
outputs agree across engines, allowing the documented lexical ties.

Both MoonBit targets have lower median times for all nine shared operations at
both sizes. Native Exact Top at 10,000 words is only 1.01× with overlapping
sample ranges, so treat it as a tie. Across the measured cases, JavaScript
speedups range from 1.06× to 3.89× and native from 1.01× to 7.42×. These are
synthetic-workload medians on this machine, not guarantees for every dictionary,
query distribution, runtime, or processor.

The index, distance, ingestion, and phrase implementations changed. The checksum
work was also inlined in both benchmark drivers, as explained under
[Measurement method](#measurement-method); driver hashes differ from older
reports, especially affecting comparisons of nanosecond-scale exact lookups.

#### 10,000 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 72.41 ms | 68.40 ms (1.06×) | 36.04 ms (2.01×) |
| Build from corpus | 26.74 ms | 24.67 ms (1.08×) | 13.50 ms (1.98×) |
| Exact Top | 27.46 ns | 13.48 ns (2.04×) | 27.26 ns (1.01×) |
| Typo Top | 3.397 µs | 1.090 µs (3.12×) | 767.18 ns (4.43×) |
| Typo Closest | 3.351 µs | 1.142 µs (2.93×) | 795.05 ns (4.21×) |
| Typo All | 15.234 µs | 6.996 µs (2.18×) | 4.813 µs (3.17×) |
| Miss Top | 4.079 µs | 1.047 µs (3.89×) | 565.38 ns (7.21×) |
| Compound correction | 62.324 µs | 30.392 µs (2.05×) | 18.831 µs (3.31×) |
| Segmentation | 694.318 µs | 291.921 µs (2.38×) | 175.930 µs (3.95×) |
| Save snapshot | — | 170.45 ms | 59.29 ms |
| Restore snapshot | — | 104.68 ms | 38.84 ms |

Ratios above 1× favor MoonBit. Snapshot times have no JavaScript comparator.

#### 82,769 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 909.24 ms | 769.57 ms (1.18×) | 550.09 ms (1.65×) |
| Build from corpus | 28.76 ms | 24.44 ms (1.18×) | 15.00 ms (1.92×) |
| Exact Top | 27.16 ns | 17.80 ns (1.53×) | 22.24 ns (1.22×) |
| Typo Top | 4.604 µs | 2.227 µs (2.07×) | 1.253 µs (3.67×) |
| Typo Closest | 4.598 µs | 2.291 µs (2.01×) | 1.313 µs (3.50×) |
| Typo All | 34.066 µs | 29.065 µs (1.17×) | 13.782 µs (2.47×) |
| Miss Top | 3.920 µs | 1.142 µs (3.43×) | 528.02 ns (7.42×) |
| Compound correction | 101.693 µs | 74.127 µs (1.37×) | 38.702 µs (2.63×) |
| Segmentation | 1.25 ms | 916.050 µs (1.36×) | 433.264 µs (2.88×) |
| Save snapshot | — | 1.542 s | 674.74 ms |
| Restore snapshot | — | 796.67 ms | 400.63 ms |

Ratios above 1× favor MoonBit. Snapshot times have no JavaScript comparator.

#### Peak process RSS

| Dictionary | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| 10,000 words | 129.0 MiB | 131.0 MiB | 44.6 MiB |
| 82,769 words | 360.1 MiB | 402.2 MiB | 163.2 MiB |

These are fresh dictionary-process high-water marks, including input and runtime.
Snapshot sizes remain 2.44 MiB and 17.89 MiB. Reports preserve every process
sample and its range, the source and driver hashes, and the environment.

[10,000-word data](results/2026-10-28-optimized-10000.json) · [Full-dictionary data](results/2026-10-28-optimized-full.json) · [Interactive comparison](results/2026-10-28-optimized-comparison.html)

### 27 October 2026

Measured with SymSpell 0.4.1 (commit `2656c2b`) and MoonBit 0.10.17 (moon 0.1.20261023) on the same Intel Core i9-12900H, Linux, and Node.js v26.10.0. Both sizes use five independent processes per engine, a 250 ms minimum warmup, a 500 ms minimum sample, and CPU affinity 0. All tested word and phrase outputs agree across engines, allowing the documented lexical ties.

Native wins dictionary loading, corpus ingestion, and all three typo modes at both sizes, and Miss Top at 10,000 words; it ties Miss Top on the full dictionary. MoonBit JS wins Top, Closest, and Miss lookups at 10,000 words only. The JavaScript baseline still leads exact matches and the phrase APIs on both MoonBit targets. These are measured medians for the specified synthetic workload.

The workload, drivers, and lookup code match 17 October; 0.4.1 only addressed toolchain deprecations, and the main change is the compiler (moonc v0.10.4 to v0.10.17). Comparing each run's fastest process sample, which background load affects least, native operations took 16–20% less time on geometric average per dictionary size and MoonBit JS operations 7–10% less, while the unchanged node-symspell baseline took 3–7% less. Snapshot save and restore took 13–29% less time natively and 14–44% less on MoonBit JS. The 17 October full-dictionary run had unusually wide sample ranges, with the slowest baseline sample up to 3.3× the fastest for the same operation, which inflated several of its medians; keep that in mind when comparing full-dictionary ratios across dates.

#### 10,000 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 74.06 ms | 145.52 ms (0.51×) | 71.00 ms (1.04×) |
| Build from corpus | 27.50 ms | 51.44 ms (0.53×) | 25.82 ms (1.07×) |
| Exact Top | 0.027 µs | 0.042 µs (0.65×) | 0.060 µs (0.45×) |
| Typo Top | 3.410 µs | 2.799 µs (1.22×) | 2.157 µs (1.58×) |
| Typo Closest | 3.547 µs | 3.084 µs (1.15×) | 2.146 µs (1.65×) |
| Typo All | 16.944 µs | 20.409 µs (0.83×) | 13.543 µs (1.25×) |
| Miss Top | 4.188 µs | 3.581 µs (1.17×) | 3.715 µs (1.13×) |
| Compound correction | 66.696 µs | 102.505 µs (0.65×) | 79.226 µs (0.84×) |
| Segmentation | 687.641 µs | 1.01 ms (0.68×) | 790.139 µs (0.87×) |
| Save snapshot | — | 193.00 ms | 61.00 ms |
| Restore snapshot | — | 128.02 ms | 41.01 ms |

Parentheses give speed relative to node-symspell; above 1× favors MoonBit. Snapshot times have no JavaScript comparator. The raw report includes all process samples and their ranges.

#### 82,769 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 967.83 ms | 1.294 s (0.75×) | 810.06 ms (1.19×) |
| Build from corpus | 30.02 ms | 44.09 ms (0.68×) | 26.57 ms (1.13×) |
| Exact Top | 0.029 µs | 0.059 µs (0.48×) | 0.065 µs (0.44×) |
| Typo Top | 4.958 µs | 5.571 µs (0.89×) | 3.334 µs (1.49×) |
| Typo Closest | 4.968 µs | 5.697 µs (0.87×) | 3.347 µs (1.48×) |
| Typo All | 37.845 µs | 66.738 µs (0.57×) | 33.429 µs (1.13×) |
| Miss Top | 4.095 µs | 4.643 µs (0.88×) | 4.118 µs (0.99×) |
| Compound correction | 105.608 µs | 245.121 µs (0.43×) | 141.508 µs (0.75×) |
| Segmentation | 1.38 ms | 2.79 ms (0.49×) | 1.59 ms (0.86×) |
| Save snapshot | — | 1.806 s | 659.66 ms |
| Restore snapshot | — | 927.55 ms | 336.96 ms |

Parentheses give speed relative to node-symspell; above 1× favors MoonBit. Snapshot times have no JavaScript comparator. The raw report includes all process samples and their ranges.

#### Peak process RSS

| Dictionary | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| 10,000 words | 130.2 MiB | 163.6 MiB | 44.6 MiB |
| 82,769 words | 360.1 MiB | 372.3 MiB | 166.9 MiB |

These are fresh dictionary-process high-water marks, including the runtime and workload input. The 10,000-word snapshot is 2.44 MiB; the full snapshot is 17.89 MiB.

[10,000-word data](results/2026-10-27-10000.json) · [Full-dictionary data](results/2026-10-27-full.json) · [Interactive comparison](results/2026-10-27-comparison.html)

### 17 October 2026

Measured on an Intel Core i9-12900H, Linux, Node.js v26.10.0, and the MoonBit toolchain recorded in the JSON reports. Both sizes use five independent processes per engine, a 250 ms minimum warmup, a 500 ms minimum sample, and CPU affinity 0. All tested word and phrase outputs agree across engines, allowing the documented lexical ties.

The JavaScript output wins Top and Closest typo lookup at 10,000 words. Native wins those modes at both sizes. The JavaScript baseline still leads exact matches, corpus ingestion, and phrase APIs. Full-dictionary loading also favors native in this run; smaller-dictionary loading favors the baseline. These are measured medians for the specified synthetic workload.

#### 10,000 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 78.80 ms | 143.10 ms (0.55×) | 86.88 ms (0.91×) |
| Build from corpus | 28.46 ms | 47.75 ms (0.60×) | 31.14 ms (0.91×) |
| Exact Top | 0.028 µs | 0.046 µs (0.60×) | 0.075 µs (0.37×) |
| Typo Top | 3.703 µs | 3.238 µs (1.14×) | 2.655 µs (1.39×) |
| Typo Closest | 3.736 µs | 3.248 µs (1.15×) | 2.699 µs (1.38×) |
| Typo All | 17.180 µs | 21.066 µs (0.82×) | 15.900 µs (1.08×) |
| Miss Top | 4.417 µs | 4.001 µs (1.10×) | 4.574 µs (0.97×) |
| Compound correction | 72.261 µs | 112.667 µs (0.64×) | 95.530 µs (0.76×) |
| Segmentation | 737.921 µs | 1.08 ms (0.68×) | 954.383 µs (0.77×) |
| Save snapshot | — | 334.63 ms | 74.05 ms |
| Restore snapshot | — | 184.92 ms | 56.58 ms |

Parentheses give speed relative to node-symspell; above 1× favors MoonBit. Snapshot times have no JavaScript comparator. The raw report includes all process samples and their ranges.

#### 82,769 words

| Operation | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| Build dictionary | 1.031 s | 1.709 s (0.60×) | 942.38 ms (1.09×) |
| Build from corpus | 30.93 ms | 46.79 ms (0.66×) | 37.38 ms (0.83×) |
| Exact Top | 0.030 µs | 0.071 µs (0.42×) | 0.081 µs (0.37×) |
| Typo Top | 6.108 µs | 9.880 µs (0.62×) | 4.494 µs (1.36×) |
| Typo Closest | 8.167 µs | 8.661 µs (0.94×) | 5.229 µs (1.56×) |
| Typo All | 55.346 µs | 100.306 µs (0.55×) | 49.623 µs (1.12×) |
| Miss Top | 5.428 µs | 6.362 µs (0.85×) | 5.544 µs (0.98×) |
| Compound correction | 156.585 µs | 406.134 µs (0.39×) | 212.481 µs (0.74×) |
| Segmentation | 1.71 ms | 4.02 ms (0.42×) | 2.06 ms (0.83×) |
| Save snapshot | — | 2.864 s | 939.26 ms |
| Restore snapshot | — | 1.151 s | 452.30 ms |

Parentheses give speed relative to node-symspell; above 1× favors MoonBit. Snapshot times have no JavaScript comparator. The raw report includes all process samples and their ranges.

#### Peak process RSS

| Dictionary | node-symspell | MoonBit JS | MoonBit native |
| --- | ---: | ---: | ---: |
| 10,000 words | 129.4 MiB | 163.4 MiB | 44.9 MiB |
| 82,769 words | 358.4 MiB | 367.0 MiB | 167.7 MiB |

These are fresh dictionary-process high-water marks, including the runtime and workload input. The 10,000-word snapshot is 2.44 MiB; the full snapshot is 17.89 MiB.

#### Before lookup tuning

The [original 10,000-word report](results/2026-10-17-before-10000.json) uses the same workload hash and corpus-builder commit `fd9367c`. Top lookup originally ran at 0.24× the JavaScript baseline on MoonBit JS and 0.24× natively. The optimized ratios are 1.14× and 1.39×. The reports preserve each run’s comparator and source hashes; the original run did not record RSS.

[Optimized 10,000-word data](results/2026-10-17-after-10000.json) · [Full-dictionary data](results/2026-10-17-after-full.json) · [Interactive comparison](results/2026-10-17-comparison.html)
