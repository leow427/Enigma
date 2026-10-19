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
    isPresented = true
    tour = nil
    step = .welcome
  }

  func finish(takeTour: Bool) {
    defaults.set(true, forKey: Self.completedKey)
    defaults.removeObject(forKey: Self.progressKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    tour = takeTour ? .history : nil
    isPresented = false
  }

  func nextTourStep() {
    guard let tour else { return }
    self.tour = WelcomeTourStep(rawValue: tour.rawValue + 1)
  }

  func endTour() { tour = nil }

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
    var size: CGFloat { self == .hero ? 150 : 40 }
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
    var isEnteringKey = false
  }

  /// It thinks while the Mac is checked or a model downloads and verifies, shows
  /// the error state when an install or connection fails, and listens while
  /// someone types an API key.
  static func characterState(for step: Step, _ activity: Activity) -> EnigmaCharacterState {
    switch step {
    case .welcome, .walkthrough:
      return .idle
    case .models:
      if activity.installFailed { return .error }
      return activity.isDetectingHardware || activity.isInstalling ? .thinking : .idle
    case .connections:
      if activity.connectionFailed { return .error }
      return activity.isEnteringKey ? .listening : .idle
    }
  }

  /// Downloading, verifying, installing, and the first performance check.
  static func isInstalling(_ state: LocalChatViewModel.State) -> Bool {
    switch state {
    case .downloading, .installing, .benchmarking: true
    default: false
    }
  }

  static func installFailed(_ state: LocalChatViewModel.State) -> Bool {
    if case .failed = state { return true }
    return false
  }

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
    case .history: "Your \(ChatSessionStore.maximumRetainedSessions) most recent chats live in the sidebar. Double-tap Control to show or hide it, and use New chat to start fresh."
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
