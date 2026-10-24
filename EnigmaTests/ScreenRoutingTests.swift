import XCTest
@testable import Enigma

final class ScreenRoutingTests: XCTestCase {
  private let ocr = ScreenOCRResult(text: String(repeating: "let answer = 42;\n", count: 5), confidence: 0.9)
  private let local = ScreenModel(id: "text", provider: "local", isLocal: true, capabilities: .textOnly)
  private let cloud = ScreenModel(id: "text", provider: "openai", isLocal: false, capabilities: .textOnly)
  private let vision = ScreenModel(id: "visual", provider: "openai", isLocal: false, capabilities: .textAndVision)
  private let localVision = ScreenModel(id: "offline-visual", provider: "llama.cpp", isLocal: true, capabilities: .textAndVision, visionProjectorPath: "/models/mmproj.gguf")

  func testTextHeavyScreensUseTextModelsWithoutImagePermission() {
    for prompt in ["explain this code", "fix the compiler error", "summarize this document", "solve this equation", "explain this stack trace", "what is the answer to this piece of code?"] {
      for mode in ChatMode.allCases {
        let result = ScreenRoutingPolicy.decide(request(prompt, mode: mode))
        XCTAssertEqual(result, .text(mode == .cloud ? cloud : local))
        XCTAssertFalse(result.sendsImage)
      }
    }
  }

  func testVisualIntentOverridesGoodOCRAndLowOCRRequiresVision() {
    for prompt in ["explain the chart", "describe this diagram", "what color is it?", "where is the button?", "fix this visual bug", "describe the photo", "is the layout aligned?", "Which shape is above the circle?", "Are the arrows connected?"] {
      XCTAssertTrue(ScreenRoutingPolicy.requiresVision(prompt: prompt, ocr: ocr), prompt)
    }
    XCTAssertFalse(ScreenRoutingPolicy.requiresVision(prompt: "transcribe the text in this chart", ocr: ocr))
    XCTAssertTrue(ScreenRoutingPolicy.requiresVision(prompt: "what is this?", ocr: .empty))
  }

  func testLocalModeNeverRoutesToCloudAcrossPermissionMatrix() {
    for allowed in [false, true] {
      var input = request("describe this chart", mode: .local)
      input.allowCloudScreenshots = allowed
      input.hasExplainedCloudPermission = true
      XCTAssertNil(ScreenRoutingPolicy.decide(input).model)
      input.localText = localVision
      XCTAssertEqual(ScreenRoutingPolicy.decide(input), .vision(localVision))
    }
  }

  func testCloudPermissionAndOfflineFallback() {
    for mode in [ChatMode.auto, .cloud] {
      var input = request("describe the diagram", mode: mode)
      input.cloudText = vision
      input.autoRoute = vision.route
      XCTAssertEqual(ScreenRoutingPolicy.decide(input), .needsCloudPermission)
      input.hasExplainedCloudPermission = true
      XCTAssertNil(ScreenRoutingPolicy.decide(input).model)
      input.localText = localVision
      if mode == .auto { XCTAssertEqual(ScreenRoutingPolicy.decide(input), .vision(localVision)) }
      else { XCTAssertNil(ScreenRoutingPolicy.decide(input).model) }
      input.allowCloudScreenshots = true
      XCTAssertEqual(ScreenRoutingPolicy.decide(input), .vision(vision))
      input.isOffline = true
      if mode == .auto { XCTAssertEqual(ScreenRoutingPolicy.decide(input), .vision(localVision)) }
      else { XCTAssertNil(ScreenRoutingPolicy.decide(input).model) }
    }
  }

