import AppKit
import Combine
import SwiftUI

@MainActor
final class WelcomeSetup: ObservableObject {
  static let shared = WelcomeSetup()
  static let completedKey = "welcomeSetup.completed.v1"
  static let progressKey = "welcomeSetup.step.v1"
  enum Step: Int, CaseIterable { case welcome, models, connections, walkthrough }
  @Published private(set) var isPresented = false
  @Published var step: Step = .welcome {
    didSet { if isPresented { defaults.set(step.rawValue, forKey: Self.progressKey) } }
  }
  @Published private(set) var tour: WelcomeTourStep?
  private let defaults: UserDefaults
  private var started = false
  private var calibrated = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // F14 spike: a tour another test started doesn't carry into this one.
    if TestHost.isActive { GuidedTour.shared.end() }
  }

  func start(hasInstalledModels: Bool) {
    guard !started else { return }
    started = true
    guard !defaults.bool(forKey: Self.completedKey) else { return }
    // Existing users can opt in through Replay; interrupted new setup resumes.
    if defaults.object(forKey: Self.progressKey) == nil,
       hasInstalledModels || defaults.bool(forKey: "localModelOnboardingDismissed") {
      defaults.set(true, forKey: Self.completedKey)
      return
    }
    isPresented = true
    step = Step(rawValue: defaults.integer(forKey: Self.progressKey)) ?? .welcome
  }

  func replay() {
    calibrated = false
    isPresented = true
    tour = nil
    step = .welcome
  }

  func finish(takeTour: Bool) {
    defaults.set(true, forKey: Self.completedKey)
    defaults.removeObject(forKey: Self.progressKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    // F14 spike: the hands-on tour replaces the six-stop overlay. It starts
    // first, so the window goes straight from the welcome's size to the tour's.
    tour = nil
    if takeTour { GuidedTour.shared.begin() }
    isPresented = false
  }

  func nextTourStep() {
    guard let tour else { return }
    self.tour = WelcomeTourStep(rawValue: tour.rawValue + 1)
  }

  func endTour() { tour = nil }

  /// The first performance check in a setup run calibrates this Mac; installs
  /// after it skip the check. Only a check that actually ran counts.
  var needsPerformanceCheck: Bool { !calibrated }

  func performanceCheckRan() { calibrated = true }

  static func choices(_ recommendations: LocalModelRecommendations, preserving selectedID: String? = nil) -> [LocalModelAssessment] {
    var choices = recommendations.roles.map(\.assessment)
    // A benchmark can reorder recommendations; do not require a second download.
    if let selectedID, !choices.contains(where: { $0.id == selectedID }),
       let chosen = recommendations.assessments.first(where: { $0.id == selectedID && $0.fit.canRun }) {
      if choices.count == 3 { choices.removeLast() }
      choices.append(chosen)
    }
    return choices
  }

  static func canContinue(selected: LocalModelAssessment?, installed: [LocalModel], activeID: String?,
                          skipLocal: Bool, busy: Bool) -> Bool {
    guard !busy else { return false }
    if skipLocal { return true }
    guard let selected, selected.fit.canRun, activeID == selected.id,
          let model = installed.first(where: { $0.id == selected.id }) else { return false }
    return !selected.model.requiresUpdate(model)
  }
}

// MARK: Flow for the welcome

extension WelcomeSetup {
  /// The step counter, like `2/4`.
  static func counter(for step: Step) -> String { "\(step.rawValue + 1)/\(Step.allCases.count)" }

  func goBack() { step = Step(rawValue: step.rawValue - 1) ?? .welcome }

  func advance() { step = Step(rawValue: step.rawValue + 1) ?? .walkthrough }

  /// Where the character sits: large on the welcome, small in each later step's header.
  enum CharacterSlot: Equatable {
    case hero, header

    var id: EnigmaCharacterSlotID { self == .hero ? "welcome.hero" : "welcome.header" }
    var size: CGFloat { self == .hero ? 170 : 44 }
  }

  static func characterSlot(for step: Step) -> CharacterSlot { step == .welcome ? .hero : .header }

  /// How the character moves between two steps: it glides up from the welcome
  /// into the header and drops back down on Back. Nil when it stays put.
  static func characterTransition(from old: Step, to new: Step) -> EnigmaCharacterTransition? {
    let from = characterSlot(for: old), to = characterSlot(for: new)
    guard from != to else { return nil }
    return to == .header ? .glide : .automatic
  }

  /// What the character reacts to during setup.
  struct Activity: Equatable {
    var isDetectingHardware = false
    var isInstalling = false
    var installFailed = false
    var connectionFailed = false
  }

  /// It thinks while the Mac is checked or a model downloads and verifies, shows
  /// the error state when an install or connection fails. The welcome has no key
  /// field to listen to since search needs no setup (F29 CP8).
  static func characterState(for step: Step, _ activity: Activity) -> EnigmaCharacterState {
    switch step {
    case .welcome, .walkthrough:
      return .idle
    case .models:
      if activity.installFailed { return .error }
      return activity.isDetectingHardware || activity.isInstalling ? .thinking : .idle
    case .connections:
      if activity.connectionFailed { return .error }
      return .idle
    }
  }

  /// Downloading, verifying, installing, and the first performance check.
  static func isInstalling(_ operation: LocalChatViewModel.ModelOperation?) -> Bool {
    switch operation {
    case .downloading, .waitingToInstall, .installing, .benchmarking: true
    case .deleting, nil: false
    }
  }

  /// A model failure, kept apart from chat errors.
  static func installFailed(_ modelFailure: String?) -> Bool { modelFailure != nil }

  /// What the models step's one primary button does.
  enum ModelAction: Equatable {
    case install, update, use, proceed
  }

