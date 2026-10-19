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

  /// `canSubmit` is only evaluated for a plain chat message, because checking cloud
  /// configuration can reach the Keychain.
  static func plan(_ context: Context, canSubmit: @autoclosure () -> Bool) -> ComposerSubmission {
    let commands = ComposerCommands(context.draft)
    if context.hasFileSelection {
      if context.hasScreenshot || commands.screen || commands.search || commands.messages { return .fileConflict }
      return .files(prompt: context.draft)
    }
    if commands.messages {
      // Message contents must never become a web search query or share a request with a capture.
      if commands.screen || commands.search || context.hasScreenshot { return .messagesConflict }
      return commands.hasPrompt ? .messages(prompt: commands.submissionPrompt) : .none
    }
    if commands.screen { return .captureScreen }
    if context.hasScreenshot { return .screenAttachment }
    guard canSubmit(), commands.hasPrompt else { return .none }
    return .chat(prompt: commands.submissionPrompt, searchEnabled: commands.search)
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
