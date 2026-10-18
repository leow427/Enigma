import SwiftUI

/// The app's identity images, drawn from the character's still pose so they
/// always match the living character (see "App icon and mark" in the spec):
///
/// - the app icon: the filled mark, flat and centered on a Paper `background`
///   rounded square;
/// - the menu bar template: the outline mark in one color, without legs, sized
///   for an 18 pt status item.
///
/// The asset catalog keeps rendered copies, the `AppIcon` set and the
/// `SpotlightLogo` template, because macOS reads the icon from the bundle.
/// `EnigmaIconTests` fails when a copy no longer matches this drawing; run
/// `scripts/generate-app-icons.sh` to redraw them.
enum EnigmaAppIcon {
  /// One image in the macOS `AppIcon` set.
  struct Rendition: Hashable, Sendable {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 1 ? "" : "@\(scale)x").png" }
  }

  /// The full macOS set: 16 to 512 pt, at 1x and 2x.
  nonisolated static let renditions: [Rendition] = [16, 32, 128, 256, 512].flatMap { points in
    [1, 2].map { Rendition(points: points, scale: $0) }
  }

  /// Finder and the Dock have one icon for both appearances, so it is Paper.
  nonisolated static let palette = EnigmaPalette.paper

  // MARK: App icon

  /// The rounded square on Apple's macOS grid: 824 of 1024 pt, centered,
  /// leaving the margin the system expects around every app icon.
  nonisolated static func tile(in canvas: CGRect) -> CGRect {
    canvas.insetBy(dx: canvas.width * 100 / 1024, dy: canvas.height * 100 / 1024)
  }

  /// The grid's corner radius for a tile, drawn as a continuous curve.
  nonisolated static func cornerRadius(forTile tile: CGRect) -> CGFloat {
    tile.width * 185.4 / 824
  }

  /// Icons this small are simplified: the character takes more of the tile
  /// and draws a heavier line, so the outline and porthole stay open.
  nonisolated static func isSmall(points: CGFloat) -> Bool { points <= 32 }

  /// The square the character fits in.
  nonisolated static func markRect(inTile tile: CGRect, points: CGFloat) -> CGRect {
    let side = tile.width * (isSmall(points: points) ? 0.88 : 0.8)
    return CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
  }

  /// The pose the icon draws at `points`: the sidebar mark's still pose, which
  /// drops its legs below `EnigmaMark`'s threshold. Small icons draw a line of
  /// about one pixel at 1x, rather than a blurred fraction of one.
  nonisolated static func pose(points: CGFloat) -> EnigmaCharacterFrame {
    let rect = markRect(inTile: tile(in: CGRect(x: 0, y: 0, width: points, height: points)), points: points)
    let legs = min(rect.width, rect.height) >= EnigmaMark.legsMinimumSide(for: .filled)
    let lineWidth: Double? = isSmall(points: points) ? 0.7 + points * 0.019 : nil
    return EnigmaCharacterModel.stillFrame(fitting: rect, legs: legs, lineWidth: lineWidth)
  }

  /// Draws the icon on a `points`-sized canvas. `scale` is pixels per point,
  /// so the tile's edge stays at least one pixel wide.
  nonisolated static func draw(points: CGFloat, scale: CGFloat, in context: inout GraphicsContext) {
    let tile = tile(in: CGRect(x: 0, y: 0, width: points, height: points))
    let shape = Path(roundedRect: tile, cornerRadius: cornerRadius(forTile: tile), style: .continuous)
    context.fill(shape, with: .color(palette.background.color))
    // The same `border` edge as the app's opaque surfaces, so the light tile
    // keeps its shape on a white Finder window. Drawn inside the tile.
    let edge = max(1 / scale, tile.width / 412)
    var inside = context
    inside.clip(to: shape)
    inside.stroke(shape, with: .color(palette.border.color), lineWidth: edge * 2)
    EnigmaCharacterRenderer.draw(pose(points: points), palette: palette, in: &context)
  }

  // MARK: Menu bar

  /// The status item's side, in points.
  nonisolated static let menuBarSide: CGFloat = 18

  /// The menu bar pose: the still pose without legs, which turn to noise at
  /// 18 pt, filling the item with half a point to spare at the top and bottom.
  nonisolated static func menuBarPose(side: CGFloat = menuBarSide) -> EnigmaCharacterFrame {
    let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side / 36, dy: side / 36)
    return EnigmaCharacterModel.stillFrame(fitting: rect, legs: false, lineWidth: menuBarLineWidth(side: side))
  }

  /// The outline's width in the menu bar: about the stroke of a regular SF
  /// Symbol at the same size.
  nonisolated static func menuBarLineWidth(side: CGFloat) -> CGFloat { side * 1.4 / 18 }

  /// Draws the template in one color: the outline, porthole, and antenna.
  nonisolated static func drawMenuBarTemplate(side: CGFloat = menuBarSide, color: Color = .black,
                                              in context: inout GraphicsContext) {
    let frame = menuBarPose(side: side)
    // One layer, so strokes that meet don't build up where they overlap.
    context.drawLayer { layer in
      EnigmaCharacterRenderer.drawOutline(frame, color: color, in: &layer)
    }
  }
}

/// The app icon as a view, for the generator and the screenshots.
struct EnigmaAppIconView: View {
  var points: CGFloat
  var scale: CGFloat = 2

  var body: some View {
    Canvas { context, _ in
      EnigmaAppIcon.draw(points: points, scale: scale, in: &context)
    }
    .frame(width: points, height: points)
    .accessibilityHidden(true)
  }
}

/// The menu bar template as a view, for the generator and the screenshots.
struct EnigmaMenuBarMarkView: View {
  var side: CGFloat = EnigmaAppIcon.menuBarSide
  var color: Color = .black

  var body: some View {
    Canvas { context, _ in
      EnigmaAppIcon.drawMenuBarTemplate(side: side, color: color, in: &context)
    }
    .frame(width: side, height: side)
    .accessibilityHidden(true)
  }
}
