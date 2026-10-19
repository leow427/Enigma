import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Enigma

/// The main window: its shared logic, how it starts after an upgrade, its
/// controls clicked for real in a key window, its fit at the panel's sizes,
/// the tour's anchors, the character, and its screenshots.
final class EnigmaMainWindowTests: XCTestCase {

  // MARK: Greeting

  func testGreetingFollowsTheTimeOfDay() {
    XCTAssertEqual(MainPageGreeting.text(hour: 0), "Morning. What are we poking at?")
    XCTAssertEqual(MainPageGreeting.text(hour: 11), "Morning. What are we poking at?")
    XCTAssertEqual(MainPageGreeting.text(hour: 12), "Afternoon. What are we poking at?")
    XCTAssertEqual(MainPageGreeting.text(hour: 17), "Afternoon. What are we poking at?")
    XCTAssertEqual(MainPageGreeting.text(hour: 18), "Evening. What are we poking at?")
    XCTAssertEqual(MainPageGreeting.text(hour: 23), "Evening. What are we poking at?")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let date = try! XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20)))
    XCTAssertEqual(MainPageGreeting.text(at: date, calendar: calendar), "Evening. What are we poking at?")
  }

  // MARK: Route status

  func testLocalStatusCoversEveryLocalState() {
    func status(_ state: LocalChatViewModel.State, model: String? = "Qwen3 8B") -> ChatRouteStatus {
      ChatRouteStatus.make(.init(mode: .local, state: state, localModelName: model))
    }
    XCTAssertEqual(status(.idle), ChatRouteStatus(kind: .ready, text: "Qwen3 8B is ready · on this Mac"))
    XCTAssertEqual(status(.idle, model: nil),
                   ChatRouteStatus(kind: .missing, text: "A local GGUF model is required.", action: .chooseModel))
    XCTAssertEqual(status(.benchmarking).text, "Checking model performance…")
    XCTAssertEqual(status(.installing).text, "Installing local model…")
    XCTAssertEqual(status(.deleting).text, "Deleting local model…")
    XCTAssertEqual(status(.downloading(ModelDownloadProgress(receivedByteCount: 42, expectedByteCount: 100))).text, "Downloading 42%")
    for state in [LocalChatViewModel.State.preparing, .refiningSearch, .searching] {
      XCTAssertEqual(status(state), ChatRouteStatus(kind: .busy, text: "Loading local model…"))
    }
    XCTAssertEqual(status(.streaming), ChatRouteStatus(kind: .busy, text: "Generating locally"))
    XCTAssertEqual(status(.failed("The model stopped.")), ChatRouteStatus(kind: .problem, text: "The model stopped."))
  }

  func testCloudStatusNamesWhatIsMissingAndOffersSettings() {
    var context = ChatRouteStatus.Context(mode: .cloud, cloudProvider: .chatGPT)
    XCTAssertEqual(ChatRouteStatus.make(context), ChatRouteStatus(kind: .missing,
      text: "Sign in with ChatGPT to use your Codex allowance.", action: .openSettings))
    context.cloudProvider = .claudeCode
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Sign in to Claude Code to use your Claude plan.")
    context.cloudProvider = .anthropic
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Add a \(CloudProviderID.anthropic.displayName) API key.")
    context.hasCloudAccess = true
    context.cloudCompatibility = .unsupported
    XCTAssertEqual(ChatRouteStatus.make(context), ChatRouteStatus(kind: .problem,
      text: CloudModelCompatibility.unsupported.message, action: .openSettings))
    context.isCloudConfigured = true
    context.cloudCompatibility = .unverified
    context.cloudModelID = "claude-x"
    XCTAssertEqual(ChatRouteStatus.make(context), ChatRouteStatus(kind: .ready,
      text: "\(CloudProviderID.anthropic.displayName) · claude-x · unverified · in the cloud"))
    context.state = .preparing
    XCTAssertEqual(ChatRouteStatus.make(context).kind, .busy)
    context.state = .streaming
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Streaming from \(CloudProviderID.anthropic.displayName)")
    context.state = .installing
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Finish the local model task before using Cloud mode.")
    context.state = .failed("Rate limited.")
    XCTAssertEqual(ChatRouteStatus.make(context).kind, .problem)
  }

  func testAutoStatusAndRunningRequests() {
    var context = ChatRouteStatus.Context(mode: .auto)
    XCTAssertEqual(ChatRouteStatus.make(context).kind, .missing)
    context.localModelName = "Qwen3 8B"
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Cloud isn’t connected; Auto stays local · Qwen3 8B")
    context.hasAutoCloud = true
    XCTAssertEqual(ChatRouteStatus.make(context).text, "Auto chooses the lowest-latency capable model.")
    context.autoDecision = AutoRouter.Decision(
      route: Route(mode: .local, providerID: "local", modelID: "qwen", usesNetwork: false),
      modelDisplayName: "Qwen3 8B", reason: .cloudUnavailable, limitation: nil)
    XCTAssertEqual(ChatRouteStatus.make(context), ChatRouteStatus(kind: .ready, text: "Auto · Local · Qwen3 8B"))
    context.autoDecision = AutoRouter.localFallback(localModel: nil)
    XCTAssertEqual(ChatRouteStatus.make(context).kind, .problem)
    context.request = .init(phase: "Preparing…", name: "Local · Qwen3 8B")
    XCTAssertEqual(ChatRouteStatus.make(context), ChatRouteStatus(kind: .busy, text: "Preparing… · Local · Qwen3 8B"),
                   "A running request is described first, as before")
  }

  func testRouteIndicatorShowsWhereTheNextRequestRuns() {
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .local, requestMode: nil, autoDecisionMode: nil,
                                               hasLocalModel: false, hasAutoCloud: false), .local)
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .cloud, requestMode: nil, autoDecisionMode: nil,
                                               hasLocalModel: true, hasAutoCloud: false), .cloud)
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .auto, requestMode: nil, autoDecisionMode: nil,
                                               hasLocalModel: true, hasAutoCloud: true), .local)
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .auto, requestMode: nil, autoDecisionMode: nil,
                                               hasLocalModel: false, hasAutoCloud: true), .cloud)
    XCTAssertNil(ComposerRouteIndicator.make(mode: .auto, requestMode: nil, autoDecisionMode: nil,
                                             hasLocalModel: false, hasAutoCloud: false))
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .auto, requestMode: nil, autoDecisionMode: .cloud,
                                               hasLocalModel: true, hasAutoCloud: true), .cloud)
    XCTAssertEqual(ComposerRouteIndicator.make(mode: .local, requestMode: .cloud, autoDecisionMode: nil,
                                               hasLocalModel: true, hasAutoCloud: false), .cloud,
                   "The request in flight keeps its route")
    XCTAssertEqual(ComposerRouteIndicator.local.text, "● local")
    XCTAssertEqual(ComposerRouteIndicator.cloud.text, "○ cloud")
  }

  // MARK: Character

  func testCharacterStateFollowsTheWindow() {
    typealias Inputs = MainWindowCharacter.Inputs
    XCTAssertEqual(MainWindowCharacter.state(Inputs()), .idle)
    XCTAssertEqual(MainWindowCharacter.state(Inputs(isTyping: true)), .listening)
    XCTAssertEqual(MainWindowCharacter.state(Inputs(routeCanRun: false, isTyping: true)), .error,
                   "A route that can't run shows the error state, even while typing")
    XCTAssertEqual(MainWindowCharacter.state(Inputs(hasProblem: true)), .error)
    XCTAssertEqual(MainWindowCharacter.state(Inputs(isWorking: true, routeCanRun: false)), .thinking,
                   "A model download thinks rather than complains")
    XCTAssertEqual(MainWindowCharacter.state(Inputs(isWorking: true, isStreaming: true)), .answering)
    XCTAssertEqual(MainWindowCharacter.mainSlotSize, 92)
  }

  // MARK: Mode and model menu

  @MainActor
  func testModeAndModelMenuListsModesThenTheModelsThatModeUses() {
    var calls: [String] = []
    let actions = ModeAndModelMenu.Actions(
      chooseMode: { calls.append("mode \($0.rawValue)") }, selectLocalModel: { calls.append("local \($0)") },
      selectCloudModel: { calls.append("cloud \($0)") }, findModel: { calls.append("find") },
      importModel: { calls.append("import") }, openSettings: { calls.append("settings") })
    var menu = ModeAndModelMenu(
      mode: .local, isBusy: false, hasActiveRequest: false,
      localModels: [.init(id: "q", name: "Qwen3 8B", supportsVision: false),
                    .init(id: "g", name: "Gemma 4", supportsVision: true)],
      selectedLocalID: "q", cloudProvider: .claudeCode,
      cloudModels: [.init(id: "sonnet", name: "Sonnet", supportsVision: true)], selectedCloudID: "sonnet")
    XCTAssertEqual(menu.label, "Qwen3 8B")
    var sections = menu.sections(actions)
    XCTAssertEqual(sections.map(\.title), ["Mode", "On this Mac", nil])
    XCTAssertEqual(sections[0].items.map(\.title), ["Auto", "Local", "Cloud"])
    XCTAssertEqual(sections[0].items.map(\.isSelected), [false, true, false])
    XCTAssertEqual(sections[1].items.map(\.detail), ["text only", "text + images"])
    XCTAssertEqual(sections[1].items.map(\.isSelected), [true, false])
    XCTAssertEqual(sections[2].items.map(\.title),
                   ["Find a model for this Mac…", "Import a text GGUF…", "Manage models in Settings…"])
    sections[0].items[2].action()
    sections[1].items[1].action()
    sections[2].items.forEach { $0.action() }
    XCTAssertEqual(calls, ["mode cloud", "local g", "find", "import", "settings"])

    menu.mode = .cloud
    XCTAssertEqual(menu.label, "sonnet")
    sections = menu.sections(actions)
    XCTAssertEqual(sections.map(\.title), ["Mode", CloudProviderID.claudeCode.displayName, nil])
    XCTAssertEqual(sections[2].items.map(\.title), ["Advanced settings…"])
    calls = []
    sections[1].items[0].action()
    XCTAssertEqual(calls, ["cloud sonnet"])

    menu.mode = .auto
    menu.isBusy = true
    menu.hasActiveRequest = true
    XCTAssertEqual(menu.label, "Auto")
    sections = menu.sections(actions)
    XCTAssertEqual(sections.map(\.title), ["Next request", "On this Mac", CloudProviderID.claudeCode.displayName, nil])
    XCTAssertTrue(sections[0].items.allSatisfy(\.isEnabled), "The mode for the next request can change mid-reply")
    XCTAssertTrue(sections[1...].flatMap(\.items).allSatisfy { !$0.isEnabled }, "Models wait for the reply, as before")

    menu = ModeAndModelMenu(mode: .auto, isBusy: false, hasActiveRequest: false, localModels: [], selectedLocalID: nil,
                            cloudProvider: .chatGPT, cloudModels: [], selectedCloudID: "")
    sections = menu.sections(actions)
    XCTAssertEqual(sections[1].items.map(\.title), ["No installed models"])
    XCTAssertEqual(sections[2].items.map(\.title), ["No discovered models"])
    XCTAssertFalse(sections[1].items[0].isEnabled)
    menu.mode = .local
    XCTAssertEqual(menu.label, "Choose model")
    menu.mode = .cloud
    XCTAssertEqual(menu.label, "Choose cloud model")
  }

  // MARK: Examples and layout

  func testCommandExamplesFollowTheAvailableCommands() {
    let withSearch = SlashCommandExample.examples(available: SlashCommand.available(hasSearchKey: true))
    XCTAssertEqual(withSearch.map(\.command), [.screen, .search, .edit, .translate])
    let withoutSearch = SlashCommandExample.examples(available: SlashCommand.available(hasSearchKey: false))
    XCTAssertEqual(withoutSearch.map(\.command), [.screen, .edit, .translate, .think])
    XCTAssertEqual(SlashCommandExample.examples(available: SlashCommand.allCases, limit: 10).count,
                   SlashCommand.allCases.count, "Every command has an example line")
    XCTAssertEqual(SlashCommandExample.example(for: .translate).argument, "\"Bạn khỏe không?\"")
  }

  func testMainPageDropsExamplesThenTheCharacterAsTheWindowShrinks() {
    let tall = MainPageLayout(height: 780, topBar: 0, info: 96, composer: 86, accessories: 0, availableExamples: 4)
    XCTAssertEqual(tall.header, .full)
    XCTAssertEqual(tall.exampleCount, 4)
    let minimum = MainPageLayout(height: 420, topBar: 0, info: 96, composer: 86, accessories: 0, availableExamples: 4)
    XCTAssertEqual(minimum.header, .full, "The character still fits the minimum window")
    XCTAssertGreaterThanOrEqual(minimum.exampleCount, 1)
    let hiddenSidebar = MainPageLayout(height: 420, topBar: EnigmaHiddenSidebarBar.height, info: 96, composer: 86,
                                       accessories: 0, availableExamples: 4)
    XCTAssertLessThanOrEqual(hiddenSidebar.exampleCount, minimum.exampleCount)
    let crowded = MainPageLayout(height: 420, topBar: 44, info: 96, composer: 86, accessories: 150,
                                 availableExamples: 4)
    XCTAssertEqual(crowded.header, .hidden)
    XCTAssertEqual(crowded.exampleCount, 0)
    let tiny = MainPageLayout(height: 200, topBar: 44, info: 96, composer: 86, accessories: 300, availableExamples: 4)
    XCTAssertEqual(tiny.accessoriesLimit, 6, "Accessories scroll before they push the composer out")
    for height in stride(from: 300.0, through: 900, by: 10) {
      for accessories in [0.0, 40, 160] {
        let layout = MainPageLayout(height: height, topBar: 44, info: 96, composer: 86, accessories: accessories,
                                    availableExamples: 4)
        let examples = layout.exampleCount > 0
          ? MainPageLayout.examplesTopPadding + CGFloat(layout.exampleCount) * MainPageLayout.exampleLineHeight : 0
        let used = 44 + MainPageLayout.headerHeight(layout.header, info: 96) + min(accessories, layout.accessoriesLimit)
          + MainPageLayout.accessoriesSpacing + 86 + examples
        XCTAssertLessThanOrEqual(used, height - MainPageLayout.bottomPadding + 0.5,
                                 "Everything fits at \(height) with \(accessories) of accessories")
        if layout.header != .full { XCTAssertEqual(layout.exampleCount, 0, "Examples go before the character") }
      }
    }
  }

  func testSidebarWidthStaysReadableFromTheMinimumToTheDefaultWindow() {
    XCTAssertEqual(MainPageLayout.sidebarWidth(for: 640), 190)
    XCTAssertEqual(MainPageLayout.sidebarWidth(for: 1200), 240)
    XCTAssertEqual(MainPageLayout.sidebarWidth(for: 1100), 220)
  }

  func testHelpWritesModifierShortcutsTogether() {
    typealias Shortcut = KeyboardShortcutsHelp.Shortcut
    XCTAssertEqual(Shortcut("", "⌘ N").compactKeys, "⌘N")
    XCTAssertEqual(Shortcut("", "⌥ ⌃").compactKeys, "⌥⌃")
    XCTAssertEqual(Shortcut("", "⇧ ⌘ Z").compactKeys, "⇧⌘Z")
    XCTAssertEqual(Shortcut("", "⇧ ⌥ Space").compactKeys, "⇧⌥ Space")
    XCTAssertEqual(Shortcut("", "⌃ Tab").compactKeys, "⌃ Tab")
    XCTAssertEqual(Shortcut("", "⌃ twice").compactKeys, "⌃ twice")
    XCTAssertEqual(Shortcut("", "Tab / Return").compactKeys, "Tab / Return")
    XCTAssertEqual(Shortcut("", "⌘ .").compactKeys, "⌘.")
    XCTAssertEqual(KeyboardShortcutsHelp.selectionChat(modifier: .command).keys, "⌘ twice")
    XCTAssertTrue(KeyboardShortcutsHelp.panel.contains(Shortcut("Open or close Mode & Model", "⌘ K")))
    XCTAssertTrue(KeyboardShortcutsHelp.commandsNote().contains("remain highlighted"))
  }

  /// Help and Settings name the selection chat and web search as the
  /// Settings pages do ("Selection", "Web search · Brave"), not by old names.
  func testHelpAndSettingsUseTheCurrentPageNames() {
    let texts = [KeyboardShortcutsHelp.selectionBackup.title, KeyboardShortcutsHelp.selectionNote,
                 KeyboardShortcutsHelp.searchNote, GeneralSettingsPage.newChatsNote]
    for text in texts {
      XCTAssertFalse(text.contains("Selection Context"), text)
      XCTAssertFalse(text.contains("Web Search settings"), text)
    }
    XCTAssertEqual(KeyboardShortcutsHelp.selectionBackup.title, "Selection chat backup")
    XCTAssertTrue(KeyboardShortcutsHelp.selectionNote.contains("web search settings"))
    XCTAssertTrue(GeneralSettingsPage.newChatsNote.contains("selection chat"))
  }

  // MARK: Upgrading

  /// Settings an earlier version may have saved: "Use new UI" off, on, or
  /// unreadable, and the liquid-glass appearance. None of them is read any
  /// more, so whatever is saved, the app starts in the one UI, follows the
  /// appearance setting, and leaves the old values alone.
  static var staleSettings: [[String: Any]] { [
    [:],
    ["enigma.newUI.isEnabled": false, "aiSpotlight.glassAppearance.isEnabled": true,
     "aiSpotlight.glassAppearance.clarity": 0.42, "aiSpotlight.glassAppearance.opacity": 0.78],
    ["enigma.newUI.isEnabled": true, "aiSpotlight.glassAppearance.isEnabled": false],
    ["enigma.newUI.isEnabled": "yes", "aiSpotlight.glassAppearance.clarity": "clear"],
  ] }

  @MainActor
  func testAnExistingInstallStartsInTheUIWhateverOldSettingsAreSaved() async throws {
    for stale in Self.staleSettings {
      let label = stale.isEmpty ? "no old settings" : "old settings \(stale)"
      let fixture = try await Fixture(test: self)
      for (key, value) in stale { fixture.defaults.set(value, forKey: key) }
      let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
      func dark() -> Bool { host.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
      try await waitForUI("the window in Paper with \(label)", in: host.view) {
        host.shows("New chat") && (try? host.pixel(at: CGPoint(x: 12, y: 500))).map {
          EnigmaSnapshot.matches($0, EnigmaPalette.paper.sidebar) } == true && !dark()
      }
      try assertPixel(try host.capture(), at: CGPoint(x: 600, y: 600), is: EnigmaPalette.paper.background, label)
      XCTAssertNotNil(composerEditor(in: host.view), "The real message field: \(label)")
      XCTAssertFalse(fixture.setup.isPresented, "An existing install skips the welcome: \(label)")

      fixture.appearance.appearance = .ink
      try await waitForUI("the window in Ink with \(label)", in: host.view) {
        (try? host.pixel(at: CGPoint(x: 12, y: 500))).map { EnigmaSnapshot.matches($0, EnigmaPalette.ink.sidebar) } == true
          && dark()
      }
      fixture.appearance.appearance = .system
      let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
      try await waitForUI("the window following the Mac with \(label)", in: host.view) {
        host.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system
      }
      for (key, value) in stale {
        XCTAssertEqual(fixture.defaults.object(forKey: key) as? NSObject, value as? NSObject,
                       "Old values are left alone: \(key)")
      }
    }
  }

  @MainActor
  func testAFreshInstallStartsWithTheWelcomeWhateverOldSettingsAreSaved() async throws {
    for stale in Self.staleSettings {
      let label = stale.isEmpty ? "no old settings" : "old settings \(stale)"
      let fixture = try await Fixture(test: self, model: nil)
      // A first launch: setup hasn't run and no model is installed.
      fixture.defaults.removeObject(forKey: WelcomeSetup.completedKey)
      fixture.defaults.removeObject(forKey: "localModelOnboardingDismissed")
      for (key, value) in stale { fixture.defaults.set(value, forKey: key) }
      let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
      // The welcome covers the sidebar, so its left margin is the canvas.
      try await waitForUI("the welcome in Paper with \(label)", in: host.view) {
        fixture.setup.isPresented && (try? host.pixel(at: CGPoint(x: 12, y: 500))).map {
          EnigmaSnapshot.matches($0, EnigmaPalette.paper.background) } == true
      }
      XCTAssertEqual(composerEditor(in: host.view)?.isEditable, false, "The chat waits under the welcome: \(label)")
      fixture.setup.finish(takeTour: false)
      try await waitForUI("the window after the welcome with \(label)", in: host.view) {
        host.shows("New chat") && composerEditor(in: host.view)?.isEditable == true
      }
    }
  }

  @MainActor
  func testFrameFitsTheMinimumAndDefaultPanelWithAndWithoutTheSidebar() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Earlier chat")])
    let host = Host(fixture, size: CGSize(width: 1200, height: 780), test: self)
    let start = fixture.chat.selectedSessionID
    for size in [CGSize(width: 640, height: 420), CGSize(width: 1200, height: 780)] {
      for sidebar in [true, false] {
        for docked in [false, true] {
          let label = "\(Int(size.width))×\(Int(size.height)), sidebar \(sidebar), docked \(docked)"
          host.window.setContentSize(size)
          if docked { fixture.chat.selectSession(id: fixture.earlierSessionID!) } else if let start {
            fixture.chat.selectSession(id: start)
          }
          if host.shows("Hide chat history") != sidebar {
            try await clickTestControl(sidebar ? "Show chat history" : "Hide chat history", in: host.view)
          }
          try await waitForUI("layout at \(label)", in: host.view) {
            host.shows("Send message") && host.shows(sidebar ? "Hide chat history" : "Show chat history")
              && host.shows("Routing mode: Auto") != docked
          }
          let names = ["Send message", "Attach files", "Commands", "Mode and model"] + (sidebar
            ? ["New chat", "Help", "Settings", "Developer Tools"] : ["Show chat history", "Bar help", "Bar settings"])
          // The composer docks and the sidebar slides on springs, which a slow
          // machine is still drawing here: measure where they come to rest.
          try await waitForSettledLayout(in: host, label, markers: names)
          let bounds = host.view.bounds
          let editor = try XCTUnwrap(composerEditor(in: host.view))
          let field = host.view.convert(editor.bounds, from: editor)
          XCTAssertTrue(bounds.contains(field), "The message field is inside the window at \(label): \(field)")
          for name in names {
            let marker = try XCTUnwrap(host.marker(name), "\(name) at \(label)")
            let frame = host.view.convert(marker.bounds, from: marker)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) is inside the window at \(label): \(frame)")
          }
          if let example = host.marker("Example /screen") {
            let frame = host.view.convert(example.bounds, from: example)
            XCTAssertFalse(frame.intersects(field), "Examples sit below the composer at \(label)")
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY, label)
          }
        }
      }
    }
  }

  // MARK: Sidebar and Help

  @MainActor
  func testSidebarActionsWork() async throws {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Earlier chat")])
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let earlier = try XCTUnwrap(fixture.earlierSessionID)
    try await waitForUI("the sidebar's recent chat", in: host.view) { host.shows("Recent Earlier chat") }

    try await clickTestControl("Recent Earlier chat", in: host.view)
    try await waitForUI("the chosen chat", in: host.view) { fixture.chat.selectedSessionID == earlier }

    let newChat = expectation(forNotification: .newChatRequested, object: nil)
    try await clickTestControl("New chat", in: host.view)
    await fulfillment(of: [newChat], timeout: 3)
    try await waitForUI("a new chat", in: host.view) { fixture.chat.selectedSessionID != earlier }

    let settings = expectation(forNotification: .settingsRequested, object: nil)
    try await clickTestControl("Settings", in: host.view)
    await fulfillment(of: [settings], timeout: 3)

    try await clickTestControl("Hide chat history", in: host.view)
    try await waitForUI("the hidden sidebar", in: host.view) { !host.shows("New chat") && host.shows("Show chat history") }
    try await clickTestControl("Show chat history", in: host.view)
    try await waitForUI("the sidebar again", in: host.view) { host.shows("New chat") }
    try await clickTestControl("Hide chat history", in: host.view)
    let barNewChat = expectation(forNotification: .newChatRequested, object: nil)
    try await clickTestControl("Bar new chat", in: host.view)
    await fulfillment(of: [barNewChat], timeout: 3)
    try await waitForUI("a new chat restoring the start preference's sidebar, as before", in: host.view) {
      host.shows("New chat")
    }

    // Double-tap Control posts this through the panel.
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    try await waitForUI("double-tap Control hides the sidebar", in: host.view) { !host.shows("New chat") }
    NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
    try await waitForUI("double-tap Control shows the sidebar", in: host.view) { host.shows("New chat") }

    try await clickTestControl("Developer Tools", in: host.view)
    try await waitForUI("Developer Tools", in: host.view) { host.shows("Replay welcome setup") }
    try await clickTestControl("Replay welcome setup", in: host.view)
    try await waitForUI("the welcome replayed from Developer Tools", in: host.view) { fixture.setup.isPresented }
  }

  /// Under Reduce Motion, hiding and showing the sidebar puts the composer's
  /// message field and Send where they rest at once, on the main page and in
  /// a chat, instead of sliding the main column sideways. They still take clicks.
  @MainActor
  func testUnderReduceMotionTheSidebarToggleMovesTheComposerAtOnce() async throws {
    let size = CGSize(width: 1000, height: 660)
    for docked in [false, true] {
      let label = docked ? "in a chat" : "on the main page"
      let shown = try await restingComposerFrames(size: size, sidebar: true, docked: docked)
      let hidden = try await restingComposerFrames(size: size, sidebar: false, docked: docked)
      XCTAssertGreaterThan(abs(shown.send.minX - hidden.send.minX), 20, "The sidebar moves the composer \(label)")

      let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Earlier chat")])
      fixture.reduceMotion = true
      fixture.animates = true
      if docked { fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID)) }
      let host = Host(fixture, size: size, test: self)
      func frames() -> (send: CGRect, field: CGRect)? {
        guard let marker = host.marker("Send message"), let editor = composerEditor(in: host.view) else { return nil }
        return (host.view.convert(marker.bounds, from: marker), host.view.convert(editor.bounds, from: editor))
      }
      func isAt(_ place: (send: CGRect, field: CGRect), _ frames: (send: CGRect, field: CGRect)?) -> Bool {
        guard let frames else { return false }
        func matches(_ frame: CGRect, _ target: CGRect) -> Bool {
          abs(frame.minX - target.minX) < 1 && abs(frame.minY - target.minY) < 1
        }
        return matches(frames.send, place.send) && matches(frames.field, place.field)
      }
      // Every place the field and Send are seen while the sidebar changes.
      var seen: [(send: CGRect, field: CGRect)] = []
      func observe() {
        if let current = frames(), seen.last.map({ $0 != current }) ?? true { seen.append(current) }
      }
      func between() -> [String] {
        seen.filter { !isAt(shown, $0) && !isAt(hidden, $0) }.map { "\($0.send) \($0.field)" }
      }
      try await waitForUI("the composer at rest beside the sidebar \(label)", in: host.view) {
        isAt(shown, frames()) && composerAcceptsClicks(in: host.view)
      }

      // Double-tap Control posts this through the panel.
      NotificationCenter.default.post(name: .sidebarToggleRequested, object: nil)
      try await waitForUI("the composer at rest without the sidebar \(label) (seen \(seen))", in: host.view) {
        observe()
        return isAt(hidden, frames()) && host.shows("Show chat history") && composerAcceptsClicks(in: host.view)
      }
      XCTAssertEqual(between(), [], "Hiding the sidebar moves the composer at once \(label)")

      seen = []
      try await clickTestControl("Show chat history", in: host.view)
      try await waitForUI("the composer at rest beside the sidebar again \(label) (seen \(seen))", in: host.view) {
        observe()
        return isAt(shown, frames()) && host.shows("New chat") && composerAcceptsClicks(in: host.view)
      }
      XCTAssertEqual(between(), [], "Showing the sidebar moves the composer at once \(label)")

      // Send takes the click where it's drawn.
      let editor = try XCTUnwrap(composerEditor(in: host.view))
      editor.insertText("Explain actors", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
      try await waitForUI("the draft \(label)", in: host.view) { fixture.screen.draft == "Explain actors" }
      try await clickTestControl("Send message", in: host.view)
      try await waitForUI("the request \(label)", in: host.view) { fixture.chat.activeRequest != nil }
      host.window.orderOut(nil)
    }
  }

  /// Where the composer's Send button and message field rest under Reduce
  /// Motion in a window that opened with the sidebar shown or hidden, so the
  /// composer never moved there.
  @MainActor
  private func restingComposerFrames(size: CGSize, sidebar: Bool, docked: Bool) async throws -> (send: CGRect, field: CGRect) {
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Earlier chat")])
    fixture.reduceMotion = true
    fixture.start.showsSidebar = sidebar
    if docked { fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID)) }
    let host = Host(fixture, size: size, test: self)
    try await waitForUI("the composer with the sidebar \(sidebar ? "shown" : "hidden")", in: host.view) {
      host.shows(sidebar ? "New chat" : "Show chat history") && host.shows("Example /screen") != docked
        && composerAcceptsClicks(in: host.view)
    }
    try await waitForSettledLayout(in: host, "sidebar \(sidebar), docked \(docked)", markers: ["Send message"])
    let marker = try XCTUnwrap(host.marker("Send message"))
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    let frames = (send: host.view.convert(marker.bounds, from: marker), field: host.view.convert(editor.bounds, from: editor))
    host.window.orderOut(nil)
    return frames
  }

  @MainActor
  func testHelpOpensAndDoneClosesIt() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await clickTestControl("Help", in: host.view)
    try await waitForUI("the Help sheet", in: host.view) { host.window.attachedSheet?.contentView != nil }
    let sheet = try XCTUnwrap(host.window.attachedSheet)
    let sheetView = try XCTUnwrap(sheet.contentView)
    try await waitForUI("Help's Done button", in: sheetView) { Host.marker("Done", in: sheetView) != nil }
    sheet.makeKey()
    try await clickTestControl("Done", in: sheetView)
    try await waitForUI("Help to close", in: host.view) { host.window.attachedSheet == nil }

    try await clickTestControl("Hide chat history", in: host.view)
    try await clickTestControl("Bar help", in: host.view)
    try await waitForUI("Help from the hidden sidebar's bar", in: host.view) { host.window.attachedSheet != nil }
    host.window.attachedSheet.map { host.window.endSheet($0) }
  }

  // MARK: Composer

  @MainActor
  func testComposerControlsTypeCommandsAttachFilesAndChooseTheMode() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    let editor = try XCTUnwrap(composerEditor(in: host.view))

    try await clickTestControl("Commands", in: host.view)
    try await waitForUI("/ in the field with the command list", in: host.view) {
      editor.string == "/" && fixture.screen.draft == "/" && editor.completion?.commands.isEmpty == false
    }
    XCTAssertTrue(host.window.firstResponder === editor, "The / button gives the field focus")
    XCTAssertEqual(editor.completion?.commands, SlashCommand.available(hasSearchKey: false))
    XCTAssertEqual(editor.commandTextColor, EnigmaPalette.paper.accentText.nsColor, "Commands use accentText")
    editor.completion?.dismiss()

    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await clickTestControl("Example /screen", in: host.view)
    try await waitForUI("the example's command in the field", in: host.view) { fixture.screen.draft == "/screen " }

    editor.insertText("Summarize this", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    XCTAssertEqual(fixture.screen.draft, "Summarize this", "Typing reaches the composer binding")

    try await clickTestControl("Attach files", in: host.view)
    try await waitForUI("the file picker", in: host.view) { fixture.picker.count == 1 && fixture.files.selection != nil }
    XCTAssertEqual(fixture.screen.draft, "Summarize this", "Attaching keeps the draft")

    try await waitForUI("the local route", in: host.view) { host.shows("Route ● local") }
    try await clickTestControl("Mode and model", in: host.view)
    try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Cloud") && host.shows("Menu item Fixture 8B") }
    try await clickTestControl("Menu item Cloud", in: host.view)
    try await waitForUI("the cloud route after choosing Cloud", in: host.view) {
      host.shows("Route ○ cloud") && !host.shows("Menu item Cloud")
    }
    try await waitForUI("focus back in the field", in: host.view) { host.window.firstResponder === editor }
  }

  @MainActor
  func testCommandKOpensTheModePaletteAndFileShortcutStillWorks() async throws {
    let fixture = try await Fixture(test: self)
    let root = fixture.shell()
    let view = NSHostingView(rootView: root)
    let controller = SpotlightPanelController(sizeStore: PanelSizeStore(defaults: fixture.defaults), contentView: view, reduceMotion: { true })
    controller.show()
    addTeardownBlock { @MainActor in controller.hide(); view.window?.contentView = nil }
    let window = try XCTUnwrap(view.window)
    try await waitForUI("the composer", in: view) { composerEditor(in: view)?.isEditable == true }
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", keyCode: 40, modifiers: .command)))
    try await waitForUI("the mode palette from ⌘K", in: view) { Host.marker("Menu item Auto", in: view) != nil }
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", keyCode: 40, modifiers: .command)))
    try await waitForUI("⌘K again closes it", in: view) { Host.marker("Menu item Auto", in: view) == nil }
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", keyCode: 40, modifiers: .command)))
    try await waitForUI("the mode palette again", in: view) { Host.marker("Menu item Auto", in: view) != nil }
    try await clickTestControl("Menu item Auto", in: view)
    try await waitForUI("the palette closes after choosing", in: view) { Host.marker("Menu item Auto", in: view) == nil }

    XCTAssertTrue(window.performKeyEquivalent(with: try key("ƒ", keyCode: 3, modifiers: [.option, .shift])))
    try await waitForUI("⇧⌥F opens the picker", in: view) { fixture.picker.count == 1 }
  }

  @MainActor
  func testSendStartsARequestAndStopEndsIt() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    let editor = try XCTUnwrap(composerEditor(in: host.view))
    editor.insertText("Hello there", replacementRange: NSRange(location: 0, length: 0))
    try await waitForUI("Send enabled", in: host.view) { fixture.screen.draft == "Hello there" }
    try await clickTestControl("Send message", in: host.view)
    try await waitForUI("a running request with Stop", in: host.view) {
      fixture.engine.requestCount == 1 && fixture.chat.activeRequest != nil && host.shows("Stop response")
    }
    XCTAssertEqual(fixture.screen.draft, "", "An accepted draft clears, as before")
    try await waitForUI("the composer docked under the conversation after the first send", in: host.view) {
      !host.shows("Example /screen") && !host.shows("Routing mode: Auto")
    }
    try await clickTestControl("Stop response", in: host.view)
    try await waitForUI("the request to stop", in: host.view) {
      fixture.chat.activeRequest == nil && host.shows("Send message")
    }
  }

  @MainActor
  func testEditorTakesFocusWhenThePanelIsPresented() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await waitForUI("the composer", in: host.view) { composerEditor(in: host.view)?.isEditable == true }
    host.window.makeFirstResponder(nil)
    NotificationCenter.default.post(name: .panelPresented, object: nil)
    try await waitForUI("the field to take focus", in: host.view) {
      host.window.firstResponder === composerEditor(in: host.view) && composerAcceptsClicks(in: host.view)
    }
  }

  @MainActor
  func testSelectionPanelUsesTheCompactPanel() async throws {
    let fixture = try await Fixture(test: self)
    let view = NSHostingView(rootView: fixture.shell())
    let sizes = PanelSizeStore(defaults: fixture.defaults)
    sizes.save(NSSize(width: 900, height: 600))
    let controller = SpotlightPanelController(sizeStore: sizes, contentView: view, reduceMotion: { true })
    controller.show()
    addTeardownBlock { @MainActor in controller.hide(); view.window?.contentView = nil }
    let window = try XCTUnwrap(view.window)
    try await waitForUI("the window frame", in: view) { Host.marker("New chat", in: view) != nil }
    let visible = try XCTUnwrap(window.screen?.visibleFrame)
    controller.presentSelectionContext(ConversationContext(sourceName: "Test editor", text: "Please send the report today."),
      cursor: NSPoint(x: visible.midX, y: visible.minY + 120), selection: nil, visible: visible)
    try await waitForUI("the compact panel", in: view) {
      controller.isSelectionComposer && window.frame.height < 150 && fixture.chat.attachedContexts.count == 1
        && composerAcceptsClicks(in: view) && Host.marker("New chat", in: view) == nil
        && Host.marker("Compact panel", in: view) != nil && Host.marker("Mode and model", in: view) != nil
    }
    let editor = try XCTUnwrap(composerEditor(in: view))
    XCTAssertEqual(editor.commandTextColor, EnigmaPalette.paper.accentText.nsColor,
                   "The compact panel's field takes the palette's colors")
    fixture.screen.draft = "Explain this passage"
    try await waitForUI("the draft in the editor", in: view) { editor.string == fixture.screen.draft }
    editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
      windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
      isARepeat: false, keyCode: 36)))
    try await waitForUI("the panel growing into its answer", in: view) {
      !controller.isSelectionComposer && fixture.engine.requestCount == 1
        && Host.marker("Compact panel answer", in: view) != nil
        && (Host.marker("Send message", in: view) != nil || Host.marker("Stop response", in: view) != nil)
    }
    XCTAssertTrue(view.bounds.contains(view.convert(try XCTUnwrap(composerEditor(in: view)).bounds,
                                                     from: try XCTUnwrap(composerEditor(in: view)))))
  }

  // MARK: Tour

  @MainActor
  func testTourTargetsAreOnTheNewControls() async throws {
    let fixture = try await Fixture(test: self)
    let box = AnchorBox()
    let size = CGSize(width: 1000, height: 660)
    let root = fixture.shell().overlayPreferenceValue(WelcomeTourAnchors.self) { anchors in
      GeometryReader { proxy in AnchorProbe(box: box, rects: anchors.mapValues { proxy[$0] }) }
    }
    let host = Host(fixture, size: size, test: self, root: AnyView(root))
    fixture.setup.replay()
    fixture.setup.finish(takeTour: true)
    let targets = Set(WelcomeTourStep.allCases.map(\.target))
    for sidebar in [true, false] {
      if !sidebar {
        fixture.setup.endTour()
        try await clickTestControl("Hide chat history", in: host.view)
        fixture.setup.replay()
        fixture.setup.finish(takeTour: true)
      }
      try await waitForUI("every tour target with the sidebar \(sidebar ? "shown" : "hidden")", in: host.view) {
        Set(box.rects.keys).isSuperset(of: targets) && host.shows(sidebar ? "New chat" : "Show chat history")
      }
      let bounds = CGRect(origin: .zero, size: size)
      // The tour's scrim stays inside the rounded window.
      let image = try host.capture()
      for corner in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: size.width - 1, y: 0.5), CGPoint(x: 0.5, y: size.height - 1),
                     CGPoint(x: size.width - 1, y: size.height - 1)] {
        XCTAssertLessThan(try EnigmaSnapshot.pixel(image, at: corner).opacity, 0.05, "Corner \(corner) is transparent")
      }
      for target in targets {
        let rect = try XCTUnwrap(box.rects[target])
        XCTAssertFalse(rect.isEmpty, "\(target) has a size")
        XCTAssertTrue(bounds.contains(rect), "\(target) is inside the window: \(rect)")
      }
      let model = try XCTUnwrap(host.marker("Mode and model"))
      XCTAssertTrue(try XCTUnwrap(box.rects[.model]).insetBy(dx: -1, dy: -1)
        .contains(host.view.convert(model.bounds, from: model)), "The model stop is the mode and model menu")
      let attach = try XCTUnwrap(host.marker("Attach files"))
      XCTAssertTrue(try XCTUnwrap(box.rects[.files]).insetBy(dx: -1, dy: -1)
        .contains(host.view.convert(attach.bounds, from: attach)), "The files stop is Attach")
    }
  }

  // MARK: Character

  @MainActor
  func testCharacterFallsIntoTheMainPageAndListensErrsAndIdles() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let character = fixture.character
    try await waitForUI("the character on the main page", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.state == .idle
    }

    let editor = try XCTUnwrap(composerEditor(in: host.view))
    host.window.makeFirstResponder(editor)
    editor.insertText("What is", replacementRange: NSRange(location: 0, length: 0))
    try await waitForUI("the character listening", in: host.view) {
      character.state == .listening && character.attention == MainWindowCharacter.composerTarget
    }
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    try await waitForUI("the character idle again", in: host.view) { character.state == .idle && character.attention == nil }

    try await clickTestControl("Routing mode: Cloud", in: host.view)
    try await waitForUI("the error state when Cloud can't run", in: host.view) { character.state == .error }
    try await clickTestControl("Routing mode: Local", in: host.view)
    try await waitForUI("idle with a local model", in: host.view) { character.state == .idle }

    fixture.setup.replay()
    try await waitForUI("the character on the welcome", in: host.view) {
      character.activeSlot == WelcomeSetup.CharacterSlot.hero.id
    }
    fixture.setup.finish(takeTour: false)
    try await waitForUI("the character back on the main page", in: host.view) {
      character.activeSlot == MainWindowCharacter.mainSlot && character.state == .idle
        && composerEditor(in: host.view)?.isEditable == true
    }
  }

  @MainActor
  func testCharacterFallsFromTheWelcomeRatherThanJumping() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let character = fixture.character
    fixture.setup.replay()
    try await waitForUI("the character settled on the welcome", in: host.view, timeout: .seconds(8)) {
      character.activeSlot == WelcomeSetup.CharacterSlot.hero.id && character.isPresent
        && character.model.slot?.size == WelcomeSetup.CharacterSlot.hero.size && !character.model.isFalling
        && character.model.velocity.dx.magnitude + character.model.velocity.dy.magnitude < 1
    }
    let start = character.model.position
    fixture.setup.finish(takeTour: false)
    // Sampled until it sets off for the main page, however slowly the machine
    // draws frames: a jump would already be there.
    let samples = try await sampleCharacter(character, in: host, for: .seconds(3)) { sample in
      sample.slot?.size == MainWindowCharacter.mainSlotSize
        && hypot(sample.position.x - start.x, sample.position.y - start.y) > 0.5
    }
    XCTAssertTrue(samples.allSatisfy(\.present), "The character stays drawn as the welcome leaves")
    let target = try XCTUnwrap(samples.last?.slot, "The character heads for the main page's slot")
    XCTAssertEqual(target.size, MainWindowCharacter.mainSlotSize)
    let last = try XCTUnwrap(samples.last)
    XCTAssertGreaterThan(hypot(last.position.x - target.center.x, last.position.y - target.center.y), 4,
                         "As it sets off from the welcome it's still on its way, not at \(target.center)")
    XCTAssertGreaterThan(samples.filter { hypot($0.position.x - start.x, $0.position.y - start.y) > 0.5 }.count, 0,
                         "It moves from where it was drawn")
    try await waitForUI("the character landing on the main page", in: host.view, timeout: .seconds(5)) {
      guard let slot = character.model.slot else { return false }
      return !character.model.isFalling
        && hypot(character.model.position.x - slot.center.x, character.model.position.y - slot.center.y) < 2
    }
  }

  @MainActor
  func testCharacterGlidesFromTheWelcomeHeroIntoTheStepHeader() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    let character = fixture.character
    fixture.setup.replay()
    try await waitForUI("the character settled on the welcome", in: host.view, timeout: .seconds(8)) {
      character.model.slot?.size == WelcomeSetup.CharacterSlot.hero.size && character.isPresent
        && character.model.velocity.dx.magnitude + character.model.velocity.dy.magnitude < 1
    }
    let start = character.model.position
    fixture.setup.advance()
    // Sampled until it sets off for the header, however slowly the machine draws frames.
    let samples = try await sampleCharacter(character, in: host, for: .seconds(3)) { sample in
      sample.slot?.size == WelcomeSetup.CharacterSlot.header.size
        && hypot(sample.position.x - start.x, sample.position.y - start.y) > 0.5
    }
    XCTAssertTrue(samples.allSatisfy(\.present), "The character stays drawn through the step change")
    let target = try XCTUnwrap(samples.last?.slot)
    XCTAssertEqual(target.size, WelcomeSetup.CharacterSlot.header.size)
    let last = try XCTUnwrap(samples.last)
    XCTAssertGreaterThan(hypot(last.position.x - target.center.x, last.position.y - target.center.y), 4,
                         "It glides into the header instead of appearing there")
    XCTAssertGreaterThan(samples.filter { hypot($0.position.x - start.x, $0.position.y - start.y) > 0.5 }.count, 0,
                         "It moves from where it was drawn")
  }

  @MainActor
  func testHiddenCharacterIgnoresKeysAndPointerMoves() async throws {
    let character = EnigmaCharacterController(seed: 2)
    // A frame with no slots: nothing is drawn, and the timeline comes to rest.
    _ = character.frame(at: 1, slots: [:], targets: ["field": CGPoint(x: 10, y: 10)], reduceMotion: false)
    try await waitForUI("the hidden character's timeline to rest") { character.activity == .rest }
    var publishes = 0
    let token = character.$activity.dropFirst().sink { _ in publishes += 1 }
    defer { token.cancel() }
    for index in 0..<10 {
      character.key(towards: "field")
      character.pointerMoved(to: CGPoint(x: CGFloat(index) * 7, y: 40))
      character.attention = index.isMultiple(of: 2) ? "field" : nil
    }
    await Task.yield()
    XCTAssertEqual(character.activity, .rest)
    XCTAssertEqual(publishes, 0, "Keys, pointer moves, and attention don't redraw a character that isn't drawn")
  }

  @MainActor
  func testChoosingAGGUFFromTheMainPageOpensTheImporterAction() async throws {
    let fixture = try await Fixture(test: self, model: nil)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await clickTestControl("Routing mode: Local", in: host.view)
    try await waitForUI("the missing-model status and its action", in: host.view) {
      host.shows("A local GGUF model is required.") && host.shows("Choose a GGUF model…")
    }
    XCTAssertEqual(fixture.character.state, .error, "No local model: the route can't run")

    try await clickTestControl("Choose a GGUF model…", in: host.view)
    func importer() -> NSSavePanel? {
      (host.window.attachedSheet as? NSSavePanel)
        ?? NSApp.windows.lazy.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
    }
    try await waitForUI("the GGUF importer", in: host.view) { importer() != nil }
    let panel = try XCTUnwrap(importer())
    XCTAssertTrue(panel is NSOpenPanel, "Choosing a model opens the file importer")
    panel.cancel(nil)
    try await waitForUI("the importer to close", in: host.view) { importer() == nil }
    XCTAssertNil(fixture.chat.installedModel, "Cancelling installs nothing")
  }

  @MainActor
  func testEscapeClosesTheOpenMenuBeforeHidingThePanel() async throws {
    let fixture = try await Fixture(test: self)
    let view = NSHostingView(rootView: fixture.shell())
    let controller = SpotlightPanelController(sizeStore: PanelSizeStore(defaults: fixture.defaults), contentView: view, reduceMotion: { true })
    controller.show()
    addTeardownBlock { @MainActor in controller.hide(); view.window?.contentView = nil }
    let window = try XCTUnwrap(view.window)
    try await waitForUI("the composer", in: view) { composerEditor(in: view)?.isEditable == true }
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", keyCode: 40, modifiers: .command)))
    try await waitForUI("the mode palette", in: view) { Host.marker("Menu item Auto", in: view) != nil }
    XCTAssertTrue(window.performKeyEquivalent(with: try key("\u{1b}", keyCode: 53, modifiers: [])))
    try await waitForUI("Escape closes only the menu (menu open: \(Host.marker("Menu item Auto", in: view) != nil), "
                        + "panel visible: \(controller.isVisible), first responder: \(String(describing: window.firstResponder)), "
                        + "key window: \(window.isKeyWindow), app active: \(NSApp.isActive), "
                        + "app's key window: \(String(describing: NSApp.keyWindow)))",
                        in: view) {
      Host.marker("Menu item Auto", in: view) == nil && window.firstResponder === composerEditor(in: view)
    }
    XCTAssertTrue(controller.isVisible, "The panel stays open")
    XCTAssertTrue(window.performKeyEquivalent(with: try key("\u{1b}", keyCode: 53, modifiers: [])))
    XCTAssertFalse(controller.isVisible, "With nothing open, Escape hides the panel as before")

    controller.show()
    XCTAssertTrue(window.performKeyEquivalent(with: try key("k", keyCode: 40, modifiers: .command)))
    try await waitForUI("the mode palette again", in: view) { Host.marker("Menu item Auto", in: view) != nil }
    controller.hide()
    controller.show()
    try await waitForUI("no stale menu after hiding the panel", in: view) {
      Host.marker("Menu item Auto", in: view) == nil && Host.marker("Mode and model", in: view) != nil
    }
  }

  @MainActor
  func testComposerMenuOpensClearOfTheComposerBox() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 660), test: self)
    try await clickTestControl("Mode and model", in: host.view)
    try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Auto") }
    let send = try XCTUnwrap(host.marker("Send message"))
    let menu = try XCTUnwrap(host.marker("Menu Mode and model"))
    let sendFrame = host.view.convert(send.bounds, from: send)
    let menuFrame = host.view.convert(menu.bounds, from: menu)
    let gap = host.view.isFlipped ? menuFrame.minY - sendFrame.maxY : sendFrame.minY - menuFrame.maxY
    // Send sits 9 pt above the box's bottom edge, and the menu opens 8 pt below the box.
    XCTAssertEqual(gap, 9 + EnigmaComposer.menuGap, accuracy: 1.5,
                   "The menu opens clear of the composer: \(menuFrame) vs \(sendFrame)")
  }

  @MainActor
  func testMenuOpensWhereItsRowsFitAndOtherwiseShowsItsScroller() {
    let container = CGSize(width: 800, height: 660)
    let composer = CGRect(x: 600, y: 320, width: 120, height: 60)
    XCTAssertFalse(EnigmaMenuPlacement(anchor: composer, container: container).opensUpward,
                   "Unmeasured, the menu opens below while there's 220 pt of room")
    let tall = EnigmaMenuPlacement(anchor: composer, container: container, contentHeight: 300)
    XCTAssertTrue(tall.opensUpward, "Measured rows that don't fit below open upward when there's more room")
    XCTAssertGreaterThanOrEqual(tall.maximumHeight, 300)
    XCTAssertEqual(EnigmaMenuPlacement(anchor: composer, container: container, contentHeight: 120).opensUpward, false)
  }

  @MainActor
  func testMenuThatDoesNotFitShowsThereIsMoreAndReachesItsLastRow() async throws {
    let fixture = try await Fixture(test: self)
    let host = Host(fixture, size: CGSize(width: 1000, height: 560), test: self)
    try await clickTestControl("Routing mode: Auto", in: host.view)
    try await clickTestControl("Mode and model", in: host.view)
    try await waitForUI("the open menu", in: host.view) { host.shows("Menu item Auto") }
    try await waitForUI("a menu cut short saying there's more", in: host.view) { host.shows("Menu has more rows") }
    // The keyboard reaches the last row, scrolling it into view.
    try await waitForOpenMenuToTakeFocus(in: host.view)
    let window = host.window
    for _ in 0..<12 {
      for type: NSEvent.EventType in [.keyDown, .keyUp] {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
          characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)))
      }
    }
    try await waitForUI("the last row in view", in: host.view) {
      host.shows("Menu item Manage models in Settings…")
    }
    try await waitForUI("the more-rows strip gone at the end", in: host.view) { !host.shows("Menu has more rows") }
  }

  // MARK: Screenshots

  @MainActor
  func testScreenshots() async throws {
    let folder = try EnigmaSnapshot.directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fixture = try await Fixture(test: self, sessions: [Fixture.savedSession("Quantizing a GGUF"),
                                                           Fixture.savedSession("Actor isolation in tests")])
    let size = CGSize(width: 1000, height: 660)
    let host = Host(fixture, size: size, test: self)
    if let start = fixture.chat.sessions.first(where: { $0.messages.isEmpty })?.id { fixture.chat.selectSession(id: start) }
    // As when the panel opens: the message field takes focus.
    NotificationCenter.default.post(name: .panelPresented, object: nil)

    try await snapshot("main-page", host, fixture) { host.shows("Example /screen") }
    try await clickTestControl("Hide chat history", in: host.view)
    try await snapshot("main-page-no-sidebar", host, fixture) { host.shows("Show chat history") }
    try await clickTestControl("Show chat history", in: host.view)

    let editor = try XCTUnwrap(composerEditor(in: host.view))
    try await clickTestControl("Commands", in: host.view)
    try await snapshot("composer-commands", host, fixture) { editor.completion?.commands.isEmpty == false }
    editor.completion?.dismiss()
    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))

    try await clickTestControl("Mode and model", in: host.view)
    try await snapshot("model-menu", host, fixture) { host.shows("Menu item Fixture 8B") }
    host.window.makeFirstResponder(editor)
    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("menu closed", in: host.view) { !host.shows("Menu item Auto") }

    try await clickTestControl("Routing mode: Auto", in: host.view)
    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await snapshot("mode-palette", host, fixture) { host.shows("Menu item Auto") && host.shows("Menu item No discovered models") }
    NotificationCenter.default.post(name: .modePaletteRequested, object: nil)
    try await waitForUI("palette closed", in: host.view) { !host.shows("Menu item Auto") }

    fixture.chat.selectSession(id: try XCTUnwrap(fixture.earlierSessionID))
    try await snapshot("conversation-docked", host, fixture) { !host.shows("Example /screen") && host.shows("Send message") }
    fixture.chat.newChat()

    host.window.setContentSize(PanelSizeStore.minimumSize)
    try await snapshot("minimum-size", host, fixture) { host.shows("Send message") }

    try EnigmaSnapshot.save("help", size: KeyboardShortcutsHelpView.size) {
      KeyboardShortcutsHelpView(searchSettings: fixture.search)
    }
  }

  private struct CharacterSample {
    let present: Bool
    let position: CGPoint
    let slot: EnigmaCharacterModel.Slot?
  }

  /// The character's position over `duration`, or until a sample is `done`,
  /// drawing the window as it goes.
  @MainActor
  private func sampleCharacter(_ character: EnigmaCharacterController, in host: Host, for duration: Duration,
                               until done: (CharacterSample) -> Bool = { _ in false }) async throws -> [CharacterSample] {
    var samples: [CharacterSample] = []
    let end = ContinuousClock.now.advanced(by: duration)
    repeat {
      await Task.yield()
      host.view.layoutSubtreeIfNeeded()
      host.window.displayIfNeeded()
      let sample = CharacterSample(present: character.isPresent, position: character.model.position,
                                   slot: character.model.slot)
      samples.append(sample)
      if done(sample) { break }
      try await Task.sleep(for: .milliseconds(8))
    } while ContinuousClock.now < end
    return samples
  }

  /// Waits until the composer field and the `markers` have kept their frames
  /// for a moment, as once the window's transitions have finished.
  @MainActor
  private func waitForSettledLayout(in host: Host, _ label: String, markers: [String],
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
    var frames: [CGRect] = []
    var since = ContinuousClock.now
    try await waitForUI("the layout to settle at \(label): \(frames)", in: host.view, file: file, line: line) {
      let views = [composerEditor(in: host.view) as NSView?] + markers.map { host.marker($0) }
      let current = views.map { view in view.map { host.view.convert($0.bounds, from: $0) } ?? .null }
      if current != frames {
        frames = current
        since = .now
      }
      return since.duration(to: .now) >= .milliseconds(200)
    }
  }

  /// Saves the hosted window in Paper and Ink, switching the real appearance setting.
  @MainActor
  private func snapshot(_ name: String, _ host: Host, _ fixture: Fixture, until ready: () -> Bool) async throws {
    let folder = try EnigmaSnapshot.directory()
    for (appearance, palette) in [(EnigmaAppearance.paper, EnigmaPalette.paper), (.ink, .ink)] {
      fixture.appearance.appearance = appearance
      let probe = CGPoint(x: host.view.bounds.width - 6, y: host.view.bounds.height / 2)
      try await waitForUI("\(name) in \(appearance)", in: host.view) {
        ready() && (try? host.pixel(at: probe)).map { EnigmaSnapshot.matches($0, palette.background) } == true
      }
      // Let transitions (the dock, the header's fade) and the character settle.
      for _ in 0..<30 { try await Task.sleep(for: .milliseconds(30)); host.view.layoutSubtreeIfNeeded(); host.window.displayIfNeeded() }
      let image = try host.capture()
      let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      try png.write(to: folder.appending(path: "\(name)-\(appearance.rawValue).png"))
    }
    fixture.appearance.appearance = .paper
  }

  private func assertPixel(_ image: NSBitmapImageRep, at point: CGPoint, is expected: EnigmaColor, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
    let color = try EnigmaSnapshot.pixel(image, at: point)
    XCTAssertTrue(EnigmaSnapshot.matches(color, expected), "\(message): \(color) at \(point)", file: file, line: line)
  }
}

