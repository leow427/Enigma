import Foundation
import XCTest
@testable import Enigma

final class IntentTrainingSupportTests: XCTestCase {
  func testBinaryAnswerUsesCutoff() {
    XCTAssertEqual(IntentSkill.search.answer(probabilities: ["yes": 0.6, "no": 0.4], cutoff: 0.5), "yes")
    XCTAssertEqual(IntentSkill.search.answer(probabilities: ["yes": 0.6, "no": 0.4], cutoff: 0.7), "no")
    XCTAssertEqual(IntentSkill.search.answer(probabilities: ["yes": 0.5, "no": 0.5], cutoff: 0.5), "yes")
  }

  func testSelectionAnswerPrefersTranslate() {
    let skill = IntentSkill.selection
    XCTAssertEqual(skill.answer(probabilities: ["edit": 0.5, "translate": 0.5, "none": 0], cutoff: 0.5), "translate")
    XCTAssertEqual(skill.answer(probabilities: ["edit": 0.8, "translate": 0.1, "none": 0.1], cutoff: 0.5), "edit")
    XCTAssertEqual(skill.answer(probabilities: ["edit": 0.3, "translate": 0.3, "none": 0.4], cutoff: 0.5), "none")
  }

  func testSkillsTable() {
    let expected: [(IntentSkill, [String], String, IntentSkill.Lean, String, Bool)] = [
      (.search, ["yes", "no"], "no", .none, "IntentSearch", true),
      (.messages, ["yes", "no"], "no", .off, "IntentMessages", true),
      (.think, ["yes", "no"], "no", .none, "IntentThink", true),
      (.selection, ["edit", "translate", "none"], "none", .off, "IntentSelection", true),
      (.coding, ["yes", "no"], "no", .off, "IntentCoding", false),
      (.reasoning, ["yes", "no"], "no", .off, "IntentReasoning", false),
    ]
    XCTAssertEqual(expected.map(\.0), IntentSkill.allCases)
    for (skill, labels, negative, lean, modelName, isChip) in expected {
      XCTAssertEqual(skill.labels, labels, "\(skill)")
      XCTAssertEqual(skill.negativeLabel, negative, "\(skill)")
      XCTAssertEqual(skill.lean, lean, "\(skill)")
      XCTAssertEqual(skill.modelName, modelName, "\(skill)")
      XCTAssertEqual(skill.isChip, isChip, "\(skill)")
    }
    XCTAssertEqual(IntentSkill.maximumWrongYesShare, 0.02)
  }

