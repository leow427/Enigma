import SwiftUI

// Syntax colours for code blocks. A small tokenizer for the common languages
// reads a block one line at a time, carrying open block comments and
// multi-line strings to the next line, so a streamed block only reads its new
// lines. A terminal session's commands are coloured and its output dimmed.

/// A code block language the highlighter knows, from the fence's hint.
enum CodeLanguage: Equatable, Sendable {
  case swift, python, javascript, shell, json, html, css, sql

  init?(hint: String?) {
    switch hint?.lowercased() {
    case "swift": self = .swift
    case "python", "py": self = .python
    case "javascript", "js", "jsx", "mjs", "typescript", "ts", "tsx": self = .javascript
    case let hint? where ChatCopy.terminalLanguages.contains(hint): self = .shell
    case "json": self = .json
    case "html", "xml", "svg": self = .html
    case "css": self = .css
    case "sql": self = .sql
    default: return nil
    }
  }
}

enum CodeTokenKind: Equatable, Sendable {
  case keyword, string, number, comment, type, variable
  /// Terminal tokens.
  case command, flag, path, output
}

enum CodeHighlighter {
  struct Segment {
    let text: Substring
    /// Nil for plain text.
    let kind: CodeTokenKind?
  }

  /// What a line's colours depend on from the lines before it.
  struct State {
    let language: CodeLanguage
    /// A terminal session: lines that don't start with a prompt are output.
    let hasPrompts: Bool
    /// The closing delimiter of an unfinished block comment or string.
    var open: (close: String, kind: CodeTokenKind)?
    /// The last shell line ended in a `\` continuation.
    var continuesCommand = false
    /// Whether that line's next word would have been a command, as after `&& \`.
    var continuedExpectsCommand = false
    /// The word that ends an unfinished shell here-document.
    var hereDocument: String?
    /// Inside an HTML tag, where quotes and `name=` are attributes.
    var insideTag = false
    /// How many CSS `{` are open: `name:` is a property inside one, a pseudo-class outside.
    var braceDepth = 0

    init(language: CodeLanguage, code: String) {
      self.language = language
      hasPrompts = language == .shell && CodeHighlighter.hasPrompts(code)
    }
  }

  /// A terminal session, as `ChatCopy.copyableCode` reads one: some line starts with a prompt.
  static func hasPrompts(_ code: String) -> Bool {
    code.split(separator: "\n").contains { $0.hasPrefix("$ ") || $0.hasPrefix("% ") }
  }

  /// One line, without its newline, split into plain and coloured pieces.
  static func segments(_ line: Substring, state: inout State) -> [Segment] {
    var scanner = Scanner(line: line)
    if state.language == .shell {
      shell(&scanner, state: &state)
    } else {
      code(&scanner, spec: Spec.of(state.language), state: &state)
    }
    return scanner.finish()
  }

  // MARK: Code

  /// How a language's tokens look.
  private struct Spec {
    var lineComments: [String] = []
    var blockComments: [(open: String, close: String)] = []
    /// Strings that can span lines; each closes with what opened it.
    var longStrings: [String] = []
    var quotes: Set<Character> = ["\"", "'"]
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// Keywords that name a new variable after them.
    var declarations: Set<String> = []
    var ignoresCase = false
    var capitalizedAreTypes = false
    /// A name before a single `=` is a variable (or an HTML attribute).
    var assignmentsAreVariables = false
    /// A name or string before `:` is a variable: a JSON key or CSS property.
    var keysAreVariables = false
    /// A name right after `<` or `</` is a tag; quotes and `name=` count only inside one.
    var tags = false
    /// Names can hold hyphens, like CSS's `background-color` or `--main-color`.
    var hyphenatedNames = false

    static func of(_ language: CodeLanguage) -> Spec {
      switch language {
      case .swift: swift
      case .python: python
      case .javascript: javascript
      case .json: json
      case .html: html
      case .css: css
      case .sql: sql
      case .shell: Spec()
      }
    }

