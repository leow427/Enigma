import AppKit
import SwiftUI

// MARK: Shared

/// A row that opens another Settings page.
struct SettingsLink: View {
  let title: String
  let subtitle: String?
  let destination: SettingsView.SettingsDestination
  @Environment(\.enigmaPalette) private var palette

  init(_ title: String, subtitle: String? = nil, to destination: SettingsView.SettingsDestination) {
    self.title = title
    self.subtitle = subtitle
    self.destination = destination
  }

  var body: some View {
    EnigmaRow(title, subtitle: subtitle,
              action: { NotificationCenter.default.post(name: .settingsDestinationRequested, object: destination) }) {
      Text("\(destination.title) ›")
        .font(EnigmaTypography.ui(12.5))
        .foregroundStyle(palette.textSecondary.color)
    }
  }
}

/// A page's "› Advanced" disclosure, closed until opened.
struct SettingsAdvanced<Content: View>: View {
  @ViewBuilder var content: () -> Content
  @State private var isOpen = false
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { isOpen.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
          Text("Advanced")
            .font(EnigmaTypography.ui(12.5, weight: .medium))
        }
        .foregroundStyle(palette.textSecondary.color)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isOpen ? "Hide advanced settings" : "Show advanced settings")
      .enigmaTestMarker("Advanced")
      .padding(.top, 22)
      if isOpen { content().transition(.opacity) }
    }
  }
}

// MARK: General

/// Appearance, how new chats start, recognized commands, and the welcome.
struct GeneralSettingsPage: View {
  @ObservedObject var appearance: EnigmaAppearancePreference
  @ObservedObject var startPreferences: StartPreferences
  /// Only Replay reads it, through `ReplayWelcomeButton`.
  let chat: LocalChatViewModel
  @AppStorage(ComposerIntent.inferCommandsKey) private var infersCommands = ComposerIntent.infersCommandsByDefault

  static let newChatsNote = "Used at launch, for each new chat, and for each selection chat."
  static let inferCommandsNote = "Turns on Messages, Think, Edit, and Translate when your wording asks for them, shown as a chip you can remove. Screen and Snapshot always need their command."

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Look")
      EnigmaRow("Appearance", subtitle: "System follows your Mac.") {
        EnigmaSegmentedControl("Appearance", selection: $appearance.appearance,
                               options: EnigmaAppearance.allCases.map { EnigmaOption($0, $0.title) })
      }
      EnigmaHairline()
      EnigmaSectionHeader("New chats")
      EnigmaRow("Start mode", subtitle: "Auto picks a model for each question.", info: Self.newChatsNote) {
        EnigmaMenu("Prefer Start Mode", selection: $startPreferences.mode,
                   options: ChatMode.allCases.map { EnigmaOption($0, $0.displayName) })
      }
      EnigmaRow("Show sidebar") {
        EnigmaSwitch("Show sidebar", isOn: $startPreferences.showsSidebar)
      }
      EnigmaHairline()
      EnigmaSectionHeader("Commands")
      EnigmaRow("Recognize commands from your wording", subtitle: "Smaller models otherwise need a /.",
                info: Self.inferCommandsNote) {
        EnigmaSwitch("Recognize commands from your wording", isOn: $infersCommands)
      }
      EnigmaHairline()
      EnigmaSectionHeader("Welcome")
      EnigmaRow("Welcome and tour", subtitle: "Your chats, models and sign-ins are kept.") {
        ReplayWelcomeButton(chat: chat)
      }
      EnigmaHairline()
    }
  }
}

/// Replay, which waits while the local model or a model install is busy.
private struct ReplayWelcomeButton: View {
  @ObservedObject var chat: LocalChatViewModel

  var body: some View {
    Button("Replay") {
      NotificationCenter.default.post(name: .welcomeSetupRequested, object: nil)
    }
    .enigmaButtonStyle(.secondary)
    .disabled(!chat.canChangeModels)
    .accessibilityLabel("Replay Welcome Setup")
  }
}

// MARK: Search and maps

/// Web search, location for places and weather, and, under Advanced, Brave and blocked sites.
struct SearchSettingsPage: View {
  @ObservedObject var search: WebSearchSettings
  @ObservedObject var location: LocationService
  @Environment(\.enigmaPalette) private var palette

