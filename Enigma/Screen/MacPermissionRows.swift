import AppKit
import SwiftUI

/// Accessibility and Screen Recording. Opening System Settings grants
/// nothing, so the state is checked again whenever Enigma comes back.
struct MacPermissionRows: View {
  @ObservedObject private var selection = SelectionAccessibilityAccess.shared
  @State private var screenGranted = CGPreflightScreenCaptureAccess()
  @SelectionShortcutPhrase private var selectionShortcut
  /// Selection settings show only Accessibility.
  var showScreen = true

  static func openScreenSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  static func status(isEnabled: Bool) -> (EnigmaStatusLine.Status, String) {
    isEnabled ? (.on, "enabled") : (.off, "action needed")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      row("Accessibility", isEnabled: selection.isGranted,
          explanation: "Required to attach selected text when you \(selectionShortcut), and to replace text in other apps.",
          settingsName: "Accessibility", action: selection.requestAccess)
      if showScreen {
        row("Screen Recording", isEnabled: screenGranted,
            explanation: "Required for /screen and /snapshot. Captures happen only when you request them.",
            settingsName: "Screen Recording", action: Self.openScreenSettings)
      }
      EnigmaHairline()
      EnigmaConnectionNote("Enable \(SelectionAccessibilityAccess.appName) in System Settings. If an older copy is already listed, remove it and add the app you’re running, then quit and reopen Enigma.")
        .padding(.top, 10)
    }
    .onAppear { refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in refresh() }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in refresh() }
  }

  private func refresh() {
    selection.refresh()
    screenGranted = CGPreflightScreenCaptureAccess()
  }

  private func row(_ title: String, isEnabled: Bool, explanation: String, settingsName: String,
                   action: @escaping () -> Void) -> some View {
    let status = Self.status(isEnabled: isEnabled)
    return EnigmaRow(title, subtitle: explanation) {
      HStack(spacing: 12) {
        EnigmaStatusLine(status.0, status.1)
        Button("Open Settings…", action: action)
          .enigmaButtonStyle(.secondary)
          .accessibilityLabel("Open \(settingsName) Settings…")
      }
    }
  }
}
