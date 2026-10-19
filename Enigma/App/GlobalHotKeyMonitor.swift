@preconcurrency import Carbon
import AppKit
import ApplicationServices

enum GlobalHotKey: CaseIterable {
  case selectionContext

  var keyCode: UInt32 {
    switch self {
    case .selectionContext: UInt32(kVK_Space)
    }
  }

  var modifiers: UInt32 { UInt32(optionKey | shiftKey) }

  fileprivate var identifier: UInt32 {
    switch self {
    case .selectionContext: 3
    }
  }

  fileprivate var displayName: String {
    switch self {
    case .selectionContext: "Shift-Option-Space"
    }
  }
}

enum GlobalHotKeyError: LocalizedError {
  case eventHandlerInstallationFailed(OSStatus)
  case registrationFailed(GlobalHotKey, OSStatus)

  var errorDescription: String? {
    switch self {
    case .eventHandlerInstallationFailed(let status):
      "The keyboard event handler could not be installed (status \(status))."
    case .registrationFailed(let hotKey, let status):
      "\(hotKey.displayName) could not be registered (status \(status))."
    }
  }
}

// Carbon invokes handlers installed on the application event target on the main event loop.
// The unchecked conformance documents that the mutable registration references stay there.
final class GlobalHotKeyMonitor: @unchecked Sendable {
  private static let signature: OSType = 0x4149_5350 // AISP

  private let hotKeyDefinition: GlobalHotKey
  private let handler: @MainActor () -> Void
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?

  init(
    hotKey: GlobalHotKey,
    handler: @escaping @MainActor () -> Void
  ) {
    self.hotKeyDefinition = hotKey
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
      id: hotKeyDefinition.identifier
    )
    let registrationStatus = RegisterEventHotKey(
      hotKeyDefinition.keyCode,
      hotKeyDefinition.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard registrationStatus == noErr else {
      stop()
      throw GlobalHotKeyError.registrationFailed(hotKeyDefinition, registrationStatus)
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
          hotKeyID.id == hotKeyDefinition.identifier else {
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
    guard flags.subtracting([.option, .control]).isEmpty else {
      phase = .cancelled
      return false
    }
    switch phase {
    case .idle, .partial:
      phase = flags == [.option, .control] ? .armed : .partial
      if phase == .armed { armedCounter = inputCounter() }
      return false
    case .armed:
      if flags == [.option, .control] { return false }
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

  init(handler: @escaping @MainActor () -> Void) { self.handler = handler }

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
    guard !IsSecureEventInputEnabled() else {
      detector.synchronize(modifiers: event.modifierFlags)
      return
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
