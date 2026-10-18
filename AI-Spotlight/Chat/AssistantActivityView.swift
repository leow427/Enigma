import SwiftUI

/// A request's activity: one monospace status line that discloses the steps
/// and the web sources as plain rows. Nothing is boxed; a hairline runs down
/// the left of the open list.
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
    .accessibilityHint("Show or hide request activity and sources")
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
      if !activity.sources.isEmpty {
        Text("web sources")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
          .padding(.top, activity.phases.isEmpty ? 0 : 6)
          .accessibilityAddTraits(.isHeader)
          .accessibilityLabel("Web sources")
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
        .enigmaTestMarker("Activity sources")
      } else if activity.phase == .searching {
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
private struct ActivitySourceRow: View {
  static let height: CGFloat = 62

  let source: WebSearchSource
  let detail: String
  @Environment(\.enigmaPalette) private var palette
  @FocusState private var isFocused: Bool
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Link(destination: source.url) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.title.isEmpty ? source.siteName : source.title)
            .font(EnigmaTypography.ui(12.5, weight: .medium))
            .foregroundStyle(palette.textPrimary.color)
            .lineLimit(1)
          Text(source.siteName + " · " + detail)
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
    .overlay(alignment: .bottom) { EnigmaHairline() }
    .onHover { isHovered = $0 }
    .help(source.url.absoluteString)
    .accessibilityLabel("\(source.title), \(source.siteName), \(detail)")
  }
}
