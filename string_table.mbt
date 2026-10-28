///|
/// The index does not need insertion ordering. Keep its string probes small,
/// cache hashes in entries, and grow at a 50% load factor. Equality always checks
/// the complete key, including when different Unicode strings have equal hashes.
priv struct StringEntry[V] {
  key : String
  hash : Int32
  mut value : V
}

///|
priv struct StringTable[V] {
  mut entries : FixedArray[StringEntry[V]?]
  mut size : Int32
}

///|
fn[V] StringTable::new() -> StringTable[V] {
  { entries: FixedArray::make(16, None), size: 0, }
}

///|
#inline
fn[V] StringTable::get(self : StringTable[V], key : String) -> V? {
  let hash = string_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(entry) {
    if entry.hash == hash && entry.key == key {
      return Some(entry.value)
    }
    slot = (slot + 1) & mask
  }
  None
}

///|
fn[V] StringTable::place(self : StringTable[V], entry : StringEntry[V]) -> Unit {
  let mask = self.entries.length() - 1
  let mut slot = entry.hash & mask
  while self.entries.unsafe_get(slot) is Some(_) {
    slot = (slot + 1) & mask
  }
  self.entries.unsafe_set(slot, Some(entry))
}

///|
fn[V] StringTable::grow(self : StringTable[V]) -> Unit {
  let old = self.entries
  self.entries = FixedArray::make(old.length() * 2, None)
  for entry in old {
    if entry is Some(entry) {
      self.place(entry)
    }
  }
}

///|
fn[V] StringTable::get_or_init(
  self : StringTable[V],
  key : String,
  initialize : () -> V,
) -> V {
  let hash = string_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(entry) {
    if entry.hash == hash && entry.key == key {
      return entry.value
    }
    slot = (slot + 1) & mask
  }
  let value = initialize()
  let entry = { key, hash, value, }
  if self.size * 2 >= self.entries.length() {
    self.grow()
    self.place(entry)
  } else {
    self.entries.unsafe_set(slot, Some(entry))
  }
  self.size = self.size + 1
  value
}

///|
#alias("_[_]=_")
fn[V] StringTable::set(self : StringTable[V], key : String, value : V) -> Unit {
  ignore(self.insert(key, value))
}

///|
fn[V] StringTable::insert(
  self : StringTable[V],
  key : String,
  value : V,
) -> Bool {
  let hash = string_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(entry) {
    if entry.hash == hash && entry.key == key {
      entry.value = value
      return false
    }
    slot = (slot + 1) & mask
  }
  let entry = { key, hash, value, }
  if self.size * 2 >= self.entries.length() {
    self.grow()
    self.place(entry)
  } else {
    self.entries.unsafe_set(slot, Some(entry))
  }
  self.size = self.size + 1
  true
}

///|
#alias("_[_]")
fn[V] StringTable::at(self : StringTable[V], key : String) -> V {
  self.get(key).unwrap()
}

///|
fn[V] StringTable::remove(self : StringTable[V], key : String) -> Unit {
  let hash = string_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(entry) {
    if entry.hash == hash && entry.key == key {
      self.entries.unsafe_set(slot, None)
      self.size = self.size - 1
      // Reinsert the following cluster so deletions never break a probe chain.
      slot = (slot + 1) & mask
      while self.entries.unsafe_get(slot) is Some(next) {
        self.entries.unsafe_set(slot, None)
        self.place(next)
        slot = (slot + 1) & mask
      }
      return
    }
    slot = (slot + 1) & mask
  }
}

///|
fn[V] StringTable::length(self : StringTable[V]) -> Int32 {
  self.size
}

///|
fn[V] StringTable::keys(self : StringTable[V]) -> Iter[String] {
  self.entries.iter().filter_map(entry => entry.map(entry => entry.key))
}

///|
#locals(visit)
fn[V] StringTable::each_hash(
  self : StringTable[V],
  hash : Int32,
  visit : (V) -> Unit,
) -> Unit {
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(entry) {
    if entry.hash == hash {
      visit(entry.value)
    }
    slot = (slot + 1) & mask
  }
}

///|
/// Store words directly in exact-match slots. An additional generic table-entry
/// object would add a pointer hop and native reference-count traffic per hit.
priv struct WordTable {
  mut entries : FixedArray[Word?]
  mut size : Int32
}

///|
fn WordTable::new() -> WordTable {
  { entries: FixedArray::make(16, None), size: 0, }
}

///|
fn WordTable::get(self : WordTable, key : String) -> Word? {
  let hash = word_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(word) {
    if word.term_hash == hash && word.term == key {
      return Some(word)
    }
    slot = (slot + 1) & mask
  }
  None
}

///|
fn WordTable::place(self : WordTable, word : Word) -> Unit {
  let mask = self.entries.length() - 1
  let mut slot = word.term_hash & mask
  while self.entries.unsafe_get(slot) is Some(_) {
    slot = (slot + 1) & mask
  }
  self.entries.unsafe_set(slot, Some(word))
}

///|
#alias("_[_]=_")
fn WordTable::set(self : WordTable, key : String, word : Word) -> Unit {
  let mask = self.entries.length() - 1
  let mut slot = word.term_hash & mask
  while self.entries.unsafe_get(slot) is Some(previous) {
    if previous.term == key {
      self.entries.unsafe_set(slot, Some(word))
      return
    }
    slot = (slot + 1) & mask
  }
  if self.size * 2 >= self.entries.length() {
    let old = self.entries
    self.entries = FixedArray::make(old.length() * 2, None)
    for item in old {
      if item is Some(item) {
        self.place(item)
      }
    }
    self.place(word)
  } else {
    self.entries.unsafe_set(slot, Some(word))
  }
  self.size = self.size + 1
}

///|
fn WordTable::remove(self : WordTable, key : String) -> Unit {
  let hash = word_table_hash(key)
  let mask = self.entries.length() - 1
  let mut slot = hash & mask
  while self.entries.unsafe_get(slot) is Some(word) {
    if word.term_hash == hash && word.term == key {
      self.entries.unsafe_set(slot, None)
      self.size = self.size - 1
      slot = (slot + 1) & mask
      while self.entries.unsafe_get(slot) is Some(next) {
        self.entries.unsafe_set(slot, None)
        self.place(next)
        slot = (slot + 1) & mask
      }
      return
    }
    slot = (slot + 1) & mask
  }
}

///|
fn WordTable::contains(self : WordTable, key : String) -> Bool {
  self.get(key) is Some(_)
}

///|
fn WordTable::length(self : WordTable) -> Int32 {
  self.size
}

///|
fn WordTable::is_empty(self : WordTable) -> Bool {
  self.size == 0
}

///|
fn WordTable::values(self : WordTable) -> Iter[Word] {
  self.entries.iter().filter_map(value => value)
}
