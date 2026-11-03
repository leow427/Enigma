import XCTest
@testable import Enigma

/// F35 CP1: the per-step budget of the tool loops Enigma drives.
final class ToolStepBudgetTests: XCTestCase {
  /// 8,192 − 1,024 output − 1,024 overhead: 6,144 tokens of input.
  private let budget = ContextBudget(contextWindow: 8_192, outputTokens: 1_024, overheadTokens: 1_024)

  func testProceedsWhenNextStepFits() {
    let steps = ToolStepBudget()
    var shrunk = false
    // 512 left: room for the smallest result and the model's next step.
    XCTAssertEqual(steps.decide(usedTokens: 6_144 - 512, budget: budget) { _ in shrunk = true; return 0 }, .proceed)
    XCTAssertFalse(shrunk, "Nothing shrinks while the next step fits")
    XCTAssertEqual(steps.roomLeft, 512)
  }

  func testShrinksWhenResultsOverflow() {
    let steps = ToolStepBudget()
    XCTAssertEqual(steps.decide(usedTokens: 6_144 - 511, budget: budget) { _ in 1_000 }, .shrinkEarlierResults)
    XCTAssertEqual(steps.roomLeft, 5_144, "The shrunk request is what's measured")
    XCTAssertEqual(steps.decide(usedTokens: 9_000, budget: budget) { _ in 6_144 - 512 }, .shrinkEarlierResults)
  }

  func testAnswersWithoutToolsWhenShrinkingIsNotEnough() {
    let steps = ToolStepBudget()
    XCTAssertEqual(steps.decide(usedTokens: 7_000, budget: budget) { _ in 6_144 - 511 }, .answerWithoutTools)
    XCTAssertEqual(steps.decide(usedTokens: 6_000, budget: budget) { _ in 6_000 }, .answerWithoutTools)
    XCTAssertNil(steps.evidenceTokens(cap: 8_192))
  }

  func testStillOverBudgetShrinksTheNewestToo() {
    let steps = ToolStepBudget()
    var asked: [Bool] = []
    // Shrinking earlier results leaves the request over; the newest shrink too.
    XCTAssertEqual(steps.decide(usedTokens: 7_000, budget: budget) { newest in
      asked.append(newest); return newest ? 5_000 : 6_500 }, .answerWithoutTools)
    XCTAssertEqual(asked, [false, true])
    XCTAssertEqual(steps.roomLeft, 1_144)
    // Within the budget, the newest stay whole.
    asked = []
    XCTAssertEqual(steps.decide(usedTokens: 7_000, budget: budget) { newest in
      asked.append(newest); return 6_000 }, .answerWithoutTools)
    XCTAssertEqual(asked, [false])
  }

  func testReservesAreTheOwnersValues() {
    XCTAssertEqual(ToolStepBudget.reserve(cap: ToolStepBudget.localEvidenceTokens), 2_560)
    XCTAssertEqual(ToolStepBudget.reserve(cap: WebSearchLimits.evidenceTokens), 8_704)
  }

  func testCloudToolTurnKeepsRoomForAResult() throws {
    let request = ChatRequest(sessionID: UUID(), messages: longChat(),
      route: Route(mode: .cloud, providerID: CloudProviderID.openAI.rawValue, modelID: "gpt-4.1", usesNetwork: true))
    let tool = try CloudContext.prepare(request, toolbox: SampleToolbox())
    XCTAssertGreaterThanOrEqual(tool.budget.availableInputTokens - tool.inputTokenCount, 8_704)
    XCTAssertEqual(tool.budget, ModelContextPolicy.cloud(provider: .openAI, modelID: "gpt-4.1",
      promptTokens: CloudContext.promptTokens(provider: .openAI, toolbox: SampleToolbox())), "The real budget, for the loop")
    let plain = try CloudContext.prepare(request)
    XCTAssertLessThan(plain.budget.availableInputTokens - plain.inputTokenCount, 8_704, "Only tool turns keep the room")
  }

