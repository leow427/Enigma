import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// The conversation: its logic, the character's
/// place in the chat, the cards' actions, and the list at real window sizes.
/// Hosted tests use the main window's isolated fixture, never the installed
/// app's settings.
final class EnigmaConversationTests: XCTestCase {
  private typealias Fixture = EnigmaMainWindowTests.Fixture
  private typealias Host = EnigmaMainWindowTests.Host
  private typealias Slot = EnigmaCharacterModel.Slot

  // MARK: Transcript

  func testTranscriptPutsTheCharacterBesideTheLatestReplyAndKeepsItsSlotAsTheReplyArrives() throws {
    let first = ChatMessage(role: .user, content: "One")
    let answer = ChatMessage(role: .assistant, content: "First answer")
    let second = ChatMessage(role: .user, content: "Two")
    var activity = AssistantActivity(id: UUID())
    activity.apply(.phase(.searching))

    // Preparing: the request's activity stands in for the reply.
    let preparing = ConversationTranscript(messages: [first, answer, second], activity: activity, isResponding: true)
    XCTAssertEqual(preparing.rows.map(\.id), [first.id, answer.id, second.id, activity.id])
    let earlier = try reply(preparing.rows[1])
    let pending = try reply(preparing.rows[3])
    XCTAssertFalse(earlier.isLatest, "Earlier replies show the mark")
    XCTAssertFalse(earlier.isInProgress)
    XCTAssertTrue(pending.isLatest)
    XCTAssertTrue(pending.isInProgress)
    XCTAssertNil(pending.message)
    XCTAssertFalse(pending.showsThinking, "The activity line shows the phase instead")
    let slot = ConversationTranscript.slot(forReply: activity.id)
    XCTAssertEqual(preparing.latestReplySlot, slot)
    XCTAssertEqual(ConversationTranscript.latestReplySlot(messages: [first, answer, second], activity: activity), slot)

    // The reply arrives carrying the request's activity: same row, same slot.
    var written = ChatMessage(role: .assistant, content: "")
    written.activity = activity
    let streaming = ConversationTranscript(messages: [first, answer, second, written], activity: activity,
                                           isResponding: true)
    XCTAssertEqual(streaming.rows.map(\.id), preparing.rows.map(\.id))
    XCTAssertEqual(streaming.latestReplySlot, slot)
    XCTAssertEqual(ConversationTranscript.latestReplySlot(messages: [first, answer, second, written], activity: activity),
                   slot)
    XCTAssertTrue(try reply(streaming.rows[3]).isInProgress)

    written.content = "Done."
    let finished = ConversationTranscript(messages: [first, answer, second, written], activity: nil, isResponding: false)
    let done = try reply(finished.rows[3])
    XCTAssertTrue(done.isLatest)
    XCTAssertFalse(done.isInProgress, "A finished reply shows its meta line")
    XCTAssertEqual(finished.latestReplySlot, slot)

    // Waiting for words with no activity: the thinking line.
    let bare = ChatMessage(role: .assistant, content: "")
    let waiting = ConversationTranscript(messages: [first, bare], activity: nil, isResponding: true)
    XCTAssertTrue(try reply(waiting.rows[1]).showsThinking)
    XCTAssertFalse(try reply(ConversationTranscript(messages: [first, bare], activity: nil, isResponding: false)
      .rows[1]).showsThinking)

    // A saved reply's sources become its activity, as before.
    let source = WebSearchSource(title: "Swift", url: try XCTUnwrap(URL(string: "https://swift.org")))
    let saved = ChatMessage(role: .assistant, content: "With sources", searchSources: [source])
    let savedReply = try reply(ConversationTranscript(messages: [first, saved], activity: nil, isResponding: false).rows[1])
    XCTAssertEqual(savedReply.id, saved.id)
    XCTAssertEqual(savedReply.activity?.sources, [source])
    XCTAssertEqual(savedReply.activity?.phase, .completed)
    XCTAssertTrue(savedReply.searched)
    XCTAssertFalse(earlier.searched)

    XCTAssertNil(ConversationTranscript(messages: [first], activity: nil, isResponding: false).latestReplySlot)
    XCTAssertNil(ConversationTranscript.latestReplySlot(messages: [first], activity: nil))
  }

  func testLatestReplySlotRestsByTheFirstLineAndStaysInViewDuringALongReply() {
    let slot = ConversationTranscript.slotSize
    // Outside a scrolling chat, and with the whole reply in view, it rests by the first line.
    XCTAssertEqual(ReplySlotPlacement(trackHeight: 400, viewport: nil, slot: slot), .resting)
    let inView = ReplySlotPlacement(trackHeight: 400, viewport: CGRect(x: 0, y: -200, width: 600, height: 700), slot: slot)
    XCTAssertEqual(inView, ReplySlotPlacement(offset: ReplySlotPlacement.restingOffset, isVisible: true))
    // The reply's start is scrolled away: it stays under the chat's top edge.
    let pinned = ReplySlotPlacement(trackHeight: 1200, viewport: CGRect(x: 0, y: 300, width: 600, height: 500), slot: slot)
    XCTAssertEqual(pinned, ReplySlotPlacement(offset: 300 + ReplySlotPlacement.topMargin, isVisible: true))
    // Only the reply's end is left: it stops at the end rather than leaving the reply.
    let end = ReplySlotPlacement(trackHeight: 1200, viewport: CGRect(x: 0, y: 1190, width: 600, height: 500), slot: slot)
    XCTAssertEqual(end.offset, 1200 - slot)
    XCTAssertFalse(end.isVisible, "Half above the chat's edge, it hides rather than drawing over the edge")
    // The reply is below the visible chat.
    XCTAssertFalse(ReplySlotPlacement(trackHeight: 300, viewport: CGRect(x: 0, y: -900, width: 600, height: 500),
                                      slot: slot).isVisible)
  }

  func testTheCharacterMovesWithinAChatAndIsAtOnceInAnotherChat() {
    let first = UUID()
    let second = UUID()
    XCTAssertEqual(ChatCharacterMove.transition(fromSession: first, toSession: first, isResponding: true), .automatic,
                   "The first and later replies in the open chat")
    XCTAssertEqual(ChatCharacterMove.transition(fromSession: nil, toSession: first, isResponding: true), .automatic,
                   "A chat the current send created is the same chat")
    XCTAssertEqual(ChatCharacterMove.transition(fromSession: nil, toSession: first, isResponding: false), .instant,
                   "Opening a saved chat before any chat was selected")
    XCTAssertEqual(ChatCharacterMove.transition(fromSession: first, toSession: second, isResponding: false), .instant)
    XCTAssertFalse(ReplySlotPlacement.waiting.isVisible, "A new slot isn't reported before it's measured")
  }

