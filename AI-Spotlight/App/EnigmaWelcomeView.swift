import AppKit
import SwiftUI

/// First-run setup in the new design: the welcome, local models, connections,
/// and the walkthrough offer. It drives the same `WelcomeSetup` as
/// `WelcomeSetupView`. The window that shows it owns the character and its stage.
struct EnigmaWelcomeView: View {
  @ObservedObject var setup: WelcomeSetup
  /// Not observed: the welcome moves the character and sets its state, but
  /// never needs to redraw when the character changes.
  let character: EnigmaCharacterController
  @ObservedObject var advisor: LocalModelAdvisor
  @ObservedObject var chat: LocalChatViewModel
  @ObservedObject var cloud: CloudSettingsModel
  @ObservedObject var search: WebSearchSettings
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(SelectionShortcutMonitor.modifierKey) private var selectionModifier = SelectionModifier.option.rawValue
  @AppStorage(SelectionShortcutMonitor.enabledKey) private var selectionShortcutEnabled = true
  @State private var selectedID: String?
  @State private var skipLocal = false
  @State private var showConnections = false
  @State private var braveAPIKey = ""
  @State private var connectionError: String?
  @State private var isEnteringKey = false

  /// The Brave key field, which the character watches while someone types.
  static let keyFieldTarget: EnigmaCharacterTargetID = "welcome.keyField"
  /// Matches the old panel's corners, so the welcome covers the whole window.
  static let windowRadius: CGFloat = 24
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

  private var isModelWorkBusy: Bool { chat.isBusy || advisor.isDetecting }

