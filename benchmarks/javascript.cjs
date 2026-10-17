// The unmodified npm package is the timed baseline. Adapters only replace its
// file/line I/O with an already-decoded string, matching the MoonBit APIs.
const fs = require('node:fs');
const { performance } = require('node:perf_hooks');
const SymSpell = require('node-symspell');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function dictionary() {
  const result = new SymSpell(2, 7, 1);
  for (const line of data.dictionary_text.trimEnd().split('\n')) {
    const [term, count] = line.split(' ');
    result.createDictionaryEntry(term, Number(count));
  }
  return result;
}

function corpus() {
  const result = new SymSpell(2, 7, 1);
  // parseWords is the package's own tokenizer, also used by createDictionary.
  const words = result.parseWords(data.corpus_text);
  for (const word of words) result.createDictionaryEntry(word, 1);
  return { result, tokens: words.length };
}

function consume(items) {
  let sum = items.length;
  for (const item of items) sum += item.term.length + item.distance;
  return sum;
}

const lookups = [
  ['exact_top', data.exact_queries, SymSpell.Verbosity.TOP],
  ['typo_top', data.typo_queries, SymSpell.Verbosity.TOP],
  ['typo_closest', data.typo_queries, SymSpell.Verbosity.CLOSEST],
  ['typo_all', data.typo_queries, SymSpell.Verbosity.ALL],
  ['miss_top', data.miss_queries, SymSpell.Verbosity.TOP],
];
const dict = dictionary();

if (process.argv[3] === 'memory') {
  console.log(`stat\twords\t${dict.words.size}`);
} else if (process.argv[3] === 'validate') {
  console.log(`stat\twords\t${dict.words.size}`);
  for (const [name, queries, mode] of lookups) {
    queries.forEach((query, index) => {
      const result = dict.lookup(query, mode, 2);
      console.log(`query\t${name}\t${index}`);
      for (const item of result) {
        console.log(`word\t${name}\t${index}\t${item.term}\t${item.distance}\t${item.count}`);
      }
    });
  }
  data.compound_queries.forEach((query, index) => {
    const item = dict.lookupCompound(query, 2)[0];
    console.log(`compound\t${index}\t${item.term}\t${item.distance}\t${item.count}`);
  });
  data.segmentation_queries.forEach((query, index) => {
    const item = dict.wordSegmentation(query, { maxEditDistance: 2 });
    console.log(`segmentation\t${index}\t${item.correctedString}\t${item.distanceSum}\t${item.probabilityLogSum}`);
  });
  const built = corpus();
  console.log(`stat\tcorpus_tokens\t${built.tokens}`);
  console.log(`stat\tcorpus_words\t${built.result.words.size}`);
} else {
  const warmupMs = Number(process.argv[3] ?? 100);
  const sampleMs = Number(process.argv[4] ?? 200);
  function measure(name, operation, operationsPerBatch) {
    let checksum = 0;
    let start = performance.now();
    while (performance.now() - start < warmupMs) checksum = (checksum + operation()) | 0;
    // Collect garbage outside the measured region. Collections caused by the
    // timed operations themselves remain part of the result.
    if (global.gc) global.gc();
    start = performance.now();
    let batches = 0;
    while (performance.now() - start < sampleMs) {
      checksum = (checksum + operation()) | 0;
      batches++;
    }
    console.log(`metric\t${name}\t${(performance.now() - start) * 1000}\t${batches * operationsPerBatch}\t${checksum}`);
  }
  measure('build', () => dictionary().words.size, 1);
  measure('corpus', () => { const built = corpus(); return built.tokens + built.result.words.size; }, 1);
  for (const [name, queries, mode] of lookups) {
    measure(name, () => {
      let sum = 0;
      for (const query of queries) sum += consume(dict.lookup(query, mode, 2));
      return sum;
    }, queries.length);
  }
  measure('compound', () => {
    let sum = 0;
    for (const query of data.compound_queries) sum += consume(dict.lookupCompound(query, 2));
    return sum;
  }, data.compound_queries.length);
  measure('segmentation', () => {
    let sum = 0;
    for (const query of data.segmentation_queries) {
      const item = dict.wordSegmentation(query, { maxEditDistance: 2 });
      sum += item.correctedString.length + item.distanceSum;
    }
    return sum;
  }, data.segmentation_queries.length);
}