    static let swift = Spec(
      lineComments: ["//"], blockComments: [("/*", "*/")], longStrings: ["\"\"\""], quotes: ["\""],
      keywords: ["actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
                 "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for",
                 "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "mutating", "nil",
                 "nonisolated", "open", "override", "private", "protocol", "public", "repeat", "rethrows", "return",
                 "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                 "true", "try", "typealias", "var", "where", "while"],
      declarations: ["let", "var"], capitalizedAreTypes: true, assignmentsAreVariables: true)

    static let python = Spec(
      lineComments: ["#"], longStrings: ["\"\"\"", "'''"],
      keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                 "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                 "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try",
                 "while", "with", "yield"],
      types: ["bool", "bytes", "dict", "float", "int", "list", "object", "set", "str", "tuple"],
      capitalizedAreTypes: true, assignmentsAreVariables: true)

    static let javascript = Spec(
      lineComments: ["//"], blockComments: [("/*", "*/")], longStrings: ["`"],
      keywords: ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                 "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function",
                 "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of",
                 "private", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true",
                 "try", "type", "typeof", "undefined", "var", "void", "while", "yield"],
      types: ["any", "boolean", "never", "number", "string", "unknown"],
      declarations: ["const", "let", "var"], capitalizedAreTypes: true, assignmentsAreVariables: true)

    static let json = Spec(keywords: ["true", "false", "null"], keysAreVariables: true)

    static let html = Spec(blockComments: [("<!--", "-->")], assignmentsAreVariables: true, tags: true,
                           hyphenatedNames: true)

    static let css = Spec(blockComments: [("/*", "*/")], keysAreVariables: true, hyphenatedNames: true)

