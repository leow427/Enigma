import AppKit
import SwiftUI

// What the copy buttons put on the pasteboard. A code block copies as plain
// text, keeping only the typed commands of a terminal session. A whole reply
// copies as plain text, as shown and without Markdown marks, plus RTF built
// from the parsed blocks. The RTF carries fonts, paragraph breaks, list
// markers and links but no palette colours: Ink's light text would paste
// invisibly onto a white page.

enum ChatCopy {
  /// Code block languages whose lines may be a terminal session.
  static let terminalLanguages: Set<String> = ["bash", "sh", "zsh", "shell", "console"]

  // MARK: Code

  /// What Copy writes for a code block. A terminal block with prompt lines
  /// (`$ ` or `% `) keeps only those commands, without the prompt, plus the
  /// lines their trailing `\` continues; everything else is output and is
  /// dropped. Without a prompt line, or in another language, the block is
  /// copied as shown. `# ` is never a prompt: it is also a comment.
  static func copyableCode(_ code: String, language: String?) -> String {
    guard let language, terminalLanguages.contains(language.lowercased()) else { return code }
    var kept: [String] = []
    var continues = false
    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
      if continues {
        kept.append(String(line))
        continues = Self.continuesOnNextLine(line)
      } else if line.hasPrefix("$ ") || line.hasPrefix("% ") {
        let command = line.dropFirst(2)
        guard !command.allSatisfy(\.isWhitespace) else { continue }
        kept.append(String(command))
        continues = Self.continuesOnNextLine(command)
      }
    }
    // No prompt line, or only empty ones, leaves nothing worth replacing the clipboard with.
    return kept.isEmpty ? code : kept.joined(separator: "\n")
  }

  /// A line ending in an unescaped backslash: an even run of them is escaped
  /// backslashes, not a continuation.
  private static func continuesOnNextLine(_ line: Substring) -> Bool {
    line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
  }

  // MARK: Replies

  /// One piece of a reply, as copied.
  enum Piece: Equatable {
    case paragraph(AttributedString, quoted: Bool)
    case heading(AttributedString, level: Int)
    /// `continuation` is a later block of an item an earlier piece began.
    case listItem(AttributedString, marker: String, depth: Int, continuation: Bool)
    /// `depth` is the list nesting of a block inside a list item, else 0, and
    /// `markerWidth` the item's marker, which the block hangs under. `marker`
    /// is the item's marker when the code is what starts the item.
    case code(String, depth: Int, markerWidth: Int, marker: String?)
    /// The header row first, each row padded to the table's columns.
    case table([[AttributedString]])

    var isListItem: Bool {
      if case .listItem = self { return true }
      return false
    }
  }

  static func pieces(_ blocks: [ChatMarkdownBlock]) -> [Piece] {
    var pieces: [Piece] = []
    // The list items already begun: a later block of the same item continues it.
    var started: Set<Int> = []
    for group in ChatMarkdown.groups(blocks) {
      if ChatMarkdownStyle.isTable(group) {
        pieces.append(.table(tableRows(group)))
        continue
      }
      for block in group {
        if ChatMarkdownStyle.isThematicBreak(block) { continue }
        let item = ChatMarkdownStyle.listItem(block)?.identity
        let continuation = item.map { started.contains($0) } ?? false
        if let item { started.insert(item) }
        if ChatMarkdownStyle.isCode(block) {
          let marker = ChatMarkdownStyle.listMarker(block)
          pieces.append(.code(ChatMarkdownStyle.displayedCode(block), depth: item == nil ? 0 : ChatMarkdownStyle.listDepth(block),
                              markerWidth: marker?.count ?? 0, marker: continuation ? nil : marker))
        } else if let marker = ChatMarkdownStyle.listMarker(block) {
          pieces.append(.listItem(block.text, marker: marker, depth: ChatMarkdownStyle.listDepth(block),
                                  continuation: continuation))
        } else if let level = ChatMarkdownStyle.headingLevel(block) {
          pieces.append(.heading(block.text, level: level))
        } else {
          pieces.append(.paragraph(block.text, quoted: block.components.contains { $0.kind == .blockQuote }))
        }
      }
    }
    return pieces
  }

  /// A table group's rows with every cell in its column. The parser emits no
  /// text for an empty cell, so cells are placed by their column index.
  private static func tableRows(_ group: [ChatMarkdownBlock]) -> [[AttributedString]] {
    var columnCount = 0
    for component in group.first?.components ?? [] {
      if case .table(let columns) = component.kind { columnCount = columns.count }
    }
    return ChatMarkdown.rows(group).map { row in
      var cells = Array(repeating: AttributedString(), count: columnCount)
      var extra: [AttributedString] = []
      for cell in row {
        let column = cell.components.lazy.compactMap { component -> Int? in
          if case .tableCell(let column) = component.kind { return column }
          return nil
        }.first
        if let column, cells.indices.contains(column) { cells[column] = cell.text } else { extra.append(cell.text) }
      }
      return cells + extra
    }
  }

  /// The reply as shown, without Markdown marks: paragraphs apart by an empty
  /// line, list items on consecutive lines with their markers, code as it is
  /// drawn, and table rows as tab-separated lines.
  static func plainText(_ blocks: [ChatMarkdownBlock]) -> String {
    let pieces = pieces(blocks)
    var text = ""
    for (index, piece) in pieces.enumerated() {
      if index > 0 { text += piece.isListItem && pieces[index - 1].isListItem ? "\n" : "\n\n" }
      switch piece {
      case .paragraph(let content, _), .heading(let content, _):
        text += trimmed(String(content.characters))
      case .listItem(let content, let marker, let depth, let continuation):
        let indent = String(repeating: "  ", count: max(0, depth - 1))
        text += indent + (continuation ? String(repeating: " ", count: marker.count + 1) : marker + " ")
          + trimmed(String(content.characters))
      case .code(let code, let depth, let markerWidth, let marker):
        // Code inside a list item hangs under the item's text, after the marker if it starts the item.
        let indent = depth == 0 ? "" : String(repeating: "  ", count: depth - 1)
        let hanging = indent + (depth == 0 ? "" : String(repeating: " ", count: markerWidth + 1))
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        text += lines.enumerated().map { offset, line in
          if offset == 0, let marker { return indent + marker + " " + line }
          return line.isEmpty ? "" : hanging + line
        }.joined(separator: "\n")
      case .table(let rows):
        text += rows.map { $0.map { String($0.characters) }.joined(separator: "\t") }.joined(separator: "\n")
      }
    }
    return text
  }

  private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .newlines) }

  // MARK: Rich text

  private static let bodySize: CGFloat = 13
  private static let codeSize: CGFloat = 12
  private static let listIndent: CGFloat = 22
  private static let blockGap: CGFloat = 8
  private static let itemGap: CGFloat = 2

  /// The reply as attributed text for RTF: the system font, bold and italic
  /// where the Markdown had them, monospace code, headings, list markers with
  /// hanging indents, indented quotes, tab-separated tables and links. Colours
  /// are left to the page it is pasted into.
  static func richText(_ blocks: [ChatMarkdownBlock]) -> NSAttributedString {
    let pieces = pieces(blocks)
    let result = NSMutableAttributedString()
    for (index, piece) in pieces.enumerated() {
      let next = index + 1 < pieces.count ? pieces[index + 1] : nil
      let gap = next == nil ? 0 : piece.isListItem && next?.isListItem == true ? itemGap : blockGap
      let content = NSMutableAttributedString()
      let style = NSMutableParagraphStyle()
      var markerStyle: NSParagraphStyle?
      switch piece {
      case .paragraph(let text, let quoted):
        content.append(attributed(text, size: bodySize))
        if quoted { style.firstLineHeadIndent = listIndent; style.headIndent = listIndent }
      case .heading(let text, let level):
        content.append(attributed(text, size: level == 1 ? 18 : level == 2 ? 16 : 14, bold: true))
      case .listItem(let text, let marker, let depth, let continuation):
        let indent = listIndent * CGFloat(max(0, depth - 1))
        style.firstLineHeadIndent = continuation ? indent + listIndent : indent
        style.headIndent = indent + listIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + listIndent)]
        if !continuation { content.append(NSAttributedString(string: marker + "\t", attributes: [.font: font(size: bodySize)])) }
        content.append(attributed(text, size: bodySize))
      case .code(let code, let depth, _, let marker):
        if depth > 0 {
          style.firstLineHeadIndent = listIndent * CGFloat(depth)
          style.headIndent = listIndent * CGFloat(depth)
        }
        if let marker { content.append(NSAttributedString(string: marker + "\t", attributes: [.font: font(size: bodySize)])) }
        content.append(NSAttributedString(string: code, attributes: [.font: monospaced(size: codeSize)]))
        if marker != nil, let first = style.mutableCopy() as? NSMutableParagraphStyle {
          // Only the first line carries the marker, hanging out to the item's text.
          first.firstLineHeadIndent = listIndent * CGFloat(depth - 1)
          first.tabStops = [NSTextTab(textAlignment: .left, location: listIndent * CGFloat(depth))]
          markerStyle = first
        }
      case .table(let rows):
        style.tabStops = (1...8).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 120) }
        for (row, cells) in rows.enumerated() {
          if row > 0 { content.append(NSAttributedString(string: "\n")) }
          for (column, cell) in cells.enumerated() {
            if column > 0 { content.append(NSAttributedString(string: "\t", attributes: [.font: font(size: bodySize)])) }
            content.append(attributed(cell, size: bodySize, bold: row == 0))
          }
        }
      }
      while content.string.hasSuffix("\n") { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }
      // Space follows the piece's last paragraph, not each line of a code block.
      let whole = NSRange(location: 0, length: content.length)
      content.addAttribute(.paragraphStyle, value: style, range: whole)
      let string = content.string as NSString
      if let markerStyle {
        let firstEnd = string.range(of: "\n")
        content.addAttribute(.paragraphStyle, value: markerStyle,
                             range: NSRange(location: 0, length: firstEnd.location == NSNotFound ? content.length : firstEnd.location))
      }
      let newline = string.range(of: "\n", options: .backwards)
      let lastStart = newline.location == NSNotFound ? 0 : newline.upperBound
      let lastLine = NSRange(location: lastStart, length: content.length - lastStart)
      if lastLine.length > 0,
         let current = content.attribute(.paragraphStyle, at: lastStart, effectiveRange: nil) as? NSParagraphStyle,
         let spaced = current.mutableCopy() as? NSMutableParagraphStyle {
        spaced.paragraphSpacing = gap
        content.addAttribute(.paragraphStyle, value: spaced, range: lastLine)
      }
      result.append(content)
      if next != nil { result.append(NSAttributedString(string: "\n")) }
    }
    return result
  }

  /// `richText` as RTF data, or nil if AppKit can't write it.
  static func rtf(_ text: NSAttributedString) -> Data? {
    try? text.data(from: NSRange(location: 0, length: text.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  }

  private static func attributed(_ text: AttributedString, size: CGFloat, bold: Bool = false) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      var attributes: [NSAttributedString.Key: Any] = [
        .font: intent.contains(.code)
          ? monospaced(size: codeSize, bold: bold || intent.contains(.stronglyEmphasized))
          : font(size: size, bold: bold || intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized)),
      ]
      if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if let link = run.link { attributes[.link] = link }
      result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return result
  }

  private static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    guard !traits.isEmpty else { return base }
    return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
  }

  /// Menlo, which every Mac has and other RTF readers can name; the system's
  /// monospaced font is a private `.AppleSystemUIFontMonospaced` they can't.
  private static func monospaced(size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
      ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
  }

  // MARK: Pasteboard

  /// Replaces the pasteboard's contents with `plain`, and with `rich` as RTF
  /// when there is some.
  static func write(plain: String, rich: NSAttributedString? = nil, to board: NSPasteboard) {
    board.clearContents()
    board.setString(plain, forType: .string)
    if let rich, let data = rtf(rich) { board.setData(data, forType: .rtf) }
  }
}