  /// Nil when nothing can be done yet, like before a model is chosen. `proceed`
  /// matches `canContinue` whenever nothing is busy.
  static func modelAction(selected: LocalModelAssessment?, installed: [LocalModel], activeID: String?,
                          skipLocal: Bool) -> ModelAction? {
    if skipLocal { return .proceed }
    guard let selected, selected.fit.canRun else { return nil }
    guard let model = installed.first(where: { $0.id == selected.id }) else { return .install }
    if selected.model.requiresUpdate(model) { return .update }
    return activeID == selected.id ? .proceed : .use
  }

  /// Whether Return presses the models step's button. Never for a download:
  /// installing or updating takes a click or Space.
  static func returnPressesModelAction(_ action: ModelAction?) -> Bool {
    action != .install && action != .update
  }

  /// The selection shortcut as the welcome shows it, like `⌥⌥`, or nil when it's off.
  static func selectionShortcut(modifier: String, isEnabled: Bool) -> String? {
    guard isEnabled else { return nil }
    let symbol = (SelectionModifier(rawValue: modifier) ?? .option).symbol
    return symbol + symbol
  }
}

enum WelcomeTourStep: Int, CaseIterable {
  case history, composer, commands, files, model, help
  /// F14 spike: New chat, for the hands-on tour.
  case newChat
  var target: Self { self == .commands ? .composer : self }
  var title: String {
    switch self {
    case .history: "Your conversations"
    case .composer: "Start a conversation"
    case .commands: "Shortcuts start with /"
    case .files: "Bring your files"
    case .model: "Choose how I think"
    case .help: "Help is always here"
    case .newChat: "Start fresh anytime"
    }
  }
  var detail: String {
    switch self {
    case .history: "Your \(ChatSessionStore.maximumRetainedSessions) most recent chats live in the sidebar. Press ⌃⌘S to show or hide it, and use New chat to start fresh."
    case .composer: "Type here and press Return to send. Use Shift–Return for a new line. Your draft stays here while you explore the tour."
    case .commands: "Type / in the message box to browse commands. Use ↑ and ↓, then Tab or Return to choose one before adding your question."
    case .files: "Open the file picker to work with a file or folder. Enigma asks for access to what you choose."
    case .model: "Choose Auto, Local, or Cloud, and a model, from the menu beside Send. Local answers on your Mac; Cloud uses your connected provider; Auto selects a route. ⌘K opens it too."
    case .help: "Find keyboard shortcuts here. Settings is nearby for models, connections, and replaying welcome setup. Press Option and Control together to hide or summon Enigma."
    case .newChat: "Press ⌘N or use New chat to start a new conversation."
    }
  }
}

struct WelcomeTourAnchors: PreferenceKey {
  static let defaultValue: [WelcomeTourStep: Anchor<CGRect>] = [:]
  static func reduce(value: inout [WelcomeTourStep: Anchor<CGRect>], nextValue: () -> [WelcomeTourStep: Anchor<CGRect>]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

extension View {
  func welcomeTourTarget(_ step: WelcomeTourStep) -> some View {
    anchorPreference(key: WelcomeTourAnchors.self, value: .bounds) { [step: $0] }
  }
}

extension Notification.Name {
  static let welcomeSetupRequested = Notification.Name("welcomeSetupRequested")
}

// F14 spike: a throwaway prototype of the hands-on tour, to iterate on with
// the owner before any spec. Not for main.

/// The tour in the main window, fully scripted: Return or the card's button
/// takes each next beat. A stop has one or more steps: a question that types
/// itself into the composer and plays a scripted reply in a temporary chat,
/// a new chat, or a beat of the selection scene's mock document.
@MainActor
final class GuidedTour: ObservableObject {
  static let shared = GuidedTour()
  /// The stop to pick up at when Enigma restarts mid-tour, as Screen Recording needs.
  static let progressKey = "guidedTour.stop.spike"

  enum Stop: Int, CaseIterable {
    case ask, code, keys, selection, files, messages, newChat, modes, permissions, done
  }

  /// Where the current step is: typing, ready for Return, playing, or the stop is done.
  enum Beat { case typing, ready, playing, finished }

  /// What a press of Return asks the window to do.
  enum Action { case send(TourDemo), newChat }

  @Published private(set) var stop: Stop?
  @Published private(set) var stepIndex = 0
  @Published private(set) var beat: Beat = .finished
  /// What the composer shows while a demo types itself.
  @Published private(set) var draft = ""
  /// The selection stop's mock document and panel.
  @Published var scene = TourScene()
  /// The character perches on the card, except while a reply plays or it sits in the scene's panel.
  @Published var characterOnCard = true
  @Published private(set) var characterInScene = false
  /// Measured by the card, so the character's perch can sit on it.
  @Published var cardHeight: CGFloat = 220
  /// The tour picked up again after a restart, for the card's welcome back.
  @Published private(set) var resumed = false

  private let defaults: UserDefaults
  /// Tests share the app's defaults, so their tours never save or resume progress.
  private let persists = !TestHost.isActive
  private var typing: Task<Void, Never>?
  private var playing: Task<Void, Never>?
  private var lastAdvance = Date.distantPast
  private var newChatObserver: NSObjectProtocol?
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // ⌘N or New chat at the new-chat step counts as doing it.
    newChatObserver = NotificationCenter.default.addObserver(forName: .newChatRequested, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.beat == .ready, self.currentStep?.kind == .newChat else { return }
        self.stepFinished()
      }
    }
  }

  var isActive: Bool { stop != nil }

  var currentStep: TourStep? {
    guard let steps = stop?.steps, steps.indices.contains(stepIndex) else { return nil }
    return steps[stepIndex]
  }

  func begin() { go(.ask) }

  /// After a restart mid-tour, picks up at the same stop.
  func resumeIfInterrupted() {
    guard persists, stop == nil, defaults.object(forKey: Self.progressKey) != nil,
          let saved = Stop(rawValue: defaults.integer(forKey: Self.progressKey)) else { return }
    go(saved)
    resumed = true
  }

