import AppKit
import os
@preconcurrency import ApplicationServices
import Carbon
import Combine

/// A lossless eager snapshot: decline clipboard use if any representation cannot be read.
@MainActor
struct SelectionPasteboardSnapshot {
  let items: [[NSPasteboard.PasteboardType: Data]]

  init?(_ board: NSPasteboard) {
    let changeCount = board.changeCount
    var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    for item in board.pasteboardItems ?? [] {
      var values: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        guard let data = item.data(forType: type) else { return nil }
        values[type] = data
      }
      snapshot.append(values)
    }
    guard board.changeCount == changeCount else { return nil }
    items = snapshot
  }

  func restore(_ board: NSPasteboard, ifUnchanged count: Int) {
    guard board.changeCount == count else { return }
    board.clearContents()
    let restored = items.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { board.writeObjects(restored) }
  }
}

@MainActor
final class SelectionContextService: ObservableObject {
  static let shared = SelectionContextService()
  @Published private(set) var isWorking = false
  @Published var notice: String?
  private var target: Target?
  private var capturedBounds: NSRect?
  private struct Target {
    let contextID: UUID
    // Retaining the running application also lets us detect its termination;
    // a later application that reuses its PID must not receive this paste.
    let app: NSRunningApplication
    var pid: pid_t { app.processIdentifier }
  }

  var canReplace: Bool { target != nil && !isWorking }
  func discardTarget() { target = nil; capturedBounds = nil; notice = nil }

  /// Apps whose last capture waited the full focus budget without a focused element,
  /// kept in memory only, so later invocations there don't wait as long again.
  private var focusMemory = SelectionFocusMemory<SelectionAppKey>()
  /// Structural lookups (focus, parents, roles, ranges) are quick or the app is busy.
  private static let messagingTimeout: Float = 0.15
  /// String reads can take longer for a large selection. Longer than `SelectionCaptureFlow.coldSelectionBudget`, so a read that times out
  /// also ends the selection retry instead of being repeated.
  static let textTimeout: Float = 1.0

