///|
/// Banded optimal string alignment distance with common affixes trimmed.
/// Return None as soon as the cutoff cannot be met. Space is linear in the
/// shorter string; time is proportional to the longer string times the band.
fn osa_distance(a : Array[Char], b : Array[Char], max_distance : Int) -> Int? {
  osa_distance_with_workspace(a, b, max_distance, OsaWorkspace::new())
}

///|
/// A lookup owns its workspace: buffers are shared between candidate checks,
/// never between queries or mutable dictionaries.
priv struct OsaWorkspace {
  mut row0 : Array[Int]
  mut row1 : Array[Int]
  mut row2 : Array[Int]
}

///|
fn OsaWorkspace::new() -> OsaWorkspace {
  { row0: [], row1: [], row2: [] }
}

///|
fn osa_distance_with_workspace(
  a : Array[Char],
  b : Array[Char],
  max_distance : Int,
  workspace : OsaWorkspace,
) -> Int? {
  let (left, right) = if a.length() <= b.length() { (a, b) } else { (b, a) }
  let mut columns = left.length()
  let mut rows = right.length()
  if rows - columns > max_distance {
    return None
  }
  // Equal affixes do not participate in a minimum OSA edit path. Keep the
  // original character arrays and adjust offsets instead of copying slices.
  while columns > 0 && left[columns - 1] == right[rows - 1] {
    columns = columns - 1
    rows = rows - 1
  }
  let mut offset = 0
  while offset < columns && left[offset] == right[offset] {
    offset = offset + 1
  }
  columns = columns - offset
  rows = rows - offset
  let limit = Int::min(max_distance, rows)
  if rows - columns > limit {
    return None
  }
  if columns == 0 {
    return Some(rows)
  }
  if columns == 1 {
    let character = left[offset]
    let mut distance = rows
    for i = offset; i < offset + rows; i = i + 1 {
      if right[i] == character {
        distance = rows - 1
        break
      }
    }
    return if distance <= limit { Some(distance) } else { None }
  }
  if limit <= 1 {
    // Trimming already handled a single insertion, deletion, or replacement.
    // The only remaining one-edit match is a two-character transposition.
    return if limit == 1 &&
      columns == 2 &&
      rows == 2 &&
      left[offset] == right[offset + 1] &&
      left[offset + 1] == right[offset] {
      Some(1)
    } else {
      None
    }
  }
  let infinity = limit + 1
  if workspace.row0.length() < columns + 1 {
    workspace.row0 = Array::make(columns + 1, infinity)
    workspace.row1 = Array::make(columns + 1, infinity)
    workspace.row2 = Array::make(columns + 1, infinity)
  }
  let mut previous_previous = workspace.row0
  let mut previous = workspace.row1
  let mut current = workspace.row2
  for j = 0; j <= Int::min(columns, limit); j = j + 1 {
    previous[j] = j
  }
  if limit < columns {
    previous[limit + 1] = infinity
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
      let cost = if left[offset + j - 1] == right[offset + i - 1] {
        0
      } else {
        1
      }
      let mut distance = Int::min(
        previous[j - 1] + cost,
        Int::min(previous[j] + 1, current[j - 1] + 1),
      )
      if i > 1 &&
        j > 1 &&
        right[offset + i - 1] == left[offset + j - 2] &&
        right[offset + i - 2] == left[offset + j - 1] {
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
