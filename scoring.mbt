///|
/// Guard floating-to-integer conversions against overflow on every target.
fn probability_count(value : Double) -> Int64 {
  if !(value > 0.0) {
    0L
  } else if value >= max_frequency.to_double() {
    max_frequency
  } else {
    value.to_int64()
  }
}

///|
/// Upstream's unknown-word prior, 10 / 10^length, rounded down to a frequency.
fn unknown_frequency(length : Int) -> Int64 {
  if length == 0 {
    10L
  } else if length == 1 {
    1L
  } else {
    0L
  }
}

///|
fn SymSpell::estimated_bigram_count(
  self : SymSpell,
  left : Int64,
  right : Int64,
) -> Int64 {
  Int64::min(
    self.bigram_count_min,
    probability_count(
      left.to_double() / self.corpus_size.to_double() * right.to_double(),
    ),
  )
}

///|
fn SymSpell::word_log_probability(self : SymSpell, count : Int64) -> Double {
  @math.log10(count.to_double() / self.corpus_size.to_double())
}

///|
/// Compute the unknown prior in log space to avoid underflow for long words.
fn SymSpell::unknown_log_probability(self : SymSpell, length : Int) -> Double {
  1.0 - @math.log10(self.corpus_size.to_double()) - length.to_double()
}
