import AppKit
import ApplicationServices
import Carbon
import SwiftUI

enum SelectionModifier: String, CaseIterable, Identifiable {
  case option, command, shift, control
  var id: Self { self }
  var title: String { rawValue.capitalized }
  var symbol: String { switch self { case .option: "⌥"; case .command: "⌘"; case .shift: "⇧"; case .control: "⌃" } }
  var flags: NSEvent.ModifierFlags {
    switch self { case .option: .option; case .command: .command; case .shift: .shift; case .control: .control }
  }
  var keyCodes: [UInt16] {
    switch self { case .option: [58, 61]; case .command: [54, 55]; case .shift: [56, 60]; case .control: [59, 62] }
  }

  /// The one modifier in `flags`, if it's one that can be double-tapped.
  init?(flags: NSEvent.ModifierFlags) {
    guard let modifier = Self.allCases.first(where: { $0.flags == flags }) else { return nil }
    self = modifier
  }

  /// What captures a selection, to follow "when you": the double tap of the chosen key
  /// while it's on, and the ⇧⌥Space backup, which is always registered.
  static func shortcutPhrase(modifier: String, isEnabled: Bool) -> String {
    guard isEnabled else { return "press ⇧⌥Space" }
    return "double-tap " + (SelectionModifier(rawValue: modifier) ?? .option).title + " or press ⇧⌥Space"
  }
}

/// How you ask about a selection, to follow "when you", kept current with Settings → Shortcuts.
@MainActor @propertyWrapper struct SelectionShortcutPhrase: DynamicProperty {
  @ObservedObject private var store = ShortcutStore.shared
  var wrappedValue: String {
    if store.selectionSameAsSummon, let summon = store.binding(.summon) { return "press \(summon.display) or ⇧⌥Space" }
    guard let binding = store.binding(.selection) else { return "press ⇧⌥Space" }
    if binding.kind == .doubleTap, let modifier = SelectionModifier(flags: binding.flags) {
      return "double-tap \(modifier.title) or press ⇧⌥Space"
    }
    return "press \(binding.display) or ⇧⌥Space"
  }
}

struct OptionDoubleTap {
  var modifier: SelectionModifier = .option
  var interval: TimeInterval = 0.35
  private var pressedAt: TimeInterval?
  private var releasedAt: TimeInterval?
  private var pressedKey: UInt16?

  /// What a modifier event meant: nothing yet, a first complete tap (which may become
  /// a double tap), or the double tap itself.
  enum Tap: Equatable { case none, first, double }

  mutating func reset() { pressedAt = nil; releasedAt = nil; pressedKey = nil }

  mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Bool {
    tap(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp) == .double
  }

  mutating func tap(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Tap {
    // Caps Lock is a latched state, not a held key, so it never counts as a chord.
    let flags = modifiers.intersection([.option, .command, .control, .shift, .function])
    guard modifier.keyCodes.contains(keyCode), flags.isEmpty || flags == modifier.flags else { reset(); return .none }
    if flags == modifier.flags {
      guard pressedAt == nil else { reset(); return .none }
      pressedAt = timestamp
      pressedKey = keyCode
      return .none
    }
    guard let down = pressedAt, pressedKey == keyCode, timestamp >= down, timestamp - down <= 0.25 else {
      reset(); return .none
    }
    pressedAt = nil
    pressedKey = nil
    if let previous = releasedAt, down >= previous, timestamp - previous <= interval {
      reset(); return .double
    }
    releasedAt = timestamp
    return .first
  }
}

@MainActor
final class SelectionShortcutMonitor {
  nonisolated static let modifierKey = "enigma.selection.modifier"
  nonisolated static let enabledKey = "enigma.selection.doubleOption.enabled"
  static let intervalKey = "enigma.selection.doubleOption.interval"
  private var accessibilityGranted = false
  private var activationObserver: NSObjectProtocol?
  private var global: Any?
  private var local: Any?
  private var detector = OptionDoubleTap()
  private let handler: @MainActor () -> Void
  private let firstTap: @MainActor () -> Void
  /// F14 spike: the action whose double tap this watches for, as chosen in Settings.
  private let action: ShortcutAction

  /// `firstTap` runs when a tap could be the start of a double tap, before it is one.
  init(action: ShortcutAction = .selection, firstTap: @escaping @MainActor () -> Void = {},
       handler: @escaping @MainActor () -> Void) {
    self.action = action
    self.firstTap = firstTap
    self.handler = handler
  }

  func reset() { detector.reset() }

