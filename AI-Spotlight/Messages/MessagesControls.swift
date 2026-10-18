import SwiftUI

/// Asks before /messages sends conversations to a cloud model.
struct MessagesDialogs: ViewModifier {
  @ObservedObject var messages: MessagesCoordinator
  let submit: (String) -> Void

  private var disclosurePresented: Binding<Bool> {
    Binding(get: { messages.cloudDisclosure != nil }, set: { if !$0 { _ = messages.answerDisclosure(allow: false) } })
  }

  func body(content: Content) -> some View {
    content.alert("Use Messages with \(messages.cloudDisclosure?.displayName ?? "the cloud")?", isPresented: disclosurePresented) {
      Button("Continue") { if let prompt = messages.answerDisclosure(allow: true) { submit(prompt) } }
      Button("Cancel", role: .cancel) { _ = messages.answerDisclosure(allow: false) }
    } message: {
      Text("With /messages, the conversations, names, and phone numbers the model looks up are sent to \(messages.cloudDisclosure?.displayName ?? "your cloud provider") to answer. Choose Local or Auto to keep Messages on this Mac. Enigma asks before sending any message.")
    }
  }
}

/// What Settings shows for the macOS permissions /messages uses.
enum MessagesPermissionStatus {
  /// Full Disk Access as Settings reports it: true when the Messages history
  /// opens, nil when this Mac has no Messages history yet, and false otherwise.
  static func fullDiskAccess(check: () throws -> Void = { try MessagesDatabase().checkAccess() }) -> Bool? {
    do {
      try check()
      return true
    } catch MessagesError.databaseMissing {
      return nil
    } catch {
      return false
    }
  }

  static func fullDiskAccessDetail(_ access: Bool?) -> String {
    access == nil ? "Messages has no history on this Mac yet."
      : "Required to read and search your Messages history. Enigma opens it read-only."
  }

  static let contactsDetail = "Optional. Shows names instead of phone numbers and finds people by name. macOS asks the first time you use /messages."
  static let automationDetail = "macOS asks to let Enigma control Messages the first time you approve a send. If you declined, turn on Messages under Enigma."
  static let privacyNote = "Every send waits for your approval of the recipient and exact text. With a local model or Auto, Messages stays on this Mac. With a cloud model, the messages and contacts it looks up are sent to that provider."
}
