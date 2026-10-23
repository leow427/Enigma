import Contacts
import SwiftUI

/// Settings → General: what /messages needs from macOS and where its data goes.
struct MessagesSettingsSection: View {
  @State private var fullDiskAccess: Bool?
  @State private var contacts = CNContactStore.authorizationStatus(for: .contacts)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      permission("Full Disk Access", isEnabled: fullDiskAccess == true,
                 detail: MessagesPermissionStatus.fullDiskAccessDetail(fullDiskAccess), pane: .fullDiskAccess)
      permission("Contacts", isEnabled: contacts == .authorized,
                 detail: MessagesPermissionStatus.contactsDetail, pane: .contacts)
      EnigmaRow("Automation", subtitle: MessagesPermissionStatus.automationDetail) {
        settingsButton(for: .automation)
      }
      EnigmaHairline()
      EnigmaNote(MessagesPermissionStatus.privacyNote).padding(.top, 10)
    }
    .onAppear(perform: refresh)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
  }

  private func refresh() {
    contacts = CNContactStore.authorizationStatus(for: .contacts)
    fullDiskAccess = MessagesPermissionStatus.fullDiskAccess()
  }

  /// The button shows only while the permission is missing.
  private func permission(_ title: String, isEnabled: Bool, detail: String, pane: MessagesPrivacyPane) -> some View {
    let status = MacPermissionRows.status(isEnabled: isEnabled)
    return EnigmaRow(title, subtitle: detail) {
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
