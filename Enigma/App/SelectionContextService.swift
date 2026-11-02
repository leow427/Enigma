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

  // The tour's pretend document can always take its replacement.
  var canReplace: Bool { (target != nil || GuidedTour.shared.stop == .selection) && !isWorking }
  func discardTarget() { target = nil; capturedBounds = nil; notice = nil }

  /// Structural lookups (focus, parents, roles, ranges) are quick or the app is busy.
  private static let messagingTimeout: Float = 0.15
  /// String reads can take longer for a large selection; one that times out falls through to ⌘C.
  static let textTimeout: Float = 1.0

  /// One quick Accessibility read, then ⌘C in any app. Nothing waits for an app's
  /// accessibility tree: an app that doesn't answer at once is copied from instead.
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
    let mayCapture = {
      !Task.isCancelled && !interaction.interrupted && !IsSecureEventInputEnabled()
        && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }
    guard mayCapture() else { return nil }
    let started = ContinuousClock.now
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    let outcome = SelectionCaptureFlow.read(tree: SelectionCaptureFlow.Tree(
      focused: { self.focus(application) },
      isSafe: { self.isSafe($0) },
      role: { self.attribute($0, kAXRoleAttribute) as? String },
      parent: { self.element($0, kAXParentAttribute) },
      selectedText: { self.selectedText($0) },
      rangeText: { node in self.selectedRange(node).flatMap { self.textForRange(node, range: $0) } },
      markerText: { self.markerText($0) }))
    var result: SelectionLog.Result = .nothingRead
    var usedCopy = false
    defer {
      let final: SelectionLog.Result = result == .nothingRead && !mayCapture() ? .cancelled : result
      SelectionLog.capture(elapsed: ContinuousClock.now - started, source: outcome.selection?.source,
                           usedCopy: usedCopy, result: final)
    }
    let range = outcome.element.flatMap { selectedRange($0) }
    var text = outcome.selection?.text
    if text == nil {
      guard mayCapture(), let resend = SelectionCapturePolicy.copyResend(mayCopy: outcome.mayCopy, range: range,
              inWebContent: outcome.inWebContent, bundleID: app.bundleIdentifier) else { return nil }
      usedCopy = true
      text = await SelectionCopyTransaction.perform(board: .general, resend: resend, mayContinue: mayCapture,
        userCopied: { interaction.copied },
        // Before each ⌘C, the focus must still be what the read saw and still safe; a busy app times out here.
        postCopy: {
          self.focus(application).isCurrent(outcome.element, same: { CFEqual($0, $1) }, isSafe: { self.isSafe($0) })
            && self.postCommand(key: 8, pid: app.processIdentifier)
        },
        accept: { SelectionCapturePolicy.acceptsCopy(range: range, bundleID: app.bundleIdentifier, webCustomData: $0()) })
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, mayCapture() else { return nil }
    guard text.utf8.count <= 256_000 else {
      notice = "The selection is too large to attach. Select a smaller passage and try again."
      result = .tooLarge
      return nil
    }
    result = .attached
    // A copy from an app with no readable focused element places the panel beside the pointer.
    switch outcome.selection?.source {
    case .focusedMarkers?:
      capturedBounds = outcome.element.flatMap { markerBounds($0) }
    case .webAreaSelectedText?, .webAreaMarkers?:
      capturedBounds = outcome.webArea.flatMap { markerBounds($0) }
    case .selectedText?, .rangeText?, nil:
      if let element = outcome.element, let range, range.length > 0 { capturedBounds = bounds(element: element, range: range) }
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
  /// `automatic` is an /edit revision pasted without Replace text: once it's
  /// sent, Enigma stays out of the way rather than coming back to the front.
  func replace(with text: String, contextID: UUID, automatic: Bool = false) async -> Bool {
    // The tour's selection goes back into its pretend document.
    if contextID == TourScene.context.id, GuidedTour.shared.stop == .selection {
      return await GuidedTour.shared.replaceInDocument(text, automatic: automatic)
    }
    guard !isWorking, let target, target.contextID == contextID else {
      notice = "Replacement is unavailable. Select text and invoke Enigma again."
      return false
    }
    isWorking = true
    defer { isWorking = false }
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    var sent = false
    defer {
      NotificationCenter.default.post(name: .selectionReplacementEnded,
                                      object: SelectionReplacementEnd(automatic: automatic, sent: sent))
    }
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
        // Inspect only the current field's password/protected status, not its identity.
        // An app that reports no focused element at all (such as ChatGPT) has no field to inspect;
        // Secure Event Input, which password fields turn on, is checked in `isAvailable`.
        return self.focus(application).allowsPaste(isSafe: { self.isSafe($0) })
      },
      postPaste: { self.postCommand(key: 9, pid: $0) },
      settle: { try? await Task.sleep(for: .milliseconds(600)) })
    switch outcome {
    case .sent:
      sent = true
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
  /// Chromium, WebKit or Xcode can take a while to serialize. One that times out falls through to ⌘C.
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

  /// A timeout or an unexpected error is unknown, so an app too busy to answer is neither
  /// copied from nor pasted into (see `SelectionFocus.init`).
  private func focus(_ application: AXUIElement) -> SelectionFocus<AXUIElement> {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
    let element = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    if let element { AXUIElementSetMessagingTimeout(element, Self.messagingTimeout) }
    return SelectionFocus(error: error, element: element)
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

/// A diagnostic line per capture, readable later with `log show`. It holds timings and
/// fixed labels only: never the selected text, its length, or the app.
enum SelectionLog {
  static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.leow427.AISpotlight",
                             category: "selection")

  enum Result: String { case attached, nothingRead, tooLarge, cancelled }

  static func capture(elapsed: Duration, source: SelectionTextSource?, usedCopy: Bool, result: Result) {
    logger.notice("""
      capture ms=\(milliseconds(elapsed), privacy: .public) \
      source=\(source.map { String(describing: $0) } ?? "none", privacy: .public) \
      copy=\(usedCopy, privacy: .public) result=\(result.rawValue, privacy: .public)
      """)
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }
}

/// What an app reports as focused: an element, nothing at all (`kAXErrorNoValue`), or an error.
enum SelectionFocus<Node> {
  case element(Node), nothing, unknown

  /// "No value", or an app that doesn't support focus (a Chromium or Electron app with its
  /// accessibility off may answer either), means nothing is focused; a timeout or any other
  /// error is unknown.
  init(error: AXError, element: Node?) {
    switch (error, element) {
    case (.success, let element?): self = .element(element)
    case (.noValue, _), (.attributeUnsupported, _), (.notImplemented, _): self = .nothing
    default: self = .unknown
    }
  }

  /// A paste may go into a safe focused element, or into an app that reports none (Secure
  /// Event Input, which password fields turn on, is checked separately); never when unknown.
  func allowsPaste(isSafe: (Node) -> Bool) -> Bool {
    switch self {
    case .element(let focused): isSafe(focused)
    case .nothing: true
    case .unknown: false
    }
  }

  /// The focus is still `read` (nil: nothing was focused) and still safe.
  func isCurrent(_ read: Node?, same: (Node, Node) -> Bool, isSafe: (Node) -> Bool) -> Bool {
    switch (self, read) {
    case (.nothing, nil): true
    case (.element(let focused), let read?): same(focused, read) && isSafe(focused)
    default: false
    }
  }
}

/// One read of the focused element's selection over an abstract accessibility tree, so
/// its order and safety rules are testable with a fake tree. Nothing waits: an app whose
/// tree doesn't answer at once is copied from with ⌘C instead.
@MainActor
enum SelectionCaptureFlow {
  nonisolated static let webAreaRole = "AXWebArea"

  struct Tree<Node> {
    var focused: () -> SelectionFocus<Node>
    /// The focused element and every ancestor up to the app are safe to read.
    var isSafe: (Node) -> Bool
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
    /// The focused element isn't safe to read, or the app couldn't say what is focused,
    /// so nothing may be read or copied.
    var refused = false

    /// The focused element is a web area or inside one, where an empty AX range can hide a DOM
    /// selection. Worked out only when nothing was read.
    var inWebContent = false

    /// Nothing was read and nothing refused, so ⌘C may be sent.
    var mayCopy: Bool { !refused && selection == nil }
  }

  static func read<Node>(tree: Tree<Node>) -> Outcome<Node> {
    let element: Node
    switch tree.focused() {
    case .nothing: return Outcome()
    case .unknown: return Outcome(refused: true)
    case .element(let node): element = node
    }
    guard tree.isSafe(element) else { return Outcome(refused: true) }
    // A focused web area (a page, frame or web view) is its own document: never read the page around it.
    var cachedArea: Node??
    let webArea = { () -> Node? in
      if let cachedArea { return cachedArea }
      let area = tree.role(element) == webAreaRole ? nil
        : SelectionAncestry.nearestAncestor(of: element, role: webAreaRole, roleOf: tree.role, parent: tree.parent)
      cachedArea = .some(area)
      return area
    }
    let selection = SelectionCapturePolicy.selectionText(
      selectedText: { tree.selectedText(element) },
      rangeText: { tree.rangeText(element) },
      focusedMarkers: { tree.markerText(element) },
      webAreaSelectedText: { webArea().flatMap(tree.selectedText) },
      webAreaMarkers: { webArea().flatMap(tree.markerText) })
    let usedArea: Node? = switch selection?.source {
    case .webAreaSelectedText?, .webAreaMarkers?: webArea()
    default: nil
    }
    return Outcome(element: element, selection: selection, webArea: usedArea,
                   inWebContent: selection == nil && (tree.role(element) == webAreaRole || webArea() != nil))
  }
}

/// ⌘C wrapped in a lossless, ownership-aware clipboard round trip. Every item on the
/// clipboard is saved first and put back afterwards unless something newer was copied;
/// if it can't all be saved, nothing is copied. Injectable so tests use a private board.
@MainActor
enum SelectionCopyTransaction {
  /// How long each ⌘C gets to change the clipboard. Electron editors sometimes drop the
  /// first one, so it is sent once more; with nothing selected the capture ends after both.
  static let attempts: [Duration] = [.milliseconds(160), .milliseconds(240)]
  static let interval: Duration = .milliseconds(20)
  static let marker = NSPasteboard.PasteboardType("com.enigma.selection-copy")

  /// `resend` allows the second ⌘C. `userCopied` reports a ⌘C or ⌘X the user pressed during the
  /// capture, whose copy must never be restored over. `accept` may read the copy's
  /// `org.chromium.web-custom-data` before the clipboard is restored.
  static func perform(board: NSPasteboard, resend: Bool = true, mayContinue: () -> Bool,
                      userCopied: () -> Bool = { false }, postCopy: () -> Bool, accept: (() -> Data?) -> Bool,
                      wait: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> String? {
    // Yield once, so input during the Accessibility read cancels the capture before anything is sent.
    await wait(interval)
    guard mayContinue(), let snapshot = SelectionPasteboardSnapshot(board) else { return nil }
    board.clearContents()
    board.setString(UUID().uuidString, forType: marker)
    let base = board.changeCount
    var sent = 0, elapsed = Duration.zero, budget = Duration.zero
    sending: for limit in resend ? attempts : [attempts[0]] {
      guard board.changeCount == base, mayContinue(), postCopy() else { break }
      sent += 1
      budget += limit
      while elapsed < budget {
        await wait(interval)
        elapsed += interval
        if board.changeCount != base || !mayContinue() { break sending }
      }
    }
    // Let every ⌘C sent land, within the whole window even after one ⌘C or a cancel, so a slow
    // one can't overwrite the restored clipboard.
    let window = attempts.reduce(Duration.zero, +)
    while board.changeCount < base + sent, elapsed < window {
      await wait(interval)
      elapsed += interval
    }
    let count = board.changeCount
    // More changes than ⌘Cs sent means something else wrote the clipboard: never read or restore over it.
    let ours = count > base && count <= base + sent && !userCopied()
    var text: String?
    if ours, mayContinue(), accept({ board.data(forType: SelectionCapturePolicy.webCustomDataType) }) {
      text = board.string(forType: .string)
    }
    let unchanged = board.changeCount == count
    if count == base || ours { snapshot.restore(board, ifUnchanged: count) }
    return unchanged ? text : nil
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
  }

  static func text(for failure: Failure, appName: String?) -> String {
    let trimmed = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmed?.isEmpty == false ? trimmed : nil
    switch failure {
    case .noSource:
      return "No selected text could be read. Highlight text in the source app and try again. If it still fails, copy the text and paste it into this chat."
    case .nothingRead:
      return "No selected text could be read from \(name ?? "the app"). If text is selected there, copy it and paste it into this chat."
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
  /// The user pressed ⌘C or ⌘X themselves, so the clipboard holds their copy.
  private(set) var copied = false
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
    if SelectionInteractionPolicy.isUserCopy(type: event.type, flags: event.modifierFlags, keyCode: event.keyCode,
                                             isOwnEvent: isOwn) { copied = true }
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

  /// The user pressed ⌘C or ⌘X, so the clipboard is theirs.
  static func isUserCopy(type: NSEvent.EventType, flags: NSEvent.ModifierFlags, keyCode: UInt16, isOwnEvent: Bool) -> Bool {
    !isOwnEvent && type == .keyDown && flags.contains(.command) && [7, 8].contains(keyCode)
  }
}

/// ⌘C is the fallback in every app. Editors that copy the whole current line when nothing
/// is selected need a nonempty AX range first. VS Code-family editors hide their selection
/// from AX, so their copy counts only when VS Code's own metadata confirms a selection; in
/// any other app (a VS Code fork or Monaco on a web page) a copy that metadata marks as from
/// an empty selection or several cursors is rejected.
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

  /// Whether ⌘C may be sent once more, or nil when it mustn't be sent at all: after a refused
  /// read, in a line-copy editor without a selection, or in a native field (outside web content)
  /// that reports an empty range, whose Copy is disabled so ⌘C would only play the alert sound.
  /// A field that reports a range has a reliable caret, so it gets no resend.
  static func copyResend(mayCopy: Bool, range: CFRange?, inWebContent: Bool, bundleID: String?) -> Bool? {
    guard mayCopy, allowsCopy(range: range, bundleID: bundleID) else { return nil }
    if let range, range.length == 0, !inWebContent, !codeEditors.contains(bundleID ?? "") { return nil }
    return range == nil
  }

  static func allowsCopy(range: CFRange?, bundleID: String?) -> Bool {
    let bundleID = bundleID ?? ""
    let lineEditors = ["com.microsoft.VSCode", "com.jetbrains.", "com.google.android.studio", "com.sublimetext.", "dev.zed."]
    guard !codeEditors.contains(bundleID), lineEditors.contains(where: bundleID.hasPrefix) else { return true }
    return (range?.length ?? 0) > 0
  }

  static func acceptsCopy(range: CFRange?, bundleID: String?, webCustomData: @autoclosure () -> Data?) -> Bool {
    let source = VSCodeClipboardMetadata.copySource(webCustomData())
    guard codeEditors.contains(bundleID ?? "") else { return source != .emptySelection && source != .multicursor }
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

/// How a replacement ended, for the window that stepped aside for it.
struct SelectionReplacementEnd: Equatable, Sendable {
  let automatic: Bool
  let sent: Bool

  /// A sent automatic paste leaves the person in their app, looking at the
  /// edited text. A manual one, or any paste that failed, brings Enigma back.
  var keepsWindowHidden: Bool { automatic && sent }
}