    static let sql = Spec(
      lineComments: ["--"], blockComments: [("/*", "*/")], quotes: ["'", "\""],
      keywords: ["add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "commit", "create",
                 "delete", "desc", "distinct", "drop", "else", "end", "exists", "false", "foreign", "from", "group",
                 "having", "if", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like",
                 "limit", "not", "null", "offset", "on", "or", "order", "outer", "primary", "references", "returning",
                 "right", "select", "set", "table", "then", "true", "union", "unique", "update", "values", "view",
                 "when", "where", "with"],
      types: ["bigint", "blob", "boolean", "char", "date", "decimal", "float", "int", "integer", "real", "text",
              "timestamp", "varchar"],
      ignoresCase: true)
  }

  private static func code(_ s: inout Scanner, spec: Spec, state: inout State) {
    if let open = state.open {
      state.open = s.through(open.close) ? nil : open
      s.emit(open.kind)
    }
    // The name before this point, if only spaces separate them.
    var previousWord: Substring?
    while let c = s.current {
      let inMarkup = !spec.tags || state.insideTag
      if spec.lineComments.contains(where: { s.rest.hasPrefix($0) }) {
        s.toEnd()
        s.emit(.comment)
      } else if let comment = spec.blockComments.first(where: { s.rest.hasPrefix($0.open) }) {
        s.skip(comment.open.count)
        if !s.through(comment.close) { state.open = (comment.close, .comment) }
        s.emit(.comment)
      } else if let long = spec.longStrings.first(where: { s.rest.hasPrefix($0) }) {
        s.skip(long.count)
        if !s.through(long) { state.open = (long, .string) }
        s.emit(.string)
      } else if spec.quotes.contains(c), inMarkup {
        s.quoted(c)
        s.emit(spec.keysAreVariables && s.isFollowed(by: ":") ? .variable : .string)
      } else if c.isNumber, !(s.previous.map(isWordCharacter) ?? false) {
        s.skip(1)
        while let next = s.current, isWordCharacter(next) || next == "%"
                || (next == "." && s.rest.dropFirst().first?.isNumber == true) { s.skip(1) }
        s.emit(.number)
      } else if c == "#", spec.keysAreVariables, state.braceDepth > 0, s.isHexColor() {
        s.emit(.number)
      } else if c == "@", s.rest.dropFirst().first?.isLetter == true {
        s.skip(1)
        s.word(hyphens: spec.hyphenatedNames)
        s.emit(.keyword)
      } else if c.isLetter || c == "_" || (c == "$" && spec.declarations.contains("const"))
                  || (spec.hyphenatedNames && s.rest.hasPrefix("--")) {
        let word = s.word(hyphens: spec.hyphenatedNames)
        let key = spec.ignoresCase ? word.lowercased() : String(word)
        let afterTag = spec.tags && (s.before.hasSuffix("<") || s.before.hasSuffix("</"))
        let kind: CodeTokenKind? =
          if spec.keywords.contains(key) || afterTag { .keyword }
          else if let previousWord, spec.declarations.contains(String(previousWord)) { .variable }
          else if spec.types.contains(key) || (spec.capitalizedAreTypes && word.first?.isUppercase == true) { .type }
          else if spec.assignmentsAreVariables && inMarkup && s.isAssigned() { .variable }
          else if spec.keysAreVariables && state.braceDepth > 0 && s.isFollowed(by: ":") { .variable }
          else { nil }
        if afterTag { state.insideTag = true }
        s.emit(kind)
        previousWord = word
        continue
      } else {
        if c == ">" { state.insideTag = false }
        if c == "{" { state.braceDepth += 1 }
        if c == "}" { state.braceDepth = max(0, state.braceDepth - 1) }
        s.skip(1)
        s.emit(nil)
        if !c.isWhitespace { previousWord = nil }
        continue
      }
      previousWord = nil
    }
  }

  // MARK: Terminal

  private static let shellKeywords: Set<String> = [
    "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local",
    "select", "then", "until", "while", "!",
  ]
  /// Shell keywords whose next word is a name, not a command.
  private static let shellNamers: Set<String> = ["case", "export", "for", "function", "local", "select"]
  fileprivate static let shellOperators: Set<Character> = ["|", "&", ";", "(", ")", "<", ">", "`"]

  private static func shell(_ s: inout Scanner, state: inout State) {
    var expectsCommand = true
    // The next word is a redirect's target, or with `<<` a here-document's end word.
    var expectsTarget = false
    var opensHereDocument = false
    /// After `export` or `local`, `NAME=value` sets a variable.
    var assigns = false
    /// What `expectsCommand` was before each open `$(`, to restore at its `)`.
    var substitutions: [Bool] = []
    /// A quoted string from `s`'s quote; one left open carries to the next line.
    func quoted(_ quote: Character, opening: Bool = true) {
      if !s.quoted(quote, opening: opening, escapes: quote == "\""), !state.hasPrompts {
        state.open = (String(quote), .string)
      }
    }
    if let open = state.open, let quote = open.close.first {
      state.open = nil
      quoted(quote, opening: false)
      s.emit(.string)
      if state.open != nil { return }
      expectsCommand = false
    } else if let end = state.hereDocument {
      if s.rest.drop(while: { $0 == "\t" }) == end { state.hereDocument = nil }
      s.toEnd()
      s.emit(nil)
      return
    } else if state.continuesCommand {
      expectsCommand = state.continuedExpectsCommand
    } else if state.hasPrompts {
      guard s.rest.hasPrefix("$ ") || s.rest.hasPrefix("% ") else {
        s.toEnd()
        s.emit(.output)
        return
      }
      s.skip(2)
      s.emit(.output)
    }
    state.continuesCommand = ChatCopy.continuesOnNextLine(s.rest)
    while let c = s.current {
      if c.isWhitespace {
        s.skip(1)
        s.emit(nil)
      } else if c == "#" {
        s.toEnd()
        s.emit(.comment)
      } else if c == "\"" || c == "'", !expectsTarget {
        quoted(c)
        s.emit(.string)
        expectsCommand = false
      } else if c == "$" {
        s.skip(1)
        if s.current == "(" {
          // `$(` runs a command; `$((` is arithmetic.
          let arithmetic = s.rest.hasPrefix("((")
          substitutions += Array(repeating: expectsCommand, count: arithmetic ? 2 : 1)
          s.skip(arithmetic ? 2 : 1)
          s.emit(nil)
          expectsCommand = !arithmetic
          continue
        }
        if s.current == "{" {
          _ = s.through("}")
        } else if let next = s.current, next.isNumber || "?#@*!$-".contains(next) {
          s.skip(1)
        } else {
          s.word()
        }
        s.emit(.variable)
        expectsCommand = false
      } else if c == "<" || c == ">" {
        // `>>`, `2>&1`, `<<EOF`: the word after a redirect isn't a command.
        let hereDocument = s.rest.hasPrefix("<<") && !s.rest.hasPrefix("<<<")
        while let next = s.current, "<>&|-".contains(next) { s.skip(1) }
        if s.previous == "&" { while s.current?.isNumber == true { s.skip(1) } }
        s.emit(nil)
        expectsTarget = true
        opensHereDocument = hereDocument
      } else if shellOperators.contains(c) {
        s.skip(1)
        s.emit(nil)
        expectsCommand = c == ")" ? substitutions.popLast() ?? true : true
        expectsTarget = false
        assigns = false
      } else {
        s.shellWord()
        while let quote = s.current, quote == "\"" || quote == "'" {
          quoted(quote)
          s.shellWord()
        }
        let word = s.pending
        if word == "\\", s.current == nil {
          // A line's trailing `\` continues it; it isn't a word.
          s.emit(nil)
          continue
        }
        if expectsTarget {
          expectsTarget = false
          let end = word.filter { !"'\"\\".contains($0) }
          // `1 << 4` in arithmetic is a shift, not a here-document.
          if opensHereDocument, !state.hasPrompts, !end.isEmpty, !end.allSatisfy(\.isNumber) {
            state.hereDocument = end
          }
          s.emit(.path)
          continue
        }
        if expectsCommand || assigns, let equals = word.firstIndex(of: "="), word.startIndex < equals,
           word[..<equals].allSatisfy({ isWordCharacter($0) }) {
          // `NAME=value` before a command sets a variable for it.
          s.rewind(to: equals)
          s.emit(.variable)
          s.shellWord()
          while let quote = s.current, quote == "\"" || quote == "'" {
            quoted(quote)
            s.shellWord()
          }
          s.emit(nil)
          continue
        }
        let text = String(word)
        if expectsCommand, shellKeywords.contains(text) {
          s.emit(.keyword)
          expectsCommand = !shellNamers.contains(text)
          assigns = text == "export" || text == "local"
        } else if expectsCommand {
          s.emit(.command)
          expectsCommand = false
        } else if word.hasPrefix("-") {
          s.emit(.flag)
        } else if word.contains("/") || word.hasPrefix("~") {
          s.emit(.path)
        } else {
          s.emit(nil)
        }
      }
    }
    state.continuedExpectsCommand = expectsCommand
  }

  private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

  /// Walks a line, collecting the text since the last `emit` as one segment.
  private struct Scanner {
    let line: Substring
    private var index: Substring.Index
    private var start: Substring.Index
    private var segments: [Segment] = []

    init(line: Substring) {
      self.line = line
      index = line.startIndex
      start = line.startIndex
    }

    var current: Character? { index < line.endIndex ? line[index] : nil }
    var previous: Character? { index > line.startIndex ? line[line.index(before: index)] : nil }
    var rest: Substring { line[index...] }
    /// The line before the pending text.
    var before: Substring { line[..<start] }
    var pending: Substring { line[start..<index] }

    mutating func skip(_ count: Int) {
      index = line.index(index, offsetBy: count, limitedBy: line.endIndex) ?? line.endIndex
    }

    mutating func toEnd() { index = line.endIndex }

    mutating func rewind(to position: Substring.Index) { index = position }

    /// Up to the next space, operator, quote or `$`.
    mutating func shellWord() {
      while let c = current, !c.isWhitespace, !CodeHighlighter.shellOperators.contains(c),
            !"\"'$".contains(c) { skip(c == "\\" ? 2 : 1) }
    }

    /// Moves past `close`, or to the end of the line if it isn't there.
    mutating func through(_ close: String) -> Bool {
      guard let range = rest.range(of: close) else { toEnd(); return false }
      index = range.upperBound
      return true
    }

    /// A string opened by `quote` (already passed unless `opening`), to its
    /// closing quote or the line's end. False if the line ends first.
    @discardableResult
    mutating func quoted(_ quote: Character, opening: Bool = true, escapes: Bool = true) -> Bool {
      if opening { skip(1) }
      while let c = current {
        skip(escapes && c == "\\" ? 2 : 1)
        if c == quote { return true }
      }
      return false
    }

    @discardableResult mutating func word(hyphens: Bool = false) -> Substring {
      let wordStart = index
      while let c = current {
        if CodeHighlighter.isWordCharacter(c) || c == "$" {
          skip(1)
        } else if hyphens, c == "-", let next = rest.dropFirst().first,
                  next == "-" || CodeHighlighter.isWordCharacter(next) {
          skip(1)
        } else {
          break
        }
      }
      return line[wordStart..<index]
    }

    func isFollowed(by character: Character) -> Bool {
      rest.drop(while: { $0 == " " || $0 == "\t" }).first == character
    }

    /// A single `=` follows, not `==` or `=>`.
    func isAssigned() -> Bool {
      let after = rest.drop(while: { $0 == " " || $0 == "\t" })
      return after.first == "=" && !["=", ">"].contains(after.dropFirst().first)
    }

    /// A CSS colour such as `#fff`, consumed if it is one.
    mutating func isHexColor() -> Bool {
      let digits = rest.dropFirst().prefix(while: CodeHighlighter.isWordCharacter)
      guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return false }
      index = digits.endIndex
      return true
    }

    /// Ends the pending text as one segment; plain text joins plain text before it.
    mutating func emit(_ kind: CodeTokenKind?) {
      guard start < index else { return }
      if kind == nil, let last = segments.last, last.kind == nil {
        segments[segments.count - 1] = Segment(text: line[last.text.startIndex..<index], kind: nil)
      } else {
        segments.append(Segment(text: line[start..<index], kind: kind))
      }
      start = index
    }

    mutating func finish() -> [Segment] {
      emit(nil)
      return segments
    }
  }
}

