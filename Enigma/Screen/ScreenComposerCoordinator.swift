import AppKit
import Combine
import Synchronization

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
  private let ocrTimeout: Duration
  /// A read that outlasted the cap and still runs. Captures meanwhile go
  /// straight to vision instead of stacking another cold Vision start.
  private var lingeringRead: UUID?

  init(captureService: any ScreenCapturing = ScreenCaptureService(), ocrService: any ScreenOCRReading = ScreenOCRService(),
       ocrTimeout: Duration = .seconds(3)) {
    self.captureService = captureService
    self.ocrService = ocrService
    self.ocrTimeout = ocrTimeout
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
        do { result = try await recognize(pixels) ?? .empty } // A slow read is handled by vision, like a failed one.
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

  /// Returns nil when OCR outlasts `ocrTimeout`. The read keeps running then:
  /// a cold Vision start loads its model once, and stopping it would keep the
  /// next capture cold too. Only real cancellation cancels it.
  private func recognize(_ pixels: CGImage) async throws -> ScreenOCRResult? {
    guard lingeringRead == nil else { return nil }
    let ocrService = ocrService
    let reading = Task.detached(priority: .userInitiated) { try await ocrService.recognize(pixels) }
    let race = FirstOutcome<ScreenOCRResult?>()
    let timeout = ocrTimeout
    let timer = Task.detached {
      try? await Task.sleep(for: timeout)
      race.finish(.success(nil))
    }
    defer { timer.cancel() }
    Task.detached {
      do { race.finish(.success(try await reading.value)) }
      catch { race.finish(.failure(error)) }
    }
    let result = try await withTaskCancellationHandler {
      try await race.value()
    } onCancel: {
      reading.cancel()
      race.finish(.failure(CancellationError()))
    }
    if result == nil {
      let token = UUID()
      lingeringRead = token
      Task { [weak self] in
        _ = try? await reading.value
        if self?.lingeringRead == token { self?.lingeringRead = nil }
      }
    }
    return result
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

/// Delivers whichever outcome arrives first; later ones are ignored.
private final class FirstOutcome<Value: Sendable>: Sendable {
  private struct State: ~Copyable {
    var outcome: Result<Value, any Error>?
    var waiter: CheckedContinuation<Value, any Error>?
  }
  private let state = Mutex(State())

  func finish(_ outcome: Result<Value, any Error>) {
    state.withLock { state in
      guard state.outcome == nil else { return }
      state.outcome = outcome
      state.waiter?.resume(with: outcome)
      state.waiter = nil
    }
  }

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      state.withLock { state in
        if let outcome = state.outcome { continuation.resume(with: outcome) }
        else { state.waiter = continuation }
      }
    }
  }
}

extension Notification.Name {
  static let screenCaptureBegan = Notification.Name("aiSpotlight.screenCaptureBegan")
  static let screenCaptureEnded = Notification.Name("aiSpotlight.screenCaptureEnded")
}
