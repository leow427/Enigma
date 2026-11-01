import AppKit
import Contacts
import CoreServices
import SwiftUI

/// Every macOS permission Enigma asks for, and the shortest way to turn each
/// one on: macOS's own dialog where there is one, the right pane where not.
@MainActor
enum MacPermission: String, CaseIterable {
  case accessibility, screenRecording, fullDiskAccess, contacts, automation

  nonisolated static let messagesBundleID = "com.apple.MobileSMS"

  var title: String {
    switch self {
    case .accessibility: "Accessibility"
    case .screenRecording: "Screen Recording"
    case .fullDiskAccess: "Full Disk Access"
    case .contacts: "Contacts"
    case .automation: "Automation"
    }
  }

  /// The service `tccutil` resets.
  var tccService: String {
    switch self {
    case .accessibility: "Accessibility"
    case .screenRecording: "ScreenCapture"
    case .fullDiskAccess: "SystemPolicyAllFiles"
    case .contacts: "AddressBook"
    case .automation: "AppleEvents"
    }
  }

  /// What to do in System Settings after Turn on…, where macOS has no dialog of its own.
  var nextStep: String? {
    switch self {
    case .screenRecording: "Switch on Enigma in the list, then choose Quit & Reopen."
    case .fullDiskAccess: "Drag Enigma from the Finder window into the list, then switch it on."
    case .accessibility: "Switch on Enigma in the list, then come back."
    case .contacts, .automation: nil
    }
  }

  /// Nil when macOS can't say yet: Automation, while Messages isn't open.
  var isGranted: Bool? {
    switch self {
    case .accessibility: AXIsProcessTrusted()
    case .screenRecording: CGPreflightScreenCaptureAccess()
    case .fullDiskAccess: MessagesPermissionStatus.fullDiskAccess() == true
    case .contacts: CNContactStore.authorizationStatus(for: .contacts) == .authorized
    case .automation:
      switch Self.automationStatus(asking: false) {
      case noErr: true
      case OSStatus(errAEEventNotPermitted): false
      default: nil
      }
    }
  }

  /// Clears an entry an older copy of Enigma left (it can say on and not
  /// apply), then asks macOS: its dialog for Accessibility, Screen Recording,
  /// Contacts and Automation, the pane and Enigma in Finder for Full Disk Access.
  func turnOn() {
    Self.resetEntry(self)
    switch self {
    case .accessibility: SelectionAccessibilityAccess.shared.requestAccess()
    case .screenRecording:
      // Adds Enigma to the list, so turning it on is one switch.
      _ = CGRequestScreenCaptureAccess()
      MacPermissionRows.openScreenSettings()
    case .fullDiskAccess:
      // macOS can't add an app to this list itself: the person drags Enigma in.
      NSWorkspace.shared.open(MessagesPrivacyPane.fullDiskAccess.url)
      NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    case .contacts:
      Task {
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        if !granted { NSWorkspace.shared.open(MessagesPrivacyPane.contacts.url) }
        NotificationCenter.default.post(name: .macPermissionChanged, object: nil)
      }
    case .automation: Task { await Self.askToControlMessages() }
    }
  }

  /// Removes this permission's entry for Enigma. Never in a debug build,
  /// which shares the installed app's bundle ID and would clear its switches.
  static func resetEntry(_ permission: MacPermission) {
    #if DEBUG
    return
    #else
    guard !TestHost.isActive, let id = Bundle.main.bundleIdentifier else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    process.arguments = ["reset", permission.tccService, id]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    process.waitUntilExit()
    #endif
  }

  /// macOS asks about Automation only while Messages is open, so it opens
  /// hidden for the question and quits again if Enigma opened it.
  private static func askToControlMessages() async {
    let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty
    if !wasRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID) {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.hides = true
      _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    // The answer waits on the person, so it's asked off the main thread.
    let status = await Task.detached { automationStatus(asking: true) }.value
    if status != noErr { NSWorkspace.shared.open(MessagesPrivacyPane.automation.url) }
    if !wasRunning {
      NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).first?.terminate()
    }
    NotificationCenter.default.post(name: .macPermissionChanged, object: nil)
  }

  nonisolated private static func automationStatus(asking: Bool) -> OSStatus {
    var target = AEAddressDesc()
    let id = Array(messagesBundleID.utf8)
    guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
    defer { AEDisposeDesc(&target) }
    return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, asking)
  }
}

