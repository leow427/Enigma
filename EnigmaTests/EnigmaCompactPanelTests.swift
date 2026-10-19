import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// The compact selection panel: its logic, the panel's sizes as it opens and
/// grows, and the selection flows, hosted in the real panel controller.
/// Hosted tests use the main window's isolated fixture, never the installed
/// app's settings.
final class EnigmaCompactPanelTests: XCTestCase {
  private typealias Fixture = EnigmaMainWindowTests.Fixture
  private typealias Host = EnigmaMainWindowTests.Host

  // MARK: Logic

  func testRouteChipNamesTheModeThenWhereAutoRunsOrTheModel() {
    XCTAssertEqual(CompactRouteChip.text(mode: .auto, route: .local, modelName: nil), "auto · local")
    XCTAssertEqual(CompactRouteChip.text(mode: .auto, route: .cloud, modelName: nil), "auto · cloud")
    XCTAssertEqual(CompactRouteChip.text(mode: .auto, route: nil, modelName: nil), "auto")
    XCTAssertEqual(CompactRouteChip.text(mode: .local, route: .local, modelName: "Qwen3 8B"), "local · Qwen3 8B")
    XCTAssertEqual(CompactRouteChip.text(mode: .local, route: .local, modelName: nil), "local · choose model")
    XCTAssertEqual(CompactRouteChip.text(mode: .cloud, route: .cloud, modelName: "gpt-5"), "cloud · gpt-5")
  }

  func testPlaceholderFollowsTheSelection() {
    XCTAssertEqual(CompactPanelLayout.placeholder(hasSelection: true), "Ask about the selection")
    XCTAssertEqual(CompactPanelLayout.placeholder(hasSelection: false), "Ask anything")
    XCTAssertEqual(CompactPanelLayout.inputSlotSize, 40)
    XCTAssertEqual(ConversationTranscript.slotSize, 30, "Replies keep their 30 pt slot in the panel")
  }

  /// Every hint names a shortcut the panel handles today.
  @MainActor
  func testHintsNameOnlyShortcutsThatWork() {
    XCTAssertEqual(CompactPanelHints.hints(isResponding: false).map(\.text), ["/ commands", "⌘O open in window", "esc close"])
    XCTAssertEqual(CompactPanelHints.hints(isResponding: true).map(\.text), ["⌘. stop", "⌘O open in window", "esc close"])
    // Key glyphs are drawn in the system font, as the welcome's command lines draw them.
    XCTAssertEqual(EnigmaCommandLine.runs("⌘O open in window").map(\.text), ["⌘", "O open in window"])
    XCTAssertEqual(EnigmaCommandLine.runs("⌘O open in window").map(\.isSymbol), [true, false])
    XCTAssertEqual(EnigmaCommandLine.runs("⌘. stop").map(\.isSymbol), [true, false])
    let panelKeys = Set(KeyboardShortcutsHelp.panel.map(\.keys))
    XCTAssertTrue(panelKeys.contains("Esc"))
    XCTAssertTrue(panelKeys.contains("⌘ O"), "⌘O opens the panel's chat in the window")
    XCTAssertTrue(panelKeys.contains("⌘ ."))
    XCTAssertEqual(PanelShortcut.resolve(characters: ".", modifiers: .command), .stopStreaming)
    XCTAssertEqual(PanelShortcut.resolve(characters: "o", modifiers: .command), .openInWindow)
    XCTAssertFalse(SlashCommand.available(hasSearchKey: false).isEmpty, "/ opens the commands")
  }

  func testCharacterShowsTheSelectionProblemOnlyWhenItCantBeReadOrPermissionIsMissing() {
    func problem(panel: Bool = true, composing: Bool = true, selection: Bool = false, notice: String? = "Unreadable",
                 granted: Bool = true, temporary: Bool = true) -> Bool {
      CompactPanelCharacter.hasSelectionProblem(isPanel: panel, isComposing: composing, hasSelection: selection,
                                                notice: notice, isAccessibilityGranted: granted,
                                                isTemporaryChat: temporary)
    }
    XCTAssertTrue(problem(), "No selection could be read")
    XCTAssertFalse(problem(notice: nil), "Nothing selected, with nothing wrong")
    XCTAssertFalse(problem(selection: true), "A notice beside an attached selection, like Replacement sent, is news")
    XCTAssertFalse(problem(composing: false), "Once grown, a notice isn't the selection's problem")
    XCTAssertTrue(problem(composing: false, selection: true, notice: nil, granted: false), "Accessibility is missing")
    XCTAssertFalse(problem(panel: false, granted: false), "Only in the compact panel")
    XCTAssertFalse(problem(granted: false, temporary: false), "Only in its temporary chat")
    XCTAssertTrue(CompactPanelCharacter.statusNeedsAttention(notice: "Replacement sent", isAccessibilityGranted: true))
    XCTAssertTrue(CompactPanelCharacter.statusNeedsAttention(notice: nil, isAccessibilityGranted: false))
    XCTAssertFalse(CompactPanelCharacter.statusNeedsAttention(notice: nil, isAccessibilityGranted: true))
  }

  func testPresentationShowsThePanelUntilTheSidebarOpens() {
    var shell = ShellPresentation(mode: .auto, showsSidebar: true)
    XCTAssertFalse(shell.showsCompactPanel)
    shell.beginSelectionComposer(mode: .auto, showsSidebar: true)
    XCTAssertTrue(shell.showsCompactPanel)
    shell.leaveSelectionComposer()
    XCTAssertTrue(shell.showsCompactPanel, "The answer opens inside the panel")
    shell.isSidebarVisible = true
    XCTAssertFalse(shell.showsCompactPanel, "Double-tap Control shows the full layout with the history")
    shell.isSidebarVisible = false
    XCTAssertTrue(shell.showsCompactPanel)
    XCTAssertTrue(shell.sessionChanged(isTemporaryChat: false))
    XCTAssertFalse(shell.showsCompactPanel, "A saved chat replacing the temporary one ends the panel")
  }