  static let locationExplanation = "When you ask about the weather or nearby places, macOS asks for permission. The model answering, local or cloud, can get your exact location. Search sites get only your city; weather and Apple Maps get coordinates rounded to about 1 km. Nothing is saved and nothing runs in the background."

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WebSearchSettingsSection(settings: search, part: .main)
      EnigmaRow("Use location for nearby questions", subtitle: location.status, info: Self.locationExplanation) {
        EnigmaSwitch("Use location for nearby questions", isOn: $location.isEnabled)
      }
      EnigmaHairline()
      SettingsAdvanced {
        WebSearchSettingsSection(settings: search, part: .advanced)
      }
    }
  }
}

// MARK: Selection

/// Automatic replacement and whether selection chats stay private.
struct SelectionSettingsPage: View {
  @ObservedObject var selectionEditing: SelectionEditingSettings
  @SelectionShortcutPhrase private var selectionShortcut

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Automatically replace selected text", subtitle: "Edits go straight back, without Replace text.",
                info: "When on, completed /edit responses are pasted directly into the source app, without a preview card or Replace text click. Questions and /translate stay read-only. When off, review the revised text first. Text is captured only when you \(selectionShortcut).") {
        EnigmaSwitch("Automatically replace selected text", isOn: $selectionEditing.automaticallyReplace)
      }
      EnigmaRow(SelectionEditingSettings.privateChatsTitle,
                info: SelectionEditingSettings.privateChatsSubtitle(isOn: selectionEditing.keepsChatsPrivate)) {
        EnigmaSwitch(SelectionEditingSettings.privateChatsTitle, isOn: $selectionEditing.keepsChatsPrivate)
      }
      SettingsLink("Accessibility", subtitle: "Needed to read and replace text in other apps.", to: .permissions)
      SettingsLink("Selection shortcut", subtitle: "⌥⌥ by default.", to: .shortcuts)
      EnigmaHairline()
    }
  }
}

// MARK: Files

/// Nothing to set yet: what attaching does, and where it's explained.
struct FilesSettingsPage: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Attach", subtitle: "+ in the composer, or ⇧⌘A.")
      EnigmaRow("Changes", subtitle: "Notes and text change at once; code asks first. Every change can be undone.")
      EnigmaHairline()
    }
  }
}

// MARK: Permissions

/// Every macOS permission Enigma uses, with its state.
struct PermissionsSettingsPage: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Selection and screen")
      MacPermissionRows()
      EnigmaHairline()
      EnigmaSectionHeader("Messages")
      MessagesSettingsSection(part: .permissions)
      EnigmaHairline()
      EnigmaSectionHeader("Places and weather")
      EnigmaRow("Location", subtitle: "For nearby places and weather.") {
        Button("Open Settings…") { NSWorkspace.shared.open(LocationService.privacySettingsURL) }
          .enigmaButtonStyle(.secondary)
          .accessibilityLabel("Open Location Services Settings")
      }
      EnigmaHairline()
    }
  }
}

// MARK: About

/// Enigma's version and updates.
struct AboutSettingsPage: View {
  @ObservedObject var updater: AppUpdater

  static let automaticChecksNote = "Once a day, from Enigma’s GitHub page. Only Enigma’s version is sent."
  static let automaticInstallNote = "Updates install when Enigma quits, or when you choose Restart to Update in the menu bar."

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow("Version", subtitle: versionSubtitle) {
        Button("Check Now") { updater.checkForUpdates() }
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Check for Updates Now")
          .disabled(!updater.canCheckForUpdates)
          .accessibilityLabel("Check for Updates Now")
      }
      EnigmaRow("Check for updates automatically", info: Self.automaticChecksNote) {
        EnigmaSwitch("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
      }
      EnigmaRow("Install updates automatically", info: Self.automaticInstallNote) {
        EnigmaSwitch("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
          .disabled(!updater.automaticallyChecksForUpdates)
      }
      EnigmaHairline()
    }
  }

  private var versionSubtitle: String {
    AppUpdater.versionText(info: Bundle.main.infoDictionary ?? [:]) + " · "
      + AppUpdater.lastCheckedText(updater.lastUpdateCheckDate, now: .now, locale: .current)
  }
}
