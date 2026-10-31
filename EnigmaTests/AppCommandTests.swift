import AppKit
@preconcurrency import Carbon
import XCTest
@testable import Enigma

final class AppCommandTests: XCTestCase {
  func testShowHideChordFiresOnReleaseOfOptionAndControlPressedTogether() {
    var chord = PanelShortcutChord()
    XCTAssertFalse(chord.flagsChanged(modifiers: .option))
    XCTAssertFalse(chord.flagsChanged(modifiers: [.option, .control]), "Pressing fires nothing")
    XCTAssertTrue(chord.flagsChanged(modifiers: .option), "Releasing one of the pair completes the tap")
    XCTAssertFalse(chord.flagsChanged(modifiers: []))
    XCTAssertFalse(chord.flagsChanged(modifiers: .control))
    XCTAssertFalse(chord.flagsChanged(modifiers: [.control, .option]))
    XCTAssertTrue(chord.flagsChanged(modifiers: []), "Releasing both at once fires too")
  }

  func testShowHideChordIgnoresKeysClicksAndExtraModifiers() {
    var chord = PanelShortcutChord()
    _ = chord.flagsChanged(modifiers: [.option, .control])
    chord.cancel() // ⌃⌥→ or a click while held
    XCTAssertFalse(chord.flagsChanged(modifiers: .control))
    XCTAssertFalse(chord.flagsChanged(modifiers: []))

    _ = chord.flagsChanged(modifiers: [.option, .control])
    XCTAssertFalse(chord.flagsChanged(modifiers: [.option, .control, .command]))
    XCTAssertFalse(chord.flagsChanged(modifiers: [.option, .control]), "Command leaving does not revive it")
    XCTAssertFalse(chord.flagsChanged(modifiers: []))

    _ = chord.flagsChanged(modifiers: [.option, .control, .shift])
    XCTAssertFalse(chord.flagsChanged(modifiers: [.option, .control]))
    XCTAssertFalse(chord.flagsChanged(modifiers: []))

    XCTAssertFalse(chord.flagsChanged(modifiers: .option))
    XCTAssertFalse(chord.flagsChanged(modifiers: []), "Option alone")
    XCTAssertFalse(chord.flagsChanged(modifiers: .control))
    XCTAssertFalse(chord.flagsChanged(modifiers: []), "Control alone")
    chord.cancel()
    XCTAssertFalse(chord.flagsChanged(modifiers: []))
  }

  func testShowHideChordIgnoresInputSwallowedByAnotherApp() {
    var counter: UInt32 = 5
    var chord = PanelShortcutChord { counter }
    _ = chord.flagsChanged(modifiers: [.option, .control])
    counter += 1 // a hot key consumed by a window manager, unseen by event monitors
    XCTAssertFalse(chord.flagsChanged(modifiers: .control))
    XCTAssertFalse(chord.flagsChanged(modifiers: []))

    _ = chord.flagsChanged(modifiers: [.option, .control])
    counter += 1
    XCTAssertFalse(chord.flagsChanged(modifiers: []), "Releasing both at once")

    _ = chord.flagsChanged(modifiers: [.option, .control])
    XCTAssertTrue(chord.flagsChanged(modifiers: .control), "Nothing pressed, so it fires")
  }

  func testShowHideChordFiresAgainAfterACancelledChord() {
    var chord = PanelShortcutChord()
    _ = chord.flagsChanged(modifiers: [.option, .control])
    chord.cancel()
    _ = chord.flagsChanged(modifiers: [])
    XCTAssertFalse(chord.flagsChanged(modifiers: [.option, .control]))
    XCTAssertTrue(chord.flagsChanged(modifiers: .control))
  }

  func testShowHideChordSynchronizeIgnoresModifiersAlreadyHeld() {
    var chord = PanelShortcutChord()
    chord.synchronize(modifiers: [.option, .control])
    XCTAssertFalse(chord.flagsChanged(modifiers: .option), "Held before monitoring began")
    XCTAssertFalse(chord.flagsChanged(modifiers: []))
    chord.synchronize(modifiers: [])
    _ = chord.flagsChanged(modifiers: [.option, .control])
    XCTAssertTrue(chord.flagsChanged(modifiers: []))
  }

