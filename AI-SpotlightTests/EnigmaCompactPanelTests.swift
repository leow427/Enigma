import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// Phase 8: the compact selection panel in the new design. Its logic, the
/// panel's sizes as it opens and grows, and the same selection flows the old
/// panel's tests cover, hosted in the real panel controller. Hosted tests use
/// the main window's isolated fixture, never the installed app's settings.
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

  /// Every hint names a shortcut the panel handles today; there's no ⌘O.
  @MainActor
  func testHintsNameOnlyShortcutsThatWork() {
    XCTAssertEqual(CompactPanelHints.hints(isResponding: false).map(\.text), ["/ commands", "⌃⌃ history", "esc close"])
    XCTAssertEqual(CompactPanelHints.hints(isResponding: true).map(\.text), ["⌘. stop", "⌃⌃ history", "esc close"])
    // Key glyphs are drawn in the system font, as the welcome's command lines draw them.
    XCTAssertEqual(EnigmaCommandLine.runs("⌃⌃ history").map(\.text), ["⌃⌃", " history"])
    XCTAssertEqual(EnigmaCommandLine.runs("⌃⌃ history").map(\.isSymbol), [true, false])
    XCTAssertEqual(EnigmaCommandLine.runs("⌘. stop").map(\.isSymbol), [true, false])
    let panelKeys = Set(KeyboardShortcutsHelp.panel.map(\.keys))
    XCTAssertTrue(panelKeys.contains("Esc"))
    XCTAssertTrue(panelKeys.contains("⌃ twice"), "Double-tap Control shows the history")
    XCTAssertTrue(panelKeys.contains("⌘ ."))
    XCTAssertEqual(PanelShortcut.resolve(characters: ".", modifiers: .command), .stopStreaming)
    XCTAssertNil(PanelShortcut.resolve(characters: "o", modifiers: .command), "⌘O doesn't exist, so no hint names it")
    XCTAssertFalse(SlashCommand.available(hasSearchKey: false).isEmpty, "/ opens the commands")
    var tap = ControlDoubleTap()
    XCTAssertFalse(tap.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 0))
    XCTAssertFalse(tap.flagsChanged(keyCode: 59, modifiers: [], timestamp: 0.05))
    XCTAssertFalse(tap.flagsChanged(keyCode: 59, modifiers: .control, timestamp: 0.1))
    XCTAssertTrue(tap.flagsChanged(keyCode: 59, modifiers: [], timestamp: 0.15))
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

  /// The old design's sizes and upward growth are unchanged; the new design
  /// keeps its top edge and grows downward on the panel-answer spring.
  func testExpansionKeepsTheOldSizesAndTheNewDesignGrowsDownward() {
    XCTAssertEqual(SelectionPanelExpansion.composerSize, NSSize(width: 720, height: 92))
    let visible = NSRect(x: -1440, y: 40, width: 1440, height: 860)
    // A composer low on the screen grows upward in the old design; one high
    // on the screen grows downward in the new one, both without moving.
    let lowComposer = NSRect(x: -1200, y: 100, width: 720, height: 128)
    let composer = NSRect(x: -1200, y: 700, width: 720, height: 128)
    let classic = SelectionPanelExpansion.frame(from: lowComposer, visible: visible)
    XCTAssertEqual(SelectionPanelExpansion.frame(from: lowComposer, visible: visible, style: .classic), classic)
    XCTAssertEqual(classic.minY, lowComposer.minY)
    let grown = SelectionPanelExpansion.frame(from: composer, visible: visible, style: .enigma)
    XCTAssertEqual(grown.maxY, composer.maxY, "The input stays where it was")
    XCTAssertEqual(grown.minX, composer.minX)
    XCTAssertEqual(grown.size, NSSize(width: 720, height: 600))
    XCTAssertTrue(visible.contains(grown))
    let low = SelectionPanelExpansion.frame(from: NSRect(x: -1200, y: 60, width: 720, height: 128), visible: visible,
                                            style: .enigma)
    XCTAssertEqual(low.minY, visible.minY, "Near the bottom it moves up to fit")
    XCTAssertTrue(visible.contains(low))
    let small = NSRect(x: 0, y: 0, width: 700, height: 500)
    XCTAssertTrue(small.contains(SelectionPanelExpansion.frame(from: composer, visible: small, style: .enigma)))

    // The frames along the way: the old design keeps its bottom, the new one its top.
    for progress in [0.0, 0.3, 0.7, 1.0] {
      let old = SelectionPanelExpansion.frame(at: progress, from: lowComposer, to: classic, visible: visible,
                                              style: .classic)
      XCTAssertEqual(old.minY, lowComposer.minY)
      let new = SelectionPanelExpansion.frame(at: progress, from: composer, to: grown, visible: visible, style: .enigma)
      XCTAssertEqual(new.maxY, composer.maxY, accuracy: 0.001)
      XCTAssertEqual(new.height, composer.height + (grown.height - composer.height) * progress, accuracy: 0.001)
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
    host.present("Please send the report today.")
    try await host.waitForComposer()
    XCTAssertTrue(fixture.chat.isTemporaryChat)
    XCTAssertEqual(fixture.chat.attachedContexts.count, 1)
    XCTAssertTrue(host.shows("Selected text"))
    XCTAssertTrue(host.shows("Hint / commands") && host.shows("Hint ⌃⌃ history") && host.shows("Hint esc close"))
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    XCTAssertEqual(editor.commandTextColor, EnigmaPalette.paper.accentText.nsColor, "The new design's field")
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
    let expanded = SelectionPanelExpansion.frame(from: composerFrame, visible: host.visible, style: .enigma)
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
    XCTAssertEqual(report.style, .enigma)
    XCTAssertEqual(host.window.frame.height, report.height, accuracy: 1.5, "The window fits the reported panel")
    let resting = host.window.frame

    try await clickTestControl("Selection details", in: host.view)
    try await waitForUI("the details under the input", in: host.view) {
      host.shows("Selection details panel") && host.window.frame.height > resting.height + 40
    }
    XCTAssertEqual(host.window.frame.maxY, resting.maxY, accuracy: 1, "It grows downward")
    XCTAssertTrue(host.shows("Remove selected text"), "The details hold the selected text's card, as the old popover did")
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
  func testTurningTheFlagOffOpensTheOldPanelAtItsOwnSize() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    host.controller.hide()
    fixture.newUI.isEnabled = false
    try await waitForUI("the old frame", in: host.view) { !host.shows("Compact panel") }
    host.present("Please send the report today.")
    XCTAssertEqual(host.window.frame.height, SelectionPanelExpansion.composerSize.height,
                   "The old panel opens at 92, as before")
    XCTAssertNotEqual(host.controller.selectionComposer?.style, .enigma, "Only the old panel's own report remains")
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

  /// Double-tap Control grows the panel and shows the history, as before: the
  /// full layout in the panel. Hiding the history goes back to the answer.
  @MainActor
  func testDoubleControlShowsTheHistoryInThePanelAndHidingItReturnsToTheAnswer() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    let composerFrame = host.window.frame
    // What SpotlightPanel's double-tap Control does.
    host.controller.expandSelectionPanel()
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    try await waitForUI("the full layout with the history", in: host.view) {
      host.shows("New chat") && !host.shows("Compact panel") && !host.shows("Compact panel answer")
    }
    XCTAssertEqual(host.window.frame, SelectionPanelExpansion.frame(from: composerFrame, visible: host.visible, style: .enigma))
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    try await waitForUI("the answer panel again", in: host.view) {
      host.shows("Compact panel answer") && !host.shows("New chat")
    }
  }

  @MainActor
  func testFlagSwapsLiveBetweenTheOldAndNewPanels() async throws {
    let fixture = try await Fixture(test: self)
    let host = try await CompactPanelHost(fixture, test: self)
    host.present("Please send the report today.")
    try await host.waitForComposer()
    XCTAssertEqual(host.controller.selectionComposer?.style, .enigma)
    fixture.newUI.isEnabled = false
    try await waitForUI("the old compact panel", in: host.view) {
      guard let editor = composerEditor(in: host.view) else { return false }
      return !host.shows("Compact panel") && editor.commandTextColor == .systemBlue
        && host.controller.selectionComposer?.style == .classic && host.window.frame.height < 150
        && composerAcceptsClicks(in: host.view)
    }
    fixture.newUI.isEnabled = true
    try await waitForUI("the new compact panel again", in: host.view) {
      host.shows("Compact panel") && host.controller.selectionComposer?.style == .enigma
        && abs(host.window.frame.height - (host.controller.selectionComposer?.height ?? 0)) < 1.5
    }
    XCTAssertTrue(host.controller.isSelectionComposer)
    XCTAssertEqual(fixture.chat.attachedContexts.count, 1, "Swapping designs keeps the selection")
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

  init(_ fixture: EnigmaMainWindowTests.Fixture, test: XCTestCase, reduceMotion: Bool = true) async throws {
    let view = NSHostingView(rootView: fixture.shell())
    let sizes = PanelSizeStore(defaults: fixture.defaults)
    sizes.save(NSSize(width: 900, height: 600))
    let controller = SpotlightPanelController(glassAppearance: GlassAppearanceSettings(defaults: fixture.defaults),
      sizeStore: sizes, contentView: view, reduceMotion: { reduceMotion })
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
    visible = try XCTUnwrap(window.screen?.visibleFrame)
    try await waitForUI("the new frame", in: view) { EnigmaMainWindowTests.Host.marker("New chat", in: view) != nil }
    normalFrame = window.frame
  }

  func marker(_ name: String) -> NSView? { EnigmaMainWindowTests.Host.marker(name, in: view) }
  func shows(_ name: String) -> Bool { marker(name) != nil }

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
      return controller.isSelectionComposer && shows("Compact panel") && report.style == .enigma
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

  /// Types `text` into the real field and presses Return, then waits for the request.
  func send(_ text: String, _ fixture: EnigmaMainWindowTests.Fixture) async throws {
    let editor = try XCTUnwrap(composerEditor(in: view))
    let count = fixture.engine.requestCount
    fixture.screen.draft = text
    try await waitForUI("the draft in the field", in: view) { editor.string == text && editor.isEditable }
    try pressReturn()
    try await waitForUI("the request (state \(fixture.chat.state))", in: view) {
      fixture.engine.requestCount == count + 1 && !controller.isSelectionComposer
    }
  }

}
