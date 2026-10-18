import Contacts
import SwiftUI

/// Shows exactly who will receive what, and sends only on an explicit choice.
struct MessagesSendApprovalCard: View {
  let approval: MessagesSendApproval
  let answer: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Send this message?", image: "MessagesTool")
        .font(.headline).foregroundStyle(MessagesStyle.tint)
      VStack(alignment: .leading, spacing: 4) {
        if let name = approval.conversationName {
          Text("Group: \(name)").font(.caption.weight(.semibold))
        }
        ForEach(Array(approval.recipients.enumerated()), id: \.offset) { _, recipient in
          HStack(spacing: 6) {
            Text(recipient.name ?? recipient.handle).font(.caption.weight(.semibold))
            if recipient.name != nil { Text(recipient.handle).font(.caption).foregroundStyle(.secondary) }
          }
        }
        Text("Via \(approval.service)").font(.caption2).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("To " + approval.recipients.map { [$0.name, $0.handle].compactMap { $0 }.joined(separator: ", ") }
        .joined(separator: "; "))
      ScrollView {
        Text(approval.text)
          .font(.body).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(maxHeight: 160)
      .fixedSize(horizontal: false, vertical: true)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityLabel("Message text")
      .accessibilityValue(approval.text)
      HStack {
        Text("Enigma sends only if you choose Send.").font(.caption2).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button("Don't Send", role: .cancel) { answer(false) }
          .keyboardShortcut(.cancelAction)
        Button("Send") { answer(true) }
          .buttonStyle(.borderedProminent).tint(MessagesStyle.tint)
      }
      .controlSize(.small)
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 12)
  }
}

struct MessagesIssueView: View {
  let issue: MessagesIssue
  let openSettings: (MessagesPrivacyPane) -> Void
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(issue.message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if let pane = issue.pane {
          Button(pane == .fullDiskAccess ? "Open Full Disk Access Settings…" : "Open Automation Settings…") { openSettings(pane) }
            .buttonStyle(.borderedProminent)
        }
        Button("Dismiss", action: dismiss).buttonStyle(.bordered)
      }
      .controlSize(.small)
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading).natureSurface(radius: 12)
  }
}

struct MessagesDialogs: ViewModifier {
  @ObservedObject var messages: MessagesCoordinator
  let submit: (String) -> Void

  private var disclosurePresented: Binding<Bool> {
    Binding(get: { messages.cloudDisclosure != nil }, set: { if !$0 { _ = messages.answerDisclosure(allow: false) } })
  }

  func body(content: Content) -> some View {
    content.alert("Use Messages with \(messages.cloudDisclosure?.displayName ?? "the cloud")?", isPresented: disclosurePresented) {
      Button("Continue") { if let prompt = messages.answerDisclosure(allow: true) { submit(prompt) } }
      Button("Cancel", role: .cancel) { _ = messages.answerDisclosure(allow: false) }
    } message: {
      Text("With /messages, the conversations, names, and phone numbers the model looks up are sent to \(messages.cloudDisclosure?.displayName ?? "your cloud provider") to answer. Choose Local or Auto to keep Messages on this Mac. Enigma asks before sending any message.")
    }
  }
}

/// Settings → General: what /messages needs from macOS and where its data goes.
struct MessagesSettingsSection: View {
  @State private var fullDiskAccess: Bool?
  @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)

  var body: some View {
    Section("Messages · /messages") {
      status("Full Disk Access", enabled: fullDiskAccess == true,
        detail: fullDiskAccess == nil ? "Messages has no history on this Mac yet." : "Required to read and search your Messages history. Enigma opens it read-only.",
        button: "Open Full Disk Access Settings…", pane: .fullDiskAccess)
      status("Contacts", enabled: contacts == .authorized,
        detail: "Optional. Shows names instead of phone numbers and finds people by name. macOS asks the first time you use /messages.",
        button: "Open Contacts Settings…", pane: .contacts)
      VStack(alignment: .leading, spacing: 6) {
        Text("Automation").font(.headline)
        Text("macOS asks to let Enigma control Messages the first time you approve a send. If you declined, turn on Messages under Enigma.")
          .font(.subheadline)
        Button("Open Automation Settings…") { NSWorkspace.shared.open(MessagesPrivacyPane.automation.url) }
      }
      Text("Every send waits for your approval of the recipient and exact text. With a local model or Auto, Messages stays on this Mac. With a cloud model, the messages and contacts it looks up are sent to that provider.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
  }

  private func refresh() {
    contacts = CNContactStore.authorizationStatus(for: .contacts)
    do { try MessagesDatabase().checkAccess(); fullDiskAccess = true }
    catch MessagesError.databaseMissing { fullDiskAccess = nil }
    catch { fullDiskAccess = false }
  }

  private func status(_ title: String, enabled: Bool, detail: String, button: String, pane: MessagesPrivacyPane) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("\(title) · \(enabled ? "Enabled" : "Action needed")",
        systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(enabled ? Color.green : Color.orange)
      Text(detail).font(.subheadline)
      if !enabled { Button(button) { NSWorkspace.shared.open(pane.url) } }
    }
  }
}

enum MessagesStyle {
  static let tint = Color.indigo
}
