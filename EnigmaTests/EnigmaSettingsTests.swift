import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// Settings: the appearance setting, the window that follows it, every
/// destination's rendering, deep links, the shared logic behind the pages, and
/// their failure paths.
final class EnigmaSettingsTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib
  /// Tall enough to show a whole page without scrolling.
  private static let tall = CGSize(width: 820, height: 3000)

  // MARK: Mac capabilities

  @MainActor
  func testHardwareDetailsNameCPUsAndMetal() {
    var hardware = LocalHardwareProfile(physicalMemory: 16 * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Fixture chip", device: "Fixture Mac", cpuCount: 10, performanceCPUCount: 4,
      availableDiskBytes: 200 * gib, metalRecommendedWorkingSet: 12 * gib, metalMaximumBufferLength: 8 * gib,
      lowPowerMode: false)
    XCTAssertEqual(LocalModelSettingsLogic.hardwareDetails(hardware),
                   "10 CPUs · Metal · \((12 * gib).formatted(.byteCount(style: .memory))) Metal working set")
    hardware.metalRecommendedWorkingSet = nil
    XCTAssertEqual(LocalModelSettingsLogic.hardwareDetails(hardware), "10 CPUs · Metal")
    hardware.hasMetal = false
    XCTAssertEqual(LocalModelSettingsLogic.hardwareDetails(hardware), "10 CPUs · CPU inference")
  }

  // MARK: Appearance setting

  @MainActor
  func testAppearanceDefaultsToSystemAndIsSaved() throws {
    let defaults = try makeDefaults()
    let preference = EnigmaAppearancePreference(defaults: defaults)
    XCTAssertEqual(preference.appearance, .system)
    preference.appearance = .ink
    XCTAssertEqual(defaults.string(forKey: EnigmaAppearancePreference.appearanceKey), "ink")
    XCTAssertEqual(EnigmaAppearancePreference(defaults: defaults).appearance, .ink, "A new launch reads it back")
    defaults.set("sepia", forKey: EnigmaAppearancePreference.appearanceKey)
    XCTAssertEqual(EnigmaAppearancePreference(defaults: defaults).appearance, .system, "Unknown values fall back")
  }

  @MainActor
  func testAppearanceMapsToColorSchemeWindowAppearanceAndBackground() throws {
    XCTAssertNil(EnigmaAppearance.system.colorScheme)
    XCTAssertEqual(EnigmaAppearance.paper.colorScheme, .light)
    XCTAssertEqual(EnigmaAppearance.ink.colorScheme, .dark)
    XCTAssertNil(EnigmaAppearance.system.windowAppearanceName)
    XCTAssertEqual(EnigmaAppearance.paper.windowAppearanceName, .aqua)
    XCTAssertEqual(EnigmaAppearance.ink.windowAppearanceName, .darkAqua)
    XCTAssertNil(EnigmaAppearance.system.windowAppearance)
    XCTAssertEqual(EnigmaAppearance.ink.windowAppearance?.name, .darkAqua)
    XCTAssertTrue(matches(EnigmaAppearance.windowBackground, under: .aqua, EnigmaPalette.paper.background))
    XCTAssertTrue(matches(EnigmaAppearance.windowBackground, under: .darkAqua, EnigmaPalette.ink.background))
  }

  @MainActor
  func testWindowChromeFollowsTheAppearance() {
    for appearance in EnigmaAppearance.allCases {
      let chrome = SettingsWindowChrome.chrome(appearance: appearance)
      XCTAssertEqual(chrome.appearanceName, appearance.windowAppearanceName)
      XCTAssertTrue(chrome.backgroundColor === EnigmaAppearance.windowBackground)
    }
  }

  @MainActor
  func testSettingsWindowFollowsTheAppearanceLive() async throws {
    let defaults = try makeDefaults()
    let appearance = EnigmaAppearancePreference(defaults: defaults)
    let controller = SettingsWindowController(contentView: NSView(), appearance: appearance)
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    XCTAssertNil(window.appearance, "System follows the Mac")
    XCTAssertTrue(window.backgroundColor === EnigmaAppearance.windowBackground)
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.sharingType, .none)
    XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowController.contentSize,
                   "The area below the title bar is 820 × 680")
    let frame = window.frame

    appearance.appearance = .paper
    await mainQueueTurn()
    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertTrue(matches(window.backgroundColor, under: .aqua, EnigmaPalette.paper.background))
    appearance.appearance = .ink
    await mainQueueTurn()
    XCTAssertEqual(window.appearance?.name, .darkAqua)
    XCTAssertTrue(matches(window.backgroundColor, under: .darkAqua, EnigmaPalette.ink.background))
    appearance.appearance = .system
    await mainQueueTurn()
    XCTAssertNil(window.appearance)
    XCTAssertEqual(window.frame, frame, "The window keeps its size and place")
    XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowController.contentSize)
  }

  @MainActor
  func testSettingsWindowStartsInTheSavedAppearance() throws {
    let defaults = try makeDefaults()
    let appearance = EnigmaAppearancePreference(defaults: defaults)
    appearance.appearance = .ink
    let controller = SettingsWindowController(contentView: NSView(), appearance: appearance)
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    XCTAssertEqual(window.appearance?.name, .darkAqua)
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowController.contentSize)
  }

  /// With SwiftUI content, the window keeps its size through appearance
  /// changes, the navigation's background runs under the title bar, and
  /// SwiftUI's own color-scheme preference doesn't override the window's
  /// appearance.
  @MainActor
  func testHostedSettingsWindowKeepsItsSizeAndAppearanceAcrossAppearanceChanges() async throws {
    let fixture = try await Fixture(test: self)
    let appearance = EnigmaAppearancePreference(defaults: fixture.defaults)
    let content = SettingsWindowContent(appearance: appearance, settings: { fixture.settings(appearance: appearance) })
    let host = SettingsWindowController.hostingView(content.transaction { $0.disablesAnimations = true })
    let controller = SettingsWindowController(contentView: host, appearance: appearance)
    let window = try XCTUnwrap(controller.window)
    window.colorSpace = .sRGB
    // On screen, as Settings always is, so SwiftUI keeps drawing it.
    window.orderFrontRegardless()
    defer { window.close() }
    func settle() async throws {
      for _ in 0..<10 {
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    try await settle()
    let frame = window.frame
    XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowController.contentSize, "At launch")

    for choice in [EnigmaAppearance.paper, .ink, .system] {
      appearance.appearance = choice
      try await settle()
      XCTAssertEqual(window.frame, frame, "\(choice): the window keeps its size and place")
      XCTAssertEqual(window.contentLayoutRect.size, SettingsWindowController.contentSize, "\(choice)")
      XCTAssertEqual(window.appearance?.name, choice.windowAppearanceName, "\(choice)")
      let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let palette = choice.palette(for: isDark ? .dark : .light)
      // Under the title bar, the navigation's color, not the window's.
      try await waitForUI("the navigation under the title bar in \(choice)", in: host) {
        guard let image = try? EnigmaSnapshot.capture(host),
              let color = try? EnigmaSnapshot.pixel(image, at: CGPoint(x: 100, y: 12)) else { return false }
        return EnigmaSnapshot.matches(color, palette.sidebar)
      }
    }
  }

  @MainActor
  func testAppearanceSwitchesTheWelcomeLive() async throws {
    let fixture = try await Fixture(test: self)
    let appearance = EnigmaAppearancePreference(defaults: fixture.defaults)
    appearance.appearance = .paper
    let setup = WelcomeSetup(defaults: fixture.defaults)
    let size = CGSize(width: 900, height: 620)
    let view = NSHostingView(rootView: AppShellView(cloudSettings: fixture.cloud, localChat: fixture.chat, modelAdvisor: fixture.advisor,
      searchSettings: fixture.search, startPreferences: fixture.start, welcomeSetup: setup,
      appearance: appearance).transaction { $0.disablesAnimations = true })
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.colorSpace = .sRGB
    window.contentView = view
    defer { window.contentView = nil }
    setup.replay()
    func canvas() throws -> EnigmaColor {
      try EnigmaSnapshot.pixel(try EnigmaSnapshot.capture(view), at: CGPoint(x: 14, y: size.height / 2))
    }
    try await waitForUI("the welcome in Paper", in: view) {
      (try? canvas()).map { EnigmaSnapshot.matches($0, EnigmaPalette.paper.background) } ?? false
    }
    appearance.appearance = .ink
    try await waitForUI("the welcome in Ink", in: view) {
      (try? canvas()).map { EnigmaSnapshot.matches($0, EnigmaPalette.ink.background) } ?? false
    }
    XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                   "The window follows Ink")
  }

  // MARK: Rendering

  @MainActor
  func testEveryDestinationRendersAtWindowSizeInPaperAndInk() async throws {
    let fixture = try await Fixture(test: self)
    let size = SettingsView.windowSize
    for destination in SettingsView.SettingsDestination.allCases {
      for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
        let label = "\(destination) in \(appearance)"
        let image = try EnigmaSnapshot.render(fixture.settings(destination).enigmaTheme(appearance), size: size)
        try assertPixel(image, at: CGPoint(x: 20, y: size.height - 20), is: palette.sidebar, label)
        try assertPixel(image, at: CGPoint(x: SettingsView.navigationWidth + 12, y: size.height / 2),
                        is: palette.background, label)
      }
    }
  }

  /// Nothing on any page is wider than its column: the page's side margins
  /// stay the bare canvas all the way down.
  @MainActor
  func testNoPageSpillsIntoItsMargins() async throws {
    let fixture = try await Fixture(test: self)
    let size = CGSize(width: SettingsView.windowSize.width, height: 3400)
    for destination in SettingsView.SettingsDestination.allCases {
      let image = try EnigmaSnapshot.render(fixture.settings(destination, size: size).enigmaTheme(.paper),
                                            size: size, scale: 1)
      let left = SettingsView.navigationWidth + 18
      let right = size.width - 23
      for y in stride(from: 4.0, to: size.height - 4, by: 6) {
        for x in [left, right] {
          let color = try EnigmaSnapshot.pixel(image, at: CGPoint(x: x, y: y))
          XCTAssertTrue(EnigmaSnapshot.matches(color, EnigmaPalette.paper.background),
                        "\(destination) draws into its margin at \(x), \(y): \(color)")
          if !EnigmaSnapshot.matches(color, EnigmaPalette.paper.background) { return }
        }
      }
    }
  }

  // MARK: Deep links

  @MainActor
  func testDeepLinksSelectTheRequestedDestination() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.general).enigmaTheme(.paper), test: self)
    try await waitForUI("General", in: host.view) { host.shows("Settings page General") }
    for destination in [SettingsView.SettingsDestination.cloud, .local, .selection, .general] {
      NotificationCenter.default.post(name: .settingsDestinationRequested, object: destination)
      // The page before it fades out, then only the requested page is left.
      try await waitForUI("only the \(destination) page", in: host.view) {
        SettingsView.SettingsDestination.allCases.allSatisfy {
          host.shows("Settings page \($0.title)") == ($0 == destination)
        }
      }
    }
    NotificationCenter.default.post(name: .settingsDestinationRequested, object: "not a destination")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(host.shows("Settings page General"), "Other objects are ignored")
    NotificationCenter.default.post(name: .settingsDestinationRequested, object: "discover")
    try await waitForUI("Local models for the removed Discover page", in: host.view) {
      SettingsView.SettingsDestination.allCases.allSatisfy {
        host.shows("Settings page \($0.title)") == ($0 == .local)
      }
    }
  }

  func testDiscoverIsGoneAndItsOldNameOpensLocalModels() {
    typealias Destination = SettingsView.SettingsDestination
    XCTAssertEqual(Destination.allCases.map(\.rawValue), ["general", "local", "cloud", "selection"])
    XCTAssertEqual(Destination.requested("discover"), .local)
    XCTAssertEqual(Destination.requested("local"), .local)
    XCTAssertEqual(Destination.requested(Destination.cloud), .cloud)
    XCTAssertNil(Destination.requested("not a destination"))
    XCTAssertNil(Destination.requested(nil))
  }

  @MainActor
  func testNavigationClickSelectsAPage() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.general).enigmaTheme(.paper), test: self)
    try await waitForUI("the navigation", in: host.view) { host.shows("Settings section Selection") }
    try host.press("Settings section Selection")
    try await waitForUI("the Selection page", in: host.view) { host.shows("Settings page Selection") }
  }

  // MARK: Settings take effect

  @MainActor
  func testAppearanceStartModeAndSwitchesChangeTheirSettings() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.general).enigmaTheme(.paper), test: self)
    try await waitForUI("the appearance control", in: host.view) { host.shows("Appearance: Ink") }
    try host.press("Appearance: Ink")
    try await waitForUI("Ink saved", in: host.view) { fixture.appearance.appearance == .ink }
    XCTAssertEqual(fixture.defaults.string(forKey: EnigmaAppearancePreference.appearanceKey), "ink")

    XCTAssertFalse(fixture.start.showsSidebar)
    try host.press("Show sidebar switch")
    try await waitForUI("the sidebar switch", in: host.view) { fixture.start.showsSidebar }

    try host.press("Prefer Start Mode")
    try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Cloud") }
    try host.press("Menu item Cloud")
    try await waitForUI("Cloud chosen", in: host.view) { fixture.start.mode == .cloud }
    try await waitForUI("the menu to close", in: host.view) { !host.shows("Menu item Cloud") }
  }

  @MainActor
  func testRecognizeCommandsSwitchIsOffByDefaultAndSavesOn() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.general, size: Self.tall).enigmaTheme(.paper).defaultAppStorage(fixture.defaults),
                    size: Self.tall, test: self)
    try await waitForUI("the recognize switch", in: host.view) {
      host.shows("Recognize commands from your wording switch")
    }
    XCTAssertNil(fixture.defaults.object(forKey: ComposerIntent.inferCommandsKey), "Off by default, with nothing saved")
    XCTAssertFalse(ComposerIntent.infersCommandsByDefault)
    try host.press("Recognize commands from your wording switch")
    try await waitForUI("recognition on", in: host.view) {
      fixture.defaults.object(forKey: ComposerIntent.inferCommandsKey) as? Bool == true
    }
    try host.press("Recognize commands from your wording switch")
    try await waitForUI("recognition off", in: host.view) {
      fixture.defaults.object(forKey: ComposerIntent.inferCommandsKey) as? Bool == false
    }
  }

  @MainActor
  func testUpdateSwitchesAndCheckNowReachTheUpdater() async throws {
    let fixture = try await Fixture(test: self)
    let backend = fixture.updaterBackend
    let host = Host(fixture.settings(.general, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the update switches", in: host.view) { host.shows("Check for updates automatically switch") }
    try host.press("Check for updates automatically switch")
    try await waitForUI("automatic checks off", in: host.view) { !backend.automaticallyChecksForUpdates }
    try await waitForUI("the download switch disabled", in: host.view) {
      host.isEnabled("Download and install updates automatically switch") == false
    }
    try host.press("Download and install updates automatically switch")
    XCTAssertTrue(backend.automaticallyDownloadsUpdates, "The download switch is disabled while checks are off.")

    try host.press("Check for updates automatically switch")
    try await waitForUI("automatic checks on", in: host.view) { backend.automaticallyChecksForUpdates }
    fixture.updater.backendCanCheckChanged(true)
    try await waitForUI("Check Now enabled", in: host.view) { host.isEnabled("Check for Updates Now") == true }
    try host.press("Check for Updates Now")
    try await waitForUI("a check", in: host.view) { backend.checkCount == 1 }
  }

  @MainActor
  func testSelectionSwitchTurnsOnAutomaticReplace() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.selection).enigmaTheme(.paper), test: self)
    try await waitForUI("the switch", in: host.view) { host.shows("Automatically replace selected text") }
    XCTAssertFalse(host.shows("Screen Recording"), "Selection lists Accessibility only")
    try host.press("Automatically replace selected text switch")
    try await waitForUI("automatic replace", in: host.view) { fixture.selection.automaticallyReplace }
  }

  @MainActor
  func testSelectionPageKeepsSelectionChatsPrivateWhenSwitchedOn() async throws {
    let fixture = try await Fixture(test: self)
    XCTAssertFalse(fixture.selection.keepsChatsPrivate, "Off by default")
    let host = Host(fixture.settings(.selection).enigmaTheme(.paper), test: self)
    try await waitForUI("the private chats row", in: host.view) {
      host.shows(SelectionEditingSettings.privateChatsTitle)
        && host.shows("\(SelectionEditingSettings.privateChatsTitle) switch")
    }
    try host.press("\(SelectionEditingSettings.privateChatsTitle) switch")
    try await waitForUI("private chats on", in: host.view) { fixture.selection.keepsChatsPrivate }
    XCTAssertTrue(fixture.defaults.bool(forKey: SelectionEditingSettings.privateChatsKey))
    try host.press("\(SelectionEditingSettings.privateChatsTitle) switch")
    try await waitForUI("private chats off", in: host.view) { !fixture.selection.keepsChatsPrivate }
    XCTAssertFalse(fixture.defaults.bool(forKey: SelectionEditingSettings.privateChatsKey))
    // General doesn't hold it.
    let general = Host(fixture.settings(.general).enigmaTheme(.paper), test: self)
    try await waitForUI("General", in: general.view) { general.shows("Appearance: Ink") }
    XCTAssertFalse(general.shows(SelectionEditingSettings.privateChatsTitle))
  }

  @MainActor
  func testAPIKeySavesToTheKeychainAndRemoves() async throws {
    let credentials = ScreenTestCredentialStore()
    let fixture = try await Fixture(test: self, cloudCredentials: credentials)
    let host = Host(fixture.settings(.cloud, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await type("  sk-test-key ", intoFieldAt: 1, of: host)
    try host.press("Save OpenAI API key")
    try await waitForUI("the key in the Keychain", in: host.view) {
      (try? credentials.apiKey(for: .openAI)) == "sk-test-key"
    }
    try await waitForUI("the stored status", in: host.view) { host.shows("API key stored in Keychain") }
    try host.press("Remove OpenAI API key")
    try await waitForUI("the key removed", in: host.view) { (try? credentials.apiKey(for: .openAI)) == nil }
    XCTAssertFalse(fixture.cloud.hasAPIKey(for: .openAI))
  }

  // MARK: Menus

  @MainActor
  func testMenuKeysPickAndCloseAndFocusReturnsToTheTrigger() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.general).enigmaTheme(.paper), test: self)
    let trigger = "Prefer Start Mode"
    func open() async throws {
      try await waitForUI("the trigger", in: host.view) { host.shows(trigger) }
      try host.press(trigger)
      try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Local") }
      try await waitForOpenMenuToTakeFocus(in: host.view)
    }
    func assertClosedWithFocusOnTrigger(_ how: String) async throws {
      try await waitForUI("the menu to close after \(how)", in: host.view) { !host.shows("Menu item Local") }
      try await waitForUI("focus back on the trigger after \(how)", in: host.view) {
        host.showsFocusRing(around: trigger, palette: .paper)
      }
    }
    XCTAssertEqual(fixture.start.mode, .auto)

    try await open()
    try host.key(125, "\u{F701}")  // ↓ from Auto to Local
    try host.key(36, "\r")
    try await waitForUI("Return to pick Local", in: host.view) { fixture.start.mode == .local }
    try await assertClosedWithFocusOnTrigger("Return")

    try await open()
    try host.key(126, "\u{F700}")  // ↑ from Local to Auto
    try host.key(49, " ")
    try await waitForUI("Space to pick Auto", in: host.view) { fixture.start.mode == .auto }
    try await assertClosedWithFocusOnTrigger("Space")

    try await open()
    try host.key(125, "\u{F701}")
    try host.key(53, "\u{1B}")
    try await assertClosedWithFocusOnTrigger("Escape")
    XCTAssertEqual(fixture.start.mode, .auto, "Escape picks nothing")

    try await open()
    try host.press("Menu item Cloud")
    try await waitForUI("a click to pick Cloud", in: host.view) { fixture.start.mode == .cloud }
    try await assertClosedWithFocusOnTrigger("an item click")

    try await open()
    try host.press("Settings page General")
    try await assertClosedWithFocusOnTrigger("a click outside")
    XCTAssertEqual(fixture.start.mode, .cloud)
  }

  /// An open menu follows its trigger, shows rows that change while it's open,
  /// and closes when its trigger goes away.
  @MainActor
  func testOpenMenuFollowsItsTriggerAndItsRows() async throws {
    let model = MenuHarnessModel()
    let host = Host(MenuHarness(model: model).enigmaTheme(.paper), test: self)
    try await waitForUI("the trigger", in: host.view) { host.shows("Harness") }
    try host.press("Harness")
    try await waitForUI("the open menu", in: host.view) { host.shows("Menu item A") }
    XCTAssertFalse(host.shows("Menu item C"))

    model.options.append("C")
    try await waitForUI("the new row", in: host.view) { host.shows("Menu item C") }

    let before = try XCTUnwrap(host.frame(of: "Menu item A")).minY
    model.offset = 120
    try await waitForUI("the menu to move with its trigger", in: host.view) {
      guard let after = host.frame(of: "Menu item A")?.minY else { return false }
      return abs(after - before - 120) < 1
    }

    model.selection = "B"
    try host.press("Menu item C")
    try await waitForUI("C picked from the refreshed rows", in: host.view) { model.selection == "C" }

    try host.press("Harness")
    try await waitForUI("the menu open again", in: host.view) { host.shows("Menu item A") }
    model.showsTrigger = false
    try await waitForUI("the menu to close with its trigger", in: host.view) { !host.shows("Menu item A") }
  }

  @MainActor
  func testPresenterKeepsAnOpenMenuInStepAndHandsFocusBack() {
    let presenter = EnigmaMenuPresenter()
    let id = UUID()
    var focusReturns = 0
    let first = EnigmaMenuSection(items: [EnigmaMenuItem(id: "a", title: "A") {}])
    presenter.present(.init(id: id, label: "Menu", anchor: CGRect(x: 0, y: 0, width: 100, height: 20),
                            minimumWidth: 160, sections: [first], onDismiss: { focusReturns += 1 }))
    presenter.update(UUID(), anchor: CGRect(x: 50, y: 50, width: 100, height: 20))
    XCTAssertEqual(presenter.presentation?.anchor.minX, 0, "Another menu's trigger can't move this one")
    presenter.update(id, anchor: CGRect(x: 50, y: 60, width: 200, height: 20))
    XCTAssertEqual(presenter.presentation?.anchor, CGRect(x: 50, y: 60, width: 200, height: 20))
    XCTAssertEqual(presenter.presentation?.minimumWidth, 200)
    let second = EnigmaMenuSection(items: [EnigmaMenuItem(id: "b", title: "B") {}])
    presenter.update(id, sections: [second])
    XCTAssertEqual(presenter.presentation?.sections.first?.items.map(\.title), ["B"])
    XCTAssertNotEqual(EnigmaMenuSection.signature(of: [first]), EnigmaMenuSection.signature(of: [second]))

    presenter.dismiss(id)
    XCTAssertNil(presenter.presentation)
    XCTAssertEqual(focusReturns, 1)
    presenter.present(.init(id: id, label: "Menu", anchor: .zero, minimumWidth: 160, sections: [first],
                            onDismiss: { focusReturns += 1 }))
    presenter.dismiss(id, restoringFocus: false)
    XCTAssertEqual(focusReturns, 1, "A trigger that went away doesn't take focus")
  }

  // MARK: Local models

  @MainActor
  func testInstallReachesTheEngine() async throws {
    let engine = SettingsRecordingEngine()
    let fixture = try await Fixture(test: self, engine: engine)
    let recommended = try XCTUnwrap(fixture.advisor.recommendations(installedModels: []).recommended)
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    let install = "Install \(recommended.model.displayName)"
    try await waitForUI("the Install button", in: host.view) { host.shows(install) }
    try host.press(install)
    var downloads: [String] = []
    for _ in 0..<200 where downloads.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      downloads = await engine.downloads
    }
    XCTAssertEqual(downloads, [recommended.id])
  }

  @MainActor
  func testLocalModelsPageHasOneSetOfChoices() async throws {
    let fixture = try await Fixture(test: self)
    let recommended = try XCTUnwrap(fixture.advisor.recommendations(installedModels: []).recommended)
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the recommended package", in: host.view) {
      host.shows("Install \(recommended.model.displayName)")
    }
    for shown in ["For this Mac", "All models", "Check this Mac", "Check performance", "267 GB/s"] {
      XCTAssertTrue(host.shows(shown), shown)
    }
    for gone in ["Detect Mac capabilities", "Refresh recommendations", "Download files", "Lightweight",
                 "Models for other memory sizes", "On this Mac"] {
      XCTAssertFalse(host.shows(gone), gone)
    }
  }

  @MainActor
  func testCheckThisMacRemeasuresBandwidth() async throws {
    let fixture = try await Fixture(test: self)
    // The page starts the advisor once; start it here so that first check,
    // which reuses the saved bandwidth, is over before the press.
    await fixture.advisor.start(installedModels: [], presentOnboarding: false)
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("Check this Mac", in: host.view) {
      host.shows("Check this Mac") && host.isEnabled("Check this Mac") == true
    }
    let before = fixture.probe.count
    try host.press("Check this Mac")
    try await waitForUI("the bandwidth test", in: host.view) {
      fixture.probe.count > before && !fixture.advisor.isDetecting
    }
    XCTAssertEqual(fixture.probe.count, before + 1)
  }

  @MainActor
  func testBandwidthStat() {
    var mac = hardware(memory: 32)
    mac.measuredBandwidth = 267.4
    XCTAssertTrue(LocalModelSettingsLogic.bandwidthStat(mac) == ("267 GB/s", "memory bandwidth"))
    mac.measuredBandwidth = nil
    XCTAssertTrue(LocalModelSettingsLogic.bandwidthStat(mac) == ("Not measured", "memory bandwidth"))
  }

  @MainActor
  func testOnThisMacKeepsPackagesThatLeftTheCatalogue() async throws {
    let file = URL(fileURLWithPath: "/tmp/enigma-settings-fixture.gguf")
    let legacy = LocalModel(id: "gemma-4-12b-it-qat-q4_0-gguf", displayName: "Google Gemma 4 12B", fileURL: file,
      visionConfiguration: LocalVisionConfiguration(projectorURL: file,
        serverExecutableURL: URL(fileURLWithPath: "/bin/echo")))
    let engine = SettingsRecordingEngine(installed: [legacy])
    let fixture = try await Fixture(test: self, engine: engine)
    await fixture.chat.refreshInstalledModel()
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the installed package", in: host.view) { host.shows("Use Google Gemma 4 12B") }
    XCTAssertTrue(host.shows("On this Mac"))
    XCTAssertTrue(host.shows("Delete Google Gemma 4 12B"))
    XCTAssertEqual(LocalModelSettingsLogic.installedSubtitle(for: legacy, inCatalogue: false),
                   "Legacy/imported image model · Select to use for all requests")
    let current = try XCTUnwrap(LocalModelManifest.bundled.models.first { $0.id == "gemma-4-12b-q5_k_m" })
    let installed = LocalModel(id: current.id, displayName: current.displayName, fileURL: file,
                               catalogDescriptor: current)
    XCTAssertEqual(LocalModelSettingsLogic.installedSubtitle(for: installed, inCatalogue: true), "Q5_K_M · Google")
  }

  @MainActor
  func testInstalledPackageNeedingUpdateCanStillBeUsed() async throws {
    // The fixture Mac (32 GB at 267 GB/s) recommends Gemma 4 26B-A4B IQ4_XS, so
    // its stale copy shows Update under For this Mac.
    let mac = hardware(memory: 32, bandwidth: 267)
    let assessment = try XCTUnwrap(LocalModelSelector.select(manifest: .bundled, hardware: mac).assessments
      .first { $0.id == "gemma-4-26b-a4b-iq4_xs" })
    var stale = installedModel(for: assessment)
    stale.visionConfiguration?.packageRevision = "old"
    let engine = SettingsRecordingEngine(installed: [stale])
    let fixture = try await Fixture(test: self, engine: engine)
    await fixture.chat.refreshInstalledModel()
    XCTAssertEqual(fixture.advisor.recommendations(installedModels: fixture.chat.installedModels).recommended?.id,
                   assessment.id)
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the Update button", in: host.view) { host.shows("Update Gemma 4 26B-A4B") }
    XCTAssertTrue(host.shows("Use Gemma 4 26B-A4B"), "The installed copy stays usable")
  }

  @MainActor
  func testUseAndDeleteReachTheEngineAndDeleteAsksFirst() async throws {
    let recommendations = LocalModelSelector.select(manifest: .bundled, hardware: hardware(memory: 32))
    let recommended = try XCTUnwrap(recommendations.recommended)
    let engine = SettingsRecordingEngine(installed: [installedModel(for: recommended)])
    let fixture = try await Fixture(test: self, engine: engine)
    await fixture.chat.refreshInstalledModel()
    let host = Host(fixture.settings(.local, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    let name = recommended.model.displayName
    try await waitForUI("the Use button", in: host.view) { host.shows("Use \(name)") }
    try host.press("Use \(name)")
    var selections: [String] = []
    for _ in 0..<200 where selections.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      selections = await engine.selections
    }
    XCTAssertEqual(selections, [recommended.id])

    try await waitForUI("Delete, once the selection settles", in: host.view) {
      host.shows("Delete \(name)") && !fixture.chat.isBusy
    }
    try host.press("Delete \(name)")
    var confirm: NSButton?
    try await waitForUI("the delete confirmation", in: host.view) {
      confirm = Self.button(titled: "Delete", outside: host.view)
      return confirm != nil
    }
    var deletions = await engine.deletions
    XCTAssertTrue(deletions.isEmpty, "Nothing is deleted before the confirmation")
    try XCTUnwrap(confirm).performClick(nil)
    for _ in 0..<200 where deletions.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      deletions = await engine.deletions
    }
    XCTAssertEqual(deletions, [recommended.id])
  }

  /// A push button with `title` in any window but the host's, like an alert's.
  @MainActor
  private static func button(titled title: String, outside host: NSView) -> NSButton? {
    func search(_ node: NSView) -> NSButton? {
      if let button = node as? NSButton, button.title == title, !button.isHiddenOrHasHiddenAncestor { return button }
      return node.subviews.lazy.compactMap(search).first
    }
    let windows = NSApp.windows.filter { $0 !== host.window && $0.isVisible }
      + [host.window?.attachedSheet].compactMap { $0 }
    return windows.lazy.compactMap { $0.contentView.flatMap(search) }.first
  }

  // MARK: Failure paths

  @MainActor
  func testCloudPageShowsTheAnthropicAPIKeyRouteWhenClaudeCodeIsMissing() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture.settings(.cloud, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the Terminal steps disclosure", in: host.view) { host.shows("Terminal steps") }
    XCTAssertTrue(host.shows("Anthropic API key note"))
  }

  @MainActor
  func testFailedKeySaveShowsTheSameErrorAndKeepsTheKey() async throws {
    let fixture = try await Fixture(test: self, cloudCredentials: FailingCloudCredentials())
    let host = Host(fixture.settings(.cloud, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    let field = try await type("sk-test-key", intoFieldAt: 1, of: host)
    try host.press("Save OpenAI API key")
    let message = FailingCloudCredentials.Failure().localizedDescription
    try await waitForUI("the error line", in: host.view) { host.shows(message) }
    XCTAssertEqual(field.stringValue, "sk-test-key", "A failed save keeps what was typed")
    var typed = "sk-test-key"
    XCTAssertEqual(CloudSettingsForm.saveAPIKey(&typed, for: .openAI, in: fixture.cloud), message,
                   "The shared form logic returns the same message")
  }

  @MainActor
  func testFailedConnectionTestShowsTheSameMessage() async throws {
    let transport = ScreenTestTransport(dataHandler: { _ in
      CloudDataResponse(data: Data(#"{"error":{"message":"Incorrect API key provided."}}"#.utf8), statusCode: 401)
    })
    let fixture = try await Fixture(test: self, cloudCredentials: ScreenTestCredentialStore(keys: [.openAI: "bad"]),
                                    transport: transport)
    let host = Host(fixture.settings(.cloud, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    try await waitForUI("the test button", in: host.view) { host.shows("Test OpenAI API connection") }
    try host.press("Test OpenAI API connection")
    try await waitForUI("the failed test", in: host.view) {
      if case .failed = fixture.cloud.connectionState(for: .openAI) { return true }
      return false
    }
    let status = try XCTUnwrap(CloudSettingsForm.connectionStatus(for: .openAI, in: fixture.cloud))
    XCTAssertEqual(status.kind, .failed)
    try await waitForUI("the failure message", in: host.view) { host.shows(status.text) }
    XCTAssertFalse(transport.dataRequests.isEmpty, "The test reached the provider")
  }

  @MainActor
  func testMissingKeysKeepSaveAndTestOff() async throws {
    let fixture = try await Fixture(test: self)
    XCTAssertFalse(CloudSettingsForm.canSave(""))
    XCTAssertFalse(CloudSettingsForm.canSave(" \n "))
    XCTAssertTrue(CloudSettingsForm.canSave(" key "))
    XCTAssertFalse(CloudSettingsForm.canTestConnection(to: .openAI, in: fixture.cloud), "No key, no test")
    XCTAssertFalse(CloudSettingsForm.canRemoveAPIKey(for: .openAI, in: fixture.cloud))
    XCTAssertNil(CloudSettingsForm.connectionStatus(for: .openAI, in: fixture.cloud), "Nothing to report without a key")
    XCTAssertFalse(WebSearchSettings.canSaveAPIKey("   "))
    var empty = ""
    XCTAssertEqual(fixture.search.saveAPIKey(from: &empty), WebSearchError.missingAPIKey.localizedDescription)
  }

  @MainActor
  func testFailedBraveKeySaveShowsTheError() async throws {
    let fixture = try await Fixture(test: self, searchCredentials: FailingSearchCredentials())
    let host = Host(fixture.settings(.cloud, size: Self.tall).enigmaTheme(.paper), size: Self.tall, test: self)
    let field = try await type("brave-key", intoFieldAt: 0, of: host)
    try host.press("Save Brave key")
    let message = FailingSearchCredentials.Failure().localizedDescription
    try await waitForUI("the error line", in: host.view) { host.shows(message) }
    XCTAssertEqual(field.stringValue, "brave-key")
    XCTAssertTrue(host.shows("no key"))
  }

  @MainActor
  func testDeniedPermissionsReadAsActionNeeded() {
    XCTAssertEqual(MacPermissionRows.status(isEnabled: false).1, "action needed")
    XCTAssertEqual(MacPermissionRows.status(isEnabled: true).1, "enabled")
    struct Denied: Error {}
    XCTAssertEqual(MessagesPermissionStatus.fullDiskAccess(check: { throw Denied() }), false)
    XCTAssertNil(MessagesPermissionStatus.fullDiskAccess(check: { throw MessagesError.databaseMissing }))
    XCTAssertEqual(MessagesPermissionStatus.fullDiskAccess(check: {}), true)
    XCTAssertEqual(MessagesPermissionStatus.fullDiskAccessDetail(nil), "Messages has no history on this Mac yet.")
    XCTAssertTrue(MessagesPermissionStatus.fullDiskAccessDetail(false).hasPrefix("Required to read"))
    XCTAssertEqual(MessagesSettingsSection.settingsName(for: .automation), "Open Automation Settings…")
  }

  // MARK: Shared Cloud logic

  @MainActor
  func testConnectionStatusCoversEveryState() {
    typealias Form = CloudSettingsForm
    XCTAssertNil(Form.connectionStatus(state: .idle, hasAPIKey: false))
    XCTAssertEqual(Form.connectionStatus(state: .idle, hasAPIKey: true)?.text, "API key stored in Keychain")
    XCTAssertEqual(Form.connectionStatus(state: .testing, hasAPIKey: true)?.kind, .testing)
    let connected = Form.connectionStatus(state: .connected(12), hasAPIKey: true)
    XCTAssertEqual(connected?.text, "API reachable · Compatible chat models: 12")
    XCTAssertEqual(connected?.detail, "Model-list check only. Sending and billing were not tested.")
    XCTAssertEqual(Form.connectionStatus(state: .failed("Nope"), hasAPIKey: true),
                   Form.ConnectionStatus(kind: .failed, text: "Nope"))
    XCTAssertEqual(APIKeyRow.status(Form.ConnectionStatus(kind: .failed, text: "x")), .problem)
    XCTAssertEqual(AdvancedCloudSettings.compatibilityStatus(.unsupported), .problem)
    XCTAssertEqual(AdvancedCloudSettings.compatibilityStatus(.compatible), .on)
  }

  @MainActor
  func testModelChoicesKeepABlankAndAManualSelection() {
    let models = [CloudModel(id: "a", displayName: "Model A", provider: .openAI),
                  CloudModel(id: "b", displayName: "Model B", provider: .openAI)]
    XCTAssertEqual(CloudSettingsForm.modelChoices(models: models, preferredModelID: "").map(\.title),
                   ["Choose a model", "Model A", "Model B"])
    XCTAssertEqual(CloudSettingsForm.modelChoices(models: models, preferredModelID: "a").map(\.id), ["a", "b"])
    XCTAssertEqual(CloudSettingsForm.modelChoices(models: models, preferredModelID: "custom").last,
                   CloudSettingsForm.ModelChoice(id: "custom", title: "Manual · custom"))
    XCTAssertEqual(CloudSettingsForm.refreshTitle(isDiscovering: true), "Refreshing…")
    XCTAssertEqual(CloudSettingsForm.refreshTitle(isDiscovering: false), "Refresh Models")
  }

  @MainActor
  func testSavingAndRemovingClearTheFields() async throws {
    let credentials = ScreenTestCredentialStore()
    let fixture = try await Fixture(test: self, cloudCredentials: credentials)
    var key = " sk-1 "
    XCTAssertNil(CloudSettingsForm.saveAPIKey(&key, for: .gemini, in: fixture.cloud))
    XCTAssertEqual(key, "")
    XCTAssertEqual(try credentials.apiKey(for: .gemini), "sk-1")
    XCTAssertTrue(CloudSettingsForm.canTestConnection(to: .gemini, in: fixture.cloud))
    XCTAssertNil(CloudSettingsForm.removeAPIKey(for: .gemini, in: fixture.cloud))
    XCTAssertFalse(fixture.cloud.hasAPIKey(for: .gemini))

    var brave = " brave "
    XCTAssertNil(fixture.search.saveAPIKey(from: &brave))
    XCTAssertEqual(brave, "")
    XCTAssertTrue(fixture.search.hasAPIKey)
    var leftover = "typed"
    XCTAssertNil(fixture.search.removeAPIKey(clearing: &leftover))
    XCTAssertEqual(leftover, "")
    XCTAssertFalse(fixture.search.hasAPIKey)
  }

  // MARK: Shared model logic

  @MainActor
  func testModelActionsFollowEachModelsState() throws {
    let recommendations = LocalModelSelector.select(manifest: .bundled, hardware: hardware(memory: 32))
    let assessment = try XCTUnwrap(recommendations.assessments.first { $0.canInstall })
    let current = installedModel(for: assessment)
    var stale = current
    stale.visionConfiguration?.packageRevision = "old"
    typealias Logic = LocalModelSettingsLogic
    XCTAssertEqual(Logic.managerAction(for: assessment, installed: [], activeID: nil, isBusy: false),
                   LocalModelActionState(action: .install, isEnabled: true))
    XCTAssertFalse(Logic.managerAction(for: assessment, installed: [], activeID: nil, isBusy: true).isEnabled)
    XCTAssertEqual(Logic.managerAction(for: assessment, installed: [current], activeID: nil, isBusy: false),
                   LocalModelActionState(action: .use(isSelected: false), isEnabled: true))
    XCTAssertEqual(Logic.managerAction(for: assessment, installed: [current], activeID: assessment.id, isBusy: false),
                   LocalModelActionState(action: .use(isSelected: true), isEnabled: false))
    XCTAssertEqual(Logic.managerAction(for: assessment, installed: [stale], activeID: nil, isBusy: false).action, .update)
    var full = hardware(memory: 32)
    full.availableDiskBytes = 0
    let noRoom = LocalModelSelector.assess(assessment.model, hardware: full)
    XCTAssertFalse(noRoom.canInstall)
    XCTAssertEqual(Logic.managerAction(for: noRoom, installed: [], activeID: nil, isBusy: false),
                   LocalModelActionState(action: .install, isEnabled: false))
    let largest = try XCTUnwrap(LocalModelManifest.bundled.models.first { $0.id == "qwen3.8-27b-q8_0" })
    let overBudget = LocalModelSelector.assess(largest, hardware: hardware(memory: 32))
    XCTAssertEqual(overBudget.fit, .memory)
    XCTAssertTrue(overBudget.permitsMemoryOverride)
    XCTAssertEqual(Logic.managerAction(for: overBudget, installed: [], activeID: nil, isBusy: false),
                   LocalModelActionState(action: .install, isEnabled: true))
  }

  @MainActor
  func testFileToolsInstallationReportsProgressFailureAndCancellation() async throws {
    struct Broken: LocalizedError { var errorDescription: String? { "The runtime couldn't be verified." } }
    let working = LocalFileToolsInstallation { progress in
      await progress(ModelDownloadProgress(receivedByteCount: 5, expectedByteCount: 10))
    }
    working.start()
    try await waitForUI("the install to finish") { working.didInstall }
    XCTAssertEqual(working.progress, 0.5)
    XCTAssertFalse(working.isInstalling)
    XCTAssertTrue(working.isReady(for: nil))

    let failing = LocalFileToolsInstallation { _ in throw Broken() }
    failing.start()
    try await waitForUI("the failure") { failing.error != nil }
    XCTAssertEqual(failing.error, Broken().localizedDescription)
    XCTAssertFalse(failing.isReady(for: nil))

    let slow = LocalFileToolsInstallation { _ in try await Task.sleep(for: .seconds(30)) }
    slow.start()
    XCTAssertTrue(slow.isInstalling)
    slow.cancel()
    try await waitForUI("the cancellation") { !slow.isInstalling }
    XCTAssertNil(slow.error, "Cancelling isn't an error")
    XCTAssertFalse(slow.didInstall)
  }

  // MARK: Screenshots

  @MainActor
  func testSaveSettingsScreenshots() async throws {
    _ = try EnigmaSnapshot.directory()
    let fixture = try await Fixture(test: self)
    for destination in SettingsView.SettingsDestination.allCases {
      try await EnigmaSnapshot.save("settings-\(destination.rawValue.lowercased().split(separator: " ").first!)",
                                    size: SettingsView.windowSize, until: { !fixture.advisor.isDetecting }) {
        fixture.settings(destination)
      }
    }
    // Whole pages: Cloud and search's web search, advanced settings, and API
    // keys; General's location, Messages and Updates.
    for (destination, height) in [(SettingsView.SettingsDestination.cloud, 1680.0), (.general, 1400.0)] {
      let size = CGSize(width: SettingsView.windowSize.width, height: height)
      try await EnigmaSnapshot.save("settings-\(destination.rawValue.lowercased().split(separator: " ").first!)-full",
                                    size: size, until: { !fixture.advisor.isDetecting }) {
        fixture.settings(destination, size: size)
      }
    }
    // The welcome's connection settings sheet, with Back to setup in its own bar.
    try await EnigmaSnapshot.save("settings-connection-sheet", size: ConnectionSettingsSheet.size,
                                  until: { !fixture.advisor.isDetecting }) {
      ConnectionSettingsSheet(cloud: fixture.cloud, advisor: fixture.advisor, chat: fixture.chat,
                                    search: fixture.search) {}
    }
    // An open menu, opened by a real click.
    for appearance in [EnigmaAppearance.paper, .ink] {
      let host = Host(fixture.settings(.general).enigmaTheme(appearance), test: self)
      try await waitForUI("the start mode menu", in: host.view) { host.shows("Prefer Start Mode") }
      try host.press("Prefer Start Mode")
      try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Local") }
      try await Task.sleep(for: .milliseconds(400))
      try save(try EnigmaSnapshot.capture(host.view), name: "settings-menu-\(appearance.rawValue)")
      host.close()
    }
  }

  @MainActor
  private func save(_ image: NSBitmapImageRep, name: String) throws {
    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try png.write(to: try EnigmaSnapshot.directory().appending(path: "\(name).png"))
  }

  // MARK: Helpers

  /// The window applies a change on the main queue's next turn.
  @MainActor
  private func mainQueueTurn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }

  @MainActor
  private func makeDefaults() throws -> UserDefaults {
    let name = "EnigmaSettingsTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return defaults
  }

  private func hardware(memory: Int, bandwidth: Double? = nil) -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: Int64(memory) * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Apple M3 Pro", device: "MacBook Pro", cpuCount: 12, performanceCPUCount: 6,
      availableDiskBytes: 212 * gib, metalRecommendedWorkingSet: nil, metalMaximumBufferLength: 8 * gib,
      lowPowerMode: false, measuredBandwidth: bandwidth)
  }

  private func installedModel(for assessment: LocalModelAssessment) -> LocalModel {
    let descriptor = assessment.model
    let file = URL(fileURLWithPath: "/tmp/enigma-settings-fixture.gguf")
    return LocalModel(id: assessment.id, displayName: descriptor.displayName, fileURL: file,
      catalogDescriptor: descriptor, visionConfiguration: LocalVisionConfiguration(projectorURL: file,
        serverExecutableURL: URL(fileURLWithPath: "/bin/echo"), contextWindow: descriptor.recommendedContextSize,
        packageRevision: descriptor.packageRevision))
  }

  private func matches(_ color: NSColor, under name: NSAppearance.Name, _ expected: EnigmaColor) -> Bool {
    var resolved: NSColor?
    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    guard let resolved else { return false }
    return EnigmaSnapshot.matches(EnigmaColor(red: resolved.redComponent, green: resolved.greenComponent,
                                              blue: resolved.blueComponent), expected)
  }

  private func assertPixel(_ image: NSBitmapImageRep, at point: CGPoint, is expected: EnigmaColor, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    let color = try EnigmaSnapshot.pixel(image, at: point)
    XCTAssertTrue(EnigmaSnapshot.matches(color, expected), "\(message): \(color) at \(point)", file: file, line: line)
  }

  /// Types into the `index`th secure field on the page, as a person would.
  @MainActor @discardableResult
  private func type(_ text: String, intoFieldAt index: Int, of host: Host,
                    file: StaticString = #filePath, line: UInt = #line) async throws -> NSSecureTextField {
    try await waitForUI("secure field \(index)", in: host.view, file: file, line: line) {
      host.secureFields.count > index
    }
    let field = host.secureFields[index]
    XCTAssertTrue(host.window.makeFirstResponder(field), file: file, line: line)
    try await waitForUI("the field's editor", in: host.view, file: file, line: line) { field.currentEditor() != nil }
    field.currentEditor()?.insertText(text)
    try await waitForUI("the typed key", in: host.view, file: file, line: line) { field.stringValue == text }
    return field
  }

  /// Real Settings models with offline fixtures: a 32 GB Mac with no models,
  /// no Codex or Claude Code, and the given key stores.
  @MainActor
  private final class Fixture {
    let defaults: UserDefaults
    let advisor: LocalModelAdvisor
    let chat: LocalChatViewModel
    let cloud: CloudSettingsModel
    let search: WebSearchSettings
    let screen: ScreenSettings
    let start: StartPreferences
    let selection: SelectionEditingSettings
    let location: LocationService
    let appearance: EnigmaAppearancePreference
    let updaterBackend = FakeUpdaterBackend()
    let updater: AppUpdater
    /// Counts the bandwidth tests; each reads 267 GB/s.
    let probe = BandwidthProbeCounter()

    init(test: EnigmaSettingsTests, cloudCredentials: any CloudCredentialStore = ScreenTestCredentialStore(),
         transport: ScreenTestTransport = ScreenTestTransport(),
         searchCredentials: any WebSearchCredentialStore = MemorySearchCredentials(),
         engine: any LocalModelEngine = SettingsTestEngine()) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: "EnigmaSettingsTests-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defaults = try test.makeDefaults()
      let profile = test.hardware(memory: 32, bandwidth: 267)
      let probe = probe
      advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil,
                                  detect: { _ in profile }, measureBandwidth: { probe.measure() })
      await advisor.detectHardware()
      let chat = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: root))
      self.chat = chat
      cloud = CloudSettingsModel(credentialStore: cloudCredentials,
        catalog: CloudModelCatalog(credentialStore: cloudCredentials, transport: transport, cacheDirectory: root),
        preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
        claudeCode: ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root, executable: { nil })))
      search = WebSearchSettings(credentials: searchCredentials, defaults: defaults)
      screen = ScreenSettings(defaults: defaults)
      start = StartPreferences(defaults: defaults)
      selection = SelectionEditingSettings(defaults: defaults)
      location = LocationService(defaults: defaults)
      appearance = EnigmaAppearancePreference(defaults: defaults)
      updater = AppUpdater(backend: updaterBackend)
      test.addTeardownBlock { @MainActor in
        await chat.stopStreaming()?.value
        await chat.sessionWriter.waitForPendingWrites()
        try? FileManager.default.removeItem(at: root)
      }
    }

    func settings(_ destination: SettingsView.SettingsDestination = .general,
                  appearance: EnigmaAppearancePreference? = nil,
                  size: CGSize = SettingsView.windowSize) -> SettingsView {
      SettingsView(settings: cloud, appearance: appearance ?? self.appearance, initialDestination: destination,
                         advisor: advisor, chat: chat, search: search, screen: screen,
                         startPreferences: start, selectionEditing: selection, location: location,
                         updater: updater, size: size)
    }
  }

  /// Settings in a window that can take clicks, with test markers on.
  @MainActor
  private final class Host {
    let view: NSView
    let window: NSWindow

    /// Pages are shown in full, without scrolling, at a tall `size`.
    init<Content: View>(_ content: Content, size: CGSize = SettingsView.windowSize, test: XCTestCase) {
      let root = content
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
        .transaction { $0.disablesAnimations = true }
      view = NSHostingView(rootView: root)
      window = SettingsKeyableTestWindow(contentRect: NSRect(origin: .zero, size: size),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.hidesOnDeactivate = false
      window.colorSpace = .sRGB
      window.contentView = view
      window.orderFrontRegardless()
      window.makeKey()
      view.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      test.addTeardownBlock { @MainActor [window] in
        window.orderOut(nil)
        window.contentView = nil
      }
    }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
    }

    /// The visible marker named `name`, in the window or a sheet on it.
    func marker(_ name: String) -> NSView? {
      func search(_ node: NSView) -> NSView? {
        if node is TestControlMarker.Marker, node.identifier?.rawValue == name, !node.isHiddenOrHasHiddenAncestor,
           node.visibleRect.width > 1, node.visibleRect.height > 1 { return node }
        return node.subviews.lazy.compactMap(search).first
      }
      let roots = [view] + [window.attachedSheet?.contentView].compactMap { $0 }
      return roots.lazy.compactMap(search).first
    }

    /// The frame of marker `name` in the host view's top-left coordinates.
    func frame(of name: String) -> CGRect? {
      guard let target = marker(name), target.window === window else { return nil }
      let rect = target.convert(target.bounds, to: view)
      return view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY,
                                            width: rect.width, height: rect.height)
    }

    /// A key press as AppKit delivers it.
    func key(_ code: UInt16, _ characters: String) throws {
      for type: NSEvent.EventType in [.keyDown, .keyUp] {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
      }
    }

    /// Whether the `accent` focus ring is drawn just outside control `name`.
    func showsFocusRing(around name: String, palette: EnigmaPalette) -> Bool {
      guard let frame = frame(of: name), let image = try? EnigmaSnapshot.capture(view),
            let color = try? EnigmaSnapshot.pixel(image, at: CGPoint(x: frame.minX - 2, y: frame.midY)) else {
        return false
      }
      return EnigmaSnapshot.matches(color, palette.accent)
    }

    func shows(_ name: String) -> Bool { marker(name) != nil }

    /// Whether SwiftUI has control `name` enabled, or nil when it isn't shown.
    func isEnabled(_ name: String) -> Bool? { (marker(name) as? TestControlMarker.Marker)?.isEnabled }

    /// Clicks the real control behind a marker with a mouse down and up.
    func press(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
      let target = try XCTUnwrap(marker(name), "No control \(name)", file: file, line: line)
      let targetWindow = try XCTUnwrap(target.window, file: file, line: line)
      let location = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
      for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWindow.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
        targetWindow.sendEvent(event)
      }
    }

    var secureFields: [NSSecureTextField] {
      func search(_ node: NSView) -> [NSSecureTextField] {
        if let field = node as? NSSecureTextField { return [field] }
        return node.subviews.flatMap(search)
      }
      return search(view)
    }
  }
}

