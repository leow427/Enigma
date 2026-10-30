import Foundation
import NaturalLanguage

/// A piece of a page, 60–180 words, in page order (`order`), with its BM25 score once scored.
struct Passage: Equatable, Sendable {
  let text: String
  let order: Int
  var score: Double = 0
}

/// Splits pages into passages and scores them against the question (spec §5).
enum PassageRanker {
  static let minimumWords = 60, targetWords = 180, splitAbove = 250, codeLimit = 400
  static let k1 = 1.2, b = 0.75
  /// Two or more distinct question words within this many tokens earn `proximityBonus`.
  static let proximityWindow = 10
  static let proximityBonus = 1.1
  /// The opening passage goes first when it scores at least this share of the page's best.
  static let leadShare = 0.3

  /// A unit before grouping: prose joins with its neighbours; a fixed passage (code, a table
  /// group) stands alone. `startsSection` marks the first unit under a heading.
  private struct Unit {
    var text: String
    var words: Int
    var fixed: Bool
    var startsSection: Bool
  }

  // MARK: Splitting

  static func passages(from blocks: [ArticleBlock]) -> [Passage] {
    var units: [Unit] = []
    var heading: String?
    var index = 0
    /// Puts a pending heading in front of the first unit under it.
    func add(_ text: String, fixed: Bool) {
      var text = text
      let startsSection = heading != nil
      if let pending = heading { text = "Section: \(pending)\n" + text }
      heading = nil
      units.append(Unit(text: text, words: TextWords.count(in: text), fixed: fixed, startsSection: startsSection))
    }
    while index < blocks.count {
      let block = blocks[index]
      let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
      switch block.kind {
      case .heading:
        if !text.isEmpty { heading = text }
        index += 1
      case .code:
        if !text.isEmpty { add(cutCode(text), fixed: true) }
        index += 1
      case .tableRow:
        var rows: [String] = []
        while index < blocks.count, blocks[index].kind == .tableRow {
          let row = blocks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !row.isEmpty { rows.append(row) }
          index += 1
        }
        for group in tableGroups(rows) { add(group, fixed: true) }
      case .paragraph, .listItem:
        index += 1
        guard !text.isEmpty else { continue }
        if TextWords.count(in: text) > splitAbove {
          for piece in sentencePieces(text) { add(piece, fixed: false) }
        } else {
          add(text, fixed: false)
        }
      }
    }
    return group(units).enumerated().map { Passage(text: $0.element, order: $0.offset) }
  }

  /// Paragraphs at blank lines (Wikipedia's extracts and `text/plain` pages), each one's line
  /// breaks folded into spaces. With `lineBreaks`, every line is a paragraph: Wikipedia's plain
  /// extracts put one paragraph per line (D74).
  static func passages(fromPlainText text: String, lineBreaks: Bool = false) -> [Passage] {
    passages(from: paragraphBlocks(text, lineBreaks: lineBreaks))
  }

