import AppKit
import Combine

@MainActor
final class ScreenComposerCoordinator: ObservableObject {
  @Published var draft = ""
  @Published private(set) var attachment: ScreenAttachment?
  var isEnabled: Bool { attachment != nil }
  @Published private(set) var isCapturing = false
  @Published private(set) var isReading = false
  var isBusy: Bool { isCapturing || isReading }
  @Published var error: String?
  @Published private(set) var needsScreenRecordingSettings = false
  private let captureService: any ScreenCapturing
  private let ocrService: any ScreenOCRReading
  private var revision = UUID()
  private var lastCaptureWasDesktop = false

  init(captureService: any ScreenCapturing = ScreenCaptureService(), ocrService: any ScreenOCRReading = ScreenOCRService()) {
    self.captureService = captureService
    self.ocrService = ocrService
  }

  /// Consume capture commands only; search stays visible and editable until this turn is accepted.
  func capture(submittedCommand: Bool = false) async -> String? {
    guard !isBusy else { return nil }
    let originalDraft = draft
    let commands = ComposerCommands(draft)
    let desktop = submittedCommand ? !commands.snapshot : lastCaptureWasDesktop
    let remainder = submittedCommand && commands.screen
      ? SlashCommand.removing([.screen, .snapshot], from: draft) : nil
    let operation = UUID()
    revision = operation
    isCapturing = true
    error = nil
    needsScreenRecordingSettings = false
    defer { isCapturing = false; isReading = false }
    do {
      guard let image = try await captureRegion(desktop: desktop) else { return nil }
      try Task.checkCancellation()
      guard revision == operation else { return nil }
      attachment = try ScreenAttachment(image: image, source: desktop ? .fullDesktop : .screenRegion)
      lastCaptureWasDesktop = desktop
      isCapturing = false
      isReading = true
      attachment?.status = .reading
      if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let result: ScreenOCRResult
        do { result = try await ocrService.recognize(pixels) }
        catch is CancellationError { return nil }
        catch { result = .empty } // An OCR failure can still be handled by vision.
        guard revision == operation else { return nil }
        attachment?.ocrText = result.text
        attachment?.ocrConfidence = result.confidence
        attachment?.status = result.isUsable ? .localOCR : .vision
      }
      guard draft == originalDraft else { return nil }
      if let remainder { draft = remainder }
      return remainder.flatMap { ComposerCommands($0).hasPrompt ? $0 : nil }
    } catch is CancellationError {
      return nil
    } catch {
      if let captureError = error as? ScreenCaptureError {
        switch captureError {
        case .permissionDenied, .restartRequired: needsScreenRecordingSettings = true
        default: break
        }
      }
      self.error = error.localizedDescription
      return nil
    }
  }

  private func captureRegion(desktop: Bool) async throws -> NSImage? {
    // Permission UI belongs in front of the visible panel. Hide only once the
    // process is authorized and interactive region selection is about to start.
    try captureService.prepareForCapture()
    NotificationCenter.default.post(name: .screenCaptureBegan, object: nil)
    defer { NotificationCenter.default.post(name: .screenCaptureEnded, object: nil) }
    return try await desktop ? captureService.captureDesktop() : captureService.capture()
  }

  func updateDecision(_ decision: ScreenRoutingPolicy.Decision) {
    attachment?.routingDecision = decision
    if case .text = decision { attachment?.status = .localOCR }
    if case .vision = decision { attachment?.status = .vision }
  }

  func removeAttachment() {
    revision = UUID()
    attachment = nil
    error = nil
    needsScreenRecordingSettings = false
  }

  func clearDraft() {
    removeAttachment()
    draft = ""
  }
}

extension Notification.Name {
  static let screenCaptureBegan = Notification.Name("aiSpotlight.screenCaptureBegan")
  static let screenCaptureEnded = Notification.Name("aiSpotlight.screenCaptureEnded")
}
