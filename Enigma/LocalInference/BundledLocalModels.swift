import Foundation

/// One model in the catalogue and the quantizations Enigma ships for it. The
/// shared facts are stated once; each package adds its exact file, size,
/// SHA-256 and largest tensor (read from its GGUF header).
struct LocalModelFamily: Sendable {
  struct Package: Sendable {
    let id: String, quantization: String, file: String
    let byteCount: Int64, sha256: String, largestTensorBytes: Int64
  }

  let name: String
  let publisher: String
  let license: String
  let profile: LocalMultimodalProfile
  let qualityScore: Double
  let summary: String
  /// "owner/name" on Hugging Face; weights and projector always share it and the revision.
  let repository: String
  let revision: String
  let projectorFile: String
  let projectorByteCount: Int64
  let projectorSHA256: String
  let supportsAudio: Bool
  let packages: [Package]

  var parameters: Double { profile.parameters }
  var activeParameters: Double { profile.activeParameters }

  func url(_ file: String) -> URL {
    URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!
  }

  var descriptors: [LocalModelDescriptor] {
    let projector = VerifiedModelArtifact(url: url(projectorFile), expectedByteCount: projectorByteCount,
                                          checksumSHA256: projectorSHA256)
    return packages.map { package in
      let memory = profile.memory(weights: package.byteCount, projector: projectorByteCount, context: 8192)
      return LocalModelDescriptor(id: package.id, displayName: name, downloadURL: url(package.file),
        expectedByteCount: package.byteCount, license: license, checksumSHA256: package.sha256,
        revision: revision, quantization: package.quantization, architecture: profile.architecture,
        chatTemplate: profile.chatTemplate, minimumLlamaBuild: LocalVisionRuntime.build,
        estimatedRuntimeMemory: memory, largestTensorBytes: package.largestTensorBytes,
        recommendedContextSize: 8192, qualityScore: qualityScore,
        performanceClass: supportsAudio ? "Vision + Audio model · Text and images in Enigma" : "Vision",
        parameterBillions: parameters, minimumMemory: memory, recommendedMemory: memory, projector: projector,
        runtimeBuild: LocalVisionRuntime.build, publisher: publisher, modelSummary: summary,
        inferenceProfile: profile, advertisedMemoryRange: nil, modelSupportsAudio: supportsAudio,
        activeParameterBillions: activeParameters)
    }
  }
}