  /// The panel opens at its first size, keeps its top edge, and grows
  /// downward on the panel-answer spring.
  func testExpansionKeepsTheTopEdgeAndGrowsDownward() {
    XCTAssertEqual(SelectionPanelExpansion.composerSize, NSSize(width: 720, height: 92))
    let visible = NSRect(x: -1440, y: 40, width: 1440, height: 860)
    // A composer high on the screen grows downward without moving.
    let composer = NSRect(x: -1200, y: 700, width: 720, height: 128)
    let grown = SelectionPanelExpansion.frame(from: composer, visible: visible)
    XCTAssertEqual(grown.maxY, composer.maxY, "The input stays where it was")
    XCTAssertEqual(grown.minX, composer.minX)
    XCTAssertEqual(grown.size, NSSize(width: 720, height: 600))
    XCTAssertTrue(visible.contains(grown))
    let low = SelectionPanelExpansion.frame(from: NSRect(x: -1200, y: 60, width: 720, height: 128), visible: visible)
    XCTAssertEqual(low.minY, visible.minY, "Near the bottom it moves up to fit")
    XCTAssertTrue(visible.contains(low))
    let small = NSRect(x: 0, y: 0, width: 700, height: 500)
    XCTAssertTrue(small.contains(SelectionPanelExpansion.frame(from: composer, visible: small)))

    // The frames along the way keep the top edge.
    for progress in [0.0, 0.3, 0.7, 1.0] {
      let frame = SelectionPanelExpansion.frame(at: progress, from: composer, to: grown, visible: visible)
      XCTAssertEqual(frame.maxY, composer.maxY, accuracy: 0.001)
      XCTAssertEqual(frame.height, composer.height + (grown.height - composer.height) * progress, accuracy: 0.001)
    }

    // The spring starts still, barely overshoots, and settles.
    XCTAssertEqual(SelectionPanelExpansion.springProgress(at: 0), 0)
    let settle = SelectionPanelExpansion.settlingDuration()
    XCTAssertGreaterThan(settle, 0.3)
    XCTAssertLessThan(settle, 1)
    XCTAssertEqual(SelectionPanelExpansion.springProgress(at: settle), 1, accuracy: 0.002)
    let samples = stride(from: 0.0, through: settle, by: 0.01).map { SelectionPanelExpansion.springProgress(at: $0) }
    XCTAssertLessThan(samples.max() ?? 2, 1.01, "Damping 0.9 settles with a barely visible overshoot")
    XCTAssertGreaterThan(SelectionPanelExpansion.springProgress(at: 0.1), 0.05)
  }

  // MARK: Hosted panel

