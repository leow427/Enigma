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
/// a new chat, or a beat of the selection stop, which runs the real selection
/// panel against a pretend document in its own window.
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
  enum Action {
    case send(TourDemo), newChat
    /// Replace text on the selection stop's revision card.
    case replace
    /// Send on the approval card.
    case approveSend
  }

  @Published private(set) var stop: Stop?
  @Published private(set) var stepIndex = 0
  @Published private(set) var beat: Beat = .finished
  /// What the composer shows while a demo types itself.
  @Published private(set) var draft = ""
  /// The selection stop's pretend document.
  @Published var scene = TourScene()
  /// The character perches on the card, except while a scripted reply plays.
  @Published var characterOnCard = true
  /// Measured by the card, so the character's perch can sit on it.
  @Published var cardHeight: CGFloat = 220
  /// The tour picked up again after a restart, for the card's welcome back.
  @Published private(set) var resumed = false
  /// The page's width while the window grows for the tour and shrinks back,
  /// set by the window: the page keeps it, and the window's edge uncovers or
  /// covers the rail beside it. Nil outside the tour.
  @Published var pageWidth: CGFloat?

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

  /// Where the rail starts in a window `width` wide: beside the page, which
  /// keeps its width while the window resizes for the tour.
  func railMinX(in width: CGFloat) -> CGFloat {
    pageWidth.map { min($0, width) } ?? width - GuidedTourPlacement.railWidth
  }

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
    let leaving = self.stop
    self.stop = stop
    if persists { defaults.set(stop.rawValue, forKey: Self.progressKey) }
    resumed = false
    characterOnCard = true
    scene = TourScene()
    stepIndex = 0
    if stop == .selection {
      // Enigma steps aside for the pretend app, as if you'd switched to it.
      NotificationCenter.default.post(name: .guidedTourStepAside, object: nil)
      TourDocumentWindow.shared.open()
    } else if leaving == .selection {
      leaveDocument()
    }
    startStep()
  }

  /// Return or the card's button, in either window.
  func press() {
    if let action = advance() { NotificationCenter.default.post(name: .guidedTourAction, object: action) }
  }

  /// End tour or Start chatting, in either window.
  func requestFinish() { NotificationCenter.default.post(name: .guidedTourFinishRequested, object: nil) }

  /// Finishes the typing, takes the step, or moves on. Returns what the window should do.
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
      case .askSelection:
        beat = .playing
        draft = ""
        scene.phase = .sent
        return .send(TourScene.demo)
      case .newChat:
        stepFinished()
        return .newChat
      case .replace:
        beat = .playing
        return .replace
      case .approve:
        beat = .playing
        return .approveSend
      case .select, .summon:
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
    let leaving = stop
    stop = nil
    beat = .finished
    draft = ""
    scene = TourScene()
    characterOnCard = true
    resumed = false
    if leaving == .selection { leaveDocument() }
  }

  // MARK: The selection stop

  /// The selection shortcut during the selection stop: it takes the ⌥⌥ step
  /// instead of reading another app.
  func shortcutPressed() {
    guard beat == .ready, currentStep?.kind == .summon else { return }
    press()
  }

  /// Replace text, sent to the pretend document instead of another app. The
  /// window steps aside and comes back the way a real paste makes it.
  func replaceInDocument(_ text: String, automatic: Bool) async -> Bool {
    NotificationCenter.default.post(name: .selectionReplacementBegan, object: nil)
    TourDocumentWindow.shared.bringForward()
    try? await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 380))
    scene.phase = .replaced
    try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1150))
    NotificationCenter.default.post(name: .selectionReplacementEnded,
                                    object: SelectionReplacementEnd(automatic: automatic, sent: true))
    if currentStep?.kind == .replace { stepFinished() }
    return true
  }

  /// Back to Enigma's own window, as it was before the stop.
  private func leaveDocument() {
    NotificationCenter.default.post(name: .guidedTourComeBack, object: nil)
    TourDocumentWindow.shared.close()
  }

  // MARK: Steps

  /// A question types itself into the composer.
  private func startStep() {
    typing?.cancel()
    draft = ""
    guard let step = currentStep else { beat = .finished; return }
    switch step.kind {
    case .send(let demo): type(demo.prompt, firstStep: stepIndex == 0)
    case .askSelection: type(TourScene.demo.prompt, firstStep: false)
    case .newChat, .select, .summon, .replace, .approve: beat = .ready
    }
  }

  /// Types `text` a character at a time, with a pause after a leading `/` so
  /// the command list shows.
  private func type(_ text: String, firstStep: Bool) {
    beat = .typing
    guard !reduceMotion else { finishTyping(); return }
    typing = Task { [weak self] in
      // Time for the character to land first.
      try? await Task.sleep(for: .milliseconds(firstStep ? 900 : 500))
      var typed = ""
      for character in text {
        guard let self, !Task.isCancelled else { return }
        typed.append(character)
        self.draft = typed
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
    case .askSelection?: draft = TourScene.demo.prompt
    default: break
    }
    beat = .ready
  }

  /// Selecting the line, and the two ⌥ taps that open the real panel under it.
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
        if let selection = TourDocumentWindow.shared.selectionOnScreen {
          NotificationCenter.default.post(name: .guidedTourSummon, object: NSValue(rect: selection))
        }
        await pause(700)
        self.scene.keys = 0
      case .send, .askSelection, .newChat, .replace, .approve:
        break
      }
      guard !Task.isCancelled else { return }
      self.stepFinished()
    }
  }
}

