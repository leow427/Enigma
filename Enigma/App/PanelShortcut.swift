import AppKit

enum PanelShortcut: Equatable {
  case newChat
  case modePalette
  case stopStreaming
  case cycleRecentChat
  case settings
  case toggleSidebar
  case openInWindow
  case fileMode

  /// `keyCode` is the hardware key, for shortcuts whose characters are not
  /// reliable: with Control held, `charactersIgnoringModifiers` can be a
  /// control character. Command-O is deliberately not consumed in the normal
  /// window, so it is not swallowed there; the panel only acts on it while it
  /// shows the selection chat.
  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16? = nil
  ) -> PanelShortcut? {
    let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    let relevantModifiers = modifiers.intersection(shortcutModifiers)
    if relevantModifiers == [.control, .command], keyCode == 1 { return .toggleSidebar }
    if relevantModifiers == [.command, .shift], keyCode == 0 || characters?.lowercased() == "a" {
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
