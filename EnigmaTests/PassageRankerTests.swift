import XCTest
@testable import Enigma

/// Passage splitting and BM25 scoring (spec §5, F29 CP5).
final class PassageRankerTests: XCTestCase {
  /// `count` distinct-ish words ending in a full stop, as one sentence.
  private func sentence(_ count: Int, word: String = "word") -> String {
    // Capitalized, so the sentence tokenizer sees where each one starts.
    let text = (0..<count).map { "\(word)\($0 % 7)" }.joined(separator: " ") + "."
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  private func words(_ text: String) -> Int { TextWords.count(in: text) }

  // MARK: Splitting

  func testGroupsBlocksIntoPassages() {
    let blocks = (0..<12).map { ArticleBlock(kind: .paragraph, text: sentence(25 + ($0 % 4) * 20)) }
    let passages = PassageRanker.passages(from: blocks)
    XCTAssertGreaterThan(passages.count, 1)
    for passage in passages.dropLast() {
      XCTAssertTrue((PassageRanker.minimumWords...PassageRanker.targetWords).contains(words(passage.text)),
                    "\(words(passage.text)) words")
    }
    XCTAssertEqual(passages.map(\.order), Array(0..<passages.count))
    // Nothing lost or reordered.
    XCTAssertEqual(passages.map { words($0.text) }.reduce(0, +), blocks.map { words($0.text) }.reduce(0, +))
  }

  func testShortPassageMergesWithTheNext() {
    // A long paragraph's short last piece joins the paragraph after it.
    let long = [sentence(170), sentence(170), sentence(20)].joined(separator: " ")
    let blocks = [ArticleBlock(kind: .paragraph, text: long), ArticleBlock(kind: .paragraph, text: sentence(100))]
    XCTAssertEqual(PassageRanker.passages(from: blocks).map { words($0.text) }, [170, 170, 120])
  }

  func testSplitsLongParagraphAtSentences() {
    let paragraph = (0..<10).map { _ in sentence(30) }.joined(separator: " ")
    XCTAssertEqual(words(paragraph), 300)
    let passages = PassageRanker.passages(from: [ArticleBlock(kind: .paragraph, text: paragraph)])
    XCTAssertEqual(passages.count, 2)
    for passage in passages {
      XCTAssertLessThanOrEqual(words(passage.text), PassageRanker.targetWords)
      XCTAssertTrue(passage.text.hasSuffix("."), "Ends on a sentence boundary")
    }
  }

  func testHeadingPrefixesPassage() {
    let passages = PassageRanker.passages(from: [
      ArticleBlock(kind: .paragraph, text: sentence(80)),
      ArticleBlock(kind: .heading, text: "Pricing"),
      ArticleBlock(kind: .paragraph, text: "The plan costs $10 a month. " + sentence(70)),
    ])
    XCTAssertEqual(passages.count, 2)
    XCTAssertTrue(passages[1].text.hasPrefix("Section: Pricing\n"), passages[1].text)
    XCTAssertTrue(passages[1].text.contains("$10 a month"))
    XCTAssertFalse(passages[0].text.contains("Pricing"))
  }

  func testCodeBlockKeptWhole() {
    let short = (0..<350).map { "token\($0)" }.joined(separator: " ")
    let kept = PassageRanker.passages(from: [ArticleBlock(kind: .paragraph, text: sentence(80)),
                                            ArticleBlock(kind: .code, text: short)])
    XCTAssertEqual(kept.count, 2)
    XCTAssertEqual(kept[1].text, short)

    let long = (0..<450).map { "token\($0)" }.joined(separator: " ")
    let cut = PassageRanker.passages(from: [ArticleBlock(kind: .code, text: long)])
    XCTAssertEqual(cut.count, 1)
    XCTAssertTrue(cut[0].text.hasSuffix("…"))
    XCTAssertTrue(cut[0].text.hasPrefix("token0 token1"))
    XCTAssertEqual(words(cut[0].text), PassageRanker.codeLimit)
    XCTAssertTrue(cut[0].text.contains("token399"))
    XCTAssertFalse(cut[0].text.contains("token400"))
  }

  func testTableRowsKeepHeader() {
    let header = "Plan | Price | Seats"
    let rows = (0..<40).map { "Plan \($0) | $\($0) a month | \($0) seats for the whole team" }
    let blocks = [ArticleBlock(kind: .tableRow, text: header)] + rows.map { ArticleBlock(kind: .tableRow, text: $0) }
    let passages = PassageRanker.passages(from: blocks)
    XCTAssertGreaterThan(passages.count, 1)
    for passage in passages {
      XCTAssertTrue(passage.text.hasPrefix(header + "\n"), passage.text)
      XCTAssertLessThanOrEqual(words(passage.text), PassageRanker.targetWords)
    }
    let allRows = passages.flatMap { $0.text.components(separatedBy: "\n").dropFirst() }
    XCTAssertEqual(allRows, rows)
  }

  func testPlainTextSplitsOnBlankLines() {
    let text = "First paragraph line one\nline two.\n\n\nSecond paragraph.\n  \nThird."
    let passages = PassageRanker.passages(fromPlainText: text)
    XCTAssertEqual(passages.count, 1, "Short paragraphs join")
    XCTAssertEqual(passages[0].text, "First paragraph line one line two.\nSecond paragraph.\nThird.")

    let long = [sentence(150), sentence(150)].joined(separator: "\n\n")
    XCTAssertEqual(PassageRanker.passages(fromPlainText: long).count, 2)
    // Wikipedia's extracts put one paragraph per line.
    let lines = [sentence(150), sentence(150)].joined(separator: "\n")
    XCTAssertEqual(PassageRanker.passages(fromPlainText: lines, lineBreaks: true).count, 2)
    XCTAssertTrue(PassageRanker.passages(fromPlainText: " \n\n ").isEmpty)
  }

  // MARK: Scoring

  private func passage(_ text: String, order: Int = 0) -> Passage { Passage(text: text, order: order) }

  func testLemmasAndContentLemmas() {
    XCTAssertEqual(PassageRanker.lemmas("Current gas prices are rising"), ["current", "gas", "price", "be", "rise"])
    XCTAssertEqual(PassageRanker.contentLemmas("What are the current gas prices?"), ["current", "gas", "price"])
    XCTAssertTrue(PassageRanker.contentLemmas("what is it?").isEmpty)
  }

  func testBM25OrdersRelevantPassageFirst() {
    let pages = PassageRanker.score([[
      passage("The weather in the region is mild for most of the year, with occasional storms.", order: 0),
      passage("Battery life on the laptop reaches eighteen hours, and the battery charges quickly.", order: 1),
      passage("Our office is closed on public holidays.", order: 2),
    ]], question: "laptop battery life")
    let scores = pages[0].map(\.score)
    XCTAssertGreaterThan(scores[1], 0)
    XCTAssertEqual(scores[0], 0)
    XCTAssertEqual(scores[2], 0)
    XCTAssertEqual(PassageRanker.ordered(pages[0]).first?.order, 1)
  }

  func testIDFCoversEveryPage() {
    // "swift" is on every passage of both pages, "actor" on one: the actor passage wins.
    let pages = PassageRanker.score([
      [passage("Swift basics and Swift syntax.", order: 0)],
      [passage("Swift actor isolation explained.", order: 0), passage("Swift packages.", order: 1)],
    ], question: "swift actor")
    XCTAssertGreaterThan(pages[1][0].score, pages[0][0].score)
    XCTAssertGreaterThan(pages[1][0].score, pages[1][1].score)
  }

  func testLemmasMatchInflections() {
    let pages = PassageRanker.score([[
      passage("The average price of regular fuel rose this week.", order: 0),
      passage("Fuel stations are open late in the city.", order: 1),
    ]], question: "current gas prices")
    XCTAssertGreaterThan(pages[0][0].score, pages[0][1].score)
  }

  func testProximityBonus() {
    let filler = "one two three four five six seven eight nine ten eleven twelve"
    // Same terms and length except the near pair: the bonus is exactly 10%.
    let near = PassageRanker.score([[passage("solar cost \(filler) \(filler) panels", order: 0),
                                     passage("solar \(filler) cost \(filler) panels", order: 1),
                                     passage("unrelated words only here", order: 2)]], question: "solar cost")
    XCTAssertGreaterThan(near[0][1].score, 0)
    XCTAssertEqual(near[0][0].score / near[0][1].score, 1.1, accuracy: 1e-9)
  }

  func testLeadPassageFirstAtThirtyPercent() {
    let best = Passage(text: "b", order: 3, score: 10)
    let other = Passage(text: "c", order: 1, score: 5)
    let leadAbove = Passage(text: "a", order: 0, score: 3.1)
    XCTAssertEqual(PassageRanker.ordered([other, leadAbove, best]).map(\.order), [0, 3, 1])
    let leadBelow = Passage(text: "a", order: 0, score: 2.9)
    XCTAssertEqual(PassageRanker.ordered([other, leadBelow, best]).map(\.order), [3, 1, 0])
    // No question words: every score is 0, and the page keeps its order.
    let flat = [Passage(text: "a", order: 0), Passage(text: "b", order: 1), Passage(text: "c", order: 2)]
    XCTAssertEqual(PassageRanker.ordered(flat).map(\.order), [0, 1, 2])
  }

  func testUnsupportedLanguageFallsBackToLowercase() {
    XCTAssertFalse(PassageRanker.lemmas("東京の天気は晴れです").isEmpty)
    let pages = PassageRanker.score([[
      passage("今日の東京の天気は晴れです。", order: 0),
      passage("大阪の人口は多いです。", order: 1),
    ]], question: "東京の天気は？")
    XCTAssertGreaterThan(pages[0][0].score, pages[0][1].score)
    XCTAssertEqual(PassageRanker.lemmas("ÉCOLE Straße"), ["école", "straße"])
  }
}
