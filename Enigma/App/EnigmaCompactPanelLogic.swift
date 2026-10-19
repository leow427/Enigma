import CoreGraphics
import Foundation

// Logic the compact selection panel would otherwise hide inline: where
// the character sits, what the route chip, the placeholder, and the hints
// say, and when the character shows the error state. Each is a plain value,
// so it can be tested without building the panel.

/// The compact panel's layout constants and the character's place in it.
enum CompactPanelLayout {
  /// The character's slot beside the input, as in the mockup.
  static let inputSlot: EnigmaCharacterSlotID = "panel.input"
  static let inputSlotSize: CGFloat = 40
  /// The panel's corners, as in the mockup.
  static let cornerRadius: CGFloat = 16
  /// The answer area's cards and notes, before they scroll.
  static let accessoriesMaximumHeight: CGFloat = 260
  /// The details surface's content, before it scrolls.
  static let detailsMaximumHeight: CGFloat = 300

  /// The room under the panel that the command list and the mode and model
  /// menu need to open downward. With less, they open above the input.
  static let overlayRoomBelow: CGFloat = 320

  static func opensOverlaysAbove(roomBelow: CGFloat) -> Bool { roomBelow < overlayRoomBelow }

  /// What the input says before anything is typed.
  static func placeholder(hasSelection: Bool) -> String {
    hasSelection ? "Ask about the selection" : "Ask anything"
  }
}

/// The selection's part in the chat. It goes with the first message only;
/// after that it stays in the conversation, where the model can refer back
/// to it, and `/edit` and a standalone `/translate` still use it, but new
/// questions don't carry it.
enum CompactSelectionStatus {
  /// The `› selected "…"` line's label: what the selection is for now.
  static func label(isSent: Bool) -> String { isSent ? "for /edit" : "selected" }

  /// The line's tooltip and the card's note, once the selection has been sent.
  static let sentNote = "Sent with your first message. New questions don't attach it; /edit and /translate still use it."
}

/// The monospace chip beside the input: the mode, then where Auto runs or the
/// model a fixed mode uses, like `auto · local`. It opens the mode and model menu.
enum CompactRouteChip {
  static func text(mode: ChatMode, route: ComposerRouteIndicator?, modelName: String?) -> String {
    switch mode {
    case .auto:
      guard let route else { return "auto" }
      return "auto · " + (route == .local ? "local" : "cloud")
    case .local:
      return "local · " + (modelName ?? "choose model")
    case .cloud:
      return "cloud · " + (modelName ?? "choose model")
    }
  }
}

/// The monospace hints under the panel. Each names a shortcut that works in
/// the panel today: `/` opens the commands, a double-tap of Control expands
/// the panel into the full window's chat, `⌘.` stops a reply, and Escape hides
/// the panel.
enum CompactPanelHints {
  struct Hint: Equatable, Identifiable {
    let keys: String
    let action: String

    var id: String { keys }
    var text: String { "\(keys) \(action)" }
  }

  static func hints(isResponding: Bool) -> [Hint] {
    [isResponding ? Hint(keys: "⌘.", action: "stop") : Hint(keys: "/", action: "commands"),
     Hint(keys: "⌃⌃", action: "open in window"),
     Hint(keys: "esc", action: "close")]
  }

  /// The tag on the hint row's trailing side while the panel's chat is
  /// temporary, which it is for as long as it's in the panel.
  static let temporaryTag = "temporary · not saved"

  /// The Open in window button's VoiceOver label.
  static let openInWindowLabel = "Open in window"

  /// The Open in window button's tooltip: whether opening the chat in the
  /// window saves it, as "Keep selection chats private" decides.
  static func openInWindowHelp(keepsPrivate: Bool) -> String {
    keepsPrivate ? "Open in window · stays private" : "Open in window · saves to history"
  }

  /// The one-time line under a selection chat opened in the window privately.
  static let privateNote = "Private chat · not saved to history"

  /// The quiet line under a chat just kept from the panel, with how many
  /// chats the history keeps.
  static var savedNote: String {
    "Saved to history · Enigma keeps your last \(ChatSessionStore.maximumRetainedSessions) chats"
  }
}

/// When the panel's character shows the error state for the selection itself.
enum CompactPanelCharacter {
  /// The selection couldn't be read, or Accessibility, which reading and
  /// replacing it need, isn't allowed. A notice after a selection was
  /// attached, like "Replacement sent", is news rather than a problem.
  static func hasSelectionProblem(isPanel: Bool, isComposing: Bool, hasSelection: Bool, notice: String?,
                                  isAccessibilityGranted: Bool, isTemporaryChat: Bool) -> Bool {
    guard isPanel, isTemporaryChat else { return false }
    if !isAccessibilityGranted { return true }
    return isComposing && !hasSelection && notice != nil
  }

  /// The status button shows a problem glyph whenever there's a notice or
  /// Accessibility is missing.
  static func statusNeedsAttention(notice: String?, isAccessibilityGranted: Bool) -> Bool {
    notice != nil || !isAccessibilityGranted
  }
}