  func testAutoUsesNormalRouterForOCRAndVisualRequestsWithSearchOnAndOff() {
    let model = LocalModel(id: "selected", displayName: "Selected", fileURL: URL(fileURLWithPath: "/tmp/model.gguf"),
      visionConfiguration: LocalVisionConfiguration(projectorURL: URL(fileURLWithPath: "/tmp/mmproj.gguf"),
        serverExecutableURL: URL(fileURLWithPath: "/usr/bin/true")))
    for search in [false, true] {
      for prompt in ["Summarize this text", "Analyze this diagram", "What color is the square?"] {
        let automatic = AutoRouter.decide(.init(selectedMode: .auto, webSearchEnabled: search, prompt: prompt,
          contextMessages: [], localModel: model, cloud: .init(provider: .openAI, modelID: "gpt-4o-mini")))
        let cloudModel = CloudModel(id: "gpt-4o-mini", displayName: "Cloud", provider: .openAI).screenModel
        let input = ScreenRoutingPolicy.Request(prompt: prompt, ocr: ocr, mode: .auto,
          localText: model.screenModel, cloudText: cloudModel, autoRoute: automatic.route,
          allowCloudScreenshots: true, hasExplainedCloudPermission: true)
        XCTAssertEqual(ScreenRoutingPolicy.decide(input).model?.id, automatic.route?.modelID)
      }
    }
  }

  func testAutoAccountsForScreenshotContextWhenChoosingItsNormalModel() {
    let model = LocalModel(id: "selected", displayName: "Selected", fileURL: URL(fileURLWithPath: "/tmp/model.gguf"),
      visionConfiguration: LocalVisionConfiguration(projectorURL: URL(fileURLWithPath: "/tmp/mmproj.gguf"),
        serverExecutableURL: URL(fileURLWithPath: "/usr/bin/true")))
    let decision = AutoRouter.decide(.init(selectedMode: .auto, prompt: "Summarize this", contextMessages: [],
      localModel: model, additionalInputTokens: 8000, cloud: .init(provider: .openAI, modelID: "gpt-4o-mini")))
    XCTAssertEqual(decision.reason, .exceedsLocalContext)
    XCTAssertEqual(decision.route?.modelID, "gpt-4o-mini")
  }

  func testTextOnlyModelsAndMissingProjectorsNeverGetImages() {
    var input = request("describe the chart", mode: .auto)
    input.allowCloudScreenshots = true
    input.hasExplainedCloudPermission = true
    input.cloudText = cloud
    input.localText = ScreenModel(id: "fake", provider: "llama.cpp", isLocal: true, capabilities: .textAndVision)
    XCTAssertNil(ScreenRoutingPolicy.decide(input).model)
  }

