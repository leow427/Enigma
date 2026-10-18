import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// The app's icons: the app icon and the menu bar template drawn from the
/// character, the tool icons, the SF Symbols the new UI uses, and the asset
/// catalog that holds them.
///
/// `testGenerateAppIdentityAssets` redraws the `AppIcon` set and the
/// `SpotlightLogo` template into the catalog named by `ENIGMA_ICON_ASSET_DIR`.
/// `scripts/generate-app-icons.sh` runs it for the repository's catalog.
@MainActor
final class EnigmaIconTests: XCTestCase {
  static let assetDirectoryVariable = "ENIGMA_ICON_ASSET_DIR"

  /// The asset catalog in the checkout, so tests can check the committed files.
  static let sourceCatalog = repositoryRoot.appending(path: "AI-Spotlight/Resources/Assets.xcassets")
  static let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

  /// Every icon asset the app draws as a template.
  static let templateAssets = ["SpotlightLogo", "WebSearch", "ScreenCapture", "MessagesTool", "TemplateAttachment",
                               "FileMode"]
  /// How many pixels a committed icon may differ from a fresh render by more
  /// than 48 of 255. Render noise stays under 0.1% of pixels at 5 of 255; a
  /// 0.1 pt change to the outline moves about 0.2%.
  static let allowedDrift = 0.002

  /// The tool icons: one line family on a 24 pt grid.
  static let toolAssets = ["WebSearch", "ScreenCapture", "MessagesTool", "TemplateAttachment", "FileMode"]

  // MARK: Generator

  func testGenerateAppIdentityAssets() throws {
    guard let path = ProcessInfo.processInfo.environment[Self.assetDirectoryVariable], !path.isEmpty else {
      throw XCTSkip("Set \(Self.assetDirectoryVariable) to an asset catalog to redraw the app icon and menu bar mark.")
    }
    let catalog = URL(filePath: path, directoryHint: .isDirectory)
    let manager = FileManager.default

    let iconSet = catalog.appending(path: "AppIcon.appiconset")
    try manager.createDirectory(at: iconSet, withIntermediateDirectories: true)
    // Only the generator's own files, so a changed size list leaves no orphans.
    for old in try manager.contentsOfDirectory(at: iconSet, includingPropertiesForKeys: nil)
    where old.lastPathComponent.hasPrefix("icon_") && old.pathExtension == "png" {
      try manager.removeItem(at: old)
    }
    for rendition in EnigmaAppIcon.renditions {
      try Self.png(Self.renderAppIcon(rendition)).write(to: iconSet.appending(path: rendition.filename))
    }
    try Self.json(Self.appIconContents).write(to: iconSet.appending(path: "Contents.json"))

    let logo = catalog.appending(path: "SpotlightLogo.imageset")
    try manager.createDirectory(at: logo, withIntermediateDirectories: true)
    for old in try manager.contentsOfDirectory(at: logo, includingPropertiesForKeys: nil) {
      try manager.removeItem(at: old)
    }
    try Self.renderMenuBarPDF().write(to: logo.appending(path: "SpotlightLogo.pdf"))
    try Self.json(Self.logoContents).write(to: logo.appending(path: "Contents.json"))
  }

  // MARK: App icon