  func capture() async -> ConversationContext? {
    guard !isWorking else { return nil }
    isWorking = true
    defer { isWorking = false }
    discardTarget()
    var failureNotice = SelectionCaptureNotice.text(for: .noSource, appName: nil)
    defer {
      if target == nil && notice == nil { notice = failureNotice }
    }
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    guard NSApp.keyWindow?.isKeyWindow != true, let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    guard AXIsProcessTrusted() else {
      notice = "Enable Accessibility using the button in this chat to attach selected text. This temporary chat is still ready."
      return nil
    }
    failureNotice = SelectionCaptureNotice.text(for: .nothingRead, appName: app.localizedName)
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    // Electron apps may not expose their focused editor until assistive access is enabled.
    // Unsupported attributes are harmless; this never grants macOS permission.
    AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    let mayCapture = {
      !Task.isCancelled && !interaction.interrupted && !IsSecureEventInputEnabled()
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
    let source = SelectionAppKey(pid: app.processIdentifier, launchDate: app.launchDate)
    let outcome = await SelectionCaptureFlow.run(tree: SelectionCaptureFlow.Tree(
        focused: { self.element(application, kAXFocusedUIElementAttribute) },
        isSafe: { self.isSafe($0) },
        sameFocus: { self.sameFocus(app: app, element: $0) },
        role: { self.attribute($0, kAXRoleAttribute) as? String },
        parent: { self.element($0, kAXParentAttribute) },
        selectedText: { self.selectedText($0) },
        rangeText: { node in self.selectedRange(node).flatMap { self.textForRange(node, range: $0) } },
        markerText: { self.markerText($0) }),
      focusBudget: focusMemory.focusBudget(for: source), appName: app.localizedName, mayCapture: mayCapture,
      lastWarm: { SelectionWarmHistory.shared.snapshot(source) })
    focusMemory.record(source, foundFocus: outcome.foundFocus, timedOut: outcome.focusTimedOut)
    if let notice = outcome.notice { failureNotice = notice }
    var result: SelectionLog.Result = outcome.focusTimedOut ? .notReady : .nothingRead
    var usedCopy = false
    defer {
      let final: SelectionLog.Result = result == .nothingRead && !mayCapture() ? .cancelled : result
      SelectionLog.capture(outcome.timing, source: outcome.selection?.source, usedCopy: usedCopy, result: final)
    }
    guard let element = outcome.element else { return nil }
    let range = selectedRange(element)
    var text = outcome.selection?.text
    if text == nil {
      // The selection retry can last 750 ms; never clear the clipboard or send ⌘C after the user moved on.
      guard outcome.mayCopy, mayCapture(),
            SelectionCapturePolicy.allowsCopy(range: range, bundleID: app.bundleIdentifier) else { return nil }
      usedCopy = true
      text = await copySelection(app: app, element: element, accept: {
        SelectionCapturePolicy.acceptsCopy(range: range, bundleID: app.bundleIdentifier, webCustomData: $0())
      })
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
    guard text.utf8.count <= 256_000 else {
      notice = "The selection is too large to attach. Select a smaller passage and try again."
      result = .tooLarge
      return nil
    }
    result = .attached
    switch outcome.selection?.source {
    case .focusedMarkers?:
      capturedBounds = markerBounds(element)
    case .webAreaSelectedText?, .webAreaMarkers?:
      capturedBounds = outcome.webArea.flatMap { markerBounds($0) }
    case .selectedText?, .rangeText?, nil:
      if let range, range.length > 0 { capturedBounds = bounds(element: element, range: range) }
    }
    let context = ConversationContext(sourceName: app.localizedName ?? "Application", text: text)
    remember(context, from: app)

    return context
  }

  func selectionBounds() -> NSRect? { capturedBounds }

  /// Replace text pastes `context`'s revision back into `app`, as long as `app`
  /// is the one running then.
  func remember(_ context: ConversationContext, from app: NSRunningApplication) {
    objectWillChange.send()
    target = Target(contextID: context.id, app: app)
  }

  private func bounds(element: AXUIElement, range: CFRange) -> NSRect? {
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    return bounds(element: element, attribute: kAXBoundsForRangeParameterizedAttribute, parameter: parameter)
  }

  /// The on-screen rectangle of the element's selected text-marker range, if it reports one.
  private func markerBounds(_ element: AXUIElement) -> NSRect? {
    guard let markers = attribute(element, Self.selectedTextMarkerRange) else { return nil }
    return bounds(element: element, attribute: "AXBoundsForTextMarkerRange", parameter: markers)
  }

  private func bounds(element: AXUIElement, attribute: String, parameter: CFTypeRef) -> NSRect? {
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString,
      parameter, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0,
          let primary = NSScreen.screens.first else { return nil }
    return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  /// Paste once into the remembered app's current selection, without restoring
  /// or inspecting the originally captured field, document, text, or range.
  func replace(with text: String, contextID: UUID) async -> Bool {
    guard !isWorking, let target, target.contextID == contextID else {
      notice = "Replacement is unavailable. Select text and invoke Enigma again."
      return false
    }
    isWorking = true
    defer { isWorking = false }
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    defer { NotificationCenter.default.post(name: .selectionReplacementEnded, object: nil) }
    let outcome = await SelectionPasteTransaction.perform(text: text, pid: target.pid, board: .general,
      isAvailable: { AXIsProcessTrusted() && !target.app.isTerminated && !IsSecureEventInputEnabled() },
      activate: {
        guard target.app.activate(options: []) else { return false }
        for _ in 0..<30 {
          if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { return true }
          try? await Task.sleep(for: .milliseconds(20))
        }
        return false
      },
      isSafeToPaste: {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let focused = self.element(application, kAXFocusedUIElementAttribute) else { return false }
        // Inspect only the current field's password/protected status, not its identity.
        return self.isSafe(focused)
      },
      postPaste: { self.postCommand(key: 9, pid: $0) },
      settle: { try? await Task.sleep(for: .milliseconds(600)) })
    switch outcome {
    case .sent:
      self.target = nil // No automatic or accidental second attempt at an ambiguous paste.
      notice = "Replacement sent to \(target.app.localizedName ?? "the source app")."
      return true
    case .unavailable:
      notice = "Replacement could not be sent. Check Accessibility permission and that the source app is open. Password fields cannot receive replacement."
    case .clipboardUnavailable:
      notice = "The clipboard could not be preserved. Replacement was not sent."
    case .eventUnavailable:
      notice = "The paste could not be sent to the source app."
    }
    return false
  }

  /// `accept` may read the copy's `org.chromium.web-custom-data` before the clipboard is restored.
  private func copySelection(app: NSRunningApplication, element: AXUIElement,
                             accept: (() -> Data?) -> Bool) async -> String? {
    guard sameFocus(app: app, element: element), isSafe(element), let snapshot = SelectionPasteboardSnapshot(.general) else { return nil }
    let interaction = SelectionInteractionGuard()
    defer { interaction.stop() }
    let board = NSPasteboard.general
    board.clearContents()
    let marker = NSPasteboard.PasteboardType("com.enigma.selection-copy")
    board.setString(UUID().uuidString, forType: marker)
    var ownedCount = board.changeCount
    defer { snapshot.restore(board, ifUnchanged: ownedCount) }
    for _ in 0..<2 {
      guard !Task.isCancelled, !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element),
            board.changeCount == ownedCount else { return nil }
      guard postCommand(key: 8, pid: app.processIdentifier) else { return nil }
      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled, !interaction.interrupted, sameFocus(app: app, element: element), isSafe(element) else { return nil }
        if board.changeCount != ownedCount {
          // Never retry after any clipboard write, or restore over a newer copy.
          guard board.changeCount == ownedCount + 1 else { return nil }
          ownedCount = board.changeCount
          let text = accept { board.data(forType: SelectionCapturePolicy.webCustomDataType) } ? board.string(forType: .string) : nil
          return board.changeCount == ownedCount ? text : nil
        }
      }
      // A single retry handles an editor that was not ready for the first Cmd+C.
      // The source is still focused and the marker has not been consumed.
    }
    return nil
  }

  @discardableResult
  private func postCommand(key: CGKeyCode, pid: pid_t) -> Bool {
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
    for event in [down, up] {
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: SelectionInteractionGuard.eventMarker)
      event.postToPid(pid)
    }
    return true
  }

