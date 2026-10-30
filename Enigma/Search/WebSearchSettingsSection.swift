import SwiftUI

/// Brave web search in Settings: automatic search, and the Brave key in the
/// Keychain.
struct WebSearchSettingsSection: View {
  @ObservedObject var settings: WebSearchSettings
  @State private var apiKey = ""
  @State private var error: String?

  static func keyStatus(hasAPIKey: Bool) -> (EnigmaStatusLine.Status, String) {
    hasAPIKey ? (.on, "key saved") : (.off, "no key")
  }

  var body: some View {
    let status = Self.keyStatus(hasAPIKey: settings.hasAPIKey)
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader("Web search · Brave")
      EnigmaRow("Search automatically when fresh information is needed",
                subtitle: "On by default. With a saved Brave key, questions about news, recent events and changing facts can search automatically, including in Local mode. Without a key, only ChatGPT and Claude Code search, with their provider's own search. Turn this off for manual-only search.") {
        EnigmaSwitch("Search automatically when fresh information is needed", isOn: $settings.automaticallySearch)
      }
      EnigmaRow("Brave Search API key",
                subtitle: "Use a Brave Search key with LLM Context access. Stored in macOS Keychain. Brave usage is billed separately.") {
        EnigmaStatusLine(status.0, status.1)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          EnigmaTextField(settings.hasAPIKey ? "Replace stored Brave API key" : "Brave Search API key",
                          text: $apiKey, isSecure: true, accessibilityLabel: "Brave Search API key", onSubmit: save)
          Button("Save key", action: save)
            .enigmaButtonStyle(.secondary)
            .disabled(!WebSearchSettings.canSaveAPIKey(apiKey))
            .enigmaTestMarker("Save Brave key")
          Button("Remove key") { error = settings.removeAPIKey(clearing: &apiKey) }
            .enigmaButtonStyle(.text)
            .disabled(!settings.hasAPIKey)
            .enigmaTestMarker("Remove Brave key")
        }
        if let error { EnigmaStatusLine(.problem, error) }
      }
      .padding(.bottom, 12)
      EnigmaHairline()
      VStack(alignment: .leading, spacing: 6) {
        if settings.hasAPIKey {
          EnigmaNote("Type /search to search for this message only, even for timeless questions. Delete it before sending to cancel explicit search. Later messages follow the automatic-search setting.")
        }
        EnigmaNote("Search sends queries to Brave, including in Local mode. Relevant attached context may refine a query only after your question authorizes search; your selected model writes the answer.")
        Link("Brave Search API dashboard", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
          .enigmaButtonStyle(.text)
          .padding(.leading, -8)
      }
      .padding(.top, 10)
    }
  }

  /// Return in the field saves too, as in the welcome.
  private func save() {
    guard WebSearchSettings.canSaveAPIKey(apiKey) else { return }
    error = settings.saveAPIKey(from: &apiKey)
  }
}
