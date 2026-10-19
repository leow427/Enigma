import Foundation

/// What a model's button in Settings does.
enum LocalModelAction: Equatable, Sendable {
  /// Switch to an installed, current package. Selected when it's already in use.
  case use(isSelected: Bool)
  /// Replace an installed package with the catalog's newer one.
  case update
  case install
  /// Download the files to a folder, for a model this Mac can't run in Enigma.
  case downloadFiles
}

struct LocalModelActionState: Equatable, Sendable {
  let action: LocalModelAction
  let isEnabled: Bool
}

/// The model actions and filters behind Local models and Discover.
@MainActor
enum LocalModelSettingsLogic {
  /// The Mac details below the Local models summary, e.g.
  /// "10 CPUs · Metal · 21.3 GB Metal working set".
  static func hardwareDetails(_ hardware: LocalHardwareProfile) -> String {
    var parts = ["\(hardware.cpuCount) CPUs", hardware.hasMetal ? "Metal" : "CPU inference"]
    if hardware.hasMetal, let limit = hardware.metalRecommendedWorkingSet {
      parts.append("\(limit.formatted(.byteCount(style: .memory))) Metal working set")
    }
    return parts.joined(separator: " · ")
  }

  static let memoryWarning = "Memory warning: this model may run slowly, use swap or fail to load on this Mac. You can still install it."

  static func compatibilityWarning(for assessment: LocalModelAssessment) -> String {
    "Compatibility warning: \(assessment.reason) You can still download its files."
  }

  /// Discover's warning for a model that doesn't fit: memory when it can still
  /// be installed, otherwise compatibility. Nil when it fits.
  static func fitWarning(for assessment: LocalModelAssessment) -> String? {
    guard !assessment.fit.canRun else { return nil }
    return assessment.permitsMemoryOverride ? memoryWarning : compatibilityWarning(for: assessment)
  }

  /// Local models: use or update an installed package; install one that can
  /// run here, or offer its files when it can't.
  static func managerAction(for assessment: LocalModelAssessment, installed: [LocalModel], activeID: String?,
                            isBusy: Bool) -> LocalModelActionState {
    if let existing = installed.first(where: { $0.id == assessment.id }) {
      if !assessment.model.requiresUpdate(existing) {
        let selected = activeID == assessment.id
        return LocalModelActionState(action: .use(isSelected: selected),
                                     isEnabled: !isBusy && assessment.canInstall && !selected)
      }
      return LocalModelActionState(action: .update, isEnabled: !isBusy && assessment.canInstall)
    }
    if assessment.canInstall { return LocalModelActionState(action: .install, isEnabled: !isBusy) }
    return LocalModelActionState(action: .downloadFiles, isEnabled: true)
  }

  /// Discover's selected packages.
  static func packageAction(for assessment: LocalModelAssessment, installed: [LocalModel], activeID: String?,
                            isBusy: Bool) -> LocalModelActionState {
    guard assessment.canInstall else { return LocalModelActionState(action: .downloadFiles, isEnabled: true) }
    return installAction(model: assessment.model, installed: installed, activeID: activeID, isBusy: isBusy,
                         isAssessed: true)
  }

  /// Discover's featured model. Until this Mac is assessed it can't be installed yet.
  static func featuredAction(for model: LocalModelDescriptor, assessment: LocalModelAssessment?,
                             installed: [LocalModel], activeID: String?, isBusy: Bool) -> LocalModelActionState {
    if let assessment, !assessment.canInstall {
      return LocalModelActionState(action: .downloadFiles, isEnabled: true)
    }
    return installAction(model: model, installed: installed, activeID: activeID, isBusy: isBusy,
                         isAssessed: assessment != nil)
  }

  private static func installAction(model: LocalModelDescriptor, installed: [LocalModel], activeID: String?,
                                    isBusy: Bool, isAssessed: Bool) -> LocalModelActionState {
    let existing = installed.first { $0.id == model.id }
    let isCurrent = existing.map { !model.requiresUpdate($0) } ?? false
    if isCurrent {
      let selected = activeID == model.id
      return LocalModelActionState(action: .use(isSelected: selected), isEnabled: !isBusy && isAssessed && !selected)
    }
    return LocalModelActionState(action: existing == nil ? .install : .update, isEnabled: !isBusy && isAssessed)
  }

  /// Discover's selected packages: every assessed package but the featured
  /// one, only audio models under Audio, matching the search by name, maker,
  /// or quantization.
  static func discoverPackages(_ assessments: [LocalModelAssessment], scope: ModelDiscoveryScope,
                               search: String) -> [LocalModelAssessment] {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return assessments.filter {
      guard $0.id != LocalModelDiscovery.featuredModelID,
            scope != .audio || $0.model.modelSupportsAudio == true else { return false }
      let text = "\($0.model.displayName) \($0.model.maker) \($0.model.quantization)"
      return term.isEmpty || text.localizedCaseInsensitiveContains(term)
    }
  }

  /// Whether Local models shows the runtime's progress, notices, and benchmark.
  static func showsOperation(chat: LocalChatViewModel, advisor: LocalModelAdvisor) -> Bool {
    chat.state != .idle || chat.benchmarkNotice != nil
      || advisor.latestBenchmark(for: chat.installedModel) != nil || advisor.notice != nil
  }

  /// Whether Discover's featured model shows the runtime's progress: while it
  /// works, and after a failure.
  static func showsDiscoverOperation(state: LocalChatViewModel.State, isBusy: Bool) -> Bool {
    if case .failed = state { return true }
    return isBusy
  }

  /// Loads what the model pages show: installed models, then the Mac and the catalog.
  static func prepare(advisor: LocalModelAdvisor, chat: LocalChatViewModel) async {
    await chat.refreshInstalledModel()
    await advisor.start(installedModels: chat.installedModels, presentOnboarding: false)
  }
}
