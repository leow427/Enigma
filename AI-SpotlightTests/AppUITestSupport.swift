import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// Wait for the asynchronous SwiftUI/AppKit handoff, without assuming a render
/// finishes in a fixed number of milliseconds. A missing state fails at the caller.
@MainActor
func waitForUI(_ description: @autoclosure () -> String, in view: NSView? = nil,
               timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
               until condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  repeat {
    await Task.yield()
    view?.layoutSubtreeIfNeeded()
    view?.window?.displayIfNeeded()
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  } while ContinuousClock.now < deadline
  _ = try XCTUnwrap(condition() ? true : nil, "Timed out waiting for \(description())", file: file, line: line)
}

@MainActor
func composerEditor(in view: NSView) -> SlashCommandTextView? {
  if let editor = view as? SlashCommandTextView { return editor }
  return view.subviews.lazy.compactMap { composerEditor(in: $0) }.first
}

@MainActor
func composerAcceptsClicks(in view: NSView) -> Bool {
  guard let editor = composerEditor(in: view), !editor.visibleRect.isEmpty,
        !editor.isHiddenOrHasHiddenAncestor else { return false }
  // hitTest expects superview coordinates, including for a flipped hosting view.
  let point = editor.convert(NSPoint(x: editor.visibleRect.midX, y: editor.visibleRect.midY), to: view.superview)
  guard let hit = view.hitTest(point) else { return false }
  return hit === editor || hit.isDescendant(of: editor)
}

struct TestControlMarker: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> Marker { Marker() }
  func updateNSView(_ view: Marker, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(name) }

  final class Marker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
  }
}

@MainActor
func clickTestControl(_ name: String, in view: NSView,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
  func marker(in node: NSView) -> TestControlMarker.Marker? {
    if let marker = node as? TestControlMarker.Marker, marker.identifier?.rawValue == name { return marker }
    return node.subviews.lazy.compactMap { marker(in: $0) }.first
  }
  let window = try XCTUnwrap(view.window, file: file, line: line)
  // Synthetic clicks do not activate a window as physical clicks do.
  window.makeKeyAndOrderFront(nil)
  try await waitForUI("visible control \(name) in the key window", in: view, file: file, line: line) {
    guard let marker = marker(in: view) else { return false }
    return window.isKeyWindow && marker.window === window && !marker.isHiddenOrHasHiddenAncestor
      && marker.visibleRect.width > 1 && marker.visibleRect.height > 1
  }
  let target = try XCTUnwrap(marker(in: view), file: file, line: line)
  let location = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
  let point = view.convert(location, from: nil)
  _ = try XCTUnwrap(view.hitTest(view.convert(point, to: view.superview)), "Control must be hittable", file: file, line: line)
  for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
    window.sendEvent(event)
  }
}
