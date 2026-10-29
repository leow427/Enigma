import Foundation
import SQLite3

enum MessagesError: LocalizedError, Equatable {
  case fullDiskAccessRequired
  case databaseMissing
  case databaseUnreadable(String)
  case automationDenied
  case sendFailed(String)
  case chatNotFound
  case recipientNotFound(String)
  case ambiguousRecipient(String, candidates: [String])
  case sendDeclined
  case duplicateSend
  case invalidArguments(String)

  var errorDescription: String? {
    switch self {
    case .fullDiskAccessRequired:
      "Enigma needs Full Disk Access to read Messages. Open System Settings → Privacy & Security → Full Disk Access, turn on Enigma, then quit and reopen Enigma."
    case .databaseMissing:
      "Messages has no history on this Mac. Open Messages and sign in with your Apple Account, then try again."
    case .databaseUnreadable(let detail):
      "Enigma could not read the Messages database: \(detail)"
    case .automationDenied:
      "Enigma isn't allowed to control Messages. Open System Settings → Privacy & Security → Automation, expand Enigma, and turn on Messages."
    case .sendFailed(let detail):
      "Messages could not send this message: \(detail)"
    case .chatNotFound:
      "No conversation matches that chat_id. Use an id returned by list_conversations or search_messages."
    case .recipientNotFound(let recipient):
      "No contact, handle, or conversation matches \"\(recipient)\". Use search_contacts or list_conversations, or give a full phone number or email address."
    case .ambiguousRecipient(let recipient, let candidates):
      "\"\(recipient)\" matches more than one recipient: \(candidates.joined(separator: "; ")). Ask the user which one, then use that handle or chat_id."
    case .sendDeclined:
      "The user declined this message, so it was not sent. Do not retry unless the user asks again."
    case .duplicateSend:
      "This exact message was already sent in this request and was not sent again."
    case .invalidArguments(let detail):
      "Invalid arguments: \(detail)"
    }
  }

  /// Errors the user resolves in System Settings rather than by rephrasing.
  var privacyPane: MessagesPrivacyPane? {
    switch self {
    case .fullDiskAccessRequired: .fullDiskAccess
    case .automationDenied: .automation
    default: nil
    }
  }
}

enum MessagesPrivacyPane: String, Sendable {
  case fullDiskAccess = "Privacy_AllFiles"
  case automation = "Privacy_Automation"
  case contacts = "Privacy_Contacts"

  var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }

  /// The button that opens this pane.
  var settingsButtonTitle: String {
    switch self {
    case .fullDiskAccess: "Open Full Disk Access Settings…"
    case .automation: "Open Automation Settings…"
    case .contacts: "Open Contacts Settings…"
    }
  }
}

/// One row of `chat`, with its participants' raw handles.
struct MessagesChatRecord: Sendable, Equatable {
  let rowID: Int64
  let guid: String
  let identifier: String
  let displayName: String?
  let service: String?
  let isGroup: Bool
  var handles: [String]
  var lastActivity: Date? = nil
}

struct MessagesMessageRecord: Sendable, Equatable {
  let rowID: Int64
  let chatGUID: String
  let date: Date?
  let isFromMe: Bool
  /// The sender's handle for incoming messages; nil for messages from this Mac's owner.
  let handle: String?
  let text: String?
  let hasAttachments: Bool
  /// Tapbacks are stored as messages that point at another message.
  let reaction: String?
}

struct MessagesConversationRecord: Sendable, Equatable {
  let chat: MessagesChatRecord
  let lastMessage: MessagesMessageRecord
}

struct MessagesSearchHit: Sendable, Equatable {
  let match: MessagesMessageRecord
  let before: [MessagesMessageRecord]
  let after: [MessagesMessageRecord]
}

struct MessagesSearchResult: Sendable, Equatable {
  let hits: [MessagesSearchHit]
  /// False when the scan limit was reached before the whole history was searched.
  let searchedAll: Bool
}

/// Reads `chat.db` through short-lived read-only connections. Every connection is opened
/// with a `mode=ro` URI, `SQLITE_OPEN_READONLY`, and `query_only`, so Enigma cannot
/// write to Messages' database even through a bug in a query.
struct MessagesDatabase: Sendable {
  /// The unsigned test host shares Enigma's bundle ID, so its opening the real database
  /// makes macOS replace the user's Full Disk Access grant with a denial. It gets a missing file.
  static let defaultURL = TestHost.isActive
    ? FileManager.default.temporaryDirectory.appending(path: "EnigmaTests-no-messages/chat.db")
    : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
  static let searchScanLimit = 100_000

