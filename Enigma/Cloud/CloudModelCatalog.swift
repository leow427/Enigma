import Foundation

actor CloudModelCatalog {
  static let cacheLifetime: TimeInterval = 24 * 60 * 60

  private struct CacheEntry: Codable {
    let fetchedAt: Date
    let models: [CloudModel]
  }

  private struct CacheArchive: Codable {
    var providers: [String: CacheEntry] = [:]
  }

  private let credentialStore: any CloudCredentialStore
  private let transport: any CloudNetworkTransport
  private let cacheURL: URL
  private let openAIModelsURL: URL
  private let anthropicModelsURL: URL
  private let codex: CodexSubscriptionClient
  private let claudeCode: ClaudeCodeSubscriptionClient
  private let codexListedModels: CodexListedModels
  /// Bumped per provider by every cache write and clear. A fetch that started under an
  /// older generation (a newer fetch finished, or the person signed out) doesn't save.
  private var generations: [CloudProviderID: Int] = [:]

  init(
    credentialStore: any CloudCredentialStore,
    transport: any CloudNetworkTransport,
    cacheDirectory: URL? = nil,
    openAIModelsURL: URL = URL(string: "https://api.openai.com/v1/models")!,
    anthropicModelsURL: URL = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!,
    codex: CodexSubscriptionClient = .live,
    claudeCode: ClaudeCodeSubscriptionClient = .live,
    codexListedModels: CodexListedModels? = nil
  ) {
    self.codex = codex
    // The shared list mirrors the app's own cache; a catalog on another cache (any catalog
    // in a test host) keeps a separate list unless it is given one.
    self.codexListedModels = codexListedModels
      ?? (cacheDirectory == nil && !TestHost.isActive ? .shared : CodexListedModels())
    self.claudeCode = claudeCode
    self.credentialStore = credentialStore
    self.transport = transport
    // A test host never reads or writes the real cache: without a directory it gets its own.
    let directory = cacheDirectory ?? (TestHost.isActive
      ? FileManager.default.temporaryDirectory.appending(path: "EnigmaTestModelCache-\(UUID().uuidString)", directoryHint: .isDirectory)
      : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "AI Spotlight", directoryHint: .isDirectory))
    cacheURL = directory.appending(path: "cloud-models.json")
    self.openAIModelsURL = openAIModelsURL
    self.anthropicModelsURL = anthropicModelsURL
  }

  func cachedModels(
    for provider: CloudProviderID,
    now: Date = .now
  ) -> [CloudModel]? {
    guard let entry = loadArchive().providers[provider.rawValue],
          now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime else {
      return nil
    }
    return CloudModelCapabilities.chatModels(entry.models, for: provider)
  }

  func models(
    for provider: CloudProviderID,
    forceRefresh: Bool = false,
    now: Date = .now
  ) async throws -> [CloudModel] {
    let archive = loadArchive()
    if !forceRefresh,
       let entry = archive.providers[provider.rawValue],
       now.timeIntervalSince(entry.fetchedAt) < Self.cacheLifetime {
      return CloudModelCapabilities.chatModels(entry.models, for: provider)
    }
    let generation = generations[provider, default: 0]

    if provider == .chatGPT || provider == .claudeCode {
      let discovered = provider == .chatGPT ? try await codex.models() : try await claudeCode.models()
      return try store(discovered, for: provider, fetchedAt: now, startedAt: generation)
    }

    guard let apiKey = try credentialStore.apiKey(for: provider), !apiKey.isEmpty else {
      throw CloudProviderError.missingAPIKey(provider)
    }
    let request = try makeRequest(provider: provider, apiKey: apiKey)
    let response: CloudDataResponse
    do {
      response = try await transport.data(for: request)
    } catch {
      throw normalizedCloudError(error)
    }
    guard (200...299).contains(response.statusCode) else {
      throw cloudHTTPError(
        provider: provider,
        statusCode: response.statusCode,
        data: response.data
      )
    }

    let discoveredModels = try decodeModels(response.data, provider: provider)
    return try store(discoveredModels, for: provider, fetchedAt: now, startedAt: generation)
  }

  /// Saves a fetched list unless the cache changed for `provider` since the fetch began,
  /// and returns the list callers should show: the fetched one, or for a superseded fetch
  /// the current cache (empty after sign-out, or the newer list), never the stale one.
  /// The archive is read again, since other providers' lists may have changed meanwhile.
  private func store(_ models: [CloudModel], for provider: CloudProviderID, fetchedAt: Date,
                     startedAt generation: Int) throws -> [CloudModel] {
    var archive = loadArchive()
    guard generations[provider, default: 0] == generation else {
      return CloudModelCapabilities.chatModels(archive.providers[provider.rawValue]?.models ?? [], for: provider)
    }
    generations[provider, default: 0] += 1
    archive.providers[provider.rawValue] = CacheEntry(fetchedAt: fetchedAt, models: models)
    try saveArchive(archive)
    return CloudModelCapabilities.chatModels(models, for: provider)
  }

  /// Whether a list for `provider` is cached at any age: a sign it was set up in Enigma.
  func hasCachedModels(for provider: CloudProviderID) -> Bool {
    loadArchive().providers[provider.rawValue]?.models.isEmpty == false
  }

  func clearCache(for provider: CloudProviderID) throws {
    generations[provider, default: 0] += 1
    var archive = loadArchive()
    archive.providers.removeValue(forKey: provider.rawValue)
    try saveArchive(archive)
  }

  private func makeRequest(provider: CloudProviderID, apiKey: String) throws -> URLRequest {
    let url = provider == .gemini ? URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!
      : (provider == .openAI ? openAIModelsURL : anthropicModelsURL)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    switch provider {
    case .chatGPT, .claudeCode, .free:
      throw CodexError.invalidResponse
    case .gemini:
      request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    case .openAI:
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    case .anthropic:
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    return request
  }

  private func decodeModels(
    _ data: Data,
    provider: CloudProviderID
  ) throws -> [CloudModel] {
    switch provider {
    case .chatGPT, .claudeCode, .free:
      throw CodexError.invalidResponse
    case .gemini:
      struct Response: Decodable {
        struct Model: Decodable { let name: String; let displayName: String?; let supportedGenerationMethods: [String]? }
        let models: [Model]
      }
      let response = try JSONDecoder().decode(Response.self, from: data)
      return response.models.filter { $0.supportedGenerationMethods?.contains("generateContent") == true }.map {
        let id = $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name
        return CloudModel(id: id, displayName: $0.displayName ?? id, provider: .gemini)
      }
    case .openAI:
      struct Response: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
      }
      guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
        throw CloudProviderError.invalidResponse
      }
      return response.data
        .map { CloudModel(id: $0.id, displayName: $0.id, provider: provider) }
    case .anthropic:
      struct Response: Decodable {
        struct Model: Decodable {
          let id: String
          let displayName: String

          enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
          }
        }
        let data: [Model]
      }
      guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
        throw CloudProviderError.invalidResponse
      }
      return response.data.map {
        CloudModel(id: $0.id, displayName: $0.displayName, provider: provider)
      }
    }
  }

  private func loadArchive() -> CacheArchive {
    guard let data = try? Data(contentsOf: cacheURL),
          let archive = try? decoder.decode(CacheArchive.self, from: data) else {
      codexListedModels.replace(with: [])
      return CacheArchive()
    }
    publishCodexModels(in: archive)
    return archive
  }

  private func saveArchive(_ archive: CacheArchive) throws {
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(archive).write(to: cacheURL, options: .atomic)
    publishCodexModels(in: archive)
  }

  private func publishCodexModels(in archive: CacheArchive) {
    codexListedModels.replace(with: archive.providers[CloudProviderID.chatGPT.rawValue]?.models ?? [])
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