  func start() {
    accessibilityGranted = AXIsProcessTrusted()
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.reset()
          SelectionAccessibilityAccess.shared.refresh()
          if self.accessibilityGranted != AXIsProcessTrusted() {
            self.stop()
            self.start()
          }
        }
      }
    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.receive(event) }
    local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.receive(event)
      return event
    }
  }

  func stop() {
    if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    activationObserver = nil
    if let global { NSEvent.removeMonitor(global) }
    if let local { NSEvent.removeMonitor(local) }
    global = nil; local = nil; detector.reset()
  }

  private func receive(_ event: NSEvent) {
    let store = ShortcutStore.shared
    guard !IsSecureEventInputEnabled(), !store.isRecording, let binding = store.binding(action),
          binding.kind == .doubleTap, let modifier = SelectionModifier(flags: binding.flags) else {
      detector.reset(); return
    }
    if detector.modifier != modifier { detector.reset(); detector.modifier = modifier }
    let configured = UserDefaults.standard.double(forKey: Self.intervalKey)
    detector.interval = configured >= 0.2 && configured <= 0.6 ? configured : 0.35
    guard event.type == .flagsChanged else { detector.reset(); return }
    switch detector.tap(keyCode: event.keyCode, modifiers: event.modifierFlags, timestamp: event.timestamp) {
    case .double: handler()
    case .first: firstTap()
    case .none: break
    }
  }
}

/// A running app, told apart from a later one that reuses its pid by its launch date.
struct SelectionAppKey: Hashable, Sendable {
  let pid: pid_t
  let launchDate: Date?
}

/// What the warmer needs to know about a running app. It never reads the app's contents.
struct SelectionWarmedApp: Equatable, Sendable {
  let key: SelectionAppKey
  let bundleID: String?
  let bundleURL: URL?

  init(key: SelectionAppKey, bundleID: String?, bundleURL: URL?) {
    self.key = key
    self.bundleID = bundleID
    self.bundleURL = bundleURL
  }

  init(_ app: NSRunningApplication) {
    self.init(key: SelectionAppKey(pid: app.processIdentifier, launchDate: app.launchDate),
              bundleID: app.bundleIdentifier, bundleURL: app.bundleURL)
  }
}

/// Asks the frontmost app to turn on its full accessibility tree (`attributes(for:)`)
/// before a capture needs it. Chromium and Electron apps build that tree only on
/// request and take about 2 s to report a focused element afterwards, so doing this
/// when an app comes to the front (and on the first tap of the shortcut) keeps the
/// first capture there from waiting. A freshly launched Electron app ignores the
/// request until it is ready, so after a launch or activation the set is repeated a few
/// times while the same app stays in front. It sets those attributes and reads nothing.
///
/// VS Code-family editors are never warmed: they treat Electron's accessibility support
/// as a screen reader, switch to screen-reader rendering and show a lasting prompt.
/// A capture there still sets the attributes when the user actually invokes Enigma.
@MainActor
final class SelectionAccessibilityWarmer {
  enum Trigger: String, Sendable { case startup, activation, launch, retry, firstTap }

