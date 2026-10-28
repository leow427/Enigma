import XCTest
@testable import Enigma

final class NativeToolsTests: XCTestCase {
  private static let flaggedFamilies: Set<LocalMultimodalProfile> = [
    .qwen35_9B, .gemma4_12B, .ministral14B, .gemma4A4B, .gemma4_31B, .qwen36_35BA3B, .qwen38_27B,
  ]
  private static let unflaggedFamilies: Set<LocalMultimodalProfile> = [
    .qwen35_2B, .qwen35_4B, .gemma4E4B, .ministral8B,
  ]

  func testStartingLocalFlags() {
    let profiles = Set(BundledLocalModels.families.map(\.profile))
    XCTAssertEqual(profiles, Self.flaggedFamilies.union(Self.unflaggedFamilies),
                   "A catalogue family was added or removed; give it a starting flag")
    for family in BundledLocalModels.families {
      let expected = Self.flaggedFamilies.contains(family.profile)
      XCTAssertEqual(family.profile.nativeTools, expected, family.name)
      XCTAssertEqual(family.descriptors.first?.supportsNativeTools, expected, family.name)
    }
    for profile in LocalMultimodalProfile.allCases where !profiles.contains(profile) {
      XCTAssertFalse(profile.nativeTools, "\(profile) is not in the catalogue")
    }
  }

  func testEveryQuantizationSharesItsFamilysFlag() {
    for family in BundledLocalModels.families {
      let flags = Set(family.descriptors.map(\.supportsNativeTools))
      XCTAssertEqual(flags, [family.profile.nativeTools], family.name)
      XCTAssertEqual(family.descriptors.count, family.packages.count, family.name)
    }
    let catalogue = Set(BundledLocalModels.models.filter(\.supportsNativeTools).map(\.displayName))
    XCTAssertEqual(catalogue.count, Self.flaggedFamilies.count)
  }

  func testUnknownProfileIsNotCapable() {
    let flagged = BundledLocalModels.models.first { $0.inferenceProfile == .qwen35_9B }!
    var descriptor = flagged
    descriptor.inferenceProfile = nil
    // 9.65B matches no legacy Qwen size, so nothing resolves.
    XCTAssertNil(descriptor.resolvedProfile)
    XCTAssertFalse(descriptor.supportsNativeTools)
  }

