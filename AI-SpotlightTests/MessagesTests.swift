import SQLite3
import XCTest
@testable import Enigma

/// A small chat.db with the tables and columns Enigma reads. Never the user's database.
struct MessagesFixture {
  static let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
  static let alice = "+15551230001", bob = "bob@example.com", carol = "+15551230003"
  static let aliceChat = "iMessage;-;+15551230001", groupChat = "any;+;chat123", carolChat = "SMS;-;+15551230003"

  let url: URL

  init(directory: URL) throws {
    url = directory.appendingPathComponent("chat.db")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MessagesError.databaseMissing }
    defer { sqlite3_close(db) }
    func run(_ sql: String) throws {
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw MessagesError.databaseUnreadable(String(cString: sqlite3_errmsg(db)))
      }
    }
    try run("""
      PRAGMA journal_mode = WAL;
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
        date INTEGER, is_from_me INTEGER, cache_has_attachments INTEGER DEFAULT 0,
        associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
      INSERT INTO handle VALUES (1, '\(Self.alice)', 'iMessage'), (2, '\(Self.bob)', 'iMessage'), (3, '\(Self.carol)', 'SMS');
      INSERT INTO chat VALUES (1, '\(Self.aliceChat)', '\(Self.alice)', '', 'iMessage', 45),
        (2, '\(Self.groupChat)', 'chat123', 'Weekend Trip', 'iMessage', 43),
        (3, '\(Self.carolChat)', '\(Self.carol)', NULL, 'SMS', 45);
      INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2), (2, 3), (3, 3);
      """)
    // Text-only, attributedBody-only, a tapback, a group event, and an attachment.
    let rows: [(id: Int, chat: Int, text: String?, body: String?, handle: Int, offset: Double, fromMe: Bool, type: Int, item: Int, attachment: Bool)] = [
      (1, 1, "Are we still on for dinner?", nil, 1, 0, false, 0, 0, false),
      (2, 1, nil, "Yes! 7pm at Café Luna", 0, 60, true, 0, 0, false),
      (3, 1, "Loved “Yes! 7pm at Café Luna”", nil, 1, 120, false, 2000, 0, false),
      (4, 2, "Who's bringing the tent?", nil, 2, 300, false, 0, 0, false),
      (5, 2, "I'll bring it", nil, 0, 360, true, 0, 0, false),
      (6, 2, nil, "Bringing snacks 🍿\u{FFFC}", 3, 420, false, 0, 0, true),
      (7, 2, nil, nil, 2, 500, false, 0, 1, false),
      (8, 3, "Package delivered", nil, 3, -86_400, false, 0, 0, false),
    ]
    for row in rows {
      var statement: OpaquePointer?
      sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil)
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      let date = AppleMessageDate.nanoseconds(Self.start.addingTimeInterval(row.offset))
      sqlite3_bind_int64(statement, 1, Int64(row.id))
      sqlite3_bind_text(statement, 2, "guid-\(row.id)", -1, transient)
      if let text = row.text { sqlite3_bind_text(statement, 3, text, -1, transient) } else { sqlite3_bind_null(statement, 3) }
      if let body = row.body {
        let data = MessagesFixture.attributedBody(body)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), transient) }
      } else { sqlite3_bind_null(statement, 4) }
      sqlite3_bind_int64(statement, 5, Int64(row.handle))
      sqlite3_bind_int64(statement, 6, date)
      sqlite3_bind_int64(statement, 7, row.fromMe ? 1 : 0)
      sqlite3_bind_int64(statement, 8, row.attachment ? 1 : 0)
      sqlite3_bind_int64(statement, 9, Int64(row.type))
      sqlite3_bind_int64(statement, 10, Int64(row.item))
      guard sqlite3_step(statement) == SQLITE_DONE else { throw MessagesError.databaseUnreadable("insert") }
      sqlite3_finalize(statement)
      try run("INSERT INTO chat_message_join VALUES (\(row.chat), \(row.id), \(date))")
    }
  }

  /// The archive Messages writes: an NSAttributedString in typedstream format.
  static func attributedBody(_ text: String) -> Data {
    NSArchiver.archivedData(withRootObject: NSAttributedString(string: text,
      attributes: [NSAttributedString.Key("__kIMMessagePartAttributeName"): 0]))
  }
}

