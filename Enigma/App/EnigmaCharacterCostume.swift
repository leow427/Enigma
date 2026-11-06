import SwiftUI

/// What the character wears while a weather card shows on the latest reply (F36), or in a
/// temporary chat (F10's ghost sheet). Each costume is drawn from the live frame's own geometry,
/// so it follows any pose.
enum EnigmaCharacterCostume: String, CaseIterable, Equatable, Sendable {
  case sunglasses, umbrella, umbrellaInsideOut, woollyHat, scarf, nightcap, ghost

  /// The costume for a card's sky: the first card's, when a reply has several.
  static func forWeather(_ card: WeatherCardModel) -> Self { forWeather(card.sky, light: card.light) }

  static func forWeather(_ sky: WeatherCardModel.Sky, light: WeatherCardModel.Light) -> Self {
    switch sky {
    case .clear, .partlyCloudy: light == .night ? .nightcap : .sunglasses
    case .overcast, .fog: .scarf
    case .rain: .umbrella
    case .storm: .umbrellaInsideOut
    case .snow: .woollyHat
    }
  }

  /// The character in `frame`, wearing `costume`. With a `time`, the character and costume move
  /// for the weather: a sway in the sun, a shiver in snow and storms, a dripping umbrella, a
  /// flapping one in a storm, a fluttering scarf, a swinging pompom. Nil draws the still pose.
  /// The frame's puffs go over the costume, so a change of outfit happens inside the smoke.
  static func draw(_ frame: EnigmaCharacterFrame, wearing costume: Self?, palette: EnigmaPalette,
                   time: Double? = nil, in canvas: inout GraphicsContext) {
    guard let costume, !frame.isEmpty else {
      EnigmaCharacterRenderer.draw(frame, palette: palette, in: &canvas)
      return
    }
    let t = time ?? 0, moving = time != nil
    var context = canvas
    if moving { costume.move(&context, frame: frame, t: t) }
    var dressed = frame
    dressed.puffs = []
    dressed.impactLines = []
    EnigmaCharacterRenderer.draw(dressed, palette: palette, in: &context)
    if let figure = Figure(frame, palette: palette, t: t, moving: moving) { costume.draw(figure, in: &context) }
    EnigmaCharacterRenderer.drawEffects(frame, palette: palette, in: &canvas)
  }

  private func draw(_ figure: Figure, in context: inout GraphicsContext) {
    switch self {
    case .sunglasses: Self.drawSunglasses(figure, in: &context)
    case .umbrella: Self.drawUmbrella(figure, insideOut: false, in: &context)
    case .umbrellaInsideOut: Self.drawUmbrella(figure, insideOut: true, in: &context)
    case .woollyHat:
      Self.drawScarf(figure, color: Self.red, in: &context)
      Self.drawWoollyHat(figure, in: &context)
    case .scarf: Self.drawScarf(figure, color: Self.blue, in: &context)
    case .nightcap: Self.drawNightcap(figure, in: &context)
    case .ghost: Self.drawGhostSheet(figure, in: &context)
    }
  }

  /// The whole character's motion, pivoting on its feet.
  private func move(_ context: inout GraphicsContext, frame: EnigmaCharacterFrame, t: Double) {
    let feet = CGPoint(x: frame.shadow.midX, y: frame.shadow.midY)
    let size = frame.calmBounds.height
    var angle = 0.0, shift = 0.0
    switch self {
    case .sunglasses:
      angle = sin(t * 1.4) * 0.05                       // a relaxed sway
    case .woollyHat, .umbrellaInsideOut:
      // Shivers in bursts: a quick tremble for about a second every few seconds.
      let burst = max(0, sin(t * (self == .woollyHat ? 0.9 : 1.6)) - 0.4) / 0.6
      shift = sin(t * 46) * size * 0.012 * burst
      if self == .umbrellaInsideOut { angle = sin(t * 2.3) * 0.06 }  // leaning into the wind
    case .umbrella:
      angle = sin(t * 0.9) * 0.025
    case .scarf:
      angle = sin(t * 0.7) * 0.02
    case .nightcap:
      angle = sin(t * 0.5) * 0.04                        // a sleepy nod
    case .ghost:
      angle = sin(t * 1.1) * 0.06                        // a spooky wobble
    }
    context.translateBy(x: feet.x + shift, y: feet.y)
    context.rotate(by: .radians(angle))
    context.translateBy(x: -feet.x, y: -feet.y)
  }

