import AppKit
import SwiftUI

/// First-run setup: the welcome, local models, connections, and the
/// walkthrough offer, driven by `WelcomeSetup`. The window that shows it owns
/// the character and its stage.
struct WelcomeSetupView: View {
  @ObservedObject var setup: WelcomeSetup
  /// Not observed: the welcome moves the character and sets its state, but
  /// never needs to redraw when the character changes.
  let character: EnigmaCharacterController
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var cloud: CloudSettingsModel
  @ObservedObject var search: WebSearchSettings
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.enigmaAppearance) private var appearance
  @AppStorage(SelectionShortcutMonitor.modifierKey) private var selectionModifier = SelectionModifier.option.rawValue
  @AppStorage(SelectionShortcutMonitor.enabledKey) private var selectionShortcutEnabled = true
  @State private var selectedID: String?
  @State private var skipLocal = false
  @State private var showConnections = false
  /// Matches the window's corners, so the welcome covers the whole window.
  static let windowRadius: CGFloat = EnigmaWindowChrome.cornerRadius
  private static let columnWidth: CGFloat = 560

  // MARK: State

  private var choices: [LocalModelAssessment] {
    WelcomeSetup.choices(advisor.recommendations(installedModels: chat.installedModels), preserving: selectedID)
  }

  private var selected: LocalModelAssessment? {
    if let selectedID { return choices.first { $0.id == selectedID } }
    return choices.first
  }

  private var modelAction: WelcomeSetup.ModelAction? {
    WelcomeSetup.modelAction(selected: selected, installed: chat.installedModels,
                             activeID: chat.installedModel?.id, skipLocal: skipLocal)
  }

  private var isModelWorkBusy: Bool { !chat.canChangeModels || advisor.isDetecting }

  private var characterState: EnigmaCharacterState {
    WelcomeSetup.characterState(for: setup.step, WelcomeSetup.Activity(
      isDetectingHardware: advisor.isDetecting,
      isInstalling: WelcomeSetup.isInstalling(chat.modelOperation),
      installFailed: WelcomeSetup.installFailed(chat.modelFailure),
      connectionFailed: cloud.accountError != nil || cloud.claudeCodeError != nil))
  }

  private var stepTransition: AnyTransition {
    reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
  }

  // MARK: Body

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.windowRadius, style: .continuous)
    GeometryReader { proxy in
      ZStack {
        if setup.step == .welcome {
          hero(height: proxy.size.height).transition(stepTransition)
        } else {
          stepPage.transition(stepTransition)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(palette.background.color)
    .clipShape(shape)
    .enigmaEdge(shape)
    .sheet(isPresented: $showConnections) {
      ConnectionSettingsSheet(cloud: cloud, advisor: advisor, chat: chat, search: search) {
        showConnections = false
      }
      // A sheet is its own window, so it takes the theme again.
      .enigmaTheme(appearance)
    }
    .task { await advisor.detectHardware() }
    .onAppear(perform: placeCharacter)
    .onChange(of: setup.step) { old, new in
      // F14 spike: it flies to each step, from wherever it was perched.
      character.attention = nil
      character.move(to: WelcomeSetup.characterSlot(for: new).id, .fly)
      if new == .connections { Task { await cloud.refreshChatGPTAccount() } }
    }
    .onChange(of: chat.modelOperation) { _, operation in if operation == .benchmarking { setup.performanceCheckRan() } }
    .onChange(of: characterState, initial: true) { _, state in character.state = state }
    // F14 spike: a happy wobble when a model lands or a plan connects.
    .onChange(of: chat.installedModel?.id) { old, new in if new != nil, old != new { character.poke() } }
    .onChange(of: cloud.isConfigured) { old, new in if new, !old { character.poke() } }
  }

  /// Puts the character in this step's slot. Arriving fresh on the welcome, it
  /// grows in; already there, it stays.
  private func placeCharacter() {
    let slot = WelcomeSetup.characterSlot(for: setup.step)
    let arrivesFresh = character.activeSlot != slot.id
    // The main page may have left it watching the composer.
    character.attention = nil
    character.move(to: slot.id, .instant)
    if arrivesFresh && slot == .hero { character.assemble() }
  }

  private func changeStep(_ change: () -> Void) {
    withAnimation(EnigmaMotion.pageChange.animation, change)
  }

  // MARK: Welcome

  private func hero(height: CGFloat) -> some View {
    let compact = height < 600
    let slot = WelcomeSetup.CharacterSlot.hero
    return ScrollView {
      VStack(spacing: 0) {
        Color.clear.enigmaCharacterSlot(id: slot.id, size: slot.size)
        Text("Hi, I’m Enigma.")
          .font(EnigmaTypography.ui(38, weight: .semibold))
          .tracking(-1.2)
          .foregroundStyle(palette.textPrimary.color)
          .accessibilityAddTraits(.isHeader)
          .padding(.top, compact ? 6 : 22)
        Text("A small assistant that lives on your Mac. Ask me anything, any way you like.")
          .font(EnigmaTypography.ui(15))
          .foregroundStyle(palette.textSecondary.color)
          .padding(.top, compact ? 4 : 8)
        WelcomeTypewriter(character: character)
          .frame(width: 520)
          .padding(.top, compact ? 14 : 30)
        primaryButton("Get started", isEnabled: true) { changeStep { setup.advance() } }
          .padding(.top, compact ? 14 : 30)
        EnigmaHint("⌥⌃ opens me in any app · setup takes about a minute")
          .padding(.top, compact ? 6 : 12)
      }
      // The antenna reaches about 25 points above the slot.
      .padding(.top, 30)
      .padding(.bottom, compact ? 8 : 30)
      .frame(maxWidth: .infinity, minHeight: height)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  // MARK: Later steps

  private var stepPage: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        ZStack(alignment: .top) {
          stepContent
            .id(setup.step)
            .transition(stepTransition)
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      footer
    }
  }

  @ViewBuilder private var stepContent: some View {
    switch setup.step {
    case .welcome: EmptyView()
    case .models: models
    case .connections: connections
    case .walkthrough: walkthrough
    }
  }

  private var header: some View {
    let slot = WelcomeSetup.CharacterSlot.header
    let copy = headerCopy
    return HStack(alignment: .center, spacing: 14) {
      Color.clear.enigmaCharacterSlot(id: slot.id, size: slot.size)
      ZStack(alignment: .leading) {
        VStack(alignment: .leading, spacing: 3) {
          Text(copy.title)
            .font(EnigmaTypography.ui(22, weight: .semibold))
            .tracking(-0.33)
            .foregroundStyle(palette.textPrimary.color)
            .accessibilityAddTraits(.isHeader)
          Text(copy.subtitle)
            .font(EnigmaTypography.ui(13.5))
            .foregroundStyle(palette.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        .id(setup.step)
        .transition(.opacity)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(WelcomeSetup.counter(for: setup.step))
        .font(EnigmaTypography.mono(11.5))
        .foregroundStyle(palette.textTertiary.color)
        .accessibilityLabel("Step \(setup.step.rawValue + 1) of \(WelcomeSetup.Step.allCases.count)")
    }
    .frame(maxWidth: Self.columnWidth)
    .padding(.horizontal, 24)
    .padding(.top, 28)
    .padding(.bottom, 12)
  }

  private var headerCopy: (title: String, subtitle: String) {
    switch setup.step {
    case .welcome: ("Enigma", "A small assistant that lives on your Mac.")
    case .models: ("Pick a brain for me", "It runs right here on your Mac. Bigger thinks deeper; smaller answers faster.")
    case .connections: ("Want backup from the cloud?", "Use your ChatGPT or Claude plan for the hard stuff. Totally optional.")
    case .walkthrough: ("Let me show you around", "A quick, hands-on tour. You try each thing yourself.")
    }
  }

  private var footer: some View {
    VStack(spacing: 0) {
      EnigmaHairline()
      ViewThatFits(in: .horizontal) {
        footerRow(showsHint: true)
        footerRow(showsHint: false)
      }
      .padding(.vertical, 14)
    }
    .frame(maxWidth: Self.columnWidth)
    .padding(.horizontal, 24)
    .padding(.bottom, 4)
  }

  private func footerRow(showsHint: Bool) -> some View {
    HStack(spacing: 12) {
      Button("Back") { changeStep { setup.goBack() } }
        .enigmaButtonStyle(.text)
        .disabled(!chat.canChangeModels)
        .padding(.leading, -8)
      Spacer(minLength: 12)
      if showsHint, let hint = footerHint {
        EnigmaHint(hint).lineLimit(1)
      }
      switch setup.step {
      case .welcome:
        EmptyView()
      case .models:
        primaryButton(modelActionTitle, isEnabled: modelAction != nil && !isModelWorkBusy,
                      isDefault: WelcomeSetup.returnPressesModelAction(modelAction), action: performModelAction)
      case .connections:
        primaryButton("Continue", isEnabled: true) { changeStep { setup.advance() } }
      case .walkthrough:
        Button("Skip the tour") { setup.finish(takeTour: false) }
          .enigmaButtonStyle(.text)
        primaryButton("Show me around", isEnabled: true) { setup.finish(takeTour: true) }
      }
    }
  }

  private var footerHint: String? {
    switch setup.step {
    case .welcome: return nil
    case .models:
      guard chat.canChangeModels else { return nil }
      let size = selected.map { ByteCountFormatter.string(fromByteCount: $0.model.downloadByteCount, countStyle: .file) } ?? ""
      switch modelAction {
      case .install: return "\(size) download, verified before install"
      case .update: return "\(size) update, verified before install"
      case .use: return "already on this Mac"
      case .proceed: return "next: cloud plans, optional"
      case nil: return "choose a model, or skip local models"
      }
    case .connections: return "next: a hands-on tour"
    case .walkthrough: return "\(GuidedTour.Stop.allCases.count) stops, leave anytime"
    }
  }

  /// The step's one `accent` button. Return presses it, unless `isDefault` is
  /// false or the key field has focus, where Return saves the key instead.
  private func primaryButton(_ title: String, isEnabled: Bool, isDefault: Bool = true,
                             action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text(title)
        if isDefault { EnigmaKeycap("↵") }
      }
    }
    .enigmaButtonStyle(.primary)
    .keyboardShortcut(isDefault ? .defaultAction : nil)
    .disabled(!isEnabled)
    .enigmaTestMarker(title)
  }

  // MARK: Models

  private var modelActionTitle: String {
    switch modelAction {
    case .install: "Install model"
    case .update: "Update model"
    case .use: "Use this model"
    case .proceed, nil: "Continue"
    }
  }

  private func performModelAction() {
    guard let action = modelAction else { return }
    switch action {
    case .install, .update:
      guard let selected else { return }
      selectedID = selected.id
      chat.downloadModel(selected.model, checkPerformance: setup.needsPerformanceCheck)
    case .use:
      guard let selected else { return }
      selectedID = selected.id
      chat.selectModel(id: selected.id)
    case .proceed:
      changeStep { setup.advance() }
    }
  }

  private var models: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let mac = advisor.hardware {
        HStack(alignment: .top, spacing: 26) {
          stat(mac.physicalMemory.formatted(.byteCount(style: .memory)), "memory")
          stat(mac.availableDiskBytes.formatted(.byteCount(style: .file)), "free storage")
          stat(mac.chip, mac.device)
        }
        .padding(.top, 8)
      } else {
        EnigmaStatusLine(.busy, "detecting your Mac…").padding(.top, 8)
      }
      if !choices.isEmpty { EnigmaSectionHeader("Good fits for this Mac") } else { Spacer().frame(height: 20) }
      let roles = advisor.recommendations(installedModels: chat.installedModels).roles
      ForEach(choices) { assessment in
        LocalModelChoiceRow(assessment: assessment,
          role: roles.first { $0.id == assessment.id }?.tag,
          isSelected: !skipLocal && selected?.id == assessment.id) {
            selectedID = assessment.id
            skipLocal = false
          }
          .disabled(isModelWorkBusy)
          .welcomePerch("model.\(assessment.id)", character: character)
      }
      EnigmaRow("Skip local models", subtitle: "Use cloud models only. You can add a local model later in Settings.",
                selection: skipLocal, action: { skipLocal = true })
        .disabled(!chat.canChangeModels)
        .welcomePerch("model.skip", character: character)
      EnigmaHairline()
      if advisor.hardware != nil && choices.isEmpty {
        note("No supported model fits the available memory and storage. You can continue with Cloud.")
          .padding(.top, 10)
      }
      LocalModelOperationView(chat: chat, advisor: advisor)
        .padding(.top, 14)
      VStack(alignment: .leading, spacing: 4) {
        note("Downloads include image support and are verified before installation. Speed estimates vary with other apps and power settings.")
        note("Add or change models later in Settings. Cloud and web search send relevant requests online.")
      }
      .padding(.top, 10)
    }
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(EnigmaTypography.ui(17, weight: .semibold))
        .foregroundStyle(palette.textPrimary.color)
      Text(label)
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textTertiary.color)
    }
    .accessibilityElement(children: .combine)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Connections

  private var connections: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Cloud plans")
      ClaudeCodeConnectionControls(settings: cloud, showsAPIKeyNote: false)
        .welcomePerch("cloud.claude", character: character)
      ChatGPTConnectionControls(settings: cloud)
        .welcomePerch("cloud.chatgpt", character: character)
      note("Auto keeps things on this Mac and asks the cloud only when it helps. Search needs no setup at all.")
        .padding(.top, 14)
    }
  }

  // MARK: Walkthrough

  private var walkthrough: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("I’ll show you around the real app. You send a question, try a command, and turn on what you want to use. Every reply in the tour is an example.")
        .font(EnigmaTypography.ui(13.5))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(GuidedTour.Stop.allCases, id: \.self) { stop in
          EnigmaCommandLine(command: "\(stop.rawValue + 1)", description: stop.title, commandWidth: 30)
        }
      }
      .padding(.top, 14)
      if chat.installedModel == nil && !cloud.isConfigured {
        EnigmaStatusLine(.problem, "No model is ready yet. Connect Cloud or install a model in Settings before sending your first message.")
          .padding(.top, 14)
      }
      VStack(alignment: .leading, spacing: 4) {
        note("The tour helps you turn on Accessibility, Screen Recording and Full Disk Access, only for what you want.")
        note("Replay this setup anytime from Settings → General.")
      }
      .padding(.top, 14)
    }
  }
}