struct FixtureContacts: MessagesContactDirectory {
  var access: MessagesContactsAccess = .granted
  var list = [
    MessagesContact(name: "Alice Smith", phones: ["(555) 123-0001"], emails: []),
    MessagesContact(name: "Bob Jones", phones: [], emails: ["Bob@Example.com"]),
  ]
  func requestAccess() async -> MessagesContactsAccess { access }
  func contacts() async throws -> [MessagesContact] { list }
}

/// Records osascript invocations instead of running them.
final class RecordingRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [(arguments: [String], script: String)] = []
  var result = ProcessOutput(status: 0, output: "sent\n", error: "")

  var invocations: [(arguments: [String], script: String)] { lock.withLock { calls } }

  var run: MessagesSender.Runner {
    { [self] executable, arguments, input in
      XCTAssertEqual(executable.path, "/usr/bin/osascript")
      return lock.withLock {
        calls.append((arguments, input))
        return result
      }
    }
  }
}

final class AppleMessageDateTests: XCTestCase {
  func testConvertsNanosecondsAndLegacySecondsFromAppleEpoch() throws {
    // 2026-09-21 14:13:20 UTC is 811,692,800 seconds after 2001-01-01.
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    XCTAssertEqual(AppleMessageDate.date(811_692_800_000_000_000), date)
    XCTAssertEqual(AppleMessageDate.date(811_692_800), date)
    XCTAssertEqual(AppleMessageDate.nanoseconds(date), 811_692_800_000_000_000)
    XCTAssertEqual(AppleMessageDate.date(AppleMessageDate.nanoseconds(date)), date)
    XCTAssertNil(AppleMessageDate.date(0))
    XCTAssertEqual(AppleMessageDate.date(1), Date(timeIntervalSinceReferenceDate: 1))
  }

  func testFormatsLocalISO8601WithOffset() throws {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    XCTAssertEqual(AppleMessageDate.string(date, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))), "2026-09-21T14:13:20Z")
    XCTAssertEqual(AppleMessageDate.string(date, timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York"))),
      "2026-09-21T10:13:20-04:00")
  }
}

final class AttributedBodyDecoderTests: XCTestCase {
  func testDecodesTypedstreamWrittenByFoundation() {
    for text in ["Hello", "Yes! 7pm at Café Luna 👋", String(repeating: "long ", count: 40), String(repeating: "é", count: 40_000)] {
      XCTAssertEqual(AttributedBodyDecoder.text(from: MessagesFixture.attributedBody(text)), text)
    }
    let mutable = NSMutableAttributedString(string: "Mutable body")
    XCTAssertEqual(AttributedBodyDecoder.text(from: NSArchiver.archivedData(withRootObject: mutable)), "Mutable body")
  }

  func testRejectsMalformedAndTruncatedArchives() {
    let valid = MessagesFixture.attributedBody("Hello there")
    XCTAssertNil(AttributedBodyDecoder.text(from: Data()))
    XCTAssertNil(AttributedBodyDecoder.text(from: Data("not an archive".utf8)))
    let textStart = valid.range(of: Data("Hello".utf8))!.lowerBound
    XCTAssertNil(AttributedBodyDecoder.text(from: valid.prefix(upTo: textStart + 4)), "A body cut inside its text")
    var oversized = valid
    let plus = oversized.firstIndex(of: 0x2B)!
    oversized[plus + 1] = 0x82
    XCTAssertNil(AttributedBodyDecoder.text(from: oversized))
    let streamtyped = Data([0x04, 0x0B]) + Data("streamtyped".utf8)
    XCTAssertNil(AttributedBodyDecoder.text(from: streamtyped + Data("NSString".utf8)))
  }
}