  func testCurrentMessageTooBigForTheReserveGoesAlone() throws {
    let budget = ContextBudget(contextWindow: 8_192, outputTokens: 1_024, overheadTokens: 1_024)
    let count: ([ChatMessage]) -> Int = { $0.reduce(0) { $0 + $1.content.count } }
    let history = (0..<6).flatMap { _ in [ChatMessage(role: .user, content: String(repeating: "q", count: 300)),
                                     ChatMessage(role: .assistant, content: String(repeating: "a", count: 300))] }
    let big = ChatMessage(role: .user, content: String(repeating: "x", count: 4_000))
    let prepared = try ChatContextPreparer.prepare(history + [big], budget: budget, reserving: 2_560, countTokens: count)
    XCTAssertEqual(prepared.messages, [big], "Older turns don't take the room the results need")
    XCTAssertEqual(prepared.omittedMessageCount, 12)
    XCTAssertEqual(prepared.budget, budget)
    // With the reserve kept, older turns fill only what it leaves.
    let small = ChatMessage(role: .user, content: "Hi")
    let kept = try ChatContextPreparer.prepare(history + [small], budget: budget, reserving: 2_560, countTokens: count)
    XCTAssertEqual(kept.messages.count, 11, "Five turns of 600 fit in the 3,584 the reserve leaves")
    XCTAssertLessThanOrEqual(kept.inputTokenCount, 6_144 - 2_560)
    XCTAssertThrowsError(try ChatContextPreparer.prepare([ChatMessage(role: .user, content: String(repeating: "x", count: 6_145))],
                                                         budget: budget, reserving: 2_560, countTokens: count))
  }