extension Notification.Name {
  /// F14 spike: the tour asks the main window to step aside, come back, or
  /// open the selection panel under the pretend document's selection.
  static let guidedTourStepAside = Notification.Name("guidedTourStepAside")
  static let guidedTourComeBack = Notification.Name("guidedTourComeBack")
  static let guidedTourSummon = Notification.Name("guidedTourSummon")
  /// A `GuidedTour.Action` for the window to carry out.
  static let guidedTourAction = Notification.Name("guidedTourAction")
  static let guidedTourFinishRequested = Notification.Name("guidedTourFinishRequested")
}

/// One step of a stop, named on the card's checklist.
struct TourStep: Equatable {
  enum Kind: Equatable {
    /// A question typed into the composer and sent.
    case send(TourDemo)
    case newChat
    /// The selection stop: select text, tap ⌥ twice, ask, put it back.
    case select, summon, askSelection, replace
    /// Send on the real approval card of the text the last step asked for.
    case approve
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
    case .approve: "Send"
    }
  }
}

/// The selection stop's pretend document, beat by beat.
struct TourScene: Equatable {
  enum Phase: Int, Comparable {
    case document, selected, panel, sent, replaced
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  var phase = Phase.document
  /// How many ⌥ presses show.
  var keys = 0

  static let original = "Don’t be late. The boat leaves at 2 sharp."
  static let revised = "Try to get there a little early, the boat leaves at 2!"
  static let context = ConversationContext(id: UUID(uuidString: "00000000-0000-0000-0000-00000000F14A")!,
                                           sourceName: "Shmoogle Docs", text: original)
  /// The question the panel types, with the selection attached, and its reply with a revision.
  static let demo = TourDemo(prompt: "make this friendlier", script: .friendlier, contexts: [context], opensInWindow: true)
}

/// A question the tour types and sends, with what's attached to it and the reply it plays.
struct TourDemo: Equatable {
  var prompt: String
  var script: TourScript
  var attachments: [MessageAttachment] = []
  var contexts: [ConversationContext] = []
  var thinks = false
  /// Sent from the selection panel: the chat moves into the window, as a real send does.
  var opensInWindow = false
}

/// A scripted exchange: the activity steps it shows, then a reply streamed word by word.
struct TourScript: Equatable {
  var reply: String
  var phases: [AssistantActivity.Phase]
  var sources: [WebSearchSource] = []
  var places: [MapPlace]? = nil
  /// How long each activity step shows, in milliseconds.
  var phaseDuration = 900
  /// A revision of the attached selection, for the reply's Revised text card.
  var revision: String? = nil
  /// A text the reply asks to send, on the real approval card. The reply
  /// waits for an answer, and nothing is ever sent.
  var approval: MessagesSendApproval? = nil
  /// The reply when the text isn't approved.
  var declined: String? = nil

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

  static let friendlier = TourScript(
    reply: "Here’s a friendlier version. Replace text puts it back in your draft.",
    phases: [.thinking], revision: TourScene.revised)

  static let sendMessage = TourScript(
    reply: "Sent to Sam: “Running 10 minutes late, see you soon!” (An example: the tour never sends a real text.)",
    phases: [.readingMessages, .awaitingApproval], phaseDuration: 1000,
    approval: MessagesSendApproval(conversationName: nil,
      recipients: [MessagesSendApproval.Recipient(name: "Sam", handle: "123-456-7891")],
      service: "iMessage", text: "Running 10 minutes late, see you soon!", target: .iMessage("1234567891")),
    declined: "Okay, I didn’t send it. Nothing goes to anyone until you choose Send.")
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
    case .selection: "In other apps this needs Accessibility. You choose at the end."
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
       TourStep(label: "Ask for a text", kind: .send(TourDemo(prompt: "text Sam that I’m running 10 minutes late", script: .sendMessage))),
       TourStep(label: "Approve it", kind: .approve)]
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

