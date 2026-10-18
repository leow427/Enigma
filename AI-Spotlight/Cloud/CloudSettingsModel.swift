import Combine
import Foundation

struct CloudPreferencesStore: @unchecked Sendable {
  private enum Key {
    static let preferredProvider = "aiSpotlight.cloud.preferredProvider"
    static let didAdoptLunaDefault = "aiSpotlight.cloud.didAdoptLunaDefault"
    static let preferredCodexThinkingCapacity = "aiSpotlight.cloud.preferredCodexThinkingCapacity"
    static let preferredClaudeCodeEffort = "aiSpotlight.cloud.preferredClaudeCodeEffort"
    static func preferredModel(_ provider: CloudProviderID) -> String {
      "aiSpotlight.cloud.preferredModel.\(provider.rawValue)"
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if !defaults.bool(forKey: Key.didAdoptLunaDefault) {
      let previousModel = defaults.string(forKey: Key.preferredModel(.chatGPT))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // Older versions persisted the first discovered model, usually Sol.
      // Migrate once so a later explicit selection of Sol remains respected.
      if previousModel.isEmpty || previousModel == "gpt-5.6-sol" {
        defaults.set(CodexSubscriptionClient.defaultModelID, forKey: Key.preferredModel(.chatGPT))
      }
      defaults.set(true, forKey: Key.didAdoptLunaDefault)
    }
  }

  func preferredProvider() -> CloudProviderID {
    defaults.string(forKey: Key.preferredProvider)
      .flatMap(CloudProviderID.init(rawValue:)) ?? .chatGPT
  }

  func setPreferredProvider(_ provider: CloudProviderID) {
    defaults.set(provider.rawValue, forKey: Key.preferredProvider)
  }

  func preferredModel(for provider: CloudProviderID) -> String {
    let model = defaults.string(forKey: Key.preferredModel(provider)) ?? ""
    guard model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return model }
    switch provider {
    case .chatGPT: return CodexSubscriptionClient.defaultModelID
    case .claudeCode: return ClaudeCodeSubscriptionClient.defaultModelID
    case .openAI, .anthropic, .gemini: return model
    }
  }

  func setPreferredModel(_ modelID: String, for provider: CloudProviderID) {
    defaults.set(modelID, forKey: Key.preferredModel(provider))
  }

  func preferredCodexThinkingCapacity() -> CodexThinkingCapacity {
    defaults.string(forKey: Key.preferredCodexThinkingCapacity)
      .flatMap(CodexThinkingCapacity.init(rawValue:)) ?? .high
  }

  func setPreferredCodexThinkingCapacity(_ capacity: CodexThinkingCapacity) {
    defaults.set(capacity.rawValue, forKey: Key.preferredCodexThinkingCapacity)
  }

  func preferredClaudeCodeEffort() -> ClaudeCodeEffort {
    defaults.string(forKey: Key.preferredClaudeCodeEffort)
      .flatMap(ClaudeCodeEffort.init(rawValue:)) ?? .automatic
  }

  func setPreferredClaudeCodeEffort(_ effort: ClaudeCodeEffort) {
    defaults.set(effort.rawValue, forKey: Key.preferredClaudeCodeEffort)
  }
}

@MainActor
final class CloudSettingsModel: ObservableObject {
  enum ConnectionState: Equatable {
    case idle
    case testing
    case connected(Int)
    case failed(String)
  }

  static let shared: CloudSettingsModel = {
    let credentialStore = KeychainCredentialStore()
    return CloudSettingsModel(
      credentialStore: credentialStore,
      catalog: CloudModelCatalog(
        credentialStore: credentialStore,
        transport: URLSessionCloudTransport.shared
      )
    )
  }()

  @Published var preferredProvider: CloudProviderID {
    didSet {
      guard preferredProvider != oldValue else { return }
      preferences.setPreferredProvider(preferredProvider)
      preferredModelID = preferences.preferredModel(for: preferredProvider)
      models = []
      hasLoadedModelList = false
      discoveryError = nil
      Task { await loadCachedModels() }
    }
  }

