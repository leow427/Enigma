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

  func testCatalogueHasSevenFamiliesAndTwentyPackages() throws {
    XCTAssertEqual(BundledLocalModels.families.map(\.name),
                   ["Qwen3.5 2B", "Qwen3.5 4B", "Qwen3.5 9B", "Gemma 4 12B", "Gemma 4 26B-A4B", "Qwen3.6 35B-A3B",
                    "Qwen3.8 27B"])
    XCTAssertEqual(models.count, 20)
    try LocalModelManifest.bundled.validate()
    XCTAssertEqual(Set(models.map(\.id)).count, 20)
    XCTAssertEqual(Set(models.map(\.checksumSHA256)).count, 20)
    XCTAssertEqual(LocalModelManifest.bundled.version, 6)
    XCTAssertEqual(LocalVisionModelDescriptor.bundled.count, 20)
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
      (16, 120, "qwen3.5-4b-q5_k_m", "qwen3.5-2b-q8_0", "qwen3.5-9b-q4_k_m"),
      (24, 307, "gemma-4-12b-q5_k_m", "qwen3.5-4b-q8_0", nil),
      (36, 150, "gemma-4-26b-a4b-q4_k_m", "qwen3.5-2b-q8_0", nil),
      (64, 460, "qwen3.6-35b-a3b-q8_0", nil, "qwen3.8-27b-q4_k_m"),
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

  func testOwnersMacRecommendsGemma4_12B() throws {
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
    XCTAssertNil(recs.smarter)

    let runs = [
      ownersRun(id: "gemma-4-12b-it-qat-q4_0-gguf", bytes: 6_975_879_296, parameters: 12,
                speed: 33.16531329376308, prompt: 234.52804679524323, age: 3_600),
      ownersRun(id: "gemma-4-e4b-it-qat-q4_0-gguf", bytes: 5_154_941_280, parameters: 7.5,
                speed: 67.19727627040184, prompt: 136.2804710085045, age: 7_200),
    ]
    let calibrated = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: runs)
    XCTAssertEqual(calibrated.recommended?.id, "gemma-4-12b-q5_k_m")
    XCTAssertEqual(calibrated.recommended?.tokensPerSecond ?? 0, 27.50, accuracy: 0.01)
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
