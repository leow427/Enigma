import XCTest
@testable import Enigma

/// F30 CP6's comparison of provider search with Enigma's `web_search` on Brave, on the owner's
/// Mac, never in CI. `testCompare` skips unless `TEST_RUNNER_ENIGMA_SEARCH_EVAL` names a folder
/// outside the repository and `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1` is set. Each question in
/// `scripts/web-search-queries.json` runs in a new chat on each route in
/// `TEST_RUNNER_ENIGMA_SEARCH_EVAL_ROUTES` (default: every provider in
/// `CloudProviderID.nativeWebSearchProviders`): once with the provider's own search, and once
/// with Brave when `TEST_RUNNER_ENIGMA_BRAVE_KEY` holds a key (never the Keychain). Each run is
/// written to `<folder>/<route>/<backend>/<id>.json` for `scripts/evaluate-native-search.py`.
@MainActor
final class NativeWebSearchEvaluationTests: XCTestCase {
  func testQuestionSetIsWellFormed() throws {
    let questions = try NativeSearchEvaluation.questions()
    XCTAssertEqual(questions.map(\.id), (1...20).map { String(format: "web-%02d", $0) })
    let counts = Dictionary(grouping: questions, by: \.category).mapValues(\.count)
    XCTAssertEqual(counts, ["news": 4, "facts": 4, "docs": 4, "health-finance": 3, "reviews": 2, "encyclopedic": 3])
    // CP0's five latency questions are among them.
    for question in ["What are the top technology news headlines today?", "current US federal funds target rate range",
                     "the `strict` parameter of `zip()`", "Sony WH-1000XM6", "next total solar eclipse visible from Europe"] {
      XCTAssertTrue(questions.contains { $0.question.contains(question) }, question)
    }
    for question in questions {
      XCTAssertNil(question.question.range(of: #"https?://|@|\bnear me\b"#, options: [.regularExpression, .caseInsensitive]),
                   "\(question.id) is a fixed, non-personal web question")
    }
  }

  /// The run record's keys are what `scripts/evaluate-native-search.py` reads. A nil error or first
  /// text time is left out, and the script reads both as optional.
  func testRecordKeysMatchTheScript() throws {
    let record = NativeSearchEvaluation.Record(
      id: "web-01", category: "news", route: "claude-code", model: "sonnet", backend: "provider", searched: true,
      sources: [WebSearchSource(title: "Example", url: URL(string: "https://example.com/a")!)], unsafeSources: 0,
      firstTextSeconds: 1.5, totalSeconds: 3, answer: "An answer.", error: nil)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try NativeSearchEvaluation.encoder.encode(record)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["id", "category", "route", "model", "backend", "searched", "sources", "unsafeSources",
                                      "firstTextSeconds", "totalSeconds", "answer"])
    XCTAssertEqual((object["sources"] as? [[String: String]])?.first, ["title": "Example", "url": "https://example.com/a"])
  }

  func testCompare() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ENIGMA_NATIVE_SEARCH_LIVE"] == "1", let path = environment["ENIGMA_SEARCH_EVAL"], !path.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 and TEST_RUNNER_ENIGMA_SEARCH_EVAL to a folder outside the repository.")
    }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let folder = URL(fileURLWithPath: path).standardizedFileURL
    guard !NativeToolsProbeTests.isInside(folder, repository) else {
      return XCTFail("The comparison must be written outside the repository.")
    }
    let routes = try (environment["ENIGMA_SEARCH_EVAL_ROUTES"].map { $0.split(separator: ",").map(String.init) }
      ?? CloudProviderID.allCases.filter(CloudProviderID.nativeWebSearchProviders.contains).map(\.rawValue))
      .map { name in
        guard let provider = CloudProviderID(rawValue: name), CloudProviderID.nativeWebSearchProviders.contains(provider) else {
          throw NativeToolsEval.EvalError("\(name) has no provider search.")
        }
        return provider
      }
    let braveKey = environment["ENIGMA_BRAVE_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    let questions = try NativeSearchEvaluation.questions()
    for provider in routes {
      let model = NativeSearchEvaluation.modelID(for: provider, environment: environment)
      for question in questions {
        for backend in braveKey == nil ? ["provider"] : ["provider", "brave"] {
          let record = await NativeSearchEvaluation.run(question, provider: provider, model: model,
                                                        braveKey: backend == "brave" ? braveKey : nil)
          let file = folder.appending(path: "\(provider.rawValue)/\(backend)/\(question.id).json")
          try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try NativeSearchEvaluation.encoder.encode(record).write(to: file)
          print("F30 comparison \(provider.rawValue) \(backend) \(question.id): searched \(record.searched), "
                + "\(record.sources.count) sources, \(record.error == nil ? "answered" : "failed")")
        }
      }
    }
  }
}

enum NativeSearchEvaluation {
  struct Question: Codable, Equatable {
    let id: String
    let category: String
    let question: String
  }

