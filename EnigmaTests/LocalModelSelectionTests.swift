import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import Enigma

final class LocalModelSelectionTests: XCTestCase {
  private let gib = LocalHardwareProfile.gib
  private var catalog: LocalModelManifest { .bundled }

  // MARK: Roles

  private func familyPackage(family: String, profile: LocalMultimodalProfile, quantization: String,
                             weights: Int64, quality: Double) -> LocalModelDescriptor {
    let revision = "0123456789abcdef0123456789abcdef01234567"
    let base = "https://huggingface.co/unsloth/Fixture-GGUF/resolve/\(revision)/"
    let id = "\(family.lowercased())-\(quantization.lowercased())"
    func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    let projector = VerifiedModelArtifact(url: URL(string: base + "mmproj-\(family).gguf")!,
                                          expectedByteCount: 900_000_000, checksumSHA256: hash(id + ".mmproj"))
    let memory = profile.memory(weights: weights, projector: projector.expectedByteCount, context: 8192)
    return LocalModelDescriptor(id: id, displayName: family,
      downloadURL: URL(string: base + "\(family)-\(quantization).gguf")!, expectedByteCount: weights,
      license: "Apache-2.0", checksumSHA256: hash(id), revision: revision, quantization: quantization,
      architecture: profile.architecture, chatTemplate: profile.chatTemplate,
      minimumLlamaBuild: LocalVisionRuntime.build, estimatedRuntimeMemory: memory, largestTensorBytes: 1_000_000_000,
      recommendedContextSize: 8192, qualityScore: quality, performanceClass: "Vision",
      parameterBillions: profile.parameters, minimumMemory: memory, recommendedMemory: memory, projector: projector,
      runtimeBuild: LocalVisionRuntime.build, publisher: "Fixture", modelSummary: "A fixture model.",
      inferenceProfile: profile, activeParameterBillions: profile.activeParameters)
  }