final class MessagesDatabaseTests: XCTestCase {
  private var root: URL!
  private var database: MessagesDatabase!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("MessagesDatabaseTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = MessagesDatabase(url: try MessagesFixture(directory: root).url)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testConversationsUseLatestRealMessageAndIncludeGroupParticipants() throws {
    let conversations = try database.conversations(limit: 10)
    XCTAssertEqual(conversations.map(\.chat.guid), [MessagesFixture.groupChat, MessagesFixture.aliceChat, MessagesFixture.carolChat])
    let group = conversations[0]
    XCTAssertTrue(group.chat.isGroup)
    XCTAssertEqual(group.chat.displayName, "Weekend Trip")
    XCTAssertEqual(group.chat.handles, [MessagesFixture.alice, MessagesFixture.bob, MessagesFixture.carol])
    // The group-event row is skipped; the attachment marker is removed.
    XCTAssertEqual(group.lastMessage.text, "Bringing snacks 🍿")
    XCTAssertTrue(group.lastMessage.hasAttachments)
    XCTAssertEqual(group.lastMessage.handle, MessagesFixture.carol)
    // Tapbacks never become previews; attributedBody-only text is decoded.
    XCTAssertEqual(conversations[1].lastMessage.text, "Yes! 7pm at Café Luna")
    XCTAssertTrue(conversations[1].lastMessage.isFromMe)
    XCTAssertNil(conversations[1].lastMessage.handle)
    XCTAssertNil(conversations[1].chat.displayName, "An empty display name is not a name")
    XCTAssertEqual(conversations[1].lastMessage.date, MessagesFixture.start.addingTimeInterval(60))
    XCTAssertEqual(try database.conversations(limit: 1, oldestFirst: true).map(\.chat.guid), [MessagesFixture.carolChat])
  }

  func testMessagesPageBackwardAndShowReactions() throws {
    let latest = try database.messages(chatGUID: MessagesFixture.groupChat, limit: 2)
    XCTAssertEqual(latest.map(\.rowID), [5, 6])
    let earlier = try database.messages(chatGUID: MessagesFixture.groupChat, limit: 2, beforeMessageID: latest[0].rowID)
    XCTAssertEqual(earlier.map(\.rowID), [4])
    let direct = try database.messages(chatGUID: MessagesFixture.aliceChat, limit: 10)
    XCTAssertEqual(direct.map(\.rowID), [1, 2, 3])
    XCTAssertEqual(direct[2].reaction, "loved a message")
    XCTAssertThrowsError(try database.messages(chatGUID: "missing", limit: 5)) {
      XCTAssertEqual($0 as? MessagesError, .chatNotFound)
    }
  }

  func testSearchIsCaseAndDiacriticInsensitiveWithContext() throws {
    let cafe = try database.search("CAFE luna", limit: 5)
    XCTAssertTrue(cafe.searchedAll)
    XCTAssertEqual(cafe.hits.map(\.match.rowID), [2])
    XCTAssertEqual(cafe.hits[0].before.map(\.rowID), [1])
    XCTAssertEqual(cafe.hits[0].after, [], "Reactions are not context")
    let tent = try database.search("tent", limit: 5)
    XCTAssertEqual(tent.hits.first?.after.map(\.rowID), [5, 6])
    XCTAssertEqual(try database.search("snacks", limit: 5).hits.first?.match.chatGUID, MessagesFixture.groupChat)
    XCTAssertEqual(try database.search("nothing like this", limit: 5).hits, [])
    let limited = try database.search("delivered", limit: 5, scanLimit: 2)
    XCTAssertEqual(limited.hits, [])
    XCTAssertFalse(limited.searchedAll, "A capped scan must say it did not search everything")
    XCTAssertThrowsError(try database.search("  ", limit: 5))
  }

  func testConnectionsAreReadOnlyAndLeaveTheDatabaseUnchanged() throws {
    let before = try Data(contentsOf: database.url)
    _ = try database.conversations(limit: 10)
    _ = try database.search("tent", limit: 5)
    let connection = try SQLiteConnection(readOnly: database.url)
    XCTAssertThrowsError(try connection.execute("INSERT INTO handle VALUES (9, 'x', 'iMessage')"))
    XCTAssertThrowsError(try connection.execute("PRAGMA query_only = 0; DELETE FROM message"))
    connection.close()
    XCTAssertEqual(try Data(contentsOf: database.url), before)
    XCTAssertEqual(try database.chats().count, 3)
  }