// MARK: Fixture

extension EnigmaMainWindowTests {
  /// The main window with offline models: a local model whose replies wait
  /// until stopped, no cloud account, no Brave key, a file picker that returns
  /// a folder, and Paper. Nothing reads the installed app's settings.
  @MainActor
  final class Fixture {
    let defaults: UserDefaults
    let root: URL
    let engine: MainWindowTestEngine
    let chat: LocalChatViewModel
    let files: FileModeCoordinator
    let picker: MainWindowTestPicker
    let screen = ScreenComposerCoordinator()
    let cloud: CloudSettingsModel
    let search: WebSearchSettings
    let advisor: LocalModelAdvisor
    let setup: WelcomeSetup
    let start: StartPreferences
    let appearance: EnigmaAppearancePreference
    let character = EnigmaCharacterController(seed: 6)
    /// The chat's /edit setting, isolated from the installed app's.
    let selectionEditing: SelectionEditingSettings
    /// Accessibility, allowed by default and never the Mac's real state. A
    /// test that needs it missing sets its own.
    var selectionAccess = SelectionAccessibilityAccess(checkTrust: { true }, prompt: {}, openSettings: { _ in })
    /// Reduce Motion, off by default and never the Mac's real setting, which
    /// GitHub's macOS runners turn on. A test that needs it on sets its own.
    var reduceMotion = false
    /// Animations, off by default so each change lands at once. A test that
    /// watches how something moves turns them on.
    var animates = false
    /// Text that Replace text would have pasted into another app.
    let pastes = MainWindowTestPastes()
    private(set) var earlierSessionID: UUID?

