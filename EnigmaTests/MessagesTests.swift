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
        associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, error INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 0);
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
      sqlite3_prepare_v2(db, """
        INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, cache_has_attachments,
          associated_message_type, item_type, is_sent) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, -1, &statement, nil)
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
      sqlite3_bind_int64(statement, 11, row.fromMe ? 1 : 0)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw MessagesError.databaseUnreadable("insert") }
      sqlite3_finalize(statement)
      try run("INSERT INTO chat_message_join VALUES (\(row.chat), \(row.id), \(date))")
    }
  }

  /// Writes to a fixture database the way Messages would.
  static func execute(_ sql: String, at url: URL) {
    var db: OpaquePointer?
    sqlite3_open(url.path, &db)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
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

  func testOutgoingListsOnlyMessagesAddedAfterTheGivenRow() throws {
    let last = try database.latestMessageID()
    XCTAssertEqual(last, 8)
    XCTAssertEqual(try database.outgoing(chatGUID: MessagesFixture.aliceChat, after: last).count, 0,
      "Earlier messages, such as row 2, are not part of a new send")
    let date = AppleMessageDate.nanoseconds(MessagesFixture.start.addingTimeInterval(600))
    MessagesFixture.execute("""
      INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent, error) VALUES
        (20, 'g20', 'Failed', 1, \(date), 1, 1, 22), (21, 'g21', 'Sending', 1, \(date), 1, 0, 0),
        (22, 'g22', 'Sent', 1, \(date), 1, 1, 0), (23, 'g23', 'Reply', 1, \(date), 0, 0, 0);
      INSERT INTO chat_message_join VALUES (1, 20, \(date)), (1, 21, \(date)), (1, 22, \(date)), (1, 23, \(date));
      """, at: database.url)
    let rows = try database.outgoing(chatGUID: MessagesFixture.aliceChat, after: last)
    XCTAssertEqual(rows.map(\.message.rowID), [20, 21, 22], "Only this Mac's messages, oldest first")
    XCTAssertEqual(rows.map(\.isFailed), [true, false, false])
    XCTAssertEqual(rows.map(\.isSent), [true, false, true])
    XCTAssertEqual(try database.outgoing(chatGUID: MessagesFixture.aliceChat, after: 21).map(\.message.rowID), [22])
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

  /// The unsigned test host shares Enigma's bundle ID: opening the real chat.db makes macOS
  /// replace the user's Full Disk Access grant with a denial for the test build.
  func testTheTestHostNeverOpensTheRealMessagesDatabase() {
    let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
    guard MessagesDatabase.defaultURL.standardizedFileURL != real.standardizedFileURL else {
      return XCTFail("The test host must not open the real chat.db")
    }
    XCTAssertThrowsError(try MessagesDatabase().checkAccess()) {
      XCTAssertEqual($0 as? MessagesError, .databaseMissing)
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
                     sender: MessagesSender? = nil,
                     approve: @escaping @Sendable (MessagesSendApproval) async -> Bool = { _ in true }) -> MessagesTools {
    var tools = MessagesTools(database: database, contacts: contacts, sender: sender ?? MessagesSender(run: runner.run),
      timeZone: utc, confirmSend: approve)
    tools.sendConfirmationTimeout = .zero
    tools.sendConfirmationPause = { XCTFail("A zero timeout checks once without pausing"); throw CancellationError() }
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
    for result in [unknown, range] {
      XCTAssertFalse(result.terminal, "The model can correct its arguments")
      XCTAssertNil(result.stop)
    }
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
    XCTAssertEqual(output["status"].string, "handed_to_messages", "The fake runner records nothing in Messages history")
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
    XCTAssertFalse(result.terminal, "A declined send goes back to the model, not to a settings card")
    XCTAssertNil(result.stop)
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
    XCTAssertFalse(ambiguous.terminal, "The model asks which person is meant")
    XCTAssertNil(ambiguous.stop)
    let unknown = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Nobody Known"), "text": .string("Hi")]))
    XCTAssertTrue(unknown.text.contains("No contact"))
    let approvalCount = await seen.approvals.count
    XCTAssertEqual(approvalCount, 3, "Unresolved recipients never reach approval")
    XCTAssertEqual(runner.invocations.count, 3)
  }

  func testNewConversationPrefersPhoneThenMobileThenEmail() async throws {
    var contacts = FixtureContacts()
    contacts.list += [
      MessagesContact(name: "Pat Both", phones: ["+15550001001"], emails: ["pat@example.com"]),
      MessagesContact(name: "Quinn Mobile", phones: ["+15550002001", "+15550002002"], emails: ["quinn@example.com"],
        mobilePhones: ["+15550002002"]),
      MessagesContact(name: "Rene Phones", phones: ["+15550003001", "+15550003002"], emails: ["rene@example.com"]),
      MessagesContact(name: "Sky Email", phones: [], emails: ["sky@example.com"]),
      MessagesContact(name: "Tess Twice", phones: ["+15550005001", "(555) 000-5001"], emails: []),
      MessagesContact(name: "Uma Mobiles", phones: ["+15550006001", "+15550006002"], emails: [],
        mobilePhones: ["+15550006001", "+15550006002"]),
    ]
    let seen = ApprovalRecorder()
    let tools = tools(contacts: contacts) { await seen.record($0); return true }
    for name in ["Pat Both", "Quinn Mobile", "Sky Email", "Tess Twice"] {
      _ = try json(await tools.execute(name: "send_message",
        arguments: .object(["recipient": .string(name), "text": .string("Hi")])))
    }
    let approvals = await seen.approvals
    XCTAssertEqual(approvals.map(\.target),
      [.iMessage("+15550001001"), .iMessage("+15550002002"), .iMessage("sky@example.com"),
       .iMessage("+15550005001")])
    let twoMobiles = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Uma Mobiles"), "text": .string("Hi")]))
    XCTAssertFalse(twoMobiles.success)
    XCTAssertTrue(twoMobiles.text.contains("+15550006001") && twoMobiles.text.contains("+15550006002"))
    let ambiguous = await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Rene Phones"), "text": .string("Hi")]))
    XCTAssertFalse(ambiguous.success)
    let first = try XCTUnwrap(ambiguous.text.range(of: "+15550003001"))
    let email = try XCTUnwrap(ambiguous.text.range(of: "rene@example.com"))
    XCTAssertTrue(ambiguous.text.contains("+15550003002") && first.lowerBound < email.lowerBound)
    let count = await seen.approvals.count
    XCTAssertEqual(count, 4)
  }

  func testExistingEmailConversationStillWinsOverPhone() async throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(database.url.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, """
      INSERT INTO handle VALUES (4, 'dana@example.com', 'iMessage');
      INSERT INTO chat VALUES (4, 'iMessage;-;dana@example.com', 'dana@example.com', NULL, 'iMessage', 45);
      INSERT INTO chat_handle_join VALUES (4, 4);
      """, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    var contacts = FixtureContacts()
    contacts.list.append(MessagesContact(name: "Dana Email", phones: ["+15550004001"], emails: ["dana@example.com"]))
    let seen = ApprovalRecorder()
    let tools = tools(contacts: contacts) { await seen.record($0); return true }
    _ = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Dana Email"), "text": .string("Hi")])))
    let approvals = await seen.approvals
    XCTAssertEqual(approvals.first?.target, .chat("iMessage;-;dana@example.com"))
  }

  func testSameNameContactCardsAreDifferentPeopleAndAreAskedAbout() async throws {
    var contacts = FixtureContacts()
    contacts.list += [
      // A second Alice Smith; the fixture's first one already has a conversation.
      MessagesContact(name: "Alice Smith", phones: ["+15550007001"], emails: [], organization: "Acme",
        labels: ["+15550007001": "work"]),
      MessagesContact(name: "Jordan Lee", phones: ["+15550008001"], emails: [], mobilePhones: ["+15550008001"],
        labels: ["+15550008001": "mobile"]),
      MessagesContact(name: "Jordan Lee", phones: ["+15550008002"], emails: [], labels: ["+15550008002": "home"]),
      MessagesContact(name: "Casey Tran", phones: ["+15550009001"], emails: []),
      MessagesContact(name: "Casey Tran", phones: [], emails: ["casey@example.com"], organization: "Initech"),
      MessagesContact(name: "Robin Twice", phones: ["+15550010001"], emails: []),
      MessagesContact(name: "Robin Twice", phones: ["(555) 001-0001"], emails: []),
    ]
    let seen = ApprovalRecorder()
    let runner = RecordingRunner()
    let tools = tools(contacts: contacts, runner: runner) { await seen.record($0); return true }
    func ask(_ name: String) async -> String {
      let result = await tools.execute(name: "send_message",
        arguments: .object(["recipient": .string(name), "text": .string("Hi")]))
      XCTAssertFalse(result.success, name)
      XCTAssertTrue(result.text.contains("Ask the user which one"), result.text)
      return result.text
    }
    let alice = await ask("Alice Smith")
    XCTAssertTrue(alice.contains("Alice Smith: (555) 123-0001"), alice)
    XCTAssertTrue(alice.contains("Alice Smith (Acme): work +15550007001"), alice)
    let jordan = await ask("Jordan Lee")
    XCTAssertTrue(jordan.contains("mobile +15550008001") && jordan.contains("home +15550008002"), jordan)
    let casey = await ask("Casey Tran")
    XCTAssertTrue(casey.contains("Casey Tran: +15550009001"), casey)
    XCTAssertTrue(casey.contains("Casey Tran (Initech): casey@example.com"), casey)
    var count = await seen.approvals.count
    XCTAssertEqual(count, 0, "Choosing between people never reaches approval")
    XCTAssertTrue(runner.invocations.isEmpty)
    // One person saved twice with the same number is still one person.
    _ = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Robin Twice"), "text": .string("Hi")])))
    count = await seen.approvals.count
    let target = await seen.approvals.first?.target
    XCTAssertEqual(count, 1)
    XCTAssertEqual(target, .iMessage("+15550010001"))
  }

  func testAmbiguityListsNamesOnlyForDifferentPeopleAndIsCapped() async throws {
    var contacts = FixtureContacts()
    contacts.list += [
      MessagesContact(name: "Sam Lee", phones: ["+15550000001"], emails: [], organization: "Example Co"),
      MessagesContact(name: "Sam Park", phones: ["+15550000002"], emails: ["sam@example.com"]),
      // Two cards named like the group: both people are told apart, as in the person-only case.
      MessagesContact(name: "Weekend Trip", phones: ["+15550000003"], emails: []),
      MessagesContact(name: "Weekend Trip", phones: ["+15550000004"], emails: []),
    ]
    // Listed out of order, as Contacts may enumerate them: the list is sorted before the cap.
    contacts.list += (1...25).reversed().map { MessagesContact(name: String(format: "Pat Many %02d", $0),
      phones: [String(format: "+155500200%02d", $0)], emails: []) }
    contacts.list += [MessagesContact(name: "Quill Apart", phones: ["+15550030001"], emails: []),
      MessagesContact(name: "Quill Between", phones: ["+15550030002"], emails: []),
      MessagesContact(name: "Quill Apart", phones: ["+15550030003"], emails: [])]
    let seen = ApprovalRecorder()
    let tools = tools(contacts: contacts) { await seen.record($0); return true }
    func ask(_ name: String) async -> String {
      let result = await tools.execute(name: "send_message",
        arguments: .object(["recipient": .string(name), "text": .string("Hi")]))
      XCTAssertFalse(result.success, name)
      return result.text
    }
    let sam = await ask("Sam")
    XCTAssertTrue(sam.contains("Sam Lee; Sam Park"), sam)
    XCTAssertFalse(sam.contains("+1555000000") || sam.contains("Example Co") || sam.contains("@"), sam)
    let trip = await ask("Weekend Trip")
    XCTAssertTrue(trip.contains("group Weekend Trip (chat_id \(MessagesFixture.groupChat))"), trip)
    XCTAssertTrue(trip.contains("Weekend Trip: +15550000003") && trip.contains("Weekend Trip: +15550000004"), trip)
    // One person named like a group still gets their handle, so choosing them doesn't ask again.
    var single = FixtureContacts()
    single.list.append(MessagesContact(name: "Weekend Trip", phones: ["+15550000005"], emails: []))
    let lone = await self.tools(contacts: single).execute(name: "send_message",
      arguments: .object(["recipient": .string("Weekend Trip"), "text": .string("Hi")]))
    XCTAssertFalse(lone.success)
    XCTAssertTrue(lone.text.contains("group Weekend Trip (chat_id \(MessagesFixture.groupChat)); Weekend Trip: +15550000005"),
                  lone.text)
    let many = await ask("Pat Many")
    XCTAssertTrue(many.contains("Pat Many 01; Pat Many 02") && many.contains("Pat Many 20"), many)
    XCTAssertFalse(many.contains("Pat Many 21"), many)
    let quill = await ask("Quill")
    XCTAssertTrue(quill.contains("Quill Apart: +15550030001; Quill Apart: +15550030003; Quill Between"), quill)
    XCTAssertTrue(many.contains("and 5 more (use search_contacts to narrow it down)"), many)
    let count = await seen.approvals.count
    XCTAssertEqual(count, 0)
  }

  func testSameNameChoicesLeadWithTheHandleASendWouldUse() async throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(database.url.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, """
      INSERT INTO handle VALUES (4, 'dana@example.com', 'iMessage');
      INSERT INTO chat VALUES (4, 'iMessage;-;dana@example.com', 'dana@example.com', NULL, 'iMessage', 45);
      INSERT INTO chat_handle_join VALUES (4, 4);
      """, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    var contacts = FixtureContacts()
    contacts.list += [
      MessagesContact(name: "Dana Email", phones: ["+15550004001"], emails: ["dana@example.com"]),
      MessagesContact(name: "Dana Email", phones: ["+15550004002", "+15550004003"], emails: ["dana.home@example.com"],
        mobilePhones: ["+15550004003"],
        labels: ["+15550004002": "home", "+15550004003": "mobile", "dana.home@example.com": "home"]),
    ]
    let result = await tools(contacts: contacts).execute(name: "send_message",
      arguments: .object(["recipient": .string("Dana Email"), "text": .string("Hi")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(result.text.contains("Dana Email: dana@example.com (chat_id iMessage;-;dana@example.com), +15550004001"),
                  result.text)
    XCTAssertTrue(result.text.contains("Dana Email: mobile +15550004003, home +15550004002, home dana.home@example.com"), result.text)
  }

  func testDuplicateCardsCombineTheirMobileLabels() {
    let plain = MessagesContact(name: "Robin Twice", phones: ["+15550010001", "+15550010002"], emails: [])
    let labelled = MessagesContact(name: "Robin Twice", phones: ["(555) 001-0001", "+15550010002"], emails: [],
      mobilePhones: ["(555) 001-0001"], labels: ["(555) 001-0001": "mobile"])
    for order in [[plain, labelled], [labelled, plain]] {
      let merged = MessagesContact.mergingDuplicates(order)
      XCTAssertEqual(merged.count, 1)
      XCTAssertEqual(merged[0].mobilePhones.map(MessagesHandle.key), ["5550010001"])
      XCTAssertTrue(merged[0].distinguishingDescription().contains("mobile"), merged[0].distinguishingDescription())
    }
  }

  func testAutomationDenialStopsTheRequestWithSettingsGuidance() async throws {
    let runner = RecordingRunner()
    runner.result = ProcessOutput(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Messages. (-1743)")
    let result = await tools(runner: runner).execute(name: "send_message",
      arguments: .object(["recipient": .string(MessagesFixture.aliceChat), "text": .string("hi")]))
    XCTAssertFalse(result.success)
    XCTAssertTrue(result.terminal)
    XCTAssertEqual(result.stop, .messages(.automationDenied), "The request ends with the error that offers Automation settings")
    XCTAssertTrue(result.text.contains("Automation"))
    XCTAssertEqual(runner.invocations.count, 1)
  }

  func testStoppedRequestEndsAsCancelledWithoutSettingsGuidance() async throws {
    let toolbox = tools()
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await toolbox.execute(name: "list_conversations", arguments: .object([:]))
    }.value
    XCTAssertTrue(result.terminal)
    XCTAssertEqual(result.stop, .cancelled)
    XCTAssertTrue(result.stopError is CancellationError)
  }

  func testSettingsButtonsAreNamedAfterTheirPane() {
    XCTAssertEqual(MessagesPrivacyPane.fullDiskAccess.settingsButtonTitle, "Open Full Disk Access Settings…")
    XCTAssertEqual(MessagesPrivacyPane.automation.settingsButtonTitle, "Open Automation Settings…")
    XCTAssertEqual(MessagesPrivacyPane.contacts.settingsButtonTitle, "Open Contacts Settings…")
  }

  func testWithoutContactsAccessHandlesAreShown() async throws {
    let output = try json(await tools(contacts: FixtureContacts(access: .denied)).execute(name: "list_conversations",
      arguments: .object([:])))
    XCTAssertEqual(output["contacts_access"].string, "denied")
    XCTAssertEqual(output["conversations"].array?[1]["name"].string, MessagesFixture.alice)
  }

  func testConfirmedSendIsReportedFromMessagesHistory() async throws {
    // Simulate Messages recording the outgoing message after osascript returns.
    let recording = sender { Self.outgoing($0, id: 20) }
    let tools = MessagesTools(database: database, contacts: FixtureContacts(), sender: recording, confirmSend: { _ in true })
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("See you soon")])))
    XCTAssertEqual(output["status"].string, "sent")
  }

  func testFailedOrUnsentMessageInAnExistingChatIsNotReportedAsSent() async throws {
    let failed = try json(await tools(sender: sender { Self.outgoing($0, id: 20, error: 22) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(failed["status"].string, "handed_to_messages", "Messages marked the message as failed")
    XCTAssertTrue(failed["note"].string?.contains("may have failed") == true)
    let pending = try json(await tools(sender: sender { Self.outgoing($0, id: 21, isSent: false) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("Alice Smith"), "text": .string("On my way")])))
    XCTAssertEqual(pending["status"].string, "handed_to_messages", "Messages is still sending it")
  }

  func testSendToANewHandleIsConfirmedInTheConversationMessagesCreates() async throws {
    let seen = ApprovalRecorder()
    let tools = tools(sender: sender { Self.newChat("+15559990000", id: 10, text: $0) }) { await seen.record($0); return true }
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("+1 (555) 999-0000"), "text": .string("Hello there")])))
    let approvals = await seen.approvals
    XCTAssertEqual(approvals.first?.target, .iMessage("+15559990000"))
    XCTAssertEqual(output["status"].string, "sent")
    XCTAssertEqual(output["note"].string, "Messages history shows the message as sent.")
  }

  func testSendToANewHandleWithoutItsConversationIsOnlyHandedToMessages() async throws {
    let runner = RecordingRunner()
    let nothing = try json(await tools(runner: runner).execute(name: "send_message",
      arguments: .object(["recipient": .string("+1 (555) 999-0000"), "text": .string("Hello there")])))
    XCTAssertEqual(runner.invocations.map(\.arguments), [["-", "imessage", "+15559990000", "Hello there"]])
    XCTAssertEqual(nothing["status"].string, "handed_to_messages", "No conversation appeared")
    let group = try json(await tools(sender: sender { Self.newChat("+15559990000", id: 10, style: 43, text: $0) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("+15559990000"), "text": .string("Hello group")])))
    XCTAssertEqual(group["status"].string, "handed_to_messages", "A group with the handle is not its conversation")
  }

  func testNewHandleConversationMatchesAnyFormatOfTheHandle() async throws {
    let phone = try json(await tools(sender: sender { Self.newChat("5559990000", id: 10, text: $0) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("+15559990000"), "text": .string("Hi")])))
    XCTAssertEqual(phone["status"].string, "sent")
    let email = try json(await tools(sender: sender { Self.newChat("Dana@Example.com", id: 11, text: $0) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("dana@example.com"), "text": .string("Hi")])))
    XCTAssertEqual(email["status"].string, "sent")
  }

  func testNewHandleIsNotConfirmedBySameTextInAnotherConversation() async throws {
    let output = try json(await tools(sender: sender { Self.outgoing($0, id: 20) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("+15559990000"), "text": .string("On my way")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages", "Alice's conversation is not the new handle's")
  }

  func testIdenticalMessageSentJustBeforeDoesNotConfirmAFailedSend() async throws {
    // The same text went out a moment ago, inside any time window, and this send fails.
    MessagesFixture.execute(Self.outgoing("Running late", id: 20), at: database.url)
    let output = try json(await tools(sender: sender { Self.outgoing($0, id: 21, error: 22) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages", "Only messages added by this send count")
  }

  func testEarlierIdenticalMessageDoesNotConfirmASendThatNeverAppears() async throws {
    MessagesFixture.execute(Self.outgoing("Running late", id: 20), at: database.url)
    let output = try json(await tools().execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages", "The earlier copy was there before the send")
  }

  func testEveryNewCopyMustBeSent() async throws {
    // One copy went out and one is still sending; the one still sending may be this send.
    let output = try json(await tools(sender: sender { Self.outgoing($0, id: 20) + Self.outgoing($0, id: 21, isSent: false) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages")
  }

  func testAnyFailedCopyMeansNotSentWithoutWaiting() async throws {
    // Another request sent the same text at the same moment; one of the two failed.
    var tools = tools(sender: sender { Self.outgoing($0, id: 20) + Self.outgoing($0, id: 21, error: 22) })
    tools.sendConfirmationTimeout = .seconds(60)
    tools.sendConfirmationPause = { XCTFail("A failure is final, so there is nothing to wait for"); throw CancellationError() }
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages")
  }

  func testOlderIdenticalMessageSyncedInDuringTheCheckIsNotConfirmation() async throws {
    // Messages in iCloud brings in an hour-old copy as a new row; this send's own row then fails.
    let url = database.url
    var tools = tools(sender: sender { Self.outgoing($0, id: 20, secondsAgo: 3600) })
    tools.sendConfirmationTimeout = .seconds(60)
    tools.sendConfirmationPause = { MessagesFixture.execute(Self.outgoing("Running late", id: 21, error: 22), at: url) }
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages", "The synced copy is not this send")
  }

  func testSendWithoutAStartingPointIsNotConfirmed() async throws {
    // Resolving by chat_id reads only chats and handles, so the send goes ahead without one.
    MessagesFixture.execute("ALTER TABLE message RENAME TO message_moved", at: database.url)
    let output = try json(await tools().execute(name: "send_message",
      arguments: .object(["recipient": .string(MessagesFixture.aliceChat), "text": .string("Hi")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages")
  }

  func testDifferentTextInHistoryIsNotConfirmation() async throws {
    let output = try json(await tools(sender: sender { _ in Self.outgoing("Something else", id: 20) })
      .execute(name: "send_message", arguments: .object(["recipient": .string("Alice Smith"), "text": .string("Running late")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages")
  }

  func testChecksAgainAfterEachPauseUntilMessagesRecordsTheSend() async throws {
    let url = database.url
    let pauses = PauseCounter()
    var newHandle = tools()
    newHandle.sendConfirmationTimeout = .seconds(60)
    newHandle.sendConfirmationPause = {
      let pause = pauses.next()
      if pause == 1 { MessagesFixture.execute(Self.newChat("+15559990000", id: 10, text: "Hello there"), at: url) }
      // A broken check fails here instead of spinning until the timeout.
      if pause > 3 { throw CancellationError() }
    }
    let created = try json(await newHandle.execute(name: "send_message",
      arguments: .object(["recipient": .string("+15559990000"), "text": .string("Hello there")])))
    XCTAssertEqual(created["status"].string, "sent", "The conversation is looked up again after the pause")
    XCTAssertEqual(pauses.count, 1)

    let existingPauses = PauseCounter()
    var existing = tools()
    existing.sendConfirmationTimeout = .seconds(60)
    existing.sendConfirmationPause = {
      let pause = existingPauses.next()
      if pause == 1 { MessagesFixture.execute(Self.outgoing("On my way", id: 20), at: url) }
      if pause > 3 { throw CancellationError() }
    }
    let recorded = try json(await existing.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("On my way")])))
    XCTAssertEqual(recorded["status"].string, "sent")
    XCTAssertEqual(existingPauses.count, 1)
  }

  func testStoppingDuringThePauseEndsTheCheck() async throws {
    let url = database.url
    let pauses = PauseCounter()
    var tools = tools()
    tools.sendConfirmationTimeout = .seconds(60)
    tools.sendConfirmationPause = {
      // Were the check to go on, it would find this and report the send as confirmed.
      if pauses.next() == 2 { MessagesFixture.execute(Self.outgoing("On my way", id: 20), at: url) }
      throw CancellationError()
    }
    let output = try json(await tools.execute(name: "send_message",
      arguments: .object(["recipient": .string("Alice Smith"), "text": .string("On my way")])))
    XCTAssertEqual(output["status"].string, "handed_to_messages")
    XCTAssertEqual(pauses.count, 1, "No check after the pause was stopped")
  }

  /// A sender that, like Messages, records the send in the fixture database before returning.
  private func sender(recording sql: @escaping @Sendable (_ text: String) -> String) -> MessagesSender {
    let url = database.url, runner = RecordingRunner()
    return MessagesSender { _, arguments, _ in
      MessagesFixture.execute(sql(arguments[3]), at: url)
      return try await runner.run(MessagesSender.osascript, arguments, "")
    }
  }

  /// An outgoing message in Alice's conversation, dated now unless `secondsAgo` says otherwise.
  private static func outgoing(_ text: String, id: Int, isSent: Bool = true, error: Int = 0,
                               secondsAgo: TimeInterval = 0) -> String {
    let date = AppleMessageDate.nanoseconds(.now.addingTimeInterval(-secondsAgo))
    return """
      INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent, error)
        VALUES (\(id), 'g\(id)', '\(text)', 1, \(date), 1, \(isSent ? 1 : 0), \(error));
      INSERT INTO chat_message_join VALUES (1, \(id), \(date));
      """
  }

  /// The conversation Messages creates for a new handle, holding the sent message.
  private static func newChat(_ handle: String, id: Int, style: Int = 45, text: String) -> String {
    let date = AppleMessageDate.nanoseconds(.now)
    return """
      INSERT INTO handle VALUES (\(id), '\(handle)', 'iMessage');
      INSERT INTO chat VALUES (\(id), 'iMessage;\(style == 43 ? "+;chat\(id)" : "-;\(handle)")', '\(handle)', NULL, 'iMessage', \(style));
      INSERT INTO chat_handle_join VALUES (\(id), \(id));
      INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_sent)
        VALUES (\(id), 'g\(id)', '\(text)', \(id), \(date), 1, 1);
      INSERT INTO chat_message_join VALUES (\(id), \(id), \(date));
      """
  }
}

/// Counts calls from a `@Sendable` closure.
private final class PauseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var count: Int { lock.withLock { calls } }
  func next() -> Int { lock.withLock { calls += 1; return calls } }
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
    XCTAssertNotNil(NSImage(named: "MessagesTool"))
  }
}

/// Records what `MessagesTools` asks, and answers from fixed lists.
actor RecordingMessagesGate: MessagesAccessGate {
  private let allowsReads: Bool
  private let allowsSearch: Bool
  private let allowedChats: Set<String>
  private(set) var reads: [(chatGUID: String, name: String)] = []
  private(set) var searches: [String] = []
  private(set) var previewChecks: [String] = []
  private(set) var messageTextMarks = 0

  init(allowsReads: Bool = true, allowsSearch: Bool = true, allowedChats: Set<String> = []) {
    self.allowsReads = allowsReads
    self.allowsSearch = allowsSearch
    self.allowedChats = allowedChats
  }

  func mayRead(chatGUID: String, name: String) async -> Bool {
    reads.append((chatGUID, name))
    return allowsReads
  }

  func maySearch(query: String) async -> Bool {
    searches.append(query)
    return allowsSearch
  }

  func isAllowed(chatGUID: String) async -> Bool {
    previewChecks.append(chatGUID)
    return allowedChats.contains(chatGUID)
  }

  func didReturnMessageText() async { messageTextMarks += 1 }
}

// MARK: Gated tools (F32)

extension MessagesToolsTests {
  private func gated(_ gate: RecordingMessagesGate) -> MessagesTools {
    var tools = tools()
    tools.gate = gate
    return tools
  }

  private func read(_ chatID: String, with tools: MessagesTools) async -> AgentToolResult {
    await tools.execute(name: "get_messages", arguments: .object(["chat_id": .string(chatID)]))
  }

  func testUngatedToolsAreUnchanged() async throws {
    XCTAssertNil(tools().gate)
    let list = try json(await tools().execute(name: "list_conversations", arguments: .object([:])))
    XCTAssertEqual(list["conversations"].array?.first?["last_message"]["text"].string, "Bringing snacks 🍿")
  }

  func testReadAsksWithChatName() async throws {
    let gate = RecordingMessagesGate()
    let output = try json(await read(MessagesFixture.groupChat, with: gated(gate)))
    XCTAssertEqual(output["messages"].array?.first?["text"].string, "Who's bringing the tent?")
    let reads = await gate.reads
    XCTAssertEqual(reads.map(\.chatGUID), [MessagesFixture.groupChat])
    XCTAssertEqual(reads.map(\.name), ["Weekend Trip"])
    let direct = RecordingMessagesGate()
    _ = try json(await read(MessagesFixture.aliceChat, with: gated(direct)))
    let directNames = await direct.reads.map(\.name)
    XCTAssertEqual(directNames, ["Alice Smith"], "A direct chat is named as summary(of:) names it")
  }

  func testDeclinedReadReturnsNoText() async {
    let gate = RecordingMessagesGate(allowsReads: false)
    let result = await read(MessagesFixture.aliceChat, with: gated(gate))
    XCTAssertFalse(result.success)
    XCTAssertFalse(result.terminal, "The model carries on without the data")
    XCTAssertEqual(result.text, "The user declined.")
    let marks = await gate.messageTextMarks
    XCTAssertEqual(marks, 0)
  }

  func testUnknownChatIDFailsWithoutAsking() async {
    let gate = RecordingMessagesGate()
    let result = await read("iMessage;-;+19999999999", with: gated(gate))
    XCTAssertFalse(result.success)
    XCTAssertEqual(result.text, MessagesError.chatNotFound.localizedDescription)
    let reads = await gate.reads
    XCTAssertTrue(reads.isEmpty)
  }

  func testSearchAsksWithQuery() async throws {
    let gate = RecordingMessagesGate()
    let output = try json(await gated(gate).execute(name: "search_messages", arguments: .object(["query": .string("café")])))
    XCTAssertEqual(output["results"].array?.count, 1)
    let searches = await gate.searches
    XCTAssertEqual(searches, ["café"])
  }

  func testDeclinedSearchReturnsNoText() async {
    let gate = RecordingMessagesGate(allowsSearch: false)
    let result = await gated(gate).execute(name: "search_messages", arguments: .object(["query": .string("café")]))
    XCTAssertFalse(result.success)
    XCTAssertEqual(result.text, "The user declined.")
    XCTAssertFalse(result.text.contains("Luna"))
    let marks = await gate.messageTextMarks
    XCTAssertEqual(marks, 0)
  }

  func testListHidesPreviewsOfChatsNotAllowed() async throws {
    let gate = RecordingMessagesGate(allowedChats: [MessagesFixture.aliceChat])
    let result = await gated(gate).execute(name: "list_conversations", arguments: .object([:]))
    let output = try json(result)
    let conversations = try XCTUnwrap(output["conversations"].array)
    let byID = Dictionary(uniqueKeysWithValues: conversations.compactMap { c in c["chat_id"].string.map { ($0, c) } })
    let group = try XCTUnwrap(byID[MessagesFixture.groupChat])
    XCTAssertEqual(group["name"].string, "Weekend Trip", "Names stay free")
    XCTAssertEqual(group["last_message"]["text"], .null)
    XCTAssertEqual(group["last_message"]["reaction"], .null)
    XCTAssertNotEqual(group["last_message"]["date"], .null, "Times stay free")
    let carol = try XCTUnwrap(byID[MessagesFixture.carolChat])
    XCTAssertEqual(carol["last_message"]["text"], .null)
    let alice = try XCTUnwrap(byID[MessagesFixture.aliceChat])
    XCTAssertEqual(alice["last_message"]["text"].string, "Yes! 7pm at Café Luna")
    let checked = await gate.previewChecks
    XCTAssertEqual(Set(checked), [MessagesFixture.aliceChat, MessagesFixture.groupChat, MessagesFixture.carolChat])
    for hidden in ["snacks", "Package delivered"] {
      XCTAssertFalse(result.text.contains(hidden), "No hidden preview leaks anywhere in the result")
    }
  }

  func testPreviewAndSearchHitsMarkMessageText() async throws {
    let shown = RecordingMessagesGate(allowedChats: [MessagesFixture.aliceChat])
    _ = try json(await gated(shown).execute(name: "list_conversations", arguments: .object([:])))
    let shownMarks = await shown.messageTextMarks
    XCTAssertEqual(shownMarks, 1, "A shown preview is message text")

    let hidden = RecordingMessagesGate()
    _ = try json(await gated(hidden).execute(name: "list_conversations", arguments: .object([:])))
    let hiddenMarks = await hidden.messageTextMarks
    XCTAssertEqual(hiddenMarks, 0, "A list with no previews")

    let hit = RecordingMessagesGate()
    _ = try json(await gated(hit).execute(name: "search_messages", arguments: .object(["query": .string("tent")])))
    let hitMarks = await hit.messageTextMarks
    XCTAssertEqual(hitMarks, 1)

    let miss = RecordingMessagesGate()
    let none = try json(await gated(miss).execute(name: "search_messages", arguments: .object(["query": .string("zebra")])))
    XCTAssertEqual(none["results"].array?.count, 0)
    let missMarks = await miss.messageTextMarks
    XCTAssertEqual(missMarks, 0, "A search with no hits")

    let read = RecordingMessagesGate()
    _ = try json(await self.read(MessagesFixture.aliceChat, with: gated(read)))
    let readMarks = await read.messageTextMarks
    XCTAssertEqual(readMarks, 1)
  }
}