  func testMissingAndPrivacyProtectedDatabasesGiveActionableErrors() throws {
    XCTAssertThrowsError(try MessagesDatabase(url: root.appendingPathComponent("absent.db")).conversations(limit: 1)) {
      XCTAssertEqual($0 as? MessagesError, .databaseMissing)
    }
    let locked = root.appendingPathComponent("locked.db")
    try Data("x".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    XCTAssertThrowsError(try MessagesDatabase(url: locked).checkAccess()) {
      XCTAssertEqual($0 as? MessagesError, .fullDiskAccessRequired)
      XCTAssertEqual(($0 as? MessagesError)?.privacyPane, .fullDiskAccess)
      XCTAssertTrue($0.localizedDescription.contains("Full Disk Access"))
    }
  }
}

final class MessagesSenderTests: XCTestCase {
  func testPassesTargetAndTextOnlyAsArguments() async throws {
    let runner = RecordingRunner()
    let sender = MessagesSender(run: runner.run)
    let hostile = #"" & (do shell script "touch /tmp/pwned") & ""#
    try await sender.send(hostile, to: .chat("iMessage;-;+15551230001"))
    try await sender.send("-e looks like a flag", to: .iMessage("+15559990000"))
    let calls = runner.invocations
    XCTAssertEqual(calls.map(\.arguments), [["-", "chat", "iMessage;-;+15551230001", hostile],
      ["-", "imessage", "+15559990000", "-e looks like a flag"]])
    XCTAssertTrue(calls.allSatisfy { $0.script == MessagesSender.script })
    XCTAssertFalse(MessagesSender.script.contains("do shell script"))
    XCTAssertTrue(MessagesSender.script.contains("on run argv"))
  }

  func testMapsAutomationAndMessagesFailures() async {
    let runner = RecordingRunner()
    runner.result = ProcessOutput(status: 1, output: "",
      error: "167:220: execution error: Not authorized to send Apple events to Messages. (-1743)\n")
    do {
      try await MessagesSender(run: runner.run).send("Hi", to: .chat("x"))
      XCTFail("Expected an Automation error")
    } catch {
      XCTAssertEqual(error as? MessagesError, .automationDenied)
      XCTAssertEqual((error as? MessagesError)?.privacyPane, .automation)
    }
    XCTAssertEqual(MessagesSender.error(from: "execution error: Messages got an error: Can’t get chat id \"x\". (-1728)"), .chatNotFound)
    XCTAssertEqual(MessagesSender.error(from: "12:30: execution error: Messages got an error: Service unavailable. (-1)"),
      .sendFailed("Messages got an error: Service unavailable. (-1)"))
  }

  /// Runs the real osascript with a harmless script to prove arguments arrive verbatim.
  func testOsascriptDeliversArgumentsVerbatimFromStandardInputScript() async throws {
    let script = "on run argv\nreturn (item 1 of argv) & \"|\" & (item 2 of argv)\nend run\n"
    let hostile = #"-e" & (do shell script "echo nope") & ""#
    let result = try await MessagesSender.runProcess(MessagesSender.osascript, ["-", hostile, "second"], script)
    XCTAssertEqual(result.status, 0, result.error)
    XCTAssertEqual(result.output.trimmingCharacters(in: .newlines), hostile + "|second")
  }
}

final class MessagesToolsTests: XCTestCase {
  private var root: URL!
  private var database: MessagesDatabase!
  private let utc = TimeZone(identifier: "UTC")!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("MessagesToolsTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = MessagesDatabase(url: try MessagesFixture(directory: root).url)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func tools(contacts: FixtureContacts = FixtureContacts(), runner: RecordingRunner = RecordingRunner(),
                     approve: @escaping @Sendable (MessagesSendApproval) async -> Bool = { _ in true }) -> MessagesTools {
    var tools = MessagesTools(database: database, contacts: contacts, sender: MessagesSender(run: runner.run),
      timeZone: utc, confirmSend: approve)
    tools.sendConfirmationTimeout = .zero
    return tools
  }

