import XCTest
@testable import Enigma

/// F35's live checks on this Mac's installed models. They skip unless `ENIGMA_F35_LIVE=1` reaches
/// the test host (`TEST_RUNNER_ENIGMA_F35_LIVE=1`). They read the installed library without
/// changing the selected model, and print sizes, counts and timings only, never answer text.
@MainActor
final class F35LiveTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ProcessInfo.processInfo.environment["ENIGMA_F35_LIVE"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_F35_LIVE=1 to run F35's live checks on the installed models.")
    }
  }

  /// CP1: a local model at 8K answers a question that searches several times.
  func testLocal8KModelSearchesSeveralTimesThenAnswers() async throws {
    let id = ProcessInfo.processInfo.environment["ENIGMA_F35_SEARCH_MODEL"] ?? "gemma-4-12b-q5_k_m"
    let model = try XCTUnwrap(LocalModelInstallationStore(contextWindow: { _ in 8_192 }).installedModels()
      .first { $0.id == id }, "\(id) isn't installed")
    XCTAssertEqual(model.contextWindow, 8_192)
    let engine = LlamaServerVisionEngine()
    let provider = OnDeviceSearchProvider.live(offline: false)
    let budget = ToolStepBudget()
    let searches = Counter()
    let tool = WebSearchTool(search: { query, recency, maximumTokens in
      await searches.add(room: budget.roomLeft, asked: maximumTokens)
      return try await provider.search(WebSearchRequest(query: query, recency: recency, maximumTokens: maximumTokens))
    }, evidenceCap: ToolStepBudget.localEvidenceTokens, stepBudget: budget, mayQuery: { _ in true }, onSources: { _ in })
    let question = "Compare the current populations of Tokyo, Delhi, Shanghai, São Paulo and Mexico City. "
      + "Search for each city separately, then give one number for each."
    let started = ContinuousClock.now
    let reply = NativeToolsEval.Reply()
    let prepared = try LocalToolAgent.prepare([ChatMessage(role: .user, content: question)], model: model, toolbox: tool)
    try await NativeToolsEval.withTimeout(.seconds(600)) {
      try await LocalToolAgent(inference: engine).runStreaming(messages: prepared.messages, model: model, toolbox: tool,
                                                               onActivity: { _ in }, onText: { reply.append($0) })
    }
    await engine.unload()
    let calls = await searches.calls
    print("LIVE F35 CP1 model=\(id) ctx=\(model.contextWindow) searches=\(calls.count)",
          "room/asked=\(calls.map { "\($0.room)/\($0.asked)" }.joined(separator: ","))",
          "replyChars=\(reply.text.count) s=\(started.duration(to: .now).components.seconds)")
    XCTAssertGreaterThanOrEqual(calls.count, 2, "The question should search more than once")
    XCTAssertFalse(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "The turn ends with an answer")
  }

  /// CP2: every installed catalogue model's server starts at the size chosen for this Mac and answers.
  func testEachInstalledModelStartsAtItsChosenSizeAndAnswers() async throws {
    let store = LocalModelInstallationStore(modelsDirectory: nil)
    let hardware = LocalHardwareProfile.detect(modelsDirectory: store.modelsDirectoryURL)
    // The app's own choice: the saved preset and Use It answers, which the test host shares.
    let preference = LocalContextWindowPreference.saved(in: .standard)
    let accepted = UserDefaults.standard.string(forKey: LocalContextWindowPreference.acceptedKey) ?? ""
    let models = LocalModelInstallationStore(contextWindow: { descriptor in
      LocalContextWindowChoice.runtimeSize(for: descriptor, preference: preference, accepted: accepted, hardware: hardware)
    }).installedModels().filter { $0.catalogDescriptor != nil }
    XCTAssertFalse(models.isEmpty, "No catalogue model is installed")
    for model in models {
      let descriptor = try XCTUnwrap(model.catalogDescriptor)
      let chosen = LocalContextWindowChoice.runtimeSize(for: descriptor, preference: preference, accepted: accepted,
                                                        hardware: hardware)
      XCTAssertEqual(model.contextWindow, chosen, model.id)
      let arguments = try LlamaServerVisionEngine.arguments(model: model, port: 1, key: "k", alias: "a")
      XCTAssertEqual(arguments.drop { $0 != "--ctx-size" }.dropFirst().first, String(chosen), model.id)
      let engine = LlamaServerVisionEngine()
      let started = ContinuousClock.now
      let reply = NativeToolsEval.Reply()
      do {
        let messages = [ChatMessage(role: .user, content: "Name three primary colors, in one short sentence.")]
        let prepared = try await engine.prepare(messages: messages, image: nil, model: model)
        try await NativeToolsEval.withTimeout(.seconds(300)) {
          for try await text in engine.stream(messages: prepared.messages, image: nil, model: model) { reply.append(text) }
        }
      } catch {
        XCTFail("\(model.id): \(error.localizedDescription)")
      }
      await engine.unload()
      let memory = LocalContextWindowChoice.memory(descriptor, size: chosen).map { $0 / 1_000_000 } ?? -1
      print("LIVE F35 CP2 model=\(model.id) preference=\(preference.rawValue) ctx=\(chosen) estimateMB=\(memory)",
            "budgetMB=\(hardware.inferenceMemoryBudget / 1_000_000) replyChars=\(reply.text.count)",
            "s=\(started.duration(to: .now).components.seconds)")
      XCTAssertFalse(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(model.id) answers")
    }
  }
}

private actor Counter {
  private(set) var calls: [(room: Int, asked: Int)] = []
  func add(room: Int, asked: Int) { calls.append((room, asked)) }
}
