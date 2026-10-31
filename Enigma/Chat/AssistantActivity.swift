import Foundation

/// Shared by retrieval, local inference orchestration, and cloud provider adapters.
enum AssistantActivityEvent: Sendable, Equatable {
  case phase(AssistantActivity.Phase)
  case sourcesDiscovered([WebSearchSource])
  case sourcesSelected([WebSearchSource])
  /// One line shown above the reply, such as a switch to another free model (F34).
  case notice(String)
  /// The free pool answered on a model other than the chosen one (F34): its display name.
  case answeredBy(String)
}

struct AssistantActivity: Sendable, Equatable, Identifiable {
  enum Phase: String, Sendable, Equatable {
    case analyzing, refiningSearch, searching, readingSources, thinking, generating
    case readingMessages, awaitingApproval
    /// `find_places` and `get_weather` (F29): searching, with their own text (D82).
    case findingPlaces, checkingWeather
    case completed, cancelled, failed

    var label: String {
      switch self {
      case .analyzing: "Analyzing query…"
      case .refiningSearch: "Preparing search query…"
      case .searching: "Searching…"
      case .readingSources: "Reading sources…"
      case .thinking: "Thinking…"
      case .generating: "Generating response…"
      case .readingMessages: "Reading Messages…"
      case .findingPlaces: "Finding places…"
      case .checkingWeather: "Checking the weather…"
      case .awaitingApproval: "Waiting for your approval…"
      case .completed: "Activity"
      case .cancelled: "Stopped"
      case .failed: "Request failed"
      }
    }

    var isTerminal: Bool { self == .completed || self == .cancelled || self == .failed }
    var isSearching: Bool { self == .searching || self == .findingPlaces || self == .checkingWeather }
  }

  let id: UUID
  private(set) var phase: Phase = .analyzing
  private(set) var phases: [Phase] = [.analyzing]
  private(set) var sources: [WebSearchSource] = []
  private(set) var selectedSourceIDs: Set<URL>?
  private(set) var notice: String?
  private(set) var answeredBy: String?

  var sourceSummary: String { "\(sources.count) " + (sources.count == 1 ? "source" : "sources") }

  var status: String {
    if phase == .readingSources { return sources.isEmpty ? "Reading sources…" : "Reading sources (\(sources.count))…" }
    if phase.isTerminal && !sources.isEmpty { return "\(phase.label) · \(sourceSummary)" }
    return phase.label
  }

  mutating func apply(_ event: AssistantActivityEvent) {
    // A notice can arrive once the reply has ended (the local fallback names itself last).
    if case .notice(let text) = event { notice = text; return }
    if case .answeredBy(let model) = event { answeredBy = model; return }
    guard !phase.isTerminal else { return }
    switch event {
    case .phase(let next):
      guard phase != next else { return }
      phase = next
      if !phases.contains(next) { phases.append(next) }
    case .sourcesDiscovered(let found):
      for source in found where source.isSafeWebLink && (selectedSourceIDs?.contains(source.id) ?? true) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
        else { sources.append(source) }
      }
      if !sources.isEmpty && phase != .generating { apply(.phase(.readingSources)) }
    case .sourcesSelected(let selected):
      sources = []
      selectedSourceIDs = Set(selected.filter(\.isSafeWebLink).map(\.id))
      apply(.sourcesDiscovered(selected))
    case .notice, .answeredBy: break
    }
  }

  static func savedSources(_ sources: [WebSearchSource], messageID: UUID) -> Self {
    var activity = Self(id: messageID)
    activity.apply(.sourcesSelected(sources))
    activity.apply(.phase(.completed))
    // Older history stores source references, not a timeline of processing events.
    activity.phases = []
    return activity
  }
}

extension WebSearchSource {
  var isSafeWebLink: Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
      && url.user == nil && url.password == nil
  }

  var siteName: String {
    let host = url.host ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

extension WebSearchSource {
  /// "Never use this site" isn't offered on Apple Maps or Open-Meteo sources (spec §8).
  var allowsBlocking: Bool {
    guard isSafeWebLink, let host = url.host(percentEncoded: false)?.lowercased() else { return false }
    return !["maps.apple.com", "open-meteo.com"].contains { host == $0 || host.hasSuffix("." + $0) }
  }
}

/// What a source row's "Never use this site" does (spec §8). The shell sets it for the main window
/// and the compact panel; without it, rows offer no action.
struct SourceBlocking {
  /// The registrable domain, by the same rule as `WebSearchSettings.block(_:)`.
  var domain: @MainActor (URL) -> String
  var block: @MainActor (URL) -> Void
  var unblock: @MainActor (String) -> Void

  /// The context-menu item and accessibility action, such as "Never use bbc.co.uk".
  @MainActor func neverUseLabel(for url: URL) -> String { "Never use \(domain(url))" }
}

extension SourceBlocking {
  @MainActor init(settings: WebSearchSettings) {
    self.init(domain: { settings.domain(of: $0) ?? WebSearchSource(title: "", url: $0).siteName },
              block: { settings.block($0) }, unblock: { settings.unblock($0) })
  }
}
