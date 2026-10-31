import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: MenuBarController?
  private var panelController: SpotlightPanelController?
  private var globalHotKeyMonitors: [GlobalHotKeyMonitor] = []
  private var panelShortcut: PanelShortcutMonitor?
  private var selectionShortcut: SelectionShortcutMonitor?
  /// F14 spike: the other kinds each action can be set to in Settings → Shortcuts.
  private var otherShortcuts: [Any] = []
  private var shortcutHotKeys: ShortcutHotKeys?
  private var accessibilityWarmer: SelectionAccessibilityWarmer?
  private var settingsWindowController: SettingsWindowController?
  private var subscriptionRefreshTask: Task<Void, Never>?

  override init() {
    super.init()
  }

  init(
    panelController: SpotlightPanelController,
    settingsWindowController: SettingsWindowController
  ) {
    self.panelController = panelController
    self.settingsWindowController = settingsWindowController
    super.init()
  }

  #if DEBUG
  private static var isTestHost: Bool { NSClassFromString("XCTestCase") != nil }
  /// Set by scripts/verify-xcode.sh (TEST_RUNNER_ENIGMA_BACKGROUND_TESTS=1). CI and
  /// Xcode keep the foreground host that the timing-sensitive UI tests were tuned for.
  static var runsTestsInBackground: Bool {
    isTestHost && ProcessInfo.processInfo.environment["ENIGMA_BACKGROUND_TESTS"] == "1"
  }
  private var appActiveBeforeTests: NSRunningApplication?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Keep a local test host out of the Dock and hand focus back to the app the
    // developer was using, so a test run does not take over the Mac.
    guard Self.runsTestsInBackground else { return }
    NSApp.setActivationPolicy(.accessory)
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      appActiveBeforeTests = frontmost
    }
  }
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Hosted unit tests create their own controllers and credential fixtures.
    // Starting the real panel here can prompt for personal Keychain entries and
    // show first-run onboarding before XCTest has started executing tests.
    #if DEBUG
    if Self.isTestHost {
      if NSApp.isActive, let appActiveBeforeTests {
        NSApp.yieldActivation(to: appActiveBeforeTests)
        appActiveBeforeTests.activate()
      }
      return
    }
    #endif
    NSApp.setActivationPolicy(.accessory)
    // A copy outside Applications cannot update; offer to move it before anything starts.
    if MoveToApplicationsPrompt.runIfNeeded() { return }
    AppUpdater.shared.start()
    // In the background, alongside startup: tidy or upgrade the built-in Codex
    // (new Codex processes prefer the pinned folder, and cleanup only runs once it
    // exists), and ask the shell where Codex and Claude Code are, so the synchronous
    // lookups find Node-manager installs from the start.
    Task.detached(priority: .utility) {
      await CodexRuntime.maintainAtLaunch()
    }
    Task.detached(priority: .utility) {
      await LoginShellToolLookup.shared.resolve("codex")
      await LoginShellToolLookup.shared.resolve("claude")
    }
    // The cached lists say which Codex models take images before anything refreshes them.
    Task { await CloudSettingsModel.shared.loadCachedModels() }
    // Shortly after launch and then daily: refresh the subscription routes' model lists
    // and keep Enigma's Codex current for people who use ChatGPT.
    let subscriptionRefresh = SubscriptionModelRefresh.live()
    subscriptionRefreshTask = Task.detached(priority: .utility) {
      await DailySchedule().run { await subscriptionRefresh.run() }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(replayWelcomeSetup),
      name: .welcomeSetupRequested, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(openRequestedSettings(_:)),
      name: .settingsRequested,
      object: nil
    )

    let panelController = SpotlightPanelController(welcomeSetup: .shared)
    let menuBarController = MenuBarController(panelController: panelController, updater: .shared)
    menuBarController.install()

    // F14 spike: each global action fires from whichever kind of shortcut
    // Settings → Shortcuts gave it. With "Same as summon", the summon
    // shortcut asks about a fresh selection and otherwise opens Enigma.
    let summon: @MainActor () -> Void = { [weak self] in
      self?.selectionShortcut?.reset()
      if ShortcutStore.shared.selectionSameAsSummon { panelController.summonOrSelect() } else { panelController.toggle() }
    }
    let select: @MainActor () -> Void = { panelController.summonSelectionContext() }
    let panelShortcut = PanelShortcutMonitor(action: .summon, handler: summon)
    panelShortcut.start()
    self.panelShortcut = panelShortcut

    let accessibilityWarmer = SelectionAccessibilityWarmer()
    accessibilityWarmer.start()
    self.accessibilityWarmer = accessibilityWarmer
    let selectionShortcut = SelectionShortcutMonitor(action: .selection, firstTap: { accessibilityWarmer.warmFrontmost() },
                                                     handler: select)
    selectionShortcut.start()
    self.selectionShortcut = selectionShortcut
    let selectionChord = PanelShortcutMonitor(action: .selection, handler: select)
    selectionChord.start()
    let summonDoubleTap = SelectionShortcutMonitor(action: .summon, firstTap: { accessibilityWarmer.warmFrontmost() },
                                                   handler: summon)
    summonDoubleTap.start()
    otherShortcuts = [selectionChord, summonDoubleTap]
    let shortcutHotKeys = ShortcutHotKeys(handlers: [.summon: summon, .selection: select])
    shortcutHotKeys.start()
    self.shortcutHotKeys = shortcutHotKeys
    let selectionBackup = GlobalHotKeyMonitor(hotKey: .selectionContext) { [weak self] in
      self?.selectionShortcut?.reset()
      panelController.summonSelectionContext()
    }
    do {
      try selectionBackup.start()
      globalHotKeyMonitors.append(selectionBackup)
    } catch {
      NSLog("Unable to register Selection Context shortcut: %@", error.localizedDescription)
    }

    self.panelController = panelController
    self.menuBarController = menuBarController

    panelController.show()
  }

  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    subscriptionRefreshTask?.cancel()
    panelShortcut?.stop()
    selectionShortcut?.stop()
    (otherShortcuts.first as? PanelShortcutMonitor)?.stop()
    (otherShortcuts.last as? SelectionShortcutMonitor)?.stop()
    shortcutHotKeys?.stop()
    accessibilityWarmer?.stop()
    globalHotKeyMonitors.forEach { $0.stop() }
    globalHotKeyMonitors.removeAll()
  }

  @objc func replayWelcomeSetup() {
    guard LocalChatViewModel.shared.canChangeModels, panelController?.isCapturingScreen != true else { return }
    settingsWindowController?.window?.orderOut(nil)
    WelcomeSetup.shared.replay()
    panelController?.show()
  }

  @objc private func openRequestedSettings(_ notification: Notification) {
    openSettings(destination: SettingsView.SettingsDestination.requested(notification.object))
  }

  func openSettings(destination: SettingsView.SettingsDestination? = nil) {
    guard panelController?.isCapturingScreen != true else { return }
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController()
    }
    settingsWindowController?.showSettings(destination: destination)
  }
}
