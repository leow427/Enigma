@preconcurrency import Carbon
import AppKit
import Combine
import ApplicationServices

enum GlobalHotKey: CaseIterable {
  case selectionContext

  var keyCode: UInt32 {
    switch self {
    case .selectionContext: UInt32(kVK_Space)
    }
  }

  var modifiers: UInt32 { UInt32(optionKey | shiftKey) }

  var identifier: UInt32 {
    switch self {
    case .selectionContext: 3
    }
  }

  var displayName: String {
    switch self {
    case .selectionContext: "Shift-Option-Space"
    }
  }
}

enum GlobalHotKeyError: LocalizedError {
  case eventHandlerInstallationFailed(OSStatus)
  case registrationFailed(String, OSStatus)

  var errorDescription: String? {
    switch self {
    case .eventHandlerInstallationFailed(let status):
      "The keyboard event handler could not be installed (status \(status))."
    case .registrationFailed(let name, let status):
      "\(name) could not be registered (status \(status))."
    }
  }
}

// Carbon invokes handlers installed on the application event target on the main event loop.
// The unchecked conformance documents that the mutable registration references stay there.
final class GlobalHotKeyMonitor: @unchecked Sendable {
  private static let signature: OSType = 0x4149_5350 // AISP

  private let keyCode: UInt32
  private let modifiers: UInt32
  private let identifier: UInt32
  private let name: String
  private let handler: @MainActor () -> Void
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?

  convenience init(
    hotKey: GlobalHotKey,
    handler: @escaping @MainActor () -> Void
  ) {
    self.init(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers, identifier: hotKey.identifier,
              name: hotKey.displayName, handler: handler)
  }

  /// Any key and modifiers, for a shortcut chosen in Settings.
  init(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, name: String,
       handler: @escaping @MainActor () -> Void) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.identifier = identifier
    self.name = name
    self.handler = handler
  }

  func start() throws {
    guard hotKey == nil else { return }

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let handlerStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      globalHotKeyEventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard handlerStatus == noErr else {
      throw GlobalHotKeyError.eventHandlerInstallationFailed(handlerStatus)
    }

    let hotKeyID = EventHotKeyID(
      signature: Self.signature,
      id: identifier
    )
    let registrationStatus = RegisterEventHotKey(
      keyCode,
      modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard registrationStatus == noErr else {
      stop()
      throw GlobalHotKeyError.registrationFailed(name, registrationStatus)
    }
  }

  func stop() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  fileprivate func receive(_ event: EventRef) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == Self.signature,
          hotKeyID.id == identifier else {
      return OSStatus(eventNotHandledErr)
    }

    MainActor.assumeIsolated {
      handler()
    }
    return noErr
  }
}

private func globalHotKeyEventHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
  return monitor.receive(event)
}

// A modifier-only shortcut cannot be registered as a Carbon hot key. This one
// is a tap: it fires when Option and Control, pressed together with no other
// modifier, key press or click in between, are released. Chords such as
// Control-Option-Right, VoiceOver commands and Control-Option-Command shortcuts
// never fire it.
struct PanelShortcutChord {
  private enum Phase {
    /// Nothing is held.
    case idle
    /// Only Option or only Control is held.
    case partial
    /// Both are held, with nothing else.
    case armed
    /// Spoiled or already fired; ignored until every modifier is released.
    case cancelled
  }

  private var phase = Phase.idle
  private var armedCounter: UInt32 = 0
  /// The modifiers pressed together, ⌥⌃ unless chosen in Settings.
  var chord: NSEvent.ModifierFlags = [.option, .control]
  /// A count of key and mouse-button presses system-wide. Global monitors never
  /// see a key another app consumes as a hot key (like Control-Option-Right in
  /// a window manager), but this count does, so a change since the chord armed
  /// means something else was pressed.
  private let inputCounter: () -> UInt32

  init(inputCounter: @escaping () -> UInt32 = { 0 }) { self.inputCounter = inputCounter }

  /// Adopts the current modifiers without firing, for when events were missed.
  mutating func synchronize(modifiers: NSEvent.ModifierFlags) {
    phase = modifiers.intersection(Self.tracked).isEmpty ? .idle : .cancelled
  }

  /// A key press or mouse click turns the held modifiers into another shortcut.
  mutating func cancel() {
    if phase != .idle { phase = .cancelled }
  }

