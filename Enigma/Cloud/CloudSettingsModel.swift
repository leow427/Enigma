import Combine
import Foundation

struct CloudPreferencesStore: @unchecked Sendable {
  private enum Key {
    static let preferredProvider = "aiSpotlight.cloud.preferredProvider"
    static let didAdoptLunaDefault = "aiSpotlight.cloud.didAdoptLunaDefault"
    static let didAdoptCodexDefault = "aiSpotlight.cloud.didAdoptCodexDefault"
    static let preferredCodexThinkingCapacity = "aiSpotlight.cloud.preferredCodexThinkingCapacity"
    static let preferredClaudeCodeEffort = "aiSpotlight.cloud.preferredClaudeCodeEffort"
    static let autoMayUseFreeGemini = "aiSpotlight.cloud.autoMayUseFreeGemini"
    static func preferredModel(_ provider: CloudProviderID) -> String {
      "aiSpotlight.cloud.preferredModel.\(provider.rawValue)"
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if !defaults.bool(forKey: Key.didAdoptCodexDefault) {
      let previousModel = defaults.string(forKey: Key.preferredModel(.chatGPT))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // A saved ChatGPT model is the person's choice; none means Codex's default. Older
      // versions saved models nobody chose: the first discovered model (usually Sol) before
      // the Luna migration, then the built-in Luna default whenever no choice was made.
      // Clear those once, so a later explicit choice of either is still respected.
      let lunaMigrationRan = defaults.bool(forKey: Key.didAdoptLunaDefault)
      if previousModel == CodexSubscriptionClient.defaultModelID || (!lunaMigrationRan && previousModel == "gpt-5.6-sol") {
        defaults.removeObject(forKey: Key.preferredModel(.chatGPT))
      }
      defaults.set(true, forKey: Key.didAdoptLunaDefault)
      defaults.set(true, forKey: Key.didAdoptCodexDefault)
    }
  }

  func preferredProvider() -> CloudProviderID {
    storedPreferredProvider() ?? .chatGPT
  }

  /// The provider saved by choosing one, or nil while the built-in default applies.
  func storedPreferredProvider() -> CloudProviderID? {
    defaults.string(forKey: Key.preferredProvider).flatMap(CloudProviderID.init(rawValue:))
  }

  func setPreferredProvider(_ provider: CloudProviderID) {
    defaults.set(provider.rawValue, forKey: Key.preferredProvider)
  }

  /// The saved model, or the built-in default when none is saved. For ChatGPT, prefer
  /// `chosenModel(for:)` with Codex's own default (`CodexSubscriptionClient.automaticModelID`).
  func preferredModel(for provider: CloudProviderID) -> String {
    if let model = chosenModel(for: provider) { return model }
    switch provider {
    case .chatGPT: return CodexSubscriptionClient.defaultModelID
    case .claudeCode: return ClaudeCodeSubscriptionClient.defaultModelID
    case .openAI, .anthropic, .gemini, .free: return ""
    }
  }

