import AppKit
import SwiftUI

// The Settings window in the new design: plain-text navigation with a dot on
// the selected section, and pages of hairline-divided rows. It has the same
// five destinations, settings, and deep links as `SettingsView`.

extension SettingsView.SettingsDestination {
  /// The section's name in the new Settings, in sentence case as in the mockup.
  var enigmaTitle: String {
    switch self {
    case .general: "General"
    case .local: "Local models"
    case .discover: "Discover"
    case .cloud: "Cloud and search"
    case .selection: "Selection"
    }
  }

  /// The one line under the page's heading.
  var enigmaSubtitle: String {
    switch self {
    case .general: "How Enigma looks, starts, and works with your Mac."
    case .local: "Run models on this Mac, without the cloud."
    case .discover: "Find your next vision or audio model."
    case .cloud: "Optional cloud models, screenshots, and web search."
    case .selection: "Permissions for selected text, and how revisions are applied."
    }
  }

  /// The navigation glyph, matching the mockup's icons.
  var enigmaSymbol: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .local: "cpu"
    case .discover: "safari"
    case .cloud: "cloud"
    case .selection: "text.cursor"
    }
  }
}

/// The Settings window's content: the new design while "Use new UI" is on,
/// and the old one otherwise. It switches as soon as the flag changes.
struct SettingsWindowContent<NewSettings: View, OldSettings: View>: View {
  @ObservedObject var newUI: NewUIPreference
  @ObservedObject var appearance: EnigmaAppearancePreference
  let newSettings: () -> NewSettings
  let oldSettings: () -> OldSettings

  /// Tests pass views with fixtures; the app uses the shared models.
  init(newUI: NewUIPreference, appearance: EnigmaAppearancePreference,
       newSettings: @escaping () -> NewSettings, oldSettings: @escaping () -> OldSettings) {
    self.newUI = newUI
    self.appearance = appearance
    self.newSettings = newSettings
    self.oldSettings = oldSettings
  }

  var body: some View {
    if newUI.isEnabled {
      // Its backgrounds run up under the window's transparent title bar, so
      // the navigation reaches the top edge, as in the mockup.
      newSettings().enigmaTheme(appearance.appearance)
    } else {
      oldSettings()
    }
  }
}

extension SettingsWindowContent where NewSettings == EnigmaSettingsView, OldSettings == SettingsView {
  init(newUI: NewUIPreference, appearance: EnigmaAppearancePreference) {
    self.init(newUI: newUI, appearance: appearance,
              newSettings: { EnigmaSettingsView(appearance: appearance) }, oldSettings: { SettingsView() })
  }
}

/// The new Settings. The window it sits in applies the theme.
struct EnigmaSettingsView: View {
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
  @StateObject private var discovery: LocalModelDiscovery
  private let downloads: HuggingFaceModelDownloads
  private let sources: HuggingFaceDownloadSources
  private let size: CGSize
  @State private var destination: SettingsView.SettingsDestination
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  /// `size` is the area below the window's title bar, if it has one.
  init(settings: CloudSettingsModel = .shared, appearance: EnigmaAppearancePreference = .shared,
       initialDestination: SettingsView.SettingsDestination = .general, discovery: LocalModelDiscovery? = nil,
       advisor: LocalModelAdvisor = .shared, chat: LocalChatViewModel = .shared,
       search: WebSearchSettings = .shared, screen: ScreenSettings = .shared,
       startPreferences: StartPreferences = .shared, selectionEditing: SelectionEditingSettings = .shared,
       location: LocationService = .shared, downloads: HuggingFaceModelDownloads = .shared,
       sources: HuggingFaceDownloadSources = .live, size: CGSize = EnigmaSettingsView.windowSize) {
    self.settings = settings
    self.appearance = appearance
    self.advisor = advisor
    self.chat = chat
    self.search = search
    self.screen = screen
    self.startPreferences = startPreferences
    self.selectionEditing = selectionEditing
    self.location = location
    self.downloads = downloads
    self.sources = sources
    self.size = size
    _destination = State(initialValue: initialDestination)
    _discovery = StateObject(wrappedValue: discovery ?? LocalModelDiscovery())
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
      if let requested = notification.object as? SettingsView.SettingsDestination { select(requested) }
    }
  }

  private func select(_ item: SettingsView.SettingsDestination) {
    guard item != destination else { return }
    withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { destination = item }
  }

  // MARK: Navigation

  private var navigation: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(SettingsView.SettingsDestination.allCases) { item in
        EnigmaSettingsNavigationItem(item: item, isSelected: destination == item) { select(item) }
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
        EnigmaSettingsPageHeader(destination: destination)
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
      EnigmaGeneralSettingsPage(appearance: appearance, startPreferences: startPreferences, location: location,
                                chat: chat)
    case .local:
      EnigmaLocalModelManagerSection(advisor: advisor, chat: chat, downloads: downloads, sources: sources)
    case .discover:
      EnigmaLocalModelDiscoveryView(discovery: discovery, advisor: advisor, chat: chat, downloads: downloads,
                                    sources: sources)
    case .cloud:
      EnigmaCloudSettingsPage(settings: settings, screen: screen, search: search)
    case .selection:
      EnigmaSelectionSettingsPage(selectionEditing: selectionEditing)
    }
  }
}

