import SwiftUI

/// Web search in Settings (spec §8, amended for D128): automatic search, on-device search as the
/// default, Brave as an optional extra with a key in the Keychain, and the blocked sites.
struct WebSearchSettingsSection: View {
  @ObservedObject var settings: WebSearchSettings
  @State private var apiKey = ""
  @State private var error: String?

  static let header = "Web search"
  static let automaticTitle = "Search automatically when fresh information is needed"
  static let automaticSubtitle = "On by default. Questions about news, recent events and changing facts search automatically, in every mode. Turn this off to search only when you type /search."
  static let statusTitle = "Web search"
  static let statusSubtitle = "Runs on this Mac. No account or key needed."
  static let braveTitle = "Use Brave Search instead"
  static let braveSubtitle = "Optional. With a saved key, searches go to Brave instead of running on this Mac. Needs a Brave Search API key with LLM Context access; Brave bills it separately. Stored in macOS Keychain."
  static let blockedTitle = "Blocked sites"
  static let blockedEmptyNote = "Use Never use this site in a reply's sources to stop Enigma using a site."
  static let blockedCloudNote = "ChatGPT and Claude Code, when they use their own search, are asked to avoid these sites, but Enigma can't enforce it."
  static let sitesNote = "Queries go to DuckDuckGo and Wikipedia, to Wikidata for facts, and to Google News for news headlines. Result pages are read on this Mac, up to six at a time, without scripts or images. Weather comes from Open-Meteo and nearby places from Apple Maps."

  /// The status row: on-device is ready with no key; a saved key means Brave runs searches (D128).
  static func searchStatus(hasAPIKey: Bool) -> (EnigmaStatusLine.Status, String) {
    hasAPIKey ? (.on, "Brave in use") : (.on, "ready")
  }

  static func keyStatus(hasAPIKey: Bool) -> (EnigmaStatusLine.Status, String) {
    hasAPIKey ? (.on, "key saved") : (.off, "not used")
  }

  var body: some View {
    let search = Self.searchStatus(hasAPIKey: settings.hasAPIKey)
    let key = Self.keyStatus(hasAPIKey: settings.hasAPIKey)
    VStack(alignment: .leading, spacing: 0) {
      EnigmaSectionHeader(Self.header)
      EnigmaRow(Self.automaticTitle, subtitle: Self.automaticSubtitle) {
        EnigmaSwitch(Self.automaticTitle, isOn: $settings.automaticallySearch)
      }
      EnigmaRow(Self.statusTitle, subtitle: Self.statusSubtitle) {
        EnigmaStatusLine(search.0, search.1)
      }
      EnigmaRow(Self.braveTitle, subtitle: Self.braveSubtitle) {
        EnigmaStatusLine(key.0, key.1)
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
      EnigmaRow(Self.blockedTitle, subtitle: Self.blockedCloudNote) { EmptyView() }
      if settings.blockedSites.isEmpty {
        EnigmaNote(Self.blockedEmptyNote).padding(.vertical, 10).enigmaTestMarker("No blocked sites")
      } else {
        // Most recently blocked first, as cloud models' own search gets them.
        ForEach(settings.blockedDomainsMostRecentFirst, id: \.self) { domain in
          EnigmaRow(domain) {
            Button("Remove") { settings.unblock(domain) }
              .enigmaButtonStyle(.text)
              .accessibilityLabel("Remove \(domain) from blocked sites")
              .enigmaTestMarker("Remove \(domain)")
          }
        }
      }
      EnigmaHairline()
      EnigmaNote(Self.sitesNote).padding(.top, 10)
    }
  }

  /// Return in the field saves too.
  private func save() {
    guard WebSearchSettings.canSaveAPIKey(apiKey) else { return }
    error = settings.saveAPIKey(from: &apiKey)
  }
}
