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

  static let savedPermissionExplanation = "This saves permission for future region and full-desktop screenshots, including all displays, to whichever cloud provider you select in Auto or Cloud. Turn it off in Settings → Cloud. Local mode keeps images on this Mac."
  static let ocrExplanation = "OCR reads text on this Mac. In Auto or Cloud, extracted text may go to your text model without uploading an image."
  static let modelPickerNote = "The normal model picker selects the model for text and images. Install a recommended package in Settings → On this Mac for private visual analysis."
}

@MainActor
struct ScreenUploadConsent: Identifiable {
  let id = UUID()
  let attachment: ScreenAttachment
  let provider: CloudProviderID
  /// False when the request came straight from a typed capture, which runs only typed commands.
  var recognizesCommands = true
  var title: String {
    "Send \(attachment.source == .fullDesktop ? "full desktop" : "selected region") to \(provider.displayName)?"
  }
  var explanation: String {
    "This image captures \(attachment.source.captureScope). It will be sent to \(provider.displayName) for image analysis, under that provider’s data policies."
  }
}
