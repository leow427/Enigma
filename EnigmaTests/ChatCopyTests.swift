import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// What the copy buttons write, and the buttons themselves in a hosted view.
final class ChatCopyTests: XCTestCase {
  // MARK: Terminal commands

  func testTerminalBlockWithPromptsKeepsOnlyTheCommandsWithoutThePrompt() {
    let block = """
    $ brew install llama.cpp
    Updating Homebrew...
    ==> Installing llama.cpp
    % ls -l
    total 0
    """
    XCTAssertEqual(ChatCopy.copyableCode(block, language: "bash"), "brew install llama.cpp\nls -l")
    for language in ["sh", "zsh", "shell", "console", "BASH", "Console"] {
      XCTAssertEqual(ChatCopy.copyableCode("$ pwd\n/tmp", language: language), "pwd", language)
    }
  }

  func testTerminalCommandKeepsItsBackslashContinuationLinesAsTheyAre() {
    let block = """
    $ swift build \\
        -c release \\
        --product enigma
    Compiling...
    $ echo done
    """
    XCTAssertEqual(ChatCopy.copyableCode(block, language: "bash"),
                   "swift build \\\n    -c release \\\n    --product enigma\necho done")
    // A prompt-looking line inside a continuation is still the command's own text.
    XCTAssertEqual(ChatCopy.copyableCode("$ echo a \\\n$ b\nout", language: "sh"), "echo a \\\n$ b")
    // Two backslashes are an escaped backslash, and a trailing space ends the command.
    XCTAssertEqual(ChatCopy.copyableCode("$ echo a \\\\\nout", language: "sh"), "echo a \\\\")
    XCTAssertEqual(ChatCopy.copyableCode("$ echo a \\ \nout", language: "sh"), "echo a \\ ")
    // An unfinished continuation at the end of the block is just the end.
    XCTAssertEqual(ChatCopy.copyableCode("$ echo a \\", language: "sh"), "echo a \\")
  }

  func testTerminalBlockWithoutAPromptIsCopiedAsShown() {
    let script = "# install\nbrew install llama.cpp\n# $ not a prompt\n  $ indented"
    XCTAssertEqual(ChatCopy.copyableCode(script, language: "bash"), script, "`#` and indented `$` are not prompts")
    XCTAssertEqual(ChatCopy.copyableCode("$HOME/bin\n$(pwd)", language: "bash"), "$HOME/bin\n$(pwd)",
                   "A dollar sign needs a space after it to be a prompt")
    XCTAssertEqual(ChatCopy.copyableCode("", language: "bash"), "")
  }

  func testOtherLanguagesAndPlainBlocksAreNeverFiltered() {
    let code = "$ price = 5\n% 3"
    XCTAssertEqual(ChatCopy.copyableCode(code, language: "python"), code)
    XCTAssertEqual(ChatCopy.copyableCode(code, language: nil), code)
    XCTAssertEqual(ChatCopy.copyableCode(code, language: ""), code)
  }

  func testAPromptWithNoCommandAddsNothing() {
    XCTAssertEqual(ChatCopy.copyableCode("$ \n$ ls\nout", language: "bash"), "ls")
    XCTAssertEqual(ChatCopy.copyableCode("$ \nout", language: "bash"), "$ \nout",
                   "Prompts with no command anywhere leave the block as shown, not an empty clipboard")
  }

  func testCodeBlockLanguageAndTextComeFromTheParsedBlock() throws {
    let blocks = ChatMarkdown.blocks("```bash title=\"x\"\n$ ls\nfile\n```\n\n```\nplain\n```\n\n~~~Swift\nlet x = 1\n~~~")
    let code = blocks.filter(ChatMarkdownStyle.isCode)
    XCTAssertEqual(code.map(ChatMarkdownStyle.languageHint), ["bash", nil, "Swift"])
    XCTAssertEqual(code.map(ChatMarkdownStyle.displayedCode), ["$ ls\nfile", "plain", "let x = 1"])
    XCTAssertEqual(ChatCopy.copyableCode(ChatMarkdownStyle.displayedCode(code[0]), language: ChatMarkdownStyle.languageHint(code[0])),
                   "ls")
  }

  // MARK: Whole replies

