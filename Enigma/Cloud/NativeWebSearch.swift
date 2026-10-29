import Foundation

/// A cloud model's own web search, offered instead of Enigma's `web_search` where privacy
/// allows (F30). The four provider routes share these rules.
enum NativeWebSearch {
  static let maximumSearches = 5
  static let maximumSources = 8

  /// Whether a flagged cloud turn may use the provider's search: a provider that's on (never
  /// Gemini), in a chat without message text, with a provider and model not marked unavailable.
  static func isAllowed(provider: CloudProviderID, modelID: String, holdsMessageText: Bool,
                        enabledProviders: Set<CloudProviderID>,
                        availability: NativeWebSearchAvailability) -> Bool {
    provider != .gemini && enabledProviders.contains(provider) && !holdsMessageText
      && availability.isAvailable(provider, modelID: modelID)
  }

  /// The sources a reply shows and saves (spec §5): the cited pages, then the answer's other
  /// links, or the results the model saw when neither gives one. Only safe web links, one per
  /// page (fragments ignored), the site name for a missing title, at most `maximumSources`.
  static func selectSources(cited: [WebSearchSource], linked: [URL],
                            discovered: [WebSearchSource]) -> [WebSearchSource] {
    let known = cited + discovered
    let chosen = tidy(cited + linked.map { source(for: $0, known: known) })
    return chosen.isEmpty ? tidy(discovered) : chosen
  }

  /// Markdown links (not images) and bare http(s) URLs, first-seen order, no duplicates.
  static func links(in text: String) -> [URL] {
    var links: [URL] = []
    var seen = Set<String>()
    let range = NSRange(text.startIndex..., in: text)
    for match in linkPattern.matches(in: text, range: range) {
      func group(_ index: Int) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
      let candidate: String
      if let destination = group(2) {
        guard group(1) != "!" else { continue }
        candidate = destination
      } else if let angled = group(3) {
        candidate = angled
      } else if let bare = group(4) {
        candidate = trimmed(bare)
      } else {
        continue
      }
      guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, seen.insert(url.absoluteString).inserted else { continue }
      links.append(url)
    }
    return links
  }

  // A Markdown link or image (its destination may hold one level of parentheses), an autolink
  // in angle brackets, or a bare URL.
  private static let linkPattern = try! NSRegularExpression(pattern:
    #"(!?)\[(?:[^\[\]\n]|\[[^\[\]\n]*\])*\]\(\s*<?((?:[^()\s<>]|\([^()\s]*\))+)>?(?:\s+"[^"]*")?\s*\)"#
      + #"|<(https?://[^\s<>]+)>"#
      + #"|(https?://[^\s<>\[\]"'`]+)"#,
    options: [.caseInsensitive])

  /// Drops sentence punctuation after a bare URL, and a closing parenthesis it didn't open.
  private static func trimmed(_ url: String) -> String {
    var url = Substring(url)
    while let last = url.last {
      if ".,;:!?*_~".contains(last) {
        url.removeLast()
      } else if last == ")", url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
        url.removeLast()
      } else {
        break
      }
    }
    return String(url)
  }

  /// Compares pages without their fragment.
  private static func pageKey(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    components.fragment = nil
    return components.string ?? url.absoluteString
  }

  /// A link as a source, titled by the search result or citation it came from.
  fileprivate static func source(for url: URL, known: [WebSearchSource]) -> WebSearchSource {
    let key = pageKey(url)
    let title = known.first {
      pageKey($0.url) == key && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.title
    return WebSearchSource(title: title ?? "", url: url)
  }

  private static func tidy(_ sources: [WebSearchSource]) -> [WebSearchSource] {
    var tidied: [WebSearchSource] = []
    var seen = Set<String>()
    for source in sources where source.isSafeWebLink && seen.insert(pageKey(source.url)).inserted {
      let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
      tidied.append(WebSearchSource(title: title.isEmpty ? source.siteName : title, url: source.url))
      if tidied.count == maximumSources { break }
    }
    return tidied
  }
}