  func testMetaLineSaysWhichModelWhereItRanAndWhen() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let locale = Locale(identifier: "en_US_POSIX")
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 30)))
    let earlier = now.addingTimeInterval(-90 * 60)
    let yesterday = now.addingTimeInterval(-26 * 3600)
    func meta(_ origin: ReplyOrigin?, searched: Bool = false, date: Date? = nil) -> String {
      ReplyMetaLine.text(origin: origin, searched: searched, date: date ?? earlier, now: now, calendar: calendar,
                         locale: locale)
    }
    let time = ReplyMetaLine.time(earlier, now: now, calendar: calendar, locale: locale)
    XCTAssertTrue(time.hasPrefix("2:00"), time)
    XCTAssertFalse(time.contains("Oct"), "Today's replies show only the time")
    XCTAssertTrue(ReplyMetaLine.time(yesterday, now: now, calendar: calendar, locale: locale).contains("Oct 17"))

    XCTAssertEqual(meta(ReplyOrigin(mode: .local, providerID: "local", modelName: "Fixture 8B")),
                   "Fixture 8B · on this mac · \(time)")
    XCTAssertEqual(meta(ReplyOrigin(mode: .local, providerID: "local", modelName: "Fixture 8B"), searched: true),
                   "Fixture 8B · on this mac · brave search · \(time)")
    let providers: [(CloudProviderID, String)] = [(.chatGPT, "chatgpt"), (.claudeCode, "claude code"),
                                                  (.openAI, "openai"), (.anthropic, "anthropic"), (.gemini, "gemini")]
    for (provider, place) in providers {
      XCTAssertEqual(meta(ReplyOrigin(mode: .cloud, providerID: provider.rawValue, modelName: "model-1")),
                     "model-1 · \(place) · \(time)")
    }
    XCTAssertEqual(meta(ReplyOrigin(mode: .cloud, providerID: "Other", modelName: "")), "other · \(time)")
    XCTAssertEqual(meta(nil), time, "A reply from an earlier session shows what it recorded")
  }

  @MainActor
  func testRepliesRecordWhereTheyRanForTheirMetaLine() async throws {
    let fixture = try await Fixture(test: self)
    fixture.chat.submit("Hello")
    try await waitForUI("the reply to be written") {
      fixture.chat.messages.last?.role == .assistant && fixture.engine.requestCount == 1
    }
    XCTAssertEqual(fixture.chat.messages.last?.origin, ReplyOrigin(mode: .local, providerID: "local",
                                                                   modelName: "Fixture 8B"))
    XCTAssertNil(fixture.chat.messages.first?.origin, "Only replies record an origin")
  }

  // MARK: Markdown styling

  func testMarkdownStylingKeepsTheParsedTextAndColorsCodeAndLinks() throws {
    let source = """
    Run `swift build`, then read [the docs](https://swift.org).

    ## Next steps

    1. First
    2. Second

    - Dot

    ```
    let x = 1
    ```

    | Name | Size |
    | --- | --- |
    | Qwen | 8B |
    """
    let blocks = ChatMarkdown.blocks(source)
    let styled = ChatMarkdownStyle.styled(blocks[0].text, palette: .ink)
    XCTAssertEqual(String(styled.characters), String(blocks[0].text.characters), "Styling never changes the text")
    var sawCode = false
    var sawLink = false
    for run in styled.runs {
      if run.inlinePresentationIntent?.contains(.code) == true {
        XCTAssertEqual(run.swiftUI.font, ChatMarkdownStyle.inlineCodeFont)
        XCTAssertEqual(run.swiftUI.backgroundColor, EnigmaPalette.ink.surface.color)
        sawCode = true
      }
      if run.link != nil {
        XCTAssertEqual(run.swiftUI.foregroundColor, EnigmaPalette.ink.accentText.color)
        sawLink = true
      }
    }
    XCTAssertTrue(sawCode && sawLink)
    XCTAssertEqual(blocks.compactMap(ChatMarkdownStyle.headingLevel), [2])
    XCTAssertEqual(blocks.compactMap(ChatMarkdownStyle.listMarker), ["1.", "2.", "•"])
    XCTAssertEqual(blocks.filter(ChatMarkdownStyle.isCode).count, 1)
    let groups = ChatMarkdown.groups(blocks)
    let table = try XCTUnwrap(groups.first(where: ChatMarkdownStyle.isTable))
    XCTAssertEqual(ChatMarkdown.rows(table).count, 2, "A header row and one body row")
  }

  // MARK: The character in the chat

  @MainActor
  func testAMoveWhoseSlotNeverArrivesHidesTheCharacterAndALateSlotIsTakenAtOnce() async throws {
    let main = Slot(center: CGPoint(x: 200, y: 100), size: 92)
    let reply = Slot(center: CGPoint(x: 60, y: 420), size: 30, movesWithContent: true)
    var time = 10.0
    func frame(_ controller: EnigmaCharacterController, _ slots: [EnigmaCharacterSlotID: Slot]) -> EnigmaCharacterFrame {
      time += 1.0 / 60
      return controller.frame(at: time, slots: slots, targets: [:], reduceMotion: false)
    }

    // With a long grace, a slot that arrives late still gets the fall.
    let patient = EnigmaCharacterController(seed: 5, stalledMoveGrace: .seconds(60))
    patient.move(to: "main")
    XCTAssertFalse(frame(patient, ["main": main]).isEmpty)
    patient.move(to: "reply")
    for _ in 0..<5 {
      XCTAssertFalse(frame(patient, [:]).isEmpty, "It waits where it was for its new slot")
      await Task.yield()
    }
    XCTAssertTrue(patient.isPresent)
    _ = frame(patient, ["reply": reply])
    XCTAssertTrue(patient.model.isFalling, "A slot that arrives within the grace gets the fall")

    // With no grace, a move whose slot never arrives hides the character.
    let stalled = EnigmaCharacterController(seed: 5, stalledMoveGrace: .zero)
    stalled.move(to: "main")
    XCTAssertFalse(frame(stalled, ["main": main]).isEmpty)
    stalled.move(to: "reply")
    XCTAssertFalse(frame(stalled, [:]).isEmpty, "It's still drawn for the frame the slot was missed in")
    try await waitForUI("the character to hide once the grace runs out") {
      _ = frame(stalled, [:])
      return !stalled.isPresent
    }
    XCTAssertEqual(stalled.neededActivity, .rest, "Nothing drawn keeps the timeline running")
    XCTAssertFalse(frame(stalled, ["reply": reply]).isEmpty)
    XCTAssertEqual(stalled.model.position, reply.center, "A late slot is taken at once")
    XCTAssertFalse(stalled.model.isFalling)

    // A newer move gets its own grace rather than inheriting a stale check.
    let moving = EnigmaCharacterController(seed: 5, stalledMoveGrace: .zero)
    moving.move(to: "main")
    _ = frame(moving, ["main": main])
    moving.move(to: "reply")
    _ = frame(moving, [:])
    moving.move(to: "main")
    _ = frame(moving, ["main": main])
    await Task.yield()
    await Task.yield()
    XCTAssertTrue(moving.isPresent, "A move whose slot arrived isn't hidden by the earlier move's check")
  }

  func testASlotThatMovesWithContentCarriesTheCharacterInsteadOfTrailing() {
    for movesWithContent in [true, false] {
      var model = EnigmaCharacterModel(seed: 2)
      let slot = Slot(center: CGPoint(x: 60, y: 400), size: 30, movesWithContent: movesWithContent)
      model.place(at: slot, instantly: true)
      for _ in 0..<10 { model.step(dt: 1.0 / 60) }
      var scrolled = slot
      scrolled.center.y -= 120
      model.updateSlot(scrolled)
      model.step(dt: 1.0 / 60)
      if movesWithContent {
        XCTAssertEqual(model.position.y, scrolled.center.y, accuracy: 0.5, "It scrolls with its reply")
      } else {
        XCTAssertGreaterThan(model.position.y, scrolled.center.y + 60, "Other slots still follow on a spring")
      }
    }
  }

  @MainActor
  func testCharacterFallsIntoTheFirstReplyFollowsTheRequestAndMovesToTheNewestReply() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let character = fixture.character
    try await waitForUI("the character on the main page", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.isPresent
        && composerEditor(in: host.view)?.isEditable == true
    }
    let start = character.model.position

    try await send("Explain actors", in: host, fixture)
    let request = try XCTUnwrap(fixture.chat.activity?.id)
    let replySlot = ConversationTranscript.slot(forReply: request)
    try await waitForUI("the move to the first reply's slot", in: host.view) { character.activeSlot == replySlot }
    XCTAssertEqual(character.state, .thinking, "It thinks while the request prepares")
    var sawFall = false
    try await waitForUI("the fall into the reply's slot", in: host.view, timeout: .seconds(4)) {
      sawFall = sawFall || character.model.isFalling
      return character.isPresent && character.model.slot?.size == ConversationTranscript.slotSize
        && !character.model.isFalling && character.model.position.y > start.y + 100
    }
    XCTAssertTrue(sawFall, "It falls from the main page rather than jumping")
    XCTAssertEqual(character.model.slot?.movesWithContent, true)

    try await waitForUI("the reply's stream", in: host.view) { fixture.engine.requestCount == 1 }
    fixture.engine.send("Actors protect their own state.")
    try await waitForUI("answering while the reply streams", in: host.view) {
      character.state == .answering && host.shows("Reply")
    }
    XCTAssertFalse(host.shows("Reply meta"), "The meta line waits for the reply to finish")
    fixture.engine.finish()
    try await waitForUI("idle once the reply is done", in: host.view) {
      character.state == .idle && fixture.chat.activeRequest == nil && host.shows("Reply meta")
    }
    XCTAssertEqual(character.activeSlot, replySlot)
    XCTAssertFalse(host.shows("Earlier reply mark"))

    try await send("And isolation?", in: host, fixture)
    let second = try XCTUnwrap(fixture.chat.activity?.id)
    try await waitForUI("the move to the newest reply and the mark on the earlier one", in: host.view) {
      character.activeSlot == ConversationTranscript.slot(forReply: second) && host.shows("Earlier reply mark")
    }
    try await waitForUI("the second reply's stream", in: host.view) { fixture.engine.requestCount == 2 }
    fixture.engine.send("Partly")
    fixture.engine.finish(throwing: CloudProviderError.invalidResponse)
    try await waitForUI("the error state when the request fails", in: host.view) {
      character.state == .error && fixture.chat.activeRequest == nil
    }

    fixture.chat.newChat()
    try await waitForUI("the character back on the main page for a new chat", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.isPresent && host.shows("Example /screen")
    }
  }

  /// Under Reduce Motion the first send moves the composer, with its message
  /// field and Send, to where a docked chat keeps it, without sliding there.
  /// The character moves between slots without falling, and later sends work.
  @MainActor
  func testUnderReduceMotionTheFirstSendDocksTheComposerAndLaterSendsStillWork() async throws {
    let size = CGSize(width: 1000, height: 660)
    let resting = try await dockedComposerFrames(size: size)

    let fixture = try await Fixture(test: self)
    fixture.reduceMotion = true
    let host = Host(fixture, size: size, test: self)
    let character = fixture.character
    try await waitForUI("the character on the main page", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.isPresent
        && composerEditor(in: host.view)?.isEditable == true
    }
    func atRest(in slot: EnigmaCharacterSlotID) -> Bool {
      guard character.activeSlot == slot, character.isPresent, let model = character.model.slot,
            model.size == ConversationTranscript.slotSize else { return false }
      return abs(character.model.position.y - model.center.y) < 1
    }
    func composer(_ name: String) -> CGRect? {
      host.marker(name).map { host.view.convert($0.bounds, from: $0) }
    }
    func field() -> CGRect? { composerEditor(in: host.view).map { host.view.convert($0.bounds, from: $0) } }
    func isAt(_ frame: CGRect?, _ place: CGRect) -> Bool {
      guard let frame else { return false }
      return abs(frame.minX - place.minX) < 1 && abs(frame.minY - place.minY) < 1
    }
    func isDocked(_ frame: CGRect?) -> Bool { isAt(frame, resting.send) }
    // Every place Send (or Stop) is seen from the first send on.
    let start = try XCTUnwrap(composer("Send message"))
    var seen: [CGRect] = []
    func observe() {
      if let frame = composer("Stop response") ?? composer("Send message"), seen.last != frame { seen.append(frame) }
    }

    // The first reply streams and finishes while the page changes, as in use.
    var moved = false
    try await send("Explain actors", in: host, fixture)
    let first = ConversationTranscript.slot(forReply: try XCTUnwrap(fixture.chat.activity?.id))
    try await waitForUI("the character in the first reply's slot and the reply's stream", in: host.view) {
      observe()
      moved = moved || character.model.isFalling
      return atRest(in: first) && fixture.engine.requestCount == 1
    }
    fixture.engine.send("Actors protect their own state.")
    try await waitForUI("answering while the reply streams", in: host.view) {
      observe()
      return character.state == .answering && host.shows("Reply")
    }
    fixture.engine.finish()
    try await waitForUI("idle once the reply is done", in: host.view) {
      observe()
      return character.state == .idle && fixture.chat.activeRequest == nil && host.shows("Reply meta")
    }
    XCTAssertFalse(moved, "It moves into the reply without falling")
    // The field and Send are AppKit views placed by SwiftUI: where they are is
    // where a click goes, so they must be where the docked composer is drawn.
    XCTAssertTrue(isDocked(composer("Send message")),
                  "Send is in the docked composer: \(String(describing: composer("Send message"))), not \(resting.send)")
    XCTAssertTrue(isAt(field(), resting.field),
                  "The message field is in the docked composer: \(String(describing: field())), not \(resting.field)")
    XCTAssertEqual(seen.filter { !isAt($0, start) && !isDocked($0) }, [],
                   "The composer goes to the bottom at once instead of sliding: \(seen) from \(start)")

    try await send("And isolation?", in: host, fixture)
    let second = ConversationTranscript.slot(forReply: try XCTUnwrap(fixture.chat.activity?.id))
    try await waitForUI("the second request and the character in its reply's slot", in: host.view) {
      moved = moved || character.model.isFalling
      return fixture.engine.requestCount == 2 && atRest(in: second) && host.shows("Earlier reply mark")
        && !host.shows("Example /screen")
    }
    XCTAssertFalse(moved, "It moves to the newest reply without falling")
    XCTAssertTrue(isDocked(composer("Stop response")), "The composer stays docked")

    // A new chat puts the composer back on the main page, also at once.
    fixture.engine.finish()
    try await waitForUI("the second reply done", in: host.view) { fixture.chat.activeRequest == nil }
    seen = []
    fixture.chat.newChat()
    try await waitForUI("the composer back on the main page (seen at \(seen), start \(start))", in: host.view) {
      observe()
      return isAt(composer("Send message"), start) && host.shows("Example /screen") && composerAcceptsClicks(in: host.view)
    }
    XCTAssertEqual(seen.filter { !isAt($0, start) && !isDocked($0) }, [], "The composer goes back at once: \(seen)")
  }

  /// Where the docked composer's Send button and message field rest under
  /// Reduce Motion, in a chat that was open before the window showed, so the
  /// composer never moved there.
  @MainActor
  private func dockedComposerFrames(size: CGSize) async throws -> (send: CGRect, field: CGRect) {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Earlier chat")])
    fixture.reduceMotion = true
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    let host = Host(fixture, size: size, test: self)
    try await waitForUI("a chat open with its composer docked", in: host.view) {
      host.shows("Send message") && !host.shows("Example /screen") && composerAcceptsClicks(in: host.view)
    }
    let marker = try XCTUnwrap(host.marker("Send message"))
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    let frames = (send: host.view.convert(marker.bounds, from: marker), field: host.view.convert(editor.bounds, from: editor))
    host.window.orderOut(nil)
    XCTAssertGreaterThan(frames.send.midY, size.height / 2, "A docked composer rests in the window's lower half: \(frames)")
    return frames
  }

  @MainActor
  func testTheMainPageShowsTheThinkingStateUntilTheRequestIsAccepted() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    try await send("Hello", in: host, fixture)
    // The reply's slot is in the chat while the request prepares, so the
    // thinking character is on screen rather than hidden.
    try await waitForUI("the thinking character beside the waiting reply", in: host.view) {
      fixture.character.state == .thinking && fixture.character.isPresent
        && fixture.character.model.slot?.size == ConversationTranscript.slotSize && host.shows("Activity")
    }
  }

  @MainActor
  func testOpeningASavedChatFromTheMainPagePutsTheCharacterThereAtOnce() async throws {
    let fixture = try await Fixture(test: self, sessions: [Self.markdownSession()])
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let character = fixture.character
    try await waitForUI("the character on the main page", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.isPresent
    }
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    let latest = try XCTUnwrap(ConversationTranscript.latestReplySlot(messages: fixture.chat.messages, activity: nil))
    var fell = false
    try await waitForUI("the character beside the chat's last reply", in: host.view) {
      fell = fell || character.model.isFalling
      return character.activeSlot == latest && character.isPresent
        && character.model.slot?.size == ConversationTranscript.slotSize
    }
    for _ in 0..<20 {
      await Task.yield()
      host.view.layoutSubtreeIfNeeded()
      host.window.displayIfNeeded()
      fell = fell || character.model.isFalling
    }
    XCTAssertFalse(fell, "Only the first send in the open chat falls")
    XCTAssertEqual(try XCTUnwrap(character.model.slot).center.y, character.model.position.y, accuracy: 1)
  }

  // MARK: Parity

  @MainActor
  func testListOpensAtTheBottomFollowsAReplyAndLetsTheReaderScrollAway() async throws {
    var session = ChatSession(title: "Long chat")
    for index in 0..<24 {
      session.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "Earlier message \(index). " + String(repeating: "A longer reply with wrapping text. ", count: 1 + index % 5)))
    }
    let fixture = try await Fixture(test: self, sessions: [session])
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    func observer() -> ConversationScrollObserver.ObserverView? {
      descendants(host.view).compactMap { $0 as? ConversationScrollObserver.ObserverView }.first
    }
    func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
      guard let document = scroll.documentView else { return .infinity }
      return document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.maxY
        : scroll.contentView.bounds.minY - document.bounds.minY
    }
    try await waitForUI("the chat open at its end", in: host.view) {
      guard let scroll = observer()?.enclosingScrollView, let document = scroll.documentView else { return false }
      return document.bounds.height > scroll.contentView.bounds.height * 2 && distanceFromBottom(scroll) <= 2
        && !host.shows("Example /screen")
    }

    try await send("Continue", in: host, fixture)
    try await waitForUI("the reply's stream", in: host.view) { fixture.engine.requestCount == 1 }
    let first = String(repeating: "More detail. ", count: 500)
    fixture.engine.send(first)
    let scroll = try XCTUnwrap(observer()?.enclosingScrollView)
    try await waitForUI("the list to follow the reply", in: host.view) {
      fixture.chat.messages.last?.content == first && distanceFromBottom(scroll) <= 2
    }
    // The reply is taller than the chat, so its start has scrolled away: the
    // character stays beside it, just inside the chat's top edge.
    let visible = host.view.convert(scroll.bounds, from: scroll)
    try await waitForUI("the character in view beside the long reply", in: host.view) {
      guard fixture.character.isPresent, let slot = fixture.character.model.slot else { return false }
      let top = host.view.isFlipped ? visible.minY : host.view.bounds.height - visible.maxY
      return slot.center.y > top && slot.center.y < top + 80
    }

    // The reader scrolls up a little: streaming no longer pulls them down.
    let watcher = try XCTUnwrap(observer())
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + (scroll.documentView?.isFlipped == false ? 60 : -60)))
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    XCTAssertFalse(watcher.followsLatest)
    let reading = scroll.contentView.bounds.minY
    fixture.engine.send(String(repeating: " Additional streamed detail.", count: 40))
    try await waitForUI("the reply to grow", in: host.view) {
      fixture.chat.messages.last?.content.hasSuffix("Additional streamed detail.") == true
    }
    host.view.layoutSubtreeIfNeeded()
    watcher.scrollToBottomIfFollowing()
    XCTAssertEqual(scroll.contentView.bounds.minY, reading, accuracy: 2, "Streaming leaves the reader where they are")
    fixture.engine.finish()
    try await waitForUI("the request to finish", in: host.view) { fixture.chat.activeRequest == nil }
  }

  @MainActor
  func testEditRevisionCardSitsUnderItsReplyAndReplacesOnlyWhenTheSelectionCanBeReplaced() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    let context = ConversationContext(sourceName: "Mail", text: "send report now")
    fixture.chat.startTemporaryChat(context: context)
    fixture.chat.submit("/edit Make it formal")
    try await waitForUI("the reply's stream", in: host.view) { fixture.engine.requestCount == 1 }
    fixture.engine.send("Here it is, more formal.\n" + SelectionRevisionResponse.opening
      + "{\"operation\":\"replace_selection\",\"text\":\"Please send the report today.\"}" + SelectionRevisionResponse.closing)
    fixture.engine.finish()
    try await waitForUI("the revision card under the reply", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Replace text") && host.shows("Reply")
    }
    XCTAssertEqual(fixture.chat.selectionRevisions.values.first?.text, "Please send the report today.")
    XCTAssertTrue(host.shows("Remove selected text"), "The selected text card stays over the composer")
    try await clickTestControl("Replace text", in: host.view)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(fixture.pastes.texts.isEmpty, "Replace text stays off without a selection to replace, as before")

    // Once the selection's app is remembered, Replace text pastes the revision.
    fixture.selectionContext.remember(context, from: .current)
    try await clickTestControl("Replace text", in: host.view)
    try await waitForUI("the paste", in: host.view) { fixture.pastes.texts == ["Please send the report today."] }
  }

  // MARK: Sizes

  @MainActor
  func testListFitsLongMarkdownCodeTablesAndActivityAtTheMinimumAndDefaultSizes() async throws {
    let fixture = try await Fixture(test: self, sessions: [Self.markdownSession()])
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    for size in [PanelSizeStore.minimumSize, CGSize(width: 1000, height: 660)] {
      host.window.setContentSize(size)
      try await waitForUI("the chat at \(size)", in: host.view) {
        host.shows("Reply") && host.shows("Activity") && host.shows("Send message")
      }
      let bounds = host.view.bounds
      for name in ["Reply", "Reply meta", "Activity", "Send message"] {
        guard let marker = host.marker(name) else { continue }
        let frame = host.view.convert(marker.bounds, from: marker)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.5, "\(name) stays inside the window at \(size): \(frame)")
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name) at \(size)")
      }
      let editor = try XCTUnwrap(composerEditor(in: host.view))
      XCTAssertTrue(bounds.contains(host.view.convert(editor.bounds, from: editor)), "The composer fits at \(size)")
    }
    try await clickTestControl("Activity", in: host.view)
    try await waitForUI("the sources", in: host.view) { host.shows("Activity sources") }
  }

  @MainActor
  func testListRendersSentImagesAndExpandedActivityAtCompactWidth() throws {
    let image = Self.sampleImage()
    var sent = ChatMessage(role: .user, content: "What's on screen?")
    sent.imagePreview = try XCTUnwrap(try ScreenAttachment(image: image).makeMessagePreview())
    sent.attachments = [MessageAttachment(name: "Notes", isDirectory: true)]
    var activity = AssistantActivity(id: UUID())
    activity.apply(.phase(.searching))
    activity.apply(.sourcesSelected(Self.sources))
    activity.apply(.phase(.generating))
    var reply = ChatMessage(role: .assistant, content: "Two windows are open.")
    reply.activity = activity
    for width in [390.0, 680] {
      let view = NSHostingView(rootView: EnigmaMessageList(
        transcript: ConversationTranscript(messages: [sent, reply], activity: activity, isResponding: true),
        scrollRevision: "", activityExpansion: { _ in .constant(true) }) { _ in EmptyView() }
        .frame(width: width, height: 520)
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
        .enigmaTheme(.paper))
      view.frame = NSRect(x: 0, y: 0, width: width, height: 520)
      view.layoutSubtreeIfNeeded()
      let marker = try XCTUnwrap(Host.marker("Your message", in: view))
      XCTAssertLessThanOrEqual(view.convert(marker.bounds, from: marker).maxX, width, "The bubble fits at \(width)")
      XCTAssertNotNil(Host.marker("Activity", in: view))
    }
  }

  // MARK: Cards

  @MainActor
  func testRevisionCardEditsAndReplacesThroughTheSameClosures() async throws {
    var replaced = 0
    var updates: [String] = []
    let ready = SelectionRevision(id: UUID(), contextID: UUID(), text: "Hello team,", automatic: false)
    let card = CardHost(SelectionRevisionCard(revision: ready, disabled: false, update: { updates.append($0) },
                                                    replace: { replaced += 1 }), test: self)
    try await clickTestControl("Edit revised text", in: card.view)
    try await waitForUI("the editor", in: card.view) { card.shows("Done editing") }
    try await clickTestControl("Replace text", in: card.view)
    XCTAssertEqual(replaced, 1)
    try await waitForUI("replacing leaves editing", in: card.view) { card.shows("Edit revised text") }
    XCTAssertTrue(updates.isEmpty)

    // A sent or disabled card can't replace again.
    for (revision, disabled) in [(SelectionRevision(id: UUID(), contextID: UUID(), text: "Hi", automatic: false,
                                                    status: .sent), false), (ready, true)] {
      var count = 0
      let blocked = CardHost(SelectionRevisionCard(revision: revision, disabled: disabled, update: { _ in },
                                                         replace: { count += 1 }), test: self)
      try await clickTestControl("Replace text", in: blocked.view)
      await Task.yield()
      XCTAssertEqual(count, 0)
    }
  }

  @MainActor
  func testSendApprovalSendsOnlyOnSendAndDeclinesOnDontSend() async throws {
    let approval = MessagesSendApproval(conversationName: "Family", recipients: [.init(name: "Alice", handle: "+1 555 0100")],
                                        service: "iMessage", text: "Running late", target: .chat("c"))
    for (button, expected) in [("Send", true), ("Don't Send", false)] {
      var answers: [Bool] = []
      let card = CardHost(MessagesSendApprovalCard(approval: approval) { answers.append($0) }, test: self)
      try await clickTestControl(button, in: card.view)
      XCTAssertEqual(answers, [expected], button)
    }

    var panes: [MessagesPrivacyPane] = []
    var dismissed = 0
    let issue = CardHost(MessagesIssueCard(issue: MessagesIssue(message: "Allow Full Disk Access.", pane: .fullDiskAccess),
                                                 openSettings: { panes.append($0) }, dismiss: { dismissed += 1 }), test: self)
    try await clickTestControl("Open Full Disk Access Settings…", in: issue.view)
    try await clickTestControl("Dismiss", in: issue.view)
    XCTAssertEqual(panes, [.fullDiskAccess])
    XCTAssertEqual(dismissed, 1)
  }

  @MainActor
  func testSendApprovalInTheWindowResolvesTheToolCallAndCancellingDeclines() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let approval = MessagesSendApproval(conversationName: nil, recipients: [.init(name: "Alice", handle: "+1")],
                                        service: "iMessage", text: "On my way", target: .chat("c"))
    let messages = fixture.chat.appleMessages
    let approved = Task { await messages.confirm(approval) }
    try await clickTestControl("Send", in: host.view)
    let sent = await approved.value
    XCTAssertTrue(sent)
    try await waitForUI("the card to close", in: host.view) { !host.shows("Don't Send") }

    let declined = Task { await messages.confirm(approval) }
    try await clickTestControl("Don't Send", in: host.view)
    let notSent = await declined.value
    XCTAssertFalse(notSent)

    let cancelled = Task { await messages.confirm(approval) }
    try await waitForUI("the card", in: host.view) { host.shows("Don't Send") }
    cancelled.cancel()
    let afterCancel = await cancelled.value
    XCTAssertFalse(afterCancel, "Stopping the request declines, as before")
    try await waitForUI("the card to close", in: host.view) { !host.shows("Don't Send") }
  }

  @MainActor
  func testScreenCardsCallTheSameActions() async throws {
    let attachment = try ScreenAttachment(image: Self.sampleImage(), source: .fullDesktop)
    var calls: [String] = []
    let card = CardHost(ScreenAttachmentCard(attachment: attachment, isBusy: false,
      remove: { calls.append("remove") }, retake: { calls.append("retake") }), test: self)
    try await clickTestControl("Retake", in: card.view)
    try await clickTestControl("Remove", in: card.view)
    let busy = CardHost(ScreenAttachmentCard(attachment: attachment, isBusy: true,
      remove: { calls.append("busy remove") }, retake: { calls.append("busy retake") }), test: self)
    try await clickTestControl("Remove", in: busy.view)

    let consent = ScreenUploadConsent(attachment: attachment, provider: .anthropic)
    let sheet = CardHost(ScreenUploadConsentView(consent: consent, allow: { calls.append("allow") },
                                                       decline: { calls.append("decline") }), test: self)
    try await clickTestControl("Keep Screenshots Local", in: sheet.view)
    try await clickTestControl("Allow & Send", in: sheet.view)

    let off = CardHost(ScreenUploadsOffCard(review: { calls.append("review") }, openSettings: { calls.append("settings") }),
                       test: self)
    try await clickTestControl("Review screenshot permission…", in: off.view)
    try await clickTestControl("Open Screen Settings", in: off.view)
    let error = CardHost(ScreenErrorCard(error: "Screen Recording is off.", needsScreenRecordingSettings: true) {
      calls.append("recording")
    }, test: self)
    try await clickTestControl("Open Screen Recording Settings…", in: error.view)
    XCTAssertEqual(calls, ["retake", "remove", "decline", "allow", "review", "settings", "recording"])
  }

  @MainActor
  func testSelectionCardsCallTheSameActions() async throws {
    var calls: [String] = []
    let context = ConversationContext(sourceName: "Notes", text: "Could you please send the report today?")
    let card = CardHost(SelectionContextCard(context: context) { calls.append("remove") }, test: self)
    try await clickTestControl("Remove selected text", in: card.view)
    let busy = CardHost(SelectionContextCard(context: context, isBusy: true) { calls.append("busy") }, test: self)
    try await clickTestControl("Remove selected text", in: busy.view)
    let access = CardHost(AccessibilityNeededCard(appName: "Enigma") { calls.append("settings") }, test: self)
    try await clickTestControl("Open Accessibility Settings…", in: access.view)
    XCTAssertEqual(calls, ["remove", "settings"])
  }

  @MainActor
  func testFileCardsRemoveReviewUndoAndOfferCodex() async throws {
    let (files, root) = try await Self.changedFiles(test: self)
    var codex = 0
    let card = CardHost(VStack(spacing: 8) {
      FileAttachmentCard(files: files, access: .readOnly, isCloud: true, isBusy: false) { codex += 1 }
      FileChangeSummary(files: files, isBusy: false)
    }, test: self)
    try await clickTestControl("Use Codex", in: card.view)
    XCTAssertEqual(codex, 1)
    try await clickTestControl("Review file changes", in: card.view)
    XCTAssertEqual(files.review?.id, files.visibleChanges.first?.id)
    try await clickTestControl("Undo file changes", in: card.view)
    try await waitForUI("the undo", in: card.view) { files.changes.isEmpty && !files.isWorking }
    XCTAssertEqual(try String(contentsOf: root.appending(path: "Project/hello.txt"), encoding: .utf8), "Hello")
    try await clickTestControl("Remove Project", in: card.view)
    try await waitForUI("the folder removed", in: card.view) { files.selection == nil }
  }

  @MainActor
  func testFileReviewSheetUndoesOrClosesWithoutChangingFiles() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let file = fixture.root.appending(path: "Project/hello.txt")
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    for undo in [false, true] {
      await fixture.files.activate(from: .menu)
      let tools = try fixture.files.begin(access: .readWrite)
      try await tools.workspace.apply([.write(path: "hello.txt", content: "Updated")])
      await fixture.files.finish(workspace: tools.workspace)
      try await clickTestControl("Review file changes", in: host.view)
      try await waitForUI("the review sheet", in: host.view) { host.window.attachedSheet != nil }
      let sheet = try XCTUnwrap(host.window.attachedSheet?.contentView)
      try await waitForUI("its controls", in: sheet) { Host.marker("Undo Changes", in: sheet) != nil }
      try await clickTestControl(undo ? "Undo Changes" : "Done reviewing", in: sheet)
      if undo {
        try await waitForUI("the files restored", in: host.view) { fixture.files.changes.isEmpty && !fixture.files.isWorking }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello")
        XCTAssertNil(fixture.files.review, "An undone change set closes its review, as before")
      } else {
        try await waitForUI("the sheet closed", in: host.view) { host.window.attachedSheet == nil }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Updated", "Done changes nothing")
        XCTAssertEqual(fixture.files.changes.count, 1)
        await fixture.files.undo(try XCTUnwrap(fixture.files.changes.first))
      }
      try await waitForUI("no sheet", in: host.view) { host.window.attachedSheet == nil }
    }
  }

  @MainActor
  func testRecoverySheetClosesOnDoneAndAfterAnUndoAndShowsAFailedUndo() async throws {
    func open(_ row: CardHost, _ files: FileModeCoordinator) async throws -> NSView {
      let change = try XCTUnwrap(files.changes.first)
      try await clickTestControl("Review saved file changes", in: row.view)
      try await clickTestControl("Menu item \(change.selection.displayName) · \(change.count) files", in: row.view)
      try await waitForUI("the review sheet", in: row.view) { row.window.attachedSheet != nil }
      let sheet = try XCTUnwrap(row.window.attachedSheet?.contentView)
      try await waitForUI("its controls", in: sheet) { Host.marker("Undo Changes", in: sheet) != nil }
      return sheet
    }

    // Done closes the sheet and leaves the change set alone; Undo closes it once the set is gone.
    let (files, root) = try await Self.changedFiles(test: self)
    let row = CardHost(FileRecoveryRow(files: files), test: self)
    try await clickTestControl("Done reviewing", in: try await open(row, files))
    try await waitForUI("the sheet closed by Done", in: row.view) { row.window.attachedSheet == nil }
    XCTAssertEqual(files.changes.count, 1)
    try await clickTestControl("Undo Changes", in: try await open(row, files))
    try await waitForUI("the sheet closed after Undo", in: row.view) {
      row.window.attachedSheet == nil && files.changes.isEmpty && !files.isWorking
    }
    XCTAssertEqual(try String(contentsOf: root.appending(path: "Project/hello.txt"), encoding: .utf8), "Hello")

    // An undo that fails keeps the sheet open and says why under it.
    let (failing, failingRoot) = try await Self.changedFiles(test: self)
    try FileManager.default.removeItem(at: failingRoot.appending(path: "Project"))
    let failingRow = CardHost(FileRecoveryRow(files: failing), test: self)
    let sheet = try await open(failingRow, failing)
    try await clickTestControl("Undo Changes", in: sheet)
    try await waitForUI("the undo error", in: sheet) {
      guard let error = failing.error, !failing.isWorking else { return false }
      return Host.marker(error, in: sheet) != nil
    }
    XCTAssertNotNil(failingRow.window.attachedSheet, "The change set is still there to review")
    XCTAssertEqual(failing.changes.count, 1)
    try await clickTestControl("Done reviewing", in: sheet)
    try await waitForUI("the sheet closed", in: failingRow.view) { failingRow.window.attachedSheet == nil }
  }

  // MARK: Screenshots

  @MainActor
  func testScreenshots() async throws {
    let folder = try EnigmaSnapshot.directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fixture = try await Fixture(test: self, sessions: [Self.markdownSession()])
    let size = CGSize(width: 1000, height: 660)
    let host = Host(fixture, size: size, test: self)
    let character = fixture.character
    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    // As when the panel opens: the message field takes focus.
    NotificationCenter.default.post(name: .panelPresented, object: nil)
    let latest = try XCTUnwrap(ConversationTranscript.latestReplySlot(messages: fixture.chat.messages, activity: nil))
    try await snapshot("conversation", host, fixture) {
      host.shows("Reply meta") && character.activeSlot == latest && character.isPresent && !character.model.isFalling
    }
    try await clickTestControl("Activity", in: host.view)
    try await snapshot("activity-sources", host, fixture) { host.shows("Activity sources") }

    fixture.chat.newChat()
    try await waitForUI("the main page", in: host.view) { host.shows("Example /screen") }
    try await send("Why does my test read the capture size too early?", in: host, fixture)
    try await waitForUI("the reply's stream", in: host.view) { fixture.engine.requestCount == 1 }
    fixture.engine.send("The test reads `capture.size` before layout finishes, so it sees **zero**. ")
    fixture.engine.send("Wait for the first layout pass, then read it")
    try await snapshot("reply-streaming", host, fixture) {
      character.state == .answering && character.isPresent && !character.model.isFalling
    }
    fixture.engine.finish(throwing: CloudProviderError.invalidResponse)
    try await snapshot("error", host, fixture) { character.state == .error && fixture.chat.activeRequest == nil }

    let approval = MessagesSendApproval(conversationName: nil, recipients: [.init(name: "Alice Chen", handle: "+1 555 0100")],
                                        service: "iMessage", text: "Running ten minutes late, start without me.",
                                        target: .chat("c"))
    let messages = fixture.chat.appleMessages
    let pending = Task { await messages.confirm(approval) }
    try await snapshot("approval-in-chat", host, fixture) { host.shows("Don't Send") }
    messages.answer(false)
    _ = await pending.value

    let attachment = try ScreenAttachment(image: Self.sampleImage(), source: .fullDesktop)
    let (files, _) = try await Self.changedFiles(test: self)
    let revision = SelectionRevision(id: UUID(), contextID: UUID(),
      text: "We're moving launch to the 24th so the migration guide ships with it.", automatic: false)
    try EnigmaSnapshot.save("cards-selection-and-messages", size: CGSize(width: 600, height: 640)) {
      VStack(alignment: .leading, spacing: 12) {
        SelectionRevisionCard(revision: revision, disabled: false, update: { _ in }, replace: {})
        SelectionContextCard(context: ConversationContext(sourceName: "Mail",
          text: "Sorry for the delay! We need to push the launch, hopefully not too far.")) {}
        AccessibilityNeededCard(appName: "Enigma") {}
        MessagesSendApprovalCard(approval: approval) { _ in }
        MessagesIssueCard(issue: MessagesIssue(message: "Enigma needs Full Disk Access to read Messages.",
                                                     pane: .fullDiskAccess), openSettings: { _ in }, dismiss: {})
      }
      .padding(24)
      .frame(width: 600, alignment: .topLeading)
    }
    try EnigmaSnapshot.save("cards-screen-and-files", size: CGSize(width: 600, height: 460)) {
      VStack(alignment: .trailing, spacing: 12) {
        ScreenAttachmentCard(attachment: attachment, isBusy: false, remove: {}, retake: {})
        ScreenUploadsOffCard(review: {}, openSettings: {})
        ScreenErrorCard(error: "Screen Recording is off for Enigma.", needsScreenRecordingSettings: true) {}
        FileAttachmentCard(files: files, access: .readWrite, isCloud: false, isBusy: false) {}
        FileChangeSummary(files: files, isBusy: false)
      }
      .padding(24)
      .frame(width: 600, alignment: .topLeading)
    }
    try EnigmaSnapshot.save("screen-consent", size: CGSize(width: ScreenUploadConsentView.width, height: 520)) {
      ScreenUploadConsentView(consent: ScreenUploadConsent(attachment: attachment, provider: .anthropic),
                                    allow: {}, decline: {})
    }
    let change = try XCTUnwrap(files.visibleChanges.first)
    try EnigmaSnapshot.save("file-review", size: FileChangesReview.size) {
      FileChangesReview(changeSet: change, undo: {})
    }

    var sent = ChatMessage(role: .user, content: "What's on screen?")
    sent.imagePreview = try XCTUnwrap(attachment.makeMessagePreview())
    var answer = ChatMessage(role: .assistant, content: "Two windows are open: Xcode, with a failing test, and Safari.")
    answer.origin = ReplyOrigin(mode: .local, providerID: "local", modelName: "Qwen3 VL 8B")
    try EnigmaSnapshot.save("sent-image", size: CGSize(width: 600, height: 300)) {
      EnigmaMessageList(transcript: ConversationTranscript(messages: [sent, answer], activity: nil, isResponding: false),
                        scrollRevision: "", activityExpansion: { _ in .constant(false) }) { _ in EmptyView() }
    }
  }

  // MARK: Helpers

  private struct NotAReply: Error {}

  private func reply(_ row: ConversationTranscript.Row, file: StaticString = #filePath,
                     line: UInt = #line) throws -> ConversationTranscript.Reply {
    guard case .reply(let reply) = row else {
      XCTFail("Expected a reply", file: file, line: line)
      throw NotAReply()
    }
    return reply
  }

  @MainActor
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  /// Types `text` into the real composer and clicks Send.
  @MainActor
  private func send(_ text: String, in host: Host, _ fixture: Fixture) async throws {
    try await waitForUI("an idle composer", in: host.view) {
      composerEditor(in: host.view)?.isEditable == true && !fixture.chat.isBusy
    }
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await waitForUI("the draft", in: host.view) { fixture.screen.draft == text }
    try await clickTestControl("Send message", in: host.view)
    try await waitForUI("the request (state \(fixture.chat.state), draft \"\(fixture.screen.draft)\")", in: host.view) {
      fixture.chat.activeRequest != nil
    }
  }

  /// Saves the hosted window in Paper and Ink once `ready`, after transitions settle.
  @MainActor
  private func snapshot(_ name: String, _ host: Host, _ fixture: Fixture, until ready: () -> Bool) async throws {
    let folder = try EnigmaSnapshot.directory()
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      fixture.appearance.appearance = appearance
      let probe = CGPoint(x: host.view.bounds.width - 6, y: host.view.bounds.height / 2)
      try await waitForUI("\(name) in \(appearance)", in: host.view, timeout: .seconds(8)) {
        ready() && (try? host.pixel(at: probe)).map { EnigmaSnapshot.matches($0, palette.background) } == true
      }
      for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutSubtreeIfNeeded()
        host.window.displayIfNeeded()
      }
      let image = try host.capture()
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      try png.write(to: folder.appending(path: "\(name)-\(appearance.rawValue).png"))
    }
    fixture.appearance.appearance = .paper
  }

  private static let sources = [
    WebSearchSource(title: "Swift concurrency: actors", url: URL(string: "https://www.swift.org/documentation/concurrency")!),
    WebSearchSource(title: "Isolation in tests", url: URL(string: "https://forums.swift.org/t/actor-isolation-in-tests")!)
  ]

  /// A saved chat with an earlier exchange, then a reply with a list, code, a table, and web sources.
  private static func markdownSession() -> ChatSession {
    var session = ChatSession(title: "Quantizing a GGUF")
    session.append(ChatMessage(role: .user, content: "What does Q4_K_M mean?"))
    session.append(ChatMessage(role: .assistant, content: "It's a 4-bit quantization that keeps the most sensitive weights at higher precision."))
    session.append(ChatMessage(role: .user, content: "How do I make one, and how big will it be?"))
    session.append(ChatMessage(role: .assistant, content: """
    Convert the model, then **quantize** it with `llama-quantize`. See the [quantization notes](https://github.com/ggml-org/llama.cpp) for every type.

    1. Convert the weights to a 16-bit GGUF.
    2. Quantize that file.

    ```
    python convert_hf_to_gguf.py ./Qwen3-8B --outtype f16
    ./llama-quantize qwen3-8b-f16.gguf qwen3-8b-q4_k_m.gguf Q4_K_M
    ```

    | Type | Size | Quality |
    | --- | --- | --- |
    | Q4_K_M | 4.9 GB | Good |
    | Q8_0 | 8.7 GB | Near lossless |
    """, searchSources: sources))
    return session
  }

  /// A small picture of two windows, for screenshots and image previews.
  private static func sampleImage() -> NSImage {
    NSImage(size: NSSize(width: 480, height: 300), flipped: true) { rect in
      NSColor(srgbRed: 0.93, green: 0.92, blue: 0.89, alpha: 1).setFill()
      rect.fill()
      NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1).setFill()
      NSRect(x: 24, y: 28, width: 260, height: 230).fill()
      NSColor.white.setFill()
      NSRect(x: 300, y: 60, width: 156, height: 200).fill()
      NSColor(srgbRed: 0.55, green: 0.75, blue: 0.4, alpha: 1).setFill()
      for line in 0..<7 { NSRect(x: 40, y: 50 + line * 26, width: 120 + (line % 3) * 40, height: 8).fill() }
      return true
    }
  }

  /// A file coordinator with an attached folder and one change set, as after a file task.
  @MainActor
  private static func changedFiles(test: XCTestCase) async throws -> (FileModeCoordinator, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "EnigmaConversationTests-\(UUID())")
    let project = root.appending(path: "Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("Hello".utf8).write(to: project.appending(path: "hello.txt"))
    test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let files = FileModeCoordinator(picker: MainWindowTestPicker([project]), journalDirectory: root.appending(path: "Recovery"))
    await files.activate(from: .menu)
    let tools = try files.begin(access: .readWrite)
    try await tools.workspace.apply([.write(path: "hello.txt", content: "Updated"),
                                     .create(path: "notes.md", content: "# Notes")])
    await files.finish(workspace: tools.workspace)
    return (files, root)
  }
}

/// One card in a key window, with the test markers and the Paper palette.
@MainActor
private final class CardHost {
  let view: NSView
  let window: NSWindow

  init<Content: View>(_ content: Content, size: CGSize = CGSize(width: 560, height: 560), test: XCTestCase) {
    let marker: @MainActor @Sendable (String) -> AnyView = { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) }
    view = NSHostingView(rootView: content
      .padding(20)
      .frame(width: size.width, height: size.height, alignment: .top)
      .enigmaMenuHost()
      .environment(\.enigmaTestMarker, marker)
      .environment(\.screenControlMarker, marker)
      .enigmaTheme(.paper)
      .transaction { $0.disablesAnimations = true })
    window = ConversationKeyableWindow(contentRect: NSRect(origin: .zero, size: size),
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

private final class ConversationKeyableWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}