  @Published var preferredModelID: String {
    didSet {
      preferences.setPreferredModel(
        preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines),
        for: preferredProvider
      )
    }
  }

  @Published var codexThinkingCapacity: CodexThinkingCapacity {
    didSet { preferences.setPreferredCodexThinkingCapacity(codexThinkingCapacity) }
  }

  @Published var claudeCodeEffort: ClaudeCodeEffort {
    didSet { preferences.setPreferredClaudeCodeEffort(claudeCodeEffort) }
  }

  @Published private(set) var models: [CloudModel] = []
  @Published private(set) var hasLoadedModelList = false
  @Published private(set) var discoveryError: String?
  @Published private(set) var isDiscovering = false
  @Published private(set) var credentialRevision = 0
  @Published private(set) var connectionStates: [CloudProviderID: ConnectionState] = [:]
  @Published private(set) var chatGPTAccount: CodexAccount?
  @Published private(set) var isSigningIn = false
  @Published private(set) var accountError: String?
  @Published private(set) var isCodexAvailable: Bool
  @Published private(set) var claudeCodeAccount: ClaudeCodeAccount?
  @Published private(set) var isClaudeCodeAvailable: Bool
  @Published private(set) var isWaitingForClaudeCodeSignIn = false
  @Published private(set) var claudeCodeError: String?

  private let credentialStore: any CloudCredentialStore
  private let catalog: CloudModelCatalog
  private let preferences: CloudPreferencesStore
  private let codex: CodexSubscriptionClient
  private let codexAvailable: @Sendable () -> Bool
  private let claudeCode: ClaudeCodeSubscriptionClient
  private let claudeCodeSignInPollInterval: Duration
  private var loginTask: Task<Void, Never>?
  private var claudeCodeSignInTask: Task<Void, Never>?
  private var discoveryID = UUID()

  init(
    credentialStore: any CloudCredentialStore,
    catalog: CloudModelCatalog,
    preferences: CloudPreferencesStore = CloudPreferencesStore(),
    codex: CodexSubscriptionClient = .live,
    codexAvailable: @escaping @Sendable () -> Bool = { CodexRuntimeConfiguration.executableURL() != nil },
    claudeCode: ClaudeCodeSubscriptionClient = .live,
    claudeCodeSignInPollInterval: Duration = .seconds(2)
  ) {
    self.codex = codex
    self.codexAvailable = codexAvailable
    isCodexAvailable = codexAvailable()
    self.claudeCode = claudeCode
    self.claudeCodeSignInPollInterval = claudeCodeSignInPollInterval
    isClaudeCodeAvailable = claudeCode.isInstalled
    self.credentialStore = credentialStore
    self.catalog = catalog
    self.preferences = preferences
    let provider = preferences.preferredProvider()
    preferredProvider = provider
    preferredModelID = preferences.preferredModel(for: provider)
    codexThinkingCapacity = preferences.preferredCodexThinkingCapacity()
    claudeCodeEffort = preferences.preferredClaudeCodeEffort()
  }

  var isConfigured: Bool {
    hasCloudAccess(for: preferredProvider)
      && selectedModelCompatibility.allowsSending
  }

  var selectedModelCompatibility: CloudModelCompatibility {
    let id = preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let compatibility = CloudModelCapabilities.compatibility(provider: preferredProvider, modelID: id)
    if compatibility == .unverified, preferredProvider != .openAI,
       models.contains(where: { $0.id == id }) {
      return .compatible
    }
    return compatibility
  }

  var modelDiscoveryNotice: String? {
    guard hasLoadedModelList, models.isEmpty else { return nil }
    return "No verified text-chat models were found. Refresh after checking model access, or enter a model ID manually. Saved selections are kept."
  }

  func hasCloudAccess(for provider: CloudProviderID) -> Bool {
    switch provider {
    case .chatGPT: chatGPTAccount != nil
    case .claudeCode: claudeCodeAccount != nil
    case .openAI, .anthropic, .gemini: hasAPIKey(for: provider)
    }
  }

  func refreshClaudeCodeAccount() async {
    isClaudeCodeAvailable = claudeCode.isInstalled
    guard isClaudeCodeAvailable else { claudeCodeAccount = nil; return }
    do {
      claudeCodeAccount = try await claudeCode.account()
      claudeCodeError = nil
    } catch {
      claudeCodeAccount = nil
      claudeCodeError = error.localizedDescription
    }
  }

  /// Claude Code owns its browser sign-in, so it runs in Terminal while Enigma
  /// checks the shared login status until it is complete.
  func signInToClaudeCode(openScript: @escaping @MainActor (URL) -> Bool) {
    guard !isWaitingForClaudeCodeSignIn else { return }
    claudeCodeError = nil
    do {
      guard openScript(try claudeCode.runtimeSignInScript()) else {
        claudeCodeError = "Terminal could not be opened to sign in to Claude Code."
        return
      }
    } catch {
      claudeCodeError = error.localizedDescription
      return
    }
    isWaitingForClaudeCodeSignIn = true
    claudeCodeSignInTask = Task {
      defer { isWaitingForClaudeCodeSignIn = false; claudeCodeSignInTask = nil }
      for _ in 0..<150 {
        do { try await Task.sleep(for: claudeCodeSignInPollInterval) } catch { return }
        if let account = try? await claudeCode.account() {
          claudeCodeAccount = account
          claudeCodeError = nil
          try? await catalog.clearCache(for: .claudeCode)
          preferredProvider = .claudeCode
          await discoverModels(forceRefresh: true)
          return
        }
      }
      claudeCodeError = "Claude Code sign-in was not completed. Try again, or check the Terminal window."
    }
  }

  func cancelClaudeCodeSignIn() { claudeCodeSignInTask?.cancel() }

  func refreshChatGPTAccount() async {
    guard !isSigningIn else { return }
    isCodexAvailable = codexAvailable()
    guard isCodexAvailable else { chatGPTAccount = nil; return }
    do {
      chatGPTAccount = try await codex.account()
      accountError = nil
    } catch {
      chatGPTAccount = nil
      accountError = error.localizedDescription
    }
  }

  func signInWithChatGPT(openURL: @escaping @Sendable (URL) async -> Bool) {
    guard !isSigningIn else { return }
    isSigningIn = true
    accountError = nil
    loginTask = Task {
      defer { isSigningIn = false; loginTask = nil }
      do {
        chatGPTAccount = try await codex.signIn(openURL: openURL)
        try await catalog.clearCache(for: .chatGPT)
        preferredProvider = .chatGPT
        await discoverModels(forceRefresh: true)
      } catch is CancellationError {
        // Cancelling the browser flow is not a connection error.
      } catch {
        accountError = error.localizedDescription
      }
    }
  }

  func cancelSignIn() { loginTask?.cancel() }

  func signOutOfChatGPT() async {
    guard !isSigningIn else { return }
    do {
      try await codex.signOut()
      chatGPTAccount = nil
      accountError = nil
      if preferredProvider == .chatGPT { models = [] }
      try await catalog.clearCache(for: .chatGPT)
    } catch {
      accountError = error.localizedDescription
    }
  }

  func hasAPIKey(for provider: CloudProviderID) -> Bool {
    guard provider != .chatGPT, provider != .claudeCode else { return false }
    return (try? credentialStore.containsAPIKey(for: provider)) ?? false
  }

  func saveAPIKey(_ apiKey: String, for provider: CloudProviderID) throws {
    guard provider != .chatGPT else { throw CodexError.notSignedIn }
    guard provider != .claudeCode else { throw ClaudeCodeError.notSignedIn }
    let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAPIKey.isEmpty else { return }
    try credentialStore.setAPIKey(trimmedAPIKey, for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func removeAPIKey(for provider: CloudProviderID) throws {
    try credentialStore.removeAPIKey(for: provider)
    credentialRevision += 1
    connectionStates[provider] = .idle
  }

  func loadCachedModels() async {
    let provider = preferredProvider
    if let cached = await catalog.cachedModels(for: provider), provider == preferredProvider {
      models = cached
      hasLoadedModelList = true
      selectDefaultModelIfNeeded()
    }
  }

  func discoverModels(forceRefresh: Bool = false) async {
    let provider = preferredProvider
    let id = UUID()
    discoveryID = id
    isDiscovering = true
    discoveryError = nil
    defer { if discoveryID == id { isDiscovering = false } }
    do {
      let discovered = try await catalog.models(
        for: provider,
        forceRefresh: forceRefresh
      )
      guard preferredProvider == provider, discoveryID == id else { return }
      models = discovered
      hasLoadedModelList = true
      selectDefaultModelIfNeeded()
    } catch {
      guard preferredProvider == provider, discoveryID == id else { return }
      models = []
      hasLoadedModelList = false
      discoveryError = error.localizedDescription
    }
  }

  func testConnection(to provider: CloudProviderID) async {
    connectionStates[provider] = .testing
    do {
      let discovered = try await catalog.models(for: provider, forceRefresh: true)
      connectionStates[provider] = .connected(discovered.count)
      if provider == preferredProvider {
        models = discovered
        hasLoadedModelList = true
        discoveryError = nil
        selectDefaultModelIfNeeded()
      }
    } catch {
      connectionStates[provider] = .failed(error.localizedDescription)
    }
  }

  func connectionState(for provider: CloudProviderID) -> ConnectionState {
    connectionStates[provider] ?? .idle
  }

  private func selectDefaultModelIfNeeded() {
    guard preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if preferredProvider == .chatGPT {
      preferredModelID = CodexSubscriptionClient.defaultModelID
    } else if preferredProvider == .claudeCode {
      preferredModelID = ClaudeCodeSubscriptionClient.defaultModelID
    } else if let defaultModel = CloudModelCapabilities.chatModels(models, for: preferredProvider).first {
      preferredModelID = defaultModel.id
    }
  }
}
