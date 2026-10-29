import Foundation

struct CloudProviderRegistry: Sendable {
  static let live = CloudProviderRegistry(
    credentialStore: KeychainCredentialStore(),
    transport: URLSessionCloudTransport.shared
  )

  let openAI: any ChatProvider
  let anthropic: any ChatProvider
  let chatGPT: any ChatProvider
  let claudeCode: any ChatProvider
  let gemini: any ChatProvider

  init(
    openAI: any ChatProvider, anthropic: any ChatProvider, chatGPT: any ChatProvider,
    gemini: (any ChatProvider)? = nil, claudeCode: (any ChatProvider)? = nil
  ) {
    self.openAI = openAI
    self.anthropic = anthropic
    self.chatGPT = chatGPT
    self.claudeCode = claudeCode ?? ClaudeCodeSubscriptionClient.live
    self.gemini = gemini ?? GeminiContentClient(credentialStore: KeychainCredentialStore(), transport: URLSessionCloudTransport.shared)
  }

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    chatGPT: any ChatProvider = CodexSubscriptionClient.live,
    claudeCode: any ChatProvider = ClaudeCodeSubscriptionClient.live
  ) {
    self.chatGPT = chatGPT
    self.claudeCode = claudeCode
    gemini = GeminiContentClient(credentialStore: credentialStore, transport: transport)
    openAI = OpenAIResponsesClient(
      credentialStore: credentialStore,
      transport: transport
    )
    anthropic = AnthropicMessagesClient(
      credentialStore: credentialStore,
      transport: transport
    )
  }

  func provider(for id: CloudProviderID) -> any ChatProvider {
    switch id {
    case .chatGPT: chatGPT
    case .claudeCode: claudeCode
    case .openAI: openAI
    case .anthropic: anthropic
    case .gemini: gemini
    }
  }
}