  let url: URL

  init(url: URL = Self.defaultURL) { self.url = url }

  /// Distinguishes a missing database from one macOS privacy controls hide from Enigma.
  func checkAccess() throws {
    let descriptor = open(url.path, O_RDONLY)
    if descriptor >= 0 { close(descriptor); return }
    switch errno {
    case EPERM, EACCES: throw MessagesError.fullDiskAccessRequired
    case ENOENT: throw MessagesError.databaseMissing
    default: throw MessagesError.databaseUnreadable(String(cString: strerror(errno)))
    }
  }

  // MARK: Queries

  func conversations(limit: Int, oldestFirst: Bool = false) throws -> [MessagesConversationRecord] {
    try withConnection { db in
      let order = oldestFirst ? "ASC" : "DESC"
      let rows = try db.query("""
        SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
               \(Self.messageColumns)
        FROM chat c
        JOIN message m ON m.ROWID = (
          SELECT j.message_id FROM chat_message_join j JOIN message x ON x.ROWID = j.message_id
          WHERE j.chat_id = c.ROWID AND x.associated_message_type = 0 AND x.item_type = 0
          ORDER BY x.date DESC, x.ROWID DESC LIMIT 1)
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        ORDER BY m.date \(order), c.ROWID \(order)
        LIMIT ?1
        """, [.integer(Int64(limit))]) { row in
        // Rows are valid only inside this callback, so map both records here.
        let chat = Self.chat(row, from: 0)
        return (chat, Self.message(row, from: 6, chatGUID: chat.guid))
      }
      var chats = rows.map(\.0)
      try db.attachHandles(to: &chats)
      return zip(chats, rows).map { MessagesConversationRecord(chat: $0, lastMessage: $1.1) }
    }
  }

  func chat(guid: String) throws -> MessagesChatRecord? {
    try withConnection { db in try db.chat(guid: guid) }
  }

  /// Every chat with its latest activity, for resolving a recipient to an existing conversation.
  func chats() throws -> [MessagesChatRecord] {
    try withConnection { db in
      var chats = try db.query("""
        SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style,
               (SELECT MAX(x.date) FROM chat_message_join j JOIN message x ON x.ROWID = j.message_id WHERE j.chat_id = c.ROWID)
        FROM chat c
        """, []) { row in
        var chat = Self.chat(row, from: 0)
        chat.lastActivity = AppleMessageDate.date(row.integer(6))
        return chat
      }
      try db.attachHandles(to: &chats)
      return chats
    }
  }

  /// The newest page before `beforeMessageID`, returned oldest-first.
  func messages(chatGUID: String, limit: Int, beforeMessageID: Int64? = nil) throws -> [MessagesMessageRecord] {
    try withConnection { db in
      guard try db.chat(guid: chatGUID) != nil else { throw MessagesError.chatNotFound }
      return try db.query("""
        SELECT \(Self.messageColumns)
        FROM chat c
        JOIN chat_message_join j ON j.chat_id = c.ROWID
        JOIN message m ON m.ROWID = j.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE c.guid = ?1 AND m.item_type = 0
          AND (m.associated_message_type = 0 OR m.associated_message_type BETWEEN 2000 AND 2999)
          AND (?2 IS NULL OR (m.date, m.ROWID) < (SELECT date, ROWID FROM message WHERE ROWID = ?2))
        ORDER BY m.date DESC, m.ROWID DESC
        LIMIT ?3
        """, [.text(chatGUID), beforeMessageID.map(SQLiteValue.integer) ?? .null, .integer(Int64(limit))]) {
        Self.message($0, from: 0, chatGUID: chatGUID)
      }.reversed()
    }
  }