  func go(_ stop: Stop) {
    typing?.cancel()
    playing?.cancel()
    self.stop = stop
    if persists { defaults.set(stop.rawValue, forKey: Self.progressKey) }
    resumed = false
    characterOnCard = true
    characterInScene = false
    scene = TourScene()
    stepIndex = 0
    startStep()
  }

  /// Return or the card's button: finishes the typing, takes the step, or
  /// moves on. Returns what the window should do.
  func advance() -> Action? {
    // The composer and the card's button can both see one Return.
    guard Date().timeIntervalSince(lastAdvance) > 0.25 else { return nil }
    lastAdvance = Date()
    switch beat {
    case .typing:
      finishTyping()
      return nil
    case .ready:
      guard let step = currentStep else { return nil }
      switch step.kind {
      case .send(let demo):
        beat = .playing
        draft = ""
        characterOnCard = false
        return .send(demo)
      case .newChat:
        stepFinished()
        return .newChat
      case .select, .summon, .askSelection, .replace:
        beat = .playing
        play(step.kind)
        return nil
      }
    case .playing:
      return nil
    case .finished:
      next()
      return nil
    }
  }

  /// The step played out: the next one starts, or the stop is done.
  func stepFinished() {
    guard let stop, beat != .finished else { return }
    stepIndex += 1
    if stepIndex < stop.steps.count { startStep() } else { beat = .finished }
  }

  func next() {
    guard let stop else { return }
    if let next = Stop(rawValue: stop.rawValue + 1) { go(next) } else { end() }
  }

  func back() {
    guard let stop, let previous = Stop(rawValue: stop.rawValue - 1) else { return }
    go(previous)
  }

  func end() {
    typing?.cancel()
    playing?.cancel()
    if persists { defaults.removeObject(forKey: Self.progressKey) }
    stop = nil
    beat = .finished
    draft = ""
    scene = TourScene()
    characterOnCard = true
    characterInScene = false
    resumed = false
  }

  // MARK: Steps

  /// A question types itself into the composer, or the scene's into its panel.
  private func startStep() {
    typing?.cancel()
    draft = ""
    guard let step = currentStep else { beat = .finished; return }
    switch step.kind {
    case .send(let demo): type(demo.prompt, firstStep: stepIndex == 0) { self.draft = $0 }
    case .askSelection: type(TourScene.question, firstStep: false) { self.scene.typed = $0 }
    case .newChat, .select, .summon, .replace: beat = .ready
    }
  }

  /// Types `text` a character at a time, with a pause after a leading `/` so
  /// the command list shows.
  private func type(_ text: String, firstStep: Bool, into show: @escaping @MainActor (String) -> Void) {
    beat = .typing
    guard !reduceMotion else { finishTyping(); return }
    typing = Task { [weak self] in
      // Time for the character to land first.
      try? await Task.sleep(for: .milliseconds(firstStep ? 900 : 500))
      var typed = ""
      for character in text {
        guard self != nil, !Task.isCancelled else { return }
        typed.append(character)
        show(typed)
        let pause = typed == "/" ? 1100 : Int.random(in: 28...62)
        try? await Task.sleep(for: .milliseconds(pause))
      }
      guard let self, !Task.isCancelled else { return }
      self.beat = .ready
    }
  }

  private func finishTyping() {
    typing?.cancel()
    switch currentStep?.kind {
    case .send(let demo)?: draft = demo.prompt
    case .askSelection?: scene.typed = TourScene.question
    default: break
    }
    beat = .ready
  }

  /// One beat of the selection scene.
  private func play(_ kind: TourStep.Kind) {
    playing = Task { [weak self] in
      guard let self else { return }
      func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(self.reduceMotion ? 0 : milliseconds)) }
      switch kind {
      case .select:
        self.scene.phase = .selected
        await pause(900)
      case .summon:
        self.scene.keys = 1
        await pause(260)
        self.scene.keys = 2
        await pause(320)
        self.scene.phase = .panel
        self.characterOnCard = false
        self.characterInScene = true
        await pause(700)
        self.scene.keys = 0
      case .askSelection:
        self.scene.phase = .thinking
        await pause(1100)
        self.scene.phase = .answered
        var reply = ""
        for word in TourScene.answer.split(separator: " ") {
          guard !Task.isCancelled else { return }
          reply += (reply.isEmpty ? "" : " ") + word
          self.scene.reply = reply
          await pause(45)
        }
        await pause(300)
        self.scene.showsRevision = true
        await pause(400)
      case .replace:
        self.scene.revisionStatus = .applying
        await pause(700)
        self.scene.revisionStatus = .sent
        self.scene.phase = .replaced
        await pause(500)
      case .send, .newChat:
        break
      }
      guard !Task.isCancelled else { return }
      self.stepFinished()
    }
  }
}

/// One step of a stop, named on the card's checklist.
struct TourStep: Equatable {
  enum Kind: Equatable {
    /// A question typed into the composer and sent.
    case send(TourDemo)
    case newChat
    /// The selection scene: select text, tap ⌥ twice, ask, put it back.
    case select, summon, askSelection, replace
  }

  var label: String
  var kind: Kind

  /// The card's button while the step waits for Return.
  var actionLabel: String {
    switch kind {
    case .send, .askSelection: "Send"
    case .newChat: "New chat"
    case .select: "Select"
    case .summon: "Tap ⌥⌥"
    case .replace: "Replace text"
    }
  }
}

/// The selection stop's mock document and panel, beat by beat.
struct TourScene: Equatable {
  enum Phase: Int, Comparable {
    case document, selected, panel, thinking, answered, replaced
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  var phase = Phase.document
  /// How many ⌥ presses show.
  var keys = 0
  var typed = ""
  var reply = ""
  var showsRevision = false
  var revisionStatus = SelectionRevision.Status.ready