  func testMenuCommandsHaveExpectedOrderAndTitles() {
    XCTAssertEqual(
      AppCommand.allCases.map(\.rawValue),
      ["Open", "New Chat", "Privacy Hide", "Restart to Update", "Check for Updates…", "Settings", "Quit"]
    )
  }

  @MainActor
  func testStartupPreferencesPersistAndRecoverInvalidValues() {
    let name = "StartPreferencesTests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = StartPreferences(defaults: defaults)
    XCTAssertEqual(preferences.mode, .auto)
    XCTAssertFalse(preferences.showsSidebar)
    for mode in ChatMode.allCases {
      preferences.mode = mode
      preferences.showsSidebar = true
      let restored = StartPreferences(defaults: defaults)
      XCTAssertEqual(restored.mode, mode)
      XCTAssertTrue(restored.showsSidebar)
    }
    defaults.set("removed-mode", forKey: StartPreferences.modeKey)
    XCTAssertEqual(StartPreferences(defaults: defaults).mode, .auto)
    preferences.showsSidebar = false
    XCTAssertFalse(StartPreferences(defaults: defaults).showsSidebar)
  }

  func testPanelShortcutsRequireOnlyTheCommandModifier() {
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "n", modifiers: .command),
      .newChat
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "K", modifiers: .command),
      .modePalette
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: ".", modifiers: .command),
      .stopStreaming
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "\t", modifiers: .control),
      .cycleRecentChat
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: ",", modifiers: .command),
      .settings
    )
    XCTAssertNil(PanelShortcut.resolve(characters: ",", modifiers: [.command, .shift]))
    XCTAssertNil(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .shift])
    )
    XCTAssertEqual(
      PanelShortcut.resolve(characters: "n", modifiers: [.command, .capsLock]),
      .newChat
    )
    XCTAssertNil(PanelShortcut.resolve(characters: "n", modifiers: []))
  }

  func testSidebarOpenInWindowAndAttachShortcuts() {
    // Control changes the characters, so S is matched by its key code.
    XCTAssertEqual(PanelShortcut.resolve(characters: "\u{13}", modifiers: [.control, .command], keyCode: 1), .toggleSidebar)
    XCTAssertNil(PanelShortcut.resolve(characters: "s", modifiers: .command, keyCode: 1))
    XCTAssertNil(PanelShortcut.resolve(characters: "s", modifiers: [.control, .command, .shift], keyCode: 1))
    XCTAssertEqual(PanelShortcut.resolve(characters: "o", modifiers: .command), .openInWindow)
    XCTAssertNil(PanelShortcut.resolve(characters: "o", modifiers: [.command, .shift]))
    XCTAssertEqual(PanelShortcut.resolve(characters: "A", modifiers: [.command, .shift]), .fileMode)
    XCTAssertEqual(PanelShortcut.resolve(characters: nil, modifiers: [.command, .shift, .capsLock], keyCode: 0), .fileMode)
    XCTAssertNil(PanelShortcut.resolve(characters: "q", modifiers: [.command, .shift], keyCode: 0), "AZERTY: this key is Q")
    XCTAssertEqual(PanelShortcut.resolve(characters: "s", modifiers: [.control, .command], keyCode: 31), .toggleSidebar)
    XCTAssertEqual(PanelShortcut.resolve(characters: "S", modifiers: [.control, .command], keyCode: 31), .toggleSidebar)
    XCTAssertNil(PanelShortcut.resolve(characters: "o", modifiers: [.control, .command], keyCode: 1), "QWERTY S key, but an O on this layout")
    XCTAssertNil(PanelShortcut.resolve(characters: "a", modifiers: .command))
    XCTAssertNil(PanelShortcut.resolve(characters: "f", modifiers: [.shift, .option], keyCode: 3), "⇧⌥F is gone")
    XCTAssertNil(PanelShortcut.resolve(characters: "h", modifiers: [.command, .shift], keyCode: 4), "⇧⌘H is gone")
  }

  @MainActor
  func testOpenInWindowShortcutIsNotConsumedOutsideTheSelectionPanel() throws {
    let field = NSTextField(string: "Keep my unsent text")
    let controller = SpotlightPanelController(contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
    XCTAssertFalse(window.performKeyEquivalent(with: event), "⌘O is left alone outside the selection panel")
    XCTAssertEqual(field.stringValue, "Keep my unsent text")
    XCTAssertTrue(controller.isVisible)
  }

  @MainActor
  func testSidebarShortcutWorksWhileTypingWithoutChangingDraft() throws {
    let field = NSTextField(string: "Keep my unsent text")
    let controller = SpotlightPanelController(contentView: field)
    controller.show()
    defer { controller.hide() }
    let window = try XCTUnwrap(field.window)
    XCTAssertTrue(window.makeFirstResponder(field))
    let delivered = expectation(forNotification: .sidebarToggleRequested, object: nil)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.control, .command], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "\u{13}", charactersIgnoringModifiers: "\u{13}", isARepeat: false, keyCode: 1))
    XCTAssertTrue(window.performKeyEquivalent(with: event))
    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(field.stringValue, "Keep my unsent text")
    XCTAssertTrue(controller.isVisible)
  }

  func testOnlyTheSelectionBackupIsAGlobalHotKey() {
    XCTAssertEqual(GlobalHotKey.allCases, [.selectionContext])
    XCTAssertEqual(GlobalHotKey.selectionContext.keyCode, UInt32(kVK_Space))
    XCTAssertEqual(GlobalHotKey.selectionContext.modifiers, UInt32(optionKey | shiftKey))
  }

  func testPanelSizeStoreUsesDefaultAndPersistsOnlySize() {
    let suiteName = "PanelSizeStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PanelSizeStore(defaults: defaults)

    XCTAssertEqual(store.load(), PanelSizeStore.defaultSize)

    store.save(NSSize(width: 900, height: 610))

    XCTAssertEqual(store.load(), NSSize(width: 900, height: 610))
    let persistentDomain = defaults.persistentDomain(forName: suiteName) ?? [:]
    let persistedKeys = Set(persistentDomain.keys)
    XCTAssertEqual(
      persistedKeys,
      ["aiSpotlight.panel.width", "aiSpotlight.panel.height"]
    )
  }

  @MainActor
  func testWelcomeTemporarilyEnlargesPanelThroughTourWithoutSavingItsSize() async throws {
    let suite = "WelcomePanel-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PanelSizeStore(defaults: defaults)
    let normal = NSSize(width: 900, height: 610)
    store.save(normal)
    let setup = WelcomeSetup(defaults: defaults)
    let view = NSView()
    let controller = SpotlightPanelController(sizeStore: store, contentView: view, welcomeSetup: setup)
    let window = try XCTUnwrap(view.window)
    defer { controller.hide() }
    func settleSizing() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    setup.start(hasInstalledModels: false)
    await settleSizing()
    let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
    let enlarged = PanelSizeStore.centeredFrame(size: NSSize(width: 1280, height: 860), in: visible).size
    XCTAssertEqual(window.frame.size, enlarged)
    controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    XCTAssertEqual(store.load(), normal)
    // The hands-on tour grows the window by its rail.
    setup.finish(takeTour: true)
    await settleSizing()
    let touring = PanelSizeStore.centeredFrame(
      size: NSSize(width: 1280 + GuidedTourPlacement.railWidth, height: 860), in: visible).size
    XCTAssertEqual(window.frame.size, touring)
    GuidedTour.shared.end()
    await settleSizing()
    XCTAssertEqual(window.frame.size, normal)
    setup.replay()
    await settleSizing()
    XCTAssertEqual(window.frame.size, enlarged)
    setup.finish(takeTour: false)
    await settleSizing()
    XCTAssertEqual(window.frame.size, normal)
    XCTAssertEqual(store.load(), normal)
  }

  @MainActor
  func testPanelRequestsCaptureExclusionWhileRemainingVisibleAndEditable() throws {
    let draft = NSTextField(string: "Visible only where capture exclusion is supported")
    let controller = SpotlightPanelController(
      contentView: draft
    )
    let window = try XCTUnwrap(draft.window)
    defer { controller.hide() }

    // Verify the flag is configured before the window's first presentation.
    XCTAssertEqual(window.sharingType, .none)
    controller.show()
    XCTAssertTrue(controller.isVisible)
    XCTAssertTrue(window.makeFirstResponder(draft))
    draft.stringValue = "The local panel remains usable"
    XCTAssertEqual(window.sharingType, .none)

    controller.hide()
    controller.show()
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertEqual(draft.stringValue, "The local panel remains usable")
  }

  @MainActor
  func testSettingsWindowOpensAndReopensWithoutASwiftUIScene() async throws {
    let controller = try isolatedSettingsWindowController()
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }

    XCTAssertEqual(window.sharingType, .none)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.backgroundColor, EnigmaAppearance.windowBackground)
    controller.showSettings()
    try await waitForUI("Settings to become key") { window.isKeyWindow }
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible)

    controller.showSettings()
    try await waitForUI("reopened Settings to become key") { window.isKeyWindow }
    XCTAssertTrue(controller.window === window)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
  }

  @MainActor
  func testOpeningAdvancedSettingsPreservesChatVisibilityAndDraft() async throws {
    let draft = NSTextField(string: "Keep this unsent message")
    let panel = SpotlightPanelController(
      contentView: draft
    )
    let settings = try isolatedSettingsWindowController()
    let window = try XCTUnwrap(settings.window)
    let delegate = ApplicationDelegate(panelController: panel, settingsWindowController: settings)
    defer {
      window.close()
      panel.hide()
    }

    panel.show()
    delegate.openSettings()
    try await waitForUI("advanced Settings to become key") { window.isKeyWindow }
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isKeyWindow)
    XCTAssertEqual(window.level, .floating)
    XCTAssertEqual(draft.stringValue, "Keep this unsent message")

    window.performClose(nil)
    XCTAssertTrue(panel.isVisible)
    delegate.openSettings()
    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(draft.stringValue, "Keep this unsent message")

    panel.hide()
    delegate.openSettings()
    XCTAssertFalse(panel.isVisible, "Opening Settings must also respect an already hidden chat.")
  }

  /// The Settings window, whatever the installed app's appearance setting is.
  @MainActor
  private func isolatedSettingsWindowController() throws -> SettingsWindowController {
    let name = "AppCommandTests-Settings-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return SettingsWindowController(contentView: NSView(), appearance: EnigmaAppearancePreference(defaults: defaults))
  }

  func testPanelFrameIsCenteredAndConstrainedToDisplay() {
    let visibleFrame = NSRect(x: 100, y: 50, width: 700, height: 500)

    let frame = PanelSizeStore.centeredFrame(
      size: NSSize(width: 760, height: 520),
      in: visibleFrame
    )

    XCTAssertEqual(frame, visibleFrame)
  }

  // MARK: Shortcuts you choose

  private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                   keyCode: code))
  }

  @MainActor
  func testSavedKeysHaveTheirFinalNames() {
    XCTAssertEqual(GuidedTour.progressKey, "guidedTour.stop.v1")
    XCTAssertEqual(ShortcutStore.overridesKey, "enigma.shortcuts.overrides.v1")
    XCTAssertEqual(ShortcutStore.sameAsSummonKey, "enigma.shortcuts.selectionSameAsSummon.v1")
  }

  @MainActor
  func testDefaultShortcutsAreTodaysAndChangesPersistAndReset() throws {
    let suite = "ShortcutStoreTest-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    let expected: [(UInt16, NSEvent.ModifierFlags, PanelShortcut)] = [
      (45, .command, .newChat), (40, .command, .modePalette), (47, .command, .stopStreaming),
      (48, .control, .cycleRecentChat), (43, .command, .settings), (1, [.control, .command], .toggleSidebar),
      (31, .command, .openInWindow), (0, [.shift, .command], .fileMode),
    ]
    for (code, flags, shortcut) in expected {
      XCTAssertEqual(store.action(for: try key(code, flags)), .panel(shortcut), "\(shortcut)")
    }
    XCTAssertNil(store.action(for: try key(45, [.command, .shift])), "⇧⌘N is not New chat")
    XCTAssertEqual(store.binding(.summon)?.display, "⌃⌥")

    let think = KeyBinding.keys("t", [.control, .option])
    store.set(think, for: .command(.think))
    store.set(nil, for: .panel(.newChat))
    XCTAssertEqual(store.action(for: try key(17, [.control, .option])), .command(.think))
    XCTAssertNil(store.action(for: try key(45, .command)), "New chat's shortcut was removed")
    let reloaded = ShortcutStore(defaults: defaults)
    XCTAssertEqual(reloaded.binding(.command(.think)), think)
    XCTAssertNil(reloaded.binding(.panel(.newChat)))
    reloaded.reset(.panel(.newChat))
    XCTAssertEqual(reloaded.action(for: try key(45, .command)), .panel(.newChat))
    reloaded.selectionSameAsSummon = true
    XCTAssertNil(reloaded.binding(.selection))
    reloaded.resetAll()
    XCTAssertNil(reloaded.binding(.command(.think)))
    XCTAssertFalse(reloaded.selectionSameAsSummon)
  }

  @MainActor
  func testAShortcutThatIsTakenIsRefused() throws {
    let suite = "ShortcutStoreTest-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    XCTAssertEqual(store.conflict(.keys("n", .command), for: .command(.search)),
                   ShortcutConflict(message: "⌘N is already New chat.", blocks: true))
    XCTAssertNil(store.conflict(.keys("n", .command), for: .panel(.newChat)), "Its own shortcut is free")
    XCTAssertEqual(store.conflict(.keys("q", .command), for: .command(.search)),
                   ShortcutConflict(message: "macOS uses ⌘Q for Quit.", blocks: false))
    XCTAssertEqual(store.conflict(ShortcutStore.selectionBackup, for: .summon)?.blocks, true)
    XCTAssertEqual(store.conflict(KeyBinding(kind: .chord, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue),
                                  for: .selection)?.message, "⌃⌥ is already Open or hide Enigma.")
    XCTAssertNil(store.conflict(.keys("t", [.control, .option]), for: .command(.think)))
    XCTAssertEqual(KeyBinding(kind: .doubleTap, modifiers: NSEvent.ModifierFlags.option.rawValue).display, "⌥⌥")
  }

  @MainActor
  func testAMacOSShortcutWarnsButIsAllowed() throws {
    let suite = "ShortcutStoreTest-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    let conflict = try XCTUnwrap(store.conflict(.keys(" ", .command, keyCode: 49), for: .panel(.newChat)))
    XCTAssertFalse(conflict.blocks)
    XCTAssertEqual(conflict.message, "macOS uses ⌘Space for Spotlight.")
  }

  @MainActor
  func testHelpListsAChangedShortcut() throws {
    let suite = "ShortcutStoreTest-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    store.set(.keys("j", .command), for: .panel(.newChat))
    let shortcuts = KeyboardShortcutsHelp.windowShortcuts(store)
    XCTAssertTrue(shortcuts.contains(KeyboardShortcutsHelp.Shortcut("New chat", "⌘J")), "\(shortcuts)")
    XCTAssertEqual(KeyboardShortcutsHelp.summon(store).keys, "⌃⌥")
  }

  /// A key another app (here, this test) already holds can't be registered:
  /// the row says so and the shortcut before it keeps working.
  @MainActor
  func testAShortcutThatFailsToRegisterSaysSo() async throws {
    let suite = "ShortcutStoreTest-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
    let store = ShortcutStore(defaults: defaults)
    let free = KeyBinding.keys("h", [.control, .option, .command], keyCode: 4)
    let taken = KeyBinding.keys("j", [.control, .option, .command], keyCode: 38)
    let blocker = GlobalHotKeyMonitor(keyCode: 38, modifiers: UInt32(cmdKey | optionKey | controlKey),
                                      identifier: 99, name: "test") {}
    try blocker.start()
    defer { blocker.stop() }
    store.set(free, for: .summon)
    let hotKeys = ShortcutHotKeys(store: store, handlers: [.summon: {}])
    hotKeys.start()
    defer { hotKeys.stop() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(store.failedActions.contains(ShortcutAction.summon.id))
    store.set(taken, for: .summon)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(store.failedActions.contains(ShortcutAction.summon.id))
    XCTAssertEqual(hotKeys.registered[.summon], free, "The shortcut before it stays registered")
    XCTAssertEqual(ShortcutEditor.failureNote, "Couldn’t set this shortcut. Another app may be using it.")
  }

}
