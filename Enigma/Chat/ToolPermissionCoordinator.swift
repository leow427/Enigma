import Combine
import Foundation

/// One permission card's question, in the words the card shows.
struct ToolPermissionRequest: Sendable, Equatable, Identifiable {
  let id: UUID
  let permission: ToolPermission
  let destination: ToolDestination
  let session: UUID
  var title: String
  var detail: String

  init(id: UUID = UUID(), permission: ToolPermission, destination: ToolDestination, session: UUID) {
    self.id = id
    self.permission = permission
    self.destination = destination
    self.session = session
    switch permission {
    case .readChat(_, let name): title = "Allow reading your chat with \(Self.oneLine(name))?"
    case .searchChats(let query): title = "Search all your messages for “\(Self.oneLine(query))”?"
    case .searchAfterMessages(let query): title = "Search the web for “\(Self.oneLine(query))”?"
    }
    detail = switch (permission, destination) {
    case (.searchAfterMessages, _): "This chat includes text from your messages."
    case (_, .thisMac): "It stays on this Mac."
    case (_, let company): "It will be sent to \(company.displayName)."
    }
  }

  /// Model-written queries and other people's chat names can't add lines to the card, such as a
  /// fake "It stays on this Mac.", or hide text in characters that draw nothing: those show as �.
  static func oneLine(_ text: String) -> String {
    let flat = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
      if CharacterSet.newlines.contains(scalar) || scalar == "\t" { return " " }
      if CharacterSet.controlCharacters.contains(scalar) || scalar.properties.isDefaultIgnorableCodePoint {
        return "\u{FFFD}"
      }
      return scalar
    }))
    return flat.trimmingCharacters(in: .whitespaces)
  }
}

/// Owns the one open permission card. A tool waits in `authorize` until the user answers it;
/// only `answer(_:)`, called by the card's buttons, can grant.
@MainActor
final class ToolPermissionCoordinator: ObservableObject {
  let store: ToolGrantStore
  @Published private(set) var pending: ToolPermissionRequest?
  private var continuation: CheckedContinuation<ToolPermissionAnswer, Never>?

  init(store: ToolGrantStore) { self.store = store }

  /// True when already granted, or when the user allows it now. Another open card, Stop,
  /// or cancellation answers Don't allow.
  func authorize(_ permission: ToolPermission, destination: ToolDestination, session: UUID) async -> Bool {
    if store.isGranted(permission, destination: destination, session: session) { return true }
    guard continuation == nil, !Task.isCancelled else { return false }
    let request = ToolPermissionRequest(permission: permission, destination: destination, session: session)
    let answer = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pending = request
        self.continuation = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.resolve(request.id, with: .deny) } }
    store.record(answer, for: permission, destination: destination, session: session)
    return answer != .deny
  }

  func answer(_ answer: ToolPermissionAnswer) {
    guard let pending else { return }
    resolve(pending.id, with: answer)
  }

  /// Resumes only the request it was asked about, so a late cancel never answers a newer card.
  private func resolve(_ id: UUID, with answer: ToolPermissionAnswer) {
    guard pending?.id == id, let continuation else { return }
    self.continuation = nil
    pending = nil
    continuation.resume(returning: answer)
  }
}