  static let original = "Don’t be late. The boat leaves at 2 sharp."
  static let revised = "Try to get there a little early, the boat leaves at 2!"
  static let question = "make this friendlier"
  static let answer = "Here’s a friendlier version. Replace text puts it back in your draft."
  static let context = ConversationContext(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F14A")!,
                                           sourceName: "Saturday plans", text: original)
  static let revision = UUID(uuidString: "00000000-0000-0000-0000-00000000F14B")!
}

/// A question the tour types and sends, with what's attached to it and the reply it plays.
struct TourDemo: Equatable {
  var prompt: String
  var script: TourScript
  var attachments: [MessageAttachment] = []
  var thinks = false
}

/// A scripted exchange: the activity steps it shows, then a reply streamed word by word.
struct TourScript: Equatable {
  var reply: String
  var phases: [AssistantActivity.Phase]
  var sources: [WebSearchSource] = []
  var places: [MapPlace]? = nil
  /// How long each activity step shows, in milliseconds.
  var phaseDuration = 900

  static let willis = TourScript(
    reply: "Architect Bruce Graham and structural engineer Fazlur Khan of Skidmore, Owings & Merrill. It went up in the early 1970s as the Sears Tower and was the tallest building in the world for nearly 25 years.",
    phases: [.searching, .readingSources],
    sources: [WebSearchSource(title: "Willis Tower - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Willis_Tower")!)])

  static let museums = TourScript(
    reply: "Plenty. The Art Institute of Chicago is right next door. The Field Museum, Shedd Aquarium and Adler Planetarium share the Museum Campus, about a 25-minute walk south along the lake.",
    phases: [.findingPlaces],
    places: [
      MapPlace(id: "tour.art", name: "Art Institute of Chicago", coordinate: SearchCoordinate(latitude: 41.8796, longitude: -87.6237), distanceMeters: nil),
      MapPlace(id: "tour.field", name: "Field Museum", coordinate: SearchCoordinate(latitude: 41.8663, longitude: -87.6170), distanceMeters: nil),
      MapPlace(id: "tour.shedd", name: "Shedd Aquarium", coordinate: SearchCoordinate(latitude: 41.8676, longitude: -87.6140), distanceMeters: nil),
      MapPlace(id: "tour.adler", name: "Adler Planetarium", coordinate: SearchCoordinate(latitude: 41.8663, longitude: -87.6068), distanceMeters: nil),
    ])

  static let weather = TourScript(
    reply: "Tomorrow in Chicago looks breezy and mostly sunny: a high of 58° and a low of 44°, with a 10% chance of rain. Bring a jacket for the lakefront. (An example: I check the real forecast once the tour is over.)",
    phases: [.checkingWeather])

  static let code = TourScript(
    reply: "Chicago’s grid counts out from State and Madison, 800 numbers to a mile:\n\n```python\ndef miles_from_downtown(number: int) -> float:\n    \"\"\"Miles from State and Madison for a Chicago address number.\"\"\"\n    return number / 800\n\nprint(miles_from_downtown(3600))  # 4.5: Addison, by Wrigley Field\n```",
    phases: [.thinking])

  static let think = TourScript(
    reply: "Take the Blue Line. At 5 on a Friday the Kennedy is usually jammed and driving can take over an hour, while the train runs often and gets from the Loop to O’Hare in about 45 minutes. Drive only with a lot of luggage or a group to split the ride.",
    phases: [.thinking], phaseDuration: 2400)

  static let files = TourScript(
    reply: "Done. Trip notes.md is now a packing list in three parts: clothes for the lake wind, things for the game, and chargers. I changed only that file, and you can undo it.",
    phases: [.thinking], phaseDuration: 1400)

  static let readMessages = TourScript(
    reply: "Mom said Sunday dinner is at 6 at her place, and asked if you can bring an Eli’s Cheesecake.",
    phases: [.readingMessages], phaseDuration: 1200)

  static let sendMessage = TourScript(
    reply: "Here’s your text to Sam: “Running 10 minutes late, see you soon!” It goes only after you approve it.",
    phases: [.readingMessages, .awaitingApproval], phaseDuration: 1000)
}

/// A macOS permission the tour asks for at its end, with its live state.
@MainActor
enum TourPermission: CaseIterable {
  case accessibility, fullDiskAccess, screenRecording

  var title: String {
    switch self {
    case .accessibility: "Accessibility"
    case .fullDiskAccess: "Full Disk Access"
    case .screenRecording: "Screen Recording"
    }
  }

  /// What it unlocks.
  var unlocks: String {
    switch self {
    case .accessibility: "⌥⌃ and ⌥⌥ from any app, and putting edits back"
    case .fullDiskAccess: "/messages"
    case .screenRecording: "/screen and /snapshot, only when you ask"
    }
  }

  /// Screen Recording reaches Enigma only after it restarts. Accessibility
  /// and Full Disk Access work at once: both are checked on each use.
  var needsRestart: Bool { self == .screenRecording }

  var isGranted: Bool {
    switch self {
    case .accessibility: SelectionAccessibilityAccess.shared.isGranted
    case .screenRecording: CGPreflightScreenCaptureAccess()
    case .fullDiskAccess: MessagesPermissionStatus.fullDiskAccess() == true
    }
  }

  func turnOn() {
    switch self {
    case .accessibility: SelectionAccessibilityAccess.shared.requestAccess()
    case .screenRecording:
      // Adds Enigma to the list, so turning it on is one switch.
      _ = CGRequestScreenCaptureAccess()
      MacPermissionRows.openScreenSettings()
    case .fullDiskAccess: NSWorkspace.shared.open(MessagesPrivacyPane.fullDiskAccess.url)
    }
  }
}

