import SwiftUI

/// F36 prototype: the weather card's illustrated sky, flat like the character: solid colour,
/// outlined shapes and two hills along the bottom. The sky keeps its own colours in Paper and
/// Ink. Rain, snow and drifting clouds fade out over the card's text column so the figures
/// stay readable.
enum WeatherSky {
  struct Colors {
    let top: EnigmaColor
    let text: EnigmaColor
    let cloud: EnigmaColor
    let isDark: Bool
    var hillBack: EnigmaColor { top.mixed(with: isDark ? .black : .white, amount: isDark ? 0.22 : 0.26) }
    var hillFront: EnigmaColor { top.mixed(with: isDark ? .black : .white, amount: isDark ? 0.36 : 0.44) }
    var cloudShade: EnigmaColor { cloud.mixed(with: top, amount: isDark ? 0.3 : 0.2) }
    var drop: EnigmaColor { isDark ? EnigmaColor(hex: 0xA9BCD2) : EnigmaColor(hex: 0x2C4966) }
  }

  /// The hills' band at the bottom of the header, which text keeps clear of.
  static let groundHeight: CGFloat = 26
  static let rainBlue = EnigmaColor(hex: 0x3C78AD)
  static let sunYellow = EnigmaColor(hex: 0xE3A92B)

  static func colors(for sky: WeatherCardModel.Sky, light: WeatherCardModel.Light) -> Colors {
    // (sky, text, cloud) for day, twilight and night.
    let table: [(UInt32, UInt32, UInt32)] = switch sky {
    case .clear, .partlyCloudy: [(0x7DB7E0, 0x10273C, 0xFFFFFF), (0xE59A66, 0x3A2111, 0xFCE6D6), (0x131B33, 0xE9ECF5, 0x46527A)]
    case .overcast: [(0xA1ABB3, 0x1A2128, 0xE2E6E9), (0xB4A196, 0x281D16, 0xE6D9CF), (0x21262D, 0xE6E9EE, 0x474F5A)]
    case .fog: [(0xBFC6CB, 0x1F262C, 0xF4F6F7), (0xCDBCAE, 0x2B221B, 0xF6F0EA), (0x292E34, 0xE6E9EE, 0x6A727C)]
    case .rain: [(0x7C8A97, 0x0E151C, 0xC3CBD2), (0x958174, 0x1C130E, 0xC9B8AC), (0x191F28, 0xE3E7EC, 0x3B4451)]
    case .snow: [(0xD3DCE4, 0x1A2733, 0xFFFFFF), (0xE3CFC1, 0x2D2118, 0xFFF5EE), (0x2A3445, 0xEEF2F7, 0x536079)]
    case .storm: [(0x343949, 0xEFF0F4, 0x5B6273), (0x47383C, 0xF5EFEF, 0x685860), (0x14171F, 0xECEEF2, 0x333946)]
    }
    let row = switch light { case .day: table[0]; case .twilight: table[1]; case .night: table[2] }
    return Colors(top: EnigmaColor(hex: row.0), text: EnigmaColor(hex: row.1), cloud: EnigmaColor(hex: row.2),
                  isDark: light == .night || sky == .storm)
  }

  // MARK: Drawing

  private static let lightningPeriod = 11.0

