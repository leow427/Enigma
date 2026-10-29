import XCTest
@testable import Enigma

/// The tool parts a capable model gets on every turn (F32 CP4).
final class NativeToolPartsTests: XCTestCase {
  private static let results = [
    WebSearchResult(source: WebSearchSource(title: "Weather today", url: URL(string: "https://example.com/weather")!),
                    snippets: ["Sunny, 21 °C."]),
    WebSearchResult(source: WebSearchSource(title: "Forecast", url: URL(string: "https://example.org/forecast")!),
                    snippets: ["Rain tomorrow.", "Clearing on Friday."]),
  ]

  func testWebSearchReturnsResultsAndSources() async throws {
    let queries = LockedStrings()
    let sources = LockedSources()
    let tool = WebSearchTool(search: { queries.append($0); return Self.results },
                             mayQuery: { _ in true }, onSources: { sources.set($0) })
    XCTAssertEqual(tool.definitions.map(\.name), ["web_search"])
    XCTAssertEqual(tool.definitions[0].required, ["query"])
    XCTAssertEqual(tool.phase(for: "web_search"), .searching)

    let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"weather in Paris"}"#)
    XCTAssertTrue(result.success)
    XCTAssertEqual(queries.values, ["weather in Paris"])
    XCTAssertEqual(sources.value, Self.results.map(\.source))
    let decoded = try JSONDecoder().decode(CodexValue.self, from: Data(result.text.utf8))
    let first = decoded["results"].array?.first
    XCTAssertEqual(first?["title"].string, "Weather today")
    XCTAssertEqual(first?["url"].string, "https://example.com/weather")
    XCTAssertEqual(first?["snippets"].array?.compactMap(\.string), ["Sunny, 21 °C."])
    XCTAssertEqual(decoded["results"].array?.count, 2)
  }

  func testWebSearchAsksBeforeQueryingAfterMessageText() async {
    let queries = LockedStrings()
    let asked = LockedStrings()
    let sources = LockedSources()
    let tool = WebSearchTool(search: { queries.append($0); return Self.results },
                             mayQuery: { asked.append($0); return false }, onSources: { sources.set($0) })
    let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"Alice's address"}"#)
    XCTAssertEqual(asked.values, ["Alice's address"])
    XCTAssertTrue(queries.values.isEmpty, "A declined query never reaches the search engine")
    XCTAssertNil(sources.value)
    XCTAssertEqual(result.text, "The user declined.")
    XCTAssertFalse(result.success)
    XCTAssertFalse(result.terminal)
  }

  /// What the card shows is what is searched: a query with a line break or a hidden
  /// character is asked about, and searched, in the card's one-line form.
  func testWebSearchSendsExactlyWhatTheCardShowed() async {
    let queries = LockedStrings()
    let asked = LockedStrings()
    let tool = WebSearchTool(search: { queries.append($0); return Self.results },
                             mayQuery: { asked.append($0); return true }, onSources: { _ in })
    _ = await tool.execute(name: "web_search", arguments: .object(["query": .string("  Alice\nhome\u{200B}address ")]))
    let shown = ToolPermissionRequest.oneLine("  Alice\nhome\u{200B}address ")
    XCTAssertEqual(asked.values, [shown])
    XCTAssertEqual(queries.values, [shown])
  }

  func testWebSearchErrorReturnsToModel() async {
    let tool = WebSearchTool(search: { _ in throw WebSearchError.rateLimited },
                             mayQuery: { _ in true }, onSources: { _ in XCTFail("No sources for a failed search") })
    let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"news"}"#)
    XCTAssertFalse(result.success)
    XCTAssertFalse(result.terminal)
    XCTAssertEqual(result.text, WebSearchError.rateLimited.localizedDescription)
  }

  func testWebSearchRejectsBadArgumentsWithoutSearching() async {
    let queries = LockedStrings()
    let tool = WebSearchTool(search: { queries.append($0); return [] }, mayQuery: { _ in true }, onSources: { _ in })
    for arguments in [#"{}"#, #"{"query":"   "}"#, #"{"query":3}"#, #"{"query":"a","extra":1}"#, "not json"] {
      let result = await tool.execute(name: "web_search", jsonArguments: arguments)
      XCTAssertFalse(result.success, arguments)
    }
    XCTAssertTrue(queries.values.isEmpty)
  }

  func testWebSearchStoppedEndsTheRequest() async {
    let tool = WebSearchTool(search: { _ in throw CancellationError() }, mayQuery: { _ in true }, onSources: { _ in })
    let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"news"}"#)
    XCTAssertEqual(result.stop, .cancelled)
  }

  func testProposeEditDeliversProposal() async {
    let proposals = LockedProposals()
    let tools = SelectionTools(allowsEdit: true) { proposals.append($0) }
    XCTAssertEqual(Set(tools.definitions.map(\.name)), ["propose_edit", "propose_translation"])
    let edit = await tools.execute(name: "propose_edit", jsonArguments: #"{"text":"Hello, world."}"#)
    XCTAssertTrue(edit.success)
    let translation = await tools.execute(name: "propose_translation",
                                          jsonArguments: #"{"text":"Bonjour.","language":"French"}"#)
    XCTAssertTrue(translation.success)
    XCTAssertEqual(proposals.values, [SelectionProposal(text: "Hello, world.", language: nil),
                                      SelectionProposal(text: "Bonjour.", language: "French")])
    let empty = await tools.execute(name: "propose_edit", jsonArguments: #"{"text":""}"#)
    XCTAssertFalse(empty.success)
    XCTAssertEqual(proposals.values.count, 2)
  }

  func testTranslationOnlyHidesProposeEdit() async {
    let proposals = LockedProposals()
    let tools = SelectionTools(allowsEdit: false) { proposals.append($0) }
    XCTAssertEqual(tools.definitions.map(\.name), ["propose_translation"])
    let edit = await tools.execute(name: "propose_edit", jsonArguments: #"{"text":"Replaced"}"#)
    XCTAssertFalse(edit.success)
    XCTAssertTrue(proposals.values.isEmpty, "A translation-only turn can't propose replacing the selection")
  }

  // MARK: Wording measured by the CP5 eval

  func testWebSearchGivesTodaysDateAndAsksToSearchRatherThanDecline() throws {
    let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T23:30:00Z"))
    let tool = WebSearchTool(search: { _ in [] }, mayQuery: { _ in true }, onSources: { _ in },
                             today: today, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Chicago")))
    XCTAssertTrue(tool.instructions.contains("Today is Wednesday, 28 October 2026."), tool.instructions)
    XCTAssertTrue(tool.instructions.contains("call web_search instead of saying you can't"), tool.instructions)
    let tokyo = WebSearchTool(search: { _ in [] }, mayQuery: { _ in true }, onSources: { _ in },
                              today: today, timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
    XCTAssertTrue(tokyo.instructions.contains("Today is Thursday, 29 October 2026."), "The date is the user's own")
  }

  func testGatedMessagesToolsSteerANamedChatToGetMessages() {
    let plain = MessagesTools(confirmSend: { _ in false })
    let gated = MessagesTools(confirmSend: { _ in false }, gate: RecordingMessagesGate())
    func description(_ tools: MessagesTools, _ name: String) -> String {
      tools.definitions.first { $0.name == name }?.description ?? ""
    }
    XCTAssertTrue(gated.instructions.contains(MessagesTools.namedChatInstruction))
    XCTAssertTrue(description(gated, "get_messages").contains("a person or group the user names"))
    XCTAssertTrue(description(gated, "search_messages").contains("Only for searching across all chats"))
    // Today's /messages on models without native tools keeps its wording.
    XCTAssertFalse(plain.instructions.contains(MessagesTools.namedChatInstruction))
    XCTAssertEqual(description(plain, "get_messages"),
                   "Read messages from one conversation, oldest first within the page. For earlier messages, pass next_before from the previous result as before.")
    XCTAssertEqual(description(plain, "search_messages"),
                   "Search message text across all conversations, newest first, with two messages of context on each side.")
  }
}

final class LockedStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) { lock.withLock { storage.append(value) } }
  var values: [String] { lock.withLock { storage } }
}

final class LockedSources: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [WebSearchSource]?
  func set(_ value: [WebSearchSource]) { lock.withLock { storage = value } }
  var value: [WebSearchSource]? { lock.withLock { storage } }
}

final class LockedProposals: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [SelectionProposal] = []
  func append(_ value: SelectionProposal) { lock.withLock { storage.append(value) } }
  var values: [SelectionProposal] { lock.withLock { storage } }
}