/// Restarts this copy of Enigma: a helper opens it again once this process has exited.
@MainActor
enum TourRelaunch {
  static func restart() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
      "sh", "\(getpid())", Bundle.main.bundleURL.path,
    ]
    guard (try? process.run()) != nil else { return }
    NSApp.terminate(nil)
  }
}

extension GuidedTour.Stop {
  var title: String {
    switch self {
    case .ask: "Just ask"
    case .code: "Code, and thinking it through"
    case .keys: "Always one keystroke away"
    case .selection: "Ask about anything you select"
    case .files: "Bring your files"
    case .messages: "Your Messages, in your own words"
    case .newChat: "Start fresh anytime"
    case .modes: "Auto is on by default"
    case .permissions: "Choose what I can do"
    case .done: "You’re all set"
    }
  }

  var detail: String {
    switch self {
    case .ask: "Ask the way you’d ask a friend. I work out on my own when to search the web, find places or check the weather."
    case .code: "I write and explain code. When you want a specific tool, start with / to pick a command, like /think for a plan or a trade-off."
    case .keys: "I’m built for the keyboard."
    case .selection: "Here’s how it works in any app, like this draft."
    case .files: "Attach files or folders with + or ⇧⌘A. I tidy notes and fix typos, ask before touching code, and you can undo every change."
    case .messages: "Ask about a chat or have me text someone. Nothing sends until you approve it."
    case .newChat: "⌘N, or New chat in the sidebar. Recents keeps your last \(ChatSessionStore.maximumRetainedSessions) chats, and after 5 minutes away I start fresh on my own."
    case .modes: "I answer on this Mac and use the cloud only when it helps. Switch for one chat from this menu or with ⌘K."
    case .permissions: "All optional. Turn on what you’re comfortable with."
    case .done: "Press ⌥⌃ in any app to bring me back. Forget a shortcut? Help, at the bottom of the sidebar, lists every one."
    }
  }

  /// A short line under the detail: what the stop's feature needs, or where to change it.
  var footnote: String? {
    switch self {
    case .selection: "Needs Accessibility. You choose at the end."
    case .messages: "Needs Full Disk Access. You choose at the end."
    case .modes: "Change the default in Settings → General → Start mode."
    case .done: "Replay this tour any time from Settings → General."
    default: nil
    }
  }

  /// The stop's steps, in order. More than one shows as a checklist on the card.
  var steps: [TourStep] {
    switch self {
    case .ask:
      [TourStep(label: "Search the web", kind: .send(TourDemo(prompt: "who designed the Willis Tower?", script: .willis))),
       TourStep(label: "Find places", kind: .send(TourDemo(prompt: "any good museums near Millennium Park?", script: .museums))),
       TourStep(label: "Check the weather", kind: .send(TourDemo(prompt: "will it rain in Chicago tomorrow?", script: .weather)))]
    case .code:
      [TourStep(label: "Write some code", kind: .send(TourDemo(
         prompt: "write a Python function for how far a Chicago address is from downtown", script: .code))),
       TourStep(label: "Think it through with /think", kind: .send(TourDemo(
         prompt: "/think Blue Line or drive to O’Hare at 5 on a Friday?", script: .think, thinks: true)))]
    case .selection:
      [TourStep(label: "Select text in any app", kind: .select),
       TourStep(label: "Tap ⌥ twice", kind: .summon),
       TourStep(label: "Ask in your own words", kind: .askSelection),
       TourStep(label: "Put it back", kind: .replace)]
    case .files:
      [TourStep(label: "Tidy a file", kind: .send(TourDemo(
         prompt: "turn my trip notes into a packing list", script: .files,
         attachments: [MessageAttachment(name: "Trip notes.md", isDirectory: false)])))]
    case .messages:
      [TourStep(label: "Read and search", kind: .send(TourDemo(prompt: "what did Mom say about Sunday dinner?", script: .readMessages))),
       TourStep(label: "Send a text", kind: .send(TourDemo(prompt: "text Sam that I’m running 10 minutes late", script: .sendMessage)))]
    case .newChat:
      [TourStep(label: "Start a new chat", kind: .newChat)]
    case .keys, .modes, .permissions, .done:
      []
    }
  }

  /// The control the stop points at, if any.
  var target: WelcomeTourStep? {
    switch self {
    case .ask, .code, .messages: .composer
    case .files: .files
    case .newChat: .newChat
    case .modes: .model
    case .done: .help
    case .keys, .selection, .permissions: nil
    }
  }

  /// The composer is where every demo happens, so it isn't ringed; smaller targets are.
  var ringsTarget: Bool { target != nil && target != .composer }

  var expectations: [String] {
    guard self == .modes else { return [] }
    return [
      "Nothing leaves your Mac unless you use the cloud or search.",
      "Smaller local models need a / for Messages, edit, translate and think.",
      "Hard questions go better with a ChatGPT or Claude plan connected.",
    ]
  }
}

// MARK: Overlay

/// Where the tour's card goes: in a rail the window grows for the tour, beside
/// the page, level with what the stop points at, so it never covers the chat
/// or the composer.
struct GuidedTourPlacement: Equatable {
  static let railWidth: CGFloat = 352
  static let margin: CGFloat = 24
  /// Room above the card for the character perched on it.
  static let perchRoom: CGFloat = 64

  let highlight: CGRect?
  let cardWidth: CGFloat
  let cardOrigin: CGPoint

  init(target: CGRect?, container: CGSize, cardHeight: CGFloat) {
    let bounds = CGRect(origin: .zero, size: container)
    let visible = target.map { $0.insetBy(dx: -5, dy: -5).intersection(bounds) }
    highlight = visible.flatMap { $0.isNull ? nil : $0 }
    cardWidth = Self.railWidth - 2 * Self.margin
    let lowest = max(Self.perchRoom, container.height - cardHeight - Self.margin)
    // Level with the target, or a little above the middle without one.
    let ideal = highlight.map { $0.midY - cardHeight / 2 } ?? (container.height - cardHeight) * 0.42
    cardOrigin = CGPoint(x: container.width - Self.railWidth + Self.margin,
                         y: min(max(Self.perchRoom, ideal), lowest))
  }

