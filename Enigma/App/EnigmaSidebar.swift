import SwiftUI

/// The main window's sidebar: the app mark, New chat, the
/// recent chats as plain rows, and Help, Settings, and Developer Tools at the
/// bottom, on the `sidebar` color. `AppShellView` owns every action.
struct EnigmaSidebar<DeveloperTools: View>: View {
  let rows: [ChatHistoryRow]
  /// The tour stop on screen, so the sidebar can scroll its target into view.
  let tourStep: TourTarget?
  let select: (ChatHistoryRow.Target) -> Void
  let newChat: () -> Void
  let hide: () -> Void
  let openHelp: () -> Void
  let openSettings: () -> Void
  @ViewBuilder let developerTools: () -> DeveloperTools
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  static var historyAnchor: String { "sidebar.history" }
  static var helpAnchor: String { "sidebar.help" }

  var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { scroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            history.id(Self.historyAnchor)
            Spacer(minLength: 20)
            footer
          }
          .padding(.top, 16)
          .padding(.horizontal, 10)
          .padding(.bottom, 12)
          .frame(minHeight: proxy.size.height, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onChange(of: tourStep, initial: true) { _, step in
          if step == .history { scroll.scrollTo(Self.historyAnchor, anchor: .top) }
          if step == .help { scroll.scrollTo(Self.helpAnchor, anchor: .center) }
        }
      }
    }
    .background(palette.sidebar.color)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color)
        .frame(width: 1 / displayScale)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")
  }

  /// The brand, New chat, and Recents: the tour's "Your conversations" stop.
  private var history: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        EnigmaMark(style: .filled).frame(width: 20, height: 20)
        Text("Enigma")
          .font(EnigmaTypography.ui(15, weight: .semibold))
          .tracking(-0.15)
          .foregroundStyle(palette.textPrimary.color)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        Button(action: hide) { Image(systemName: "sidebar.left") }
          .enigmaIconButtonStyle(size: CGSize(width: 28, height: 26))
          .accessibilityLabel("Hide chat history")
          .help("Hide chat history · ⌃⌘S")
          .enigmaTestMarker("Hide chat history")
      }
      .padding(.leading, 6)
      .padding(.bottom, 12)

      EnigmaNavigationRow("New chat", hint: "⌘N", action: newChat) {
        Image(systemName: "plus")
          .font(EnigmaTypography.symbol(13))
          .foregroundStyle(palette.onAccent.color)
          .frame(width: 20, height: 20)
          .background(palette.accent.color, in: Circle())
      }
      .tourTarget(.newChat)

      Text("Recents")
        .font(EnigmaTypography.ui(11.5, weight: .medium))
        .foregroundStyle(palette.textTertiary.color)
        .padding(.leading, 35)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          EnigmaNavigationRow(row.title, isSelected: row.isSelected, marker: "Recent \(row.title)",
                              action: { select(row.target) }) {
            EnigmaSelectionDot(isSelected: row.isSelected)
          }
        }
      }
    }
    .tourTarget(.history)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaNavigationRow("Help", action: openHelp) {
        Image(systemName: "questionmark.circle").font(EnigmaTypography.navigationSymbol)
          .foregroundStyle(palette.textSecondary.color)
      }
      .tourTarget(.help)
      .id(Self.helpAnchor)
      EnigmaNavigationRow("Settings", hint: "⌘,", action: openSettings) {
        Image(systemName: "gearshape").font(EnigmaTypography.navigationSymbol)
          .foregroundStyle(palette.textSecondary.color)
      }
      developerTools()
    }
  }
}

/// The slim bar at the top of the main page. With the sidebar hidden it keeps
/// the sidebar's actions in reach: show the sidebar, New chat, Help, and
/// Settings. Its right end is the window's top-right slot, for What's new?
/// after an update; while the sidebar is shown, the bar is there only when
/// that slot has something in it.
struct EnigmaTopBar: View {
  struct SidebarActions {
    let show: () -> Void
    let openHelp: () -> Void
    let openSettings: () -> Void
    let newChat: () -> Void
  }

  /// Nil while the sidebar is shown.
  let sidebarActions: SidebarActions?
  /// What's new?'s VoiceOver label and action, while an update's notes are unread.
  let whatsNew: (label: String, open: () -> Void)?
  /// Update available's action (F33), while an update waits.
  var update: (() -> Void)? = nil
  /// The bug report button, last in the slot; nil where it doesn't belong.
  var reportBug: (() -> Void)? = nil
  @Environment(\.enigmaPalette) private var palette

  static let height: CGFloat = 44

  static let updateTitle = "Update available"

  static func isShown(isSidebarVisible: Bool, hasWhatsNew: Bool, hasUpdate: Bool = false) -> Bool {
    !isSidebarVisible || hasWhatsNew || hasUpdate
  }