/// A code block's highlighted text, kept between updates so a streamed block
/// only highlights its new lines: finished lines are highlighted once, and
/// only the unfinished last line again on each update.
@MainActor
final class CodeHighlightCache {
  private struct Key: Equatable {
    let language: CodeLanguage
    let hasPrompts: Bool
    let palette: EnigmaPalette
  }

  private var key: Key?
  /// The finished lines read so far, each with its newline.
  private var source = ""
  private var text = AttributedString()
  private var state: CodeHighlighter.State?
  /// How many UTF-8 bytes the last call highlighted, for tests.
  private(set) var lastHighlightedLength = 0

  func highlighted(_ code: String, language: CodeLanguage, palette: EnigmaPalette) -> AttributedString {
    let initial = CodeHighlighter.State(language: language, code: code)
    let key = Key(language: language, hasPrompts: initial.hasPrompts, palette: palette)
    if key != self.key || !code.utf8.starts(with: source.utf8) {
      self.key = key
      source = ""
      text = AttributedString()
      state = initial
    }
    var state = state ?? initial
    let unread = Substring(code.utf8.dropFirst(source.utf8.count))
    var lines = unread.split(separator: "\n", omittingEmptySubsequences: false)
    let last = lines.removeLast()
    for line in lines {
      text.append(Self.render(line, state: &state, palette: palette))
      text.append(AttributedString("\n"))
      source += line
      source += "\n"
    }
    self.state = state
    lastHighlightedLength = unread.utf8.count
    var result = text
    result.append(Self.render(last, state: &state, palette: palette))
    return result
  }

  private static func render(_ line: Substring, state: inout CodeHighlighter.State,
                             palette: EnigmaPalette) -> AttributedString {
    var result = AttributedString()
    for segment in CodeHighlighter.segments(line, state: &state) {
      var piece = AttributedString(String(segment.text))
      if let kind = segment.kind { piece.foregroundColor = color(kind, palette: palette).color }
      result.append(piece)
    }
    return result
  }

  /// Terminal tokens reuse the syntax colours, each kind its own.
  nonisolated static func color(_ kind: CodeTokenKind, palette: EnigmaPalette) -> EnigmaColor {
    switch kind {
    case .keyword, .command: palette.codeKeyword
    case .string, .path: palette.codeString
    case .number: palette.codeNumber
    case .comment: palette.codeComment
    case .type, .flag: palette.codeType
    case .variable: palette.codeVariable
    case .output: palette.textSecondary
    }
  }
}
