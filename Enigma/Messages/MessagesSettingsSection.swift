import Contacts
import SwiftUI

/// What /messages needs from macOS, the chats it may read without asking, and
/// where its data goes. Each part is on its own Settings page.
struct MessagesSettingsSection: View {
  enum Part { case permissions, approvals, about }
  let part: Part
  @State private var fullDiskAccess: Bool?
  @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)
  @ObservedObject var grants: ToolGrantStore = .shared

  static let alwaysAllowedHeading = "Always allowed"

  /// One Always grant's row in the list.
  static func rowText(for grant: ToolAlwaysGrant) -> String {
    let destination = grant.destination?.displayName ?? ""
    return switch grant.kind {
    case .readChat: "Read your chat with \(grant.chatName ?? grant.chatGUID ?? "") · \(destination)"
    case .searchChats: "Search all your messages · \(destination)"
    case .searchAfterMessages: "Search the web after reading messages"
    case .placesAfterMessages: "Find places after reading messages"
    case .weatherAfterMessages: "Check the weather after reading messages"
    case .shareMessageText: "Send text from your messages · \(destination)"
    case .shareLocation: "Share your location with web search · \(grant.provider?.shortName ?? "")"
    case .providerSearchAfterMessages: "Let \(grant.provider?.shortName ?? "a provider") search the web after reading messages"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch part {
      case .permissions:
        permission("Full Disk Access", isEnabled: fullDiskAccess == true, subtitle: "To read your Messages chats.",
                   detail: MessagesPermissionStatus.fullDiskAccessDetail(fullDiskAccess), pane: .fullDiskAccess)
        permission("Contacts", isEnabled: contacts == .authorized, subtitle: "To show names instead of numbers.",
                   detail: MessagesPermissionStatus.contactsDetail, pane: .contacts)
        EnigmaRow("Automation", subtitle: "To send a text you approve.", info: MessagesPermissionStatus.automationDetail) {
          settingsButton(for: .automation)
        }
      case .approvals:
        if grants.alwaysGrants.isEmpty {
          EnigmaRow("Nothing yet", subtitle: "Choose Always on an approval card and it’s listed here.")
        }
        ForEach(grants.alwaysGrants) { grant in
          let text = Self.rowText(for: grant)
          EnigmaRow(text) {
            Button("Remove") { grants.remove(grant) }
              .enigmaButtonStyle(.secondary)
              .accessibilityLabel("Remove \(text)")
          }
        }
        EnigmaHairline()
      case .about:
        EnigmaNote(MessagesPermissionStatus.privacyNote).padding(.vertical, 10)
      }
    }
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
  }

  private func refresh() {
    contacts = CNContactStore.authorizationStatus(for: .contacts)
    fullDiskAccess = MessagesPermissionStatus.fullDiskAccess()
  }

  /// The button shows only while the permission is missing.
  private func permission(_ title: String, isEnabled: Bool, subtitle: String, detail: String,
                          pane: MessagesPrivacyPane) -> some View {
    let status = MacPermissionRows.status(isEnabled: isEnabled)
    return EnigmaRow(title, subtitle: subtitle, info: detail) {
      HStack(spacing: 12) {
        EnigmaStatusLine(status.0, status.1)
        if !isEnabled { settingsButton(for: pane) }
      }
    }
  }

  private func settingsButton(for pane: MessagesPrivacyPane) -> some View {
    Button("Open Settings…") { NSWorkspace.shared.open(pane.url) }
      .enigmaButtonStyle(.secondary)
      .accessibilityLabel(pane.settingsButtonTitle)
  }
}