  @MainActor
  func testPanelShowsTheSelectionAndGrowsDownwardIntoTheAnswerOnlyAfterAnAcceptedPrompt() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self, reduceMotion: false)
    // Opened near the top of the screen, there's room for the answer below the
    // input on any display; lower down it moves up to fit, as tested above.
    host.present("Please send the report today.", cursor: NSPoint(x: host.visible.midX, y: host.visible.maxY - 24))
    try await host.waitForComposer()
    XCTAssertTrue(fixture.chat.isTemporaryChat)
    XCTAssertEqual(fixture.chat.attachedContexts.count, 1)
    XCTAssertTrue(host.shows("Selected text"))
    XCTAssertTrue(host.shows("Hint / commands") && host.shows("Hint ⌘O open in window") && host.shows("Hint esc close"))
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    XCTAssertEqual(editor.commandTextColor, EnigmaPalette.paper.accentText.nsColor, "The field takes the palette's colors")
    XCTAssertTrue(host.view.bounds.contains(host.view.convert(editor.bounds, from: editor)))
    let image = try XCTUnwrap(try EnigmaSnapshot.capture(host.view).cgImage)
    let text = try await ScreenOCRService().recognize(image).text.lowercased()
    XCTAssertTrue(text.contains("please send the report today"), "The selected text is visible before sending: \(text)")

    // Empty input doesn't grow the panel or start a request.
    try host.pressReturn()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(host.controller.isSelectionComposer)
    XCTAssertNil(fixture.chat.activeRequest)

    fixture.screen.draft = "Explain this passage"
    try await waitForUI("the draft in the field", in: host.view) { editor.string == fixture.screen.draft }
    let composerFrame = host.window.frame
    let expanded = SelectionPanelExpansion.frame(from: composerFrame, visible: host.visible)
    XCTAssertGreaterThanOrEqual(composerFrame.maxY - expanded.height, host.visible.minY,
                                "The screen has room for the answer below the input (visible \(host.visible))")
    try host.pressReturn()
    try await waitForUI("the accepted prompt and the grown panel (frame \(host.window.frame))", in: host.view) {
      !host.controller.isSelectionComposer && host.window.frame == expanded && fixture.engine.requestCount == 1
        && fixture.screen.draft.isEmpty && host.shows("Compact panel answer")
    }
    XCTAssertEqual(host.window.frame.maxY, composerFrame.maxY, "The input stays put as the answer opens under it")
    XCTAssertTrue(host.visible.contains(host.window.frame))
    XCTAssertTrue(fixture.chat.presentationMessages.contains { $0.contexts?.first?.text == "Please send the report today." },
                  "The question carries the selection")
    try await waitForUI("the question, Stop, and the selection line in the answer", in: host.view) {
      host.shows("Your message") && host.shows("Stop response") && host.shows("Hint ⌘. stop") && host.shows("Selected text")
    }
    fixture.engine.send("It asks the team to send the report today.")
    fixture.engine.finish()
    try await waitForUI("the reply with its meta line", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Reply") && host.shows("Reply meta") && host.shows("Send message")
    }

    // A new selection opens the composer again, with no text selected this time.
    host.present(nil)
    try await host.waitForComposer()
    XCTAssertTrue(host.shows("No text selected"))
    XCTAssertTrue(fixture.chat.messages.isEmpty)
    XCTAssertFalse(host.shows("Compact panel answer"))
  }

  @MainActor
  func testHeightIsReportedAndMakesRoomForTheDetailsCommandsAndMenu() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    let report = try XCTUnwrap(host.controller.selectionComposer)
    XCTAssertEqual(host.window.frame.height, report.height, accuracy: 1.5, "The window fits the reported panel")
    let resting = host.window.frame

    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details under the input", in: host.view) {
      host.shows("Selection details panel") && host.window.frame.height > resting.height + 40
    }
    XCTAssertEqual(host.window.frame.maxY, resting.maxY, accuracy: 1, "It grows downward")
    XCTAssertTrue(host.shows("Remove selected text"), "The details hold the selected text's card")
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details closed", in: host.view) {
      !host.shows("Selection details panel") && abs(host.window.frame.height - resting.height) < 1.5
    }

    let editor = try XCTUnwrap(composerEditor(in: host.view))
    host.window.makeFirstResponder(editor)
    editor.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    try await waitForUI("room for the command list", in: host.view) {
      editor.completion?.commands.isEmpty == false && host.window.frame.height > resting.height + 120
    }
    editor.completion?.dismiss()
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await waitForUI("the command list's room gone", in: host.view) {
      abs(host.window.frame.height - resting.height) < 1.5
    }

    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("the mode and model menu, inside the panel", in: host.view) {
      guard host.shows("Menu item Auto"), let menu = host.marker("Menu Mode and model") else { return false }
      let frame = host.view.convert(menu.bounds, from: menu)
      return host.window.frame.height > resting.height + 120 && host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }
    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("the menu closed and its room gone", in: host.view) {
      !host.shows("Menu item Auto") && abs(host.window.frame.height - resting.height) < 1.5
    }
  }

  @MainActor
  func testEscapeClosesTheDetailsFirstAndThePanelStays() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    let resting = host.window.frame
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details", in: host.view) { host.shows("Selection details panel") }
    fixture.screen.draft = "Keep this draft"
    XCTAssertTrue(host.window.performKeyEquivalent(with: try host.escape()))
    try await waitForUI("the details closed, the panel still up", in: host.view) {
      !host.shows("Selection details panel") && abs(host.window.frame.height - resting.height) < 1.5
    }
    XCTAssertTrue(host.window.isVisible)
    XCTAssertTrue(host.controller.isSelectionComposer)
    XCTAssertEqual(fixture.screen.draft, "Keep this draft")
    // With nothing left open, Escape hides the panel, as before.
    XCTAssertTrue(host.window.performKeyEquivalent(with: try host.escape()))
    XCTAssertFalse(host.window.isVisible)
  }

  /// Low on the screen, the command list and the menu open above the input,
  /// which stays put; the details push the panel up to fit, and every one of
  /// them hands the panel back to its place when it closes.
  @MainActor
  func testLowOnTheScreenListsOpenAboveAndThePanelReturnsToItsPlace() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.", cursor: NSPoint(x: host.visible.midX, y: host.visible.minY + 8))
    try await host.waitForComposer()
    let resting = host.window.frame
    XCTAssertLessThan(resting.minY - host.visible.minY, CompactPanelLayout.overlayRoomBelow)
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    func fieldTop() -> CGFloat { host.window.convertToScreen(editor.convert(editor.bounds, to: nil)).maxY }
    let field = fieldTop()

    host.window.makeFirstResponder(editor)
    editor.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    try await waitForUI("the command list above the input", in: host.view) {
      editor.completion?.commands.isEmpty == false && host.window.frame.maxY > resting.maxY + 120
    }
    XCTAssertEqual(host.window.frame.minY, resting.minY, accuracy: 1, "The panel grows up, not off the screen")
    XCTAssertEqual(fieldTop(), field, accuracy: 1, "The input stays where it was")
    XCTAssertTrue(host.visible.contains(host.window.frame))
    editor.completion?.dismiss()
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await waitForUI("the panel back in its place", in: host.view) { host.window.frame == resting }

    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("the menu above the input, inside the panel", in: host.view) {
      guard host.shows("Menu item Auto"), let menu = host.marker("Menu Mode and model") else { return false }
      let frame = host.view.convert(menu.bounds, from: menu)
      let input = host.view.convert(editor.bounds, from: editor)
      return host.window.frame.maxY > resting.maxY + 120 && host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
        && (host.view.isFlipped ? frame.maxY <= input.minY : frame.minY >= input.maxY)
    }
    XCTAssertEqual(fieldTop(), field, accuracy: 1)
    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("the panel back after the menu", in: host.view) { host.window.frame == resting }

    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details, pushed up to fit", in: host.view) {
      host.shows("Selection details panel") && host.window.frame.height > resting.height + 40
    }
    XCTAssertTrue(host.visible.contains(host.window.frame))
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the panel back after the details", in: host.view) { host.window.frame == resting }
  }

  @MainActor
  func testPanelReopensAtItsRestingHeightWithTheDetailsClosed() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    let resting = host.window.frame.height
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details", in: host.view) {
      host.shows("Selection details panel") && host.window.frame.height > resting + 40
    }
    XCTAssertEqual(try XCTUnwrap(host.controller.selectionComposer).restingHeight, resting, accuracy: 1.5)
    host.controller.hide()
    try await waitForUI("the details closed with the panel", in: host.view) { !host.shows("Selection details panel") }
    host.present("Please send the report today.")
    XCTAssertEqual(host.window.frame.height, resting, accuracy: 1.5, "It opens at its resting height, without a snap")
    try await host.waitForComposer()
    XCTAssertFalse(host.shows("Selection details panel"))
    XCTAssertEqual(host.window.frame.height, resting, accuracy: 1.5)
  }

  @MainActor
  func testSendKeyHasAPointerSizedTarget() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    fixture.screen.draft = "Explain this passage"
    try await waitForUI("Send enabled", in: host.view) { composerEditor(in: host.view)?.string == "Explain this passage" }
    let send = try XCTUnwrap(host.marker("Send message"))
    XCTAssertGreaterThanOrEqual(send.bounds.width, 24)
    XCTAssertGreaterThanOrEqual(send.bounds.height, 24)
    try await clickTestControl("Send message", in: host.view)
    try await waitForUI("the request", in: host.view) {
      fixture.engine.requestCount == 1 && !host.controller.isSelectionComposer
    }
    let stop = try XCTUnwrap(host.marker("Stop response"))
    XCTAssertGreaterThanOrEqual(min(stop.bounds.width, stop.bounds.height), 24)
    try await clickTestControl("Stop response", in: host.view)
    try await waitForUI("the reply stopped", in: host.view) { fixture.chat.activeRequest == nil }
  }

  @MainActor
  func testMessagesApprovalInTheAnswerStaysInViewAndSendsOnlyOnSend() async throws {
    let fixture = try await Fixture(test: self)
    // Accessibility missing too, so the cards pass the area's height.
    fixture.selectionAccess = SelectionAccessibilityAccess(checkTrust: { false }, prompt: {}, openSettings: { _ in })
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    try await host.send("Tell Sam I'm running late", fixture)
    let approval = MessagesSendApproval(conversationName: "Sam", recipients: [.init(name: "Sam", handle: "+1 555 0100")],
                                        service: "iMessage", text: "Running late", target: .chat("c"))
    let answer = Task { await fixture.chat.appleMessages.confirm(approval) }
    try await waitForUI("the approval's buttons in view", in: host.view) {
      ["Send", "Don't Send"].allSatisfy { name in
        guard let button = host.marker(name) else { return false }
        return host.view.bounds.contains(host.view.convert(button.bounds, from: button))
      }
    }
    try await clickTestControl("Send", in: host.view)
    let approved = await answer.value
    XCTAssertTrue(approved)
  }

  @MainActor
  func testUnreadableSelectionShowsTheErrorStateAndProblemsOpenTheDetails() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    addTeardownBlock { @MainActor in SelectionContextService.shared.notice = nil }
    host.present("Please send the report today.")
    try await host.waitForComposer()
    try await waitForUI("no problem with a readable selection", in: host.view) { fixture.character.state == .idle }
    // As when the capture couldn't read anything.
    host.present(nil)
    SelectionContextService.shared.notice = "No selected text could be read."
    try await host.waitForComposer()
    try await waitForUI("the error state with no text selected", in: host.view) {
      fixture.character.state == .error && host.shows("No text selected")
    }
    XCTAssertFalse(host.shows("Selection details panel"))
    // A problem the panel would otherwise hide opens the details, as before.
    fixture.files.error = "The folder can't be read."
    try await waitForUI("the details opened with the file error", in: host.view) {
      host.shows("Selection details panel") && host.controller.isSelectionComposer
    }
    let details = try XCTUnwrap(host.marker("Selection details panel"))
    XCTAssertTrue(host.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(host.view.convert(details.bounds, from: details)))
  }

  @MainActor
  func testMissingAccessibilityShowsTheErrorStateAndItsSettingsButton() async throws {
    var trusted = false
    var operations: [String] = []
    let fixture = try await Fixture(test: self)
    fixture.selectionAccess = SelectionAccessibilityAccess(checkTrust: { trusted }, prompt: { operations.append("prompt") },
                                                           openSettings: { _ in operations.append("settings") })
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    try await waitForUI("the error state", in: host.view) { fixture.character.state == .error }
    try await clickTestControl("Selection details", in: host.view)
    try await clickTestControl("Open Accessibility Settings…", in: host.view)
    XCTAssertEqual(operations, ["prompt", "settings"], "The prompt, then the Settings pane, as before")
    trusted = true
    NotificationCenter.default.post(name: .panelPresented, object: nil)
    try await waitForUI("the error state cleared once allowed", in: host.view) {
      fixture.character.state != .error && !host.shows("Open Accessibility Settings…")
    }
  }

  @MainActor
  func testEditRevisionCardInTheAnswerReplacesOnlyOnReplaceText() async throws {
    try await runEditRevision(automatic: false)
  }

  @MainActor
  func testAutomaticEditReplacementShowsNoCard() async throws {
    try await runEditRevision(automatic: true)
  }

  /// /edit in the panel, with the automatic replacement setting on or off.
  @MainActor
  private func runEditRevision(automatic: Bool) async throws {
    let revision = "Please send the report today."
    let fixture = try await Fixture(test: self)
    fixture.selectionEditing.automaticallyReplace = automatic
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("send report now")
    try await host.waitForComposer()
    try await host.send("/edit Make it formal", fixture)
    fixture.engine.send("Here it is, more formal.\n" + SelectionRevisionResponse.opening
      + "{\"operation\":\"replace_selection\",\"text\":\"\(revision)\"}" + SelectionRevisionResponse.closing)
    fixture.engine.finish()
    if automatic {
      try await waitForUI("the automatic replacement", in: host.view) {
        fixture.pastes.texts == [revision] && fixture.chat.activeRequest == nil && host.shows("Reply")
      }
      XCTAssertFalse(host.shows("Replace text"), "Automatic replacement shows no card")
      return
    }
    try await waitForUI("the revision card in the answer", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Replace text") && host.shows("Reply")
        && host.shows("Compact panel answer")
    }
    XCTAssertTrue(fixture.pastes.texts.isEmpty, "Manual replacement waits for Replace text")
    try await clickTestControl("Replace text", in: host.view)
    if SelectionContextService.shared.canReplace {
      try await waitForUI("the paste", in: host.view) { fixture.pastes.texts == [revision] }
    } else {
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertTrue(fixture.pastes.texts.isEmpty, "Replace text stays off without a selection to replace, as before")
    }
  }

  @MainActor
  func testSavedChatReplacingTheTemporaryOneResetsThePanel() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Quantizing a GGUF")])
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    try await host.send("Explain this passage", fixture)
    fixture.engine.finish()
    try await waitForUI("the finished answer", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Compact panel answer")
    }
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    try await waitForUI("the normal window with the saved chat", in: host.view) {
      host.window.frame == host.normalFrame && !host.shows("Compact panel answer") && !host.shows("Compact panel")
        && host.shows("Send message")
    }
    XCTAssertFalse(host.controller.isSelectionComposer)
  }

  /// A fixed screen for the tests that move or expand the panel, whatever
  /// the Mac's displays: GitHub's runners have small screens.
  static let testScreen = NSRect(x: 0, y: 0, width: 1280, height: 800)

  /// Double-tap Control in the panel opens its chat in the window, even before
  /// the first answer: the normal layout, sidebar as the saved preference has
  /// it (off here), and the chat saved from then on. Double-tap Control again
  /// shows or hides the history, as in any chat.
  @MainActor
  func testDoubleControlOpensThePanelsChatInTheWindowBeforeTheFirstAnswer() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    fixture.start.showsSidebar = false
    host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    let id = try XCTUnwrap(fixture.chat.selectedSessionID)
    XCTAssertTrue(fixture.chat.isTemporaryChat)
    XCTAssertTrue(host.shows("Hint tag \(CompactPanelHints.temporaryTag)"), "The panel says its chat is temporary")
    // The selection panel has no history: ⌃⌘S is left unhandled there.
    let sidebarKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
      timestamp: 0, windowNumber: host.window.windowNumber, context: nil, characters: "\u{13}",
      charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
    host.window.makeKey()
    XCTAssertFalse(host.window.performKeyEquivalent(with: sidebarKey))
    try host.press("o", keyCode: 31, modifiers: .command)
    try await waitForUI("the window's chat, without the sidebar", in: host.view) {
      !host.shows("Compact panel") && host.shows("Show chat history") && !host.shows("New chat")
        && host.shows("Send message")
    }
    XCTAssertEqual(host.window.frame, PanelSizeStore.centeredFrame(size: host.normalFrame.size, in: Self.testScreen),
                   "The window's normal size, on the panel's screen")
    XCTAssertFalse(host.controller.isSelectionComposer)
    XCTAssertFalse(fixture.chat.isTemporaryChat, "Opened in the window, the chat is an ordinary one")
    XCTAssertEqual(fixture.chat.selectedSessionID, id, "The same chat")
    XCTAssertEqual(fixture.chat.attachedContexts.count, 1, "The selection stays for /edit and Replace text")
    XCTAssertFalse(host.shows("Hint tag \(CompactPanelHints.temporaryTag)"))
    XCTAssertFalse(host.shows("Window tag \(CompactPanelHints.temporaryTag)"), "It isn't temporary any more")
    await fixture.chat.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(ChatSessionStore(applicationSupportDirectory: fixture.root).load().map(\.id), [id])
    try host.press("s", keyCode: 1, modifiers: [.control, .command])
    try await waitForUI("the history, as in any chat", in: host.view) { host.shows("New chat") }
  }

  /// The Open in window button does what ⌘O does, after an
  /// answer too. With the sidebar preference on, the chat tops Recents,
  /// selected, and says once that it's saved.
  @MainActor
  func testOpenInWindowButtonOpensTheNormalChatSavedAtTheTopOfRecents() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Quantizing a GGUF")])
    fixture.start.showsSidebar = true
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    try await host.send("Explain this passage", fixture)
    fixture.engine.send("It asks for the report today.")
    fixture.engine.finish()
    try await waitForUI("the finished answer", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Compact panel answer") && host.shows("Open in window")
    }
    await fixture.chat.sessionWriter.waitForPendingWrites()
    let before = try Data(contentsOf: fixture.root.appending(path: "chats.json"))
    XCTAssertFalse(fixture.chat.historySessions.contains { $0.id == fixture.chat.selectedSessionID })
    try await clickTestControl("Open in window", in: host.view)
    try await waitForUI("the window's chat with the sidebar", in: host.view) {
      !host.shows("Compact panel answer") && host.shows("New chat") && host.shows("Your message")
    }
    XCTAssertFalse(fixture.chat.isTemporaryChat)
    let rows = ChatHistoryList.rows(sessions: fixture.chat.historySessions, selectedSessionID: fixture.chat.selectedSessionID)
    XCTAssertEqual(rows.first?.title, "Explain this passage", "It tops Recents")
    XCTAssertEqual(rows.first?.isSelected, true)
    let note = "Chat footnote Saved to history · Enigma keeps your last \(ChatSessionStore.maximumRetainedSessions) chats"
    try await waitForUI("the saved line", in: host.view) { host.shows(note) }
    XCTAssertEqual(host.markers(note), 1, "Said once")
    XCTAssertFalse(fixture.chat.messages.contains { $0.content.contains("Saved to history") }, "Not part of the transcript")
    await fixture.chat.sessionWriter.waitForPendingWrites()
    let saved = ChatSessionStore(applicationSupportDirectory: fixture.root).load()
    XCTAssertNotEqual(try Data(contentsOf: fixture.root.appending(path: "chats.json")), before)
    XCTAssertEqual(saved.first?.title, "Explain this passage")
    XCTAssertEqual(saved.first?.messages.map(\.content), ["Explain this passage", "It asks for the report today."])
    let file = try String(decoding: Data(contentsOf: fixture.root.appending(path: "chats.json")), as: UTF8.self)
    XCTAssertFalse(file.contains("Please send the report today."), "Selected text is never written to disk")

    // The line is a one-off: the next message ends it.
    try await host.send("Thanks", fixture, expectsPanelToGrow: false)
    try await waitForUI("the line gone with the next message", in: host.view) { !host.shows(note) }
    fixture.engine.finish()
    try await waitForUI("the reply", in: host.view) { fixture.chat.activeRequest == nil }
    XCTAssertFalse(host.shows(note))

    // Another chat ends the selection.
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    try await waitForUI("the other chat", in: host.view) { !host.shows("Your message") || fixture.chat.selectedSessionID == fixture.earlierSessionID }
    XCTAssertTrue(fixture.chat.attachedContexts.isEmpty)
  }

  /// Closed without opening in the window, the panel's chat is never written.
  @MainActor
  func testClosingThePanelWithoutOpeningInTheWindowSavesNothing() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Quantizing a GGUF")])
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    await fixture.chat.sessionWriter.waitForPendingWrites()
    let before = try Data(contentsOf: fixture.root.appending(path: "chats.json"))
    host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    try await host.send("Explain this passage", fixture)
    fixture.engine.send("It asks for the report today.")
    fixture.engine.finish()
    try await waitForUI("the finished answer", in: host.view) { fixture.chat.activeRequest == nil }
    host.controller.hide()
    fixture.chat.applicationBecameInactive()
    host.present(nil, cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    await fixture.chat.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: "chats.json")), before)
    XCTAssertFalse(fixture.chat.sessions.contains { $0.title == "Explain this passage" })
  }

  /// With "Keep selection chats private" on, the chat opens in the window but
  /// stays temporary: never written, out of Recents, tagged for as long as
  /// it's open, and gone with the next chat. Turning the setting off then
  /// doesn't save it after the fact.
  @MainActor
  func testPrivateSelectionChatsOpenInTheWindowWithoutBeingSaved() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Quantizing a GGUF")])
    fixture.selectionEditing.keepsChatsPrivate = true
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    await fixture.chat.sessionWriter.waitForPendingWrites()
    let before = try Data(contentsOf: fixture.root.appending(path: "chats.json"))
    host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    try await host.send("Explain this passage", fixture)
    fixture.engine.send("It asks for the report today.")
    fixture.engine.finish()
    try await waitForUI("the finished answer", in: host.view) { fixture.chat.activeRequest == nil }
    XCTAssertTrue(host.shows("Hint tag \(CompactPanelHints.temporaryTag)"))
    let id = try XCTUnwrap(fixture.chat.selectedSessionID)
    try await clickTestControl("Open in window", in: host.view)
    try await waitForUI("the window's chat, private", in: host.view) {
      !host.shows("Compact panel answer") && host.shows("Your message")
        && host.shows("Window tag \(CompactPanelHints.temporaryTag)")
        && host.shows("Chat footnote \(CompactPanelHints.privateNote)")
    }
    XCTAssertTrue(fixture.chat.isTemporaryChat)
    XCTAssertEqual(fixture.chat.selectedSessionID, id)
    XCTAssertFalse(fixture.chat.historySessions.contains { $0.id == id }, "Not in Recents")
    XCTAssertFalse(host.shows("Hint tag \(CompactPanelHints.temporaryTag)"))
    // Set mid-chat, the setting applies from the next chat opened in the window.
    fixture.selectionEditing.keepsChatsPrivate = false
    fixture.chat.applicationBecameInactive()
    await fixture.chat.sessionWriter.waitForPendingWrites()
    XCTAssertTrue(fixture.chat.isTemporaryChat)
    XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: "chats.json")), before)
    // The private line goes with the next message; the tag stays.
    try await host.send("Thanks", fixture, expectsPanelToGrow: false)
    try await waitForUI("the line gone, the tag kept", in: host.view) {
      !host.shows("Chat footnote \(CompactPanelHints.privateNote)") && host.shows("Window tag \(CompactPanelHints.temporaryTag)")
    }
    fixture.engine.finish()
    try await waitForUI("the reply", in: host.view) { fixture.chat.activeRequest == nil }
    fixture.chat.applicationBecameInactive()
    await fixture.chat.sessionWriter.waitForPendingWrites()
    XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: "chats.json")), before, "Still never written")
    NotificationCenter.default.post(name: .newChatRequested, object: nil)
    try await waitForUI("a new chat", in: host.view) { fixture.chat.selectedSessionID != id }
    XCTAssertFalse(fixture.chat.sessions.contains { $0.id == id }, "Discarded with the next chat")
  }

  /// The panel moves when dragged by its background, small or grown, while
  /// its controls keep their clicks. Moved, it keeps its place through the
  /// automatic resizing that follows, still on the screen, and the next
  /// summons opens it by the selection again.
  @MainActor
  func testDraggedPanelKeepsItsPlaceThroughAutomaticResizing() async throws {
    let fixture = try await Fixture(test: self)
    let screen = Self.testScreen
    let host = try await CompactPanelHost(fixture, test: self, visible: screen)
    let cursor = NSPoint(x: 640, y: 120)
    host.present("Please send the report today.", cursor: cursor)
    try await host.waitForComposer()
    let placed = host.window.frame
    XCTAssertLessThan(placed.minY - screen.minY, CompactPanelLayout.overlayRoomBelow, "Low enough for lists to open above")
    for control in ["Send message", "Open in window", "Selection details", "Remove selection", "Attach files"] {
      XCTAssertNil(host.dragArea(atMarker: control), "\(control) keeps its clicks")
    }
    XCTAssertTrue(composerAcceptsClicks(in: host.view), "The field keeps its clicks")

    // Dragged up by its background, the lists open under the input from there.
    try host.drag(by: NSSize(width: -200, height: 450))
    let moved = host.window.frame
    XCTAssertEqual(moved.origin, NSPoint(x: placed.minX - 200, y: placed.minY + 450))
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    host.window.makeFirstResponder(editor)
    editor.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    try await waitForUI("the command list under the input, where the panel is now", in: host.view) {
      editor.completion?.commands.isEmpty == false && host.window.frame.height > moved.height + 120
    }
    XCTAssertEqual(host.window.frame.maxY, moved.maxY, accuracy: 1, "It grows down from where it was moved")
    editor.completion?.dismiss()
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await waitForUI("back at its moved place", in: host.view) { host.window.frame == moved }

    // Partly off the screen's edge, the next resize brings it back on.
    try host.drag(by: NSSize(width: 900, height: 0))
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details, on the screen", in: host.view) {
      host.shows("Selection details panel") && host.window.frame.maxX <= screen.maxX + 0.5
    }
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details closed", in: host.view) { !host.shows("Selection details panel") }
    let resting = host.window.frame
    XCTAssertEqual(resting.maxY, moved.maxY, accuracy: 1)

    // The answer opens under the input where it is.
    try await host.send("Explain this passage", fixture)
    try await waitForUI("the grown panel", in: host.view) {
      host.window.frame == SelectionPanelExpansion.frame(from: resting, visible: screen)
    }
    // Grown, it moves too, and stays where it's put as the reply streams in.
    try await waitForUI("the answer's background", in: host.view) { host.dragArea(at: host.hintRowPoint) != nil }
    let grown = host.window.frame
    try host.drag(by: NSSize(width: -300, height: 40))
    XCTAssertEqual(host.window.frame.origin, NSPoint(x: grown.minX - 300, y: grown.minY + 40))
    let grownMoved = host.window.frame
    fixture.engine.send("It asks for the report today.")
    fixture.engine.finish()
    try await waitForUI("the reply", in: host.view) { fixture.chat.activeRequest == nil && host.shows("Reply") }
    XCTAssertEqual(host.window.frame, grownMoved)

    // The next summons opens by the selection again.
    host.present("Another passage", cursor: cursor)
    try await host.waitForComposer()
    XCTAssertEqual(host.window.frame.minX, placed.minX, accuracy: 1)
    XCTAssertEqual(host.window.frame.maxY, placed.maxY, accuracy: 1)
  }

  /// A first reply that fails, or is stopped before any text, leaves the
  /// selection attached: the line still reads `selected`, and the next
  /// question carries it with the first-message instructions.
  @MainActor
  func testSelectionStaysAttachedWhenTheFirstReplyFailsOrIsStopped() async throws {
    for stops in [false, true] {
      let fixture = try await Fixture(test: self)
      let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
      host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
      try await host.waitForComposer()
      try await host.send("Explain this passage", fixture)
      if stops { fixture.chat.stopStreaming() } else { fixture.engine.finish(throwing: LocalInferenceError.invalidModelFile) }
      try await waitForUI("the first reply ended without text", in: host.view) {
        fixture.chat.activeRequest == nil && host.shows("Selected text to send")
      }
      XCTAssertFalse(host.shows("Selected text for /edit"))
      try await host.send("Explain it again", fixture)
      let current = try XCTUnwrap(fixture.engine.lastRequest?.messages.last)
      XCTAssertTrue(current.content.contains("Please send the report today."), "Attached again")
      XCTAssertTrue(current.content.contains(SelectionResponseMode.answer.instructions))
      fixture.engine.send("It asks for the report today.")
      fixture.engine.finish()
      try await waitForUI("the reply, and the selection now sent", in: host.view) {
        fixture.chat.activeRequest == nil && host.shows("Selected text for /edit")
      }
    }
  }

  /// The main window moves by its background too, but not along its edges,
  /// which are left to resizing, and not over the sidebar or the chat.
  @MainActor
  func testMainWindowMovesWhenDraggedByItsBackground() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    // On the test's screen, whatever the Mac's displays.
    host.window.setFrameOrigin(NSPoint(x: 100, y: 80))
    let start = host.window.frame
    // The empty page around the composer is background.
    let point = NSPoint(x: start.width * 0.75, y: start.height * 0.12)
    XCTAssertNotNil(host.dragArea(at: point), "The page's background moves the window")
    let edge = EnigmaWindowChrome.resizeEdge
    XCTAssertNil(host.dragArea(at: NSPoint(x: start.width - edge / 2, y: point.y)), "The right edge resizes")
    XCTAssertNil(host.dragArea(at: NSPoint(x: point.x, y: edge / 2)), "The bottom edge resizes")
    for control in ["Send message", "New chat", "Help", "Settings"] {
      XCTAssertNil(host.dragArea(atMarker: control), "\(control) keeps its clicks")
    }
    XCTAssertTrue(composerAcceptsClicks(in: host.view))
    try host.drag(from: point, by: NSSize(width: 40, height: -30))
    XCTAssertEqual(host.window.frame.origin, NSPoint(x: start.minX + 40, y: start.minY - 30))
    // A drag stops at the screen's visible edge, clear of the menu bar. The
    // screen is kept inside the Mac's real one, since AppKit itself won't put
    // a window above the real menu bar (CI runners have small displays).
    let real = try XCTUnwrap(host.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
    let screen = Self.testScreen.intersection(real)
    try host.drag(from: point, by: NSSize(width: 0, height: 2_000), screen: screen)
    XCTAssertEqual(host.window.frame.maxY, screen.maxY, accuracy: 0.5)

    // With a chat, its messages keep their clicks and scrolling.
    try await host.send("Explain this passage", fixture, expectsPanelToGrow: false)
    try await waitForUI("the message", in: host.view) { host.shows("Your message") }
    XCTAssertNil(host.dragArea(atMarker: "Your message"))
    let scrollViews = Self.descendants(host.view).compactMap { $0 as? NSScrollView }
    let chatScroll = try XCTUnwrap(scrollViews.max { $0.frame.width < $1.frame.width }, "The chat's scroll view")
    let scrollPoint = chatScroll.convert(NSPoint(x: chatScroll.bounds.midX, y: chatScroll.bounds.midY), to: nil)
    XCTAssertNil(host.dragArea(at: scrollPoint), "The chat scrolls rather than dragging")
  }

  private static func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }

  /// A click on the background without moving changes nothing.
  @MainActor
  func testClickingTheBackgroundDoesNotMoveOrResetThePanel() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self, visible: Self.testScreen)
    host.present("Please send the report today.", cursor: NSPoint(x: 640, y: 700))
    try await host.waitForComposer()
    try host.drag(by: NSSize(width: -100, height: -200))
    let moved = host.window.frame
    var events = 0
    let began = NotificationCenter.default.addObserver(forName: .enigmaWindowDragBegan, object: nil, queue: nil) { _ in
      events += 1
    }
    defer { NotificationCenter.default.removeObserver(began) }
    try host.drag(by: NSSize(width: 0, height: 0))
    XCTAssertEqual(events, 0, "A click isn't a drag")
    XCTAssertEqual(host.window.frame, moved)
    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details", in: host.view) { host.shows("Selection details panel") }
    XCTAssertEqual(host.window.frame.maxY, moved.maxY, accuracy: 1, "It grows from where it was moved")
  }

  @MainActor
  func testOpenInWindowButtonNamesWhatItDoes() throws {
    XCTAssertEqual(CompactPanelHints.openInWindowHelp(keepsPrivate: false), "Open in window · saves to history")
    XCTAssertEqual(CompactPanelHints.openInWindowHelp(keepsPrivate: true), "Open in window · stays private")
    XCTAssertEqual(CompactPanelHints.savedNote,
                   "Saved to history · Enigma keeps your last \(ChatSessionStore.maximumRetainedSessions) chats")
    XCTAssertEqual(CompactPanelHints.temporaryTag, "temporary · not saved")
    XCTAssertEqual(CompactPanelHints.openInWindowLabel, "Open in window", "The VoiceOver label")
    // The button renders in the panel's top row, with or without a selection.
    for keepsPrivate in [false, true] {
      let line = EnigmaCompactSelectionLine(contexts: [], isComposing: false, remove: { _ in }, openInWindow: {},
                                            opensPrivately: keepsPrivate)
        .frame(width: 720).enigmaTheme(.paper)
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
      let view = NSHostingView(rootView: line)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 40), styleMask: [.borderless],
                            backing: .buffered, defer: false)
      window.contentView = view
      view.layoutSubtreeIfNeeded()
      defer { window.contentView = nil }
      XCTAssertNotNil(EnigmaMainWindowTests.Host.marker("Open in window", in: view))
    }
  }

  @MainActor
  func testCharacterSitsBesideTheInputThenMovesToTheReply() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    try await waitForUI("the character beside the input", in: host.view) {
      fixture.character.activeSlot == CompactPanelLayout.inputSlot && fixture.character.isPresent
    }
    let slot = try XCTUnwrap(fixture.character.model.slot)
    XCTAssertEqual(slot.size, CompactPanelLayout.inputSlotSize)
    let field = try XCTUnwrap(composerEditor(in: host.view))
    let fieldFrame = host.view.convert(field.bounds, from: field)
    XCTAssertLessThan(slot.center.x, fieldFrame.minX, "The slot is left of the field")
    try await host.send("Explain this passage", fixture)
    try await waitForUI("the character beside the reply", in: host.view) {
      fixture.character.activeSlot?.rawValue.hasPrefix("chat.reply.") == true && fixture.character.isPresent
        && fixture.character.model.slot?.size == ConversationTranscript.slotSize
    }
    try await waitForUI("thinking while the panel answers", in: host.view) { fixture.character.state == .thinking }
  }

  // MARK: Screenshots

  @MainActor
  func testScreenshots() async throws {
    _ = try EnigmaSnapshot.directory()
    let passage = "Actor isolation means each actor protects its own mutable state, so only one task can touch it at a time."
    let fixture = try await Fixture(test: self)
    fixture.start.mode = .auto
    let host = try await CompactPanelHost(fixture, test: self)
    host.present(passage)
    try await host.waitForComposer()
    try await snapshot("panel-selection", host, fixture) { host.shows("Route chip auto · local") }

    let editor = try XCTUnwrap(composerEditor(in: host.view))
    host.window.makeFirstResponder(editor)
    editor.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    try await snapshot("panel-commands", host, fixture) { editor.completion?.commands.isEmpty == false }
    editor.completion?.dismiss()
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))

    try await clickTestControl("Selection details", in: host.view)
    try await snapshot("panel-details", host, fixture) { host.shows("Selection details panel") }
    try await clickTestControl("Selection details", in: host.view)

    try await host.send("What does this mean, in plain words?", fixture)
    fixture.engine.send("Each actor keeps its own state to itself, so only one task can change it at a time. "
      + "Anything outside the actor has to wait its turn with await. That's what lets Swift rule out data races at compile time.")
    fixture.engine.finish()
    try await snapshot("panel-answer", host, fixture) {
      fixture.chat.activeRequest == nil && host.shows("Reply meta") && host.shows("Compact panel answer")
    }

    let approval = MessagesSendApproval(conversationName: "Sam", recipients: [.init(name: "Sam", handle: "+1 555 0100")],
                                        service: "iMessage", text: "Running late, there in 10", target: .chat("c"))
    let pending = Task { await fixture.chat.appleMessages.confirm(approval) }
    try await snapshot("panel-approval", host, fixture) { host.shows("Send") && host.shows("Don't Send") }
    fixture.chat.appleMessages.answer(false)
    _ = await pending.value

    host.present(nil)
    try await host.waitForComposer()
    try await snapshot("panel-no-selection", host, fixture) { host.shows("No text selected") }

    host.present("send report now")
    try await host.waitForComposer()
    try await host.send("/edit Make it formal", fixture)
    fixture.engine.send("Here it is, more formal.\n" + SelectionRevisionResponse.opening
      + "{\"operation\":\"replace_selection\",\"text\":\"Please send the report today.\"}" + SelectionRevisionResponse.closing)
    fixture.engine.finish()
    try await snapshot("panel-edit", host, fixture) {
      fixture.chat.activeRequest == nil && host.shows("Replace text")
    }
  }

  /// Saves the panel in Paper and Ink once `ready`, after transitions settle.
  @MainActor
  private func snapshot(_ name: String, _ host: CompactPanelHost, _ fixture: Fixture,
                        until ready: () -> Bool) async throws {
    let folder = try EnigmaSnapshot.directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      fixture.appearance.appearance = appearance
      try await waitForUI("\(name) in \(appearance)", in: host.view, timeout: .seconds(8)) {
        let probe = CGPoint(x: host.view.bounds.width - 5, y: host.view.bounds.height / 2)
        return ready() && (try? EnigmaSnapshot.pixel(EnigmaSnapshot.capture(host.view), at: probe))
          .map { EnigmaSnapshot.matches($0, palette.surface) } == true
      }
      for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        host.window.displayIfNeeded()
      }
      let image = try EnigmaSnapshot.capture(host.view)
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      try png.write(to: folder.appending(path: "\(name)-\(appearance.rawValue).png"))
    }
    fixture.appearance.appearance = .paper
  }
}

