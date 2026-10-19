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
}
