import Foundation

/// What `CloudSettingsPage` does with keys, connection tests, and pickers,
/// kept out of the view so it can be tested.
@MainActor
enum CloudSettingsForm {
  // MARK: API keys

  /// Save stays off until something other than spaces is typed.
  static func canSave(_ apiKey: String) -> Bool {
    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Saves `apiKey` to the Keychain and clears it. On failure the typed key is
  /// kept and the error's message is returned.
  static func saveAPIKey(_ apiKey: inout String, for provider: CloudProviderID,
                         in settings: CloudSettingsModel) -> String? {
    do {
      try settings.saveAPIKey(apiKey, for: provider)
      apiKey = ""
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// Removes the stored key, returning the error's message on failure.
  static func removeAPIKey(for provider: CloudProviderID, in settings: CloudSettingsModel) -> String? {
    do {
      try settings.removeAPIKey(for: provider)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  static func canRemoveAPIKey(for provider: CloudProviderID, in settings: CloudSettingsModel) -> Bool {
    settings.hasAPIKey(for: provider)
  }

  /// A test needs a stored key and no test already running.
  static func canTestConnection(to provider: CloudProviderID, in settings: CloudSettingsModel) -> Bool {
    settings.hasAPIKey(for: provider) && settings.connectionState(for: provider) != .testing
  }

  // MARK: Connection status

  /// The line under a provider's key: stored, testing, reachable, or failed.
  struct ConnectionStatus: Equatable {
    enum Kind: Equatable { case stored, testing, connected, failed }

    let kind: Kind
    let text: String
    var detail: String?
  }

  static func connectionStatus(for provider: CloudProviderID, in settings: CloudSettingsModel) -> ConnectionStatus? {
    connectionStatus(state: settings.connectionState(for: provider), hasAPIKey: settings.hasAPIKey(for: provider))
  }

  static func connectionStatus(state: CloudSettingsModel.ConnectionState, hasAPIKey: Bool) -> ConnectionStatus? {
    switch state {
    case .idle:
      hasAPIKey ? ConnectionStatus(kind: .stored, text: "API key stored in Keychain") : nil
    case .testing:
      ConnectionStatus(kind: .testing, text: "Testing connection…")
    case .connected(let modelCount):
      ConnectionStatus(kind: .connected, text: "API reachable · Compatible chat models: \(modelCount)",
                       detail: "Model-list check only. Sending and billing were not tested.")
    case .failed(let message):
      ConnectionStatus(kind: .failed, text: message)
    }
  }

  // MARK: Model picker

  struct ModelChoice: Identifiable, Equatable {
    let id: String
    let title: String
  }

  /// The preferred-model choices. A blank selection adds "Choose a model", and
  /// a manual ID that isn't listed is kept as a choice.
  static func modelChoices(models: [CloudModel], preferredModelID: String) -> [ModelChoice] {
    var choices: [ModelChoice] = []
    if preferredModelID.isEmpty { choices.append(ModelChoice(id: "", title: "Choose a model")) }
    choices += models.map { ModelChoice(id: $0.id, title: $0.displayName) }
    if !preferredModelID.isEmpty, !models.contains(where: { $0.id == preferredModelID }) {
      choices.append(ModelChoice(id: preferredModelID, title: "Manual · \(preferredModelID)"))
    }
    return choices
  }

  /// Shown instead of the model picker while there are no models.
  static func emptyModelsNotice(in settings: CloudSettingsModel) -> String {
    settings.modelDiscoveryNotice
      ?? "Refresh models to find compatible chat choices, or enter a model ID manually."
  }

  static func refreshTitle(isDiscovering: Bool) -> String {
    isDiscovering ? "Refreshing…" : "Refresh Models"
  }

  static func canRefreshModels(in settings: CloudSettingsModel) -> Bool {
    !settings.isDiscovering && settings.hasCloudAccess(for: settings.preferredProvider)
  }

  // MARK: Loading

  /// Runs when the Cloud settings appear: account checks, cached models, then
  /// a model refresh if the preferred provider is usable but has none yet.
  static func load(_ settings: CloudSettingsModel) async {
    await settings.refreshChatGPTAccount()
    await settings.refreshClaudeCodeAccount()
    await settings.loadCachedModels()
    if settings.hasCloudAccess(for: settings.preferredProvider), settings.models.isEmpty {
      await settings.discoverModels()
    }
  }

  /// Runs when the preferred provider changes: check its sign-in, then find its models.
  static func preferredProviderChanged(to provider: CloudProviderID, in settings: CloudSettingsModel) async {
    if provider == .chatGPT { await settings.refreshChatGPTAccount() }
    if provider == .claudeCode { await settings.refreshClaudeCodeAccount() }
    guard settings.preferredProvider == provider, settings.hasCloudAccess(for: provider) else { return }
    await settings.discoverModels()
  }
}
