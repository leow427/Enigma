import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
  @ObservedObject private var welcomeSetup: WelcomeSetup
  /// System, Paper, or Ink.
  @ObservedObject private var appearance: EnigmaAppearancePreference
  /// The window's character: on the welcome, then on the main page. Owned
  /// here but not observed: the stage redraws it, and nothing here reads it.
  @State private var character: EnigmaCharacterController
  @ObservedObject private var selectionAccess: SelectionAccessibilityAccess
  @ObservedObject private var selectionContext = SelectionContextService.shared
  @ObservedObject private var cloudSettings: CloudSettingsModel
  @StateObject private var localChat: LocalChatViewModel
  @ObservedObject private var modelAdvisor: LocalModelAdvisor
  @ObservedObject private var files: FileModeCoordinator
  @ObservedObject private var messages: MessagesCoordinator
  /// Whether a selection chat stays private when opened in the window.
  @ObservedObject private var selectionEditing: SelectionEditingSettings
  @State private var isFileCloudConsentPresented = false
  @StateObject private var screen: ScreenComposerCoordinator
  @ObservedObject private var screenSettings: ScreenSettings
  @ObservedObject private var connectivity = ScreenConnectivity.shared
  @State private var screenUploadConsent: ScreenUploadConsent?
  private var draft: String {
    get { screen.draft }
    nonmutating set { screen.draft = newValue }
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var searchSettings: WebSearchSettings
  @State private var isModelImporterPresented = false
  @ObservedObject private var startPreferences: StartPreferences
  @State private var shell: ShellPresentation
  /// Text the composer's `/` button or a command example types into the field.
  @State private var composerInsertion: SlashCommandInsertion?
  /// The compact panel sits too low on its screen for lists and menus to open
  /// under it, so they open above its input.
  @State private var compactOpensOverlaysAbove = false
  @AppStorage(ComposerIntent.inferCommandsKey) private var infersCommands = true
  /// Recognized commands turned off for the current draft. Cleared when the draft empties.
  @State private var dismissedInferences: Set<SlashCommand> = []

  init(
    localEngine: (any LocalModelEngine)? = nil,
    cloudSettings: CloudSettingsModel = .shared,
    cloudProviders: CloudProviderRegistry = .live,
    localChat: LocalChatViewModel? = nil,
    screen: ScreenComposerCoordinator = ScreenComposerCoordinator(),
    screenSettings: ScreenSettings = .shared,
    modelAdvisor: LocalModelAdvisor = .shared,
    searchSettings: WebSearchSettings = .shared,
    startPreferences: StartPreferences = .shared,
    welcomeSetup: WelcomeSetup = .shared,
    appearance: EnigmaAppearancePreference = .shared,
    character: EnigmaCharacterController? = nil,
    selectionAccess: SelectionAccessibilityAccess = .shared
  ) {
    self.selectionAccess = selectionAccess
    self.cloudSettings = cloudSettings
    self.modelAdvisor = modelAdvisor
    self.searchSettings = searchSettings
    self.screenSettings = screenSettings
    self.welcomeSetup = welcomeSetup
    self.appearance = appearance
    self.startPreferences = startPreferences
    _shell = State(initialValue: ShellPresentation(mode: startPreferences.mode, showsSidebar: startPreferences.showsSidebar))
    _character = State(initialValue: character ?? EnigmaCharacterController())
    _screen = StateObject(wrappedValue: screen)
    let chat = localChat ?? localEngine.map { LocalChatViewModel(engine: $0, cloudProviders: cloudProviders) } ?? .shared
    _localChat = StateObject(wrappedValue: chat)
    self.files = chat.files
    self.messages = chat.appleMessages
    self.selectionEditing = chat.selectionEditingSettings
  }

  /// Notices and cards over the composer, as opaque cards. The compact panel
  /// leaves out what it shows itself: the selected text in its own line once
  /// it has grown, and, in its details, the screenshot that sits under its
  /// input, so the screenshot's consent sheet has one home.
  private func composerAccessories(showsSelectedText: Bool = true, showsScreenshot: Bool = true) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      // The empty page shows the status under its greeting instead.
      if !isChatEmpty {
        EnigmaRouteStatusLine(status: routeStatusSummary, isActionEnabled: !localChat.isBusy,
                              performAction: performRouteAction)
      }
      if let notice = localChat.contextNotice {
        EnigmaChatNote(notice)
      }
      if let decision = localChat.screenRouteDecision {
        EnigmaChatNote(decision.status + (decision.sendsImage ? "" : " · Image not sent"), monospaced: true)
      }
      // A private selection chat in the window says it's temporary for as long
      // as it's open, where the panel's chat says it: in the panel, its hint row.
      if localChat.isTemporaryChat && !shell.showsCompactPanel {
        EnigmaChatNote(CompactPanelHints.temporaryTag, monospaced: true)
          .enigmaTestMarker("Window tag \(CompactPanelHints.temporaryTag)")
      }
      // The selection's chat, in the panel or kept in the window, needs
      // Accessibility to replace the selection.
      if !selectionAccess.isGranted && localChat.isSelectionChat {
        AccessibilityNeededCard(appName: SelectionAccessibilityAccess.appName) { selectionAccess.requestAccess() }
      }
      if showsSelectedText {
        ForEach(localChat.attachedContexts) { context in
          SelectionContextCard(context: context, isSent: localChat.sentContextIDs.contains(context.id),
                               isBusy: localChat.isBusy || selectionContext.isWorking) {
            localChat.removeContext(id: context.id)
          }
        }
      }
      if let notice = selectionContext.notice, localChat.isSelectionChat {
        EnigmaChatNote(notice)
      }
      if showsScreenshot, let attachment = screen.attachment, localChat.pendingUserMessage == nil {
        screenshotAttachment(attachment)
      }
      if screen.attachment?.routingDecision == .needsCloudPermission || screen.attachment?.routingDecision == .blocked(ScreenRoutingPolicy.screenshotUploadDisabledMessage) {
        ScreenUploadsOffCard(review: { reviewScreenPermission() }, openSettings: openConnectionSettings)
      }
      if let error = screen.error {
        ScreenErrorCard(error: error, needsScreenRecordingSettings: screen.needsScreenRecordingSettings) {
          MacPermissionRows.openScreenSettings()
        }
      }
      if let approval = messages.pendingSend {
        MessagesSendApprovalCard(approval: approval) { messages.answer($0) }
      }
      if let issue = messages.issue {
        MessagesIssueCard(issue: issue, openSettings: messages.openPrivacySettings) { messages.issue = nil }
      }
      if files.selection != nil || files.error != nil || files.protectedWrite != nil {
        FileAttachmentCard(files: files, access: fileAccess, isCloud: shell.selectedMode == .cloud,
          isBusy: localChat.isBusy, useCodex: { isFileCloudConsentPresented = true })
      }
      FileChangeSummary(files: files, isBusy: localChat.isBusy)
    }
  }

  /// The attached screenshot, with the consent sheet that asks before a cloud
  /// model sees it.
  private func screenshotAttachment(_ attachment: ScreenAttachment) -> some View {
    ScreenAttachmentCard(attachment: attachment, isBusy: localChat.isBusy || screen.isBusy,
      remove: screen.removeAttachment, retake: captureScreen)
      .sheet(item: $screenUploadConsent, onDismiss: { shell.isComposerFocused = !localChat.isBusy }) { consent in
        ScreenUploadConsentView(consent: consent,
          allow: { answerScreenPermission(consent, allow: true) },
          decline: { answerScreenPermission(consent, allow: false) })
          .enigmaTheme(appearance.appearance)
      }
  }

  // Keep these modifier groups separate so Swift can type-check each expression.
  /// The compact selection panel, or the window frame with the sidebar and main page.
  @ViewBuilder private var windowFrame: some View {
    if shell.showsCompactPanel {
      compactPanel
    } else {
      shellLayout
    }
  }

  private var welcomeShell: some View {
    windowFrame
    .disabled(welcomeSetup.isPresented || welcomeSetup.tour != nil)
    .accessibilityHidden(welcomeSetup.isPresented)
    .overlayPreferenceValue(WelcomeTourAnchors.self) { anchors in
      if welcomeSetup.tour != nil {
        WelcomeTourOverlay(setup: welcomeSetup, anchors: anchors,
          availableCommands: SlashCommand.available(hasSearchKey: searchSettings.hasAPIKey))
      }
    }
    .overlay {
      ZStack {
        if welcomeSetup.isPresented {
          WelcomeSetupView(setup: welcomeSetup, character: character, advisor: modelAdvisor, chat: localChat,
            cloud: cloudSettings, search: searchSettings)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12)))
        }
      }
      // The welcome fades away over the main page.
      .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.screenChange.animation,
                 value: welcomeSetup.isPresented)
    }
    // The window's corners, so the tour's scrim and the welcome stay inside
    // it. The compact panel draws its own corners.
    .clipShape(shell.showsCompactPanel ? AnyShape(Rectangle())
               : AnyShape(RoundedRectangle(cornerRadius: EnigmaWindowChrome.cornerRadius, style: .continuous)))
    // One stage for the whole window, so the character can fall from the
    // welcome into the main page.
    .enigmaCharacterStage(character)
    // One theme for the window, its welcome, tour, and character.
    .enigmaTheme(appearance.appearance)
  }

  private var commandObservedShell: some View {
    welcomeShell
    .onPreferenceChange(SelectionComposerHeight.self) { report in
      guard shell.isSelectionComposer, report.height > 0 else { return }
      NotificationCenter.default.post(name: .selectionComposerHeightChanged, object: report)
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionPanelExpanded)) { _ in
      shell.leaveSelectionComposer()
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionChatOpenedInWindow)) { _ in
      // The panel's chat is now the window's: the normal layout with the
      // sidebar as a new chat has it, and saved to history from here on.
      shell.openSelectionChatInWindow(showsSidebar: startPreferences.showsSidebar)
      localChat.openTemporaryChatInWindow()
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionPanelPlaced)) { notification in
      guard let roomBelow = notification.object as? CGFloat else { return }
      compactOpensOverlaysAbove = CompactPanelLayout.opensOverlaysAbove(roomBelow: roomBelow)
    }
    .onReceive(NotificationCenter.default.publisher(for: .sidebarToggleRequested)) { _ in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      shell.isSidebarVisible.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .fileModeRequested)) { _ in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      activateFileMode(from: .keyboard)
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionContextRequested)) { notification in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      screen.clearDraft()
      shell.beginSelectionComposer(mode: startPreferences.mode, showsSidebar: startPreferences.showsSidebar)
      localChat.startTemporaryChat(context: notification.object as? ConversationContext)
    }
    .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      screen.clearDraft()
      shell.startNewChat(mode: startPreferences.mode, showsSidebar: startPreferences.showsSidebar)
      localChat.newChat()
    }
    .onReceive(NotificationCenter.default.publisher(for: .modePaletteRequested)) { _ in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      shell.isModePalettePresented.toggle()
    }
    .onReceive(NotificationCenter.default.publisher(for: .settingsRequested)) { _ in
      shell.isModePalettePresented = false
    }
  }

  private var observedShell: some View {
    commandObservedShell
    .onReceive(NotificationCenter.default.publisher(for: .panelPresented)) { _ in
      selectionAccess.refresh()
      localChat.applicationBecameActive()
      Task { await modelAdvisor.refreshCatalog() }
      shell.isComposerFocused = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .panelHidden)) { _ in
      localChat.applicationBecameInactive()
      // An open menu or the details don't outlive the panel.
      shell.isModePalettePresented = false
      shell.isSelectionDetailsPresented = false
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      selectionAccess.refresh()
      localChat.applicationBecameActive()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      localChat.applicationBecameInactive()
    }
    .onReceive(NotificationCenter.default.publisher(for: .stopStreamingRequested)) { _ in
      localChat.stopStreaming()
    }
    .onReceive(NotificationCenter.default.publisher(for: .recentChatCycleRequested)) { _ in
      guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
      shell.cycleRecentChat()
      localChat.cycleRecentChat()
    }
  }

  private var selectionObservedShell: some View {
    observedShell
    .onChange(of: localChat.state) { _, state in
      if shell.isSelectionComposer, case .failed = state { shell.revealSelectionProblem() }
    }
    .onChange(of: screen.error) { _, error in
      if shell.isSelectionComposer, error != nil { shell.revealSelectionProblem() }
    }
    .onChange(of: files.error) { _, error in
      if shell.isSelectionComposer, error != nil { shell.revealSelectionProblem() }
    }
    .onChange(of: messages.issue) { _, issue in
      if shell.isSelectionComposer, issue != nil { shell.revealSelectionProblem() }
    }
  }

  /// The character's state and attention follow the window outside the welcome.
  private var characterObservedShell: some View {
    selectionObservedShell
    .onChange(of: mainCharacterState, initial: true) { _, state in
      guard !welcomeSetup.isPresented else { return }
      character.state = state
    }
    .onChange(of: isTypingInComposer) { _, typing in
      guard !welcomeSetup.isPresented else { return }
      character.attention = typing ? MainWindowCharacter.composerTarget : nil
    }
    .onChange(of: screen.draft) { old, new in
      // Sending or clearing the draft brings back dismissed recognized commands.
      if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !dismissedInferences.isEmpty {
        dismissedInferences = []
      }
      // A nudge toward the composer for each keystroke that adds text.
      guard !welcomeSetup.isPresented, shell.isComposerFocused, new.count > old.count else { return }
      character.key(towards: MainWindowCharacter.composerTarget)
    }
    .onChange(of: CharacterPlacement(session: localChat.selectedSessionID, slot: windowCharacterSlot)) { old, new in
      // In the open chat it falls into the first reply and moves down to each
      // newer one. Opening another chat, saved or new, puts it there at once.
      guard !welcomeSetup.isPresented, old.slot != new.slot else { return }
      character.move(to: new.slot, ChatCharacterMove.transition(fromSession: old.session, toSession: new.session,
                                                                isResponding: localChat.activeRequest != nil))
    }
    .onChange(of: localChat.presentationMessages.last?.content.utf8.count) { _, _ in
      // One ripple per streamed update, while the character is in the chat to show it.
      guard !welcomeSetup.isPresented, localChat.state == .streaming, character.isPresent else { return }
      character.token()
    }
    .onAppear {
      settleCharacter(.instant)
    }
  }

  var body: some View {
    characterObservedShell
    .sheet(isPresented: $modelAdvisor.isOnboardingPresented, onDismiss: { modelAdvisor.dismissOnboarding() }) {
      LocalModelOnboardingView(advisor: modelAdvisor, chat: localChat)
        .enigmaTheme(appearance.appearance)
    }
    .modifier(MessagesDialogs(messages: messages, submit: submitMessages))
    .modifier(FileModeDialogs(files: files, isCloudConsentPresented: $isFileCloudConsentPresented,
      isBusy: localChat.isBusy, reviewAppearance: appearance.appearance, useCodex: {
        cloudSettings.preferredProvider = .chatGPT
        shell.selectedMode = .cloud
        if let handoff = files.prepareProtectedCloudDraft() {
          cloudSettings.preferredModelID = handoff.modelID
          if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = handoff.prompt }
        }
      }))
    .onChange(of: localChat.isBusy) { _, busy in
      // A disabled TextField cannot take focus at first-token acceptance.
      // Restore its editor only after the owning request has finished.
      shell.requestBusyChanged(busy)
    }
    .onChange(of: localChat.selectedSessionID) { _, _ in
      if shell.sessionChanged(isTemporaryChat: localChat.isTemporaryChat) {
        NotificationCenter.default.post(name: .selectionPanelResetRequested, object: nil)
      }
      if localChat.activeRequest == nil { screen.removeAttachment() }
    }
    .onChange(of: screenSettings.allowCloudScreenshots) { _, allowed in
      if !allowed, localChat.screenRouteDecision?.sendsImage == true, localChat.activeRequest?.route.mode == .cloud {
        localChat.stopStreaming()
      }
    }
    .sheet(isPresented: $shell.isHelpPresented) {
      KeyboardShortcutsHelpView(searchSettings: searchSettings)
        .enigmaTheme(appearance.appearance)
    }
    .fileImporter(
      isPresented: $isModelImporterPresented,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data],
      allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        localChat.installModel(from: url)
        shell.selectedMode = .local
      }
    }
    .task {
      await localChat.refreshInstalledModel()
      welcomeSetup.start(hasInstalledModels: !localChat.installedModels.isEmpty)
      await modelAdvisor.start(installedModels: localChat.installedModels, presentOnboarding: false)
    }
    .onChange(of: welcomeSetup.isPresented) { _, presented in
      shell.welcomeChanged(isPresented: presented, isTourActive: welcomeSetup.tour != nil)
      if !presented { startPreferences.mode = .auto }
      // The character falls from the welcome into the main page's slot.
      if !presented { settleCharacter(.automatic) }
    }
    .onChange(of: welcomeSetup.tour) { _, tour in
      shell.tourChanged(isActive: tour != nil, isWelcomePresented: welcomeSetup.isPresented)
    }
    .onChange(of: shell.selectedMode, initial: true) { _, mode in
      localChat.clearAutoRouteDecision()
      guard mode == .cloud || mode == .auto else { return }
      Task {
        if cloudSettings.preferredProvider == .chatGPT {
          await cloudSettings.refreshChatGPTAccount()
        } else if cloudSettings.preferredProvider == .claudeCode {
          await cloudSettings.refreshClaudeCodeAccount()
        }
        if cloudSettings.hasCloudAccess(for: cloudSettings.preferredProvider) {
          await cloudSettings.discoverModels()
        }
      }
    }
  }

  // MARK: Window frame

  /// The window: the sidebar and the main page on an opaque background.
  private var shellLayout: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if shell.isSidebarVisible {
          sidebar
            .frame(width: MainPageLayout.sidebarWidth(for: geometry.size.width))
            .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
        }
        mainColumn
          // Under Reduce Motion the main column doesn't slide: it takes its
          // new width at once, so its AppKit views (the message field, Send)
          // never pass through in-between frames, and only the sidebar fades.
          .transaction(value: shell.isSidebarVisible) { if reduceMotion { $0.animation = nil } }
      }
      .animation(reduceMotion ? .easeOut(duration: 0.15) : EnigmaMotion.screenChange.animation,
                 value: shell.isSidebarVisible)
    }
    .enigmaMenuHost()
    .modifier(EnigmaWindowChrome())
    .frame(minWidth: 640, minHeight: shell.isSelectionPresentation ? 0 : 420)
  }

  private var sidebar: some View {
    EnigmaSidebar(
      // A private selection chat stays out of Recents.
      rows: ChatHistoryList.rows(sessions: localChat.historySessions, selectedSessionID: localChat.selectedSessionID),
      tourStep: welcomeSetup.tour,
      select: { target in
        switch target {
        case .newChat: NotificationCenter.default.post(name: .newChatRequested, object: nil)
        case .session(let id): localChat.selectSession(id: id)
        }
      },
      newChat: { NotificationCenter.default.post(name: .newChatRequested, object: nil) },
      hide: { shell.isSidebarVisible = false },
      openHelp: { shell.isHelpPresented = true },
      openSettings: openSettings
    ) {
      // Developer Tools is for development only; Settings has the same tools.
      #if DEBUG
      DeveloperToolsView(advisor: modelAdvisor, chat: localChat, replayWelcome: { welcomeSetup.replay() })
      #endif
    }
  }

  private var mainColumn: some View {
    let examples = SlashCommandExample.examples(available: availableCommands)
    return EnigmaMainColumn(
      isEmpty: isChatEmpty,
      showsTopBar: !shell.isSidebarVisible,
      availableExamples: examples.count,
      topBar: {
        EnigmaHiddenSidebarBar(
          show: { shell.isSidebarVisible = true },
          openHelp: { shell.isHelpPresented = true },
          openSettings: openSettings,
          newChat: { NotificationCenter.default.post(name: .newChatRequested, object: nil) })
      },
      header: { style in
        EnigmaMainPageHeader(style: style, greeting: MainPageGreeting.text(at: .now), status: routeStatusSummary,
                             performStatusAction: performRouteAction, mode: $shell.selectedMode,
                             isStatusActionEnabled: !localChat.isBusy)
      },
      conversation: { messageList },
      accessories: { composerAccessories() },
      composer: { docked in composer(docked: docked) },
      examples: { count in
        EnigmaCommandExamples(examples: Array(examples.prefix(count)), isEnabled: composerIsEnabled) { command in
          shell.isComposerFocused = true
          composerInsertion = SlashCommandInsertion(text: command.token + " ")
        }
      })
  }

  private func composer(docked: Bool) -> some View {
    EnigmaComposer(
      text: composerText, isFocused: composerFocus, isEnabled: composerIsEnabled,
      availableCommands: availableCommands, insertion: composerInsertion, opensSuggestionsBelow: !docked,
      submit: { submitDraft() },
      files: files, isAttachDisabled: localChat.isBusy || files.isPicking || files.isWorking,
      attach: { activateFileMode(from: .menu) },
      beginCommand: {
        shell.isComposerFocused = true
        composerInsertion = SlashCommandInsertion(text: "/")
      },
      route: routeIndicator, menu: modeAndModelMenu, menuActions: modeAndModelActions,
      isMenuPresented: $shell.isModePalettePresented,
      // Closing the menu returns to the message field.
      menuClosed: { shell.isComposerFocused = true },
      isResponding: localChat.activeRequest != nil, canSend: canSendDraft,
      send: { submitDraft() }, stop: { localChat.stopStreaming() },
      inferredCommands: recognizedCommands, dismissInferred: dismissRecognizedCommand)
  }

  /// The selected route's state, for the status line on the main page and above the composer.
  private var routeStatusSummary: ChatRouteStatus {
    let mode = shell.selectedMode
    var context = ChatRouteStatus.Context(mode: mode, state: localChat.state,
      request: localChat.activeRequest.map { ChatRouteStatus.Request(phase: requestPhase, name: $0.displayName) },
      localModelName: localChat.installedModel?.displayName)
    // Cloud checks run only for the modes that use the cloud.
    if mode != .local, localChat.activeRequest == nil {
      context.cloudProvider = cloudSettings.preferredProvider
      context.autoDecision = localChat.autoRouteDecision
      if mode == .cloud {
        context.hasCloudAccess = cloudSettings.hasCloudAccess(for: cloudSettings.preferredProvider)
        context.isCloudConfigured = context.hasCloudAccess && cloudSettings.isConfigured
        context.cloudCompatibility = cloudSettings.selectedModelCompatibility
        context.cloudModelID = cloudSettings.preferredModelID
      } else {
        context.hasAutoCloud = autoCloudConfiguration != nil
      }
    }
    return ChatRouteStatus.make(context)
  }

  private func performRouteAction(_ action: ChatRouteStatus.Action) {
    switch action {
    case .chooseModel: isModelImporterPresented = true
    case .openSettings: openSettings()
    }
  }

  private var routeIndicator: ComposerRouteIndicator? {
    ComposerRouteIndicator.make(
      mode: shell.selectedMode, requestMode: localChat.activeRequest?.route.mode,
      autoDecisionMode: localChat.autoRouteDecision?.route?.mode, hasLocalModel: localChat.installedModel != nil,
      hasAutoCloud: shell.selectedMode == .auto && autoCloudConfiguration != nil)
  }

  private var modeAndModelMenu: ModeAndModelMenu {
    ModeAndModelMenu(
      mode: shell.selectedMode, isBusy: localChat.isBusy, hasActiveRequest: localChat.activeRequest != nil,
      localModels: localChat.installedModels.map {
        ModeAndModelMenu.LocalChoice(id: $0.id, name: $0.displayName, supportsVision: $0.supportsVision)
      },
      selectedLocalID: localChat.installedModel?.id,
      cloudProvider: cloudSettings.preferredProvider,
      cloudModels: cloudSettings.models.map {
        ModeAndModelMenu.CloudChoice(id: $0.id, name: $0.displayName, supportsVision: $0.supportsVision)
      },
      selectedCloudID: cloudSettings.preferredModelID)
  }

  private var modeAndModelActions: ModeAndModelMenu.Actions {
    ModeAndModelMenu.Actions(
      chooseMode: { shell.chooseMode($0) },
      selectLocalModel: { localChat.selectModel(id: $0) },
      selectCloudModel: { cloudSettings.preferredModelID = $0 },
      findModel: { Task { await modelAdvisor.replayOnboarding() } },
      importModel: { isModelImporterPresented = true },
      // After the menu has closed and handed focus back, so Settings keeps it.
      openSettings: { Task { @MainActor in openSettings() } })
  }

  // MARK: Compact panel

  /// The compact selection panel, with the same actions, notices, cards, and
  /// consent steps as the window.
  private var compactPanel: some View {
    let composing = shell.isSelectionComposer
    return EnigmaCompactPanel(
      isComposing: composing,
      opensOverlaysAbove: compactOpensOverlaysAbove,
      hints: CompactPanelHints.hints(isResponding: localChat.activeRequest != nil),
      isTemporary: localChat.isTemporaryChat,
      selection: {
        EnigmaCompactSelectionLine(
          contexts: localChat.attachedContexts, sentContextIDs: localChat.sentContextIDs,
          isBusy: localChat.isBusy || selectionContext.isWorking,
          isComposing: composing,
          statusNeedsAttention: CompactPanelCharacter.statusNeedsAttention(
            notice: selectionContext.notice, isAccessibilityGranted: selectionAccess.isGranted),
          isStatusPresented: shell.isSelectionDetailsPresented,
          toggleStatus: { shell.isSelectionDetailsPresented.toggle() },
          remove: { localChat.removeContext(id: $0) },
          openInWindow: { NotificationCenter.default.post(name: .selectionChatOpenInWindowRequested, object: nil) },
          opensPrivately: selectionEditing.keepsChatsPrivate)
      },
      composer: { compactComposer },
      attachment: {
        if let attachment = screen.attachment, localChat.pendingUserMessage == nil {
          screenshotAttachment(attachment)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
      },
      details: {
        if shell.isSelectionDetailsPresented {
          EnigmaCompactDetails { composerAccessories(showsScreenshot: false) }
            // Escape closes the details first, before the panel.
            .enigmaDismissesOnEscape { shell.isSelectionDetailsPresented = false }
            .transition(.opacity)
        }
      },
      answer: {
        EnigmaCompactAnswer(conversation: { compactMessageList },
                            accessories: { composerAccessories(showsSelectedText: false) })
      })
    .animation(reduceMotion ? .easeOut(duration: 0.12) : EnigmaMotion.menu.animation,
               value: shell.isSelectionDetailsPresented)
    .enigmaMenuHost()
    .frame(minWidth: 640)
  }

  private var compactComposer: some View {
    EnigmaCompactComposer(
      text: composerText, isFocused: composerFocus, isEnabled: composerIsEnabled,
      availableCommands: availableCommands,
      // Once the selection has gone with the first message, new questions don't carry it.
      placeholder: CompactPanelLayout.placeholder(hasSelection: localChat.attachedContexts.contains {
        !localChat.sentContextIDs.contains($0.id)
      }),
      opensSuggestionsAbove: compactOpensOverlaysAbove,
      insertion: composerInsertion, submit: { submitDraft() },
      files: files, isAttachDisabled: localChat.isBusy || files.isPicking || files.isWorking,
      attach: { activateFileMode(from: .menu) },
      chip: CompactRouteChip.text(mode: shell.selectedMode, route: routeIndicator,
                                  modelName: shell.selectedMode == .auto ? nil : compactModelName),
      menu: modeAndModelMenu, menuActions: modeAndModelActions,
      isMenuPresented: $shell.isModePalettePresented,
      menuClosed: { shell.isComposerFocused = true },
      isResponding: localChat.activeRequest != nil, canSend: canSendDraft,
      send: { submitDraft() }, stop: { localChat.stopStreaming() },
      inferredCommands: recognizedCommands, dismissInferred: dismissRecognizedCommand)
  }

  /// The model a fixed mode uses, for the compact panel's route chip.
  private var compactModelName: String? {
    switch shell.selectedMode {
    case .local: localChat.installedModel?.displayName
    case .cloud: cloudSettings.preferredModelID.isEmpty ? nil : cloudSettings.preferredModelID
    case .auto: nil
    }
  }

  /// The chat under the compact panel's input: the same list, revision cards,
  /// and per-chat identity as the main window's, gathered at the top.
  private var compactMessageList: some View {
    EnigmaMessageList(transcript: conversationTranscript, scrollRevision: conversationScrollRevision,
                      activityExpansion: activityExpansion, gathersAtBottom: false, horizontalPadding: 16) {
      revisionCard($0)
    }
    .id(localChat.selectedSessionID)
  }

  // MARK: Character

  private var isTypingInComposer: Bool {
    shell.isComposerFocused && composerIsEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var mainCharacterState: EnigmaCharacterState {
    let state = localChat.state
    let isPreparing = state == .preparing || state == .refiningSearch || state == .searching
    let isModelTask: Bool = switch state {
    case .installing, .deleting, .benchmarking, .downloading: true
    default: false
    }
    return MainWindowCharacter.state(MainWindowCharacter.Inputs(
      isWorking: isPreparing || isModelTask || screen.isBusy || files.isWorking || files.isPicking,
      isStreaming: state == .streaming,
      routeCanRun: ComposerSubmission.canSubmit(
        mode: shell.selectedMode, hasLocalModel: localChat.installedModel != nil,
        isCloudConfigured: cloudSettings.isConfigured, hasAutoCloud: autoCloudConfiguration != nil, isBusy: false),
      hasProblem: hasRouteProblem || hasSelectionProblem,
      isTyping: isTypingInComposer))
  }

  /// In the compact panel, the selection couldn't be read or Accessibility is missing.
  private var hasSelectionProblem: Bool {
    CompactPanelCharacter.hasSelectionProblem(
      isPanel: shell.isSelectionPresentation, isComposing: shell.isSelectionComposer,
      hasSelection: !localChat.attachedContexts.isEmpty, notice: selectionContext.notice,
      isAccessibilityGranted: selectionAccess.isGranted, isTemporaryChat: localChat.isTemporaryChat)
  }

  /// The last request failed, or Auto can't take the next one. A route that's
  /// missing something is covered by `routeCanRun`.
  private var hasRouteProblem: Bool {
    if case .failed = localChat.state { return true }
    return shell.selectedMode == .auto && localChat.autoRouteDecision?.limitation != nil
  }

  /// Where the character sits outside the welcome: beside the latest reply
  /// in a chat, and otherwise on the main page, or beside the compact panel's input.
  private var windowCharacterSlot: EnigmaCharacterSlotID {
    let home = shell.showsCompactPanel ? CompactPanelLayout.inputSlot : MainWindowCharacter.mainSlot
    guard !isChatEmpty else { return home }
    return ConversationTranscript.latestReplySlot(messages: localChat.presentationMessages,
                                                  activity: localChat.activity) ?? home
  }

  /// Sends the character to its slot in the window with its state there.
  private func settleCharacter(_ transition: EnigmaCharacterTransition) {
    guard !welcomeSetup.isPresented else { return }
    character.move(to: windowCharacterSlot, transition)
    // On the next turn, once the update that closed the welcome has finished,
    // so the welcome's last state change can't land after this one.
    Task { @MainActor in
      guard !welcomeSetup.isPresented else { return }
      character.state = mainCharacterState
      character.attention = isTypingInComposer ? MainWindowCharacter.composerTarget : nil
    }
  }

  // MARK: Composer state, shared by the window and the compact panel

  private var composerText: Binding<String> {
    Binding(get: { localChat.pendingUserMessage == nil ? screen.draft : "" }, set: { screen.draft = $0 })
  }

  private var composerFocus: Binding<Bool> {
    Binding(get: { shell.isComposerFocused && !welcomeSetup.isPresented && welcomeSetup.tour == nil },
            set: { shell.isComposerFocused = $0 })
  }

  private var composerIsEnabled: Bool {
    !(localChat.isBusy || screen.isBusy || files.isWorking || files.isPicking)
      && !welcomeSetup.isPresented && welcomeSetup.tour == nil
  }

  private var availableCommands: [SlashCommand] { SlashCommand.available(hasSearchKey: searchSettings.hasAPIKey) }

  /// Send is available for a draft the selected route can take.
  private var canSendDraft: Bool {
    !(!canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || screen.isBusy || files.isWorking || files.isPicking)
  }

  /// Nothing has been sent in this chat, and nothing is on its way.
  private var isChatEmpty: Bool { localChat.presentationMessages.isEmpty && localChat.activeRequest == nil }

  /// What keeps a reader at the bottom following the chat, for both lists.
  private var conversationScrollRevision: String {
    (localChat.presentationMessages.last?.content ?? "") + String(localChat.presentationMessages.count)
      + (localChat.activity?.status ?? "") + String(shell.expandedActivities.count)
  }

  /// The chat, with a new identity for each chat so it opens at its own end.
  private var messageList: some View {
    EnigmaMessageList(transcript: conversationTranscript, scrollRevision: conversationScrollRevision,
                      activityExpansion: activityExpansion,
                      footnote: openedSelectionChatNote) {
      revisionCard($0)
    }
    .id(localChat.selectedSessionID)
  }

  /// The one-time line under a chat just opened in the window from the panel:
  /// saved to history, or private.
  private var openedSelectionChatNote: String? {
    guard let opened = localChat.openedSelectionChat, opened.id == localChat.selectedSessionID else { return nil }
    return opened.isPrivate ? CompactPanelHints.privateNote : CompactPanelHints.savedNote
  }

  /// The /edit revision card under a reply, when it has one to review.
  @ViewBuilder private func revisionCard(_ message: ChatMessage) -> some View {
    if let revision = localChat.selectionRevisions[message.id], !revision.automatic {
      SelectionRevisionCard(revision: revision, disabled: localChat.isBusy || !selectionContext.canReplace,
        update: { localChat.updateSelectionRevision(messageID: message.id, text: $0) },
        replace: { Task { await localChat.applySelectionRevision(messageID: message.id) } })
    }
  }

  private var conversationTranscript: ConversationTranscript {
    ConversationTranscript(messages: localChat.presentationMessages.map(localChat.selectionDisplayMessage),
                           activity: localChat.activity, isResponding: localChat.activeRequest != nil)
  }

  private func activityExpansion(_ id: UUID) -> Binding<Bool> {
    Binding(get: { shell.isActivityExpanded(id) }, set: { shell.setActivity(id, expanded: $0) })
  }

  private var requestPhase: String { localChat.activity?.status ?? "Preparing…" }

  private var canSubmit: Bool {
    ComposerSubmission.canSubmit(mode: shell.selectedMode, hasLocalModel: localChat.installedModel != nil,
      isCloudConfigured: cloudSettings.isConfigured, hasAutoCloud: autoCloudConfiguration != nil, isBusy: localChat.isBusy)
  }

  private var fileAccess: FileAccessLevel {
    if shell.selectedMode == .cloud { return cloudSettings.preferredProvider == .chatGPT ? .readWrite : .readOnly }
    return localChat.installedModel.map { LocalFileCapabilities.production.access(for: $0) } ?? .readOnly
  }

  private func activateFileMode(from source: FileModeCoordinator.Activation) {
    guard !localChat.isBusy, !screen.isBusy else { return }
    Task {
      await files.activate(from: source)
      if files.selection != nil {
        screen.removeAttachment()
        draft = SlashCommand.removing([.search], from: draft)
      }
      shell.isComposerFocused = true
    }
  }

  private func captureScreen() {
    guard !localChat.isBusy else { return }
    Task {
      _ = await screen.capture()
      shell.isComposerFocused = true
    }
  }

  private func expandSelectionConversation() {
    guard shell.isSelectionComposer else { return }
    NotificationCenter.default.post(name: .selectionPanelExpandRequested, object: nil)
    shell.leaveSelectionComposer()
  }

  /// What the composer's chips and Send both resolve, so they agree.
  private var composerIntentContext: ComposerIntent.Context {
    ComposerIntent.Context(
      draft: draft, hasSelection: localChat.attachedContexts.contains { $0.kind == .selectedText },
      hasFileSelection: files.selection != nil, hasScreenshot: screen.isEnabled,
      previousTurnUsedMessages: localChat.previousTurnUsedMessages, infersCommands: infersCommands,
      searchesAutomatically: searchSettings.canSearchAutomatically, dismissed: dismissedInferences)
  }

  private var composerIntent: ComposerIntent { composerIntent(recognizesCommands: true) }

  /// `recognizesCommands` is false for the request a typed `/screen` or `/snapshot`
  /// sends after its capture: captures run only their typed commands.
  private func composerIntent(recognizesCommands: Bool) -> ComposerIntent {
    var context = composerIntentContext
    context.infersCommands = context.infersCommands && recognizesCommands
    return ComposerIntent.resolve(context)
  }

  /// The chips for the draft the field shows; none while a sent message is pending.
  private var recognizedCommands: [SlashCommand] {
    localChat.pendingUserMessage == nil ? composerIntent.inferred : []
  }

  private func dismissRecognizedCommand(_ command: SlashCommand) {
    dismissedInferences.insert(command)
    shell.isComposerFocused = true
  }

  private func submitDraft(recognizesCommands: Bool = true) {
    guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
    guard !localChat.isBusy, !screen.isBusy, !files.isWorking, !files.isPicking else { return }
    let originalDraft = draft
    let submission = ComposerSubmission.plan(composerIntent(recognizesCommands: recognizesCommands), hasFileSelection: files.selection != nil,
                                             hasScreenshot: screen.isEnabled, canSubmit: canSubmit)
    switch submission {
    case .none:
      return
    case .fileConflict:
      files.error = ComposerSubmission.fileConflictMessage
    case .files(let prompt):
      localChat.submitFiles(prompt, mode: shell.selectedMode, cloudProvider: cloudSettings.preferredProvider,
        cloudModelID: cloudSettings.preferredModelID) {
          expandSelectionConversation()
          draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
        }
    case .messagesConflict:
      messages.report(ComposerSubmission.messagesConflictMessage)
    case .messages(let prompt):
      submitMessages(prompt)
    case .captureScreen:
      Task {
        let automaticPrompt = await screen.capture(submittedCommand: true)
        shell.isComposerFocused = true
        if automaticPrompt != nil { submitDraft(recognizesCommands: false) }
      }
    case .screenAttachment:
      if let attachment = screen.attachment { submitScreenAttachment(attachment, recognizesCommands: recognizesCommands) }
    case .chat(let prompt, let searchEnabled):
      let accepted: @MainActor () -> Void = {
        expandSelectionConversation()
        draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
      }
      // The resolved draft already decided search, including a dismissed search chip.
      switch shell.selectedMode {
      case .local:
        localChat.submit(prompt, searchEnabled: searchEnabled, allowsAutomaticSearch: false, onAccepted: accepted)
      case .cloud:
        localChat.submitCloud(
          prompt,
          provider: cloudSettings.preferredProvider,
          modelID: cloudSettings.preferredModelID,
          searchEnabled: searchEnabled,
          allowsAutomaticSearch: false,
          onAccepted: accepted
        )
      case .auto:
        localChat.submitAuto(prompt, cloud: autoCloudConfiguration, searchEnabled: searchEnabled,
                             allowsAutomaticSearch: false, onAccepted: accepted)
      }
    }
  }

  private func submitMessages(_ prompt: String) {
    if shell.selectedMode == .cloud, !messages.hasDisclosed(cloudSettings.preferredProvider) {
      messages.requestDisclosure(for: cloudSettings.preferredProvider, prompt: prompt)
      return
    }
    let originalDraft = draft
    localChat.submitMessages(prompt, mode: shell.selectedMode, cloudProvider: cloudSettings.preferredProvider,
      cloudModelID: cloudSettings.preferredModelID) {
        expandSelectionConversation()
        draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
      }
  }

  private func submitScreenAttachment(_ attachment: ScreenAttachment, recognizesCommands: Bool) {
    let originalDraft = draft
    let intent = composerIntent(recognizesCommands: recognizesCommands)
    guard intent.hasPrompt else { return }
    let prompt = intent.submissionPrompt
    let cloudText = cloudSettings.isConfigured
      ? CloudModel(id: cloudSettings.preferredModelID, displayName: cloudSettings.preferredModelID,
                   provider: cloudSettings.preferredProvider).screenModel : nil
    let searchEnabled = localChat.shouldSearch(prompt, explicitlyEnabled: intent.search, allowsAutomaticSearch: false)
    let automatic = shell.selectedMode == .auto ? AutoRouter.decide(AutoRouter.Request(
      selectedMode: .auto, webSearchEnabled: searchEnabled, prompt: prompt,
      contextMessages: localChat.autoRoutingContextMessages, localModel: localChat.installedModel,
      additionalInputTokens: attachment.ocrText.utf8.count + 512
        + (ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ScreenOCRResult(text: attachment.ocrText,
          confidence: attachment.ocrConfidence)) ? 4096 : 0),
      cloud: connectivity.isOffline ? nil : autoCloudConfiguration)) : nil
    if let limitation = automatic?.limitation {
      screen.error = limitation.message
      return
    }
    let request = ScreenRoutingPolicy.Request(
      prompt: prompt, ocr: ScreenOCRResult(text: attachment.ocrText, confidence: attachment.ocrConfidence),
      mode: shell.selectedMode, localText: localChat.installedModel?.screenModel, cloudText: cloudText,
      autoRoute: automatic?.route,
      allowCloudScreenshots: screenSettings.allowCloudScreenshots,
      hasExplainedCloudPermission: screenSettings.hasExplainedCloudPermission, isOffline: connectivity.isOffline
    )
    let decision = ScreenRoutingPolicy.decide(request)
    screen.updateDecision(decision)
    screen.error = nil
    switch decision {
    case .needsCloudPermission:
      reviewScreenPermission(recognizesCommands: recognizesCommands)
    case .blocked(let reason):
      screen.error = reason
    case .text, .vision:
      localChat.submitScreen(prompt, attachment: attachment, decision: decision, selectedMode: shell.selectedMode,
        searchEnabled: searchEnabled, allowsAutomaticSearch: false,
        cloudUploadAllowed: { screenSettings.allowCloudScreenshots && screenSettings.hasExplainedCloudPermission }) {
          expandSelectionConversation()
          draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
          if screen.attachment?.id == attachment.id { screen.removeAttachment() }
          shell.isComposerFocused = true
        }
    }
  }

  private func reviewScreenPermission(recognizesCommands: Bool = true) {
    guard shell.selectedMode != .local, let attachment = screen.attachment else { return }
    shell.isSelectionDetailsPresented = false
    screenUploadConsent = ScreenUploadConsent(attachment: attachment, provider: cloudSettings.preferredProvider,
                                              recognizesCommands: recognizesCommands)
  }

  private func answerScreenPermission(_ consent: ScreenUploadConsent, allow: Bool) {
    screenUploadConsent = nil
    // A replaced draft or destination must not inherit an unseen image's approval.
    guard screen.attachment?.id == consent.attachment.id,
          cloudSettings.preferredProvider == consent.provider, shell.selectedMode != .local else { return }
    screenSettings.answerCloudPermission(allow: allow)
    if allow {
      // Recheck the current route and permission before sending pixels.
      submitDraft(recognizesCommands: consent.recognizesCommands)
    } else {
      screen.error = "Screenshot kept on this Mac. Use a local vision model, or enable uploads in Screen settings."
    }
  }

  private var autoCloudConfiguration: AutoRouter.CloudConfiguration? {
    guard cloudSettings.isConfigured else { return nil }
    let modelID = cloudSettings.preferredModelID
    let displayName = cloudSettings.models.first(where: { $0.id == modelID })?.displayName ?? modelID
    return AutoRouter.CloudConfiguration(
      provider: cloudSettings.preferredProvider,
      modelID: modelID,
      modelDisplayName: displayName
    )
  }

  private func openConnectionSettings() {
    shell.prepareForSettings()
    NotificationCenter.default.post(name: .settingsRequested, object: SettingsView.SettingsDestination.cloud)
  }

  private func openSettings() {
    shell.prepareForSettings()
    NotificationCenter.default.post(name: .settingsRequested, object: nil)
  }
}

/// Which chat is open and where the character sits in it.
private struct CharacterPlacement: Equatable {
  let session: UUID?
  let slot: EnigmaCharacterSlotID
}