  /// One run, as the comparison script reads it. The answer stays in the folder outside the
  /// repository; the report keeps only metrics and judgments.
  struct Record: Codable {
    let id: String
    let category: String
    let route: String
    let model: String
    /// `provider` for the provider's own search, `brave` for Enigma's `web_search`.
    let backend: String
    let searched: Bool
    let sources: [WebSearchSource]
    /// Saved sources that fail `isSafeWebLink`; the gate needs none.
    let unsafeSources: Int
    let firstTextSeconds: Double?
    let totalSeconds: Double
    let answer: String
    let error: String?
  }

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// F30's 20 questions (`web-` IDs). F29 CP7 adds 40 more to the same file for its own evaluation,
  /// as `scripts/evaluate-native-search.py` also skips.
  static func questions() throws -> [Question] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "scripts/web-search-queries.json")
    return try JSONDecoder().decode([Question].self, from: Data(contentsOf: url)).filter { $0.id.hasPrefix("web-") }
  }

  /// The model the live checks use: `ENIGMA_CHATGPT_MODEL` or `ENIGMA_CLAUDE_CODE_MODEL`, else the
  /// client's default.
  static func modelID(for provider: CloudProviderID, environment: [String: String]) -> String {
    switch provider {
    case .chatGPT: environment["ENIGMA_CHATGPT_MODEL"] ?? CodexSubscriptionClient.defaultModelID
    case .claudeCode: environment["ENIGMA_CLAUDE_CODE_MODEL"] ?? ClaudeCodeSubscriptionClient.defaultModelID
    case .openAI, .anthropic, .gemini: ""
    }
  }

  /// Runs one question in a new chat through `submitNative`, with automatic search on: provider
  /// search when `braveKey` is nil, Enigma's `web_search` on Brave otherwise (the key selects
  /// Brave, D128).
  @MainActor
  static func run(_ question: Question, provider: CloudProviderID, model: String, braveKey: String?) async -> Record {
    let route = Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true)
    let started = ContinuousClock.now
    var firstText: Duration?
    var reply: ChatMessage?
    var failure: String?
    do {
      reply = try await NativeSearchTurn.ask(question.question, route: route,
                                             providers: braveKey == nil ? [provider] : [], braveKey: braveKey) {
        if firstText == nil { firstText = started.duration(to: .now) }
      }
    } catch {
      failure = error.localizedDescription
    }
    let sources = reply?.searchSources ?? []
    return Record(id: question.id, category: question.category, route: provider.rawValue, model: model,
                  backend: braveKey == nil ? "provider" : "brave",
                  searched: reply?.activity?.phases.contains(.searching) == true,
                  sources: sources, unsafeSources: sources.filter { !$0.isSafeWebLink }.count,
                  firstTextSeconds: firstText?.evalSeconds, totalSeconds: started.duration(to: .now).evalSeconds,
                  answer: reply?.content ?? "", error: failure)
  }
}

/// One flagged turn through `submitNative`, as the app sends it, in a new chat with scratch
/// preferences. Messages tools see no real chats. Shared by the live checks and the comparison.
enum NativeSearchTurn {
  @MainActor
  static func ask(_ prompt: String, route: Route, providers: Set<CloudProviderID>, braveKey: String? = nil,
                  onFirstText: () -> Void = {}) async throws -> ChatMessage {
    let root = FileManager.default.temporaryDirectory.appending(path: "NativeSearchTurn-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "NativeSearchTurn-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: braveKey), defaults: defaults)
    settings.automaticallySearch = true
    // Opt-in and live: Brave with the given key, and an online on-device search otherwise (D139).
    let brave: (any WebSearchProvider)? = braveKey.map {
      BraveSearchClient(credentials: NativeSearchCredentials(key: $0))
    }
    let chat = LocalChatViewModel(
      engine: NativeTestEngine(model: NativeToolRequestTests.flaggedModel),
      selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
      toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
      messagesToolbox: { confirm in
        MessagesTools(database: MessagesDatabase(url: URL(fileURLWithPath: "/nonexistent")), contacts: FixtureContacts(),
                      confirmSend: confirm)
      },
      messagesAccess: {},
      webSearch: OnDeviceSearchProvider.live(offline: false),
      braveSearch: brave,
      searchSettings: settings,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root),
      nativeToolsEnabled: true,
      nativeWebSearchProviders: providers)
    // `submitNative` gives the plan provider search for the route.
    chat.submitNative(prompt, route: route, plan: chat.nativeToolPlan(for: ComposerCommands(prompt)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    var sawText = false
    while chat.activeRequest != nil || chat.isBusy {
      guard ContinuousClock.now < deadline else {
        _ = chat.stopStreaming()
        throw NativeToolsEval.EvalError("The live turn took longer than 3 minutes.")
      }
      if !sawText, chat.messages.last(where: { $0.role == .assistant })?.content.isEmpty == false {
        sawText = true
        onFirstText()
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    if case .failed(let message) = chat.state { throw NativeToolsEval.EvalError("The turn failed: \(message)") }
    return try XCTUnwrap(chat.messages.last { $0.role == .assistant })
  }
}
