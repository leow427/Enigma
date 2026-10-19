import Foundation

struct LocalBenchmarkMetrics: Codable, Sendable, Equatable {
  let timeToFirstToken: Double
  let generationTokensPerSecond: Double
  let promptTokensPerSecond: Double
  let peakMemoryBytes: Int64
  let promptTokenCount: Int
  let generatedTokenCount: Int
  let modelLoadSeconds: Double

  var isValid: Bool {
    [timeToFirstToken, generationTokensPerSecond, promptTokensPerSecond, modelLoadSeconds]
      .allSatisfy { $0.isFinite && $0 >= 0 }
      && timeToFirstToken > 0 && generationTokensPerSecond > 0 && promptTokensPerSecond > 0
      && peakMemoryBytes > 0 && promptTokenCount > 0 && generatedTokenCount >= 16
  }
}

struct LocalModelBenchmark: Codable, Sendable, Equatable {
  static let version = 1
  let version: Int
  let llamaBuild: Int
  let hardwareFingerprint: String
  let lowPowerMode: Bool
  let modelID: String
  let modelChecksum: String
  let modelByteCount: Int64
  let parameterBillions: Double
  let architecture: String
  let contextSize: Int
  let recordedAt: Date
  let metrics: LocalBenchmarkMetrics
  let predictedTokensPerSecond: Double
  let predictedTimeToFirstToken: Double
  // Absent from benchmarks saved before 0.11; see the calibration accessors.
  var activeParameterBillions: Double? = nil
  var isMixtureOfExperts: Bool? = nil

  var underperformed: Bool {
    metrics.generationTokensPerSecond < predictedTokensPerSecond * 0.6
      || metrics.timeToFirstToken > max(5, predictedTimeToFirstToken * 1.75)
  }

  func isApplicable(to hardware: LocalHardwareProfile, now: Date = .now) -> Bool {
    version == Self.version && llamaBuild == (LocalMultimodalProfile.allCases.contains { $0.architecture == architecture } ? LocalVisionRuntime.build : LocalModelCompatibility.llamaBuild)
      && hardwareFingerprint == hardware.fingerprint && lowPowerMode == hardware.lowPowerMode
      && recordedAt <= now && now.timeIntervalSince(recordedAt) < 90 * 86_400 && metrics.isValid
  }

  /// Efficiency belongs to the Mac, so calibration ignores the runtime build.
  /// Imported models (no size or parameters) never calibrate.
  func isApplicableForCalibration(to hardware: LocalHardwareProfile, now: Date = .now) -> Bool {
    version == Self.version && hardwareFingerprint == hardware.fingerprint && lowPowerMode == hardware.lowPowerMode
      && recordedAt <= now && now.timeIntervalSince(recordedAt) < 90 * 86_400 && metrics.isValid
      && modelByteCount > 0 && parameterBillions > 0
  }

  /// The bundled package's profile, else the profile with the same architecture
  /// and total parameters (packages that left the catalogue), else nil.
  var calibrationProfile: LocalMultimodalProfile? {
    if let bundled = BundledLocalModels.models.first(where: { $0.id == modelID })?.resolvedProfile { return bundled }
    return LocalMultimodalProfile.allCases.first { $0.architecture == architecture && $0.parameters == parameterBillions }
  }

  var calibrationActiveParameterBillions: Double {
    activeParameterBillions ?? calibrationProfile?.activeParameters ?? parameterBillions
  }

  var calibrationActiveWeightBytes: Double {
    let fraction: Double
    if let activeParameterBillions, parameterBillions > 0 {
      fraction = activeParameterBillions / parameterBillions
    } else if let profile = calibrationProfile {
      fraction = profile.activeParameters / profile.parameters
    } else {
      fraction = 1
    }
    return Double(modelByteCount) * fraction
  }

  var calibrationIsMixtureOfExperts: Bool {
    isMixtureOfExperts ?? calibrationProfile?.isMixtureOfExperts ?? false
  }
}
