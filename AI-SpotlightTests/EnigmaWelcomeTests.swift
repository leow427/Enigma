import AppKit
import SwiftUI
import XCTest
@testable import Enigma

/// The new UI's first-run setup: its flow logic, its rendering at the panel's
/// sizes, the flag that swaps it in, and its screenshots.
final class EnigmaWelcomeTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib

  // MARK: Flow logic

  @MainActor
  func testCounterReadsTheStepOutOfFour() {
    XCTAssertEqual(WelcomeSetup.Step.allCases.map(WelcomeSetup.counter(for:)), ["1/4", "2/4", "3/4", "4/4"])
  }

  @MainActor
  func testBackAndContinueStayWithinTheFourSteps() throws {
    let setup = WelcomeSetup(defaults: try defaults())
    setup.replay()
    setup.goBack()
    XCTAssertEqual(setup.step, .welcome, "Back on the first step stays there")
    var visited = [setup.step]
    for _ in 0..<5 {
      setup.advance()
      visited.append(setup.step)
    }
    XCTAssertEqual(visited, [.welcome, .models, .connections, .walkthrough, .walkthrough, .walkthrough])
    setup.goBack()
    XCTAssertEqual(setup.step, .connections)
  }

  @MainActor
  func testCharacterGlidesFromTheWelcomeIntoTheStepHeader() {
    XCTAssertEqual(WelcomeSetup.characterSlot(for: .welcome), .hero)
    XCTAssertEqual(WelcomeSetup.CharacterSlot.hero.size, 150)
    XCTAssertEqual(WelcomeSetup.CharacterSlot.header.size, 40)
    XCTAssertNotEqual(WelcomeSetup.CharacterSlot.hero.id, WelcomeSetup.CharacterSlot.header.id)
    for step in [WelcomeSetup.Step.models, .connections, .walkthrough] {
      XCTAssertEqual(WelcomeSetup.characterSlot(for: step), .header)
    }
    XCTAssertEqual(WelcomeSetup.characterTransition(from: .welcome, to: .models), .glide)
    XCTAssertEqual(WelcomeSetup.characterTransition(from: .models, to: .welcome), .automatic,
                   "Back to the welcome drops it into the large slot")
    XCTAssertNil(WelcomeSetup.characterTransition(from: .models, to: .connections),
                 "Between later steps it stays in the header")
    XCTAssertNil(WelcomeSetup.characterTransition(from: .welcome, to: .welcome))
  }

  @MainActor
  func testCharacterThinksListensAndShowsErrorsOnTheRightSteps() {
    typealias Activity = WelcomeSetup.Activity
    let state = WelcomeSetup.characterState
    XCTAssertEqual(state(.models, Activity(isDetectingHardware: true)), .thinking)
    XCTAssertEqual(state(.models, Activity(isInstalling: true)), .thinking)
    XCTAssertEqual(state(.models, Activity(installFailed: true)), .error)
    XCTAssertEqual(state(.models, Activity()), .idle)
    XCTAssertEqual(state(.models, Activity(connectionFailed: true, isEnteringKey: true)), .idle,
                   "Connection cues belong to the connections step")
    XCTAssertEqual(state(.connections, Activity(isEnteringKey: true)), .listening)
    XCTAssertEqual(state(.connections, Activity(connectionFailed: true, isEnteringKey: true)), .error,
                   "A failure outranks typing")
    XCTAssertEqual(state(.connections, Activity(isInstalling: true)), .idle)
    for step in [WelcomeSetup.Step.welcome, .walkthrough] {
      XCTAssertEqual(state(step, Activity(isDetectingHardware: true, isInstalling: true, installFailed: true,
                                          connectionFailed: true, isEnteringKey: true)), .idle)
    }
  }

  @MainActor
  func testDownloadingVerifyingAndCheckingCountAsInstalling() {
    let progress = ModelDownloadProgress(receivedByteCount: 5, expectedByteCount: 10)
    let installing: [LocalChatViewModel.State] = [.downloading(progress), .installing, .benchmarking]
    let other: [LocalChatViewModel.State] = [.idle, .deleting, .preparing, .streaming, .failed("No")]
    XCTAssertTrue(installing.allSatisfy(WelcomeSetup.isInstalling))
    XCTAssertFalse(other.contains(where: WelcomeSetup.isInstalling))
    XCTAssertTrue(WelcomeSetup.installFailed(.failed("The download couldn't be verified.")))
    XCTAssertFalse((installing + [.idle, .streaming]).contains(where: WelcomeSetup.installFailed))
  }

  @MainActor
  func testModelStepHasOneActionThatContinuesExactlyWhenSetupAllowsIt() throws {
    let recommendations = LocalModelSelector.select(manifest: .bundled, hardware: hardware(memory: 32))
    let selected = try XCTUnwrap(WelcomeSetup.choices(recommendations).first)
    let current = installedModel(for: selected)
    var stale = current
    stale.visionConfiguration?.packageRevision = "old"
    let action = WelcomeSetup.modelAction
    XCTAssertEqual(action(selected, [], nil, false), .install)
    XCTAssertEqual(action(selected, [stale], selected.id, false), .update)
    XCTAssertEqual(action(selected, [current], "other", false), .use)
    XCTAssertEqual(action(selected, [current], selected.id, false), .proceed)
    XCTAssertNil(action(nil, [], nil, false), "Nothing to do before a model is chosen")
    XCTAssertEqual(action(nil, [], nil, true), .proceed, "Skipping local models continues")
    // Continue is offered exactly when the old screen's Next would be enabled.
    for selection in [selected, nil] as [LocalModelAssessment?] {
      for installed in [[], [current], [stale]] {
        for activeID in [nil, selected.id, "other"] {
          for skip in [false, true] {
            XCTAssertEqual(action(selection, installed, activeID, skip) == .proceed,
                           WelcomeSetup.canContinue(selected: selection, installed: installed, activeID: activeID,
                                                    skipLocal: skip, busy: false))
          }
        }
      }
    }
  }

  @MainActor
  func testReturnPressesTheModelButtonOnlyWhenNothingDownloads() {
    XCTAssertFalse(WelcomeSetup.returnPressesModelAction(.install))
    XCTAssertFalse(WelcomeSetup.returnPressesModelAction(.update))
    XCTAssertTrue(WelcomeSetup.returnPressesModelAction(.use))
    XCTAssertTrue(WelcomeSetup.returnPressesModelAction(.proceed))
  }

  @MainActor
  func testSelectionShortcutLineFollowsTheSetting() {
    XCTAssertEqual(WelcomeSetup.selectionShortcut(modifier: "option", isEnabled: true), "⌥⌥")
    XCTAssertEqual(WelcomeSetup.selectionShortcut(modifier: "command", isEnabled: true), "⌘⌘")
    XCTAssertEqual(WelcomeSetup.selectionShortcut(modifier: "nonsense", isEnabled: true), "⌥⌥")
    XCTAssertNil(WelcomeSetup.selectionShortcut(modifier: "option", isEnabled: false))
  }

  func testTourCardStaysInsideTheWindowAndBesideItsTarget() {
    for container in [CGSize(width: 640, height: 420), CGSize(width: 1200, height: 780)] {
      let height: CGFloat = 200
      let top = WelcomeTourPlacement(target: CGRect(x: 20, y: 30, width: 40, height: 30), container: container,
                                     cardHeight: height)
      XCTAssertEqual(top.highlight, CGRect(x: 15, y: 25, width: 50, height: 40))
      XCTAssertEqual(top.cardOrigin.y, top.highlight.maxY + 16, "Below a target in the top half")
      let bottom = WelcomeTourPlacement(target: CGRect(x: container.width - 300, y: container.height - 60,
                                                       width: 280, height: 44),
                                        container: container, cardHeight: height)
      XCTAssertEqual(bottom.cardOrigin.y + height, bottom.highlight.minY - 16, "Above a target in the bottom half")
      let missing = WelcomeTourPlacement(target: nil, container: container, cardHeight: height)
      XCTAssertEqual(missing.highlight.size, .zero)
      let offscreen = WelcomeTourPlacement(target: CGRect(x: -400, y: -400, width: 10, height: 10),
                                           container: container, cardHeight: height)
      XCTAssertEqual(offscreen.highlight.size, .zero, "A target outside the window falls back")
      for placement in [top, bottom, missing, offscreen] {
        XCTAssertLessThanOrEqual(placement.cardWidth, WelcomeTourPlacement.maximumCardWidth)
        let card = CGRect(origin: placement.cardOrigin, size: CGSize(width: placement.cardWidth, height: height))
        XCTAssertTrue(CGRect(origin: .zero, size: container).insetBy(dx: 15.9, dy: 15.9).contains(card),
                      "\(card) leaves \(container)")
      }
    }
  }

  // MARK: Theme inside the old window

  @MainActor
  func testEmbeddedThemeFollowsTheMacAndLeavesTheOldWindowDark() throws {
    for (appearance, mac, palette, scheme) in [
      (EnigmaAppearance.system, ColorScheme.light, EnigmaPalette.paper, ColorScheme.light),
      (.system, .dark, .ink, .dark),
      (.paper, .dark, .paper, .light),
      (.ink, .light, .ink, .dark),
    ] {
      let probe = EmbeddedThemeProbe.Box()
      // The old shell forces dark mode on its whole window.
      let root = EmbeddedThemeProbe(box: probe)
        .enigmaEmbeddedTheme(appearance, system: EnigmaSystemAppearance(colorScheme: mac))
        .preferredColorScheme(.dark)
      let host = NSHostingView(rootView: root)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                            backing: .buffered, defer: false)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      XCTAssertEqual(probe.palette, palette, "\(appearance) on a \(mac) Mac")
      XCTAssertEqual(probe.colorScheme, scheme, "\(appearance) on a \(mac) Mac")
      XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                     "The new screen must not change the old window's scheme")
      window.contentView = nil
    }
  }

  @MainActor
  func testSystemAppearanceReadsLightAndDark() throws {
    XCTAssertEqual(EnigmaSystemAppearance.scheme(of: try XCTUnwrap(NSAppearance(named: .aqua))), .light)
    XCTAssertEqual(EnigmaSystemAppearance.scheme(of: try XCTUnwrap(NSAppearance(named: .darkAqua))), .dark)
    XCTAssertEqual(EnigmaSystemAppearance(colorScheme: .dark).colorScheme, .dark)
  }

  // MARK: Rendering

  @MainActor
  func testNewWelcomeRendersEveryStepAtMinimumAndDefaultPanelSizes() async throws {
    let fixture = try await Fixture(test: self)
    fixture.setup.replay()
    for step in WelcomeSetup.Step.allCases {
      fixture.setup.step = step
      for size in [CGSize(width: 640, height: 420), CGSize(width: 1200, height: 780)] {
        for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
          let character = EnigmaCharacterController(seed: 3)
          let image = try EnigmaSnapshot.render(
            fixture.welcome(character: character).enigmaCharacterStage(character).enigmaTheme(appearance),
            size: size)
          let label = "\(step) at \(Int(size.width))×\(Int(size.height)) in \(appearance)"
          for corner in [CGPoint(x: 0, y: 0), CGPoint(x: size.width - 0.5, y: 0), CGPoint(x: 0, y: size.height - 0.5),
                         CGPoint(x: size.width - 0.5, y: size.height - 0.5)] {
            XCTAssertLessThan(try alpha(image, at: corner), 0.05, "Corners stay transparent: \(label)")
          }
          // The margin beside the content column is the opaque canvas.
          try assertPixel(image, at: CGPoint(x: 14, y: size.height / 2), is: palette.background, label)
          XCTAssertEqual(character.activeSlot, WelcomeSetup.characterSlot(for: step).id, label)
        }
      }
    }
  }

  @MainActor
  func testNewOnboardingSheetRendersWithRealChoices() async throws {
    let fixture = try await Fixture(test: self)
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      let image = try EnigmaSnapshot.render(
        EnigmaLocalModelOnboardingView(advisor: fixture.advisor, chat: fixture.chat).enigmaTheme(appearance),
        size: CGSize(width: 560, height: 650))
      try assertPixel(image, at: CGPoint(x: 8, y: 325), is: palette.background, "\(appearance) sheet")
    }
  }

  // MARK: In the app

  @MainActor
  func testFlagSwapsTheWelcomeWhileTheAppRunsAndKeepsTheOldWindowDark() async throws {
    let fixture = try await Fixture(test: self)
    let newUI = NewUIPreference(defaults: fixture.defaults)
    XCTAssertFalse(newUI.isEnabled)
    let size = CGSize(width: 900, height: 620)
    let view = NSHostingView(rootView: fixture.shell(newUI: newUI).transaction { $0.disablesAnimations = true })
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.colorSpace = .sRGB
    window.contentView = view
    defer { window.contentView = nil }
    fixture.setup.replay()
    let palette = EnigmaAppearance.system.palette(for: EnigmaSystemAppearance.shared.colorScheme)
    func showsNewWelcome() throws -> Bool {
      let image = try EnigmaSnapshot.capture(view)
      return EnigmaSnapshot.matches(try EnigmaSnapshot.pixel(image, at: CGPoint(x: 14, y: size.height / 2)),
                                    palette.background)
    }
    try await waitForUI("the old welcome", in: view) { (try? showsNewWelcome()) == false && composerEditor(in: view) != nil }
    XCTAssertFalse(try showsNewWelcome())

    newUI.isEnabled = true
    try await waitForUI("the new welcome after turning the flag on", in: view) { (try? showsNewWelcome()) == true }
    XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                   "The old shell still owns the window's scheme")
    XCTAssertEqual(composerEditor(in: view)?.isEditable, false, "The chat stays disabled under the new welcome")

    newUI.isEnabled = false
    try await waitForUI("the old welcome after turning the flag off", in: view) { (try? showsNewWelcome()) == false }
  }

  @MainActor
  func testChatBecomesEditableImmediatelyAfterEveryNewWelcomeExit() async throws {
    let fixture = try await Fixture(test: self)
    let newUI = NewUIPreference(defaults: fixture.defaults)
    newUI.isEnabled = true
    let preferences = StartPreferences(defaults: fixture.defaults)
    preferences.mode = .cloud
    let appearance = GlassAppearanceSettings(defaults: fixture.defaults)
    let view = NSHostingView(rootView: fixture.shell(newUI: newUI, preferences: preferences)
      .transaction { $0.disablesAnimations = true })
    let controller = SpotlightPanelController(glassAppearance: appearance, sizeStore: PanelSizeStore(defaults: fixture.defaults),
      contentView: view, welcomeSetup: fixture.setup)
    controller.show()
    defer { controller.hide(); view.window?.contentView = nil }
    try await waitForUI("new welcome host to install the composer", in: view) { composerEditor(in: view) != nil }
    for exit in 0..<3 {
      fixture.setup.replay()
      try await waitForUI("new welcome replay to disable the composer", in: view) {
        composerEditor(in: view)?.isEditable == false
      }
      fixture.setup.finish(takeTour: exit != 0)
      if exit == 1 { fixture.setup.endTour() }
      if exit == 2 {
        for _ in WelcomeTourStep.allCases { fixture.setup.nextTourStep() }
      }
      try await waitForUI("new welcome exit \(exit) to enable, focus, and uncover the composer", in: view) {
        guard let composer = composerEditor(in: view) else { return false }
        return composer.isEditable && composer.window?.firstResponder === composer && composerAcceptsClicks(in: view)
      }
      let composer = try XCTUnwrap(composerEditor(in: view))
      XCTAssertTrue(composer.isEditable, "New welcome exit \(exit) must enable the composer")
      XCTAssertEqual(preferences.mode, .auto)
      let point = composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: view.superview)
      let hit = try XCTUnwrap(view.hitTest(point))
      XCTAssertTrue(hit === composer || hit.isDescendant(of: composer),
                    "New welcome exit \(exit) must allow clicks through to chat; hit \(hit)")
      let draft = "Ready after new exit \(exit)"
      composer.insertText(draft, replacementRange: NSRange(location: 0, length: composer.string.utf16.count))
      XCTAssertEqual(fixture.screen.draft, draft, "Typing must reach the composer binding after every exit")
    }
  }

  @MainActor
  func testReturnPressesTheStepsPrimaryButton() async throws {
    let fixture = try await Fixture(test: self)
    fixture.setup.replay()
    let character = EnigmaCharacterController(seed: 2)
    let view = NSHostingView(rootView: fixture.welcome(character: character).enigmaCharacterStage(character)
      .enigmaTheme(.paper).transaction { $0.disablesAnimations = true })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view
    defer { window.contentView = nil }
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func pressReturn() throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
      _ = window.performKeyEquivalent(with: event)
    }
    try pressReturn()
    try await waitForUI("Return to start setup", in: view) { fixture.setup.step == .models }
    try await waitForUI("the character to glide to the header", in: view) {
      character.activeSlot == WelcomeSetup.CharacterSlot.header.id
    }
    fixture.setup.step = .walkthrough
    try await waitForUI("the walkthrough", in: view) { true }
    try pressReturn()
    try await waitForUI("Return to take the tour", in: view) { fixture.setup.tour == .history }
    XCTAssertFalse(fixture.setup.isPresented)
  }

  // MARK: Screenshots

  @MainActor
  func testSaveWelcomeScreenshots() async throws {
    _ = try EnigmaSnapshot.directory()
    let fixture = try await Fixture(test: self)
    fixture.setup.replay()
    let defaultSize = CGSize(width: 1200, height: 780)
    for step in WelcomeSetup.Step.allCases {
      fixture.setup.step = step
      try await saveWelcome("welcome-\(step.rawValue + 1)-\(step)", fixture: fixture, step: step, size: defaultSize)
    }
    try await saveWelcome("welcome-1-welcome-minimum", fixture: fixture, step: .welcome, size: CGSize(width: 640, height: 420))
    try EnigmaSnapshot.save("tour-card", size: CGSize(width: 380, height: 600)) {
      EnigmaWelcomeTourCard(setup: fixture.setup, step: .commands,
                            availableCommands: SlashCommand.available(hasSearchKey: true))
        .frame(width: WelcomeTourPlacement.maximumCardWidth)
    }
  }

  @MainActor
  private func saveWelcome(_ name: String, fixture: Fixture, step: WelcomeSetup.Step, size: CGSize) async throws {
    fixture.setup.step = step
    let character = EnigmaCharacterController(seed: 5)
    // Already in place, so the screenshot shows it rather than its grow-in.
    character.move(to: WelcomeSetup.characterSlot(for: step).id, .instant)
    // The welcome checks the Mac again when it appears, as the old one does.
    try await EnigmaSnapshot.save(name, size: size, until: { !fixture.advisor.isDetecting }) {
      fixture.welcome(character: character).enigmaCharacterStage(character)
    }
  }

  // MARK: Helpers

  @MainActor
  private func defaults() throws -> UserDefaults {
    let name = "EnigmaWelcomeTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return defaults
  }

  private func hardware(memory: Int) -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: Int64(memory) * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Apple M3 Pro", device: "MacBook Pro", cpuCount: 12, performanceCPUCount: 6,
      availableDiskBytes: 212 * gib, metalRecommendedWorkingSet: nil, metalMaximumBufferLength: 8 * gib,
      lowPowerMode: false)
  }

  private func installedModel(for assessment: LocalModelAssessment) -> LocalModel {
    let descriptor = assessment.model
    let file = URL(fileURLWithPath: "/tmp/enigma-welcome-fixture.gguf")
    return LocalModel(id: assessment.id, displayName: descriptor.displayName, fileURL: file,
      catalogDescriptor: descriptor, visionConfiguration: LocalVisionConfiguration(projectorURL: file,
        serverExecutableURL: URL(fileURLWithPath: "/bin/echo"), contextWindow: descriptor.recommendedContextSize,
        packageRevision: descriptor.packageRevision))
  }

  private func alpha(_ image: NSBitmapImageRep, at point: CGPoint) throws -> Double {
    try EnigmaSnapshot.pixel(image, at: point).opacity
  }

  private func assertPixel(_ image: NSBitmapImageRep, at point: CGPoint, is expected: EnigmaColor, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    let color = try EnigmaSnapshot.pixel(image, at: point)
    XCTAssertTrue(EnigmaSnapshot.matches(color, expected), "\(message): \(color) at \(point)", file: file, line: line)
  }

  /// Real setup models with offline fixtures: a 32 GB Mac, no models, no
  /// Codex or Claude Code on the machine, and no Brave key.
  @MainActor
  private final class Fixture {
    let defaults: UserDefaults
    let setup: WelcomeSetup
    let advisor: LocalModelAdvisor
    let chat: LocalChatViewModel
    let cloud: CloudSettingsModel
    let search: WebSearchSettings
    let screen = ScreenComposerCoordinator()

    init(test: EnigmaWelcomeTests, engine: any LocalModelEngine = WelcomeTestEngine(),
         searchCredentials: any WebSearchCredentialStore = WelcomeTestSearchCredentials()) async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: "EnigmaWelcomeTests-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defaults = try test.defaults()
      let profile = test.hardware(memory: 32)
      advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil,
                                  detect: { _ in profile })
      await advisor.detectHardware()
      let chat = LocalChatViewModel(engine: engine, sessionStore: ChatSessionStore(applicationSupportDirectory: root))
      self.chat = chat
      let credentials = ScreenTestCredentialStore()
      cloud = CloudSettingsModel(credentialStore: credentials,
        catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
        preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
        claudeCode: ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root, executable: { nil })))
      search = WebSearchSettings(credentials: searchCredentials, defaults: defaults)
      setup = WelcomeSetup(defaults: defaults)
      test.addTeardownBlock { @MainActor in
        await chat.stopStreaming()?.value
        await chat.sessionWriter.waitForPendingWrites()
        try? FileManager.default.removeItem(at: root)
      }
    }

    func welcome(character: EnigmaCharacterController) -> EnigmaWelcomeView {
      EnigmaWelcomeView(setup: setup, character: character, advisor: advisor, chat: chat, cloud: cloud, search: search)
    }

    func shell(newUI: NewUIPreference, preferences: StartPreferences? = nil) -> AppShellView {
      AppShellView(glassAppearance: GlassAppearanceSettings(defaults: defaults), cloudSettings: cloud,
        localChat: chat, screen: screen, modelAdvisor: advisor, searchSettings: search,
        startPreferences: preferences ?? StartPreferences(defaults: defaults), welcomeSetup: setup, newUI: newUI)
    }
  }
}

