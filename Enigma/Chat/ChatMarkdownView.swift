import SwiftUI

// The styling layer for replies. Parsing stays in `ChatMarkdown`;
// this file only decides how each parsed block looks: serif text with roomy
// lines, links in `accentText`, and code in monospace on an opaque `surface`
// with a `border` edge.

/// How a parsed block's inline text is styled.
enum ChatMarkdownStyle {
  /// Between lines of a reply, for the mockup's 1.62 line height at 15 pt.
  static let lineSpacing: CGFloat = 6.5
  static let blockSpacing: CGFloat = 12
  static let codeFont = EnigmaTypography.mono(12.5)
  static let inlineCodeFont = EnigmaTypography.mono(13)
  static let tableFont = EnigmaTypography.reply(size: 14)

  /// The heading font for a level, or nil for body text. Headings in a reply
  /// stay in the reply's serif, semibold.
  static func headingFont(level: Int) -> Font {
    let size: CGFloat = switch level {
    case 1: 19
    case 2: 17
    default: 15.5
    }
    return EnigmaTypography.reply(size: size, weight: .semibold)
  }

  /// The block's text with the palette applied: inline code in monospace on
  /// `surface`, and links in `accentText`. Bold and italics keep the parser's
  /// intents, which the reply's font draws.
  static func styled(_ text: AttributedString, palette: EnigmaPalette) -> AttributedString {
    var styled = text
    for run in styled.runs {
      if run.inlinePresentationIntent?.contains(.code) == true {
        styled[run.range].font = inlineCodeFont
        styled[run.range].backgroundColor = palette.surface.color
      }
      if run.link != nil {
        styled[run.range].foregroundColor = palette.accentText.color
      }
    }
    return styled
  }

  static func isCode(_ block: ChatMarkdownBlock) -> Bool {
    block.components.contains { if case .codeBlock = $0.kind { return true }; return false }
  }

  static func isTable(_ group: [ChatMarkdownBlock]) -> Bool {
    group.first?.components.contains { if case .table = $0.kind { return true }; return false } == true
  }

  static func isThematicBreak(_ block: ChatMarkdownBlock) -> Bool {
    block.components.contains { $0.kind == .thematicBreak }
  }

  static func headingLevel(_ block: ChatMarkdownBlock) -> Int? {
    for component in block.components {
      if case .header(let level) = component.kind { return level }
    }
    return nil
  }

  /// The list marker for a block inside a list item: `•`, or `3.` in an ordered list.
  static func listMarker(_ block: ChatMarkdownBlock) -> String? {
    guard let item = block.components.first(where: { if case .listItem = $0.kind { return true }; return false }),
          case .listItem(let ordinal) = item.kind else { return nil }
    let ordered = block.components.drop(while: { $0.identity != item.identity }).dropFirst().first?.kind == .orderedList
    return ordered ? "\(ordinal)." : "•"
  }

  static func listDepth(_ block: ChatMarkdownBlock) -> Int {
    block.components.filter { if case .listItem = $0.kind { return true }; return false }.count
  }
}

/// A reply's Markdown.
struct ChatMarkdownView: View {
  let content: String
  @Environment(\.enigmaPalette) private var palette
  /// Keeps the settled part of a streaming reply parsed between updates.
  @State private var stream = ChatMarkdownStream()

  var body: some View {
    let blocks = stream.blocks(content)
    VStack(alignment: .leading, spacing: ChatMarkdownStyle.blockSpacing) {
      ForEach(ChatMarkdown.groups(blocks), id: \.first?.id) { group in
        if ChatMarkdownStyle.isTable(group) {
          ChatMarkdownTable(rows: ChatMarkdown.rows(group))
        } else {
          ForEach(group) { block in ChatMarkdownBlockView(block: block) }
        }
      }
    }
    .font(EnigmaTypography.reply)
    .lineSpacing(ChatMarkdownStyle.lineSpacing)
    .foregroundStyle(palette.textPrimary.color)
    .tint(palette.accentText.color)
    .textSelection(.enabled)
  }
}

private struct ChatMarkdownBlockView: View {
  let block: ChatMarkdownBlock
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let quote = block.components.contains { $0.kind == .blockQuote }
    let depth = ChatMarkdownStyle.listDepth(block)
    HStack(alignment: .top, spacing: 8) {
      if quote {
        Rectangle()
          .fill(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color)
          .frame(width: 2)
      }
      if let marker = ChatMarkdownStyle.listMarker(block) {
        Text(marker).foregroundStyle(palette.textSecondary.color)
      }
      content(quote: quote)
    }
    .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func content(quote: Bool) -> some View {
    if ChatMarkdownStyle.isCode(block) {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      ScrollView(.horizontal) {
        Text(verbatim: String(block.text.characters).trimmingCharacters(in: .newlines))
          .font(ChatMarkdownStyle.codeFont)
          .lineSpacing(3)
          .foregroundStyle(palette.textPrimary.color)
          .fixedSize(horizontal: true, vertical: true)
          .padding(12)
      }
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.surface.color, in: shape)
      .enigmaEdge(shape)
      .accessibilityLabel("Code")
      .accessibilityValue(String(block.text.characters))
    } else if ChatMarkdownStyle.isThematicBreak(block) {
      EnigmaHairline().padding(.vertical, 4)
    } else {
      Text(ChatMarkdownStyle.styled(block.text, palette: palette))
        .font(ChatMarkdownStyle.headingLevel(block).map(ChatMarkdownStyle.headingFont) ?? EnigmaTypography.reply)
        .foregroundStyle((quote ? palette.textSecondary : palette.textPrimary).color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A table on an opaque `surface` with a `border` edge and hairlines between
/// rows. A wide table scrolls sideways rather than squeezing the reply.
private struct ChatMarkdownTable: View {
  let rows: [[ChatMarkdownBlock]]
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        ForEach(Array(rows.enumerated()), id: \.element.first?.id) { index, row in
          if index > 0 {
            EnigmaHairline().gridCellUnsizedAxes(.horizontal)
          }
          GridRow {
            ForEach(row) { cell in
              let header = cell.components.contains { $0.kind == .tableHeaderRow }
              Text(ChatMarkdownStyle.styled(cell.text, palette: palette))
                .font(ChatMarkdownStyle.tableFont)
                .fontWeight(header ? .semibold : .regular)
                .foregroundStyle(palette.textPrimary.color)
            }
          }
        }
      }
      .lineSpacing(3)
      .padding(12)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
  }
}
