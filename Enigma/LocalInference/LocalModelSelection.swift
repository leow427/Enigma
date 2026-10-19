import Foundation

enum LocalModelCompatibility {
  // Tied to Packages/LlamaBridge/Package.swift. A remote catalog cannot expand
  // native capabilities; new architectures require an app/bridge review.
  static let llamaBuild = 5_046
  static let minimumContext = 4_096

  static func supports(_ model: LocalModelDescriptor) -> Bool {
    if model.supportsVision {
      guard let profile = model.resolvedProfile, profile != .miniCPMO45 else { return false }
      return model.runtimeBuild == LocalVisionRuntime.build && model.minimumLlamaBuild <= LocalVisionRuntime.build
        && model.architecture == profile.architecture && model.chatTemplate == profile.chatTemplate
        && model.parameterBillions == profile.parameters
        && profile.quantizations.contains(model.quantization) && model.recommendedContextSize == 8192
    }
    return model.minimumLlamaBuild <= llamaBuild && model.architecture == "qwen2"
      && model.chatTemplate == "chatml"
      && ["Q4_K_M", "Q5_K_M", "Q8_0"].contains(model.quantization)
      && model.recommendedContextSize >= minimumContext
      && model.recommendedContextSize <= 32_768
  }
}

enum LocalModelFit: String, Sendable {
  case excellent = "Excellent fit"
  case good = "Good fit"
  case slow = "May be slow"
  case memory = "Insufficient memory"
  case disk = "Insufficient disk space"
  case unsupported = "Unsupported"

  var canRun: Bool { self == .excellent || self == .good || self == .slow }
}

struct LocalModelAssessment: Identifiable, Sendable {
  let model: LocalModelDescriptor
  let fit: LocalModelFit
  let reason: String
  let tokensPerSecond: Double
  let timeToFirstToken: Double
  let isMeasured: Bool
  var id: String { model.id }
  /// Users can install compatible packages above the recommended memory budget.
  /// Disk space and runtime compatibility still determine whether installation
  /// is possible; unsupported models remain available as file downloads.
  var permitsMemoryOverride: Bool { fit == .memory && model.permitsMemoryOverride }
  var canInstall: Bool { fit.canRun || permitsMemoryOverride }
  /// Fast: at least 20 tok/s and a first token within 2 s on a 256-token prompt.
  var isFast: Bool {
    fit.canRun && tokensPerSecond >= LocalModelSelector.fastTokensPerSecond
      && timeToFirstToken <= LocalModelSelector.fastTimeToFirstToken
  }
  var isUsable: Bool { fit.canRun && tokensPerSecond >= LocalModelSelector.usableTokensPerSecond }
  var performanceDescription: String {
    if !fit.canRun { return reason }
    let prefix = isMeasured ? "Measured" : "Estimated"
    return "\(prefix) \(Int(tokensPerSecond.rounded())) tokens/sec · "
      + (isFast ? "Responsive everyday chat" : "Longer waits for replies")
  }
}

/// The three choices every picker shows, in this order.
enum LocalModelRole: String, Sendable, CaseIterable {
  case recommended, faster, smarter

  func tag(isFast: Bool) -> String {
    switch self {
    case .recommended: isFast ? "recommended" : "best available, expect longer waits"
    case .faster: "faster"
    case .smarter: "smarter, slower replies"
    }
  }
}

struct LocalModelRoleChoice: Identifiable, Sendable {
  let role: LocalModelRole
  let assessment: LocalModelAssessment
  var id: String { assessment.id }
  var tag: String { role.tag(isFast: assessment.isFast) }
}

struct LocalModelRecommendations: Sendable {
  /// Every package in the catalogue.
  let assessments: [LocalModelAssessment]
  let recommended: LocalModelAssessment?
  let faster: LocalModelAssessment?
  let smarter: LocalModelAssessment?
  /// One package per family, in quality order.
  var allFamilies: [LocalModelAssessment] = []

  var roles: [LocalModelRoleChoice] {
    [(LocalModelRole.recommended, recommended), (.faster, faster), (.smarter, smarter)].compactMap { role, assessment in
      assessment.map { LocalModelRoleChoice(role: role, assessment: $0) }
    }
  }

  func fasterAlternative(to modelID: String) -> LocalModelAssessment? {
    guard let current = assessments.first(where: { $0.id == modelID }) else { return nil }
    return assessments.filter {
      $0.id != modelID && $0.isFast
        && $0.model.estimatedRuntimeMemory < current.model.estimatedRuntimeMemory
        && $0.tokensPerSecond >= current.tokensPerSecond * 1.2
    }.sorted(by: LocalModelSelector.qualityOrder).first
  }
}

