import SwiftUI

/// Cloud and search in Settings: the subscriptions, screenshots, web search,
/// advanced provider and model settings, and API keys, through
/// `CloudSettingsForm`.
struct CloudSettingsPage: View {
  @ObservedObject var settings: CloudSettingsModel
  @ObservedObject var screen: ScreenSettings
  @ObservedObject var search: WebSearchSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Subscriptions")
      ChatGPTConnectionControls(settings: settings)
      ClaudeCodeConnectionControls(settings: settings)
      EnigmaHairline()

      ScreenSettingsSection(settings: screen)
      WebSearchSettingsSection(settings: search)
      AdvancedCloudSettings(settings: settings)

      EnigmaSectionHeader("API keys")
      APIKeyRow(settings: settings, provider: .openAI, title: "OpenAI API",
                      subtitle: "Pay as you go with your own key. OpenAI API usage requires separate API billing; a ChatGPT subscription does not include API access.")
      APIKeyRow(settings: settings, provider: .anthropic, title: "Anthropic API",
                      subtitle: "Pay as you go with your own key. Separate billing.")
      APIKeyRow(settings: settings, provider: .gemini, title: "Gemini API",
                      subtitle: "Your own Gemini API key.")
      EnigmaHairline()
    }
    .task { await CloudSettingsForm.load(settings) }
    .onChange(of: settings.preferredProvider) { _, provider in
      Task { await CloudSettingsForm.preferredProviderChanged(to: provider, in: settings) }
    }
  }
}

/// The preferred provider, model, and the provider's thinking or effort setting.
struct AdvancedCloudSettings: View {
  @ObservedObject var settings: CloudSettingsModel

  var body: some View {
    let compatibility = settings.selectedModelCompatibility
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Advanced cloud settings")
      EnigmaRow("Preferred provider") {
        EnigmaMenu("Preferred provider", selection: $settings.preferredProvider,
                   options: CloudProviderID.allCases.map { EnigmaOption($0, $0.displayName) })
      }
      EnigmaRow("Preferred model",
                subtitle: settings.models.isEmpty ? CloudSettingsForm.emptyModelsNotice(in: settings) : nil) {
        if !settings.models.isEmpty {
          EnigmaMenu("Preferred model", selection: $settings.preferredModelID,
                     options: CloudSettingsForm.modelChoices(models: settings.models,
                                                             preferredModelID: settings.preferredModelID)
                       .map { EnigmaOption($0.id, $0.title) })
        }
      }
      EnigmaRow("Manual model ID") {
        EnigmaStatusLine(Self.compatibilityStatus(compatibility), compatibility.message)
          .padding(.top, 4)
      } trailing: {
        EnigmaTextField("Manual model ID", text: $settings.preferredModelID)
          .frame(width: 220)
      }
      if settings.preferredProvider == .chatGPT {
        EnigmaRow("Thinking capacity") {
          EnigmaMenu("Thinking capacity", selection: $settings.codexThinkingCapacity,
                     options: CodexThinkingCapacity.allCases.map { EnigmaOption($0, $0.displayName) })
        }
      }
      if settings.preferredProvider == .claudeCode {
        EnigmaRow("Effort") {
          EnigmaMenu("Effort", selection: $settings.claudeCodeEffort,
                     options: ClaudeCodeEffort.allCases.map { EnigmaOption($0, $0.displayName) })
        }
      }
      EnigmaRow("Model list", subtitle: "Find the compatible chat models for the preferred provider.") {
        if let discoveryError = settings.discoveryError {
          EnigmaStatusLine(.problem, discoveryError).padding(.top, 4)
        }
      } trailing: {
        HStack(spacing: 10) {
          if settings.isDiscovering { EnigmaStatusLine(.busy, "refreshing") }
          Button(CloudSettingsForm.refreshTitle(isDiscovering: settings.isDiscovering)) {
            Task { await settings.discoverModels(forceRefresh: true) }
          }
          .enigmaButtonStyle(.secondary)
          .disabled(!CloudSettingsForm.canRefreshModels(in: settings))
        }
      }
      EnigmaHairline()
    }
  }

  /// Unsupported models are a problem; a compatible one reads as on.
  static func compatibilityStatus(_ compatibility: CloudModelCompatibility) -> EnigmaStatusLine.Status {
    switch compatibility {
    case .compatible: .on
    case .unsupported: .problem
    case .unselected, .unverified: .off
    }
  }
}

/// One provider's API key: the secure field, Save to Keychain, Remove, Test
/// connection, and the connection's status and errors.
struct APIKeyRow: View {
  @ObservedObject var settings: CloudSettingsModel
  let provider: CloudProviderID
  let title: String
  let subtitle: String
  @State private var apiKey = ""
  @State private var error: String?

  static func status(_ status: CloudSettingsForm.ConnectionStatus) -> EnigmaStatusLine.Status {
    switch status.kind {
    case .stored, .connected: .on
    case .testing: .busy
    case .failed: .problem
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaRow(title, subtitle: subtitle)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          EnigmaTextField(settings.hasAPIKey(for: provider) ? "Replace stored API key" : "API key",
                          text: $apiKey, isSecure: true, accessibilityLabel: "\(title) key", onSubmit: save)
          Button("Save to Keychain", action: save)
          .enigmaButtonStyle(.secondary)
          .disabled(!CloudSettingsForm.canSave(apiKey))
          .enigmaTestMarker("Save \(title) key")
          Button("Remove") { error = CloudSettingsForm.removeAPIKey(for: provider, in: settings) }
            .enigmaButtonStyle(.text)
            .disabled(!CloudSettingsForm.canRemoveAPIKey(for: provider, in: settings))
            .accessibilityLabel("Remove \(title) key")
            .enigmaTestMarker("Remove \(title) key")
          Button("Test connection") { Task { await settings.testConnection(to: provider) } }
            .enigmaButtonStyle(.secondary)
            .disabled(!CloudSettingsForm.canTestConnection(to: provider, in: settings))
            .accessibilityLabel("Test \(title) connection")
            .enigmaTestMarker("Test \(title) connection")
        }
        if let status = CloudSettingsForm.connectionStatus(for: provider, in: settings) {
          EnigmaStatusLine(Self.status(status), status.text)
          if let detail = status.detail { EnigmaNote(detail) }
        }
        if let error { EnigmaStatusLine(.problem, error) }
      }
      .padding(.bottom, 12)
    }
  }

  /// Return in the field saves too, as for the Brave key. Nothing typed, nothing saved.
  private func save() {
    guard CloudSettingsForm.canSave(apiKey) else { return }
    error = CloudSettingsForm.saveAPIKey(&apiKey, for: provider, in: settings)
  }
}
