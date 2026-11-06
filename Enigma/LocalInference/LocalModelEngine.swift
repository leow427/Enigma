import Foundation

enum LocalModelIdlePolicy {
  static let unloadDelay: Duration = .seconds(60)
}

struct LocalModel: Codable, Sendable, Equatable, Identifiable {
  let id: String
  let displayName: String
  let fileURL: URL
  var catalogDescriptor: LocalModelDescriptor? = nil
  var visionConfiguration: LocalVisionConfiguration? = nil
  /// The window this Mac runs the model at (F35), set as the library loads it; nil keeps the
  /// package's. Never written into `visionConfiguration`, whose value the Update check compares.
  var runtimeContextWindow: Int? = nil

  /// The window the runtime and every budget use.
  var contextWindow: Int { runtimeContextWindow ?? packageContextWindow }

  /// The package's own window.
  var packageContextWindow: Int {
    if let configured = visionConfiguration?.contextWindow, configured > 0 { return configured }
    if let recommended = catalogDescriptor?.recommendedContextSize, recommended > 0 { return recommended }
    return ModelContextPolicy.localContextWindow
  }
}

/// F27: small local models make mistakes with tools, and people tend to approve what they're shown,
/// so only catalogue families reviewed for it may change files or send messages. Imports never may.
enum SensitiveTools {
  static let off = "File edits and sending messages are off"
  static let backOn = "File edits and sending messages are back on."
  static func isNotice(_ text: String?) -> Bool { text == backOn || text?.hasPrefix(off) == true }
  static func offNotice(_ modelName: String) -> String {
    "\(off) with \(modelName). Use Cloud or a larger model to turn them on."
  }
}

extension LocalModel {
  var allowsSensitiveTools: Bool {
    guard let descriptor = catalogDescriptor else { return false }
    // An install saved before F27 has no value; its family's current catalogue entry decides.
    return descriptor.allowsSensitiveTools
      ?? BundledLocalModels.models.first { $0.id == descriptor.id }?.allowsSensitiveTools ?? false
  }
}

struct LocalModelRequest: Sendable, Equatable {
  let messages: [ChatMessage]

  var prompt: String { messages.last?.content ?? "" }
  let maximumTokenCount: Int
  let temperature: Float

  init(
    prompt: String,
    maximumTokenCount: Int = ModelContextPolicy.localOutputTokens,
    temperature: Float = 0.7
  ) {
    self.init(messages: [ChatMessage(role: .user, content: prompt)],
              maximumTokenCount: maximumTokenCount, temperature: temperature)
  }

  init(
    messages: [ChatMessage],
    maximumTokenCount: Int = ModelContextPolicy.localOutputTokens,
    temperature: Float = 0.7
  ) {
    self.messages = messages
    self.maximumTokenCount = ThinkCommand.enabled(in: messages) ? max(maximumTokenCount, 2_048) : maximumTokenCount
    self.temperature = temperature
  }
}

protocol LocalModelEngine: Sendable {
  func install(_ model: LocalModel) async throws
  func installedModel() async -> LocalModel?
  func installedModels() async -> [LocalModel]
  func selectModel(id: String) async throws
  func deleteModel(id: String) async throws
  func download(
    _ model: LocalModelDescriptor,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel
  /// Downloads and verifies beside chat, then awaits `beforeCommit` right before
  /// the atomic install that may select the new model.
  func download(
    _ model: LocalModelDescriptor,
    beforeCommit: @escaping @Sendable () async throws -> Void,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel
  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation
  func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error>
  func unload() async
  func benchmark() async throws -> LocalBenchmarkMetrics?
}

enum LocalInferenceError: LocalizedError, Equatable {
  case noModelInstalled
  case invalidModelFile
  case unknownInstalledModel
  case bridgeFailure(String)

  var errorDescription: String? {
    switch self {
    case .noModelInstalled:
      "Choose a GGUF model before using Local mode."
    case .invalidModelFile:
      "The selected file is not a readable GGUF model."
    case .unknownInstalledModel:
      "That local model is no longer installed."
    case .bridgeFailure(let message):
      message
    }
  }
}

extension LocalModelEngine {
  func download(
    _ model: LocalModelDescriptor,
    beforeCommit: @escaping @Sendable () async throws -> Void,
    progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
  ) async throws -> LocalModel {
    try await download(model, progress: progress)
  }

  func deleteModel(id: String) async throws {
    throw LocalInferenceError.bridgeFailure("This model cannot be deleted by the current local engine.")
  }

  func benchmark() async throws -> LocalBenchmarkMetrics? { nil }

  func prepare(_ request: LocalModelRequest) async throws -> PreparedConversation {
    let contextWindow = await installedModel()?.contextWindow ?? ModelContextPolicy.localContextWindow
    return try ChatContextPreparer.prepare(
      request.messages,
      budget: ContextBudget(contextWindow: contextWindow,
                            outputTokens: request.maximumTokenCount, overheadTokens: 256),
      countTokens: { $0.reduce(0) { $0 + $1.content.utf8.count + 32 } }
    )
  }
}