  static func draw(_ model: WeatherCardModel, at t: Double, animated: Bool, in size: CGSize,
                   context g: inout GraphicsContext) {
    let width = size.width, height = size.height
    guard width > 0, height > 0 else { return }
    let sky = model.sky, colors = colors(for: sky, light: model.light)
    let ink = colors.text.color
    let scale = min(1, max(0.55, height / 160))
    var random = EnigmaCharacterRandom(seed: FNV1a64.hash(model.place + model.caption))
    func fade(_ x: Double) -> Double { min(1, max(0, (x - width * 0.42) / (width * 0.14))) }

    g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.top.color))
    if model.light == .twilight { twilightBands(&g, width: width, height: height, colors: colors, clear: sky.isOpen) }

    let stars = (0..<54).map { _ in (x: random.unit(), y: random.unit(), r: 0.5 + random.unit() * 1.1,
                                     rate: 0.6 + random.unit() * 1.4, phase: random.unit() * 6.28) }
    if sky.isOpen, model.light == .night {
      for star in stars {
        let alpha = animated ? 0.35 + 0.65 * (0.5 + 0.5 * sin(t * star.rate + star.phase)) : 0.8
        let center = CGPoint(x: star.x * width, y: star.y * (height - groundHeight) * 0.9)
        var layer = g
        layer.opacity = alpha
        layer.fill(star.r > 1.35 ? sparkle(center, radius: star.r * 2.4) : circle(center, star.r),
                   with: .color(EnigmaColor(hex: 0xFFF4D6).color))
      }
    }
    if sky.isOpen {
      switch model.light {
      case .night: moon(&g, center: CGPoint(x: width - 64 * scale, y: 46 * scale), radius: 15 * scale, ink: ink)
      case .twilight:
        sun(&g, center: CGPoint(x: width - 92 * scale, y: height - groundHeight - 2), radius: 30 * scale, t: t,
            color: EnigmaColor(hex: 0xF39A3A), ink: ink, rays: false)
      case .day:
        sun(&g, center: CGPoint(x: width - 64 * scale, y: 52 * scale), radius: 19 * scale, t: t,
            color: EnigmaColor(hex: 0xF6C443), ink: ink, rays: true)
      }
    }

    // Lightning comes from under the clouds, so it's drawn before them; its flash goes over everything.
    var flash = 0.0
    if sky == .storm, animated, let strike = strike(at: t, seed: model.place) {
      flash = strike.flash
      if strike.showsBolt { bolt(&g, seed: strike.seed, width: width, height: height, ink: ink) }
    }

    let clouds = (0..<6).map { _ in (x: random.unit(), y: random.unit(), size: random.unit(), speed: random.unit()) }
    let layout = sky.cloudLayout(code: model.code)
    for cloud in clouds.prefix(layout.count) {
      let unit = 22 * scale * (layout.sizes.lowerBound + (layout.sizes.upperBound - layout.sizes.lowerBound) * cloud.size)
      // Clouds drift across the right side only, appearing beside the text and leaving off the edge.
      let zone = width * 0.46, span = width - zone + 3.5 * unit
      let x = zone + (cloud.x * span + (2 + cloud.speed * 4) * t).truncatingRemainder(dividingBy: span) - unit
      let y = height * (layout.heights.lowerBound + (layout.heights.upperBound - layout.heights.lowerBound) * cloud.y)
        + unit * 0.6
      // One layer, so a fading cloud doesn't show its puffs' inner outlines.
      var faded = g
      faded.opacity = min(1, (x - zone + unit) / (1.6 * unit))
      faded.drawLayer { layer in drawCloud(&layer, at: CGPoint(x: x, y: y), unit: unit, colors: colors) }
    }

    let banks = (0..<5).map { _ in (x: random.unit(), width: 0.3 + random.unit() * 0.35, speed: 0.5 + random.unit()) }
    if sky == .fog {
      for (index, bank) in banks.enumerated() {
        let bankWidth = bank.width * width, span = width + bankWidth
        let x = (bank.x * span + bank.speed * 5 * t).truncatingRemainder(dividingBy: span) - bankWidth
        let alpha = fade(x + bankWidth / 2)
        guard alpha > 0 else { continue }
        var layer = g
        layer.opacity = (colors.isDark ? 0.3 : 0.62) * alpha
        layer.fill(Path(roundedRect: CGRect(x: x, y: height * (0.3 + Double(index) * 0.12), width: bankWidth,
                                            height: 8 * scale), cornerRadius: 4 * scale),
                   with: .color(colors.cloud.color))
      }
    }

    hill(&g, width: width, height: height, base: height - 22 * scale, amplitude: 7, frequency: 0.0105, phase: 1.3,
         fill: colors.hillBack, ink: ink)
    hill(&g, width: width, height: height, base: height - 9 * scale, amplitude: 5, frequency: 0.0145, phase: 4.1,
         fill: colors.hillFront, ink: ink)

    let top = height * 0.24, span = height - top + 24, crowd = min(1.4, width / 560)
    let intensity = WeatherCardModel.intensity(forCode: model.code)
    let drops = (0..<150).map { _ in (x: random.unit(), y: random.unit(), length: 7 + random.unit() * 6,
                                      speed: 0.85 + random.unit() * 0.4) }
    if sky == .rain || sky == .storm {
      var full = Path(), faint = Path()
      for drop in drops.prefix(min(150, Int(60 * intensity * crowd))) {
        let y = top - 12 + (drop.y * span + drop.speed * 130 * t).truncatingRemainder(dividingBy: span)
        let x = drop.x * (width + 30) - (y - top) * 0.18
        let alpha = fade(x)
        guard alpha > 0 else { continue }
        let start = CGPoint(x: x, y: y), end = CGPoint(x: x - drop.length * 0.2, y: y + drop.length)
        if alpha < 1 { faint.move(to: start); faint.addLine(to: end) } else { full.move(to: start); full.addLine(to: end) }
      }
      let style = StrokeStyle(lineWidth: 1.3, lineCap: .round)
      g.stroke(full, with: .color(colors.drop.color.opacity(0.75)), style: style)
      g.stroke(faint, with: .color(colors.drop.color.opacity(0.3)), style: style)
    }
    let flakes = (0..<130).map { _ in (x: random.unit(), y: random.unit(), r: 1.1 + random.unit() * 1.7,
                                       speed: 0.6 + random.unit() * 0.7, phase: random.unit() * 6.28) }
    if sky == .snow {
      for flake in flakes.prefix(min(130, Int(48 * intensity * crowd))) {
        let y = top - 6 + (flake.y * span + flake.speed * 16 * t).truncatingRemainder(dividingBy: span)
        let x = flake.x * width + sin(t * 0.9 + flake.phase) * 5
        let alpha = fade(x)
        guard alpha > 0 else { continue }
        var layer = g
        layer.opacity = alpha
        let dot = circle(CGPoint(x: x, y: y), flake.r)
        layer.fill(dot, with: .color(.white))
        layer.stroke(dot, with: .color(ink.opacity(0.45)), lineWidth: 0.8)
      }
    }
    if flash > 0 { g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.14 * flash))) }
  }

  /// A moment when a storm card shows a bolt, for snapshots.
  static func strikeTime(for model: WeatherCardModel) -> Double {
    var t = 0.0
    while t < 200 {
      if let strike = strike(at: t, seed: model.place), strike.showsBolt, strike.flash > 0.6 { return t }
      t += 0.01
    }
    return 0
  }

  /// Lightning at most once per 11 s, a dim flash (at most 14% brighter) with one flicker, so
  /// it stays calm and safe for people sensitive to flashing.
  private static func strike(at t: Double, seed: String) -> (flash: Double, showsBolt: Bool, seed: Int)? {
    let salt = Double(FNV1a64.hash(seed) % 997)
    let shifted = t + salt.truncatingRemainder(dividingBy: lightningPeriod)
    let cycle = (shifted / lightningPeriod).rounded(.down)
    let phase = shifted - cycle * lightningPeriod - (1 + unit(cycle + salt) * 5)
    guard phase >= 0, phase < 0.7 else { return nil }
    let flash = max(phase < 0.05 ? phase / 0.05 : exp(-(phase - 0.05) * 7), phase > 0.22 && phase < 0.32 ? 0.55 : 0)
    return (flash, phase < 0.14 || (phase > 0.22 && phase < 0.3), Int(cycle + salt))
  }

  private static func unit(_ n: Double) -> Double {
    let x = sin(n * 12.9898) * 43_758.5453
    return x - x.rounded(.down)
  }

  private static func circle(_ center: CGPoint, _ radius: Double) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }

  /// A four-pointed twinkle for the brightest stars.
  private static func sparkle(_ center: CGPoint, radius: Double) -> Path {
    var path = Path()
    let waist = radius * 0.22
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - waist, y: center.y - waist))
    return path
  }

  /// Two flat bands of warm light low in the sky, like a printed sunset.
  private static func twilightBands(_ g: inout GraphicsContext, width: Double, height: Double, colors: Colors,
                                    clear: Bool) {
    let glow = EnigmaColor(hex: 0xF8D9A8)
    for (start, amount) in [(0.5, clear ? 0.3 : 0.16), (0.68, clear ? 0.58 : 0.3)] {
      g.fill(Path(CGRect(x: 0, y: height * start, width: width, height: height * (1 - start))),
             with: .color(colors.top.mixed(with: glow, amount: amount).color))
    }
  }

  private static func sun(_ g: inout GraphicsContext, center: CGPoint, radius: Double, t: Double, color: EnigmaColor,
                          ink: Color, rays: Bool) {
    let line = max(1.3, radius * 0.08)
    if rays {
      var path = Path()
      let turn = t * 0.08
      for index in 0..<10 {
        let angle = turn + Double(index) * .pi / 5
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let inner = radius + radius * 0.3, outer = radius + radius * 0.62
        path.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
        path.addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
      }
      g.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
    }
    let disc = circle(center, radius)
    g.fill(disc, with: .color(color.color))
    // A lighter crescent of light along the top left, as on the character's flat shading.
    var shine = g
    shine.clip(to: disc)
    shine.fill(circle(CGPoint(x: center.x - radius * 0.28, y: center.y - radius * 0.3), radius * 0.62),
               with: .color(color.mixed(with: .white, amount: 0.32).color))
    g.stroke(disc, with: .color(ink), lineWidth: line)
  }

  private static func moon(_ g: inout GraphicsContext, center: CGPoint, radius: Double, ink: Color) {
    let crescent = circle(center, radius)
      .subtracting(circle(CGPoint(x: center.x + radius * 0.52, y: center.y - radius * 0.32), radius * 0.9))
    g.fill(crescent, with: .color(EnigmaColor(hex: 0xF2E6BE).color))
    g.stroke(crescent, with: .color(ink), style: StrokeStyle(lineWidth: max(1.3, radius * 0.1), lineJoin: .round))
  }

  private static let puffs: [(Double, Double, Double)] = [(-1.05, 0.1, 0.55), (-0.45, -0.28, 0.72), (0.3, -0.4, 0.82),
                                                          (0.95, -0.02, 0.6), (0.1, 0.12, 0.7)]

  private static func drawCloud(_ g: inout GraphicsContext, at point: CGPoint, unit: Double, colors: Colors) {
    var shape = Path()
    for (dx, dy, r) in puffs { shape.addPath(circle(CGPoint(x: point.x + dx * unit, y: point.y + dy * unit), r * unit)) }
    shape.addRoundedRect(in: CGRect(x: point.x - 1.05 * unit, y: point.y + 0.05 * unit, width: 2 * unit, height: 0.6 * unit),
                         cornerSize: CGSize(width: 0.3 * unit, height: 0.3 * unit))
    // Stroking every puff at double width, then filling them all, leaves one outline round the union.
    g.stroke(shape, with: .color(colors.text.color), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
    g.fill(shape, with: .color(colors.cloud.color))
    var underside = g
    underside.clip(to: shape)
    underside.fill(Path(CGRect(x: point.x - 2 * unit, y: point.y + 0.3 * unit, width: 4 * unit, height: unit)),
                   with: .color(colors.cloudShade.color))
  }

  private static func hill(_ g: inout GraphicsContext, width: Double, height: Double, base: Double, amplitude: Double,
                           frequency: Double, phase: Double, fill: EnigmaColor, ink: Color) {
    var ridge = Path()
    var x = 0.0
    while x <= width + 6 {
      let y = base + sin(x * frequency + phase) * amplitude + sin(x * frequency * 2.3 + phase * 1.7) * amplitude * 0.4
      if x == 0 { ridge.move(to: CGPoint(x: x, y: y)) } else { ridge.addLine(to: CGPoint(x: x, y: y)) }
      x += 6
    }
    var land = ridge
    land.addLine(to: CGPoint(x: width + 6, y: height + 2))
    land.addLine(to: CGPoint(x: 0, y: height + 2))
    land.closeSubpath()
    g.fill(land, with: .color(fill.color))
    g.stroke(ridge, with: .color(ink), lineWidth: 1.4)
  }

  private static func bolt(_ g: inout GraphicsContext, seed: Int, width: Double, height: Double, ink: Color) {
    let n = Double(seed)
    var point = CGPoint(x: width * (0.55 + unit(n * 3 + 1) * 0.3), y: height * 0.3)
    var path = Path()
    path.move(to: point)
    for index in 1...5 {
      point = CGPoint(x: point.x + (unit(n * 7 + Double(index)) - 0.5) * 22, y: height * (0.3 + Double(index) * 0.1))
      path.addLine(to: point)
    }
    g.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round))
    g.stroke(path, with: .color(EnigmaColor(hex: 0xFFE27A).color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
  }
}

extension WeatherCardModel.Sky {
  /// Sun or moon showing.
  var isOpen: Bool { self == .clear || self == .partlyCloudy }

  /// How many clouds, how high (fractions of the header) and how big.
  func cloudLayout(code: Int) -> (count: Int, heights: ClosedRange<Double>, sizes: ClosedRange<Double>) {
    switch self {
    case .clear: (code == 1 ? 1 : 0, 0.18...0.5, 0.6...0.9)
    case .partlyCloudy: (3, 0.12...0.5, 0.7...1.05)
    case .overcast: (6, 0...0.34, 0.9...1.35)
    case .fog: (1, 0.05...0.2, 0.8...1)
    case .rain: (5, 0...0.28, 0.95...1.35)
    case .snow: (4, 0...0.28, 0.9...1.25)
    case .storm: (6, 0...0.28, 1...1.5)
    }
  }
}

private extension EnigmaColor {
  static let white = EnigmaColor(hex: 0xFFFFFF)
  static let black = EnigmaColor(hex: 0x000000)
}