  private func json(_ result: AgentToolResult) throws -> CodexValue {
    XCTAssertTrue(result.success, result.text)
    return try JSONDecoder().decode(CodexValue.self, from: Data(result.text.utf8))
  }

  func testListConversationsResolvesNamesAndPreviews() async throws {
    let output = try json(await tools().execute(name: "list_conversations", arguments: .object(["limit": .number(2)])))
    let conversations = try XCTUnwrap(output["conversations"].array)
    XCTAssertEqual(conversations.count, 2)
    XCTAssertEqual(conversations[0]["name"].string, "Weekend Trip")
    XCTAssertEqual(conversations[0]["participants"].array?.compactMap { $0["name"].string }, ["Alice Smith", "Bob Jones"])
    XCTAssertEqual(conversations[0]["last_message"]["from"].string, MessagesFixture.carol, "Unknown senders keep their handle")
    XCTAssertEqual(conversations[1]["name"].string, "Alice Smith")
    XCTAssertEqual(conversations[1]["chat_id"].string, MessagesFixture.aliceChat)
    XCTAssertEqual(conversations[1]["last_message"]["from"].string, "me")
    XCTAssertEqual(conversations[1]["last_message"]["date"].string, "2026-09-21T14:14:20Z")
    XCTAssertEqual(output["contacts_access"].string, "granted")
  }

  func testGetMessagesPaginatesWithCursor() async throws {
    let tools = tools()
    let page = try json(await tools.execute(name: "get_messages",
      arguments: .object(["chat_id": .string(MessagesFixture.groupChat), "limit": .number(2)])))
    XCTAssertEqual(page["messages"].array?.compactMap { $0["text"].string }, ["I'll bring it", "Bringing snacks 🍿"])
    XCTAssertEqual(page["messages"].array?.last?["has_attachment"].bool, true)
    let cursor = try XCTUnwrap(page["next_before"].integer)
    let earlier = try json(await tools.execute(name: "get_messages",
      arguments: .object(["chat_id": .string(MessagesFixture.groupChat), "limit": .number(2), "before": .number(Double(cursor))])))
    XCTAssertEqual(earlier["messages"].array?.compactMap { $0["from"].string }, ["Bob Jones"])
    XCTAssertEqual(earlier["next_before"], .null)
  }

  func testSearchToolsReturnContextAndContacts() async throws {
    let tools = tools()
    let search = try json(await tools.execute(name: "search_messages", arguments: .object(["query": .string("café")])))
    let hit = try XCTUnwrap(search["results"].array?.first)
    XCTAssertEqual(hit["conversation"].string, "Alice Smith")
    XCTAssertEqual(hit["context_before"].array?.first?["text"].string, "Are we still on for dinner?")
    let contacts = try json(await tools.execute(name: "search_contacts", arguments: .object(["query": .string("alice")])))
    XCTAssertEqual(contacts["contacts"].array?.first?["handles"].array?.first?["chat_id"].string, MessagesFixture.aliceChat)
    let byPhone = try json(await tools.execute(name: "search_contacts", arguments: .object(["query": .string("555-123-0003")])))
    XCTAssertEqual(byPhone["other_handles"].array?.first?["handle"].string, MessagesFixture.carol)
  }

  func testInvalidArgumentsAndPermissionErrorsAreReported() async throws {
    let tools = tools()
    let unknown = await tools.execute(name: "get_messages", arguments: .object(["chat": .string("x")]))
    XCTAssertFalse(unknown.success)
    XCTAssertTrue(unknown.text.contains("chat_id"))
    let range = await tools.execute(name: "list_conversations", arguments: .object(["limit": .number(500)]))
    XCTAssertFalse(range.success)
    let locked = MessagesTools(database: MessagesDatabase(url: root.appendingPathComponent("none.db")),
      contacts: FixtureContacts(), confirmSend: { _ in true })
    let missing = await locked.execute(name: "list_conversations", arguments: .object([:]))
    XCTAssertFalse(missing.success)
    XCTAssertTrue(missing.text.contains("Messages has no history"))
  }