  private func sameFocus(app: NSRunningApplication, element: AXUIElement) -> Bool {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          let focused = self.element(application, kAXFocusedUIElementAttribute) else { return false }
    return CFEqual(focused, element)
  }

  private func isSafe(_ element: AXUIElement) -> Bool {
    guard !IsSecureEventInputEnabled() else { return false }
    return SelectionAncestry.isSafe(from: element, info: { node in
      guard let role = self.attribute(node, kAXRoleAttribute) as? String else { return nil }
      return SelectionAncestry.NodeInfo(role: role, subrole: self.attribute(node, kAXSubroleAttribute) as? String,
        isProtected: { self.attribute(node, "AXProtectedContent") as? Bool == true })
    }, parent: { self.element($0, kAXParentAttribute) })
  }

  private static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"

  /// Chromium and WebKit selections as text markers. The marker range is an opaque
  /// value that is only handed back to the same element.
  private func markerText(_ element: AXUIElement) -> String? {
    guard let markers = attribute(element, Self.selectedTextMarkerRange) else { return nil }
    return textRead(element) {
      AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, markers, &$0)
    } as? String
  }

  /// A string read gets a longer timeout than structural lookups: a large selection in
  /// Chromium, WebKit or Xcode can take a while to serialize. One that times out uses up
  /// the whole selection retry, so it isn't repeated.
  private func textRead(_ element: AXUIElement, _ read: (inout CFTypeRef?) -> AXError) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, Self.textTimeout)
    defer { AXUIElementSetMessagingTimeout(element, Self.messagingTimeout) }
    var value: CFTypeRef?
    return read(&value) == .success ? value : nil
  }

  private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }

  private func element(_ owner: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(owner, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = value as! AXUIElement
    // The timeout is per element; the default would let a hung app block the main thread for seconds per call.
    AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    return element
  }

  private func selectedText(_ element: AXUIElement) -> String? {
    textRead(element) {
      AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &$0)
    } as? String
  }

  private func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
    return range
  }

  private func textForRange(_ element: AXUIElement, range: CFRange) -> String? {
    var range = range
    guard range.length > 0, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    if let text = textRead(element, {
      AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &$0)
    }) as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
    let value = textRead(element) { AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &$0) }
    return SelectionCapturePolicy.text(in: value as? String, range: range)
  }
}

