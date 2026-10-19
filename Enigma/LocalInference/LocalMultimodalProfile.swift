import Foundation

/// F16 K and V cache shape, read from the model's GGUF header.
struct LocalCacheLayout: Sendable, Equatable {
  var fullLayers: Int
  var fullKVHeads: Int
  var fullHeadDimension: Int
  var slidingLayers = 0
  var slidingKVHeads = 0
  var slidingHeadDimension = 0
  var slidingWindow = 0

  /// Full layers hold `context` tokens; sliding layers hold
  /// min(context, roundUp(slidingWindow + physicalBatch, 256)), which is how
  /// llama.cpp sizes a sliding-window cache without `--swa-full`.
  /// 4 bytes per head dimension (K + V at F16).
  func bytes(context: Int, physicalBatch: Int) -> Int64 {
    let full = Int64(fullLayers * fullKVHeads * fullHeadDimension * 4) * Int64(context)
    guard slidingLayers > 0 else { return full }
    let window = min(context, (slidingWindow + physicalBatch + 255) / 256 * 256)
    return full + Int64(slidingLayers * slidingKVHeads * slidingHeadDimension * 4) * Int64(window)
  }
}

/// Reviewed against publisher configs and the pinned runtime. Cache layouts
/// come from each model's GGUF header (`scripts/gguf-header.py`); Gemma's global
/// layers share K and V in the model but are counted separately here, which
/// keeps the estimate conservative.
enum LocalMultimodalProfile: String, Codable, CaseIterable, Sendable {
  case qwen3VL4B, qwen3VL8B, qwen3VL32B
  case gemma4E2B, gemma4E4B, gemma4_12B, gemma4A4B, gemma4_31B
  case ministral3B, ministral8B, ministral14B
  case miniCPMV4, miniCPMV45
  case smolVLM2, qwen35_4B, qwen35_9B, miniCPMO45
  case qwen35_2B, qwen36_35BA3B, qwen38_27B

  static let defaultPhysicalBatch = 512

  static func legacyQwen(parameters: Double) -> Self? {
    switch parameters { case 4: .qwen3VL4B; case 8: .qwen3VL8B; case 32: .qwen3VL32B; default: nil }
  }

