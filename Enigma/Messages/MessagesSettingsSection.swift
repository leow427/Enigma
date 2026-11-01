import Contacts
import SwiftUI

/// What /messages needs from macOS, the chats it may read without asking, and
/// where its data goes. Each part is on its own Settings page.
struct MessagesSettingsSection: View {
  enum Part { case permissions, approvals, about }
  let part: Part
  @State private var fullDiskAccess: Bool?
  @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)
  @State private var automation: Bool?
  @State private var asked: Set<MacPermission> = []
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
        permission(.fullDiskAccess, isEnabled: fullDiskAccess == true, subtitle: "To read your Messages chats.",
                   detail: MessagesPermissionStatus.fullDiskAccessDetail(fullDiskAccess))
        permission(.contacts, isEnabled: contacts == .authorized, subtitle: "To show names instead of numbers.",
                   detail: MessagesPermissionStatus.contactsDetail)
        permission(.automation, isEnabled: automation == true, subtitle: "To send a text you approve.",
                   detail: MessagesPermissionStatus.automationDetail, isKnown: automation != nil)
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
    .onReceive(NotificationCenter.default.publisher(for: .macPermissionChanged)) { _ in refresh() }
  }

  private func refresh() {
    contacts = CNContactStore.authorizationStatus(for: .contacts)
    fullDiskAccess = MessagesPermissionStatus.fullDiskAccess()
    automation = MacPermission.automation.isGranted
  }

  /// Turn on… shows only while the permission is off. Automation's state is
  /// known only while Messages is open, so until then it shows no status.
  private func permission(_ permission: MacPermission, isEnabled: Bool, subtitle: String, detail: String,
                          isKnown: Bool = true) -> some View {
    let status = MacPermissionRows.status(isEnabled: isEnabled)
    return EnigmaRow(permission.title,
                     subtitle: !isEnabled && asked.contains(permission) ? permission.nextStep ?? subtitle : subtitle,
                     info: detail) {
      HStack(spacing: 12) {
        if isKnown { EnigmaStatusLine(status.0, status.1) }
        if !isEnabled { MacPermissionRows.turnOnButton(permission) { asked.insert(permission) } }
      }
    }
  }
}