/// A panel that can be key even while another app is active, which happens on
/// CI runners mid-run: a plain window then can't be key, and an open menu
/// can't take keyboard focus.
private final class SettingsKeyableTestWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}

private actor SettingsTestEngine: LocalModelEngine {
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { [] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private final class MemorySearchCredentials: WebSearchCredentialStore, @unchecked Sendable {
  private var key: String?
  func apiKey() throws -> String? { key }
  func setAPIKey(_ value: String) throws { key = value }
  func removeAPIKey() throws { key = nil }
}

private struct FailingSearchCredentials: WebSearchCredentialStore {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The keychain refused the Brave key." }
  }
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws { throw Failure() }
  func removeAPIKey() throws {}
}

private struct FailingCloudCredentials: CloudCredentialStore {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The keychain refused the API key." }
  }
  func apiKey(for provider: CloudProviderID) throws -> String? { nil }
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws { throw Failure() }
  func removeAPIKey(for provider: CloudProviderID) throws { throw Failure() }
}

private final class TransferLog: @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String] = []
  var files: [String] { lock.withLock { names.sorted() } }
  func append(_ name: String) { lock.withLock { names.append(name) } }
}

/// Records what the Local models page asks of the engine. Downloads fail, so nothing installs.
private actor SettingsRecordingEngine: LocalModelEngine {
  private(set) var downloads: [String] = []
  private(set) var selections: [String] = []
  private(set) var deletions: [String] = []
  private var installed: [LocalModel]

  init(installed: [LocalModel] = []) { self.installed = installed }
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { installed }
  func selectModel(id: String) async throws { selections.append(id) }
  func deleteModel(id: String) async throws {
    deletions.append(id)
    installed.removeAll { $0.id == id }
  }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    downloads.append(model.id)
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

@MainActor
private final class MenuHarnessModel: ObservableObject {
  @Published var options = ["A", "B"]
  @Published var selection = "A"
  @Published var offset: CGFloat = 0
  @Published var showsTrigger = true
}

private struct MenuHarness: View {
  @ObservedObject var model: MenuHarnessModel
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.showsTrigger {
        EnigmaMenu("Harness", selection: $model.selection,
                   options: model.options.map { EnigmaOption($0, $0) })
          .padding(.top, model.offset)
      }
      Spacer(minLength: 0)
    }
    .padding(40)
    .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height,
           alignment: .topLeading)
    .background(palette.background.color)
    .enigmaMenuHost()
  }
}

/// A bandwidth test that reads 267 GB/s and counts how often it runs.
private final class BandwidthProbeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var count: Int { lock.withLock { calls } }
  func measure() -> Double? {
    lock.withLock { calls += 1 }
    return 267
  }
}