  func testSendShowsExactApprovalAndSendsOnlyAfterApproval() async throws {
    let runner = RecordingRunner()
    let seen = ApprovalRecorder()
    let tools = tools(runner: runner) { await seen.record($0); return true }
    let text = "Running 10 min late — save me a seat?"
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice"), "text": .string(text)])))
    let approvals = await seen.approvals
    let approval = try XCTUnwrap(approvals.first)
    XCTAssertEqual(approval.recipients, [.init(name: "Alice Smith", handle: MessagesFixture.alice)])
    XCTAssertEqual(approval.text, text)
    XCTAssertEqual(approval.service, "iMessage")
    XCTAssertEqual(approval.target, .chat(MessagesFixture.aliceChat))
    XCTAssertEqual(runner.invocations.map(\.arguments), [["-", "chat", MessagesFixture.aliceChat, text]])
    XCTAssertEqual(output["status"].string, "handed_to_messages")
    let repeated = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice"), "text": .string(text)]))
    XCTAssertFalse(repeated.success)
    XCTAssertEqual(runner.invocations.count, 1, "An identical second send is refused")
  }

  func testDeclinedSendNeverRunsOsascript() async throws {
    let runner = RecordingRunner()
    let result = await tools(runner: runner) { _ in false }.execute(name: "send_message",
      arguments: .object(["recipient": .string(MessagesFixture.aliceChat), "text": .string("hi")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(result.text.contains("declined"))
    XCTAssertTrue(runner.invocations.isEmpty)
  }

  func testRecipientResolutionCoversGroupsNewNumbersAndAmbiguity() async throws {
    let seen = ApprovalRecorder()
    var contacts = FixtureContacts()
    contacts.list += [MessagesContact(name: "Sam Lee", phones: ["+15550000001"], emails: []),
      MessagesContact(name: "Sam Park", phones: ["+15550000002"], emails: [])]
    let runner = RecordingRunner()
    let tools = tools(contacts: contacts, runner: runner) { await seen.record($0); return true }
    _ = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("weekend trip"), "text": .string("On my way")])))
    _ = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("+1 (555) 999-0000"), "text": .string("Hello")])))
    _ = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("555-123-0003"), "text": .string("Thanks")])))
    let approvals = await seen.approvals
    XCTAssertEqual(approvals[0].conversationName, "Weekend Trip")
    XCTAssertEqual(approvals[0].recipients.map(\.handle), [MessagesFixture.alice, MessagesFixture.bob, MessagesFixture.carol])
    XCTAssertEqual(approvals[1].target, .iMessage("+15559990000"))
    XCTAssertEqual(approvals[2].target, .chat(MessagesFixture.carolChat))
    XCTAssertEqual(approvals[2].service, "SMS")
    let ambiguous = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Sam"), "text": .string("Hi")]))
    XCTAssertFalse(ambiguous.success)
    XCTAssertTrue(ambiguous.text.contains("Sam Lee") && ambiguous.text.contains("Sam Park"))
    let unknown = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Nobody Known"), "text": .string("Hi")]))
    XCTAssertTrue(unknown.text.contains("No contact"))
    let approvalCount = await seen.approvals.count
    XCTAssertEqual(approvalCount, 3, "Unresolved recipients never reach approval")
    XCTAssertEqual(runner.invocations.count, 3)
  }

  func testAutomationDenialStopsTheRequestWithSettingsGuidance() async throws {
    let runner = RecordingRunner()
    runner.result = ProcessOutput(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Messages. (-1743)")
    let result = await tools(runner: runner).execute(name: "send_message",
      arguments: .object(["recipient": .string(MessagesFixture.aliceChat), "text": .string("hi")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(result.terminal)
    XCTAssertTrue(result.text.contains("Automation"))
  }

  func testWithoutContactsAccessHandlesAreShown() async throws {
    let output = try json(await tools(contacts: FixtureContacts(access: .denied)).execute(name: "list_conversations",
      arguments: .object([:])))
    XCTAssertEqual(output["contacts_access"].string, "denied")
    XCTAssertEqual(output["conversations"].array?[1]["name"].string, MessagesFixture.alice)
  }

  func testConfirmedSendIsReportedFromMessagesHistory() async throws {
    // Simulate Messages recording the outgoing message after osascript returns.
    let url = database.url
    let runner = RecordingRunner()
    let recording = MessagesSender { _, arguments, _ in
      var db: OpaquePointer?
      sqlite3_open(url.path, &db)
      let date = AppleMessageDate.nanoseconds(.now)
      sqlite3_exec(db, "INSERT INTO message VALUES (20, 'g20', '\(arguments[3])', NULL, 0, \(date), 1, 0, 0, 0); INSERT INTO chat_message_join VALUES (1, 20, \(date));", nil, nil, nil)
      sqlite3_close(db)
      return try await runner.run(MessagesSender.osascript, arguments, "")
    }
    let tools = MessagesTools(database: database, contacts: FixtureContacts(), sender: recording, confirmSend: { _ in true })
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("See you soon")])))
    XCTAssertEqual(output["status"].string, "sent")
  }
}

