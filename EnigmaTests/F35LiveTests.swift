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

  /// CP3: a local model at 8K compacts a chat that no longer fits, then answers a follow-up that
  /// needs facts from its oldest turns.
  func testLocal8KModelCompactsALongChatAndStillRecallsIt() async throws {
    let id = ProcessInfo.processInfo.environment["ENIGMA_F35_SEARCH_MODEL"] ?? "gemma-4-12b-q5_k_m"
    let model = try XCTUnwrap(LocalModelInstallationStore(contextWindow: { _ in 8_192 }).installedModels()
      .first { $0.id == id }, "\(id) isn't installed")
    let engine = LlamaServerVisionEngine()
    let prepare = { (messages: [ChatMessage]) in try await engine.prepare(messages: messages, image: nil, model: model) }
    do {
      try await Self.compactAndAsk(label: "local model=\(id) ctx=\(model.contextWindow)", force: false, prepare: prepare) { messages in
        engine.stream(messages: messages, image: nil, model: model, temperature: 0.2)
      }
    } catch {
      await engine.unload()
      throw error
    }
    await engine.unload()
  }

  /// CP3: `/compact` on ChatGPT through Codex, then the same follow-up.
  func testCodexCompactsAChatAndStillRecallsIt() async throws {
    let modelID = ProcessInfo.processInfo.environment["ENIGMA_F35_CODEX_MODEL"] ?? CodexSubscriptionClient.defaultModelID
    let route = Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: modelID, usesNetwork: true)
    let client = CodexSubscriptionClient.live
    let prepare = { (messages: [ChatMessage]) in
      try CloudContext.prepare(ChatRequest(sessionID: UUID(), messages: messages, route: route))
    }
    try await Self.compactAndAsk(label: "codex model=\(modelID)", force: true, prepare: prepare) { messages in
      client.textStream(ChatRequest(sessionID: UUID(), messages: messages, route: route))
    }
  }

  /// A trip-planning chat with three facts in its older turns and long replies between them,
  /// past an 8K model's input budget.
  private static func plannedChat() -> [ChatMessage] {
    let filler = String(repeating: "The old town has steep streets, tiled facades, small bakeries and viewpoints over the river. ", count: 45)
    var chat: [ChatMessage] = [
      ChatMessage(role: .user, content: "I'm planning a trip to Lisbon in May with my sister Ana. Our budget is 2,400 euros for the week."),
      ChatMessage(role: .assistant, content: "Lisbon in May is a lovely choice. " + filler),
    ]
    for day in 1...9 {
      chat.append(ChatMessage(role: .user, content: day == 4
        ? "One more thing to remember: I'm allergic to shellfish, so keep restaurant ideas free of it."
        : "What could we do on day \(day)? Give me a few ideas with rough costs."))
      chat.append(ChatMessage(role: .assistant, content: "For day \(day), here are some ideas. " + filler))
    }
    return chat
  }

  private static let question = "Remind me in one sentence: who am I travelling with, what is our budget, and what am I allergic to?"

  /// Compacts `plannedChat()` with the route's own preparation and model, then asks `question`.
  /// Prints sizes, counts, recall flags and timings only.
  private static func compactAndAsk(label: String, force: Bool,
                                    prepare: @escaping ([ChatMessage]) async throws -> PreparedConversation,
                                    stream: @escaping ([ChatMessage]) -> AsyncThrowingStream<String, Error>) async throws {
    let chat = plannedChat() + [ChatMessage(role: .user, content: question)]
    let chunks = Counter()
    let started = ContinuousClock.now
    let compacted = try await ChatCompactor().compact(chat, existing: nil, force: force, prepare: prepare) { messages, existing in
      await chunks.add(room: messages.count, asked: 0)
      let request = try await prepare([ChatCompactor.summaryRequest(messages, existing: existing)])
      var notes = ""
      for try await text in stream(request.messages) { notes += text }
      return notes
    }
    let summarized = ContinuousClock.now
    var answer = ""
    for try await text in stream(compacted.prepared.messages) { answer += text }
    answer = answer.lowercased()
    let recalled = (ana: answer.contains("ana"), budget: answer.contains("2,400") || answer.contains("2400") || answer.contains("2 400"),
                    allergy: answer.contains("shellfish"))
    let summary = compacted.newSummary
    print("LIVE F35 CP3 \(label) tier=\(compacted.tier) chunks=\(await chunks.calls.count)",
          "chatChars=\(chat.reduce(0) { $0 + $1.content.count }) usageAfter=\(Int(compacted.prepared.usage.fraction * 100))%",
          "notesWords=\(summary?.text.split(whereSeparator: \.isWhitespace).count ?? 0)",
          "recentMessages=\(summary?.recentMessages?.count ?? 0) omitted=\(compacted.prepared.omittedMessageCount)",
          "recalled ana=\(recalled.ana) budget=\(recalled.budget) allergy=\(recalled.allergy)",
          "summarizeS=\(started.duration(to: summarized).components.seconds) answerS=\(summarized.duration(to: .now).components.seconds)")
    XCTAssertEqual(compacted.tier, .summarized)
    XCTAssertTrue(recalled.ana && recalled.budget && recalled.allergy, "The follow-up recalls the planted facts")
  }
}

private actor Counter {
  private(set) var calls: [(room: Int, asked: Int)] = []
  func add(room: Int, asked: Int) { calls.append((room, asked)) }
}