    static func savedSession(_ title: String) -> ChatSession {
      var session = ChatSession(title: title)
      session.append(ChatMessage(role: .user, content: "Tell me about \(title.lowercased())."))
      session.append(ChatMessage(role: .assistant, content: "Here is a short answer about \(title.lowercased())."))
      return session
    }

    init(test: XCTestCase, model: LocalModel? = LocalModel(id: "fixture", displayName: "Fixture 8B",
                                                           fileURL: URL(fileURLWithPath: "/tmp/enigma-main-fixture.gguf")),
         sessions: [ChatSession] = []) async throws {
      let name = "EnigmaMainWindowTests-\(UUID())"
      defaults = try XCTUnwrap(UserDefaults(suiteName: name))
      root = FileManager.default.temporaryDirectory.appending(path: name)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let folder = root.appending(path: "Project", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("Hello".utf8).write(to: folder.appending(path: "hello.txt"))
      defaults.set(true, forKey: WelcomeSetup.completedKey)
      defaults.set(true, forKey: "localModelOnboardingDismissed")
      defaults.set(ChatMode.local.rawValue, forKey: StartPreferences.modeKey)
      defaults.set(true, forKey: StartPreferences.sidebarKey)
      let store = ChatSessionStore(applicationSupportDirectory: root)
      if !sessions.isEmpty { try store.save(sessions) }
      earlierSessionID = sessions.first?.id
      engine = MainWindowTestEngine(model: model)
      picker = MainWindowTestPicker([folder])
      files = FileModeCoordinator(picker: picker, journalDirectory: root.appending(path: "Recovery"))
      selectionEditing = SelectionEditingSettings(defaults: defaults)
      let chat = LocalChatViewModel(engine: engine, selectionEditingSettings: selectionEditing,
        replaceSelection: { [pastes] text, _ in pastes.texts.append(text); return true },
        files: files, sessionStore: store)
      self.chat = chat
      await chat.refreshInstalledModel()
      // Saved chats load with the newest selected; start from a fresh, empty one.
      if !sessions.isEmpty { chat.newChat() }
      let credentials = ScreenTestCredentialStore()
      cloud = CloudSettingsModel(credentialStore: credentials,
        catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
        preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false },
        claudeCode: ClaudeCodeSubscriptionClient(runtime: ClaudeCodeRuntime(directory: root, executable: { nil })))
      search = WebSearchSettings(credentials: MainWindowTestSearchCredentials(), defaults: defaults)
      advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil)
      setup = WelcomeSetup(defaults: defaults)
      start = StartPreferences(defaults: defaults)
      appearance = EnigmaAppearancePreference(defaults: defaults)
      appearance.appearance = .paper
      let root = root
      test.addTeardownBlock { @MainActor in
        await chat.stopStreaming()?.value
        await chat.sessionWriter.waitForPendingWrites()
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
      }
    }