  func testAppIconSetIsCompleteAndMatchesTheCharacterDrawing() throws {
    let iconSet = Self.sourceCatalog.appending(path: "AppIcon.appiconset")
    let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: iconSet.appending(path: "Contents.json")))
    let images = try XCTUnwrap((contents as? [String: Any])?["images"] as? [[String: String]])
    let listed = Set(images.map { "\($0["idiom"] ?? "") \($0["size"] ?? "") \($0["scale"] ?? "") \($0["filename"] ?? "")" })
    let expected = Set(EnigmaAppIcon.renditions.map {
      "mac \($0.points)x\($0.points) \($0.scale)x \($0.filename)"
    })
    XCTAssertEqual(listed, expected, "The AppIcon set lists the full macOS set, 16 to 512 pt at 1x and 2x.")
    XCTAssertEqual(EnigmaAppIcon.renditions.count, 10)

    for rendition in EnigmaAppIcon.renditions {
      let file = iconSet.appending(path: rendition.filename)
      let source = try XCTUnwrap(NSImage(contentsOf: file), rendition.filename)
      let committed = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
      XCTAssertEqual(committed.width, rendition.pixels, rendition.filename)
      XCTAssertEqual(committed.height, rendition.pixels, rendition.filename)
      let pixels = try Self.rgba(committed)
      // The corners are clear and the tile's center is opaque, on Apple's grid.
      XCTAssertEqual(pixels.alpha(x: 0, y: 0), 0, rendition.filename)
      XCTAssertEqual(pixels.alpha(x: rendition.pixels / 2, y: rendition.pixels * 15 / 100), 255, rendition.filename)
      let fresh = try Self.rgba(Self.renderAppIcon(rendition))
      XCTAssertLessThan(pixels.differingFraction(from: fresh), Self.allowedDrift,
                        "\(rendition.filename) no longer matches the character. Run scripts/generate-app-icons.sh.")
    }
  }

  func testAppIconIsTheStillCharacterOnAPaperTile() throws {
    let rendition = EnigmaAppIcon.Rendition(points: 512, scale: 1)
    let pixels = try Self.rgba(Self.renderAppIcon(rendition))
    let paper = EnigmaAppIcon.palette.background
    let tile = EnigmaAppIcon.tile(in: CGRect(x: 0, y: 0, width: 512, height: 512))
    // Just inside the tile's top edge, past the corner: the Paper background.
    XCTAssertTrue(pixels.matches(x: 256, y: Int(tile.minY) + 12, paper))
    // The frame drawn is the still pose: no shadow, its body in `characterBody`.
    let frame = EnigmaAppIcon.pose(points: 512)
    XCTAssertEqual(frame.shadowOpacity, 0)
    XCTAssertEqual(frame.holes.count, 1)
    XCTAssertEqual(frame.legs.count, 3, "Large icons keep the three legs.")
    let hole = try XCTUnwrap(frame.holes.first)
    let body = CGPoint(x: hole.center.x, y: hole.center.y - hole.radius * 2.2)
    XCTAssertTrue(pixels.matches(x: Int(body.x), y: Int(body.y), EnigmaAppIcon.palette.characterBody))
    XCTAssertTrue(pixels.matches(x: Int(hole.center.x), y: Int(hole.center.y), paper), "The porthole shows the tile.")
    XCTAssertTrue(tile.insetBy(dx: tile.width * 0.05, dy: tile.height * 0.05).contains(frame.drawnBounds),
                  "The character sits inside the tile with a margin.")
    // Small icons drop the legs and draw a heavier line, as the sidebar mark does.
    let small = EnigmaAppIcon.pose(points: 16)
    XCTAssertTrue(small.legs.isEmpty)
    XCTAssertGreaterThan(small.lineWidth, EnigmaMark.pose(.filled, in: EnigmaAppIcon.markRect(
      inTile: EnigmaAppIcon.tile(in: CGRect(x: 0, y: 0, width: 16, height: 16)), points: 16)).lineWidth)
  }

  // MARK: Menu bar

  func testMenuBarTemplateIsVectorAndMatchesTheCharacterDrawing() throws {
    let file = Self.sourceCatalog.appending(path: "SpotlightLogo.imageset/SpotlightLogo.pdf")
    let data = try Data(contentsOf: file)
    let image = try XCTUnwrap(NSImage(data: data))
    XCTAssertEqual(image.size, NSSize(width: EnigmaAppIcon.menuBarSide, height: EnigmaAppIcon.menuBarSide))
    XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep })
    XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)), "The template holds paths, not a bitmap.")
    let scale = 4
    let committed = try Self.rgba(try XCTUnwrap(Self.rasterize(image, scale: scale)))
    // The fresh drawing goes through the same PDF and rasterizer as the
    // committed file, so only a changed drawing can differ.
    let freshImage = try XCTUnwrap(NSImage(data: Self.renderMenuBarPDF()))
    let fresh = try Self.rgba(try XCTUnwrap(Self.rasterize(freshImage, scale: scale)))
    XCTAssertLessThan(committed.differingFraction(from: fresh), Self.allowedDrift,
                      "SpotlightLogo no longer matches the character. Run scripts/generate-app-icons.sh.")
  }

  func testMenuBarPDFIsTheSameOnEveryRender() throws {
    let first = try Self.renderMenuBarPDF()
    let second = try Self.renderMenuBarPDF()
    XCTAssertEqual(first, second, "Redrawing an unchanged mark must not change the committed file.")
    XCTAssertNotNil(first.range(of: Data("/ID [ <00000000000000000000000000000000>".utf8)), "The random /ID is zeroed.")
    XCTAssertNil(first.range(of: Data("/CreationDate".utf8)))
  }

  func testMenuBarPoseDropsTheLegsAndMatchesTheMenuBarStroke() throws {
    let frame = EnigmaAppIcon.menuBarPose()
    XCTAssertTrue(frame.legs.isEmpty)
    XCTAssertTrue(frame.feet.isEmpty)
    XCTAssertEqual(frame.holes.count, 1)
    XCTAssertEqual(frame.lineWidth, 1.4, accuracy: 0.001)
    let item = CGRect(x: 0, y: 0, width: EnigmaAppIcon.menuBarSide, height: EnigmaAppIcon.menuBarSide)
    XCTAssertTrue(item.contains(frame.drawnBounds))
    XCTAssertGreaterThan(frame.drawnBounds.height, 16, "The mark fills the item's height.")
    // The porthole stays open inside its ring.
    let hole = try XCTUnwrap(frame.holes.first)
    XCTAssertGreaterThan(hole.radius - frame.lineWidth / 2, 0.4)
  }

  func testMenuBarImageIsAnEighteenPointTemplateCopy() throws {
    let image = try XCTUnwrap(MenuBarController.statusImage())
    XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    XCTAssertTrue(image.isTemplate)
    XCTAssertFalse(image === NSImage(named: "SpotlightLogo"), "Resizing the status image leaves the asset alone.")
  }

  // MARK: Asset catalog

  func testTemplateIconsLoadAsVectorTemplates() throws {
    for name in Self.templateAssets {
      let image = try XCTUnwrap(NSImage(named: name), name)
      XCTAssertTrue(image.isTemplate, "\(name) is a template")
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), name)
      let folder = Self.sourceCatalog.appending(path: "\(name).imageset")
      let contents = try XCTUnwrap(try JSONSerialization.jsonObject(
        with: Data(contentsOf: folder.appending(path: "Contents.json"))) as? [String: Any], name)
      let properties = try XCTUnwrap(contents["properties"] as? [String: Any], name)
      XCTAssertEqual(properties["template-rendering-intent"] as? String, "template", name)
      XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, true, name)
      let files = try XCTUnwrap(contents["images"] as? [[String: Any]], name).compactMap { $0["filename"] as? String }
      XCTAssertEqual(files.count, 1, name)
      XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".svg") || $0.hasSuffix(".pdf") }, "\(name) is a vector: \(files)")
    }
  }

  func testToolIconsShareOneLineStyle() throws {
    for name in Self.toolAssets {
      let svg = try String(contentsOf: Self.sourceCatalog.appending(path: "\(name).imageset/\(name).svg"), encoding: .utf8)
      XCTAssertTrue(svg.contains(#"viewBox="0 0 24 24""#), "\(name) is on the 24 pt grid")
      XCTAssertTrue(svg.contains(#"stroke-width="1.75""#), "\(name) uses the family's stroke")
      XCTAssertTrue(svg.contains(#"stroke-linecap="round""#), "\(name) has round caps")
      XCTAssertTrue(svg.contains(#"stroke-linejoin="round""#), "\(name) has round joins")
      XCTAssertTrue(svg.contains(#"fill="none""#), "\(name) is drawn in lines")
      XCTAssertEqual(svg.components(separatedBy: "stroke-width=").count - 1, 1, "\(name) has one stroke weight")
      // Fills are only small dots.
      for element in svg.components(separatedBy: "<").dropFirst() where element.contains(" fill=\"")
        && !element.contains(#"fill="none""#) {
        XCTAssertTrue(element.hasPrefix("circle "), "\(name) fills only dots: <\(element)")
        let radius = Self.attributes(named: "r", in: element).first.flatMap(Double.init) ?? 99
        XCTAssertLessThanOrEqual(radius, 1.25, "\(name) fills only small dots")
      }
      XCTAssertFalse(svg.contains("<image"), "\(name) holds no bitmap")
    }
  }

  func testEveryAssetNameTheAppUsesLoads() throws {
    let sources = try Self.appSources()
    var names = Set(SlashCommand.allCases.compactMap(\.assetImage))
    let patterns = [#"Image\("([A-Za-z0-9]+)"\)"#, #"NSImage\(named: "([A-Za-z0-9]+)"\)"#, #"image: "([A-Za-z0-9]+)""#,
                    #"assetImage: "([A-Za-z0-9]+)""#, #"imageName: "([A-Za-z0-9]+)""#]
    for (_, text) in sources {
      for pattern in patterns {
        let regex = try NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
          if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
        }
      }
    }
    XCTAssertTrue(names.isSuperset(of: ["SpotlightLogo", "MessagesTool", "TemplateAttachment"]), "\(names)")
    for name in names.sorted() {
      let image = try XCTUnwrap(NSImage(named: name), "\(name) is in the asset catalog")
      XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), name)
    }
  }

  func testNewUISymbolsExistAndKeepTheLineStyle() throws {
    let regex = try NSRegularExpression(pattern: #""([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
    var symbols: [String: String] = [:]
    for destination in SettingsView.SettingsDestination.allCases {
      symbols[destination.enigmaSymbol] = "EnigmaSettingsView.swift"
    }
    for (file, text) in try Self.appSources() where file.hasPrefix("Enigma") {
      for line in text.split(separator: "\n") where line.contains("systemName") || line.contains("systemImage") {
        let line = String(line)
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
          if let range = Range(match.range(at: 1), in: line) { symbols[String(line[range])] = file }
        }
      }
    }
    XCTAssertGreaterThan(symbols.count, 15, "\(symbols.keys.sorted())")
    for (symbol, file) in symbols {
      XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) in \(file) exists")
      // Outline glyphs only. The one solid glyph is Stop, on the solid Send button.
      if symbol != "stop.fill" {
        XCTAssertFalse(symbol.hasSuffix(".fill") || symbol.contains(".fill."), "\(symbol) in \(file) is filled")
      }
    }
    // The compact panel's status button keeps one metaphor in both states.
    XCTAssertNotNil(symbols["info.circle"])
    XCTAssertNotNil(symbols["exclamationmark.circle"])
    XCTAssertNil(symbols["exclamationmark.bubble"])
  }

  // MARK: Screenshots

  func testIconSheetScreenshots() throws {
    let sizes: [CGFloat] = [16, 18, 24, 32]
    try EnigmaSnapshot.save("icons", size: CGSize(width: 520, height: 330)) {
      IconSheet(sizes: sizes)
    }
    try EnigmaSnapshot.save("app-icon", size: CGSize(width: 820, height: 580)) {
      AppIconSheet()
    }
    try EnigmaSnapshot.save("menu-bar", size: CGSize(width: 360, height: 112)) {
      MenuBarSheet()
    }
  }

  // MARK: Rendering

  /// The app icon rendition as a bitmap, drawn by the app's own code.
  static func renderAppIcon(_ rendition: EnigmaAppIcon.Rendition) throws -> CGImage {
    let renderer = ImageRenderer(content: EnigmaAppIconView(points: CGFloat(rendition.points),
                                                            scale: CGFloat(rendition.scale)))
    renderer.scale = CGFloat(rendition.scale)
    return try sRGB(try XCTUnwrap(renderer.cgImage))
  }

  /// The menu bar template as a one-page vector PDF of 18 × 18 pt.
  static func renderMenuBarPDF() throws -> Data {
    let renderer = ImageRenderer(content: EnigmaMenuBarMarkView())
    let data = NSMutableData()
    var failed = true
    renderer.render { size, draw in
      var box = CGRect(origin: .zero, size: size)
      guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
      pdf.beginPDFPage(nil)
      draw(pdf)
      pdf.endPDFPage()
      pdf.closePDF()
      failed = false
    }
    XCTAssertFalse(failed)
    return stableDates(in: data as Data)
  }

  /// Blanks the PDF's dates and the macOS build that wrote it, and zeroes the
  /// random document `/ID`, keeping every byte offset, so redrawing an
  /// unchanged mark leaves the file unchanged.
  static func stableDates(in pdf: Data) -> Data {
    var bytes = [UInt8](pdf)
    for key in ["/CreationDate", "/ModDate", "/Producer"] {
      var search = bytes.startIndex
      let pattern = Array(key.utf8)
      while let start = firstIndex(of: pattern, in: bytes, from: search) {
        // The string ends at the first `)` that isn't escaped.
        guard let close = bytes.indices.dropFirst(start).first(where: {
          bytes[$0] == UInt8(ascii: ")") && bytes[$0 - 1] != UInt8(ascii: "\\")
        }) else { break }
        for index in start...close { bytes[index] = UInt8(ascii: " ") }
        search = close
      }
    }
    // The trailer's `/ID [<hex><hex>]`: zero every hex digit inside the array.
    var search = bytes.startIndex
    while let start = firstIndex(of: Array("/ID".utf8), in: bytes, from: search) {
      guard let open = bytes.indices.dropFirst(start).first(where: { bytes[$0] == UInt8(ascii: "[") }),
            let close = bytes.indices.dropFirst(open).first(where: { bytes[$0] == UInt8(ascii: "]") }) else { break }
      var inHex = false
      for index in open...close {
        switch bytes[index] {
        case UInt8(ascii: "<"): inHex = true
        case UInt8(ascii: ">"): inHex = false
        default: if inHex, bytes[index] != UInt8(ascii: " ") { bytes[index] = UInt8(ascii: "0") }
        }
      }
      search = close
    }
    return Data(bytes)
  }

  private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
    guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
    for index in start...(bytes.count - pattern.count) where bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
      return index
    }
    return nil
  }

  static func rasterize(_ image: NSImage, scale: Int) -> CGImage? {
    let rect = NSRect(x: 0, y: 0, width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
  }

  /// The image redrawn into an 8-bit sRGB bitmap, the form the PNGs keep.
  static func sRGB(_ image: CGImage) throws -> CGImage {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return try XCTUnwrap(context.makeImage())
  }

  static func png(_ image: CGImage) throws -> Data {
    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  }

  static func json(_ object: Any) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(contentsOf: Array("\n".utf8))
    return data
  }

  static var appIconContents: [String: Any] {
    ["images": EnigmaAppIcon.renditions.map {
      ["filename": $0.filename, "idiom": "mac", "scale": "\($0.scale)x", "size": "\($0.points)x\($0.points)"]
    }, "info": ["author": "xcode", "version": 1]]
  }

  static var logoContents: [String: Any] {
    ["images": [["filename": "SpotlightLogo.pdf", "idiom": "universal"]],
     "info": ["author": "xcode", "version": 1],
     "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]]
  }

  /// The app's Swift sources by file name.
  static func appSources() throws -> [(String, String)] {
    let root = repositoryRoot.appending(path: "AI-Spotlight")
    let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map {
      ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
    }
  }

  static func attributes(named name: String, in svg: String) -> [String] {
    svg.components(separatedBy: " \(name)=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
  }

  /// An image's pixels as 8-bit premultiplied sRGB, top row first.
  struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    func matches(x: Int, y: Int, _ color: EnigmaColor) -> Bool {
      let offset = (y * width + x) * 4
      let channels = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
      return bytes[offset + 3] == 255 && (0..<3).allSatisfy { abs(Int(bytes[offset + $0]) - channels[$0]) <= 4 }
    }

    /// The share of pixels where some channel differs by more than 48 of 255:
    /// more than antialiasing ever moves an edge, so only a changed drawing counts.
    func differingFraction(from other: Pixels) -> Double {
      guard width == other.width, height == other.height else { return 1 }
      var differing = 0
      for pixel in 0..<(width * height) {
        let offset = pixel * 4
        if (0..<4).contains(where: { abs(Int(bytes[offset + $0]) - Int(other.bytes[offset + $0])) > 48 }) {
          differing += 1
        }
      }
      return Double(differing) / Double(width * height)
    }
  }

  static func rgba(_ image: CGImage) throws -> Pixels {
    let converted = try sRGB(image)
    let data = try XCTUnwrap(converted.dataProvider?.data as Data?)
    var bytes = [UInt8](repeating: 0, count: converted.width * converted.height * 4)
    for row in 0..<converted.height {
      for column in 0..<(converted.width * 4) {
        bytes[row * converted.width * 4 + column] = data[row * converted.bytesPerRow + column]
      }
    }
    return Pixels(width: converted.width, height: converted.height, bytes: bytes)
  }
}

// MARK: Screenshot sheets

/// Every icon the app draws itself, at the sizes it's used, beside the SF
/// Symbols the new UI uses at `.regular`, so the line weights can be compared.
private struct IconSheet: View {
  let sizes: [CGFloat]
  @Environment(\.enigmaPalette) private var palette

  private let assets = ["SpotlightLogo", "WebSearch", "ScreenCapture", "MessagesTool", "TemplateAttachment",
                        "FileMode"]
  private let symbols = ["plus", "gearshape", "questionmark.circle", "sidebar.left", "cloud", "cpu", "xmark",
                         "info.circle"]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(sizes, id: \.self) { size in
        HStack(spacing: 14) {
          Text("\(Int(size))")
            .font(EnigmaTypography.mono(11))
            .foregroundStyle(palette.textTertiary.color)
            .frame(width: 22, alignment: .trailing)
          ForEach(assets, id: \.self) { name in
            Image(name).renderingMode(.template).resizable().scaledToFit()
              .frame(width: size, height: size)
              .frame(width: 32, height: 32)
          }
          Rectangle().fill(palette.hairline.color).frame(width: 1, height: 26)
          ForEach(symbols, id: \.self) { symbol in
            Image(systemName: symbol)
              .font(.system(size: size * 0.8, weight: .regular))
              .frame(width: 30, height: 32)
          }
        }
        .foregroundStyle(palette.textPrimary.color)
      }
      HStack(spacing: 14) {
        Text("mark")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
          .frame(width: 22 + 14 + 32, alignment: .leading)
        ForEach(sizes, id: \.self) { size in
          EnigmaMark(style: .filled).frame(width: size, height: size).frame(width: 32, height: 32)
        }
        ForEach(sizes, id: \.self) { size in
          EnigmaMark(style: .outline).frame(width: size, height: size).frame(width: 32, height: 32)
        }
      }
    }
    .padding(20)
  }
}

/// The app icon at 16, 32, 128, and 512 pt, read from the committed asset files.
private struct AppIconSheet: View {
  var body: some View {
    HStack(alignment: .bottom, spacing: 24) {
      ForEach([16, 32, 128, 512], id: \.self) { points in
        let file = EnigmaIconTests.sourceCatalog.appending(path: "AppIcon.appiconset/icon_\(points)x\(points)@2x.png")
        if let image = NSImage(contentsOf: file) {
          Image(nsImage: image).resizable().frame(width: CGFloat(points), height: CGFloat(points))
        }
      }
    }
    .padding(20)
  }
}

/// The status item's template over a light and a dark menu bar, beside
/// system menu bar glyphs, in the system's own menu bar colors.
private struct MenuBarSheet: View {
  var body: some View {
    VStack(spacing: 16) {
      ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
        MenuBarStrip().environment(\.colorScheme, scheme)
      }
    }
    .padding(20)
  }
}

private struct MenuBarStrip: View {
  var body: some View {
    HStack(spacing: 16) {
      Spacer()
      Image(systemName: "magnifyingglass").font(.system(size: 14))
      if let image = MenuBarController.statusImage() {
        Image(nsImage: image).renderingMode(.template)
      }
      Image(systemName: "wifi").font(.system(size: 14))
      Image(systemName: "switch.2").font(.system(size: 14))
      Text("Sun 18 Oct  13:40").font(.system(size: 13))
    }
    .padding(.horizontal, 12)
    .frame(height: 24)
    .foregroundStyle(.primary)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