  func testSearchResultFitsTheSizeItWasGivenWithEveryField() async throws {
    let results = (1...10).map { index in
      WebSearchResult(source: WebSearchSource(title: "A fairly long page title number \(index)",
                                              url: URL(string: "https://www.example.com/articles/2026/11/03/page-\(index)")!),
                      snippets: [String(repeating: "word ", count: 400)], site: "Example News", published: Date())
    }
    for size in [256, 512, 1_280, 2_048] {
      let steps = ToolStepBudget()
      steps.measure(budget, usedTokens: 6_144 - 2 * size)
      let tool = WebSearchTool(search: { _, _, _ in results }, evidenceCap: 8_192, stepBudget: steps,
                               mayQuery: { _ in true }, onSources: { _ in })
      let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"news"}"#)
      XCTAssertTrue(result.success, "\(size)")
      XCTAssertLessThanOrEqual(ContextEstimate.tokens(result.text), size, "\(size)")
      XCTAssertTrue(result.text.contains("page-1\""), "The first source stays")
    }
  }

  func testSearchResultFillsMostOfItsSizeAndKeepsSourcesThatFit() throws {
    let results = (1...10).map { index in
      WebSearchResult(source: WebSearchSource(title: "A fairly long page title number \(index)",
                                              url: URL(string: "https://www.example.com/articles/2026/11/03/page-\(index)")!),
                      snippets: [String(repeating: "word ", count: 2_000)], site: "Example News", published: Date())
    }
    for size in [1_008, 2_032, 4_336, 8_176] {
      let fitted = try XCTUnwrap(WebSearchExcerpts.json(results, timeZone: .current, maximumTokens: size))
      let tokens = ContextEstimate.tokens(fitted.text)
      XCTAssertLessThanOrEqual(tokens, size, "\(size)")
      XCTAssertGreaterThanOrEqual(tokens, size * 9 / 10, "\(size): the excerpts fill what the fields leave")
      XCTAssertEqual(fitted.kept, 10, "\(size): every source whose fields fit stays")
    }
    // With room for the fields of only some sources, the trailing ones go.
    let few = try XCTUnwrap(WebSearchExcerpts.json(results, timeZone: .current, maximumTokens: 300))
    XCTAssertLessThan(few.kept, 10)
    XCTAssertGreaterThan(few.kept, 0)
    XCTAssertLessThanOrEqual(ContextEstimate.tokens(few.text), 300)
  }

  func testOnlyKeptSourcesAreReported() async throws {
    let results = (1...10).map { index in
      WebSearchResult(source: WebSearchSource(title: "A fairly long page title number \(index)",
                                              url: URL(string: "https://www.example.com/articles/2026/11/03/page-\(index)")!),
                      snippets: [String(repeating: "word ", count: 400)], site: "Example News", published: Date())
    }
    let steps = ToolStepBudget()
    steps.measure(budget, usedTokens: 6_144 - 2 * 300)
    let reported = LockedSizes()
    let tool = WebSearchTool(search: { _, _, _ in results }, evidenceCap: 8_192, stepBudget: steps,
                             mayQuery: { _ in true }, onSources: { reported.append($0.count) })
    let result = await tool.execute(name: "web_search", jsonArguments: #"{"query":"news"}"#)
    let shown = result.text.components(separatedBy: "https://www.example.com/").count - 1
    XCTAssertLessThan(shown, 10, "Some sources didn't fit")
    XCTAssertEqual(reported.values, [shown], "The reply lists only what the model saw")
  }

  func testSmallWindowToolTurnKeepsSomeHistory() throws {
    let chat = [ChatMessage(role: .user, content: "Who won the game last night?"),
                ChatMessage(role: .assistant, content: "The home team won 102 to 98."),
                ChatMessage(role: .user, content: "And who scored the most points?")]
    // An unreviewed model gets the default 8,192-token window, less than the cloud reserve.
    for (provider, model) in [(CloudProviderID.anthropic, "claude-opus-4-1-20250805"), (.gemini, "gemini-flash-latest")] {
      let request = ChatRequest(sessionID: UUID(), messages: chat,
        route: Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true))
      let prepared = try CloudContext.prepare(request, toolbox: SampleToolbox())
      XCTAssertEqual(prepared.messages.count, 3, "\(model)")
      XCTAssertEqual(prepared.omittedMessageCount, 0, "\(model)")
    }
    // The reserve takes at most half the budget.
    let count: ([ChatMessage]) -> Int = { $0.reduce(0) { $0 + $1.content.count } }
    let history = [ChatMessage(role: .user, content: String(repeating: "q", count: 1_000)),
                   ChatMessage(role: .assistant, content: String(repeating: "a", count: 1_000)),
                   ChatMessage(role: .user, content: "Hi")]
    let kept = try ChatContextPreparer.prepare(history, budget: budget, reserving: 8_704, countTokens: count)
    XCTAssertEqual(kept.messages.count, 3, "2,002 fits in the 3,072 half the budget leaves")
  }

  func testThinkReserveCountsInStepBudget() {
    // The same request fits with the plain 1,024 reserve and not with /think's 2,048.
    let plain = ContextBudget(contextWindow: 8_192, outputTokens: 1_024, overheadTokens: 1_024)
    let thinking = ContextBudget(contextWindow: 8_192, outputTokens: 2_048, overheadTokens: 1_024)
    let used = 6_144 - 1_000
    XCTAssertEqual(ToolStepBudget().decide(usedTokens: used, budget: plain) { _ in used }, .proceed)
    XCTAssertEqual(ToolStepBudget().decide(usedTokens: used, budget: thinking) { _ in used }, .answerWithoutTools)
  }

  func testEvidenceTokensHalveRoomLeftAndRespectCap() {
    let steps = ToolStepBudget()
    XCTAssertEqual(steps.evidenceTokens(cap: 2_048), 2_048, "Before any measurement, the cap")
    steps.measure(budget, usedTokens: 6_144 - 3_000)
    XCTAssertEqual(steps.evidenceTokens(cap: 2_048), 1_500)
    XCTAssertEqual(steps.evidenceTokens(cap: 1_000), 1_000)
    steps.add(1_000)
    XCTAssertEqual(steps.roomLeft, 2_000, "A result returned to a CLI counts as used")
    XCTAssertEqual(steps.evidenceTokens(cap: 2_048), 1_000)
    XCTAssertEqual(steps.usage, ContextUsage(usedTokens: 6_144 - 2_000, limitTokens: 6_144))
  }

  func testEvidenceTokensNilBelowSmallestResult() {
    let steps = ToolStepBudget()
    steps.measure(budget, usedTokens: 6_144 - 512)
    XCTAssertEqual(steps.evidenceTokens(cap: 8_192), 256)
    steps.measure(budget, usedTokens: 6_144 - 511)
    XCTAssertNil(steps.evidenceTokens(cap: 8_192))
    steps.measure(budget, usedTokens: 7_000)
    XCTAssertNil(steps.evidenceTokens(cap: 8_192), "An overfull request has no room at all")
    XCTAssertNil(ToolStepBudget().evidenceTokens(cap: 255), "A cap below the smallest result never searches")
  }

  // MARK: Shrinking

  private let search = #"{"results":[{"id":1,"kind":"page","site":"Example","text":"A long excerpt about the topic, which goes on for a good while so that removing it saves space.","title":"Topic","url":"https://example.com/topic"},{"id":2,"kind":"page","site":"Other","text":"More text.","title":"Other page","url":"https://other.example/a"}]}"#

  func testShrinkKeepsTitleSiteAndURL() throws {
    let shrunk = ToolStepBudget.shrunkSearchResult(search)
    let results = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(shrunk.utf8)) as? [String: Any])?["results"] as? [[String: Any]])
    XCTAssertEqual(results.map { $0["title"] as? String }, ["Topic", "Other page"])
    XCTAssertEqual(results.map { $0["site"] as? String }, ["Example", "Other"])
    XCTAssertEqual(results.map { $0["url"] as? String }, ["https://example.com/topic", "https://other.example/a"])
    XCTAssertEqual(results.map { $0["text"] as? String }, Array(repeating: "(excerpt removed to save space)", count: 2))
    XCTAssertTrue(shrunk.contains("https://example.com/topic"), "URLs keep their slashes unescaped")
    XCTAssertLessThan(shrunk.utf8.count, search.utf8.count)
    // The local loop wraps each result.
    let wrapped = #"{"result":"# + search + #","success":true}"#
    XCTAssertEqual(ToolStepBudget.shrunkSearchResult(wrapped), #"{"result":"# + shrunk + #","success":true}"#)
  }

  func testShrinkLeavesNonSearchResultsAlone() {
    for text in [#"{"answer":"42"}"#, "Plain text", #"{"results":"none"}"#, #"{"result":{"conversations":[]},"success":true}"#] {
      XCTAssertEqual(ToolStepBudget.shrunkSearchResult(text), text)
    }
  }

  func testShrinkIsIdempotent() {
    let once = ToolStepBudget.shrunkSearchResult(search)
    XCTAssertEqual(ToolStepBudget.shrunkSearchResult(once), once)
  }

  // MARK: Search sizing

  private final class Searches: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    private var asked = 0
    var sizes: [Int] { lock.withLock { recorded } }
    var questions: Int { lock.withLock { asked } }
    func record(_ size: Int) { lock.withLock { recorded.append(size) } }
    func ask() { lock.withLock { asked += 1 } }
  }

  private func tool(_ searches: Searches, budget: ToolStepBudget, cap: Int = 8_192) -> AssistantToolbox {
    let results = (1...3).map { index in
      WebSearchResult(source: WebSearchSource(title: "Result \(index)", url: URL(string: "https://example.com/\(index)")!),
                      snippets: [String(repeating: "word ", count: 600)])
    }
    let search = WebSearchTool(search: { _, _, size in searches.record(size); return results }, evidenceCap: cap,
                               stepBudget: budget, mayQuery: { _ in searches.ask(); return true }, onSources: { _ in })
    var toolbox = AssistantToolbox(parts: [search], requiredTool: nil, extraInstructions: [])
    toolbox.stepBudget = budget
    return toolbox
  }

  func testWebSearchWithNoRoomAnswersNoRoom() async {
    let searches = Searches()
    let steps = ToolStepBudget()
    steps.measure(budget, usedTokens: 6_144 - 511)
    let result = await tool(searches, budget: steps).execute(name: "web_search", jsonArguments: #"{"query":"news"}"#)
    XCTAssertEqual(result.text, "No room is left in this conversation for more search results. Answer from what you already have.")
    XCTAssertFalse(result.success)
    XCTAssertFalse(result.terminal)
    XCTAssertTrue(searches.sizes.isEmpty, "No search runs")
    XCTAssertEqual(searches.questions, 0, "Nothing to ask about")
  }

  func testCLIRoutesSizeResultsFromEstimate() async throws {
    // About 50,000 tokens of chat, so the room left is smaller than the 8,192 cap.
    let messages = [ChatMessage(role: .user, content: String(repeating: "context ", count: 18_750) + "What's new?")]
    for provider in [CloudProviderID.chatGPT, .claudeCode] {
      let searches = Searches()
      let steps = ToolStepBudget()
      let toolbox = tool(searches, budget: steps)
      let request = ChatRequest(sessionID: UUID(), messages: messages,
        route: Route(mode: .cloud, providerID: provider.rawValue, modelID: provider == .chatGPT ? "gpt-5.6-luna" : "sonnet",
                     usesNetwork: true))
      let prepared = try CloudContext.prepare(request, toolbox: toolbox)
      // What Enigma sends the CLI is what it measures.
      if provider == .chatGPT { _ = try CodexSubscriptionClient.prompt(for: request, toolbox: toolbox) }
      else { _ = try ClaudeCodeSubscriptionClient.prompt(for: request, toolbox: toolbox) }
      let room = prepared.budget.availableInputTokens - prepared.inputTokenCount
      XCTAssertEqual(steps.roomLeft, room, "\(provider)")
      var returned: [String] = []
      for call in 0..<2 {
        if provider == .chatGPT {
          let reply = await CodexToolMode.handle(method: "item/tool/call", params: .object([
            "tool": .string("web_search"), "turnId": .string("u"), "callId": .string("c\(call)"),
            "arguments": .object(["query": .string("news")])]), toolbox: toolbox)
          returned.append(reply["contentItems"].array?.first?["text"].string ?? "")
        } else {
          let reply = try await ClaudeCodeToolMode.respond(to: .object(["jsonrpc": .string("2.0"), "id": .number(Double(call)),
            "method": .string("tools/call"), "params": .object(["name": .string("web_search"),
              "arguments": .object(["query": .string("news")])])]), toolbox: toolbox)
          returned.append(reply["result"]["content"].array?.first?["text"].string ?? "")
        }
      }
      XCTAssertFalse(returned[0].isEmpty, "\(provider)")
      XCTAssertEqual(searches.sizes.first, min(8_192, room / 2), "\(provider)")
      XCTAssertEqual(searches.sizes.last, min(8_192, (room - ContextEstimate.tokens(returned[0])) / 2), "\(provider)")
      XCTAssertLessThan(searches.sizes[1], searches.sizes[0], "\(provider)")
    }
  }
}
