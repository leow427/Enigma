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
    .task { await advisor.detectHardware() }
    .onAppear(perform: placeCharacter)
    .onChange(of: setup.step) { old, new in
      // It flies to each step, from wherever it was perched.
      character.attention = nil
      character.move(to: WelcomeSetup.characterSlot(for: new).id, .fly)
      if new == .connections { Task { await cloud.refreshChatGPTAccount() } }
    }
    .onChange(of: chat.modelOperation) { _, operation in if operation == .benchmarking { setup.performanceCheckRan() } }
    .onChange(of: characterState, initial: true) { _, state in character.state = state }
    // A happy wobble when a model lands or a plan connects.
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