  static func paragraphBlocks(_ text: String, lineBreaks: Bool = false) -> [ArticleBlock] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let paragraphs: [String]
    if lineBreaks {
      paragraphs = normalized.components(separatedBy: "\n")
    } else {
      paragraphs = normalized.replacingOccurrences(of: #"\n[ \t]*\n"#, with: "\u{0}", options: .regularExpression)
        .components(separatedBy: "\u{0}")
    }
    return paragraphs.compactMap { paragraph in
      let folded = paragraph.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " ")
      return folded.isEmpty ? nil : ArticleBlock(kind: .paragraph, text: folded)
    }
  }

  /// Prose units join until the next would pass `targetWords`; a section start or a fixed unit
  /// begins a new passage. Then a passage under `minimumWords` merges with the next when the two
  /// still fit and the next doesn't start a section or stand alone.
  private static func group(_ units: [Unit]) -> [String] {
    var joined: [Unit] = []
    for unit in units {
      if !unit.fixed, !unit.startsSection, var last = joined.last, !last.fixed,
         last.words + unit.words <= targetWords {
        last.text += "\n" + unit.text
        last.words += unit.words
        joined[joined.count - 1] = last
      } else {
        joined.append(unit)
      }
    }
    var merged: [Unit] = []
    var index = 0
    while index < joined.count {
      var unit = joined[index]
      if unit.words < minimumWords, !unit.fixed, index + 1 < joined.count {
        let next = joined[index + 1]
        if !next.fixed, !next.startsSection, unit.words + next.words <= targetWords {
          unit.text += "\n" + next.text
          unit.words += next.words
          index += 1
        }
      }
      merged.append(unit)
      index += 1
    }
    return merged.map(\.text)
  }

  /// Sentences from `NLTokenizer`, grouped into pieces of at most `targetWords`. A single
  /// sentence longer than that is cut at word boundaries.
  private static func sentencePieces(_ text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var sentences: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
      if !sentence.isEmpty { sentences.append(sentence) }
      return true
    }
    var pieces: [String] = []
    var current = "", currentWords = 0
    for sentence in sentences.flatMap(cutLongSentence) {
      let words = TextWords.count(in: sentence)
      if currentWords > 0, currentWords + words > targetWords {
        pieces.append(current)
        current = ""
        currentWords = 0
      }
      current += (current.isEmpty ? "" : " ") + sentence
      currentWords += words
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }

  private static func cutLongSentence(_ sentence: String) -> [String] {
    guard TextWords.count(in: sentence) > targetWords else { return [sentence] }
    var pieces: [String] = []
    var rest = Substring(sentence)
    while let end = endOfWord(targetWords, in: rest), end < rest.endIndex {
      pieces.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
      rest = rest[end...]
    }
    let tail = rest.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { pieces.append(tail) }
    return pieces
  }

  /// Where the `count`th word ends, or nil when the text has fewer words.
  private static func endOfWord(_ count: Int, in text: Substring) -> String.Index? {
    var seen = 0
    var end: String.Index?
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, stop in
      seen += 1
      if seen == count {
        end = range.upperBound
        stop = true
      }
    }
    return end
  }

  private static func cutCode(_ text: String) -> String {
    guard TextWords.count(in: text) > codeLimit, let end = endOfWord(codeLimit, in: Substring(text)) else { return text }
    return String(text[..<end]) + "…"
  }

  /// Rows grouped up to `targetWords`, each group starting with the header row.
  private static func tableGroups(_ rows: [String]) -> [String] {
    guard let header = rows.first else { return [] }
    guard rows.count > 1 else { return [header] }
    let headerWords = TextWords.count(in: header)
    var groups: [String] = []
    var current: [String] = []
    var currentWords = headerWords
    for row in rows.dropFirst() {
      let words = TextWords.count(in: row)
      if !current.isEmpty, currentWords + words > targetWords {
        groups.append(([header] + current).joined(separator: "\n"))
        current = []
        currentWords = headerWords
      }
      current.append(row)
      currentWords += words
    }
    if !current.isEmpty { groups.append(([header] + current).joined(separator: "\n")) }
    return groups
  }
}

// MARK: Scoring

extension PassageRanker {
  /// A small fixed English list; lemmas, so "is" and "are" appear as "be".
  static let stopWords: Set<String> = [
    "a", "an", "the", "be", "is", "are", "was", "were", "been", "being", "am", "of", "in", "on", "at", "to", "for",
    "from", "by", "with", "about", "as", "into", "and", "or", "but", "if", "then", "than", "so", "not", "no", "what",
    "which", "who", "whom", "whose", "when", "where", "why", "how", "do", "does", "did", "can", "could", "should",
    "would", "will", "shall", "may", "might", "must", "i", "you", "he", "she", "it", "we", "they", "me", "him",
    "her", "us", "them", "my", "your", "his", "its", "our", "their", "this", "that", "these", "those", "there",
    "here", "have", "has", "had", "any", "some", "all", "'s", "s", "get", "tell", "please", "up", "out",
  ]

