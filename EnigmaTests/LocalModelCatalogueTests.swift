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

  func testCatalogueHasFourteenFamiliesAndFortyEightPackages() throws {
    XCTAssertEqual(BundledLocalModels.families.map(\.name),
                   ["Qwen3.5 2B", "Qwen3.5 4B", "Gemma 4 E4B", "Ministral 3 8B", "Qwen3.5 9B", "Gemma 4 12B",
                    "Ministral 3 14B", "Gemma 4 26B-A4B", "Gemma 4 31B", "Qwen3.6 35B-A3B", "Qwen3.8 27B",
                    "Bonsai 2 4B", "Bonsai 2 9B", "Bonsai 2 27B"])
    XCTAssertEqual(models.count, 48)
    try LocalModelManifest.bundled.validate()
    XCTAssertEqual(Set(models.map(\.id)).count, 48)
    XCTAssertEqual(Set(models.map(\.checksumSHA256)).count, 48)
    XCTAssertEqual(LocalModelManifest.bundled.version, 9)
    XCTAssertEqual(LocalVisionModelDescriptor.bundled.count, 48)
  }

  /// F35 CP2: read from each package's GGUF `<arch>.context_length` (scripts/gguf-header.py).
  func testEveryBundledPackageHasTrainedContextLength() throws {
    for model in models {
      let trained = try XCTUnwrap(model.trainedContextLength, model.id)
      XCTAssertGreaterThanOrEqual(trained, 8_192, model.id)
    }
    XCTAssertEqual(models.first { $0.id == "gemma-4-e4b-q4_k_m" }?.trainedContextLength, 131_072)
    XCTAssertEqual(models.first { $0.id == "qwen3.5-4b-q4_k_m" }?.trainedContextLength, 262_144)
  }

  func testDescriptorDecodesWithoutTrainedContextLength() throws {
    let model = try XCTUnwrap(models.first)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    XCTAssertNotNil(object.removeValue(forKey: "trainedContextLength"))
    let decoded = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.trainedContextLength)
    try decoded.validate()
  }

  func testTrainedContextLengthBelowTheRecommendedSizeIsRejected() throws {
    var model = try XCTUnwrap(models.first)
    model.trainedContextLength = model.recommendedContextSize - 1
    XCTAssertThrowsError(try model.validate())
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
      // Back in the catalogue with the IDs and pins they left with.
      ("gemma-4-e4b-q4_k_m", "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87", "bfc15c382204943c3a8fff0c750b94ae2364d7a3"),
      ("ministral-3-8b-q4_k_m", "33e7a72cf5e6e2cfc2f2847075acc013d68bba023e35310cef86b5cf8fdca761", "0102285ad796bd99af90f58de616092e5630e970"),
      ("ministral-3-14b-q5_k_m", "f16fef77021df0d4c22e69140a2038478370492f51867b6237699918ae711000", "74fac473c43357d7fb2671713608183cc72496d0"),
      ("ministral-3-14b-q8_0", "8122acc8df446039d41dd9650dabb024d3c6b8dae6eff336d28ac2bddd3bbc13", "74fac473c43357d7fb2671713608183cc72496d0"),
    ]
    for (id, checksum, revision) in pins {
      let model = try XCTUnwrap(models.first { $0.id == id }, id)
      XCTAssertEqual(model.checksumSHA256, checksum, id)
      XCTAssertEqual(model.revision, revision, id)
    }
  }

  func testFamilyMetadataIsConsistent() throws {
    let stems = ["qwen3.5-2b-", "qwen3.5-4b-", "gemma-4-e4b-", "ministral-3-8b-", "qwen3.5-9b-", "gemma-4-12b-",
                 "ministral-3-14b-", "gemma-4-26b-a4b-", "gemma-4-31b-", "qwen3.6-35b-a3b-", "qwen3.8-27b-",
                 "bonsai-2-4b-", "bonsai-2-9b-", "bonsai-2-27b-"]
    XCTAssertEqual(stems.count, BundledLocalModels.families.count)
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
    XCTAssertLessThan(try quality("Gemma 4 E4B"), try quality("Gemma 4 12B"))
    XCTAssertLessThan(try quality("Gemma 4 12B"), try quality("Gemma 4 31B"))
    XCTAssertLessThan(try quality("Ministral 3 8B"), try quality("Ministral 3 14B"))
    XCTAssertLessThan(try quality("Bonsai 2 4B"), try quality("Bonsai 2 9B"))
    XCTAssertLessThan(try quality("Bonsai 2 9B"), try quality("Bonsai 2 27B"))
  }

  func testBonsai2ShipsOneTernaryQ2_0PackagePerFamily() throws {
    // Each score is its base model's score × PrismML's measured vision retention.
    let expected: [(String, String, String, Int64, String, Double, LocalMultimodalProfile)] = [
      ("bonsai-2-4b-q2_0", "prism-ml/Ternary-Bonsai-2-4B-gguf", "8d6557168168f91ea6697a4a49ed2ef622b53adb",
       1_212_103_520, "64a5183b44921bdb5ac4a6f5f92007821d6ebe5c66997d3c147fd214ab9433d4", 11.9, .bonsai2_4B),
      ("bonsai-2-9b-q2_0", "prism-ml/Ternary-Bonsai-2-9B-gguf", "5b2abb02362efbed46bbe204014b02837778b2c2",
       2_556_640_128, "1f884aa56aacd2bbbb2e4b7abaead2b1102b74a9c75a23fc33dab916813a384d", 12.5, .bonsai2_9B),
      ("bonsai-2-27b-q2_0", "prism-ml/Ternary-Bonsai-2-27B-gguf", "94dd51cdbbec5309ed8b76a12f3268bc4fdceb93",
       7_626_008_928, "4f99aed01b8a877e153f9aa6569a4440fe17c59701cc0953e36d7f460549e70e", 26, .bonsai2_27B),
    ]
    for (id, repository, revision, bytes, checksum, quality, profile) in expected {
      let model = try XCTUnwrap(models.first { $0.id == id }, id)
      let size = repository.split(separator: "-")[4]
      XCTAssertEqual(model.downloadURL.absoluteString,
                     "https://huggingface.co/\(repository)/resolve/\(revision)/Ternary-Bonsai-2-\(size)-Q2_0.gguf", id)
      XCTAssertEqual(model.projector?.url.lastPathComponent, "Ternary-Bonsai-2-\(size)-mmproj-Q8_0.gguf", id)
      XCTAssertEqual(model.quantization, "Q2_0", id)
      XCTAssertEqual(model.expectedByteCount, bytes, id)
      XCTAssertEqual(model.checksumSHA256, checksum, id)
      XCTAssertEqual(model.inferenceProfile, profile, id)
      XCTAssertEqual(model.publisher, "PrismML", id)
      XCTAssertEqual(model.qualityScore, quality, id)
      // The ternary loss is in the family score, so Q2_0 takes no further cut.
      XCTAssertEqual(model.rankedQualityScore, quality, id)
      XCTAssertEqual(model.modelSupportsAudio, false, id)
      XCTAssertFalse(profile.usesNonCausalImageAttention, id)
      XCTAssertTrue(LocalModelCompatibility.supports(model), id)
    }
  }

  func testLeftPackagesAreGone() {
    for left in ["smolvlm2", "minicpm"] {
      XCTAssertFalse(models.contains { $0.id.contains(left) }, left)
    }
  }

  func testGemma4_31BShipsSixSizesFromOneRevision() throws {
    let expected: [(String, String, Int64)] = [
      ("gemma-4-31b-iq3_xxs", "IQ3_XXS", 12_981_709_152), ("gemma-4-31b-q3_k_m", "Q3_K_M", 15_918_123_360),
      ("gemma-4-31b-iq4_xs", "IQ4_XS", 17_155_893_600), ("gemma-4-31b-q4_k_m", "Q4_K_M", 19_598_489_952),
      ("gemma-4-31b-q5_k_m", "Q5_K_M", 22_608_877_920), ("gemma-4-31b-q8_0", "Q8_0", 32_635_677_024),
    ]
    for (id, quantization, bytes) in expected {
      let model = try XCTUnwrap(models.first { $0.id == id }, id)
      XCTAssertEqual(model.quantization, quantization, id)
      XCTAssertEqual(model.expectedByteCount, bytes, id)
      XCTAssertEqual(model.revision, "619aca7589c72be65dd968de8602ad23d68b5c14", id)
      XCTAssertEqual(model.downloadURL.lastPathComponent, "google_gemma-4-31B-it-\(quantization).gguf", id)
      XCTAssertEqual(model.projector?.url.lastPathComponent, "mmproj-google_gemma-4-31B-it-f16.gguf", id)
      XCTAssertEqual(model.projector?.expectedByteCount, 1_198_956_736, id)
      XCTAssertEqual(model.inferenceProfile, .gemma4_31B, id)
      XCTAssertEqual(model.qualityScore, 15, id)
      XCTAssertEqual(model.modelSupportsAudio, false, id)
    }
    XCTAssertTrue(LocalMultimodalProfile.gemma4_31B.usesNonCausalImageAttention)
    XCTAssertFalse(LocalMultimodalProfile.gemma4E4B.usesNonCausalImageAttention)
  }

  @MainActor
  func testReaddedPackagesKeepTheirIdentityAndOfferAnUpdate() throws {
    // Records saved by 0.10.1: the same ID, file, size and checksums, but that
    // release's runtime (b10797) and memory floors. Their package revision ends
    // ":10797", so Settings offers Update, a download that moves them to b11734.
    let records: [(String, String, Int64, String, Int64, Int64)] = [
      ("gemma-4-e4b-q4_k_m", "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf",
       4_977_171_584, "ddf46c21d7078e95338cfc22306b19b276a29a5ad089023449dd54d4b6170a51", 990_372_672, 16),
      ("ministral-3-8b-q4_k_m", "https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF/resolve/0102285ad796bd99af90f58de616092e5630e970/Ministral-3-8B-Instruct-2512-Q4_K_M.gguf",
       5_198_911_904, "e799380f596d152ff4026a72d409ecc89c96cd437676804bc3f2ab3bd6b486ec", 858_283_168, 16),
      ("ministral-3-14b-q5_k_m", "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-Q5_K_M.gguf",
       9_621_091_904, "ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7", 879_258_784, 24),
      ("ministral-3-14b-q8_0", "https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/74fac473c43357d7fb2671713608183cc72496d0/Ministral-3-14B-Instruct-2512-Q8_0.gguf",
       14_359_836_224, "ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7", 879_258_784, 32),
    ]
    for (id, url, bytes, projectorSHA, projectorBytes, minimumGiB) in records {
      let current = try XCTUnwrap(models.first { $0.id == id }, id)
      XCTAssertEqual(current.downloadURL.absoluteString, url, id)
      XCTAssertEqual(current.expectedByteCount, bytes, id)
      XCTAssertEqual(current.projector?.checksumSHA256, projectorSHA, id)
      XCTAssertEqual(current.projector?.expectedByteCount, projectorBytes, id)
      var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
      let floor = max(current.estimatedRuntimeMemory, minimumGiB * gib)
      json["minimumMemory"] = floor
      json["recommendedMemory"] = floor
      json["largestTensorBytes"] = (current.architecture == "gemma4" ? 3 : 1) * gib
      json["advertisedMemoryRange"] = "7–9"
      json["runtimeBuild"] = 10797
      json["minimumLlamaBuild"] = 10797
      json.removeValue(forKey: "activeParameterBillions")
      let installed = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
      XCTAssertEqual(installed.id, current.id)
      XCTAssertEqual(installed.downloadURL, current.downloadURL, id)
      XCTAssertEqual(installed.checksumSHA256, current.checksumSHA256, id)
      XCTAssertEqual(installed.projector?.checksumSHA256, current.projector?.checksumSHA256, id)
      XCTAssertEqual(installed.expectedByteCount, current.expectedByteCount, id)
      XCTAssertEqual(installed.resolvedProfile, current.inferenceProfile, id)
      XCTAssertTrue(installed.packageRevision.hasSuffix(":10797"), id)
      XCTAssertNotEqual(installed.packageRevision, current.packageRevision, id)

      let file = URL(fileURLWithPath: "/tmp/enigma-readded-fixture.gguf")
      let record = LocalModel(id: installed.id, displayName: installed.displayName, fileURL: file,
        catalogDescriptor: installed, visionConfiguration: LocalVisionConfiguration(projectorURL: file,
          serverExecutableURL: URL(fileURLWithPath: "/bin/echo"), contextWindow: installed.recommendedContextSize,
          packageRevision: installed.packageRevision))
      XCTAssertTrue(current.requiresUpdate(record), id)
      let assessment = LocalModelSelector.assess(current, hardware: mac(memoryGiB: 64, publishedBandwidth: 400),
                                                 installed: true)
      XCTAssertEqual(LocalModelSettingsLogic.managerAction(for: assessment, installed: [record], activeID: nil,
                                                           isBusy: false).action, .update, id)
    }
  }

  func testExpectedPicksOnSyntheticMacs() {
    let expected: [(Int, Double, String?, String?, String?)] = [
      // The best usable Bonsai is Recommended even when it misses the speed bar:
      // Bonsai 2 4B reaches 36.6 tok/s here, but its first token takes 2.24 s.
      (8, 68, "bonsai-2-4b-q2_0", nil, nil),
      (8, 100, "bonsai-2-4b-q2_0", nil, nil),
      // Bonsai 2 27B doesn't fit 16 GB. Bonsai 2 4B (64.6 tok/s) is twice as fast
      // as Bonsai 2 9B (30.6); Qwen3.5 9B IQ4_XS (12.96) ranks above 12.5 but is slow.
      (16, 120, "bonsai-2-9b-q2_0", "bonsai-2-4b-q2_0", "qwen3.5-9b-iq4_xs"),
      // Every 24 GB Mac gets Bonsai 2 27B, even a base chip at 8.6 tok/s.
      (24, 100, "bonsai-2-27b-q2_0", "bonsai-2-4b-q2_0", nil),
      (24, 307, "bonsai-2-27b-q2_0", "bonsai-2-9b-q2_0", nil),
      // Below 8 tok/s Bonsai 2 27B isn't usable, so Bonsai 2 9B is Recommended.
      (24, 68, "bonsai-2-9b-q2_0", nil, "qwen3.5-9b-iq4_xs"),
      // Qwen3.8 27B IQ4_XS (26.88) still ranks above Bonsai 2 27B (26), so it's Smarter.
      (32, 200, "bonsai-2-27b-q2_0", "bonsai-2-9b-q2_0", "qwen3.8-27b-iq4_xs"),
      (36, 150, "bonsai-2-27b-q2_0", "bonsai-2-4b-q2_0", nil),
      // Qwen3.8 27B's fast size is 3-bit (23.8), but its slower IQ4_XS (26.88) is Smarter.
      (64, 460, "bonsai-2-27b-q2_0", "bonsai-2-9b-q2_0", "qwen3.8-27b-iq4_xs"),
      // Bonsai 2 27B decodes at 52.5 tok/s, so no Faster is offered; Qwen3.8 27B
      // Q5_K_M is fast too but ranks higher (27.72 above 26), so it's Smarter.
      (128, 614, "bonsai-2-27b-q2_0", nil, "qwen3.8-27b-q5_k_m"),
    ]
    for (memory, bandwidth, recommended, faster, smarter) in expected {
      let recs = LocalModelSelector.select(manifest: .bundled, hardware: mac(memoryGiB: memory, publishedBandwidth: bandwidth))
      let label = "\(memory) GB at \(bandwidth) GB/s"
      XCTAssertEqual(recs.recommended?.id, recommended, label)
      XCTAssertEqual(recs.faster?.id, faster, label)
      XCTAssertEqual(recs.smarter?.id, smarter, label)
    }
  }

  func testOwnersMacRecommendsBonsai2_27B() throws {
    let recs = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac)
    // Bonsai 2 27B fits at 9.69 GiB and decodes at 26.3 tok/s; its first token
    // takes 2.97 s, but the best usable Bonsai is Recommended anyway.
    let recommended = try XCTUnwrap(recs.recommended)
    XCTAssertEqual(recommended.id, "bonsai-2-27b-q2_0")
    XCTAssertEqual(recommended.tokensPerSecond, 26.26, accuracy: 0.01)
    XCTAssertEqual(recommended.timeToFirstToken, 2.97, accuracy: 0.01)
    XCTAssertFalse(recommended.isFast)
    XCTAssertEqual(recommended.fit, .excellent)
    XCTAssertEqual(Double(recommended.model.estimatedRuntimeMemory) / Double(gib), 9.69, accuracy: 0.01)
    XCTAssertEqual(Double(ownersMac.inferenceMemoryBudget) / Double(gib), 14.21, accuracy: 0.01)
    XCTAssertEqual(recs.faster?.id, "bonsai-2-9b-q2_0")
    XCTAssertEqual(recs.faster?.tokensPerSecond ?? 0, 78.33, accuracy: 0.01)
    // Nothing that fits ranks above 26: Qwen3.8 27B's 3-bit candidate is 23.8.
    XCTAssertNil(recs.smarter)
    // A Bonsai Recommended is a choice, not a best-available fallback.
    XCTAssertEqual(recs.roles.map(\.tag), ["recommended", "faster"])
    // Only 3-bit Qwen3.8 27B fits the 14.21 GiB budget (IQ3_S at 14.11 GiB too;
    // IQ4_XS needs 16.17). Neither is fast, so the family offers its smallest.
    let iq3 = try XCTUnwrap(recs.assessments.first { $0.id == "qwen3.8-27b-iq3_xxs" })
    XCTAssertEqual(iq3.tokensPerSecond, 18.31, accuracy: 0.01)
    XCTAssertEqual(iq3.timeToFirstToken, 2.98, accuracy: 0.01)
    XCTAssertEqual(iq3.fit, .good)
    XCTAssertEqual(Double(iq3.model.estimatedRuntimeMemory) / Double(gib), 13.08, accuracy: 0.01)
    XCTAssertEqual(iq3.model.rankedQualityScore, 23.8, accuracy: 0.0001)
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
    // Ordinary runs never calibrate ternary packages, so Bonsai 2 27B keeps its
    // starting estimate and stays Recommended.
    let calibrated = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: runs)
    let calibratedRecommended = try XCTUnwrap(calibrated.recommended)
    XCTAssertEqual(calibratedRecommended.id, "bonsai-2-27b-q2_0")
    XCTAssertEqual(calibratedRecommended.tokensPerSecond, 26.26, accuracy: 0.01)
    XCTAssertEqual(calibratedRecommended.timeToFirstToken, 2.97, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(calibrated.assessments.first { $0.id == "gemma-4-12b-q5_k_m" }).tokensPerSecond,
                   27.50, accuracy: 0.01)

    // Its own Check performance, with a quicker first token, makes it fast too.
    let bonsai = recommended.model
    let measured = LocalModelBenchmark(version: 1, llamaBuild: LocalVisionRuntime.build,
      hardwareFingerprint: ownersMac.fingerprint, lowPowerMode: false, modelID: bonsai.id,
      modelChecksum: bonsai.checksumSHA256, modelByteCount: bonsai.expectedByteCount,
      parameterBillions: bonsai.parameterBillions, architecture: bonsai.architecture, contextSize: 8192,
      recordedAt: .now - 60,
      metrics: LocalBenchmarkMetrics(timeToFirstToken: 1.6, generationTokensPerSecond: 26,
        promptTokensPerSecond: 160, peakMemoryBytes: 9_000_000_000, promptTokenCount: 140,
        generatedTokenCount: 64, modelLoadSeconds: 4),
      predictedTokensPerSecond: 26.26, predictedTimeToFirstToken: 2.97)
    let promoted = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: runs + [measured])
    XCTAssertEqual(promoted.recommended?.id, "bonsai-2-27b-q2_0")
    XCTAssertTrue(promoted.recommended?.isMeasured ?? false)
    XCTAssertTrue(promoted.recommended?.isFast ?? false)
    XCTAssertEqual(promoted.faster?.id, "bonsai-2-9b-q2_0")
  }

  func testSlowPromptRunsNeverLowerThePromptPrior() throws {
    // The E4B run's prompt speed was measured on a short prompt; taken as is it
    // would cut the prompt factor to about 0.33 and push Gemma 4 12B over 2 s.
    let e4b = ownersRun(id: "gemma-4-e4b-it-qat-q4_0-gguf", bytes: 5_154_941_280, parameters: 7.5,
                        speed: 67.19727627040184, prompt: 136.2804710085045, age: 60)
    let recs = LocalModelSelector.select(manifest: .bundled, hardware: ownersMac, measurements: [e4b])
    let twelve = try XCTUnwrap(recs.assessments.first { $0.id == "gemma-4-12b-q5_k_m" })
    XCTAssertTrue(twelve.isFast)
    XCTAssertLessThanOrEqual(twelve.timeToFirstToken, 2)
    XCTAssertEqual(twelve.tokensPerSecond, 24.70, accuracy: 0.01)
  }

  func testSmarterStaysSlowerThanAMeasuredSlowBonsai() throws {
    // An M5 16 GB whose Check performance finds Bonsai 2 9B at half its estimate.
    let mac = mac(memoryGiB: 16, publishedBandwidth: 153)
    let nine = try XCTUnwrap(models.first { $0.id == "bonsai-2-9b-q2_0" })
    let run = LocalModelBenchmark(version: 1, llamaBuild: LocalVisionRuntime.build,
      hardwareFingerprint: mac.fingerprint, lowPowerMode: false, modelID: nine.id,
      modelChecksum: nine.checksumSHA256, modelByteCount: nine.expectedByteCount,
      parameterBillions: nine.parameterBillions, architecture: nine.architecture, contextSize: 8192,
      recordedAt: .now - 60,
      metrics: LocalBenchmarkMetrics(timeToFirstToken: 1.5, generationTokensPerSecond: 19.5,
        promptTokensPerSecond: 300, peakMemoryBytes: 4_000_000_000, promptTokenCount: 140,
        generatedTokenCount: 64, modelLoadSeconds: 2),
      predictedTokensPerSecond: 39, predictedTimeToFirstToken: 1.2)
    let recs = LocalModelSelector.select(manifest: .bundled, hardware: mac, measurements: [run])
    let recommended = try XCTUnwrap(recs.recommended)
    XCTAssertEqual(recommended.id, "bonsai-2-9b-q2_0")
    XCTAssertTrue(recommended.isMeasured)
    XCTAssertEqual(recs.faster?.id, "bonsai-2-4b-q2_0")
    // Fast Qwen3.5 4B Q8_0 (22.3 tok/s) ranks higher but isn't slower, so it isn't Smarter.
    XCTAssertNotEqual(recs.smarter?.id, "qwen3.5-4b-q8_0")
    if let smarter = recs.smarter { XCTAssertLessThan(smarter.tokensPerSecond, recommended.tokensPerSecond) }
    XCTAssertEqual(Set(recs.roles.map(\.id)).count, recs.roles.count)
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