/// Pure geometry shared by placement tests. Prefer a side with no selection overlap.
enum SelectionPanelPlacement {
  static func frame(size: NSSize, cursor: NSPoint, selection: NSRect?, visible: NSRect) -> NSRect {
    let size = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
    let anchor = selection ?? NSRect(origin: cursor, size: .zero)
    let candidates = [
      NSPoint(x: anchor.maxX + 16, y: anchor.maxY - size.height),
      NSPoint(x: anchor.minX - size.width - 16, y: anchor.maxY - size.height),
      NSPoint(x: cursor.x - size.width / 2, y: anchor.minY - size.height - 16),
      NSPoint(x: cursor.x - size.width / 2, y: anchor.maxY + 16)
    ].map { point in
      NSRect(x: min(max(point.x, visible.minX), visible.maxX - size.width),
             y: min(max(point.y, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
    }
    return candidates.min { lhs, rhs in
      func score(_ rect: NSRect) -> CGFloat {
        let overlap = rect.intersection(anchor)
        return (overlap.isNull ? 0 : overlap.width * overlap.height) * 1000
          + hypot(rect.midX - cursor.x, rect.midY - cursor.y)
      }
      return score(lhs) < score(rhs)
    }!
  }
}

/// Bounded readiness retries occur only inside a deliberate invocation.
@MainActor
enum SelectionCaptureRetry {
  nonisolated static func uptime() -> Duration { .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds)) }

  /// Reads at once, then every `interval` until `budget` has passed. `now` is any
  /// monotonic time; tests inject a simulated clock that `wait` advances.
  static func first<Value>(within budget: Duration, interval: Duration = .milliseconds(30),
                           mayContinue: () -> Bool, read: () -> Value?,
                           now: () -> Duration = uptime,
                           wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> Value? {
    let deadline = now() + budget
    while true {
      guard !Task.isCancelled, mayContinue() else { return nil }
      if let value = read() { return value }
      let remaining = deadline - now()
      guard remaining > .zero else { return nil }
      await wait(min(interval, remaining))
    }
  }
}

/// A diagnostic line per capture and per warm, readable later with `log show`. It holds
/// timings and fixed labels only: never the selected text, its length, or the app.
enum SelectionLog {
  static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight",
                             category: "selection")

  enum Result: String { case attached, nothingRead, notReady, tooLarge, cancelled }

  static func capture(_ timing: SelectionCaptureFlow.Timing, source: SelectionTextSource?, usedCopy: Bool,
                      result: Result) {
    let warm = timing.lastWarm
    logger.notice("""
      capture focusWaitMs=\(milliseconds(timing.focusWait), privacy: .public) \
      focusReads=\(timing.focusReads, privacy: .public) cold=\(timing.wasCold, privacy: .public) \
      selectionMs=\(milliseconds(timing.selectionTime), privacy: .public) \
      source=\(source.map { String(describing: $0) } ?? "none", privacy: .public) \
      copy=\(usedCopy, privacy: .public) result=\(result.rawValue, privacy: .public) \
      lastWarm=\(seconds(warm.sinceWarm), privacy: .public) \
      lastWarmTrigger=\(warm.trigger?.rawValue ?? "none", privacy: .public) \
      firstTapWarm=\(seconds(warm.sinceFirstTap), privacy: .public)
      """)
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  /// Seconds ago to one decimal, such as "2.4", or "never".
  static func seconds(_ duration: Duration?) -> String {
    guard let duration else { return "never" }
    return String(format: "%.1f", Double(milliseconds(duration)) / 1000)
  }
}

/// The capture sequence over an abstract accessibility tree, so its order, budgets
/// and failure kinds are testable with a fake tree. `SelectionContextService`
/// supplies thin closures over the real Accessibility calls.
@MainActor
enum SelectionCaptureFlow {
  nonisolated static let webAreaRole = "AXWebArea"
  /// How long a just-enabled Chromium or Electron tree gets to report its focused
  /// element. Measured cold trees took about 2 s (see docs/Selection-Context.md).
  nonisolated static let focusBudget: Duration = .milliseconds(2_500)
  /// The focus wait for an app whose last capture never reported a focused element.
  nonisolated static let shortFocusBudget: Duration = .milliseconds(300)
  /// About three reads, 30 ms apart, for a tree that answered at once.
  nonisolated static let quickBudget: Duration = .milliseconds(60)
  /// The longer selection retry for a tree that only just reported its focus.
  nonisolated static let coldSelectionBudget: Duration = .milliseconds(750)
  nonisolated static let interval: Duration = .milliseconds(30)

  struct Tree<Node> {
    var focused: () -> Node?
    /// The focused element and every ancestor up to the app are safe to read.
    var isSafe: (Node) -> Bool
    /// The node is still the app's focused element.
    var sameFocus: (Node) -> Bool
    var role: (Node) -> String?
    var parent: (Node) -> Node?
    var selectedText: (Node) -> String?
    /// `AXStringForRange`, or the selected slice of `AXValue`.
    var rangeText: (Node) -> String?
    var markerText: (Node) -> String?
  }

  struct Outcome<Node> {
    /// The safe focused element, when there was one.
    var element: Node?
    var selection: (source: SelectionTextSource, text: String)?
    /// The web area the selection came from, if it did.
    var webArea: Node?
    var foundFocus: Bool
    /// The whole focus budget passed, while capture could continue, with no focused element.
    var focusTimedOut: Bool
    /// Capture could still continue when the flow ended, so the ⌘C fallback may run.
    var mayCopy = false
    /// What to show if nothing ends up attached; nil once text was read.
    var notice: String?
    var timing = Timing()
  }

  /// How long each step took, for the diagnostic log.
  struct Timing: Equatable {
    var focusWait: Duration = .zero
    var focusReads = 0
    var wasCold = false
    var selectionTime: Duration = .zero
    /// When the app was last warmed, taken before the capture started waiting.
    var lastWarm = SelectionWarmSnapshot()
  }

  static func run<Node>(tree: Tree<Node>, focusBudget: Duration, appName: String?, mayCapture: () -> Bool,
                        lastWarm: () -> SelectionWarmSnapshot = { SelectionWarmSnapshot() },
                        now: () -> Duration = SelectionCaptureRetry.uptime,
                        wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> Outcome<Node> {
    let nothingRead = SelectionCaptureNotice.text(for: .nothingRead, appName: appName)
    // A cold Chromium tree builds asynchronously after AXManualAccessibility is set.
    let start = now()
    let focusDeadline = start + focusBudget
    var focusReads = 0
    // Before any waiting, so warms during the capture itself don't hide earlier ones.
    var timing = Timing(lastWarm: lastWarm())
    guard let focused = await SelectionCaptureRetry.first(within: focusBudget, interval: interval, mayContinue: mayCapture,
      read: { focusReads += 1; return tree.focused() }, now: now, wait: wait) else {
      let timedOut = mayCapture()
      timing.focusWait = now() - start
      timing.focusReads = focusReads
      timing.wasCold = focusReads > 1
      return Outcome(element: nil, selection: nil, webArea: nil, foundFocus: false, focusTimedOut: timedOut,
        notice: timedOut ? SelectionCaptureNotice.text(for: .notReady, appName: appName) : nothingRead, timing: timing)
    }
    let wasCold = focusReads > 1
    timing.focusWait = now() - start
    timing.focusReads = focusReads
    timing.wasCold = wasCold
    var safeFocus: Node? = tree.isSafe(focused) ? focused : nil
    if safeFocus == nil {
      // A tree still being filled in may not reach the app yet; never read until it does.
      // After a cold wait, keep trying for what's left of the focus budget.
      let budget = wasCold ? max(focusDeadline - now(), quickBudget) : quickBudget
      safeFocus = await SelectionCaptureRetry.first(within: budget, interval: interval, mayContinue: mayCapture, read: {
        tree.focused().flatMap { tree.isSafe($0) ? $0 : nil }
      }, now: now, wait: wait)
    }
    guard var element = safeFocus else {
      return Outcome(element: nil, selection: nil, webArea: nil, foundFocus: true, focusTimedOut: false, notice: nothingRead,
        timing: timing)
    }
    // A focused web area (a page, frame or web view) is its own document: never read the page around it.
    var cachedArea: Node??
    let webArea = { () -> Node? in
      if let cachedArea { return cachedArea }
      let area = tree.role(element) == webAreaRole ? nil
        : SelectionAncestry.nearestAncestor(of: element, role: webAreaRole, roleOf: tree.role, parent: tree.parent)
      cachedArea = .some(area)
      return area
    }
    let selectionStart = now()
    let selection = await SelectionCaptureRetry.first(within: wasCold ? coldSelectionBudget : quickBudget, interval: interval,
      mayContinue: { mayCapture() && (wasCold || (tree.sameFocus(element) && tree.isSafe(element))) },
      read: { () -> (source: SelectionTextSource, text: String)? in
        if wasCold, !(tree.sameFocus(element) && tree.isSafe(element)) {
          // Only a tree that just woke up may still move its focus (VS Code first reports its
          // web area, then the editor): follow it to the new, safe element.
          guard let moved = tree.focused(), tree.isSafe(moved) else { return nil }
          element = moved
          cachedArea = nil
        }
        return SelectionCapturePolicy.selectionText(
          selectedText: { tree.selectedText(element) },
          rangeText: { tree.rangeText(element) },
          focusedMarkers: { tree.markerText(element) },
          webAreaSelectedText: { webArea().flatMap(tree.selectedText) },
          webAreaMarkers: { webArea().flatMap(tree.markerText) })
      }, now: now, wait: wait)
    timing.selectionTime = now() - selectionStart
    let usedArea: Node? = switch selection?.source {
    case .webAreaSelectedText?, .webAreaMarkers?: webArea()
    default: nil
    }
    return Outcome(element: element, selection: selection, webArea: usedArea, foundFocus: true, focusTimedOut: false,
      mayCopy: selection == nil && mayCapture(), notice: selection == nil ? nothingRead : nil, timing: timing)
  }
}

/// Remembers, in memory only, apps whose last capture waited the whole focus budget
/// without a focused element, so the next capture there waits only briefly.
struct SelectionFocusMemory<Key: Hashable> {
  private(set) var unresponsive: Set<Key> = []

  func focusBudget(for key: Key) -> Duration {
    unresponsive.contains(key) ? SelectionCaptureFlow.shortFocusBudget : SelectionCaptureFlow.focusBudget
  }

  mutating func record(_ key: Key, foundFocus: Bool, timedOut: Bool) {
    if foundFocus { unresponsive.remove(key) } else if timedOut { unresponsive.insert(key) }
  }
}

/// Walks a focused element's ancestors. Chromium and Electron trees can put the
/// application more than 30 levels up, so the walk allows 128 hops. It fails closed:
/// a missing role or parent, a secure or protected node, or not reaching the
/// application within the bound (which also ends a parent cycle) is unsafe.
enum SelectionAncestry {
  static let maximumHops = 128

  struct NodeInfo {
    let role: String
    let subrole: String?
    /// Read only when the role and subrole aren't already secure.
    let isProtected: () -> Bool
  }

  static func isSafe<Node>(from start: Node, maximumHops: Int = maximumHops,
                           info: (Node) -> NodeInfo?, parent: (Node) -> Node?) -> Bool {
    var node = start
    for hop in 0...max(0, maximumHops) {
      guard let info = info(node) else { return false }
      if info.role.lowercased().contains("secure") || (info.subrole ?? "").lowercased().contains("secure")
        || info.isProtected() { return false }
      if info.role == kAXApplicationRole { return true }
      guard hop < maximumHops, let next = parent(node) else { return false }
      node = next
    }
    return false
  }

  /// The closest strict ancestor with `role`, below the application.
  static func nearestAncestor<Node>(of start: Node, role: String, maximumHops: Int = maximumHops,
                                    roleOf: (Node) -> String?, parent: (Node) -> Node?) -> Node? {
    var node = start
    for _ in 0..<max(0, maximumHops) {
      guard let next = parent(node), let nodeRole = roleOf(next), nodeRole != kAXApplicationRole else { return nil }
      if nodeRole == role { return next }
      node = next
    }
    return nil
  }
}

/// Where captured text came from, in the order the sources are tried.
enum SelectionTextSource: Equatable {
  case selectedText, rangeText, focusedMarkers, webAreaSelectedText, webAreaMarkers
}

/// The notice shown when a capture attached nothing.
enum SelectionCaptureNotice {
  enum Failure: Equatable {
    /// No other app was frontmost to read from.
    case noSource
    /// The app was asked, but no selected text came back.
    case nothingRead
    /// The app didn't report a focused element within the wait.
    case notReady
  }

  static func text(for failure: Failure, appName: String?) -> String {
    let trimmed = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmed?.isEmpty == false ? trimmed : nil
    switch failure {
    case .noSource:
      return "No selected text could be read. Highlight text in the source app and try again. If it still fails, copy the text and paste it into this chat."
    case .nothingRead:
      return "No selected text could be read from \(name ?? "the app"). If text is selected there, copy it and paste it into this chat."
    case .notReady:
      return "\(name ?? "The app") didn't share its text with Enigma in time. Try again, or copy the text and paste it into this chat."
    }
  }
}

/// One process-targeted paste with a lossless, ownership-aware clipboard restore.
/// The injectable operations keep transaction ordering and failure paths testable
/// without sending keyboard events to real applications during unit tests.
@MainActor
enum SelectionPasteTransaction {
  enum Outcome: Equatable { case sent, unavailable, clipboardUnavailable, eventUnavailable }

  static func perform(text: String, pid: pid_t, board: NSPasteboard,
                      isAvailable: () -> Bool, activate: () async -> Bool,
                      isSafeToPaste: () -> Bool, postPaste: (pid_t) -> Bool,
                      settle: () async -> Void) async -> Outcome {
    guard !Task.isCancelled, !text.isEmpty, text.utf8.count <= 256_000, isAvailable(), await activate(),
          !Task.isCancelled, isAvailable(), isSafeToPaste() else { return .unavailable }
    guard let snapshot = SelectionPasteboardSnapshot(board) else { return .clipboardUnavailable }
    board.clearContents()
    var ownedCount = board.changeCount
    defer { snapshot.restore(board, ifUnchanged: ownedCount) }
    let written = board.setString(text, forType: .string)
      && board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
      && board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
    ownedCount = board.changeCount
    guard written else { return .clipboardUnavailable }
    guard postPaste(pid) else { return .eventUnavailable }
    await settle()
    return .sent // Dispatch is not proof that an external editor accepted the paste.
  }
}

/// Watches event metadata only during an explicit capture transaction.
/// Synthetic copy/paste events are tagged so they do not cancel their own transaction.
@MainActor
private final class SelectionInteractionGuard {
  static let eventMarker: Int64 = 0x454E_4947
  private(set) var interrupted = false
  private var global: Any?
  private var local: Any?
  /// Releasing the shortcut's modifiers (⇧⌥ after ⇧⌥Space) must not cancel the capture it started.
  private var modifiers = SelectionModifierTracker(previous: NSEvent.modifierFlags)

  init() {
    let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.receive(event) }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.receive(event)
      return event
    }
  }

  func stop() {
    if let global { NSEvent.removeMonitor(global) }
    if let local { NSEvent.removeMonitor(local) }
    global = nil; local = nil
  }

  private func receive(_ event: NSEvent) {
    let isOwn = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.eventMarker
    if modifiers.interrupts(type: event.type, flags: event.modifierFlags, isOwnEvent: isOwn) { interrupted = true }
  }
}

/// The modifier keys held when the previous event arrived, so a release can be told
/// apart from a press.
struct SelectionModifierTracker {
  private(set) var previous: NSEvent.ModifierFlags