  private static let reply = """
  # Cover letter

  Dear **Sam**, I *really* want this [role](https://example.com/job). Use `swift build`.

  - First
  - Second
    - Nested
  1. One
  2. Two

  > A quote

  ```swift
  let x = 1
  let y = 2
  ```

  | Name | Size |
  | --- | --- |
  | Qwen | 8B |

  ---

  Thanks!
  """

  func testPlainTextIsTheReplyAsShownWithoutMarkdownMarks() {
    let text = ChatCopy.plainText(ChatMarkdown.blocks(Self.reply))
    XCTAssertEqual(text, """
    Cover letter

    Dear Sam, I really want this role. Use swift build.

    • First
    • Second
      • Nested
    1. One
    2. Two

    A quote

    let x = 1
    let y = 2

    Name\tSize
    Qwen\t8B

    Thanks!
    """)
  }

  func testPlainTextKeepsALongListItemsFurtherParagraphsUnderIt() {
    let text = ChatCopy.plainText(ChatMarkdown.blocks("1. First line\n\n   More about it\n\n2. Second"))
    XCTAssertEqual(text, "1. First line\n   More about it\n2. Second")
  }

  func testPlainTextOfAnUnparsedOrEmptyReply() {
    XCTAssertEqual(ChatCopy.plainText([]), "")
    XCTAssertEqual(ChatCopy.plainText(ChatMarkdown.blocks("Just a line")), "Just a line")
    XCTAssertEqual(ChatCopy.plainText(ChatMarkdown.blocks("C:\\Users\\leo\\notes.md")), "C:\\Users\\leo\\notes.md")
  }

  func testRichTextCarriesFontsListsLinksAndNoColours() throws {
    let rich = ChatCopy.richText(ChatMarkdown.blocks(Self.reply))
    XCTAssertEqual(rich.string, """
    Cover letter
    Dear Sam, I really want this role. Use swift build.
    •\tFirst
    •\tSecond
    •\tNested
    1.\tOne
    2.\tTwo
    A quote
    let x = 1
    let y = 2
    Name\tSize
    Qwen\t8B
    Thanks!
    """)
    func font(of text: String) throws -> NSFont {
      let range = (rich.string as NSString).range(of: text)
      return try XCTUnwrap(rich.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont, text)
    }
    func traits(_ text: String) throws -> NSFontDescriptor.SymbolicTraits {
      try font(of: text).fontDescriptor.symbolicTraits
    }
    XCTAssertTrue(try traits("Cover letter").contains(.bold))
    XCTAssertGreaterThan(try font(of: "Cover letter").pointSize, try font(of: "Dear").pointSize)
    XCTAssertTrue(try traits("Sam").contains(.bold))
    XCTAssertTrue(try traits("really").contains(.italic))
    XCTAssertFalse(try traits("Dear").contains(.bold))
    XCTAssertTrue(try traits("swift build").contains(.monoSpace))
    XCTAssertTrue(try traits("let x = 1").contains(.monoSpace))
    XCTAssertTrue(try traits("Name").contains(.bold), "The table's header row is bold")
    XCTAssertFalse(try traits("Qwen").contains(.bold))
    let link = (rich.string as NSString).range(of: "role")
    XCTAssertEqual(rich.attribute(.link, at: link.location, effectiveRange: nil) as? URL, URL(string: "https://example.com/job"))
    var coloured = false
    rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, _, _ in
      if attributes[.foregroundColor] != nil || attributes[.backgroundColor] != nil { coloured = true }
    }
    XCTAssertFalse(coloured, "Palette colours would paste invisibly onto a white page")