/// Reports the palette and scheme its environment resolves to.
private struct EmbeddedThemeProbe: View {
  final class Box {
    var palette: EnigmaPalette?
    var colorScheme: ColorScheme?
  }

  let box: Box
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    box.palette = palette
    box.colorScheme = colorScheme
    return Color.clear
  }
}

private actor WelcomeTestEngine: LocalModelEngine {
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

private struct WelcomeTestSearchCredentials: WebSearchCredentialStore {
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws {}
  func removeAPIKey() throws {}
}

// MARK: Hosted interactions

extension EnigmaWelcomeTests {
  /// The welcome in a window, with its own character, as `AppShellView` shows it.
  @MainActor
  private final class Host {
    let view: NSView
    let window: NSWindow
    let character = EnigmaCharacterController(seed: 4)

    init(_ fixture: Fixture, test: XCTestCase) {
      let root = fixture.welcome(character: character).enigmaCharacterStage(character).enigmaTheme(.paper)
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
        .transaction { $0.disablesAnimations = true }
      view = NSHostingView(rootView: root)
      window = KeyableTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      // Clicks reach SwiftUI controls only in a window that can take them.
      window.orderFrontRegardless()
      window.makeKey()
      view.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      test.addTeardownBlock { @MainActor [window] in
        window.orderOut(nil)
        window.contentView = nil
      }
    }

    func returnKey() throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    /// Return through the window's key-equivalent path, where default buttons answer.
    func pressReturnAsShortcut() throws { _ = window.performKeyEquivalent(with: try returnKey()) }

    /// Return as AppKit delivers it: key equivalents first, then the first responder.
    func typeReturn() throws { window.sendEvent(try returnKey()) }

    /// The visible marker named `name`, from `.enigmaTestMarker`.
    func marker(_ name: String) -> NSView? {
      func search(_ node: NSView) -> NSView? {
        if node is TestControlMarker.Marker, node.identifier?.rawValue == name, !node.isHiddenOrHasHiddenAncestor,
           node.visibleRect.width > 1, node.visibleRect.height > 1 { return node }
        return node.subviews.lazy.compactMap(search).first
      }
      return search(view)
    }

    func shows(_ name: String) -> Bool { marker(name) != nil }

    /// Clicks the real control behind a marker with a mouse down and up.
    func press(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
      let target = try XCTUnwrap(marker(name), "No control \(name)", file: file, line: line)
      let location = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
      for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1), file: file, line: line)
        window.sendEvent(event)
      }
    }

    var keyField: NSSecureTextField? {
      func search(_ view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap(search).first
      }
      return search(view)
    }
  }

  @MainActor
  func testReturnInTheKeyFieldSavesTheKeyAndStaysOnConnections() async throws {
    let credentials = RecordingSearchCredentials()
    let fixture = try await Fixture(test: self, searchCredentials: credentials)
    fixture.setup.replay()
    fixture.setup.step = .connections
    let host = Host(fixture, test: self)
    try await waitForUI("the key field", in: host.view) { host.keyField != nil }
    let field = try XCTUnwrap(host.keyField)
    XCTAssertTrue(host.window.makeFirstResponder(field))
    try await waitForUI("the field's editor", in: host.view) { field.currentEditor() != nil }
    field.currentEditor()?.insertText("  brave-test-key ")
    try await waitForUI("the character to listen", in: host.view) { host.character.state == .listening }
    try host.typeReturn()
    try await waitForUI("Return to save the key", in: host.view) { credentials.saved == ["brave-test-key"] }
    XCTAssertEqual(fixture.setup.step, .connections, "Return in the field must not press Continue")
    try await waitForUI("the field to clear and the saved status", in: host.view) {
      field.stringValue.isEmpty && host.shows("key saved · not tested here")
    }
    XCTAssertTrue(fixture.search.hasAPIKey)
  }

  @MainActor
  func testFailedKeySaveShowsTheErrorAndTheCharactersErrorState() async throws {
    let fixture = try await Fixture(test: self, searchCredentials: FailingSearchCredentials())
    fixture.setup.replay()
    fixture.setup.step = .connections
    let host = Host(fixture, test: self)
    try await waitForUI("the key field", in: host.view) { host.keyField != nil }
    let field = try XCTUnwrap(host.keyField)
    XCTAssertTrue(host.window.makeFirstResponder(field))
    try await waitForUI("the field's editor", in: host.view) { field.currentEditor() != nil }
    field.currentEditor()?.insertText("brave-test-key")
    try await waitForUI("the Save button", in: host.view) { host.shows("Save key") }
    try host.press("Save key")
    let message = FailingSearchCredentials.Failure().localizedDescription
    try await waitForUI("the error line", in: host.view) { host.shows(message) }
    try await waitForUI("the character's error state", in: host.view) { host.character.state == .error }
    XCTAssertFalse(fixture.search.hasAPIKey)
    XCTAssertEqual(field.stringValue, "brave-test-key", "A failed save keeps what was typed")
    XCTAssertTrue(host.shows("not connected"))
  }

  @MainActor
  func testSkippingLocalModelsTurnsThePrimaryButtonIntoContinue() async throws {
    let engine = RecordingModelEngine()
    let fixture = try await Fixture(test: self, engine: engine)
    fixture.setup.replay()
    fixture.setup.step = .models
    let host = Host(fixture, test: self)
    try await waitForUI("the install button", in: host.view) { host.shows("Install model") }
    try host.press("Skip local models")
    try await waitForUI("Continue after skipping", in: host.view) { host.shows("Continue") }
    XCTAssertFalse(host.shows("Install model"))
    try host.press("Continue")
    try await waitForUI("the connections step", in: host.view) { fixture.setup.step == .connections }
    let downloads = await engine.downloads
    XCTAssertTrue(downloads.isEmpty)
  }

  @MainActor
  func testReturnNeverStartsADownloadButInstallDoes() async throws {
    let engine = RecordingModelEngine()
    let fixture = try await Fixture(test: self, engine: engine)
    fixture.setup.replay()
    fixture.setup.step = .models
    let host = Host(fixture, test: self)
    let recommended = try XCTUnwrap(WelcomeSetup.choices(
      fixture.advisor.recommendations(installedModels: [])).first)
    try await waitForUI("the install button", in: host.view) { host.shows("Install model") }
    try host.pressReturnAsShortcut()
    try host.typeReturn()
    try await Task.sleep(for: .milliseconds(300))
    var downloads = await engine.downloads
    XCTAssertTrue(downloads.isEmpty, "Return must never start a download")
    XCTAssertEqual(fixture.setup.step, .models)
    try host.press("Install model")
    try await waitForUI("Install to reach the engine", in: host.view) {
      fixture.chat.state != .idle
    }
    for _ in 0..<100 where downloads.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      downloads = await engine.downloads
    }
    XCTAssertEqual(downloads, [recommended.id])
  }

  @MainActor
  func testUseReachesSelectModelAndReturnPressesIt() async throws {
    let recommendations = LocalModelSelector.select(manifest: .bundled, hardware: hardware(memory: 32))
    let recommended = try XCTUnwrap(WelcomeSetup.choices(recommendations).first)
    let engine = RecordingModelEngine(installed: [installedModel(for: recommended)])
    let fixture = try await Fixture(test: self, engine: engine)
    await fixture.chat.refreshInstalledModel()
    fixture.setup.replay()
    fixture.setup.step = .models
    let host = Host(fixture, test: self)
    try await waitForUI("the Use button", in: host.view) { host.shows("Use this model") }
    // Use keeps Return, since it downloads nothing.
    try host.pressReturnAsShortcut()
    var selections: [String] = []
    for _ in 0..<100 where selections.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
      selections = await engine.selections
    }
    XCTAssertEqual(selections, [recommended.id])
    let downloads = await engine.downloads
    XCTAssertTrue(downloads.isEmpty, "Using a downloaded model downloads nothing")
  }
}

