import XCTest
@testable import Enigma

/// Live checks of each provider's own web search (F30), on the owner's Mac, never in CI. They skip
/// unless `TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1` is set, and use the Mac's sign-ins as the app does.
@MainActor
final class NativeWebSearchLiveTests: XCTestCase {
  static let question = "What is the latest stable Swift release? Link your source."
  static let multiSearchQuestion =
    "Compare the current prices of the cheapest MacBook Air and the cheapest MacBook Pro in the US. Link your sources."

  override func setUpWithError() throws {
    guard ProcessInfo.processInfo.environment["ENIGMA_NATIVE_SEARCH_LIVE"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_ENIGMA_NATIVE_SEARCH_LIVE=1 to run the live provider-search checks.")
    }
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

  /// Sends one flagged turn through `submitNative`, with automatic search on and no Brave key.
  private func ask(_ prompt: String, route: Route, providers: Set<CloudProviderID>) async throws -> ChatMessage {
    try await NativeSearchTurn.ask(prompt, route: route, providers: providers)
  }
}