  private var familyManifest: LocalModelManifest {
    LocalModelManifest(version: 1, models: [
      familyPackage(family: "Tiny", profile: .qwen35_2B, quantization: "Q4_K_M", weights: 500_000_000, quality: 5),
      familyPackage(family: "Small", profile: .qwen35_2B, quantization: "Q4_K_M", weights: 1_000_000_000, quality: 8),
      familyPackage(family: "Mid", profile: .qwen35_4B, quantization: "Q4_K_M", weights: 3_000_000_000, quality: 13),
      familyPackage(family: "Mid", profile: .qwen35_4B, quantization: "Q5_K_M", weights: 4_000_000_000, quality: 13),
      familyPackage(family: "Mid", profile: .qwen35_4B, quantization: "Q8_0", weights: 6_000_000_000, quality: 13),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "Q4_K_M", weights: 16_000_000_000, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "Q5_K_M", weights: 17_000_000_000, quality: 28),
    ])
  }

  private func familyMac(memoryGiB: Int = 32, bandwidth: Double?) -> LocalHardwareProfile {
    let memory = Int64(memoryGiB) * gib
    let workingSet = Int64(Double(memory) * 0.74)
    return LocalHardwareProfile(physicalMemory: memory, isAppleSilicon: true, hasMetal: true, hasUnifiedMemory: true,
      chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 500 * gib, metalRecommendedWorkingSet: workingSet,
      metalMaximumBufferLength: workingSet * 3 / 4, lowPowerMode: false, measuredBandwidth: bandwidth)
  }

  func testRolesAtTwoHundredGigabytesPerSecond() throws {
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(bandwidth: 200))
    XCTAssertEqual(recs.recommended?.id, "mid-q8_0")
    XCTAssertEqual(recs.faster?.id, "small-q4_k_m")
    XCTAssertEqual(recs.smarter?.id, "big-q4_k_m")
    XCTAssertEqual(recs.roles.map(\.role), [.recommended, .faster, .smarter])
    XCTAssertEqual(recs.roles.map(\.tag), ["recommended", "faster", "smarter, slower replies"])
    XCTAssertEqual(recs.allFamilies.map(\.model.familyID), ["Big", "Mid", "Small", "Tiny"])
  }

  func testNoFasterRoleWhenRecommendedIsAlreadyQuick() {
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(bandwidth: 400))
    XCTAssertEqual(recs.recommended?.id, "mid-q8_0")
    XCTAssertEqual(recs.recommended?.tokensPerSecond ?? 0, 50, accuracy: 0.01)
    XCTAssertNil(recs.faster)
    XCTAssertEqual(recs.smarter?.id, "big-q4_k_m")
  }

  func testNothingFastRecommendsTheBestUsableFamily() throws {
    var mac = familyMac(bandwidth: nil)
    mac.performanceCPUCount = 1
    mac.cpuCount = 1
    mac.lowPowerMode = true
    XCTAssertEqual(LocalModelSelector.bandwidth(for: mac), 14.95, accuracy: 0.0001)
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: mac)
    let recommended = try XCTUnwrap(recs.recommended)
    XCTAssertEqual(recommended.id, "small-q4_k_m")
    XCTAssertFalse(recommended.isFast)
    XCTAssertEqual(recs.roles.first?.tag, "best available, expect longer waits")
    XCTAssertNil(recs.faster)
    XCTAssertNil(recs.smarter)
  }

  func testNothingFitsHasNoRoles() {
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(memoryGiB: 4, bandwidth: 200))
    XCTAssertNil(recs.recommended)
    XCTAssertTrue(recs.roles.isEmpty)
    XCTAssertEqual(recs.allFamilies.count, 4)
    XCTAssertTrue(recs.allFamilies.allSatisfy { !$0.fit.canRun })
  }

  func testRoleTags() {
    XCTAssertEqual(LocalModelRole.recommended.tag(isFast: true), "recommended")
    XCTAssertEqual(LocalModelRole.recommended.tag(isFast: false), "best available, expect longer waits")
    XCTAssertEqual(LocalModelRole.faster.tag(isFast: true), "faster")
    XCTAssertEqual(LocalModelRole.smarter.tag(isFast: false), "smarter, slower replies")
  }

  // MARK: Quantizations

  func testQuantizationQualityFactors() {
    let factors: [(String, Double)] = [
      ("Q8_0", 1), ("Q5_K_M", 0.99), ("Q4_K_M", 0.97), ("Q4_0", 0.97), ("IQ4_XS", 0.96),
      ("Q3_K_M", 0.85), ("IQ3_S", 0.85), ("IQ3_XXS", 0.85), ("IQ1_S", 1), ("", 1),
    ]
    for (quantization, factor) in factors {
      XCTAssertEqual(LocalQuantization.qualityFactor(quantization), factor, quantization)
    }
    let package = familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS",
                                weights: 10_000_000_000, quality: 28)
    XCTAssertEqual(package.rankedQualityScore, 23.8, accuracy: 0.0001)
    XCTAssertEqual(package.qualityScore, 28)
  }

  func testPrecisionOrderKnowsEveryShippedQuantization() {
    XCTAssertEqual(LocalQuantization.precisionOrder,
                   ["Q8_0", "Q5_K_M", "Q4_K_M", "Q4_0", "IQ4_XS", "Q3_K_M", "IQ3_S", "IQ3_XXS"])
    let ranks = LocalQuantization.precisionOrder.map(LocalQuantization.precision)
    XCTAssertEqual(ranks, ranks.sorted(by: >))
    XCTAssertLessThan(LocalQuantization.precision("IQ1_S"), LocalQuantization.precision("IQ3_XXS"))
  }

  func testFamilyChoiceRanksByPrecisionNotFileSize() throws {
    // A synthetic IQ4_XS file larger than the Q4_K_M one: both are fast, and
    // the higher precision wins even though it is the smaller file.
    let manifest = LocalModelManifest(version: 1, models: [
      familyPackage(family: "Nine", profile: .qwen35_9B, quantization: "Q4_K_M", weights: 5_000_000_000, quality: 13.5),
      familyPackage(family: "Nine", profile: .qwen35_9B, quantization: "IQ4_XS", weights: 5_500_000_000, quality: 13.5),
    ])
    let recs = LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 200))
    XCTAssertTrue(recs.assessments.allSatisfy(\.isFast))
    XCTAssertEqual(recs.recommended?.id, "nine-q4_k_m")
  }

  func testFamilyDropsToThreeBitOnlyWhenNothingLargerFitsAndIsFast() throws {
    let manifest = LocalModelManifest(version: 1, models: [
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS", weights: 10_934_860_704, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ4_XS", weights: 14_252_845_984, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "Q4_K_M", weights: 16_464_440_224, quality: 28),
    ])
    // 32 GiB: Q4_K_M fits and is fast.
    XCTAssertEqual(LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 600)).recommended?.id,
                   "big-q4_k_m")
    // 32 GiB at 420 GB/s: everything fits and only Q4_K_M misses 20 tok/s, so
    // the family stays at 4 bits.
    let slower = LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 420))
    XCTAssertEqual(slower.assessments.map(\.isFast), [true, true, false])
    XCTAssertEqual(slower.recommended?.id, "big-iq4_xs")
    // 24 GiB: only IQ3_XXS fits.
    let small = LocalModelSelector.select(manifest: manifest, hardware: familyMac(memoryGiB: 24, bandwidth: 600))
    XCTAssertEqual(small.assessments.map(\.fit.canRun), [true, false, false])
    XCTAssertEqual(small.recommended?.id, "big-iq3_xxs")
  }

  func testSlowFamilyOffersItsSmallestUsableFourBitPackage() throws {
    let manifest = LocalModelManifest(version: 1, models: [
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS", weights: 10_934_860_704, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ4_XS", weights: 14_252_845_984, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "Q4_K_M", weights: 16_464_440_224, quality: 28),
    ])
    // 200 GB/s: none is fast; IQ4_XS (10.5 tok/s) is the smallest usable package with a factor of 0.96 or more.
    let usable = LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 200))
    XCTAssertFalse(usable.assessments.contains(where: \.isFast))
    XCTAssertEqual(usable.assessments.map(\.isUsable), [true, true, true])
    XCTAssertEqual(LocalModelSelector.choice(in: usable.assessments)?.id, "big-iq4_xs")
    // 140 GB/s: IQ4_XS drops under 8 tok/s, so the family falls back to its smallest package that fits.
    let slow = LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 140))
    XCTAssertEqual(slow.assessments.map(\.isUsable), [true, false, false])
    XCTAssertEqual(LocalModelSelector.choice(in: slow.assessments)?.id, "big-iq3_xxs")
  }

  func testThreeBitRecommendedOffersItsOwnFamilysFourBitAsSmarter() throws {
    let manifest = LocalModelManifest(version: 1, models: [
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS", weights: 10_934_860_704, quality: 28),
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "Q4_K_M", weights: 16_464_440_224, quality: 28),
      familyPackage(family: "Nine", profile: .qwen35_9B, quantization: "Q4_K_M", weights: 5_680_522_464, quality: 13.5),
    ])
    // 420 GB/s: IQ3_XXS is fast and Recommended (23.8); Q4_K_M (19.1 tok/s) misses the bar but ranks 27.16.
    let recs = LocalModelSelector.select(manifest: manifest, hardware: familyMac(bandwidth: 420))
    XCTAssertEqual(recs.recommended?.id, "big-iq3_xxs")
    XCTAssertEqual(recs.smarter?.id, "big-q4_k_m")
    XCTAssertFalse(try XCTUnwrap(recs.smarter).isFast)
    // A 4-bit Recommended never offers its own family again.
    let fourBit = LocalModelManifest(version: 1, models: manifest.models.filter { $0.quantization != "IQ3_XXS" })
    let other = LocalModelSelector.select(manifest: fourBit, hardware: familyMac(bandwidth: 600))
    XCTAssertEqual(other.recommended?.id, "big-q4_k_m")
    XCTAssertNil(other.smarter)
  }

  func testThreeBitLosesToAFourBitFamilyUnlessClearlyStronger() throws {
    let nine = familyPackage(family: "Nine", profile: .qwen35_9B, quantization: "Q4_K_M",
                             weights: 5_680_522_464, quality: 13.5)
    // 14 × 0.85 = 11.9 against 13.5 × 0.97 = 13.095.
    let twelve = familyPackage(family: "Twelve", profile: .gemma4_12B, quantization: "IQ3_XXS",
                               weights: 4_639_716_160, quality: 14)
    let close = LocalModelSelector.select(manifest: LocalModelManifest(version: 1, models: [nine, twelve]),
                                          hardware: familyMac(bandwidth: 200))
    XCTAssertTrue(close.assessments.allSatisfy(\.isFast))
    XCTAssertEqual(close.recommended?.id, "nine-q4_k_m")
    // 28 × 0.85 = 23.8 is clearly stronger.
    let big = familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS",
                            weights: 10_934_860_704, quality: 28)
    let strong = LocalModelSelector.select(manifest: LocalModelManifest(version: 1, models: [nine, twelve, big]),
                                           hardware: familyMac(bandwidth: 450))
    XCTAssertEqual(strong.recommended?.id, "big-iq3_xxs")
  }

  func testSmarterComparesQualityAfterTheQuantizationFactor() throws {
    let nine = familyPackage(family: "Nine", profile: .qwen35_9B, quantization: "Q4_K_M",
                             weights: 5_680_522_464, quality: 13.5)
    func slowThreeBit(quality: Double) -> LocalModelDescriptor {
      familyPackage(family: "Big", profile: .qwen38_27B, quantization: "IQ3_XXS", weights: 10_934_860_704,
                    quality: quality)
    }
    // 15 × 0.85 = 12.75 is below 13.095, although 15 is above 13.5.
    let weaker = LocalModelSelector.select(manifest: LocalModelManifest(version: 1, models: [nine, slowThreeBit(quality: 15)]),
                                           hardware: familyMac(bandwidth: 200))
    XCTAssertEqual(weaker.recommended?.id, "nine-q4_k_m")
    XCTAssertNil(weaker.smarter)
    // 16 × 0.85 = 13.6 is above it.
    let stronger = LocalModelSelector.select(manifest: LocalModelManifest(version: 1, models: [nine, slowThreeBit(quality: 16)]),
                                             hardware: familyMac(bandwidth: 200))
    XCTAssertEqual(stronger.smarter?.id, "big-iq3_xxs")
    XCTAssertFalse(try XCTUnwrap(stronger.smarter).isFast)
  }

  func testRolesFollowTheGatesOnEveryMac() throws {
    for memory in [8, 16, 24, 32, 36, 48, 64, 128, 256] {
      for bandwidth in [50.0, 120, 267, 614, 1_000] {
        let mac = familyMac(memoryGiB: memory, bandwidth: bandwidth)
        let recs = LocalModelSelector.select(manifest: catalog, hardware: mac)
        let label = "\(memory) GiB at \(bandwidth) GB/s"
        let families = Dictionary(grouping: recs.assessments, by: \.model.familyID)
        let candidates = families.values.compactMap { LocalModelSelector.choice(in: $0) }
          .sorted(by: LocalModelSelector.qualityOrder)
        if let recommended = recs.recommended {
          if let bestFast = candidates.first(where: \.isFast) {
            XCTAssertTrue(recommended.isFast, label)
            XCTAssertEqual(recommended.id, bestFast.id, label)
          } else {
            XCTAssertEqual(recommended.id, candidates.first(where: \.isUsable)?.id, label)
          }
          if let faster = recs.faster {
            XCTAssertLessThan(recommended.tokensPerSecond, 40, label)
            XCTAssertTrue(faster.isFast, label)
            XCTAssertNotEqual(faster.model.familyID, recommended.model.familyID, label)
            XCTAssertGreaterThanOrEqual(faster.tokensPerSecond, recommended.tokensPerSecond * 1.5, label)
          }
          if recommended.tokensPerSecond >= 40 { XCTAssertNil(recs.faster, label) }
          if let smarter = recs.smarter {
            XCTAssertTrue(smarter.isUsable && !smarter.isFast, label)
            XCTAssertGreaterThan(smarter.model.rankedQualityScore, recommended.model.rankedQualityScore, label)
          }
        } else {
          XCTAssertNil(candidates.first(where: \.isUsable), label)
          XCTAssertTrue(recs.roles.isEmpty, label)
        }
        for role in recs.roles {
          let family = families[role.assessment.model.familyID] ?? []
          if role.assessment.isFast {
            let precision = LocalQuantization.precision(role.assessment.model.quantization)
            XCTAssertFalse(family.contains { $0.isFast && LocalQuantization.precision($0.model.quantization) > precision }, label)
          } else {
            // The smallest usable package with a factor of 0.96 or more, else the smallest that fits.
            let fourBit = family.filter { $0.isUsable && LocalQuantization.qualityFactor($0.model.quantization) >= 0.96 }
            let pool = fourBit.isEmpty ? family.filter(\.fit.canRun) : fourBit
            XCTAssertFalse(pool.contains { $0.model.expectedByteCount < role.assessment.model.expectedByteCount }, label)
            XCTAssertTrue(pool.contains { $0.id == role.assessment.id }, label)
          }
          XCTAssertTrue(role.assessment.fit.canRun, label)
          XCTAssertLessThanOrEqual(role.assessment.model.estimatedRuntimeMemory, mac.inferenceMemoryBudget, label)
          XCTAssertGreaterThanOrEqual(mac.availableDiskBytes, role.assessment.model.downloadByteCount * 2 + 2 * gib, label)
        }
        XCTAssertEqual(Set(recs.roles.map(\.id)).count, recs.roles.count, label)
      }
    }
  }

  func testEnigmaProductKeepsExistingUserDataIdentity() {
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Enigma")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Enigma")
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.leow427.AISpotlight")
  }

  func testCatalogPinsEveryQuantizationAndMatchesEmbeddedBuild() throws {
    try catalog.validate()
    XCTAssertEqual(catalog.models.count, 45)
    XCTAssertEqual(Set(catalog.models.map(\.quantization)),
                   ["IQ3_XXS", "IQ3_S", "Q3_K_M", "IQ4_XS", "Q4_K_M", "Q5_K_M", "Q8_0"])
    XCTAssertEqual(Set(catalog.models.map(\.maker)), ["Alibaba / Qwen", "Google", "Mistral AI"])
    XCTAssertEqual(Set(catalog.models.compactMap(\.resolvedProfile)),
                   Set([.qwen35_2B, .qwen35_4B, .gemma4E4B, .ministral8B, .qwen35_9B, .gemma4_12B, .ministral14B,
                        .gemma4A4B, .gemma4_31B, .qwen36_35BA3B, .qwen38_27B]))
    for model in catalog.models {
      XCTAssertTrue(LocalModelCompatibility.supports(model))
      XCTAssertTrue(model.supportsVision)
      XCTAssertNotNil(model.modelSummary)
      XCTAssertLessThanOrEqual(model.summary.count, 300)
      XCTAssertTrue(model.summary.hasSuffix("."))
      XCTAssertNotNil(model.projector)
      XCTAssertEqual(model.runtimeBuild, LocalVisionRuntime.build)
      XCTAssertGreaterThanOrEqual(model.recommendedContextSize, 4_096)
      XCTAssertEqual(model.downloadURL.pathComponents[4], model.revision)
    }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Packages/LlamaBridge/Package.swift")
    XCTAssertTrue(try String(contentsOf: source, encoding: .utf8).contains("releases/download/b\(LocalModelCompatibility.llamaBuild)/"))
  }

  func testGemmaTwelveBUsesPinnedOfficialQuantizedPackage() throws {
    let model = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })
    XCTAssertEqual(model.displayName, "Google Gemma 4 12B")
    XCTAssertEqual(model.revision, "29d097773436b69ff9feafd636ab4cf873786537")
    XCTAssertEqual(model.expectedByteCount, 6_975_879_296)
    XCTAssertEqual(model.checksumSHA256, "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b")
    XCTAssertEqual(model.projector?.expectedByteCount, 175_115_616)
    XCTAssertEqual(model.projector?.checksumSHA256, "cb018338a7538a9814d994bfe54644c71eb7ed54e31eae2f721e45fd3c260da7")
    XCTAssertEqual(model.inferenceProfile, .gemma4_12B)
    XCTAssertEqual(model.quantization, "Q4_0")
    XCTAssertEqual(LocalModelCompatibility.supports(model), model.inferenceProfile != .miniCPMO45)
  }

  func testCompatibleModelsCanBeInstalledAndLoadedWithMemoryWarnings() throws {
    let gemma = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })
    let insufficientMemory = LocalModelSelector.assess(gemma, hardware: hardware(memory: 24))
    XCTAssertEqual(insufficientMemory.fit, .memory)
    XCTAssertTrue(insufficientMemory.permitsMemoryOverride)
    XCTAssertTrue(insufficientMemory.canInstall)

    let other = try XCTUnwrap(catalog.models.first { $0.id != gemma.id })
    let blocked = LocalModelSelector.assess(other, hardware: hardware(memory: 4))
    XCTAssertEqual(blocked.fit, .memory)
    XCTAssertTrue(blocked.permitsMemoryOverride)
    XCTAssertTrue(blocked.canInstall)
    XCTAssertFalse(blocked.fit.canRun, "Memory warnings must still exclude this model from automatic recommendations")
  }

  func testEveryFamilyHasAReviewedMemoryFloorAndRejectsMismatchedProfiles() throws {
    for model in catalog.models {
      let profile = try XCTUnwrap(model.resolvedProfile)
      let projector = try XCTUnwrap(model.projector)
      let required = profile.memory(weights: model.expectedByteCount, projector: projector.expectedByteCount, context: 8192)
      XCTAssertGreaterThanOrEqual(model.estimatedRuntimeMemory, required)
      XCTAssertThrowsError(try modifying(model, ["estimatedRuntimeMemory": required - 1]).validate())
      let incorrect = try modifying(model, ["chatTemplate": "another-family"])
      XCTAssertEqual(LocalModelSelector.assess(incorrect, hardware: hardware(memory: 128)).fit, .unsupported)
      let record = benchmark(model: model, hardware: hardware(memory: 128), speed: 2)
      XCTAssertTrue(record.isApplicable(to: hardware(memory: 128)))
      let measured = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 128), measurements: [record])
      XCTAssertTrue(try XCTUnwrap(measured.assessments.first { $0.id == model.id }).isMeasured)
      XCTAssertNotEqual(measured.recommended?.id, model.id)
    }
    XCTAssertEqual(LocalMultimodalProfile.ministral14B.cacheLayout.bytes(context: 8192, physicalBatch: 512), 1_342_177_280)
    XCTAssertEqual(LocalMultimodalProfile.gemma4E4B.cacheLayout.bytes(context: 8192, physicalBatch: 512), 308_281_344)
    let moe = try XCTUnwrap(catalog.models.first { $0.id == "gemma-4-26b-a4b-q4_k_m" })
    XCTAssertGreaterThan(moe.expectedByteCount, 14_000_000_000)
    XCTAssertGreaterThan(moe.estimatedRuntimeMemory, 19 * gib)
  }

  func testOldInstalledDescriptorDecodesWithoutDescriptionsOrProfilesAndKeepsPackageIdentity() throws {
    // The legacy fixture is pinned to an older runtime; re-pin it so the
    // decoded record can still be validated as a supported package.
    let model = try modifying(LegacyModelFixtures.models[0],
      ["runtimeBuild": LocalVisionRuntime.build, "minimumLlamaBuild": LocalVisionRuntime.build])
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    for key in ["publisher", "modelSummary", "inferenceProfile"] { json.removeValue(forKey: key) }
    let restored = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
    try restored.validate()
    XCTAssertEqual(restored.packageRevision, model.packageRevision)
    XCTAssertTrue(LocalModelCompatibility.supports(restored))
    XCTAssertFalse(LocalModelCompatibility.supports(LegacyModelFixtures.models[0]))
    XCTAssertFalse(restored.summary.isEmpty)
    XCTAssertEqual(restored.maker, "Alibaba / Qwen")
  }

  func testBudgetReservesOSMemoryAndHonorsMetalWorkingSet() {
    var mac = hardware(memory: 8)
    XCTAssertEqual(mac.inferenceMemoryBudget, 4 * gib)
    mac.physicalMemory = 4 * gib
    XCTAssertEqual(mac.inferenceMemoryBudget, 0)
    mac.physicalMemory = 64 * gib
    mac.metalRecommendedWorkingSet = 10 * gib
    XCTAssertEqual(mac.inferenceMemoryBudget, 8 * gib)
    mac.metalRecommendedWorkingSet = nil
    XCTAssertLessThanOrEqual(mac.inferenceMemoryBudget, mac.physicalMemory - mac.osReserve)
  }

  func testSafetyGatesCannotBeOutweighedByQualityAcrossMemoryAndDiskSizes() {
    for memory in [4, 8, 12, 16, 24, 32, 48, 64, 128] {
      for disk in [0, 4, 20, 100] {
        var mac = hardware(memory: memory)
        mac.availableDiskBytes = Int64(disk) * gib
        let results = LocalModelSelector.select(manifest: catalog, hardware: mac)
        XCTAssertEqual(results.roles.map(\.id), [results.recommended, results.faster, results.smarter].compactMap { $0?.id })
        for candidate in results.roles.map(\.assessment) {
          XCTAssertTrue(candidate.fit.canRun)
          XCTAssertLessThanOrEqual(candidate.model.estimatedRuntimeMemory, mac.inferenceMemoryBudget)
          XCTAssertGreaterThanOrEqual(mac.availableDiskBytes, candidate.model.downloadByteCount * 2 + 2 * gib)
          XCTAssertGreaterThanOrEqual(candidate.model.recommendedContextSize, 4_096)
        }
        if let recommended = results.recommended {
          XCTAssertTrue(recommended.isUsable)
          let fast = results.assessments.filter(\.isFast)
          if !fast.isEmpty {
            XCTAssertEqual(recommended.model.rankedQualityScore, fast.map(\.model.rankedQualityScore).max())
          }
        }
      }
    }
  }

  func testChipNamesDoNotControlSelectionAndCPUResourcesDo() throws {
    var mac = hardware(memory: 24)
    mac.performanceCPUCount = 12
    let first = LocalModelSelector.select(manifest: catalog, hardware: mac)
    mac.chip = "A future chip with an unknown name"
    XCTAssertEqual(first.recommended?.id, LocalModelSelector.select(manifest: catalog, hardware: mac).recommended?.id)
    mac.performanceCPUCount = 2
    mac.cpuCount = 2
    XCTAssertNotEqual(first.recommended?.id, LocalModelSelector.select(manifest: catalog, hardware: mac).recommended?.id)
    let recommended = try XCTUnwrap(first.recommended)
    if let faster = first.faster {
      XCTAssertGreaterThanOrEqual(faster.tokensPerSecond, recommended.tokensPerSecond * 1.5)
    }
    // At about 78 GB/s only Qwen3.5 4B Q4_K_M is fast. Gemma 4 12B is not, so
    // its candidate is its smallest usable package of IQ4_XS or better: IQ4_XS
    // (14 × 0.96 = 13.44, above 12.61).
    XCTAssertEqual(recommended.id, "qwen3.5-4b-q4_k_m")
    XCTAssertEqual(first.smarter?.id, "gemma-4-12b-iq4_xs")
    XCTAssertGreaterThan(try XCTUnwrap(first.smarter).model.rankedQualityScore, recommended.model.rankedQualityScore)
    XCTAssertEqual(first.roles.map(\.id), ["qwen3.5-4b-q4_k_m", "gemma-4-12b-iq4_xs"])
    XCTAssertEqual(Set(first.roles.map(\.id)).count, first.roles.count)
  }

  func testDiskCheckIncludesInstallerCopyButInstalledModelsRemainUsable() {
    var mac = hardware()
    let model = catalog.models[0]
    mac.availableDiskBytes = model.downloadByteCount * 2 + 2 * gib - 1
    XCTAssertEqual(LocalModelSelector.assess(model, hardware: mac).fit, .disk)
    XCTAssertTrue(LocalModelSelector.assess(model, hardware: mac, installed: true).fit.canRun)
    mac.availableDiskBytes += 1
    XCTAssertTrue(LocalModelSelector.assess(model, hardware: mac).fit.canRun)
  }

  func testCompatibilityRejectsUnsupportedArchitectureTemplateQuantizationContextAndBuild() throws {
    for fields: [String: Any] in [
      ["architecture": "qwen3"], ["chatTemplate": "unknown"], ["quantization": "IQ1_S"],
      ["recommendedContextSize": 2_048], ["minimumLlamaBuild": 99_999],
    ] {
      let model = try modifying(catalog.models[0], fields)
      XCTAssertEqual(LocalModelSelector.assess(model, hardware: hardware()).fit, .unsupported)
    }
    var mac = hardware()
    mac.metalMaximumBufferLength = 256 * 1_024 * 1_024
    XCTAssertEqual(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit, .unsupported)
    mac.hasUnifiedMemory = false
    XCTAssertEqual(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit, .unsupported)
    mac.hasMetal = false
    mac.isAppleSilicon = false
    XCTAssertTrue(LocalModelSelector.assess(catalog.models[0], hardware: mac).fit.canRun)
    mac.cpuCount = 1
    mac.performanceCPUCount = 1
    XCTAssertNil(LocalModelSelector.select(manifest: catalog, hardware: mac).recommended)
  }

  func testManifestRejectsMutableURLsBadHashesDuplicateIDsAndInvalidEstimates() throws {
    for fields: [String: Any] in [
      ["revision": "main"], ["downloadURL": "https://example.com/model.gguf"],
      ["checksumSHA256": "not-a-checksum"], ["expectedByteCount": -1],
      ["expectedByteCount": Int64.max], ["recommendedContextSize": Int.max], ["qualityScore": 101],
      ["estimatedRuntimeMemory": 1], ["minimumMemory": 1], ["parameterBillions": 0],
    ] {
      XCTAssertThrowsError(try modifying(catalog.models[0], fields).validate())
    }
    XCTAssertThrowsError(try LocalModelManifest(version: 1, models: [catalog.models[0], catalog.models[0]]).validate())
  }

  func testActualSlowdownChangesRecommendationAndSuggestsSmallerModel() throws {
    var mac = hardware(memory: 32)
    mac.measuredBandwidth = 200
    let original = LocalModelSelector.select(manifest: catalog, hardware: mac)
    let recommended = try XCTUnwrap(original.recommended)
    // The run also recalibrates every dense estimate, so it is slow enough to
    // miss the speed bar while smaller packages still pass it.
    let record = benchmark(model: recommended.model, hardware: mac, speed: 11, promptSpeed: 2_000)
    XCTAssertTrue(record.underperformed)
    let measured = LocalModelSelector.select(manifest: catalog, hardware: mac, measurements: [record])
    XCTAssertNotEqual(measured.recommended?.id, recommended.id)
    let current = try XCTUnwrap(measured.assessments.first { $0.id == recommended.id })
    XCTAssertTrue(current.isMeasured)
    XCTAssertEqual(current.tokensPerSecond, 11)
    XCTAssertFalse(current.isFast)
    XCTAssertEqual(LocalModelSelector.assess(recommended.model, hardware: mac,
      measurements: [benchmark(model: recommended.model, hardware: mac, speed: 4)]).fit, .slow)
    XCTAssertNotNil(measured.fasterAlternative(to: recommended.id))
    let alternative = try XCTUnwrap(measured.fasterAlternative(to: recommended.id))
    XCTAssertFalse(alternative.isMeasured)
  }

  func testMeasurementsAreScopedToMacRuntimeContextChecksumAgeAndPowerMode() throws {
    let mac = hardware()
    let model = catalog.models[0]
    let record = benchmark(model: model, hardware: mac, speed: 4)
    XCTAssertTrue(record.isApplicable(to: mac))
    var anotherMac = mac
    anotherMac.physicalMemory *= 2
    XCTAssertFalse(record.isApplicable(to: anotherMac))
    anotherMac = mac
    anotherMac.lowPowerMode = true
    XCTAssertFalse(record.isApplicable(to: anotherMac))
    XCTAssertFalse(record.isApplicable(to: mac, now: .now.addingTimeInterval(91 * 86_400)))
    let changedContext = try modifying(model, ["recommendedContextSize": 4_096])
    XCTAssertFalse(LocalModelSelector.assess(changedContext, hardware: mac, measurements: [record]).isMeasured)
    let changedChecksum = try modifying(model, ["checksumSHA256": String(repeating: "a", count: 64)])
    XCTAssertFalse(LocalModelSelector.assess(changedChecksum, hardware: mac, measurements: [record]).isMeasured)
  }

  func testFastRealMeasurementsCanPromoteASmarterModelWithoutOverridingMemorySafety() throws {
    var mac = hardware(memory: 24)
    mac.performanceCPUCount = 12
    let initial = LocalModelSelector.select(manifest: catalog, hardware: mac)
    let recommended = try XCTUnwrap(initial.recommended)
    let measurement = benchmark(model: recommended.model, hardware: mac, speed: 100, promptSpeed: 4_000)
    let learned = LocalModelSelector.select(manifest: catalog, hardware: mac, measurements: [measurement])
    let smarter = try XCTUnwrap(learned.recommended)
    XCTAssertGreaterThan(smarter.model.qualityScore, recommended.model.qualityScore)
    XCTAssertLessThanOrEqual(smarter.model.estimatedRuntimeMemory, mac.inferenceMemoryBudget)
    XCTAssertTrue(smarter.isFast)
  }

  func testMeasuredMemoryCanDisqualifyModelThatEstimatedToFit() {
    let mac = hardware()
    let model = catalog.models[0]
    let record = benchmark(model: model, hardware: mac, memory: mac.inferenceMemoryBudget + 1)
    XCTAssertEqual(LocalModelSelector.assess(model, hardware: mac, measurements: [record]).fit, .memory)
  }

  func testSignedCatalogAcceptsTrustedUpdateAndRejectsTamperingWrongKeyAndRollback() throws {
    let key = Curve25519.Signing.PrivateKey()
    let trust = LocalCatalogTrust(url: URL(string: "https://example.com/catalog.json")!, publicKey: key.publicKey.rawRepresentation)
    let updated = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    let signed = try signedData(updated, key: key)
    XCTAssertEqual(try trust.verify(signed, minimumVersion: 1), updated)
    XCTAssertThrowsError(try trust.verify(signed, minimumVersion: updated.version + 1))
    XCTAssertThrowsError(try trust.verify(signedData(updated, key: .init()), minimumVersion: 1))
    let envelope = try JSONDecoder().decode(SignedLocalModelCatalog.self, from: signed)
    let tampered = SignedLocalModelCatalog(payload: Data("tampered".utf8), signature: envelope.signature)
    XCTAssertThrowsError(try trust.verify(JSONEncoder().encode(tampered), minimumVersion: 1))
    XCTAssertThrowsError(try trust.verify(Data(repeating: 0, count: 1_048_577), minimumVersion: 1))
    let unsupported = LocalModelManifest(version: 3, models: [try modifying(catalog.models[0], ["architecture": "future"] )])
    let validButUnsupported = try trust.verify(signedData(unsupported, key: key), minimumVersion: 1)
    XCTAssertNil(LocalModelSelector.select(manifest: validButUnsupported, hardware: hardware()).recommended)
  }

  func testMonthlyCadenceAndCachedCatalogFallback() async throws {
    let root = try temporaryDirectory()
    let key = Curve25519.Signing.PrivateKey()
    let trust = LocalCatalogTrust(url: URL(string: "https://example.invalid/catalog.json")!, publicKey: key.publicKey.rawRepresentation)
    let updated = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    let now = Date()
    try signedData(updated, key: key).write(to: root.appending(path: "signed-model-catalog.json"))
    try JSONEncoder().encode(now).write(to: root.appending(path: "catalog-last-check.json"))
    let updater = LocalCatalogUpdater(directory: root, trust: trust)
    let cached = await updater.catalog(now: now)
    XCTAssertEqual(cached, updated)
    try Data("corrupt".utf8).write(to: root.appending(path: "signed-model-catalog.json"))
    let fallback = await updater.catalog(now: now)
    XCTAssertEqual(fallback, catalog)
    XCTAssertTrue(LocalCatalogUpdater.isDue(lastCheck: nil, now: now))
    XCTAssertFalse(LocalCatalogUpdater.isDue(lastCheck: now, now: now.addingTimeInterval(29 * 86_400)))
    XCTAssertTrue(LocalCatalogUpdater.isDue(lastCheck: now, now: now.addingTimeInterval(30 * 86_400)))
  }

  @MainActor
  func testFirstRunOnlyPresentsWithNoModelsAndDeveloperReplayDoesNotResetLibrary() async throws {
    let root = try temporaryDirectory()
    let suite = "ModelAdvisorTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = hardware()
    func makeAdvisor() -> LocalModelAdvisor {
      LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    }
    let advisor = makeAdvisor()
    await advisor.start(installedModels: [])
    XCTAssertTrue(advisor.isOnboardingPresented)
    XCTAssertNotNil(advisor.hardware)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "hardware.json").path))
    advisor.dismissOnboarding()
    let restored = makeAdvisor()
    await restored.start(installedModels: [])
    XCTAssertFalse(restored.isOnboardingPresented)
    await restored.replayOnboarding()
    XCTAssertTrue(restored.isOnboardingPresented)
    defaults.removeObject(forKey: "localModelOnboardingDismissed")
    let installed = LocalModel(id: "existing", displayName: "Existing", fileURL: root.appending(path: "existing.gguf"))
    let upgrading = makeAdvisor()
    await upgrading.start(installedModels: [installed])
    XCTAssertFalse(upgrading.isOnboardingPresented)
    let selection = upgrading.recommendations(installedModels: [installed])
    XCTAssertNotNil(selection.recommended)
  }

  @MainActor
  func testBenchmarksPersistLocallyAndDoNotChangeSelectedModel() async throws {
    let root = try temporaryDirectory()
    let profile = hardware()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let descriptor = catalog.models[0]
    let source = root.appending(path: "test.gguf")
    try Data("fixture".utf8).write(to: source)
    let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
    let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: source, catalogDescriptor: descriptor))
    XCTAssertEqual(store.installedModel()?.catalogDescriptor, descriptor)
    advisor.record(benchmark(model: descriptor, hardware: profile).metrics, model: installed, prediction: nil)
    let restored = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await restored.detectHardware()
    XCTAssertEqual(restored.measurements, advisor.measurements)
    XCTAssertNotNil(restored.latestBenchmark(for: installed))
    XCTAssertEqual(store.installedModel(), installed)
  }

  @MainActor
  func testRecordedBenchmarksKeepActiveParameters() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 64)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let descriptor = try XCTUnwrap(catalog.models.first { $0.id == "gemma-4-26b-a4b-q4_k_m" })
    let source = root.appending(path: "test.gguf")
    try Data("fixture".utf8).write(to: source)
    let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
    let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: source, catalogDescriptor: descriptor))
    advisor.record(benchmark(model: descriptor, hardware: profile).metrics, model: installed, prediction: nil)
    let saved = try JSONDecoder().decode([LocalModelBenchmark].self,
      from: Data(contentsOf: root.appending(path: "benchmarks.json")))
    XCTAssertEqual(saved.last?.activeParameterBillions, 3.8)
    XCTAssertEqual(saved.last?.isMixtureOfExperts, true)
  }

  @MainActor
  func testBenchmarksOfInstallsSavedBefore011RecordTheProfilesActiveParameters() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 64)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let current = try XCTUnwrap(catalog.models.first { $0.id == "gemma-4-26b-a4b-q4_k_m" })
    // An installed record written by 0.10.x: no active parameters, old total.
    let legacy = try modifying(current, ["parameterBillions": 26.0])
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    json.removeValue(forKey: "activeParameterBillions")
    let descriptor = try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
    let source = root.appending(path: "test.gguf")
    try Data("fixture".utf8).write(to: source)
    let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
    let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: source, catalogDescriptor: descriptor))
    advisor.record(benchmark(model: descriptor, hardware: profile).metrics, model: installed, prediction: nil)
    let saved = try XCTUnwrap(advisor.measurements.last)
    XCTAssertEqual(saved.activeParameterBillions, 3.8)
    XCTAssertEqual(saved.isMixtureOfExperts, true)
  }

  @MainActor
  func testOnboardingAndModelManagerRenderWithRealSelectionResults() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    try render(LocalModelOnboardingView(advisor: advisor, chat: chat).enigmaTheme(.paper),
               size: NSSize(width: 560, height: 650), name: "local-model-onboarding")
    try render(LocalModelManagerSection(advisor: advisor, chat: chat).padding(24)
                 .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                 .background(EnigmaPalette.paper.background.color).enigmaTheme(.paper),
               size: NSSize(width: 560, height: 740), name: "local-model-manager")
  }

  @MainActor
  func testInstallationBenchmarksBeforeAllowingChatAndKeepsSelectionOnSlowResult() async throws {
    let root = try temporaryDirectory()
    let mac = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in mac })
    await advisor.detectHardware()
    let candidate = try XCTUnwrap(advisor.recommendations(installedModels: []).recommended)
    let started = expectation(description: "Benchmark started after installation")
    let engine = SelectionWorkflowEngine(started: { started.fulfill() })
    let chat = LocalChatViewModel(engine: engine, modelAdvisor: advisor,
      sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let finished = expectation(description: "Installation and benchmark finished")
    let subscription = chat.$modelOperation.dropFirst().sink { if $0 == nil { finished.fulfill() } }
    defer { subscription.cancel() }
    chat.downloadModel(candidate.model)
    await fulfillment(of: [started], timeout: 3)
    XCTAssertEqual(chat.modelOperation, .benchmarking)
    XCTAssertTrue(chat.isBusy, "The performance check needs the engine to itself")
    XCTAssertEqual(chat.installedModel?.id, candidate.id)
    chat.submit("Must not start while benchmarking")
    chat.downloadModel(catalog.models[0])
    XCTAssertTrue(chat.messages.isEmpty)
    let downloads = await engine.downloadCount
    XCTAssertEqual(downloads, 1)
    await engine.finish(benchmark(model: candidate.model, hardware: mac, speed: 4).metrics)
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(chat.installedModel?.id, candidate.id)
    XCTAssertEqual(advisor.measurements.count, 1)
    XCTAssertTrue(try XCTUnwrap(advisor.latestBenchmark(for: chat.installedModel)).underperformed)
    XCTAssertFalse(chat.isBusy)
  }

  @MainActor
  func testBenchmarkFailureAndCancellationKeepVerifiedInstallationUsable() async throws {
    for cancel in [false, true] {
      let root = try temporaryDirectory()
      let mac = hardware()
      let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in mac })
      await advisor.detectHardware()
      let started = expectation(description: "Benchmark started")
      let engine = SelectionWorkflowEngine(started: { started.fulfill() })
      let chat = LocalChatViewModel(engine: engine, modelAdvisor: advisor,
        sessionStore: ChatSessionStore(applicationSupportDirectory: root))
      let finished = expectation(description: "Benchmark error acknowledged")
      let subscription = chat.$modelOperation.dropFirst().sink { if $0 == nil { finished.fulfill() } }
      chat.downloadModel(catalog.models[0])
      await fulfillment(of: [started], timeout: 3)
      if cancel { chat.cancelInstallation() }
      await engine.finish(nil)
      await fulfillment(of: [finished], timeout: 3)
      subscription.cancel()
      XCTAssertNotNil(chat.installedModel)
      XCTAssertFalse(chat.isBusy)
      XCTAssertTrue(advisor.measurements.isEmpty)
      XCTAssertTrue(chat.benchmarkNotice?.contains(cancel ? "cancelled" : "Performance check:") == true)
    }
  }

  @MainActor
  func testDownloadConfirmationRechecksCurrentResources() async throws {
    let root = try temporaryDirectory()
    var mac = hardware()
    mac.availableDiskBytes = 0
    let current = mac
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in current })
    do {
      _ = try await advisor.confirmDownload(catalog.models[0], installedModels: [])
      XCTFail("Must reject a model when disk space is no longer available")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("resources"))
    }
  }

  @MainActor
  func testRetiredGemmaPackageIsNotOfferedForNewDownload() async throws {
    let root = try temporaryDirectory()
    let profile = hardware(memory: 24)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, trust: nil, detect: { _ in profile })
    let gemma = try XCTUnwrap(LegacyModelFixtures.models.first { $0.id == "gemma-4-12b-it-qat-q4_0-gguf" })

    do {
      _ = try await advisor.confirmDownload(gemma, installedModels: [])
      XCTFail("Retired packages must not be offered for new installation")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("resources"))
    }
  }

  @MainActor
  private func render<V: View>(_ root: V, size: NSSize, name: String, roundedWindow: Bool = false) throws {
    let view = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    if roundedWindow {
      for (x, y) in [(0, 0), (image.pixelsWide - 1, 0), (0, image.pixelsHigh - 1), (image.pixelsWide - 1, image.pixelsHigh - 1)] {
        XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent, 0.05, "Window corners must stay transparent")
      }
      XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)).alphaComponent, 0.95)
    }
    let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    try png.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testVerifiedDownloadUsesExistingAtomicInstallerAndFailuresKeepOldModel() async throws {
    let bytes = Data("GGUF test transport bytes".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    for scenario in ["valid", "checksum", "truncated", "overlong", "http", "disk"] {
      let root = try temporaryDirectory()
      let store = LocalModelInstallationStore(modelsDirectory: root.appending(path: "models"))
      let source = root.appending(path: "old.gguf")
      try Data("old model".utf8).write(to: source)
      let old = try store.install(LocalModel(id: "old", displayName: "Old", fileURL: source))
      var components = try XCTUnwrap(URLComponents(url: catalog.models[0].downloadURL, resolvingAgainstBaseURL: false))
      components.query = "fixture=\(UUID())"
      let url = try XCTUnwrap(components.url)
      let descriptor = try modifying(catalog.models[0], [
        "downloadURL": url.absoluteString, "expectedByteCount": bytes.count,
        "checksumSHA256": scenario == "checksum" ? String(repeating: "0", count: 64) : hash,
      ])
      let body = scenario == "truncated" ? bytes.dropLast() : scenario == "overlong" ? bytes + Data([0]) : bytes
      ModelTransportProtocol.responses.set(url, body: Data(body), status: scenario == "http" ? 503 : 200)
      let session = fixtureSession()
      defer { session.invalidateAndCancel() }
      let mac = hardware()
      let download = LocalModelCatalog(installationStore: store, session: session,
        detectHardware: { _ in mac }, availableDisk: { _ in scenario == "disk" ? 0 : 200 * LocalHardwareProfile.gib })
      do {
        if scenario == "disk" {
          _ = try await download.download(descriptor) { _ in }
          XCTFail("Expected real disk gate to reject installation")
        }
        let staged = root.appending(path: "verified.gguf")
        try await VerifiedModelArtifact(url: url, expectedByteCount: Int64(bytes.count),
          checksumSHA256: descriptor.checksumSHA256).download(to: staged, session: session, policy: .immediate) { _ in }
        let installed = try store.install(LocalModel(id: descriptor.id, displayName: descriptor.displayName,
          fileURL: staged, catalogDescriptor: descriptor))
        XCTAssertEqual(scenario, "valid")
        XCTAssertEqual(try Data(contentsOf: installed.fileURL), bytes)
        XCTAssertEqual(installed.catalogDescriptor, descriptor)
        XCTAssertEqual(store.installedModel(), installed)
      } catch {
        XCTAssertNotEqual(scenario, "valid", "\(error)")
        XCTAssertEqual(store.installedModel(), old)
      }
      XCTAssertEqual(try Data(contentsOf: old.fileURL), Data("old model".utf8))
      let files = try FileManager.default.contentsOfDirectory(atPath: store.modelsDirectoryURL.path)
      XCTAssertFalse(files.contains { $0.hasPrefix(".downloading") || $0.hasPrefix(".installing") })
    }
  }

  func testRemoteRefreshCachesOnlyVerifiedUpdatesAndRetainsCacheAfterFailure() async throws {
    let root = try temporaryDirectory()
    let key = Curve25519.Signing.PrivateKey()
    let url = URL(string: "https://example.com/\(UUID())/catalog.json")!
    let trust = LocalCatalogTrust(url: url, publicKey: key.publicKey.rawRepresentation)
    let session = fixtureSession()
    defer { session.invalidateAndCancel() }
    let updater = LocalCatalogUpdater(directory: root, trust: trust, session: session)
    let next = LocalModelManifest(version: catalog.version + 1, models: catalog.models)
    ModelTransportProtocol.responses.set(url, body: try signedData(next, key: key))
    let refreshed = await updater.catalog(force: true)
    XCTAssertEqual(refreshed, next)
    let cacheURL = root.appending(path: "signed-model-catalog.json")
    let cache = try Data(contentsOf: cacheURL)
    ModelTransportProtocol.responses.set(url, body: Data("invalid signature".utf8))
    let untrusted = await updater.catalog(force: true)
    XCTAssertEqual(untrusted, next)
    XCTAssertEqual(try Data(contentsOf: cacheURL), cache)
    ModelTransportProtocol.responses.set(url, body: Data(), status: 503)
    let unavailable = await updater.catalog(force: true)
    XCTAssertEqual(unavailable, next)
    XCTAssertEqual(try Data(contentsOf: cacheURL), cache)
    ModelTransportProtocol.responses.set(url, body: try signedData(catalog, key: key))
    let rollback = await updater.catalog(force: true)
    XCTAssertEqual(rollback, next)
  }

  private func fixtureSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelTransportProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func hardware(memory: Int = 16) -> LocalHardwareProfile {
    LocalHardwareProfile(physicalMemory: Int64(memory) * gib, isAppleSilicon: true, hasMetal: true,
      hasUnifiedMemory: true, chip: "Fixture chip", device: "Fixture Mac", cpuCount: 12, performanceCPUCount: 8,
      availableDiskBytes: 200 * gib, metalRecommendedWorkingSet: nil, metalMaximumBufferLength: 8 * gib, lowPowerMode: false)
  }

  private func modifying(_ model: LocalModelDescriptor, _ fields: [String: Any]) throws -> LocalModelDescriptor {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
    json.merge(fields) { _, new in new }
    return try JSONDecoder().decode(LocalModelDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func benchmark(model: LocalModelDescriptor, hardware: LocalHardwareProfile, speed: Double = 20,
                         memory: Int64 = 2_000_000_000, promptSpeed: Double = 100) -> LocalModelBenchmark {
    LocalModelBenchmark(version: 1, llamaBuild: model.runtimeBuild ?? LocalModelCompatibility.llamaBuild,
      hardwareFingerprint: hardware.fingerprint, lowPowerMode: hardware.lowPowerMode,
      modelID: model.id, modelChecksum: model.checksumSHA256, modelByteCount: model.expectedByteCount,
      parameterBillions: model.parameterBillions, architecture: model.architecture, contextSize: model.recommendedContextSize,
      recordedAt: .now, metrics: LocalBenchmarkMetrics(timeToFirstToken: 1,
        generationTokensPerSecond: speed, promptTokensPerSecond: promptSpeed, peakMemoryBytes: memory,
        promptTokenCount: 140, generatedTokenCount: 64, modelLoadSeconds: 0.5),
      predictedTokensPerSecond: 20, predictedTimeToFirstToken: 1)
  }

  private func signedData(_ manifest: LocalModelManifest, key: Curve25519.Signing.PrivateKey) throws -> Data {
    let payload = try JSONEncoder().encode(manifest)
    return try JSONEncoder().encode(SignedLocalModelCatalog(payload: payload, signature: key.signature(for: payload)))
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "LocalSelectionTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

private actor SelectionTestEngine: LocalModelEngine {
  func install(_ model: LocalModel) async throws {}
  func installedModel() async -> LocalModel? { nil }
  func installedModels() async -> [LocalModel] { [] }
  func selectModel(id: String) async throws {}
  func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    throw LocalInferenceError.invalidModelFile
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private actor SelectionWorkflowEngine: LocalModelEngine {
  var model: LocalModel?
  var downloadCount = 0
  let started: @Sendable () -> Void
  private var continuation: CheckedContinuation<LocalBenchmarkMetrics?, Never>?

  init(started: @escaping @Sendable () -> Void) { self.started = started }
  func install(_ model: LocalModel) async throws { self.model = model }
  func installedModel() async -> LocalModel? { model }
  func installedModels() async -> [LocalModel] { model.map { [$0] } ?? [] }
  func selectModel(id: String) async throws {}
  func download(_ descriptor: LocalModelDescriptor, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> LocalModel {
    downloadCount += 1
    let model = LocalModel(id: descriptor.id, displayName: descriptor.displayName,
      fileURL: URL(fileURLWithPath: "/tmp/selection-fixture.gguf"), catalogDescriptor: descriptor)
    self.model = model
    return model
  }
  func benchmark() async throws -> LocalBenchmarkMetrics? {
    let result = await withCheckedContinuation { continuation in
      self.continuation = continuation
      started()
    }
    try Task.checkCancellation()
    guard let result else { throw LocalInferenceError.bridgeFailure("Fixture benchmark failed") }
    return result
  }
  func finish(_ result: LocalBenchmarkMetrics?) {
    continuation?.resume(returning: result)
    continuation = nil
  }
  nonisolated func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { $0.finish() }
  }
  func unload() async {}
}

private final class ModelTransportProtocol: URLProtocol, @unchecked Sendable {
  static let responses = Responses()

  final class Responses: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL: (Data, Int)] = [:]
    func set(_ url: URL, body: Data, status: Int = 200) {
      lock.lock()
      defer { lock.unlock() }
      items[url] = (body, status)
    }
    func take(_ url: URL) -> (Data, Int)? {
      lock.lock()
      defer { lock.unlock() }
      return items.removeValue(forKey: url)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let (body, status) = Self.responses.take(url),
          let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension LocalModelSelectionTests {
  @MainActor
  private func welcomeDefaults() throws -> UserDefaults {
    let name = "WelcomeSetupTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return defaults
  }

  @MainActor
  func testWelcomeResumesIncompleteSetupAndCompletionPersists() throws {
    let defaults = try welcomeDefaults()
    let setup = WelcomeSetup(defaults: defaults)
    setup.start(hasInstalledModels: false)
    XCTAssertTrue(setup.isPresented)
    XCTAssertEqual(setup.step, .welcome)
    setup.step = .connections
    let resumed = WelcomeSetup(defaults: defaults)
    resumed.start(hasInstalledModels: true)
    XCTAssertTrue(resumed.isPresented)
    XCTAssertEqual(resumed.step, .connections)
    resumed.finish(takeTour: false)
    XCTAssertFalse(resumed.isPresented)
    XCTAssertNil(resumed.tour)
    XCTAssertNil(defaults.object(forKey: WelcomeSetup.progressKey))
    let completed = WelcomeSetup(defaults: defaults)
    completed.start(hasInstalledModels: false)
    XCTAssertFalse(completed.isPresented)
  }

  @MainActor
  func testWelcomeMigrationAndReplayPreserveExistingPreferences() throws {
    for hasModel in [false, true] {
      let defaults = try welcomeDefaults()
      defaults.set(!hasModel, forKey: "localModelOnboardingDismissed")
      defaults.set("cloud", forKey: StartPreferences.modeKey)
      let setup = WelcomeSetup(defaults: defaults)
      setup.start(hasInstalledModels: hasModel)
      XCTAssertFalse(setup.isPresented)
      setup.replay()
      XCTAssertTrue(setup.isPresented)
      XCTAssertEqual(setup.step, .welcome)
      XCTAssertEqual(defaults.string(forKey: StartPreferences.modeKey), "cloud")
      setup.finish(takeTour: true)
      for step in WelcomeTourStep.allCases {
        XCTAssertEqual(setup.tour, step)
        setup.nextTourStep()
      }
      XCTAssertNil(setup.tour)
      setup.replay()
      setup.finish(takeTour: true)
      setup.endTour()
      XCTAssertNil(setup.tour)
    }
  }

  @MainActor
  func testWelcomeShowsTheRolesInOrder() {
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(bandwidth: 200))
    XCTAssertEqual(WelcomeSetup.choices(recs).map(\.id), recs.roles.map(\.id))
    XCTAssertEqual(WelcomeSetup.choices(recs).count, 3)
  }

  @MainActor
  func testWelcomeKeepsChosenModelVisibleAfterRecommendationChanges() throws {
    let recs = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(bandwidth: 200))
    XCTAssertEqual(WelcomeSetup.choices(recs, preserving: "mid-q4_k_m").map(\.id),
                   ["mid-q8_0", "small-q4_k_m", "mid-q4_k_m"])
    let limited = LocalModelSelector.select(manifest: familyManifest, hardware: familyMac(memoryGiB: 4, bandwidth: 200))
    XCTAssertTrue(WelcomeSetup.choices(limited, preserving: "mid-q4_k_m").isEmpty)
  }

  @MainActor
  func testWelcomeNextRequiresVerifiedSelectedInstallationOrExplicitSkip() throws {
    let recommendations = LocalModelSelector.select(manifest: catalog, hardware: hardware(memory: 32))
    let selected = try XCTUnwrap(WelcomeSetup.choices(recommendations).first)
    let descriptor = selected.model
    let file = URL(fileURLWithPath: "/tmp/welcome-fixture.gguf")
    let installed = LocalModel(id: selected.id, displayName: descriptor.displayName, fileURL: file,
      catalogDescriptor: descriptor, visionConfiguration: LocalVisionConfiguration(projectorURL: file,
        serverExecutableURL: URL(fileURLWithPath: "/bin/echo"), contextWindow: descriptor.recommendedContextSize,
        packageRevision: descriptor.packageRevision))
    XCTAssertTrue(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: selected.id, skipLocal: false, busy: false))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: "other", skipLocal: false, busy: false))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [], activeID: selected.id, skipLocal: false, busy: false))
    var stale = installed
    stale.visionConfiguration?.packageRevision = "old"
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [stale], activeID: selected.id, skipLocal: false, busy: false))
    for busy in [false, true] {
      XCTAssertEqual(WelcomeSetup.canContinue(selected: nil, installed: [], activeID: nil, skipLocal: true, busy: busy), !busy)
    }
    XCTAssertFalse(WelcomeSetup.canContinue(selected: selected, installed: [installed], activeID: selected.id, skipLocal: false, busy: true))
    XCTAssertFalse(WelcomeSetup.canContinue(selected: nil, installed: [], activeID: nil, skipLocal: false, busy: false))
  }

  @MainActor
  func testWelcomeSuppressesLegacyAutomaticModelSheet() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let mac = hardware()
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in mac })
    await advisor.start(installedModels: [], presentOnboarding: false)
    XCTAssertNotNil(advisor.hardware)
    XCTAssertFalse(advisor.isOnboardingPresented)
    await advisor.replayOnboarding()
    XCTAssertTrue(advisor.isOnboardingPresented)
  }

  @MainActor
  func testChatBecomesEditableImmediatelyAfterEveryWelcomeExit() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let screen = ScreenComposerCoordinator()
    addTeardownBlock { @MainActor in
      await chat.stopStreaming()?.value
      await chat.sessionWriter.waitForPendingWrites()
    }
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let setup = WelcomeSetup(defaults: defaults)
    let preferences = StartPreferences(defaults: defaults)
    preferences.mode = .cloud
    let view = NSHostingView(rootView: AppShellView(cloudSettings: cloud,
      localChat: chat, screen: screen, modelAdvisor: advisor,
      searchSettings: WebSearchSettings(credentials: WelcomeEmptySearchCredentials(), defaults: defaults),
      startPreferences: preferences, welcomeSetup: setup, appearance: EnigmaAppearancePreference(defaults: defaults))
      .transaction { $0.disablesAnimations = true })
    let controller = SpotlightPanelController(sizeStore: PanelSizeStore(defaults: defaults),
      contentView: view, welcomeSetup: setup)
    controller.show()
    defer { controller.hide(); view.window?.contentView = nil }
    try await waitForUI("welcome host to install the composer", in: view) { composerEditor(in: view) != nil }
    for exit in 0..<3 {
      setup.replay()
      try await waitForUI("welcome replay to disable the composer", in: view) {
        composerEditor(in: view)?.isEditable == false
      }
      XCTAssertFalse(try XCTUnwrap(composerEditor(in: view)).isEditable)
      setup.finish(takeTour: exit != 0)
      if exit == 1 { setup.endTour() }
      if exit == 2 {
        for _ in WelcomeTourStep.allCases { setup.nextTourStep() }
      }
      try await waitForUI("welcome exit \(exit) to enable, focus, and uncover the composer", in: view) {
        guard let composer = composerEditor(in: view) else { return false }
        return composer.isEditable && composer.window?.firstResponder === composer && composerAcceptsClicks(in: view)
      }
      let composer = try XCTUnwrap(composerEditor(in: view))
      XCTAssertTrue(composer.isEditable, "Welcome exit \(exit) must enable the composer")
      XCTAssertTrue(composer.window?.firstResponder === composer, "Welcome exit \(exit) must focus the composer")
      XCTAssertEqual(preferences.mode, .auto)
      // NSView.hitTest takes a point in the receiver's superview coordinates.
      let point = composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: view.superview)
      let hit = try XCTUnwrap(view.hitTest(point))
      XCTAssertTrue(hit === composer || hit.isDescendant(of: composer), "Welcome exit \(exit) must allow clicks through to chat; hit \(hit), point \(point)")
      let draft = "Ready to chat after exit \(exit)"
      composer.insertText(draft, replacementRange: NSRange(location: 0, length: composer.string.utf16.count))
      XCTAssertEqual(composer.string, draft)
      XCTAssertEqual(screen.draft, draft, "Typing must reach the composer binding after every exit")
    }
  }

  @MainActor
  func testWelcomeScreensRenderAtMinimumAndDefaultPanelSizes() async throws {
    let root = try temporaryDirectory()
    let defaults = try welcomeDefaults()
    let profile = hardware(memory: 32)
    let advisor = LocalModelAdvisor(directory: root, modelsDirectory: root, defaults: defaults, trust: nil, detect: { _ in profile })
    await advisor.detectHardware()
    let chat = LocalChatViewModel(engine: SelectionTestEngine(), sessionStore: ChatSessionStore(applicationSupportDirectory: root))
    let credentials = ScreenTestCredentialStore()
    let cloud = CloudSettingsModel(credentialStore: credentials,
      catalog: CloudModelCatalog(credentialStore: credentials, transport: ScreenTestTransport(), cacheDirectory: root),
      preferences: CloudPreferencesStore(defaults: defaults), codexAvailable: { false })
    let search = WebSearchSettings(credentials: WelcomeEmptySearchCredentials(), defaults: defaults)
    let setup = WelcomeSetup(defaults: defaults)
    setup.replay()
    for step in WelcomeSetup.Step.allCases {
      setup.step = step
      for size in [NSSize(width: 640, height: 420), NSSize(width: 1000, height: 780)] {
        let character = EnigmaCharacterController(seed: 3)
        try render(WelcomeSetupView(setup: setup, character: character, advisor: advisor, chat: chat, cloud: cloud,
                                    search: search).enigmaCharacterStage(character).enigmaTheme(.paper),
                   size: size, name: "welcome-\(step)-\(Int(size.width))", roundedWindow: true)
      }
    }
    try render(SettingsView(settings: cloud, updater: AppUpdater(backend: FakeUpdaterBackend())).enigmaTheme(.paper),
               size: NSSize(width: 820, height: 680), name: "settings-permissions")
    try render(SettingsView(settings: cloud, initialDestination: .selection,
                            updater: AppUpdater(backend: FakeUpdaterBackend())).enigmaTheme(.paper),
               size: NSSize(width: 820, height: 680), name: "selection-permissions")
    setup.step = .welcome
    let shell = AppShellView(cloudSettings: cloud,
      localChat: chat, modelAdvisor: advisor, searchSettings: search,
      startPreferences: StartPreferences(defaults: defaults), welcomeSetup: setup,
      appearance: EnigmaAppearancePreference(defaults: defaults))
    try render(shell, size: NSSize(width: 640, height: 420), name: "welcome-window-rounded", roundedWindow: true)
    setup.finish(takeTour: true)
    for sidebar in [false, true] {
      let preferences = StartPreferences(defaults: defaults)
      preferences.showsSidebar = sidebar
      for step in WelcomeTourStep.allCases {
        // Rewind without changing any chat or account state.
        setup.replay()
        setup.finish(takeTour: true)
        for _ in 0..<step.rawValue { setup.nextTourStep() }
        let view = AppShellView(cloudSettings: cloud,
          localChat: chat, modelAdvisor: advisor, searchSettings: search, startPreferences: preferences, welcomeSetup: setup,
          appearance: EnigmaAppearancePreference(defaults: defaults))
        try render(view, size: NSSize(width: 1000, height: 780), name: "welcome-tour-\(step)-\(sidebar)")
        try render(view, size: NSSize(width: 640, height: 420), name: "welcome-tour-small-\(step)-\(sidebar)")
      }
    }
  }
}