  /// The page between the sidebar and the rail, where the selection scene plays.
  static func page(in container: CGSize, sidebarVisible: Bool) -> CGRect {
    let leading = sidebarVisible ? MainPageLayout.sidebarWidth(for: container.width) : 0
    return CGRect(x: leading, y: 0, width: max(0, container.width - leading - railWidth), height: container.height)
  }
}

/// The tour's rail beside the page: the window grows by its width for the
/// tour, so the page keeps its own.
struct GuidedTourRail: View {
  @Environment(\.enigmaPalette) private var palette
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    palette.sidebar.color
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(EnigmaEdge.border.color(in: palette, increasedContrast: contrast == .increased).color)
          .frame(width: 1 / displayScale)
      }
      .accessibilityHidden(true)
  }
}

/// What the tour draws under the character: the selection scene, and the
/// character's perch at the card's top-left corner. It's inside the
/// character's stage, so the character can sit on both.
struct GuidedTourPerch: View {
  @ObservedObject var tour: GuidedTour
  let anchors: [WelcomeTourStep: Anchor<CGRect>]
  var sidebarVisible = true
  static let slot: EnigmaCharacterSlotID = "tour.card"

  var body: some View {
    GeometryReader { geometry in
      if let stop = tour.stop {
        let placement = GuidedTourPlacement(target: stop.target.flatMap { anchors[$0] }.map { geometry[$0] },
                                            container: geometry.size, cardHeight: tour.cardHeight)
        ZStack(alignment: .topLeading) {
          if stop == .selection {
            GuidedTourScene(tour: tour)
              .frame(width: GuidedTourPlacement.page(in: geometry.size, sidebarVisible: sidebarVisible).width,
                     height: geometry.size.height)
              .offset(x: GuidedTourPlacement.page(in: geometry.size, sidebarVisible: sidebarVisible).minX)
              .transition(.opacity)
          }
          Color.clear
            .enigmaCharacterSlot(id: Self.slot, size: 54)
            .position(x: placement.cardOrigin.x + 36, y: placement.cardOrigin.y - 22)
        }
        .animation(EnigmaMotion.pageChange.animation, value: stop)
      }
    }
    .allowsHitTesting(false)
  }
}

/// The tour's card and highlight. Only the card takes clicks.
struct GuidedTourOverlay: View {
  @ObservedObject var tour: GuidedTour
  let anchors: [WelcomeTourStep: Anchor<CGRect>]
  var onAdvance: () -> Void
  var onFinish: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    GeometryReader { geometry in
      if let stop = tour.stop {
        let target = stop.target.flatMap { anchors[$0] }.map { geometry[$0] }
        let placement = GuidedTourPlacement(target: target, container: geometry.size, cardHeight: tour.cardHeight)
        ZStack(alignment: .topLeading) {
          if stop.ringsTarget, let highlight = placement.highlight {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(palette.accent.color, lineWidth: 2)
              .frame(width: highlight.width, height: highlight.height)
              .position(x: highlight.midX, y: highlight.midY)
              .allowsHitTesting(false)
          }
          GuidedTourCard(tour: tour, stop: stop, onAdvance: onAdvance, onFinish: onFinish)
            .frame(width: placement.cardWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tour.cardHeight = $0 }
            .offset(x: placement.cardOrigin.x, y: placement.cardOrigin.y)
            .id(stop)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(EnigmaMotion.pageChange.animation, value: stop)
        .animation(EnigmaMotion.pageChange.animation, value: placement)
      }
    }
  }
}

