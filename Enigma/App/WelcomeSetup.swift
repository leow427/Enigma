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

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

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
  var target: Self { self == .commands ? .composer : self }
  var title: String {
    switch self {
    case .history: "Your conversations"
    case .composer: "Start a conversation"
    case .commands: "Shortcuts start with /"
    case .files: "Bring your files"
    case .model: "Choose how I think"
    case .help: "Help is always here"
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
/// takes each next beat. A stop's demos type themselves into the composer,
/// and sending one plays a scripted reply in a temporary chat.
@MainActor
final class GuidedTour: ObservableObject {
  static let shared = GuidedTour()
  /// The stop to pick up at when Enigma restarts mid-tour, as Screen Recording needs.
  static let progressKey = "guidedTour.stop.spike"

  enum Stop: Int, CaseIterable {
    case ask, command, selection, files, messages, screen, modes, expect, done
  }

  /// Where a stop is: a demo typing, ready to send, its reply playing, or done.
  enum Beat { case typing, ready, playing, finished }

  @Published private(set) var stop: Stop?
  @Published private(set) var beat: Beat = .finished
  /// What the composer shows while a demo types itself.
  @Published private(set) var draft = ""
  /// The character perches on the card, except while a scripted reply plays.
  @Published var characterOnCard = true
  /// Measured by the card, so the character's perch can sit on it.
  @Published var cardHeight: CGFloat = 220
  /// The tour picked up again after a restart, for the card's welcome back.
  @Published private(set) var resumed = false

  private let defaults: UserDefaults
  private var demoIndex = 0
  private var typing: Task<Void, Never>?
  private var lastAdvance = Date.distantPast

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var isActive: Bool { stop != nil }

  func begin() { go(.ask) }

  /// After a restart mid-tour, picks up at the same stop.
  func resumeIfInterrupted() {
    guard stop == nil, defaults.object(forKey: Self.progressKey) != nil,
          let saved = Stop(rawValue: defaults.integer(forKey: Self.progressKey)) else { return }
    go(saved)
    resumed = true
  }

  func go(_ stop: Stop) {
    self.stop = stop
    defaults.set(stop.rawValue, forKey: Self.progressKey)
    resumed = false
    characterOnCard = true
    demoIndex = 0
    startDemo()
  }

  /// Return or the card's button: finishes the typing, sends the demo, or
  /// moves on. Returns the demo to play when this press sends one.
  func advance() -> TourDemo? {
    // The composer and the card's button can both see one Return.
    guard Date().timeIntervalSince(lastAdvance) > 0.25 else { return nil }
    lastAdvance = Date()
    switch beat {
    case .typing:
      finishTyping()
      return nil
    case .ready:
      guard let demo = currentDemo else { return nil }
      beat = .playing
      draft = ""
      characterOnCard = false
      return demo
    case .playing:
      return nil
    case .finished:
      next()
      return nil
    }
  }

  /// The scripted reply finished: the stop's next demo types, or the stop is done.
  func demoFinished() {
    guard beat == .playing, let stop else { return }
    demoIndex += 1
    if demoIndex < stop.demos.count { startDemo() } else { beat = .finished }
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
    defaults.removeObject(forKey: Self.progressKey)
    stop = nil
    beat = .finished
    draft = ""
    characterOnCard = true
    resumed = false
  }

  private var currentDemo: TourDemo? {
    guard let demos = stop?.demos, demos.indices.contains(demoIndex) else { return nil }
    return demos[demoIndex]
  }

  /// Types the current demo into the composer, a character at a time, with a
  /// pause after a leading `/` so the command list shows.
  private func startDemo() {
    typing?.cancel()
    draft = ""
    guard let demo = currentDemo else { beat = .finished; return }
    beat = .typing
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finishTyping(); return }
    let firstDemo = demoIndex == 0
    typing = Task { [weak self] in
      // Time for the character to land on the card first.
      try? await Task.sleep(for: .milliseconds(firstDemo ? 900 : 500))
      var typed = ""
      for character in demo.prompt {
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
    guard let demo = currentDemo else { return }
    draft = demo.prompt
    beat = .ready
  }
}

/// A question the tour types and sends, with the reply it plays.
struct TourDemo: Equatable {
  var prompt: String
  var script: TourScript
}

/// A scripted exchange: the activity steps it shows, then a reply streamed word by word.
struct TourScript: Equatable {
  var reply: String
  var phases: [AssistantActivity.Phase]
  var sources: [WebSearchSource] = []
  var places: [MapPlace]? = nil

  static let eiffel = TourScript(
    reply: "Gustave Eiffel’s company built it, from a design by two of his engineers, Maurice Koechlin and Émile Nouguier, with architect Stephen Sauvestre. It opened for the 1889 World’s Fair in Paris.",
    phases: [.searching, .readingSources],
    sources: [WebSearchSource(title: "Eiffel Tower - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Eiffel_Tower")!)])

  static let weather = TourScript(
    reply: "Tomorrow in Paris looks dry: sunny spells, a high of 17° and a low of 9°, with only a 10% chance of rain. (This is an example. I check the real forecast once the tour is over.)",
    phases: [.checkingWeather])

  static let museums = TourScript(
    reply: "Here are four museums near the Eiffel Tower. Musée du quai Branly is a short walk along the river. Musée de l’Homme is just across the Seine at Trocadéro. Musée d’Orsay is about half an hour on foot, and the Louvre a little further.",
    phases: [.findingPlaces],
    places: [
      MapPlace(id: "tour.branly", name: "Musée du quai Branly", coordinate: SearchCoordinate(latitude: 48.8609, longitude: 2.2977), distanceMeters: nil),
      MapPlace(id: "tour.homme", name: "Musée de l’Homme", coordinate: SearchCoordinate(latitude: 48.8625, longitude: 2.2875), distanceMeters: nil),
      MapPlace(id: "tour.orsay", name: "Musée d’Orsay", coordinate: SearchCoordinate(latitude: 48.8600, longitude: 2.3266), distanceMeters: nil),
      MapPlace(id: "tour.louvre", name: "Louvre", coordinate: SearchCoordinate(latitude: 48.8606, longitude: 2.3376), distanceMeters: nil),
    ])

  static let translate = TourScript(
    reply: "“Hello, everyone.” In any app, select some text and tap ⌥ twice: I open right beside it to explain it, /edit it or /translate it.",
    phases: [.thinking])
}

/// A macOS permission a stop helps turn on, with its live state.
@MainActor
enum TourPermission {
  case accessibility, screenRecording, fullDiskAccess

  var title: String {
    switch self {
    case .accessibility: "Accessibility"
    case .screenRecording: "Screen Recording"
    case .fullDiskAccess: "Full Disk Access"
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

  /// What to do, one short step at a time.
  var steps: [String] {
    switch self {
    case .accessibility:
      ["Click Turn on…", "Switch on Enigma in System Settings.", "Come back. It works right away."]
    case .fullDiskAccess:
      ["Click Turn on…", "Switch on Enigma in Full Disk Access.", "If macOS offers to reopen Enigma, either choice is fine."]
    case .screenRecording:
      ["Click Turn on…", "Switch on Enigma in Screen Recording.", "Restart Enigma. The tour picks up right here."]
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
    case .command: "Or tell me exactly what to do"
    case .selection: "Ask about anything you select"
    case .files: "Bring your files"
    case .messages: "Your Messages"
    case .screen: "Ask about your screen"
    case .modes: "Where I think"
    case .expect: "Good to know"
    case .done: "You’re all set"
    }
  }

  var detail: String {
    switch self {
    case .ask: "Ask the way you’d ask a friend. I work out on my own when to search the web, find places, check the weather or just answer."
    case .command: "Start with / to see every command. Picking one makes sure I use that tool."
    case .selection: "Select text in any app, then tap ⌥ twice. I open right there to explain it, /edit it or /translate it."
    case .files: "Attach files or folders with + or ⇧⌘A. I tidy notes and fix typos, ask before touching code, and you can undo every change."
    case .messages: "/messages reads a chat or sends a text for you. You see every text before it goes."
    case .screen: "/snapshot lets you drag over part of the screen. /screen takes all of it. I only look when you type one."
    case .modes: "Auto answers on this Mac and uses the cloud only when it helps. Pick Local or Cloud from this menu, or press ⌘K."
    case .expect: ""
    case .done: "Press ⌥⌃ in any app to bring me back. You can replay this tour from Settings."
    }
  }

  /// What the stop types and sends, in order.
  var demos: [TourDemo] {
    switch self {
    case .ask:
      [TourDemo(prompt: "who designed the Eiffel Tower?", script: .eiffel),
       TourDemo(prompt: "will it rain in Paris tomorrow?", script: .weather)]
    case .command: [TourDemo(prompt: "/maps museums near the Eiffel Tower", script: .museums)]
    case .selection: [TourDemo(prompt: "/translate Bonjour tout le monde", script: .translate)]
    default: []
    }
  }

  var permission: TourPermission? {
    switch self {
    case .selection: .accessibility
    case .messages: .fullDiskAccess
    case .screen: .screenRecording
    default: nil
    }
  }

  /// The control the stop points at, if any.
  var target: WelcomeTourStep? {
    switch self {
    case .ask, .command, .selection, .screen: .composer
    case .files: .files
    case .modes: .model
    case .messages, .expect, .done: nil
    }
  }

  var expectations: [String] {
    guard self == .expect else { return [] }
    return [
      "Chats are short-lived: Recents keeps your last \(ChatSessionStore.maximumRetainedSessions), and I start fresh after 5 minutes away.",
      "Smaller local models need a / for Messages, edit, translate and think.",
      "I never look at your screen unless you type /screen or /snapshot.",
      "Nothing leaves your Mac unless you use the cloud or search.",
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
                                            container: geometry.size, cardHeight: tour.cardHeight)
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
        let placement = GuidedTourPlacement(target: target, container: geometry.size, cardHeight: tour.cardHeight)
        ZStack(alignment: .topLeading) {
          if let highlight = placement.highlight {
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
  @State private var granted = false
  /// Screen Recording was asked for, so the card offers the restart it needs.
  @State private var askedForPermission = false
  private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
      if let permission = stop.permission { permissionSection(permission) }
      buttons.padding(.top, 2)
    }
    .padding(16)
    .background(palette.surface.color, in: shape)
    .enigmaEdge(shape)
    .onAppear { check() }
    .onReceive(refresh) { _ in check() }
  }

  /// The permission with its live state, and what to do, step by step.
  private func permissionSection(_ permission: TourPermission) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(permission.title)
          .font(EnigmaTypography.ui(13.5, weight: .medium))
          .foregroundStyle(palette.textPrimary.color)
        Spacer(minLength: 8)
        if granted {
          EnigmaStatusLine(.on, "on")
        } else if permission.needsRestart && askedForPermission {
          Button("Restart Enigma") { TourRelaunch.restart() }
            .enigmaButtonStyle(.secondary)
        } else {
          Button("Turn on…") {
            askedForPermission = true
            permission.turnOn()
          }
          .enigmaButtonStyle(.secondary)
        }
      }
      .padding(.vertical, 8)
      .overlay(alignment: .top) { EnigmaHairline() }
      .overlay(alignment: .bottom) { EnigmaHairline() }
      if !granted {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(permission.steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("\(index + 1)")
                .font(EnigmaTypography.mono(11.5))
                .foregroundStyle(palette.accentText.color)
              Text(step)
                .font(EnigmaTypography.ui(12.5))
                .foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
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
        Button { onAdvance() } label: {
          HStack(spacing: 10) {
            Text(tour.beat == .typing || tour.beat == .ready ? "Send" : "Next")
            EnigmaKeycap("↵")
          }
        }
        .enigmaButtonStyle(.primary)
        // Return here too when the composer isn't focused; the tour takes one beat per press.
        .keyboardShortcut(.defaultAction)
        .disabled(tour.beat == .playing)
      }
    }
  }

  private func check() {
    guard let permission = stop.permission else { return }
    let now = permission.isGranted
    if now != granted { granted = now }
  }
}

extension LocalChatViewModel {
  /// F14 spike: plays a scripted exchange in a temporary chat that's never saved.
  func playTourExchange(prompt: String, script: TourScript, onFinish: @escaping @MainActor () -> Void) {
    guard !isBusy else { onFinish(); return }
    if !isTemporaryChat { startTemporaryChat(context: nil) }
    tourAppend(prompt: prompt, script: script, onFinish: onFinish)
  }
}