  /// `railMinX` is where the rail starts, beside the page; by default the
  /// rail is the window's right edge.
  init(target: CGRect?, container: CGSize, cardHeight: CGFloat, railMinX: CGFloat? = nil) {
    let bounds = CGRect(origin: .zero, size: container)
    let visible = target.map { $0.insetBy(dx: -5, dy: -5).intersection(bounds) }
    highlight = visible.flatMap { $0.isNull ? nil : $0 }
    cardWidth = Self.railWidth - 2 * Self.margin
    let lowest = max(Self.perchRoom, container.height - cardHeight - Self.margin)
    // Level with the target, or a little above the middle without one.
    let ideal = highlight.map { $0.midY - cardHeight / 2 } ?? (container.height - cardHeight) * 0.42
    cardOrigin = CGPoint(x: (railMinX ?? container.width - Self.railWidth) + Self.margin,
                         y: min(max(Self.perchRoom, ideal), lowest))
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

/// The character's perch on the tour card. It sits inside the character's
/// stage, under the card, at the card's top-left corner.
struct GuidedTourPerch: View {
  @ObservedObject var tour: GuidedTour
  let anchors: [WelcomeTourStep: Anchor<CGRect>]
  static let slot: EnigmaCharacterSlotID = "tour.card"

  var body: some View {
    GeometryReader { geometry in
      if let stop = tour.stop {
        let placement = GuidedTourPlacement(target: stop.target.flatMap { anchors[$0] }.map { geometry[$0] },
                                            container: geometry.size, cardHeight: tour.cardHeight,
                                            railMinX: tour.railMinX(in: geometry.size.width))
        Color.clear
          .enigmaCharacterSlot(id: Self.slot, size: 54)
          .position(x: placement.cardOrigin.x + 36, y: placement.cardOrigin.y - 22)
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
        let placement = GuidedTourPlacement(target: target, container: geometry.size, cardHeight: tour.cardHeight,
                                            railMinX: tour.railMinX(in: geometry.size.width))
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
        // The card moves on its own only for a new stop or a new height. It
        // follows a window that's growing or shrinking frame by frame.
        .animation(EnigmaMotion.pageChange.animation, value: stop)
        .animation(EnigmaMotion.pageChange.animation, value: tour.cardHeight)
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

// MARK: Pretend document

/// The selection stop's pretend app: a real window with a draft in it, so
/// Enigma's own selection panel can open under its selected line exactly as
/// it does over any app. Its right side holds the tour's card while Enigma's
/// window is away or is the panel.
@MainActor
final class TourDocumentWindow {
  static let shared = TourDocumentWindow()
  static let contentSize = NSSize(width: 560 + GuidedTourPlacement.railWidth, height: 560)
  private var window: NSPanel?
  /// The selected line, in the content's own space with a top-left origin.
  var selection: CGRect = .zero
  /// Counts fades, so a finished fade-out can't hide the window opened again since.
  private var fades = 0
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// Rises into place as Enigma's window fades aside.
  func open() {
    let window = self.window ?? makeWindow()
    self.window = window
    fades += 1
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let frame = screen.map { PanelSizeStore.centeredFrame(size: window.frame.size, in: $0.visibleFrame) } ?? window.frame
    window.setFrame(frame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -16), display: false)
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.15 : 0.38
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      window.animator().alphaValue = 1
      window.animator().setFrame(frame, display: true)
    }
  }

  /// Fades away, behind Enigma's window.
  func close() {
    guard let window, window.isVisible else { return }
    fades += 1
    let fade = fades
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : 0.22
      window.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        guard fade == self.fades else { return }
        window.orderOut(nil)
        window.alphaValue = 1
      }
    }
  }

  /// Above the other apps while Enigma's window steps aside for a paste.
  func bringForward() { window?.orderFrontRegardless() }

  /// The selected line on screen, for placing the panel under it.
  var selectionOnScreen: NSRect? {
    guard let window, let content = window.contentView, window.isVisible, !selection.isEmpty else { return nil }
    let inView = content.isFlipped ? selection
      : NSRect(x: selection.minX, y: content.bounds.height - selection.maxY, width: selection.width, height: selection.height)
    return window.convertToScreen(content.convert(inView, to: nil))
  }

  private func makeWindow() -> NSPanel {
    let panel = TourDocumentPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Saturday plans – Shmoogle Docs"
    panel.isFloatingPanel = true
    // Under Enigma's window and panel, as another app's window is, so it
    // never covers them, even after a click on its card, and above the rest.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    // It fades and rises on its own.
    panel.animationBehavior = .none
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: TourDocumentRoot())
    return panel
  }
}

/// Takes keys, so Return reaches the card's button.
private final class TourDocumentPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// The pretend document in Enigma's theme, which only its card uses.
private struct TourDocumentRoot: View {
  @ObservedObject private var appearance = EnigmaAppearancePreference.shared

