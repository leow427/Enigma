import XCTest
@testable import Enigma

final class ShellPresentationTests: XCTestCase {
  func testStartsFromSavedPreferences() {
    let shell = ShellPresentation(mode: .local, showsSidebar: true)
    XCTAssertEqual(shell.selectedMode, .local)
    XCTAssertTrue(shell.isSidebarVisible)
    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isComposerFocused)
  }

  func testSelectionComposerHidesSidebarAndClosesOverlays() {
    var shell = ShellPresentation(mode: .cloud, showsSidebar: true)
    shell.isModePalettePresented = true
    shell.isHelpPresented = true
    shell.isSelectionDetailsPresented = true

    shell.beginSelectionComposer(mode: .local, showsSidebar: true)

    XCTAssertTrue(shell.isSelectionComposer)
    XCTAssertTrue(shell.isSelectionPresentation)
    XCTAssertFalse(shell.isSelectionDetailsPresented)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertFalse(shell.isHelpPresented)
    XCTAssertFalse(shell.isSidebarVisible)
    XCTAssertEqual(shell.selectedMode, .local)
    XCTAssertTrue(shell.isComposerFocused)
  }

  func testNewChatLeavesSelectionPanelAndRestoresPreferences() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.isModePalettePresented = true
    shell.isHelpPresented = true

    shell.isSelectionDetailsPresented = true
    shell.startNewChat(mode: .cloud, showsSidebar: true)

    XCTAssertTrue(shell.isSelectionDetailsPresented, "New chat leaves the details popover alone")
    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionPresentation)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertTrue(shell.isHelpPresented, "New chat doesn't close Help")
    XCTAssertEqual(shell.selectedMode, .cloud)
    XCTAssertTrue(shell.isSidebarVisible)
    XCTAssertTrue(shell.isComposerFocused)
  }

  func testExpandingTheSelectionPanelKeepsItsWindowSizing() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.isSelectionDetailsPresented = true

    shell.leaveSelectionComposer()

    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionDetailsPresented)
    XCTAssertTrue(shell.isSelectionPresentation)
  }

  func testCyclingRecentChatsLeavesTheSelectionPanel() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.isSelectionDetailsPresented = true
    let before = shell

    shell.cycleRecentChat()

    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionPresentation)
    XCTAssertTrue(shell.isSelectionDetailsPresented)
    XCTAssertEqual(shell.selectedMode, before.selectedMode)
    XCTAssertEqual(shell.isComposerFocused, before.isComposerFocused)
  }

  func testSavedChatReplacingTheSelectionPanelResetsIt() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    XCTAssertFalse(shell.sessionChanged(isTemporaryChat: false), "No panel to reset")

    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    XCTAssertFalse(shell.sessionChanged(isTemporaryChat: true), "Still the panel's own temporary chat")
    XCTAssertTrue(shell.isSelectionComposer)

    XCTAssertTrue(shell.sessionChanged(isTemporaryChat: false))
    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionPresentation)
  }

  func testExpandedSelectionPanelStillResetsWhenASavedChatOpens() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.leaveSelectionComposer()

    XCTAssertFalse(shell.sessionChanged(isTemporaryChat: true))
    XCTAssertTrue(shell.isSelectionPresentation)
    XCTAssertTrue(shell.sessionChanged(isTemporaryChat: false))
    XCTAssertFalse(shell.isSelectionPresentation)
    XCTAssertFalse(shell.sessionChanged(isTemporaryChat: false), "Only resets once")
  }

  /// Opening the panel's chat in the window shows the window's own layout,
  /// with the sidebar as the saved preference has it, on or off.
  func testOpeningTheSelectionChatInTheWindowFollowsTheSidebarPreference() {
    for showsSidebar in [false, true] {
      var shell = ShellPresentation(mode: .auto, showsSidebar: !showsSidebar)
      shell.beginSelectionComposer(mode: .auto, showsSidebar: showsSidebar)
      shell.isSelectionDetailsPresented = true
      shell.isModePalettePresented = true
      XCTAssertTrue(shell.showsCompactPanel)
      shell.openSelectionChatInWindow(showsSidebar: showsSidebar)
      XCTAssertFalse(shell.showsCompactPanel)
      XCTAssertFalse(shell.isSelectionComposer)
      XCTAssertFalse(shell.isSelectionPresentation)
      XCTAssertFalse(shell.isSelectionDetailsPresented)
      XCTAssertFalse(shell.isModePalettePresented)
      XCTAssertEqual(shell.isSidebarVisible, showsSidebar)
      XCTAssertTrue(shell.isComposerFocused)
      XCTAssertFalse(shell.sessionChanged(isTemporaryChat: false), "Nothing left to reset")
    }
  }

  func testProblemsOpenSelectionDetailsOnlyInTheSelectionPanel() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    shell.revealSelectionProblem()
    XCTAssertFalse(shell.isSelectionDetailsPresented)

    shell.beginSelectionComposer(mode: .auto, showsSidebar: true)
    shell.revealSelectionProblem()
    XCTAssertTrue(shell.isSelectionDetailsPresented)
  }

  func testModePaletteChoicesReturnFocusToTheComposer() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    shell.isModePalettePresented = true
    shell.chooseMode(.local)
    XCTAssertEqual(shell.selectedMode, .local)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertTrue(shell.isComposerFocused)

    shell.isModePalettePresented = true
    shell.isComposerFocused = false
    shell.dismissModePalette()
    XCTAssertEqual(shell.selectedMode, .local)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertTrue(shell.isComposerFocused)
  }

  func testOpeningSettingsReleasesComposerFocus() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    shell.isModePalettePresented = true
    shell.isComposerFocused = true
    shell.prepareForSettings()
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertFalse(shell.isComposerFocused)
  }

  func testComposerFocusReturnsWhenARequestEnds() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    shell.requestBusyChanged(true)
    XCTAssertFalse(shell.isComposerFocused)
    shell.requestBusyChanged(false)
    XCTAssertTrue(shell.isComposerFocused)
  }

  func testWelcomeSetupClosesOverlaysAndResetsToAuto() {
    var shell = ShellPresentation(mode: .cloud, showsSidebar: true)
    shell.isModePalettePresented = true
    shell.isHelpPresented = true
    shell.isComposerFocused = true

    shell.welcomeChanged(isPresented: true, isTourActive: false)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertFalse(shell.isHelpPresented)
    XCTAssertFalse(shell.isComposerFocused)
    XCTAssertEqual(shell.selectedMode, .cloud)

    shell.isHelpPresented = true
    shell.welcomeChanged(isPresented: false, isTourActive: true)
    XCTAssertTrue(shell.isHelpPresented, "Closing Welcome leaves Help alone")
    XCTAssertEqual(shell.selectedMode, .auto)
    XCTAssertFalse(shell.isComposerFocused, "The tour still has focus")

    shell.tourChanged(isActive: false, isWelcomePresented: false)
    XCTAssertTrue(shell.isComposerFocused)
    shell.tourChanged(isActive: true, isWelcomePresented: false)
    XCTAssertFalse(shell.isComposerFocused)
  }

  func testActivityExpansionIsTrackedPerActivity() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    let first = UUID()
    let second = UUID()
    shell.setActivity(first, expanded: true)
    XCTAssertTrue(shell.isActivityExpanded(first))
    XCTAssertFalse(shell.isActivityExpanded(second))
    shell.setActivity(first, expanded: false)
    XCTAssertFalse(shell.isActivityExpanded(first))
    XCTAssertTrue(shell.expandedActivities.isEmpty)
  }
}

