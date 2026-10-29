import Foundation

/// `web_search` for capable models (F32): the model writes the query, and Enigma searches it
/// with the user's search engine. After message text has entered the chat, each query waits for
/// the user's answer on the search-after-messages card (gate 3).
struct WebSearchTool: AgentToolbox {
  private let search: @Sendable (String) async throws -> [WebSearchResult]
  private let mayQuery: @Sendable (String) async -> Bool
  private let onSources: @Sendable ([WebSearchSource]) async -> Void

  init(search: @escaping @Sendable (String) async throws -> [WebSearchResult],
       mayQuery: @escaping @Sendable (String) async -> Bool,
       onSources: @escaping @Sendable ([WebSearchSource]) async -> Void) {
    self.search = search
    self.mayQuery = mayQuery
    self.onSources = onSources
  }

  var instructions: String {
    """
    Use web_search for facts that change or that you may not know: news, prices, schedules, weather, recent events, and specific pages. Don't search for things you already know well, for the user's own data, or to answer from Messages or an attached selection. Write a short, specific query. Cite the sources you use.
    """
  }

  var definitions: [AgentToolDefinition] {
    [AgentToolDefinition(name: "web_search",
      description: "Search the web. Returns the top results with their title, URL and relevant snippets.",
      properties: ["query": .object(["type": .string("string"),
        "description": .string("What to search for, in a few words.")])],
      required: ["query"])]
  }

  func phase(for _: String) -> AssistantActivity.Phase { .searching }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    guard name == "web_search", case .object(let fields) = arguments, fields.keys.allSatisfy({ $0 == "query" }),
          let raw = fields["query"]?.string else {
      return AgentToolResult(text: "Invalid tool arguments: call web_search with {\"query\": string}.", success: false)
    }
    // The card shows the query on one line; the search engine gets exactly what it showed.
    let query = ToolPermissionRequest.oneLine(raw)
    guard !query.isEmpty else { return AgentToolResult(text: WebSearchError.emptyQuery.localizedDescription, success: false) }
    guard await mayQuery(query) else {
      // Stop while the card was open counts as Don't allow, and ends the request.
      if Task.isCancelled { return Self.stopped }
      return AgentToolResult(text: MessagesTools.declinedResult, success: false)
    }
    do {
      let results = try await search(query)
      try Task.checkCancellation()
      await onSources(results.map(\.source))
      let output = CodexValue.object(["results": .array(results.map { result in
        .object(["title": .string(result.source.title), "url": .string(result.source.url.absoluteString),
                 "snippets": .array(result.snippets.map(CodexValue.string))])
      })])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return AgentToolResult(text: String(decoding: try encoder.encode(output), as: UTF8.self), success: true)
    } catch is CancellationError {
      return Self.stopped
    } catch {
      return AgentToolResult(text: error.localizedDescription, success: false)
    }
  }

  private static let stopped = AgentToolResult(text: "The request was stopped.", success: false, terminal: true, stop: .cancelled)
}