  func testParseExampleFile() throws {
    let good = """
      {"asOf": "2026-10-27"}
      {"text": "latest news", "label": "yes", "nearMiss": false}
      {"text": "write a poem", "label": "no", "why": "a transformation"}

      """
    let file = try IntentExampleFile.parse(Data(good.utf8), skill: .search)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    XCTAssertEqual(file.asOf, utc.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12)))
    XCTAssertEqual(file.examples, [
      IntentExample(text: "latest news", label: "yes", nearMiss: false),
      IntentExample(text: "write a poem", label: "no", why: "a transformation"),
    ])

    let badJSON = """
      {"asOf": "2026-10-27"}
      {"text": "latest news", "label": "yes"}
      {"text": "oops", "label":
      """
    XCTAssertThrowsError(try IntentExampleFile.parse(Data(badJSON.utf8), skill: .search)) { error in
      XCTAssertTrue(String(describing: error).contains("line 3"), String(describing: error))
    }

    let noAsOf = #"{"text": "latest news", "label": "yes"}"#
    XCTAssertThrowsError(try IntentExampleFile.parse(Data(noAsOf.utf8), skill: .search)) { error in
      XCTAssertTrue(String(describing: error).contains("line 1"), String(describing: error))
    }

    let crlf = "{\"asOf\": \"2026-10-27\"}\r\n{\"text\": \"latest news\", \"label\": \"yes\"}\r\n"
    XCTAssertEqual(try IntentExampleFile.parse(Data(crlf.utf8), skill: .search).examples,
                   [IntentExample(text: "latest news", label: "yes")])

    // JSON allows a raw line or paragraph separator inside a string; only \n and \r\n end a line.
    let separator = "{\"asOf\": \"2026-10-27\"}\n{\"text\": \"what\u{2028}is new\", \"label\": \"yes\"}\n"
    XCTAssertEqual(try IntentExampleFile.parse(Data(separator.utf8), skill: .search).examples.map(\.text),
                   ["what\u{2028}is new"])

    // The app removes a typed /think before any recognizer or model reads the draft.
    for typed in ["/think what's the temperature today?", "What happened yesterday? /THINK", "please /think\tnow"] {
      let line = "{\"asOf\": \"2026-10-27\"}\n" + String(data: try JSONEncoder().encode(IntentExample(text: typed, label: "yes")), encoding: .utf8)!
      XCTAssertThrowsError(try IntentExampleFile.parse(Data(line.utf8), skill: .search), typed) { error in
        XCTAssertTrue(String(describing: error).contains("line 2"), String(describing: error))
        XCTAssertTrue(String(describing: error).contains("/think"), String(describing: error))
      }
    }
    let notTyped = "{\"asOf\": \"2026-10-27\"}\n{\"text\": \"see src/think.swift\", \"label\": \"no\"}\n"
    XCTAssertNoThrow(try IntentExampleFile.parse(Data(notTyped.utf8), skill: .search))

    let badLabel = """
      {"asOf": "2026-10-27"}
      {"text": "latest news", "label": "maybe"}
      """
    XCTAssertThrowsError(try IntentExampleFile.parse(Data(badLabel.utf8), skill: .search)) { error in
      XCTAssertTrue(String(describing: error).contains("line 2"), String(describing: error))
    }
  }

  func testScoreCountsWrongYeses() {
    let score = IntentScore(answers: [("yes", "yes"), ("no", "yes"), ("yes", "no"), ("no", "no")], negativeLabel: "no")
    XCTAssertEqual(score.total, 4)
    XCTAssertEqual(score.correct, 2)
    XCTAssertEqual(score.accuracy, 0.5)
    XCTAssertEqual(score.yesCount, 2)
    XCTAssertEqual(score.wrongYes, 1)
    XCTAssertEqual(score.wrongYesShare, 0.5)

    let selection = IntentScore(answers: [("translate", "edit"), ("edit", "none"), ("edit", "edit")], negativeLabel: "none")
    XCTAssertEqual(selection.yesCount, 2)
    XCTAssertEqual(selection.wrongYes, 1)
    XCTAssertEqual(selection.correct, 1)

    let empty = IntentScore(answers: [], negativeLabel: "no")
    XCTAssertEqual(empty.accuracy, 0)
    XCTAssertEqual(empty.wrongYesShare, 0)
  }

  func testCutoffCandidates() {
    let candidates = IntentTrainingSupport.cutoffCandidates
    XCTAssertEqual(candidates.count, 91)
    XCTAssertEqual(candidates.first, 0.05)
    XCTAssertEqual(candidates.last, 0.95)
    XCTAssertTrue(candidates.contains(0.6))
  }

  func testChooseCutoffLeanNone() {
    // Yeses at 0.60 and noes at 0.59: only a cut-off of exactly 0.60 gets every answer right.
    let validation = Array(repeating: (expected: "yes", probabilities: ["yes": 0.60, "no": 0.40]), count: 5)
      + Array(repeating: (expected: "no", probabilities: ["yes": 0.59, "no": 0.41]), count: 5)
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .search, validation: validation), 0.60)
  }

  func testChooseCutoffLeanNoneTiesToTheMiddle() {
    // Every cut-off from 0.21 to 0.80 is fully right; 0.5 is nearest the middle.
    let validation = [(expected: "yes", probabilities: ["yes": 0.80, "no": 0.20]),
                      (expected: "no", probabilities: ["yes": 0.20, "no": 0.80])]
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .think, validation: validation), 0.5)
  }

  func testChooseCutoffLeanOff() {
    // Accuracy is highest at 0.40 and below, but those cut-offs say yes to the 0.74 noes.
    // 0.75 is the first cut-off with no wrong yeses, and above it no yes is right.
    let validation = Array(repeating: (expected: "yes", probabilities: ["yes": 0.75, "no": 0.25]), count: 10)
      + Array(repeating: (expected: "no", probabilities: ["yes": 0.74, "no": 0.26]), count: 3)
      + Array(repeating: (expected: "yes", probabilities: ["yes": 0.40, "no": 0.60]), count: 5)
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .messages, validation: validation), 0.75)
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .search, validation: validation), 0.40)

    // A wrong yes ranked above every right one: no cut-off says yes with at most 2% wrong.
    let hopeless = [(expected: "no", probabilities: ["yes": 0.99, "no": 0.01]),
                    (expected: "yes", probabilities: ["yes": 0.98, "no": 0.02])]
    XCTAssertNil(IntentTrainingSupport.chooseCutoff(for: .messages, validation: hopeless))

    // Cut-offs above 0.90 say yes to nothing, so they have no wrong yeses, but they don't qualify either.
    let neverRight = [(expected: "no", probabilities: ["yes": 0.90, "no": 0.10]),
                      (expected: "yes", probabilities: ["yes": 0.80, "no": 0.20])]
    XCTAssertNil(IntentTrainingSupport.chooseCutoff(for: .messages, validation: neverRight))
  }

  func testChooseCutoffLeanOffAllowsExactlyTwoPercent() {
    // 1 wrong yes in 50 is exactly 2% and qualifies; 1 in 49 is over it, and nothing else says yes.
    let wrong = (expected: "no", probabilities: ["yes": 0.90, "no": 0.10])
    let right = (expected: "yes", probabilities: ["yes": 0.90, "no": 0.10])
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .messages, validation: [wrong] + Array(repeating: right, count: 49)), 0.90)
    XCTAssertNil(IntentTrainingSupport.chooseCutoff(for: .messages, validation: [wrong] + Array(repeating: right, count: 48)))
  }

  func testChooseCutoffLeanOffForSelection() {
    let validation = [(expected: "translate", probabilities: ["edit": 0.1, "translate": 0.9, "none": 0.0]),
                      (expected: "none", probabilities: ["edit": 0.7, "translate": 0.1, "none": 0.2]),
                      (expected: "edit", probabilities: ["edit": 0.8, "translate": 0.1, "none": 0.1])]
    // Cut-offs up to 0.70 wrongly edit the "none" draft; 0.71...0.80 get all three right.
    XCTAssertEqual(IntentTrainingSupport.chooseCutoff(for: .selection, validation: validation), 0.80)
  }

  func testValidationSplitIsStable() {
    XCTAssertEqual(IntentTrainingSupport.isValidation("What's new?"), IntentTrainingSupport.isValidation("What's new?"))
    XCTAssertEqual(IntentTrainingSupport.isValidation("What's new?"), IntentTrainingSupport.isValidation("whats   new?"))
    // Known members. The split hashes the cleaned text: its first byte is 45 for the first
    // and 76 for the second; hashing the raw text would give 149 and 195.
    XCTAssertTrue(IntentTrainingSupport.isValidation(Self.validationText))
    XCTAssertFalse(IntentTrainingSupport.isValidation(Self.trainingText))
    let share = Double((0..<1_000).filter { IntentTrainingSupport.isValidation("example draft number \($0)") }.count) / 1_000
    XCTAssertGreaterThanOrEqual(share, 0.15)
    XCTAssertLessThanOrEqual(share, 0.25)
  }

  func testOverlapsUseCleanedText() {
    let first = [IntentExample(text: "What's new?", label: "yes"), IntentExample(text: "write a poem", label: "no")]
    let second = [IntentExample(text: "whats   new?", label: "yes"), IntentExample(text: "tell a joke", label: "no")]
    XCTAssertEqual(IntentTrainingSupport.overlaps(first, second), ["what's new?"])
    XCTAssertEqual(IntentTrainingSupport.overlaps(first, []), [])
  }

  func testFingerprintIsSHA256Hex() {
    XCTAssertEqual(IntentTrainingSupport.fingerprint(Data("abc".utf8)),
                   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  private static let validationText = "Example Draft Number 10"
  private static let trainingText = "Example Draft Number 57"
}