actor ApprovalRecorder {
  private(set) var approvals: [MessagesSendApproval] = []
  func record(_ approval: MessagesSendApproval) { approvals.append(approval) }
}

@MainActor
final class MessagesCoordinatorTests: XCTestCase {
  private func approval() -> MessagesSendApproval {
    MessagesSendApproval(conversationName: nil, recipients: [.init(name: "Alice", handle: "+1")], service: "iMessage",
      text: "Hi", target: .chat("c"))
  }

  func testApprovalResolvesOnlyFromTheUsersAnswer() async {
    let coordinator = MessagesCoordinator(defaults: UserDefaults(suiteName: "MessagesCoordinatorTests-\(UUID())")!)
    let pending = Task { await coordinator.confirm(approval()) }
    while coordinator.pendingSend == nil { await Task.yield() }
    XCTAssertEqual(coordinator.pendingSend?.text, "Hi")
    coordinator.answer(true)
    let approved = await pending.value
    XCTAssertTrue(approved)
    XCTAssertNil(coordinator.pendingSend)
  }

  func testCancellingTheRequestDeclines() async {
    let coordinator = MessagesCoordinator(defaults: UserDefaults(suiteName: "MessagesCoordinatorTests-\(UUID())")!)
    let pending = Task { await coordinator.confirm(approval()) }
    while coordinator.pendingSend == nil { await Task.yield() }
    pending.cancel()
    let approved = await pending.value
    XCTAssertFalse(approved)
    XCTAssertNil(coordinator.pendingSend)
  }

  func testCloudDisclosureIsRememberedPerProviderOnlyWhenAllowed() throws {
    let suite = "MessagesCoordinatorTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let coordinator = MessagesCoordinator(defaults: defaults)
    coordinator.requestDisclosure(for: .anthropic, prompt: "summarize")
    XCTAssertNil(coordinator.answerDisclosure(allow: false))
    XCTAssertFalse(coordinator.hasDisclosed(.anthropic))
    coordinator.requestDisclosure(for: .anthropic, prompt: "summarize")
    XCTAssertEqual(coordinator.answerDisclosure(allow: true), "summarize")
    XCTAssertTrue(coordinator.hasDisclosed(.anthropic))
    XCTAssertFalse(coordinator.hasDisclosed(.gemini))
  }

  func testMessagesCommandIsRecognizedAndRemovedFromThePrompt() {
    let commands = ComposerCommands("/messages who texted me last?")
    XCTAssertTrue(commands.messages)
    XCTAssertEqual(commands.prompt, "who texted me last?")
    XCTAssertFalse(ComposerCommands("see ~/messages folder").messages)
    XCTAssertEqual(SlashCommand.messages.assetImage, "MessagesTool")
    XCTAssertNotNil(NSImage(named: "MessagesTool"))
  }
}
