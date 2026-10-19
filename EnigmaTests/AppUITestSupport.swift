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

/// Waits until an open Enigma menu has taken keyboard focus. The list asks
/// for focus as it appears, which can land a run-loop turn or more after its
/// rows are on screen; keys sent before then go to the trigger instead. Once
/// it has focus, the window's first responder moves from the trigger's (or
/// the field's) responder to `hostingView`, which draws the list.
@MainActor
func waitForOpenMenuToTakeFocus(in hostingView: NSView, file: StaticString = #filePath,
                                line: UInt = #line) async throws {
  let window = hostingView.window
  try await waitForUI("the open menu to take keyboard focus (key window: \(window?.isKeyWindow == true), "
                      + "app active: \(NSApp.isActive), first responder: \(String(describing: window?.firstResponder)), "
                      + "app's key window: \(String(describing: NSApp.keyWindow)))",
                      in: hostingView, file: file, line: line) {
    hostingView.window?.firstResponder === hostingView
  }
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

extension View {
  /// Sets Reduce Motion for this view, whatever the Mac's setting. GitHub's
  /// macOS runners turn it on, which makes the character move instantly and rest.
  func enigmaTestReduceMotion(_ isOn: Bool) -> some View {
    environment(\._accessibilityReduceMotion, isOn)
  }
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

/// The test bundle's principal class. Some tests deliberately activate the host
/// (Settings uses NSApp.activate); in a background run, focus then returns to the
/// app the developer was using so a local run does not hold the keyboard.
@MainActor @objc(TestFocusObserver)
final class TestFocusObserver: NSObject, @preconcurrency XCTestObservation {
  private var developerApp: NSRunningApplication?

  override init() {
    super.init()
    rememberDeveloperApp()
    XCTestObservationCenter.shared.addTestObserver(self)
  }

  func testCaseWillStart(_ testCase: XCTestCase) { rememberDeveloperApp() }

  func testCaseDidFinish(_ testCase: XCTestCase) {
    guard ApplicationDelegate.runsTestsInBackground, NSApp.isActive, let developerApp, !developerApp.isTerminated else { return }
    NSApp.yieldActivation(to: developerApp)
    developerApp.activate()
  }

  private func rememberDeveloperApp() {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
          frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    developerApp = frontmost
  }
}

/// The chat's message and reply views for `messages`, laid out as the window
/// lays them out, without the scrolling list around them.
struct TranscriptPreview: View {
  let messages: [ChatMessage]
  var spacing: CGFloat = 20
  /// Shows each reply's activity and sources open.
  var expandsActivity = false

  var body: some View {
    let transcript = ConversationTranscript(messages: messages, activity: nil, isResponding: false)
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(transcript.rows) { row in
        switch row {
        case .message(let message): EnigmaUserMessage(message: message)
        case .reply(let reply): EnigmaReplyView(reply: reply, expandedActivity: expandsActivity ? .constant(true) : nil)
        }
      }
    }
  }
}