  /// Matches are found newest-first in Swift, because many bodies exist only in
  /// `attributedBody` and SQL `LIKE` is not Unicode-aware.
  func search(_ query: String, limit: Int, context: Int = 2,
              scanLimit: Int = Self.searchScanLimit) throws -> MessagesSearchResult {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { throw MessagesError.invalidArguments("query must not be empty.") }
    return try withConnection { db in
      var matches: [MessagesMessageRecord] = []
      var scanned = 0
      try db.each("""
        SELECT \(Self.messageColumns), c.guid
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.associated_message_type = 0 AND m.item_type = 0
          AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
        ORDER BY m.date DESC, m.ROWID DESC
        LIMIT ?1
        """, [.integer(Int64(scanLimit))]) { row in
        scanned += 1
        let record = Self.message(row, from: 0, chatGUID: row.text(Self.messageColumnCount) ?? "")
        if record.text?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
          matches.append(record)
        }
        return matches.count < limit
      }
      let hits = try matches.map { match in
        MessagesSearchHit(match: match,
          before: try db.neighbors(of: match, count: context, after: false),
          after: try db.neighbors(of: match, count: context, after: true))
      }
      return MessagesSearchResult(hits: hits, searchedAll: matches.count >= limit || scanned < scanLimit)
    }
  }

  /// Every distinct handle Messages has seen, for recipient and contact lookups.
  func handles() throws -> [String] {
    try withConnection { db in
      try db.query("SELECT DISTINCT id FROM handle WHERE id IS NOT NULL ORDER BY id", []) { $0.text(0) ?? "" }
        .filter { !$0.isEmpty }
    }
  }

  /// The newest message row, read before a send so the check only looks at rows added after it.
  func latestMessageID() throws -> Int64 {
    try withConnection { db in
      try db.query("SELECT IFNULL(MAX(ROWID), 0) FROM message", []) { $0.integer(0) }.first ?? 0
    }
  }

  /// Messages from this Mac's owner in a chat added after `messageID`, used to confirm a send.
  /// `isSent` is false while one is still being sent; Messages marks a failure with a non-zero `error`.
  func outgoing(chatGUID: String, after messageID: Int64) throws
    -> [(message: MessagesMessageRecord, isSent: Bool, isFailed: Bool)] {
    try withConnection { db in
      try db.query("""
        SELECT \(Self.messageColumns), m.is_sent, m.error
        FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE c.guid = ?1 AND j.message_id > ?2 AND m.is_from_me = 1 AND m.associated_message_type = 0
        ORDER BY m.ROWID LIMIT 50
        """, [.text(chatGUID), .integer(messageID)]) {
        (Self.message($0, from: 0, chatGUID: chatGUID), $0.integer(Self.messageColumnCount) != 0,
         $0.integer(Self.messageColumnCount + 1) != 0)
      }
    }
  }

  /// One-to-one chats with `handle`, in any format of it, such as the one Messages creates
  /// when sending to a new handle.
  func directChatGUIDs(handle: String) throws -> [String] {
    let key = MessagesHandle.key(handle)
    return try withConnection { db in
      var guids: [String] = []
      try db.each("""
        SELECT c.guid, c.chat_identifier, h.id FROM chat c
        LEFT JOIN chat_handle_join j ON j.chat_id = c.ROWID LEFT JOIN handle h ON h.ROWID = j.handle_id
        WHERE c.style IS NOT 43
        """, []) { row in
        if let guid = row.text(0), !guids.contains(guid),
           [row.text(1), row.text(2)].contains(where: { $0.map(MessagesHandle.key) == key }) { guids.append(guid) }
        return true
      }
      return guids
    }
  }

  // MARK: Row mapping

  fileprivate static let messageColumns = """
    m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date, h.id, m.cache_has_attachments, m.associated_message_type
    """
  fileprivate static let messageColumnCount = 8

  fileprivate static func chat(_ row: SQLiteRow, from start: Int) -> MessagesChatRecord {
    MessagesChatRecord(rowID: row.integer(start), guid: row.text(start + 1) ?? "",
      identifier: row.text(start + 2) ?? "",
      displayName: row.text(start + 3).flatMap { $0.isEmpty ? nil : $0 },
      service: row.text(start + 4), isGroup: row.integer(start + 5) == 43, handles: [])
  }

  fileprivate static func message(_ row: SQLiteRow, from start: Int, chatGUID: String) -> MessagesMessageRecord {
    let isFromMe = row.integer(start + 3) != 0
    let reactionType = row.integer(start + 7)
    let body = row.text(start + 1).flatMap { $0.isEmpty ? nil : $0 }
      ?? row.blob(start + 2).flatMap(AttributedBodyDecoder.text(from:))
    // U+FFFC marks where an attachment sits in the text.
    let text = body.map { $0.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    return MessagesMessageRecord(rowID: row.integer(start), chatGUID: chatGUID,
      date: AppleMessageDate.date(row.integer(start + 4)), isFromMe: isFromMe,
      handle: isFromMe ? nil : row.text(start + 5), text: text.flatMap { $0.isEmpty ? nil : $0 },
      hasAttachments: row.integer(start + 6) != 0, reaction: reaction(reactionType, text: text))
  }

  private static func reaction(_ type: Int64, text: String?) -> String? {
    switch type {
    case 2000: "loved a message"
    case 2001: "liked a message"
    case 2002: "disliked a message"
    case 2003: "laughed at a message"
    case 2004: "emphasized a message"
    case 2005: "questioned a message"
    case 2006...2999: "reacted to a message"
    default: nil
    }
  }

  private func withConnection<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
    try checkAccess()
    let connection = try SQLiteConnection(readOnly: url)
    defer { connection.close() }
    return try body(connection)
  }
}

