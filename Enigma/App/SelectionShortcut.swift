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
  /// `.first` marks a complete solo tap that could start a double tap; the tests use it to pin where taps begin and end.
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
  /// The action whose double tap this watches for, as chosen in Settings.
  private let action: ShortcutAction

  init(action: ShortcutAction = .selection, handler: @escaping @MainActor () -> Void) {
    self.action = action
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
    case .first, .none: break
    }
  }
}
