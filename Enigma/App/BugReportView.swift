import SwiftUI

/// Report a Bug (F12): a short form sent straight from Enigma, anonymously unless the user adds their
/// email. If sending fails it can become an email in the user's mail app instead. Opened from the
/// ladybug, Help, Settings → About, and the menu-bar menu.
struct BugReportView: View {
  @ObservedObject var chat: LocalChatViewModel
  let diagnostics: BugReport.Diagnostics
  let recipient: String?
  let endpoint: URL?
  let transport: CloudNetworkTransport
  let close: () -> Void
  /// The email is open: the form stops floating over the mail app.
  let composed: () -> Void
  @State private var report: BugReport
  @State private var notice: String?
  @State private var logText = ""
  @State private var sending: Task<Void, Never>?
  @State private var sent = false
  @State private var sendFailed = false
  @Environment(\.enigmaPalette) private var palette

  static let size = CGSize(width: 520, height: 580)
  static let noChatsNote = "No saved chats to include. Temporary chats are never saved."
  static func composedNote(recipient: String) -> String {
    "The email is open in your mail app. If none opened, send the text under What will be sent to \(recipient)."
  }
  static let subtitle = "Sent straight from Enigma. It’s anonymous unless you add your email."
  static let sentNote = "Sent. Thank you for the report."
  static let sendFailedNote = "Couldn’t send the report. Try again later, or email it instead."

  /// `draft` starts the form filled in, for tests.
  init(chat: LocalChatViewModel, diagnostics: BugReport.Diagnostics, recipient: String?, endpoint: URL?,
       transport: CloudNetworkTransport = BugReportSender.transport, draft: BugReport = BugReport(),
       close: @escaping () -> Void, composed: @escaping () -> Void = {}) {
    self.chat = chat
    self.diagnostics = diagnostics
    self.recipient = recipient
    self.endpoint = endpoint
    self.transport = transport
    self.close = close
    self.composed = composed
    var report = draft
    report.chatID = report.chatID ?? BugReport.defaultChatID(in: chat)
    _report = State(initialValue: report)
  }

  private var chats: [ChatSession] { BugReport.chats(in: chat) }
  private var chosenChat: ChatSession? { chats.first { $0.id == report.chatID } }
  private var isSending: Bool { sending != nil }
  /// Sending failed or isn't set up: the report goes by email.
  private var emails: Bool { sendFailed || endpoint == nil }
  private var message: String { report.body(diagnostics: diagnostics, chat: chosenChat, logs: logText) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Report a bug")
        .font(EnigmaTypography.ui(20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 28)
        .padding(.top, 24)
      Text(Self.subtitle)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 12)
      ScrollView {
        form
          .padding(.horizontal, 28)
          .padding(.bottom, 16)
      }
      .scrollBounceBehavior(.basedOnSize)
      EnigmaHairline()
      footer
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .enigmaMenuHost()
    .onExitCommand(perform: dismiss)
    .onDisappear { sending?.cancel() }
    .onChange(of: report.includesLogs) { _, includes in logText = includes ? EnigmaLog.shared.text() : "" }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        EnigmaTextField("What happened?", text: $report.whatHappened, accessibilityLabel: "What happened", minHeight: 54)
        EnigmaTextField("Steps to reproduce (optional)", text: $report.steps, accessibilityLabel: "Steps to reproduce",
                        minHeight: 36)
        EnigmaTextField("Your email, if you’d like a reply (optional)", text: $report.contactEmail,
                        accessibilityLabel: "Contact email")
      }
      .padding(.bottom, 12)
      EnigmaHairline()
      EnigmaRow("Include logs", info: BugReport.logsNote) {
        EnigmaSwitch("Include logs", isOn: $report.includesLogs)
      }
      EnigmaHairline()
      EnigmaRow("Include this conversation") {
        EnigmaSwitch("Include this conversation", isOn: $report.includesConversation)
      }
      .disabled(chats.isEmpty)
      EnigmaNote(chats.isEmpty ? Self.noChatsNote : BugReport.sensitiveNote)
        .padding(.bottom, 10)
      if report.includesConversation, !chats.isEmpty {
        EnigmaRow("Chat") {
          EnigmaMenu("Chat", selection: $report.chatID,
                     options: chats.map { EnigmaOption(Optional($0.id), $0.title) }, placeholder: "Choose a chat")
        }
        EnigmaNote(BugReport.textOnlyNote).padding(.bottom, 10)
      }
      EnigmaHairline()
      EnigmaDisclosure("What will be sent") {
        Text(verbatim: preview)
          .font(EnigmaTypography.mono(11.5))
          .foregroundStyle(palette.textSecondary.color)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(palette.surface.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .enigmaEdge(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .padding(.top, 10)
    }
  }

  private var preview: String {
    let replyTo = report.replyTo.map { "\nReply to: \($0)" } ?? ""
    return "To: \(recipient ?? "")\(emails ? "" : ", via Formspree")\(replyTo)\nSubject: \(BugReport.subject)\n\n" + message
  }

  private var footer: some View {
    VStack(alignment: .trailing, spacing: 10) {
      if let notice {
        Text(notice)
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: 10) {
        Spacer()
        Button(notice == nil ? "Cancel" : "Close", action: dismiss)
          .enigmaButtonStyle(.secondary)
          .keyboardShortcut(.cancelAction)
        if emails {
          Button("Email Instead", action: createEmail)
            .enigmaButtonStyle(.secondary)
            .disabled(recipient == nil)
            .enigmaTestMarker("Email Instead")
        }
        Button(isSending ? "Sending…" : "Send Report", action: send)
          .enigmaButtonStyle(.primary)
          .enigmaTestMarker("Send Report")
          .disabled(!report.canSend || endpoint == nil || isSending || sent)
      }
    }
  }

  /// Cancel stops a report still on its way; one that already reached Formspree still arrives.
  private func dismiss() {
    sending?.cancel()
    close()
  }

  private func send() {
    guard let endpoint, !isSending, !sent else { return }
    let request = BugReportSender.request(endpoint: endpoint, body: message, replyTo: report.replyTo)
    notice = nil
    sending = Task {
      let delivered = await BugReportSender.send(request, transport: transport)
      guard !Task.isCancelled else { return }
      EnigmaLog.event(delivered ? "Bug report sent" : "Bug report failed to send")
      sending = nil
      sent = delivered
      sendFailed = !delivered
      show(delivered ? Self.sentNote : Self.sendFailedNote)
    }
  }

  private func createEmail() {
    guard let recipient else { return }
    EnigmaLog.event("Bug report created")
    // The form stays open with its draft: a mail app still being set up may show no email.
    guard BugReportMailer.send(to: recipient, body: message) else {
      return show("No mail app could open the report. Email it to \(recipient).")
    }
    show(Self.composedNote(recipient: recipient))
    composed()
  }

  private func show(_ text: String) {
    notice = text
    AccessibilityNotification.Announcement(text).post()
  }
}
