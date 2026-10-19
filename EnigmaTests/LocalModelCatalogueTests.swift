import XCTest
@testable import Enigma

final class LocalModelCatalogueTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib
  private var models: [LocalModelDescriptor] { BundledLocalModels.models }

  private func mac(memoryGiB: Int, publishedBandwidth: Double) -> LocalHardwareProfile {
    let memory = Int64(memoryGiB) * gib
    let workingSet = Int64(Double(memory) * (memoryGiB <= 16 ? 2.0 / 3.0 : 0.74))
    return LocalHardwareProfile(physicalMemory: memory, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 500 * gib, metalRecommendedWorkingSet: workingSet,
      metalMaximumBufferLength: workingSet * 3 / 4, lowPowerMode: false,
      measuredBandwidth: publishedBandwidth * 0.87)
  }

  private var ownersMac: LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: 25_769_803_776, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Apple M5 Pro", device: "Mac17,9", cpuCount: 18, performanceCPUCount: 6,
      availableDiskBytes: 500 * gib, metalRecommendedWorkingSet: 19_069_665_280,
      metalMaximumBufferLength: 14_302_248_960, lowPowerMode: false, measuredBandwidth: 267)
  }

  private func ownersRun(id: String, bytes: Int64, parameters: Double, speed: Double, prompt: Double,
                         age: TimeInterval) -> LocalModelBenchmark {
    LocalModelBenchmark(version: 1, llamaBuild: 10797, hardwareFingerprint: ownersMac.fingerprint, lowPowerMode: false,
      modelID: id, modelChecksum: String(repeating: "b", count: 64), modelByteCount: bytes,
      parameterBillions: parameters, architecture: "gemma4", contextSize: 8192, recordedAt: .now - age,
      metrics: LocalBenchmarkMetrics(timeToFirstToken: 0.8, generationTokensPerSecond: speed,
        promptTokensPerSecond: prompt, peakMemoryBytes: 9_206_136_832, promptTokenCount: 140,
        generatedTokenCount: 64, modelLoadSeconds: 2),
      predictedTokensPerSecond: speed, predictedTimeToFirstToken: 0.8)
  }

  func testCatalogueHasSevenFamiliesAndThirtyFivePackages() throws {
    XCTAssertEqual(BundledLocalModels.families.map(\.name),
                   ["Qwen3.5 2B", "Qwen3.5 4B", "Qwen3.5 9B", "Gemma 4 12B", "Gemma 4 26B-A4B", "Qwen3.6 35B-A3B",
                    "Qwen3.8 27B"])
    XCTAssertEqual(models.count, 35)
    try LocalModelManifest.bundled.validate()
    XCTAssertEqual(Set(models.map(\.id)).count, 35)
    XCTAssertEqual(Set(models.map(\.checksumSHA256)).count, 35)
    XCTAssertEqual(LocalModelManifest.bundled.version, 6)
    XCTAssertEqual(LocalVisionModelDescriptor.bundled.count, 35)
  }

  func testEveryPackageIsRunnable() throws {
    for model in models {
      let profile = try XCTUnwrap(model.inferenceProfile, model.id)
      XCTAssertTrue(LocalModelCompatibility.supports(model), model.id)
      try model.validate()
      XCTAssertTrue(profile.quantizations.contains(model.quantization), model.id)
      XCTAssertTrue(model.downloadURL.lastPathComponent.contains(model.quantization), model.id)
      XCTAssertEqual(model.activeParameterBillions, profile.activeParameters, model.id)
      XCTAssertEqual(model.runtimeBuild, LocalVisionRuntime.build, model.id)
      XCTAssertLessThan(model.largestTensorBytes, 14_302_248_960, model.id)
      XCTAssertTrue(model.supportsVision, model.id)
      XCTAssertTrue(model.summary.hasSuffix("."), model.id)
      XCTAssertLessThanOrEqual(model.summary.count, 300, model.id)
      XCTAssertEqual(model.downloadURL.pathComponents[4], model.revision, model.id)
      if model.modelSupportsAudio == true {
        XCTAssertTrue(model.performanceClass.contains("Text and images in Enigma"), model.id)
      }
    }
  }

  func testLargerFamiliesShipThreeBitAndIQ4Sizes() throws {
    let expected: [(String, String, String, Int64)] = [
      ("qwen3.5-9b-iq3_xxs", "IQ3_XXS", "Qwen3.5-9B-UD-IQ3_XXS.gguf", 4_016_235_744),
      ("qwen3.5-9b-q3_k_m", "Q3_K_M", "Qwen3.5-9B-Q3_K_M.gguf", 4_673_643_744),
      ("qwen3.5-9b-iq4_xs", "IQ4_XS", "Qwen3.5-9B-IQ4_XS.gguf", 5_168_653_536),
      ("gemma-4-12b-iq3_xxs", "IQ3_XXS", "gemma-4-12b-it-UD-IQ3_XXS.gguf", 4_639_716_160),
      ("gemma-4-12b-q3_k_m", "Q3_K_M", "gemma-4-12b-it-Q3_K_M.gguf", 5_693_872_960),
      ("gemma-4-12b-iq4_xs", "IQ4_XS", "gemma-4-12b-it-IQ4_XS.gguf", 6_375_734_080),
      ("gemma-4-26b-a4b-iq3_xxs", "IQ3_XXS", "google_gemma-4-26B-A4B-it-IQ3_XXS.gguf", 12_160_200_320),
      ("gemma-4-26b-a4b-q3_k_m", "Q3_K_M", "google_gemma-4-26B-A4B-it-Q3_K_M.gguf", 13_019_981_440),
      ("gemma-4-26b-a4b-iq4_xs", "IQ4_XS", "google_gemma-4-26B-A4B-it-IQ4_XS.gguf", 14_205_004_928),
      ("qwen3.6-35b-a3b-iq3_xxs", "IQ3_XXS", "Qwen_Qwen3.6-35B-A3B-IQ3_XXS.gguf", 15_761_446_528),
      ("qwen3.6-35b-a3b-q3_k_m", "Q3_K_M", "Qwen_Qwen3.6-35B-A3B-Q3_K_M.gguf", 17_117_951_616),
      ("qwen3.6-35b-a3b-iq4_xs", "IQ4_XS", "Qwen_Qwen3.6-35B-A3B-IQ4_XS.gguf", 19_699_553_920),
      ("qwen3.8-27b-iq3_xxs", "IQ3_XXS", "Qwen3.8-27B-UD-IQ3_XXS.gguf", 10_934_860_704),
      ("qwen3.8-27b-iq3_s", "IQ3_S", "Qwen3.8-27B-UD-IQ3_S.gguf", 12_040_883_104),
      ("qwen3.8-27b-iq4_xs", "IQ4_XS", "Qwen3.8-27B-UD-IQ4_XS.gguf", 14_252_845_984),
    ]
    for (id, quantization, file, bytes) in expected {
      let model = try XCTUnwrap(models.first { $0.id == id }, id)
      XCTAssertEqual(model.quantization, quantization, id)
      XCTAssertEqual(model.downloadURL.lastPathComponent, file, id)
      XCTAssertEqual(model.expectedByteCount, bytes, id)
      XCTAssertTrue(LocalModelCompatibility.supports(model), id)
      XCTAssertEqual(LocalQuantization.qualityFactor(quantization), quantization.hasPrefix("IQ4") ? 0.96 : 0.85, id)
    }
  }

  func testExistingPackagesKeepTheirIDsAndPins() throws {
    let pins: [(String, String, String)] = [
      ("qwen3.5-4b-q4_k_m", "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", "e87f176479d0855a907a41277aca2f8ee7a09523"),
      ("qwen3.5-4b-q5_k_m", "8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39", "e87f176479d0855a907a41277aca2f8ee7a09523"),
      ("qwen3.5-4b-q8_0", "10cc391b403021dd11c614679d2fd92f611c3681d29e29651b717316965d61e1", "e87f176479d0855a907a41277aca2f8ee7a09523"),
      ("qwen3.5-9b-q5_k_m", "dc2a39aef291f91a9116ad214058da0d86eb648743a124bd8c333787c4b9c91c", "3885219b6810b007914f3a7950a8d1b469d598a5"),
      ("gemma-4-12b-q5_k_m", "32c554c7d1338a23837ae39b3db482213a4a642f96df3b2619f516a2375d16cd", "fc034cfff751157913579611efad8462ac1be606"),
      ("gemma-4-26b-a4b-q4_k_m", "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a", "10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d"),
    ]
    for (id, checksum, revision) in pins {
      let model = try XCTUnwrap(models.first { $0.id == id }, id)
      XCTAssertEqual(model.checksumSHA256, checksum, id)
      XCTAssertEqual(model.revision, revision, id)
    }
  }

  func testFamilyMetadataIsConsistent() throws {
    let stems = ["qwen3.5-2b-", "qwen3.5-4b-", "qwen3.5-9b-", "gemma-4-12b-", "gemma-4-26b-a4b-", "qwen3.6-35b-a3b-",
                 "qwen3.8-27b-"]
    for (family, stem) in zip(BundledLocalModels.families, stems) {
      let descriptors = family.descriptors
      let first = try XCTUnwrap(descriptors.first)
      for model in descriptors {
        XCTAssertEqual(model.displayName, first.displayName)
        XCTAssertEqual(model.publisher, first.publisher)
        XCTAssertEqual(model.license, first.license)
        XCTAssertEqual(model.revision, first.revision)
        XCTAssertEqual(model.projector, first.projector)
        XCTAssertEqual(model.inferenceProfile, first.inferenceProfile)
        XCTAssertEqual(model.qualityScore, first.qualityScore)
        XCTAssertEqual(model.modelSummary, first.modelSummary)
        let projector = try XCTUnwrap(model.projector)
        XCTAssertEqual(Array(model.downloadURL.pathComponents.prefix(5)), Array(projector.url.pathComponents.prefix(5)))
        XCTAssertTrue(model.id.hasPrefix(stem), model.id)
        XCTAssertEqual(model.familyID, family.name)
      }
    }
  }

  func testLargerModelsOfALineRankHigher() throws {
    func quality(_ name: String) throws -> Double {
      try XCTUnwrap(BundledLocalModels.families.first { $0.name == name }).qualityScore
    }
    XCTAssertLessThan(try quality("Qwen3.5 2B"), try quality("Qwen3.5 4B"))
    XCTAssertLessThan(try quality("Qwen3.5 4B"), try quality("Qwen3.5 9B"))
    XCTAssertLessThan(try quality("Gemma 4 12B"), try quality("Gemma 4 26B-A4B"))
  }

  func testLeftPackagesAreGone() {
    for left in ["smolvlm2", "gemma-4-e4b", "ministral", "minicpm"] {
      XCTAssertFalse(models.contains { $0.id.contains(left) }, left)
    }
  }

  func testExpectedPicksOnSyntheticMacs() {
    let expected: [(Int, Double, String?, String?, String?)] = [
      (8, 68, "qwen3.5-2b-q4_k_m", nil, nil),
      // Qwen3.5 9B misses the speed bar, so its candidate is its smallest
      // package, IQ3_XXS: 13.5 × 0.85 ranks below Qwen3.5 4B Q5_K_M (13 × 0.99).
      (16, 120, "qwen3.5-4b-q5_k_m", "qwen3.5-2b-q8_0", nil),
      // Qwen3.8 27B IQ3_XXS fits at 13.08 GiB and reaches 8 tok/s.
      (24, 307, "gemma-4-12b-q5_k_m", "qwen3.5-4b-q8_0", "qwen3.8-27b-iq3_xxs"),
      // Qwen3.6 35B-A3B IQ4_XS fits (18 × 0.96 above Gemma 26B-A4B Q4_K_M's
      // 17 × 0.97) at 35.8 tok/s, so no family is 1.5 times as fast.
      (36, 150, "qwen3.6-35b-a3b-iq4_xs", nil, "qwen3.8-27b-iq3_xxs"),
      // Qwen3.8 27B IQ3_S is fast (24.9 tok/s, first token in 1.99 s); IQ4_XS
      // misses 2 s by milliseconds. Qwen3.6 Q8_0 is 2.3 times as fast.
      (64, 460, "qwen3.8-27b-iq3_s", "qwen3.6-35b-a3b-q8_0", nil),
      (128, 614, "qwen3.8-27b-q5_k_m", "qwen3.6-35b-a3b-q8_0", nil),
    ]
    for (memory, bandwidth, recommended, faster, smarter) in expected {
      let recs = LocalModelSelector.select(manifest: .bundled, hardware: mac(memoryGiB: memory, publishedBandwidth: bandwidth))
      let label = "\(memory) GB at \(bandwidth) GB/s"
      XCTAssertEqual(recs.recommended?.id, recommended, label)
      XCTAssertEqual(recs.faster?.id, faster, label)
      XCTAssertEqual(recs.smarter?.id, smarter, label)
    }
  }

  func testOwnersMacRecommendsGemma4_12BAndOffersQwen38AtThreeBits() throws {
    let recs = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac)
    let recommended = try XCTUnwrap(recs.recommended)
    XCTAssertEqual(recommended.id, "gemma-4-12b-q5_k_m")
    XCTAssertEqual(recommended.tokensPerSecond, 23.80, accuracy: 0.01)
    XCTAssertTrue(recommended.isFast)
    XCTAssertEqual(recommended.fit, .excellent)
    XCTAssertEqual(Double(recommended.model.estimatedRuntimeMemory) / Double(gib), 10.75, accuracy: 0.01)
    XCTAssertEqual(Double(ownersMac.inferenceMemoryBudget) / Double(gib), 14.21, accuracy: 0.01)
    XCTAssertEqual(recs.faster?.id, "qwen3.5-4b-q8_0")
    XCTAssertEqual(recs.faster?.tokensPerSecond ?? 0, 44.67, accuracy: 0.01)
    // Only 3-bit Qwen3.8 27B fits the 14.21 GiB budget (IQ3_S at 14.11 GiB too;
    // IQ4_XS needs 16.17). Neither is fast, so the family offers its smallest.
    let smarter = try XCTUnwrap(recs.smarter)
    XCTAssertEqual(smarter.id, "qwen3.8-27b-iq3_xxs")
    XCTAssertEqual(smarter.tokensPerSecond, 18.31, accuracy: 0.01)
    XCTAssertEqual(smarter.timeToFirstToken, 2.98, accuracy: 0.01)
    XCTAssertEqual(smarter.fit, .good)
    XCTAssertEqual(Double(smarter.model.estimatedRuntimeMemory) / Double(gib), 13.08, accuracy: 0.01)
    XCTAssertEqual(smarter.model.rankedQualityScore, 23.8, accuracy: 0.0001)
    let iq3s = try XCTUnwrap(recs.assessments.first { $0.id == "qwen3.8-27b-iq3_s" })
    XCTAssertEqual(Double(iq3s.model.estimatedRuntimeMemory) / Double(gib), 14.11, accuracy: 0.01)
    XCTAssertTrue(iq3s.fit.canRun)
    XCTAssertEqual(try XCTUnwrap(recs.assessments.first { $0.id == "qwen3.8-27b-iq4_xs" }).fit, .memory)

    let runs = [
      ownersRun(id: "gemma-4-12b-it-qat-q4_0-gguf", bytes: 6_975_879_296, parameters: 12,
                speed: 33.16531329376308, prompt: 234.52804679524323, age: 3_600),
      ownersRun(id: "gemma-4-e4b-it-qat-q4_0-gguf", bytes: 5_154_941_280, parameters: 7.5,
                speed: 67.19727627040184, prompt: 136.2804710085045, age: 7_200),
    ]
    let calibrated = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: runs)
    XCTAssertEqual(calibrated.recommended?.id, "gemma-4-12b-q5_k_m")
    XCTAssertEqual(calibrated.recommended?.tokensPerSecond ?? 0, 27.50, accuracy: 0.01)
    // The Gemma 4 12B run lifts dense decode efficiency to 0.87, so IQ3_XXS
    // decodes at 21.16 tok/s; its prompt factor rises only to 1.51, leaving the
    // first token at 2.58 s, so it stays Smarter rather than Recommended.
    let calibratedSmarter = try XCTUnwrap(calibrated.smarter)
    XCTAssertEqual(calibratedSmarter.id, "qwen3.8-27b-iq3_xxs")
    XCTAssertEqual(calibratedSmarter.tokensPerSecond, 21.16, accuracy: 0.01)
    XCTAssertEqual(calibratedSmarter.timeToFirstToken, 2.58, accuracy: 0.01)
    XCTAssertFalse(calibratedSmarter.isFast)

    // A run on this Mac showing a quicker first token (its own Check
    // performance) makes it Recommended: 23.8 ranks above Gemma 4 12B's 13.86.
    let iq3 = try XCTUnwrap(recs.assessments.first { $0.id == "qwen3.8-27b-iq3_xxs" }).model
    let measured = LocalModelBenchmark(version: 1, llamaBuild: LocalVisionRuntime.build,
      hardwareFingerprint: ownersMac.fingerprint, lowPowerMode: false, modelID: iq3.id,
      modelChecksum: iq3.checksumSHA256, modelByteCount: iq3.expectedByteCount, parameterBillions: iq3.parameterBillions,
      architecture: iq3.architecture, contextSize: 8192, recordedAt: .now - 60,
      metrics: LocalBenchmarkMetrics(timeToFirstToken: 1.6, generationTokensPerSecond: 21,
        promptTokensPerSecond: 160, peakMemoryBytes: 13_000_000_000, promptTokenCount: 140,
        generatedTokenCount: 64, modelLoadSeconds: 4),
      predictedTokensPerSecond: 18.31, predictedTimeToFirstToken: 2.98)
    let promoted = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: runs + [measured])
    XCTAssertEqual(promoted.recommended?.id, "qwen3.8-27b-iq3_xxs")
    XCTAssertTrue(promoted.recommended?.isMeasured ?? false)
    // Gemma 4 12B at 27.5 tok/s is not 1.5 times as fast; Qwen3.5 4B Q8_0 is.
    XCTAssertEqual(promoted.faster?.id, "qwen3.5-4b-q8_0")
  }

  func testSlowPromptRunsNeverLowerThePromptPrior() throws {
    // The E4B run's prompt speed was measured on a short prompt; taken as is it
    // would cut the prompt factor to about 0.33 and push Gemma 4 12B over 2 s.
    let e4b = ownersRun(id: "gemma-4-e4b-it-qat-q4_0-gguf", bytes: 5_154_941_280, parameters: 7.5,
                        speed: 67.19727627040184, prompt: 136.2804710085045, age: 60)
    let recs = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: [e4b])
    let recommended = try XCTUnwrap(recs.recommended)
    XCTAssertEqual(recommended.id, "gemma-4-12b-q5_k_m")
    XCTAssertLessThanOrEqual(recommended.timeToFirstToken, 2)
    XCTAssertEqual(recommended.tokensPerSecond, 24.70, accuracy: 0.01)
  }

  func testOlderInstalledRecordsDecode() throws {
    for model in models {
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
      json.removeValue(forKey: "activeParameterBillions")
      let restored = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
      try restored.validate()
      XCTAssertEqual(restored.packageRevision, model.packageRevision)
      XCTAssertEqual(restored.resolvedActiveParameterBillions, restored.parameterBillions)
    }
  }
}
