import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Enigma

final class MessagesIntentPolicyTests: XCTestCase {
  func testReadRequests() {
    for prompt in ["check what my sister texted me last", "what did Sam text me?", "did Mom message me today",
                   "check my messages from Alex", "any new texts from Jordan?", "what did Sam say in our chat",
                   "what did Sam say on iMessage", "show me the last text from Dad", "what didn’t she text me back about",
                   "What did Sam text me last?", "last text from Alex", "has Jordan texted me?",
                   "read my latest messages", "any new messages from Mom",
                   "what was the last message Sam sent me", "did Alex reply", "check messages", "check my messages",
                   "did Alex reply yet?", "has Mom texted back?"] {
      XCTAssertTrue(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }

  func testSendRequests() {
    for prompt in ["text Alex that I'm running late", "send her a message saying hey", "send Sam a text saying hi",
                   "message Sam that dinner is at 7", "reply to Mom with ok", "tell Jordan on iMessage I'm here",
                   "iMessage Alex the address", "Text Alex that I’m running late", "please text Mom that I landed",
                   "can you send Alex a message saying I'm late", "tell Sam by text that I'm here",
                   "send a message to Alex saying hi", "text the group that I'm late", "text her I'm on my way",
                   "message my sister saying happy birthday", "text Mom back that I'm fine"] {
      XCTAssertTrue(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }

  func testNearMissesDoNotInfer() {
    for prompt in ["what does this error message mean", "write a commit message for this diff",
                   "what does this message mean", "write a message to my landlord about rent",
                   "explain how a message queue works", "send me a summary", "tell me about Denmark",
                   "send an email to Alex", "summarize this text", "write a text for my slide",
                   #"what does "text Alex" mean"#, "`message Sam` is a command",
                   "the error message says file not found", "what's the exit message from this script",
                   "message me a joke", "text me a summary", "draft a text to my boss asking for Friday off",
                   "reply to this email politely", "explain this message broker", "what's on my screen",
                   "what does “text Alex” mean", "translate this text to French", "check the log message",
                   "text editor recommendations", "what is a text message", "send me the last text you wrote",
                   // Nouns that start a draft, not send verbs.
                   "text classification with BERT", "text wrapping in css", "text alignment in swiftui",
                   "text generation models", "message passing in Erlang explained", "explain actors and message passing",
                   "message brokers compared", "message types in protobuf", "message board software recommendations",
                   "sms gateway providers", "SMS marketing best practices", "imessage not working on mac",
                   "message types that protobuf supports", "text messages vs email for marketing",
                   // "my … text from" without a read request.
                   "fix my text with proper punctuation", "rewrite my text from above",
                   "in your last message from earlier you said X", "what was the last message you sent me",
                   "reply to reviewer 2 politely", "did you reply to my question", "check messages in the kafka queue"] {
      XCTAssertFalse(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }

  func testFollowUpCues() {
    for prompt in ["send her a message saying hey", "reply with sounds good", "tell him I'm on my way",
                   "text them back", "what about Alex?", "what else did she say", "send it",
                   "message her that I'm late", "Tell her I’ll be there"] {
      XCTAssertTrue(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
    for prompt in ["yes, send the message", "send this message", "reply to him", "text Sam back"] {
      XCTAssertTrue(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
    for prompt in ["what's 2 + 2", "thanks!", "explain photosynthesis", #"what does "send it" mean"#,
                   "translate this text", "what does this error message mean", "send me a summary",
                   "write a commit message", "explain message passing", "text classification with BERT",
                   "summarize the text above", "send us the details"] {
      XCTAssertFalse(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
  }
}

final class ThinkIntentTests: XCTestCase {
  func testThinkCues() {
    for p in ["think hard about this", "think carefully: which plan is cheaper?", "think deeply about it",
              "take your time and compare them", "walk me through it step by step", "reason it through",
              "Think harder about this one", "please think it through carefully",
              "/search think hard about the latest news"] {
      XCTAssertTrue(ThinkCommand.isRequested(by: p), p)
    }
    for p in ["I think it's broken", "what do you think of this?", #"what does "think hard" mean"#,
              "do you think it will rain", "`step by step` is a phrase", "I thought hard about it"] {
      XCTAssertFalse(ThinkCommand.isRequested(by: p), p)
    }
  }
}

final class SelectionIntentPolicyTests: XCTestCase {
  func testEditAndTranslate() {
    for p in ["rewrite this", "make it shorter", "make this more formal", "make it friendlier",
              "fix the grammar", "fix the typos", "reword this", "proofread it", "tighten this up",
              "shorten this", "Please rewrite this", "fix the spelling", "make it longer",
              "can you make this a bit more casual", "polish this", "polish it up", "polish my intro"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .edit, p)
    }
    for p in ["translate this", "translate it to Spanish", "translate into Japanese",
              "please translate this and fix the grammar", "Translate", "can you translate this to Spanish",
              "help me translate it into French"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .translate, p)
    }
    for p in ["what does this mean?", "who wrote this?", "summarize it", #"what does "rewrite this" mean"#,
              "is the grammar right?", "how would you translate idioms in general?",
              "Polish translation of this", "what's the Polish word for this?", "is it hard to translate this idiom?",
              "why is this hard to translate?"] {
      XCTAssertNil(SelectionIntentPolicy.command(for: p), p)
    }
  }
}

final class ComposerIntentResolveTests: XCTestCase {
  private func resolve(_ draft: String, hasSelection: Bool = false, hasFileSelection: Bool = false,
                       hasScreenshot: Bool = false, previousTurnUsedMessages: Bool = false,
                       infersCommands: Bool = true, searchesAutomatically: Bool = false,
                       dismissed: Set<SlashCommand> = []) -> ComposerIntent {
    ComposerIntent.resolve(.init(draft: draft, hasSelection: hasSelection, hasFileSelection: hasFileSelection,
                                 hasScreenshot: hasScreenshot, previousTurnUsedMessages: previousTurnUsedMessages,
                                 infersCommands: infersCommands, searchesAutomatically: searchesAutomatically,
                                 dismissed: dismissed))
  }

  func testInfersMessages() {
    let intent = resolve("what did Sam text me")
    XCTAssertEqual(intent.inferred, [.messages])
    XCTAssertTrue(intent.messages)
    XCTAssertEqual(intent.submissionPrompt, "what did Sam text me")
  }

  func testDismissedInferenceDoesNotApply() {
    let intent = resolve("what did Sam text me", dismissed: [.messages])
    XCTAssertEqual(intent.inferred, [])
    XCTAssertFalse(intent.messages)
  }

  func testSettingOffInfersOnlySearch() {
    for draft in ["what did Sam text me", "think hard about this", "make it shorter", "translate this"] {
      let intent = resolve(draft, hasSelection: true, infersCommands: false)
      XCTAssertEqual(intent.inferred, [], draft)
      XCTAssertFalse(intent.messages || intent.think || intent.edit || intent.translate, draft)
    }
    let search = resolve("what's the latest AI news", infersCommands: false, searchesAutomatically: true)
    XCTAssertEqual(search.inferred, [.search])
  }

  func testEditAndTranslateNeedASelection() {
    XCTAssertEqual(resolve("make it shorter").inferred, [])
    let edit = resolve("make it shorter", hasSelection: true)
    XCTAssertEqual(edit.inferred, [.edit])
    XCTAssertTrue(edit.edit)
    XCTAssertEqual(edit.submissionPrompt, "/edit make it shorter")

    XCTAssertEqual(resolve("translate this").inferred, [])
    let translate = resolve("translate this", hasSelection: true)
    XCTAssertEqual(translate.inferred, [.translate])
    XCTAssertTrue(translate.submissionPrompt.hasPrefix("/translate "), translate.submissionPrompt)
  }

  func testTypedTranslateDropsInferredEdit() {
    let intent = resolve("/translate make it shorter", hasSelection: true)
    XCTAssertFalse(intent.edit)
    XCTAssertTrue(intent.translate)
    XCTAssertEqual(intent.inferred, [])
  }

  func testTypedEditKeepsWinningOverInferredTranslate() {
    let intent = resolve("/edit translate this", hasSelection: true)
    XCTAssertTrue(intent.edit)
    XCTAssertFalse(intent.translate)
    XCTAssertEqual(intent.inferred, [])
  }

  func testSearchAndThinkTogether() {
    let intent = resolve("think hard: what's the latest AI news", searchesAutomatically: true)
    XCTAssertEqual(intent.inferred, [.search, .think])
    XCTAssertTrue(intent.search)
    XCTAssertTrue(intent.submissionPrompt.hasPrefix("/think "), intent.submissionPrompt)
  }

  func testSearchNeedsAutomaticSearch() {
    XCTAssertEqual(resolve("what's the latest AI news").inferred, [])
    XCTAssertEqual(resolve("what's the latest AI news", searchesAutomatically: true, dismissed: [.search]).inferred, [])
    XCTAssertFalse(resolve("what's the latest AI news", searchesAutomatically: true, dismissed: [.search]).search)
  }

  func testMessagesDropsInferredSearch() {
    let intent = resolve("what's the latest news Sam texted me", searchesAutomatically: true)
    XCTAssertTrue(intent.messages)
    XCTAssertFalse(intent.search)
    XCTAssertEqual(intent.inferred, [.messages])

    let typed = resolve("/messages what's the latest news Sam sent", searchesAutomatically: true)
    XCTAssertFalse(typed.search)
    XCTAssertEqual(typed.inferred, [])
  }

  func testTypedSearchDropsInferredMessages() {
    let intent = resolve("/search what did Sam text me")
    XCTAssertTrue(intent.search)
    XCTAssertFalse(intent.messages)
    XCTAssertEqual(intent.inferred, [])
  }

  func testAttachmentsDropInferredMessages() {
    let files = resolve("what did Sam text me", hasFileSelection: true)
    XCTAssertFalse(files.messages)
    XCTAssertEqual(files.inferred, [])
    let filesSearch = resolve("what's the latest AI news", hasFileSelection: true, searchesAutomatically: true)
    XCTAssertFalse(filesSearch.search)
    XCTAssertEqual(filesSearch.inferred, [])
    let screenshot = resolve("what did Sam text me", hasScreenshot: true)
    XCTAssertFalse(screenshot.messages)
    XCTAssertEqual(screenshot.inferred, [])
  }

  func testScreenIsNeverInferredAndTypedScreenInfersNothing() {
    XCTAssertEqual(resolve("/screen what did Sam text me").inferred, [])
    XCTAssertEqual(resolve("/snapshot think hard about this").inferred, [])
    for draft in ["what's on my screen", "look at my screen", "take a screenshot", "snapshot this window"] {
      let intent = resolve(draft, searchesAutomatically: true)
      XCTAssertEqual(intent.inferred, [], draft)
      XCTAssertFalse(intent.typed.screen, draft)
    }
  }

  func testRequestAfterCaptureRunsOnlyTypedCommands() {
    let context = ComposerIntent.Context(draft: "think hard: what's the latest AI news", hasScreenshot: true,
                                         searchesAutomatically: true)
    XCTAssertEqual(ComposerIntent.resolve(context).inferred, [.search, .think])
    XCTAssertEqual(ComposerIntent.resolve(context.recognizingCommands(true)), ComposerIntent.resolve(context))
    let afterCapture = ComposerIntent.resolve(context.recognizingCommands(false))
    XCTAssertEqual(afterCapture.inferred, [])
    XCTAssertFalse(afterCapture.search, "No chip was shown, so nothing may search automatically")
    XCTAssertFalse(afterCapture.think)

    // What a typed `/screen /search /think` draft becomes once the capture consumes `/screen`.
    let typed = SlashCommand.removing([.screen, .snapshot], from: "/screen /search /think what's the latest AI news")
    var typedContext = context
    typedContext.draft = typed
    let typedAfterCapture = ComposerIntent.resolve(typedContext.recognizingCommands(false))
    XCTAssertTrue(typedAfterCapture.search)
    XCTAssertTrue(typedAfterCapture.think)
    XCTAssertEqual(typedAfterCapture.inferred, [])
  }

  func testFollowUpCarriesMessagesOnlyWithTheFlag() {
    XCTAssertEqual(resolve("send her a message saying hi", previousTurnUsedMessages: true).inferred, [.messages])
    XCTAssertEqual(resolve("what about Alex?", previousTurnUsedMessages: true).inferred, [.messages])
    XCTAssertEqual(resolve("what about Alex?").inferred, [])
    XCTAssertEqual(resolve("explain photosynthesis", previousTurnUsedMessages: true).inferred, [])
  }

  func testTypedCommandsGetNoChip() {
    let intent = resolve("/messages hi")
    XCTAssertTrue(intent.messages)
    XCTAssertEqual(intent.inferred, [])
    XCTAssertEqual(resolve("/think think hard about this").inferred, [])
    XCTAssertEqual(resolve("/edit make it shorter", hasSelection: true).inferred, [])
  }

  func testQuotedTextNeverInfers() {
    XCTAssertEqual(resolve(#"what does "text Alex that I'm late" mean"#, hasSelection: true).inferred, [])
    XCTAssertEqual(resolve("explain `think hard`", hasSelection: true).inferred, [])
  }

  func testDismissedMessagesLetsSearchApply() {
    // A follow-up after a Messages turn that also reads as news. News someone texted the person never
    // searches (owner, 2026-10-27; `WebSearchTests.testNewsSomeoneTextedMeNeverSearches`).
    let draft = "what about the latest election results?"
    XCTAssertEqual(resolve(draft, previousTurnUsedMessages: true, searchesAutomatically: true).inferred, [.messages])
    let intent = resolve(draft, previousTurnUsedMessages: true, searchesAutomatically: true, dismissed: [.messages])
    XCTAssertEqual(intent.inferred, [.search])
    XCTAssertFalse(intent.messages)
  }

  func testQuestionTextNormalizesWhitespaceApostrophesAndQuotes() {
    XCTAssertEqual(WebSearchPolicy.questionText("  What’s\tthe\r\n\u{00A0}latest\u{2028}NEWS \"Sam\"  "),
                   "what's the latest news")
    XCTAssertEqual(WebSearchPolicy.questionText(" \n "), "")
    XCTAssertEqual(WebSearchPolicy.questionText("Whats new? whatsapp"), "what's new? whatsapp")
  }

  func testResolvingIsFast() {
    // A generous wall-clock bound that only catches large regressions, so it isn't flaky on CI.
    // One draft infers Messages (which skips the search check); the other runs every matcher.
    for sentence in ["what did Sam text me about dinner, think it over and make it shorter please. ",
                     "explain the 2026 election results in Denmark, step by step, and rewrite this summary. "] {
      let draft = String(String(repeating: sentence, count: 30).prefix(2_000))
      let context = ComposerIntent.Context(draft: draft, hasSelection: true, previousTurnUsedMessages: false,
                                           searchesAutomatically: true)
      let start = Date()
      for _ in 0..<1_000 { _ = ComposerIntent.resolve(context) }
      XCTAssertLessThan(Date().timeIntervalSince(start), 5, sentence)
    }
  }
}

/// The chips, rendered in both composers and in the real shell.
@MainActor
final class ComposerIntentChipsTests: XCTestCase {
  private typealias Fixture = EnigmaMainWindowTests.Fixture
  private typealias Host = EnigmaMainWindowTests.Host

  private var menu: ModeAndModelMenu {
    ModeAndModelMenu(mode: .local, isBusy: false, hasActiveRequest: false,
                     localModels: [.init(id: "f", name: "Fixture 8B", supportsVision: false)], selectedLocalID: "f",
                     cloudProvider: .anthropic, cloudModels: [], selectedCloudID: "")
  }
  private let actions = ModeAndModelMenu.Actions(chooseMode: { _ in }, selectLocalModel: { _ in },
    selectCloudModel: { _ in }, findModel: {}, importModel: {}, openSettings: {})

  private func render(_ view: some View, fixture: Fixture, size: CGSize) -> Host {
    Host(fixture, size: size, test: self, root: AnyView(view
      .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
      .enigmaTheme(.paper)
      .enigmaMenuHost()))
  }

  private func mainComposer(_ commands: [SlashCommand], fixture: Fixture,
                            dismiss: @escaping (SlashCommand) -> Void = { _ in }) -> some View {
    EnigmaComposer(
      text: .constant("what did Sam text me"), isFocused: .constant(false), isEnabled: true,
      availableCommands: SlashCommand.allCases, insertion: nil, opensSuggestionsBelow: true, submit: {},
      files: fixture.files, isAttachDisabled: false, attach: {}, beginCommand: {},
      route: nil, menu: menu, menuActions: actions, isMenuPresented: .constant(false), menuClosed: {},
      isResponding: false, canSend: true, send: {}, stop: {},
      inferredCommands: commands, dismissInferred: dismiss)
      .frame(width: 680)
      .padding(20)
  }

  private func compactComposer(_ commands: [SlashCommand], fixture: Fixture) -> some View {
    EnigmaCompactComposer(
      text: .constant("what did Sam text me"), isFocused: .constant(false), isEnabled: true,
      availableCommands: SlashCommand.allCases, placeholder: "Ask anything", submit: {},
      files: fixture.files, isAttachDisabled: false, attach: {}, chip: "● local · Fixture 8B",
      menu: menu, menuActions: actions, isMenuPresented: .constant(false), menuClosed: {},
      isResponding: false, canSend: true, send: {}, stop: {},
      inferredCommands: commands, dismissInferred: { _ in })
      .frame(width: 680)
  }

  func testMainComposerShowsRecognizedCommandsAndDismissesThem() async throws {
    let fixture = try await Fixture(test: self)
    var dismissed: [SlashCommand] = []
    let host = render(mainComposer([.messages, .think], fixture: fixture) { dismissed.append($0) },
                      fixture: fixture, size: CGSize(width: 720, height: 160))
    try await waitForUI("the recognized chips", in: host.view) {
      host.shows("Recognized messages") && host.shows("Recognized think")
    }
    XCTAssertFalse(host.shows("Recognized search"))
    try await clickTestControl("Recognized messages", in: host.view)
    XCTAssertEqual(dismissed, [.messages])
  }

  /// Saved only when `ENIGMA_SNAPSHOT_DIR` is set, in Paper and Ink.
  func testRecognizedChipsScreenshot() throws {
    try EnigmaSnapshot.save("composer-recognized-commands", size: CGSize(width: 300, height: 40)) {
      ComposerIntentChips(commands: [.messages, .search, .think], dismiss: { _ in }).padding(10)
    }
  }

  func testMainComposerWithoutRecognizedCommandsShowsNoChip() async throws {
    let fixture = try await Fixture(test: self)
    let host = render(mainComposer([], fixture: fixture), fixture: fixture, size: CGSize(width: 720, height: 160))
    try await waitForUI("the composer", in: host.view) { host.shows("Send message") }
    for command in SlashCommand.allCases { XCTAssertFalse(host.shows("Recognized \(command.rawValue)"), command.rawValue) }
  }

  func testCompactComposerShowsRecognizedCommands() async throws {
    let fixture = try await Fixture(test: self)
    let host = render(compactComposer([.messages], fixture: fixture), fixture: fixture, size: CGSize(width: 720, height: 80))
    try await waitForUI("the recognized chip", in: host.view) { host.shows("Recognized messages") }
    let empty = render(compactComposer([], fixture: fixture), fixture: fixture, size: CGSize(width: 720, height: 80))
    try await waitForUI("the compact composer", in: empty.view) { empty.shows("Send message") }
    XCTAssertFalse(empty.shows("Recognized messages"))
  }

  func testShellChipFollowsTheDraftAndDismissingTurnsItOff() async throws {
    let fixture = try await Fixture(test: self)
    fixture.defaults.set(true, forKey: ComposerIntent.inferCommandsKey)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self,
                    root: AnyView(fixture.shell().defaultAppStorage(fixture.defaults)))
    try await waitForUI("the composer", in: host.view) { host.shows("Send message") }
    XCTAssertFalse(host.shows("Recognized messages"))
    fixture.screen.draft = "what did Sam text me"
    try await waitForUI("the messages chip", in: host.view) { host.shows("Recognized messages") }
    try await clickTestControl("Recognized messages", in: host.view)
    try await waitForUI("the dismissed chip", in: host.view) { !host.shows("Recognized messages") }
    fixture.screen.draft = "what did Sam text me today"
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(host.shows("Recognized messages"), "A dismissal lasts for the draft")
    fixture.screen.draft = ""
    try await waitForUI("the cleared draft", in: host.view) { composerEditor(in: host.view)?.string == "" }
    fixture.screen.draft = "what did Sam text me"
    try await waitForUI("the chip back for a new draft", in: host.view) { host.shows("Recognized messages") }
    fixture.screen.draft = "/messages what did Sam text me"
    try await waitForUI("no chip for a typed command", in: host.view) { !host.shows("Recognized messages") }
  }

  func testShellRecognizesNothingByDefault() async throws {
    let fixture = try await Fixture(test: self)
    XCTAssertNil(fixture.defaults.object(forKey: ComposerIntent.inferCommandsKey))
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self,
                    root: AnyView(fixture.shell().defaultAppStorage(fixture.defaults)))
    try await waitForUI("the composer", in: host.view) { host.shows("Send message") }
    fixture.screen.draft = "what did Sam text me"
    try await waitForUI("the draft in the editor", in: host.view) { composerEditor(in: host.view)?.string == fixture.screen.draft }
    XCTAssertFalse(host.shows("Recognized messages"), "Off until the person turns it on")
  }

  func testShellHidesChipsWhenRecognitionIsOff() async throws {
    let fixture = try await Fixture(test: self)
    fixture.defaults.set(false, forKey: ComposerIntent.inferCommandsKey)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self,
                    root: AnyView(fixture.shell().defaultAppStorage(fixture.defaults)))
    try await waitForUI("the composer", in: host.view) { host.shows("Send message") }
    fixture.screen.draft = "what did Sam text me"
    try await waitForUI("the draft in the editor", in: host.view) { composerEditor(in: host.view)?.string == fixture.screen.draft }
    XCTAssertFalse(host.shows("Recognized messages"))
  }
}


