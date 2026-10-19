import Foundation
import XCTest
@testable import Enigma

final class ChatContextTests: XCTestCase {
  private let budget = ContextBudget(contextWindow: 100, outputTokens: 20, overheadTokens: 10)

  func testInputBoundaryReservesOutputAndOverhead() throws {
    for length in [69, 70] {
      let current = ChatMessage(role: .user, content: String(repeating: "x", count: length))
      let prepared = try prepare([current])
      XCTAssertEqual(prepared.messages, [current])
      XCTAssertLessThanOrEqual(prepared.inputTokenCount + budget.outputTokens + budget.overheadTokens, 100)
    }
    XCTAssertThrowsError(try prepare([ChatMessage(role: .user, content: String(repeating: "x", count: 71))])) {
      XCTAssertEqual($0 as? ChatContextError, .oversizedPrompt(inputLimit: 70))
    }
  }

  func testTrimmingRetainsWholeRecentTurnsAndCurrentMessageExactlyOnce() throws {
    let messages = [
      ChatMessage(role: .user, content: String(repeating: "old", count: 20)),
      ChatMessage(role: .assistant, content: "old answer"),
      ChatMessage(role: .user, content: "recent question"),
      ChatMessage(role: .assistant, content: "recent answer"),
      ChatMessage(role: .user, content: "latest question"),
    ]
    let original = messages
    let prepared = try prepare(messages)
    XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
    XCTAssertEqual(prepared.omittedMessageCount, 2)
    XCTAssertNotNil(prepared.notice)
    XCTAssertEqual(messages, original)
  }

  func testUnansweredAndEmptyTurnsDoNotLeaveOrphanedAssistantContext() throws {
    let current = ChatMessage(role: .user, content: "current")
    let messages = [
      ChatMessage(role: .assistant, content: "orphan"),
      ChatMessage(role: .user, content: "failed"),
      ChatMessage(role: .assistant, content: ""),
      ChatMessage(role: .user, content: "unanswered"),
      ChatMessage(role: .user, content: "answered"),
      ChatMessage(role: .assistant, content: "partial but useful"),
      current,
    ]
    let prepared = try prepare(messages)
    XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
    XCTAssertEqual(prepared.omittedMessageCount, 4)
  }

  func testOversizedRecentTurnDoesNotPullInDisconnectedOlderTurns() throws {
    let messages = [
      ChatMessage(role: .user, content: "old"),
      ChatMessage(role: .assistant, content: "old answer"),
      ChatMessage(role: .user, content: "recent"),
      ChatMessage(role: .assistant, content: String(repeating: "x", count: 80)),
      ChatMessage(role: .user, content: "current"),
    ]
    XCTAssertEqual(try prepare(messages).messages, Array(messages.suffix(1)))
  }

  func testEveryCloudRouteBoundsEscapedUnicodeAndManualModels() throws {
    for provider in CloudProviderID.allCases {
      for model in ["gpt-5.6-luna", "manual-unknown-model"] {
        let messages = [
          ChatMessage(role: .user, content: String(repeating: "older 👩🏽‍💻\n\"\\", count: 10_000)),
          ChatMessage(role: .assistant, content: "older reply"),
          ChatMessage(role: .user, content: "recent"),
          ChatMessage(role: .assistant, content: "answer"),
          ChatMessage(role: .user, content: "你好 👩🏽‍💻\n\"\\ current"),
        ]
        let request = request(messages, provider: provider, model: model)
        let prepared = try CloudContext.prepare(request)
        XCTAssertEqual(prepared.messages, Array(messages.suffix(3)))
        XCTAssertEqual(request.messages, messages)
        XCTAssertLessThanOrEqual(prepared.inputTokenCount, prepared.budget.availableInputTokens)
        XCTAssertEqual(try CloudContext.prepare(self.request(prepared.messages, provider: provider, model: model)).messages, prepared.messages)
      }
      let limit = ModelContextPolicy.cloud(provider: provider, modelID: "manual").availableInputTokens
      XCTAssertThrowsError(try CloudContext.prepare(request([
        ChatMessage(role: .user, content: String(repeating: "x", count: limit + 1)),
      ], provider: provider, model: "manual")))
    }
  }

