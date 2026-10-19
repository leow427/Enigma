import SwiftUI

/// Display-only repair. Stored messages and provider streams remain verbatim.
enum ChatResponseNormalizer {
  /// What a line's repair depends on from the lines before it.
  struct LineState {
    var fence: (character: Character, count: Int)?
    var inlineFence: Int?
    /// No code block or code span carries over from earlier lines.
    var isInitial: Bool { fence == nil && inlineFence == nil }
  }

  // Keep code spans (including an unfinished streamed span), paths and URLs untouched.
  private static let protected = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1|`+[^`]*$|(?:[A-Za-z]:\\|\\\\|\.{1,2}[/\\]|/)[^\s]+|\\\[[^\]\n]+\\?\]\\?\(https?://[^\s)]+\\?\)|https?://[^\s]+"#)

  static func normalize(_ source: String, escapingPathsForParser: Bool = false) -> String {
    var state = LineState()
    return source.components(separatedBy: "\n").map {
      normalize(line: $0, state: &state, escapingPathsForParser: escapingPathsForParser)
    }.joined(separator: "\n")
  }

  /// One line of `normalize(_:escapingPathsForParser:)`, carrying `state` to the next.
  static func normalize(line original: String, state: inout LineState, escapingPathsForParser: Bool = false) -> String {
    if let width = state.inlineFence {
      // Code spans can cross a soft line break; avoid repairing their contents.
      let pattern = "(?<!`)`{" + String(width) + "}(?!`)"
      if original.range(of: pattern, options: .regularExpression) != nil || original.isEmpty { state.inlineFence = nil }
      return original
    }
    let trimmed = original.drop(while: { $0 == " " || $0 == "\t" })
    if let active = state.fence {
      if trimmed.prefix(while: { $0 == active.character }).count >= active.count,
         trimmed.drop(while: { $0 == active.character }).trimmingCharacters(in: .whitespaces).isEmpty { state.fence = nil }
      return original
    }
    if let first = trimmed.first, first == "`" || first == "~" {
      let count = trimmed.prefix(while: { $0 == first }).count
      if count >= 3 { state.fence = (first, count); return original }
    }
    if original.hasPrefix("    ") || original.hasPrefix("\t") { return original }
    let ns = original as NSString
    var result = ""
    var offset = 0
    for match in protected.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
      result += repair(ns.substring(with: NSRange(location: offset, length: match.range.location - offset)), atLineStart: offset == 0)
      let literal = ns.substring(with: match.range)
      if literal.hasPrefix("`") {
        let width = literal.prefix(while: { $0 == "`" }).count
        if literal.count < width * 2 || !literal.hasSuffix(String(repeating: "`", count: width)) { state.inlineFence = width }
      }
      if literal.hasPrefix(#"\["#) {
        result += literal.replacingOccurrences(of: #"\\([\[\]()])"#, with: "$1", options: .regularExpression)
      } else if escapingPathsForParser, !literal.hasPrefix("`"), !literal.hasPrefix("http") {
        // Markdown consumes backslashes before punctuation even in a plain path.
        result += literal.replacingOccurrences(of: #"\"#, with: #"\\"#)
      } else { result += literal }
      offset = NSMaxRange(match.range)
    }
    result += repair(ns.substring(from: offset), atLineStart: offset == 0)
    return result
  }

  private static func repair(_ source: String, atLineStart: Bool) -> String {
    var text = source
    for scalar in ["\u{00a0}", "\u{2007}", "\u{202f}", "\u{2009}"] { text = text.replacingOccurrences(of: scalar, with: " ") }
    for scalar in ["\u{200b}", "\u{feff}"] { text = text.replacingOccurrences(of: scalar, with: "") }
    text = text.replacingOccurrences(of: "\r", with: "")
    func replace(_ pattern: String, _ template: String) {
      text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    if atLineStart {
      if let range = text.range(of: ##"^ {0,3}(?:\\#){1,6}(?=\s+\S)"##, options: .regularExpression) {
        text.replaceSubrange(range, with: text[range].replacingOccurrences(of: #"\"#, with: ""))
      }
      replace(#"^( {0,3})\\(#{1,6})(?=\s+\S)"#, "$1$2")
      replace(#"^( {0,3})\\([-+*>])(?=\s+\S)"#, "$1$2")
      replace(#"^( {0,3}\d{1,9})\\([.)])(?=\s+\S)"#, "$1$2")
    }
    // Paired delimiters are evidence of formatting; unmatched escapes stay literal.
    replace(#"(?<![\\\w])\\\*\\\*(\S(?:.*?\S)?)\\\*\\\*(?!\w)"#, "**$1**")
    replace(#"(?<![\\\w])\\(\*\*|__)(\S(?:.*?\S)?)\\\1(?!\w)"#, "$1$2$1")
    replace(#"(?<![\\\w])\\([*_])(\S(?:.*?\S)?)\\\1(?!\w)"#, "$1$2$1")
    return text
  }
}

struct ChatMarkdownBlock: Identifiable, Equatable {
  let id: Int
  private(set) var text: AttributedString
  let components: [PresentationIntent.IntentType]
  /// Shared by copies of a block until its text changes, so SwiftUI can tell
  /// an unchanged block from a streamed one without comparing every character.
  private var revision = Revision()
  private final class Revision {}
  /// The text's length, so a block that grew compares unequal at once.
  private var characterCount: Int

  init(id: Int, text: AttributedString, components: [PresentationIntent.IntentType]) {
    self.id = id
    self.text = text
    self.components = components
    characterCount = text.characters.count
  }

  mutating func append(_ more: AttributedString) {
    text.append(more)
    characterCount += more.characters.count
    revision = Revision()
  }

  static func == (lhs: ChatMarkdownBlock, rhs: ChatMarkdownBlock) -> Bool {
    if lhs.revision === rhs.revision { return true }
    return lhs.id == rhs.id && lhs.characterCount == rhs.characterCount && lhs.components == rhs.components
      && lhs.text == rhs.text
  }
}

enum ChatMarkdown {
  static func blocks(_ source: String) -> [ChatMarkdownBlock] {
    let normalized = ChatResponseNormalizer.normalize(source, escapingPathsForParser: true)
    return parse(normalized: normalized, identityOffset: 0)?.blocks
      ?? [ChatMarkdownBlock(id: 0, text: AttributedString(normalized), components: [])]
  }

  /// The blocks of already normalized Markdown, with every presentation
  /// identity raised by `identityOffset`, and the highest identity they use.
  /// Nil if the text can't be parsed.
  static func parse(normalized: String, identityOffset: Int) -> (blocks: [ChatMarkdownBlock], maximumIdentity: Int)? {
    guard let parsed = try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .full)) else {
      return nil
    }
    var blocks: [ChatMarkdownBlock] = []
    var maximumIdentity = identityOffset
    for run in parsed.runs {
      var components = run.presentationIntent?.components ?? []
      var text = AttributedString(parsed[run.range])
      if identityOffset != 0, !components.isEmpty {
        for index in components.indices { components[index].identity += identityOffset }
        // The text keeps its intent too, numbered as if parsed with what came before.
        text.presentationIntent = components.reversed().reduce(nil) { parent, component in
          PresentationIntent(component.kind, identity: component.identity, parent: parent)
        }
      }
      maximumIdentity = components.reduce(maximumIdentity) { max($0, $1.identity) }
      let id = components.first?.identity ?? 0
      if run.inlinePresentationIntent?.contains(.code) == true { text.font = .system(size: 13, design: .monospaced) }
      if blocks.last?.id == id { blocks[blocks.count - 1].append(text) }
      else { blocks.append(ChatMarkdownBlock(id: id, text: text, components: components)) }
    }
    return (blocks, maximumIdentity)
  }

  /// `tail` after `head`, joining a block that `blocks(_:)` would have joined.
  static func appending(_ tail: [ChatMarkdownBlock], to head: [ChatMarkdownBlock]) -> [ChatMarkdownBlock] {
    var blocks = head
    for block in tail {
      if blocks.last?.id == block.id { blocks[blocks.count - 1].append(block.text) }
      else { blocks.append(block) }
    }
    return blocks
  }

  /// Blocks grouped for layout: each table's cells together, every other block alone.
  static func groups(_ blocks: [ChatMarkdownBlock]) -> [[ChatMarkdownBlock]] {
    var groups: [[ChatMarkdownBlock]] = []
    for block in blocks {
      let table = block.components.first { if case .table = $0.kind { return true }; return false }
      if let table, groups.last?.last?.components.contains(table) == true { groups[groups.count - 1].append(block) }
      else { groups.append([block]) }
    }
    return groups
  }

  /// A table group's cells split into rows.
  static func rows(_ blocks: [ChatMarkdownBlock]) -> [[ChatMarkdownBlock]] {
    var rows: [[ChatMarkdownBlock]] = []
    for block in blocks {
      let row = block.components.dropFirst().first?.identity
      if let row, rows.last?.last?.components.dropFirst().first?.identity == row { rows[rows.count - 1].append(block) }
      else { rows.append([block]) }
    }
    return rows
  }
}

/// A reply's blocks as it streams, without parsing the whole reply again for
/// every fragment. The text up to the last place a new top-level block must
/// start (an empty line, outside any code, before an unindented line that
/// can't continue a list) is parsed once and kept; only the rest is parsed
/// again. Presentation identities are numbered on from the kept part, so the
/// result is the same as `ChatMarkdown.blocks(_:)` for the whole text.
/// Markdown that can reach across blocks (link reference definitions and the
/// HTML blocks that can span empty lines) falls back to parsing everything.
@MainActor
final class ChatMarkdownStream {
  private var settled = ""
  private var settledBlocks: [ChatMarkdownBlock] = []
  private var settledIdentity = 0
  private var scan = Scan()
  private var parsesWholeText = false
  /// How many characters the last call parsed, for tests.
  private(set) var lastParsedLength = 0

  /// Line state from the end of `settled` up to the start of the first line
  /// not yet read, which is `offset` UTF-8 bytes past `settled`.
  private struct Scan {
    var offset = 0
    var repair = ChatResponseNormalizer.LineState()
    var fence: (character: Character, count: Int)?
    var previousLineIsEmpty = false
    /// The start of the latest line that must begin a new top-level block.
    var boundary: Int?
  }

  func blocks(_ source: String) -> [ChatMarkdownBlock] {
    if !source.utf8.starts(with: settled.utf8) { reset() }
    if !parsesWholeText { read(source) }
    guard !parsesWholeText else {
      lastParsedLength = source.utf8.count
      return ChatMarkdown.blocks(source)
    }
    let tail = Substring(source.utf8.dropFirst(settled.utf8.count))
    if let boundary = scan.boundary {
      let chunk = String(Substring(tail.utf8.prefix(boundary)))
      guard let parsed = parse(chunk) else { return fallBack(source) }
      settledBlocks = ChatMarkdown.appending(parsed.blocks, to: settledBlocks)
      settledIdentity = parsed.maximumIdentity
      settled += chunk
      scan.offset -= boundary
      scan.boundary = nil
      lastParsedLength = chunk.utf8.count
    } else {
      lastParsedLength = 0
    }
    let rest = String(Substring(source.utf8.dropFirst(settled.utf8.count)))
    lastParsedLength += rest.utf8.count
    guard let parsed = parse(rest) else { return fallBack(source) }
    return ChatMarkdown.appending(parsed.blocks, to: settledBlocks)
  }

  private func parse(_ text: String) -> (blocks: [ChatMarkdownBlock], maximumIdentity: Int)? {
    guard !text.isEmpty else { return ([], settledIdentity) }
    return ChatMarkdown.parse(normalized: ChatResponseNormalizer.normalize(text, escapingPathsForParser: true),
                              identityOffset: settledIdentity)
  }

  private func fallBack(_ source: String) -> [ChatMarkdownBlock] {
    parsesWholeText = true
    lastParsedLength = source.utf8.count
    return ChatMarkdown.blocks(source)
  }

  private func reset() {
    settled = ""
    settledBlocks = []
    settledIdentity = 0
    scan = Scan()
    parsesWholeText = false
  }

  /// Reads the complete lines not yet read, noting where blocks must start.
  /// The unfinished last line is only checked for cross-block Markdown.
  private func read(_ source: String) {
    let unread = source.utf8.dropFirst(settled.utf8.count + scan.offset)
    var start = unread.startIndex
    while let newline = unread[start...].firstIndex(of: UInt8(ascii: "\n")) {
      let line = String(Substring(unread[start..<newline]))
      if Self.reachesAcrossBlocks(line) { parsesWholeText = true; return }
      if scan.previousLineIsEmpty, scan.repair.isInitial, scan.fence == nil, Self.startsTopLevelBlock(line) {
        scan.boundary = scan.offset
      }
      _ = ChatResponseNormalizer.normalize(line: line, state: &scan.repair)
      Self.updateFence(&scan.fence, with: line)
      scan.previousLineIsEmpty = line.isEmpty
      scan.offset += line.utf8.count + 1
      start = unread.index(after: newline)
    }
    if Self.reachesAcrossBlocks(String(Substring(unread[start...]))) { parsesWholeText = true }
  }

  /// A line that, after an empty line, starts a top-level block whatever came
  /// before: unindented, and not a list item, which could continue a list.
  private static func startsTopLevelBlock(_ line: String) -> Bool {
    guard let first = line.first, first != " ", first != "\t" else { return false }
    if first == "-" || first == "*" || first == "+" {
      guard let next = line.dropFirst().first else { return false }
      return next != " " && next != "\t"
    }
    let digits = line.prefix(while: \.isASCII).prefix(while: \.isNumber)
    guard !digits.isEmpty else { return true }
    let marker = line.dropFirst(digits.count)
    guard let delimiter = marker.first, delimiter == "." || delimiter == ")" else { return true }
    guard let next = marker.dropFirst().first else { return false }
    return next != " " && next != "\t"
  }

  /// Link reference definitions apply to the whole reply, and these HTML
  /// blocks run on past empty lines.
  private static func reachesAcrossBlocks(_ line: String) -> Bool {
    if line.contains("]:") { return true }
    let start = line.drop(while: { $0 == " " }).lowercased()
    return ["<!", "<?", "<script", "<pre", "<style", "<textarea"].contains { start.hasPrefix($0) }
  }

  /// CommonMark's fenced code blocks: up to three spaces of indent, then three
  /// or more backticks or tildes, closed by at least as many of the same.
  private static func updateFence(_ fence: inout (character: Character, count: Int)?, with line: String) {
    let indent = line.prefix(while: { $0 == " " }).count
    guard indent <= 3 else { return }
    let rest = line.dropFirst(indent)
    guard let first = rest.first, first == "`" || first == "~" else { return }
    let count = rest.prefix(while: { $0 == first }).count
    if let open = fence {
      if first == open.character, count >= open.count,
         rest.dropFirst(count).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
    } else if count >= 3, first == "~" || !rest.dropFirst(count).contains("`") {
      fence = (first, count)
    }
  }
}
