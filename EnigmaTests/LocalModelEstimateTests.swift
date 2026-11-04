import XCTest
@testable import Enigma

final class LocalModelEstimateTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib

  func testCacheLayoutsMatchTheGGUFHeaders() {
    XCTAssertEqual(LocalMultimodalProfile.qwen35_2B.cacheLayout,
                   LocalCacheLayout(fullLayers: 6, fullKVHeads: 2, fullHeadDimension: 256))
    for profile in [LocalMultimodalProfile.qwen35_4B, .qwen35_9B, .bonsai2_4B, .bonsai2_9B] {
      XCTAssertEqual(profile.cacheLayout, LocalCacheLayout(fullLayers: 8, fullKVHeads: 4, fullHeadDimension: 256))
    }
    // Ternary Bonsai 2 27B: 64 blocks like Qwen3.8 27B but no multi-token-prediction layer.
    XCTAssertEqual(LocalMultimodalProfile.bonsai2_27B.cacheLayout,
                   LocalCacheLayout(fullLayers: 16, fullKVHeads: 4, fullHeadDimension: 256))
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
    // 60 blocks, every sixth global: 4 KV heads × 512 there, 16 × 256 in the sliding layers.
    XCTAssertEqual(LocalMultimodalProfile.gemma4_31B.cacheLayout,
                   LocalCacheLayout(fullLayers: 10, fullKVHeads: 4, fullHeadDimension: 512, slidingLayers: 50,
                                    slidingKVHeads: 16, slidingHeadDimension: 256, slidingWindow: 1024))
    XCTAssertEqual(LocalMultimodalProfile.ministral8B.cacheLayout,
                   LocalCacheLayout(fullLayers: 34, fullKVHeads: 8, fullHeadDimension: 128))
    XCTAssertEqual(LocalMultimodalProfile.ministral14B.cacheLayout,
                   LocalCacheLayout(fullLayers: 40, fullKVHeads: 8, fullHeadDimension: 128))
  }

  func testCacheBytesAtTheDefaultContext() {
    let expected: [(LocalMultimodalProfile, Int64)] = [
      (.qwen35_2B, 100_663_296), (.qwen35_4B, 268_435_456), (.qwen36_35BA3B, 184_549_376),
      (.qwen38_27B, 570_425_344), (.gemma4_12B, 805_306_368), (.gemma4A4B, 587_202_560),
      (.gemma4E4B, 308_281_344), (.gemma4_31B, 2_348_810_240), (.ministral8B, 1_140_850_688),
      (.ministral14B, 1_342_177_280), (.bonsai2_4B, 268_435_456), (.bonsai2_27B, 536_870_912),
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
      (.qwen36_35BA3B, 36), (.qwen38_27B, 27.8), (.bonsai2_4B, 4.66), (.bonsai2_9B, 9.65), (.bonsai2_27B, 27.8),
    ]
    for (profile, value) in parameters { XCTAssertEqual(profile.parameters, value, profile.rawValue) }
    let active: [LocalMultimodalProfile: Double] = [.gemma4A4B: 3.8, .qwen36_35BA3B: 3, .gemma4E4B: 4.5, .gemma4E2B: 2.3]
    for profile in LocalMultimodalProfile.allCases {
      XCTAssertEqual(profile.activeParameters, active[profile] ?? profile.parameters, profile.rawValue)
      XCTAssertEqual(profile.isMixtureOfExperts, profile == .gemma4A4B || profile == .qwen36_35BA3B, profile.rawValue)
      if profile.rawValue.hasPrefix("gemma4") {
        XCTAssertEqual(profile.quantizations, ["Q4_0", "Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "Q3_K_M", "IQ3_XXS"],
                       profile.rawValue)
      } else if profile == .qwen35_2B {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q8_0"])
      } else if profile == .qwen38_27B {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "IQ3_S", "IQ3_XXS"])
      } else if profile.rawValue.hasPrefix("bonsai2") {
        XCTAssertEqual(profile.quantizations, ["Q2_0"], profile.rawValue)
      } else if profile == .qwen35_9B || profile == .qwen36_35BA3B {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "Q3_K_M", "IQ3_XXS"],
                       profile.rawValue)
      } else {
        XCTAssertEqual(profile.quantizations, ["Q4_K_M", "Q5_K_M", "Q8_0"], profile.rawValue)
      }
      XCTAssertTrue(profile.quantizations.allSatisfy(LocalQuantization.precisionOrder.contains), profile.rawValue)
    }
    XCTAssertEqual(LocalMultimodalProfile.qwen35_2B.architecture, "qwen35")
    XCTAssertEqual(LocalMultimodalProfile.qwen38_27B.architecture, "qwen35")
    XCTAssertEqual(LocalMultimodalProfile.qwen36_35BA3B.architecture, "qwen35moe")
    for profile in [LocalMultimodalProfile.qwen35_2B, .qwen35_4B, .qwen35_9B, .qwen36_35BA3B, .qwen38_27B,
                    .bonsai2_4B, .bonsai2_9B, .bonsai2_27B] {
      XCTAssertEqual(profile.chatTemplate, "qwen3.5", profile.rawValue)
    }
    for profile in [LocalMultimodalProfile.bonsai2_4B, .bonsai2_9B, .bonsai2_27B] {
      XCTAssertEqual(profile.architecture, "qwen35", profile.rawValue)
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

  func testTernaryAndOrdinaryRunsNeverCalibrateEachOther() throws {
    let bonsai = record(id: "bonsai-2-4b-q2_0", architecture: "qwen35", bytes: 1_212_103_520, parameters: 4.66,
                        speed: 110, prompt: 650, build: 11734, recordedAt: .now - 600)
    XCTAssertEqual(try estimate("qwen3.5-4b-q8_0", [bonsai]).speed, try estimate("qwen3.5-4b-q8_0").speed)
    XCTAssertEqual(try estimate("qwen3.5-4b-q8_0", [bonsai, twelveQAT]).speed, 51.61, accuracy: 0.01)
    XCTAssertEqual(try estimate("bonsai-2-4b-q2_0", [twelveQAT]).speed, try estimate("bonsai-2-4b-q2_0").speed)
    XCTAssertEqual(try estimate("bonsai-2-9b-q2_0", [bonsai, twelveQAT]).speed,
                   110 * 1_212_103_520 / 2_556_640_128, accuracy: 0.01)
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


/// F35 CP2: the window each local model runs at.
final class LocalContextWindowTests: XCTestCase {
  /// The catalogue tests' Mac: about 3/5 of memory for inference, within 4/5 of Metal's working set.
  private func mac(_ gib: Int64) -> LocalHardwareProfile {
    let memory = gib * LocalHardwareProfile.gib
    let workingSet = Int64(Double(memory) * (gib <= 16 ? 2.0 / 3.0 : 0.74))
    return LocalHardwareProfile(physicalMemory: memory, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 500 * LocalHardwareProfile.gib, metalRecommendedWorkingSet: workingSet,
      metalMaximumBufferLength: workingSet * 3 / 4, lowPowerMode: false)
  }

  private func package(_ id: String) throws -> LocalModelDescriptor {
    try XCTUnwrap(BundledLocalModels.models.first { $0.id == id }, id)
  }

  private func installed(_ descriptor: LocalModelDescriptor) -> LocalModel {
    LocalModel(id: descriptor.id, displayName: descriptor.displayName, fileURL: URL(fileURLWithPath: "/tmp/m.gguf"),
               catalogDescriptor: descriptor)
  }

  func testAutomaticPicksLargestThatFitsMemory() throws {
    // Comfortable lines: 8 GB 3.4 GB, 16 GB 7.3 GB, 24 GB 12.2 GB, 36 GB 18.3 GB, 64 GB 32.5 GB.
    let small = try package("qwen3.5-2b-q4_k_m")
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: small, hardware: mac(16)), 32_768)
    let ministral = try package("ministral-3-8b-q4_k_m")   // 8.8 GB at 8K, 9.9 at 16K, 12.2 at 32K
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: ministral, hardware: mac(16)), 8_192)
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: ministral, hardware: mac(24)), 16_384)
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: ministral, hardware: mac(36)), 32_768)
    let large = try package("gemma-4-31b-iq3_xxs")         // 18.7 GB at 8K, 20.7 at 32K
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: large, hardware: mac(36)), 8_192)
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: large, hardware: mac(64)), 32_768)
    // A larger window never makes a model uncomfortable.
    for descriptor in BundledLocalModels.models {
      for gib: Int64 in [8, 16, 24, 36, 64] {
        let hardware = mac(gib)
        let size = LocalContextWindowChoice.automatic(for: descriptor, hardware: hardware)
        guard size > 8_192 else { continue }
        let memory = try XCTUnwrap(LocalContextWindowChoice.memory(descriptor, size: size))
        XCTAssertLessThanOrEqual(memory, hardware.inferenceMemoryBudget * 4 / 5, "\(descriptor.id) on \(gib) GB")
      }
    }
  }

  func testAutomaticRespectsTrainedMaximum() throws {
    var ministral = try package("ministral-3-8b-q4_k_m")
    ministral.trainedContextLength = 16_384
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: ministral, hardware: mac(64)), 16_384)
    // An installed record saved before the field reads the bundled package's.
    ministral.trainedContextLength = nil
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: ministral, hardware: mac(64)), 32_768)
    // Unknown anywhere: 8,192.
    let unknown = LocalModelDescriptor(id: "other", displayName: ministral.displayName, downloadURL: ministral.downloadURL,
      expectedByteCount: ministral.expectedByteCount, license: ministral.license, checksumSHA256: String(repeating: "c", count: 64),
      revision: ministral.revision, quantization: ministral.quantization, architecture: ministral.architecture,
      chatTemplate: ministral.chatTemplate, minimumLlamaBuild: ministral.minimumLlamaBuild,
      estimatedRuntimeMemory: ministral.estimatedRuntimeMemory, largestTensorBytes: ministral.largestTensorBytes,
      recommendedContextSize: 8_192, qualityScore: 1, performanceClass: "Vision", parameterBillions: ministral.parameterBillions,
      minimumMemory: ministral.minimumMemory, recommendedMemory: ministral.recommendedMemory, projector: ministral.projector,
      runtimeBuild: ministral.runtimeBuild, inferenceProfile: ministral.inferenceProfile)
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: unknown, hardware: mac(64)), 8_192)
  }

  func testAutomaticNeverBelow8KForCatalogueModels() throws {
    for descriptor in BundledLocalModels.models {
      XCTAssertGreaterThanOrEqual(LocalContextWindowChoice.automatic(for: descriptor, hardware: mac(8)), 8_192, descriptor.id)
    }
    // Over the comfortable line even at 8K, it stays at 8K.
    XCTAssertEqual(LocalContextWindowChoice.automatic(for: try package("gemma-4-31b-iq3_xxs"), hardware: mac(8)), 8_192)
  }

  func testPresetsDisabledByTrainedMaximum() throws {
    var model = try package("qwen3.5-2b-q4_k_m")
    model.trainedContextLength = 16_384
    let sizes = LocalContextWindowPreference.allCases.map {
      LocalContextWindowChoice.size(for: $0, model: installed(model), hardware: mac(64))
    }
    XCTAssertEqual(sizes, [nil, 16_384, 16_384, nil])
    model.trainedContextLength = 8_192
    XCTAssertEqual(LocalContextWindowChoice.size(for: .larger, model: installed(model), hardware: mac(64)), nil)
    // Memory rules a size out too: over the whole inference budget (9.2 GB on 16 GB).
    let ministral = installed(try package("ministral-3-8b-q4_k_m"))
    XCTAssertEqual(LocalContextWindowPreference.allCases.map {
      LocalContextWindowChoice.size(for: $0, model: ministral, hardware: mac(16))
    }, [nil, 8_192, nil, nil])
    // Under a ruled-out preference, the runtime uses Automatic.
    XCTAssertEqual(LocalContextWindowChoice.runtimeSize(for: try package("ministral-3-8b-q4_k_m"), preference: .maximum,
                                                        accepted: "", hardware: mac(16)), 8_192)
    // An imported model keeps its own window, and the presets are ruled out.
    let imported = LocalModel(id: "imported", displayName: "Imported", fileURL: URL(fileURLWithPath: "/tmp/i.gguf"))
    XCTAssertEqual(LocalContextWindowPreference.allCases.map {
      LocalContextWindowChoice.size(for: $0, model: imported, hardware: mac(64))
    }, [nil, 4_096, nil, nil])
  }

  /// A screenshot's image tokens don't fit in 4K, so only text packages offer Smaller.
  func testSmallerIsOnlyForTextPackages() throws {
    var model = try package("qwen3.5-2b-q4_k_m")
    XCTAssertNil(LocalContextWindowChoice.size(for: .smaller, model: installed(model), hardware: mac(64)))
    model.projector = nil
    XCTAssertEqual(LocalContextWindowChoice.size(for: .smaller, model: installed(model), hardware: mac(64)), 4_096)
  }

  /// The preset is global: a model whose warning wasn't answered Use It runs at Automatic.
  func testUnansweredWarningRunsAtAutomatic() throws {
    let ministral = try package("ministral-3-8b-q4_k_m")
    XCTAssertEqual(LocalContextWindowChoice.runtimeSize(for: ministral, preference: .maximum, accepted: "", hardware: mac(24)), 16_384)
    let accepted = LocalContextWindowPreference.accepting(.maximum, modelID: ministral.id, in: "other=larger")
    XCTAssertEqual(accepted, "other=larger\n\(ministral.id)=maximum")
    XCTAssertEqual(LocalContextWindowPreference.accepting(.maximum, modelID: ministral.id, in: accepted), accepted)
    XCTAssertEqual(LocalContextWindowChoice.runtimeSize(for: ministral, preference: .maximum, accepted: accepted, hardware: mac(24)), 32_768)
    // Use It for one preset doesn't answer another.
    XCTAssertFalse(LocalContextWindowPreference.isAccepted(.larger, modelID: ministral.id, in: accepted))
  }

  func testWarningWhenPresetIsOverComfortableMemory() throws {
    // On 24 GB: 32K needs 12.23 GB, over the 12.20 comfortable line but within the 15.3 budget.
    let ministral = installed(try package("ministral-3-8b-q4_k_m"))
    XCTAssertTrue(LocalContextWindowChoice.needsWarning(.maximum, model: ministral, hardware: mac(24)))
    XCTAssertFalse(LocalContextWindowChoice.needsWarning(.larger, model: ministral, hardware: mac(24)))
    XCTAssertFalse(LocalContextWindowChoice.needsWarning(.automatic, model: ministral, hardware: mac(24)))
    XCTAssertFalse(LocalContextWindowChoice.needsWarning(.maximum, model: ministral, hardware: mac(36)))
    // A ruled-out preset is disabled, not warned about.
    XCTAssertFalse(LocalContextWindowChoice.needsWarning(.maximum, model: ministral, hardware: mac(16)))
    // Over the line already at 8K, a smaller size uses less, so it doesn't warn; a larger one does.
    let large = installed(try package("gemma-4-31b-iq3_xxs"))
    var textOnly = try package("gemma-4-31b-iq3_xxs")
    textOnly.projector = nil
    XCTAssertFalse(LocalContextWindowChoice.needsWarning(.smaller, model: installed(textOnly), hardware: mac(36)))
    XCTAssertTrue(LocalContextWindowChoice.needsWarning(.larger, model: large, hardware: mac(36)))
  }

  func testPresetLabels() {
    XCTAssertEqual(LocalContextWindowPreference.allCases.map(\.title), ["Smaller (4K)", "Automatic", "Larger (16K)", "Max (32K)"])
    XCTAssertEqual(LocalContextWindowPreference.allCases.map(\.fixedSize), [4_096, nil, 16_384, 32_768])
    let defaults = UserDefaults(suiteName: "LocalContextWindowTests")!
    defaults.removePersistentDomain(forName: "LocalContextWindowTests")
    XCTAssertEqual(LocalContextWindowPreference.saved(in: defaults), .automatic)
    defaults.set("maximum", forKey: LocalContextWindowPreference.key)
    XCTAssertEqual(LocalContextWindowPreference.saved(in: defaults), .maximum)
    defaults.removePersistentDomain(forName: "LocalContextWindowTests")
  }
}