/// Providers and models whose search failed this run, so later turns skip it. Memory only.
struct NativeWebSearchAvailability: Equatable, Sendable {
  private struct Pair: Hashable, Sendable {
    let provider: CloudProviderID
    let modelID: String
  }

  private var unavailable: Set<Pair> = []

  mutating func markUnavailable(_ provider: CloudProviderID, modelID: String) {
    unavailable.insert(Pair(provider: provider, modelID: modelID))
  }

  func isAvailable(_ provider: CloudProviderID, modelID: String) -> Bool {
    !unavailable.contains(Pair(provider: provider, modelID: modelID))
  }
}

/// One request's search bookkeeping, shared by the four clients: what the searches found, what
/// the answer cites, and the answer's text for its links.
struct NativeWebSearchSources: Sendable {
  private var discoveredSources: [WebSearchSource] = []
  private var citedSources: [WebSearchSource] = []
  private var answer = ""
  /// A search returned results, or the answer cited one.
  private(set) var searched = false

  mutating func discovered(_ sources: [WebSearchSource]) {
    searched = true
    discoveredSources += sources
  }

  mutating func cited(_ source: WebSearchSource) {
    searched = true
    citedSources.append(source)
  }

  mutating func answered(_ text: String) {
    answer += text
  }

  /// `selectSources` over what was collected. `linksAreCitations` for Codex and Claude Code,
  /// whose answers' links are their citations, in the order the answer gives them.
  func selection(linksAreCitations: Bool) -> [WebSearchSource] {
    let links = NativeWebSearch.links(in: answer)
    guard linksAreCitations else {
      return NativeWebSearch.selectSources(cited: citedSources, linked: links, discovered: discoveredSources)
    }
    let known = citedSources + discoveredSources
    return NativeWebSearch.selectSources(cited: links.map { NativeWebSearch.source(for: $0, known: known) } + citedSources,
                                         linked: [], discovered: discoveredSources)
  }
}

/// Raised by the Messages gate to stop a provider-search request before message text reaches it,
/// so the turn runs again without provider search (spec §2). Never shown as Stop or as an error.
struct ProviderSearchRestart: Error, Equatable {}

/// The provider-search instruction (spec §4) as a toolbox part with no definitions: the provider's
/// own tool is added by its client, and the system prompt stays assembled in `AssistantToolbox`.
struct ProviderSearchPart: AgentToolbox {
  /// The instruction names at most this many blocked sites, most recently blocked first.
  static let maximumNamedBlockedDomains = 20

  private let today: String
  let blockedDomains: [String]
  let location: ProviderSearchLocation?

  init(today: Date = Date(), timeZone: TimeZone = .current, blockedDomains: [String] = [],
       location: ProviderSearchLocation? = nil) {
    self.today = WebSearchTool.formattedDate(today, timeZone: timeZone)
    self.blockedDomains = blockedDomains
    self.location = location
  }

  var instructions: String {
    let area = location?.displayName ?? ""
    let nearMe = area.isEmpty
      ? "You don't know where the user is: for places or weather near them, ask which city they mean."
      : "The user's approximate location is \(area); your web search tool uses it for places and weather near them."
    var text = "Today is \(today). You can search the web with your web search tool. Use it for facts that change or that you may not know: news, prices, schedules, weather, recent events, and specific pages. You can't see live information yourself, so when a question depends on it, search instead of saying you can't look it up or asking for the date. Don't search for things you already know well, for the user's own data, or to answer from Messages or an attached selection. Search at most \(NativeWebSearch.maximumSearches) times. Never put personal details, credentials, file contents, or text from messages into a search query. \(nearMe) Link the pages you rely on."
    if !blockedDomains.isEmpty {
      text += " Don't use results from these sites: "
        + blockedDomains.prefix(Self.maximumNamedBlockedDomains).joined(separator: ", ") + "."
    }
    return text
  }

  var definitions: [AgentToolDefinition] { [] }

  func phase(for _: String) -> AssistantActivity.Phase { .searching }

  func execute(name: String, arguments _: CodexValue) async -> AgentToolResult {
    AgentToolResult(text: "Unknown tool \(name). Use only the tools you were given.", success: false)
  }
}
