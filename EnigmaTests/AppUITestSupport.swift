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
  func center(of marker: NSView) -> NSPoint {
    marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
  }
  let window = try XCTUnwrap(view.window, file: file, line: line)
  // Synthetic clicks do not activate a window as physical clicks do.
  window.makeKeyAndOrderFront(nil)
  try await waitForUI("visible, uncovered control \(name) in the key window", in: view, file: file, line: line) {
    guard let marker = marker(in: view), window.isKeyWindow, marker.window === window,
          !marker.isHiddenOrHasHiddenAncestor, marker.visibleRect.width > 1, marker.visibleRect.height > 1
    else { return false }
    // The click must reach the control, not a field or text drawn over it
    // while the layout is still moving, as a person's click would. The window
    // sends a click to the deepest view under it, found from its frame view.
    guard let frame = window.contentView?.superview, let hit = frame.hitTest(center(of: marker)) else { return false }
    return marker.isDescendant(of: hit)
  }
  let location = center(of: try XCTUnwrap(marker(in: view), file: file, line: line))
  let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
  }
  // A view that tracks the mouse, as a text view does to select, waits inside
  // its mouse-down for the mouse-up from the event queue. Queue it first, so
  // such a view can't wait forever; otherwise deliver it right after, as before.
  NSApp.postEvent(events[1], atStart: true)
  window.sendEvent(events[0])
  if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
    window.sendEvent(up)
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

// MARK: Tests of the helpers

@MainActor
final class UITestSupportTests: XCTestCase {
  /// A panel that can be key without activating the app, as the app's panels can.
  private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
  }

  private func window(_ content: NSView) -> NSWindow {
    let window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    window.orderFrontRegardless()
    window.makeKey()
    addTeardownBlock { @MainActor in window.orderOut(nil); window.contentView = nil }
    return window
  }

  private func marker(_ name: String, frame: NSRect) -> TestControlMarker.Marker {
    let marker = TestControlMarker.Marker(frame: frame)
    marker.identifier = NSUserInterfaceItemIdentifier(name)
    return marker
  }

  /// A focused text view selects by tracking the mouse inside its mouse-down
  /// until the mouse-up arrives. The click returns instead of waiting forever,
  /// as a hosted test once did on CI when its click landed on the composer.
  func testClickOnAViewThatTracksTheMouseReturns() async throws {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let text = NSTextView(frame: content.bounds)
    text.string = "Selectable text that tracks the mouse"
    content.addSubview(text)
    text.addSubview(marker("Text", frame: NSRect(x: 20, y: 20, width: 100, height: 40)))
    let window = window(content)
    window.makeFirstResponder(text)
    try await clickTestControl("Text", in: content)
    XCTAssertTrue(window.firstResponder === text, "The text view kept the click")
  }

  /// A control with something drawn over it isn't clicked until it's uncovered.
  func testCoveredControlIsClickedOnlyOnceUncovered() async throws {
    var taps = 0
    let host = NSHostingView(rootView: Button("Tap") { taps += 1 }
      .frame(width: 120, height: 40)
      .background(TestControlMarker(name: "Tap").allowsHitTesting(false))
      .frame(maxWidth: .infinity, maxHeight: .infinity))
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    host.frame = content.bounds
    content.addSubview(host)
    let cover = NSTextView(frame: content.bounds)
    content.addSubview(cover)
    _ = window(content)
    let options = XCTExpectedFailure.Options()
    options.issueMatcher = { $0.compactDescription.contains("Timed out waiting for visible, uncovered control Tap") }
    XCTExpectFailure("The covered control is never clicked", options: options)
    try? await clickTestControl("Tap", in: host)
    XCTAssertEqual(taps, 0, "Nothing reached the covered button")
    cover.removeFromSuperview()
    try await clickTestControl("Tap", in: host)
    XCTAssertEqual(taps, 1)
  }
}
