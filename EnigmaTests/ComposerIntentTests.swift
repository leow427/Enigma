import Foundation
import XCTest
@testable import Enigma

final class MessagesIntentPolicyTests: XCTestCase {
  func testReadRequests() {
    for prompt in ["check what my sister texted me last", "what did Sam text me?", "did Mom message me today",
                   "check my messages from Alex", "any new texts from Jordan?", "what did Sam say in our chat",
                   "what did Sam say on iMessage", "show me the last text from Dad", "what didn’t she text me back about",
                   "What did Sam text me last?", "last text from Alex", "has Jordan texted me?",
                   "read my latest messages", "any new messages from Mom"] {
      XCTAssertTrue(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }

  func testSendRequests() {
    for prompt in ["text Alex that I'm running late", "send her a message saying hey", "send Sam a text saying hi",
                   "message Sam that dinner is at 7", "reply to Mom with ok", "tell Jordan on iMessage I'm here",
                   "iMessage Alex the address", "Text Alex that I’m running late", "please text Mom that I landed",
                   "can you send Alex a message saying I'm late", "tell Sam by text that I'm here"] {
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
                   "text editor recommendations", "what is a text message", "send me the last text you wrote"] {
      XCTAssertFalse(MessagesIntentPolicy.isRequested(prompt), prompt)
    }
  }

  func testFollowUpCues() {
    for prompt in ["send her a message saying hey", "reply with sounds good", "tell him I'm on my way",
                   "text them back", "what about Alex?", "what else did she say", "send it",
                   "message her that I'm late", "Tell her I’ll be there"] {
      XCTAssertTrue(MessagesIntentPolicy.isFollowUp(prompt), prompt)
    }
    for prompt in ["what's 2 + 2", "thanks!", "explain photosynthesis", #"what does "send it" mean"#] {
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
              "can you make this a bit more casual"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .edit, p)
    }
    for p in ["translate this", "translate it to Spanish", "translate into Japanese",
              "please translate this and fix the grammar", "Translate"] {
      XCTAssertEqual(SelectionIntentPolicy.command(for: p), .translate, p)
    }
    for p in ["what does this mean?", "who wrote this?", "summarize it", #"what does "rewrite this" mean"#,
              "is the grammar right?", "how would you translate idioms in general?"] {
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
    let intent = resolve("what's the latest news Sam texted me", searchesAutomatically: true, dismissed: [.messages])
    XCTAssertEqual(intent.inferred, [.search])
    XCTAssertFalse(intent.messages)
  }

  func testQuestionTextNormalizesWhitespaceApostrophesAndQuotes() {
    XCTAssertEqual(WebSearchPolicy.questionText("  What’s\tthe\r\n\u{00A0}latest\u{2028}NEWS \"Sam\"  "),
                   "what's the latest news")
    XCTAssertEqual(WebSearchPolicy.questionText(" \n "), "")
  }

  func testResolvingIsFast() {
    // One draft infers Messages (which skips the search check); the other runs every matcher.
    for sentence in ["what did Sam text me about dinner, think it over and make it shorter please. ",
                     "explain the 2026 election results in Denmark, step by step, and rewrite this summary. "] {
      let draft = String(String(repeating: sentence, count: 30).prefix(2_000))
      let context = ComposerIntent.Context(draft: draft, hasSelection: true, previousTurnUsedMessages: false,
                                           searchesAutomatically: true)
      let start = Date()
      for _ in 0..<1_000 { _ = ComposerIntent.resolve(context) }
      XCTAssertLessThan(Date().timeIntervalSince(start), 1, sentence)
    }
  }
}