  /// `NLTagger`'s lemmas, lowercased; the lowercased word where a language has no lemma.
  static func lemmas(_ text: String) -> [String] {
    lemmas(text, tagger: NLTagger(tagSchemes: [.lemma]))
  }

  private static func lemmas(_ text: String, tagger: NLTagger) -> [String] {
    tagger.string = text
    var result: [String] = []
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                         options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
      let lemma = tag?.rawValue.lowercased() ?? ""
      result.append(lemma.isEmpty ? text[range].lowercased() : lemma)
      return true
    }
    return result
  }

  /// Lemmas minus `stopWords`.
  static func contentLemmas(_ text: String) -> Set<String> {
    Set(lemmas(text)).subtracting(stopWords)
  }

  static func score(_ pages: [[Passage]], question: String) -> [[Passage]] {
    scoreWithLemmas(pages, question: question).pages
  }

  /// BM25 over every passage of every page, with document frequencies across them all, plus
  /// each page's content lemmas for the off-topic check. Lemmatizing stops on a page after
  /// `wordLimit` words: later passages keep a score of 0.
  static func scoreWithLemmas(_ pages: [[Passage]], question: String, wordLimit: Int = .max)
    -> (pages: [[Passage]], pageLemmas: [Set<String>]) {
    let questionLemmas = contentLemmas(question)
    let tagger = NLTagger(tagSchemes: [.lemma])
    var tokens: [[[String]]] = []
    for page in pages {
      var words = 0
      tokens.append(page.map { passage in
        guard words < wordLimit else { return [] }
        let lemmas = lemmas(passage.text, tagger: tagger)
        words += lemmas.count
        return lemmas
      })
    }
    let pageLemmas = tokens.map { Set($0.joined()).subtracting(stopWords) }
    let all = tokens.joined().filter { !$0.isEmpty }
    guard !questionLemmas.isEmpty, !all.isEmpty else { return (pages, pageLemmas) }

    let count = Double(all.count)
    let averageLength = max(1, Double(all.reduce(0) { $0 + $1.count }) / count)
    var documentFrequency: [String: Int] = [:]
    for passage in all {
      for lemma in Set(passage) where questionLemmas.contains(lemma) { documentFrequency[lemma, default: 0] += 1 }
    }
    var scored = pages
    for pageIndex in pages.indices {
      for passageIndex in pages[pageIndex].indices {
        let passage = tokens[pageIndex][passageIndex]
        guard !passage.isEmpty else { continue }
        var frequencies: [String: Int] = [:]
        for lemma in passage where questionLemmas.contains(lemma) { frequencies[lemma, default: 0] += 1 }
        let length = Double(passage.count)
        var score = 0.0
        for (lemma, frequency) in frequencies {
          let n = Double(documentFrequency[lemma] ?? 0)
          let idf = log((count - n + 0.5) / (n + 0.5) + 1)
          let tf = Double(frequency)
          score += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * length / averageLength))
        }
        if frequencies.count >= 2, hasNearbyPair(passage, questionLemmas) { score *= proximityBonus }
        scored[pageIndex][passageIndex].score = score
      }
    }
    return (scored, pageLemmas)
  }

  /// Two distinct question lemmas within any `proximityWindow`-token window.
  private static func hasNearbyPair(_ tokens: [String], _ question: Set<String>) -> Bool {
    let hits = tokens.enumerated().filter { question.contains($0.element) }
    for (index, hit) in hits.enumerated() {
      for other in hits[(index + 1)...] {
        guard other.offset - hit.offset < proximityWindow else { break }
        if other.element != hit.element { return true }
      }
    }
    return false
  }

  /// Best first, ties in page order; the opening passage goes first when it scores at least
  /// `leadShare` of the best.
  static func ordered(_ passages: [Passage]) -> [Passage] {
    var sorted = passages.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
    guard let best = sorted.first?.score, let lead = sorted.firstIndex(where: { $0.order == 0 }), lead > 0,
          sorted[lead].score >= leadShare * best else { return sorted }
    sorted.insert(sorted.remove(at: lead), at: 0)
    return sorted
  }
}