  /// The model the person chose for `provider`, or nil when none is saved.
  func chosenModel(for provider: CloudProviderID) -> String? {
    let model = defaults.string(forKey: Key.preferredModel(provider)) ?? ""
    return model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model
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

  /// Off by default: on Google's free tier, prompts may be used to improve Google's products (F34).
  func autoMayUseFreeGemini() -> Bool { defaults.bool(forKey: Key.autoMayUseFreeGemini) }

  func setAutoMayUseFreeGemini(_ allowed: Bool) { defaults.set(allowed, forKey: Key.autoMayUseFreeGemini) }

  /// A Claude Code the person chose with "Choose Claude Code…", the only path saved.
  func chosenClaudeCodePath() -> String? {
    defaults.string(forKey: ClaudeCodeRuntime.chosenPathKey)
  }

  func setChosenClaudeCodePath(_ path: String) {
    defaults.set(path, forKey: ClaudeCodeRuntime.chosenPathKey)
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

  /// The outcome of an explicit "Check sign-in status".
  enum SignInCheck: Equatable {
    case signedIn(String?)
    case notSignedIn
    case notInstalled
    /// ChatGPT with no Codex yet: Sign in downloads it, so nothing is wrong.
    case notSignedInNeedsCodexDownload
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
      models = []
      if preferredProvider == .chatGPT, preferences.chosenModel(for: .chatGPT) == nil {
        applyAutomaticChatGPTModel()
      } else {
        preferredModelID = preferences.preferredModel(for: preferredProvider)
      }
      hasLoadedModelList = false
      discoveryError = nil
      Task { await loadCachedModels() }
    }
  }

  /// The model requests use. Setting it saves it as the person's choice, except while
  /// Enigma fills in Codex's default for someone who hasn't chosen a ChatGPT model.
  @Published var preferredModelID: String {
    didSet {
      guard !isApplyingAutomaticModel else { return }
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

  @Published var autoMayUseFreeGemini: Bool {
    didSet { preferences.setAutoMayUseFreeGemini(autoMayUseFreeGemini) }
  }

  /// Apple's model on Private Cloud Compute (F34 Task 8). False until its client ships.
  var isApplePCCAvailable: Bool { false }

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
  @Published private(set) var isCheckingChatGPT = false
  @Published private(set) var chatGPTCheck: SignInCheck?
  @Published private(set) var isCheckingClaudeCode = false
  @Published private(set) var claudeCodeCheck: SignInCheck?
  @Published private(set) var isDownloadingCodex = false
  @Published private(set) var codexDownloadProgress: Double = 0
  @Published private(set) var isInstallingClaudeCode = false

  private let credentialStore: any CloudCredentialStore
  private let catalog: CloudModelCatalog
  private let preferences: CloudPreferencesStore
  private let codex: CodexSubscriptionClient
  private let codexAvailable: @Sendable () -> Bool
  /// Asks the shell where Codex is; `true` first forgets a cached "not found".
  private let prepareCodexLookup: @Sendable (Bool) async -> Void
  private let installCodex: CodexInstall
  private let claudeCode: ClaudeCodeSubscriptionClient
  private let claudeCodeSignInPollInterval: Duration
  private var loginTask: Task<Void, Never>?
  private var claudeCodeSignInTask: Task<Void, Never>?
  private var discoveryID = UUID()
  private var isApplyingAutomaticModel = false

  typealias CodexInstall = @Sendable (@escaping @Sendable (ModelDownloadProgress) async -> Void) async throws -> Void

  /// Sign-in waits this many polls after the sign-in script opens, and longer
  /// after the install script, which also downloads Claude Code.
  static let claudeCodeSignInAttempts = 150
  static let claudeCodeInstallAttempts = 450

  /// `codexAvailable` replaces the live lookup; the live login-shell question is
  /// then skipped unless `codexShellLookup` is given. `installCodex` replaces the
  /// download of Enigma's pinned Codex, which a test host never runs.
  init(
    credentialStore: any CloudCredentialStore,
    catalog: CloudModelCatalog,
    preferences: CloudPreferencesStore = CloudPreferencesStore(),
    codex: CodexSubscriptionClient = .live,
    codexAvailable: (@Sendable () -> Bool)? = nil,
    codexShellLookup: LoginShellToolLookup? = nil,
    installCodex: CodexInstall? = nil,
    claudeCode: ClaudeCodeSubscriptionClient = .live,
    claudeCodeSignInPollInterval: Duration = .seconds(2)
  ) {
    self.codex = codex
    self.codexAvailable = codexAvailable ?? { CodexRuntimeConfiguration.executableURL() != nil }
    if let lookup = codexShellLookup ?? (codexAvailable == nil ? .shared : nil) {
      prepareCodexLookup = { askAgain in
        if askAgain { lookup.forgetNotFound("codex") }
        _ = await lookup.resolve("codex")
      }
    } else {
      prepareCodexLookup = { _ in }
    }
    if let installCodex {
      self.installCodex = installCodex
    } else if TestHost.isActive {
      self.installCodex = { @Sendable _ in throw CodexRuntimeError.installFailed("Test hosts never download Codex.") }
    } else {
      self.installCodex = { @Sendable progress in _ = try await CodexRuntime.install(progress: progress) }
    }
    isCodexAvailable = self.codexAvailable()
    self.claudeCode = claudeCode
    self.claudeCodeSignInPollInterval = claudeCodeSignInPollInterval
    isClaudeCodeAvailable = claudeCode.isInstalled
    self.credentialStore = credentialStore
    self.catalog = catalog
    self.preferences = preferences
    let provider = preferences.preferredProvider()
    preferredProvider = provider
    preferredModelID = provider == .chatGPT && preferences.chosenModel(for: .chatGPT) == nil
      ? CodexSubscriptionClient.automaticModelID(in: CodexListedModels.shared.models)
      : preferences.preferredModel(for: provider)
    codexThinkingCapacity = preferences.preferredCodexThinkingCapacity()
    claudeCodeEffort = preferences.preferredClaudeCodeEffort()
    autoMayUseFreeGemini = preferences.autoMayUseFreeGemini()
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
    case .free: hasAPIKey(for: .gemini) || isApplePCCAvailable
    }
  }

  /// `asksShellAgain`, for the explicit check, re-asks the shell after a cached "not found".
  @discardableResult
  func refreshClaudeCodeAccount(asksShellAgain: Bool = false) async -> SignInCheck {
    claudeCodeCheck = nil
    // The shell's answer ranks below the folders, so a found tool needs no shell.
    if asksShellAgain || !claudeCode.isInstalled { await claudeCode.prepareLookup(askAgain: asksShellAgain) }
    isClaudeCodeAvailable = claudeCode.isInstalled
    guard isClaudeCodeAvailable else { claudeCodeAccount = nil; return .notInstalled }
    do {
      let account = try await claudeCode.account()
      claudeCodeAccount = account
      claudeCodeError = nil
      return account.map { .signedIn($0.email) } ?? .notSignedIn
    } catch {
      claudeCodeAccount = nil
      claudeCodeError = error.localizedDescription
      if let error = error as? ClaudeCodeError, error == .notSignedIn { return .notSignedIn }
      return .failed(error.localizedDescription)
    }
  }

  /// The explicit button: shows progress, then always leaves a result.
  func checkClaudeCodeSignIn() async {
    guard !isCheckingClaudeCode, !isWaitingForClaudeCodeSignIn else { return }
    isCheckingClaudeCode = true
    claudeCodeCheck = nil
    defer { isCheckingClaudeCode = false }
    let result = await refreshClaudeCodeAccount(asksShellAgain: true)
    if !isWaitingForClaudeCodeSignIn { claudeCodeCheck = result }
  }

  /// Claude Code owns its browser sign-in, so it runs in Terminal while Enigma
  /// checks the shared login status until it is complete.
  func signInToClaudeCode(openScript: @escaping @MainActor (URL) -> Bool) {
    startClaudeCodeTerminal(script: { try $0.runtimeSignInScript() }, openScript: openScript,
                            attempts: Self.claudeCodeSignInAttempts, installs: false)
  }

  /// Runs Anthropic's official installer in Terminal, which then signs in, and
  /// waits as sign-in does: Enigma never downloads or bundles Claude Code.
  func installClaudeCode(openScript: @escaping @MainActor (URL) -> Bool) {
    startClaudeCodeTerminal(script: { try $0.runtimeInstallScript() }, openScript: openScript,
                            attempts: Self.claudeCodeInstallAttempts, installs: true)
  }

  /// Saves a Claude Code the person chose, when it is an executable file.
  @discardableResult
  func chooseClaudeCode(at url: URL) async -> Bool {
    guard !isCheckingClaudeCode, !isWaitingForClaudeCodeSignIn else { return false }
    guard CommandLineToolSearch.isExecutableFile(url.path) else {
      claudeCodeCheck = nil
      claudeCodeError = "That file is not a program Enigma can run. Choose the claude file from your Claude Code install."
      return false
    }
    preferences.setChosenClaudeCodePath(url.path)
    claudeCodeError = nil
    isCheckingClaudeCode = true
    defer { isCheckingClaudeCode = false }
    claudeCodeCheck = await refreshClaudeCodeAccount()
    return true
  }

  private func startClaudeCodeTerminal(script: (ClaudeCodeSubscriptionClient) throws -> URL,
                                       openScript: @escaping @MainActor (URL) -> Bool, attempts: Int, installs: Bool) {
    guard !isWaitingForClaudeCodeSignIn else { return }
    claudeCodeError = nil
    claudeCodeCheck = nil
    do {
      guard openScript(try script(claudeCode)) else {
        claudeCodeError = installs ? "Terminal could not be opened to install Claude Code."
          : "Terminal could not be opened to sign in to Claude Code."
        return
      }
    } catch {
      claudeCodeError = error.localizedDescription
      return
    }
    isWaitingForClaudeCodeSignIn = true
    isInstallingClaudeCode = installs
    claudeCodeSignInTask = Task {
      defer { isWaitingForClaudeCodeSignIn = false; isInstallingClaudeCode = false; claudeCodeSignInTask = nil }
      for _ in 0..<attempts {
        do { try await Task.sleep(for: claudeCodeSignInPollInterval) } catch { return }
        isClaudeCodeAvailable = claudeCode.isInstalled
        guard isClaudeCodeAvailable else { continue }
        if let account = try? await claudeCode.account() {
          claudeCodeAccount = account
          claudeCodeError = nil
          try? await catalog.clearCache(for: .claudeCode)
          preferredProvider = .claudeCode
          await discoverModels(forceRefresh: true)
          return
        }
      }
      claudeCodeError = installs && !isClaudeCodeAvailable
        ? "Claude Code was not installed. Check the Terminal window, then try again."
        : "Claude Code sign-in was not completed. Try again, or check the Terminal window."
    }
  }

  func cancelClaudeCodeSignIn() { claudeCodeSignInTask?.cancel() }

  /// `asksShellAgain`, for the explicit check, re-asks the shell after a cached "not found".
  @discardableResult
  func refreshChatGPTAccount(asksShellAgain: Bool = false) async -> SignInCheck? {
    chatGPTCheck = nil
    guard !isSigningIn else { return nil }
    // The shell's answer ranks below the folders, so a found Codex needs no shell.
    if asksShellAgain || !codexAvailable() {
      await prepareCodexLookup(asksShellAgain)
      // Sign-in may have started while the shell answered.
      guard !isSigningIn else { return nil }
    }
    isCodexAvailable = codexAvailable()
    guard isCodexAvailable else { chatGPTAccount = nil; return .notSignedInNeedsCodexDownload }
    do {
      let account = try await codex.account()
      chatGPTAccount = account
      accountError = nil
      return account.map { .signedIn($0.email) } ?? .notSignedIn
    } catch {
      chatGPTAccount = nil
      accountError = error.localizedDescription
      if let error = error as? CodexError, error == .notSignedIn { return .notSignedIn }
      return .failed(error.localizedDescription)
    }
  }

  /// The explicit button: shows progress, then always leaves a result.
  func checkChatGPTSignIn() async {
    guard !isCheckingChatGPT, !isSigningIn else { return }
    isCheckingChatGPT = true
    chatGPTCheck = nil
    defer { isCheckingChatGPT = false }
    let result = await refreshChatGPTAccount(asksShellAgain: true)
    if !isSigningIn { chatGPTCheck = result }
  }

  /// Signs in through Codex's browser login. When no Codex is found, this
  /// first downloads Enigma's pinned copy and then continues without a second click.
  func signInWithChatGPT(openURL: @escaping @Sendable (URL) async -> Bool) {
    guard !isSigningIn else { return }
    isSigningIn = true
    accountError = nil
    chatGPTCheck = nil
    loginTask = Task {
      defer { isSigningIn = false; isDownloadingCodex = false; loginTask = nil }
      do {
        // The shell may know a Codex the folders don't; ask before downloading.
        await prepareCodexLookup(false)
        if !codexAvailable() {
          isDownloadingCodex = true
          codexDownloadProgress = 0
          do {
            try await installCodex { update in
              await MainActor.run { self.codexDownloadProgress = update.fractionCompleted }
            }
          } catch let error where error is CancellationError || Task.isCancelled {
            // A cancelled transfer can surface as a URL error.
            throw CancellationError()
          } catch {
            throw CodexInstallFailure(error)
          }
          isDownloadingCodex = false
          isCodexAvailable = codexAvailable()
          guard isCodexAvailable else { throw CodexInstallFailure(CodexRuntimeError.incomplete) }
        }
        try Task.checkCancellation()
        chatGPTAccount = try await codex.signIn(openURL: openURL)
        try await catalog.clearCache(for: .chatGPT)
        preferredProvider = .chatGPT
        await discoverModels(forceRefresh: true)
      } catch is CancellationError {
        // Cancelling the download or the browser flow is not a connection error.
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
      chatGPTCheck = nil
      if preferredProvider == .chatGPT { models = [] }
      try await catalog.clearCache(for: .chatGPT)
    } catch {
      accountError = error.localizedDescription
    }
  }

  func hasAPIKey(for provider: CloudProviderID) -> Bool {
    guard provider != .chatGPT, provider != .claudeCode, provider != .free else { return false }
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
    if provider == .free { return showFreeModels() }
    if let cached = await catalog.cachedModels(for: provider), provider == preferredProvider {
      models = cached
      hasLoadedModelList = true
      selectDefaultModelIfNeeded()
    } else if provider == .chatGPT, provider == preferredProvider {
      // Reading the cache shared Codex's last list even when it is too old to show.
      selectDefaultModelIfNeeded()
    }
  }

  func discoverModels(forceRefresh: Bool = false) async {
    let provider = preferredProvider
    if provider == .free { return showFreeModels() }
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

  /// Free models are listed from what is set up on this Mac, without a network call.
  private func showFreeModels() {
    models = FreeModelCatalog.available(hasGeminiKey: hasAPIKey(for: .gemini), appleAvailable: isApplePCCAvailable)
    hasLoadedModelList = true
    discoveryError = nil
    selectDefaultModelIfNeeded()
  }

  /// The daily background refresh of a subscription route's list: no progress, no error
  /// shown, and on failure the cached list (and the one shown) stays as it was. Returns
  /// false when the refresh failed and is worth retrying soon; a route that isn't signed
  /// in or installed has nothing to refresh, which is not a failure.
  @discardableResult
  func refreshModelsQuietly(for provider: CloudProviderID) async -> Bool {
    let discovered: [CloudModel]
    do {
      discovered = try await catalog.models(for: provider, forceRefresh: true)
    } catch let error as CodexError where error == .notSignedIn || error == .notInstalled {
      return true
    } catch let error as ClaudeCodeError where [.notSignedIn, .notSubscription, .notInstalled].contains(error) {
      return true
    } catch ClaudeCodeError.exited, ClaudeCodeError.invalidResponse {
      // `auth status` printed something other than its JSON: an unexpected CLI, which an
      // hourly retry won't fix.
      return true
    } catch {
      return false
    }
    guard provider == preferredProvider else { return true }
    models = discovered
    hasLoadedModelList = true
    discoveryError = nil
    selectDefaultModelIfNeeded()
    return true
  }

  /// A cheap, local sign that the person may use ChatGPT in Enigma, checked before the daily
  /// refresh starts Codex: ChatGPT was chosen as the provider, a ChatGPT model was chosen,
  /// or a ChatGPT list is cached (only a signed-in Codex lists models).
  func mayUseChatGPT() async -> Bool {
    await mayUse(.chatGPT)
  }

  /// The same sign for Claude Code, checked before the daily refresh runs its CLI.
  func mayUseClaudeCode() async -> Bool {
    await mayUse(.claudeCode)
  }

  private func mayUse(_ provider: CloudProviderID) async -> Bool {
    if preferences.storedPreferredProvider() == provider || preferences.chosenModel(for: provider) != nil { return true }
    return await catalog.hasCachedModels(for: provider)
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

  /// Where Enigma looked for Claude Code, for "not found".
  var claudeCodeLookedIn: String { claudeCode.runtime.lookedIn() }

  private func selectDefaultModelIfNeeded() {
    // Without a choice, ChatGPT follows Codex's current default as the list changes.
    if preferredProvider == .chatGPT, preferences.chosenModel(for: .chatGPT) == nil {
      applyAutomaticChatGPTModel()
      return
    }
    guard preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if preferredProvider == .claudeCode {
      preferredModelID = ClaudeCodeSubscriptionClient.defaultModelID
    } else if let defaultModel = CloudModelCapabilities.chatModels(models, for: preferredProvider).first {
      preferredModelID = defaultModel.id
    }
  }

  /// Shows Codex's default (from the loaded list, else the last cached one) without
  /// saving it, so it never becomes a choice the person didn't make.
  private func applyAutomaticChatGPTModel() {
    showWithoutSaving(CodexSubscriptionClient.automaticModelID(in: models.isEmpty ? CodexListedModels.shared.models : models))
  }

  private func showWithoutSaving(_ modelID: String) {
    guard modelID != preferredModelID else { return }
    isApplyingAutomaticModel = true
    defer { isApplyingAutomaticModel = false }
    preferredModelID = modelID
  }

  /// Uses the ChatGPT model File Mode checked when it hands a draft to Cloud mode. That
  /// check uses the chosen model when Codex lists it and otherwise Codex's default, so the
  /// model is saved only when it is the person's choice; a fallback is shown, not saved.
  func useChatGPTModelFromFileMode(_ modelID: String) {
    preferredProvider = .chatGPT
    if preferences.chosenModel(for: .chatGPT) == modelID {
      preferredModelID = modelID
    } else {
      showWithoutSaving(modelID)
    }
  }
}

/// Getting Codex failed; Sign in can try again.
struct CodexInstallFailure: LocalizedError, Equatable {
  enum Stage: Equatable { case download, install, start }

  let stage: Stage
  let message: String

  init(_ error: Error) {
    switch error as? CodexRuntimeError {
    case .cannotStart?: stage = .start
    case .some: stage = .install
    case nil: stage = .download
    }
    message = error.localizedDescription
  }

  var errorDescription: String? {
    let what = switch stage {
    case .download: "Codex could not be downloaded from OpenAI."
    case .install: "Codex was downloaded but could not be installed."
    case .start: "Codex was downloaded but could not be started."
    }
    return "\(what) \(message) Choose Sign in to try again."
  }
}
