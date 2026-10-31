import AppKit
import Combine

enum PanelShortcut: String, CaseIterable, Equatable {
  case newChat
  case modePalette
  case stopStreaming
  case cycleRecentChat
  case settings
  case toggleSidebar
  case openInWindow
  case fileMode

  /// `keyCode` is only a fallback for events without characters; with Control
  /// held, `charactersIgnoringModifiers` can be a control character (Control-S
  /// is U+0013). Command-O is deliberately not consumed in the normal
  /// window, so it is not swallowed there; the panel only acts on it while it
  /// shows the selection chat.
  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16? = nil
  ) -> PanelShortcut? {
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    let relevantModifiers = modifiers.intersection(shortcutModifiers)
    // Letters match by character, so other layouts work. The hardware key is
    // only a last resort when the event has no characters.
    let unlabeled = characters?.isEmpty ?? true
    if relevantModifiers == [.control, .command],
       characters?.lowercased() == "s" || characters == "\u{13}" || (unlabeled && keyCode == 1) {
      return .toggleSidebar
    }
    if relevantModifiers == [.command, .shift], characters?.lowercased() == "a" || (unlabeled && keyCode == 0) {
      return .fileMode
    }
    if relevantModifiers == .control, characters == "\t" {
      return .cycleRecentChat
    }
    guard relevantModifiers == .command else { return nil }

    switch characters?.lowercased() {
    case "n":
      return .newChat
    case "k":
      return .modePalette
    case ".":
      return .stopStreaming
    case ",":
      return .settings
    case "o":
      return .openInWindow
    default:
      return nil
    }
  }
}
