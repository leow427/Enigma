import Foundation
import XCTest
@testable import Enigma

final class IntentTextTests: XCTestCase {
  func testCleanMatchesTodaysQuestionText() {
    let cases = [
      ("What's   the\nWeather?", "what's the weather?"),
      ("whats new", "what's new"),
      ("Don’t search", "don't search"),
      ("  Hello  ", "hello"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(IntentText.clean(input), expected, input)
      XCTAssertEqual(WebSearchPolicy.questionText(input), IntentText.clean(input), input)
    }
  }

  func testCleanRemovesLiteralMaterial() {
    let cases = [
      (#"what does "text Alex" mean"#, "what does mean"),
      ("`message Sam` is a command", "is a command"),
      ("```swift\nsearch the web\n``` explain", "explain"),
      ("“text me back” lyrics", "lyrics"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(IntentText.clean(input), expected, input)
    }
  }

  func testQuestionTextStillRemovesThink() {
    XCTAssertEqual(WebSearchPolicy.questionText("/think What's new"), "what's new")
  }

  func testYearsBecomeWordsRelativeToNow() {
    let now = Date(timeIntervalSince1970: 1_781_524_800) // 2026-06-15 12:00 UTC
    let cases = [
      ("election results 2024", "election results yearpast"),
      ("2025 2026 2027", "yearrecent yearrecent yearrecent"),
      ("plans for 2028", "plans for yearfuture"),
      ("in 1999", "in yearpast"),
      ("from 1000 to 2999", "from yearpast to yearfuture"),
      ("v2024 in the 1990s", "vyearpast in the yearpasts"),
      ("12345 and 3000 and 0999", "12345 and 3000 and 0999"),
    ]
    for (input, expected) in cases {
      XCTAssertEqual(IntentText.modelInput(input, now: now), expected, input)
    }
  }

  func testLongInputKeepsBothEnds() {
    let input = "start " + String(repeating: "x", count: 2_000) + " end"
    let result = IntentText.modelInput(input, now: Date())
    XCTAssertEqual(result.count, 1_001)
    XCTAssertEqual(String(result.prefix(500)), String(input.prefix(500)))
    XCTAssertEqual(String(result.suffix(500)), String(input.suffix(500)))
  }

  func testModelInputLeavesShortTextAlone() {
    let input = String(repeating: "word ", count: 200)
    XCTAssertEqual(input.count, 1_000)
    XCTAssertEqual(IntentText.modelInput(input, now: Date()), input)
  }

  func testManyYearsInALongNonASCIIDraftStayFast() {
    // Each replacement used to rebuild the string's UTF-16 index: 1.5 s for this draft.
    let input = String(repeating: "2024 ", count: 16_000) + "é"
    let start = Date()
    let result = IntentText.modelInput(input, now: Date(timeIntervalSince1970: 1_781_524_800))
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    XCTAssertTrue(result.hasPrefix("yearpast yearpast "))
    XCTAssertTrue(result.hasSuffix("yearpast é"))
    XCTAssertEqual(result.count, 1_001)
  }
}
