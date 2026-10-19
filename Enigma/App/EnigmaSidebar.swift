import SwiftUI

/// The main window's sidebar: the app mark, New chat, the
/// recent chats as plain rows, and Help, Settings, and Developer Tools at the
/// bottom, on the `sidebar` color. `AppShellView` owns every action.
struct EnigmaSidebar<DeveloperTools: View>: View {
  let rows: [ChatHistoryRow]
  /// The tour stop on screen, so the sidebar can scroll its target into view.
  let tourStep: WelcomeTourStep?
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
    .welcomeTourTarget(.history)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaNavigationRow("Help", action: openHelp) {
        Image(systemName: "questionmark.circle").font(EnigmaTypography.navigationSymbol)
          .foregroundStyle(palette.textSecondary.color)
      }
      .welcomeTourTarget(.help)
      .id(Self.helpAnchor)
      EnigmaNavigationRow("Settings", hint: "⌘,", action: openSettings) {
        Image(systemName: "gearshape").font(EnigmaTypography.navigationSymbol)
          .foregroundStyle(palette.textSecondary.color)
      }
      developerTools()
        .padding(.top, 8)
        .padding(.horizontal, 6)
    }
  }
}

/// With the sidebar hidden, a slim bar at the top of the main page keeps its
/// actions in reach: show the sidebar, Help, Settings, and New chat.
struct EnigmaHiddenSidebarBar: View {
  let show: () -> Void
  let openHelp: () -> Void
  let openSettings: () -> Void
  let newChat: () -> Void

  static let height: CGFloat = 44

  var body: some View {
    HStack(spacing: 4) {
      Button(action: show) { Image(systemName: "sidebar.left") }
        .enigmaIconButtonStyle()
        .welcomeTourTarget(.history)
        .accessibilityLabel("Show chat history")
        .help("Show chat history · ⌃⌘S")
        .enigmaTestMarker("Show chat history")
      Spacer(minLength: 0)
      Button(action: newChat) { Image(systemName: "plus") }
        .enigmaIconButtonStyle()
        .accessibilityLabel("New chat")
        .help("New chat · ⌘N")
        .enigmaTestMarker("Bar new chat")
      Button(action: openHelp) { Image(systemName: "questionmark.circle") }
        .enigmaIconButtonStyle()
        .welcomeTourTarget(.help)
        .accessibilityLabel("Help")
        .help("Help")
        .enigmaTestMarker("Bar help")
      Button(action: openSettings) { Image(systemName: "gearshape") }
        .enigmaIconButtonStyle()
        .accessibilityLabel("Settings")
        .help("Settings · ⌘,")
        .enigmaTestMarker("Bar settings")
    }
    .padding(.horizontal, 12)
    .frame(height: Self.height)
  }
}

/// Developer Tools, behind a disclosure: hardware detection and welcome replay.
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
          .disabled(advisor.isDetecting || chat.isBusy)
        Button("Replay welcome setup", action: replayWelcome)
          .enigmaButtonStyle(.text)
          .enigmaTestMarker("Replay welcome setup")
          .padding(.leading, -8)
          .disabled(advisor.isDetecting || chat.isBusy)
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
  }
}