struct GuidedTourCard: View {
  @ObservedObject var tour: GuidedTour
  let stop: GuidedTour.Stop
  var onAdvance: () -> Void
  var onFinish: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      // Room for the character, who perches on the card's corner.
      HStack {
        Spacer()
        Text("\(stop.rawValue + 1)/\(GuidedTour.Stop.allCases.count)")
          .font(EnigmaTypography.mono(11.5))
          .foregroundStyle(palette.textTertiary.color)
      }
      if tour.resumed {
        Text("Welcome back. Picking up where we left off.")
          .font(EnigmaTypography.ui(12.5, weight: .medium))
          .foregroundStyle(palette.accentText.color)
      }
      Text(stop.title)
        .font(EnigmaTypography.ui(17, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(palette.textPrimary.color)
      if !stop.detail.isEmpty {
        Text(stop.detail)
          .font(EnigmaTypography.ui(13.5))
          .foregroundStyle(palette.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      if stop.steps.count > 1 { checklist }
      if stop == .keys { GuidedTourKeys() }
      if !stop.expectations.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(stop.expectations, id: \.self) { line in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("›").font(EnigmaTypography.mono(12)).foregroundStyle(palette.accentText.color)
              Text(line)
                .font(EnigmaTypography.ui(13))
                .foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      if stop == .permissions { GuidedTourPermissions() }
      if let footnote = stop.footnote {
        Text(footnote)
          .font(EnigmaTypography.ui(12.5))
          .foregroundStyle(palette.textTertiary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      buttons.padding(.top, 2)
    }
    .padding(16)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
  }

  /// The stop's steps: done ones checked, the current one marked.
  private var checklist: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(stop.steps.enumerated()), id: \.offset) { index, step in
        let isDone = tour.stop == stop && (index < tour.stepIndex || tour.beat == .finished)
        let isCurrent = tour.stop == stop && index == tour.stepIndex && tour.beat != .finished
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(isDone ? "✓" : isCurrent ? "→" : "·")
            .font(EnigmaTypography.mono(12))
            .foregroundStyle(isDone || isCurrent ? palette.accentText.color : palette.textTertiary.color)
            .frame(width: 12)
          Text(step.label)
            .font(EnigmaTypography.ui(13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? palette.textPrimary.color
                             : isDone ? palette.textSecondary.color : palette.textTertiary.color)
        }
      }
    }
    .padding(.vertical, 2)
    .animation(EnigmaMotion.pageChange.animation, value: tour.stepIndex)
  }

  private var primaryLabel: String {
    switch tour.beat {
    case .typing, .ready: tour.currentStep?.actionLabel ?? "Next"
    case .playing, .finished: "Next"
    }
  }

  private var buttons: some View {
    HStack(spacing: 12) {
      if stop == .done {
        Spacer(minLength: 0)
        Button { onFinish() } label: { HStack(spacing: 10) { Text("Start chatting"); EnigmaKeycap("↵") } }
          .enigmaButtonStyle(.primary)
          .keyboardShortcut(.defaultAction)
      } else {
        Button("End tour") { onFinish() }
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
        Spacer(minLength: 0)
        if stop != .ask {
          Button("Back") { tour.back() }.enigmaButtonStyle(.text)
        }
        Button { onAdvance() } label: { HStack(spacing: 10) { Text(primaryLabel); EnigmaKeycap("↵") } }
          .enigmaButtonStyle(.primary)
          // Return here too when the composer isn't focused; the tour takes one beat per press.
          .keyboardShortcut(.defaultAction)
          .disabled(tour.beat == .playing)
      }
    }
  }
}

/// The keyboard stop: the three keys that matter most, large, then where Enigma lives.
struct GuidedTourKeys: View {
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        row(["⌥", "⌃"], "Summon me from any app")
        row(["⌥", "⌥"], "Ask about the text you’ve selected")
        row(["esc"], "Hide me again")
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.background.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 7) {
        fact("menubar.rectangle", "I live in the menu bar, never in the Dock.")
        fact("eye.slash", "Screenshots and screen sharing leave my window out.")
      }
    }
  }

  private func row(_ keys: [String], _ label: String) -> some View {
    HStack(spacing: 12) {
      HStack(spacing: 4) {
        ForEach(keys.indices, id: \.self) { index in
          GuidedTourKeycap(key: keys[index])
        }
      }
      .frame(width: 72, alignment: .leading)
      Text(label)
        .font(EnigmaTypography.ui(13.5, weight: .medium))
        .foregroundStyle(palette.textPrimary.color)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fact(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(EnigmaTypography.symbol(12))
        .foregroundStyle(palette.accentText.color)
        .frame(width: 18)
      Text(text)
        .font(EnigmaTypography.ui(13))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A large keycap, pressed while `isPressed`.
struct GuidedTourKeycap: View {
  let key: String
  var isPressed = false
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    Text(key)
      .font(EnigmaTypography.ui(key.count > 1 ? 12 : 16, weight: .medium))
      .foregroundStyle(isPressed ? palette.onAccent.color : palette.textPrimary.color)
      .frame(minWidth: 30, minHeight: 30)
      .padding(.horizontal, key.count > 1 ? 6 : 0)
      .background(isPressed ? palette.accent.color : palette.surface.color, in: shape)
      .enigmaEdge(shape)
      .scaleEffect(isPressed ? 0.92 : 1)
  }
}

/// The last stop's permissions: each optional, with what it unlocks and its
/// live state. Screen Recording, the only one that needs a restart, never
/// restarts on its own: it waits for the next launch unless asked.
struct GuidedTourPermissions: View {
  @Environment(\.enigmaPalette) private var palette
  @State private var granted: Set<TourPermission> = []
  @State private var askedForScreen = false
  private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(TourPermission.allCases, id: \.self) { permission in
        row(permission)
          .padding(.vertical, 9)
          .overlay(alignment: .top) { EnigmaHairline() }
      }
      EnigmaHairline()
      Text("Turn on… opens System Settings: switch on Enigma, then come back. If macOS offers to reopen Enigma, Later is fine.")
        .font(EnigmaTypography.ui(12.5))
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    }
    .onAppear { check() }
    .onReceive(refresh) { _ in check() }
  }

  private func row(_ permission: TourPermission) -> some View {
    let waitsForRestart = permission.needsRestart && askedForScreen && !granted.contains(permission)
    return HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(permission.title)
          .font(EnigmaTypography.ui(13.5, weight: .medium))
          .foregroundStyle(palette.textPrimary.color)
        Text(waitsForRestart ? "Works next time Enigma opens." : permission.unlocks)
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textTertiary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if granted.contains(permission) {
        EnigmaStatusLine(.on, "on")
      } else if waitsForRestart {
        Button("Restart now") { TourRelaunch.restart() }
          .enigmaButtonStyle(.text)
      } else {
        Button("Turn on…") {
          if permission.needsRestart { askedForScreen = true }
          permission.turnOn()
        }
        .enigmaButtonStyle(.secondary)
      }
    }
  }

  private func check() {
    let now = Set(TourPermission.allCases.filter(\.isGranted))
    if now != granted { granted = now }
  }
}

// MARK: Selection scene

/// The selection stop's scripted scene over the page: a draft in another app,
/// its text selected, ⌥ tapped twice, the selection panel asked in plain
/// words, and the revision put back into the draft. The panel is built from
/// the real panel's parts, with the character in its input slot.
struct GuidedTourScene: View {
  @ObservedObject var tour: GuidedTour
  static let slot: EnigmaCharacterSlotID = "tour.scene"
  private static let space = "guidedTourScene"
  private static let panelWidth: CGFloat = 540
  @Environment(\.enigmaPalette) private var palette
  @State private var selection: CGRect = .zero