private extension WelcomeTourStep {
  /// The stop as the walkthrough lists it, like a command.
  var stopName: String {
    switch self {
    case .history: "history"
    case .composer: "message box"
    case .commands: "/"
    case .files: "files"
    case .model: "model"
    case .help: "help"
    case .newChat: "new chat"
    }
  }

  var stopSummary: String {
    switch self {
    case .history: "your recent chats"
    case .composer: "type, then ↵ to send"
    case .commands: "slash commands"
    case .files: "work with a file or folder"
    case .model: "local, cloud, or auto"
    case .help: "shortcuts and settings"
    case .newChat: "a new conversation"
    }
  }
}

// MARK: Tour

/// Where the tour puts its highlight and card in the window: the card sits
/// below a target in the top half and above one in the bottom half, and always
/// stays inside the window.
struct WelcomeTourPlacement: Equatable {
  static let margin: CGFloat = 16
  static let maximumCardWidth: CGFloat = 320

  let highlight: CGRect
  let cardWidth: CGFloat
  let cardOrigin: CGPoint

  /// With no visible target, the highlight is an empty point near the top center.
  init(target: CGRect?, container: CGSize, cardHeight: CGFloat) {
    let margin = Self.margin
    let bounds = CGRect(origin: .zero, size: container)
    let visible = target.map { $0.insetBy(dx: -5, dy: -5).intersection(bounds) }
    let highlight = visible.flatMap { $0.isNull ? nil : $0 }
      ?? CGRect(x: container.width / 2, y: 24, width: 0, height: 0)
    let width = max(0, min(Self.maximumCardWidth, container.width - 2 * margin))
    let x = min(max(margin, highlight.midX - width / 2), container.width - width - margin)
    let y = highlight.midY > container.height / 2
      ? max(margin, highlight.minY - cardHeight - margin)
      : max(margin, min(highlight.maxY + margin, container.height - cardHeight - margin))
    self.highlight = highlight
    cardWidth = width
    cardOrigin = CGPoint(x: x, y: y)
  }
}

