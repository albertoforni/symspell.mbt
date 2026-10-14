///|
fn main {
  let dictionary = try! @symspell.SymSpell::new()
  let _ = try! dictionary.load_dictionary(
    "members 226656153\nmember 100000\nremember 90000\ncafé 5000\n東京 3000\n😀 1000\n",
  )
  for query in ["memebers", "cafe", "東亰", "😃"] {
    println("\{query}:")
    for suggestion in (try! dictionary.lookup(query)) {
      println(
        "  \{suggestion.term} (distance \{suggestion.distance}, frequency \{suggestion.count})",
      )
    }
  }
}