private struct WelcomeEmptySearchCredentials: WebSearchCredentialStore {
  func apiKey() throws -> String? { nil }
  func setAPIKey(_ value: String) throws {}
  func removeAPIKey() throws {}
}


// Official publisher GGUF/LFS metadata and llama.cpp b10797 reviewed 2026-09-06.
// See docs/Local-Model-Selection.md for evidence, memory policy and limitations.
// Retired packages are fixtures for decoding and memory-override compatibility only.
private enum LegacyModelFixtures {
  static let models: [LocalModelDescriptor] = [
    LocalModelDescriptor(
      id: "qwen3-vl-4b-instruct-q4-k-m", displayName: "Qwen3-VL 4B Instruct",
      downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/1cd86afb9a95c410a6038ab3b40d8b578c892266/Qwen3VL-4B-Instruct-Q4_K_M.gguf")!,
      expectedByteCount: 2497281664, license: "Apache-2.0", checksumSHA256: "66358cb18bb6b3b1b6675aa412c7a88ef01d228f481184d13668e5201c730a0a",
      revision: "1cd86afb9a95c410a6038ab3b40d8b578c892266", quantization: "Q4_K_M", architecture: "qwen3vl",
      chatTemplate: "qwen3-vl-instruct", minimumLlamaBuild: 10797,
      estimatedRuntimeMemory: LocalModelDescriptor.multimodalMemory(weights: 2497281664, projector: 836180256, parameters: 4, context: 8192),
      largestTensorBytes: LocalHardwareProfile.gib, recommendedContextSize: 8192,
      qualityScore: 76, performanceClass: "General text and visual reasoning", parameterBillions: 4,
      minimumMemory: 12 * LocalHardwareProfile.gib, recommendedMemory: 16 * LocalHardwareProfile.gib,
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/1cd86afb9a95c410a6038ab3b40d8b578c892266/mmproj-Qwen3VL-4B-Instruct-F16.gguf")!,
        expectedByteCount: 836180256, checksumSHA256: "256f3a43bd4205ffef48d6b92715e1e70b5b0e9aef06522584967513a9985331"), runtimeBuild: 10797, publisher: "Alibaba / Qwen", modelSummary: "An efficient Alibaba model for everyday chat, reading screenshots and visual questions."),
    package(id: "gemma-4-12b-it-qat-q4_0-gguf", name: "Google Gemma 4 12B", publisher: "Google",
      summary: "A mid-sized Google model for stronger reasoning, writing and image understanding on higher-memory Macs.", profile: .gemma4_12B, quality: 89, minimumGiB: 32, recommendedGiB: 48,
      revision: "29d097773436b69ff9feafd636ab4cf873786537", model: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/29d097773436b69ff9feafd636ab4cf873786537/gemma-4-12b-it-qat-q4_0.gguf")!,
        expectedByteCount: 6975879296, checksumSHA256: "93567e57a8fe10b23569b9d9ec38cd005deedf71e29477c421a4b83f418a538b"),
      projector: VerifiedModelArtifact(url: URL(string: "https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf/resolve/29d097773436b69ff9feafd636ab4cf873786537/mmproj-gemma-4-12b-it-qat-q4_0.gguf")!,
        expectedByteCount: 175115616, checksumSHA256: "cb018338a7538a9814d994bfe54644c71eb7ed54e31eae2f721e45fd3c260da7")),
  ]

  private static func package(id: String, name: String, publisher: String, summary: String,
    profile: LocalMultimodalProfile, quality: Double, minimumGiB: Int64, recommendedGiB: Int64,
    revision: String, model: VerifiedModelArtifact, projector: VerifiedModelArtifact) -> LocalModelDescriptor {
    LocalModelDescriptor(id: id, displayName: name, downloadURL: model.url,
      expectedByteCount: model.expectedByteCount, license: "Apache-2.0", checksumSHA256: model.checksumSHA256,
      revision: revision, quantization: profile.quantizations[0], architecture: profile.architecture,
      chatTemplate: profile.chatTemplate, minimumLlamaBuild: LocalVisionRuntime.build,
      estimatedRuntimeMemory: profile.memory(weights: model.expectedByteCount, projector: projector.expectedByteCount, context: 8192),
      largestTensorBytes: (profile.architecture == "gemma4" ? 3 : 1) * LocalHardwareProfile.gib,
      recommendedContextSize: 8192, qualityScore: quality, performanceClass: "General text and visual reasoning",
      parameterBillions: profile.parameters, minimumMemory: minimumGiB * LocalHardwareProfile.gib,
      recommendedMemory: recommendedGiB * LocalHardwareProfile.gib, projector: projector,
      runtimeBuild: LocalVisionRuntime.build, publisher: publisher, modelSummary: summary, inferenceProfile: profile)
  }
}
