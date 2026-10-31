import AppKit
import SwiftUI

// The Settings window: plain-text navigation with a dot on the selected
// section, and pages of hairline-divided rows.

/// The Settings window's content, in the saved appearance. Tests pass views
/// with fixtures; the app uses the shared models.
struct SettingsWindowContent<Settings: View>: View {
  @ObservedObject var appearance: EnigmaAppearancePreference
  let settings: () -> Settings

  init(appearance: EnigmaAppearancePreference, settings: @escaping () -> Settings) {
    self.appearance = appearance
    self.settings = settings
  }

  var body: some View {
    // Its backgrounds run up under the window's transparent title bar, so
    // the navigation reaches the top edge, as in the mockup.
    settings().enigmaTheme(appearance.appearance)
  }
}

extension SettingsWindowContent where Settings == SettingsView {
  init(appearance: EnigmaAppearancePreference) {
    self.init(appearance: appearance, settings: { SettingsView(appearance: appearance) })
  }
}

/// Settings. The window it sits in applies the theme.
struct SettingsView: View {
  /// A Settings page. `.settingsDestinationRequested` with one of these opens it.
  enum SettingsDestination: String, CaseIterable, Identifiable {
    // F14 spike: grouped as Enigma, Models, Abilities, Privacy, then About.
    // The first four raw values are the old pages', so deep links still work.
    case general, shortcuts, local, cloud, search, selection, screen, files, messages, permissions, approvals, about

    var id: Self { self }

    /// A destination, its raw value, or "discover" (removed; opens .local). Anything else is nil.
    static func requested(_ object: Any?) -> SettingsDestination? {
      if let destination = object as? SettingsDestination { return destination }
      guard let name = object as? String else { return nil }
      return name == "discover" ? .local : SettingsDestination(rawValue: name)
    }

    /// The sidebar's groups, in order. About stands alone at the bottom.
    static let groups: [(title: String?, items: [SettingsDestination])] = [
      ("Enigma", [.general, .shortcuts]),
      ("Models", [.local, .cloud]),
      ("Abilities", [.search, .selection, .screen, .files, .messages]),
      ("Privacy", [.permissions, .approvals]),
      (nil, [.about]),
    ]

    var title: String {
      switch self {
      case .general: "General"
      case .shortcuts: "Shortcuts"
      case .local: "On this Mac"
      case .cloud: "Cloud"
      case .search: "Search and maps"
      case .selection: "Selection"
      case .screen: "Screen"
      case .files: "Files"
      case .messages: "Messages"
      case .permissions: "Permissions"
      case .approvals: "Approvals"
      case .about: "About"
      }
    }

    /// The one short line under the page's heading.
    var subtitle: String {
      switch self {
      case .general: "How Enigma looks and starts."
      case .shortcuts: "Enigma works from the keyboard, in any app."
      case .local: "Models that run on this Mac, with nothing sent anywhere."
      case .cloud: "Optional ChatGPT and Claude, for harder questions."
      case .search: "Web search, places and weather."
      case .selection: "Ask about text you select in any app."
      case .screen: "Ask about what’s on your screen."
      case .files: "Attach files and folders to a chat."
      case .messages: "Read and send your texts, in your own words."
      case .permissions: "Everything Enigma can ask macOS for, in one place."
      case .approvals: "What you’ve allowed Enigma to do without asking."
      case .about: "Version and updates."
      }
    }

    var symbol: String {
      switch self {
      case .general: "slider.horizontal.3"
      case .shortcuts: "keyboard"
      case .local: "cpu"
      case .cloud: "cloud"
      case .search: "magnifyingglass"
      case .selection: "text.cursor"
      case .screen: "rectangle.dashed"
      case .files: "folder"
      case .messages: "message"
      case .permissions: "lock"
      case .approvals: "checkmark.shield"
      case .about: "info.circle"
      }
    }