  init(previous: NSEvent.ModifierFlags) { self.previous = previous }

  mutating func interrupts(type: NSEvent.EventType, flags: NSEvent.ModifierFlags, isOwnEvent: Bool) -> Bool {
    defer { if type == .flagsChanged { previous = flags } }
    return SelectionInteractionPolicy.interrupts(type: type, flags: flags, previousFlags: previous, isOwnEvent: isOwnEvent)
  }
}

/// Which events during a capture mean the user has moved on.
enum SelectionInteractionPolicy {
  /// Any key, click or scroll interrupts, and so does pressing a modifier. Releasing
  /// modifiers, such as letting go of ⇧⌥ after ⇧⌥Space, doesn't. Enigma's own
  /// tagged events never do.
  static func interrupts(type: NSEvent.EventType, flags: NSEvent.ModifierFlags,
                         previousFlags: NSEvent.ModifierFlags, isOwnEvent: Bool) -> Bool {
    guard !isOwnEvent else { return false }
    guard type == .flagsChanged else { return true }
    let now = flags.intersection(.deviceIndependentFlagsMask)
    let before = previousFlags.intersection(.deviceIndependentFlagsMask)
    return !before.isSuperset(of: now)
  }
}

/// Browser canvas editors can expose an empty hidden input while DOM text is selected.
/// Copy is authoritative there. Native copy-line editors require a nonempty AX range.
/// VS Code-family editors hide their selection from AX and copy the whole line when
/// nothing is selected, so their copy counts only when VS Code's own metadata confirms a selection.
enum SelectionCapturePolicy {
  static let webCustomDataType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
  static let codeEditors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
    "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]