// Catalogue reviewed 2026-10-19 — see docs/Updating-the-Model-Catalogue.md.
// Sizes and SHA-256 come from the Hugging Face tree API at each revision.
enum BundledLocalModels {
  static let families: [LocalModelFamily] = [
    LocalModelFamily(name: "Qwen3.5 2B", publisher: "Alibaba / Qwen", license: "Apache-2.0", profile: .qwen35_2B,
      // No index score; placed below Qwen3.5 4B by size (assumption).
      qualityScore: 8,
      summary: "A compact model for quick questions and screenshots on smaller Macs.",
      repository: "unsloth/Qwen3.5-2B-GGUF", revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 668227264,
      projectorSHA256: "7035e9cb8d7c6a9681d07eef9a364783e86ea4cd73faab2eabb4f43a101830c7", supportsAudio: false,
      packages: [
        .init(id: "qwen3.5-2b-q4_k_m", quantization: "Q4_K_M", file: "Qwen3.5-2B-Q4_K_M.gguf", byteCount: 1280835840,
              sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", largestTensorBytes: 417177600),
        .init(id: "qwen3.5-2b-q8_0", quantization: "Q8_0", file: "Qwen3.5-2B-Q8_0.gguf", byteCount: 2012012800,
              sha256: "1b04acba824817554f4ce23639bc8495ff70453b8fcb047900c731521021f2c1", largestTensorBytes: 540344320),
      ]),
    LocalModelFamily(name: "Qwen3.5 4B", publisher: "Alibaba / Qwen", license: "Apache-2.0", profile: .qwen35_4B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: 13 (estimate); MMMU-Pro 66.3.
      qualityScore: 13,
      summary: "Efficient reasoning, writing and screenshot understanding.",
      repository: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 672423616,
      projectorSHA256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864", supportsAudio: false,
      packages: [
        .init(id: "qwen3.5-4b-q4_k_m", quantization: "Q4_K_M", file: "Qwen3.5-4B-Q4_K_M.gguf", byteCount: 2740937888,
              sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", largestTensorBytes: 521472000),
        .init(id: "qwen3.5-4b-q5_k_m", quantization: "Q5_K_M", file: "Qwen3.5-4B-Q5_K_M.gguf", byteCount: 3143656608,
              sha256: "8814232b85594dcd46c50e5b8b29324a7efe9e746edbe8a3d1df3d3fce7aad39", largestTensorBytes: 521472000),
        .init(id: "qwen3.5-4b-q8_0", quantization: "Q8_0", file: "Qwen3.5-4B-Q8_0.gguf", byteCount: 4482403488,
              sha256: "10cc391b403021dd11c614679d2fd92f611c3681d29e29651b717316965d61e1", largestTensorBytes: 675430400),
      ]),
    LocalModelFamily(name: "Qwen3.5 9B", publisher: "Alibaba / Qwen", license: "Apache-2.0", profile: .qwen35_9B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: raised from 11 so the
      // larger model of the line ranks above Qwen3.5 4B; MMMU-Pro 70.1.
      qualityScore: 13.5,
      summary: "More capacity for detailed reasoning and document understanding.",
      repository: "unsloth/Qwen3.5-9B-GGUF", revision: "3885219b6810b007914f3a7950a8d1b469d598a5",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 918166080,
      projectorSHA256: "f70dc3509053962b0d0d3ee8a7eacebf5d60aa560cad78254ae8698516ae029f", supportsAudio: false,
      packages: [
        .init(id: "qwen3.5-9b-q4_k_m", quantization: "Q4_K_M", file: "Qwen3.5-9B-Q4_K_M.gguf", byteCount: 5680522464,
              sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8", largestTensorBytes: 834355200),
        .init(id: "qwen3.5-9b-q5_k_m", quantization: "Q5_K_M", file: "Qwen3.5-9B-Q5_K_M.gguf", byteCount: 6577841376,
              sha256: "dc2a39aef291f91a9116ad214058da0d86eb648743a124bd8c333787c4b9c91c", largestTensorBytes: 834355200),
        .init(id: "qwen3.5-9b-q8_0", quantization: "Q8_0", file: "Qwen3.5-9B-Q8_0.gguf", byteCount: 9527502048,
              sha256: "809626574d0cb43d4becfa56169980da2bb448f2299270f7be443cb89d0a6ae4", largestTensorBytes: 1080688640),
      ]),
    LocalModelFamily(name: "Gemma 4 12B", publisher: "Google", license: "Apache-2.0", profile: .gemma4_12B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: 14 (estimate); MMMU-Pro 69.1.
      qualityScore: 14,
      summary: "Stronger reasoning and image understanding for demanding questions.",
      repository: "unsloth/gemma-4-12b-it-GGUF", revision: "fc034cfff751157913579611efad8462ac1be606",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 175115840,
      projectorSHA256: "91f086971e56d7a7d8d39e271873fccdb49541bd259d6e02c401a4f1cb7a219e", supportsAudio: true,
      packages: [
        .init(id: "gemma-4-12b-q4_k_m", quantization: "Q4_K_M", file: "gemma-4-12b-it-Q4_K_M.gguf", byteCount: 7121861440,
              sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42", largestTensorBytes: 566231040),
        .init(id: "gemma-4-12b-q5_k_m", quantization: "Q5_K_M", file: "gemma-4-12b-it-Q5_K_M.gguf", byteCount: 8413576000,
              sha256: "32c554c7d1338a23837ae39b3db482213a4a642f96df3b2619f516a2375d16cd", largestTensorBytes: 692060160),
        .init(id: "gemma-4-12b-q8_0", quantization: "Q8_0", file: "gemma-4-12b-it-Q8_0.gguf", byteCount: 12669647680,
              sha256: "f20e7ff1be28c283eeeb18fc895733791c56a5851d5cd3fe9691b7f7d12afa72", largestTensorBytes: 1069547520),
      ]),
    LocalModelFamily(name: "Gemma 4 26B-A4B", publisher: "Google", license: "Apache-2.0", profile: .gemma4A4B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: 17 (estimate); MMMU-Pro 73.8.
      qualityScore: 17,
      summary: "A larger mixture-of-experts model for complex text and visual reasoning.",
      repository: "bartowski/google_gemma-4-26B-A4B-it-GGUF", revision: "10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d",
      projectorFile: "mmproj-google_gemma-4-26B-A4B-it-f16.gguf", projectorByteCount: 1193058528,
      projectorSHA256: "41cdabd1e8066e983ee6c288eb0117777376223ee0279cadcd67b2295e4d975f", supportsAudio: false,
      packages: [
        .init(id: "gemma-4-26b-a4b-q4_k_m", quantization: "Q4_K_M", file: "google_gemma-4-26B-A4B-it-Q4_K_M.gguf",
              byteCount: 17035039872, sha256: "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a",
              largestTensorBytes: 605552640),
        .init(id: "gemma-4-26b-a4b-q5_k_m", quantization: "Q5_K_M", file: "google_gemma-4-26B-A4B-it-Q5_K_M.gguf",
              byteCount: 19319198848, sha256: "6b4f8074239f72543997a950ff6ae4509553c599f5b432748309ff3438416493",
              largestTensorBytes: 605552640),
        .init(id: "gemma-4-26b-a4b-q8_0", quantization: "Q8_0", file: "google_gemma-4-26B-A4B-it-Q8_0.gguf",
              byteCount: 26859861120, sha256: "1bb7fdb37fbd542ba972b3eb83ae87752bb9063aff560402e0e2f64235c85226",
              largestTensorBytes: 784334848),
      ]),
    LocalModelFamily(name: "Qwen3.6 35B-A3B", publisher: "Alibaba / Qwen", license: "Apache-2.0", profile: .qwen36_35BA3B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: 18.
      qualityScore: 18,
      summary: "A large mixture-of-experts model that stays quick on high-memory Macs.",
      repository: "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF", revision: "5c2410d71524f4f72b023ce8daf7a80528226d5f",
      projectorFile: "mmproj-Qwen_Qwen3.6-35B-A3B-f16.gguf", projectorByteCount: 899283296,
      projectorSHA256: "67924785ff1885c2b34c15d0e52979e991acca64221694ba2cc3a6474a053fb4", supportsAudio: false,
      packages: [
        .init(id: "qwen3.6-35b-a3b-q4_k_m", quantization: "Q4_K_M", file: "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf",
              byteCount: 22285080192, sha256: "b46fedd33e0bfb0cae308aa3c158d0a4b2c4a1d2185a1ed6f093cdaf39064772",
              largestTensorBytes: 417177600),
        .init(id: "qwen3.6-35b-a3b-q5_k_m", quantization: "Q5_K_M", file: "Qwen_Qwen3.6-35B-A3B-Q5_K_M.gguf",
              byteCount: 25913185920, sha256: "ec438d1326eb11d8bb94785c54739cd4b60b01ae32bd8532e232a046b19d296d",
              largestTensorBytes: 417177600),
        .init(id: "qwen3.6-35b-a3b-q8_0", quantization: "Q8_0", file: "Qwen_Qwen3.6-35B-A3B-Q8_0.gguf",
              byteCount: 37812647552, sha256: "bc57de096ec30e45773aa86103f35a8a32cea01f2193a53a3c636d618e4434e9",
              largestTensorBytes: 540344320),
      ]),
    LocalModelFamily(name: "Qwen3.8 27B", publisher: "Alibaba / Qwen", license: "Apache-2.0", profile: .qwen38_27B,
      // Artificial Analysis Intelligence Index v4.3.2, October 2026: 34 at xhigh reasoning; 28 at medium.
      qualityScore: 28,
      summary: "The strongest model here, for detailed reasoning on Max and Ultra chips.",
      repository: "unsloth/Qwen3.8-27B-GGUF", revision: "4ca720788d1e01f1bff70c033e0d0028fd02e502",
      projectorFile: "mmproj-F16.gguf", projectorByteCount: 927607488,
      projectorSHA256: "cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e", supportsAudio: false,
      packages: [
        // The repository's only Q4 and Q5 files are Unsloth Dynamic quantizations.
        .init(id: "qwen3.8-27b-q4_k_m", quantization: "Q4_K_M", file: "Qwen3.8-27B-UD-Q4_K_M.gguf",
              byteCount: 16464440224, sha256: "322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482",
              largestTensorBytes: 1042944000),
        .init(id: "qwen3.8-27b-q5_k_m", quantization: "Q5_K_M", file: "Qwen3.8-27B-UD-Q5_K_M.gguf",
              byteCount: 19771509664, sha256: "2de73110cb254cbf09b54b717578dadff12ef1194e7271527e68202f39ba4bfd",
              largestTensorBytes: 1042944000),
        .init(id: "qwen3.8-27b-q8_0", quantization: "Q8_0", file: "Qwen3.8-27B-Q8_0.gguf",
              byteCount: 29047086048, sha256: "a680f44a06920e5d689774823782006aa3acc8db95750323373b24139b67e348",
              largestTensorBytes: 1350860800),
      ]),
  ]

  static let models: [LocalModelDescriptor] = families.flatMap(\.descriptors)
}
