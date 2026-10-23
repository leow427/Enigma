import AppKit
import Combine
import Foundation

struct MessagesIssue: Equatable {
  let message: String
  let pane: MessagesPrivacyPane?
}

/// Owns the one pending send approval and the Messages problem for the chat UI: a preflight
/// error, or a permission lost while a request ran.
@MainActor
final class MessagesCoordinator: ObservableObject {
  @Published private(set) var pendingSend: MessagesSendApproval?
  @Published var issue: MessagesIssue?
  /// A cloud provider waiting for the one-time Messages disclosure, and the prompt to send after it.
  @Published private(set) var cloudDisclosure: CloudProviderID?
  private var disclosedPrompt: String?
  private var continuation: CheckedContinuation<Bool, Never>?
  private let defaults: UserDefaults
  private static let disclosedProvidersKey = "messages.cloudDisclosedProviders"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  /// Suspends the tool call until the user answers. Stop, a new chat, or cancellation declines.
  func confirm(_ approval: MessagesSendApproval) async -> Bool {
    guard continuation == nil, !Task.isCancelled else { return false }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pendingSend = approval
        self.continuation = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.answer(false) } }
  }

  func answer(_ approved: Bool) {
    let continuation = continuation
    self.continuation = nil
    pendingSend = nil
    continuation?.resume(returning: approved)
  }

  // MARK: Cloud disclosure

  func hasDisclosed(_ provider: CloudProviderID) -> Bool {
    (defaults.stringArray(forKey: Self.disclosedProvidersKey) ?? []).contains(provider.rawValue)
  }

  func requestDisclosure(for provider: CloudProviderID, prompt: String) {
    cloudDisclosure = provider
    disclosedPrompt = prompt
  }

  /// Returns the prompt to submit when the user allows it.
  func answerDisclosure(allow: Bool) -> String? {
    defer { cloudDisclosure = nil; disclosedPrompt = nil }
    guard allow, let provider = cloudDisclosure else { return nil }
    var providers = defaults.stringArray(forKey: Self.disclosedProvidersKey) ?? []
    if !providers.contains(provider.rawValue) { providers.append(provider.rawValue) }
    defaults.set(providers, forKey: Self.disclosedProvidersKey)
    return disclosedPrompt
  }

  func report(_ error: Error) {
    issue = MessagesIssue(message: error.localizedDescription, pane: (error as? MessagesError)?.privacyPane)
  }

  func report(_ message: String) { issue = MessagesIssue(message: message, pane: nil) }

  func openPrivacySettings(_ pane: MessagesPrivacyPane) {
    NSWorkspace.shared.open(pane.url)
  }
}