  private var characterState: EnigmaCharacterState {
    WelcomeSetup.characterState(for: setup.step, WelcomeSetup.Activity(
      isDetectingHardware: advisor.isDetecting,
      isInstalling: WelcomeSetup.isInstalling(chat.state),
      installFailed: WelcomeSetup.installFailed(chat.state),
      connectionFailed: cloud.accountError != nil || cloud.claudeCodeError != nil || connectionError != nil,
      isEnteringKey: isEnteringKey))
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
    .overlay {
      shape.strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color,
                         lineWidth: 1 / displayScale)
        .allowsHitTesting(false)
    }
    .sheet(isPresented: $showConnections) {
      // Phase 5: open the new Settings here instead.
      SettingsView(settings: cloud, initialDestination: .cloud)
        .overlay(alignment: .topTrailing) {
          Button("Back to Setup") { showConnections = false }.padding(20)
        }
        .frame(width: 820, height: 660)
        // The old Settings is drawn for the dark scheme the old UI forces.
        .environment(\.colorScheme, .dark)
    }
    .task { await advisor.detectHardware() }
    .onAppear(perform: placeCharacter)
    .onChange(of: setup.step) { old, new in
      isEnteringKey = false
      if let transition = WelcomeSetup.characterTransition(from: old, to: new) {
        character.move(to: WelcomeSetup.characterSlot(for: new).id, transition)
      }
      if new == .connections { Task { await cloud.refreshChatGPTAccount() } }
    }
    .onChange(of: characterState, initial: true) { _, state in character.state = state }
    .onChange(of: isEnteringKey) { _, entering in character.attention = entering ? Self.keyFieldTarget : nil }
    .onChange(of: braveAPIKey) { _, _ in if isEnteringKey { character.key() } }
    .onDisappear {
      character.attention = nil
      character.state = .idle
    }
  }

  /// Puts the character in this step's slot. Arriving fresh on the welcome, it
  /// grows in; already there, as when the flag flips mid-setup, it stays.
  private func placeCharacter() {
    let slot = WelcomeSetup.characterSlot(for: setup.step)
    let arrivesFresh = character.activeSlot != slot.id
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
        Text("Enigma")
          .font(EnigmaTypography.ui(34, weight: .semibold))
          .tracking(-1)
          .foregroundStyle(palette.textPrimary.color)
          .accessibilityAddTraits(.isHeader)
          .padding(.top, compact ? 6 : 22)
        Text("A small assistant that lives on your Mac.")
          .font(EnigmaTypography.ui(14.5))
          .foregroundStyle(palette.textSecondary.color)
          .padding(.top, compact ? 4 : 8)
        VStack(alignment: .leading, spacing: 0) {
          EnigmaCommandLine(command: "⌥⌃ in any app", description: "opens over what you’re doing")
          if let shortcut = WelcomeSetup.selectionShortcut(modifier: selectionModifier,
                                                           isEnabled: selectionShortcutEnabled) {
            EnigmaCommandLine(command: "select, then \(shortcut)", description: "ask about the selection")
          }
          EnigmaCommandLine(command: "/screen /search /edit", description: "do things, not just chat")
        }
        .frame(width: 440)
        .padding(.top, compact ? 10 : 24)
        primaryButton("Get started", isEnabled: true) { changeStep { setup.advance() } }
          .padding(.top, compact ? 10 : 24)
        EnigmaHint("next: pick a local model, about a minute")
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
    case .models: ("Pick a local model", "It answers on this Mac. Choose a balance of speed, capability, and space.")
    case .connections: ("Connect what you use", "All optional. Connect here, or skip and come back whenever you’re ready.")
    case .walkthrough: ("Make yourself at home", "Would you like a quick walkthrough?")
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
        .disabled(chat.isBusy)
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
        Button("Finish without the tour") { setup.finish(takeTour: false) }
          .enigmaButtonStyle(.text)
        primaryButton("Show me around", isEnabled: true) { setup.finish(takeTour: true) }
      }
    }
  }

  private var footerHint: String? {
    switch setup.step {
    case .welcome: return nil
    case .models:
      guard !chat.isBusy else { return nil }
      let size = selected.map { ByteCountFormatter.string(fromByteCount: $0.model.downloadByteCount, countStyle: .file) } ?? ""
      switch modelAction {
      case .install: return "\(size) download, verified before install"
      case .update: return "\(size) update, verified before install"
      case .use: return "already on this Mac"
      case .proceed: return "next: cloud and search, optional"
      case nil: return "choose a model, or skip local models"
      }
    case .connections: return "next: a quick look around"
    case .walkthrough: return "six stops, leave anytime"
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
    .keyboardShortcut(isDefault && !isEnteringKey ? .defaultAction : nil)
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
      chat.downloadModel(selected.model)
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
      ForEach(Array(choices.enumerated()), id: \.element.id) { index, assessment in
        EnigmaLocalModelChoiceRow(assessment: assessment,
          role: index == 0 ? (assessment.isResponsive ? "recommended" : "best available, expect longer waits") : nil,
          isSelected: !skipLocal && selected?.id == assessment.id) {
            selectedID = assessment.id
            skipLocal = false
          }
          .disabled(isModelWorkBusy)
      }
      EnigmaRow("Skip local models", subtitle: "Use cloud models only. You can add a local model later in Settings.",
                selection: skipLocal, action: { skipLocal = true })
        .disabled(chat.isBusy)
      EnigmaHairline()
      if advisor.hardware != nil && choices.count < 3 {
        note(choices.isEmpty ? "No supported model fits the available memory and storage. You can continue with Cloud."
          : "Only \(choices.count) compatible choices fit this Mac right now.")
          .padding(.top, 10)
      }
      EnigmaLocalModelOperationView(chat: chat, advisor: advisor)
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
      EnigmaSectionHeader("Cloud models")
      EnigmaClaudeCodeConnectionControls(settings: cloud)
      EnigmaChatGPTConnectionControls(settings: cloud)
      EnigmaSectionHeader("Search")
      EnigmaRow("Brave Search", subtitle: "Used by /search, with sources cited.") {
        EnigmaStatusLine(search.hasAPIKey ? .on : .off, search.hasAPIKey ? "key saved · not tested here" : "not connected")
      }
      EnigmaConnectionDetails {
        EnigmaConnectionNote("Get a Brave Search API key with LLM Context access, then paste it here. Brave usage is billed separately.")
        HStack(spacing: 10) {
          EnigmaTextField("Brave Search API key", text: $braveAPIKey, isSecure: true,
                          onFocusChange: { isEnteringKey = $0 }, onSubmit: saveBraveKey)
            .enigmaCharacterTarget(Self.keyFieldTarget)
          Button("Save key", action: saveBraveKey)
            .enigmaButtonStyle(.secondary)
            .enigmaTestMarker("Save key")
            .disabled(braveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Link("Get a Brave API key", destination: URL(string: "https://brave.com/search/api/")!)
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
        if let connectionError { EnigmaStatusLine(.problem, connectionError) }
      }
      EnigmaSectionHeader("Mac permissions")
      EnigmaMacPermissionRows()
      Button("More connection settings") { showConnections = true }
        .enigmaButtonStyle(.text)
        .padding(.leading, -8)
        .padding(.top, 14)
    }
  }

  private func saveBraveKey() {
    guard !braveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do {
      try search.saveAPIKey(braveAPIKey)
      braveAPIKey = ""
      connectionError = nil
    } catch {
      connectionError = error.localizedDescription
    }
  }

  // MARK: Walkthrough

  private var walkthrough: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Six quick stops show you chat history, the message box, slash commands, files, model choices, and Help. Follow the highlighted controls with Next, or leave the tour anytime.")
        .font(EnigmaTypography.ui(13.5))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(WelcomeTourStep.allCases, id: \.self) { stop in
          EnigmaCommandLine(command: stop.stopName, description: stop.stopSummary, commandWidth: 110)
        }
      }
      .padding(.top, 14)
      if chat.installedModel == nil && !cloud.isConfigured {
        EnigmaStatusLine(.problem, "No model is ready yet. Connect Cloud or install a model in Settings before sending your first message.")
          .padding(.top, 14)
      }
      VStack(alignment: .leading, spacing: 4) {
        note("Screen, selection, and location permissions are requested when you use those features. You’re in control.")
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

/// The six-stop tour over the main window, in the new design. Its anchors
/// still point at the old main window's controls. Phase 6 adds the new ones.
struct EnigmaWelcomeTourOverlay: View {
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
          EnigmaWelcomeTourCard(setup: setup, step: step, availableCommands: availableCommands)
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
struct EnigmaWelcomeTourCard: View {
  @ObservedObject var setup: WelcomeSetup
  let step: WelcomeTourStep
  let availableCommands: [SlashCommand]
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale
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
      }
      .padding(.top, 4)
    }
    .padding(16)
    .background(palette.surface.color, in: shape)
    .overlay {
      shape.strokeBorder(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color,
                         lineWidth: 1 / displayScale)
    }
    .task(id: step) { isHeadingFocused = true }
  }
}