    func shell() -> some View {
      AppShellView(cloudSettings: cloud,
        localChat: chat, screen: screen, modelAdvisor: advisor, searchSettings: search, startPreferences: start,
        welcomeSetup: setup, appearance: appearance, character: character,
        selectionAccess: selectionAccess)
        .environment(\.enigmaTestMarker, { AnyView(TestControlMarker(name: $0).allowsHitTesting(false)) })
        .enigmaTestReduceMotion(reduceMotion)
        .transaction { [animates] in if !animates { $0.disablesAnimations = true } }
    }
  }

  /// The shell in a borderless window that can become key, so clicks reach
  /// its SwiftUI controls.
  @MainActor
  final class Host {
    let view: NSView
    let window: NSWindow

    init(_ fixture: Fixture, size: CGSize, test: XCTestCase, root: AnyView? = nil) {
      view = NSHostingView(rootView: root ?? AnyView(fixture.shell()))
      window = MainWindowKeyableWindow(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.colorSpace = .sRGB
      window.backgroundColor = .clear
      window.isOpaque = false
      window.contentView = view
      window.orderFrontRegardless()
      window.makeKey()
      view.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      test.addTeardownBlock { @MainActor [window] in
        window.attachedSheet.map { window.endSheet($0) }
        window.orderOut(nil)
        window.contentView = nil
      }
    }

    static func marker(_ name: String, in view: NSView) -> NSView? {
      if view is TestControlMarker.Marker, view.identifier?.rawValue == name, !view.isHiddenOrHasHiddenAncestor,
         view.visibleRect.width > 1, view.visibleRect.height > 1 { return view }
      return view.subviews.lazy.compactMap { marker(name, in: $0) }.first
    }

    func marker(_ name: String) -> NSView? { Self.marker(name, in: view) }
    func shows(_ name: String) -> Bool { marker(name) != nil }

    func capture() throws -> NSBitmapImageRep { try EnigmaSnapshot.capture(view) }
    func pixel(at point: CGPoint) throws -> EnigmaColor { try EnigmaSnapshot.pixel(try capture(), at: point) }
  }
}