struct OpenAIResponsesClient: ChatProvider {
  let credentialStore: any CloudCredentialStore
  let transport: any CloudNetworkTransport
  let responsesURL: URL

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    responsesURL: URL = URL(string: "https://api.openai.com/v1/responses")!
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    self.responsesURL = responsesURL
  }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(for: request)
          try await consume(urlRequest, continuation: continuation)
        } catch {
          continuation.finish(throwing: normalizedCloudError(error))
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func makeRequest(for request: ChatRequest) throws -> URLRequest {
    guard request.route.providerID == CloudProviderID.openAI.rawValue else {
      throw CloudProviderError.invalidResponse
    }
    guard let apiKey = try credentialStore.apiKey(for: .openAI), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(.openAI)
    }

    let prepared = try CloudContext.prepare(request)
    var body: [String: Any] = [
      "model": request.route.modelID,
      "instructions": ChatResponseStyle.instructions,
      "input": try MultimodalSerialization.messages(prepared.messages, image: request.image, format: .openAIResponses),
      "stream": true, "store": false, "max_output_tokens": prepared.budget.outputTokens,
    ]
    if ThinkCommand.enabled(in: prepared.messages) { body["reasoning"] = ["effort": "high"] }
    var urlRequest = URLRequest(url: responsesURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  private func consume(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async throws {
    var parser = ServerSentEventParser()
    var statusCode: Int?
    var errorBody = Data()
    var didComplete = false

    for try await networkEvent in transport.stream(for: request) {
      // If cancellation races a buffered event, advance the cancelled iterator
      // once more so AsyncThrowingStream terminates its underlying producer.
      // Throwing here could leave a retained network stream running.
      if Task.isCancelled { continue }
      switch networkEvent {
      case .response(let responseStatusCode):
        statusCode = responseStatusCode
      case .data(let data):
        guard let statusCode else { throw CloudProviderError.invalidResponse }
        guard (200...299).contains(statusCode) else {
          errorBody.append(data)
          continue
        }
        for event in parser.append(data) {
          didComplete = try handle(event, continuation: continuation) || didComplete
        }
      }
    }

    try Task.checkCancellation()
    guard let statusCode else { throw CloudProviderError.invalidResponse }
    guard (200...299).contains(statusCode) else {
      throw cloudHTTPError(provider: .openAI, statusCode: statusCode, data: errorBody)
    }
    for event in parser.finish() {
      didComplete = try handle(event, continuation: continuation) || didComplete
    }
    guard didComplete else { throw CloudProviderError.streamEndedUnexpectedly }
    continuation.finish()
  }

  private func handle(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) throws -> Bool {
    if event.data == "[DONE]" {
      continuation.yield(.completed)
      return true
    }
    guard let data = event.data.data(using: .utf8),
          let payload = try? JSONDecoder().decode(OpenAIStreamPayload.self, from: data) else {
      throw CloudProviderError.invalidResponse
    }
    switch payload.type {
    case "response.output_text.delta":
      if let delta = payload.delta, !delta.isEmpty {
        continuation.yield(.token(delta))
      }
    case "response.completed":
      continuation.yield(.completed)
      return true
    case "response.failed", "response.incomplete", "error":
      throw CloudProviderError.providerMessage(
        payload.error?.message ?? payload.response?.error?.message
          ?? "OpenAI could not complete the response."
      )
    default:
      break
    }
    return false
  }
}

private struct OpenAIStreamPayload: Decodable {
  struct ErrorPayload: Decodable {
    let message: String
  }

  struct ResponsePayload: Decodable {
    let error: ErrorPayload?
  }

  let type: String
  let delta: String?
  let error: ErrorPayload?
  let response: ResponsePayload?
}

struct AnthropicMessagesClient: ChatProvider {
  let credentialStore: any CloudCredentialStore
  let transport: any CloudNetworkTransport
  let messagesURL: URL

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    messagesURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
  ) {
    self.credentialStore = credentialStore
    self.transport = transport
    self.messagesURL = messagesURL
  }

  func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(for: request)
          try await consume(urlRequest, continuation: continuation)
        } catch {
          continuation.finish(throwing: normalizedCloudError(error))
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private func makeRequest(for request: ChatRequest) throws -> URLRequest {
    guard request.route.providerID == CloudProviderID.anthropic.rawValue else {
      throw CloudProviderError.invalidResponse
    }
    guard let apiKey = try credentialStore.apiKey(for: .anthropic), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(.anthropic)
    }

    let prepared = try CloudContext.prepare(request)
    var body: [String: Any] = [
      "model": request.route.modelID, "max_tokens": prepared.budget.outputTokens,
      "system": ChatResponseStyle.instructions,
      "messages": try MultimodalSerialization.messages(prepared.messages, image: request.image, format: .anthropic),
      "stream": true,
    ]
    if ThinkCommand.enabled(in: prepared.messages) { body.merge(Self.thinking(modelID: request.route.modelID)) { $1 } }
    var urlRequest = URLRequest(url: messagesURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  static func thinking(modelID: String) -> [String: Any] {
    let manual = ["claude-3", "claude-sonnet-4-202", "claude-opus-4-202", "claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-1", "claude-opus-4-5"].contains { modelID.hasPrefix($0) }
    return manual ? ["thinking": ["type": "enabled", "budget_tokens": 2_048]]
      : ["thinking": ["type": "adaptive"], "output_config": ["effort": "high"]]
  }

  /// Whether `tool_choice` `tool` (and `any`) is allowed. Claude Opus 5.5, Sonnet 5.5, Fable 5.1
  /// and Mythos 5.1 return a 400 for it whatever the thinking settings (define-tools docs,
  /// "Forcing tool use", checked 2026-10-29); later versions of those families are assumed to too.
  static func acceptsForcedToolChoice(modelID: String) -> Bool {
    let firstRejecting: [String: (Int, Int)] = ["opus": (5, 5), "sonnet": (5, 5), "fable": (5, 1), "mythos": (5, 1)]
    let parts = modelID.split(separator: "-")
    guard parts.count >= 3, parts[0] == "claude", let first = firstRejecting[String(parts[1])],
          let major = Int(parts[2]) else { return true }
    // A dated snapshot such as claude-opus-5-20261001 has no minor version.
    let minor = parts.count > 3 ? Int(parts[3]).flatMap { $0 < 1_000 ? $0 : nil } ?? 0 : 0
    return (major, minor) < first
  }

  private func consume(
    _ request: URLRequest,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async throws {
    var parser = ServerSentEventParser()
    var statusCode: Int?
    var errorBody = Data()
    var didComplete = false

    for try await networkEvent in transport.stream(for: request) {
      // If cancellation races a buffered event, advance the cancelled iterator
      // once more so AsyncThrowingStream terminates its underlying producer.
      // Throwing here could leave a retained network stream running.
      if Task.isCancelled { continue }
      switch networkEvent {
      case .response(let responseStatusCode):
        statusCode = responseStatusCode
      case .data(let data):
        guard let statusCode else { throw CloudProviderError.invalidResponse }
        guard (200...299).contains(statusCode) else {
          errorBody.append(data)
          continue
        }
        for event in parser.append(data) {
          didComplete = try handle(event, continuation: continuation) || didComplete
        }
      }
    }

    try Task.checkCancellation()
    guard let statusCode else { throw CloudProviderError.invalidResponse }
    guard (200...299).contains(statusCode) else {
      throw cloudHTTPError(provider: .anthropic, statusCode: statusCode, data: errorBody)
    }
    for event in parser.finish() {
      didComplete = try handle(event, continuation: continuation) || didComplete
    }
    guard didComplete else { throw CloudProviderError.streamEndedUnexpectedly }
    continuation.finish()
  }

  private func handle(
    _ event: ServerSentEvent,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) throws -> Bool {
    guard let data = event.data.data(using: .utf8),
          let payload = try? JSONDecoder().decode(AnthropicStreamPayload.self, from: data) else {
      throw CloudProviderError.invalidResponse
    }
    switch payload.type {
    case "content_block_delta" where payload.delta?.type == "text_delta":
      if let text = payload.delta?.text, !text.isEmpty {
        continuation.yield(.token(text))
      }
    case "message_stop":
      continuation.yield(.completed)
      return true
    case "error":
      throw CloudProviderError.providerMessage(
        payload.error?.message ?? "Anthropic could not complete the response."
      )
    default:
      break
    }
    return false
  }
}

private struct AnthropicStreamPayload: Decodable {
  struct Delta: Decodable {
    let type: String?
    let text: String?
  }

  struct ErrorPayload: Decodable {
    let message: String
  }

  let type: String
  let delta: Delta?
  let error: ErrorPayload?
}
