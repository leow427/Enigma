@preconcurrency import Carbon
import AppKit
import ApplicationServices

enum GlobalHotKey: CaseIterable {
  case openSettings
  case selectionContext

  var keyCode: UInt32 {
    switch self {
    case .openSettings: UInt32(kVK_ANSI_S)
    case .selectionContext: UInt32(kVK_Space)
    }
  }

  var modifiers: UInt32 { self == .selectionContext ? UInt32(optionKey | shiftKey) : UInt32(optionKey) }

  fileprivate var identifier: UInt32 {
    switch self {
    case .openSettings: 2
    case .selectionContext: 3
    }
  }

  fileprivate var displayName: String {
    switch self {
    case .openSettings: "Option-S"
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

// A modifier-only shortcut cannot be registered as a Carbon hot key.
struct PanelShortcutChord {
  private var waitingForRelease = false

  mutating func synchronize(modifiers: NSEvent.ModifierFlags) {
    waitingForRelease = !modifiers.intersection([.option, .control]).isEmpty
  }

  mutating func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let flags = modifiers.intersection([.option, .control, .command, .shift, .function])
    if flags.intersection([.option, .control]).isEmpty {
      waitingForRelease = false
      return false
    }
    guard !waitingForRelease else { return false }
    guard flags.subtracting([.option, .control]).isEmpty else {
      waitingForRelease = true
      return false
    }
    guard [UInt16(58), 61, 59, 62].contains(keyCode), flags == [.option, .control] else { return false }
    waitingForRelease = true
    return true
  }
}

@MainActor
final class PanelShortcutMonitor {
  private var global: Any?
  private var local: Any?
  private var activationObserver: NSObjectProtocol?
  private var accessibilityGranted = false
  private var detector = PanelShortcutChord()
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
    global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.receive(event)
    }
    local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
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
    detector = PanelShortcutChord()
  }

  private func receive(_ event: NSEvent) {
    guard !IsSecureEventInputEnabled() else {
      detector.synchronize(modifiers: event.modifierFlags)
      return
    }
    if detector.flagsChanged(keyCode: event.keyCode, modifiers: event.modifierFlags) {
      handler()
    }
  }
}
