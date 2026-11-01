import AppKit

/// A bug report (F12): the form's fields, and the email they make. Diagnostics go in
/// automatically; the chat's text only when the user turns on Include this conversation.
struct BugReport: Equatable {
  static let recipientKey = "EnigmaBugReportEmail"
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

  func body(diagnostics: Diagnostics, chat: ChatSession?) -> String {
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
      "Logs: \(includesLogs ? "attached" : "not included")",
      included == nil ? "Conversation: not included" : nil,
    ].compactMap { $0 }.joined(separator: "\n"))
    if let included { sections.append("Conversation (“\(included.title)”, text only)\n" + Self.transcript(included)) }
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

/// Hands a report to the user's mail app, ready to send. Nothing is sent from Enigma itself.
@MainActor
enum BugReportMailer {
  enum Outcome: Equatable {
    case composed
    /// The mail app opened from a mailto: link, which can't carry attachments: the logs are shown in Finder.
    case composedWithoutAttachments
    case failed
  }

  nonisolated static let mailBundleID = "com.apple.mail"

  /// Mail's sharing service only for Mail; a mailto: link for any other default mail app.
  nonisolated static func usesMailService(defaultMailApp bundleID: String?) -> Bool { bundleID == mailBundleID }

  /// Mail, when it's the default mail app, gets the email with its attachments. Any other default
  /// (like a browser for web mail) gets a mailto: link, so the email opens where the user reads mail.
  static func send(to recipient: String, body: String, attachments: [URL]) -> Outcome {
    let items: [Any] = [body] + attachments
    let defaultApp = URL(string: "mailto:").flatMap(NSWorkspace.shared.urlForApplication(toOpen:))
    if usesMailService(defaultMailApp: defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }),
       let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
      service.recipients = [recipient]
      service.subject = BugReport.subject
      service.perform(withItems: items)
      return .composed
    }
    guard let url = BugReport.mailtoURL(recipient: recipient, subject: BugReport.subject, body: body),
          NSWorkspace.shared.open(url) else { return .failed }
    guard !attachments.isEmpty else { return .composed }
    NSWorkspace.shared.activateFileViewerSelecting(attachments)
    return .composedWithoutAttachments
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
