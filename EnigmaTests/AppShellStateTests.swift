import AppKit
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
    shell.isWhatsNewPresented = true
    shell.isSelectionDetailsPresented = true

    shell.beginSelectionComposer(mode: .local, showsSidebar: true)

    XCTAssertTrue(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionDetailsPresented)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertFalse(shell.isHelpPresented)
    XCTAssertFalse(shell.isWhatsNewPresented, "The panel is too small for the release notes")
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
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertTrue(shell.isHelpPresented, "New chat doesn't close Help")
    XCTAssertEqual(shell.selectedMode, .cloud)
    XCTAssertTrue(shell.isSidebarVisible)
    XCTAssertTrue(shell.isComposerFocused)
  }

  /// The panel went back to the window's normal frame without opening its
  /// chat there: the window's own layout, with the details closed.
  func testRestoringTheNormalPanelLeavesTheSelectionPanel() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.isSelectionDetailsPresented = true

    shell.leaveSelectionPanel()

    XCTAssertFalse(shell.isSelectionComposer)
    XCTAssertFalse(shell.isSelectionDetailsPresented)
    XCTAssertFalse(shell.sessionChanged(isTemporaryChat: false), "Nothing left to reset")
  }

  func testCyclingRecentChatsLeavesTheSelectionPanel() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: false)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: false)
    shell.isSelectionDetailsPresented = true
    let before = shell

    shell.cycleRecentChat()

    XCTAssertFalse(shell.isSelectionComposer)
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
      XCTAssertTrue(shell.isSelectionComposer)
      shell.openSelectionChatInWindow(showsSidebar: showsSidebar)
      XCTAssertFalse(shell.isSelectionComposer)
      XCTAssertTrue(shell.isSettlingIntoWindow, "Until the window reaches its normal frame")
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

  func testComposerKeepsFocusDuringAReplyItCanQueueFrom() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    shell.isComposerFocused = true
    shell.requestBusyChanged(true, composerStaysEditable: true)
    XCTAssertTrue(shell.isComposerFocused, "Typing goes on while the reply runs")
    shell.isComposerFocused = false
    shell.requestBusyChanged(true, composerStaysEditable: true)
    XCTAssertTrue(shell.isComposerFocused, "Focus returns to the field after clicking Send")
    shell.isComposerFocused = false
    shell.requestBusyChanged(false, composerStaysEditable: true)
    XCTAssertTrue(shell.isComposerFocused, "It returns once the reply ends")
    shell.requestBusyChanged(true, composerStaysEditable: false)
    XCTAssertFalse(shell.isComposerFocused, "Work that disables the field still takes focus")
  }

  func testWelcomeSetupClosesOverlaysAndResetsToAuto() {
    var shell = ShellPresentation(mode: .cloud, showsSidebar: true)
    shell.isModePalettePresented = true
    shell.isHelpPresented = true
    shell.isWhatsNewPresented = true
    shell.isComposerFocused = true

    shell.welcomeChanged(isPresented: true, isTourActive: false)
    XCTAssertFalse(shell.isModePalettePresented)
    XCTAssertFalse(shell.isHelpPresented)
    XCTAssertFalse(shell.isWhatsNewPresented)
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

  func testAcceptedRequestClearsTheDraftItWasSentFrom() {
    // The sent prompt can differ from the draft, as with a recognized /think in File Mode.
    XCTAssertEqual(ComposerSubmission.draftAfterAcceptance(current: "think hard about these",
                                                           sent: "think hard about these"), "")
    XCTAssertEqual(ComposerSubmission.draftAfterAcceptance(current: "a newer draft", sent: "think hard about these"),
                   "a newer draft", "A draft edited since sending is kept")
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

  func testMapsWinsOverSearch() {
    XCTAssertEqual(plan("/search /maps bookshops"), .chat(prompt: "/maps bookshops", searchEnabled: true))
    XCTAssertEqual(plan("/maps bookshops"), .chat(prompt: "/maps bookshops", searchEnabled: true))
  }

  func testMapsAloneKeepsDraft() {
    XCTAssertEqual(plan("/maps"), .nothingToFind)
    XCTAssertEqual(plan("/maps /search"), .nothingToFind)
    XCTAssertEqual(ComposerSubmission.nothingToFindMessage, "There's nothing to look for.")
  }

  func testMapsConflicts() {
    XCTAssertEqual(plan("/maps bookshops", files: true), .fileConflict)
    XCTAssertEqual(plan("/maps /messages bookshops"), .messagesConflict)
    XCTAssertEqual(plan("/maps bookshops", screenshot: true), .mapsConflict)
    XCTAssertEqual(plan("/maps /screen bookshops"), .mapsConflict)
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

@MainActor
final class ChatReturnTests: XCTestCase {
  private let hidden = Date(timeIntervalSince1970: 1_800_000_000)
  private var used: ChatReturnState { ChatReturnState(lastUsedAt: hidden.addingTimeInterval(-60)) }

  func testPolicyStartsANewChatOnlyAfterMoreThanFiveMinutesAway() {
    XCTAssertEqual(ChatReturnPolicy.awayLimit, 300)
    func starts(after seconds: TimeInterval, hiddenAt: Date? = hidden, _ chat: ChatReturnState? = nil) -> Bool {
      ChatReturnPolicy.startsNewChat(hiddenAt: hiddenAt, now: hidden.addingTimeInterval(seconds), chat: chat ?? used)
    }
    XCTAssertFalse(starts(after: 3_600, hiddenAt: nil), "Never hidden")
    XCTAssertFalse(starts(after: 60))
    XCTAssertFalse(starts(after: 300), "Exactly five minutes comes back to the same chat")
    XCTAssertTrue(starts(after: 301))
    var busy = used
    busy.isBusy = true
    XCTAssertFalse(starts(after: 3_600, busy), "A running reply is never interrupted")
    XCTAssertFalse(starts(after: 3_600, ChatReturnState(lastUsedAt: nil)), "No chat with messages: nothing to leave")
    var unsent = used
    unsent.hasUnsentWork = true
    XCTAssertFalse(starts(after: 3_600, unsent), "Unsent work stays")
    // A reply that finished two minutes after the window was hidden.
    let finished = ChatReturnState(lastUsedAt: hidden.addingTimeInterval(120))
    XCTAssertFalse(starts(after: 360, finished), "Used four minutes ago")
    XCTAssertFalse(starts(after: 420, finished))
    XCTAssertTrue(starts(after: 421, finished))
  }

  func testComingBackWithinFiveMinutesKeepsTheChat() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 300
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
    XCTAssertNil(controller.hiddenAt)
  }

  func testComingBackAfterFiveMinutesStartsANewChatBeforeTheWindowShows() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 301
    let counter = Counter()
    let token = NotificationCenter.default.addObserver(forName: .newChatRequested, object: nil, queue: nil) { _ in
      MainActor.assumeIsolated {
        counter.count += 1
        XCTAssertFalse(controller.isVisible, "The new chat is asked for before the window is ordered front")
      }
    }
    controller.show()
    NotificationCenter.default.removeObserver(token)
    XCTAssertEqual(counter.count, 1)
    XCTAssertTrue(controller.isVisible)
    // Shown again, the time away starts over.
    controller.hide()
    clock.now += 60
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
  }

  func testHidingAgainKeepsTheFirstHiddenTime() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 240
    controller.hide()
    clock.now += 120
    XCTAssertEqual(newChatRequests { controller.show() }, 1)
  }

  func testAVisibleWindowIsNeverAway() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    clock.now += 3_600
    XCTAssertEqual(newChatRequests { controller.show() }, 0, "Left open behind other apps, it keeps its chat")
  }

  func testAReplyThatFinishedWhileHiddenCountsAsUse() {
    let clock = TestClock(hidden)
    let chat = TestChat(used)
    let controller = makeController(clock: clock, chat: chat)
    controller.show()
    controller.hide()
    chat.state.lastUsedAt = hidden.addingTimeInterval(120)
    clock.now += 360
    XCTAssertEqual(newChatRequests { controller.show() }, 0, "Four minutes after the reply landed")
  }

  func testNothingToLeaveOrUnsentWorkKeepsTheChat() {
    let clock = TestClock(hidden)
    let chat = TestChat(ChatReturnState(lastUsedAt: nil))
    let controller = makeController(clock: clock, chat: chat)
    controller.hide()
    clock.now += 3_600
    XCTAssertEqual(newChatRequests { controller.show() }, 0, "No chat, or an empty one")
    chat.state = used
    chat.state.hasUnsentWork = true
    controller.hide()
    clock.now += 3_600
    XCTAssertEqual(newChatRequests { controller.show() }, 0, "A draft, screenshot or files")
  }

  func testABusyChatKeepsItsChatAndItsPanel() {
    let clock = TestClock(hidden)
    var busy = used
    busy.isBusy = true
    let controller = makeController(clock: clock, chat: TestChat(busy))
    presentSelectionPanel(controller)
    controller.hide()
    clock.now += 3_600
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
    XCTAssertTrue(controller.isSelectionComposer, "The compact panel isn't reset either")
  }

  func testANewChatAfterTimeAwayReturnsACompactPanelToTheWindow() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    presentSelectionPanel(controller)
    controller.hide()
    clock.now += 301
    XCTAssertEqual(newChatRequests { controller.show() }, 1)
    XCTAssertFalse(controller.isSelectionComposer)
  }

  func testASelectionSummonIsUnaffectedAndTheRuleAppliesAfterIt() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 3_600
    XCTAssertEqual(newChatRequests { presentSelectionPanel(controller) }, 0, "The selection starts its own chat")
    XCTAssertNil(controller.hiddenAt)
    controller.hide()
    clock.now += 60
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
    controller.hide()
    clock.now += 301
    XCTAssertEqual(newChatRequests { controller.show() }, 1)
  }

  func testAManualReplacementBringingTheWindowBackEndsTheTimeAway() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 3_600
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    NotificationCenter.default.post(name: .selectionReplacementEnded,
                                    object: SelectionReplacementEnd(automatic: false, sent: true))
    XCTAssertTrue(controller.isVisible)
    XCTAssertNil(controller.hiddenAt)
    controller.hide()
    clock.now += 60
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
  }

  func testTheEndOfAScreenCaptureEndsTheTimeAway() {
    let clock = TestClock(hidden)
    let controller = makeController(clock: clock)
    controller.show()
    controller.hide()
    clock.now += 3_600
    NotificationCenter.default.post(name: .screenCaptureBegan, object: nil)
    NotificationCenter.default.post(name: .screenCaptureEnded, object: nil)
    XCTAssertTrue(controller.isVisible)
    XCTAssertNil(controller.hiddenAt)
    controller.hide()
    clock.now += 60
    XCTAssertEqual(newChatRequests { controller.show() }, 0)
  }

  private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  private final class TestChat {
    var state: ChatReturnState
    init(_ state: ChatReturnState) { self.state = state }
  }

  private final class Counter: @unchecked Sendable {
    var count = 0
  }

  private func makeController(clock: TestClock, chat: TestChat? = nil) -> SpotlightPanelController {
    let defaults = UserDefaults(suiteName: "ChatReturnTests-\(UUID().uuidString)")!
    let chat = chat ?? TestChat(used)
    let controller = SpotlightPanelController(sizeStore: PanelSizeStore(defaults: defaults), contentView: NSView(),
      reduceMotion: { true }, visibleFrame: { _ in NSRect(x: 0, y: 0, width: 1440, height: 900) },
      now: { clock.now }, chatState: { chat.state })
    addTeardownBlock { @MainActor in controller.hide() }
    return controller
  }

  private func presentSelectionPanel(_ controller: SpotlightPanelController) {
    controller.presentSelectionContext(nil, cursor: NSPoint(x: 400, y: 400), selection: nil,
                                       visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
    XCTAssertTrue(controller.isSelectionComposer)
  }

  /// How many new chats `body` asks for.
  private func newChatRequests(_ body: () -> Void) -> Int {
    let counter = Counter()
    let token = NotificationCenter.default.addObserver(forName: .newChatRequested, object: nil, queue: nil) { _ in
      counter.count += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body()
    return counter.count
  }
}

// F32 CP4: which function a send calls on flagged and unflagged routes.
extension ComposerSubmissionTests {
  private static let flagged = LocalModel(id: "gemma", displayName: "Gemma", fileURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
    catalogDescriptor: BundledLocalModels.models.first { $0.inferenceProfile == .gemma4_12B })
  private static let unflagged = LocalModel(id: "qwen", displayName: "Qwen", fileURL: URL(fileURLWithPath: "/tmp/qwen.gguf"),
    catalogDescriptor: BundledLocalModels.models.first { $0.inferenceProfile == .qwen35_2B })

  private func nativeRoute(_ submission: ComposerSubmission, mode: ChatMode, enabled: Bool = true,
                           local: LocalModel? = flagged, provider: CloudProviderID = .anthropic,
                           model: String = "claude-sonnet-4-6") -> Route? {
    ComposerSubmission.nativeRoute(for: submission, mode: mode, nativeToolsEnabled: enabled, localModel: local,
                                   cloudProvider: provider, cloudModelID: model)
  }

  func testFlaggedRoutesGoToSubmitNative() {
    let chat = ComposerSubmission.chat(prompt: "hi", searchEnabled: false)
    let messages = ComposerSubmission.messages(prompt: "who texted?")
    // Local with a flagged model.
    XCTAssertEqual(nativeRoute(chat, mode: .local), Route(mode: .local, providerID: "local", modelID: "gemma", usesNetwork: false))
    XCTAssertEqual(nativeRoute(messages, mode: .local)?.mode, .local)
    XCTAssertNil(nativeRoute(chat, mode: .local, local: Self.unflagged), "An unflagged model keeps today's submit")
    XCTAssertNil(nativeRoute(chat, mode: .local, local: nil))
    // Cloud.
    XCTAssertEqual(nativeRoute(chat, mode: .cloud), Route(mode: .cloud, providerID: "anthropic",
                                                         modelID: "claude-sonnet-4-6", usesNetwork: true))
    XCTAssertEqual(nativeRoute(messages, mode: .cloud)?.mode, .cloud)
    XCTAssertNil(nativeRoute(chat, mode: .cloud, model: " "))
    XCTAssertNil(nativeRoute(chat, mode: .cloud, provider: .openAI, model: "an-unreviewed-model"))
    // Auto: chat goes to submitAuto, which picks either route; /messages stays on the local model.
    XCTAssertNil(nativeRoute(chat, mode: .auto))
    XCTAssertEqual(nativeRoute(messages, mode: .auto)?.mode, .local)
    XCTAssertNil(nativeRoute(messages, mode: .auto, local: Self.unflagged), "Today's local /messages")
    // Files and screen captures keep today's paths.
    for other in [ComposerSubmission.files(prompt: "hi"), .captureScreen, .screenAttachment, .none, .fileConflict, .messagesConflict] {
      for mode in [ChatMode.local, .cloud, .auto] { XCTAssertNil(nativeRoute(other, mode: mode), "\(other) \(mode)") }
    }
  }

  func testSwitchOffKeepsTodaysRouting() {
    for submission in [ComposerSubmission.chat(prompt: "hi", searchEnabled: true), .messages(prompt: "hi")] {
      for mode in [ChatMode.local, .cloud, .auto] {
        XCTAssertNil(nativeRoute(submission, mode: mode, enabled: false), "\(submission) \(mode)")
      }
    }
    XCTAssertTrue(ComposerSubmission.asksMessagesCloudNotice(mode: .cloud, nativeRoute: nil, hasDisclosed: false))
  }

  func testCloudMessagesNoticeSkippedOnFlaggedRoutes() {
    let route = nativeRoute(.messages(prompt: "who texted?"), mode: .cloud)
    XCTAssertNotNil(route)
    XCTAssertFalse(ComposerSubmission.asksMessagesCloudNotice(mode: .cloud, nativeRoute: route, hasDisclosed: false),
                   "The per-chat permission card replaces the one-time notice")
    XCTAssertTrue(ComposerSubmission.asksMessagesCloudNotice(mode: .cloud, nativeRoute: nil, hasDisclosed: false))
    XCTAssertFalse(ComposerSubmission.asksMessagesCloudNotice(mode: .cloud, nativeRoute: nil, hasDisclosed: true))
    XCTAssertFalse(ComposerSubmission.asksMessagesCloudNotice(mode: .local, nativeRoute: nil, hasDisclosed: false))
  }

  func testChipsFollowTheRoutesFlag() {
    func chips(_ mode: ChatMode, local: LocalModel?, provider: CloudProviderID = .anthropic, model: String = "claude-sonnet-4-6") -> Bool {
      NativeTools.isCapable(mode: mode, localModel: local, cloudProvider: provider, cloudModelID: model)
    }
    XCTAssertTrue(chips(.local, local: Self.flagged))
    XCTAssertFalse(chips(.local, local: Self.unflagged))
    XCTAssertTrue(chips(.cloud, local: Self.unflagged))
    XCTAssertFalse(chips(.cloud, local: Self.flagged, provider: .openAI, model: "an-unreviewed-model"))
    XCTAssertTrue(chips(.auto, local: Self.flagged, provider: .openAI, model: "an-unreviewed-model"), "Auto starts local")
    XCTAssertFalse(chips(.auto, local: Self.unflagged))
    XCTAssertFalse(chips(.auto, local: nil))
  }
}
