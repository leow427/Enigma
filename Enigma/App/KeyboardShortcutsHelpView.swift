import SwiftUI

/// Help: every shortcut, as hairline rows with monospace keys, and the
/// selection shortcut settings.
struct KeyboardShortcutsHelpView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.enigmaPalette) private var palette

  static let size = CGSize(width: 500, height: 540)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Keyboard shortcuts")
        .font(EnigmaTypography.ui(20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 28)
        .padding(.top, 24)
      Text("Enigma works from the keyboard, in any app.")
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 8)
      ScrollView {
        KeyboardShortcutsList()
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
      }
      .scrollBounceBehavior(.basedOnSize)
      EnigmaHairline()
      HStack {
        Spacer()
        Button { dismiss() } label: {
          HStack(spacing: 10) {
            Text("Done")
            EnigmaKeycap("↵")
          }
        }
        .enigmaButtonStyle(.primary)
        .keyboardShortcut(.defaultAction)
        .enigmaTestMarker("Done")
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 14)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .enigmaMenuHost()
    .onExitCommand { dismiss() }
  }
}

/// Every shortcut and the selection shortcut's settings: in Help, and on
/// Settings → Shortcuts (F14 spike).
struct KeyboardShortcutsList: View {
  @ObservedObject private var selectionAccess = SelectionAccessibilityAccess.shared
  @AppStorage(SelectionShortcutMonitor.intervalKey) private var doubleTapInterval = 0.35
  @Environment(\.enigmaPalette) private var palette

  private var modifier: SelectionModifier {
    ShortcutStore.shared.binding(.selection).flatMap { SelectionModifier(flags: $0.flags) } ?? .option
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      anywhere
      inThePanel
      editing
      EnigmaHint(KeyboardShortcutsHelp.legend)
        .padding(.top, 14)
    }
  }

  private var anywhere: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Anywhere on your Mac")
      row(KeyboardShortcutsHelp.selectionChat(modifier: modifier))
      row(KeyboardShortcutsHelp.selectionBackup)
      EnigmaRow("Double-tap interval") {
        EnigmaMenu("Double-tap interval", selection: $doubleTapInterval,
                   options: KeyboardShortcutsHelp.intervals.map { EnigmaOption($0.seconds, $0.title) })
      }
      EnigmaHairline()
      EnigmaNote("Change any shortcut in Settings → Shortcuts.").padding(.top, 10)
      EnigmaNote(KeyboardShortcutsHelp.selectionNote).padding(.top, 6)
      VStack(alignment: .leading, spacing: 8) {
        EnigmaStatusLine(selectionAccess.isGranted ? .on : .off,
                         selectionAccess.isGranted ? "accessibility enabled" : "accessibility permission required")
        EnigmaNote(KeyboardShortcutsHelp.accessibilityNote(appName: SelectionAccessibilityAccess.appName))
        Button("Open Accessibility Settings…") { selectionAccess.requestAccess() }
          .enigmaButtonStyle(.secondary)
      }
      .padding(.top, 12)
      .padding(.bottom, 4)
      row(KeyboardShortcutsHelp.showOrHide)
      EnigmaHairline()
      EnigmaNote(KeyboardShortcutsHelp.showOrHideNote).padding(.vertical, 10)
    }
  }

  private var inThePanel: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("In the chat panel")
      ForEach(KeyboardShortcutsHelp.panel, id: \.self) { row($0) }
      row(KeyboardShortcutsHelp.search)
      row(KeyboardShortcutsHelp.maps)
      EnigmaHairline()
      EnigmaNote(KeyboardShortcutsHelp.searchNote).padding(.vertical, 10)
      ForEach(KeyboardShortcutsHelp.commands, id: \.self) { row($0) }
      EnigmaHairline()
      EnigmaNote(KeyboardShortcutsHelp.commandsNote()).padding(.top, 10)
    }
  }

  private var editing: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Editing text")
      ForEach(KeyboardShortcutsHelp.editing, id: \.self) { row($0) }
      EnigmaHairline()
    }
  }

  private func row(_ shortcut: KeyboardShortcutsHelp.Shortcut) -> some View {
    EnigmaRow(shortcut.title) {
      Text(shortcut.compactKeys)
        .font(EnigmaTypography.mono(12))
        .foregroundStyle(palette.textSecondary.color)
        .accessibilityLabel(shortcut.keys)
    }
  }
}

// MARK: F14 spike: Settings → Shortcuts

/// Records a shortcut for one action at a time: keys with ⌘, ⌃ or ⌥ for any
/// action, and for opening Enigma or asking about a selection also modifiers
/// pressed together (⌥⌃) or one tapped twice (⌥⌥). Esc cancels; Delete
/// removes the shortcut.
@MainActor
final class ShortcutRecorder: ObservableObject {
  @Published private(set) var recording: ShortcutAction?
  @Published private(set) var message: String?
  private let store: ShortcutStore
  private var monitor: Any?
  /// The modifiers held together since they were last all released.
  private var held: NSEvent.ModifierFlags = []
  private var lastTap: (flags: NSEvent.ModifierFlags, at: TimeInterval)?

  init(store: ShortcutStore = .shared) { self.store = store }