  /// After an app launches or comes to the front, the set is repeated at these delays.
  static let retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]

  /// The attributes that turn on an app's full accessibility tree. Each is set to true and Enigma
  /// never clears it; an unsupported one is harmless.
  nonisolated static func attributes(for bundleID: String?) -> [String] {
    SelectionCapturePolicy.chromiumBrowsers.contains(bundleID ?? "")
      ? ["AXManualAccessibility", "AXEnhancedUserInterface"] : ["AXManualAccessibility"]
  }

  /// Sets each attribute to true and returns its result. Chrome answers `AXEnhancedUserInterface`
  /// with notImplemented (-25208) yet builds its tree about 2 s later.
  @discardableResult
  nonisolated static func turnOnAccessibility(
    _ application: AXUIElement, attributes: [String],
    set: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
  ) -> [AXError] {
    attributes.map { set(application, $0 as CFString, kCFBooleanTrue) }
  }

  private let isTrusted: () -> Bool
  private let ownPID: pid_t
  private let frontmostPID: () -> pid_t?
  private let appInfo: (pid_t) -> SelectionWarmedApp?
  private let fileExists: (URL) -> Bool
  private let enable: (pid_t, [String], Trigger) -> Void
  private let schedule: (Duration, @escaping @MainActor () -> Void) -> Void
  private let center: NotificationCenter
  private let history: SelectionWarmHistory
  private var observers: [NSObjectProtocol] = []
  /// Bumped by each activation and by `stop()`; a retry from an older one does nothing.
  private var generation = 0

  init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
       ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
       frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
       appInfo: @escaping (pid_t) -> SelectionWarmedApp? = {
         NSRunningApplication(processIdentifier: $0).map(SelectionWarmedApp.init)
       },
       fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
       enable: @escaping (pid_t, [String], Trigger) -> Void = SelectionAccessibilityWarmer.enableAccessibility,
       schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> Void = SelectionAccessibilityWarmer.afterDelay,
       center: NotificationCenter = NSWorkspace.shared.notificationCenter,
       history: SelectionWarmHistory = .shared) {
    self.isTrusted = isTrusted
    self.ownPID = ownPID
    self.frontmostPID = frontmostPID
    self.appInfo = appInfo
    self.fileExists = fileExists
    self.enable = enable
    self.schedule = schedule
    self.center = center
    self.history = history
  }

  /// Warms the current frontmost app, then each app as it launches or becomes frontmost.
  func start() {
    guard observers.isEmpty else { return }
    for (name, trigger) in [(NSWorkspace.didActivateApplicationNotification, Trigger.activation),
                            (NSWorkspace.didLaunchApplicationNotification, Trigger.launch)] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        MainActor.assumeIsolated { self?.appeared(pid: pid, trigger: trigger) }
      })
    }
    warm(pid: frontmostPID(), trigger: .startup)
  }

  func stop() {
    observers.forEach(center.removeObserver)
    observers.removeAll()
    generation += 1
  }

  func warmFrontmost() { warm(pid: frontmostPID(), trigger: .firstTap) }

  /// An app launched or came to the front: warm it now and retry while it stays in front.
  /// A launch in the background is left to its own activation.
  func appeared(pid: pid_t?, trigger: Trigger) {
    guard let pid, trigger != .launch || frontmostPID() == pid, eligibleApp(pid) != nil else { return }
    generation += 1
    let current = generation
    warm(pid: pid, trigger: trigger)
    for delay in Self.retryDelays {
      schedule(delay) { [weak self] in
        guard let self, self.generation == current, self.frontmostPID() == pid else { return }
        self.warm(pid: pid, trigger: .retry)
      }
    }
  }

  func warm(pid: pid_t?, trigger: Trigger) {
    guard let pid, let app = eligibleApp(pid) else { return }
    history.record(app.key, trigger: trigger)
    enable(pid, Self.attributes(for: app.bundleID), trigger)
  }

  private func eligibleApp(_ pid: pid_t) -> SelectionWarmedApp? {
    guard pid > 0, pid != ownPID, isTrusted(), let app = appInfo(pid),
          Self.isWarmable(app, fileExists: fileExists) else { return nil }
    return app
  }

  /// An app is warmed only when Enigma knows what it is and it isn't built on VS Code:
  /// one of the known editors, or any bundle with VS Code's `product.json` (forks such as
  /// Cursor and Windsurf). This checks that the file exists; it reads nothing from it.
  nonisolated static func isWarmable(_ app: SelectionWarmedApp, fileExists: (URL) -> Bool) -> Bool {
    guard let bundleID = app.bundleID, let bundleURL = app.bundleURL,
          !SelectionCapturePolicy.codeEditors.contains(bundleID) else { return false }
    return !fileExists(bundleURL.appendingPathComponent("Contents/Resources/app/product.json"))
  }

  nonisolated static func afterDelay(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
    let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(action) }
  }

  private nonisolated static let queue = DispatchQueue(label: "enigma.selection.accessibility-warmer", qos: .utility)

  /// Runs off the main thread, so an app that is slow or hung can't delay Enigma's
  /// shortcut handling; a serial queue keeps repeated activations from piling up threads.
  nonisolated static func enableAccessibility(_ pid: pid_t, attributes: [String], trigger: Trigger) {
    queue.async {
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.25)
      // Unsupported in native apps and some browsers; the error is harmless.
      let result = turnOnAccessibility(application, attributes: attributes)
        .map { String($0.rawValue) }.joined(separator: ",")
      // Debug level: not kept in the persistent log; watch it with `log stream --level debug`.
      SelectionLog.logger.debug("warm trigger=\(trigger.rawValue, privacy: .public) result=\(result, privacy: .public)")
    }
  }
}

/// How long ago an app was warmed, taken when a capture starts.
struct SelectionWarmSnapshot: Equatable {
  /// The latest warm by startup, activation, launch or retry.
  var sinceWarm: Duration?
  var trigger: SelectionAccessibilityWarmer.Trigger?
  /// The latest first-tap warm, kept apart so it can't hide the earlier one.
  var sinceFirstTap: Duration?
}

/// When each app was last warmed, in memory only, for the capture log line. Keyed by
/// pid and launch date, so a new app that reuses a pid starts with no history.
@MainActor
final class SelectionWarmHistory {
  static let shared = SelectionWarmHistory()
  private let now: () -> Duration
  private var warms: [SelectionAppKey: (time: Duration, trigger: SelectionAccessibilityWarmer.Trigger)] = [:]
  private var firstTaps: [SelectionAppKey: Duration] = [:]

  init(now: @escaping () -> Duration = SelectionCaptureRetry.uptime) { self.now = now }

  func record(_ key: SelectionAppKey, trigger: SelectionAccessibilityWarmer.Trigger) {
    if trigger == .firstTap { firstTaps[key] = now() } else { warms[key] = (now(), trigger) }
  }

  func snapshot(_ key: SelectionAppKey) -> SelectionWarmSnapshot {
    let time = now()
    return SelectionWarmSnapshot(sinceWarm: warms[key].map { time - $0.time }, trigger: warms[key]?.trigger,
                                 sinceFirstTap: firstTaps[key].map { time - $0 })
  }
}
