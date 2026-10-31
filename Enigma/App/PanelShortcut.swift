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

// MARK: F14 spike: shortcuts you choose

/// A shortcut: keys with modifiers (⌘N), modifiers alone pressed together and
/// released (⌥⌃), or one modifier tapped twice (⌥⌥).
struct KeyBinding: Codable, Hashable {
  enum Kind: String, Codable { case keys, chord, doubleTap }

  var kind: Kind
  /// `NSEvent.ModifierFlags` among ⌃⌥⇧⌘.
  var modifiers: UInt
  /// The key, as this keyboard layout types it without modifiers; empty for chords and double taps.
  var key = ""
  /// The hardware key, for a global hot key.
  var keyCode: UInt16 = 0

  static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

  /// The same shortcut, whichever hardware key typed it.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.modifiers == rhs.modifiers && lhs.key == rhs.key
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(kind)
    hasher.combine(modifiers)
    hasher.combine(key)
  }

  var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

  static func keys(_ key: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> KeyBinding {
    KeyBinding(kind: .keys, modifiers: flags.rawValue, key: key, keyCode: keyCode)
  }

  /// A key press as a binding, or nil without ⌘, ⌃ or ⌥, which typing would trigger.
  init?(keyDown event: NSEvent) {
    let flags = event.modifierFlags.intersection(Self.relevant)
    guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
    self.init(kind: .keys, modifiers: flags.rawValue, key: Self.key(of: event), keyCode: event.keyCode)
  }

  init(kind: Kind, modifiers: UInt, key: String = "", keyCode: UInt16 = 0) {
    self.kind = kind
    self.modifiers = modifiers
    self.key = key
    self.keyCode = keyCode
  }

  /// The key without modifiers: Control-S is "s", not a control character.
  static func key(of event: NSEvent) -> String {
    (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
  }

  func matches(_ event: NSEvent) -> Bool {
    kind == .keys && event.modifierFlags.intersection(Self.relevant) == flags
      && (Self.key(of: event) == key || (key.isEmpty && event.keyCode == keyCode))
  }

  var display: String {
    let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { flags.contains($0.0) }.map(\.1).joined()
    switch kind {
    case .chord: return symbols
    case .doubleTap: return symbols + symbols
    case .keys:
      let name = switch key {
      case "\t": "⇥"
      case " ": "Space"
      case "\r": "↩"
      case "\u{7f}": "⌫"
      default: key.uppercased()
      }
      return symbols + name
    }
  }
}

/// Everything a shortcut can do: open Enigma, ask about a selection, the
/// window's own shortcuts, and starting a / command.
enum ShortcutAction: Hashable, Identifiable {
  case summon, selection
  case panel(PanelShortcut)
  case command(SlashCommand)

  static let global: [ShortcutAction] = [.summon, .selection]
  static let window: [ShortcutAction] = PanelShortcut.allCases.map { .panel($0) }
  static let commands: [ShortcutAction] = SlashCommand.allCases.map { .command($0) }
  static let all = global + window + commands

  var id: String {
    switch self {
    case .summon: "summon"
    case .selection: "selection"
    case .panel(let shortcut): "panel." + shortcut.rawValue
    case .command(let command): "command." + command.rawValue
    }
  }

  var isGlobal: Bool { self == .summon || self == .selection }

  var title: String {
    switch self {
    case .summon: "Open or hide Enigma"
    case .selection: "Ask about selected text"
    case .panel(.newChat): "New chat"
    case .panel(.modePalette): "Choose a mode"
    case .panel(.stopStreaming): "Stop a reply"
    case .panel(.cycleRecentChat): "Next recent chat"
    case .panel(.settings): "Settings"
    case .panel(.toggleSidebar): "Show or hide the sidebar"
    case .panel(.openInWindow): "Open a selection chat in the window"
    case .panel(.fileMode): "Attach files"
    case .command(let command): command.token
    }
  }

  var defaultBinding: KeyBinding? {
    switch self {
    case .summon: KeyBinding(kind: .chord, modifiers: NSEvent.ModifierFlags([.option, .control]).rawValue)
    case .selection: Self.legacySelectionBinding
    case .panel(.newChat): .keys("n", .command)
    case .panel(.modePalette): .keys("k", .command)
    case .panel(.stopStreaming): .keys(".", .command)
    case .panel(.cycleRecentChat): .keys("\t", .control)
    case .panel(.settings): .keys(",", .command)
    case .panel(.toggleSidebar): .keys("s", [.control, .command])
    case .panel(.openInWindow): .keys("o", .command)
    case .panel(.fileMode): .keys("a", [.shift, .command])
    case .command: nil
    }
  }

  /// The double tap the old Settings chose, or none when it was turned off.
  private static var legacySelectionBinding: KeyBinding? {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: SelectionShortcutMonitor.enabledKey) as? Bool ?? true else { return nil }
    let modifier = SelectionModifier(rawValue: defaults.string(forKey: SelectionShortcutMonitor.modifierKey) ?? "") ?? .option
    return KeyBinding(kind: .doubleTap, modifiers: modifier.flags.rawValue)
  }
}