// MARK: Host

/// The shell in the app's real panel controller, which sizes and places the
/// compact panel, with the main window's isolated fixture.
@MainActor
final class CompactPanelHost {
  let view: NSView
  let controller: SpotlightPanelController
  let window: NSWindow
  let visible: NSRect
  /// The window's frame before the panel opened, which a reset restores.
  let normalFrame: NSRect

  /// `visible` sets the screen the panel is on, instead of the Mac's own.
  init(_ fixture: EnigmaMainWindowTests.Fixture, test: XCTestCase, reduceMotion: Bool = true,
       visible screen: NSRect? = nil) async throws {
    let view = NSHostingView(rootView: fixture.shell())
    let sizes = PanelSizeStore(defaults: fixture.defaults)
    sizes.save(NSSize(width: 900, height: 600))
    let controller = SpotlightPanelController(sizeStore: sizes, contentView: view, reduceMotion: { reduceMotion },
      visibleFrame: { window in screen ?? window.screen?.visibleFrame })
    controller.show()
    test.addTeardownBlock { @MainActor in
      controller.hide()
      view.window?.attachedSheet.map { view.window?.endSheet($0) }
      view.window?.contentView = nil
    }
    self.view = view
    self.controller = controller
    window = try XCTUnwrap(view.window)
    window.colorSpace = .sRGB
    visible = try screen ?? XCTUnwrap(window.screen?.visibleFrame)
    try await waitForUI("the window frame", in: view) { EnigmaMainWindowTests.Host.marker("New chat", in: view) != nil }
    normalFrame = window.frame
  }

