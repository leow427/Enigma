import SwiftUI

/// Draws an `EnigmaCharacterFrame` in a palette's colors.
enum EnigmaCharacterRenderer {
  struct Paths {
    var body = Path()
    var legs = Path()
    var feet = Path()
    var antenna = Path()
    var antennaBall = Path()
    var shadow = Path()
    var puffs = Path()
    var impactLines = Path()
  }

  static func paths(for frame: EnigmaCharacterFrame) -> Paths {
    var paths = Paths()
    guard !frame.isEmpty else { return paths }
    paths.body = outlinePath(frame.outline)
    for hole in frame.holes { paths.body.addEllipse(in: rect(hole)) }
    for leg in frame.legs {
      paths.legs.move(to: leg.start)
      paths.legs.addQuadCurve(to: leg.end, control: leg.control)
    }
    for foot in frame.feet { paths.feet.addEllipse(in: rect(foot)) }
    paths.antenna.move(to: frame.antenna.start)
    paths.antenna.addQuadCurve(to: frame.antenna.end, control: frame.antenna.control)
    paths.antennaBall.addEllipse(in: rect(frame.antennaBall))
    paths.shadow.addEllipse(in: frame.shadow)
    for puff in frame.puffs { paths.puffs.addEllipse(in: rect(puff)) }
    for line in frame.impactLines {
      paths.impactLines.move(to: line.start)
      paths.impactLines.addLine(to: line.end)
    }
    return paths
  }

  /// A smooth closed curve through the midpoints of the outline's points,
  /// with each point as the control, as in the mockup.
  static func outlinePath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let last = points.last, let first = points.first else { return path }
    path.move(to: midpoint(last, first))
    for index in points.indices {
      let next = points[(index + 1) % points.count]
      path.addQuadCurve(to: midpoint(points[index], next), control: points[index])
    }
    path.closeSubpath()
    return path
  }

  /// The body and antenna ball fade to `warning` in the error state.
  static func bodyColor(for frame: EnigmaCharacterFrame, palette: EnigmaPalette) -> EnigmaColor {
    let t = min(max(frame.errorTint, 0), 1)
    return palette.characterBody.mixed(with: palette.warning, amount: t * t * (3 - 2 * t))
  }

  /// The contact shadow is `characterInk` at 13% on a light canvas. On a dark
  /// canvas, where the ink is light, 8% is enough.
  static func shadowOpacity(for palette: EnigmaPalette) -> Double {
    palette.characterInk.relativeLuminance > 0.5 ? 0.08 : 0.13
  }

  static func draw(_ frame: EnigmaCharacterFrame, palette: EnigmaPalette, in context: inout GraphicsContext) {
    guard !frame.isEmpty else { return }
    let paths = paths(for: frame)
    let ink = palette.characterInk.color
    let body = bodyColor(for: frame, palette: palette).color
    let shadowOpacity = shadowOpacity(for: palette) * frame.shadowOpacity
    if shadowOpacity > 0 {
      context.fill(paths.shadow, with: .color(palette.characterInk.color.opacity(shadowOpacity)))
    }
    context.stroke(paths.legs, with: .color(ink), style: StrokeStyle(lineWidth: frame.legWidth, lineCap: .round))
    context.fill(paths.feet, with: .color(ink))
    context.stroke(paths.antenna, with: .color(ink), style: StrokeStyle(lineWidth: frame.lineWidth, lineCap: .round))
    context.fill(paths.antennaBall, with: .color(body))
    context.stroke(paths.antennaBall, with: .color(ink), lineWidth: frame.antennaBallLineWidth)
    context.fill(paths.body, with: .color(body), style: FillStyle(eoFill: true))
    context.stroke(paths.body, with: .color(ink), style: StrokeStyle(lineWidth: frame.lineWidth, lineJoin: .round))
    if !frame.puffs.isEmpty {
      context.fill(paths.puffs, with: .color(palette.background.color))
      context.stroke(paths.puffs, with: .color(ink), lineWidth: frame.puffLineWidth)
    }
    if !frame.impactLines.isEmpty {
      context.stroke(paths.impactLines, with: .color(ink),
                     style: StrokeStyle(lineWidth: frame.impactLineWidth, lineCap: .round))
    }
  }

  /// The same pose as lines only, in one color: no fill, shadow, or effects.
  static func drawOutline(_ frame: EnigmaCharacterFrame, color: Color, in context: inout GraphicsContext) {
    guard !frame.isEmpty else { return }
    let paths = paths(for: frame)
    let shading = GraphicsContext.Shading.color(color)
    context.stroke(paths.legs, with: shading, style: StrokeStyle(lineWidth: frame.legWidth, lineCap: .round))
    context.fill(paths.feet, with: shading)
    // The stalk starts inside the body, where the fill would hide it.
    var outside = context
    outside.clip(to: paths.body, options: .inverse)
    outside.stroke(paths.antenna, with: shading, style: StrokeStyle(lineWidth: frame.lineWidth, lineCap: .round))
    context.stroke(paths.antennaBall, with: shading, lineWidth: frame.antennaBallLineWidth)
    context.stroke(paths.body, with: shading, style: StrokeStyle(lineWidth: frame.lineWidth, lineJoin: .round))
  }

  private static func rect(_ circle: EnigmaCharacterFrame.Circle) -> CGRect {
    CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
           width: circle.radius * 2, height: circle.radius * 2)
  }

  private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
  }
}