  var architecture: String {
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .qwen3VL32B: "qwen3vl"
    case .gemma4E2B, .gemma4E4B, .gemma4_12B, .gemma4A4B, .gemma4_31B: "gemma4"
    case .ministral3B, .ministral8B, .ministral14B: "mistral3"
    case .miniCPMV4: "llama"
    case .miniCPMV45, .miniCPMO45: "qwen3"
    case .smolVLM2: "llama"
    case .qwen35_2B, .qwen35_4B, .qwen35_9B, .qwen38_27B: "qwen35"
    case .qwen36_35BA3B: "qwen35moe"
    }
  }

  var chatTemplate: String {
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .qwen3VL32B: "qwen3-vl-instruct"
    case .gemma4E2B, .gemma4E4B, .gemma4_12B, .gemma4A4B, .gemma4_31B: "gemma4-instruct"
    case .ministral3B, .ministral8B, .ministral14B: "ministral3-instruct"
    case .miniCPMV4: "minicpm-v4"
    case .miniCPMV45: "minicpm-v4.5"
    case .miniCPMO45: "minicpm-o4.5"
    case .smolVLM2: "smolvlm2"
    case .qwen35_2B, .qwen35_4B, .qwen35_9B, .qwen36_35BA3B, .qwen38_27B: "qwen3.5"
    }
  }

  /// Total parameters in billions.
  var parameters: Double {
    switch self {
    case .qwen3VL4B: 4; case .qwen3VL8B: 8; case .qwen3VL32B: 32
    case .gemma4E2B: 4.6; case .gemma4E4B: 7.5; case .gemma4_12B: 12
    case .gemma4A4B: 25.2; case .gemma4_31B: 31
    case .ministral3B: 3.4; case .ministral8B: 8.5; case .ministral14B: 13.5
    case .miniCPMV4: 3.6; case .miniCPMV45: 8.2
    case .miniCPMO45: 9; case .smolVLM2: 2.2
    case .qwen35_2B: 2.27; case .qwen35_4B: 4.66; case .qwen35_9B: 9.65
    case .qwen36_35BA3B: 36; case .qwen38_27B: 27.8
    }
  }

  /// Parameters read per token, in billions: the active experts of a
  /// mixture-of-experts model, the effective parameters of a Gemma E-model.
  var activeParameters: Double {
    switch self {
    case .gemma4A4B: 3.8
    case .qwen36_35BA3B: 3
    case .gemma4E4B: 4.5
    case .gemma4E2B: 2.3
    default: parameters
    }
  }

  var isMixtureOfExperts: Bool { self == .gemma4A4B || self == .qwen36_35BA3B }

  /// The reviewed quantizations: the original ones first, then the smaller sizes.
  var quantizations: [String] {
    switch self {
    case _ where architecture == "gemma4": ["Q4_0", "Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "Q3_K_M", "IQ3_XXS"]
    case .qwen35_2B: ["Q4_K_M", "Q8_0"]
    case .qwen38_27B: ["Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "IQ3_S", "IQ3_XXS"]
    case .qwen35_9B, .qwen36_35BA3B: ["Q4_K_M", "Q5_K_M", "Q8_0", "IQ4_XS", "Q3_K_M", "IQ3_XXS"]
    default: ["Q4_K_M", "Q5_K_M", "Q8_0"]
    }
  }

  var cacheLayout: LocalCacheLayout {
    switch self {
    case .qwen3VL4B, .qwen3VL8B, .miniCPMV45, .miniCPMO45:
      LocalCacheLayout(fullLayers: 36, fullKVHeads: 8, fullHeadDimension: 128)
    case .qwen3VL32B: LocalCacheLayout(fullLayers: 64, fullKVHeads: 8, fullHeadDimension: 128)
    case .ministral3B: LocalCacheLayout(fullLayers: 26, fullKVHeads: 8, fullHeadDimension: 128)
    case .ministral8B: LocalCacheLayout(fullLayers: 34, fullKVHeads: 8, fullHeadDimension: 128)
    case .ministral14B: LocalCacheLayout(fullLayers: 40, fullKVHeads: 8, fullHeadDimension: 128)
    case .miniCPMV4: LocalCacheLayout(fullLayers: 32, fullKVHeads: 2, fullHeadDimension: 128)
    case .smolVLM2: LocalCacheLayout(fullLayers: 24, fullKVHeads: 32, fullHeadDimension: 64)
    // Hybrid Qwen models: only their attention layers hold a KV cache; the Gated
    // DeltaNet layers keep a small recurrent state that the runtime reserve
    // covers. The multi-token-prediction layer is an attention layer and counts.
    case .qwen35_2B: LocalCacheLayout(fullLayers: 6, fullKVHeads: 2, fullHeadDimension: 256)
    case .qwen35_4B, .qwen35_9B: LocalCacheLayout(fullLayers: 8, fullKVHeads: 4, fullHeadDimension: 256)
    case .qwen36_35BA3B: LocalCacheLayout(fullLayers: 11, fullKVHeads: 2, fullHeadDimension: 256)
    case .qwen38_27B: LocalCacheLayout(fullLayers: 17, fullKVHeads: 4, fullHeadDimension: 256)
    case .gemma4_12B:
      LocalCacheLayout(fullLayers: 8, fullKVHeads: 1, fullHeadDimension: 512,
                       slidingLayers: 40, slidingKVHeads: 8, slidingHeadDimension: 256, slidingWindow: 1024)
    case .gemma4A4B:
      LocalCacheLayout(fullLayers: 5, fullKVHeads: 2, fullHeadDimension: 512,
                       slidingLayers: 25, slidingKVHeads: 8, slidingHeadDimension: 256, slidingWindow: 1024)
    case .gemma4E4B:
      LocalCacheLayout(fullLayers: 7, fullKVHeads: 2, fullHeadDimension: 512,
                       slidingLayers: 35, slidingKVHeads: 2, slidingHeadDimension: 256, slidingWindow: 512)
    // Not verified against a GGUF header; the model is not in the catalogue.
    case .gemma4E2B:
      LocalCacheLayout(fullLayers: 7, fullKVHeads: 1, fullHeadDimension: 512,
                       slidingLayers: 28, slidingKVHeads: 1, slidingHeadDimension: 256, slidingWindow: 512)
    case .gemma4_31B:
      LocalCacheLayout(fullLayers: 10, fullKVHeads: 4, fullHeadDimension: 512,
                       slidingLayers: 50, slidingKVHeads: 16, slidingHeadDimension: 256, slidingWindow: 1024)
    }
  }

  /// Since llama.cpp b11327 these models' image tokens attend to each other,
  /// so one image must fit in a single physical batch. In b11734 that is every
  /// Gemma 4 projector except E2B's and E4B's (`mtmd_decode_use_non_causal`).
  var usesNonCausalImageAttention: Bool {
    self == .gemma4_12B || self == .gemma4A4B || self == .gemma4_31B
  }

  var physicalBatchSize: Int { usesNonCausalImageAttention ? 1024 : Self.defaultPhysicalBatch }
  var imageMaxTokens: Int { usesNonCausalImageAttention ? 1024 : 4096 }

  /// Compute buffer, one image and the server. A larger physical batch reserves
  /// logits for every extra token: 1_048_576 bytes is one F32 logits row of
  /// Gemma 4's 262,144-token vocabulary.
  var runtimeReserve: Int64 {
    LocalHardwareProfile.gib * 3 / 2 + Int64(physicalBatchSize - Self.defaultPhysicalBatch) * 1_048_576
  }

  /// Weights and projector count once: llama.cpp maps the file and Metal wraps
  /// the mapping without copying it.
  func memory(weights: Int64, projector: Int64, context: Int) -> Int64 {
    weights + projector + cacheLayout.bytes(context: context, physicalBatch: physicalBatchSize) + runtimeReserve
  }
}
