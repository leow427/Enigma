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
