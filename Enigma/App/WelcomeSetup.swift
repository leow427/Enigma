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
  private let defaults: UserDefaults
  private var started = false
  /// Setup was already done, or skipped for an existing user, when this launch started it.
  @Published private(set) var wasCompletedBeforeLaunch = false
  private var calibrated = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // A tour another test started doesn't carry into this one.
    if TestHost.isActive { GuidedTour.shared.end() }
  }

  func start(hasInstalledModels: Bool) {
    guard !started else { return }
    started = true
    wasCompletedBeforeLaunch = defaults.bool(forKey: Self.completedKey)
    guard !wasCompletedBeforeLaunch else { return }
    // Existing users can opt in through Replay; interrupted new setup resumes.
    if defaults.object(forKey: Self.progressKey) == nil,
       hasInstalledModels || defaults.bool(forKey: "localModelOnboardingDismissed") {
      defaults.set(true, forKey: Self.completedKey)
      wasCompletedBeforeLaunch = true
      return
    }
    isPresented = true
    step = Step(rawValue: defaults.integer(forKey: Self.progressKey)) ?? .welcome
  }

  func replay() {
    calibrated = false
    isPresented = true
    step = .welcome
  }

  func finish(takeTour: Bool) {
    defaults.set(true, forKey: Self.completedKey)
    defaults.removeObject(forKey: Self.progressKey)
    defaults.set(true, forKey: "localModelOnboardingDismissed")
    // The tour starts first, so the window goes straight from the welcome's size to the tour's.
    if takeTour { GuidedTour.shared.begin() }
    isPresented = false
  }

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

extension Notification.Name {
  static let welcomeSetupRequested = Notification.Name("welcomeSetupRequested")
}
