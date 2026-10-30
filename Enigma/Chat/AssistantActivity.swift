import Foundation

/// Shared by retrieval, local inference orchestration, and cloud provider adapters.
enum AssistantActivityEvent: Sendable, Equatable {
  case phase(AssistantActivity.Phase)
  case sourcesDiscovered([WebSearchSource])
  case sourcesSelected([WebSearchSource])
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

  var sourceSummary: String { "\(sources.count) " + (sources.count == 1 ? "source" : "sources") }

  var status: String {
    if phase == .readingSources { return sources.isEmpty ? "Reading sources…" : "Reading sources (\(sources.count))…" }
    if phase.isTerminal && !sources.isEmpty { return "\(phase.label) · \(sourceSummary)" }
    return phase.label
  }

  mutating func apply(_ event: AssistantActivityEvent) {
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