  // MARK: Geometry

  /// Where to put things on the body, in body radii from its center.
  private struct Figure {
    let center: CGPoint
    let radius: Double
    let halfHeight: Double
    let hole: CGPoint
    let tip: CGPoint
    let tipRadius: Double
    let line: Double
    let body: Path
    let antenna: Path
    let antennaBall: Path
    let ink: Color
    let palette: EnigmaPalette
    /// Seconds, for the costume's own motion; 0 and still when not moving.
    let t: Double
    let moving: Bool

    init?(_ frame: EnigmaCharacterFrame, palette: EnigmaPalette, t: Double = 0, moving: Bool = false) {
      // The calm box, not the rippling outline, so tokens streaming in don't shake the outfit.
      let box = frame.calmBounds
      guard box.width > 0 else { return nil }
      center = CGPoint(x: box.midX, y: box.midY)
      radius = box.width / 2
      halfHeight = box.height / 2
      hole = frame.holes.first?.center ?? center
      tip = frame.antennaBall.center
      tipRadius = frame.antennaBall.radius
      line = frame.lineWidth
      let paths = EnigmaCharacterRenderer.paths(for: frame)
      body = EnigmaCharacterRenderer.outlinePath(frame.outline)
      antenna = paths.antenna
      antennaBall = paths.antennaBall
      ink = palette.characterInk.color
      self.palette = palette
      self.t = t
      self.moving = moving
    }

    /// A 0..<1 phase that repeats every `period` seconds.
    func phase(_ period: Double, offset: Double = 0) -> Double {
      let x = (t + offset) / period
      return x - x.rounded(.down)
    }

    var top: Double { center.y - halfHeight }

    /// A point `x` radii right of center and `y` radii below `top`.
    func onTop(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: center.x + x * radius, y: top + y * radius) }

    /// Costume colours, a little quieter on the dark canvas, like the character's moss green.
    func fill(_ color: EnigmaColor) -> Color {
      palette.characterInk.relativeLuminance > 0.5 ? color.mixed(with: palette.background, amount: 0.18).color : color.color
    }