/// Records the tour's anchors as rectangles in the window.
private final class AnchorBox {
  var rects: [WelcomeTourStep: CGRect] = [:]
}

private struct AnchorProbe: View {
  let box: AnchorBox
  let rects: [WelcomeTourStep: CGRect]

  var body: some View {
    box.rects = rects
    return Color.clear.allowsHitTesting(false)
  }
}

/// A panel like the app's own, which can take key focus in a background test run.
private final class MainWindowKeyableWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Records what the chat would paste over a selection, instead of pasting.
@MainActor
final class MainWindowTestPastes {
  var texts: [String] = []
}

final class MainWindowTestPicker: WorkspacePicking, @unchecked Sendable {
  var urls: [URL]?
  var count = 0
  init(_ urls: [URL]?) { self.urls = urls }
  func pick() async -> [URL]? { count += 1; return urls }
}

/// A local model whose replies wait until the request is stopped, unless a
/// test streams words into them with `send(_:)` and ends them with `finish`.
final class MainWindowTestEngine: LocalModelEngine, @unchecked Sendable {
  private let model: LocalModel?
  private let lock = NSLock()
  private var requests = 0
  private var latest: LocalModelRequest?
  private var replies: [AsyncThrowingStream<String, Error>.Continuation] = []

  init(model: LocalModel?) { self.model = model }

  var requestCount: Int { lock.withLock { requests } }
  /// The latest request's messages, as the model received them.
  var lastRequest: LocalModelRequest? { lock.withLock { latest } }

  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { model.map { [$0] } ?? [] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor,
                progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    lock.withLock { requests += 1; latest = request }
    return AsyncThrowingStream { continuation in self.lock.withLock { self.replies.append(continuation) } }
  }

  /// Streams `text` into the latest reply.
  func send(_ text: String) {
    _ = lock.withLock { replies.last }?.yield(text)
  }

  /// Ends the latest reply, or fails it with `error`.
  func finish(throwing error: Error? = nil) {
    lock.withLock { replies.last }?.finish(throwing: error)
  }
  func unload() async {}
}

private struct MainWindowTestSearchCredentials: WebSearchCredentialStore {
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws {}
  func removeAPIKey() throws {}
}
