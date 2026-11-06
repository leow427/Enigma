import SwiftUI

/// A request's activity: one monospace status line that discloses the steps
/// as plain rows (the web sources open from the reply's meta line instead).
/// Nothing is boxed; a hairline runs down the left of the open list.
struct AssistantActivityView: View {
  let activity: AssistantActivity
  var expanded: Binding<Bool>? = nil
  @State private var locallyExpanded = false
  @FocusState private var isFocused: Bool
  @State private var isHovered = false
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isExpanded: Binding<Bool> { expanded ?? $locallyExpanded }

  /// The status line's glyph: busy while the request runs, then how it ended.
  static func status(of phase: AssistantActivity.Phase) -> EnigmaStatusLine.Status {
    switch phase {
    case .completed: .on
    case .cancelled: .off
    case .failed: .problem
    default: .busy
    }
  }

  /// A step's glyph in the open list: the current step is busy, the rest done.
  static func stepGlyph(_ phase: AssistantActivity.Phase, current: AssistantActivity.Phase) -> String {
    phase == current && !phase.isTerminal ? "◌" : "✓"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let notice = activity.notice {
        Text(notice)
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      toggle
      if isExpanded.wrappedValue {
        panel.transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var toggle: some View {
    let status = Self.status(of: activity.phase)
    return Button {
      withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) {
        isExpanded.wrappedValue.toggle()
      }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(status.glyph).fontWeight(status == .problem ? .bold : .regular)
          .foregroundStyle(status.color(in: palette).color)
        Text(activity.status)
          .foregroundStyle((isHovered ? palette.textPrimary : palette.textSecondary).color)
        Image(systemName: "chevron.right")
          .font(EnigmaTypography.disclosureSymbol)
          .foregroundStyle(palette.textTertiary.color)
          .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
      }
      .font(EnigmaTypography.mono(11.5))
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 4, outset: 3)
    .onHover { isHovered = $0 }
    .accessibilityLabel(activity.status)
    .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    .accessibilityHint("Show or hide request activity")
    .accessibilityIdentifier("assistant-activity-toggle")
    .enigmaTestMarker("Activity")
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(activity.phases, id: \.self) { phase in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(Self.stepGlyph(phase, current: activity.phase))
            .foregroundStyle(palette.textTertiary.color)
            .accessibilityHidden(true)
          Text(phase == .readingSources && !activity.sources.isEmpty ? "Selected \(activity.sourceSummary)" : phase.label)
            .foregroundStyle(palette.textSecondary.color)
        }
        .font(EnigmaTypography.mono(11))
      }
      if activity.sources.isEmpty && activity.phase.isSearching {
        Text("Waiting for search results…")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textSecondary.color)
      }
    }
    .padding(.leading, 12)
    .overlay(alignment: .leading) {
      EnigmaVerticalHairline()
    }
    .padding(.leading, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("assistant-activity-panel")
  }
}

/// A reply's web sources, collapsed: a "Sources" bubble on its meta line, led by
/// the first sites' letter badges, that opens `ReplySourceList` under it.
struct ReplySourcesButton: View {
  static let badgeCount = 3

  let activity: AssistantActivity
  @Binding var isExpanded: Bool
  @FocusState private var isFocused: Bool
  @State private var isHovered = false
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isLit = isHovered || isExpanded
    Button {
      withAnimation(reduceMotion ? nil : EnigmaMotion.pageChange.animation) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 5) {
        HStack(spacing: -4) {
          ForEach(SourceBadge.leading(activity.sources, count: Self.badgeCount)) { source in
            SourceBadgeView(source: source, size: 14)
              .overlay { Circle().stroke(palette.userBubble.color, lineWidth: 1.5) }
          }
        }
        Text("Sources")
      }
      .font(EnigmaTypography.mono(11))
      .foregroundStyle((isLit ? palette.textPrimary : palette.textSecondary).color)
      .padding(.leading, 3)
      .padding(.trailing, 8)
      .padding(.vertical, 2)
      .background {
        Capsule().fill(palette.userBubble.color)
        if isLit { Capsule().fill(palette.hover.color) }
      }
      .overlay { Capsule().strokeBorder(palette.hairline.color, lineWidth: 1) }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 9, outset: 2)
    .onHover { isHovered = $0 }
    .help(activity.sourceSummary)
    .accessibilityLabel(activity.sourceSummary)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Show or hide web sources")
    .enigmaTestMarker("Sources")
  }
}

/// A source's letter badge (owner, 2026-11-06): the site's initial, like W for
/// Wikipedia, on a theme colour picked from the site's name, so a site keeps its
/// colour from reply to reply.
enum SourceBadge {
  /// The site's own name from its host: "en.wikipedia.org" and "www.bbc.co.uk" give "wikipedia" and "bbc".
  static func name(for source: WebSearchSource) -> String {
    var labels = source.siteName.lowercased().split(separator: ".").map(String.init)
    if labels.count > 1 { labels.removeLast() }
    if labels.count > 1, let last = labels.last, ["co", "com", "org", "net", "gov", "ac", "edu"].contains(last) {
      labels.removeLast()
    }
    return labels.last ?? source.siteName.lowercased()
  }

  static func letter(for source: WebSearchSource) -> String {
    name(for: source).first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
  }

