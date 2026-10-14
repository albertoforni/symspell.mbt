///|
/// Banded optimal string alignment distance with three reusable rows.
/// Return None as soon as the cutoff cannot be met. Space is linear in the
/// shorter string; time is proportional to the longer string times the band.
fn osa_distance(a : Array[Char], b : Array[Char], max_distance : Int) -> Int? {
  let (left, right) = if a.length() <= b.length() { (a, b) } else { (b, a) }
  let columns = left.length()
  let rows = right.length()
  let limit = Int::min(max_distance, rows)
  if rows - columns > limit {
    return None
  }
  if columns == 0 {
    return Some(rows)
  }
  let infinity = limit + 1
  let mut previous_previous = Array::make(columns + 1, infinity)
  let mut previous = Array::make(columns + 1, infinity)
  let mut current = Array::make(columns + 1, infinity)
  for j = 0; j <= Int::min(columns, limit); j = j + 1 {
    previous[j] = j
  }
  for i = 1; i <= rows; i = i + 1 {
    let start = Int::max(1, i - limit)
    let end = Int::min(columns, i + limit)
    current[0] = if i <= limit { i } else { infinity }
    if start > 1 {
      current[start - 1] = infinity
    }
    if end < columns {
      current[end + 1] = infinity
    }
    let mut row_min = current[0]
    for j = start; j <= end; j = j + 1 {
      let cost = if left[j - 1] == right[i - 1] { 0 } else { 1 }
      let mut distance = Int::min(
        previous[j - 1] + cost,
        Int::min(previous[j] + 1, current[j - 1] + 1),
      )
      if i > 1 &&
        j > 1 &&
        right[i - 1] == left[j - 2] &&
        right[i - 2] == left[j - 1] {
        distance = Int::min(distance, previous_previous[j - 2] + 1)
      }
      current[j] = Int::min(distance, infinity)
      row_min = Int::min(row_min, current[j])
    }
    if row_min > limit {
      return None
    }
    let reusable = previous_previous
    previous_previous = previous
    previous = current
    current = reusable
  }
  if previous[columns] <= limit {
    Some(previous[columns])
  } else {
    None
  }
}