/// The six-stop tour over the main window. Its anchors are on the main
/// window's controls.
struct WelcomeTourOverlay: View {
  @ObservedObject var setup: WelcomeSetup
  let anchors: [WelcomeTourStep: Anchor<CGRect>]
  let availableCommands: [SlashCommand]
  @Environment(\.enigmaPalette) private var palette
  @State private var cardHeight: CGFloat = 220

  var body: some View {
    GeometryReader { geometry in
      if let step = setup.tour {
        let placement = WelcomeTourPlacement(target: anchors[step.target].map { geometry[$0] },
                                             container: geometry.size, cardHeight: cardHeight)
        let highlight = placement.highlight
        ZStack(alignment: .topLeading) {
          Path { path in
            path.addRect(CGRect(origin: .zero, size: geometry.size))
            path.addRoundedRect(in: highlight, cornerSize: CGSize(width: 12, height: 12))
          }
          .fill(palette.background.color.opacity(0.6), style: FillStyle(eoFill: true))
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(palette.accent.color, lineWidth: 2)
            .frame(width: highlight.width, height: highlight.height)
            .position(x: highlight.midX, y: highlight.midY)
          WelcomeTourCard(setup: setup, step: step, availableCommands: availableCommands)
            .frame(width: placement.cardWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            .offset(x: placement.cardOrigin.x, y: placement.cardOrigin.y)
        }
        .contentShape(Rectangle())
        .onExitCommand { setup.endTour() }
      }
    }
  }
}

/// One stop's card: an opaque `surface` card with the stop count, End tour, and Next.
struct WelcomeTourCard: View {
  @ObservedObject var setup: WelcomeSetup
  let step: WelcomeTourStep
  let availableCommands: [SlashCommand]
  @Environment(\.enigmaPalette) private var palette
  @AccessibilityFocusState private var isHeadingFocused: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      Text("\(step.rawValue + 1)/\(WelcomeTourStep.allCases.count)")
        .font(EnigmaTypography.mono(11.5))
        .foregroundStyle(palette.textTertiary.color)
        .accessibilityLabel("Stop \(step.rawValue + 1) of \(WelcomeTourStep.allCases.count)")
      Text(step.title)
        .font(EnigmaTypography.ui(15, weight: .semibold))
        .tracking(-0.2)
        .foregroundStyle(palette.textPrimary.color)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isHeadingFocused)
      Text(step.detail)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
      if step == .commands {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(availableCommands) { command in
            EnigmaCommandLine(command: command.token, description: command.description, commandWidth: 84)
          }
        }
      }
      HStack(spacing: 12) {
        Button("End tour") { setup.endTour() }
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
        Spacer(minLength: 0)
        Button { setup.nextTourStep() } label: {
          HStack(spacing: 10) {
            Text(step == .help ? "Finish setup" : "Next")
            EnigmaKeycap("↵")
          }
        }
        .enigmaButtonStyle(.primary)
        .keyboardShortcut(.defaultAction)
        .enigmaTestMarker("Next tour stop")
      }
      .padding(.top, 4)
    }
    .padding(16)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
    .task(id: step) { isHeadingFocused = true }
  }
}