  var body: some View {
    HStack(spacing: 4) {
      if let actions = sidebarActions {
        Button(action: actions.show) { Image(systemName: "sidebar.left") }
          .enigmaIconButtonStyle()
          .tourTarget(.history)
          .accessibilityLabel("Show chat history")
          .help("Show chat history · ⌃⌘S")
          .enigmaTestMarker("Show chat history")
      }
      Spacer(minLength: 0)
      if let actions = sidebarActions {
        Button(action: actions.newChat) { Image(systemName: "plus") }
          .enigmaIconButtonStyle()
          .tourTarget(.newChat)
          .accessibilityLabel("New chat")
          .help("New chat · ⌘N")
          .enigmaTestMarker("Bar new chat")
        Button(action: actions.openHelp) { Image(systemName: "questionmark.circle") }
          .enigmaIconButtonStyle()
          .tourTarget(.help)
          .accessibilityLabel("Help")
          .help("Help")
          .enigmaTestMarker("Bar help")
        Button(action: actions.openSettings) { Image(systemName: "gearshape") }
          .enigmaIconButtonStyle()
          .accessibilityLabel("Settings")
          .help("Settings · ⌘,")
          .enigmaTestMarker("Bar settings")
      }
      if let update {
        // Quieter than What's new?: secondary text with a small accent dot.
        Button(action: update) {
          HStack(spacing: 5) {
            Circle().fill(palette.accent.color).frame(width: 6, height: 6)
            Text(Self.updateTitle)
          }
        }
        .enigmaButtonStyle(.text)
        .accessibilityLabel(Self.updateTitle)
        .help("Install the new version of Enigma")
        .enigmaTestMarker("Update available")
        .transition(.opacity)
      }
      if let whatsNew {
        Button("What's new?", action: whatsNew.open)
          .enigmaButtonStyle(.notice)
          .accessibilityLabel(whatsNew.label)
          .enigmaTestMarker("What's new")
          .padding(.leading, sidebarActions == nil ? 0 : 4)
          .transition(.opacity)
      }
      if let reportBug { ReportBugButton(action: reportBug) }
    }
    .padding(.horizontal, 12)
    .frame(height: Self.height)
  }
}

/// Report a bug, in the chat's top-right corner: a ladybug whose label slides out
/// toward the chat on hover.
struct ReportBugButton: View {
  static let title = "Report a bug"
  /// The corner it takes from the page's right edge: 12 pt inset and a 30 pt button, plus a little air.
  static let cornerWidth: CGFloat = 46

  /// Whether, floating in the corner, it stays clear of the chat column (680 pt at most, centred) in a
  /// main page this wide; if not, the top bar holds it instead, so it never covers a message.
  static func floatsClear(ofChatIn width: CGFloat) -> Bool {
    width >= MainPageLayout.columnMaximumWidth + 2 * cornerWidth
  }
  let action: () -> Void
  /// Over the chat rather than in the top bar: an opaque backing, so text scrolling under it never shows through.
  var isFloating = false
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered: Bool

  init(action: @escaping () -> Void, isFloating: Bool = false, isHovered: Bool = false) {
    self.action = action
    self.isFloating = isFloating
    _isHovered = State(initialValue: isHovered)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    Button(action: action) { Image(systemName: "ladybug") }
      .enigmaIconButtonStyle()
      .accessibilityLabel(Self.title)
      .enigmaTestMarker(Self.title)
      .background { if isFloating { shape.fill(palette.background.color) } }
      // Drawn over its neighbours, opaque, so nothing beside it moves.
      .overlay(alignment: .trailing) {
        if isHovered {
          Text(Self.title)
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textSecondary.color)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(palette.background.color, in: shape)
            .offset(x: -32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 6)))
        }
      }
      .onHover { hovering in
        withAnimation(reduceMotion ? nil : EnigmaControlStyle.press.animation) { isHovered = hovering }
      }
  }
}

/// Developer Tools, behind a disclosure: hardware detection and welcome replay.
/// Debug builds only; Settings offers both in release builds.
struct DeveloperToolsView: View {
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  let replayWelcome: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    EnigmaDisclosure("Developer Tools") {
      VStack(alignment: .leading, spacing: 6) {
        Button("Detect Mac capabilities") { Task { await advisor.detectHardware() } }
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
          .disabled(advisor.isDetecting || !chat.canChangeModels)
        Button("Replay welcome setup", action: replayWelcome)
          .enigmaButtonStyle(.text)
          .enigmaTestMarker("Replay welcome setup")
          .padding(.leading, -8)
          .disabled(advisor.isDetecting || !chat.canChangeModels)
        if let hardware = advisor.hardware {
          VStack(alignment: .leading, spacing: 3) {
            Text("\(hardware.chip) · \(hardware.cpuCount) CPUs")
            Text("inference budget \(hardware.inferenceMemoryBudget, format: .byteCount(style: .memory))")
            Text("free disk \(hardware.availableDiskBytes, format: .byteCount(style: .file))")
            Text(hardware.hasMetal ? "metal available" : "cpu inference")
            if let limit = hardware.metalRecommendedWorkingSet {
              Text("metal working set \(limit, format: .byteCount(style: .memory))")
            }
          }
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 4)
    }
    // The padding lives here so release builds, which leave the tools out, add no space.
    .padding(.top, 8)
    .padding(.horizontal, 6)
  }
}