enum LocalModelSelector {
  static let fastTokensPerSecond = 20.0
  static let fastTimeToFirstToken = 2.0
  static let usableTokensPerSecond = 8.0
  /// Above this Recommended already feels instant, so no Faster role is offered.
  static let instantTokensPerSecond = 40.0
  static let fasterSpeedup = 1.5

  /// The family's package: the largest fast package, else the smallest runnable one, else nil.
  /// Within a family a higher precision is a larger file.
  static func choice(in family: [LocalModelAssessment]) -> LocalModelAssessment? {
    if let fast = family.filter(\.isFast).max(by: { $0.model.expectedByteCount < $1.model.expectedByteCount }) {
      return fast
    }
    return family.filter(\.fit.canRun).min { $0.model.expectedByteCount < $1.model.expectedByteCount }
  }

  /// Speed and memory are gates; quality ranks only what passes them.
  static func select(
    manifest: LocalModelManifest, hardware: LocalHardwareProfile,
    measurements: [LocalModelBenchmark] = [], installedIDs: Set<String> = []
  ) -> LocalModelRecommendations {
    let assessments = manifest.models.map {
      assess($0, hardware: hardware, measurements: measurements, installed: installedIDs.contains($0.id))
    }
    var families: [String: [LocalModelAssessment]] = [:]
    var familyOrder: [String] = []
    for assessment in assessments {
      let family = assessment.model.familyID
      if families[family] == nil { familyOrder.append(family) }
      families[family, default: []].append(assessment)
    }
    let grouped = familyOrder.compactMap { families[$0] }
    let candidates = grouped.compactMap { choice(in: $0) }.sorted(by: qualityOrder)
    let allFamilies = grouped.compactMap { family in
      choice(in: family) ?? family.min { $0.model.expectedByteCount < $1.model.expectedByteCount }
    }.sorted(by: qualityOrder)
    let recommended = candidates.first(where: \.isFast) ?? candidates.first(where: \.isUsable)
    var faster: LocalModelAssessment?
    var smarter: LocalModelAssessment?
    if let recommended, recommended.isFast {
      if recommended.tokensPerSecond < instantTokensPerSecond {
        faster = candidates.first {
          $0.isFast && $0.model.familyID != recommended.model.familyID
            && $0.tokensPerSecond >= recommended.tokensPerSecond * fasterSpeedup
        }
      }
      smarter = candidates.first {
        $0.isUsable && !$0.isFast && $0.model.qualityScore > recommended.model.qualityScore
      }
    }
    return LocalModelRecommendations(assessments: assessments, recommended: recommended,
                                     faster: faster, smarter: smarter, allFamilies: allFamilies)
  }

  static func qualityOrder(_ lhs: LocalModelAssessment, _ rhs: LocalModelAssessment) -> Bool {
    if lhs.model.qualityScore != rhs.model.qualityScore {
      return lhs.model.qualityScore > rhs.model.qualityScore
    }
    if lhs.tokensPerSecond != rhs.tokensPerSecond { return lhs.tokensPerSecond > rhs.tokensPerSecond }
    return lhs.id < rhs.id
  }

