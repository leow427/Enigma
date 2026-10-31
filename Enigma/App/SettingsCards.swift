import SwiftUI

/// A card starts at the first row after a heading or closing line, and ends at the next one.
struct SettingsCardMark {
  enum Kind { case row, end }
  let kind: Kind
  let anchor: Anchor<CGPoint>
}

struct SettingsCardMarks: PreferenceKey {
  static let defaultValue: [SettingsCardMark] = []
  static func reduce(value: inout [SettingsCardMark], nextValue: () -> [SettingsCardMark]) { value += nextValue() }
}

extension View {
  func settingsCardMark(_ kind: SettingsCardMark.Kind, at point: UnitPoint, if isOn: Bool) -> some View {
    transformAnchorPreference(key: SettingsCardMarks.self, value: .unitPoint(point)) { marks, anchor in
      if isOn { marks.append(SettingsCardMark(kind: kind, anchor: anchor)) }
    }
  }

  /// Draws the cards behind a Settings page, `inset` wider than its rows on each side.
  func settingsCards(inset: CGFloat) -> some View {
    backgroundPreferenceValue(SettingsCardMarks.self) { marks in
      GeometryReader { proxy in SettingsCardsBackground(cards: SettingsCardsBackground.cards(
        marks.map { ($0.kind, proxy[$0.anchor].y) }), width: proxy.size.width, inset: inset) }
    }
  }
}

struct SettingsCardsBackground: View {
  /// Each card's top, bottom, and the tops of its rows after the first.
  struct Card: Equatable { var top: CGFloat; var bottom: CGFloat; var dividers: [CGFloat] }
  let cards: [Card]
  let width: CGFloat
  let inset: CGFloat
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  static func cards(_ marks: [(SettingsCardMark.Kind, CGFloat)]) -> [Card] {
    var cards: [Card] = []
    var open: Card?
    for (kind, y) in marks.sorted(by: { $0.1 < $1.1 }) {
      switch kind {
      case .row:
        if open == nil { open = Card(top: y, bottom: y, dividers: []) } else { open?.dividers.append(y) }
      case .end:
        if var card = open, y > card.top + 1 { card.bottom = y; cards.append(card) }
        open = nil
      }
    }
    return cards
  }

  var body: some View {
    let line = EnigmaEdge.hairline.color(in: palette, increasedContrast: contrast == .increased).color
    ZStack(alignment: .topLeading) {
      ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(palette.surface.color)
          .enigmaEdge(shape)
          .frame(width: width + inset * 2, height: card.bottom - card.top)
          .offset(x: -inset, y: card.top)
        ForEach(card.dividers, id: \.self) { y in
          Rectangle().fill(line).frame(width: width, height: 1 / displayScale).offset(y: y)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityHidden(true)
  }
}