  var body: some View {
    TourDocumentView(tour: .shared)
      .enigmaTheme(appearance.appearance)
  }
}

/// The draft, with its line selected, the ⌥ taps, and the replacement as
/// they happen, beside the tour's card.
struct TourDocumentView: View {
  @ObservedObject var tour: GuidedTour
  /// Tests leave the shared pretend window alone.
  var measures = true
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let scene = tour.scene
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        ShmoogleDocsHeader()
        document(scene)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.white)
      .overlay(alignment: .bottom) {
        // The two ⌥ taps, under the text so they never cover it.
        HStack(spacing: 10) {
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 1)
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 2)
        }
        .scaleEffect(1.4)
        .padding(.bottom, 48)
        .opacity(scene.keys > 0 ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: scene.keys)
      }
      ZStack {
        GuidedTourRail()
        // The card stays here until the chat moves into Enigma's window, which shows its own.
        if scene.phase < .sent {
          GuidedTourCard(tour: tour, stop: .selection, onAdvance: { GuidedTour.shared.press() },
                         onFinish: { GuidedTour.shared.requestFinish() })
            .frame(width: GuidedTourPlacement.railWidth - 2 * GuidedTourPlacement.margin)
            .transition(.opacity)
        }
      }
      .frame(width: GuidedTourPlacement.railWidth)
      .animation(EnigmaMotion.pageChange.animation, value: scene.phase)
    }
    .frame(width: TourDocumentWindow.contentSize.width, height: TourDocumentWindow.contentSize.height)
  }

  private func document(_ scene: TourScene) -> some View {
    let replaced = scene.phase >= .replaced
    return VStack(alignment: .leading, spacing: 14) {
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
      .animation(.easeInOut(duration: 0.35), value: replaced)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        if measures { TourDocumentWindow.shared.selection = frame }
      }
      Text("See you there,\nAlex")
    }
    .font(.system(size: 15))
    .foregroundStyle(Color(white: 0.12))
    .padding(40)
  }
}

/// The pretend app's toolbar, for fun: its logo, the draft's name, its menus and Share.
private struct ShmoogleDocsHeader: View {
  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      ShmoogleDocsLogo()
      VStack(alignment: .leading, spacing: 3) {
        Text("Saturday plans")
          .font(.system(size: 15))
          .foregroundStyle(Color(white: 0.13))
        HStack(spacing: 11) {
          ForEach(["File", "Edit", "View", "Insert", "Format", "Tools"], id: \.self) { Text($0) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color(white: 0.35))
      }
      Spacer(minLength: 8)
      Text("Share")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 0.04, green: 0.20, blue: 0.43))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(red: 0.76, green: 0.87, blue: 0.99), in: Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(red: 0.976, green: 0.984, blue: 0.992))
    .overlay(alignment: .bottom) { Color(white: 0.88).frame(height: 1) }
    .accessibilityHidden(true)
  }
}

/// Shmoogle Docs' logo: a blue page with a folded corner and lines of text.
private struct ShmoogleDocsLogo: View {
  var body: some View {
    let blue = Color(red: 0.26, green: 0.52, blue: 0.96)
    ZStack(alignment: .topLeading) {
      ShmooglePage(fold: 6).fill(blue)
      ShmoogleFold(fold: 6).fill(Color(red: 0.63, green: 0.76, blue: 0.98))
      VStack(alignment: .leading, spacing: 2.4) {
        ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white).frame(width: 11, height: 1.6) }
        Capsule().fill(.white).frame(width: 7, height: 1.6)
      }
      .offset(x: 4.5, y: 9)
    }
    .frame(width: 20, height: 26)
    .fixedSize()
  }
}

private struct ShmooglePage: Shape {
  let fold: CGFloat
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}

private struct ShmoogleFold: Shape {
  let fold: CGFloat
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
      path.closeSubpath()
    }
  }
}

extension LocalChatViewModel {
  /// F14 spike: plays a scripted exchange in a temporary chat that's never
  /// saved. A text it asks to send waits on `confirm`, the real approval card.
  func playTourExchange(_ demo: TourDemo, confirm: (@MainActor (MessagesSendApproval) async -> Bool)? = nil,
                        onFinish: @escaping @MainActor () -> Void) {
    guard !isBusy else { onFinish(); return }
    if !isTemporaryChat { startTemporaryChat(context: nil) }
    var message = ChatMessage(role: .user, content: demo.prompt)
    message.attachments = demo.attachments.isEmpty ? nil : demo.attachments
    message.contexts = demo.contexts.isEmpty ? nil : demo.contexts
    message.extendedThinking = demo.thinks ? true : nil
    tourAppend(message, script: demo.script, confirm: confirm, onFinish: onFinish)
  }
}