/// What a copy button writes, made when it is pressed.
struct ChatCopyPayload {
  var plain: String
  var rich: NSAttributedString?

  /// A reply's Markdown as plain and rich text, parsed as it is shown.
  static func reply(_ content: String) -> ChatCopyPayload {
    let blocks = ChatMarkdown.blocks(content)
    return ChatCopyPayload(plain: ChatCopy.plainText(blocks), rich: ChatCopy.richText(blocks))
  }
}

extension EnvironmentValues {
  /// Where the copy buttons write. Hosted tests give them their own, so they
  /// never touch the person's clipboard.
  @Entry var enigmaPasteboard: NSPasteboard = .general
}

/// A small icon button that copies, then shows a check mark for a moment.
/// Unless `isEmphasized`, it rests dimmed rather than hidden (a reply's copy
/// button brightens when the pointer is over the reply): a view at zero
/// opacity can't be clicked and drops out of the accessibility tree, and
/// VoiceOver and Tab never fire hover. It is full strength while it has
/// keyboard focus or shows its check mark.
struct ChatCopyButton: View {
  /// "Copy code" or "Copy reply", its accessibility label and tooltip.
  let label: String
  var isEmphasized = true
  var size = CGSize(width: 26, height: 22)
  let payload: () -> ChatCopyPayload
  @Environment(\.enigmaPasteboard) private var pasteboard
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var copied = false
  @State private var reset: Task<Void, Never>?

