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
/// Settings → Shortcuts.
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