/// "More connection settings": Settings on Cloud and search, under a
/// bar of its own with Back to setup, so the button never covers a row.
struct ConnectionSettingsSheet: View {
  static let size = CGSize(width: 820, height: 660)
  static let barHeight: CGFloat = 48

  let cloud: CloudSettingsModel
  let advisor: LocalModelAdvisor
  let chat: LocalChatViewModel
  let search: WebSearchSettings
  let back: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Connection settings")
          .font(EnigmaTypography.ui(13, weight: .medium))
          .foregroundStyle(palette.textSecondary.color)
        Spacer()
        Button("Back to setup", action: back).enigmaButtonStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .frame(height: Self.barHeight)
      EnigmaHairline()
      SettingsView(settings: cloud, initialDestination: .cloud, advisor: advisor, chat: chat, search: search,
                         size: CGSize(width: Self.size.width, height: Self.size.height - Self.barHeight))
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
  }
}

// MARK: F14 spike: the character follows clicks, and the welcome types examples

extension View {
  /// A spot just right of this row where the character lands when the row is clicked.
  func welcomePerch(_ id: String, character: EnigmaCharacterController) -> some View {
    let slot = EnigmaCharacterSlotID("welcome.perch." + id)
    return overlay(alignment: .trailing) {
      Color.clear
        .enigmaCharacterSlot(id: slot, size: 38)
        .offset(x: 62)
        .allowsHitTesting(false)
    }
    .simultaneousGesture(TapGesture().onEnded { character.move(to: slot, .fly) })
  }
}