  var body: some View {
    let scene = tour.scene
    ZStack(alignment: .topLeading) {
      backdrop
      VStack(spacing: 18) {
        // The two ⌥ taps, above the window so they never cover its text.
        HStack(spacing: 10) {
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 1)
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 2)
        }
        .scaleEffect(1.4)
        .frame(height: 44)
        .opacity(scene.keys > 0 ? 1 : 0)
        document(scene)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 40)
      if scene.phase >= .panel {
        // It opens under the selection, as the real panel does.
        panel(scene)
          .frame(width: Self.panelWidth)
          .offset(x: selection.midX - Self.panelWidth / 2, y: selection.maxY + 14)
          .transition(.opacity.combined(with: .offset(y: -8)))
      }
    }
    .coordinateSpace(.named(Self.space))
    .animation(.easeInOut(duration: 0.25), value: scene.keys)
    .animation(EnigmaMotion.pageChange.animation, value: scene.phase)
    .animation(EnigmaMotion.pageChange.animation, value: scene.showsRevision)
    .animation(EnigmaMotion.pageChange.animation, value: scene.revisionStatus)
  }

  /// Another app on the Mac: a soft wallpaper over the page.
  private var backdrop: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(LinearGradient(colors: [Color(red: 0.33, green: 0.45, blue: 0.62), Color(red: 0.53, green: 0.43, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(alignment: .topLeading) {
        Text("Another app on your Mac")
          .font(EnigmaTypography.ui(12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
          .padding(16)
      }
      .padding(16)
  }

  private func document(_ scene: TourScene) -> some View {
    let replaced = scene.phase >= .replaced
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7) {
        ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                 Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
          Circle().fill(color).frame(width: 11, height: 11)
        }
        Spacer()
        Text("Saturday plans").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(white: 0.35))
        Spacer()
        Color.clear.frame(width: 47, height: 1)
      }
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(Color(white: 0.93))
      VStack(alignment: .leading, spacing: 12) {
        Text("Hi Jamie,")
        Text("Saturday is all set. Let’s meet at the Art Institute at 10, then lunch at Portillo’s.")
          .fixedSize(horizontal: false, vertical: true)
        ZStack(alignment: .leading) {
          // The selection sweeps across the line, as a drag would.
          Text(TourScene.original)
            .background(alignment: .leading) {
              Color(red: 0.70, green: 0.84, blue: 1)
                .padding(-2)
                .scaleEffect(x: scene.phase >= .selected ? 1 : 0, anchor: .leading)
                .animation(.easeInOut(duration: 0.8), value: scene.phase)
            }
            .opacity(replaced ? 0 : 1)
          Text(TourScene.revised)
            .background(palette.accent.color.opacity(0.22).padding(-2))
            .opacity(replaced ? 1 : 0)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { selection = $0 }
        Text("See you there,\nAlex")
      }
      .font(.system(size: 14))
      .foregroundStyle(Color(white: 0.12))
      .padding(22)
    }
    .frame(width: 480, alignment: .leading)
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
  }

  /// The selection panel as it opens under the selection, from the real
  /// panel's selection line and hints.
  private func panel(_ scene: TourScene) -> some View {
    let shape = RoundedRectangle(cornerRadius: CompactPanelLayout.cornerRadius, style: .continuous)
    return VStack(spacing: 0) {
      EnigmaCompactSelectionLine(contexts: [TourScene.context], isBusy: scene.phase == .thinking, remove: { _ in })
      HStack(alignment: .center, spacing: 10) {
        Color.clear
          .frame(width: CompactPanelLayout.inputSlotSize, height: CompactPanelLayout.inputSlotSize)
          .enigmaCharacterSlot(id: Self.slot, size: CompactPanelLayout.inputSlotSize)
        Text(scene.typed.isEmpty ? CompactPanelLayout.placeholder(hasSelection: true) : scene.typed)
          .font(EnigmaTypography.ui(16))
          .foregroundStyle(scene.typed.isEmpty ? palette.textTertiary.color : palette.textPrimary.color)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("auto · local")
          .font(EnigmaTypography.mono(11))
          .foregroundStyle(palette.textTertiary.color)
        Text("↵")
          .font(EnigmaTypography.mono(12))
          .foregroundStyle(palette.textSecondary.color)
          .frame(width: 26, height: 22)
          .background(palette.background.color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .padding(.leading, 12)
      .padding(.trailing, 14)
      .padding(.vertical, 12)
      if scene.phase >= .thinking {
        VStack(alignment: .leading, spacing: 12) {
          if scene.phase == .thinking {
            EnigmaStatusLine(.busy, "Thinking…")
          } else {
            Text(scene.reply)
              .font(EnigmaTypography.reply)
              .foregroundStyle(palette.textPrimary.color)
              .fixedSize(horizontal: false, vertical: true)
            if scene.showsRevision {
              SelectionRevisionCard(
                revision: SelectionRevision(id: TourScene.revision, contextID: TourScene.context.id,
                                            text: TourScene.revised, automatic: false, status: scene.revisionStatus),
                disabled: false, update: { _ in }, replace: {})
              .transition(.opacity)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
      }
      EnigmaCompactHints(hints: CompactPanelHints.hints(isResponding: scene.phase == .thinking),
                         tag: CompactPanelHints.temporaryTag)
    }
    .background(palette.surface.color)
    .clipShape(shape)
    .enigmaEdge(shape)
    .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
  }
}

extension LocalChatViewModel {
  /// F14 spike: plays a scripted exchange in a temporary chat that's never saved.
  func playTourExchange(_ demo: TourDemo, onFinish: @escaping @MainActor () -> Void) {
    guard !isBusy else { onFinish(); return }
    if !isTemporaryChat { startTemporaryChat(context: nil) }
    var message = ChatMessage(role: .user, content: demo.prompt)
    message.attachments = demo.attachments.isEmpty ? nil : demo.attachments
    message.extendedThinking = demo.thinks ? true : nil
    tourAppend(message, script: demo.script, onFinish: onFinish)
  }
}