  static func assess(
    _ model: LocalModelDescriptor, hardware: LocalHardwareProfile,
    measurements: [LocalModelBenchmark] = [], installed: Bool = false
  ) -> LocalModelAssessment {
    let usable = measurements.filter { $0.isApplicable(to: hardware) }
    let exact = usable.filter { $0.modelChecksum == model.checksumSHA256
      && $0.contextSize == model.recommendedContextSize }.max { $0.recordedAt < $1.recordedAt }
    let estimate = estimate(model, hardware: hardware,
      calibration: measurements.filter { $0.isApplicableForCalibration(to: hardware) })
    let speed = exact?.metrics.generationTokensPerSecond ?? estimate.speed
    let ttft = exact?.metrics.timeToFirstToken ?? estimate.ttft
    func result(_ fit: LocalModelFit, _ reason: String) -> LocalModelAssessment {
      LocalModelAssessment(model: model, fit: fit, reason: reason, tokensPerSecond: speed,
                           timeToFirstToken: ttft, isMeasured: exact != nil)
    }
    if model.resolvedProfile == .miniCPMO45 {
      return result(.unsupported, "MiniCPM-o 4.5 requires its dedicated runtime; its files can be downloaded for use in another app.")
    }
    guard model.supportsVision, (try? model.validate()) != nil, LocalModelCompatibility.supports(model) else {
      return result(.unsupported, "Requires an unsupported architecture, chat format, context, or llama.cpp build.")
    }
    // The bridge uses GPU offload when Metal exists. Discrete GPU memory needs
    // a separately validated policy; do not assume it is unified CPU memory.
    guard !hardware.hasMetal || (hardware.isAppleSilicon && hardware.hasUnifiedMemory) else {
      return result(.unsupported, "This catalog currently supports Apple unified-memory Metal or CPU inference.")
    }
    if hardware.hasMetal, let bufferLimit = hardware.metalMaximumBufferLength,
       model.largestTensorBytes > bufferLimit {
      return result(.unsupported, "This model requires larger Metal buffers than this Mac supports.")
    }
    // Installation copies the verified download before committing the library.
    let requiredDisk = model.downloadByteCount * 2 + 2 * LocalHardwareProfile.gib
    guard installed || hardware.availableDiskBytes >= requiredDisk else {
      return result(.disk, "Needs room for the download, installation copy, and 2 GB of free space.")
    }
    let runtimeMemory = max(model.estimatedRuntimeMemory, exact?.metrics.peakMemoryBytes ?? 0)
    guard hardware.physicalMemory >= model.minimumMemory,
          runtimeMemory <= hardware.inferenceMemoryBudget else {
      return result(.memory, "Does not leave enough memory for macOS and other apps.")
    }
    if speed < 8 || ttft > 5 { return result(.slow, "Fits in memory, but replies may take longer.") }
    let comfortable = runtimeMemory <= hardware.inferenceMemoryBudget * 4 / 5
      && hardware.physicalMemory >= model.recommendedMemory
    return result(comfortable ? .excellent : .good, "Fits with memory reserved for macOS.")
  }

  static let denseEfficiency = 0.75
  static let mixtureEfficiency = 0.45
  static let promptFactor = 1.3

  /// GB/s: the measured bandwidth when present (measured in the current power
  /// mode); otherwise a conservative prior from CPU resources, never chip names.
  static func bandwidth(for hardware: LocalHardwareProfile) -> Double {
    if let measured = hardware.measuredBandwidth { return measured }
    let cores = Double(max(1, min(hardware.performanceCPUCount, hardware.cpuCount)))
    let prior = hardware.hasMetal ? min(100, 18 + 5 * cores) : min(16, 2 * cores)
    return hardware.lowPowerMode ? prior * 0.65 : prior
  }

  /// The latest benchmark of the same kind (dense or mixture-of-experts),
  /// preferring the same architecture. Pass only calibration-applicable runs.
  static func calibration(for model: LocalModelDescriptor, from benchmarks: [LocalModelBenchmark]) -> LocalModelBenchmark? {
    let kind = benchmarks.filter { $0.calibrationIsMixtureOfExperts == model.isMixtureOfExperts }
    func latest(_ runs: [LocalModelBenchmark]) -> LocalModelBenchmark? { runs.max { $0.recordedAt < $1.recordedAt } }
    return latest(kind.filter { $0.architecture == model.architecture }) ?? latest(kind)
  }

  /// Decode is memory-bound: bandwidth × efficiency ÷ active weight bytes. A
  /// benchmark on this Mac replaces the starting efficiency and prompt factor.
  static func estimate(_ model: LocalModelDescriptor, hardware: LocalHardwareProfile,
                       calibration benchmarks: [LocalModelBenchmark]) -> (speed: Double, ttft: Double) {
    let bandwidth = bandwidth(for: hardware)
    var efficiency = model.isMixtureOfExperts ? mixtureEfficiency : denseEfficiency
    var factor = promptFactor
    if let run = calibration(for: model, from: benchmarks) {
      efficiency = run.metrics.generationTokensPerSecond * run.calibrationActiveWeightBytes / (bandwidth * 1e9)
      factor = run.metrics.promptTokensPerSecond * run.calibrationActiveParameterBillions / (bandwidth * 7)
    }
    let decode = bandwidth * 1e9 * efficiency / model.activeWeightBytes
    let prompt = factor * bandwidth * 7 / model.resolvedActiveParameterBillions
    return (decode, 256 / max(1, prompt) + 1 / max(0.1, decode))
  }
}