/// A little composer that types what people ask Enigma, plain words and
/// commands alike, while the character leans in at each keystroke.
struct WelcomeTypewriter: View {
  let character: EnigmaCharacterController
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = ""
  @State private var cursorOn = true
  static let target: EnigmaCharacterTargetID = "welcome.typewriter"
  static let examples = [
    "cafes near me",
    "/translate this into Spanish",
    "what did Sam say about Saturday?",
    "/snapshot what does this error mean?",
    "will it rain tomorrow?",
    "/edit make this sound friendlier",
    "fix the typos in notes.md",
    "/think plan my week around three deadlines",
  ]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 0) {
        typed
        Rectangle()
          .fill(palette.accent.color)
          .frame(width: 2, height: 19)
          .opacity(cursorOn ? 1 : 0)
          .padding(.leading, 1)
        Spacer(minLength: 0)
      }
      .frame(height: 22)
      HStack(spacing: 16) {
        Text("+").font(EnigmaTypography.ui(17))
        Text("/").font(EnigmaTypography.mono(15))
        Text("● local").font(EnigmaTypography.mono(12))
        Spacer()
        Circle().fill(palette.accent.color).frame(width: 26, height: 26)
          .overlay(Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.onAccent.color))
      }
      .foregroundStyle(palette.textSecondary.color)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
    .enigmaCharacterTarget(Self.target)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Examples of what you can ask")
    .task { await run() }
  }

  /// The command in `accentText`, the rest in body text, as the composer shows them.
  private var typed: some View {
    let parts = shown.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let isCommand = shown.hasPrefix("/")
    var text = AttributedString(shown)
    text.font = EnigmaTypography.ui(16)
    text.foregroundColor = palette.textPrimary.color
    if isCommand, let first = parts.first, let range = text.range(of: first) {
      text[range].foregroundColor = palette.accentText.color
      text[range].font = EnigmaTypography.mono(15)
    }
    return Text(text)
  }

  private func run() async {
    if reduceMotion { shown = Self.examples[0]; return }
    var index = 0
    while !Task.isCancelled {
      let example = Self.examples[index % Self.examples.count]
      for character in example {
        shown.append(character)
        self.character.key(towards: Self.target)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95)))
      }
      for _ in 0..<4 { cursorOn.toggle(); try? await Task.sleep(for: .milliseconds(350)) }
      cursorOn = true
      self.character.token()
      try? await Task.sleep(for: .milliseconds(500))
      while !shown.isEmpty {
        shown.removeLast()
        try? await Task.sleep(for: .milliseconds(18))
      }
      try? await Task.sleep(for: .milliseconds(300))
      index += 1
    }
  }
}
