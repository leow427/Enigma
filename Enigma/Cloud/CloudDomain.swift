import Foundation

enum CodexThinkingCapacity: String, CaseIterable, Identifiable, Sendable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
  case ultra

  var forExtendedThinking: Self {
    switch self {
    case .none, .minimal, .low, .medium, .high: .xhigh
    case .xhigh, .max, .ultra: self
    }
  }

  var id: Self { self }

  var displayName: String {
    switch self {
    case .none: "None"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    case .ultra: "Ultra"
    }
  }
}

enum CloudProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
  case chatGPT = "chatgpt-codex"
  case claudeCode = "claude-code"
  case openAI = "openai"
  case anthropic
  case gemini

  var id: Self { self }

  var displayName: String {
    switch self {
    case .chatGPT: "ChatGPT via Codex"
    case .claudeCode: "Claude via Claude Code"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .gemini: "Gemini"
    }
  }

  /// The provider's name as cards and Settings show it, without the route (F30 location card).
  var shortName: String {
    switch self {
    case .chatGPT: "ChatGPT"
    case .claudeCode: "Claude Code"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .gemini: "Gemini"
    }
  }

  /// The providers whose own web search is on (F30). CP2–CP5 each add theirs; never `.gemini`.
  static let nativeWebSearchProviders: Set<CloudProviderID> = []

  var supportsNativeWebSearch: Bool { Self.nativeWebSearchProviders.contains(self) }
}

struct CloudModel: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
  let provider: CloudProviderID
  /// What the model accepts ("text", "image", "audio"), when the provider's own list says.
  /// Only Codex reports this; nil means unknown, which never counts as image support.
  var inputModalities: [String]? = nil
  /// Whether the provider marks this as its default model. Only Codex reports this.
  var isDefault = false

  init(id: String, displayName: String, provider: CloudProviderID,
       inputModalities: [String]? = nil, isDefault: Bool = false) {
    self.id = id
    self.displayName = displayName
    self.provider = provider
    self.inputModalities = inputModalities
    self.isDefault = isDefault
  }

  private enum CodingKeys: String, CodingKey { case id, displayName, provider, inputModalities, isDefault }

  /// Caches written before these fields existed decode as unknown modalities and not default.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    provider = try container.decode(CloudProviderID.self, forKey: .provider)
    inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities)
    isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
  }
}

/// The models Codex last listed for this account, kept so checks that know only a model ID
/// (screen routing, the request guard, context limits) can use Codex's own answers about
/// compatibility and image input. `CloudModelCatalog` replaces it whenever it reads or
/// writes the ChatGPT list; signing out clears it.
final class CodexListedModels: @unchecked Sendable {
  static let shared = CodexListedModels()

  private let lock = NSLock()
  private var listed: [CloudModel] = []

  var models: [CloudModel] { lock.withLock { listed } }

  func model(id: String) -> CloudModel? {
    lock.withLock { listed.first { $0.id == id } }
  }

  func replace(with models: [CloudModel]) {
    let models = models.filter { $0.provider == .chatGPT }
    lock.withLock { listed = models }
  }
}

enum CloudProviderError: LocalizedError, Equatable, Sendable {
  case missingAPIKey(CloudProviderID)
  case unsupportedModel(CloudProviderID, modelID: String)
  case offline
  case authenticationFailed(CloudProviderID)
  case rateLimited(CloudProviderID)
  case invalidResponse
  case requestFailed(statusCode: Int, message: String?)
  case streamEndedUnexpectedly
  case providerMessage(String)
  /// The provider's own web search can't be used with this model or account (F30).
  case webSearchUnavailable(CloudProviderID)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey(let provider):
      "Add an API key for \(provider.displayName) in Settings → Cloud and search."
    case .unsupportedModel(let provider, let modelID):
      "\(modelID) cannot be used for text chat with \(provider.displayName) in Enigma. Choose a compatible model in Settings → Cloud and search."
    case .offline:
      "The cloud provider could not be reached. Check your internet connection."
    case .authenticationFailed(let provider):
      "\(provider.displayName) rejected the API key. Check it in Settings → Cloud and search."
    case .rateLimited(let provider):
      "\(provider.displayName) is rate limiting this account. Please try again shortly."
    case .invalidResponse:
      "The cloud provider returned an invalid response."
    case .requestFailed(let statusCode, let message):
      message.map { "Cloud request failed (\(statusCode)): \($0)" }
        ?? "Cloud request failed with status \(statusCode)."
    case .streamEndedUnexpectedly:
      "The cloud response ended before it completed."
    case .providerMessage(let message):
      message
    case .webSearchUnavailable:
      "Web search isn't available for this model."
    }
  }
}

protocol CloudCredentialStore: Sendable {
  func containsAPIKey(for provider: CloudProviderID) throws -> Bool
  func apiKey(for provider: CloudProviderID) throws -> String?
  func setAPIKey(_ apiKey: String, for provider: CloudProviderID) throws
  func removeAPIKey(for provider: CloudProviderID) throws
}

extension CloudCredentialStore {
  func containsAPIKey(for provider: CloudProviderID) throws -> Bool {
    try apiKey(for: provider)?.isEmpty == false
  }
}

enum CloudNetworkEvent: Sendable, Equatable {
  case response(statusCode: Int)
  case data(Data)
}

struct CloudDataResponse: Sendable, Equatable {
  let data: Data
  let statusCode: Int
}

protocol CloudNetworkTransport: Sendable {
  func data(for request: URLRequest) async throws -> CloudDataResponse
  func stream(for request: URLRequest) -> AsyncThrowingStream<CloudNetworkEvent, Error>
}

func normalizedCloudError(_ error: Error) -> Error {
  if error is CancellationError {
    return CancellationError()
  }
  guard let urlError = error as? URLError else { return error }
  switch urlError.code {
  case .cancelled:
    return CancellationError()
  case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
       .cannotFindHost, .dnsLookupFailed, .timedOut:
    return CloudProviderError.offline
  default:
    return error
  }
}

func cloudHTTPError(
  provider: CloudProviderID,
  statusCode: Int,
  data: Data
) -> CloudProviderError {
  switch statusCode {
  case 401, 403:
    return .authenticationFailed(provider)
  case 429:
    return .rateLimited(provider)
  default:
    return .requestFailed(
      statusCode: statusCode,
      message: providerErrorMessage(in: data)
    )
  }
}

private func providerErrorMessage(in data: Data) -> String? {
  guard !data.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return nil
  }
  if let error = object["error"] as? [String: Any],
     let message = error["message"] as? String {
    return message
  }
  return object["message"] as? String
}
