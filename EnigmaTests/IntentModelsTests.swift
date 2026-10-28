import CoreML
import Foundation
import NaturalLanguage
import XCTest
@testable import Enigma

final class IntentModelsTests: XCTestCase {
  private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Fixtures/IntentModels")
  private var compiledModels: URL!
  private var emptyFolder: URL!

  override func setUp() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: "IntentModelsTests-\(UUID().uuidString)")
    compiledModels = temporary.appending(path: "compiled")
    emptyFolder = temporary.appending(path: "empty")
    try FileManager.default.createDirectory(at: compiledModels, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    try await compileFixture(.search)
  }

  /// Compiles a fixture model into `compiledModels`; false when the fixture doesn't exist.
  @discardableResult
  private func compileFixture(_ skill: IntentSkill) async throws -> Bool {
    let source = Self.fixtures.appending(path: "\(skill.modelName).mlmodel")
    guard FileManager.default.fileExists(atPath: source.path) else { return false }
    let compiled = try await MLModel.compileModel(at: source)
    try FileManager.default.moveItem(at: compiled, to: compiledModels.appending(path: "\(skill.modelName).mlmodelc"))
    return true
  }

  override func tearDownWithError() throws {
    if let compiledModels {
      try? FileManager.default.removeItem(at: compiledModels.deletingLastPathComponent())
    }
  }

  func testLoadsFixtureModelAndMetadata() throws {
    let models = IntentModels(compiledModelsIn: compiledModels)
    let info = try XCTUnwrap(models.info(.search))
    XCTAssertEqual(info.kind, "maxEnt")
    XCTAssertGreaterThanOrEqual(info.cutoff, 0.05)
    XCTAssertLessThanOrEqual(info.cutoff, 0.95)
    XCTAssertEqual(info.asOf, "2026-10-27")
    let training = try Data(contentsOf: Self.fixtures.appending(path: "search/train.jsonl"))
    XCTAssertEqual(info.trainingFingerprint, IntentTrainingSupport.fingerprint(training))
    let report = try JSONSerialization.jsonObject(
      with: Data(contentsOf: Self.fixtures.appending(path: "search/report.json"))) as? [String: Any]
    XCTAssertEqual(info.cutoff, report?["cutoff"] as? Double)
  }

  func testAnswerUsesTheRecordedCutoff() throws {
    let models = IntentModels(compiledModelsIn: compiledModels)
    let cutoff = try XCTUnwrap(models.info(.search)?.cutoff)
    XCTAssertNotEqual(cutoff, 0.5, "The fixture's cut-off must differ from 0.5 for this test to mean anything")
    let training = try IntentExampleFile.parse(
      Data(contentsOf: Self.fixtures.appending(path: "search/train.jsonl")), skill: .search)
    let drafts = training.examples.map { IntentText.clean($0.text) }
    let now = Date(timeIntervalSince1970: 1_781_524_800)
    // A draft whose yes-probability lies between 0.5 and the cut-off tells the two apart.
    let between = drafts.first { draft in
      let yes = models.probabilities(.search, for: IntentText.modelInput(draft, now: now))?["yes"] ?? 0
      return yes >= min(0.5, cutoff) && yes < max(0.5, cutoff)
    }
    let draft = try XCTUnwrap(between, "No fixture draft lies between 0.5 and the cut-off")
    XCTAssertEqual(models.answer(.search, cleaned: draft, now: now), cutoff > 0.5 ? "no" : "yes", draft)
  }

  func testFixtureModelAnswers() {
    let models = IntentModels(compiledModelsIn: compiledModels)
    XCTAssertEqual(models.answer(.search, cleaned: "latest news about the election"), "yes")
    XCTAssertEqual(models.answer(.search, cleaned: "write a poem about the sea"), "no")
    let probabilities = models.probabilities(.search, for: "latest news about the election")
    XCTAssertEqual(Set(probabilities?.keys.map { $0 } ?? []), ["yes", "no"])
  }

  func testMissingModelAnswersNegative() {
    let models = IntentModels(compiledModelsIn: emptyFolder)
    XCTAssertNil(models.info(.messages))
    XCTAssertNil(models.probabilities(.messages, for: "text mom"))
    XCTAssertEqual(models.answer(.messages, cleaned: "text mom"), "no")
    XCTAssertEqual(models.answer(.selection, cleaned: "translate this"), "none")
    // Asking again after the failed load still answers, without retrying (and logging) again.
    XCTAssertEqual(models.answer(.messages, cleaned: "text mom"), "no")
    XCTAssertEqual(models.loadAttempts(.messages), 1)
    XCTAssertEqual(models.loadAttempts(.think), 0)
  }

  func testModelLoadsOnce() {
    let models = IntentModels(compiledModelsIn: compiledModels)
    DispatchQueue.concurrentPerform(iterations: 50) { _ in
      _ = models.answer(.search, cleaned: "latest news about the election")
    }
    XCTAssertNotNil(models.info(.search))
    XCTAssertEqual(models.loadAttempts(.search), 1)
  }

  func testDamagedModelAnswersNegative() throws {
    let damaged = emptyFolder.appending(path: "\(IntentSkill.search.modelName).mlmodelc")
    try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
    try Data("not a model".utf8).write(to: damaged.appending(path: "model.mil"))
    let models = IntentModels(compiledModelsIn: emptyFolder)
    XCTAssertNil(models.info(.search))
    XCTAssertEqual(models.answer(.search, cleaned: "latest news about the election"), "no")
  }

  func testMetadataNeedsEveryKey() {
    let full = ["enigma.cutoff": "0.66", "enigma.kind": "maxEnt", "enigma.fingerprint": "abc", "enigma.asOf": "2026-10-27"]
    XCTAssertEqual(IntentModelInfo(metadata: full),
                   IntentModelInfo(cutoff: 0.66, kind: "maxEnt", trainingFingerprint: "abc", asOf: "2026-10-27"))
    for key in full.keys {
      var missing = full
      missing[key] = nil
      XCTAssertNil(IntentModelInfo(metadata: missing), key)
    }
    for cutoff in ["high", "nan", "inf", "1.5", "-0.1"] {
      var unreadable = full
      unreadable["enigma.cutoff"] = cutoff
      XCTAssertNil(IntentModelInfo(metadata: unreadable), cutoff)
    }
  }

  func testPinsApplyWithoutAModel() {
    let pins = IntentPins([.messages: [(#"^check my texts$"#, "yes")]])
    let models = IntentModels(compiledModelsIn: emptyFolder, pins: pins)
    XCTAssertEqual(models.answer(.messages, cleaned: "check my texts"), "yes")
    XCTAssertEqual(models.answer(.messages, cleaned: "check my texts later"), "no")
    XCTAssertEqual(pins.count(.messages), 1)
    XCTAssertEqual(pins.count(.search), 0)
  }

  func testPinsWinOverTheModelInOrder() {
    let pins = IntentPins([.search: [(#"\bpoem\b"#, "yes"), (#"\bsea\b"#, "no"), (#"news"#, "no")]])
    let models = IntentModels(compiledModelsIn: compiledModels, pins: pins)
    XCTAssertEqual(models.answer(.search, cleaned: "write a poem about the sea"), "yes")
    XCTAssertEqual(models.answer(.search, cleaned: "latest news about the election"), "no")
    XCTAssertEqual(pins.answer(.search, cleaned: "a song about the sea"), "no")
    XCTAssertNil(pins.answer(.search, cleaned: "what is the weather"))
  }

  func testEmptyTextAnswersNegativeWithoutAModel() {
    let models = IntentModels(compiledModelsIn: compiledModels, pins: IntentPins([.search: [("^$", "yes")]]))
    XCTAssertEqual(models.answer(.search, cleaned: ""), "no")
    XCTAssertEqual(models.answer(.selection, cleaned: ""), "none")
    XCTAssertEqual(models.loadAttempts(.search), 0)
    XCTAssertEqual(models.loadAttempts(.selection), 0)
  }

  func testEmojiAndNonEnglishDraftsAnswer() {
    let models = IntentModels(compiledModelsIn: compiledModels)
    for draft in ["🎉🎉", "¿dónde está la biblioteca?"] {
      XCTAssertTrue(["yes", "no"].contains(models.answer(.search, cleaned: draft)), draft)
    }
  }

  func testUsesTheModelInputForYears() throws {
    // The app passes cleaned text; the model must see the same year words the script trained on.
    let models = IntentModels(compiledModelsIn: compiledModels)
    let now = Date(timeIntervalSince1970: 1_781_524_800) // 2026-06-15 12:00 UTC
    let cutoff = try XCTUnwrap(models.info(.search)?.cutoff)
    let raw = try XCTUnwrap(models.probabilities(.search, for: "in 2026")?["yes"])
    let words = try XCTUnwrap(models.probabilities(.search, for: "in yearrecent")?["yes"])
    // The fixture must answer the two inputs differently, or this test can't tell them apart.
    XCTAssertLessThan(raw, cutoff)
    XCTAssertGreaterThanOrEqual(words, cutoff)
    XCTAssertEqual(models.answer(.search, cleaned: "in 2026", now: now), "yes")
  }

  func testConcurrentAnswersAgree() {
    let models = IntentModels(compiledModelsIn: compiledModels)
    let expected = models.answer(.search, cleaned: "latest news about the election")
    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      XCTAssertEqual(models.answer(.search, cleaned: "latest news about the election"), expected)
    }
  }

  func testShippedPinsStayWithinLimit() {
    XCTAssertEqual(IntentPins.maximumPerSkill, 20)
    for skill in IntentSkill.allCases {
      XCTAssertLessThanOrEqual(IntentPins.shipped.count(skill), IntentPins.maximumPerSkill, "\(skill)")
    }
  }

  func testBERTFixturePredictsOffline() async throws {
    guard NLContextualEmbedding(language: .english)?.hasAvailableAssets == true else {
      throw XCTSkip("The English contextual embedding's assets aren't on this Mac")
    }
    // Compiled here, not in setUp, so a BERT problem fails only this test.
    guard try await compileFixture(.think) else { throw XCTSkip("No BERT fixture") }
    let models = IntentModels(compiledModelsIn: compiledModels)
    XCTAssertEqual(models.info(.think)?.kind, "bert")
    XCTAssertNotNil(models.probabilities(.think, for: "think hard about this"))
  }
}