  func marker(_ name: String) -> NSView? { EnigmaMainWindowTests.Host.marker(name, in: view) }
  func shows(_ name: String) -> Bool { marker(name) != nil }

  /// How many visible markers are named `name`.
  func markers(_ name: String) -> Int {
    func isMarker(_ node: NSView) -> Bool {
      guard node is TestControlMarker.Marker, node.identifier?.rawValue == name else { return false }
      guard !node.isHiddenOrHasHiddenAncestor else { return false }
      return node.visibleRect.width > 1 && node.visibleRect.height > 1
    }
    func count(_ node: NSView) -> Int {
      let own = isMarker(node) ? 1 : 0
      return own + node.subviews.reduce(0) { $0 + count($1) }
    }
    return count(view)
  }

  /// A shortcut typed into the panel, which handles it only while it's the key window.
  func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
    window.makeKey()
    XCTAssertTrue(window.isKeyWindow, "Shortcuts reach the panel only while it's key; the test host must be frontmost")
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    XCTAssertTrue(window.performKeyEquivalent(with: event))
  }

  /// A point in the hint row between the shortcuts and the trailing tag, in
  /// window coordinates: background, with nothing over it.
  var hintRowPoint: NSPoint { NSPoint(x: window.frame.width * 0.62, y: 4) }

  /// The drag area a click at `point`, in window coordinates, lands on, if any.
  func dragArea(at point: NSPoint) -> EnigmaWindowDragArea.DragView? {
    guard let superview = view.superview else { return nil }
    return view.hitTest(superview.convert(point, from: nil)) as? EnigmaWindowDragArea.DragView
  }

  /// The drag area a click on the control marked `name` would land on: none.
  func dragArea(atMarker name: String) -> EnigmaWindowDragArea.DragView? {
    guard let marker = marker(name) else { return nil }
    return dragArea(at: marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil))
  }

  /// Presses at `point`, or the hint row, drags by `delta`, and lets go, as a
  /// person dragging the window's background would.
  func drag(from point: NSPoint? = nil, by delta: NSSize, screen: NSRect? = nil) throws {
    let point = point ?? hintRowPoint
    let area = try XCTUnwrap(dragArea(at: point), "The background at \(point) moves the window")
    let pointer = PointerBox()
    area.pointerLocation = { pointer.location }
    let screen = screen ?? visible
    area.visibleFrame = { _ in screen }
    func send(_ type: NSEvent.EventType) throws {
      window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
    }
    try send(.leftMouseDown)
    pointer.location = NSPoint(x: pointer.location.x + delta.width / 2, y: pointer.location.y + delta.height / 2)
    try send(.leftMouseDragged)
    pointer.location = NSPoint(x: 500 + delta.width, y: 500 + delta.height)
    try send(.leftMouseDragged)
    try send(.leftMouseUp)
  }

  /// What double-tap ⌥ does once the selection is read, with the pointer at
  /// `cursor`, or the middle of the screen.
  func present(_ text: String?, cursor: NSPoint? = nil) {
    controller.presentSelectionContext(text.map { ConversationContext(sourceName: "Test editor", text: $0) },
      cursor: cursor ?? NSPoint(x: visible.midX, y: visible.midY), selection: nil, visible: visible)
  }

  func escape() throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
  }

  func waitForComposer(file: StaticString = #filePath, line: UInt = #line) async throws {
    try await waitForUI("the compact panel (frame \(window.frame))", in: view, file: file, line: line) {
      guard let report = controller.selectionComposer else { return false }
      return controller.isSelectionComposer && shows("Compact panel")
        && window.frame.height < 150 && abs(window.frame.height - report.height) < 1.5
        && composerAcceptsClicks(in: view)
    }
  }

  func pressReturn() throws {
    let editor = try XCTUnwrap(composerEditor(in: view))
    editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
  }

  /// Types `text` into the real field and presses Return, then waits for the
  /// request, and in the panel for it to grow.
  func send(_ text: String, _ fixture: EnigmaMainWindowTests.Fixture, expectsPanelToGrow: Bool = true) async throws {
    let editor = try XCTUnwrap(composerEditor(in: view))
    let count = fixture.engine.requestCount
    fixture.screen.draft = text
    try await waitForUI("the draft in the field", in: view) { editor.string == text && editor.isEditable }
    try pressReturn()
    try await waitForUI("the request (state \(fixture.chat.state))", in: view) {
      fixture.engine.requestCount == count + 1 && (!expectsPanelToGrow || !controller.isSelectionComposer)
    }
  }

}

/// The pointer's place on screen for a simulated drag.
@MainActor
private final class PointerBox {
  var location = NSPoint(x: 500, y: 500)
}