    /// Words the sidebar's search finds this page by, besides its title.
    var keywords: [String] {
      switch self {
      case .general: ["appearance", "dark", "light", "start mode", "auto", "sidebar", "welcome", "replay", "tour", "commands", "wording"]
      case .shortcuts: ["keyboard", "double-tap", "option", "control", "hotkey", "interval"]
      case .local: ["model", "download", "install", "gguf", "memory", "local"]
      case .cloud: ["chatgpt", "claude", "openai", "anthropic", "gemini", "api key", "provider", "subscription", "effort", "thinking"]
      case .search: ["web", "brave", "location", "weather", "places", "maps", "blocked sites"]
      case .selection: ["edit", "replace", "revision", "private", "accessibility"]
      case .screen: ["screenshot", "snapshot", "screen recording", "cloud"]
      case .files: ["attach", "folder", "undo", "codex"]
      case .messages: ["imessage", "sms", "texts", "full disk access", "contacts"]
      case .permissions: ["accessibility", "screen recording", "full disk access", "contacts", "automation", "location", "privacy"]
      case .approvals: ["always", "allowed", "grants", "privacy"]
      case .about: ["version", "update", "check for updates"]
      }
    }

    func matches(_ query: String) -> Bool {
      let query = query.trimmingCharacters(in: .whitespaces).lowercased()
      return query.isEmpty || title.lowercased().contains(query) || keywords.contains { $0.contains(query) }
    }
  }

  static let windowSize = CGSize(width: 820, height: 680)
  static let navigationWidth: CGFloat = 200
  static let pagePadding: CGFloat = 30

  // Passed down to the pages, which observe what they read. Observing them
  // here would redraw every page on each streamed chat update.
  private let settings: CloudSettingsModel
  private let appearance: EnigmaAppearancePreference
  private let advisor: LocalModelAdvisor
  private let chat: LocalChatViewModel
  private let search: WebSearchSettings
  private let screen: ScreenSettings
  private let startPreferences: StartPreferences
  private let selectionEditing: SelectionEditingSettings
  private let location: LocationService
  private let updater: AppUpdater
  private let size: CGSize
  @State private var destination: SettingsDestination
  @State private var query = ""
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  /// `size` is the area below the window's title bar, if it has one.
  init(settings: CloudSettingsModel = .shared, appearance: EnigmaAppearancePreference = .shared,
       initialDestination: SettingsDestination = .general,
       advisor: LocalModelAdvisor = .shared, chat: LocalChatViewModel = .shared,
       search: WebSearchSettings = .shared, screen: ScreenSettings = .shared,
       startPreferences: StartPreferences = .shared, selectionEditing: SelectionEditingSettings = .shared,
       location: LocationService = .shared, updater: AppUpdater = .shared,
       size: CGSize = SettingsView.windowSize) {
    self.settings = settings
    self.appearance = appearance
    self.advisor = advisor
    self.chat = chat
    self.search = search
    self.screen = screen
    self.startPreferences = startPreferences
    self.selectionEditing = selectionEditing
    self.location = location
    self.updater = updater
    self.size = size
    _destination = State(initialValue: initialDestination)
  }

  var body: some View {
    HStack(spacing: 0) {
      navigation
      page
    }
    .environment(\.enigmaStrongDividers, true)
    .frame(width: size.width, height: size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .enigmaMenuHost()
    .onReceive(NotificationCenter.default.publisher(for: .settingsDestinationRequested)) { notification in
      if let requested = SettingsDestination.requested(notification.object) { select(requested) }
    }
  }

  private func select(_ item: SettingsDestination) {
    guard item != destination else { return }
    withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { destination = item }
  }

  // MARK: Navigation

  private var navigation: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Finds a page by its name or what's on it; Return opens the first match.
      EnigmaTextField("Search", text: $query, accessibilityLabel: "Search Settings", onSubmit: {
        if let first = SettingsDestination.allCases.first(where: { $0.matches(query) }) { select(first) }
      })
      .padding(.horizontal, 2)
      .padding(.bottom, 6)
      .enigmaTestMarker("Search Settings")
      ForEach(Array(SettingsDestination.groups.enumerated()), id: \.offset) { _, group in
        let items = group.items.filter { $0.matches(query) }
        if !items.isEmpty {
          if let title = group.title {
            Text(title)
              .font(EnigmaTypography.ui(12, weight: .semibold))
              .foregroundStyle(palette.textSecondary.color)
              .padding(.horizontal, 4)
              .padding(.top, 14)
              .padding(.bottom, 3)
              .accessibilityAddTraits(.isHeader)
          } else {
            Spacer().frame(height: 10)
          }
          ForEach(items) { item in
            SettingsNavigationItem(item: item, isSelected: destination == item) { select(item) }
          }
        }
      }
      if SettingsDestination.allCases.allSatisfy({ !$0.matches(query) }) {
        Text("No matches")
          .font(EnigmaTypography.ui(12.5))
          .foregroundStyle(palette.textTertiary.color)
          .padding(.horizontal, 4)
          .padding(.top, 8)
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 14)
    .padding(.horizontal, 10)
    .padding(.bottom, 12)
    .frame(width: Self.navigationWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(palette.sidebar.color)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color)
        .frame(width: 1 / displayScale)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings sections")
  }