  /// Returns true when the tap completes: the first release of either key.
  mutating func flagsChanged(modifiers: NSEvent.ModifierFlags) -> Bool {
    let flags = modifiers.intersection(Self.tracked)
    if flags.isEmpty {
      defer { phase = .idle }
      return phase == .armed && completes()
    }
    guard flags.subtracting(chord).isEmpty else {
      phase = .cancelled
      return false
    }
    switch phase {
    case .idle, .partial:
      phase = flags == chord ? .armed : .partial
      if phase == .armed { armedCounter = inputCounter() }
      return false
    case .armed:
      if flags == chord { return false }
      phase = .cancelled
      return completes()
    case .cancelled:
      return false
    }
  }

  private func completes() -> Bool { inputCounter() == armedCounter }

  private static let tracked: NSEvent.ModifierFlags = [.option, .control, .command, .shift, .function]
}

@MainActor
final class PanelShortcutMonitor {
  private var global: Any?
  private var local: Any?
  private var activationObserver: NSObjectProtocol?
  private var accessibilityGranted = false
  private var detector = PanelShortcutMonitor.makeDetector()
  private let handler: @MainActor () -> Void
  /// The action whose chord this watches for, as chosen in Settings.
  private let action: ShortcutAction

  init(action: ShortcutAction = .summon, handler: @escaping @MainActor () -> Void) {
    self.action = action
    self.handler = handler
  }

  func start() {
    guard local == nil else { return }
    accessibilityGranted = AXIsProcessTrusted()
    detector.synchronize(modifiers: NSEvent.modifierFlags)
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.accessibilityGranted != AXIsProcessTrusted() {
          self.stop()
          self.start()
        }
      }
    }
    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.receive(event)
    }
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
    global = nil
    local = nil
    detector = Self.makeDetector()
  }

  private static func makeDetector() -> PanelShortcutChord {
    PanelShortcutChord {
      [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(0) {
        $0 &+ CGEventSource.counterForEventType(.hidSystemState, eventType: $1)
      }
    }
  }

  private func receive(_ event: NSEvent) {
    let store = ShortcutStore.shared
    guard !IsSecureEventInputEnabled(), !store.isRecording,
          let binding = store.binding(action), binding.kind == .chord else {
      detector.synchronize(modifiers: event.modifierFlags)
      return
    }
    if detector.chord != binding.flags {
      detector.chord = binding.flags
      detector.synchronize(modifiers: event.modifierFlags)
    }
    guard event.type == .flagsChanged else {
      detector.cancel()
      return
    }
    if detector.flagsChanged(modifiers: event.modifierFlags) {
      handler()
    }
  }
}

/// Global hot keys for the actions set to keys with modifiers in
/// Settings → Shortcuts, registered again whenever the shortcuts change.
@MainActor
final class ShortcutHotKeys {
  private let handlers: [ShortcutAction: @MainActor () -> Void]
  private var monitors: [GlobalHotKeyMonitor] = []
  private var observation: AnyCancellable?

  init(handlers: [ShortcutAction: @MainActor () -> Void]) { self.handlers = handlers }

  func start() {
    let store = ShortcutStore.shared
    observation = store.$overrides.combineLatest(store.$selectionSameAsSummon)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _, _ in self?.register() }
  }

  func stop() {
    observation = nil
    monitors.forEach { $0.stop() }
    monitors = []
  }

  private func register() {
    monitors.forEach { $0.stop() }
    monitors = []
    for (index, action) in ShortcutAction.global.enumerated() {
      guard let binding = ShortcutStore.shared.binding(action), binding.kind == .keys,
            let handler = handlers[action] else { continue }
      let monitor = GlobalHotKeyMonitor(keyCode: UInt32(binding.keyCode), modifiers: Self.carbon(binding.flags),
                                        identifier: UInt32(10 + index), name: binding.display) {
        if !ShortcutStore.shared.isRecording { handler() }
      }
      do {
        try monitor.start()
        monitors.append(monitor)
      } catch {
        NSLog("Unable to register %@: %@", binding.display, error.localizedDescription)
      }
    }
  }

  private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers = 0
    if flags.contains(.command) { modifiers |= cmdKey }
    if flags.contains(.option) { modifiers |= optionKey }
    if flags.contains(.control) { modifiers |= controlKey }
    if flags.contains(.shift) { modifiers |= shiftKey }
    return UInt32(modifiers)
  }
}