/// A section in the navigation: its glyph and name, darker with a dot when selected.
private struct EnigmaSettingsNavigationItem: View {
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
        Image(systemName: item.enigmaSymbol)
          .font(EnigmaTypography.navigationSymbol)
          .frame(width: 18)
          .foregroundStyle((isSelected ? palette.accentText : emphasized ? palette.textPrimary : palette.textSecondary).color)
          .padding(.trailing, 8)
          .accessibilityHidden(true)
        Text(item.enigmaTitle)
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
    .accessibilityLabel(item.enigmaTitle)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .enigmaTestMarker("Settings section \(item.enigmaTitle)")
  }
}

/// A page's semibold heading and its one secondary line.
struct EnigmaSettingsPageHeader: View {
  let title: String
  let subtitle: String
  @Environment(\.enigmaPalette) private var palette

  init(destination: SettingsView.SettingsDestination) {
    title = destination.enigmaTitle
    subtitle = destination.enigmaSubtitle
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

/// Appearance, permissions, the welcome, new chats, location, and Messages.
struct EnigmaGeneralSettingsPage: View {
  @ObservedObject var appearance: EnigmaAppearancePreference
  @ObservedObject var startPreferences: StartPreferences
  @ObservedObject var location: LocationService
  /// Only Replay reads it, through `EnigmaReplayWelcomeButton`.
  let chat: LocalChatViewModel
  @Environment(\.enigmaPalette) private var palette

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
      EnigmaMacPermissionRows()

      EnigmaSectionHeader("Welcome")
      EnigmaRow("Replay welcome setup",
                subtitle: "Try setup and the walkthrough again. Your chats, installed models, and credentials are kept.") {
        EnigmaReplayWelcomeButton(chat: chat)
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
      EnigmaNote("Used at launch and for each new chat or Selection Context session.").padding(.top, 8)

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
      EnigmaMessagesSettingsSection()
    }
  }
}

/// Replay, which waits while the local model is busy, as the old button does.
private struct EnigmaReplayWelcomeButton: View {
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

/// The Accessibility permission and automatic replacement.
struct EnigmaSelectionSettingsPage: View {
  @ObservedObject var selectionEditing: SelectionEditingSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Required for selection capture and replacement")
      EnigmaMacPermissionRows(showScreen: false)

      EnigmaSectionHeader("Text editing")
      EnigmaRow("Automatically replace selected text",
                subtitle: "When on, completed /edit responses are pasted directly into the source app, without a preview card or Replace text click. Questions and /translate stay read-only.") {
        EnigmaSwitch("Automatically replace selected text", isOn: $selectionEditing.automaticallyReplace)
      }
      EnigmaHairline()
      EnigmaNote("When off, review the revised text, edit it yourself, or use /edit again to ask for more changes before choosing Replace text. Text is captured only when you double-tap Option.")
        .padding(.top, 8)
    }
  }
}

#if DEBUG
#Preview("Settings, Paper") {
  EnigmaSettingsView().enigmaTheme(.paper)
}

#Preview("Settings, Ink") {
  EnigmaSettingsView(initialDestination: .cloud).enigmaTheme(.ink)
}
#endif