extension EnigmaColor {
  /// This color moved `amount` of the way to `other`, in sRGB like a CSS transition.
  func mixed(with other: EnigmaColor, amount: Double) -> EnigmaColor {
    EnigmaColor(red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount,
                opacity: opacity + (other.opacity - opacity) * amount)
  }
}

/// The character's still pose as a mark: the same drawing as the living
/// character, at rest. It fills its frame, centered, and reads from 14 pt up.
/// Earlier chat replies show the quiet outline style where the character
/// stood; the filled style is the sidebar's app mark and the app icon's art.
struct EnigmaMark: View {
  enum Style: Sendable {
    /// A quiet single-color outline in `textTertiary`, for earlier chat replies.
    case outline
    /// The lime body with its ink outline, porthole, antenna, and legs.
    case filled
  }

  var style: Style = .outline

  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Canvas { context, size in
      Self.draw(style, in: CGRect(origin: .zero, size: size), palette: palette,
                increasedContrast: contrast == .increased, in: &context)
    }
    .accessibilityHidden(true)
  }

  /// Below this side, in points, the legs read as whiskers rather than legs,
  /// so the mark drops them and the body grows into their room. Neither style
  /// shows them at chat sizes.
  nonisolated static func legsMinimumSide(for style: Style) -> Double {
    switch style {
    case .outline: 40
    case .filled: 32
    }
  }

  /// How strongly the outline style draws: faint, as in the mockup, and twice
  /// as strong with Increase Contrast.
  nonisolated static func outlineOpacity(increasedContrast: Bool) -> Double { increasedContrast ? 1 : 0.55 }

  /// The pose to draw in `rect`. Pure, so icons can be drawn off the main actor.
  nonisolated static func pose(_ style: Style, in rect: CGRect) -> EnigmaCharacterFrame {
    EnigmaCharacterModel.stillFrame(fitting: rect, legs: min(rect.width, rect.height) >= legsMinimumSide(for: style))
  }

  static func draw(_ style: Style, in rect: CGRect, palette: EnigmaPalette, increasedContrast: Bool,
                   in context: inout GraphicsContext) {
    let frame = pose(style, in: rect)
    guard !frame.isEmpty else { return }
    switch style {
    case .outline:
      let color = palette.textTertiary.color
      context.opacity = outlineOpacity(increasedContrast: increasedContrast)
      // One layer, so strokes that cross don't darken where they overlap.
      context.drawLayer { layer in
        EnigmaCharacterRenderer.drawOutline(frame, color: color, in: &layer)
      }
    case .filled:
      EnigmaCharacterRenderer.draw(frame, palette: palette, in: &context)
    }
  }
}
