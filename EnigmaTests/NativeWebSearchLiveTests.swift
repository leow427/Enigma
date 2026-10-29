import XCTest
@testable import Enigma

/// Live checks of each provider's own web search (F30), on the owner's Mac, never in CI. They skip
/// unless `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1` is set, and use the Mac's sign-ins as the app does.
@MainActor
final class NativeWebSearchLiveTests: XCTestCase {
  static let question = "What is the latest stable Swift release? Link your source."
  static let multiSearchQuestion =
    "Compare the current prices of the cheapest MacBook Air and the cheapest MacBook Pro in the US. Link your sources."

  private var root: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    guard ProcessInfo.processInfo.environment["ENIGMA_NATIVE_SEARCH_LIVE"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 to run the live provider-search checks.")
    }
    root = FileManager.default.temporaryDirectory.appending(path: "NativeWebSearchLiveTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    suiteName = "NativeWebSearchLiveTests-\(UUID())"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  /// Uses the Mac's ChatGPT sign-in, through Codex, with no Brave key.
  func testChatGPTSearchesLive() async throws {
    let modelID = ProcessInfo.processInfo.environment["ENIGMA_CHATGPT_MODEL"] ?? CodexSubscriptionClient.defaultModelID
    let route = Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: modelID, usesNetwork: true)
    let reply = try await ask(Self.question, route: route, providers: [.chatGPT])
    XCTAssertTrue(reply.activity?.phases.contains(.searching) == true, "Codex searched")
    let sources = reply.searchSources ?? []
    XCTAssertFalse(sources.isEmpty, "At least one source was selected")
    XCTAssertTrue(sources.allSatisfy(\.isSafeWebLink))
    XCTAssertFalse(reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    print("F30 live \(route.providerID) \(modelID): \(sources.count) sources, \(reply.content.count) characters")
  }

  /// Uses the Mac's Claude sign-in, through Claude Code, with no Brave key. The question needs two
  /// searches (CP0's multi-search question).
  func testClaudeCodeSearchesLive() async throws {
    let modelID = ProcessInfo.processInfo.environment["ENIGMA_CLAUDE_CODE_MODEL"] ?? ClaudeCodeSubscriptionClient.defaultModelID
    let route = Route(mode: .cloud, providerID: CloudProviderID.claudeCode.rawValue, modelID: modelID, usesNetwork: true)
    let reply = try await ask(Self.multiSearchQuestion, route: route, providers: [.claudeCode])
    XCTAssertTrue(reply.activity?.phases.contains(.searching) == true, "Claude Code searched")
    let sources = reply.searchSources ?? []
    XCTAssertGreaterThanOrEqual(sources.count, 2, "At least two sources were selected")
    XCTAssertTrue(sources.allSatisfy(\.isSafeWebLink))
    XCTAssertFalse(reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    print("F30 live \(route.providerID) \(modelID): \(sources.count) sources, \(reply.content.count) characters")
  }

  /// Sends one flagged turn through `submitNative`, with automatic search on and no Brave key, and
  /// returns the reply. Messages tools see no real chats.
  private func ask(_ prompt: String, route: Route, providers: Set<CloudProviderID>) async throws -> ChatMessage {
    let settings = WebSearchSettings(credentials: NativeSearchCredentials(key: nil), defaults: defaults)
    settings.automaticallySearch = true
    let chat = LocalChatViewModel(
      engine: NativeTestEngine(model: NativeToolRequestTests.flaggedModel),
      selectionEditingSettings: SelectionEditingSettings(defaults: defaults),
      toolPermissions: ToolPermissionCoordinator(store: ToolGrantStore(defaults: defaults)),
      messagesToolbox: { confirm in
        MessagesTools(database: MessagesDatabase(url: URL(fileURLWithPath: "/nonexistent")), contacts: FixtureContacts(),
                      confirmSend: confirm)
      },
      messagesAccess: {},
      searchSettings: settings,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root),
      nativeToolsEnabled: true,
      nativeWebSearchProviders: providers)
    // `submitNative` gives the plan provider search for the route.
    chat.submitNative(prompt, route: route, plan: chat.nativeToolPlan(for: ComposerCommands(prompt)))
    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
    while chat.activeRequest != nil || chat.isBusy {
      guard ContinuousClock.now < deadline else {
        _ = chat.stopStreaming()
        return try XCTUnwrap(nil, "The live turn took longer than 3 minutes.")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    if case .failed(let message) = chat.state { XCTFail("The turn failed: \(message)") }
    return try XCTUnwrap(chat.messages.last { $0.role == .assistant })
  }
}
