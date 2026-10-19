import Foundation

/// What pressing Send does with the current draft, decided before any service runs.
enum ComposerSubmission: Equatable {
  /// Nothing to send yet.
  case none
  /// Attached files can't be combined with Screen, Web Search, or Messages.
  case fileConflict
  /// Work with the attached files, using the draft as typed.
  case files(prompt: String)
  /// Messages can't be combined with Screen, Web Search, or a screenshot.
  case messagesConflict
  case messages(prompt: String)
  /// /screen or /snapshot: take a capture first, then send.
  case captureScreen
  /// Send the screenshot that's already attached.
  case screenAttachment
  case chat(prompt: String, searchEnabled: Bool)

  static let fileConflictMessage = "Turn off Screen, Web Search, and Messages to work with your attached files."
  static let messagesConflictMessage =
    "/messages can't be combined with Screen or Web Search. Remove /screen, /snapshot, /search, or the screenshot, then send again."

  struct Context: Equatable {
    var draft: String
    var hasFileSelection = false
    /// Screen is on exactly when a screenshot is attached.
    var hasScreenshot = false
  }

  /// Plans typed commands only, with nothing recognized from the wording.
  static func plan(_ context: Context, canSubmit: @autoclosure () -> Bool) -> ComposerSubmission {
    let intent = ComposerIntent.resolve(ComposerIntent.Context(
      draft: context.draft, hasFileSelection: context.hasFileSelection, hasScreenshot: context.hasScreenshot,
      infersCommands: false, searchesAutomatically: false))
    return plan(intent, hasFileSelection: context.hasFileSelection, hasScreenshot: context.hasScreenshot,
                canSubmit: canSubmit())
  }

  /// Plans a resolved draft. Only typed commands can conflict; `ComposerIntent` has already
  /// dropped any recognized command that would. `canSubmit` is only evaluated for a plain
  /// chat message, because checking cloud configuration can reach the Keychain.
  static func plan(_ intent: ComposerIntent, hasFileSelection: Bool, hasScreenshot: Bool,
                   canSubmit: @autoclosure () -> Bool) -> ComposerSubmission {
    let typed = intent.typed
    if hasFileSelection {
      if hasScreenshot || typed.screen || typed.search || typed.messages { return .fileConflict }
      return .files(prompt: intent.draftWithInferredCommands)
    }
    if intent.messages {
      // Message contents must never become a web search query or share a request with a capture.
      if typed.screen || typed.search || hasScreenshot { return .messagesConflict }
      return intent.hasPrompt ? .messages(prompt: intent.submissionPrompt) : .none
    }
    if typed.screen { return .captureScreen }
    if hasScreenshot { return .screenAttachment }
    guard canSubmit(), intent.hasPrompt else { return .none }
    return .chat(prompt: intent.submissionPrompt, searchEnabled: intent.search)
  }

  /// The draft once a request sent from `sent` is accepted: cleared, unless it was
  /// edited meanwhile. Compare with the draft as it was when sent, never with the
  /// prompt, which can carry recognized commands the draft doesn't show.
  static func draftAfterAcceptance(current: String, sent: String) -> String {
    current == sent ? "" : current
  }

  /// Whether the selected mode has a model ready and no request is running. The cloud
  /// checks run only for the modes that need them, since they can reach the Keychain.
  static func canSubmit(
    mode: ChatMode, hasLocalModel: Bool, isCloudConfigured: @autoclosure () -> Bool,
    hasAutoCloud: @autoclosure () -> Bool, isBusy: Bool
  ) -> Bool {
    guard !isBusy else { return false }
    switch mode {
    case .local: return hasLocalModel
    case .cloud: return isCloudConfigured()
    case .auto: return hasLocalModel || hasAutoCloud()
    }
  }
}
