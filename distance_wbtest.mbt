///|
// Independent full-matrix OSA oracle: no affix trimming, cutoff band, or reused
// buffers. Deliberately keep the reference simple for the optimized kernel.
fn reference_osa(a : Array[Char], b : Array[Char]) -> Int {
  let matrix = Array::makei(a.length() + 1, _ => Array::make(b.length() + 1, 0))
  for i = 0; i <= a.length(); i = i + 1 {
    matrix[i][0] = i
  }
  for j = 0; j <= b.length(); j = j + 1 {
    matrix[0][j] = j
  }
  for i = 1; i <= a.length(); i = i + 1 {
    for j = 1; j <= b.length(); j = j + 1 {
      let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 }
      let mut value = Int::min(
        matrix[i - 1][j - 1] + cost,
        Int::min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1),
      )
      if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
        value = Int::min(value, matrix[i - 2][j - 2] + 1)
      }
      matrix[i][j] = value
    }
  }
  matrix[a.length()][b.length()]
}

///|
test "reused distance buffers and trimmed Unicode affixes match full OSA" {
  let workspace = OsaWorkspace::new()
  let terms = [
    "", "a", "b", "😀", "ab", "ba", "aa", "a😀", "😀a", "😀😀", "aba",
    "b😀a", "abcabcab", "xxabc", "Á", "ā", "😁",
  ]
  for affixes in [("", ""), ("prefix😀", "😀suffix"), ("aaaaa", "aa")] {
    let (prefix, suffix) = affixes
    for left in terms {
      for right in terms {
        let a = (prefix + left + suffix).to_array()
        let b = (prefix + right + suffix).to_array()
        let distance = reference_osa(a, b)
        let left_signature = character_signature(a)
        let right_signature = character_signature(b)
        assert_true(
          (left_signature & right_signature.lnot()).popcnt() <= distance,
        )
        assert_true(
          (right_signature & left_signature.lnot()).popcnt() <= distance,
        )
        // Exercise decreasing and increasing bands with the same storage.
        for cutoff in [4, 0, 2, 1, 3, 0] {
          let expected = if distance <= cutoff { Some(distance) } else { None }
          assert_eq(
            osa_distance_with_workspace(a, b, cutoff, workspace),
            expected,
          )
          assert_eq(osa_distance(a, b, cutoff), expected)
        }
      }
    }
  }
}