final class ComposerSubmissionTests: XCTestCase {
  private func plan(_ draft: String, files: Bool = false, screenshot: Bool = false, canSubmit: Bool = true) -> ComposerSubmission {
    ComposerSubmission.plan(
      ComposerSubmission.Context(draft: draft, hasFileSelection: files, hasScreenshot: screenshot), canSubmit: canSubmit)
  }

  func testPlainDraftsBecomeChatMessages() {
    XCTAssertEqual(plan("What changed in macOS 26.1?"), .chat(prompt: "What changed in macOS 26.1?", searchEnabled: false))
    XCTAssertEqual(plan("/search macOS 26.1 date"), .chat(prompt: "macOS 26.1 date", searchEnabled: true))
  }

  func testNothingIsSentWithoutAPromptOrAReadyModel() {
    XCTAssertEqual(plan(""), .none)
    XCTAssertEqual(plan("   "), .none)
    XCTAssertEqual(plan("/search"), .none)
    XCTAssertEqual(plan("Hello", canSubmit: false), .none)
  }

  func testReadinessIsCheckedOnlyForPlainChat() {
    var checks = 0
    func ready() -> Bool { checks += 1; return false }
    let cases: [(String, Bool, Bool)] = [
      ("Summarize", true, false), ("/messages Sam", false, false), ("/screen why", false, false), ("Explain", false, true),
    ]
    for (draft, files, screenshot) in cases {
      _ = ComposerSubmission.plan(
        ComposerSubmission.Context(draft: draft, hasFileSelection: files, hasScreenshot: screenshot), canSubmit: ready())
    }
    XCTAssertEqual(checks, 0)
    _ = ComposerSubmission.plan(ComposerSubmission.Context(draft: "Hello"), canSubmit: ready())
    XCTAssertEqual(checks, 1)
  }