  // MARK: Page

  private var page: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        SettingsPageHeader(destination: destination)
        pageContent
      }
      .padding(.horizontal, Self.pagePadding)
      .padding(.top, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    // Each page gets its own scroll position, and pages cross-fade with a
    // small rise. Reduce Motion keeps only the fade.
    .id(destination)
    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
  }

  @ViewBuilder private var pageContent: some View {
    switch destination {
    case .general:
      GeneralSettingsPage(appearance: appearance, startPreferences: startPreferences, chat: chat)
    case .shortcuts:
      KeyboardShortcutsList()
    case .local:
      LocalModelManagerSection(advisor: advisor, chat: chat)
    case .cloud:
      CloudSettingsPage(settings: settings)
    case .search:
      SearchSettingsPage(search: search, location: location)
    case .selection:
      SelectionSettingsPage(selectionEditing: selectionEditing)
    case .screen:
      ScreenSettingsSection(settings: screen)
      SettingsLink("Screen Recording", subtitle: "Needed for /screen and /snapshot.", to: .permissions)
    case .files:
      FilesSettingsPage()
    case .messages:
      MessagesSettingsSection(part: .about)
      SettingsLink("Full Disk Access and Contacts", subtitle: "Needed to read your chats.", to: .permissions)
      SettingsLink("Always allowed", subtitle: "Chats you let Enigma read without asking.", to: .approvals)
    case .permissions:
      PermissionsSettingsPage()
    case .approvals:
      MessagesSettingsSection(part: .approvals)
    case .about:
      AboutSettingsPage(updater: updater)
    }
  }
}

/// A section in the navigation: its glyph and name, darker with a dot when selected.
private struct SettingsNavigationItem: View {
  let item: SettingsView.SettingsDestination
  let isSelected: Bool
  let action: () -> Void
  @Environment(\.enigmaPalette) private var palette
  @FocusState private var isFocused: Bool
  @State private var isHovered = false

  var body: some View {
    let emphasized = isSelected || isHovered
    Button(action: action) {
      HStack(spacing: 0) {
        Image(systemName: item.symbol)
          .font(EnigmaTypography.navigationSymbol)
          .frame(width: 18)
          .foregroundStyle((isSelected ? palette.accentText : emphasized ? palette.textPrimary : palette.textSecondary).color)
          .padding(.trailing, 8)
          .accessibilityHidden(true)
        Text(item.title)
          .font(EnigmaTypography.ui(13, weight: isSelected ? .medium : .regular))
          .foregroundStyle((emphasized ? palette.textPrimary : palette.textSecondary).color)
          .lineLimit(1)
        Spacer(minLength: 2)
        EnigmaSelectionDot(isSelected: isSelected)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 6, outset: 0)
    .onHover { isHovered = $0 }
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .enigmaTestMarker("Settings section \(item.title)")
  }
}

/// A page's semibold heading and its one secondary line.
struct SettingsPageHeader: View {
  let title: String
  let subtitle: String
  @Environment(\.enigmaPalette) private var palette

  init(destination: SettingsView.SettingsDestination) {
    title = destination.title
    subtitle = destination.subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(EnigmaTypography.ui(20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
    }
    .enigmaTestMarker("Settings page \(title)")
  }
}

// MARK: Shared

/// F14 spike: a row that opens another Settings page.
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

/// F14 spike: a page's "› Advanced" disclosure, closed until opened.
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
      .padding(.top, 22)
      .accessibilityLabel(isOpen ? "Hide advanced settings" : "Show advanced settings")
      .enigmaTestMarker("Advanced")
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

#if DEBUG
#Preview("Settings, Paper") {
  SettingsView().enigmaTheme(.paper)
}

#Preview("Settings, Ink") {
  SettingsView(initialDestination: .cloud).enigmaTheme(.ink)
}
#endif
