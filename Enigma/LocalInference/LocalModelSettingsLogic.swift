import Foundation

/// What a model's button in Settings does.
enum LocalModelAction: Equatable, Sendable {
  /// Switch to an installed, current package. Selected when it's already in use.
  case use(isSelected: Bool)
  /// Replace an installed package with the catalog's newer one.
  case update
  case install
}

struct LocalModelActionState: Equatable, Sendable {
  let action: LocalModelAction
  let isEnabled: Bool
}

/// The model actions and summary lines behind Local models.
@MainActor
enum LocalModelSettingsLogic {
  /// A package's details line, with the window it runs at here (F35): an installed copy's, else
  /// `runtimeSize`'s, else the package's.
  static func contextDetail(for model: LocalModelDescriptor, installed: [LocalModel],
                            runtimeSize: (LocalModelDescriptor) -> Int? = { _ in nil }) -> String {
    let size = installed.first { $0.id == model.id }?.contextWindow ?? runtimeSize(model) ?? model.recommendedContextSize
    return "\(model.quantization) · \(size) token context · \(model.performanceClass)"
  }

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

  /// The measured bandwidth for the Local models summary.
  static func bandwidthStat(_ hardware: LocalHardwareProfile) -> (value: String, label: String) {
    guard let bandwidth = hardware.measuredBandwidth else { return ("Not measured", "memory bandwidth") }
    return ("\(Int(bandwidth.rounded())) GB/s", "memory bandwidth")
  }

  /// The line under an installed model in On this Mac.
  static func installedSubtitle(for model: LocalModel, inCatalogue: Bool) -> String {
    if inCatalogue, let descriptor = model.catalogDescriptor {
      return "\(descriptor.quantization) · \(descriptor.maker)"
    }
    return model.supportsVision
      ? "Legacy/imported image model · Select to use for all requests"
      : "Legacy/imported text-only model · OCR available, images unsupported"
  }

  /// Local models: use or update an installed package, or install one. A
  /// package this Mac can't install keeps a disabled Install.
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
    return LocalModelActionState(action: .install, isEnabled: !isBusy && assessment.canInstall)
  }

  /// The model sheet closes during a download; only work that holds the engines keeps it open.
  static func canDismissModelSheet(chat: LocalChatViewModel) -> Bool { !chat.isBusy }

  /// Whether Local models shows the runtime's progress, notices, and benchmark.
  static func showsOperation(chat: LocalChatViewModel, advisor: LocalModelAdvisor) -> Bool {
    chat.modelOperation != nil || chat.modelFailure != nil || chat.state != .idle || chat.benchmarkNotice != nil
      || advisor.latestBenchmark(for: chat.installedModel) != nil || advisor.notice != nil
  }

  /// Loads what the model pages show: installed models, then the Mac and the catalog.
  static func prepare(advisor: LocalModelAdvisor, chat: LocalChatViewModel) async {
    await chat.refreshInstalledModel()
    await advisor.start(installedModels: chat.installedModels, presentOnboarding: false)
  }
}