  func testAttachedFilesSendTheDraftExactlyAsTyped() {
    XCTAssertEqual(plan("  Summarize these\n", files: true, canSubmit: false), .files(prompt: "  Summarize these\n"))
    XCTAssertEqual(plan("", files: true), .files(prompt: ""))
  }

  func testAttachedFilesRejectScreenSearchAndMessages() {
    XCTAssertEqual(plan("/search notes", files: true), .fileConflict)
    XCTAssertEqual(plan("/screen what's this", files: true), .fileConflict)
    XCTAssertEqual(plan("/messages from Sam", files: true), .fileConflict)
    XCTAssertEqual(plan("Summarize", files: true, screenshot: true), .fileConflict)
  }

  func testMessagesStaysApartFromScreenAndSearch() {
    XCTAssertEqual(plan("/messages what did Sam say"), .messages(prompt: "what did Sam say"))
    XCTAssertEqual(plan("/messages what did Sam say", canSubmit: false), .messages(prompt: "what did Sam say"))
    XCTAssertEqual(plan("/messages /search Sam"), .messagesConflict)
    XCTAssertEqual(plan("/messages /screen Sam"), .messagesConflict)
    XCTAssertEqual(plan("/messages Sam", screenshot: true), .messagesConflict)
    XCTAssertEqual(plan("/messages"), .none)
  }

  func testScreenCommandsCaptureFirst() {
    XCTAssertEqual(plan("/screen what's failing?"), .captureScreen)
    XCTAssertEqual(plan("/snapshot", canSubmit: false), .captureScreen)
    XCTAssertEqual(plan("/screen retake it", screenshot: true), .captureScreen, "A new capture replaces the old one")
  }

  private func plan(intent draft: String, files: Bool = false, screenshot: Bool = false, selection: Bool = false,
                    automatic: Bool = false, dismissed: Set<SlashCommand> = [], canSubmit: Bool = true) -> ComposerSubmission {
    let intent = ComposerIntent.resolve(.init(draft: draft, hasSelection: selection, hasFileSelection: files,
      hasScreenshot: screenshot, searchesAutomatically: automatic, dismissed: dismissed))
    return ComposerSubmission.plan(intent, hasFileSelection: files, hasScreenshot: screenshot, canSubmit: canSubmit)
  }

  func testRecognizedCommandsSendLikeTypedOnes() {
    XCTAssertEqual(plan(intent: "what did Sam text me"), .messages(prompt: "what did Sam text me"))
    XCTAssertEqual(plan(intent: "what did Sam text me", canSubmit: false), .messages(prompt: "what did Sam text me"))
    XCTAssertEqual(plan(intent: "think hard about this"), .chat(prompt: "/think think hard about this", searchEnabled: false))
    XCTAssertEqual(plan(intent: "make it shorter", selection: true), .chat(prompt: "/edit make it shorter", searchEnabled: false))
    XCTAssertEqual(plan(intent: "translate it to Spanish", selection: true),
                   .chat(prompt: "/translate translate it to Spanish", searchEnabled: false))
    XCTAssertEqual(plan(intent: "What's the latest AI news?", automatic: true),
                   .chat(prompt: "What's the latest AI news?", searchEnabled: true))
  }

  func testDismissedRecognizedSearchStaysOff() {
    XCTAssertEqual(plan(intent: "What's the latest AI news?", automatic: true, dismissed: [.search]),
                   .chat(prompt: "What's the latest AI news?", searchEnabled: false))
    XCTAssertEqual(plan(intent: "what did Sam text me", dismissed: [.messages]),
                   .chat(prompt: "what did Sam text me", searchEnabled: false))
  }

  func testRecognizedMessagesNeverConflicts() {
    XCTAssertEqual(plan(intent: "what did Sam text me", screenshot: true), .screenAttachment)
    XCTAssertEqual(plan(intent: "what did Sam text me", files: true), .files(prompt: "what did Sam text me"))
    XCTAssertEqual(plan(intent: "What's the latest AI news?", files: true, automatic: true),
                   .files(prompt: "What's the latest AI news?"))
    XCTAssertEqual(plan(intent: "/search what did Sam text me"), .chat(prompt: "what did Sam text me", searchEnabled: true))
  }

  func testRecognizedThinkJoinsTheFilesDraft() {
    XCTAssertEqual(plan(intent: "think hard about these", files: true), .files(prompt: "/think think hard about these"))
  }