  /// The badge colours: the theme's code colours and its red, each dark on Paper
  /// and light on Ink, so `letterColor` reads on all of them.
  static func colors(in palette: EnigmaPalette) -> [EnigmaColor] {
    [palette.codeVariable, palette.codeString, palette.codeNumber, palette.codeKeyword, palette.codeType, palette.contextFull]
  }

  static func letterColor(in palette: EnigmaPalette) -> EnigmaColor { palette.background }

  static func color(for source: WebSearchSource, in palette: EnigmaPalette) -> EnigmaColor {
    // FNV-1a, since `hashValue` changes from launch to launch.
    var hash: UInt32 = 2_166_136_261
    for byte in name(for: source).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    let colors = colors(in: palette)
    return colors[Int(hash % UInt32(colors.count))]
  }

  /// The first `count` sources from different sites, for the collapsed bubble.
  static func leading(_ sources: [WebSearchSource], count: Int) -> [WebSearchSource] {
    var seen = Set<String>()
    return Array(sources.filter { seen.insert(name(for: $0)).inserted }.prefix(count))
  }
}

/// A source's letter on its colour, in a circle.
struct SourceBadgeView: View {
  let source: WebSearchSource
  let size: CGFloat
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    Text(SourceBadge.letter(for: source))
      .font(EnigmaTypography.ui(size * 0.6, weight: .semibold))
      .foregroundStyle(SourceBadge.letterColor(in: palette).color)
      .frame(width: size, height: size)
      .background { Circle().fill(SourceBadge.color(for: source, in: palette).color) }
      .accessibilityHidden(true)
  }
}

/// A reply's open web sources, as the rows the activity panel used to show.
struct ReplySourceList: View {
  let activity: AssistantActivity

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(activity.sources) { source in
          ActivitySourceRow(source: source, detail: sourceDetail(source))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(CGFloat(activity.sources.count) * ActivitySourceRow.height, 260))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Web sources")
    .enigmaTestMarker("Activity sources")
  }

  private func sourceDetail(_ source: WebSearchSource) -> String {
    guard let selected = activity.selectedSourceIDs else { return "Collected excerpt" }
    return selected.contains(source.id) ? "Included in context" : "Collected excerpt"
  }
}

/// A one-pixel line down the side of something, like the activity's open list.
private struct EnigmaVerticalHairline: View {
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Rectangle()
      .fill(EnigmaEdge.hairline.color(in: palette, increasedContrast: contrast == .increased).color)
      .frame(width: 1 / displayScale)
      .accessibilityHidden(true)
  }
}

/// A web source as a plain row that opens the page: its title, then the site
/// and whether it was used, then the address, in monospace.
extension EnvironmentValues {
  /// "Never use this site" for source rows (spec §8); nil offers no action.
  @Entry var sourceBlocking: SourceBlocking? = nil
}

private struct ActivitySourceRow: View {
  static let height: CGFloat = 62

  let source: WebSearchSource
  let detail: String
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.sourceBlocking) private var blocking
  @FocusState private var isFocused: Bool
  @State private var isHovered = false
  /// The domain this row blocked, until Undo or the panel closes.
  @State private var blockedDomain: String?

  /// The blocking actions this row offers: none for Apple Maps, Open-Meteo, or without the environment.
  private var offeredBlocking: SourceBlocking? { source.allowsBlocking ? blocking : nil }

  var body: some View {
    HStack(alignment: .center, spacing: 6) {
      link
      if let blockedDomain, let blocking = offeredBlocking {
        Button("Undo") {
          blocking.unblock(blockedDomain)
          self.blockedDomain = nil
        }
        .enigmaButtonStyle(.text)
        .accessibilityLabel("Undo blocking \(blockedDomain)")
      }
    }
    .overlay(alignment: .bottom) { EnigmaHairline() }
  }

  private var link: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    let line = blockedDomain == nil ? source.siteName + " · " + detail : source.siteName + " · blocked"
    return Link(destination: source.url) {
      HStack(alignment: .top, spacing: 8) {
        SourceBadgeView(source: source, size: 18).padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(source.title.isEmpty ? source.siteName : source.title)
            .font(EnigmaTypography.ui(12.5, weight: .medium))
            .foregroundStyle(palette.textPrimary.color)
            .lineLimit(1)
          Text(line)
            .font(EnigmaTypography.mono(10.5))
            .foregroundStyle(palette.textSecondary.color)
            .lineLimit(1)
          Text(source.url.absoluteString)
            .font(EnigmaTypography.mono(10.5))
            .foregroundStyle(palette.textTertiary.color)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
        Text("↗")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle((isHovered ? palette.accentText : palette.textTertiary).color)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 6)
      .frame(height: Self.height)
      .background { if isHovered { shape.fill(palette.hover.color) } }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focused($isFocused)
    .focusEffectDisabled()
    .enigmaFocusRing(isFocused, palette: palette, cornerRadius: 6, outset: 0)
    .onHover { isHovered = $0 }
    .help(source.url.absoluteString)
    .accessibilityLabel("\(source.title), \(line)")
    .contextMenu {
      if let blocking = offeredBlocking, blockedDomain == nil {
        Button(blocking.neverUseLabel(for: source.url)) { block(blocking) }
      }
    }
    .accessibilityActions {
      if let blocking = offeredBlocking, blockedDomain == nil {
        Button(blocking.neverUseLabel(for: source.url)) { block(blocking) }
      }
    }
  }

  private func block(_ blocking: SourceBlocking) {
    blockedDomain = blocking.domain(source.url)
    blocking.block(source.url)
  }
}
