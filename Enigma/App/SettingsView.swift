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
    case general, local, cloud, selection

    var id: Self { self }

    /// A destination, its raw value, or "discover" (removed; opens .local). Anything else is nil.
    static func requested(_ object: Any?) -> SettingsDestination? {
      if let destination = object as? SettingsDestination { return destination }
      guard let name = object as? String else { return nil }
      return name == "discover" ? .local : SettingsDestination(rawValue: name)
    }

    /// The section's name, in sentence case as in the mockup.
    var title: String {
      switch self {
      case .general: "General"
      case .local: "Local models"
      case .cloud: "Cloud and search"
      case .selection: "Selection"
      }
    }

    /// The one line under the page's heading.
    var subtitle: String {
      switch self {
      case .general: "How Enigma looks, starts, and works with your Mac."
      case .local: "Run models on this Mac, without the cloud."
      case .cloud: "Optional cloud models, screenshots, and web search."
      case .selection: "Permissions for selected text, how revisions are applied, and whether selection chats are saved."
      }
    }

    /// The navigation glyph, matching the mockup's icons.
    var symbol: String {
      switch self {
      case .general: "slider.horizontal.3"
      case .local: "cpu"
      case .cloud: "cloud"
      case .selection: "text.cursor"
      }
    }
  }

  static let windowSize = CGSize(width: 820, height: 680)
  static let navigationWidth: CGFloat = 176
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
      ForEach(SettingsDestination.allCases) { item in
        SettingsNavigationItem(item: item, isSelected: destination == item) { select(item) }
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
      GeneralSettingsPage(appearance: appearance, startPreferences: startPreferences, location: location,
                                chat: chat, updater: updater)
    case .local:
      LocalModelManagerSection(advisor: advisor, chat: chat)
    case .cloud:
      CloudSettingsPage(settings: settings, screen: screen, search: search)
    case .selection:
      SelectionSettingsPage(selectionEditing: selectionEditing)
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

// MARK: General

/// Appearance, permissions, the welcome, new chats, location, Messages, and updates.
struct GeneralSettingsPage: View {
  @ObservedObject var appearance: EnigmaAppearancePreference
  @ObservedObject var startPreferences: StartPreferences
  @ObservedObject var location: LocationService
  /// Only Replay reads it, through `ReplayWelcomeButton`.
  let chat: LocalChatViewModel
  @ObservedObject var updater: AppUpdater
  @Environment(\.enigmaPalette) private var palette

  static let newChatsNote = "Used at launch, for each new chat, and for each selection chat."
  static let automaticChecksNote = "Once a day, from Enigma’s GitHub page. Only Enigma’s version is sent."
  static let automaticInstallNote = "Updates install when Enigma quits, or when you choose Restart to Update in the menu bar."
  static let locationExplanation = "When you ask about local weather or nearby places, macOS asks for permission. Your approximate area is sent to Brave Search and included with the answer context. Requires Web Search setup in Cloud and search. No background tracking."

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Look")
      EnigmaRow("Appearance", subtitle: "System follows your Mac’s light or dark setting.") {
        EnigmaSegmentedControl("Appearance", selection: $appearance.appearance,
                               options: EnigmaAppearance.allCases.map { EnigmaOption($0, $0.title) })
      }
      EnigmaHairline()

      EnigmaSectionHeader("Permissions")
      MacPermissionRows()

      EnigmaSectionHeader("Welcome")
      EnigmaRow("Replay welcome setup",
                subtitle: "Try setup and the walkthrough again. Your chats, installed models, and credentials are kept.") {
        ReplayWelcomeButton(chat: chat)
      }
      EnigmaHairline()

      EnigmaSectionHeader("New chats")
      EnigmaRow("Start mode") {
        EnigmaMenu("Prefer Start Mode", selection: $startPreferences.mode,
                   options: ChatMode.allCases.map { EnigmaOption($0, $0.displayName) })
      }
      EnigmaRow("Show sidebar") {
        EnigmaSwitch("Show sidebar", isOn: $startPreferences.showsSidebar)
      }
      EnigmaHairline()
      EnigmaNote(Self.newChatsNote).padding(.top, 8)

      EnigmaSectionHeader("Location")
      EnigmaRow("Use location for nearby questions", subtitle: Self.locationExplanation) {
        Text(location.status)
          .font(EnigmaTypography.mono(11.5))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      } trailing: {
        EnigmaSwitch("Use location for nearby questions", isOn: $location.isEnabled)
      }
      EnigmaRow("Location Services", subtitle: "Allow or deny location access for Enigma in System Settings.") {
        Button("Open Settings…") { NSWorkspace.shared.open(LocationService.privacySettingsURL) }
          .enigmaButtonStyle(.secondary)
          .accessibilityLabel("Open Location Services Settings")
      }
      EnigmaHairline()

      EnigmaSectionHeader("Messages · /messages")
      MessagesSettingsSection()

      EnigmaSectionHeader("Updates")
      EnigmaRow("Check for updates automatically", subtitle: Self.automaticChecksNote) {
        EnigmaSwitch("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
      }
      EnigmaRow("Download and install updates automatically", subtitle: Self.automaticInstallNote) {
        EnigmaSwitch("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
          .disabled(!updater.automaticallyChecksForUpdates)
      }
      EnigmaRow("Version", subtitle: versionSubtitle) {
        Button("Check Now") { updater.checkForUpdates() }
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Check for Updates Now")
          .disabled(!updater.canCheckForUpdates)
          .accessibilityLabel("Check for Updates Now")
      }
      EnigmaHairline()
    }
  }

  private var versionSubtitle: String {
    AppUpdater.versionText(info: Bundle.main.infoDictionary ?? [:]) + " · "
      + AppUpdater.lastCheckedText(updater.lastUpdateCheckDate, now: .now, locale: .current)
  }
}

/// Replay, which waits while the local model is busy.
private struct ReplayWelcomeButton: View {
  @ObservedObject var chat: LocalChatViewModel

  var body: some View {
    Button("Replay") {
      NotificationCenter.default.post(name: .welcomeSetupRequested, object: nil)
    }
    .enigmaButtonStyle(.secondary)
    .disabled(chat.isBusy)
    .accessibilityLabel("Replay Welcome Setup")
  }
}

// MARK: Selection

/// The Accessibility permission, automatic replacement, and whether selection
/// chats stay private.
struct SelectionSettingsPage: View {
  @ObservedObject var selectionEditing: SelectionEditingSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Required for selection capture and replacement")
      MacPermissionRows(showScreen: false)

      EnigmaSectionHeader("Text editing")
      EnigmaRow("Automatically replace selected text",
                subtitle: "When on, completed /edit responses are pasted directly into the source app, without a preview card or Replace text click. Questions and /translate stay read-only.") {
        EnigmaSwitch("Automatically replace selected text", isOn: $selectionEditing.automaticallyReplace)
      }
      EnigmaHairline()
      EnigmaNote("When off, review the revised text, edit it yourself, or use /edit again to ask for more changes before choosing Replace text. Text is captured only when you double-tap Option.")
        .padding(.top, 8)

      EnigmaSectionHeader("Privacy")
      EnigmaRow(SelectionEditingSettings.privateChatsTitle,
                subtitle: SelectionEditingSettings.privateChatsSubtitle(isOn: selectionEditing.keepsChatsPrivate)) {
        EnigmaSwitch(SelectionEditingSettings.privateChatsTitle, isOn: $selectionEditing.keepsChatsPrivate)
      }
      EnigmaHairline()
    }
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
