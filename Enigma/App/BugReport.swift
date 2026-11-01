import AppKit

/// A bug report (F12): the form's fields, and the report they make. Diagnostics go in
/// automatically; the chat's text only when the user turns on Include this conversation.
struct BugReport: Equatable {
  static let recipientKey = "EnigmaBugReportEmail"
  static let endpointKey = "EnigmaBugReportURL"
  static let subject = "Enigma bug report"
  static let sensitiveNote = "Never turn this on if the chat contains anything sensitive, such as passwords, personal or financial details, or private messages."
  static let textOnlyNote = "Only the chat’s text is sent: no attachments, screenshots, file contents, selected text or Messages data, unless they’re already in the text."
  static let logsNote = "What Enigma did, such as launches, requests and errors. Never chat text or model output."

  var whatHappened = ""
  var steps = ""
  var contactEmail = ""
  var includesLogs = false
  var includesConversation = false
  /// The chat to include: the open one by default. Temporary chats are never offered.
  var chatID: UUID?

  var canSend: Bool { !Self.trimmed(whatHappened).isEmpty }

  /// The contact email, when it looks like an address: the report's reply-to. Anything else stays in the text only.
  var replyTo: String? {
    let address = Self.trimmed(contactEmail)
    return address.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil ? address : nil
  }

  struct Diagnostics: Equatable {
    var appVersion: String
    var macOS: String
    var chip: String
    var memory: String
    /// The route and model of the last request this launch, if any.
    var route: String?
    var localModel: String?
    var cloudModel: String?
  }

  /// The chats a report can include: saved ones with messages. Temporary chats are never saved, so never offered.
  @MainActor
  static func chats(in chat: LocalChatViewModel) -> [ChatSession] {
    chat.historySessions.filter { !$0.messages.isEmpty }
  }

  /// The open chat, if it's one of `chats(in:)`.
  @MainActor
  static func defaultChatID(in chat: LocalChatViewModel) -> UUID? {
    chats(in: chat).contains { $0.id == chat.selectedSessionID } ? chat.selectedSessionID : nil
  }

  static func recipient(info: [String: Any]) -> String? {
    guard let address = (info[recipientKey] as? String).map(trimmed), !address.isEmpty else { return nil }
    return address
  }

  /// The endpoint reports are sent to, from Info.plist. HTTPS only.
  static func endpoint(info: [String: Any]) -> URL? {
    guard let url = (info[endpointKey] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
    return url
  }

  /// `logs` is the log's text, from `EnigmaLog.text(limit:)`: used only when `includesLogs` is on.
  func body(diagnostics: Diagnostics, chat: ChatSession?, logs: String) -> String {
    var sections = ["What happened\n" + Self.trimmed(whatHappened)]
    if !Self.trimmed(steps).isEmpty { sections.append("Steps to reproduce\n" + Self.trimmed(steps)) }
    if !Self.trimmed(contactEmail).isEmpty { sections.append("Contact: " + Self.trimmed(contactEmail)) }
    let included = includesConversation ? chat : nil
    sections.append([
      "Diagnostics",
      "Enigma: \(diagnostics.appVersion)",
      "macOS: \(diagnostics.macOS)",
      "Chip: \(diagnostics.chip)",
      "Memory: \(diagnostics.memory)",
      "Last route: \(diagnostics.route ?? "none this launch")",
      "Local model: \(diagnostics.localModel ?? "none")",
      "Cloud model: \(diagnostics.cloudModel ?? "none")",
      "Logs: \(includesLogs ? "below" : "not included")",
      included == nil ? "Conversation: not included" : nil,
    ].compactMap { $0 }.joined(separator: "\n"))
    if let included { sections.append("Conversation (“\(included.title)”, text only)\n" + Self.transcript(included)) }
    if includesLogs { sections.append("Logs\n" + (logs.isEmpty ? "No events yet" : logs)) }
    return sections.joined(separator: "\n\n")
  }

  /// The chat's visible text, nothing else: attachments, contexts and images stay out.
  static func transcript(_ chat: ChatSession) -> String {
    chat.messages.map { ($0.role == .user ? "You: " : "Enigma: ") + $0.content }.joined(separator: "\n\n")
  }

  // shortcut: a very long body can pass what a mail app accepts in a mailto: link; truncate if that's reported.
  static func mailtoURL(recipient: String, subject: String, body: String) -> URL? {
    // URLQueryItem leaves "&", "=" and "+" alone, which would split or change a field.
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
    func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = recipient
    components.percentEncodedQuery = "subject=\(encoded(subject))&body=\(encoded(body))"
    return components.url
  }

  private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Sends a report straight from Enigma to the bug report form (Formspree), which emails it on. Anonymous:
/// no name or address goes with it unless the user typed one for a reply.
enum BugReportSender {
  // Ephemeral: no cookies or cache kept between reports.
  static let transport = URLSessionCloudTransport(session: URLSession(configuration: .ephemeral))

  static func request(endpoint: URL, body: String, replyTo: String?) -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var fields = ["_subject": BugReport.subject, "message": body]
    // Formspree makes `email` the reply-to address.
    if let replyTo { fields["email"] = replyTo }
    request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
    return request
  }

  static func send(_ request: URLRequest, transport: CloudNetworkTransport = transport) async -> Bool {
    guard let response = try? await transport.data(for: request) else { return false }
    return (200..<300).contains(response.statusCode)
  }
}

/// Hands a report to the user's mail app, ready to send: the fallback when sending from Enigma fails.
@MainActor
enum BugReportMailer {
  nonisolated static let mailBundleID = "com.apple.mail"

  /// Mail's sharing service only for Mail; a mailto: link for any other default mail app.
  nonisolated static func usesMailService(defaultMailApp bundleID: String?) -> Bool { bundleID == mailBundleID }

  /// Mail, when it's the default mail app, gets the email through its sharing service. Any other default
  /// (like a browser for web mail) gets a mailto: link, so the email opens where the user reads mail.
  /// False when nothing could open it.
  static func send(to recipient: String, body: String) -> Bool {
    let items: [Any] = [body]
    let defaultApp = URL(string: "mailto:").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))
    if usesMailService(defaultMailApp: defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }),
       let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
      service.recipients = [recipient]
      service.subject = BugReport.subject
      service.perform(withItems: items)
      return true
    }
    guard let url = BugReport.mailtoURL(recipient: recipient, subject: BugReport.subject, body: body) else { return false }
    return NSWorkspace.shared.open(url)
  }
}

extension BugReport.Diagnostics {
  /// This Mac and Enigma now. Read when the form opens.
  @MainActor
  static func current(chat: LocalChatViewModel = .shared, cloud: CloudSettingsModel = .shared,
                      hardware: LocalHardwareProfile? = LocalModelAdvisor.shared.hardware) -> Self {
    let process = ProcessInfo.processInfo
    return Self(
      appVersion: AppUpdater.versionText(info: Bundle.main.infoDictionary ?? [:]),
      macOS: process.operatingSystemVersionString,
      chip: hardware?.chip ?? "Unknown",
      memory: Int64(process.physicalMemory).formatted(.byteCount(style: .memory)),
      route: chat.lastRouteName,
      localModel: chat.installedModel?.displayName,
      cloudModel: cloud.preferredModelID.isEmpty ? nil : "\(cloud.preferredProvider.displayName) · \(cloud.preferredModelID)")
  }
}
