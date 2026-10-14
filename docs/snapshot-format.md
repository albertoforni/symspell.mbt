# SymSpell snapshot format, version 1

`SymSpell::to_snapshot()` encodes the following sequence. There is no padding,
compression, BOM, or target-specific representation. All integers are
little-endian. A reader must reject trailing bytes.

| Field | Encoding | Constraint |
| --- | --- | --- |
| Magic | 8 bytes: `4d 42 53 53 49 44 58 00` (`MBSSIDX` followed by NUL) | Must match exactly |
| Format version | `u32` | `1` |
| Maximum dictionary edit distance | `u32` | `0` through `2147483647` |
| Prefix length | `u32` | Greater than edit distance; at most `2147483647` |
| Count threshold | `i64` | Nonnegative |
| Corpus size | `i64` | Positive |
| Indexed words | Frequency table | Counts at least the threshold |
| Pending words | Frequency table | Counts positive and less than the threshold |
| Bigrams | Frequency table | Nonnegative counts; canonical two-word terms |
| Deletion index | Bucket table | Valid, unique, complete memberships |
| Checksum | `u32` | CRC32 of every preceding byte |

The smallest snapshot contains four empty tables and is 56 bytes long.
The format version describes the byte representation and semantic invariants,
independently of the library's semantic version. A future incompatible change
must use a new format version.

## Strings and frequencies

A string is a `u32` byte length followed by exactly that many UTF-8 bytes. The
length must fit a nonnegative MoonBit `Int` (`0` through `2147483647`). UTF-8
must be well-formed; decoding preserves a leading U+FEFF. Empty strings, NUL,
newlines, combining marks, and supplementary characters are allowed in words.
No normalization, whitespace trimming, or case conversion is performed.

A frequency table is a `u32` entry count followed by that many entries. Each
entry consists of a string and an `i64` frequency. Entries must be strictly
ordered by UTF-16 code units, using `String::lexical_compare`; this matches
lookup's documented tie order. Duplicate terms are invalid. Counts use the
full nonnegative signed 64-bit range, including `9223372036854775807`.

Indexed words define zero-based word IDs by their position in their table.
Pending terms must not also occur in the indexed-word table. Bigrams must
consist of exactly two nonempty words, joined by one ASCII space, with no
other Unicode whitespace. Their words retain exact spelling and casing;
they do not need entries in the indexed-word table.

## Deletion buckets

The bucket table begins with a `u32` bucket count. Each bucket contains:

1. A deletion key encoded as a string.
2. A positive `u32` membership count.
3. That many `u32` word IDs in strictly increasing order.

Bucket keys must be strictly ordered by UTF-16 code units. Every word ID must
refer to the indexed-word table; duplicate references and empty buckets are
invalid. All table and membership counts must fit a nonnegative MoonBit `Int`.

For a word with Unicode-character array `chars`, let `prefix` be its first
`min(chars.length(), prefix_length)` characters. A valid deletion key is a
subsequence of that prefix, with at most `max_dictionary_edit_distance`
characters removed. The unchanged prefix is included. Every distinct valid
key must contain the word exactly once. Repeated characters can produce the
same key through multiple deletion paths; they still require only one membership.

The loader checks each saved membership using Unicode `Char` values. It then
counts the expected number of distinct subsequences for each word without
generating their strings. Because all keys and references are unique and valid,
equality between expected and observed counts establishes completeness. This
rejects a missing bucket even when the checksum has been recomputed.

Restored buckets share each word's mutable frequency object with the word
table. Updating a word therefore affects both exact and approximate lookups.
The maximum word length and minimum bigram frequency are derived from the
tables rather than stored redundantly.

## Checksum and errors

The checksum is CRC-32/ISO-HDLC: polynomial `0x04C11DB7` (reflected form
`0xEDB88320`), reflected input/output, initial value `0xFFFFFFFF`, and final
XOR `0xFFFFFFFF`. The check value for ASCII `123456789` is `0xCBF43926`.
Python's `zlib.crc32(payload)` computes the same unsigned checksum.

The loader checks magic and version before verifying the checksum. An unknown
version raises `UnsupportedSnapshotVersion(version)`. Other malformed data
raises `InvalidSnapshot(offset, reason)`; offsets are zero-based byte positions
in the snapshot, not character positions. Invalid snapshots never change an
existing dictionary. CRC32 detects accidental corruption, not authenticity.

The reader bounds lengths and entry counts against the remaining input before
allocating or iterating. Restoring a valid snapshot still requires memory for
the dictionary and work proportional to its stored index. It does not regenerate
deletion strings and is not a zero-copy mapping of the input bytes.

`scripts/generate_snapshot_fixtures.py` is an independent reference encoder
using Python's standard library. Its checked-in fixtures pin the byte format
across native, JavaScript, Wasm, and Wasm GC builds. The format does not read
Python pickle or C# serialized objects.