  func testCapabilitiesAreExplicitAndLegacyLocalModelsStayTextOnly() throws {
    let model = try JSONDecoder().decode(LocalModel.self, from: Data(#"{"id":"vision-in-name","displayName":"Vision","fileURL":"file:///tmp/model.gguf"}"#.utf8))
    XCTAssertFalse(model.supportsVision)
    XCTAssertNil(model.visionProjectorPath)
    XCTAssertTrue(CloudModel(id: "gpt-4o-mini", displayName: "test", provider: .openAI).supportsVision)
    XCTAssertFalse(CloudModel(id: "gpt-future-vision", displayName: "test", provider: .openAI).supportsVision)
  }

  func testSubscriptionModelsTakeScreenshotsOnlyWhenAllowedAndImageCapable() throws {
    CodexListedModels.shared.replace(with: [
      CloudModel(id: "gpt-6-sol", displayName: "GPT-6 Sol", provider: .chatGPT, inputModalities: ["text", "image"]),
      CloudModel(id: "gpt-6-text", displayName: "Text", provider: .chatGPT, inputModalities: ["text"]),
    ])
    addTeardownBlock { CodexListedModels.shared.replace(with: []) }
    // Routing builds models from the saved ID alone, so Codex's last list answers for ChatGPT.
    let claude = CloudModel(id: "opus", displayName: "opus", provider: .claudeCode).screenModel
    let codex = CloudModel(id: "gpt-6-sol", displayName: "gpt-6-sol", provider: .chatGPT).screenModel
    let codexText = CloudModel(id: "gpt-6-text", displayName: "gpt-6-text", provider: .chatGPT).screenModel
    XCTAssertTrue(claude.supportsVision)
    XCTAssertTrue(codex.supportsVision)
    XCTAssertFalse(codexText.supportsVision)
    XCTAssertFalse(CloudModel(id: "gpt-unlisted", displayName: "x", provider: .chatGPT).supportsVision)
    XCTAssertFalse(CloudModel(id: "gpt-6-sol", displayName: "x", provider: .chatGPT, inputModalities: ["text"]).supportsVision,
                   "A model's own list entry wins")

    for model in [claude, codex] {
      var input = request("describe the diagram", mode: .cloud)
      input.cloudText = model
      input.hasExplainedCloudPermission = true
      XCTAssertEqual(ScreenRoutingPolicy.decide(input), .blocked(ScreenRoutingPolicy.screenshotUploadDisabledMessage),
                     "Cloud screenshots stay off until allowed")
      input.allowCloudScreenshots = true
      XCTAssertEqual(ScreenRoutingPolicy.decide(input), .vision(model))
    }
    var textOnly = request("describe the diagram", mode: .cloud)
    textOnly.cloudText = codexText
    textOnly.allowCloudScreenshots = true
    textOnly.hasExplainedCloudPermission = true
    XCTAssertNil(ScreenRoutingPolicy.decide(textOnly).model)

    // The request guard applies the same rules just before sending.
    let image = PreparedScreenImage(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", pixelWidth: 2, pixelHeight: 2)
    for (provider, modelID) in [(CloudProviderID.claudeCode, "sonnet"), (.chatGPT, "gpt-6-sol")] {
      var send = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "What is this?")],
        route: Route(mode: .cloud, providerID: provider.rawValue, modelID: modelID, usesNetwork: true), image: image)
      XCTAssertThrowsError(try ScreenRequestGuard.validateCloud(send)) {
        XCTAssertEqual($0 as? ScreenRequestError, .cloudUploadNotAllowed)
      }
      send.allowsCloudImages = true
      XCTAssertNoThrow(try ScreenRequestGuard.validateCloud(send))
    }
    let textOnlySend = ChatRequest(sessionID: UUID(), messages: [ChatMessage(role: .user, content: "What is this?")],
      route: Route(mode: .cloud, providerID: CloudProviderID.chatGPT.rawValue, modelID: "gpt-6-text", usesNetwork: true),
      image: image, allowsCloudImages: true)
    XCTAssertThrowsError(try ScreenRequestGuard.validateCloud(textOnlySend)) {
      XCTAssertEqual($0 as? ScreenRequestError, .textOnlyModel)
    }
  }

  @MainActor
  func testCloudScreenshotPermissionDefaultsOffAndPersistsExplicitAnswer() {
    let suite = "ScreenPermissionTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = ScreenSettings(defaults: defaults)
    XCTAssertFalse(settings.allowCloudScreenshots)
    XCTAssertFalse(settings.hasExplainedCloudPermission)
    settings.answerCloudPermission(allow: false)
    XCTAssertTrue(ScreenSettings(defaults: defaults).hasExplainedCloudPermission)
    XCTAssertFalse(ScreenSettings(defaults: defaults).allowCloudScreenshots)
    settings.answerCloudPermission(allow: true)
    XCTAssertTrue(ScreenSettings(defaults: defaults).allowCloudScreenshots)
    settings.allowCloudScreenshots = false
    XCTAssertFalse(ScreenSettings(defaults: defaults).allowCloudScreenshots)
  }

  private func request(_ prompt: String, mode: ChatMode) -> ScreenRoutingPolicy.Request {
    ScreenRoutingPolicy.Request(prompt: prompt, ocr: ocr, mode: mode, localText: local, cloudText: cloud)
  }
}