    func outline(_ path: Path, in context: inout GraphicsContext, width: Double = 0.9) {
      context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line * width, lineCap: .round, lineJoin: .round))
    }
  }

  private static let red = EnigmaColor(hex: 0xC4553E)
  private static let blue = EnigmaColor(hex: 0x3F6B8E)
  private static let cream = EnigmaColor(hex: 0xF2E8D5)
  private static let canopy = EnigmaColor(hex: 0x3E78A8)
  private static let canopyLight = EnigmaColor(hex: 0x6A9CC6)
  private static let night = EnigmaColor(hex: 0x5D6FA6)
  private static let nightLight = EnigmaColor(hex: 0x8191C4)
  private static let lens = EnigmaColor(hex: 0x1E2126)
  private static let sheet = EnigmaColor(hex: 0xFAF7F0)

  // MARK: Sunglasses

  /// One pair of shades over the porthole, which peeks through at the bridge.
  private static func drawSunglasses(_ f: Figure, in context: inout GraphicsContext) {
    let r = f.radius, c = f.hole
    let half = 0.8 * r, top = c.y - 0.3 * r, depth = 0.52 * r
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * r, y: top + y * r) }
    var frame = Path()
    frame.move(to: CGPoint(x: c.x - half - 0.2 * r, y: top - 0.06 * r))
    frame.addLine(to: CGPoint(x: c.x - half, y: top + 0.02 * r))
    frame.move(to: CGPoint(x: c.x + half + 0.2 * r, y: top - 0.06 * r))
    frame.addLine(to: CGPoint(x: c.x + half, y: top + 0.02 * r))
    f.outline(frame, in: &context)

    var lenses = Path()
    lenses.move(to: CGPoint(x: c.x - half, y: top))
    lenses.addLine(to: CGPoint(x: c.x + half, y: top))
    lenses.addQuadCurve(to: p(0.45, depth / r), control: CGPoint(x: c.x + half, y: top + depth))
    lenses.addQuadCurve(to: p(0.08, 0.13), control: p(0.1, depth / r))
    lenses.addLine(to: p(-0.08, 0.13))
    lenses.addQuadCurve(to: p(-0.45, depth / r), control: p(-0.1, depth / r))
    lenses.addQuadCurve(to: CGPoint(x: c.x - half, y: top), control: CGPoint(x: c.x - half, y: top + depth))
    lenses.closeSubpath()
    context.fill(lenses, with: .color(lens.color))
    var glints = Path()
    for side in [-1.0, 1] {
      glints.move(to: p(side * 0.62, 0.12))
      glints.addLine(to: p(side * 0.5, 0.3))
    }
    context.stroke(glints, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: f.line * 0.75, lineCap: .round))
    if f.moving {
      let sweep = f.phase(4) / 0.18  // the glint crosses in the first 0.7 s of every 4
      if sweep < 1 {
        var shine = context
        shine.clip(to: lenses)
        let x = c.x - half - 0.3 * r + sweep * (2 * half + 0.6 * r)
        var band = Path()
        band.move(to: CGPoint(x: x, y: top - 0.1 * r))
        band.addLine(to: CGPoint(x: x + 0.22 * r, y: top - 0.1 * r))
        band.addLine(to: CGPoint(x: x - 0.05 * r, y: top + depth + 0.1 * r))
        band.addLine(to: CGPoint(x: x - 0.27 * r, y: top + depth + 0.1 * r))
        band.closeSubpath()
        shine.fill(band, with: .color(.white.opacity(0.55)))
      }
    }
    f.outline(lenses, in: &context)
  }

  // MARK: Umbrella

  /// An umbrella balanced on the antenna: the antenna is its handle. In a storm it's blown
  /// inside out and tilts with the wind.
  private static func drawUmbrella(_ f: Figure, insideOut: Bool, in context: inout GraphicsContext) {
    let r = f.radius, tip = f.tip
    let base = tip.y - 0.35 * r, apex = tip.y - 1.08 * r, half = 1.3 * r
    var canopy = Path()
    canopy.move(to: CGPoint(x: tip.x - half, y: base))
    canopy.addCurve(to: CGPoint(x: tip.x, y: apex), control1: CGPoint(x: tip.x - half * 0.98, y: base - 0.55 * r),
                    control2: CGPoint(x: tip.x - half * 0.5, y: apex))
    canopy.addCurve(to: CGPoint(x: tip.x + half, y: base), control1: CGPoint(x: tip.x + half * 0.5, y: apex),
                    control2: CGPoint(x: tip.x + half * 0.98, y: base - 0.55 * r))
    let scallops = 4
    var ribEnds: [CGPoint] = [CGPoint(x: tip.x + half, y: base)]
    for index in 1...scallops {
      let x = tip.x + half - 2 * half * Double(index) / Double(scallops)
      let previous = tip.x + half - 2 * half * Double(index - 1) / Double(scallops)
      canopy.addQuadCurve(to: CGPoint(x: x, y: base), control: CGPoint(x: (x + previous) / 2, y: base - 0.2 * r))
      ribEnds.append(CGPoint(x: x, y: base))
    }
    canopy.closeSubpath()
    var ribs = Path()
    for end in ribEnds.dropFirst().dropLast() {
      ribs.move(to: CGPoint(x: tip.x, y: apex))
      ribs.addQuadCurve(to: end, control: CGPoint(x: (tip.x + end.x) / 2, y: apex + 0.05 * r))
    }
    // Alternate panels in the lighter blue, between every other pair of ribs.
    var panels = Path()
    for index in stride(from: 0, to: ribEnds.count - 1, by: 2) {
      panels.move(to: CGPoint(x: tip.x, y: apex))
      panels.addLine(to: ribEnds[index])
      panels.addLine(to: ribEnds[index + 1])
      panels.closeSubpath()
    }
    var shaft = Path()
    shaft.move(to: CGPoint(x: tip.x, y: apex - 0.16 * r))
    shaft.addLine(to: CGPoint(x: tip.x, y: tip.y - f.tipRadius))

    var layer = context
    let flip = insideOut
      ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * tip.y - 1.55 * r)
      : .identity
    let tilt = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: (insideOut ? 0.36 : -0.18)
      + (f.moving ? (insideOut ? sin(f.t * 5.2) * 0.09 + sin(f.t * 11.5) * 0.03 : sin(f.t * 1.3) * 0.06) : 0))
      .translatedBy(x: -tip.x, y: -tip.y)
    let place = flip.concatenating(tilt)
    let shape = canopy.applying(place)
    f.outline(shaft.applying(tilt), in: &layer, width: 0.85)
    layer.fill(shape, with: .color(f.fill(canopyLight)))
    var shaded = layer
    shaded.clip(to: shape)
    shaded.fill(panels.applying(place), with: .color(f.fill(Self.canopy)))
    layer.stroke(ribs.applying(place), with: .color(f.ink.opacity(0.5)), lineWidth: f.line * 0.55)
    f.outline(shape, in: &layer)
    // The antenna ball over the shaft, so the umbrella reads as held.
    layer.fill(f.antennaBall, with: .color(EnigmaCharacterRenderer.bodyColor(for: .empty, palette: f.palette).color))
    layer.stroke(f.antennaBall, with: .color(f.ink), lineWidth: f.line * 0.9)

    if insideOut {
      var gusts = Path()
      for (dx, dy, length) in [(-1.75, -1.3, 0.55), (-1.95, -0.95, 0.75), (-1.7, -0.6, 0.45)] {
        let slide = f.moving ? f.phase(0.9, offset: dy) * 0.5 * r : 0
        let start = CGPoint(x: f.center.x + dx * r + slide, y: f.center.y + dy * r)
        gusts.move(to: start)
        gusts.addLine(to: CGPoint(x: start.x + length * r, y: start.y))
      }
      context.stroke(gusts, with: .color(f.ink.opacity(0.55)), style: StrokeStyle(lineWidth: f.line * 0.8, lineCap: .round))
    } else {
      // Two drops running off the canopy's edges.
      for (point, size) in [(CGPoint(x: -1.3, y: 0.32), 0.13), (CGPoint(x: 1.12, y: 0.52), 0.1)] {
        let anchor = CGPoint(x: tip.x - half, y: base).applying(tilt)
        let right = CGPoint(x: tip.x + half, y: base).applying(tilt)
        let origin = point.x < 0 ? anchor : right
        // Each drop gathers on the edge, falls and fades, then another forms.
        let fall = f.moving ? f.phase(1.4, offset: point.x) : 0.25
        let center = CGPoint(x: origin.x + (point.x < 0 ? -0.02 : 0.02) * r,
                             y: origin.y + (0.1 + fall * 1.1) * r)
        var dripping = context
        dripping.opacity = f.moving ? min(1, (1 - fall) * 2.5) * min(1, fall * 8) : 1
        dripping.fill(drop(at: center, size: size * r * (f.moving ? 0.6 + 0.4 * min(1, fall * 4) : 1)),
                      with: .color(WeatherSky.rainBlue.color))
      }
    }
  }

  private static func drop(at center: CGPoint, size: Double) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: center.x, y: center.y - size * 1.6))
    path.addQuadCurve(to: CGPoint(x: center.x + size, y: center.y + size * 0.2), control: CGPoint(x: center.x + size, y: center.y - size * 0.4))
    path.addArc(center: CGPoint(x: center.x, y: center.y + size * 0.2), radius: size, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - size * 1.6), control: CGPoint(x: center.x - size, y: center.y - size * 0.4))
    return path
  }

  // MARK: Hats and scarves

  /// A knitted hat with a ribbed brim and a stripe; the antenna ball pokes out of the top as its bobble.
  private static func drawWoollyHat(_ f: Figure, in context: inout GraphicsContext) {
    let r = f.radius
    var dome = Path()
    dome.move(to: f.onTop(-0.9, 0.42))
    dome.addCurve(to: f.onTop(0, -0.4), control1: f.onTop(-0.94, -0.06), control2: f.onTop(-0.52, -0.4))
    dome.addCurve(to: f.onTop(0.9, 0.42), control1: f.onTop(0.52, -0.4), control2: f.onTop(0.94, -0.06))
    dome.closeSubpath()
    context.fill(dome, with: .color(f.fill(red)))
    var stripe = context
    stripe.clip(to: dome)
    stripe.fill(Path(CGRect(x: f.center.x - r, y: f.top - 0.04 * r, width: 2 * r, height: 0.13 * r)), with: .color(f.fill(cream)))
    f.outline(dome, in: &context)
    let brim = Path(roundedRect: CGRect(x: f.center.x - 0.98 * r, y: f.top + 0.3 * r, width: 1.96 * r, height: 0.3 * r),
                    cornerRadius: 0.15 * r)
    context.fill(brim, with: .color(f.fill(red.mixed(with: .init(hex: 0x000000), amount: 0.12))))
    var ribs = Path()
    var x = -0.84
    while x < 0.9 {
      ribs.move(to: CGPoint(x: f.center.x + x * r, y: f.top + 0.36 * r))
      ribs.addLine(to: CGPoint(x: f.center.x + x * r, y: f.top + 0.54 * r))
      x += 0.14
    }
    context.stroke(ribs, with: .color(f.ink.opacity(0.35)), style: StrokeStyle(lineWidth: f.line * 0.5, lineCap: .round))
    f.outline(brim, in: &context)
  }

  /// A scarf wrapped under the porthole, its end hanging down one side with a fringe.
  private static func drawScarf(_ f: Figure, color: EnigmaColor, in context: inout GraphicsContext) {
    let r = f.radius, c = f.center
    let bandTop = c.y + 0.3 * r, bandHeight = 0.28 * r
    let band = Path(CGRect(x: c.x - 1.2 * r, y: bandTop, width: 2.4 * r, height: bandHeight))
    var wrapped = context
    wrapped.clip(to: f.body)
    wrapped.fill(band, with: .color(f.fill(color)))
    var edges = Path()
    edges.move(to: CGPoint(x: c.x - 1.2 * r, y: bandTop))
    edges.addLine(to: CGPoint(x: c.x + 1.2 * r, y: bandTop))
    edges.move(to: CGPoint(x: c.x - 1.2 * r, y: bandTop + bandHeight))
    edges.addLine(to: CGPoint(x: c.x + 1.2 * r, y: bandTop + bandHeight))
    f.outline(edges, in: &wrapped, width: 0.8)

    var tail = Path()
    let top = CGPoint(x: c.x + 0.34 * r, y: bandTop + bandHeight * 0.4)
    let flutter = f.moving ? sin(f.t * 2.4) * 0.14 + sin(f.t * 5.3) * 0.05 : 0
    var context = context
    context.translateBy(x: top.x, y: top.y)
    context.rotate(by: .radians(flutter))
    context.translateBy(x: -top.x, y: -top.y)
    tail.move(to: top)
    tail.addLine(to: CGPoint(x: top.x + 0.27 * r, y: top.y))
    tail.addLine(to: CGPoint(x: top.x + 0.4 * r, y: top.y + 0.62 * r))
    tail.addLine(to: CGPoint(x: top.x + 0.12 * r, y: top.y + 0.66 * r))
    tail.closeSubpath()
    context.fill(tail, with: .color(f.fill(color)))
    var stripes = context
    stripes.clip(to: tail)
    for y in [0.2, 0.36] {
      stripes.fill(Path(CGRect(x: top.x - 0.2 * r, y: top.y + y * r, width: r, height: 0.06 * r)), with: .color(f.fill(cream)))
    }
    f.outline(tail, in: &context, width: 0.8)
    var fringe = Path()
    for step in 0..<4 {
      let t = Double(step) / 3
      let start = CGPoint(x: top.x + (0.12 + 0.28 * t) * r, y: top.y + (0.66 - 0.04 * t) * r)
      fringe.move(to: start)
      fringe.addLine(to: CGPoint(x: start.x + 0.02 * r, y: start.y + 0.14 * r))
    }
    context.stroke(fringe, with: .color(f.ink), style: StrokeStyle(lineWidth: f.line * 0.6, lineCap: .round))
  }

  /// A floppy striped nightcap for clear nights, its pompom hanging to one side.
  private static func drawNightcap(_ f: Figure, in context: inout GraphicsContext) {
    let r = f.radius
    let swing = f.moving ? sin(f.t * 1.1) : 0
    let tip = f.onTop(1.22 + swing * 0.07, -0.3 + abs(swing) * 0.05)
    var cap = Path()
    cap.move(to: f.onTop(-0.86, 0.32))
    cap.addCurve(to: f.onTop(0.18, -0.98), control1: f.onTop(-0.82, -0.42), control2: f.onTop(-0.32, -0.98))
    cap.addCurve(to: tip, control1: f.onTop(0.66, -0.98), control2: f.onTop(1.08, -0.66))
    cap.addCurve(to: f.onTop(0.86, 0.32), control1: f.onTop(0.98, -0.3), control2: f.onTop(0.8, -0.38))
    cap.closeSubpath()
    context.fill(cap, with: .color(f.fill(night)))
    var stripes = context
    stripes.clip(to: cap)
    for offset in [-0.62, -0.18] {
      var band = Path()
      band.move(to: f.onTop(-1.2, offset + 0.1))
      band.addLine(to: f.onTop(1.6, offset - 0.55))
      band.addLine(to: f.onTop(1.6, offset - 0.37))
      band.addLine(to: f.onTop(-1.2, offset + 0.28))
      band.closeSubpath()
      stripes.fill(band, with: .color(f.fill(nightLight)))
    }
    f.outline(cap, in: &context)
    let brim = Path(roundedRect: CGRect(x: f.center.x - 0.94 * r, y: f.top + 0.16 * r, width: 1.88 * r, height: 0.3 * r),
                    cornerRadius: 0.15 * r)
    context.fill(brim, with: .color(f.fill(cream)))
    f.outline(brim, in: &context)
    let pompom = Path(ellipseIn: CGRect(x: tip.x - 0.2 * r, y: tip.y - 0.2 * r, width: 0.4 * r, height: 0.4 * r))
    context.fill(pompom, with: .color(f.fill(cream)))
    f.outline(pompom, in: &context)
    // Sleepy z's drifting up from the cap.
    guard f.moving else { return }
    for index in 0..<2 {
      let rise = f.phase(3.2, offset: Double(index) * 1.6)
      var z = context
      z.opacity = sin(rise * .pi)
      let point = f.onTop(-0.75 - rise * 0.35, -0.2 - rise * 0.9)
      z.draw(Text("z").font(.system(size: max(6, r * (0.42 + rise * 0.25)), weight: .semibold, design: .rounded))
        .foregroundStyle(f.ink), at: point)
    }
  }

  // MARK: Ghost sheet

  /// A bedsheet thrown over the whole body, its feet and antenna ball poking out, with two eye
  /// holes either side of the porthole, dark on either canvas.
  private static func drawGhostSheet(_ f: Figure, in context: inout GraphicsContext) {
    let r = f.radius
    let box = CGRect(x: f.center.x - 1.15 * r, y: f.top - 0.2 * r, width: 2.3 * r, height: 2 * f.halfHeight + 0.3 * r)
    let sheet = GhostShape.sheet(in: box)
    context.fill(sheet, with: .color(f.fill(Self.sheet)))
    f.outline(sheet, in: &context)
    let eyeWidth = 0.24 * r, eyeHeight = 0.34 * r
    for side in [-1.0, 1] {
      let eye = CGRect(x: f.hole.x + side * 0.36 * r - eyeWidth / 2, y: f.hole.y - eyeHeight / 2,
                       width: eyeWidth, height: eyeHeight)
      context.fill(Path(ellipseIn: eye), with: .color(lens.color))
    }
  }
}

/// A little bedsheet ghost: a dome with a wavy hem and two eye holes, cut out even-odd. The ghost
/// button's glyph (F10), and the sheet the character wears in a temporary chat.
struct GhostShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Self.sheet(in: rect)
    for x in [0.33, 0.67] {
      path.addEllipse(in: CGRect(x: rect.minX + (x - 0.08) * rect.width, y: rect.minY + 0.3 * rect.height,
                                 width: 0.16 * rect.width, height: 0.22 * rect.height))
    }
    return path
  }

  /// The sheet alone, filling `rect`: a round top and three scallops along the hem.
  static func sheet(in rect: CGRect) -> Path {
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
    var path = Path()
    path.move(to: p(0, 0.88))
    path.addLine(to: p(0, 0.45))
    path.addCurve(to: p(0.5, 0), control1: p(0, 0.15), control2: p(0.22, 0))
    path.addCurve(to: p(1, 0.45), control1: p(0.78, 0), control2: p(1, 0.15))
    path.addLine(to: p(1, 0.88))
    for step in 1...3 {
      let x = 1 - Double(step) / 3
      path.addQuadCurve(to: p(x, 0.88), control: p(x + 1.0 / 6, 1.08))
    }
    path.closeSubpath()
    return path
  }
}