// MARK: - SQLite

enum SQLiteValue {
  case integer(Int64)
  case text(String)
  case null
}

/// A view of the current row. It must not outlive the `each` callback that received it.
struct SQLiteRow {
  fileprivate let statement: OpaquePointer

  func integer(_ column: Int) -> Int64 { sqlite3_column_int64(statement, Int32(column)) }

  func text(_ column: Int) -> String? {
    guard sqlite3_column_type(statement, Int32(column)) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, Int32(column)) else { return nil }
    return String(cString: pointer)
  }

  func blob(_ column: Int) -> Data? {
    guard sqlite3_column_type(statement, Int32(column)) == SQLITE_BLOB,
          let pointer = sqlite3_column_blob(statement, Int32(column)) else { return nil }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, Int32(column))))
  }
}

final class SQLiteConnection {
  private var handle: OpaquePointer?

  init(readOnly url: URL) throws {
    var components = URLComponents()
    components.scheme = "file"
    components.path = url.path
    components.query = "mode=ro"
    guard let uri = components.string else { throw MessagesError.databaseUnreadable("Invalid database path.") }
    let status = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
    guard status == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
      close()
      throw status == SQLITE_AUTH || status == SQLITE_PERM ? MessagesError.fullDiskAccessRequired
        : MessagesError.databaseUnreadable(message)
    }
    sqlite3_busy_timeout(handle, 2_000)
    try execute("PRAGMA query_only = 1")
  }

  deinit { close() }

  func close() {
    if let handle { sqlite3_close_v2(handle) }
    handle = nil
  }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }

  func query<T>(_ sql: String, _ values: [SQLiteValue], map: (SQLiteRow) throws -> T) throws -> [T] {
    var results: [T] = []
    try each(sql, values) { results.append(try map($0)); return true }
    return results
  }

  /// Calls `body` for each row until it returns false.
  func each(_ sql: String, _ values: [SQLiteValue], body: (SQLiteRow) throws -> Bool) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .integer(let number): sqlite3_bind_int64(statement, index, number)
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw error() }
      guard try body(SQLiteRow(statement: statement)) else { return }
    }
  }

  fileprivate func chat(guid: String) throws -> MessagesChatRecord? {
    var chats = try query("""
      SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.service_name, c.style FROM chat c WHERE c.guid = ?1
      """, [.text(guid)]) { MessagesDatabase.chat($0, from: 0) }
    try attachHandles(to: &chats)
    return chats.first
  }

  fileprivate func attachHandles(to chats: inout [MessagesChatRecord]) throws {
    guard !chats.isEmpty else { return }
    var handles: [Int64: [String]] = [:]
    let ids = chats.map { String($0.rowID) }.joined(separator: ",")
    try each("""
      SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id
      WHERE j.chat_id IN (\(ids)) ORDER BY j.chat_id, h.ROWID
      """, []) { row in
      if let handle = row.text(1) { handles[row.integer(0), default: []].append(handle) }
      return true
    }
    for index in chats.indices { chats[index].handles = handles[chats[index].rowID] ?? [] }
  }

  fileprivate func neighbors(of message: MessagesMessageRecord, count: Int, after: Bool) throws -> [MessagesMessageRecord] {
    guard count > 0 else { return [] }
    let comparison = after ? ">" : "<"
    let order = after ? "ASC" : "DESC"
    let rows = try query("""
      SELECT \(MessagesDatabase.messageColumns)
      FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE c.guid = ?1 AND m.associated_message_type = 0 AND m.item_type = 0
        AND (m.date, m.ROWID) \(comparison) (SELECT date, ROWID FROM message WHERE ROWID = ?2)
      ORDER BY m.date \(order), m.ROWID \(order) LIMIT ?3
      """, [.text(message.chatGUID), .integer(message.rowID), .integer(Int64(count))]) {
      MessagesDatabase.message($0, from: 0, chatGUID: message.chatGUID)
    }
    return after ? rows : rows.reversed()
  }

  private func error() -> MessagesError {
    MessagesError.databaseUnreadable(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
  }
}
