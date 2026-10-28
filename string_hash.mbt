///|
/// Hash every UTF-16 unit. Expanding four polynomial steps lets their character
/// products execute independently while preserving the scalar hash exactly.
#inline
fn string_table_hash(key : String) -> Int32 {
  let mut hash = 0U
  let mut i = 0
  while key.length() - i >= 4 {
    hash = hash * 923521U +
      key.unsafe_get(i).to_int().reinterpret_as_uint() * 29791U +
      key.unsafe_get(i + 1).to_int().reinterpret_as_uint() * 961U +
      key.unsafe_get(i + 2).to_int().reinterpret_as_uint() * 31U +
      key.unsafe_get(i + 3).to_int().reinterpret_as_uint()
    i = i + 4
  }
  while i < key.length() {
    hash = hash * 31U + key.unsafe_get(i).to_int().reinterpret_as_uint()
    i = i + 1
  }
  hash = (hash ^ (hash >> 16)) * 0x85ebca6bU
  let result = (hash ^ (hash >> 13)).reinterpret_as_int()
  if result == 0 {
    1
  } else {
    result
  }
}

///|
#cfg(not(target="js"))
#inline
fn word_table_hash(key : String) -> Int32 {
  string_table_hash(key)
}

///|
/// JavaScript's word slots use the runtime's own cached string hashes.
#cfg(target="js")
fn word_table_hash(_key : String) -> Int32 {
  0
}