  func toggle(_ action: ShortcutAction) {
    if recording == action { stop() } else { start(action) }
  }

  func start(_ action: ShortcutAction) {
    stop()
    recording = action
    store.isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      self?.receive(event) ?? event
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = nil
    message = nil
    held = []
    lastTap = nil
    store.isRecording = false
  }

  private func receive(_ event: NSEvent) -> NSEvent? {
    guard let action = recording else { return event }
    let flags = event.modifierFlags.intersection(KeyBinding.relevant)
    if event.type == .keyDown {
      switch event.keyCode {
      case 53 where flags.isEmpty: stop()
      case 51 where flags.isEmpty, 117 where flags.isEmpty:
        store.set(nil, for: action)
        stop()
      default:
        if let binding = KeyBinding(keyDown: event) { finish(binding, for: action) }
        else { message = "Include ⌘, ⌃ or ⌥, so typing never sets it off." }
      }
      return nil
    }
    // Modifiers alone count only for the two shortcuts that work in any app.
    guard action.isGlobal else { return event }
    if !flags.isEmpty { held.formUnion(flags); return event }
    let pressed = held
    held = []
    let count = [NSEvent.ModifierFlags.control, .option, .shift, .command].filter { pressed.contains($0) }.count
    if count >= 2 {
      finish(KeyBinding(kind: .chord, modifiers: pressed.rawValue), for: action)
    } else if count == 1, let tap = lastTap, tap.flags == pressed, event.timestamp - tap.at < 0.5 {
      finish(KeyBinding(kind: .doubleTap, modifiers: pressed.rawValue), for: action)
    } else if count == 1 {
      lastTap = (pressed, event.timestamp)
    }
    return event
  }

  private func finish(_ binding: KeyBinding, for action: ShortcutAction) {
    lastTap = nil
    if let conflict = store.conflict(binding, for: action) {
      message = conflict + " Try another."
      return
    }
    store.set(binding, for: action)
    stop()
  }
}

/// Settings → Shortcuts: every shortcut, each one changeable.
struct ShortcutEditor: View {
  @ObservedObject private var store = ShortcutStore.shared
  @StateObject private var recorder = ShortcutRecorder()
  @AppStorage(SelectionShortcutMonitor.intervalKey) private var doubleTapInterval = 0.35

  static let sameAsSummonNote = "Your summon shortcut then attaches text you’ve just selected, and otherwise opens Enigma as usual. Reading a selection can take a moment, up to about 2 seconds the first time in Chrome and other Electron apps, and the selection panel opens under the text rather than in the middle of the screen."

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Anywhere on your Mac")
      row(.summon, subtitle: "Works in any app.")
      row(.selection, subtitle: store.selectionSameAsSummon ? "Uses the summon shortcut." : "Select text first.")
        .disabled(store.selectionSameAsSummon)
      EnigmaRow("Same as summon", subtitle: "One shortcut for both.", info: Self.sameAsSummonNote) {
        EnigmaSwitch("Same as summon", isOn: $store.selectionSameAsSummon)
      }
      EnigmaRow("Backup for selected text", subtitle: "Always on.") {
        Text(ShortcutStore.selectionBackup.display)
          .font(EnigmaTypography.ui(13))
      }
      EnigmaRow("Double-tap speed") {
        EnigmaMenu("Double-tap speed", selection: $doubleTapInterval,
                   options: KeyboardShortcutsHelp.intervals.map { EnigmaOption($0.seconds, $0.title) })
      }
      EnigmaHairline()

      EnigmaSectionHeader("In Enigma")
      ForEach(ShortcutAction.window) { row($0) }
      EnigmaHairline()

      EnigmaSectionHeader("Commands")
      ForEach(ShortcutAction.commands) { action in
        if case .command(let command) = action { row(action, subtitle: command.description) }
      }
      EnigmaHairline()

      HStack {
        Spacer()
        Button("Restore Defaults") { recorder.stop(); store.resetAll() }
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Restore Default Shortcuts")
      }
      .padding(.top, 16)
    }
    .onDisappear { recorder.stop() }
  }

  private func row(_ action: ShortcutAction, subtitle: String? = nil) -> some View {
    let isRecording = recorder.recording == action
    return EnigmaRow(action.title, subtitle: subtitle) {
      if isRecording {
        EnigmaNote(recorder.message ?? (action.isGlobal
          ? "Press keys, press modifiers together, or tap one twice. Esc cancels; Delete removes it."
          : "Press keys with ⌘, ⌃ or ⌥. Esc cancels; Delete removes it."))
          .padding(.top, 4)
      }
    } trailing: {
      HStack(spacing: 8) {
        if store.isChanged(action) && !isRecording {
          Button("Reset") { store.reset(action) }
            .enigmaButtonStyle(.text)
            .accessibilityLabel("Reset \(action.title)")
        }
        Button(isRecording ? "Type shortcut…" : store.binding(action)?.display ?? "None") { recorder.toggle(action) }
          .enigmaButtonStyle(isRecording ? .primary : .secondary)
          .accessibilityLabel("Shortcut for \(action.title)")
          .enigmaTestMarker("Shortcut \(action.id)")
      }
    }
  }
}