  static func text(in value: String?, range: CFRange) -> String? {
    guard let value, range.location >= 0, range.length > 0 else { return nil }
    let text = value as NSString
    guard range.location <= text.length, range.length <= text.length - range.location else { return nil }
    return text.substring(with: NSRange(location: range.location, length: range.length))
  }

  /// The first nonblank text: the focused element's own selection, then its range,
  /// then its text markers, then its web area's selection and markers. Later sources
  /// are never read once one succeeds.
  static func selectionText(selectedText: () -> String?, rangeText: () -> String?, focusedMarkers: () -> String?,
                            webAreaSelectedText: () -> String?, webAreaMarkers: () -> String?)
    -> (source: SelectionTextSource, text: String)? {
    func usable(_ text: String?) -> String? {
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return text
    }
    if let text = usable(selectedText()) { return (.selectedText, text) }
    if let text = usable(rangeText()) { return (.rangeText, text) }
    if let text = usable(focusedMarkers()) { return (.focusedMarkers, text) }
    if let text = usable(webAreaSelectedText()) { return (.webAreaSelectedText, text) }
    if let text = usable(webAreaMarkers()) { return (.webAreaMarkers, text) }
    return nil
  }

  static func allowsCopy(range: CFRange?, bundleID: String?) -> Bool {
    let bundleID = bundleID ?? ""
    if codeEditors.contains(bundleID) { return true }
    let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
      "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox"]
    if let range { return range.length > 0 || browsers.contains(bundleID) }
    let lineEditors = ["com.microsoft.VSCode", "com.jetbrains.", "com.sublimetext."]
    return !lineEditors.contains { bundleID.hasPrefix($0) }
  }

