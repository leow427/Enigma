import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// Renders SwiftUI views to PNG files for the UI revamp's screenshots in
/// docs/design/ui-revamp/screenshots/.
///
/// Files are written only when `ENIGMA_SNAPSHOT_DIR` names a folder. Pass it to
/// the test host as `TEST_RUNNER_ENIGMA_SNAPSHOT_DIR`; without it, `save` throws
/// `XCTSkip` and the calling test is skipped.
@MainActor
enum EnigmaSnapshot {
  static let directoryVariable = "ENIGMA_SNAPSHOT_DIR"

  /// The folder screenshots go to. Throws `XCTSkip` when the variable isn't set.
  static func directory() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment[directoryVariable], !path.isEmpty else {
      throw XCTSkip("Set \(directoryVariable) to save screenshots.")
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  /// Renders `content` on the palette's `background`, once in Paper and once in
  /// Ink, at 2x, and writes `<name>-paper.png` and `<name>-ink.png`. The content
  /// reads its colors from the environment's `enigmaPalette`.
  @discardableResult
  static func save<Content: View>(_ name: String, size: CGSize,
                                  @ViewBuilder content: () -> Content) throws -> [URL] {
    let folder = try directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let view = content()
    return try [EnigmaAppearance.paper, .ink].map { appearance in
      let image = try render(SnapshotBackdrop(content: view).enigmaTheme(appearance), size: size)
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      let url = folder.appending(path: "\(name)-\(appearance.rawValue).png")
      try png.write(to: url)
      return url
    }
  }

  /// Like `save`, but each appearance waits, up to `timeout`, until `isSettled`
  /// is true before it is drawn, for views that start work when they appear.
  @discardableResult
  static func save<Content: View>(_ name: String, size: CGSize, timeout: Duration = .seconds(3),
                                  until isSettled: () -> Bool,
                                  @ViewBuilder content: () -> Content) async throws -> [URL] {
    let folder = try directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let view = content()
    var urls: [URL] = []
    for appearance in [EnigmaAppearance.paper, .ink] {
      let host = NSHostingView(rootView: SnapshotBackdrop(content: view).enigmaTheme(appearance))
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                            backing: .buffered, defer: false)
      window.colorSpace = .sRGB
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      let deadline = ContinuousClock.now.advanced(by: timeout)
      repeat {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      } while !isSettled() && ContinuousClock.now < deadline
      let image = try capture(host)
      window.contentView = nil
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      let url = folder.appending(path: "\(name)-\(appearance.rawValue).png")
      try png.write(to: url)
      urls.append(url)
    }
    return urls
  }

  /// Renders `view` at `size` points into an sRGB bitmap with `scale` pixels per point.
  static func render<Content: View>(_ view: Content, size: CGSize, scale: CGFloat = 2) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    // Draw in sRGB, the palette's space, whatever display the test runs on.
    window.colorSpace = .sRGB
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    return try capture(host, scale: scale)
  }

  /// Draws a view that is already in a window into an sRGB bitmap.
  static func capture(_ host: NSView, scale: CGFloat = 2) throws -> NSBitmapImageRep {
    let size = host.bounds.size
    host.layoutSubtreeIfNeeded()
    host.window?.displayIfNeeded()
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
      data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
      bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // A bitmap made from an sRGB image stays sRGB, so the PNG's bytes are the palette's.
    let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    image.size = size
    host.cacheDisplay(in: host.bounds, to: image)
    return image
  }

  /// The sRGB color at `point`, in points, of a bitmap from `render` or `capture`.
  /// It reads the bytes directly, since `colorAt` would label them Generic RGB.
  nonisolated static func pixel(_ image: NSBitmapImageRep, at point: CGPoint) throws -> EnigmaColor {
    let scale = Double(image.pixelsWide) / image.size.width
    let data = try XCTUnwrap(image.bitmapData)
    let offset = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * image.bitsPerPixel / 8
    let channels = (0..<4).map { Double(data[offset + $0]) / 255 }
    // Premultiplied: undo it so translucent pixels compare by color.
    let alpha = channels[3]
    guard alpha > 0 else { return EnigmaColor(red: 0, green: 0, blue: 0, opacity: 0) }
    return EnigmaColor(red: channels[0] / alpha, green: channels[1] / alpha, blue: channels[2] / alpha, opacity: alpha)
  }

  /// Whether `color` is `expected`, to within about five steps of 255 per channel.
  nonisolated static func matches(_ color: EnigmaColor, _ expected: EnigmaColor) -> Bool {
    abs(color.red - expected.red) < 0.02 && abs(color.green - expected.green) < 0.02
      && abs(color.blue - expected.blue) < 0.02
  }

  private struct SnapshotBackdrop<Content: View>: View {
    let content: Content
    @Environment(\.enigmaPalette) private var palette

    var body: some View {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.color)
    }
  }
}