    // Items hang their text past the marker; the code block's lines share one block's spacing.
    let item = (rich.string as NSString).range(of: "Second")
    let itemStyle = try XCTUnwrap(rich.attribute(.paragraphStyle, at: item.location, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertGreaterThan(itemStyle.headIndent, itemStyle.firstLineHeadIndent)
    let nested = (rich.string as NSString).range(of: "Nested")
    let nestedStyle = try XCTUnwrap(rich.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertGreaterThan(nestedStyle.headIndent, itemStyle.headIndent)
    let firstCodeLine = (rich.string as NSString).range(of: "let x = 1")
    let secondCodeLine = (rich.string as NSString).range(of: "let y = 2")
    let first = try XCTUnwrap(rich.attribute(.paragraphStyle, at: firstCodeLine.location, effectiveRange: nil) as? NSParagraphStyle)
    let second = try XCTUnwrap(rich.attribute(.paragraphStyle, at: secondCodeLine.location, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(first.paragraphSpacing, 0)
    XCTAssertGreaterThan(second.paragraphSpacing, 0)
  }

  func testCodeInsideAListItemHangsUnderItAndTheItemContinuesAfterIt() throws {
    let blocks = ChatMarkdown.blocks("1. Install:\n\n   ```bash\n   brew x\n   brew y\n   ```\n\n   Then run it.\n\n2. Next")
    XCTAssertEqual(ChatCopy.plainText(blocks), "1. Install:\n\n   brew x\n   brew y\n\n   Then run it.\n2. Next")
    let rich = ChatCopy.richText(blocks)
    XCTAssertEqual(rich.string, "1.\tInstall:\nbrew x\nbrew y\nThen run it.\n2.\tNext")
    let code = (rich.string as NSString).range(of: "brew x")
    let style = try XCTUnwrap(rich.attribute(.paragraphStyle, at: code.location, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertGreaterThan(style.headIndent, 0, "The code hangs under the item's text")
    let after = (rich.string as NSString).range(of: "Then run it.")
    let afterStyle = try XCTUnwrap(rich.attribute(.paragraphStyle, at: after.location, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(afterStyle.firstLineHeadIndent, style.headIndent, "A continuation has no marker of its own")
  }

  func testCodeThatStartsAListItemKeepsTheItemsMarker() throws {
    let steps = ChatMarkdown.blocks("1. ```\n   npm install\n   ```\n2. ```\n   npm start\n   ```")
    XCTAssertEqual(ChatCopy.plainText(steps), "1. npm install\n\n2. npm start")
    let stepsRich = ChatCopy.richText(steps)
    XCTAssertEqual(stepsRich.string, "1.\tnpm install\n2.\tnpm start")
    // Single-line code that starts an item keeps both the hanging marker and the spacing after it.
    let installStyle = try XCTUnwrap(stepsRich.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(installStyle.firstLineHeadIndent, 0)
    XCTAssertEqual(installStyle.headIndent, 22)
    XCTAssertEqual(installStyle.tabStops.map(\.location), [22])
    XCTAssertGreaterThan(installStyle.paragraphSpacing, 0)

    let mixed = ChatMarkdown.blocks("1. ```bash\n   npm i\n   npm test\n   ```\n\n   Then start it.\n2. Done")
    XCTAssertEqual(ChatCopy.plainText(mixed), "1. npm i\n   npm test\n\n   Then start it.\n2. Done")
    let rich = ChatCopy.richText(mixed)
    XCTAssertEqual(rich.string, "1.\tnpm i\nnpm test\nThen start it.\n2.\tDone")
    func style(_ text: String) throws -> NSParagraphStyle {
      let range = (rich.string as NSString).range(of: text)
      return try XCTUnwrap(rich.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }
    let first = try style("npm i")
    let second = try style("npm test")
    XCTAssertLessThan(first.firstLineHeadIndent, first.headIndent, "The marker hangs out to the item's text")
    XCTAssertEqual(second.firstLineHeadIndent, first.headIndent, "Later lines of the code have no marker")
    XCTAssertGreaterThan(second.paragraphSpacing, 0, "Spacing follows the code's last line")
  }

  func testCodeThatStartsANestedItemKeepsItsNesting() throws {
    let blocks = ChatMarkdown.blocks("- outer\n  - ```\n    x1\n    x2\n    ```")
    XCTAssertEqual(ChatCopy.plainText(blocks), "• outer\n\n  • x1\n    x2")
    let rich = ChatCopy.richText(blocks)
    XCTAssertEqual(rich.string, "•\touter\n•\tx1\nx2")
    func style(_ text: String) throws -> NSParagraphStyle {
      let range = (rich.string as NSString).range(of: text)
      return try XCTUnwrap(rich.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }
    let first = try style("x1")
    XCTAssertEqual(first.firstLineHeadIndent, 22)
    XCTAssertEqual(first.headIndent, 44)
    XCTAssertEqual(first.tabStops.map(\.location), [44])
    let second = try style("x2")
    XCTAssertEqual(second.firstLineHeadIndent, 44)
    XCTAssertEqual(second.headIndent, 44)
  }

  func testAnItemsLaterParagraphAfterANestedListContinuesIt() {
    let blocks = ChatMarkdown.blocks("1. Step one\n   - detail\n\n   More about step one.\n2. Step two")
    XCTAssertEqual(ChatCopy.plainText(blocks), "1. Step one\n  • detail\n   More about step one.\n2. Step two")
  }

  func testEmptyTableCellsKeepTheirColumns() {
    let blocks = ChatMarkdown.blocks("| a | b | c |\n|---|---|---|\n| 1 |  | 3 |\n|  | 5 |  |")
    XCTAssertEqual(ChatCopy.plainText(blocks), "a\tb\tc\n1\t\t3\n\t5\t")
    XCTAssertEqual(ChatCopy.richText(blocks).string, "a\tb\tc\n1\t\t3\n\t5\t")
  }

  func testTrailingNewlinesOfHTMLBlocksDoNotAddEmptyLines() {
    let blocks = ChatMarkdown.blocks("<div>x</div>\n\ntext")
    XCTAssertEqual(ChatCopy.plainText(blocks), "<div>x</div>\n\ntext")
    XCTAssertEqual(ChatCopy.richText(blocks).string, "<div>x</div>\ntext")
  }

  func testRTFNamesOnlyFontsOtherAppsCanResolve() throws {
    let rich = ChatCopy.richText(ChatMarkdown.blocks("Plain **bold** *italic* `code`\n\n```\nlet x = 1\n```"))
    let data = try XCTUnwrap(ChatCopy.rtf(rich))
    let rtf = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(rtf.contains(".AppleSystem"), "Private system font names paste as a proportional fallback elsewhere")
    XCTAssertTrue(rtf.contains("Menlo"))
  }

  func testRichTextIsRTFThatReadsBackWithTheSameText() throws {
    let rich = ChatCopy.richText(ChatMarkdown.blocks(Self.reply))
    let data = try XCTUnwrap(ChatCopy.rtf(rich))
    XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("{\\rtf"))
    let readBack = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
    XCTAssertEqual(readBack.string, rich.string)
  }

  func testRichTextOfAnEmptyReplyIsEmpty() {
    XCTAssertEqual(ChatCopy.richText([]).length, 0)
  }

  func testCopyButtonNeverRestsAtZeroOpacity() {
    func opacity(_ emphasized: Bool, _ focused: Bool, _ copied: Bool) -> Double {
      ChatCopyButton.opacity(isEmphasized: emphasized, isFocused: focused, copied: copied)
    }
    XCTAssertEqual(opacity(true, false, false), 1, "Emphasized, like a reply under the pointer")
    XCTAssertEqual(opacity(false, true, false), 1, "Keyboard focus")
    XCTAssertEqual(opacity(false, false, true), 1, "The check mark")
    XCTAssertEqual(opacity(false, false, false), ChatCopyButton.restingOpacity)
    XCTAssertGreaterThan(ChatCopyButton.restingOpacity, 0.5, "Dimmed, not hidden: it must stay legible and clickable")
    XCTAssertLessThan(ChatCopyButton.restingOpacity, 1)
  }

  // MARK: Pasteboard

  private func scratchPasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("com.enigma.tests.copy-\(UUID().uuidString)")
    addTeardownBlock { NSPasteboard(name: name).releaseGlobally() }
    return NSPasteboard(name: name)
  }

  func testWritingReplacesThePasteboardWithPlainAndRichText() throws {
    let board = scratchPasteboard()
    board.clearContents()
    board.setString("old", forType: .string)
    board.setData(Data("old".utf8), forType: .png)

    ChatCopy.write(plain: "plain", rich: ChatCopy.richText(ChatMarkdown.blocks("**bold**")), to: board)
    XCTAssertEqual(board.string(forType: .string), "plain")
    XCTAssertNotNil(board.data(forType: .rtf))
    XCTAssertNil(board.data(forType: .png), "Earlier contents are replaced")

    ChatCopy.write(plain: "code", to: board)
    XCTAssertEqual(board.string(forType: .string), "code")
    XCTAssertNil(board.data(forType: .rtf), "Code Copy writes plain text only")
  }

  // MARK: The buttons

  @MainActor
  func testCopyCodeButtonCopiesTheTerminalCommandsAndShowsACheckMarkBriefly() async throws {
    let board = scratchPasteboard()
    let host = CopyHost(ChatMarkdownView(content: "Run it:\n\n```bash\n$ swift build\nBuild complete!\n```\n\n```python\nprint(1)\n```"),
                        pasteboard: board, test: self)
    try await waitForUI("the code blocks", in: host.view) { host.shows("Copy code") }
    XCTAssertNil(board.string(forType: .string))
    try await clickTestControl("Copy code", in: host.view)
    try await waitForUI("the copied command", in: host.view) { board.string(forType: .string) == "swift build" }
    XCTAssertNil(board.data(forType: .rtf))
    try await waitForUI("the check mark", in: host.view) { host.shows("Copied") }
    try await waitForUI("the icon to return", in: host.view, timeout: .seconds(4)) { !host.shows("Copied") }
    XCTAssertTrue(host.shows("Copy code"))
  }

  @MainActor
  func testCopyReplyButtonRestsDimmedButClickableAndCopiesPlainAndRichText() async throws {
    let board = scratchPasteboard()
    var answer = ChatMessage(role: .assistant, content: "Dear **Sam**,\n\n- one\n- two\n\nThanks")
    answer.origin = ReplyOrigin(mode: .local, providerID: "local", modelName: "Fixture 8B")
    let host = CopyHost(TranscriptPreview(messages: [ChatMessage(role: .user, content: "Write a note"), answer]),
                        pasteboard: board, test: self)
    // Not hovered: dimmed, but still in the view tree and clickable, so keyboard and VoiceOver users reach it.
    try await waitForUI("the reply's copy button", in: host.view) { host.shows("Copy reply") }
    XCTAssertNil(board.string(forType: .string))
    try await clickTestControl("Copy reply", in: host.view)
    try await waitForUI("the copied reply", in: host.view) {
      board.string(forType: .string) == "Dear Sam,\n\n• one\n• two\n\nThanks"
    }
    let rtf = try XCTUnwrap(board.data(forType: .rtf))
    let rich = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    XCTAssertEqual(rich.string, "Dear Sam,\n•\tone\n•\ttwo\nThanks")
    try await waitForUI("the check mark", in: host.view) { host.shows("Copied") }
  }

  @MainActor
  func testNoCopyReplyButtonWhileTheReplyStreamsOrHasNoText() async throws {
    let board = scratchPasteboard()
    var activity = AssistantActivity(id: UUID())
    activity.apply(.phase(.searching))
    let transcript = ConversationTranscript(messages: [ChatMessage(role: .user, content: "Hi")], activity: activity,
                                            isResponding: true)
    let rows = transcript.rows
    let replyRow = try XCTUnwrap(rows.compactMap { row -> ConversationTranscript.Reply? in
      if case .reply(let reply) = row { return reply }
      return nil
    }.first)
    let host = CopyHost(EnigmaReplyView(reply: replyRow), pasteboard: board, test: self)
    try await waitForUI("the reply", in: host.view) { host.view.fittingSize.height > 1 }
    XCTAssertFalse(host.shows("Copy reply"))
    let streaming = ConversationTranscript.Reply(id: UUID(), message: ChatMessage(role: .assistant, content: "Partial te"),
                                                 activity: nil, isLatest: true, isInProgress: true)
    let streamingHost = CopyHost(EnigmaReplyView(reply: streaming), pasteboard: board, test: self)
    try await waitForUI("the streamed text", in: streamingHost.view) { streamingHost.shows("Reply") }
    XCTAssertFalse(streamingHost.shows("Copy reply"), "A reply that is still streaming has no meta line or copy button")
    let empty = ConversationTranscript.Reply(id: UUID(), message: ChatMessage(role: .assistant, content: ""),
                                             activity: nil, isLatest: true, isInProgress: false)
    let emptyHost = CopyHost(EnigmaReplyView(reply: empty), pasteboard: board, test: self)
    try await waitForUI("the finished reply", in: emptyHost.view) { emptyHost.shows("Reply meta") }
    XCTAssertFalse(emptyHost.shows("Copy reply"), "A reply with no text has nothing to copy")
    let blank = ConversationTranscript.Reply(id: UUID(), message: ChatMessage(role: .assistant, content: " \n\n "),
                                             activity: nil, isLatest: true, isInProgress: false)
    let blankHost = CopyHost(EnigmaReplyView(reply: blank), pasteboard: board, test: self)
    try await waitForUI("the blank reply", in: blankHost.view) { blankHost.shows("Reply meta") }
    XCTAssertFalse(blankHost.shows("Copy reply"), "Whitespace isn't worth replacing the clipboard with")
  }

  @MainActor
  func testRegenerateShowsUnderEveryReply() async throws {
    let board = scratchPasteboard()
    let messages = [ChatMessage(role: .user, content: "One"), ChatMessage(role: .assistant, content: "First"),
                    ChatMessage(role: .user, content: "Two"), ChatMessage(role: .assistant, content: "Second")]
    let replies = ConversationTranscript(messages: messages, activity: nil, isResponding: false).rows.compactMap {
      row -> ConversationTranscript.Reply? in
      if case .reply(let reply) = row { return reply }
      return nil
    }
    XCTAssertEqual(replies.count, 2)
    let hosts = replies.map {
      CopyHost(EnigmaReplyView(reply: $0, regenerate: { _ in }, canRegenerate: true) { EmptyView() }, pasteboard: board, test: self)
    }
    for host in hosts { try await waitForUI("the reply", in: host.view) { host.shows("Copy reply") } }
    XCTAssertTrue(hosts[0].shows(ChatRegenerateButton.label), "An earlier reply can be regenerated")
    XCTAssertTrue(hosts[1].shows(ChatRegenerateButton.label))
    XCTAssertEqual(replies.map(\.regeneratesFrom), [messages[0].id, messages[2].id])
  }
}

extension ChatCopyTests {
  @MainActor
  func testThePencilEditsInPlaceAndCancelOrEscapeChangesNothing() async throws {
    let message = ChatMessage(role: .user, content: "Old question")
    let box = EditBox()
    let host = CopyHost(EditHarness(box: box, message: message), pasteboard: scratchPasteboard(), test: self)
    try await waitForUI("the pencil", in: host.view) { host.shows(EnigmaUserMessage.editLabel) }
    let plain = CopyHost(EnigmaUserMessage(message: message), pasteboard: scratchPasteboard(), test: self)
    try await waitForUI("the message", in: plain.view) { plain.shows("Your message") }
    XCTAssertFalse(plain.shows(EnigmaUserMessage.editLabel), "No pencil without an edit action")

    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
      host.window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 1, windowNumber: host.window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    func openEditor() async throws -> NSTextView {
      try await clickTestControl(EnigmaUserMessage.editLabel, in: host.view)
      try await waitForUI("the editor", in: host.view) {
        host.shows("Message editor") && (host.window.firstResponder as? NSTextView)?.string == "Old question"
      }
      XCTAssertFalse(host.shows("Your message"), "The bubble becomes the editor")
      XCTAssertTrue(host.shows("Edit note"), "Says what editing won't undo")
      return try XCTUnwrap(host.window.firstResponder as? NSTextView)
    }
    func replace(_ field: NSTextView, with text: String) {
      field.selectAll(nil)
      field.insertText(text, replacementRange: field.selectedRange())
    }
    func closed() -> Bool { host.shows("Your message") && !host.shows("Message editor") }

    var field = try await openEditor()
    field.insertText(" edited", replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
    try await clickTestControl("Cancel edit", in: host.view)
    try await waitForUI("the message again", in: host.view) { closed() }

    field = try await openEditor()
    try key("\u{1b}", code: 53)
    try await waitForUI("Escape closes the editor", in: host.view) { closed() }
    XCTAssertEqual(box.sent, [], "Cancel and Escape send nothing")

    field = try await openEditor()
    replace(field, with: "New")
    try key("\r", code: 36, modifiers: [.shift])
    try await waitForUI("Shift-Return starts a new line", in: host.view) { field.string == "New\n" }
    XCTAssertEqual(box.sent, [], "Shift-Return doesn't send")
    replace(field, with: "Return question")
    try key("\r", code: 36)
    try await waitForUI("Return sends", in: host.view) { box.sent == ["Return question"] && closed() }

    // An edit whose reply never started reopens with its text, without taking the keys from
    // another field, such as the composer.
    box.showsOther = true
    try await clickTestControl("Other field", in: host.view)
    func otherHasFocus() -> Bool { (host.window.firstResponder as? NSTextView)?.string == box.other }
    try await waitForUI("the other field focused", in: host.view) { otherHasFocus() }
    box.returned = "Kept edit"
    try await waitForUI("the editor with the returned text", in: host.view) {
      host.shows("Message editor") && box.returned == nil
    }
    try await Task.sleep(for: .milliseconds(200))
    host.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(otherHasFocus(), "A returned edit leaves focus where it was")
    box.showsOther = false
    // Also when its row was gone meanwhile, as while the edit's reply was pending.
    box.shown = false
    try await waitForUI("the row gone", in: host.view) { !host.shows("Message editor") && !host.shows("Your message") }
    box.returned = "Kept edit"
    box.shown = true
    try await waitForUI("the new row's editor with the returned text", in: host.view) {
      host.shows("Message editor") && box.returned == nil
    }
    host.view.window?.makeFirstResponder(nil)
    try await clickTestControl("Message editor", in: host.view)
    try await waitForUI("the field focused", in: host.view) {
      (host.window.firstResponder as? NSTextView)?.string == "Kept edit"
    }

    // While it can't run, neither Send nor Return sends.
    box.canEdit = false
    try await Task.sleep(for: .milliseconds(50))
    try key("\r", code: 36)
    try await clickTestControl("Send edit", in: host.view)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(box.sent, ["Return question"])
    box.canEdit = true
    try await clickTestControl("Send edit", in: host.view)
    try await waitForUI("Send sends", in: host.view) { box.sent == ["Return question", "Kept edit"] && closed() }

    // A message that stops being editable closes its editor.
    field = try await openEditor()
    box.hasEdit = false
    try await waitForUI("the editor closes", in: host.view) { closed() && !host.shows(EnigmaUserMessage.editLabel) }
  }
}

@MainActor
private final class EditBox: ObservableObject {
  @Published var returned: String?
  @Published var canEdit = true
  @Published var hasEdit = true
  @Published var shown = true
  /// A field standing in for the composer.
  @Published var showsOther = false
  @Published var other = "Composer draft"
  var sent: [String] = []
}

/// A message whose edit action, availability and returned edit a test changes while it's shown.
private struct EditHarness: View {
  @ObservedObject var box: EditBox
  let message: ChatMessage

  var body: some View {
    VStack {
      if box.showsOther {
        TextField("", text: $box.other).enigmaTestMarker("Other field")
      }
      if box.shown { message(of: self.message) }
    }
  }

  private func message(of message: ChatMessage) -> some View {
    EnigmaUserMessage(message: message, edit: box.hasEdit ? { box.sent.append($0) } : nil, canEdit: box.canEdit,
                      returnedText: box.returned, takeReturnedText: { box.returned = nil },
                      editNote: ConversationTranscript.editKeepsActionsNote)
  }
}

/// A view in a key window with the test markers, the Paper palette and its own pasteboard.
@MainActor
private final class CopyHost {
  let view: NSView
  let window: NSWindow

  init<Content: View>(_ content: Content, pasteboard: NSPasteboard, test: XCTestCase) {
    let marker: @MainActor @Sendable (String) -> AnyView = { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) }
    let size = CGSize(width: 560, height: 460)
    view = NSHostingView(rootView: content
      .padding(20)
      .frame(width: size.width, height: size.height, alignment: .top)
      .environment(\.enigmaTestMarker, marker)
      .environment(\.enigmaPasteboard, pasteboard)
      .enigmaTheme(.paper)
      .transaction { $0.disablesAnimations = true })
    window = CopyKeyableWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    window.makeKey()
    view.layoutSubtreeIfNeeded()
    test.addTeardownBlock { @MainActor [window] in
      window.orderOut(nil)
      window.contentView = nil
    }
  }

  func shows(_ name: String) -> Bool { EnigmaMainWindowTests.Host.marker(name, in: view) != nil }
}

private final class CopyKeyableWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}