  func testTypedConflictsStillReportThemselves() {
    XCTAssertEqual(plan(intent: "/messages /search Sam"), .messagesConflict)
    XCTAssertEqual(plan(intent: "/messages Sam", screenshot: true), .messagesConflict)
    XCTAssertEqual(plan(intent: "/messages from Sam", files: true), .fileConflict)
    XCTAssertEqual(plan(intent: "/screen what did Sam text me"), .captureScreen)
  }

  func testAttachedScreenshotIsSentWithoutOtherChecks() {
    XCTAssertEqual(plan("Explain this", screenshot: true), .screenAttachment)
    // The screenshot path applies its own prompt and routing checks.
    XCTAssertEqual(plan("", screenshot: true, canSubmit: false), .screenAttachment)
  }

  func testCanSubmitNeedsAReadyModelForTheMode() {
    func check(_ mode: ChatMode, local: Bool = false, cloud: Bool = false, autoCloud: Bool = false, busy: Bool = false) -> Bool {
      ComposerSubmission.canSubmit(mode: mode, hasLocalModel: local, isCloudConfigured: cloud, hasAutoCloud: autoCloud, isBusy: busy)
    }
    XCTAssertTrue(check(.local, local: true))
    XCTAssertFalse(check(.local, cloud: true, autoCloud: true))
    XCTAssertTrue(check(.cloud, cloud: true))
    XCTAssertFalse(check(.cloud, local: true))
    XCTAssertTrue(check(.auto, local: true))
    XCTAssertTrue(check(.auto, autoCloud: true))
    XCTAssertFalse(check(.auto, cloud: true), "Auto needs a cloud model it can route to")
    XCTAssertFalse(check(.local, local: true, busy: true))
    XCTAssertFalse(check(.auto, local: true, autoCloud: true, busy: true))
  }

  func testCanSubmitSkipsCloudChecksTheModeDoesNotNeed() {
    var cloudChecks = 0
    func cloud() -> Bool { cloudChecks += 1; return true }
    _ = ComposerSubmission.canSubmit(mode: .local, hasLocalModel: true, isCloudConfigured: cloud(), hasAutoCloud: cloud(), isBusy: false)
    _ = ComposerSubmission.canSubmit(mode: .auto, hasLocalModel: true, isCloudConfigured: cloud(), hasAutoCloud: cloud(), isBusy: false)
    _ = ComposerSubmission.canSubmit(mode: .cloud, hasLocalModel: false, isCloudConfigured: cloud(), hasAutoCloud: cloud(), isBusy: true)
    XCTAssertEqual(cloudChecks, 0)
    _ = ComposerSubmission.canSubmit(mode: .cloud, hasLocalModel: false, isCloudConfigured: cloud(), hasAutoCloud: cloud(), isBusy: false)
    XCTAssertEqual(cloudChecks, 1)
  }
}

final class ChatHistoryListTests: XCTestCase {
  func testEmptyHistoryShowsASelectedNewChatRow() {
    XCTAssertEqual(ChatHistoryList.rows(sessions: [], selectedSessionID: nil),
                   [ChatHistoryRow(target: .newChat, title: "New Chat", date: nil, isSelected: true)])
  }

  func testShowsEveryRetainedSessionInOrder() {
    XCTAssertEqual(ChatHistoryList.visibleCount, ChatSessionStore.maximumRetainedSessions)
    XCTAssertEqual(ChatHistoryList.visibleCount, 10)
    let sessions = (0..<12).map { ChatSession(title: "Chat \($0)") }
    let rows = ChatHistoryList.rows(sessions: sessions, selectedSessionID: sessions[2].id)
    XCTAssertEqual(rows.map(\.title), (0..<10).map { "Chat \($0)" })
    XCTAssertEqual(rows.map(\.isSelected), (0..<10).map { $0 == 2 })
    XCTAssertEqual(rows.map(\.target), sessions.prefix(10).map { ChatHistoryRow.Target.session($0.id) })
  }

  func testOnlyChatsWithMessagesShowADate() {
    let activity = Date(timeIntervalSince1970: 1_800_000_000)
    let used = ChatSession(title: "Release notes", messages: [ChatMessage(role: .user, content: "Hi")], lastActivityAt: activity)
    let fresh = ChatSession()
    let rows = ChatHistoryList.rows(sessions: [used, fresh], selectedSessionID: nil)
    XCTAssertEqual(rows[0].date, activity)
    XCTAssertNil(rows[1].date)
    XCTAssertFalse(rows.contains(where: \.isSelected))
  }
}