  func testCloudSerializedInputJustUnderAtAndOverBudget() throws {
    for provider in CloudProviderID.allCases {
      let budget = ModelContextPolicy.cloud(provider: provider, modelID: "manual")
      let wrapperCount = try CloudContext.inputTokenCount([ChatMessage(role: .user, content: "x")], provider: provider) - 1
      let maximumLength = budget.availableInputTokens - wrapperCount
      for length in [maximumLength - 1, maximumLength] {
        let prepared = try CloudContext.prepare(request([
          ChatMessage(role: .user, content: String(repeating: "x", count: length)),
        ], provider: provider, model: "manual"))
        XCTAssertEqual(prepared.inputTokenCount, length + wrapperCount)
      }
      XCTAssertThrowsError(try CloudContext.prepare(request([
        ChatMessage(role: .user, content: String(repeating: "x", count: maximumLength + 1)),
      ], provider: provider, model: "manual")))
    }
  }

  func testModelMetadataAndAutoSharePolicyWithoutAssumingManual128K() {
    for provider in CloudProviderID.allCases {
      for id in ["gpt-5.6-luna", "my-manual-model"] {
        let model = CloudModel(id: id, displayName: id, provider: provider)
        let cloud = AutoRouter.CloudConfiguration(provider: provider, modelID: id)
        XCTAssertEqual(cloud.capabilities.maximumContextTokens, model.contextBudget.contextWindow)
      }
      XCTAssertLessThan(ModelContextPolicy.cloud(provider: provider, modelID: "manual").contextWindow, 128_000)
    }
  }

  func testAsyncTokenizerPreservesTheSameHistoryAndThinkingPolicy() async throws {
    var current = ChatMessage(role: .user, content: "Current question")
    current.extendedThinking = true
    let messages = [ChatMessage(role: .assistant, content: "Orphan"),
      ChatMessage(role: .user, content: String(repeating: "Old text ", count: 500)),
      ChatMessage(role: .assistant, content: "Old answer"),
      ChatMessage(role: .user, content: "Recent question"),
      ChatMessage(role: .assistant, content: "Recent answer"), current]
    let budget = ContextBudget(contextWindow: 1_024, outputTokens: 512, overheadTokens: 64)
    let sync = try ChatContextPreparer.prepare(messages, budget: budget) { $0.reduce(0) { $0 + $1.content.count } }
    let async = try await ChatContextPreparer.prepareAsync(messages, budget: budget) { $0.reduce(0) { $0 + $1.content.count } }
    XCTAssertEqual(async, sync)
    XCTAssertTrue(async.messages.last?.content.hasPrefix(ThinkCommand.guidance) == true)
    XCTAssertEqual(async.messages.map(\.id), Array(messages.suffix(3)).map(\.id))
  }

  func testNativeFormatterUsesAllMessagesAndAssistantGenerationPrefix() throws {
    let messages = [
      ChatMessage(role: .user, content: "Remember blåbær"),
      ChatMessage(role: .assistant, content: "I will remember blåbær"),
      ChatMessage(role: .user, content: "What did I ask you to remember?"),
    ]
    let formatted = try format(messages, template: "chatml")
    XCTAssertEqual(formatted, "<|im_start|>user\n\(ChatResponseStyle.instructions)\n\nRemember blåbær<|im_end|>\n<|im_start|>assistant\nI will remember blåbær<|im_end|>\n<|im_start|>user\nWhat did I ask you to remember?<|im_end|>\n<|im_start|>assistant\n")
    let other = try format([ChatMessage(role: .user, content: "Separate chat")], template: "chatml")
    XCTAssertFalse(other.contains("blåbær"))
    XCTAssertEqual(other, "<|im_start|>user\n\(ChatResponseStyle.instructions)\n\nSeparate chat<|im_end|>\n<|im_start|>assistant\n")
  }

  func testNativeFormatterDoesNotSilentlyDropHistoryForUnsupportedTemplates() throws {
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello")], template: "unsupported-template"))
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello")], template: ""))
    XCTAssertThrowsError(try format([ChatMessage(role: .user, content: "Hello\0hidden")], template: "chatml"))
  }

  private func prepare(_ messages: [ChatMessage]) throws -> PreparedConversation {
    try ChatContextPreparer.prepare(messages, budget: budget) { $0.reduce(0) { $0 + $1.content.utf8.count } }
  }

  private func request(_ messages: [ChatMessage], provider: CloudProviderID, model: String) -> ChatRequest {
    ChatRequest(sessionID: UUID(), messages: messages,
                route: Route(mode: .cloud, providerID: provider.rawValue, modelID: model, usesNetwork: true))
  }

  private func format(_ messages: [ChatMessage], template: String) throws -> String {
    try LocalChatBridge.formatted(messages, template: template)
  }
}

