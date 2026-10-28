import Foundation
import XCTest
@testable import Enigma

/// Reads IntentTraining/ through #filePath.
enum IntentExamples {
  static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "IntentTraining")

  /// `name` is "train", "test" or "must-pass".
  static func url(_ skill: IntentSkill, _ name: String) -> URL {
    folder.appending(path: "\(skill.rawValue)/\(name).jsonl")
  }

  static func file(_ skill: IntentSkill, _ name: String) throws -> IntentExampleFile {
    try IntentExampleFile.parse(Data(contentsOf: url(skill, name)), skill: skill)
  }

  /// floors.json: the score floor of each skill that has switched to its model.
  static func floors() throws -> [IntentSkill: Double] {
    let data = try Data(contentsOf: folder.appending(path: "floors.json"))
    let object = try JSONDecoder().decode([String: Double].self, from: data)
    return try Dictionary(uniqueKeysWithValues: object.map { name, floor in
      guard let skill = IntentSkill(rawValue: name) else {
        throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "unknown skill \(name)"])
      }
      return (skill, floor)
    })
  }

  /// baseline.json: today's rules scored on each test set.
  static func baseline() throws -> [IntentSkill: Baseline] {
    let data = try Data(contentsOf: folder.appending(path: "baseline.json"))
    let object = try JSONDecoder().decode([String: Baseline].self, from: data)
    return try Dictionary(uniqueKeysWithValues: object.map { name, baseline in
      guard let skill = IntentSkill(rawValue: name) else {
        throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "unknown skill \(name)"])
      }
      return (skill, baseline)
    })
  }

  struct Baseline: Decodable {
    let accuracy: Double
    let wrongYesShare: Double
    let total: Int
    let mustPassFailures: Int
  }

  /// The app's end-to-end answer for a raw draft.
  static func appAnswer(_ skill: IntentSkill, text: String, asOf: Date) -> String {
    switch skill {
    case .search:
      return WebSearchPolicy.needsFreshInformation(text, now: asOf) ? "yes" : "no"
    case .messages:
      return MessagesIntentPolicy.isRequested(text) ? "yes" : "no"
    case .think:
      return ThinkCommand.isRequested(by: text) ? "yes" : "no"
    case .selection:
      switch SelectionIntentPolicy.command(for: text) {
      case .edit: return "edit"
      case .translate: return "translate"
      default: return "none"
      }
    case .coding:
      return AutoRouter.requiresCoding(text) ? "yes" : "no"
    case .reasoning:
      return AutoRouter.requiresAdvancedReasoning(text) ? "yes" : "no"
    }
  }

  static func score(_ skill: IntentSkill, _ file: IntentExampleFile) -> IntentScore {
    IntentScore(answers: file.examples.map {
      (expected: $0.label, actual: appAnswer(skill, text: $0.text, asOf: file.asOf))
    }, negativeLabel: skill.negativeLabel)
  }

  static func mustPassFailures(_ skill: IntentSkill, _ file: IntentExampleFile) -> [IntentExample] {
    file.examples.filter { appAnswer(skill, text: $0.text, asOf: file.asOf) != $0.label }
  }
}

/// Every skill's example files, and the end-to-end scores of the skills that use a model.
final class IntentScoreTests: XCTestCase {
  func testExampleFilesMeetSizes() throws {
    for skill in IntentSkill.allCases {
      let training = try IntentExamples.file(skill, "train").examples
      XCTAssertGreaterThanOrEqual(training.count, skill == .search ? 1_400 : 800, skill.rawValue)
      let negatives = training.filter { $0.label == skill.negativeLabel }
      let nearMisses = negatives.filter { $0.nearMiss == true }
      XCTAssertGreaterThanOrEqual(Double(nearMisses.count), 0.4 * Double(negatives.count), skill.rawValue)
      XCTAssertGreaterThanOrEqual(try IntentExamples.file(skill, "test").examples.count, 200, skill.rawValue)
      XCTAssertGreaterThanOrEqual(try IntentExamples.file(skill, "must-pass").examples.count, 25, skill.rawValue)
    }
  }