extension Notification.Name {
  /// A permission's dialog was answered.
  static let macPermissionChanged = Notification.Name("macPermissionChanged")
}

/// After an update from a copy signed differently (before 0.13, Enigma
/// wasn't signed with a Developer ID), macOS keeps the old copy's switches:
/// they say on and don't apply. Once per signer, for someone who used
/// Enigma before, the entries that aren't working are cleared so turning
/// them on works the first time. Working permissions are never touched.
enum PermissionUpdateCleanup {
  static let signerKey = "permissions.signer.v1"

  /// The permissions it cleared, for the card that asks to turn them on again.
  @MainActor
  static func run(defaults: UserDefaults, signer: String?, usedBefore: Bool,
                  isGranted: (MacPermission) -> Bool?, reset: (MacPermission) -> Void) -> [MacPermission] {
    guard let signer, defaults.string(forKey: signerKey) != signer else { return [] }
    defaults.set(signer, forKey: signerKey)
    guard usedBefore else { return [] }
    // Automation can't be checked without opening Messages; it asks again on the next send.
    let cleared = [MacPermission.accessibility, .screenRecording, .fullDiskAccess, .contacts]
      .filter { isGranted($0) == false }
    cleared.forEach(reset)
    return cleared
  }

  /// The team that signed this copy, or nil for an unsigned or ad hoc build.
  static func currentSigner() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }
}

/// Once after an update cleared old switches: which to turn on again.
struct PermissionsAgainCard: View {
  let permissions: [MacPermission]
  let openPermissions: () -> Void
  let dismiss: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      Text("Used these before this update? Turn \(ListFormatter.localizedString(byJoining: permissions.map(\.title))) on again.")
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
      Button("Turn on…", action: openPermissions)
        .enigmaButtonStyle(.primary)
        .accessibilityLabel("Turn permissions on again in Settings")
      Button("Not now", action: dismiss)
        .enigmaButtonStyle(.text)
    }
    .enigmaTestMarker("Permissions again")
  }
}

/// Accessibility and Screen Recording. Opening System Settings grants
/// nothing, so the state is checked again whenever Enigma comes back.
struct MacPermissionRows: View {
  @ObservedObject private var selection = SelectionAccessibilityAccess.shared
  @State private var screenGranted = CGPreflightScreenCaptureAccess()
  @State private var asked: Set<MacPermission> = []
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
      row(.accessibility, isEnabled: selection.isGranted, subtitle: "For ⌥⌃, ⌥⌥ and putting edits back.",
          explanation: "Required to attach selected text when you \(selectionShortcut), and to replace text in other apps.")
      if showScreen {
        row(.screenRecording, isEnabled: screenGranted, subtitle: "For /screen and /snapshot.",
            explanation: "Required for /screen and /snapshot. Captures happen only when you request them.")
      }
    }
    .onAppear { refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .macPermissionChanged)) { _ in refresh() }
    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in refresh() }
  }

  private func refresh() {
    selection.refresh()
    screenGranted = CGPreflightScreenCaptureAccess()
  }

  private func row(_ permission: MacPermission, isEnabled: Bool, subtitle: String, explanation: String) -> some View {
    let status = Self.status(isEnabled: isEnabled)
    return EnigmaRow(permission.title,
                     subtitle: !isEnabled && asked.contains(permission) ? permission.nextStep ?? subtitle : subtitle,
                     info: explanation) {
      HStack(spacing: 12) {
        EnigmaStatusLine(status.0, status.1)
        if !isEnabled { Self.turnOnButton(permission) { asked.insert(permission) } }
      }
    }
  }

  /// Turn on… for a permission that's off.
  static func turnOnButton(_ permission: MacPermission, pressed: @escaping () -> Void = {}) -> some View {
    Button("Turn on…") {
      pressed()
      permission.turnOn()
    }
    .enigmaButtonStyle(.secondary)
    .accessibilityLabel("Turn on \(permission.title)")
    .enigmaTestMarker("Turn on \(permission.title)")
  }
}