  func testCloudModelsAreCapable() {
    let lacking = CloudModelCapabilities.modelsWithoutFunctionCalling
    var checked = 0
    for provider in CloudProviderID.allCases {
      for id in CloudModelCapabilities.reviewedModelIDs(for: provider) {
        XCTAssertEqual(CloudModelCapabilities.supportsNativeTools(provider: provider, modelID: id),
                       !(lacking[provider]?.contains(id) ?? false), "\(provider) \(id)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 20)
    for provider in CloudProviderID.allCases {
      XCTAssertFalse(CloudModelCapabilities.reviewedModelIDs(for: provider).isEmpty, "\(provider)")
    }
    // Anthropic and Gemini go by family, so newer models the providers list first are covered.
    for id in ["claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-4-6"] {
      XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: id), id)
    }
    for id in ["gemini-3-flash", "gemini-3.1-pro-preview", "gemini-2.5-flash-lite", " gemini-3-flash ",
               "gemini-flash-latest", "gemini-pro-latest"] {
      XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .gemini, modelID: id), id)
    }
    for id in ["gemini-2.5-flash-image", "gemini-2.5-flash-preview-tts", "gemini-2.5-flash-native-audio-preview",
               "gemini-2.5-flash-live-preview", "gemini-live-2.5-flash", "gemini-2.0-flash", "gemini-embedding-001",
               "gemma-3-27b-it-latest"] {
      XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .gemini, modelID: id), id)
    }
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: "claude-instant-1.2"))
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: "claude-2.1"))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: " claude-sonnet-4-5 "))
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: "gpt-4.1"))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .claudeCode, modelID: "sonnet"))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .openAI, modelID: " gpt-4.1-mini "))
    // An open model on the Gemini API, or an OpenAI ID nobody reviewed, keeps today's path.
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .gemini, modelID: "gemma-3-27b-it"))
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .openAI, modelID: "o9-preview"))
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .openAI, modelID: "gpt-image-1"))
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: ""))
    // A reviewed model listed as lacking function calling keeps today's path, on that provider only.
    let lackingHaiku: [CloudProviderID: Set<String>] = [.anthropic: ["claude-haiku-4-5"]]
    XCTAssertFalse(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: " claude-haiku-4-5 ",
                                                              lacking: lackingHaiku))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .anthropic, modelID: "claude-sonnet-4-5",
                                                             lacking: lackingHaiku))
    XCTAssertTrue(CloudModelCapabilities.supportsNativeTools(provider: .claudeCode, modelID: "haiku",
                                                             lacking: lackingHaiku))
  }

  func testRouteCapability() {
    let flagged = model(BundledLocalModels.models.first { $0.inferenceProfile == .gemma4_12B }!)
    let unflagged = model(BundledLocalModels.models.first { $0.inferenceProfile == .qwen35_2B }!)
    let imported = LocalModel(id: "custom", displayName: "Custom", fileURL: URL(fileURLWithPath: "/tmp/custom.gguf"))
    let local = Route(mode: .local, providerID: "llama.cpp", modelID: "m", usesNetwork: false)

    XCTAssertTrue(NativeTools.isCapable(route: local, localModel: flagged))
    XCTAssertFalse(NativeTools.isCapable(route: local, localModel: unflagged))
    XCTAssertFalse(NativeTools.isCapable(route: local, localModel: imported))
    XCTAssertFalse(NativeTools.isCapable(route: local, localModel: nil))

    let cloud = Route(mode: .cloud, providerID: CloudProviderID.anthropic.rawValue,
                      modelID: "claude-haiku-4-5", usesNetwork: true)
    XCTAssertTrue(NativeTools.isCapable(route: cloud, localModel: unflagged), "a cloud route ignores the local model")
    let claudeCode = Route(mode: .cloud, providerID: CloudProviderID.claudeCode.rawValue, modelID: "opus", usesNetwork: true)
    XCTAssertTrue(NativeTools.isCapable(route: claudeCode, localModel: nil))
    let unreviewed = Route(mode: .cloud, providerID: CloudProviderID.openAI.rawValue,
                           modelID: "my-fine-tune", usesNetwork: true)
    XCTAssertFalse(NativeTools.isCapable(route: unreviewed, localModel: nil))

    let noProvider = Route(mode: .cloud, providerID: "", modelID: "gpt-4.1", usesNetwork: true)
    XCTAssertFalse(NativeTools.isCapable(route: noProvider, localModel: flagged))
    let unknownProvider = Route(mode: .auto, providerID: "llama.cpp", modelID: "gpt-4.1", usesNetwork: false)
    XCTAssertFalse(NativeTools.isCapable(route: unknownProvider, localModel: flagged))
  }

  func testSwitchIsOff() {
    XCTAssertFalse(NativeTools.isEnabled)
  }

  func testFixturesAreScrubbed() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/F32")
    let cases = ["text", "call", "text-then-call", "forced", "cut-mid-call"]
    let expected = ["openai", "anthropic", "gemini", "llama", "llama/qwen38"].flatMap { folder in
      cases.map { "\(folder)/\($0).txt" }
    } + ["anthropic/thinking-call.txt", "llama/thinking-call.txt", "llama/qwen38/thinking-call.txt"]
    for path in expected {
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: path).path), "missing fixture \(path)")
    }
    let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }
    XCTAssertGreaterThanOrEqual(files.count, expected.count)
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for secret in ["sk-", "Bearer", "x-api-key", #""id":"resp_"#, #""id":"msg_"#, #""id":"fc_"#, "req_", "toolu_", "/Users/",
                     "/private/", "claude-501"] {
        XCTAssertFalse(text.contains(secret), "\(file.lastPathComponent) contains \(secret)")
      }
      for pattern in [#":\s*"call_[A-Za-z0-9]"#, #"chatcmpl-[A-Za-z0-9]{2}"#, #"probe-[0-9A-F]{8}-"#,
                      #""responseId":"(?!response-0")"#] {
        XCTAssertNil(text.range(of: pattern, options: .regularExpression), "\(file.lastPathComponent) matches \(pattern)")
      }
    }
  }

  func testProbeFolderMustBeOutsideTheRepository() throws {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "NativeToolsTests-\(UUID().uuidString)")
    let repository = scratch.appending(path: "Repo")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let link = scratch.appending(path: "Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository)

    XCTAssertTrue(NativeToolsProbeTests.isInside(repository, repository))
    XCTAssertTrue(NativeToolsProbeTests.isInside(repository.appending(path: "not/yet/made"), repository))
    XCTAssertTrue(NativeToolsProbeTests.isInside(link.appending(path: "out"), repository), "through a symbolic link")
    XCTAssertTrue(NativeToolsProbeTests.isInside(scratch.appending(path: "REPO/out"), repository), "APFS ignores case")
    // /tmp is a link to /private/tmp; a folder that doesn't exist yet keeps whichever spelling it was given.
    let tmp = URL(fileURLWithPath: "/tmp").appending(path: "NativeToolsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    XCTAssertTrue(NativeToolsProbeTests.isInside(URL(fileURLWithPath: "/private" + tmp.path).appending(path: "new"), tmp))
    XCTAssertTrue(NativeToolsProbeTests.isInside(tmp.appending(path: "new"), URL(fileURLWithPath: "/private" + tmp.path)))

    XCTAssertFalse(NativeToolsProbeTests.isInside(scratch.appending(path: "Repository-probes"), repository), "a sibling sharing the prefix")
    XCTAssertFalse(NativeToolsProbeTests.isInside(scratch, repository))
  }

  private func model(_ descriptor: LocalModelDescriptor) -> LocalModel {
    LocalModel(id: descriptor.id, displayName: descriptor.displayName,
               fileURL: URL(fileURLWithPath: "/tmp/\(descriptor.id).gguf"), catalogDescriptor: descriptor)
  }
}
