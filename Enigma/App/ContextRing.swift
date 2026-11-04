import SwiftUI

/// A small ring in the composer showing how full the chat's context is (F35). It fills
/// clockwise from the top with the exact share of the route's input budget the chat uses.
struct ContextRing: View {
  let usage: ContextUsage
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsPopover = false

  static let diameter: CGFloat = 14
  static let lineWidth: CGFloat = 2

  static func color(for level: ContextUsage.Level, palette: EnigmaPalette) -> EnigmaColor {
    switch level {
    case .normal: palette.accent
    case .high: palette.contextHigh
    case .full: palette.contextFull
    }
  }

  static func help(_ usage: ContextUsage) -> String {
    let left = "\(usage.percentLeft)% of context left"
    return usage.level == .full ? left + ". Earlier messages will be summarized." : left
  }

  static func tokenLine(_ usage: ContextUsage) -> String {
    "\(tokens(usage.usedTokens)) of \(tokens(usage.limitTokens)) tokens used"
  }

  /// 640, 8.2K, 12K: decided on the rounded value, halves up, so 9,999 is 10K, never 10.0K.
  static func tokens(_ count: Int) -> String {
    let tenths = (count + 50) / 100
    if tenths >= 100 { return "\((count + 500) / 1_000)K" }
    if count >= 1_000 { return "\(tenths / 10).\(tenths % 10)K" }
    return "\(count)"
  }

  static func accessibilityValue(_ usage: ContextUsage) -> String { tokenLine(usage) + "\n" + help(usage) }

  var body: some View {
    let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
    Button { showsPopover = true } label: {
      ZStack {
        Circle().stroke(palette.contextTrack.color, style: style)
        Circle()
          .trim(from: 0, to: usage.fraction)
          .stroke(Self.color(for: usage.level, palette: palette).color, style: style)
          .rotationEffect(.degrees(-90))
      }
      .frame(width: Self.diameter, height: Self.diameter)
      .padding(5)
      .contentShape(Rectangle())
      .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: usage)
    }
    .buttonStyle(.plain)
    .help(Self.help(usage))
    .popover(isPresented: $showsPopover) {
      VStack(alignment: .leading, spacing: 4) {
        Text(Self.tokenLine(usage)).foregroundStyle(palette.textPrimary.color)
        Text(Self.help(usage)).foregroundStyle(palette.textSecondary.color)
      }
      .font(EnigmaTypography.mono(11))
      .padding(10)
    }
    .accessibilityLabel("Context")
    .accessibilityValue(Self.accessibilityValue(usage))
    .enigmaTestMarker("Context ring")
  }
}
