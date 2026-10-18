import CoreGraphics
import Foundation

// Logic the new compact selection panel would otherwise hide inline: where
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
/// the panel today: `/` opens the commands, a double-tap of Control shows the
/// chat history, which grows the panel, `⌘.` stops a reply, and Escape hides
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
     Hint(keys: "⌃⌃", action: "history"),
     Hint(keys: "esc", action: "close")]
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
  /// Accessibility is missing, as the old button did.
  static func statusNeedsAttention(notice: String?, isAccessibilityGranted: Bool) -> Bool {
    notice != nil || !isAccessibilityGranted
  }
}
