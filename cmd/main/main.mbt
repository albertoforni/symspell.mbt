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
  let phrases = try! @symspell.SymSpell::new()
  let _ = try! phrases.load_dictionary(
    "where 2\nis 2\nwhereas 2\nhello 100\nworld 90\nsteam 1\nmachine 1\n",
  )
  let _ = try! phrases.load_bigram_dictionary("where is 10")
  for query in ["whereiz", "ste am machie"] {
    let result = (try! phrases.lookup_compound(query))[0]
    println("\{query} => \{result.term} (distance \{result.distance})")
  }
  for query in ["helloworld", "helo world"] {
    let result = try! phrases.word_segmentation(query)
    println(
      "\{query} => \{result.corrected_string} (penalty \{result.distance_sum})",
    )
  }
}
