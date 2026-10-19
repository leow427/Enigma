import XCTest
@testable import Enigma

final class LocalModelEstimateTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib

  func testCacheLayoutsMatchTheGGUFHeaders() {
    XCTAssertEqual(LocalMultimodalProfile.qwen35_2B.cacheLayout,
                   LocalCacheLayout(fullLayers: 6, fullKVHeads: 2, fullHeadDimension: 256))
    for profile in [LocalMultimodalProfile.qwen35_4B, .qwen35_9B] {
      XCTAssertEqual(profile.cacheLayout, LocalCacheLayout(fullLayers: 8, fullKVHeads: 4, fullHeadDimension: 256))
    }
    XCTAssertEqual(LocalMultimodalProfile.qwen36_35BA3B.cacheLayout,
                   LocalCacheLayout(fullLayers: 11, fullKVHeads: 2, fullHeadDimension: 256))
    XCTAssertEqual(LocalMultimodalProfile.qwen38_27B.cacheLayout,
                   LocalCacheLayout(fullLayers: 17, fullKVHeads: 4, fullHeadDimension: 256))
    XCTAssertEqual(LocalMultimodalProfile.gemma4_12B.cacheLayout,
                   LocalCacheLayout(fullLayers: 8, fullKVHeads: 1, fullHeadDimension: 512, slidingLayers: 40,
                                    slidingKVHeads: 8, slidingHeadDimension: 256, slidingWindow: 1024))
    XCTAssertEqual(LocalMultimodalProfile.gemma4A4B.cacheLayout,
                   LocalCacheLayout(fullLayers: 5, fullKVHeads: 2, fullHeadDimension: 512, slidingLayers: 25,
                                    slidingKVHeads: 8, slidingHeadDimension: 256, slidingWindow: 1024))
    XCTAssertEqual(LocalMultimodalProfile.gemma4E4B.cacheLayout,
                   LocalCacheLayout(fullLayers: 7, fullKVHeads: 2, fullHeadDimension: 512, slidingLayers: 35,
                                    slidingKVHeads: 2, slidingHeadDimension: 256, slidingWindow: 512))
  }

  func testCacheBytesAtTheDefaultContext() {
    let expected: [(LocalMultimodalProfile, Int64)] = [
      (.qwen35_2B, 100_663_296), (.qwen35_4B, 268_435_456), (.qwen36_35BA3B, 184_549_376),
      (.qwen38_27B, 570_425_344), (.gemma4_12B, 805_306_368), (.gemma4A4B, 587_202_560),
      (.gemma4E4B, 308_281_344),
    ]
    for (profile, bytes) in expected {
      XCTAssertEqual(profile.cacheLayout.bytes(context: 8192, physicalBatch: profile.physicalBatchSize), bytes,
                     profile.rawValue)
    }
    XCTAssertEqual(LocalMultimodalProfile.gemma4_12B.cacheLayout.bytes(context: 4096, physicalBatch: 1024),
                   738_197_504)
  }

  func testSlidingLayersFollowThePhysicalBatch() {
    let gemma = LocalMultimodalProfile.gemma4_12B.cacheLayout
    XCTAssertEqual(gemma.bytes(context: 8192, physicalBatch: 512), 637_534_208)
    XCTAssertEqual(gemma.bytes(context: 8192, physicalBatch: 1024), 805_306_368)
    let qwen = LocalMultimodalProfile.qwen35_4B.cacheLayout
    XCTAssertEqual(qwen.bytes(context: 8192, physicalBatch: 512), 2 * qwen.bytes(context: 4096, physicalBatch: 512))
  }

  func testGemmaImageBatchAndReserve() {
    let nonCausal: Set<LocalMultimodalProfile> = [.gemma4_12B, .gemma4A4B, .gemma4_31B]
    for profile in LocalMultimodalProfile.allCases {
      XCTAssertEqual(profile.usesNonCausalImageAttention, nonCausal.contains(profile), profile.rawValue)
    }
    for profile in nonCausal {
      XCTAssertEqual(profile.physicalBatchSize, 1024)
      XCTAssertEqual(profile.imageMaxTokens, 1024)
    }
    XCTAssertEqual(LocalMultimodalProfile.qwen35_4B.physicalBatchSize, 512)
    XCTAssertEqual(LocalMultimodalProfile.qwen35_4B.imageMaxTokens, 4096)
    XCTAssertEqual(LocalMultimodalProfile.gemma4_12B.runtimeReserve, 2_147_483_648)
    XCTAssertEqual(LocalMultimodalProfile.qwen35_4B.runtimeReserve, 1_610_612_736)
    XCTAssertEqual(LocalMultimodalProfile.gemma4E4B.runtimeReserve, 1_610_612_736)
  }

  func testEstimatesCoverTheRecordedPeaks() {
    let twelve = LocalMultimodalProfile.gemma4_12B.memory(weights: 6_975_879_296, projector: 175_115_616, context: 8192)
    XCTAssertEqual(twelve, 10_103_784_928)
    XCTAssertGreaterThanOrEqual(twelve, 9_206_136_832)
    XCTAssertLessThanOrEqual(Double(twelve), 9_206_136_832 * 1.25)
    let e4b = LocalMultimodalProfile.gemma4E4B.memory(weights: 5_154_941_280, projector: 991_552_256, context: 8192)
    XCTAssertEqual(e4b, 8_065_387_616)
    XCTAssertGreaterThanOrEqual(e4b, 7_132_168_192)
    XCTAssertLessThanOrEqual(Double(e4b), 7_132_168_192 * 1.25)
  }

  func testWeightsAndProjectorCountOnce() {
    for profile in LocalMultimodalProfile.allCases {
      let base = profile.memory(weights: 4 * gib, projector: gib, context: 8192)
      XCTAssertEqual(profile.memory(weights: 5 * gib, projector: gib, context: 8192), base + gib)
      XCTAssertEqual(profile.memory(weights: 4 * gib, projector: 2 * gib, context: 8192), base + gib)
    }
  }

  func testParametersKindsAndFormats() {
    let parameters: [(LocalMultimodalProfile, Double)] = [
      (.qwen35_2B, 2.27), (.qwen35_4B, 4.66), (.qwen35_9B, 9.65), (.gemma4_12B, 12), (.gemma4A4B, 25.2),
      (.qwen36_35BA3B, 36), (.qwen38_27B, 27.8),
    ]
    for (profile, value) in parameters { XCTAssertEqual(profile.parameters, value, profile.rawValue) }
    let active: [LocalMultimodalProfile: Double] = [.gemma4A4B: 3.8, .qwen36_35BA3B: 3, .gemma4E4B: 4.5, .gemma4E2B: 2.3]
    for profile in LocalMultimodalProfile.allCases {
      XCTAssertEqual(profile.activeParameters, active[profile] ?? profile.parameters, profile.rawValue)
      XCTAssertEqual(profile.isMixtureOfExperts, profile == .gemma4A4B || profile == .qwen36_35BA3B, profile.rawValue)
      if profile.rawValue.hasPrefix("gemma4") {
        XCTAssertEqual(profile.quantizations, ["Q4_0", "Q4_K_M", "Q5_K_M", "Q8_0"], profile.rawValue)
      } else if profile == .qwen35_2B {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q8_0"])
      } else {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q5_K_M", "Q8_0"], profile.rawValue)
      }
    }
    XCTAssertEqual(LocalMultimodalProfile.qwen35_2B.architecture, "qwen35")
    XCTAssertEqual(LocalMultimodalProfile.qwen38_27B.architecture, "qwen35")
    XCTAssertEqual(LocalMultimodalProfile.qwen36_35BA3B.architecture, "qwen35moe")
    for profile in [LocalMultimodalProfile.qwen35_2B, .qwen35_4B, .qwen35_9B, .qwen36_35BA3B, .qwen38_27B] {
      XCTAssertEqual(profile.chatTemplate, "qwen3.5", profile.rawValue)
    }
  }

  // MARK: Speed estimates

  private var ownersMac: LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: 25_769_803_776, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Apple M5 Pro", device: "Mac17,9", cpuCount: 18, performanceCPUCount: 6,
      availableDiskBytes: 500 * gib, metalRecommendedWorkingSet: 19_069_665_280,
      metalMaximumBufferLength: 14_302_248_960, lowPowerMode: false, measuredBandwidth: 267)
  }

  private func package(_ id: String) throws -> LocalModelDescriptor {
    try XCTUnwrap(LocalModelManifest.bundled.models.first { $0.id == id }, id)
  }

  private func record(id: String, architecture: String, bytes: Int64, parameters: Double, speed: Double,
                      prompt: Double, build: Int, recordedAt: Date, checksum: String? = nil,
                      context: Int = 8192) -> LocalModelBenchmark {
    LocalModelBenchmark(version: 1, llamaBuild: build, hardwareFingerprint: ownersMac.fingerprint, lowPowerMode: false,
      modelID: id, modelChecksum: checksum ?? String(repeating: "a", count: 64), modelByteCount: bytes,
      parameterBillions: parameters, architecture: architecture, contextSize: context, recordedAt: recordedAt,
      metrics: LocalBenchmarkMetrics(timeToFirstToken: 0.8, generationTokensPerSecond: speed,
        promptTokensPerSecond: prompt, peakMemoryBytes: 9_206_136_832, promptTokenCount: 140,
        generatedTokenCount: 64, modelLoadSeconds: 2),
      predictedTokensPerSecond: speed, predictedTimeToFirstToken: 0.8)
  }

  private var twelveQAT: LocalModelBenchmark {
    record(id: "gemma-4-12b-it-qat-q4_0-gguf", architecture: "gemma4", bytes: 6_975_879_296, parameters: 12,
           speed: 33.16531329376308, prompt: 234.52804679524323, build: 10797, recordedAt: .now - 3_600)
  }

  private var e4bQAT: LocalModelBenchmark {
    record(id: "gemma-4-e4b-it-qat-q4_0-gguf", architecture: "gemma4", bytes: 5_154_941_280, parameters: 7.5,
           speed: 67.19727627040184, prompt: 136.2804710085045, build: 10797, recordedAt: .now - 7_200)
  }

  private func estimate(_ id: String, on mac: LocalHardwareProfile? = nil,
                        _ runs: [LocalModelBenchmark] = []) throws -> (speed: Double, ttft: Double) {
    let mac = mac ?? ownersMac
    return LocalModelSelector.estimate(try package(id), hardware: mac,
      calibration: runs.filter { $0.isApplicableForCalibration(to: mac) })
  }

  func testDenseEstimateUsesMeasuredBandwidth() throws {
    let result = try estimate("gemma-4-12b-q5_k_m")
    XCTAssertEqual(result.speed, 23.80, accuracy: 0.01)
    XCTAssertEqual(result.ttft, 1.31, accuracy: 0.01)
  }

  func testMixtureOfExpertsReadsOnlyActiveWeights() throws {
    let result = try estimate("gemma-4-26b-a4b-q4_k_m")
    XCTAssertEqual(result.speed, 46.77, accuracy: 0.01)
    XCTAssertEqual(result.ttft, 0.42, accuracy: 0.01)
    XCTAssertEqual(try package("gemma-4-26b-a4b-q4_k_m").activeWeightBytes, 17_035_039_872 * 3.8 / 25.2, accuracy: 1)
    XCTAssertTrue(try package("gemma-4-26b-a4b-q4_k_m").isMixtureOfExperts)
  }

  func testMeasuredRunCalibratesEveryDenseModelWithoutACap() throws {
    let twelve = try estimate("gemma-4-12b-q5_k_m", [twelveQAT])
    XCTAssertEqual(twelve.speed, 27.50, accuracy: 0.01)
    XCTAssertEqual(twelve.ttft, 1.13, accuracy: 0.01)
    XCTAssertEqual(try estimate("qwen3.5-4b-q8_0", [twelveQAT]).speed, 51.61, accuracy: 0.01)
    XCTAssertEqual(try estimate("gemma-4-26b-a4b-q4_k_m", [twelveQAT]).speed, 46.77, accuracy: 0.01)
    var unmeasured = ownersMac
    unmeasured.measuredBandwidth = nil
    XCTAssertEqual(try estimate("gemma-4-12b-q5_k_m", on: unmeasured, [twelveQAT]).speed, 27.50, accuracy: 0.01)
  }

  func testSameArchitectureIsPreferred() throws {
    let qwen = record(id: "qwen3.5-4b-q5_k_m", architecture: "qwen35", bytes: 3_143_656_608, parameters: 4,
                      speed: 63.0, prompt: 300, build: 10797, recordedAt: .now - 60)
    XCTAssertEqual(try estimate("gemma-4-12b-q5_k_m", [twelveQAT, qwen]).speed, 27.50, accuracy: 0.01)
    XCTAssertEqual(try estimate("qwen3.5-4b-q8_0", [twelveQAT, qwen]).speed,
                   63.0 * 3_143_656_608 / 4_482_403_488, accuracy: 0.01)
    XCTAssertEqual(try estimate("qwen3.5-4b-q8_0", [twelveQAT, qwen]).speed, 44.18, accuracy: 0.01)
  }

  func testGemmaEModelsCalibrateFromEffectiveParameters() throws {
    XCTAssertEqual(try estimate("gemma-4-12b-q5_k_m", [e4bQAT]).speed, 24.70, accuracy: 0.01)
  }

  func testExactMeasurementNeedsTheCurrentRuntime() throws {
    let model = try package("gemma-4-12b-q5_k_m")
    let old = record(id: model.id, architecture: "gemma4", bytes: model.expectedByteCount,
                     parameters: model.parameterBillions, speed: 30, prompt: 250, build: 10797,
                     recordedAt: .now - 60, checksum: model.checksumSHA256)
    let stale = LocalModelSelector.assess(model, hardware: ownersMac, measurements: [old])
    XCTAssertFalse(stale.isMeasured)
    XCTAssertEqual(stale.tokensPerSecond, 30.00, accuracy: 0.01)
    let current = record(id: model.id, architecture: "gemma4", bytes: model.expectedByteCount,
                         parameters: model.parameterBillions, speed: 30, prompt: 250, build: LocalVisionRuntime.build,
                         recordedAt: .now - 60, checksum: model.checksumSHA256)
    let exact = LocalModelSelector.assess(model, hardware: ownersMac, measurements: [current])
    XCTAssertTrue(exact.isMeasured)
    XCTAssertEqual(exact.tokensPerSecond, 30)
  }

  func testImportedModelBenchmarksNeverCalibrate() throws {
    let imported = record(id: "imported", architecture: "unverified", bytes: 0, parameters: 0, speed: 50,
                          prompt: 400, build: LocalModelCompatibility.llamaBuild, recordedAt: .now - 60,
                          checksum: "unverified-import")
    XCTAssertFalse(imported.isApplicableForCalibration(to: ownersMac))
    let model = try package("gemma-4-12b-q5_k_m")
    let assessed = LocalModelSelector.assess(model, hardware: ownersMac, measurements: [imported])
    XCTAssertEqual(assessed.tokensPerSecond, 23.80, accuracy: 0.01)
    XCTAssertTrue(assessed.tokensPerSecond.isFinite && assessed.timeToFirstToken.isFinite)
  }

  func testPriorBandwidthWithoutAMeasurement() {
    var mac = ownersMac
    mac.measuredBandwidth = nil
    XCTAssertEqual(LocalModelSelector.bandwidth(for: mac), 48)
    mac.lowPowerMode = true
    XCTAssertEqual(LocalModelSelector.bandwidth(for: mac), 31.2, accuracy: 0.0001)
    mac.measuredBandwidth = 200
    XCTAssertEqual(LocalModelSelector.bandwidth(for: mac), 200)
    var cpu = ownersMac
    cpu.measuredBandwidth = nil
    cpu.hasMetal = false
    XCTAssertEqual(LocalModelSelector.bandwidth(for: cpu), 12)
  }

  func testOldBenchmarksDecode() throws {
    for (run, active) in [(twelveQAT, 12.0), (e4bQAT, 4.5)] {
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
      json.removeValue(forKey: "activeParameterBillions")
      json.removeValue(forKey: "isMixtureOfExperts")
      let restored = try JSONDecoder().decode(LocalModelBenchmark.self, from: JSONSerialization.data(withJSONObject: json))
      XCTAssertNil(restored.activeParameterBillions)
      XCTAssertEqual(restored.calibrationActiveParameterBillions, active, accuracy: 0.0001)
      XCTAssertFalse(restored.calibrationIsMixtureOfExperts)
    }
  }

  func testSpeedGates() throws {
    XCTAssertTrue(LocalModelSelector.assess(try package("gemma-4-12b-q5_k_m"), hardware: ownersMac).isFast)
    var slow = ownersMac
    slow.measuredBandwidth = 60
    let twelve = LocalModelSelector.assess(try package("gemma-4-12b-q5_k_m"), hardware: slow)
    XCTAssertEqual(twelve.tokensPerSecond, 5.35, accuracy: 0.01)
    XCTAssertFalse(twelve.isFast)
    XCTAssertFalse(twelve.isUsable)
    let four = LocalModelSelector.assess(try package("qwen3.5-4b-q5_k_m"), hardware: slow)
    XCTAssertEqual(four.tokensPerSecond, 14.31, accuracy: 0.01)
    XCTAssertTrue(four.isUsable)
    XCTAssertFalse(four.isFast)
  }
}