  func testHeldOutExamplesDontOverlapTraining() throws {
    for skill in IntentSkill.allCases {
      let training = try IntentExamples.file(skill, "train").examples
      let test = try IntentExamples.file(skill, "test").examples
      let mustPass = try IntentExamples.file(skill, "must-pass").examples
      XCTAssertEqual(IntentTrainingSupport.overlaps(training, test), [], "\(skill.rawValue) train.jsonl overlaps test.jsonl")
      XCTAssertEqual(IntentTrainingSupport.overlaps(training, mustPass), [],
                     "\(skill.rawValue) train.jsonl overlaps must-pass.jsonl")
      XCTAssertEqual(IntentTrainingSupport.overlaps(test, mustPass), [], "\(skill.rawValue) test.jsonl overlaps must-pass.jsonl")
    }
  }

  /// Writes <folder>/<skill>.json with today's end-to-end scores when ENIGMA_INTENT_REPORT names a folder.
  func testWriteScoreReport() throws {
    guard let path = ProcessInfo.processInfo.environment["ENIGMA_INTENT_REPORT"], !path.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_INTENT_REPORT to a folder to write the score report")
    }
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for skill in IntentSkill.allCases {
      let score = IntentExamples.score(skill, try IntentExamples.file(skill, "test"))
      let failures = IntentExamples.mustPassFailures(skill, try IntentExamples.file(skill, "must-pass"))
      let report = ScoreReport(score: score, accuracy: score.accuracy, wrongYesShare: score.wrongYesShare,
                               mustPassFailures: failures.map(\.text))
      try encoder.encode(report).write(to: folder.appending(path: "\(skill.rawValue).json"))
    }
  }

  /// Skills still on their rules must score exactly what baseline.json records, so a later checkpoint
  /// compares its model with numbers that describe today's rules.
  func testRulesMatchTheBaseline() throws {
    let baseline = try IntentExamples.baseline()
    let floors = try IntentExamples.floors()
    for skill in IntentSkill.allCases where floors[skill] == nil {
      let recorded = try XCTUnwrap(baseline[skill], "baseline.json has no \(skill.rawValue)")
      let score = IntentExamples.score(skill, try IntentExamples.file(skill, "test"))
      let failures = IntentExamples.mustPassFailures(skill, try IntentExamples.file(skill, "must-pass"))
      XCTAssertEqual(score.total, recorded.total, skill.rawValue)
      XCTAssertEqual(score.accuracy, recorded.accuracy, accuracy: 0.00005, skill.rawValue)
      XCTAssertEqual(score.wrongYesShare, recorded.wrongYesShare, accuracy: 0.00005, skill.rawValue)
      XCTAssertEqual(failures.count, recorded.mustPassFailures, skill.rawValue)
    }
  }

  func testSwitchedSkillsMeetFloors() throws {
    for (skill, floor) in try IntentExamples.floors() {
      let score = IntentExamples.score(skill, try IntentExamples.file(skill, "test"))
      XCTAssertGreaterThanOrEqual(score.accuracy, floor, skill.rawValue)
    }
  }

  func testSwitchedSkillsPassMustPass() throws {
    for skill in try IntentExamples.floors().keys {
      let failures = IntentExamples.mustPassFailures(skill, try IntentExamples.file(skill, "must-pass"))
      XCTAssertEqual(failures.map(\.text), [], skill.rawValue)
    }
  }

  func testSwitchedModelsMatchTrainingData() throws {
    for skill in try IntentExamples.floors().keys {
      let training = try Data(contentsOf: IntentExamples.url(skill, "train"))
      XCTAssertEqual(IntentModels.shared.info(skill)?.trainingFingerprint, IntentTrainingSupport.fingerprint(training),
                     "Retrain \(skill.rawValue) with scripts/train-intent-models.sh")
    }
  }

  private struct ScoreReport: Encodable {
    let score: IntentScore
    let accuracy: Double
    let wrongYesShare: Double
    let mustPassFailures: [String]
  }
}
