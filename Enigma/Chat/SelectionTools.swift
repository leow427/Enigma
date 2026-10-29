import Foundation

/// A capable model's answer for the attached selection: revised text for the revision card, or
/// a translation, which is shown in the reply and never replaces the selection.
struct SelectionProposal: Sendable, Equatable {
  let text: String
  /// The target language for a translation; nil for an edit.
  let language: String?
}

/// The selection tools for capable models (F32). They only propose: replacing the selection
/// still takes the user's click on the revision card, or the automatic-replace setting.
struct SelectionTools: AgentToolbox {
  private let allowsEdit: Bool
  private let onProposal: @Sendable (SelectionProposal) async -> Void

  /// `allowsEdit` is false for a typed /translate, which stays read-only.
  init(allowsEdit: Bool, onProposal: @escaping @Sendable (SelectionProposal) async -> Void) {
    self.allowsEdit = allowsEdit
    self.onProposal = onProposal
  }

  var instructions: String {
    // Measured on Gemma 4 12B (CP4): softer wording got the revision written as plain text.
    (allowsEdit ? """
    Text the user selected in another app is attached. When the user asks you to edit, fix, correct, rewrite, reword, shorten, expand or otherwise change it, you must call propose_edit with the complete revised text, and must not write the revised text in your reply. After the call, say in one sentence what you changed. Enigma shows the revision in a card, and the user decides whether to replace their selection. For questions about the text, answer normally and don't call propose_edit.

    """ : "Text the user selected in another app is attached. It stays read-only.\n")
    + """
    When the user asks for a translation of the selection, call propose_translation with the complete translation; Enigma shows it in your reply. \(SelectionResponseMode.translationInstructions)
    """
  }

  var definitions: [AgentToolDefinition] {
    let text = CodexValue.object(["type": .string("string")])
    return (allowsEdit ? [AgentToolDefinition(name: "propose_edit",
      description: "Give the user a changed version of their selected text: any edit, fix, correction, rewrite, rewording or shortening. Pass the complete revised text. Never write revised text in your reply instead.",
      properties: ["text": text], required: ["text"])] : [])
      + [AgentToolDefinition(name: "propose_translation",
        description: "Show the complete translation of the selection in your reply.",
        properties: ["text": text, "language": .object(["type": .string("string"),
          "description": .string("The language translated into, such as English.")])],
        required: ["text", "language"])]
  }

  func execute(name: String, arguments: CodexValue) async -> AgentToolResult {
    guard let definition = definitions.first(where: { $0.name == name }), case .object(let fields) = arguments,
          fields.keys.allSatisfy({ definition.properties[$0] != nil }),
          let text = fields["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf8.count <= 256_000 else {
      return AgentToolResult(text: "Invalid tool arguments: call \(allowsEdit ? "propose_edit or " : "")propose_translation with the complete text.", success: false)
    }
    if name == "propose_translation" {
      guard let language = fields["language"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
        return AgentToolResult(text: "Invalid tool arguments: language is required.", success: false)
      }
      await onProposal(SelectionProposal(text: text, language: language))
      return AgentToolResult(text: "The translation is shown to the user after your reply. Don't repeat it.", success: true)
    }
    await onProposal(SelectionProposal(text: text, language: nil))
    return AgentToolResult(text: "The revised text is shown to the user in a card. Briefly say what you changed; don't repeat the text.", success: true)
  }
}