extension EnigmaWelcomeTests {
  @MainActor
  func testReturnInTheNewModelSheetNeverStartsADownload() async throws {
    let engine = RecordingModelEngine()
    let fixture = try await Fixture(test: self, engine: engine)
    let view = NSHostingView(rootView: EnigmaLocalModelOnboardingView(advisor: fixture.advisor, chat: fixture.chat)
      .enigmaTheme(.paper))
    let window = KeyableTestWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    window.makeKey()
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    _ = window.performKeyEquivalent(with: event)
    window.sendEvent(event)
    try await Task.sleep(for: .milliseconds(300))
    let downloads = await engine.downloads
    XCTAssertTrue(downloads.isEmpty, "Return in the model sheet must not download")
    XCTAssertEqual(fixture.chat.state, .idle)
  }
}

/// Records downloads and selections. Downloads then fail, so nothing installs.
private actor RecordingModelEngine: LocalModelEngine {
  private(set) var downloads: [String] = []
  private(set) var selections: [String] = []
  private let installed: [LocalModel]

  init(installed: [LocalModel] = []) { self.installed = installed }
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { installed }
  func selectModel(id: String) async throws { selections.append(id) }
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    downloads.append(model.id)
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private final class RecordingSearchCredentials: WebSearchCredentialStore, @unchecked Sendable {
  private(set) var saved: [String] = []
  func apiKey() throws -> String? { saved.last }
  func setAPIKey(_ value: String) throws { saved.append(value) }
  func removeAPIKey() throws { saved.removeAll() }
}

private struct FailingSearchCredentials: WebSearchCredentialStore {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The keychain refused the Brave key." }
  }
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws { throw Failure() }
  func removeAPIKey() throws {}
}

/// A borderless window that can become key, as the panel can.
private final class KeyableTestWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}