final class ChatMarkdownTests: XCTestCase {
  func testRepairsClearFormattingAndWhitespace() {
    XCTAssertEqual(ChatResponseNormalizer.normalize("\\### Heading"), "### Heading")
    XCTAssertEqual(ChatResponseNormalizer.normalize(#"\* item"#), "* item")
    XCTAssertEqual(ChatResponseNormalizer.normalize(#"1\. item"#), "1. item")
    XCTAssertEqual(ChatResponseNormalizer.normalize(#"\> quote"#), "> quote")
    XCTAssertEqual(ChatResponseNormalizer.normalize(#"\*\*bold\*\* and \*italic\*"#), "**bold** and *italic*")
    XCTAssertEqual(ChatResponseNormalizer.normalize("a\u{00a0}b\u{202f}c\u{200b}\r\nd"), "a b c\nd")
  }

  func testPreservesCodePathsAndAmbiguousEscapes() {
    for input in [#"C:\Users\leo\notes.md"#, #"\\server\share\*.txt"#, #"Use \n or \d+ and an unmatched \*"#,
                  "`\\*literal\\*` and ``a ` \\###``", "    \\* code\u{00a0}  ",
                  "```swift\n\\### code\u{00a0}\n```", "~~~\n\\* code\n~~~",
                  "```\n\\### unfinished", "`\\*unfinished", "`code\n\\*literal\\*\nend`", "``code\n\\### untouched\nend``"] {
      XCTAssertEqual(ChatResponseNormalizer.normalize(input), input)
    }
  }

  func testRenderedPathsKeepLiteralBackslashes() {
    for path in [#"C:\Users\leo\*.txt"#, #"\\server\share\_notes"#, #".\folder\file.txt"#] {
      XCTAssertEqual(ChatMarkdown.blocks("Path: " + path).map { String($0.text.characters) }.joined(), "Path: " + path)
    }
    XCTAssertEqual(ChatResponseNormalizer.normalize("\\#\\#\\# Heading"), "### Heading")
    XCTAssertEqual(ChatResponseNormalizer.normalize(#"\[Example\]\(https://example.com\)"#), "[Example](https://example.com)")
  }

  func testNormalizationIsIdempotentAndStreamingSafe() {
    let source = "\\### Heading\n\n\\*\\*bold\\*\\*\n\n```swift\nlet path = #\"C:\\temp\"#\n```"
    for count in 0...source.count {
      let prefix = String(source.prefix(count))
      let normalized = ChatResponseNormalizer.normalize(prefix)
      XCTAssertEqual(ChatResponseNormalizer.normalize(normalized), normalized)
      _ = ChatMarkdown.blocks(prefix)
    }
  }

  /// Streaming blocks equal whole-reply blocks at every step: same ids, text
  /// and attributes, and presentation intents.
  @MainActor
  func testStreamingBlocksMatchParsingTheWholeReplyAtEveryPrefix() {
    var documents = Self.markdownEdgeCases
    var generator = SplitMix(seed: 7)
    for _ in 0..<20 {
      let pieces = (0..<Int.random(in: 6...12, using: &generator)).map { _ in
        Self.markdownPieces.randomElement(using: &generator)!
      }
      documents.append(pieces.reduce("") { $0 + $1 + (Bool.random(using: &generator) ? "\n\n" : "\n") })
    }
    for document in documents {
      let stream = ChatMarkdownStream()
      let characters = Array(document)
      for count in 0...characters.count {
        let prefix = String(characters.prefix(count))
        let expected = ChatMarkdown.blocks(prefix)
        let streamed = stream.blocks(prefix)
        guard streamed.count == expected.count, zip(streamed, expected).allSatisfy({
          $0.id == $1.id && $0.text == $1.text && $0.components == $1.components
        }) else {
          XCTFail("Streamed blocks differ from the whole reply's after \(count) characters of \(document.debugDescription)")
          break
        }
      }
    }
  }

  /// Each update parses only the reply's unsettled end, however long the reply is.
  @MainActor
  func testStreamingParsesOnlyTheUnsettledEndOfALongReply() {
    let paragraph = "A paragraph with **bold**, `code`, and a [link](https://example.com) that runs for a while. "
    var reply = ""
    for index in 0..<80 {
      reply += index.isMultiple(of: 10) ? "## Section \(index / 10)\n\n" : ""
      reply += String(repeating: paragraph, count: 3) + "\n\n"
      reply += index.isMultiple(of: 7) ? "```swift\nlet value = \(index)\n\nprint(value)\n```\n\n" : ""
    }
    XCTAssertGreaterThan(reply.utf8.count, 20_000)
    let stream = ChatMarkdownStream()
    var largest = 0
    var shown = ""
    var characters = Substring(reply)
    while !characters.isEmpty {
      shown += characters.prefix(7)
      characters = characters.dropFirst(7)
      _ = stream.blocks(shown)
      if shown.utf8.count > 5_000 { largest = max(largest, stream.lastParsedLength) }
    }
    XCTAssertLessThan(largest, 1_000, "An update parses the last block or two, not the whole reply")
    let expected = ChatMarkdown.blocks(reply)
    let streamed = stream.blocks(reply)
    XCTAssertEqual(streamed.map(\.id), expected.map(\.id))
    XCTAssertEqual(streamed.map(\.text), expected.map(\.text))

    // A reply that changes rather than grows starts over.
    let edited = "Different text\n\nand more"
    XCTAssertEqual(stream.blocks(edited).map(\.text), ChatMarkdown.blocks(edited).map(\.text))
    XCTAssertEqual(stream.lastParsedLength, edited.utf8.count)
  }

  private static let markdownEdgeCases = [
    "# Heading\n\n- **bold** and *italic* and `code` and [link](https://example.com)\n- second\n\n3. third\n\n> quote\n\n```swift\nlet path = #\"C:\\temp\"#\n```\n\n| A | B |\n|---|---|\n| x | y |",
    "1. one\n\n2. two\n\nPara\n\n3. three\n\n5. five",
    "- a\n\n- b\n\n  continued in b\n\n* c\n\n+ d\n\nAfter the list",
    "Para\n\n```\ncode\n\nmore code\n\n```\n\nAfter\n\n~~~\nx\n\n~~~~\n\nEnd",
    "Para\n\n    ```\n    indented\n\nNot code\n\n   ```\ninside a fence\n\n      ```\nstill inside\n   ```\n\nOut",
    "| a | b |\n|---|---|\n| 1 | 2 |\n\n| c | d |\n|---|---|\n| 3 | 4 |\n\nText",
    "> one\n\n> two\n\nTitle\n===\n\n---\n\n* * *\n\nText",
    "Start `unfinished span\ncontinues\n\nNew \\*\\*bold\\*\\* and C:\\Users\\leo\\*.txt",
    "Text with [ref][x]\n\nMore text\n\n[x]: https://example.com",
    "Text\n\n<!-- note\n\nstill a comment -->\n\nAfter",
    "- item\n  ```\n  code\n\nColumn zero ends the item\n\n1990 was a year\n\n12) twelve\n\n1.5 is a number",
    "Tab\n\n\tindented code\n\nline\r\n\r\nwindows\n\n#hashtag and # heading",
  ]

  private static let markdownPieces = [
    "Plain paragraph with **bold** text.", "Another line that wraps\nonto a second line.", "# Heading", "### Small heading",
    "- bullet", "- bullet\n  - nested", "1. first", "2. second", "10) tenth", "> quoted", "> quoted\nlazy line",
    "```\ncode\n\nmore\n```", "```swift\nlet x = 1\n", "~~~\ntilde\n~~~", "    indented code", "---", "Setext\n---",
    "| a | b |\n|---|---|\n| 1 | 2 |", "Inline `code` and a [link](https://example.com).", "`unfinished",
    "\\*\\*escaped\\*\\*", "C:\\Users\\leo\\notes.md", "2024 was a year.", "* star bullet", "+ plus bullet",
    "Term\n: definition-ish", "<div>html</div>", "",
  ]

  func testFullMarkdownParserProducesSemanticBlocksAndInlineStyles() throws {
    let blocks = ChatMarkdown.blocks("# Heading\n\n- **bold** and *italic* and `code` and [link](https://example.com)\n- second\n\n3. third\n\n> quote\n\n```swift\nlet path = #\"C:\\temp\"#\n```\n\n| A | B |\n|---|---|\n| x | y |")
    let kinds = blocks.flatMap { $0.components.map(\.kind) }
    XCTAssertTrue(kinds.contains(.header(level: 1)))
    XCTAssertTrue(kinds.contains(.unorderedList))
    XCTAssertTrue(kinds.contains(.orderedList))
    XCTAssertTrue(kinds.contains(.blockQuote))
    XCTAssertTrue(kinds.contains(.codeBlock(languageHint: "swift")))
    XCTAssertEqual(blocks.filter { $0.components.contains { if case .tableCell = $0.kind { return true }; return false } }.count, 4)
    let runs = blocks.flatMap { Array($0.text.runs) }
    XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    XCTAssertTrue(runs.contains { $0.link == URL(string: "https://example.com") })
  }
}

/// A seeded generator, so generated test documents are the same every run.
struct SplitMix: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
