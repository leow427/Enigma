import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
  @ObservedObject private var welcomeSetup: WelcomeSetup
  @ObservedObject private var whatsNew: WhatsNew
  /// System, Paper, or Ink.
  @ObservedObject private var appearance: EnigmaAppearancePreference
  /// The window's character: on the welcome, then on the main page. Owned
  /// here but not observed: the stage redraws it, and nothing here reads it.
  @State private var character: EnigmaCharacterController
  @ObservedObject private var selectionAccess: SelectionAccessibilityAccess
  @ObservedObject private var selectionContext: SelectionContextService
  @ObservedObject private var cloudSettings: CloudSettingsModel
  @StateObject private var localChat: LocalChatViewModel
  @ObservedObject private var modelAdvisor: LocalModelAdvisor
  @ObservedObject private var files: FileModeCoordinator
  @ObservedObject private var messages: MessagesCoordinator
  @ObservedObject private var toolPermissions: ToolPermissionCoordinator
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
  @AppStorage(ComposerIntent.inferCommandsKey) private var infersCommands = ComposerIntent.infersCommandsByDefault
  /// Recognized commands turned off for the current draft. Cleared when the draft empties.
  @State private var dismissedInferences: Set<SlashCommand> = []
  /// The draft as it was sent, and the pending message it became: while that
  /// message waits to be accepted, the field shows blank for the draft, but
  /// keeps anything typed meanwhile.
  @State private var sentDraft: (text: String, messageID: UUID)?

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
    whatsNew: WhatsNew = .shared,
    appearance: EnigmaAppearancePreference = .shared,
    character: EnigmaCharacterController? = nil,
    selectionAccess: SelectionAccessibilityAccess = .shared,
    selectionContext: SelectionContextService = .shared
  ) {
    self.selectionAccess = selectionAccess
    self.selectionContext = selectionContext
    self.cloudSettings = cloudSettings
    self.modelAdvisor = modelAdvisor
    self.searchSettings = searchSettings
    self.screenSettings = screenSettings
    self.welcomeSetup = welcomeSetup
    self.whatsNew = whatsNew
    self.appearance = appearance
    self.startPreferences = startPreferences
    _shell = State(initialValue: ShellPresentation(mode: startPreferences.mode, showsSidebar: startPreferences.showsSidebar))
    _character = State(initialValue: character ?? EnigmaCharacterController())
    _screen = StateObject(wrappedValue: screen)
    let chat = localChat ?? localEngine.map { LocalChatViewModel(engine: $0, cloudProviders: cloudProviders) } ?? .shared
    _localChat = StateObject(wrappedValue: chat)
    self.files = chat.files
    self.messages = chat.appleMessages
    self.toolPermissions = chat.toolPermissions
    self.selectionEditing = chat.selectionEditingSettings
  }

  /// Notices and cards over the composer, as opaque cards. The compact panel's
  /// details leave out the screenshot that sits under its input, so the
  /// screenshot's consent sheet has one home.
  private func composerAccessories(showsScreenshot: Bool = true) -> some View {
    VStack(alignment: .trailing, spacing: 8) {
      // The empty page shows the status under its greeting instead. The
      // panel has no page, so its details show a problem that kept a question
      // from starting.
      if !isChatEmpty || (shell.isSelectionComposer && routeStatusSummary.kind == .problem) {
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
      if localChat.isTemporaryChat && !shell.isSelectionComposer {
        EnigmaChatNote(CompactPanelHints.temporaryTag, monospaced: true)
          .enigmaTestMarker("Window tag \(CompactPanelHints.temporaryTag)")
      }
      // The selection's chat, in the panel or kept in the window, needs
      // Accessibility to replace the selection.
      if !selectionAccess.isGranted && localChat.isSelectionChat {
        AccessibilityNeededCard(appName: SelectionAccessibilityAccess.appName) { selectionAccess.requestAccess() }
      }
      ForEach(localChat.attachedContexts) { context in
        SelectionContextCard(context: context, isSent: localChat.sentContextIDs.contains(context.id),
                             isBusy: localChat.isBusy || selectionContext.isWorking) {
          localChat.removeContext(id: context.id)
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
      if let request = toolPermissions.pending {
        ToolPermissionCard(request: request) { toolPermissions.answer($0) }
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
    if shell.isSelectionComposer {
      compactPanel
    } else {
      shellLayout
    }
  }

  /// The window's corners. The compact panel draws its own.
  private var windowShape: AnyShape {
    shell.isSelectionComposer ? AnyShape(Rectangle())
      : AnyShape(RoundedRectangle(cornerRadius: EnigmaWindowChrome.cornerRadius, style: .continuous))
  }

  private var welcomeShell: some View {
    windowFrame
    .disabled(welcomeSetup.isPresented || welcomeSetup.tour != nil)
    .accessibilityHidden(welcomeSetup.isPresented)
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
    // The welcome stays inside the window's corners.
    .clipShape(windowShape)
    // One stage for the whole window, so the character can fall from the
    // welcome into the main page.
    .enigmaCharacterStage(character, tracksPointer: false)
    // The tour and open menus draw above the character, so it never covers
    // their rows and buttons or takes their clicks. The tour's scrim stays
    // inside the window's corners.
    .overlayPreferenceValue(WelcomeTourAnchors.self) { anchors in
      ZStack {
        if welcomeSetup.tour != nil {
          WelcomeTourOverlay(setup: welcomeSetup, anchors: anchors,
            availableCommands: SlashCommand.available(hasSearchKey: searchSettings.hasAPIKey))
            .clipShape(windowShape)
            .transition(.opacity)
        }
      }
      // The tour fades in as the welcome fades away under it.
      .animation(reduceMotion ? .easeOut(duration: 0.2) : EnigmaMotion.screenChange.animation,
                 value: welcomeSetup.tour != nil)
    }
    // One menu host for the window, the compact panel, and the welcome,
    // above everything else in them. The window's controls are disabled
    // during the welcome and the tour, which closes their open menus.
    .enigmaMenuHost()
    // The character follows the pointer over the tour and open menus too.
    .enigmaCharacterPointer(character)
    // One theme for the window, its welcome, tour, menus, and character.
    .enigmaTheme(appearance.appearance)
  }

  private var commandObservedShell: some View {
    welcomeShell
    .onPreferenceChange(SelectionComposerHeight.self) { report in
      guard shell.isSelectionComposer, report.height > 0 else { return }
      NotificationCenter.default.post(name: .selectionComposerHeightChanged, object: report)
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionPanelRestored)) { _ in
      shell.leaveSelectionPanel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionPanelSettled)) { _ in
      shell.isSettlingIntoWindow = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectionChatOpenedInWindow)) { _ in
      // The panel's chat is now the window's: the normal layout with the
      // sidebar as a new chat has it, in Recents and written once its first
      // question lands, unless "Keep selection chats private" is on.
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
      // The panel stays while the chat can't switch, as when a request or the
      // file picker is running: its chat isn't left half in the window.
      let leavesPanel = shell.isSelectionComposer
      guard localChat.cycleRecentChat() else { return }
      shell.cycleRecentChat()
      if leavesPanel { NotificationCenter.default.post(name: .selectionPanelResetRequested, object: nil) }
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
      // A local model with tools loads while the question is typed (F32).
      if !welcomeSetup.isPresented {
        localChat.warmNativeTurn(draft: new, mode: shell.selectedMode, hasScreenshot: screen.attachment != nil)
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
          cloudSettings.useChatGPTModelFromFileMode(handoff.modelID)
          if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = handoff.prompt }
        }
      }))
    .onChange(of: localChat.isBusy) { _, busy in
      // A disabled TextField cannot take focus at first-token acceptance.
      // Restore its editor only after the owning request has finished. The
      // window's editor stays editable during a reply, and keeps focus.
      shell.requestBusyChanged(busy, composerStaysEditable: !shell.isSelectionComposer && composerCanType)
      // Whatever held the chat has let go, such as the file picker: the
      // next queued message can go.
      if !busy { localChat.drainQueue() }
    }
    .onAppear {
      localChat.queuedMessageSender = { message, accepted in sendQueuedMessage(message, onAccepted: accepted) }
    }
    // The sender holds this view, which holds the chat: let go with the view.
    .onDisappear { localChat.queuedMessageSender = nil }
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
    .sheet(isPresented: $shell.isWhatsNewPresented) {
      WhatsNewView(version: whatsNew.newestVersion, notes: whatsNew.notes)
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
    .modifier(EnigmaWindowChrome())
    // The window's minimum height, except while it's the panel or on its way
    // from the panel, which starts smaller.
    .frame(minWidth: 640, minHeight: shell.isSelectionComposer || shell.isSettlingIntoWindow ? 0 : 420)
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
      showsTopBar: EnigmaTopBar.isShown(isSidebarVisible: shell.isSidebarVisible, hasWhatsNew: whatsNew.showsButton),
      availableExamples: examples.count,
      topBar: { topBar },
      header: { style in
        EnigmaMainPageHeader(style: style, greeting: MainPageGreeting.text(at: .now), status: routeStatusSummary,
                             performStatusAction: performRouteAction, mode: $shell.selectedMode,
                             isStatusActionEnabled: !localChat.isBusy)
      },
      conversation: { messageList },
      accessories: { composerAccessories() },
      composer: { docked in composer(docked: docked) },
      examples: { count in
        EnigmaCommandExamples(examples: Array(examples.prefix(count)), isEnabled: composerCanType) { command in
          shell.isComposerFocused = true
          composerInsertion = SlashCommandInsertion(text: command.token + " ")
        }
      })
  }

  private var topBar: EnigmaTopBar {
    let sidebarActions = EnigmaTopBar.SidebarActions(
      show: { shell.isSidebarVisible = true },
      openHelp: { shell.isHelpPresented = true },
      openSettings: openSettings,
      newChat: { NotificationCenter.default.post(name: .newChatRequested, object: nil) })
    // The button fades out as the notes open, or goes at once under Reduce Motion.
    let openWhatsNew: () -> Void = {
      shell.isWhatsNewPresented = true
      withAnimation(reduceMotion ? nil : EnigmaMotion.screenChange.animation) { whatsNew.open() }
    }
    return EnigmaTopBar(sidebarActions: shell.isSidebarVisible ? nil : sidebarActions,
                        whatsNew: whatsNew.showsButton ? (label: whatsNew.accessibilityLabel, open: openWhatsNew) : nil)
  }

  private func composer(docked: Bool) -> some View {
    EnigmaComposer(
      text: composerText, isFocused: composerFocus, isEnabled: composerCanType,
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
      showsQueueButton: !visibleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, canQueue: canQueueDraft,
      inferredCommands: recognizedCommands, dismissInferred: dismissRecognizedCommand)
  }

  /// The selected route's state, for the status line on the main page and above the composer.
  private var routeStatusSummary: ChatRouteStatus {
    let mode = shell.selectedMode
    var context = ChatRouteStatus.Context(mode: mode, state: localChat.state, modelOperation: localChat.modelOperation,
      modelFailure: localChat.modelFailure,
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
      mode: shell.selectedMode, isBusy: localChat.isBusy, isManagingModels: localChat.isManagingModels,
      hasActiveRequest: localChat.activeRequest != nil,
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
    EnigmaCompactPanel(
      opensOverlaysAbove: compactOpensOverlaysAbove,
      hints: CompactPanelHints.hints(isResponding: localChat.activeRequest != nil),
      isTemporary: localChat.isTemporaryChat,
      selection: {
        EnigmaCompactSelectionLine(
          contexts: localChat.attachedContexts,
          isBusy: localChat.isBusy || selectionContext.isWorking,
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
      })
    .animation(reduceMotion ? .easeOut(duration: 0.12) : EnigmaMotion.menu.animation,
               value: shell.isSelectionDetailsPresented)
    .frame(minWidth: 640)
  }

  private var compactComposer: some View {
    EnigmaCompactComposer(
      text: composerText, isFocused: composerFocus, isEnabled: composerIsEnabled,
      availableCommands: availableCommands,
      placeholder: CompactPanelLayout.placeholder(hasSelection: !localChat.attachedContexts.isEmpty),
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

  // MARK: Character

  private var isTypingInComposer: Bool {
    shell.isComposerFocused && composerCanType && !visibleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var mainCharacterState: EnigmaCharacterState {
    let state = localChat.state
    let isPreparing = state == .preparing || state == .refiningSearch || state == .searching
    let isModelTask = localChat.modelOperation != nil
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
      isPanel: shell.isSelectionComposer,
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
    let home = shell.isSelectionComposer ? CompactPanelLayout.inputSlot : MainWindowCharacter.mainSlot
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
    Binding(get: { visibleDraft }, set: {
      // Typing over a sent draft starts a new one: the sent draft's dismissed chips stay with it.
      if isDraftSent { dismissedInferences = [] }
      screen.draft = $0
    })
  }

  /// The field's draft was just sent and its message waits to be accepted.
  /// Anything typed since replaces it, and stays once the message is accepted.
  private var isDraftSent: Bool {
    guard let sentDraft, let pending = localChat.pendingUserMessage else { return false }
    return pending.id == sentDraft.messageID && sentDraft.text == screen.draft
  }

  /// The draft the field shows: blank for one already sent.
  private var visibleDraft: String { isDraftSent ? "" : draft }

  /// Remembers a draft just sent while its message waits to be accepted.
  private func rememberSentDraft(_ text: String) {
    sentDraft = localChat.pendingUserMessage.map { (text, $0.id) }
  }

  private var composerFocus: Binding<Bool> {
    Binding(get: { shell.isComposerFocused && !welcomeSetup.isPresented && welcomeSetup.tour == nil },
            set: { shell.isComposerFocused = $0 })
  }

  /// Whether the compact panel's field takes input. A panel send moves to the
  /// window as soon as its request starts, so there's no queue there.
  private var composerIsEnabled: Bool {
    !(localChat.isBusy || screen.isBusy || files.isWorking || files.isPicking)
      && !welcomeSetup.isPresented && welcomeSetup.tour == nil
  }

  /// Whether the window's field takes typing: during a reply too, including
  /// a File Mode run, so the next message can be queued. A capture, the file
  /// picker, and a model install, delete or performance check still block it.
  private var composerCanType: Bool {
    !(screen.isBusy || files.isPicking || localChat.modelOperation?.blocksChat == true)
      && !welcomeSetup.isPresented && welcomeSetup.tour == nil
  }

  /// Send and Return queue the draft instead of sending it: a reply is
  /// running, or queued messages are on their way. Never in the compact panel.
  private var queuesDraft: Bool {
    !shell.isSelectionComposer
      && (localChat.activeRequest != nil || (!localChat.messageQueue.isEmpty && !localChat.messageQueue.isHeld))
  }

  /// A draft with a screenshot or files stays in the field with them: only text is queued.
  private var canQueueDraft: Bool {
    queuesDraft && composerCanType
      && ComposerSubmission.canQueue(visibleDraft, in: localChat.messageQueue,
                                     hasAttachments: screen.attachment != nil || files.selection != nil)
  }

  private var availableCommands: [SlashCommand] { SlashCommand.available(hasSearchKey: searchSettings.hasAPIKey) }

  /// Send is available for a draft the selected route can take.
  private var canSendDraft: Bool {
    !(!canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || screen.isBusy || files.isWorking || files.isPicking)
  }

  /// Nothing has been sent in this chat, and nothing is on its way or
  /// queued: a held queue keeps the chat, and its rows, in view.
  private var isChatEmpty: Bool {
    localChat.presentationMessages.isEmpty && localChat.activeRequest == nil && localChat.messageQueue.isEmpty
  }

  /// What keeps a reader at the bottom following the chat, for both lists.
  private var conversationScrollRevision: String {
    (localChat.presentationMessages.last?.content ?? "") + String(localChat.presentationMessages.count)
      + (localChat.activity?.status ?? "") + String(shell.expandedActivities.count)
      + String(localChat.messageQueue.messages.count)
  }

  /// The latest message the person sent, for both lists: a new one brings the end into view.
  private var conversationSendRevision: String {
    localChat.presentationMessages.last { $0.role == .user }?.id.uuidString ?? ""
  }

  /// The chat, with a new identity for each chat so it opens at its own end.
  private var messageList: some View {
    EnigmaMessageList(transcript: conversationTranscript, scrollRevision: conversationScrollRevision,
                      sendRevision: conversationSendRevision,
                      activityExpansion: activityExpansion,
                      queued: localChat.messageQueue.messages,
                      sendQueuedNow: { localChat.sendQueuedMessageNow(id: $0) },
                      cancelQueued: { localChat.cancelQueuedMessage(id: $0) },
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

  /// After a send from the selection panel. A question whose request started
  /// moves its chat to the window's own layout before any reply, as ⌘O does:
  /// into Recents, or kept temporary when "Keep selection chats private" is
  /// on. A send that started none stays in the panel, and opens its details
  /// on whatever stopped it, every time, so a repeated send never looks like
  /// it did nothing. One waiting on a consent dialog leaves them to it.
  private func finishSendFromPanel() {
    guard shell.isSelectionComposer else { return }
    if localChat.activeRequest != nil {
      NotificationCenter.default.post(name: .selectionChatOpenInWindowRequested, object: nil)
      return
    }
    guard screenUploadConsent == nil, messages.cloudDisclosure == nil else { return }
    var failed = false
    if case .failed = localChat.state { failed = true }
    if failed || localChat.autoRouteDecision?.limitation != nil || screen.error != nil || files.error != nil
        || messages.issue != nil {
      shell.revealSelectionProblem()
    }
  }

  /// What the composer's chips and Send both resolve, so they agree.
  private var composerIntentContext: ComposerIntent.Context {
    intentContext(draft: draft, hasFileSelection: files.selection != nil, hasScreenshot: screen.isEnabled,
                  dismissed: dismissedInferences)
  }

  private func intentContext(draft: String, hasFileSelection: Bool, hasScreenshot: Bool,
                             dismissed: Set<SlashCommand>) -> ComposerIntent.Context {
    var context = ComposerIntent.Context(
      draft: draft, hasSelection: localChat.attachedContexts.contains { $0.kind == .selectedText },
      hasFileSelection: hasFileSelection, hasScreenshot: hasScreenshot,
      previousTurnUsedMessages: localChat.previousTurnUsedMessages, infersCommands: infersCommands,
      searchesAutomatically: searchSettings.canSearchAutomatically, dismissed: dismissed)
    context.nativeTools = composerChoosesTools
    return context
  }

  /// The selected mode's model chooses its own tools (F32), so the composer recognizes nothing.
  private var composerChoosesTools: Bool {
    localChat.nativeToolsEnabled && NativeTools.isCapable(mode: shell.selectedMode, localModel: localChat.installedModel,
      cloudProvider: cloudSettings.preferredProvider, cloudModelID: cloudSettings.preferredModelID)
  }

  /// The route a chat or Messages send takes through `submitNative`, or nil for today's path.
  private func nativeRoute(for submission: ComposerSubmission) -> Route? {
    ComposerSubmission.nativeRoute(for: submission, mode: shell.selectedMode, nativeToolsEnabled: localChat.nativeToolsEnabled,
      localModel: localChat.installedModel, cloudProvider: cloudSettings.preferredProvider,
      cloudModelID: cloudSettings.preferredModelID)
  }

  private var composerIntent: ComposerIntent { composerIntent(recognizesCommands: true) }

  /// `recognizesCommands` is false for the request a typed `/screen` or `/snapshot`
  /// sends after its capture: captures run only their typed commands.
  private func composerIntent(recognizesCommands: Bool) -> ComposerIntent {
    ComposerIntent.resolve(composerIntentContext.recognizingCommands(recognizesCommands))
  }

  /// The chips for the draft the field shows; none while it shows blank for a sent message.
  private var recognizedCommands: [SlashCommand] {
    isDraftSent ? [] : composerIntent.inferred
  }

  private func dismissRecognizedCommand(_ command: SlashCommand) {
    dismissedInferences.insert(command)
    shell.isComposerFocused = true
  }

  private func submitDraft(recognizesCommands: Bool = true) {
    guard !welcomeSetup.isPresented, welcomeSetup.tour == nil else { return }
    if queuesDraft {
      guard canQueueDraft, localChat.queueMessage(visibleDraft, dismissed: dismissedInferences) else { return }
      draft = ""
      return
    }
    guard !localChat.isBusy, !screen.isBusy, !files.isWorking, !files.isPicking else { return }
    // A typed /screen captures first; the send that follows the capture
    // finishes it, so an earlier problem doesn't reopen the details meanwhile.
    var finishesSend = true
    defer { if finishesSend { finishSendFromPanel() } }
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
          draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
        }
    case .messagesConflict:
      messages.report(ComposerSubmission.messagesConflictMessage)
    case .nothingToFind:
      messages.report(ComposerSubmission.nothingToFindMessage)
    case .mapsConflict:
      messages.report(ComposerSubmission.mapsConflictMessage)
    case .messages(let prompt):
      submitMessages(prompt)
    case .captureScreen:
      finishesSend = false
      Task {
        let automaticPrompt = await screen.capture(submittedCommand: true)
        shell.isComposerFocused = true
        if automaticPrompt != nil { submitDraft(recognizesCommands: false) }
      }
    case .screenAttachment:
      if let attachment = screen.attachment { submitScreenAttachment(attachment, recognizesCommands: recognizesCommands) }
    case .chat(let prompt, let searchEnabled):
      submitChat(prompt, searchEnabled: searchEnabled) {
        draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
      }
      rememberSentDraft(originalDraft)
    }
  }

  /// Sends a chat message on the selected route. The resolved draft already
  /// decided search, including a dismissed search chip.
  private func submitChat(_ prompt: String, searchEnabled: Bool, onAccepted accepted: @escaping @MainActor () -> Void) {
    if let route = nativeRoute(for: .chat(prompt: prompt, searchEnabled: searchEnabled)) {
      let typed = ComposerCommands((searchEnabled ? "/search " : "") + prompt)
      localChat.submitNative(prompt, route: route, plan: localChat.nativeToolPlan(for: typed), onAccepted: accepted)
      return
    }
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

  /// Sends a queued message as Send would have sent it as a draft, on the
  /// route selected now: its commands resolve now, and it never takes a
  /// screenshot or files, which belong to the field's draft. Anything that
  /// starts no request leaves it to the queue, which puts it back in front
  /// and waits.
  private func sendQueuedMessage(_ message: QueuedMessage, onAccepted: @escaping @MainActor () -> Void) {
    guard !welcomeSetup.isPresented, welcomeSetup.tour == nil, !screen.isBusy, !files.isPicking else { return }
    let intent = ComposerIntent.resolve(intentContext(draft: message.text, hasFileSelection: false, hasScreenshot: false,
                                                      dismissed: message.dismissed))
    switch ComposerSubmission.plan(intent, hasFileSelection: false, hasScreenshot: false, canSubmit: canSubmit) {
    case .none, .captureScreen, .screenAttachment, .fileConflict, .files, .nothingToFind, .mapsConflict:
      return
    case .messagesConflict:
      messages.report(ComposerSubmission.messagesConflictMessage)
    case .messages(let prompt):
      if let route = nativeRoute(for: .messages(prompt: prompt)) {
        localChat.submitNative(prompt, route: route, plan: localChat.nativeToolPlan(for: ComposerCommands("/messages " + prompt)),
                               onAccepted: onAccepted)
        return
      }
      // The one-time cloud disclosure is answered from the field, never for a message sent unseen.
      if ComposerSubmission.asksMessagesCloudNotice(mode: shell.selectedMode, nativeRoute: nil,
                                                    hasDisclosed: messages.hasDisclosed(cloudSettings.preferredProvider)) {
        messages.report(ComposerSubmission.queuedMessagesDisclosureMessage)
        return
      }
      localChat.submitMessages(prompt, mode: shell.selectedMode, cloudProvider: cloudSettings.preferredProvider,
                               cloudModelID: cloudSettings.preferredModelID, onAccepted: onAccepted)
    case .chat(let prompt, let searchEnabled):
      submitChat(prompt, searchEnabled: searchEnabled, onAccepted: onAccepted)
    }
  }

  private func submitMessages(_ prompt: String) {
    defer { finishSendFromPanel() }
    let originalDraft = draft
    let route = nativeRoute(for: .messages(prompt: prompt))
    if ComposerSubmission.asksMessagesCloudNotice(mode: shell.selectedMode, nativeRoute: route,
                                                  hasDisclosed: messages.hasDisclosed(cloudSettings.preferredProvider)) {
      messages.requestDisclosure(for: cloudSettings.preferredProvider, prompt: prompt)
      return
    }
    if let route {
      // The permission card asks before any chat is read, so the one-time notice isn't needed.
      localChat.submitNative(prompt, route: route, plan: localChat.nativeToolPlan(for: ComposerCommands("/messages " + prompt))) {
        draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
      }
      return
    }
    localChat.submitMessages(prompt, mode: shell.selectedMode, cloudProvider: cloudSettings.preferredProvider,
      cloudModelID: cloudSettings.preferredModelID) {
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
      // Auto keeps a chat holding message text on this Mac, as submitAuto does.
      autoRoute: automatic?.route.flatMap { localChat.messageTextMayGo(to: $0) ? $0 : nil },
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
          draft = ComposerSubmission.draftAfterAcceptance(current: draft, sent: originalDraft)
          if screen.attachment?.id == attachment.id { screen.removeAttachment() }
          shell.isComposerFocused = true
        }
      rememberSentDraft(originalDraft)
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
