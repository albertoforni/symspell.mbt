///|
/// The JavaScript runtime provides a faster slot table than a second hash map
/// implemented on JavaScript arrays. Integer hash keys also let lookup probe
/// deletion variants without building strings. Chains retain full key equality.
priv struct StringEntry[V] {
  key : String
  mut value : V
  mut next : StringEntry[V]?
}

///|
#external
priv type IndexMap

///|
#external
priv type IndexValue

///|
extern "js" fn index_map_new() -> IndexMap =
  #| () => new Map()

///|
extern "js" fn index_map_get(map : IndexMap, hash : Int32) -> IndexValue =
  #| (map, hash) => map.get(hash)

///|
extern "js" fn index_map_set(
  map : IndexMap,
  hash : Int32,
  value : IndexValue,
) -> Unit =
  #| (map, hash, value) => { map.set(hash, value); }

///|
extern "js" fn index_map_remove(map : IndexMap, hash : Int32) -> Unit =
  #| (map, hash) => { map.delete(hash); }

///|
extern "js" fn index_word_get(map : IndexMap, key : String) -> IndexValue =
  #| (map, key) => map.get(key)

///|
extern "js" fn index_word_set(
  map : IndexMap,
  key : String,
  value : IndexValue,
) -> Unit =
  #| (map, key, value) => { map.set(key, value); }

///|
extern "js" fn index_word_remove(map : IndexMap, key : String) -> Unit =
  #| (map, key) => { map.delete(key); }

///|
extern "js" fn index_map_values(map : IndexMap) -> FixedArray[IndexValue] =
  #| map => Array.from(map.values())

///|
extern "js" fn index_value_missing(value : IndexValue) -> Bool =
  #| value => value === undefined

///|
// These representation casts are confined to JavaScript and StringEntry
// references created by this file. No primitive, Option, or Array ABI is cast.
fn[V] erase_index_entry(value : StringEntry[V]) -> IndexValue = "%identity"

///|
fn[V] restore_index_entry(value : IndexValue) -> StringEntry[V] = "%identity"

///|
#warnings("-unused_type_variable")
priv struct StringTable[V] {
  slots : IndexMap
  word_keys : Bool
  mut size : Int32
}

///|
fn[V] StringTable::new(word_keys~ : Bool = false) -> StringTable[V] {
  { slots: index_map_new(), word_keys, size: 0, }
}

///|
fn[V] StringTable::head(self : StringTable[V], hash : Int32) -> StringEntry[V]? {
  let value = index_map_get(self.slots, hash)
  if index_value_missing(value) {
    None
  } else {
    Some(restore_index_entry(value))
  }
}

///|
fn[V] StringTable::key_head(
  self : StringTable[V],
  key : String,
  hash : Int32,
) -> StringEntry[V]? {
  if self.word_keys {
    let value = index_word_get(self.slots, key)
    if index_value_missing(value) {
      None
    } else {
      Some(restore_index_entry(value))
    }
  } else {
    self.head(hash)
  }
}

///|
fn[V] StringTable::store(
  self : StringTable[V],
  key : String,
  hash : Int32,
  entry : StringEntry[V],
) -> Unit {
  if self.word_keys {
    index_word_set(self.slots, key, erase_index_entry(entry))
  } else {
    index_map_set(self.slots, hash, erase_index_entry(entry))
  }
}

///|
fn[V] StringTable::get(self : StringTable[V], key : String) -> V? {
  let hash = if self.word_keys { 0 } else { string_table_hash(key) }
  let mut next = self.key_head(key, hash)
  while next is Some(entry) {
    if entry.key == key {
      return Some(entry.value)
    }
    next = entry.next
  }
  None
}

///|
fn[V] StringTable::get_or_init(
  self : StringTable[V],
  key : String,
  initialize : () -> V,
) -> V {
  let hash = if self.word_keys { 0 } else { string_table_hash(key) }
  let head = self.key_head(key, hash)
  let mut next = head
  while next is Some(entry) {
    if entry.key == key {
      return entry.value
    }
    next = entry.next
  }
  let value = initialize()
  let entry = { key, value, next: head, }
  self.store(key, hash, entry)
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
  let hash = if self.word_keys { 0 } else { string_table_hash(key) }
  let head = self.key_head(key, hash)
  let mut next = head
  while next is Some(entry) {
    if entry.key == key {
      entry.value = value
      return false
    }
    next = entry.next
  }
  let entry = { key, value, next: head, }
  self.store(key, hash, entry)
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
  let hash = if self.word_keys { 0 } else { string_table_hash(key) }
  let mut previous : StringEntry[V]? = None
  let mut next = self.key_head(key, hash)
  while next is Some(entry) {
    if entry.key == key {
      if previous is Some(previous) {
        previous.next = entry.next
      } else if entry.next is Some(tail) {
        self.store(key, hash, tail)
      } else if self.word_keys {
        index_word_remove(self.slots, key)
      } else {
        index_map_remove(self.slots, hash)
      }
      self.size = self.size - 1
      return
    }
    previous = next
    next = entry.next
  }
}

///|
fn[V] StringTable::contains(self : StringTable[V], key : String) -> Bool {
  self.get(key) is Some(_)
}

///|
fn[V] StringTable::length(self : StringTable[V]) -> Int32 {
  self.size
}

///|
fn[V] StringTable::is_empty(self : StringTable[V]) -> Bool {
  self.size == 0
}

///|
fn[V] StringTable::all_entries(self : StringTable[V]) -> Array[StringEntry[V]] {
  let entries = []
  for value in index_map_values(self.slots) {
    let mut next = Some(restore_index_entry(value))
    while next is Some(entry) {
      entries.push(entry)
      next = entry.next
    }
  }
  entries
}

///|
fn[V] StringTable::keys(self : StringTable[V]) -> Iter[String] {
  self.all_entries().iter().map(entry => entry.key)
}

///|
fn[V] StringTable::values(self : StringTable[V]) -> Iter[V] {
  self.all_entries().iter().map(entry => entry.value)
}

///|
#locals(visit)
fn[V] StringTable::each_hash(
  self : StringTable[V],
  hash : Int32,
  visit : (V) -> Unit,
) -> Unit {
  let mut next = self.head(hash)
  while next is Some(entry) {
    visit(entry.value)
    next = entry.next
  }
}

///|
priv struct WordTable {
  words : StringTable[Word]
}

///|
fn WordTable::new() -> WordTable {
  { words: StringTable::new(word_keys=true), }
}

///|
fn WordTable::get(self : WordTable, key : String) -> Word? {
  self.words.get(key)
}

///|
#alias("_[_]=_")
fn WordTable::set(self : WordTable, key : String, word : Word) -> Unit {
  self.words[key] = word
}

///|
fn WordTable::remove(self : WordTable, key : String) -> Unit {
  self.words.remove(key)
}

///|
fn WordTable::contains(self : WordTable, key : String) -> Bool {
  self.words.contains(key)
}

///|
fn WordTable::length(self : WordTable) -> Int32 {
  self.words.length()
}

///|
fn WordTable::is_empty(self : WordTable) -> Bool {
  self.words.is_empty()
}

///|
fn WordTable::values(self : WordTable) -> Iter[Word] {
  self.words.values()
}
