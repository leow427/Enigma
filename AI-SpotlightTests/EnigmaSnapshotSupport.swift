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

  /// Renders `view` at `size` points into an sRGB bitmap with `scale` pixels per point.
  static func render<Content: View>(_ view: Content, size: CGSize, scale: CGFloat = 2) throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    // Draw in sRGB, the palette's space, whatever display the test runs on.
    window.colorSpace = .sRGB
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
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