  /// How long the check mark stays.
  static let confirmationDuration = Duration.seconds(1.5)
  /// How dim a button rests at while the pointer is elsewhere.
  static let restingOpacity = 0.7

  /// The button's opacity: full strength when emphasized, focused or showing
  /// its check mark, else resting. Never zero, which would remove it from
  /// clicks and from the accessibility tree.
  static func opacity(isEmphasized: Bool, isFocused: Bool, copied: Bool) -> Double {
    isEmphasized || isFocused || copied ? 1 : restingOpacity
  }

  var body: some View {
    Button(action: copy) {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .font(EnigmaTypography.symbol(11.5))
    }
    .buttonStyle(EnigmaIconButtonStyle(isActive: copied, size: size, isFocused: isFocused))
    .focused($isFocused)
    .focusEffectDisabled()
    .opacity(Self.opacity(isEmphasized: isEmphasized, isFocused: isFocused, copied: copied))
    .animation(reduceMotion ? nil : EnigmaMotion.menu.animation, value: isEmphasized)
    .help(copied ? "Copied" : label)
    .accessibilityLabel(copied ? "Copied" : label)
    .enigmaTestMarker(copied ? "Copied" : label)
    .onDisappear {
      reset?.cancel()
      copied = false
    }
  }

  private func copy() {
    let payload = payload()
    // Nothing to copy (a reply that draws only a rule) must not clear the clipboard.
    guard !payload.plain.isEmpty else { return }
    ChatCopy.write(plain: payload.plain, rich: payload.rich, to: pasteboard)
    copied = true
    reset?.cancel()
    reset = Task {
      try? await Task.sleep(for: Self.confirmationDuration)
      if !Task.isCancelled { copied = false }
    }
  }
}
