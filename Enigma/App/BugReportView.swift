import SwiftUI

/// Report a Bug (F12): a short form that becomes an email in the user's mail app. Opened from
/// Help, Settings → About, and the menu-bar menu.
struct BugReportView: View {
  @ObservedObject var chat: LocalChatViewModel
  let diagnostics: BugReport.Diagnostics
  let recipient: String?
  let close: () -> Void
  /// The email is open: the form stops floating over the mail app.
  let composed: () -> Void
  @State private var report: BugReport
  @State private var notice: String?
  @Environment(\.enigmaPalette) private var palette

  static let size = CGSize(width: 520, height: 580)
  static let noChatsNote = "No saved chats to include. Temporary chats are never saved."
  static func composedNote(recipient: String) -> String {
    "The email is open in your mail app. If none opened, send the text under What will be sent to \(recipient)."
  }
  static let noAttachmentsNote = "Your mail app can’t take attachments this way. Drag the log files shown in Finder into the email."

  init(chat: LocalChatViewModel, diagnostics: BugReport.Diagnostics, recipient: String?, close: @escaping () -> Void,
       composed: @escaping () -> Void = {}) {
    self.chat = chat
    self.diagnostics = diagnostics
    self.recipient = recipient
    self.close = close
    self.composed = composed
    var report = BugReport()
    report.chatID = BugReport.defaultChatID(in: chat)
    _report = State(initialValue: report)
  }

  private var chats: [ChatSession] { BugReport.chats(in: chat) }
  private var chosenChat: ChatSession? { chats.first { $0.id == report.chatID } }
  private var email: String { report.body(diagnostics: diagnostics, chat: chosenChat) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Report a bug")
        .font(EnigmaTypography.ui(20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 28)
        .padding(.top, 24)
      Text("Opens an email in your mail app. Nothing is sent until you send it there.")
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
    .onExitCommand(perform: close)
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
        Text(verbatim: "To: \(recipient ?? "")\nSubject: \(BugReport.subject)\n\n" + email)
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

  private var footer: some View {
    HStack(spacing: 10) {
      if let notice {
        Text(notice)
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button(notice == nil ? "Cancel" : "Close", action: close)
        .enigmaButtonStyle(.secondary)
        .keyboardShortcut(.cancelAction)
      Button("Create Email", action: send)
        .enigmaButtonStyle(.primary)
        .disabled(!report.canSend || recipient == nil)
        .enigmaTestMarker("Create Email")
    }
  }

  private func send() {
    guard let recipient else { return }
    let attachments = report.includesLogs ? EnigmaLog.shared.files : []
    EnigmaLog.event("Bug report created")
    switch BugReportMailer.send(to: recipient, body: email, attachments: attachments) {
    // The form stays open with its draft: a mail app still being set up may show no email.
    case .composed:
      notice = Self.composedNote(recipient: recipient)
      composed()
    case .composedWithoutAttachments:
      notice = Self.noAttachmentsNote
      composed()
    case .failed: notice = "No mail app could open the report. Email it to \(recipient)."
    }
  }
}
