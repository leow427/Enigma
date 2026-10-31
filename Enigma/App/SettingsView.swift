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
  /// A page with its "› Advanced" already open, like the model menu's Advanced settings….
  struct SettingsRequest {
    let destination: SettingsDestination
    let opensAdvanced: Bool
  }

  enum SettingsDestination: String, CaseIterable, Identifiable {
    // Grouped as Enigma, Models, Abilities, Privacy, then About.
    // The first four raw values are the old pages', so deep links still work.
    case general, shortcuts, local, cloud, search, selection, screen, files, messages, permissions, approvals, about

    var id: Self { self }

    static func opensAdvanced(_ object: Any?) -> Bool { (object as? SettingsRequest)?.opensAdvanced == true }

    /// A destination, a request, its raw value, or "discover" (removed; opens .local). Anything else is nil.
    static func requested(_ object: Any?) -> SettingsDestination? {
      if let destination = object as? SettingsDestination { return destination }
      if let request = object as? SettingsRequest { return request.destination }
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
      case .shortcuts: "Enigma works from the keyboard. Change any shortcut."
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

    /// What Return in the search field opens.
    static func firstMatch(_ query: String) -> SettingsDestination? { allCases.first { $0.matches(query) } }

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
  /// The page asked for opens its Advanced; any other navigation closes it again.
  @State private var opensAdvanced = false
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
       size: CGSize = SettingsView.windowSize, opensAdvanced: Bool = false) {
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
    _opensAdvanced = State(initialValue: opensAdvanced)
  }

  var body: some View {
    HStack(spacing: 0) {
      navigation
      page
    }
    .environment(\.enigmaSettingsStyle, true)
    .frame(width: size.width, height: size.height)
    .background(palette.background.color)
    .tint(palette.accent.color)
    .enigmaMenuHost()
    .onReceive(NotificationCenter.default.publisher(for: .settingsDestinationRequested)) { notification in
      if let requested = SettingsDestination.requested(notification.object) {
        select(requested)
        opensAdvanced = SettingsDestination.opensAdvanced(notification.object)
      }
    }
  }

  private func select(_ item: SettingsDestination) {
    opensAdvanced = false
    guard item != destination else { return }
    withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { destination = item }
  }

  // MARK: Navigation

  private var navigation: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Finds a page by its name or what's on it; Return opens the first match.
      EnigmaTextField("Search", text: $query, accessibilityLabel: "Search Settings", onSubmit: {
        if let first = SettingsDestination.firstMatch(query) { select(first) }
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
          // A page that starts with a card, not a heading, still clears the subtitle.
          .padding(.bottom, 16)
        pageContent
      }
      .settingsCards(inset: 14)
      .padding(.horizontal, Self.pagePadding)
      .padding(.top, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    // Each page gets its own scroll position, and pages cross-fade with a
    // small rise. Reduce Motion keeps only the fade.
    .environment(\.settingsOpensAdvanced, opensAdvanced)
    .id(destination)
    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
  }

  @ViewBuilder private var pageContent: some View {
    switch destination {
    case .general:
      GeneralSettingsPage(appearance: appearance, startPreferences: startPreferences, chat: chat)
    case .shortcuts:
      ShortcutEditor()
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

#if DEBUG
#Preview("Settings, Paper") {
  SettingsView().enigmaTheme(.paper)
}

#Preview("Settings, Ink") {
  SettingsView(initialDestination: .cloud).enigmaTheme(.ink)
}
#endif