/// The shortcuts in use: each action's default unless changed in Settings → Shortcuts.
@MainActor
final class ShortcutStore: ObservableObject {
  /// Tests share the app's defaults, so theirs are kept apart.
  static let shared = ShortcutStore(defaults: TestHost.isActive ? UserDefaults(suiteName: "EnigmaShortcutStoreTests")! : .standard)
  static let overridesKey = "enigma.shortcuts.overrides.spike"
  static let sameAsSummonKey = "enigma.shortcuts.selectionSameAsSummon.spike"
  /// ⇧⌥Space always asks about a selection, as a backup.
  static let selectionBackup = KeyBinding.keys(" ", [.shift, .option], keyCode: 49)
  /// Shortcuts macOS or every text field uses, which no action may take.
  static let reserved: [KeyBinding: String] = [
    .keys("q", .command): "Quit", .keys("w", .command): "Close", .keys("h", .command): "Hide",
    .keys("m", .command): "Minimize", .keys("c", .command): "Copy", .keys("v", .command): "Paste",
    .keys("x", .command): "Cut", .keys("z", .command): "Undo", .keys("a", .command): "Select All",
    .keys("\t", .command): "the app switcher", .keys(" ", .command): "Spotlight",
  ]

  /// An action set to nil has no shortcut; one missing keeps its default.
  @Published private(set) var overrides: [String: KeyBinding?]
  /// ⌥⌥ and the like are off; the summon shortcut asks about a fresh selection instead.
  @Published var selectionSameAsSummon: Bool { didSet { defaults.set(selectionSameAsSummon, forKey: Self.sameAsSummonKey) } }
  /// While a shortcut is being recorded, no shortcut fires.
  @Published var isRecording = false

  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    overrides = defaults.data(forKey: Self.overridesKey)
      .flatMap { try? JSONDecoder().decode([String: KeyBinding?].self, from: $0) } ?? [:]
    selectionSameAsSummon = defaults.bool(forKey: Self.sameAsSummonKey)
  }

  func binding(_ action: ShortcutAction) -> KeyBinding? {
    if action == .selection, selectionSameAsSummon { return nil }
    if let override = overrides[action.id] { return override }
    return action.defaultBinding
  }

  func isChanged(_ action: ShortcutAction) -> Bool { overrides[action.id] != nil }

  func set(_ binding: KeyBinding?, for action: ShortcutAction) {
    overrides[action.id] = .some(binding)
    save()
  }

  func reset(_ action: ShortcutAction) {
    overrides[action.id] = nil
    save()
  }

  func resetAll() {
    overrides = [:]
    selectionSameAsSummon = false
    save()
  }

  /// What already uses `binding`, other than `action`, or nil when it's free.
  func conflict(_ binding: KeyBinding, for action: ShortcutAction) -> String? {
    if let reserved = Self.reserved[binding] { return "macOS uses \(binding.display) for \(reserved)." }
    if binding == Self.selectionBackup { return "\(binding.display) is the backup for asking about a selection." }
    if let other = ShortcutAction.all.first(where: { $0 != action && self.binding($0) == binding }) {
      return "\(binding.display) is already \(other.title)."
    }
    return nil
  }

  /// The window's action, or a command's, for a key press in Enigma.
  func action(for event: NSEvent) -> ShortcutAction? {
    guard !isRecording else { return nil }
    return (ShortcutAction.window + ShortcutAction.commands).first { binding($0)?.matches(event) == true }
  }

  private func save() {
    defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.overridesKey)
  }
}

extension Notification.Name {
  /// F14 spike: a command's shortcut; the object is its `SlashCommand`.
  static let commandShortcutPressed = Notification.Name("commandShortcutPressed")
}