  static func acceptsCopy(range: CFRange?, bundleID: String?, webCustomData: @autoclosure () -> Data?) -> Bool {
    guard codeEditors.contains(bundleID ?? "") else { return true }
    let source = VSCodeClipboardMetadata.copySource(webCustomData())
    if let range, range.length > 0 { return source != .emptySelection }
    return source == .selection
  }

  /// Reads `vscode-editor-data` from Chromium's web-custom-data Pickle: UInt32 payload
  /// size, UInt32 entry count, then key/value strings, each a UInt32 UTF-16 length and
  /// UTF-16LE units padded to 4 bytes. All fields are little-endian.
  enum VSCodeClipboardMetadata {
    /// VS Code reports `isFromEmptySelection: false` for several cursors even when each is
    /// empty and copies each cursor's whole line, so any `multicursorText` is ambiguous.
    enum CopySource: Equatable { case selection, emptySelection, multicursor, unknown }

    private struct EditorData: Decodable {
      let isFromEmptySelection: Bool, hasMulticursorText: Bool
      private enum Key: CodingKey { case isFromEmptySelection, multicursorText }
      init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        isFromEmptySelection = try values.decode(Bool.self, forKey: .isFromEmptySelection)
        hasMulticursorText = try values.contains(.multicursorText) && !values.decodeNil(forKey: .multicursorText)
      }
    }

