import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class ScreenSettings: ObservableObject {
  static let shared = ScreenSettings()
  private let defaults: UserDefaults
  @Published var allowCloudScreenshots: Bool {
    didSet {
      defaults.set(allowCloudScreenshots, forKey: "screen.allowCloudScreenshots")
      if allowCloudScreenshots { hasExplainedCloudPermission = true }
    }
  }
  @Published private(set) var hasExplainedCloudPermission: Bool {
    didSet { defaults.set(hasExplainedCloudPermission, forKey: "screen.hasExplainedCloudPermission") }
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Retire only the obsolete preference. The normal library selection and all
    // installed model/projector files are preserved; migration never downloads.
    defaults.removeObject(forKey: "screen.localVisionModelID")
    allowCloudScreenshots = defaults.bool(forKey: "screen.allowCloudScreenshots")
    hasExplainedCloudPermission = defaults.bool(forKey: "screen.hasExplainedCloudPermission")

  }

  func answerCloudPermission(allow: Bool) {
    hasExplainedCloudPermission = true
    allowCloudScreenshots = allow
  }

  static let savedPermissionExplanation = "This saves permission for future region and full-desktop screenshots, including all displays, to whichever cloud provider you select in Auto or Cloud. Turn it off in Settings → Screen. Local mode keeps images on this Mac."
  static let ocrExplanation = "OCR reads text on this Mac. In Auto or Cloud, extracted text may go to your text model without uploading an image."
}

@MainActor
struct ScreenUploadConsent: Identifiable {
  let id = UUID()
  let attachment: ScreenAttachment
  let provider: CloudProviderID
  var title: String {
    "Send \(attachment.source == .fullDesktop ? "full desktop" : "selected region") to \(provider.displayName)?"
  }
  var explanation: String {
    "This image captures \(attachment.source.captureScope). It will be sent to \(provider.displayName) for image analysis, under that provider’s data policies."
  }
}

struct ScreenSettingsSection: View {
  @ObservedObject var settings: ScreenSettings
  var body: some View {
    Section("Screen") {
      Toggle("Allow screenshots to be sent to cloud models", isOn: $settings.allowCloudScreenshots)
      Text("Off by default. " + ScreenSettings.savedPermissionExplanation)
        .font(.caption).foregroundStyle(.secondary)
      Text(ScreenSettings.ocrExplanation)
        .font(.caption).foregroundStyle(.secondary)
      Text("The normal model picker selects the model for text and images. Install a recommended package in Local Models for private visual analysis.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Consent is checked again when returning from System Settings; opening it grants nothing.
struct MacPermissionControls: View {
  @ObservedObject private var selection = SelectionAccessibilityAccess.shared
  @State private var screenGranted = CGPreflightScreenCaptureAccess()
  var showScreen = true

  static func openScreenSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      permission(title: "Accessibility", enabled: selection.isGranted,
        explanation: "Required to attach selected text with double-Option and replace text in other apps.",
        button: "Open Accessibility Settings…", action: selection.requestAccess)
      if showScreen {
        Divider()
        permission(title: "Screen Recording", enabled: screenGranted,
          explanation: "Required for /screen and /snapshot. Captures happen only when you request them.",
          button: "Open Screen Recording Settings…", action: Self.openScreenSettings)
      }
      Text("Enable \(SelectionAccessibilityAccess.appName) in System Settings. If an older copy is already listed, remove it and add the app you’re running, then quit and reopen Enigma.")
        .font(.caption).foregroundStyle(.secondary)
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

  private func permission(title: String, enabled: Bool, explanation: String, button: String,
                          action: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("\(title) · \(enabled ? "Enabled" : "Action needed")",
        systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.headline).foregroundStyle(enabled ? Color.green : Color.orange)
      Text(explanation).font(.subheadline)
      Button(button, action: action).buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