    static func copySource(_ data: Data?) -> CopySource {
      guard let editor = editorData(data) else { return .unknown }
      return editor.isFromEmptySelection ? .emptySelection : editor.hasMulticursorText ? .multicursor : .selection
    }

    private static func editorData(_ data: Data?) -> EditorData? {
      guard let data else { return nil }
      var bytes = [UInt8](data), offset = 0
      func uint32() -> Int? {
        guard bytes.count - offset >= 4 else { return nil }
        defer { offset += 4 }
        return (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
      }
      func string() -> String? {
        guard let units = uint32(), units <= (bytes.count - offset) / 2 else { return nil }
        let size = units * 2, padded = (size + 3) & ~3
        let value = String(bytes: bytes[offset..<offset + size], encoding: .utf16LittleEndian)
        offset = min(bytes.count, offset + padded)
        return value
      }
      // Bound reads by the declared payload; Chromium may leave capacity padding after it.
      guard let size = uint32(), size <= bytes.count - 4 else { return nil }
      bytes = Array(bytes.prefix(4 + size))
      guard let count = uint32(), count <= (bytes.count - offset) / 8 else { return nil }
      for _ in 0..<count {
        guard let key = string(), let value = string() else { return nil }
        if key == "vscode-editor-data" {
          return try? JSONDecoder().decode(EditorData.self, from: Data(value.utf8))
        }
      }
      return nil
    }
  }
}

/// macOS may suppress repeated trust prompts, so always provide a direct Settings route.
@MainActor
final class SelectionAccessibilityAccess: ObservableObject {
  static let shared = SelectionAccessibilityAccess()
  static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Enigma"
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
  @Published private(set) var isGranted: Bool
  private let checkTrust: () -> Bool
  private let prompt: () -> Void
  private let openSettings: (URL) -> Void

  init(checkTrust: @escaping () -> Bool = { AXIsProcessTrusted() },
       prompt: @escaping () -> Void = {
         let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
         _ = AXIsProcessTrustedWithOptions(options)
       },
       openSettings: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }) {
    self.checkTrust = checkTrust
    self.prompt = prompt
    self.openSettings = openSettings
    isGranted = checkTrust()
  }

  func refresh() { isGranted = checkTrust() }

  func requestAccess() {
    prompt()
    openSettings(Self.settingsURL)
    refresh()
  }
}
